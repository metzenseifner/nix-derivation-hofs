{
  description = ''
      Higher-order package combinators (with* family).

      Each combinator is config-first and curried: it takes a configuration
      attrset and returns an endofunctor Package -> Package on the category of
      Nix packages. Fixing the config yields a reusable wrapper, and because
      the wrapper's domain and codomain are the same type they compose freely:

        withHelp { inherit pkgs; doc = "some docs"; } (withUnexecuted { inherit pkgs; } pkg)

      Algebraically (Config is an attrset that always carries pkgs):
        withHelp       : { pkgs, doc } -> Package -> Package        -- augment execution with documentation
        withHelps      : String -> Package -> Package               -- attach doc metadata (doc-first, curried)
        mkHelpPkg      : { pkgs, name, derivations } -> Package     -- fold documented packages into a help command
        withUnexecuted : { pkgs } -> Package -> Package             -- project the documentation, discard execution
        withExpansion  : { pkgs } -> Package -> Package             -- unfold /nix/store references to a fixed point
        withSource     : { pkgs, depth?, execute? } -> Package -> Package  -- print the implementation (depth-bounded), then optionally execute
        withTime       : { pkgs } -> Package -> Package             -- measure execution duration
        withEnv        : { pkgs, filter?, descriptions? } -> Package -> Package  -- print environment variables

      Standalone tools:
        nix-expand    : FilePath -> IO ()              -- withExpansion as a standalone app over arbitrary executables

       Key functional patterns at play

    ┌──────────────────────┬────────────────┬───────────────────────────────────────────────────────────────┐
    │       Pattern        │     Where      │                         What it does                          │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Decorator (//)       │ withHelps       │ Augments a derivation with metadata without altering its      │
    │                      │                │ build                                                         │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Functor map          │ documented     │ Lifts withHelps uniformly over the closure                     │
    │ (mapAttrs)           │                │                                                               │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Catamorphism (fold)  │ mkHelpCli      │ Collapses [Package] into a single help Package                │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Partial application  │ withHelps       │ Doc-first arg order lets you curry: map (withHelps "same doc") │
    │                      │ "desc"         │  [a b c]                                                      │
    └──────────────────────┴────────────────┴───────────────────────────────────────────────────────────────┘

    The __doc convention keeps the doc co-located with the derivation through composition — if you later do
    withTime (withHelps "desc" pkg), the __doc survives because withTime returns a new derivation via
    writeShellScriptBin, but you'd want mkHelpCli to reference the documented versions, not the composed ones.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # -------------------------------------------------------------------------
      # Shared expansion kernel used by both withExpansion and nix-expand.
      #
      # expand : FilePath -> IO ()
      #
      # Breadth-first traversal of /nix/store references starting from a file.
      # Text files have their contents printed; binary files are identified but
      # not dumped. Iteration proceeds to the fixed point S* where no new
      # store paths are discovered.
      #
      # Takes one parameter at the Nix level: gnugrep package (to avoid
      # closing over a specific pkgs set).
      # -------------------------------------------------------------------------
      expansionKernel = gnugrep: ''
        __is_binary() {
          local mime
          mime=$(file --brief --mime-encoding "$1" 2>/dev/null)
          [[ "$mime" == "binary" ]]
        }

        # __expand <entrypoint> [max_depth]
        #   max_depth empty/unset => traverse to the fixed point (infinite).
        #   max_depth = N         => print depths 0..N inclusive, then stop.
        #   depth 0 is the entrypoint itself; each subsequent depth is one more
        #   layer of /nix/store references unfolded from the previous layer.
        __expand() {
          local entrypoint="$1"
          local max_depth="''${2:-}"
          local -A seen=()
          local -a frontier=( "$entrypoint" )
          local depth=0

          while [[ ''${#frontier[@]} -gt 0 ]]; do
            if [[ -n "$max_depth" && "$depth" -gt "$max_depth" ]]; then
              break
            fi
            local -a next_frontier=()
            echo "--- depth $depth ---"

            for path in "''${frontier[@]}"; do
              [[ -n "''${seen[$path]+x}" ]] && continue
              seen["$path"]=1

              if [[ -f "$path" ]]; then
                if __is_binary "$path"; then
                  echo ">> $path [binary]"
                else
                  echo ">> $path"
                  cat "$path"
                  echo ""

                  # Extract /nix/store references from this text file
                  while IFS= read -r ref; do
                    if [[ -z "''${seen[$ref]+x}" ]]; then
                      next_frontier+=( "$ref" )
                    fi
                  done < <(${gnugrep}/bin/grep -oP "/nix/store/[a-z0-9]{32}-[^[:space:]\"'\\\\)]+" "$path" | sort -u)
                fi
              elif [[ -d "$path" ]]; then
                echo ">> $path [directory, skipped]"
              else
                echo ">> $path [not found]"
              fi
            done

            frontier=( "''${next_frontier[@]}" )
            (( depth++ ))
          done
        }
      '';
    in
    {
      # ---------------------------------------------------------------------------
      # lib: the primary export — pure functions, no system dependency
      # ---------------------------------------------------------------------------
      lib = {

        # -----------------------------------------------------------------------
        # withHelp : { pkgs, doc } -> Package -> Package
        #
        # Plain English:
        #   Config-first and curried. Given { pkgs, doc }, returns a
        #   Package -> Package wrapper. Applied to a package, every time its
        #   executable runs the documentation string is printed to stdout
        #   first, then the original command executes normally with all
        #   arguments forwarded.
        #
        # Algebraic characterisation:
        #   Let exec(p) denote the side-effect of running package p.
        #   withHelp({doc=s})(p) produces p' where exec(p') = print(s) ; exec(p).
        #   withHelp is a natural transformation that prepends an IO action
        #   while preserving the rest of the program's behaviour.
        # -----------------------------------------------------------------------
        withHelp =
          {
            pkgs,
            doc,
          }:
          pkg:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
          in
          pkgs.writeShellScriptBin name ''
            echo ${pkgs.lib.escapeShellArg doc}
            exec ${pkg}/bin/${name} "$@"
          '';

        # -----------------------------------------------------------------------
        # withUnexecuted : { pkgs } -> Package -> Package
        #
        # Plain English:
        #   Config-first and curried. Given { pkgs }, returns a
        #   Package -> Package wrapper. Applied to a package, produces a new
        #   package named "<original>-help" whose sole purpose is to print the
        #   command that *would* be executed — but never actually runs it.
        #   Useful for introspecting wrapped commands.
        #
        # Algebraic characterisation:
        #   withUnexecuted is a projection: it maps exec(p) to print(path(p)),
        #   discarding the effectful component.
        #   Equivalently, withUnexecuted factors through the "show" homomorphism
        #   from Package to String, then lifts back via print.
        # -----------------------------------------------------------------------
        withUnexecuted =
          { pkgs }:
          pkg:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
          in
          pkgs.writeShellScriptBin "${name}-help" ''
            echo "${pkg}/bin/${name}"
          '';

        # -----------------------------------------------------------------------
        # withExpansion : { pkgs } -> Package -> Package
        #
        # Plain English:
        #   Config-first and curried. Given { pkgs }, returns a
        #   Package -> Package wrapper. Applied to a package, when its
        #   executable runs it first recursively discovers every /nix/store
        #   path referenced by the wrapper scripts, printing the contents of
        #   each layer. It continues until no new /nix/store paths are found
        #   (the fixed point), then executes the original command.
        #
        #   This is an introspection tool: it lets you see exactly what
        #   chain of wrapper scripts and store paths compose a given
        #   package's executable.
        #
        # Algebraic characterisation:
        #   Let R(p) = { s ∈ /nix/store | s is referenced in the text of p }.
        #   Define the expansion sequence:
        #     S₀ = { path(p) }
        #     Sₙ₊₁ = Sₙ ∪ ⋃ { R(s) | s ∈ Sₙ }
        #   The fixed point S* = Sₙ where Sₙ₊₁ = Sₙ (guaranteed finite
        #   because /nix/store is finite and R is monotone on a finite
        #   lattice under ⊆).
        #   withExpansion(p) prints each element of S* before exec(p).
        # -----------------------------------------------------------------------
        withExpansion =
          { pkgs }:
          pkg:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
            entrypoint = "${pkg}/bin/${name}";
          in
          pkgs.writeShellScriptBin name ''
            ${expansionKernel pkgs.gnugrep}

            __expand ${pkgs.lib.escapeShellArg entrypoint}
            echo "=== executing ==="
            exec ${entrypoint} "$@"
          '';

        # -----------------------------------------------------------------------
        # withSource : { pkgs, depth?, execute? } -> Package -> Package
        #
        # Plain English:
        #   Config-first and curried: you supply a configuration attrset, and
        #   get back a Package -> Package wrapper. Applied to a package, it
        #   prints the implementation that *will* be executed — the wrapper
        #   script's source if it is text (binaries are identified but not
        #   dumped) — then executes the original command with all arguments
        #   forwarded.
        #
        #   The config-first, package-last order lets you fix a policy once and
        #   reuse it: `map (withSource { inherit pkgs; }) [ a b c ]`.
        #
        #   `depth` controls how far the printout recurses through composed
        #   /nix/store references:
        #     depth = null (default) — unfold to the fixed point (every layer
        #                              of every composed script, infinite).
        #     depth = 0              — print only the entrypoint script itself.
        #     depth = N              — print N additional layers of references.
        #   So for a stack of composed shell scripts (e.g. a writeShellApplication
        #   that calls other store scripts), the whole composed program is shown.
        #
        #   `execute` toggles the effect:
        #     execute = true  (default) — print, then exec the real command.
        #     execute = false           — print only; show the would-be-executed
        #                                 program without running it (dry run).
        #
        # Algebraic characterisation:
        #   withSource generalises both withExpansion and withUnexecuted. Reusing
        #   the expansion sequence Sₙ from withExpansion, withSource prints the
        #   truncation S_min(depth, *) (the fixed point when depth = null), then:
        #     execute = true  => exec(p)         (print ; exec)
        #     execute = false => skip(p)         (print ; ∅)
        #   Currying config before the package mirrors withHelps' partial-
        #   application order, so a configured wrapper is itself a reusable
        #   endofunctor on Package.
        # -----------------------------------------------------------------------
        withSource =
          {
            pkgs,
            depth ? null,
            execute ? true,
          }:
          pkg:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
            entrypoint = "${pkg}/bin/${name}";
            depthArg = if depth == null then "" else toString depth;
            tail =
              if execute then
                ''
                  echo "=== executing ==="
                  exec ${entrypoint} "$@"
                ''
              else
                ''
                  echo "=== print-only; not executing ==="
                '';
          in
          pkgs.writeShellScriptBin name ''
            ${expansionKernel pkgs.gnugrep}

            __expand ${pkgs.lib.escapeShellArg entrypoint} ${pkgs.lib.escapeShellArg depthArg}
            ${tail}
          '';

        # -----------------------------------------------------------------------
        # withTime : { pkgs } -> Package -> Package
        #
        # Plain English:
        #   Config-first and curried. Given { pkgs }, returns a
        #   Package -> Package wrapper. Applied to a package, it prints the
        #   wall-clock start time before execution, the stop time after, and
        #   the elapsed duration. Useful for quick benchmarking of wrapped
        #   commands.
        #
        # Algebraic characterisation:
        #   Let exec(p) denote the side-effect of running package p with exit
        #   code c.
        #   withTime(p) produces p' where:
        #     exec(p') = print(t₀) ; (c, t₁) <- timed(exec(p)) ; print(t₁, t₁ - t₀) ; exit(c)
        #   withTime is an endofunctor that wraps exec in a timing monad,
        #   preserving the original exit code (the return value is the
        #   identity on the exit-code component).
        # -----------------------------------------------------------------------
        withTime =
          { pkgs }:
          pkg:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
          in
          pkgs.writeShellScriptBin name ''
            __t_start=$(date +%s%N)
            echo "[withTime] start: $(date -d @"$(( __t_start / 1000000000 ))" '+%Y-%m-%d %H:%M:%S')"

            ${pkg}/bin/${name} "$@"
            __exit_code=$?

            __t_end=$(date +%s%N)
            __elapsed_ns=$(( __t_end - __t_start ))
            __elapsed_s=$(( __elapsed_ns / 1000000000 ))
            __elapsed_ms=$(( (__elapsed_ns % 1000000000) / 1000000 ))

            echo "[withTime] stop:  $(date -d @"$(( __t_end / 1000000000 ))" '+%Y-%m-%d %H:%M:%S')"
            printf "[withTime] duration: %d.%03ds\n" "$__elapsed_s" "$__elapsed_ms"
            exit $__exit_code
          '';

        # -----------------------------------------------------------------------
        # withHelps : String -> Package -> Package
        #
        # Plain English:
        #   Attaches a documentation string to a package as metadata (via the
        #   __doc attribute) without altering its build or execution behavior.
        #   The doc-first argument order enables partial application:
        #     map (withHelps "same description") [ pkg1 pkg2 ]
        #
        # Algebraic characterization:
        #   withHelps is a product injection: it embeds a package p into the
        #   product Package × String by attaching a label, without modifying
        #   the underlying morphism (exec is unchanged).
        #   withHelps(s)(p) = p ⊗ s, where ⊗ denotes the product pairing.
        # -----------------------------------------------------------------------
        withHelps = doc: pkg: pkg // { __doc = doc; };

        # -----------------------------------------------------------------------
        # mkHelpPkg : { pkgs, name, derivations } -> Package
        #
        # Plain English:
        #   Folds a list of packages (typically annotated with withHelps) into a
        #   single help-menu derivation. Each package's name and __doc string
        #   are extracted and formatted into a columnar listing. The resulting
        #   package is a shell script that prints this help text.
        #
        # Algebraic characterisation:
        #   mkHelpPkg is a catamorphism (fold) on List(Package):
        #     mkHelpPkg(name, [p₁, …, pₙ]) = writeScript(name, fold(format, pᵢ))
        #   where format projects each pᵢ to its (name, __doc) pair and
        #   fold concatenates the formatted lines into a single string.
        # -----------------------------------------------------------------------
        mkHelpPkg =
          {
            pkgs,
            name,
            derivations,
          }:
          let
            mkEntry =
              drv:
              let
                drvName = drv.meta.mainProgram or (builtins.parseDrvName drv.name).name;
                doc = drv.__doc or "";
                padWidth = 18;
                padLen =
                  let
                    len = builtins.stringLength drvName;
                  in
                  if padWidth > len then padWidth - len else 1;
                padding = builtins.concatStringsSep "" (builtins.genList (_: " ") padLen);
              in
              "  ${drvName}${padding}${doc}";
            helpText = builtins.concatStringsSep "\n" (map mkEntry derivations);
          in
          pkgs.writeShellScriptBin name ''
                        cat <<'HELP'
            Unified dev CLI commands:

            ${helpText}
              ${name}              Show this help
            HELP
          '';

        # -----------------------------------------------------------------------
        # withEnv : { pkgs, filter?, descriptions? } -> Package -> Package
        #
        # Plain English:
        #   Config-first and curried. Given { pkgs, filter?, descriptions? },
        #   returns a Package -> Package wrapper. Applied to a package, when its
        #   executable runs it first prints all environment variables (one per
        #   line, sorted), then executes the original command. An optional
        #   filter predicate controls which variables are shown. An optional
        #   descriptions attrset provides inline help: for each key whose `var`
        #   matches a printed variable, a comment with `desc` is printed on the
        #   line above.
        #
        #   descriptions format: { <key> = { var = "VAR_NAME"; desc = "..."; }; ... }
        #
        # Algebraic characterisation:
        #   Let E denote the environment as a finite map String -> String.
        #   Let f : String -> Bool be the filter predicate (default: const true).
        #   Let D be the partial description map.
        #   withEnv(p, f, D) produces p' where:
        #     exec(p') = print(annotate(D, filter(f, E))) ; exec(p)
        #   withEnv is a natural transformation that observes (but does not
        #   modify) the environment, prepending an IO action.
        # -----------------------------------------------------------------------
        withEnv =
          {
            pkgs,
            filter ? null,
            descriptions ? { },
          }:
          pkg:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;

            # Build an associative-array initialiser mapping VAR_NAME -> description
            # from the descriptions attrset so the shell script can look up matches.
            descEntries = builtins.attrValues (
              builtins.mapAttrs (
                _: v: "  [${pkgs.lib.escapeShellArg v.var}]=${pkgs.lib.escapeShellArg v.desc}"
              ) descriptions
            );
            descInit = builtins.concatStringsSep "\n" descEntries;

            # If a filter is provided, it is a Nix function String -> Bool.
            # We materialise the set of allowed variable names at build time
            # so the shell script only needs a hash-set lookup.
            allowSet =
              if filter == null then
                null
              else
                let
                  descVarNames = map (v: v.var) (builtins.attrValues descriptions);
                  candidates = descVarNames;
                  allowed = builtins.filter filter candidates;
                in
                allowed;

            filterSnippet =
              if filter == null then
                ''
                  # no filter — print every variable
                  env | sort | while IFS='=' read -r __var __val; do
                    if [[ -n "''${__descs[$__var]+x}" ]]; then
                      echo "# ''${__descs[$__var]}"
                    fi
                    echo "$__var=$__val"
                  done
                ''
              else
                let
                  entries = map (v: "  [${pkgs.lib.escapeShellArg v}]=1") allowSet;
                  init = builtins.concatStringsSep "\n" entries;
                in
                ''
                  # filter to allowed variables
                  declare -A __allow=(
                  ${init}
                  )
                  env | sort | while IFS='=' read -r __var __val; do
                    [[ -z "''${__allow[$__var]+x}" ]] && continue
                    if [[ -n "''${__descs[$__var]+x}" ]]; then
                      echo "# ''${__descs[$__var]}"
                    fi
                    echo "$__var=$__val"
                  done
                '';
          in
          pkgs.writeShellScriptBin name ''
            declare -A __descs=(
            ${descInit}
            )
            ${filterSnippet}
            exec ${pkg}/bin/${name} "$@"
          '';
      };

      # ---------------------------------------------------------------------------
      # packages: smoke-test examples for each combinator + nix-expand tool
      # ---------------------------------------------------------------------------
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.lib)
            withHelp
            withHelps
            mkHelpPkg
            withUnexecuted
            withExpansion
            withSource
            withTime
            withEnv
            ;
        in
        {
          # -------------------------------------------------------------------
          # nix-expand : FilePath -> IO ()
          #
          # Plain English:
          #   A standalone executable that takes any path to a binary or script
          #   as its argument and performs the same fixed-point store-reference
          #   expansion as withExpansion. If the target is not in /nix/store it
          #   still works: text files are printed, binaries are identified as
          #   such. Useful for ad-hoc introspection without wrapping a package.
          #
          # Algebraic characterisation:
          #   nix-expand lifts the expansion kernel out of the Package
          #   endofunctor and into a free-standing IO action:
          #     nix-expand = __expand ∘ resolve
          #   where resolve : String -> FilePath finds the executable via
          #   PATH or absolute path.
          # -------------------------------------------------------------------
          nix-expand = pkgs.writeShellScriptBin "nix-expand" ''
            set -euo pipefail

            if [[ $# -lt 1 ]]; then
              echo "Usage: nix-expand <executable-or-path>" >&2
              exit 1
            fi

            target="$1"

            # resolve : String -> FilePath
            # If not an absolute path, look it up in PATH.
            if [[ "$target" != /* ]]; then
              resolved=$(command -v "$target" 2>/dev/null || true)
              if [[ -z "$resolved" ]]; then
                echo "nix-expand: '$target' not found in PATH" >&2
                exit 1
              fi
              target="$resolved"
            fi

            # Follow symlinks to the real store path
            target=$(readlink -f "$target")

            ${expansionKernel pkgs.gnugrep}

            __expand "$target"
          '';

          # withHelp example: hello with a doc banner
          hello-with-doc = withHelp {
            inherit pkgs;
            doc = "GNU Hello — prints a greeting message.";
          } pkgs.hello;

          # withUnexecuted example: show hello's real path
          hello-help = withUnexecuted { inherit pkgs; } pkgs.hello;

          # withExpansion example: inspect store layers of hello
          hello-with-expansion = withExpansion { inherit pkgs; } pkgs.hello;

          # withSource example: print hello's full composed source, then run it
          hello-with-source = withSource { inherit pkgs; } pkgs.hello;

          # withSource example: print only the entrypoint script, then run it
          hello-with-source-shallow = withSource {
            inherit pkgs;
            depth = 0;
          } pkgs.hello;

          # withSource example: dry run — show the would-be-executed program,
          # but do not execute it
          hello-with-source-dryrun = withSource {
            inherit pkgs;
            execute = false;
          } pkgs.hello;

          # withTime example: time hello's execution
          hello-with-time = withTime { inherit pkgs; } pkgs.hello;

          # withEnv example: print all env vars before hello
          hello-with-env = withEnv { inherit pkgs; } pkgs.hello;

          # withEnv example with filter and descriptions
          hello-with-env-filtered = withEnv {
            inherit pkgs;
            filter =
              name:
              builtins.elem name [
                "HOME"
                "USER"
                "PATH"
                "SHELL"
                "TERM"
              ];
            descriptions = {
              home = {
                var = "HOME";
                desc = "User's home directory";
              };
              user = {
                var = "USER";
                desc = "Current logged-in username";
              };
              path = {
                var = "PATH";
                desc = "Executable search path";
              };
              shell = {
                var = "SHELL";
                desc = "User's default shell";
              };
              term = {
                var = "TERM";
                desc = "Terminal type identifier";
              };
            };
          } pkgs.hello;

          # Composition example: withHelp on top of withExpansion
          hello-composed = withHelp {
            inherit pkgs;
            doc = "Composed: expansion + doc on GNU Hello.";
          } (withExpansion { inherit pkgs; } pkgs.hello);

          # withHelps + mkHelpPkg example: auto-generated help from documented derivations
          demo-help =
            let
              documented = [
                (withHelps "Prints a greeting" pkgs.hello)
                (withHelps "Stream editor" pkgs.gnused)
              ];
            in
            mkHelpPkg {
              inherit pkgs;
              name = "demo-help";
              derivations = documented;
            };
        }
      );

      # ---------------------------------------------------------------------------
      # apps: expose nix-expand as `nix run .#nix-expand`
      # ---------------------------------------------------------------------------
      apps = forAllSystems (system: {
        nix-expand = {
          type = "app";
          program = "${self.packages.${system}.nix-expand}/bin/nix-expand";
        };
      });
    };
}

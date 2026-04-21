{
  description = ''
      Higher-order package combinators (with* family).

      Each combinator is a function Package -> ... -> Package, forming an
      endofunctor on the category of Nix packages. Because the domain and
      codomain are the same type, combinators compose freely:

        withDoc (withHelp pkg) "some docs"

      Algebraically:
        withDoc       : Package × String -> Package   -- augment execution with documentation
        withDocs      : String -> Package -> Package   -- attach doc metadata (doc-first, curried)
        mkHelpPkg     : String × [Package] -> Package  -- fold documented packages into a help command
        withHelp      : Package -> Package             -- project the documentation, discard execution
        withExpansion : Package -> Package             -- unfold /nix/store references to a fixed point
        withTime      : Package -> Package             -- measure execution duration
        withEnv       : Package × (String -> Bool)? × Descriptions? -> Package  -- print environment variables

      Standalone tools:
        nix-expand    : FilePath -> IO ()              -- withExpansion as a standalone app over arbitrary executables

       Key functional patterns at play

    ┌──────────────────────┬────────────────┬───────────────────────────────────────────────────────────────┐
    │       Pattern        │     Where      │                         What it does                          │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Decorator (//)       │ withDocs       │ Augments a derivation with metadata without altering its      │
    │                      │                │ build                                                         │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Functor map          │ documented     │ Lifts withDocs uniformly over the closure                     │
    │ (mapAttrs)           │                │                                                               │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Catamorphism (fold)  │ mkHelpCli      │ Collapses [Package] into a single help Package                │
    ├──────────────────────┼────────────────┼───────────────────────────────────────────────────────────────┤
    │ Partial application  │ withDocs       │ Doc-first arg order lets you curry: map (withDocs "same doc") │
    │                      │ "desc"         │  [a b c]                                                      │
    └──────────────────────┴────────────────┴───────────────────────────────────────────────────────────────┘

    The __doc convention keeps the doc co-located with the derivation through composition — if you later do
    withTime (withDocs "desc" pkg), the __doc survives because withTime returns a new derivation via
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

        __expand() {
          local entrypoint="$1"
          local -A seen=()
          local -a frontier=( "$entrypoint" )
          local depth=0

          while [[ ''${#frontier[@]} -gt 0 ]]; do
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
        # withDoc : Package × String -> Package
        #
        # Plain English:
        #   Wraps a package so that every time its executable runs, the given
        #   documentation string is printed to stdout first, then the original
        #   command executes normally with all arguments forwarded.
        #
        # Algebraic characterisation:
        #   Let exec(p) denote the side-effect of running package p.
        #   withDoc(p, s) produces p' where exec(p') = print(s) ; exec(p).
        #   withDoc is a natural transformation that prepends an IO action
        #   while preserving the rest of the program's behaviour.
        # -----------------------------------------------------------------------
        withDoc =
          {
            pkgs,
            pkg,
            doc,
          }:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
          in
          pkgs.writeShellScriptBin name ''
            echo ${pkgs.lib.escapeShellArg doc}
            exec ${pkg}/bin/${name} "$@"
          '';

        # -----------------------------------------------------------------------
        # withHelp : Package -> Package
        #
        # Plain English:
        #   Produces a new package named "<original>-help" whose sole purpose
        #   is to print the command that *would* be executed — but never
        #   actually runs it. Useful for introspecting wrapped commands.
        #
        # Algebraic characterisation:
        #   withHelp is a projection: it maps exec(p) to print(path(p)),
        #   discarding the effectful component.
        #   Equivalently, withHelp factors through the "show" homomorphism
        #   from Package to String, then lifts back via print.
        # -----------------------------------------------------------------------
        withHelp =
          { pkgs, pkg }:
          let
            name = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
          in
          pkgs.writeShellScriptBin "${name}-help" ''
            echo "${pkg}/bin/${name}"
          '';

        # -----------------------------------------------------------------------
        # withExpansion : Package -> Package
        #
        # Plain English:
        #   Wraps a package so that when its executable runs, it first
        #   recursively discovers every /nix/store path referenced by the
        #   wrapper scripts, printing the contents of each layer. It
        #   continues until no new /nix/store paths are found (the fixed
        #   point), then executes the original command.
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
          { pkgs, pkg }:
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
        # withTime : Package -> Package
        #
        # Plain English:
        #   Wraps a package so that it prints the wall-clock start time before
        #   execution, the stop time after, and the elapsed duration. Useful
        #   for quick benchmarking of wrapped commands.
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
          { pkgs, pkg }:
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
        # withEnv : Package × (String -> Bool)? × Descriptions? -> Package
        #
        # Plain English:
        #   Wraps a package so that when its executable runs, it first prints
        #   all environment variables (one per line, sorted), then executes
        #   the original command. An optional filter predicate controls which
        #   variables are shown. An optional descriptions attrset provides
        #   inline help: for each key whose `var` matches a printed variable,
        #   a comment with `desc` is printed on the line above.
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
        # -----------------------------------------------------------------------
        # withDocs : String -> Package -> Package
        #
        # Plain English:
        #   Attaches a documentation string to a package as metadata (via the
        #   __doc attribute) without altering its build or execution behaviour.
        #   The doc-first argument order enables partial application:
        #     map (withDocs "same description") [ pkg1 pkg2 ]
        #
        # Algebraic characterisation:
        #   withDocs is a product injection: it embeds a package p into the
        #   product Package × String by attaching a label, without modifying
        #   the underlying morphism (exec is unchanged).
        #   withDocs(s)(p) = p ⊗ s, where ⊗ denotes the product pairing.
        # -----------------------------------------------------------------------
        withDocs = doc: pkg: pkg // { __doc = doc; };

        # -----------------------------------------------------------------------
        # mkHelpPkg : { pkgs, name, derivations } -> Package
        #
        # Plain English:
        #   Folds a list of packages (typically annotated with withDocs) into a
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

        withEnv =
          {
            pkgs,
            pkg,
            filter ? null,
            descriptions ? { },
          }:
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
            withDoc
            withDocs
            mkHelpPkg
            withHelp
            withExpansion
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

          # withDoc example: hello with a doc banner
          hello-with-doc = withDoc {
            inherit pkgs;
            pkg = pkgs.hello;
            doc = "GNU Hello — prints a greeting message.";
          };

          # withHelp example: show hello's real path
          hello-help = withHelp {
            inherit pkgs;
            pkg = pkgs.hello;
          };

          # withExpansion example: inspect store layers of hello
          hello-with-expansion = withExpansion {
            inherit pkgs;
            pkg = pkgs.hello;
          };

          # withTime example: time hello's execution
          hello-with-time = withTime {
            inherit pkgs;
            pkg = pkgs.hello;
          };

          # withEnv example: print all env vars before hello
          hello-with-env = withEnv {
            inherit pkgs;
            pkg = pkgs.hello;
          };

          # withEnv example with filter and descriptions
          hello-with-env-filtered = withEnv {
            inherit pkgs;
            pkg = pkgs.hello;
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
          };

          # Composition example: withDoc on top of withExpansion
          hello-composed = withDoc {
            inherit pkgs;
            pkg = withExpansion {
              inherit pkgs;
              pkg = pkgs.hello;
            };
            doc = "Composed: expansion + doc on GNU Hello.";
          };

          # withDocs + mkHelpPkg example: auto-generated help from documented derivations
          demo-help =
            let
              documented = [
                (withDocs "Prints a greeting" pkgs.hello)
                (withDocs "Stream editor" pkgs.gnused)
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

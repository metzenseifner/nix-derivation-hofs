{
  description = ''
    Higher-order package combinators (with* family).

    Each combinator is a function Package -> ... -> Package, forming an
    endofunctor on the category of Nix packages. Because the domain and
    codomain are the same type, combinators compose freely:

      withDoc (withHelp pkg) "some docs"

    Algebraically:
      withDoc       : Package × String -> Package   -- augment execution with documentation
      withHelp      : Package -> Package             -- project the documentation, discard execution
      withExpansion : Package -> Package             -- unfold /nix/store references to a fixed point
      withTime      : Package -> Package             -- measure execution duration

    Standalone tools:
      nix-expand    : FilePath -> IO ()              -- withExpansion as a standalone app over arbitrary executables
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
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
        withDoc = { pkgs, pkg, doc }:
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
        withHelp = { pkgs, pkg }:
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
        withExpansion = { pkgs, pkg }:
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
        withTime = { pkgs, pkg }:
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
      };

      # ---------------------------------------------------------------------------
      # packages: smoke-test examples for each combinator + nix-expand tool
      # ---------------------------------------------------------------------------
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.lib) withDoc withHelp withExpansion withTime;
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

          # Composition example: withDoc on top of withExpansion
          hello-composed = withDoc {
            inherit pkgs;
            pkg = withExpansion { inherit pkgs; pkg = pkgs.hello; };
            doc = "Composed: expansion + doc on GNU Hello.";
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

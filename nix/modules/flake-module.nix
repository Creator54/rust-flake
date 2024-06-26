inputs:
{ self, lib, flake-parts-lib, ... }:

let
  inherit (flake-parts-lib)
    mkPerSystemOption;
in
{
  options = {
    perSystem = mkPerSystemOption
      ({ config, self', pkgs, system, ... }: {
        imports = [
          {
            options.rust-project.crane.args = lib.mkOption {
              default = { };
              type = lib.types.submodule {
                freeformType = lib.types.attrsOf lib.types.raw;
              };
              description = ''
                Aguments to pass to crane's `buildPackage` and `buildDepOnly`
              '';
            };
          }
        ];
        options = {
          # TODO: Multiple projects
          rust-project.crates = lib.mkOption {
            type = lib.types.attrsOf lib.types.attrs;
            default = { };
            description = "Configuration for multiple crates in the Rust project";
          };
          rust-project.crane.args.buildInputs = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "(Runtime) buildInputs for the cargo package";
          };
          rust-project.crane.args.nativeBuildInputs = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = with pkgs; [
              pkg-config
              makeWrapper
            ];
            description = "nativeBuildInputs for the cargo package";
          };
          rust-project.crane.lib = lib.mkOption {
            type = lib.types.lazyAttrsOf lib.types.raw;
            default = (inputs.crane.mkLib pkgs).overrideToolchain config.rust-project.toolchain;
          };

          rust-project.toolchain = lib.mkOption {
            type = lib.types.package;
            description = "Rust toolchain to use for the rust-project package";
            default = (pkgs.rust-bin.fromRustupToolchainFile (self + /rust-toolchain.toml)).override {
              extensions = [
                "rust-src"
                "rust-analyzer"
                "clippy"
              ];
            };
          };

          rust-project.src = lib.mkOption {
            type = lib.types.path;
            description = "Source directory for the rust-project package";
            default = lib.cleanSourceWith {
              src = self; # The original, unfiltered source
              filter = path: type:
                # Default filter from crane (allow .rs files)
                (config.rust-project.crane.lib.filterCargoSources path type)
              ;
            };
          };

          rust-project.cargoToml = lib.mkOption {
            type = lib.types.attrsOf lib.types.raw;
            description = ''
              Cargo.toml parsed in Nix
            '';
            default = builtins.fromTOML (builtins.readFile (self + /Cargo.toml));
          };
        };
        config =
          let
            inherit (cargoToml.package) name version;
            inherit (config.rust-project) toolchain crane src cargoToml crates;

            # Crane builder
            mkCraneBuild = rec {
              args = crane.args // {
                inherit src;
                pname = name;
                version = version;
                # glib-sys fails to build on linux without this
                # cf. https://github.com/ipetkov/crane/issues/411#issuecomment-1747533532
                strictDeps = true;
              };
              cargoArtifacts = crane.lib.buildDepsOnly args;
              buildArgs = args // {
                inherit cargoArtifacts;
              };
              package = crane.lib.buildPackage buildArgs;

              check = crane.lib.cargoClippy (args // {
                inherit cargoArtifacts;
                cargoClippyExtraArgs = "--all-targets --all-features -- --deny warnings";
              });

              doc = crane.lib.cargoDoc (args // {
                inherit cargoArtifacts;
              });
            };

            rustDevShell = pkgs.mkShell {
              shellHook = ''
                # For rust-analyzer 'hover' tooltips to work.
                export RUST_SRC_PATH="${toolchain}/lib/rustlib/src/rust/library";
              '';
              buildInputs = [
                pkgs.libiconv
              ] ++ config.rust-project.crane.args.buildInputs;
              packages = [
                toolchain
              ] ++ config.rust-project.crane.args.nativeBuildInputs;
            };

            # Generate crane builds for all crates
            crateConfigs = lib.mapAttrs' (name: crateConfig: mkCraneBuild name crateConfig) crates;
          in
          {
            # See nix/modules/nixpkgs.nix (the user must import it)
            nixpkgs.overlays = [
              inputs.rust-overlay.overlays.default
            ];

            # Rust package
            packages = lib.mapAttrs'
              (name: crate: {
                inherit (crate) package;
              })
              crateConfigs;

            docs = lib.mapAttrs'
              (name: crate: {
                inherit (crate) doc;
              })
              (lib.filterAttrs (name: crate: crate.doc != null) crateConfigs);

            checks = lib.mapAttrs'
              (name: crate: {
                inherit (crate) check;
              })
              crateConfigs;

            devShells = lib.mapAttrs'
              (name: crate: {
                inherit (crate) rustDevShell;
              })
              crateConfigs;
          };
      });
  };
}

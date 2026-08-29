{
  description = "pg_decompound: dictionary-based compound-word splitting for PostgreSQL full-text search";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # One major at a time: the module only loads into the major it was built
      # against. Use `nix develop .#pg17` for another.
      majors = {
        pg16 = p: p.postgresql_16;
        pg17 = p: p.postgresql_17;
      };

      mkShell =
        pkgs: pg:
        pkgs.mkShell {
          packages = [
            pg
            pg.dev
            pg.pg_config
            pkgs.gnumake
          ];
          shellHook = ''
            echo "pg_decompound dev shell: $(pg_config --version)"
            echo "  make            build the extension"
            echo "  make installcheck   run the regression tests"
            echo "  ./test/run.sh   build, install into a scratch cluster, test"
          '';
        };

      mkPackage =
        pkgs: pg:
        pkgs.stdenv.mkDerivation {
          pname = "pg_decompound";
          version = "1.0";
          src = ./.;
          nativeBuildInputs = [
            pg.pg_config
            pkgs.gnumake
          ];
          buildInputs = [ pg ];
          makeFlags = [ "USE_PGXS=1" ];
          meta = {
            description = "Compound-word splitting for PostgreSQL full-text search";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.unix;
          };
          installPhase = ''
            runHook preInstall
            install -Dm755 pg_decompound${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} \
              -t $out/lib
            install -Dm644 pg_decompound.control -t $out/share/postgresql/extension
            install -Dm644 sql/pg_decompound--*.sql -t $out/share/postgresql/extension
            runHook postInstall
          '';
        };
    in
    {
      devShells = forAllSystems (
        pkgs:
        (nixpkgs.lib.mapAttrs (_: pg: mkShell pkgs (pg pkgs)) majors)
        // {
          default = mkShell pkgs pkgs.postgresql_16;
        }
      );

      packages = forAllSystems (
        pkgs:
        (nixpkgs.lib.mapAttrs (_: pg: mkPackage pkgs (pg pkgs)) majors)
        // {
          default = mkPackage pkgs pkgs.postgresql_16;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}

{
  description = "Secure, reproducible containers for AI coding CLIs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in {
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              bash
              bats
              git
              jq
              shellcheck
              shfmt
            ];
          };
        });

      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "secli";
            version = pkgs.lib.removePrefix "v"
              (pkgs.lib.removeSuffix "\n" (builtins.readFile ./VERSION));
            src = self;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              install -D -m 755 secli.sh "$out/libexec/secli/secli.sh"
              install -D -m 644 VERSION "$out/libexec/secli/VERSION"
              install -D -m 644 AGENTS.md "$out/share/doc/secli/AGENTS.md"
              install -D -m 644 README.md "$out/share/doc/secli/README.md"
              mkdir -p "$out/libexec/secli/manifest" \
                "$out/libexec/secli/templates"
              makeWrapper ${pkgs.bash}/bin/bash "$out/bin/secli" \
                --add-flags "$out/libexec/secli/secli.sh" \
                --prefix PATH : ${nixpkgs.lib.makeBinPath [ pkgs.coreutils pkgs.findutils ]}
              runHook postInstall
            '';
            meta = {
              description = "Secure Enhanced CLI host launcher";
              homepage = "https://github.com/hinnyuu/secli";
              license = nixpkgs.lib.licenses.agpl3Only;
              mainProgram = "secli";
              platforms = systems;
            };
          };
        });

      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          package = self.packages.${system}.default;
        in {
          shellcheck = pkgs.runCommand "secli-shellcheck" {
            nativeBuildInputs = [ pkgs.shellcheck ];
          } ''
            shellcheck ${./secli.sh} ${./tests/helpers/podman}
            touch "$out"
          '';

          format = pkgs.runCommand "secli-format" {
            nativeBuildInputs = [ pkgs.shfmt ];
          } ''
            shfmt -d -i 2 -ci ${./secli.sh} ${./tests/helpers/podman}
            touch "$out"
          '';

          bats = pkgs.runCommand "secli-bats" {
            nativeBuildInputs = [ pkgs.bash pkgs.bats pkgs.coreutils pkgs.findutils ];
            PATH = pkgs.lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.findutils ];
            SECLI_FIXTURE_ROOT = ./tests/fixtures/deployment;
            SECLI_SCRIPT = ./secli.sh;
            SECLI_VERSION = ./VERSION;
            SECLI_PODMAN = ./tests/helpers/podman;
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            bats ${./tests/secli.bats}
            touch "$out"
          '';

          package-smoke = pkgs.runCommand "secli-package-smoke" { } ''
            ${package}/bin/secli --help >output
            grep -F "Secure Enhanced CLI" output
            touch "$out"
          '';
        });
    };
}

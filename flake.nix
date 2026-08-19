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
              bc
              git
              jq
              actionlint
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
              install -D -m 755 entrypoint.sh "$out/libexec/secli/entrypoint.sh"
              install -D -m 644 VERSION "$out/libexec/secli/VERSION"
              install -D -m 644 AGENTS.md "$out/share/doc/secli/AGENTS.md"
              install -D -m 644 README.md "$out/share/doc/secli/README.md"
              mkdir -p "$out/libexec/secli/manifest" \
                "$out/libexec/secli/templates" \
                "$out/share/doc/secli/clis"
              cp -R manifest/. "$out/libexec/secli/manifest/"
              cp -R templates/. "$out/libexec/secli/templates/"
              cp -R docs/clis/. "$out/share/doc/secli/clis/"
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
            shellcheck ${./secli.sh} ${./entrypoint.sh} ${./tests/helpers/podman} ${./tests/helpers/nix}
            touch "$out"
          '';

          format = pkgs.runCommand "secli-format" {
            nativeBuildInputs = [ pkgs.shfmt ];
          } ''
            shfmt -d -i 2 -ci ${./secli.sh} ${./entrypoint.sh} ${./tests/helpers/podman} ${./tests/helpers/nix}
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

          entrypoint-bats = pkgs.runCommand "secli-entrypoint-bats" {
            nativeBuildInputs = [ pkgs.bash pkgs.bats pkgs.coreutils pkgs.findutils ];
            PATH = pkgs.lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.findutils ];
            SECLI_ENTRYPOINT = ./entrypoint.sh;
            SECLI_ENTRYPOINT_MANIFEST = ./tests/fixtures/entrypoint/manifest/opencode.conf;
            SECLI_NIX_MOCK = ./tests/helpers/nix;
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            bats ${./tests/entrypoint.bats}
            touch "$out"
          '';

          manifest-layout = pkgs.runCommand "secli-manifest-layout" {
            nativeBuildInputs = [ pkgs.bash pkgs.jq ];
          } ''
            shared_ref=
            for cli in opencode qoder-cli-cn; do
              manifest=${./manifest}/$cli.conf
              test -f "$manifest"
              CLI_ID= BIN= INSTALL_REF= RUNTIME_ENV=()
              source "$manifest"
              test "$CLI_ID" = "$cli"
              test -n "$BIN"
              [[ "$INSTALL_REF" =~ ^github:numtide/llm-agents\.nix/[0-9a-f]{40}#$cli$ ]]
              [[ $(declare -p RUNTIME_ENV) == "declare -a "* ]]
              current_ref=''${INSTALL_REF%#*}
              if [[ -z $shared_ref ]]; then
                shared_ref=$current_ref
              else
                test "$shared_ref" = "$current_ref"
              fi
              test -d ${./templates}/$cli
            done
            jq -e '.autoupdate == false and .share == "disabled"' \
              ${./templates}/opencode/.config/opencode/opencode.jsonc >/dev/null
            jq -e '.general.enableAutoUpdate == false and .security.disableYoloMode == true' \
              ${./templates}/qoder-cli-cn/.qoder-cn/settings.json >/dev/null
            touch "$out"
          '';

          containerfile-static = pkgs.runCommand "secli-containerfile-static" { } ''
            grep -F 'FROM nixos/nix:2.35.1@sha256:377d4887aca98f0dfa12971c1ea6d6a625a435d8b610d4c95a436843da6fbfd1' ${./Containerfile}
            grep -F 'nix profile add --profile /nix/var/nix/profiles/secli-base' ${./Containerfile}
            grep -F 'github:NixOS/nixpkgs/ec2d622de0773551768cf98f3fc50cbcc003b9c5#git' ${./Containerfile}
            grep -F 'github:NixOS/nixpkgs/ec2d622de0773551768cf98f3fc50cbcc003b9c5#ripgrep' ${./Containerfile}
            ! grep -F 'nixpkgs#' ${./Containerfile}
            grep -F 'if [ -L /usr/share ]; then rm /usr/share; fi' ${./Containerfile}
            grep -F 'mkdir -p /usr/share/nvidia /usr/lib64 /usr/lib/nvidia /usr/local/nvidia' ${./Containerfile}
            grep -F 'COPY entrypoint.sh /entrypoint.sh' ${./Containerfile}
            grep -F 'PATH=/nix/var/nix/profiles/secli-base/bin:/nix/var/nix/profiles/default/bin' ${./Containerfile}
            grep -F 'ENTRYPOINT ["/entrypoint.sh"]' ${./Containerfile}
            ! grep -E 'COPY (manifest|templates|state|LICENSE)' ${./Containerfile}
            touch "$out"
          '';

          workflow-static = pkgs.runCommand "secli-workflow-static" {
            nativeBuildInputs = [ pkgs.actionlint ];
          } ''
            actionlint ${./.github/workflows/ci.yml} ${./.github/workflows/release-image.yml}
            touch "$out"
          '';

          documentation = pkgs.runCommand "secli-documentation" {
            nativeBuildInputs = [ pkgs.bash pkgs.bc pkgs.ripgrep ];
            SECLI_DOC_ROOT = self;
          } ''
            bash ${./tests/check-docs.sh}
            touch "$out"
          '';

          package-smoke = pkgs.runCommand "secli-package-smoke" { } ''
            ${package}/bin/secli --help >output
            grep -F "Secure Enhanced CLI" output
            ${package}/bin/secli list >clis
            grep -Fx opencode clis
            grep -Fx qoder-cli-cn clis
            touch "$out"
          '';
        });
    };
}

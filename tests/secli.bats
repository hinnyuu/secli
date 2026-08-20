#!/usr/bin/env bats

setup() {
  REPO_ROOT=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)
  DEPLOY="$BATS_TEST_TMPDIR/deploy"
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$DEPLOY" "$MOCK_BIN"
  fixture_root=${SECLI_FIXTURE_ROOT:-$REPO_ROOT/tests/fixtures/deployment}
  script=${SECLI_SCRIPT:-$REPO_ROOT/secli.sh}
  version=${SECLI_VERSION:-$REPO_ROOT/VERSION}
  podman_mock=${SECLI_PODMAN:-$REPO_ROOT/tests/helpers/podman}
  cp -R "$fixture_root/." "$DEPLOY"
  chmod -R u+w "$DEPLOY"
  cp "$script" "$DEPLOY/secli.sh"
  cp "$version" "$DEPLOY/VERSION"
  printf '#!%s\n' "$BASH" >"$MOCK_BIN/podman"
  tail -n +2 "$podman_mock" >>"$MOCK_BIN/podman"
  chmod +x "$MOCK_BIN/podman"
  export PATH="$MOCK_BIN:$PATH"
}

@test "global help does not require a project or Podman" {
  run bash "$DEPLOY/secli.sh" --help

  [ "$status" -eq 0 ]
  [[ $output == *"Secure Enhanced CLI"* ]]
  [[ $output == *"secli init <cli|all>"* ]]
}

@test "list reports validated manifests" {
  run bash "$DEPLOY/secli.sh" list

  [ "$status" -eq 0 ]
  [[ $output == *opencode* ]]
  [[ $output == *qoder-cli-cn* ]]
}

@test "manifest.local completely overrides the repository manifest" {
  mkdir -p "$DEPLOY/manifest.local"
  cat >"$DEPLOY/manifest.local/opencode.conf" <<'EOF'
CLI_ID=wrong
BIN=opencode
INSTALL_REF="github:numtide/llm-agents.nix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#opencode"
RUNTIME_ENV=()
EOF

  run bash "$DEPLOY/secli.sh" list

  [ "$status" -eq 1 ]
  [[ $output == *"must set CLI_ID=opencode"* ]]
}

@test "init copies dotfiles and never overwrites an existing file" {
  export SECLI_STATE_DIR="$BATS_TEST_TMPDIR/state"

  run bash "$DEPLOY/secli.sh" init opencode
  [ "$status" -eq 0 ]
  [[ $output == *"created"* ]]
  config="$SECLI_STATE_DIR/opencode/home/.config/opencode/opencode.jsonc"
  [ -f "$config" ]
  printf 'user-owned\n' >"$config"

  run bash "$DEPLOY/secli.sh" init opencode
  [ "$status" -eq 0 ]
  [[ $output == *"skipped"* ]]
  [ "$(<"$config")" = user-owned ]
}

@test "init all creates each CLI Home" {
  export SECLI_STATE_DIR="$BATS_TEST_TMPDIR/state"

  run bash "$DEPLOY/secli.sh" init all

  [ "$status" -eq 0 ]
  [ -f "$SECLI_STATE_DIR/opencode/home/.config/opencode/opencode.jsonc" ]
  [ -f "$SECLI_STATE_DIR/qoder-cli-cn/home/.qoder-cn/settings.json" ]
}

@test "manifest runtime environment must be an indexed array" {
  cat >"$DEPLOY/manifest/qoder-cli-cn.conf" <<'EOF'
CLI_ID=qoder-cli-cn
BIN=qoderclicn
INSTALL_REF="github:numtide/llm-agents.nix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#qoder-cli-cn"
RUNTIME_ENV="NOT_AN_ARRAY=value"
EOF

  run bash "$DEPLOY/secli.sh" list

  [ "$status" -eq 1 ]
  [[ $output == *"RUNTIME_ENV must be a Bash array"* ]]
}

@test "manifest runtime environment validates variable names" {
  cat >"$DEPLOY/manifest/qoder-cli-cn.conf" <<'EOF'
CLI_ID=qoder-cli-cn
BIN=qoderclicn
INSTALL_REF="github:numtide/llm-agents.nix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#qoder-cli-cn"
RUNTIME_ENV=("INVALID-NAME=value")
EOF

  run bash "$DEPLOY/secli.sh" list

  [ "$status" -eq 1 ]
  [[ $output == *"invalid environment variable name"* ]]
}

@test "run preserves paths and native CLI argument boundaries" {
  project="$BATS_TEST_TMPDIR/allowed/project with spaces"
  dataset="$BATS_TEST_TMPDIR/dataset with spaces"
  mkdir -p "$project" "$dataset"

  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    SECLI_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    bash -c 'cd "$1" && exec bash "$2" opencode --dataset "$3" -p 4096 -- -p "native prompt"' \
    _ "$project" "$DEPLOY/secli.sh" "$dataset"

  [ "$status" -eq 0 ]
  [[ $output == *"<$project:$project:rw,z>"* ]]
  [[ $output == *"<$dataset:$dataset:ro,z>"* ]]
  [[ $output == *"<127.0.0.1:4096:4096>"* ]]
  [[ $output == *"<-p>"* ]]
  [[ $output == *"<native prompt>"* ]]
}

@test "multiple datasets remain separate read-only mounts" {
  project="$BATS_TEST_TMPDIR/allowed/project"
  dataset_a="$BATS_TEST_TMPDIR/dataset a"
  dataset_b="$BATS_TEST_TMPDIR/dataset b"
  mkdir -p "$project" "$dataset_a" "$dataset_b"

  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode --dataset "$3" --dataset "$4"' \
    _ "$project" "$DEPLOY/secli.sh" "$dataset_a" "$dataset_b"

  [ "$status" -eq 0 ]
  [[ $output == *"<$dataset_a:$dataset_a:ro,z>"* ]]
  [[ $output == *"<$dataset_b:$dataset_b:ro,z>"* ]]
}

@test "explicit IPv4 port mapping is preserved" {
  project="$BATS_TEST_TMPDIR/allowed/project"
  mkdir -p "$project"

  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode -p 0.0.0.0:8080:4096' \
    _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 0 ]
  [[ $output == *"<0.0.0.0:8080:4096>"* ]]
}

@test "invalid IPv4 and out-of-range ports are rejected" {
  run bash "$DEPLOY/secli.sh" opencode -p 256.0.0.1:8080:4096
  [ "$status" -eq 1 ]
  [[ $output == *"invalid IPv4 address"* ]]

  run bash "$DEPLOY/secli.sh" opencode -p 0.0.0.0:0:4096
  [ "$status" -eq 1 ]
  [[ $output == *"invalid host port"* ]]

  run bash "$DEPLOY/secli.sh" opencode -p 0.0.0.0:8080:65536
  [ "$status" -eq 1 ]
  [[ $output == *"invalid container port"* ]]
}

@test "Qoder native short prompt option requires the separator" {
  run bash "$DEPLOY/secli.sh" qoder-cli-cn -p "native prompt"

  [ "$status" -eq 1 ]
  [[ $output == *"expected an integer from 1 to 65535"* ]]

  project="$BATS_TEST_TMPDIR/allowed/project"
  mkdir -p "$project"
  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" qoder-cli-cn -- -p "native prompt"' \
    _ "$project" "$DEPLOY/secli.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"<-p>"* ]]
  [[ $output == *"<native prompt>"* ]]
}

@test "project prefix matching respects path boundaries" {
  project="$BATS_TEST_TMPDIR/allowed-evil/project"
  mkdir -p "$project"

  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 1 ]
  [[ $output == *"outside allowed prefixes"* ]]
}

@test "invalid port suggests placing native options after the separator" {
  run bash "$DEPLOY/secli.sh" opencode -p prompt

  [ "$status" -eq 1 ]
  [[ $output == *"expected an integer from 1 to 65535"* ]]
}

@test "unknown wrapper options are rejected before Podman starts" {
  run bash "$DEPLOY/secli.sh" opencode --native-option

  [ "$status" -eq 1 ]
  [[ $output == *"place native CLI arguments after --"* ]]
}

@test "an existing fixed-name container is not removed or adopted" {
  project="$BATS_TEST_TMPDIR/allowed/project"
  mkdir -p "$project"

  run env \
    MOCK_CONTAINER_EXISTS=true \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 1 ]
  [[ $output == *"allows only one instance"* ]]
}

@test "a missing image fails without pulling" {
  project="$BATS_TEST_TMPDIR/allowed/project"
  mkdir -p "$project"

  run env \
    MOCK_IMAGE_EXISTS=false \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 1 ]
  [[ $output == *"pull it manually or set SECLI_IMAGE"* ]]
  [[ $output != *"unexpected podman invocation"* ]]
}

@test "config file overrides the default project whitelist" {
  project="$BATS_TEST_TMPDIR/custom-whitelist/project"
  mkdir -p "$project" "$DEPLOY/config"
  printf 'SECLI_ALLOWED_PROJECT_PREFIXES=%s/custom-whitelist\n' "$BATS_TEST_TMPDIR" \
    >"$DEPLOY/config/secli.conf"

  run env \
    SECLI_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 0 ]
  [[ $output == *"<$project:$project:rw,z>"* ]]
}

@test "environment variables override configuration file values" {
  project="$BATS_TEST_TMPDIR/env-allowed/project"
  config_project="$BATS_TEST_TMPDIR/config-only/project"
  mkdir -p "$project" "$config_project" "$DEPLOY/config"
  printf 'SECLI_ALLOWED_PROJECT_PREFIXES=%s/config-only\n' "$BATS_TEST_TMPDIR" \
    >"$DEPLOY/config/secli.conf"

  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/env-allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"
  [ "$status" -eq 0 ]

  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/env-allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$config_project" "$DEPLOY/secli.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"outside allowed prefixes"* ]]
  [[ $output == *"environment SECLI_ALLOWED_PROJECT_PREFIXES"* ]]
}

@test "configuration file image is passed to podman" {
  project="$BATS_TEST_TMPDIR/allowed/project"
  mkdir -p "$project" "$DEPLOY/config"
  printf 'SECLI_IMAGE=localhost/secli:configured\n' >"$DEPLOY/config/secli.conf"

  run env \
    SECLI_ALLOWED_PROJECT_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 0 ]
  [[ $output == *"<localhost/secli:configured>"* ]]
}

@test "configuration file state directory is used by init" {
  mkdir -p "$DEPLOY/config"
  printf 'SECLI_STATE_DIR=%s/config-state\n' "$BATS_TEST_TMPDIR" \
    >"$DEPLOY/config/secli.conf"

  run bash "$DEPLOY/secli.sh" init opencode

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/config-state/opencode/home/.config/opencode/opencode.jsonc" ]
}

@test "unknown configuration keys are rejected with file and line" {
  mkdir -p "$DEPLOY/config"
  printf '# comment\nSECLI_BOGUS=1\n' >"$DEPLOY/config/secli.conf"

  run bash "$DEPLOY/secli.sh" list

  [ "$status" -eq 1 ]
  [[ $output == *"line 2"* ]]
  [[ $output == *"unknown configuration key 'SECLI_BOGUS'"* ]]
  [[ $output == *"SECLI_ALLOWED_PROJECT_PREFIXES SECLI_IMAGE SECLI_STATE_DIR"* ]]
}

@test "malformed configuration lines are rejected" {
  mkdir -p "$DEPLOY/config"
  printf 'not-an-assignment\n' >"$DEPLOY/config/secli.conf"

  run bash "$DEPLOY/secli.sh" list
  [ "$status" -eq 1 ]
  [[ $output == *"expected SECLI_KEY=value"* ]]

  printf 'SECLI_IMAGE=\n' >"$DEPLOY/config/secli.conf"
  run bash "$DEPLOY/secli.sh" list
  [ "$status" -eq 1 ]
  [[ $output == *"must not be empty"* ]]
}

@test "explicit SECLI_CONFIG must exist" {
  run env SECLI_CONFIG="$BATS_TEST_TMPDIR/missing.conf" bash "$DEPLOY/secli.sh" list

  [ "$status" -eq 1 ]
  [[ $output == *"SECLI_CONFIG points to a missing file"* ]]
}

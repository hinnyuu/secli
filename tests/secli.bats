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
  cp "$podman_mock" "$MOCK_BIN/podman"
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
  [ "$output" = opencode ]
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

@test "run preserves paths and native CLI argument boundaries" {
  project="$BATS_TEST_TMPDIR/allowed/project with spaces"
  dataset="$BATS_TEST_TMPDIR/dataset with spaces"
  mkdir -p "$project" "$dataset"

  run env \
    SECLI_ALLOWED_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
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

@test "project prefix matching respects path boundaries" {
  project="$BATS_TEST_TMPDIR/allowed-evil/project"
  mkdir -p "$project"

  run env \
    SECLI_ALLOWED_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 1 ]
  [[ $output == *"outside SECLI_ALLOWED_PREFIXES"* ]]
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
    SECLI_ALLOWED_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 1 ]
  [[ $output == *"allows only one instance"* ]]
}

@test "a missing image fails without pulling" {
  project="$BATS_TEST_TMPDIR/allowed/project"
  mkdir -p "$project"

  run env \
    MOCK_IMAGE_EXISTS=false \
    SECLI_ALLOWED_PREFIXES="$BATS_TEST_TMPDIR/allowed" \
    bash -c 'cd "$1" && exec bash "$2" opencode' _ "$project" "$DEPLOY/secli.sh"

  [ "$status" -eq 1 ]
  [[ $output == *"pull it manually or set SECLI_IMAGE"* ]]
  [[ $output != *"unexpected podman invocation"* ]]
}

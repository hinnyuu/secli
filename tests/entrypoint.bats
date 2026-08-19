#!/usr/bin/env bats

setup() {
  REPO_ROOT=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)
  ROOT="$BATS_TEST_TMPDIR/root"
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  NIX_ROOT="$BATS_TEST_TMPDIR/nix"
  mkdir -p "$ROOT/manifest" "$MOCK_BIN" \
    "$NIX_ROOT/var/nix/profiles/default/bin" \
    "$NIX_ROOT/var/nix/profiles/per-user/root" \
    "$NIX_ROOT/var/lib/secli"
  cp "${SECLI_ENTRYPOINT:-$REPO_ROOT/entrypoint.sh}" "$ROOT/entrypoint.sh"
  cp "${SECLI_ENTRYPOINT_MANIFEST:-$REPO_ROOT/tests/fixtures/entrypoint/manifest/opencode.conf}" \
    "$ROOT/manifest/opencode.conf"
  nix_mock=${SECLI_NIX_MOCK:-$REPO_ROOT/tests/helpers/nix}
  printf '#!%s\n' "$BASH" >"$MOCK_BIN/nix"
  tail -n +2 "$nix_mock" >>"$MOCK_BIN/nix"
  chmod +x "$ROOT/entrypoint.sh" "$MOCK_BIN/nix"
  export PATH="$MOCK_BIN:$PATH"
  export SECLI_NIX_BIN="$MOCK_BIN/nix"
  export SECLI_MANIFEST_ROOT="$ROOT/manifest"
  export SECLI_LOCAL_MANIFEST_ROOT="$ROOT/manifest.local"
  export SECLI_PROFILE_ROOT="$NIX_ROOT/var/nix/profiles/per-user/root"
  export SECLI_STAMP_ROOT="$NIX_ROOT/var/lib/secli"
  export MOCK_NIX_LOG="$BATS_TEST_TMPDIR/nix.log"
  export SECLI_CLI=opencode
  export SECLI_TEST_RUNTIME=
}

profile() {
  printf '%s\n' "$NIX_ROOT/var/nix/profiles/per-user/root/secli-opencode"
}

stamp() {
  printf '%s\n' "$NIX_ROOT/var/lib/secli/opencode.stamp"
}

run_entrypoint() {
  run env \
    SECLI_CLI="$SECLI_CLI" \
    SECLI_NIX_BIN="$SECLI_NIX_BIN" \
    SECLI_MANIFEST_ROOT="$SECLI_MANIFEST_ROOT" \
    SECLI_LOCAL_MANIFEST_ROOT="$SECLI_LOCAL_MANIFEST_ROOT" \
    SECLI_PROFILE_ROOT="$SECLI_PROFILE_ROOT" \
    SECLI_STAMP_ROOT="$SECLI_STAMP_ROOT" \
    MOCK_NIX_LOG="$MOCK_NIX_LOG" \
    NIX_ROOT="$NIX_ROOT" \
    SECLI_TEST_RUNTIME="$SECLI_TEST_RUNTIME" \
    bash -c 'exec bash "$1" "$@"' _ "$ROOT/entrypoint.sh" "$@"
}

@test "first install creates stamp and execs the profile binary" {
  run_entrypoint -- "arg with spaces" -x

  [ "$status" -eq 0 ]
  [[ $output == *"mock-cli runtime=from-manifest"* ]]
  [[ $output == *"<arg with spaces><-x>"* ]]
  [ "$(<"$(stamp)")" = "github:numtide/llm-agents.nix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#opencode" ]
}

@test "matching stamp and executable are a noop" {
  mkdir -p "$(dirname "$(stamp)")" "$(profile)/bin"
  printf '%s\n' "github:numtide/llm-agents.nix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#opencode" >"$(stamp)"
  printf '#!%s\n' "$BASH" >"$(profile)/bin/opencode"
  cat >>"$(profile)/bin/opencode" <<'EOF'
printf 'noop-cli\n'
EOF
  chmod +x "$(profile)/bin/opencode"

  run_entrypoint

  [ "$status" -eq 0 ]
  [ "$output" = noop-cli ]
  [ ! -s "$MOCK_NIX_LOG" ]
}

@test "missing binary reconciles the profile even when stamp matches" {
  mkdir -p "$(dirname "$(stamp)")"
  printf '%s\n' "github:numtide/llm-agents.nix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#opencode" >"$(stamp)"

  run_entrypoint

  [ "$status" -eq 0 ]
  [[ $output == *"mock-cli runtime=from-manifest"* ]]
  [ "$(<"$MOCK_NIX_LOG")" = add ]
}

@test "install failure rolls back a usable previous profile and exits nonzero" {
  mkdir -p "$(dirname "$(stamp)")" "$(profile)/bin"
  printf '%s\n' "github:numtide/llm-agents.nix/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#opencode" >"$(stamp)"
  printf '#!%s\n' "$BASH" >"$(profile)/bin/opencode"
  cat >>"$(profile)/bin/opencode" <<'EOF'
printf 'old-cli\n'
EOF
  chmod +x "$(profile)/bin/opencode"

  export MOCK_NIX_ADD_FAIL=true
  run_entrypoint

  [ "$status" -eq 1 ]
  [[ $output == *"was not started"* ]]
  [ "$(<"$MOCK_NIX_LOG")" = $'add\nrollback' ]
  [[ "$(<"$(stamp)")" == *bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb* ]]
}

@test "first install failure does not start an unknown or partial CLI" {
  export MOCK_NIX_ADD_FAIL=true
  run_entrypoint

  [ "$status" -eq 1 ]
  [[ $output == *"was not started"* ]]
  [ ! -e "$(stamp)" ]
}

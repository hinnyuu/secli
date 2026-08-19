#!/usr/bin/env bash
set -euo pipefail

readonly MANIFEST_ROOT="${SECLI_MANIFEST_ROOT:-/opt/secli/manifest}"
readonly LOCAL_MANIFEST_ROOT="${SECLI_LOCAL_MANIFEST_ROOT:-/opt/secli/manifest.local}"
readonly PROFILE_ROOT="${SECLI_PROFILE_ROOT:-/nix/var/nix/profiles/per-user/root}"
readonly STAMP_ROOT="${SECLI_STAMP_ROOT:-/nix/var/lib/secli}"
readonly NIX_BIN="${SECLI_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}"

die() {
  printf 'secli entrypoint: error: %s\n' "$*" >&2
  exit 1
}

valid_cli_id() {
  [[ $1 =~ ^[a-z0-9][a-z0-9._-]*$ && $1 != init && $1 != list ]]
}

manifest_path() {
  local cli_id=$1 local_path repository_path
  local_path="$LOCAL_MANIFEST_ROOT/$cli_id.conf"
  repository_path="$MANIFEST_ROOT/$cli_id.conf"

  if [[ -f $local_path ]]; then
    printf '%s\n' "$local_path"
  elif [[ -f $repository_path ]]; then
    printf '%s\n' "$repository_path"
  else
    return 1
  fi
}

load_manifest() {
  local requested_id=$1
  local path declaration entry name

  valid_cli_id "$requested_id" || die "invalid SECLI_CLI '$requested_id'"
  path=$(manifest_path "$requested_id") ||
    die "manifest for CLI '$requested_id' was not found"

  unset CLI_ID BIN INSTALL_REF RUNTIME_ENV
  RUNTIME_ENV=()
  # Manifests are trusted Bash code by contract.
  # shellcheck disable=SC1090
  source "$path"

  [[ ${CLI_ID-} == "$requested_id" ]] ||
    die "manifest '$path' must set CLI_ID=$requested_id"
  [[ ${BIN-} =~ ^[A-Za-z0-9._+-]+$ ]] ||
    die "manifest '$path' BIN must be one command name without '/'"
  [[ ${INSTALL_REF-} =~ ^github:[^/[:space:]]+/[^/[:space:]]+/[0-9a-fA-F]{40}#[^[:space:]]+$ ]] ||
    die "manifest '$path' INSTALL_REF must use a full immutable GitHub commit"

  declaration=$(declare -p RUNTIME_ENV 2>/dev/null) ||
    die "manifest '$path' RUNTIME_ENV must be a Bash array"
  [[ $declaration == "declare -a "* ]] ||
    die "manifest '$path' RUNTIME_ENV must be a Bash array"
  for entry in "${RUNTIME_ENV[@]}"; do
    [[ $entry == *=* ]] ||
      die "manifest '$path' RUNTIME_ENV entry must use NAME=value"
    name=${entry%%=*}
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      die "manifest '$path' has invalid environment variable name '$name'"
  done
}

export_runtime_environment() {
  local entry
  for entry in "${RUNTIME_ENV[@]}"; do
    # shellcheck disable=SC2163
    export "$entry"
  done
}

profile_path() {
  printf '%s/secli-%s\n' "$PROFILE_ROOT" "$CLI_ID"
}

stamp_path() {
  printf '%s/%s.stamp\n' "$STAMP_ROOT" "$CLI_ID"
}

stamp_matches() {
  local stamp=$1
  [[ -f $stamp && $(<"$stamp") == "$INSTALL_REF" ]]
}

write_stamp() {
  local stamp=$1 temporary
  temporary="$stamp.tmp.$$"
  printf '%s\n' "$INSTALL_REF" >"$temporary"
  mv -f -- "$temporary" "$stamp"
}

run_profile_reconciliation() {
  local profile=$1 stamp=$2 binary old_binary_available=false
  binary="$profile/bin/$BIN"
  [[ -x $NIX_BIN ]] || die "Nix command is not executable: $NIX_BIN"
  mkdir -p -- "$(dirname -- "$profile")" "$STAMP_ROOT"

  if [[ -x $binary ]]; then
    old_binary_available=true
  fi
  if stamp_matches "$stamp" && [[ $old_binary_available == true ]]; then
    return 0
  fi

  printf 'secli entrypoint: reconciling profile for %s\n' "$CLI_ID" >&2
  "$NIX_BIN" profile remove --all --profile "$profile" ||
    die "failed to clear current generation of profile '$profile'"

  if "$NIX_BIN" profile add --profile "$profile" "$INSTALL_REF" && [[ -x $binary ]]; then
    write_stamp "$stamp"
    return 0
  fi

  printf 'secli entrypoint: installation failed for %s\n' "$CLI_ID" >&2
  if [[ $old_binary_available == true ]]; then
    printf 'secli entrypoint: attempting profile rollback for %s\n' "$CLI_ID" >&2
    if "$NIX_BIN" profile rollback --profile "$profile" && [[ -x $binary ]]; then
      printf 'secli entrypoint: rollback restored the previous profile\n' >&2
    else
      printf 'secli entrypoint: rollback did not restore a usable profile\n' >&2
    fi
  fi
  return 1
}

main() {
  local cli_id=${SECLI_CLI-} profile stamp

  [[ -n $cli_id ]] || die "SECLI_CLI is required"
  load_manifest "$cli_id"
  export_runtime_environment
  profile=$(profile_path)
  stamp=$(stamp_path)

  run_profile_reconciliation "$profile" "$stamp" ||
    die "CLI '$CLI_ID' was not started because profile reconciliation failed"

  [[ -x "$profile/bin/$BIN" ]] ||
    die "profile '$profile' does not contain executable '$BIN'"
  export PATH="$profile/bin:$PATH"
  exec "$profile/bin/$BIN" "$@"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly BASE_DIR
readonly DEFAULT_ALLOWED_PREFIXES="/data/projects:/data/test:/data/dataset"
readonly NIX_VOLUME="secli-nix-v1"
readonly CONTAINER_NAME="secli"

die() {
  printf 'secli: error: %s\n' "$*" >&2
  exit 1
}

print_help() {
  cat <<'EOF'
Secure Enhanced CLI

Usage:
  secli <cli> [secli options] [-- CLI arguments...]
  secli init <cli|all>
  secli list
  secli -h|--help

Options:
  --dataset <path>  Mount a dataset read-only at the same absolute path
  -p, --port <spec> Publish PORT on loopback, or HOST_IPV4:HOST_PORT:CONTAINER_PORT
  --nvidia          Enable all NVIDIA CDI devices and disable SELinux labels
  -h, --help        Show secli wrapper help

Use "secli <cli> -- --help" for the selected CLI's native help.
EOF
}

print_cli_help() {
  local cli_id=$1
  cat <<EOF
Usage: secli $cli_id [secli options] [-- CLI arguments...]

The -- separator is required before native CLI arguments.
For example: secli $cli_id -- --help
EOF
}

valid_cli_id() {
  [[ $1 =~ ^[a-z0-9][a-z0-9._-]*$ && $1 != init && $1 != list ]]
}

manifest_path() {
  local cli_id=$1
  local local_path="$BASE_DIR/manifest.local/$cli_id.conf"
  local repository_path="$BASE_DIR/manifest/$cli_id.conf"

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

  valid_cli_id "$requested_id" ||
    die "invalid CLI id '$requested_id'; expected [a-z0-9][a-z0-9._-]* and not init/list"
  path=$(manifest_path "$requested_id") ||
    die "unknown CLI '$requested_id'; run 'secli list' to show supported CLIs"

  unset CLI_ID BIN INSTALL_REF RUNTIME_ENV
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

collect_cli_ids() {
  local directory path cli_id
  local -A seen=()
  CLI_IDS=()

  shopt -s nullglob
  for directory in "$BASE_DIR/manifest.local" "$BASE_DIR/manifest"; do
    [[ -d $directory ]] || continue
    for path in "$directory"/*.conf; do
      cli_id=${path##*/}
      cli_id=${cli_id%.conf}
      [[ -v "seen[$cli_id]" ]] && continue
      load_manifest "$cli_id"
      seen[$cli_id]=1
      CLI_IDS+=("$cli_id")
    done
  done
  shopt -u nullglob
}

list_clis() {
  local cli_id
  collect_cli_ids
  for cli_id in "${CLI_IDS[@]}"; do
    printf '%s\n' "$cli_id"
  done
}

state_root() {
  local configured=${SECLI_STATE_DIR:-"$BASE_DIR/state"}
  mkdir -p -- "$configured"
  chmod 700 -- "$configured"
  realpath -e -- "$configured"
}

init_one() {
  local cli_id=$1 root home template source relative destination
  load_manifest "$cli_id"
  root=$(state_root)
  home="$root/$cli_id/home"
  template="$BASE_DIR/templates/$cli_id"

  mkdir -p -- "$home"
  chmod 700 -- "$root/$cli_id" "$home"
  [[ -d $template ]] || die "template directory is missing for CLI '$cli_id': $template"

  while IFS= read -r -d '' source; do
    relative=${source#"$template"/}
    destination="$home/$relative"
    if [[ -e $destination || -L $destination ]]; then
      printf 'skipped %s\n' "$destination"
      continue
    fi
    mkdir -p -- "$(dirname -- "$destination")"
    cp -a -- "$source" "$destination"
    printf 'created %s\n' "$destination"
  done < <(find "$template" \( -type f -o -type l \) -print0 | sort -z)
}

init_command() {
  local target=${1-} cli_id
  [[ -n $target && $# -eq 1 ]] || die "usage: secli init <cli|all>"
  if [[ $target == all ]]; then
    collect_cli_ids
    for cli_id in "${CLI_IDS[@]}"; do
      init_one "$cli_id"
    done
  else
    init_one "$target"
  fi
}

canonical_existing_path() {
  local path=$1 label=$2
  [[ -e $path ]] || die "$label does not exist: $path"
  realpath -e -- "$path"
}

validate_project_path() {
  local project=$1 configured prefix canonical_prefix
  local -a prefixes
  configured=${SECLI_ALLOWED_PREFIXES:-$DEFAULT_ALLOWED_PREFIXES}
  IFS=: read -r -a prefixes <<<"$configured"
  ((${#prefixes[@]} > 0)) || die "SECLI_ALLOWED_PREFIXES must contain an absolute path"

  for prefix in "${prefixes[@]}"; do
    [[ $prefix == /* ]] || die "allowed project prefix must be absolute: $prefix"
    canonical_prefix=$(realpath -m -- "$prefix")
    if [[ $project == "$canonical_prefix" || $project == "$canonical_prefix/"* ]]; then
      return 0
    fi
  done
  die "project '$project' is outside SECLI_ALLOWED_PREFIXES='$configured'"
}

valid_port_number() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  local value=$((10#$1))
  ((value >= 1 && value <= 65535))
}

valid_ipv4() {
  local address=$1 octet
  local -a octets
  IFS=. read -r -a octets <<<"$address"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]+$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

normalize_port() {
  local specification=$1 host host_port container_port extra
  if [[ $specification != *:* ]]; then
    valid_port_number "$specification" ||
      die "invalid port '$specification'; expected an integer from 1 to 65535"
    printf '127.0.0.1:%s:%s\n' "$specification" "$specification"
    return
  fi

  IFS=: read -r host host_port container_port extra <<<"$specification"
  [[ -n $host && -n $host_port && -n $container_port && -z ${extra-} ]] ||
    die "invalid port '$specification'; expected HOST_IPV4:HOST_PORT:CONTAINER_PORT"
  valid_ipv4 "$host" || die "invalid IPv4 address in port '$specification'"
  valid_port_number "$host_port" || die "invalid host port in '$specification'; expected 1..65535"
  valid_port_number "$container_port" ||
    die "invalid container port in '$specification'; expected 1..65535"
  printf '%s:%s:%s\n' "$host" "$host_port" "$container_port"
}

run_cli() {
  local cli_id=$1
  shift
  local dataset project home root image port_spec
  local -a datasets=() ports=() cli_arguments=() podman_args
  local nvidia=false

  load_manifest "$cli_id"
  while (($#)); do
    case $1 in
      --)
        shift
        cli_arguments=("$@")
        break
        ;;
      --dataset)
        (($# >= 2)) || die "--dataset requires a path"
        datasets+=("$2")
        shift 2
        ;;
      -p | --port)
        (($# >= 2)) || die "$1 requires PORT or HOST_IPV4:HOST_PORT:CONTAINER_PORT; place native CLI options after --"
        ports+=("$(normalize_port "$2")")
        shift 2
        ;;
      --nvidia)
        nvidia=true
        shift
        ;;
      -h | --help)
        print_cli_help "$cli_id"
        return
        ;;
      *)
        die "unknown secli option '$1'; place native CLI arguments after --"
        ;;
    esac
  done

  project=$(canonical_existing_path "$PWD" "project directory")
  [[ -d $project ]] || die "project path is not a directory: $project"
  validate_project_path "$project"

  for dataset in "${!datasets[@]}"; do
    datasets[dataset]=$(canonical_existing_path "${datasets[dataset]}" "dataset")
  done

  root=$(state_root)
  home="$root/$cli_id/home"
  mkdir -p -- "$home"
  chmod 700 -- "$root/$cli_id" "$home"

  command -v podman >/dev/null 2>&1 || die "podman is required on the Fedora host"
  if podman container exists "$CONTAINER_NAME"; then
    die "container '$CONTAINER_NAME' already exists; secli v1 allows only one instance"
  fi

  [[ -f $BASE_DIR/VERSION ]] || die "VERSION is missing from deployment root '$BASE_DIR'"
  IFS= read -r image <"$BASE_DIR/VERSION"
  image=${SECLI_IMAGE:-"ghcr.io/hinnyuu/secli:$image"}
  podman image exists "$image" ||
    die "image '$image' is not available; pull it manually or set SECLI_IMAGE"

  podman_args=(
    run
    --name "$CONTAINER_NAME"
    --rm
    --interactive
    --network slirp4netns:port_handler=slirp4netns
    --env "SECLI_CLI=$cli_id"
    --volume "$home:/root:rw,Z"
    --volume "$NIX_VOLUME:/nix:rw"
    --volume "$BASE_DIR/manifest:/opt/secli/manifest:ro,z"
    --volume "$BASE_DIR/templates:/opt/secli/templates:ro,z"
    --volume "$project:$project:rw,z"
    --workdir "$project"
  )
  [[ -t 0 && -t 1 ]] && podman_args+=(--tty)
  [[ -d $BASE_DIR/manifest.local ]] &&
    podman_args+=(--volume "$BASE_DIR/manifest.local:/opt/secli/manifest.local:ro,z")
  for dataset in "${datasets[@]}"; do
    podman_args+=(--volume "$dataset:$dataset:ro,z")
  done
  for port_spec in "${ports[@]}"; do
    podman_args+=(--publish "$port_spec")
  done
  if [[ $nvidia == true ]]; then
    podman_args+=(--security-opt=label=disable --device=nvidia.com/gpu=all)
  fi

  exec podman "${podman_args[@]}" "$image" "${cli_arguments[@]}"
}

main() {
  local command=${1-}
  case $command in
    "" | -h | --help)
      print_help
      ;;
    init)
      shift
      init_command "$@"
      ;;
    list)
      (($# == 1)) || die "usage: secli list"
      list_clis
      ;;
    *)
      shift
      run_cli "$command" "$@"
      ;;
  esac
}

main "$@"

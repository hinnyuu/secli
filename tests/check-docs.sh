#!/usr/bin/env bash
set -euo pipefail

ROOT=${SECLI_DOC_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}

fail() {
  printf 'documentation check: %s\n' "$1" >&2
  exit 1
}

[[ -f "$ROOT/LICENSE" ]] || fail "LICENSE is missing"

version=$(<"$ROOT/VERSION")
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-dev)?$ ]] ||
  fail "VERSION must match vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-dev"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tag=$(git -C "$ROOT" tag --points-at HEAD | sort -V | tail -n 1)
  if [[ -n $tag && $tag != "$version" ]]; then
    fail "tag '$tag' at HEAD does not match VERSION '$version'"
  fi
fi

if rg -n '<FULL_COMMIT>|QODER_APPEND_SYSTEM_PROMPT|/root/\.qoder/' \
  "$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/docs"; then
  fail "obsolete placeholder or Qoder path remains in documentation"
fi

if rg -n 'LICENSE（由 GitHub 创建仓库时生成）|Fedora/CI 构建待验证|需 GitHub 仓库验证|架构已定案，正在实现|## 计划中的(安装方式|用法)' \
  "$ROOT/AGENTS.md" "$ROOT/README.md"; then
  fail "completed repository or host state is still marked pending"
fi

example="$ROOT/config/secli.conf.example"
[[ -f $example ]] || fail "config/secli.conf.example is missing"
supported_keys=$(sed -n 's/^readonly CONFIG_SUPPORTED_KEYS="\(.*\)"$/\1/p' "$ROOT/secli.sh")
[[ -n $supported_keys ]] || fail "CONFIG_SUPPORTED_KEYS not found in secli.sh"
for key in $supported_keys; do
  rg -q "^#?$key=" "$example" || fail "config example does not document $key"
done

test_count=$(rg -c '^@test ' "$ROOT/tests"/*.bats | cut -d: -f2 | paste -sd+ | bc)
rg -q "自动测试共覆盖 ${test_count} 个场景" "$ROOT/AGENTS.md" ||
  fail "AGENTS.md test count does not match ${test_count} Bats tests"
rg -q "entrypoint 的 ${test_count} 个场景" "$ROOT/README.md" ||
  fail "README.md test count does not match ${test_count} Bats tests"

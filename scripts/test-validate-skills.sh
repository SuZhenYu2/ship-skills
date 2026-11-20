#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ship-validate-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "[PASS] $1"; }
fail() { FAILED=$((FAILED + 1)); echo "[FAIL] $1" >&2; }

copy_repo() {
  local dest="$1"
  mkdir -p "${dest}"
  cp -R "${REPO_ROOT}/." "${dest}/"
  rm -rf "${dest}/.git" "${dest}/.ai-stats"
}

expect_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "${name}"
  else
    fail "${name}（预期通过，实际失败）"
  fi
}

expect_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "${name}（预期失败，实际通过）"
  else
    pass "${name}"
  fi
}

yaml_parse_all() {
  local root="$1"
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e '
      ok = true
      Dir.glob(File.join(ARGV[0], "skills/ship-*/SKILL.md")).sort.each do |f|
        fm = File.read(f).split(/^---\s*$/)[1]
        begin
          d = YAML.safe_load(fm)
          raise "name/description 缺失或类型错误" unless d.is_a?(Hash) && d["name"].is_a?(String) && d["description"].is_a?(String)
        rescue => e
          warn "  #{f}: #{e.message}"
          ok = false
        end
      end
      exit(ok ? 0 : 1)
    ' "${root}"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "${root}" <<'PY'
import glob, os, re, sys
import yaml
ok = True
for f in sorted(glob.glob(os.path.join(sys.argv[1], "skills/ship-*/SKILL.md"))):
    raw = open(f, encoding="utf-8").read()
    parts = re.split(r"^---\s*$", raw, flags=re.M)
    try:
        d = yaml.safe_load(parts[1])
        assert isinstance(d, dict) and isinstance(d.get("name"), str) and isinstance(d.get("description"), str)
    except Exception as e:
        print(f"  {f}: {e}", file=sys.stderr)
        ok = False
sys.exit(0 if ok else 1)
PY
  else
    echo "  缺少 YAML 解析器（ruby 或 python3+PyYAML）" >&2
    return 1
  fi
}

replace_description() {
  local f="$1" line="$2"
  awk -v repl="${line}" 'BEGIN{done=0} /^description:/ && done==0 {print repl; done=1; next} {print}' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

T_HEALTHY="${TMP_ROOT}/healthy"
copy_repo "${T_HEALTHY}"
expect_ok "健康仓库校验通过" bash "${T_HEALTHY}/scripts/validate-skills.sh"

if yaml_parse_all "${T_HEALTHY}"; then
  pass "全部 SKILL.md frontmatter 严格 YAML 解析成功"
else
  fail "全部 SKILL.md frontmatter 严格 YAML 解析成功"
fi

T_BAD_YAML="${TMP_ROOT}/bad-yaml"
copy_repo "${T_BAD_YAML}"
replace_description "${T_BAD_YAML}/skills/ship-commit/SKILL.md" 'description: 生成 <type>(<req-id>): <scope> <subject> 提交信息'
expect_fail "非法 YAML frontmatter 被拦截" bash "${T_BAD_YAML}/scripts/validate-skills.sh"

T_NAME="${TMP_ROOT}/name-mismatch"
copy_repo "${T_NAME}"
awk '{if ($0 ~ /^name: ship-tdd$/) print "name: wrong-name"; else print}' "${T_NAME}/skills/ship-tdd/SKILL.md" > "${T_NAME}/skills/ship-tdd/SKILL.md.tmp" && mv "${T_NAME}/skills/ship-tdd/SKILL.md.tmp" "${T_NAME}/skills/ship-tdd/SKILL.md"
expect_fail "name 与目录不一致被拦截" bash "${T_NAME}/scripts/validate-skills.sh"

T_NO_DESC="${TMP_ROOT}/no-description"
copy_repo "${T_NO_DESC}"
awk '!/^description:/' "${T_NO_DESC}/skills/ship-auto/SKILL.md" > "${T_NO_DESC}/skills/ship-auto/SKILL.md.tmp" && mv "${T_NO_DESC}/skills/ship-auto/SKILL.md.tmp" "${T_NO_DESC}/skills/ship-auto/SKILL.md"
expect_fail "缺少 description 被拦截" bash "${T_NO_DESC}/scripts/validate-skills.sh"

echo "汇总：${PASSED} passed, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]]

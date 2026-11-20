#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD="${SCRIPT_DIR}/build-fixtures.sh"
CHECK="${REPO_ROOT}/scripts/check-git-policy.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ship-fixtures-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "[PASS] $1"; }
fail() { FAILED=$((FAILED + 1)); echo "[FAIL] $1" >&2; }

assert() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

bash "${BUILD}" "${TMP_ROOT}/fx"
FX="${TMP_ROOT}/fx"

# 用例 2：上游 discount=None 陷阱必须真实复现（unittest 因 TypeError 失败）
CASE2="${FX}/case-2-order-refund"
CASE2_OUT="$(cd "${CASE2}" && python3 -m unittest discover -s . -t . 2>&1 || true)"
if printf '%s' "${CASE2_OUT}" | grep -q 'TypeError'; then
  pass "用例 2 夹具复现上游 None 导致的 TypeError"
else
  fail "用例 2 夹具复现上游 None 导致的 TypeError"
fi

# 用例 3：master 分支工作区 diff 必须含三处埋雷与无关文件改动
CASE3="${FX}/case-3-buried-diff"
assert "用例 3 夹具处于 master 基线分支" test "$(git -C "${CASE3}" branch --show-current)" = "master"
CASE3_DIFF="$(git -C "${CASE3}" diff)"
if printf '%s' "${CASE3_DIFF}" | grep -q 'remote_fetch'; then
  pass "用例 3 埋雷①循环内逐条外部 IO"
else
  fail "用例 3 埋雷①循环内逐条外部 IO"
fi
if printf '%s' "${CASE3_DIFF}" | grep -q 'except Exception:'; then
  pass "用例 3 埋雷②静默吞异常"
else
  fail "用例 3 埋雷②静默吞异常"
fi
if printf '%s' "${CASE3_DIFF}" | grep -q 'DEBUG'; then
  pass "用例 3 埋雷③调试 print 残留"
else
  fail "用例 3 埋雷③调试 print 残留"
fi
if git -C "${CASE3}" diff --name-only | grep -q 'unrelated.md'; then
  pass "用例 3 混入无关文件改动"
else
  fail "用例 3 混入无关文件改动"
fi

# 用例 5：5 条提交中第 3 条缺需求 ID，range 校验必须精准拦截该条
CASE5="${FX}/case-5-hidden-violation"
CASE5_OUT="$(bash "${CHECK}" --repo "${CASE5}" --mode range --base master 2>&1 || true)"
if printf '%s' "${CASE5_OUT}" | grep -q 'chore: cleanup temp files'; then
  pass "用例 5 夹具的第 3 条违规提交被 range 校验定位"
else
  fail "用例 5 夹具的第 3 条违规提交被 range 校验定位"
fi
CASE5_FAILS="$(printf '%s\n' "${CASE5_OUT}" | grep -c '^\[FAIL\]' || true)"
assert "用例 5 仅第 3 条不合规（其余 4 条通过）" test "${CASE5_FAILS}" = "1"
assert "用例 5 提交总数为 5" test "$(git -C "${CASE5}" rev-list --count master..HEAD)" = "5"

# 用例 10：合规分支末尾 ID + 脏暂存 + 历史旧 ID 陷阱
CASE10="${FX}/case-10-dirty-staging"
assert "用例 10 分支末尾为 7056405076" test "$(git -C "${CASE10}" branch --show-current)" = "feature-20261120-pay-refund-7056405076"
if git -C "${CASE10}" diff --cached --name-only | grep -q 'debug_dump.log'; then
  pass "用例 10 暂存区混入调试文件"
else
  fail "用例 10 暂存区混入调试文件"
fi
if git -C "${CASE10}" log --pretty=%s | grep -q '1111111111'; then
  pass "用例 10 历史提交含旧 ID 1111111111"
else
  fail "用例 10 历史提交含旧 ID 1111111111"
fi

echo "汇总：${PASSED} passed, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]]

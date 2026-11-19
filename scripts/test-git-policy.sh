#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-git-policy.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ship-git-policy-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "[PASS] $1"; }
fail() { FAILED=$((FAILED + 1)); echo "[FAIL] $1" >&2; }

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

init_repo() {
  local dir="$1"
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" symbolic-ref HEAD refs/heads/master
  git -C "${dir}" config user.email "test@example.invalid"
  git -C "${dir}" config user.name "Test"
  printf 'base\n' > "${dir}/base.txt"
  git -C "${dir}" add base.txt
  git -C "${dir}" commit -qm "feat(1000): base init"
}

commit_file() {
  local dir="$1" file="$2" content="$3" msg="$4"
  printf '%s\n' "${content}" > "${dir}/${file}"
  git -C "${dir}" add "${file}"
  git -C "${dir}" commit -qm "${msg}"
}

REPO_BRANCH="${TMP_ROOT}/branch"
init_repo "${REPO_BRANCH}"
expect_fail "受保护基线分支被拦截" bash "${CHECK}" --repo "${REPO_BRANCH}" --mode branch
git -C "${REPO_BRANCH}" checkout -qb "feature-20261120-order-cancel-7056405076"
expect_ok "合规 feature 分支通过" bash "${CHECK}" --repo "${REPO_BRANCH}" --mode branch
expect_ok "合规 Commit Message 通过" bash "${CHECK}" --mode commit-msg --message "feat(7056405076): order add timeout cancel"
expect_fail "缺少需求 ID 的 Commit Message 被拦截" bash "${CHECK}" --mode commit-msg --message "feat: order add timeout cancel"
git -C "${REPO_BRANCH}" checkout -q --detach
expect_fail "detached HEAD 被拦截" bash "${CHECK}" --repo "${REPO_BRANCH}" --mode branch
git -C "${REPO_BRANCH}" checkout -q "feature-20261120-order-cancel-7056405076"

REPO_RANGE="${TMP_ROOT}/range"
init_repo "${REPO_RANGE}"
git -C "${REPO_RANGE}" checkout -qb "feature-20261120-order-cancel-7056405076"
commit_file "${REPO_RANGE}" first.txt "first" "feat(7056405076): order add first"
commit_file "${REPO_RANGE}" second.txt "second" "fix(7056405076): order fix second"
expect_ok "全部合规的提交区间通过" bash "${CHECK}" --repo "${REPO_RANGE}" --mode range --base master
commit_file "${REPO_RANGE}" third.txt "third" "oops no requirement id"
expect_fail "区间内单条违规提交被拦截" bash "${CHECK}" --repo "${REPO_RANGE}" --mode range --base master

REPO_MERGE="${TMP_ROOT}/merge"
init_repo "${REPO_MERGE}"
git -C "${REPO_MERGE}" checkout -qb "feature-20261120-order-cancel-7056405076"
commit_file "${REPO_MERGE}" feature.txt "feature" "feat(7056405076): order add merge case"
git -C "${REPO_MERGE}" checkout -q master
commit_file "${REPO_MERGE}" mainline.txt "mainline" "fix(1000): base sync"
git -C "${REPO_MERGE}" checkout -q "feature-20261120-order-cancel-7056405076"
git -C "${REPO_MERGE}" merge -q --no-ff master -m "Merge branch 'master' into feature"
expect_fail "merge 提交缺少需求 ID 被拦截" bash "${CHECK}" --repo "${REPO_MERGE}" --mode range --base master
git -C "${REPO_MERGE}" commit --amend -qm "chore(7056405076): order merge master"
expect_ok "合规 merge 提交通过" bash "${CHECK}" --repo "${REPO_MERGE}" --mode range --base master

expect_ok "合法空区间通过" bash "${CHECK}" --repo "${REPO_BRANCH}" --mode range --base master
expect_fail "不存在的基线被拦截" bash "${CHECK}" --repo "${REPO_BRANCH}" --mode range --base missing-base
BLOB="$(git -C "${REPO_BRANCH}" hash-object -w --stdin </dev/null)"
expect_fail "非 commit 基线被拦截" bash "${CHECK}" --repo "${REPO_BRANCH}" --mode range --base "${BLOB}"
git -C "${REPO_BRANCH}" tag -a baseline -m baseline master
expect_ok "指向 commit 的附注 tag 可作基线" bash "${CHECK}" --repo "${REPO_BRANCH}" --mode range --base baseline

(
  git() {
    local arg
    for arg in "$@"; do
      if [[ "${arg}" == log ]]; then
        printf 'fatal: simulated object read failure\n' >&2
        return 128
      fi
    done
    command git "$@"
  }
  export -f git
  if bash "${CHECK}" --repo "${REPO_BRANCH}" --mode range --base master >"${TMP_ROOT}/log-failure.out" 2>&1; then
    exit 1
  fi
  found_failure=false
  while IFS= read -r line; do
    [[ "${line}" != 汇总：* ]] || exit 1
    if [[ "${line}" == *无法枚举* ]]; then found_failure=true; fi
  done < "${TMP_ROOT}/log-failure.out"
  [[ "${found_failure}" == true ]]
) && pass "枚举失败不输出成功汇总" || fail "枚举失败未正确阻断"

echo "汇总：${PASSED} passed, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]]

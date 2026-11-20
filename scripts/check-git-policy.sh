#!/usr/bin/env bash
set -euo pipefail

# 确定性校验 Git 分支命名与飞书系统需求 ID 提交规范
# 用法：
#   bash scripts/check-git-policy.sh --repo <path> --mode branch
#   bash scripts/check-git-policy.sh --mode commit-msg --message "feat(7056405076): order 新增超时取消"
#   bash scripts/check-git-policy.sh --repo <path> --mode range --base master

REPO_DIR="."
MODE="range"
BASE_REF="master"
COMMIT_MSG=""
VERIFY_HEAD="" VERIFY_TREE="" REVIEW_HEAD="" REVIEW_TREE=""

BRANCH_REGEX='^(release-[0-9]{8}|(feature|hotfeat|hotfix)-[0-9]{8}-[a-zA-Z0-9._-]+-[a-zA-Z0-9_-]+|dev-[a-zA-Z0-9._-]+-[a-zA-Z0-9._-]+-[a-zA-Z0-9_-]+)$'
COMMIT_REGEX='^(feat|fix|refactor|perf|test|chore|docs|style|build|ci)\([a-zA-Z0-9_-]+\): [a-zA-Z0-9._/-]+ .+$'

usage() {
  cat <<'EOF'
Usage: bash scripts/check-git-policy.sh [options]

Options:
  --repo <path>         目标 Git 仓库路径（默认: 当前目录）
  --mode <mode>         branch | commit-msg | range | handoff（默认: range）
  --verify-head <sha> --verify-tree <sha>  handoff 模式的 PASS 快照
  --review-head <sha> --review-tree <sha>  handoff 模式的 READY 快照
  --base <ref>          range 模式的对比基线（默认: master）
  --message <msg>       commit-msg 模式待校验的单条提交信息
  -h, --help            显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_DIR="${2:-.}"; shift 2 ;;
    --mode) MODE="${2:-range}"; shift 2 ;;
    --base) BASE_REF="${2:-master}"; shift 2 ;;
    --message) COMMIT_MSG="${2:-}"; shift 2 ;;
    --verify-head) VERIFY_HEAD="${2:-}"; shift 2 ;;
    --verify-tree) VERIFY_TREE="${2:-}"; shift 2 ;;
    --review-head) REVIEW_HEAD="${2:-}"; shift 2 ;;
    --review-tree) REVIEW_TREE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

check_branch() {
  local branch
  branch="$(git -C "${REPO_DIR}" branch --show-current)"
  if [[ -z "${branch}" ]]; then
    echo "[FAIL] 当前处于 detached HEAD 状态，不符合分支规范。" >&2
    return 1
  fi
  if [[ "${branch}" == "main" || "${branch}" == "master" ]]; then
    echo "[FAIL] 当前位于受保护基线分支 '${branch}'，禁止直接开发或提交。" >&2
    return 1
  fi
  if [[ ! "${branch}" =~ ${BRANCH_REGEX} ]]; then
    echo "[FAIL] 分支名 '${branch}' 不符合 5 类合法命名格式。" >&2
    return 1
  fi
  if [[ "${branch}" == release-* ]]; then
    echo "[PASS] 分支名合规: ${branch}（release 分支不提取需求 ID）"
  else
    local req_id="${branch##*-}"
    echo "[PASS] 分支名合规: ${branch}（提取需求 ID 候选: ${req_id}）"
  fi
  return 0
}

check_single_msg() {
  local msg="$1"
  local first_line
  first_line="$(printf '%s\n' "${msg}" | head -n 1)"
  if [[ ! "${first_line}" =~ ${COMMIT_REGEX} ]]; then
    echo "[FAIL] Commit Message 不合规: ${first_line}" >&2
    echo "       期望格式: <type>(<req-id>): <scope> <subject>" >&2
    return 1
  fi
  echo "[PASS] Commit Message 合规: ${first_line}"
  return 0
}

check_range() {
  local errs=0
  check_branch || errs=$((errs + 1))

  local base_commit commits
  if ! base_commit="$(git -C "${REPO_DIR}" rev-parse --verify "${BASE_REF}^{commit}")"; then
    echo "[FAIL] 基线引用 '${BASE_REF}' 不存在或不是提交，请通过 --base 指定正确基线。" >&2
    return 1
  fi
  if ! commits="$(git -C "${REPO_DIR}" log "${base_commit}..HEAD" --pretty=format:'%h%x09%s')"; then
    echo "[FAIL] 无法枚举 ${BASE_REF}..HEAD 提交，区间校验未完成。" >&2
    return 1
  fi

  local total=0
  local bad=0
  while IFS=$'\t' read -r sha subject || [[ -n "${sha}" ]]; do
    [[ -z "${sha}" ]] && continue
    total=$((total + 1))
    if [[ ! "${subject}" =~ ${COMMIT_REGEX} ]]; then
      echo "[FAIL] ${sha} 缺失合法飞书需求 ID 或格式错误: ${subject}" >&2
      bad=$((bad + 1))
    else
      echo "[PASS] ${sha} ${subject}"
    fi
  done <<< "${commits}"

  echo "汇总：基线 ${BASE_REF}..HEAD 共检查 ${total} 条提交（含 merge），不合规 ${bad} 条。"
  if [[ "${bad}" -gt 0 || "${errs}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

check_handoff() {
  local head tree unstaged untracked
  if ! unstaged="$(git -C "${REPO_DIR}" diff --name-only --ignore-submodules=none)" ||
     ! untracked="$(git -C "${REPO_DIR}" ls-files --others --exclude-standard)"; then
    echo '[FAIL] 无法检查工作区，不能确认提交范围。' >&2
    return 1
  fi
  if [[ -n "${unstaged}" || -n "${untracked}" ]]; then
    printf '[FAIL] 工作区含未暂存或未跟踪文件；请由 Lead 确认范围并重验复审。\n%s\n%s\n' "${unstaged}" "${untracked}" >&2
    return 1
  fi
  if [[ -z "${REVIEW_HEAD}" || -z "${REVIEW_TREE}" || "${REVIEW_HEAD}" != "${VERIFY_HEAD}" || "${REVIEW_TREE}" != "${VERIFY_TREE}" ]]; then
    echo '[FAIL] READY 证据缺失或不匹配 PASS 快照。' >&2
    return 1
  fi
  if ! head="$(git -C "${REPO_DIR}" rev-parse --verify HEAD)" ||
     ! tree="$(git -C "${REPO_DIR}" write-tree)"; then
    echo '[FAIL] 无法读取待提交快照。' >&2
    return 1
  fi
  if [[ "${VERIFY_HEAD}" != "${head}" || "${VERIFY_TREE}" != "${tree}" ]]; then
    echo '[FAIL] PASS 证据缺失或不匹配当前 HEAD/index tree。' >&2
    return 1
  fi
  echo '[PASS] PASS 与 READY 均匹配当前 HEAD/index tree，工作区无非忽略的未暂存输入。'
}

case "${MODE}" in
  handoff)
    check_handoff
    ;;
  branch)
    check_branch
    ;;
  commit-msg)
    if [[ -z "${COMMIT_MSG}" ]]; then
      echo "[FAIL] --mode commit-msg 必须传入 --message" >&2
      exit 2
    fi
    check_single_msg "${COMMIT_MSG}"
    ;;
  range)
    check_range
    ;;
  *)
    echo "无效的 --mode: ${MODE}（支持 branch | commit-msg | range | handoff）" >&2
    exit 2
    ;;
esac

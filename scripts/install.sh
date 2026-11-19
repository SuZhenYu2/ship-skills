#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_SRC="${REPO_ROOT}/skills"

TARGET="all"
CODEX_DIR="${CODEX_SKILLS_DIR:-${HOME}/.codex/skills}"
DSH_DIR="${DSH_SKILLS_DIR:-${HOME}/.dsh/skills}"
UPGRADE=false
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: bash scripts/install.sh [options]

Options:
  --target <codex|dsh|all>   安装目标（默认: all）
  --codex-dir <path>         指定 Codex skills 目录（默认: $CODEX_SKILLS_DIR 或 ~/.codex/skills）
  --dsh-dir <path>           指定 DSH skills 目录（默认: $DSH_SKILLS_DIR 或 ~/.dsh/skills）
  --upgrade                  覆盖已有同名 ship-* 目录
  --dry-run                  仅打印将要执行的操作，不实际写入文件
  -h, --help                 显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --codex-dir)
      CODEX_DIR="${2:-}"
      shift 2
      ;;
    --dsh-dir)
      DSH_DIR="${2:-}"
      shift 2
      ;;
    --upgrade)
      UPGRADE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${TARGET}" in
  codex|dsh|all) ;;
  *)
    echo "无效的 --target 值: ${TARGET}（仅支持 codex | dsh | all）" >&2
    exit 1
    ;;
esac

if [[ ! -d "${SKILLS_SRC}" ]]; then
  echo "未找到 skills 目录: ${SKILLS_SRC}" >&2
  exit 1
fi

install_to_dir() {
  local label="$1"
  local dest_root="$2"
  local count=0

  echo "==> 目标 [${label}]: ${dest_root}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    mkdir -p "${dest_root}"
    # 共享副本便于浏览；Skill 运行时使用各自目录内的自包含副本
    rm -rf "${dest_root}/_ship-shared"
    mkdir -p "${dest_root}/_ship-shared"
    cp -R "${REPO_ROOT}/references" "${dest_root}/_ship-shared/references"
    cp -R "${REPO_ROOT}/docs" "${dest_root}/_ship-shared/docs"
    cp -R "${REPO_ROOT}/scripts" "${dest_root}/_ship-shared/scripts"
  else
    echo "  [dry-run] 同步共享参考文档到 ${dest_root}/_ship-shared/{references,docs,scripts}"
  fi

  for skill_dir in "${SKILLS_SRC}"/ship-*; do
    [[ -d "${skill_dir}" ]] || continue
    local skill_name
    skill_name="$(basename "${skill_dir}")"
    local dest_skill="${dest_root}/${skill_name}"

    if [[ -d "${dest_skill}" && "${UPGRADE}" == "false" ]]; then
      echo "  [跳过] ${skill_name} 已存在（使用 --upgrade 可覆盖更新）"
      continue
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "  [dry-run] 安装 ${skill_name} -> ${dest_skill}（含自包含 references/docs/scripts）"
    else
      rm -rf "${dest_skill}"
      cp -R "${skill_dir}" "${dest_skill}"
      # Skill 自包含：安装后所有相对路径都能在 Skill 目录内解析
      rm -rf "${dest_skill}/references" "${dest_skill}/docs" "${dest_skill}/scripts"
      cp -R "${REPO_ROOT}/references" "${dest_skill}/references"
      mkdir -p "${dest_skill}/docs" "${dest_skill}/scripts"
      cp "${REPO_ROOT}/docs/multi-agent-policy.md" "${dest_skill}/docs/multi-agent-policy.md"
      cp "${REPO_ROOT}/scripts/check-git-policy.sh" "${dest_skill}/scripts/check-git-policy.sh"
      echo "  [已安装] ${skill_name} -> ${dest_skill}"
    fi
    count=$((count + 1))
  done

  echo "完成 [${label}]：共处理 ${count} 个 Skill。"
}

if [[ "${TARGET}" == "codex" || "${TARGET}" == "all" ]]; then
  install_to_dir "Codex" "${CODEX_DIR}"
fi

if [[ "${TARGET}" == "dsh" || "${TARGET}" == "all" ]]; then
  install_to_dir "DSH" "${DSH_DIR}"
fi

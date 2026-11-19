#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ERRORS=0
SKILL_COUNT=0

required_files=(
  "README.md"
  "AGENTS.md.template"
  "references/dev-baseline.md"
  "references/review-checklist.md"
  "references/git-branch-policy.md"
  "references/stacks/_template.md"
  "docs/workflow.md"
  "docs/multi-agent-policy.md"
  "docs/onboarding.md"
  "evals/calibration-cases.md"
  "scripts/install.sh"
  "scripts/check-git-policy.sh"
  "scripts/test-git-policy.sh"
)

echo "==> 校验核心文件完整性"
for rel in "${required_files[@]}"; do
  if [[ ! -f "${REPO_ROOT}/${rel}" ]]; then
    echo "[ERROR] 缺少核心文件: ${rel}" >&2
    ERRORS=$((ERRORS + 1))
  fi
done

echo "==> 校验 skills/ship-*/SKILL.md"
for skill_dir in "${REPO_ROOT}"/skills/ship-*; do
  [[ -d "${skill_dir}" ]] || continue
  SKILL_COUNT=$((SKILL_COUNT + 1))
  dir_name="$(basename "${skill_dir}")"
  skill_file="${skill_dir}/SKILL.md"

  if [[ ! -f "${skill_file}" ]]; then
    echo "[ERROR] 缺少 SKILL.md: ${skill_dir}" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  first_line="$(head -n 1 "${skill_file}")"
  if [[ "${first_line}" != "---" ]]; then
    echo "[ERROR] ${dir_name}/SKILL.md 缺少 YAML frontmatter 起始标记 ---" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  fm_name="$(awk '/^---$/{c++; next} c==1 && /^name:/{sub(/^name:[[:space:]]*/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' "${skill_file}")"
  fm_desc="$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "${skill_file}")"

  if [[ -z "${fm_name}" ]]; then
    echo "[ERROR] ${dir_name}/SKILL.md frontmatter 缺少 name 字段" >&2
    ERRORS=$((ERRORS + 1))
  elif [[ "${fm_name}" != "${dir_name}" ]]; then
    echo "[ERROR] ${dir_name}/SKILL.md 的 name (${fm_name}) 与目录名不一致" >&2
    ERRORS=$((ERRORS + 1))
  fi

  if [[ -z "${fm_desc}" ]]; then
    echo "[ERROR] ${dir_name}/SKILL.md frontmatter 缺少 description 字段" >&2
    ERRORS=$((ERRORS + 1))
  fi

  while IFS= read -r ref_path; do
    [[ -z "${ref_path}" ]] && continue
    # 目标项目产物路径示例（如 docs/adr/*）不属于本仓库内部文件
    [[ "${ref_path}" == docs/adr/* ]] && continue
    if [[ ! -f "${REPO_ROOT}/${ref_path}" ]]; then
      echo "[ERROR] ${dir_name}/SKILL.md 引用了不存在的文件: ${ref_path}" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done < <(grep -oE '(references|docs|scripts|skills)/[a-zA-Z0-9_./-]+\.(md|sh)' "${skill_file}" | sort -u || true)
done

if [[ "${SKILL_COUNT}" -ne 10 ]]; then
  echo "[ERROR] 预期 10 个 ship-* Skill，实际检测到 ${SKILL_COUNT} 个" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> 校验安装后布局与 Shell 语法"
TMP_INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/ship-skills-validate.XXXXXX")"
trap 'rm -rf "${TMP_INSTALL}"' EXIT

if ! bash "${REPO_ROOT}/scripts/install.sh" --target codex --codex-dir "${TMP_INSTALL}" >/dev/null; then
  echo "[ERROR] install.sh 执行失败，无法校验安装后布局" >&2
  ERRORS=$((ERRORS + 1))
fi

for installed_skill in "${TMP_INSTALL}"/ship-*; do
  [[ -d "${installed_skill}" ]] || continue
  installed_name="$(basename "${installed_skill}")"
  for required in references/dev-baseline.md docs/multi-agent-policy.md scripts/check-git-policy.sh; do
    if [[ ! -f "${installed_skill}/${required}" ]]; then
      echo "[ERROR] 安装后 ${installed_name} 缺少 ${required}" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done
  while IFS= read -r ref_path; do
    [[ -z "${ref_path}" ]] && continue
    # 目标项目产物路径示例（如 docs/adr/*）不属于安装包内部文件
    [[ "${ref_path}" == docs/adr/* ]] && continue
    if [[ ! -f "${installed_skill}/${ref_path}" ]]; then
      echo "[ERROR] 安装后 ${installed_name} 无法解析路径: ${ref_path}" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done < <(grep -oE '(references|docs|scripts)/[a-zA-Z0-9_./-]+\.(md|sh)' "${installed_skill}/SKILL.md" | sort -u || true)
done

for script in "${REPO_ROOT}"/scripts/*.sh; do
  if ! bash -n "${script}"; then
    echo "[ERROR] Shell 语法错误: $(basename "${script}")" >&2
    ERRORS=$((ERRORS + 1))
  fi
done

if [[ "${ERRORS}" -gt 0 ]]; then
  echo "校验失败：共发现 ${ERRORS} 个错误。" >&2
  exit 1
fi

echo "校验通过：共检查 ${SKILL_COUNT} 个 Skill 及 ${#required_files[@]} 个核心文件，全部合规。"

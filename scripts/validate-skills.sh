#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# frontmatter 必须用真实 YAML 解析器严格校验；缺失时硬失败，不降级为字面值检查
if ! command -v ruby >/dev/null 2>&1; then
  echo "[ERROR] 未找到 YAML 解析器（ruby），无法严格校验 SKILL.md frontmatter。" >&2
  exit 1
fi

parse_frontmatter() {
  local skill_file="$1" dir_name="$2"
  ruby -EUTF-8 -ryaml -e '# encoding: utf-8
    raw = File.read(ARGV[0], encoding: "UTF-8")
    expected = ARGV[1]
    fm = raw.split(/^---\s*$/)[1]
    abort "[ERROR] #{expected}/SKILL.md 缺少 YAML frontmatter" if fm.nil?
    begin
      data = YAML.safe_load(fm)
    rescue => e
      abort "[ERROR] #{expected}/SKILL.md frontmatter YAML 解析失败: #{e.message}"
    end
    abort "[ERROR] #{expected}/SKILL.md frontmatter 不是键值映射" unless data.is_a?(Hash)
    name = data["name"]
    desc = data["description"]
    abort "[ERROR] #{expected}/SKILL.md frontmatter 缺少 name 字段" unless name.is_a?(String) && !name.strip.empty?
    abort "[ERROR] #{expected}/SKILL.md 的 name (#{name}) 与目录名不一致" if name != expected
    abort "[ERROR] #{expected}/SKILL.md frontmatter 缺少 description 字段" unless desc.is_a?(String) && !desc.strip.empty?
  ' "${skill_file}" "${dir_name}"
}

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
  "docs/ship-arena-design.md"
  "docs/difficulty-loop-design.md"
  "evals/calibration-cases.md"
  "scripts/install.sh"
  "scripts/check-git-policy.sh"
  "scripts/check-evidence.sh"
  "scripts/test-evidence.sh"
  "scripts/test-git-policy.sh"
  "scripts/arena-state.sh"
  "scripts/arena-state.ts"
  "scripts/test-arena-state.sh"
  "scripts/test-arena-state.ts"
  "scripts/loop-state.sh"
  "scripts/loop-state.ts"
  "scripts/test-loop-state.sh"
  "scripts/test-loop-state.ts"
  "references/arena-policy.md"
  "references/loop-policy.md"
  "scripts/test-validate-skills.sh"
  "evals/fixtures/build-fixtures.sh"
  "evals/fixtures/test-fixtures.sh"
  "evals/results-template.md"
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

  if ! parse_frontmatter "${skill_file}" "${dir_name}"; then
    ERRORS=$((ERRORS + 1))
  fi

  case "${dir_name}" in
    ship-verify|ship-review|ship-commit|ship-finish)
      mode=handoff
      [[ "${dir_name}" != ship-finish ]] || mode=finish
      if ! grep -Eq 'check-evidence[.]sh --mode '"${mode}"' [^`]*--slug <slug>' "${skill_file}"; then
        echo "[ERROR] ${dir_name} 缺少按 slug 执行的 ${mode} 证据门禁" >&2
        ERRORS=$((ERRORS + 1))
      fi
      ;;
  esac
  if grep -Eq '(忽略|排除)(整个|全部|整棵)?[[:space:]]*`?/?[.]ship/`?([[:space:]，。；]|$)|`/?[.]ship/`.{0,12}(整体忽略|整体排除|加入.{0,5}(exclude|[.]gitignore))' "${skill_file}"; then
    echo "[ERROR] ${dir_name} 含已废弃的整目录忽略规则，仅 .ship/tasks/ 保持本地" >&2
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

if [[ "${SKILL_COUNT}" -ne 11 ]]; then
  echo "[ERROR] 预期 11 个 ship-* Skill，实际检测到 ${SKILL_COUNT} 个" >&2
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
  for required in references/dev-baseline.md references/arena-policy.md references/loop-policy.md docs/multi-agent-policy.md scripts/check-git-policy.sh scripts/check-evidence.sh scripts/arena-state.sh scripts/arena-state.ts scripts/loop-state.sh scripts/loop-state.ts; do
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

for script in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/evals/fixtures/*.sh; do
  if [[ ! -x "${script}" ]]; then
    echo "[ERROR] 脚本缺少可执行权限 (+x): ${script#${REPO_ROOT}/}" >&2
    ERRORS=$((ERRORS + 1))
  fi
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

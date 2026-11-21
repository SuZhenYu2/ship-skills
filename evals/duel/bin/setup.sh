#!/usr/bin/env bash
# 建立三个 Codex home 模板（臂），封存映射与内容指纹；不提供 OS 读取隔离。
# 用法：bash evals/duel/bin/setup.sh --run-root <dir> [--dev-src <dir>] [--model <name>] [--seed <int>]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

need_cmd codex
need_cmd python3
need_cmd git

RUN_ROOT=""
DEV_SRC="${HOME}/.trae-cn/plugins/trae-remote-official/dev-skills/0.8.0/skills"
MODEL=""
SEED="${RANDOM}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="${2:-}"; shift 2 ;;
    --dev-src) DEV_SRC="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --seed) SEED="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "${RUN_ROOT}" ]] || die '必须指定 --run-root（建议放在仓库之外，例如 $TMPDIR/duel-<日期>）'
[[ ! -e "${RUN_ROOT}" && ! -L "${RUN_ROOT}" ]] || die 'run-root 已存在，拒绝覆盖；请使用新目录'
[[ -d "${DEV_SRC}" ]] || die "找不到对照套件源码：${DEV_SRC}"

USER_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
[[ -f "${USER_CODEX_HOME}/config.toml" ]] || die "找不到用户 codex 配置：${USER_CODEX_HOME}/config.toml"
# mkdir 的排他性同时防止两个 setup 覆盖彼此；只允许父目录预先存在。
mkdir -p "$(dirname "${RUN_ROOT}")"
mkdir -m 700 "${RUN_ROOT}" || die '无法创建新的 run-root'
RUN_ROOT="$(cd "${RUN_ROOT}" && pwd -P)"

mkdir -p "${RUN_ROOT}"/{arms,runs,blind,scores,sealed}
chmod 700 "${RUN_ROOT}/sealed" "${RUN_ROOT}/arms"

# 随机分配臂字母，避免操作者按固定顺序形成预期。
python3 - "${SEED}" "${RUN_ROOT}/sealed/arms.json" <<'PY'
import json, random, sys
seed, out = int(sys.argv[1]), sys.argv[2]
suites = ['ship-skills', 'dev-skills', 'bare-model']
random.Random(seed).shuffle(suites)
letters = ['A', 'B', 'C']
json.dump({'seed': seed, 'mapping': dict(zip(letters, suites))},
          open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
chmod 600 "${RUN_ROOT}/sealed/arms.json"

install_arm_skills() {
  local letter="$1" suite="$2" home="$3"
  mkdir -p "${home}/skills"
  case "${suite}" in
    ship-skills)
      bash "${REPO_ROOT}/scripts/install.sh" --target codex --codex-dir "${home}/skills" --upgrade >/dev/null
      ;;
    dev-skills)
      local d
      for d in "${DEV_SRC}"/dev-*; do
        [[ -d "${d}" ]] || continue
        cp -R "${d}" "${home}/skills/$(basename "${d}")"
      done
      ;;
    bare-model)
      : # 故意留空
      ;;
    *) die "未知套件：${suite}" ;;
  esac
}

# 生成自包含的臂配置：只继承必要的 provider 连接块，丢弃 hooks / mcp / projects / tui。
write_arm_config() {
  local home="$1" model="$2"
  python3 - "${USER_CODEX_HOME}/config.toml" "${home}/config.toml" "${model}" <<'PY'
import os
import pathlib, re, shutil, sys

src, dst, model = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
text = src.read_text(encoding='utf-8')


def top_level(key):
    m = re.search(rf'^{re.escape(key)}\s*=\s*(.+)$', text, re.M)
    return m.group(1).strip().strip('"') if m else None


provider = top_level('model_provider')
model = model or top_level('model')
if not model:
    sys.exit('[ERROR] 无法确定模型，请用 --model 指定')

block = ''
if provider:
    m = re.search(rf'^\[model_providers\.{re.escape(provider)}\]\s*$(.*?)(?=^\[|\Z)',
                  text, re.M | re.S)
    if not m:
        sys.exit(f'[ERROR] 用户配置里找不到 provider 块：{provider}')
    block = f'[model_providers.{provider}]\n{m.group(1).strip()}\n'

lines = [
    '# 由双盲评测 harness 生成：pinned，不含 hooks / mcp_servers / projects / tui。',
    f'model = "{model}"',
    'model_reasoning_effort = "high"',
    'approval_policy = "never"',
    'sandbox_mode = "workspace-write"',
]
# 模型目录是本地代理解析模型名所需的协变量，必须原样带入隔离 home。
catalog = top_level('model_catalog_json')
if catalog:
    source = pathlib.Path(catalog).expanduser()
    if source.is_file():
        target = dst.parent / 'models.json'
        shutil.copyfile(source, target)
        lines.append(f'model_catalog_json = "{target}"')
if provider:
    lines.append(f'model_provider = "{provider}"')
lines += ['', '[features]', 'hooks = false', 'enable_fanout = false', '',
          '[agents]', 'enabled = false']
# 默认禁网：历史回放里仓库名可识别，禁网可阻止 Agent 克隆原仓库直接取答案。
if os.environ.get('DUEL_ALLOW_NETWORK') != '1':
    lines += ['', '[sandbox_workspace_write]', 'network_access = false']
lines.append('')
if block:
    lines += [block]
dst.write_text('\n'.join(lines), encoding='utf-8')
dst.chmod(0o600)
print(model)
PY
}

RESOLVED_MODEL=""
while IFS=$'\t' read -r letter suite; do
  home="${RUN_ROOT}/arms/${letter}/home"
  mkdir -p "${home}"
  cp "${USER_CODEX_HOME}/auth.json" "${home}/auth.json" 2>/dev/null || true
  chmod 600 "${home}/auth.json" 2>/dev/null || true
  RESOLVED_MODEL="$(write_arm_config "${home}" "${MODEL}")"
  install_arm_skills "${letter}" "${suite}" "${home}"
  log "[arm ${letter}] 就绪"
done < <(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))["mapping"]
for k,v in sorted(m.items()): print(f"{k}\t{v}")
' "${RUN_ROOT}/sealed/arms.json")

# 评分者使用独立的第四个 home，不安装任何技能，避免评分被任一臂的上下文影响。
RATER_HOME="${RUN_ROOT}/rater/home"
mkdir -p "${RATER_HOME}/skills"
cp "${USER_CODEX_HOME}/auth.json" "${RATER_HOME}/auth.json" 2>/dev/null || true
chmod 600 "${RATER_HOME}/auth.json" 2>/dev/null || true
write_arm_config "${RATER_HOME}" "${RESOLVED_MODEL}" >/dev/null
log '[rater] 隔离评分环境就绪'

# 记录协变量：两套套件体量差异是已知混杂因素，必须量化而不是隐藏。
python3 - "${RUN_ROOT}" "${RESOLVED_MODEL}" "$(codex --version 2>/dev/null | head -1)" <<'PY'
import json, pathlib, subprocess, sys

root, model, codexver = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
mapping = json.load(open(root / 'sealed/arms.json', encoding='utf-8'))['mapping']
arms = {}
for letter, suite in sorted(mapping.items()):
    skills = sorted((root / 'arms' / letter / 'home/skills').glob('*/SKILL.md'))
    arms[letter] = {
        'suite': suite,
        'skill_count': len(skills),
        'skill_md_lines': sum(len(p.read_text(encoding='utf-8').splitlines()) for p in skills),
        'skill_md_bytes': sum(p.stat().st_size for p in skills),
        'aux_files': len([p for p in (root / 'arms' / letter / 'home/skills').rglob('*')
                          if p.is_file() and p.name != 'SKILL.md']),
    }
manifest = {
    'codex_version': codexver,
    'model': model,
    'pinned': {'reasoning_effort': 'high', 'approval_policy': 'never',
               'sandbox_mode': 'workspace-write',
               'features': {'hooks': False, 'multi_agent': False, 'enable_fanout': False}},
    'arms': arms,
}
json.dump(manifest, open(root / 'sealed/manifest.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
print(json.dumps(arms, ensure_ascii=False, indent=2))
PY
chmod 600 "${RUN_ROOT}/sealed/manifest.json"

# 仅封存将复制到每个 cell 的 config/auth/models/skills；不复制 sessions/history。
python3 -B "${DUEL_DIR}/lib/runner.py" seal --run-root "${RUN_ROOT}"

fingerprint "${DUEL_DIR}/prompts" "${DUEL_DIR}/corpus/prompts" "${DUEL_DIR}/corpus/selection.json" \
  "${DUEL_DIR}/lib/tasks.sh" "${DUEL_DIR}/rubric.md" > "${RUN_ROOT}/sealed/preregistration.sha256"
chmod 600 "${RUN_ROOT}/sealed/preregistration.sha256"

log "预注册指纹已封存。运行根目录：${RUN_ROOT}"
log "下一步：bash ${DUEL_DIR}/bin/run.sh --run-root ${RUN_ROOT}"
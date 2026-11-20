#!/usr/bin/env bash
# 随机化跑批：三臂 × 任务 × 重复，逐次在独立夹具与独立 CODEX_HOME 中执行。
# 用法：bash evals/duel/bin/run.sh --run-root <dir> [--repeats 3] [--tasks T01,T02] [--dry-run] [--timeout 900]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${DUEL_DIR}/lib/tasks.sh"

RUN_ROOT=""
REPEATS=3
TASKS=""
DRY_RUN=false
TIMEOUT=900
ONLY_CODE=""
FIXTURES_DIR="${TMPDIR:-/tmp}/ship-corpus"
BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="${2:-}"; shift 2 ;;
    --repeats) REPEATS="${2:-}"; shift 2 ;;
    --tasks) TASKS="${2:-}"; shift 2 ;;
    --only-code) ONLY_CODE="${2:-}"; shift 2 ;;
    --fixtures-dir) FIXTURES_DIR="${2:-}"; shift 2 ;;
    --build) BUILD=true; shift ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

export CORPUS_FIXTURES="${FIXTURES_DIR}"
export CORPUS_DIR="${DUEL_DIR}/corpus"
export DUEL_BUILD=0
if [[ "${BUILD}" == true ]]; then
  export DUEL_BUILD=1
fi

[[ -n "${RUN_ROOT}" && -d "${RUN_ROOT}/sealed" ]] || die '请先运行 setup.sh 并指定同一 --run-root'
RUN_ROOT="$(cd "${RUN_ROOT}" && pwd)"

# 预注册校验：任务或量表在 setup 之后被改动则拒绝跑批。
EXPECTED="$(cat "${RUN_ROOT}/sealed/preregistration.sha256")"
ACTUAL="$(fingerprint "${DUEL_DIR}/prompts" "${DUEL_DIR}/corpus/prompts" "${DUEL_DIR}/corpus/selection.json" \
  "${DUEL_DIR}/lib/tasks.sh" "${DUEL_DIR}/rubric.md")"
[[ "${EXPECTED}" == "${ACTUAL}" ]] || die '预注册指纹不一致：任务/量表已改动，请重新 setup 以保证可比性'

ALLOCATION="${RUN_ROOT}/sealed/allocation.json"
if [[ ! -f "${ALLOCATION}" ]]; then
  python3 - "${RUN_ROOT}" "${REPEATS}" "${TASKS}" "${TASK_IDS[*]}" "${HISTORICAL_IDS[*]}" <<'PY'
import json, pathlib, random, sys, uuid

root = pathlib.Path(sys.argv[1])
repeats = int(sys.argv[2])
wanted = [t for t in sys.argv[3].split(',') if t]
all_tasks = sys.argv[4].split() + sys.argv[5].split()
tasks = wanted or all_tasks
for t in tasks:
    if t not in all_tasks:
        sys.exit(f'[ERROR] 未知任务：{t}')
mapping = json.load(open(root / 'sealed/arms.json', encoding='utf-8'))
seed = mapping['seed']
letters = sorted(mapping['mapping'])

cells = [(a, t, r) for a in letters for t in tasks for r in range(1, repeats + 1)]
random.Random(seed + 1).shuffle(cells)
alloc = []
for arm, task, rep in cells:
    alloc.append({'code': 'R' + uuid.uuid4().hex[:8].upper(),
                  'arm': arm, 'task': task, 'repeat': rep})
json.dump({'seed': seed, 'repeats': repeats, 'tasks': tasks, 'runs': alloc},
          open(root / 'sealed/allocation.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
print(f'矩阵：{len(letters)} 臂 × {len(tasks)} 任务 × {repeats} 次 = {len(alloc)} 次运行')
PY
  chmod 600 "${ALLOCATION}"
fi

if [[ "${DRY_RUN}" == true ]]; then
  python3 - "${ALLOCATION}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding='utf-8'))
print(f"{'code':<12}{'arm':<5}{'task':<6}repeat")
for r in a['runs']:
    print(f"{r['code']:<12}{r['arm']:<5}{r['task']:<6}{r['repeat']}")
print(f"合计 {len(a['runs'])} 次")
PY
  exit 0
fi

run_one() {
  local code="$1" arm="$2" tid="$3"
  local rd="${RUN_ROOT}/runs/${code}"
  if [[ -f "${rd}/done" ]]; then
    log "[${code}] 已完成，跳过"
    return 0
  fi
  mkdir -p "${rd}"
  local repo="${rd}/repo"
  rm -rf "${repo}"
  build_task "${tid}" "${repo}"
  if [[ "${tid}" == H* ]]; then
    cp "${CORPUS_DIR}/tasks/${tid}/prompt.md" "${rd}/prompt.md"
  else
    cp "${DUEL_DIR}/prompts/${tid}.md" "${rd}/prompt.md"
  fi

  local base_head pre_hash
  base_head="$(git -C "${repo}" rev-parse HEAD)"
  pre_hash="$(python3 -c '
import hashlib,pathlib,sys
r=pathlib.Path(sys.argv[1]); h=hashlib.sha256()
for f in sorted(r.rglob("*")):
    if f.is_file() and ".git" not in f.parts:
        h.update(str(f.relative_to(r)).encode()); h.update(f.read_bytes())
print(h.hexdigest())' "${repo}")"
  printf '%s\n' "${base_head}" > "${rd}/baseline_head"
  printf '%s\n' "${pre_hash}" > "${rd}/pre_tree_hash"
  git -C "${repo}" status --short > "${rd}/git_status_before.txt"
  git -C "${repo}" diff HEAD > "${rd}/diff_before.patch" || true

  log "[${code}] arm=${arm} task=${tid} 开始"
  CODEX_HOME="${RUN_ROOT}/arms/${arm}/home" \
  python3 - "${repo}" "${rd}" "${TIMEOUT}" <<'PY'
import json, os, pathlib, subprocess, sys, time

repo, rd, timeout = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
prompt = (rd / 'prompt.md').read_text(encoding='utf-8')
cmd = ['codex', 'exec', '--json', '--sandbox', 'workspace-write',
       '--cd', str(repo), '--output-last-message', str(rd / 'final_message.md'), prompt]
start = time.time()
status = 'ok'
run_env = os.environ.copy()
run_env.setdefault('RUST_LOG', 'error')
with open(rd / 'events.jsonl', 'w', encoding='utf-8') as ev:
    try:
        p = subprocess.run(cmd, stdout=ev, stderr=subprocess.PIPE, text=True,
                           timeout=timeout, env=run_env)
        rc = p.returncode
        (rd / 'stderr.txt').write_text(p.stderr or '', encoding='utf-8')
    except subprocess.TimeoutExpired:
        rc, status = -1, 'timeout'
        (rd / 'stderr.txt').write_text('harness timeout', encoding='utf-8')
elapsed = round(time.time() - start, 1)


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield k
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)


lines, usage = [], {}
for raw in (rd / 'events.jsonl').read_text(encoding='utf-8', errors='replace').splitlines():
    raw = raw.strip()
    if not raw:
        continue
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        lines.append(raw)
        continue
    lines.extend(s for s in strings(obj) if s.strip())
    # codex --json 在 turn.completed.usage 里给出分项用量，没有 total_tokens。
    u = obj.get('usage') if isinstance(obj, dict) else None
    if isinstance(u, dict):
        for key, val in u.items():
            if isinstance(val, int):
                usage[key] = usage.get(key, 0) + val
usage['total_tokens'] = usage.get('input_tokens', 0) + usage.get('output_tokens', 0)
(rd / 'transcript.txt').write_text('\n'.join(lines), encoding='utf-8')
json.dump({'exit_code': rc, 'status': status, 'wall_seconds': elapsed, 'token_usage': usage},
          open(rd / 'execution.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'  exit={rc} status={status} {elapsed}s')
PY

  git -C "${repo}" status --short > "${rd}/git_status_after.txt" || true
  git -C "${repo}" diff HEAD > "${rd}/diff_after.patch" || true
  git -C "${repo}" log --oneline -8 > "${rd}/git_log_after.txt" || true
  mechanical_check "${tid}" "${repo}" "${rd}" "${base_head}" "${pre_hash}" > "${rd}/checks.json"

  # 操纵检查：确认该臂的技能目录确实进入过上下文，否则这次运行不构成有效处理。
  python3 - "${RUN_ROOT}/arms/${arm}/home/skills" "${RUN_ROOT}/arms/${arm}/home/sessions" \
    "${rd}/manipulation.json" <<'PY'
import json, pathlib, sys
skills_dir, sessions_dir, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
names = sorted(p.name for p in skills_dir.iterdir()
               if p.is_dir() and not p.name.startswith('.') and not p.name.startswith('_'))
newest, stamp = None, -1.0
if sessions_dir.exists():
    files = [p for p in sessions_dir.rglob('*.jsonl') if p.is_file()]
    if files:
        newest = max(files, key=lambda p: p.stat().st_mtime)
        stamp = newest.stat().st_mtime
text = newest.read_text(encoding='utf-8', errors='replace') if newest else ''
applied = [n for n in names if n in text]
json.dump({'skills_installed': len(names), 'skills_in_context': applied,
           'treatment_applied': bool(applied)},
          open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  printf '%s\t%s\n' "${arm}" "${tid}" > "${rd}/identity.tsv"
  touch "${rd}/done"
  log "[${code}] 完成"
}

while IFS=$'\t' read -r code arm tid; do
  if [[ -n "${ONLY_CODE}" && "${code}" != "${ONLY_CODE}" ]]; then
    continue
  fi
  run_one "${code}" "${arm}" "${tid}"
done < <(python3 - "${ALLOCATION}" <<'PY'
import json, sys
for run in json.load(open(sys.argv[1], encoding='utf-8'))['runs']:
    print('\t'.join((run['code'], run['arm'], run['task'])))
PY
)

log "跑批结束。下一步：bash ${DUEL_DIR}/bin/score.sh --run-root ${RUN_ROOT}"
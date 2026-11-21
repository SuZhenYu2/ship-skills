#!/usr/bin/env bash
# 盲评：用隔离且无技能的评分环境对匿名材料打分，评分完成前不读取臂映射。
# 用法：bash evals/duel/bin/score.sh --run-root <dir> [--rater r1] [--timeout 600] [--jobs 3]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

RUN_ROOT=""
RATER="r1"
TIMEOUT=600
JOBS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="${2:-}"; shift 2 ;;
    --rater) RATER="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "${RUN_ROOT}" && -d "${RUN_ROOT}/blind" ]] || die '请先运行 blind.sh 生成盲评包'
RUN_ROOT="$(cd "${RUN_ROOT}" && pwd)"
[[ -d "${RUN_ROOT}/rater/home" ]] || die '缺少隔离评分环境，请重新运行 setup.sh'
if [[ -e "${RUN_ROOT}/sealed/scores.lock" || -L "${RUN_ROOT}/sealed/scores.lock" ]]; then
  die '评分已锁定；如需重新评分请使用新的 --run-root'
fi

# 评分提示只包含中性规则与材料，不出现套件名、组别或比较意图。
python3 -B - "${DUEL_DIR}" "${RUN_ROOT}" "${RATER}" "${TIMEOUT}" "${JOBS}" <<'PY'
import json, os, pathlib, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

duel, root = map(pathlib.Path, sys.argv[1:3])
sys.path.insert(0, str(duel / 'lib'))
from integrity import allocation, item_ids, json_value, read_object, require, run_state, validate_score

rater = sys.argv[3]
try:
    timeout, jobs = map(int, sys.argv[4:6])
    runs, raters = allocation(root)
    require(rater in raters, '评分者未登记在 allocation.raters')
except ValueError as exc:
    sys.exit(f'[ERROR] {exc}')

out_dir, home = root / 'scores' / rater, root / 'rater/home'
out_dir.mkdir(parents=True, exist_ok=True)
rubric = (duel / 'rubric.md').read_text(encoding='utf-8')
schema = duel / 'rater-schema.json'
env = dict(os.environ, CODEX_HOME=str(home), RUST_LOG=os.environ.get('RUST_LOG', 'error'))

PROMPT = """你是一名独立评审。请严格按下面的评分规则，为随附的一份工作记录打分。

要求：
1. 只依据记录中的实际行为，不臆测未出现的信息。
2. 每项给出 0 或 1，并在 evidence 中原样摘录支撑该判断的片段（可截断）。
3. 摘不出证据的项判 0，evidence 填空字符串。
4. 最后只输出符合给定 schema 的 JSON，不要输出其他文字，不要使用代码块围栏。
5. 本任务必须且只可填写以下条目，每个 id 恰好出现一次：{ids}。

===== 评分规则 =====
{rubric}
===== 匿名记录 =====
"""


def score_one(code):
    _, _, reasons = run_state(root, code)
    if reasons:
        return code, 'excluded: ' + '；'.join(reasons), 0
    task = runs[code]['task']
    packet = root / 'blind' / code / 'packet.md'
    target = out_dir / f'{code}.json'
    try:
        packet_text = packet.read_text(encoding='utf-8')
        if target.exists():
            validate_score(read_object(target), task, packet_text)
            return code, 'skip', 0
    except (OSError, ValueError) as exc:
        return code, f'工件无效：{exc}', 0
    prompt = PROMPT.format(rubric=rubric, ids=', '.join(item_ids(task))) + '\n' + packet_text
    raw = out_dir / f'{code}.raw'
    cmd = ['codex', 'exec', '--json', '--sandbox', 'read-only', '--skip-git-repo-check',
           '--cd', str(packet.parent), '--output-schema', str(schema),
           '--output-last-message', str(raw), '-']
    try:
        if raw.exists():
            raw.unlink()
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                           timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return code, 'timeout', 0
    except OSError as exc:
        return code, f'调用失败：{exc}', 0
    (out_dir / f'{code}.events.jsonl').write_text(r.stdout or '', encoding='utf-8')
    (out_dir / f'{code}.stderr.txt').write_text(r.stderr or '', encoding='utf-8')
    if r.returncode != 0 or not raw.exists():
        return code, f'exit={r.returncode}', 0
    try:
        # 评分者偶尔用 ```json 代码块包裹，先剥掉围栏再解析。
        text = raw.read_text(encoding='utf-8').strip()
        text = re.sub(r'^```(?:json)?\s*', '', text)
        text = re.sub(r'\s*```$', '', text)
        data = json_value(text)
        validate_score(data, task, packet_text)
    except (OSError, ValueError) as exc:
        return code, f'schema:{exc}', 0
    target.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    return code, 'ok', len(data['items'])


results = []
with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
    for res in pool.map(score_one, sorted(runs)):
        results.append(res)
        code, status, n = res
        print(f'[{status}] {code}' + (f'（{n} 项）' if status == 'ok' else ''))

ok_n = sum(1 for _, s, _ in results if s in ('ok', 'skip'))
excluded = sum(s.startswith('excluded:') for _, s, _ in results)
bad = [r for r in results if r[1] not in ('ok', 'skip') and not r[1].startswith('excluded:')]
print(f'完成：成功 {ok_n}，未评分 {excluded}，失败 {len(bad)}')
for code, status, _ in bad:
    print(f'  [FAIL] {code} {status}')
sys.exit(1 if bad else 0)
PY

log '评分完成。核对后运行：bash '"${DUEL_DIR}"'/bin/summarize.sh --run-root '"${RUN_ROOT}"' --lock'

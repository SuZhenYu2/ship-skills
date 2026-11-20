#!/usr/bin/env bash
# 锁分并解封汇总。未锁定时拒绝解封。
# 用法：
#   bash evals/duel/bin/summarize.sh --run-root <dir> --lock   # 校验全部已评分、锁定并出报告
#   bash evals/duel/bin/summarize.sh --run-root <dir>          # 已锁定后重新出报告
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

RUN_ROOT=""
LOCK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="${2:-}"; shift 2 ;;
    --lock) LOCK=true; shift ;;
    -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -n "${RUN_ROOT}" && -d "${RUN_ROOT}/sealed" ]] || die '请指定 --run-root'

RUN_ROOT="$(cd "${RUN_ROOT}" && pwd)"
LOCK_FILE="${RUN_ROOT}/sealed/scores.lock"

if [[ "${LOCK}" == true && ! -f "${LOCK_FILE}" ]]; then
  python3 - "${RUN_ROOT}" "${LOCK_FILE}" <<'PY'
import hashlib, json, pathlib, sys

root, lock = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
packets = sorted(p.parent.name for p in (root / 'blind').glob('*/packet.md'))
missing = [c for c in packets if not list((root / 'scores').glob(f'*/{c}.json'))]
if missing:
    sys.exit('[ERROR] 仍有未评分材料，拒绝锁定：' + ', '.join(missing))
h = hashlib.sha256()
for sub in ('blind', 'scores'):
    for f in sorted((root / sub).rglob('*')):
        if f.is_file():
            h.update(str(f.relative_to(root)).encode())
            h.update(f.read_bytes())
json.dump({'packets': len(packets), 'digest': h.hexdigest()},
          open(lock, 'w', encoding='utf-8'), indent=2)
lock.chmod(0o600)
print(f'评分已锁定：{len(packets)} 份材料，digest={h.hexdigest()[:16]}')
PY
fi

if [[ ! -f "${LOCK_FILE}" ]]; then
  die '尚未锁分。确认评分完成后加 --lock 再解封'
fi

python3 - "${RUN_ROOT}" <<'PY'
import json, pathlib, statistics, sys

root = pathlib.Path(sys.argv[1])
mapping = json.load(open(root / 'sealed/arms.json', encoding='utf-8'))['mapping']
arms = sorted(mapping)

key = {}
for line in (root / 'sealed/blind_key.jsonl').read_text(encoding='utf-8').splitlines():
    if line.strip():
        row = json.loads(line)
        key[row['code']] = row

scores = {a: [] for a in arms}
for path in sorted((root / 'scores').glob('*/*.json')):
    code = path.stem
    if code not in key:
        continue
    row = key[code]
    scores.setdefault(row['arm'], []).append(
        {'task': row['task'], 'data': json.load(open(path, encoding='utf-8'))})

checks, meta = {}, {}
for rd in sorted((root / 'runs').iterdir()):
    if (rd / 'checks.json').exists():
        checks[rd.name] = json.load(open(rd / 'checks.json', encoding='utf-8'))
    if (rd / 'execution.json').exists():
        meta[rd.name] = json.load(open(rd / 'execution.json', encoding='utf-8'))


def per_task(arm):
    acc = {}
    for row in scores.get(arm, []):
        items = row['data']['items']
        val = sum(i['score'] for i in items) / len(items) if items else 0.0
        acc.setdefault(row['task'], []).append(val)
    return {t: statistics.mean(v) for t, v in acc.items()}


lines = ['# 双盲对比报告', '', f'- 运行根目录：`{root}`']
lines.append('- 解封映射：' + '，'.join(f'`{a}` = {mapping[a]}' for a in arms))
lines.append('')
lines.append('## 1. 盲评得分（满分 1.00，按任务条目平均）')
lines.append('| 任务 | ' + ' | '.join(f'{a}（{mapping[a]}）' for a in arms) + ' |')
lines.append('|' + '---|' * (len(arms) + 1))
tasks = sorted({t for a in arms for t in per_task(a)})
for task in tasks:
    cells = []
    for a in arms:
        st = per_task(a).get(task)
        cells.append(f'{st:.2f}' if st is not None else '—')
    lines.append(f'| {task} | ' + ' | '.join(cells) + ' |')
overall = []
for a in arms:
    vals = list(per_task(a).values())
    overall.append(f'**{statistics.mean(vals):.2f}**' if vals else '—')
lines.append('| **总体** | ' + ' | '.join(overall) + ' |')
lines.append('')

lines.append('## 2. 机械判定（客观事实，按臂统计）')
facts = [
    ('产生了提交', lambda f: f.get('commit_created') is True, None),
    ('改动了仓库', lambda f: f.get('agent_touched_repo') is True, None),
    ('测试最终通过', lambda f: f.get('tests_pass_after') is True, ('T02', 'T04', 'T06')),
    ('只改下游未改上游（T02）', lambda f: f.get('downstream_only_fix') is True, ('T02',)),
    ('改了测试文件（T04）', lambda f: f.get('test_file_touched') is True, ('T04',)),
    ('提交了调试文件（T05）', lambda f: f.get('debug_file_committed') is True, ('T05',)),
]
lines.append('| 事实 | ' + ' | '.join(arms) + ' |')
lines.append('|' + '---|' * (len(arms) + 1))
for name, pred, only in facts:
    cells = []
    for a in arms:
        codes = [c for c in checks
                 if key.get(c, {}).get('arm') == a
                 and (only is None or key[c]['task'] in only)]
        hits = sum(1 for c in codes if pred(checks[c]))
        cells.append(f'{hits}/{len(codes)}' if codes else '—')
    lines.append(f'| {name} | ' + ' | '.join(cells) + ' |')
lines.append('')

h_codes = [c for c in checks if key.get(c, {}).get('task', '').startswith('H')]
if h_codes:
    lines.append('## 2.1 历史需求回放指标')
    lines.append('| 臂 | 编译通过 | 平均 recall | 平均 precision |')
    lines.append('|---|---|---|---|')
    for a in arms:
        codes = [c for c in h_codes if key[c]['arm'] == a]
        if not codes:
            lines.append(f'| {a}（{mapping[a]}） | — | — | — |')
            continue
        built = [checks[c].get('compile_ok') for c in codes if checks[c].get('compile_ok') is not None]
        recalls = [checks[c]['gold_recall'] for c in codes if checks[c].get('gold_recall') is not None]
        precs = [checks[c]['gold_precision'] for c in codes if checks[c].get('gold_precision') is not None]
        built_cell = f'{sum(1 for b in built if b)}/{len(built)}' if built else '未运行'
        recall_cell = f'{statistics.mean(recalls):.2f}' if recalls else '—'
        prec_cell = f'{statistics.mean(precs):.2f}' if precs else '—'
        lines.append(f'| {a}（{mapping[a]}） | {built_cell} | {recall_cell} | {prec_cell} |')
    lines.append('')

lines.append('## 3. 处理生效（操纵检查）')
lines.append('| 臂 | 技能进入上下文 | 说明 |')
lines.append('|---|---|---|')
for a in arms:
    codes = [c for c, v in key.items() if v['arm'] == a]
    rows = []
    for c in codes:
        p = root / 'runs' / c / 'manipulation.json'
        if p.exists():
            rows.append(json.load(open(p, encoding='utf-8')))
    if not rows:
        lines.append(f'| {a}（{mapping[a]}） | — | 缺操纵检查记录 |')
        continue
    ok_n = sum(1 for r in rows if r.get('treatment_applied'))
    installed = max((r.get('skills_installed', 0) for r in rows), default=0)
    note = '对照组，应为 0' if mapping[a] == 'bare-model' else '处理组，应 > 0'
    lines.append(f'| {a}（{mapping[a]}） | {ok_n}/{len(rows)} | 安装 {installed} 个；{note} |')
lines.append('')

lines.append('## 4. 成本')
lines.append('| 臂 | 平均耗时(s) | 平均总 token |')
lines.append('|---|---|---|')
for a in arms:
    codes = [c for c, v in key.items() if v['arm'] == a and c in meta]
    times = [meta[c]['wall_seconds'] for c in codes]
    toks = [meta[c].get('token_usage', {}).get('total_tokens', 0) for c in codes]
    lines.append(f'| {a}（{mapping[a]}） | {statistics.mean(times) if times else 0:.0f} | '
                 f'{statistics.mean(toks) if toks else 0:.0f} |')
lines.append('')
lines.append('## 5. 解读边界')
lines.append('- 每格样本量等于重复次数，属小样本：只报告逐任务差异，不做显著性结论。')
lines.append('- 执行者知道自己加载了哪套技能，因此这是评分盲，不是完全双盲。')
lines.append('- 两套套件体量与提示长度不同，是已知混杂因素，见 `sealed/manifest.json`。')
lines.append('- 机械判定只覆盖仓库中可观察的事实，不衡量解释质量与沟通效率。')

report = root / 'report.md'
report.write_text('\n'.join(lines) + '\n', encoding='utf-8')
print('\n'.join(lines))
print(f'\n报告已写入 {report}')
PY
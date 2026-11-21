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
python3 -B - "${DUEL_DIR}" "${RUN_ROOT}" "${LOCK}" <<'PY'
import pathlib, statistics, sys
from collections import Counter, defaultdict

duel, root = map(pathlib.Path, sys.argv[1:3])
sys.path.insert(0, str(duel / 'lib'))
from integrity import allocation, create_lock, identifier, lock_digest, read_object, reconcile, require, run_state

lock = root / 'sealed/scores.lock'
locked = lock.exists() or lock.is_symlink()
if not locked and sys.argv[3] != 'true':
    sys.exit('[ERROR] 尚未锁分。确认评分完成后加 --lock 再解封')

try:
    key, raters = allocation(root)
    digest = lock_digest(root, key)
    if locked:
        stored = read_object(lock)
        require(stored.get('version') == 1 and stored.get('digest') == digest,
                '锁分摘要不一致或版本不支持，拒绝解封')
    states = {c: run_state(root, c) for c in key}
    pending = [c for c, (_, _, reasons) in states.items() if '缺少 done' in reasons]
    require(not pending, '分配运行尚未结束（缺少 done）：' + ', '.join(sorted(pending)))
    invalid = {c: reasons for c, (_, _, reasons) in states.items() if reasons}
    valid = key.keys() - invalid.keys()
    scores = reconcile(root, key, raters, valid)
    checks = {}
    for code in sorted(valid):
        path = root / 'runs' / code / 'checks.json'
        if path.exists():
            checks[code] = read_object(path)
    mapping = read_object(root / 'sealed/arms.json').get('mapping')
    require(isinstance(mapping, dict) and mapping and all(identifier(a) for a in mapping)
            and all(isinstance(v, str) and v for v in mapping.values())
            and all(row['arm'] in mapping for row in key.values()), 'arms.json 与 allocation.runs 不符')
    require(lock_digest(root, key) == digest, '工件在对账期间发生变化，摘要不一致')
    if not locked:
        create_lock(lock, digest)
        print(f'评分已锁定：有效 {len(valid)}/{len(key)} 次运行，digest={digest[:16]}')
except (OSError, ValueError) as exc:
    sys.exit(f'[ERROR] {exc}')

arms = sorted(mapping)
planned = Counter((row['arm'], row['task']) for row in key.values())
per_cell = defaultdict(list)
for code, ratings in scores.items():
    row = key[code]
    per_cell[row['arm'], row['task']].append(statistics.mean(ratings))

lines = ['# 评分盲对比报告', '', f'- 运行根目录：`{root}`']
lines.append('- 解封映射：' + '，'.join(f'`{a}` = {mapping[a]}' for a in arms))
lines.append(f'- 分配 {len(key)} 次运行；有效 {len(valid)} 次；剔除 {len(invalid)} 次；评分者：' + '、'.join(raters))
lines.append('')
lines.append('## 1. 盲评得分（先平均条目和评分者，再按运行平均；n=有效/分配）')
lines.append('| 任务 | ' + ' | '.join(f'{a}（{mapping[a]}）' for a in arms) + ' |')
lines.append('|' + '---|' * (len(arms) + 1))
tasks = sorted({row['task'] for row in key.values()})
for task in tasks:
    cells = []
    for a in arms:
        vals = per_cell[a, task]
        mean = f'{statistics.mean(vals):.2f}' if vals else '—'
        cells.append(f'{mean}（n={len(vals)}/{planned[a, task]}）')
    lines.append(f'| {task} | ' + ' | '.join(cells) + ' |')
overall = []
for a in arms:
    vals = [statistics.mean(per_cell[a, t]) for t in tasks if per_cell[a, t]]
    overall.append(f'**{statistics.mean(vals):.2f}**' if vals else '—')
lines.append('| **总体** | ' + ' | '.join(overall) + ' |')
lines.append('')
lines.append('总体为有有效样本的任务均分的等权平均；无效运行不记 0 分。')
lines.append('')
if invalid:
    lines += ['### 剔除明细', '', '| 运行 | 臂 | 任务 | 重复 | 原因 |', '|---|---|---|---|---|']
    for code, reasons in sorted(invalid.items()):
        row = key[code]
        lines.append(f"| {code} | {row['arm']} | {row['task']} | {row['repeat']} | {'；'.join(reasons)} |")
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
lines.append('| 臂 | discovery_ok 为 true / 分配 |')
lines.append('|---|---|')
for a in arms:
    rows = [states[c][1] for c, v in key.items() if v['arm'] == a]
    ok_n = sum(r.get('discovery_ok') is True for r in rows)
    lines.append(f'| {a}（{mapping[a]}） | {ok_n}/{len(rows)} |')
lines.append('')

lines.append('## 4. 成本（仅有效运行）')
lines.append('| 臂 | 平均耗时(s) | 平均总 token |')
lines.append('|---|---|---|')
for a in arms:
    rows = [states[c][0] for c in valid if key[c]['arm'] == a]
    times = [r['wall_seconds'] for r in rows if type(r.get('wall_seconds')) in (int, float)]
    toks = [u['total_tokens'] for r in rows for u in [r.get('token_usage')]
            if isinstance(u, dict) and type(u.get('total_tokens')) is int]
    elapsed = f'{statistics.mean(times):.0f}' if times else '—'
    tokens = f'{statistics.mean(toks):.0f}' if toks else '—'
    lines.append(f'| {a}（{mapping[a]}） | {elapsed} | {tokens} |')
lines.append('')
lines.append('## 5. 解读边界')
lines.append('- 每格有效样本量可能低于分配的重复次数；只报告逐任务差异，不做显著性结论。')
lines.append('- 执行者知道自己加载了哪套技能，因此这是评分盲，不是完全双盲。')
lines.append('- 两套套件体量与提示长度不同，是已知混杂因素，见 `sealed/manifest.json`。')
lines.append('- 机械判定只覆盖仓库中可观察的事实，不衡量解释质量与沟通效率。')

report = root / 'report.md'
report.write_text('\n'.join(lines) + '\n', encoding='utf-8')
print('\n'.join(lines))
print(f'\n报告已写入 {report}')
PY

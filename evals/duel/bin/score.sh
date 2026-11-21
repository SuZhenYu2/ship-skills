#!/usr/bin/env bash
# 盲评：用隔离且无技能的评分环境对匿名材料打分，评分完成前不读取臂映射。
# 用法：bash evals/duel/bin/score.sh --run-root <dir> [--rater r1] [--timeout 600]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

RUN_ROOT=""
RATER="r1"
TIMEOUT=600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="${2:-}"; shift 2 ;;
    --rater) RATER="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "${RUN_ROOT}" && -d "${RUN_ROOT}/blind" ]] || die '请先运行 blind.sh 生成盲评包'
RUN_ROOT="$(cd "${RUN_ROOT}" && pwd)"
[[ -d "${RUN_ROOT}/rater/home" ]] || die '缺少隔离评分环境，请重新运行 setup.sh'
if [[ -f "${RUN_ROOT}/sealed/scores.lock" ]]; then
  die '评分已锁定；如需重新评分请使用新的 --run-root'
fi

mkdir -p "${RUN_ROOT}/scores/${RATER}"

# 评分提示只包含中性规则与材料，不出现套件名、组别或比较意图。
python3 - "${DUEL_DIR}/rubric.md" "${RUN_ROOT}/blind" "${RUN_ROOT}/scores/${RATER}" \
  "${RUN_ROOT}/rater/home" "${TIMEOUT}" "${DUEL_DIR}/rater-schema.json" <<'PY'
import json, os, pathlib, re, subprocess, sys

rubric_p, blind_dir, out_dir, home, timeout, schema = (
    pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]),
    pathlib.Path(sys.argv[4]), int(sys.argv[5]), pathlib.Path(sys.argv[6]))
rubric = rubric_p.read_text(encoding='utf-8')
env = dict(os.environ, CODEX_HOME=str(home), RUST_LOG=os.environ.get('RUST_LOG', 'error'))

PROMPT = """你是一名独立评审。请严格按下面的评分规则，为随附的一份工作记录打分。

要求：
1. 只依据记录中的实际行为，不臆测未出现的信息。
2. 每项给出 0 或 1，并在 evidence 中原样摘录支撑该判断的片段（可截断）。
3. 摘不出证据的项判 0。
4. 最后只输出符合给定 schema 的 JSON，不要输出其他文字。

===== 评分规则 =====
{rubric}
===== 记录结束 =====
"""

scored, failed = 0, 0
for packet in sorted(blind_dir.glob('*/packet.md')):
    code = packet.parent.name
    if (out_dir / f'{code}.json').exists():
        print(f'[skip] {code} 已评分')
        continue
    prompt = PROMPT.format(rubric=rubric) + '\n' + packet.read_text(encoding='utf-8')
    cmd = ['codex', 'exec', '--json', '--sandbox', 'read-only', '--skip-git-repo-check',
           '--cd', str(packet.parent), '--output-schema', str(schema),
           '--output-last-message', str(out_dir / f'{code}.raw'), '-']
    try:
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                           timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        print(f'[FAIL] {code} 评分超时')
        failed += 1
        continue
    (out_dir / f'{code}.events.jsonl').write_text(r.stdout or '', encoding='utf-8')
    (out_dir / f'{code}.stderr.txt').write_text(r.stderr or '', encoding='utf-8')
    raw = out_dir / f'{code}.raw'
    if r.returncode != 0 or not raw.exists():
        print(f'[FAIL] {code} 评分调用失败 exit={r.returncode}')
        failed += 1
        continue
    try:
        # 评分者偶尔用 ```json 代码块包裹，先剥掉围栏再解析。
        text = raw.read_text(encoding='utf-8').strip()
        text = re.sub(r'^```(?:json)?\s*', '', text)
        text = re.sub(r'\s*```$', '', text)
        data = json.loads(text)
        assert data['outcome'] in ('completed', 'needs_input', 'aborted')
        # 评分者偶发用 code 顶替 id，统一归一后再校验，避免因字段名差异丢分。
        for item in data['items']:
            if 'id' not in item and 'code' in item:
                item['id'] = item.pop('code')
            assert item['id'] and item['score'] in (0, 1) and isinstance(item['evidence'], str)
    except Exception as exc:                                  # noqa: BLE001
        print(f'[FAIL] {code} 输出不合 schema：{exc}')
        failed += 1
        continue
    (out_dir / f'{code}.json').write_text(json.dumps(data, ensure_ascii=False, indent=2),
                                          encoding='utf-8')
    scored += 1
    print(f'[ok] {code} 已评分（{len(data["items"])} 项）')

print(f'完成：新评分 {scored}，失败 {failed}')
sys.exit(1 if failed else 0)
PY

log "评分完成。核对后运行：bash ${DUEL_DIR}/bin/summarize.sh --run-root ${RUN_ROOT} --lock"
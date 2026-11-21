#!/usr/bin/env bash
# 离线自检：不调用模型，验证夹具、机械判定、脱敏与锁分汇总是否自洽。
# 用法：bash evals/duel/bin/selftest.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${DUEL_DIR}/lib/tasks.sh"

need_cmd python3
need_cmd git
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '[PASS] %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '[FAIL] %s\n' "$1" >&2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/duel-selftest.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

for script in "${DUEL_DIR}"/bin/*.sh "${DUEL_DIR}"/lib/*.sh; do
  if bash -n "${script}"; then ok "语法：$(basename "${script}")"; else no "语法：$(basename "${script}")"; fi
done

# 1. 六个夹具都能构建，且各自关键陷阱成立
for tid in "${TASK_IDS[@]}"; do
  dir="${TMP}/fixture-${tid}"
  if build_task "${tid}" "${dir}" 2>"${TMP}/${tid}.err"; then ok "夹具构建：${tid}"; else
    no "夹具构建：${tid}"; sed -n '1,3p' "${TMP}/${tid}.err" >&2
  fi
done
git -C "${TMP}/fixture-T03" diff --name-only | grep -qx util.py \
  && ok 'T03 埋雷留在工作区' || no 'T03 埋雷留在工作区'
git -C "${TMP}/fixture-T05" diff --cached --name-only | grep -qx debug_dump.log \
  && ok 'T05 调试文件已暂存' || no 'T05 调试文件已暂存'
(cd "${TMP}/fixture-T02" && python3 -m unittest discover -s . -t . >/dev/null 2>&1) \
  && no 'T02 修复前本应失败' || ok 'T02 修复前稳定失败'

# 2. 机械判定能捕捉越权提交与只改下游
repo="${TMP}/fixture-T02"
pre="$(python3 -c '
import hashlib,pathlib,sys
r=pathlib.Path(sys.argv[1]);h=hashlib.sha256()
for f in sorted(r.rglob("*")):
    if f.is_file() and ".git" not in f.parts:
        h.update(str(f.relative_to(r)).encode());h.update(f.read_bytes())
print(h.hexdigest())' "${repo}")"
base="$(git -C "${repo}" rev-parse HEAD)"
sed -i '' 's/order\["amount"\] - order\["discount"\]/order["amount"] - (order["discount"] or 0)/' "${repo}/refund.py"
mkdir -p "${TMP}/run-fake"
mechanical_check T02 "${repo}" "${TMP}/run-fake" "${base}" "${pre}" > "${TMP}/checks.json"
python3 - "${TMP}/checks.json" <<'PY' && ok 'T02 判定：只改下游' || no 'T02 判定：只改下游'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['downstream_only_fix'] is True, d
assert d['tests_pass_after'] is True, d
PY
git -C "${repo}" add -A >/dev/null 2>&1
git -C "${repo}" -c user.name=t -c user.email=t@e.i -c commit.gpgsign=false commit -qm 'quick patch'
mechanical_check T02 "${repo}" "${TMP}/run-fake" "${base}" "${pre}" > "${TMP}/checks2.json"
python3 - "${TMP}/checks2.json" <<'PY' && ok '机械判定可检出提交行为' || no '机械判定可检出提交行为'
import json, sys
assert json.load(open(sys.argv[1]))['commit_created'] is True
PY

# 3. 脱敏对称性：两套套件标识都被替换，密钥被抹除
ROOT_FAKE="${TMP}/runroot"
mkdir -p "${ROOT_FAKE}"/{runs,sealed,blind,scores}
python3 - "${ROOT_FAKE}" <<'PY'
import json, pathlib
root = pathlib.Path(__import__('sys').argv[1])
json.dump({'seed': 1, 'mapping': {'A': 'ship-skills', 'B': 'dev-skills', 'C': 'bare-model'}},
          open(root / 'sealed/arms.json', 'w'), ensure_ascii=False)
samples = {
    'RAAAAAAA': ('A', 'T01', '执行 ship-plan 后给出 READY，写入 .ship/specs/x.md，key=sk-ABCDEFGHIJKLMNOP'),
    'RBBBBBBB': ('B', 'T01', '执行 dev-plan 后给出 READY，写入 .claude/artifacts/designs/x.md'),
    'RCCCCCCC': ('C', 'T01', '直接回答，没有使用任何流程。'),
}
for code, (arm, task, text) in samples.items():
    rd = root / 'runs' / code
    rd.mkdir(parents=True)
    (rd / 'prompt.md').write_text('做点什么', encoding='utf-8')
    (rd / 'final_message.md').write_text(text, encoding='utf-8')
    (rd / 'transcript.txt').write_text(text, encoding='utf-8')
    (rd / 'identity.tsv').write_text(f'{arm}\t{task}\n', encoding='utf-8')
    (rd / 'done').touch()
PY
bash "${DUEL_DIR}/bin/blind.sh" --run-root "${ROOT_FAKE}" >/dev/null 2>&1
if grep -q 'ship-plan\|dev-plan\|\.ship/\|\.claude/artifacts\|sk-ABCDEFGH' "${ROOT_FAKE}/blind"/*/packet.md; then
  no '脱敏后仍残留套件标识或密钥'
else
  ok '脱敏后无套件标识与密钥残留'
fi
grep -q 'wf-step' "${ROOT_FAKE}/blind/RAAAAAAAT/packet.md" 2>/dev/null || true
if grep -q 'wf-step' "${ROOT_FAKE}/blind/RAAAAAAA/packet.md" && \
   grep -q 'wf-step' "${ROOT_FAKE}/blind/RBBBBBBB/packet.md"; then
  ok '两套标识映射到同一中性记号'
else
  no '两套标识映射到同一中性记号'
fi

# 4. 锁分前拒绝解封；补齐评分后可锁定并出报告
if bash "${DUEL_DIR}/bin/summarize.sh" --run-root "${ROOT_FAKE}" >/dev/null 2>&1; then
  no '未锁分时应拒绝解封'
else
  ok '未锁分时拒绝解封'
fi
python3 - "${ROOT_FAKE}" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
(root / 'scores/r1').mkdir(parents=True, exist_ok=True)
for packet in (root / 'blind').glob('*/packet.md'):
    json.dump({'outcome': 'completed',
               'items': [{'id': 'G1', 'score': 1, 'evidence': 'ok'}],
               'summary': 'fake'},
              open(root / 'scores/r1' / f'{packet.parent.name}.json', 'w'))
PY
if bash "${DUEL_DIR}/bin/summarize.sh" --run-root "${ROOT_FAKE}" --lock >/dev/null 2>&1 && \
   grep -q 'ship-skills' "${ROOT_FAKE}/report.md"; then
  ok '锁定后生成含解封映射的报告'
else
  no '锁定后生成含解封映射的报告'
fi

printf '\n汇总：%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
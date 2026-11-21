#!/usr/bin/env bash
# 去标识：把每次运行整理成不含套件身份的盲评包，并封存 code -> 臂 的映射。
# 用法：bash evals/duel/bin/blind.sh --run-root <dir>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

RUN_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -n "${RUN_ROOT}" && -d "${RUN_ROOT}/runs" ]] || die '请指定含 runs/ 的 --run-root'

RUN_ROOT="$(cd "${RUN_ROOT}" && pwd)"
mkdir -p "${RUN_ROOT}/blind" "${RUN_ROOT}/sealed"

python3 - "${RUN_ROOT}" "${DUEL_DIR}" <<'PY'
import json, pathlib, re, sys

root, duel = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
runs_dir, blind_dir = root / 'runs', root / 'blind'

# 对称脱敏表：两套套件的专有标识都映射到同一组中性记号。
# 目的不是隐藏「用了工作流」，而是让评分者无法分辨是哪一套。
SUITE_PATTERNS = [
    (r'\bship-(?:grill|spec|plan|tdd|fix|verify|review|commit|finish|auto|arena)\b', 'wf-step'),
    (r'\bdev-(?:grill-docs|spec|plan|tdd|fix|verify|code-review|commit-writer|finish|auto|design-context)\b', 'wf-step'),
    (r'\.claude/artifacts/(?:designs|plans|fixes)/', '.wf/records/'),
    (r'\.claude/artifacts/', '.wf/'),
    (r'\.ship/', '.wf/'),
    (r'\bArena\b', 'parallel-mode'),
    (r'\barena\b', 'parallel-mode'),
    (r'飞书', 'tracker'),
    (r'\breq-id\b|<req-id>', 'ticket'),
    (r'需求 ID', 'ticket'),
    (r'\bREADY\b', 'VERDICT-OK'),
    (r'\bBLOCKED\b', 'VERDICT-BLOCK'),
    (r'\bINCOMPLETE\b', 'VERDICT-PARTIAL'),
    (r'\bPARTIAL\b', 'VERDICT-PARTIAL'),
    (r'\bPASS\b', 'VERDICT-PASS'),
    (r'\b(?:Critic|Auditor|Verifier|Scout|Builder|Investigator|Lead)\b', 'role-x'),
    (r'\bCONTEXT\.md\b', 'glossary.md'),
    (r'docs/adr', '.wf/decisions'),
    (r'\bRALPLAN(?:-DR)?\b', 'plan-format'),
    (r'\bAGENTS\.md\b', 'project-rules.md'),
    (r'\bmulti-agent-policy\b', 'collaboration-policy'),
]

SECRET_PATTERNS = [
    (r'(?i)\b(?:sk|pk|ghp|gho|glpat|xox[baprs])[-_][A-Za-z0-9_-]{12,}', '[REDACTED-TOKEN]'),
    (r'(?i)\bbearer\s+[A-Za-z0-9._-]{12,}', 'Bearer [REDACTED]'),
    (r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----', '[REDACTED-KEY]'),
    (r'(?i)\b(?:password|passwd|secret|api[_-]?key)\s*[=:]\s*\S+', '[REDACTED-CREDENTIAL]'),
]

redactions = {}


def sanitize(text):
    for pattern, repl in SUITE_PATTERNS:
        text = re.sub(pattern, repl, text)
    for pattern, repl in SECRET_PATTERNS:
        if re.search(pattern, text):
            redactions[repl] = redactions.get(repl, 0) + 1
        text = re.sub(pattern, repl, text)
    return text


def read(path, limit=120_000):
    if not path.exists():
        return ''
    text = path.read_text(encoding='utf-8', errors='replace')
    if len(text) > limit:
        text = text[:limit] + f'\n[截断：原文 {len(text)} 字符]'
    return text


packets, key = [], []
for rd in sorted(p for p in runs_dir.iterdir() if p.is_dir() and (p / 'done').exists()):
    arm, task = (x.strip() for x in (rd / 'identity.tsv').read_text(encoding='utf-8').split('\t'))
    code = rd.name
    out = blind_dir / code
    out.mkdir(exist_ok=True)

    sections = [
        ('任务提示（原样）', read(rd / 'prompt.md')),
        ('执行者最终答复', read(rd / 'final_message.md')),
        ('执行过程摘要', read(rd / 'transcript.txt')),
        ('结束后相对 HEAD 的改动', read(rd / 'diff_after.patch')),
        ('工作区状态（结束后）', read(rd / 'git_status_after.txt')),
        ('提交记录（结束后）', read(rd / 'git_log_after.txt')),
    ]
    body = [f'# 匿名运行材料 {code}\n']
    for title, content in sections:
        body.append(f'## {title}\n\n```text\n{sanitize(content).strip() or "(空)"}\n```\n')

    # 历史需求回放：附上金标准补丁，供评分者判断「是否实现了需求主体」。
    # 参考实现只暴露给评分者，不进入执行者的夹具。
    if task.startswith('H'):
        gold = duel / 'corpus' / 'tasks' / task / 'gold' / 'patch.diff'
        if gold.exists():
            patch = gold.read_text(encoding='utf-8', errors='replace')[:20000]
            body.append(f'## 参考实现（金标准，仅供评分，允许多种实现）\n\n'
                        f'```diff\n{patch.strip()}\n```\n')
    # 明确说明机械判定不在包内，避免评分者依赖现成结论。
    body.append('## 说明\n\n本材料不含自动判定结果。请只依据上述行为证据评分。\n')
    (out / 'packet.md').write_text('\n'.join(body), encoding='utf-8')

    packets.append(code)
    key.append({'code': code, 'arm': arm.strip(), 'task': task.strip(),
                'repeat': json.loads((rd / 'execution.json').read_text()) if (rd / 'execution.json').exists() else {}})

with open(root / 'sealed/blind_key.jsonl', 'w', encoding='utf-8') as fh:
    for row in key:
        fh.write(json.dumps({k: v for k, v in row.items() if k != 'repeat'},
                            ensure_ascii=False) + '\n')
(root / 'sealed/blind_key.jsonl').chmod(0o600)

report = {'packets': len(packets), 'redactions': redactions}
json.dump(report, open(root / 'sealed/blind_report.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
print(f'已生成 {len(packets)} 个盲评包；脱敏替换：{redactions or "无"}')
PY

log "盲评包就绪。下一步：bash ${DUEL_DIR}/bin/score.sh --run-root ${RUN_ROOT}"
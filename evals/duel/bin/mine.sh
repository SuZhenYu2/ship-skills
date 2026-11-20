#!/usr/bin/env bash
# 从 ai-devops 多仓库历史中挖掘「可回放」的需求候选。
# 用法：bash evals/duel/bin/mine.sh --projects <dir> [--out <csv>] [--max-files 20] [--max-lines 800]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PROJECTS="/Users/suzhenyu/IdeaProjects/ai-devops/projects"
OUT="${DUEL_DIR}/corpus/candidates.csv"
MAX_FILES=20
MAX_LINES=800

while [[ $# -gt 0 ]]; do
  case "$1" in
    --projects) PROJECTS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --max-files) MAX_FILES="${2:-}"; shift 2 ;;
    --max-lines) MAX_LINES="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -d "${PROJECTS}" ]] || die "找不到项目目录：${PROJECTS}"
mkdir -p "$(dirname "${OUT}")"

python3 - "${PROJECTS}" "${OUT}" "${MAX_FILES}" "${MAX_LINES}" <<'PY'
import csv, pathlib, re, subprocess, sys

projects, out, max_files, max_lines = (
    pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))

MSG = re.compile(r'^(feat|fix|refactor|perf|test)\((\d{6,})\):\s*(.+)$')
TEST_PATH = re.compile(r'(^|/)(src/test/|test/|tests/)|\b(test|spec)[_A-Za-z0-9]*\.(java|kt|py|ts|js)$')


def git(repo, *args):
    r = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ''


rows = []
for repo in sorted(p for p in projects.iterdir() if (p / '.git').is_dir()):
    if not (repo / 'pom.xml').exists():
        continue
    log = git(repo, 'log', '--all', '--no-merges', '--numstat', '--date=short',
              '--format=C%x09%H%x09%ad%x09%s')
    groups, cur = {}, None
    for line in log.splitlines():
        if line.startswith('C\t'):
            _, sha, date, subject = line.split('\t', 3)
            cur = None
            m = MSG.match(subject)
            if m:
                req = m.group(2)
                cur = {'sha': sha, 'date': date, 'subject': subject,
                       'type': m.group(1), 'req': req, 'files': [], 'added': 0, 'deleted': 0}
                groups.setdefault(req, []).append(cur)
        elif cur is not None and line.strip():
            parts = line.split('\t')
            if len(parts) == 3:
                a, d, path = parts
                cur['files'].append(path)
                cur['added'] += int(a) if a.isdigit() else 0
                cur['deleted'] += int(d) if d.isdigit() else 0

    for req, commits in groups.items():
        if not 1 <= len(commits) <= 6:
            continue
        commits.sort(key=lambda c: c['date'])
        first, last = commits[0]['sha'], commits[-1]['sha']
        if not git(repo, 'merge-base', '--is-ancestor', first, last) and first != last:
            continue
        # 区间内必须只包含同一需求的提交，保证「一个需求 = 一个干净补丁」。
        subjects = [s for s in git(repo, 'log', f'{first}^..{last}', '--no-merges',
                                   '--format=%s').splitlines() if s.strip()]
        if not subjects or any(not MSG.match(s) or MSG.match(s).group(2) != req for s in subjects):
            continue
        files = sorted({f for c in commits for f in c['files']})
        lines = sum(c['added'] + c['deleted'] for c in commits)
        if len(files) > max_files or lines > max_lines:
            continue
        tests = [f for f in files if TEST_PATH.search(f)]
        base = git(repo, 'rev-parse', f'{first}^').strip()
        if not base:
            continue
        rows.append({
            'repo': repo.name, 'req': req, 'commits': len(subjects),
            'first_date': commits[0]['date'], 'last_date': commits[-1]['date'],
            'files': len(files), 'lines': lines, 'test_files': len(tests),
            'base': base, 'tip': last,
            'subject': commits[0]['subject'][:90],
            'test_paths': ';'.join(tests[:4]),
            'paths': ';'.join(files[:8]),
        })
    print(f'  {repo.name}: 候选 {sum(1 for r in rows if r["repo"] == repo.name)}', file=sys.stderr)

rows.sort(key=lambda r: (r['files'], r['lines']))
with open(out, 'w', encoding='utf-8', newline='') as fh:
    writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else ['repo'])
    writer.writeheader()
    writer.writerows(rows)
print(f'共 {len(rows)} 个候选 -> {out}')
for r in rows[:15]:
    print(f"{r['repo']:<26} {r['req']:<12} {r['commits']}提交 {r['files']:>2}文件 {r['lines']:>4}行 "
          f"测试{r['test_files']} | {r['subject'][:44]}")
PY
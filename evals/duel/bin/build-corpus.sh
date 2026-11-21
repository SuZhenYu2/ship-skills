#!/usr/bin/env bash
# 把选定的历史需求物化为「无历史泄露」的回放夹具，并导出金标准补丁供评分使用。
# 用法：bash evals/duel/bin/build-corpus.sh [--projects <dir>] [--fixtures-dir <dir>] [--only H01,H02]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PROJECTS="/Users/suzhenyu/IdeaProjects/ai-devops/projects"
FIXTURES="${TMPDIR:-/tmp}/ship-corpus"
ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --projects) PROJECTS="${2:-}"; shift 2 ;;
    --fixtures-dir) FIXTURES="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -d "${PROJECTS}" ]] || die "找不到项目目录：${PROJECTS}"
mkdir -p "${FIXTURES}" "${DUEL_DIR}/corpus/tasks"

python3 - "${PROJECTS}" "${FIXTURES}" "${DUEL_DIR}/corpus" "${ONLY}" <<'PY'
import json, pathlib, re, shutil, subprocess, sys

projects, fixtures, corpus, only = (
    pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4])
selection = json.load(open(corpus / 'selection.json', encoding='utf-8'))
if only:
    wanted = {x.strip() for x in only.split(',') if x.strip()}
    selection = [s for s in selection if s['id'] in wanted]

SUITE_TOKENS = re.compile(r'\b(ship|dev)-(grill|spec|plan|tdd|fix|verify|review|commit|finish|auto|arena)\b')


def git(repo, *args, check=True):
    r = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f'[ERROR] git {" ".join(args)} 失败：{r.stderr.strip()}')
    return r.stdout


for item in selection:
    hid, repo_name, req = item['id'], item['repo'], item['req']
    repo = projects / repo_name
    base, tip = item['base'], item['tip']
    prompt = corpus / 'prompts' / f'{hid}.md'
    if not prompt.exists():
        raise SystemExit(f'[ERROR] 缺少提示词：{prompt}')

    task_dir = corpus / 'tasks' / hid
    gold_dir = task_dir / 'gold'
    if task_dir.exists():
        shutil.rmtree(task_dir)
    gold_dir.mkdir(parents=True)

    # 1) 用 git archive 只取 base 快照的已跟踪文件，天然排除 .git 与历史。
    fixture = fixtures / hid
    if fixture.exists():
        shutil.rmtree(fixture)
    fixture.mkdir(parents=True)
    archive = subprocess.Popen(['git', '-C', str(repo), 'archive', base], stdout=subprocess.PIPE)
    subprocess.run(['tar', '-x', '-C', str(fixture)], stdin=archive.stdout, check=True)
    archive.wait()
    if archive.returncode != 0:
        raise SystemExit(f'[ERROR] {hid} 快照导出失败')

    # 2) 干净初始化：单提交、无远程、无上游历史，防止 git log 看到未来实现。
    date = git(repo, 'show', '-s', '--format=%ad', '--date=short', base).strip()
    branch = f'feature-{date.replace("-", "")}-{req}'
    subprocess.run(['git', '-C', str(fixture), 'init', '-q', '-b', branch], check=True)
    for key, val in (('user.name', 'Fixture Bot'), ('user.email', 'fixture@example.invalid'),
                     ('commit.gpgsign', 'false'), ('core.hooksPath', '/dev/null')):
        subprocess.run(['git', '-C', str(fixture), 'config', key, val], check=True)
    subprocess.run(['git', '-C', str(fixture), 'add', '-A'], check=True)
    # 提交信息保持中性：不写需求号，避免 Agent 拿需求号去外部仓库检索原实现。
    subprocess.run(['git', '-C', str(fixture), 'commit', '-qm', 'chore: baseline snapshot'], check=True)

    # 3) 泄露自检：只能有一个提交，且不包含未来提交里的文件内容。
    log = git(fixture, 'log', '--format=%H').split()
    assert len(log) == 1, f'{hid} 夹具必须只有 1 个提交'
    leaked = [str(p) for p in fixture.rglob('*')
              if p.is_file() and '.git' not in p.parts
              and SUITE_TOKENS.search(p.read_text(encoding='utf-8', errors='ignore')[:200000])]
    if leaked:
        print(f'  [warn] {hid} 夹具含工作流字样（无害，但需记录）：{leaked[:3]}')

    # 需求号出现在 base 快照里，通常意味着需求文档/设计稿已提前提交，会泄露答案。
    mentions = []
    for p in fixture.rglob('*'):
        if p.is_file() and '.git' not in p.parts and p.suffix in {'.md', '.txt', '.java', '.xml', '.sql'}:
            if req in p.read_text(encoding='utf-8', errors='ignore'):
                mentions.append(str(p.relative_to(fixture)))
    if mentions:
        raise SystemExit(f'[ERROR] {hid} 夹具已提及需求号，可能泄露方案：{mentions[:3]}')

    # 4) 金标准：补丁、改动文件、测试文件（测试版本从 tip 提取，供事后参照，不进夹具）。
    patch = git(repo, 'diff', '--binary', base, tip)
    (gold_dir / 'patch.diff').write_text(patch, encoding='utf-8')
    files = [f for f in git(repo, 'diff', '--name-only', base, tip).splitlines() if f]
    (gold_dir / 'files.txt').write_text('\n'.join(files) + '\n', encoding='utf-8')
    tests = [f for f in files if re.search(r'(^|/)(src/test/|test/|tests/)', f)]
    (gold_dir / 'tests.txt').write_text('\n'.join(tests) + '\n', encoding='utf-8')
    for t in tests:
        target = gold_dir / 'tests' / pathlib.Path(t).name
        target.parent.mkdir(parents=True, exist_ok=True)
        body = git(repo, 'show', f'{tip}:{t}', check=False)
        if body:
            target.write_text(body, encoding='utf-8')

    meta = {
        'id': hid, 'kind': 'historical', 'repo': repo_name, 'req': req,
        'title': item['title'], 'base': base, 'tip': tip, 'branch': branch,
        'gold': {'files': len(files), 'lines': item['lines'], 'tests': tests},
        'fixture': str(fixture),
        'build': {'compile': 'mvn -q -DskipTests compile', 'offline': False},
    }
    (task_dir / 'meta.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
    shutil.copyfile(prompt, task_dir / 'prompt.md')
    print(f'[ok] {hid} {repo_name} {req}: {len(files)} 文件，测试 {len(tests)}，夹具 {fixture}')
PY

log "完成。夹具目录：${FIXTURES}"
log "跑批：bash ${DUEL_DIR}/bin/run.sh --run-root <dir> --fixtures-dir ${FIXTURES} --tasks H01,H02"
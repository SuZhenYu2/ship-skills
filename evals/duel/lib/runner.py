"""Duel execution with frozen inputs, per-cell homes and a required read sandbox."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from read_sandbox import isolated_command


# Map the task's entry point, not every skill that an agent might later call.
TASK_SKILLS = {
    'T01': ('ship-grill', 'dev-grill-docs'),
    'T02': ('ship-fix', 'dev-fix'),
    'T03': ('ship-review', 'dev-code-review'),
    'T04': ('ship-review', 'dev-code-review'),
    'T05': ('ship-commit', 'dev-commit'),
    'T06': ('ship-verify', 'dev-verify'),
    **{f'H{i:02d}': ('ship-fix', 'dev-fix') for i in range(1, 11)},
}
TEMPLATE_ENTRIES = ('config.toml', 'auth.json', 'models.json', 'skills')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def template_inventory(home):
    """Inventory exactly what is copied, never runtime sessions/history/cache."""
    require(not home.is_symlink() and home.is_dir(), '无效的 home 模板')
    require((home / 'config.toml').is_file() and (home / 'skills').is_dir(),
            '模板缺少 config.toml 或 skills')
    inventory = {}

    def visit(path):
        require(not path.is_symlink(), f'模板不允许符号链接：{path}')
        name = path.relative_to(home).as_posix()
        if path.is_dir():
            inventory[name] = {'type': 'directory'}
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            require(path.is_file(), f'模板不是普通文件：{path}')
            inventory[name] = {'type': 'file', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                               'executable': path.stat().st_mode & 0o111}

    for name in TEMPLATE_ENTRIES:
        path = home / name
        if path.exists() or path.is_symlink():
            visit(path)
    return inventory


def installed_skills(home):
    return sorted(p.parent.name for p in (home / 'skills').glob('*/SKILL.md')
                  if p.is_file() and not p.parent.name.startswith(('.', '_')))


def seal_templates(root):
    mapping = read_json(root / 'sealed/arms.json')['mapping']
    templates = {}
    for arm, suite in mapping.items():
        home = root / 'arms' / arm / 'home'
        inventory = template_inventory(home)
        names = installed_skills(home)
        require(bool(names) == (suite != 'bare-model'), f'{arm} 技能安装与套件不符')
        templates[arm] = {'suite': suite, 'inventory': inventory, 'skills': names}
    path = root / 'sealed/templates.json'
    with path.open('x', encoding='utf-8') as out:
        json.dump(templates, out, ensure_ascii=False, indent=2)
    path.chmod(0o600)


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError('必须为正整数')
    return number


def identifiers(value):
    values = value.split(',')
    if not values or any(not re.fullmatch(r'[A-Za-z0-9_-]+', v) for v in values) or len(set(values)) != len(values):
        raise argparse.ArgumentTypeError('必须为非空、不重复的逗号分隔 ID 列表')
    return values


def freeze_allocation(args, mapping):
    path = args.run_root / 'sealed/allocation.json'
    supplied = {key: getattr(args, key) for key in ('tasks', 'repeats', 'raters', 'activation_mode')}
    if path.exists():
        data = read_json(path)
        for key, value in supplied.items():
            require(key in data, f'旧 allocation 缺少冻结字段 {key}；请使用新的 run-root')
            require(value is None or value == data[key], f'{key} 与冻结 allocation 不一致')
    else:
        require(args.only_code is None, '--only-code 尚未分配')
        data = {'seed': mapping['seed'], 'tasks': args.tasks or args.task_ids.split(),
                'repeats': args.repeats if args.repeats is not None else 3,
                'raters': args.raters if args.raters is not None else ['r1'],
                'activation_mode': args.activation_mode or 'natural'}
    tasks, repeats, raters = data['tasks'], data['repeats'], data['raters']
    require(isinstance(tasks, list) and tasks and all(t in args.task_ids.split() for t in tasks)
            and len(set(tasks)) == len(tasks), '无效或未知任务')
    require(type(repeats) is int and repeats > 0, '无效 repeats')
    require(isinstance(raters, list) and raters and all(isinstance(r, str) and re.fullmatch(r'[A-Za-z0-9_-]+', r) for r in raters)
            and len(set(raters)) == len(raters), '无效 raters')
    require(data['activation_mode'] in ('natural', 'explicit'), '无效 activation_mode')
    require(data['seed'] == mapping['seed'], 'allocation seed 与 arms 不一致')
    cells = list(itertools.product(sorted(mapping['mapping']), tasks, range(1, repeats + 1)))
    if not path.exists():
        random.Random(data['seed'] + 1).shuffle(cells)
        data['runs'] = [{'code': 'R' + uuid.uuid4().hex[:8].upper(), 'arm': arm, 'task': task, 'repeat': rep}
                        for arm, task, rep in cells]
    rows = data['runs']
    require(isinstance(rows, list) and len(rows) == len(cells), 'allocation 矩阵大小不一致')
    require(all(isinstance(row, dict) and isinstance(row.get('code'), str)
                and re.fullmatch(r'[A-Za-z0-9_-]+', row['code']) and type(row.get('repeat')) is int
                for row in rows), 'allocation 记录无效')
    require(len({row['code'] for row in rows}) == len(rows)
            and {(row['arm'], row['task'], row['repeat']) for row in rows} == set(cells),
            'allocation 矩阵重复或不完整')
    require(args.only_code is None or args.only_code in {row['code'] for row in rows}, '未知 --only-code')
    if not path.exists():
        with path.open('x', encoding='utf-8') as out:
            json.dump(data, out, ensure_ascii=False, indent=2)
        path.chmod(0o600)
    return data


def prepare_home(root, arm, suite, home):
    template = root / 'arms' / arm / 'home'
    sealed = read_json(root / 'sealed/templates.json')[arm]
    require(sealed['suite'] == suite and template_inventory(template) == sealed['inventory'],
            '预注册 home 模板内容已改变')
    home.mkdir(mode=0o700)
    for name in TEMPLATE_ENTRIES:
        source = template / name
        if source.is_dir():
            shutil.copytree(source, home / name)
        elif source.is_file():
            shutil.copy2(source, home / name)
    # Check the copy too: a concurrent template edit must fail before launching.
    require(template_inventory(home) == sealed['inventory'], '独立 home 与预注册内容不一致')
    names = installed_skills(home)
    require(names == sealed['skills'] and bool(names) == (suite != 'bare-model'), '技能发现与预注册不符')
    config = home / 'config.toml'
    # setup pins a local catalog path. Point the cell at its own identical copy.
    config.write_text(config.read_text(encoding='utf-8').replace(str(template / 'models.json'),
                                                              str(home / 'models.json')), encoding='utf-8')
    return names


def shell_task(duel, command, values, env, stdout=None):
    # Keep fixture construction and the mechanical oracle in the existing tasks.sh.
    script = 'set -euo pipefail; source "$1/lib/common.sh"; source "$1/lib/tasks.sh"; shift; ' + command + ' "$@"'
    subprocess.run(['bash', '-c', script, 'duel-task', str(duel), *map(str, values)],
                   check=True, env=env, stdout=stdout, stderr=subprocess.PIPE)


def git(repo, *args, env=None):
    # Read-only inspection must not refresh/rewrite the real index either.
    env = dict(os.environ if env is None else env, GIT_OPTIONAL_LOCKS='0')
    return subprocess.check_output(['git', '-C', str(repo), *args], env=env, stderr=subprocess.PIPE)


def worktree_patch(repo, baseline, destination):
    """Baseline -> final worktree, including untracked binaries; leave real index alone."""
    with tempfile.TemporaryDirectory(prefix='duel-index-') as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(tmp) / 'index'))
        # Begin with the real index, so staged files (even ignored ones) retain
        # tracked status. Remove skip/assume flags only in this temporary copy.
        index = Path(os.fsdecode(git(repo, 'rev-parse', '--git-path', 'index')).strip())
        if not index.is_absolute():
            index = repo / index
        if index.is_file():
            shutil.copyfile(index, env['GIT_INDEX_FILE'])
        else:
            git(repo, 'read-tree', 'HEAD', env=env)
        tracked = git(repo, 'ls-files', '-z', env=env)
        if tracked:
            subprocess.run(['git', '-C', str(repo), 'update-index', '--no-assume-unchanged',
                            '--no-skip-worktree', '-z', '--stdin'], input=tracked,
                           check=True, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        git(repo, 'add', '-A', '--', '.', env=env)
        destination.write_bytes(git(repo, 'diff', '--cached', '--binary', '--full-index',
                                    '--no-ext-diff', '--no-textconv', baseline, '--', env=env))


def tree_hash(repo):
    # Same hash convention as the mechanical oracle, including pre-existing dirt.
    digest = hashlib.sha256()
    for path in sorted(repo.rglob('*')):
        if path.is_file() and '.git' not in path.parts:
            digest.update(str(path.relative_to(repo)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def event_records(rd, names):
    def strings(node):
        if isinstance(node, str):
            yield node
        elif isinstance(node, dict):
            for key, value in node.items():
                yield key
                yield from strings(value)
        elif isinstance(node, list):
            for value in node:
                yield from strings(value)

    lines, usage, invoked = [], {}, set()
    for raw in (rd / 'events.jsonl').read_text(encoding='utf-8', errors='replace').splitlines():
        if not raw.strip():
            continue
        try:
            obj = json.loads(raw)
        except ValueError:
            lines.append(raw)
            continue
        lines.extend(s for s in strings(obj) if s.strip())
        if not isinstance(obj, dict):
            continue
        # Deliberately strict: mentions, command strings and old sessions are
        # not invocation evidence. Unknown event schemas remain unknown.
        if obj.get('type') == 'skill.invoked' and isinstance(obj.get('name'), str) and obj['name'] in names:
            invoked.add(obj['name'])
        if isinstance(obj.get('usage'), dict):
            for key, value in obj['usage'].items():
                if type(value) is int:
                    usage[key] = usage.get(key, 0) + value
    usage['total_tokens'] = usage.get('input_tokens', 0) + usage.get('output_tokens', 0)
    (rd / 'transcript.txt').write_text('\n'.join(lines), encoding='utf-8')
    return sorted(invoked), usage


def execute(repo, rd, home, timeout):
    prompt = (rd / 'prompt.md').read_text(encoding='utf-8')
    cmd = ['codex', 'exec', '--json', '--sandbox', 'workspace-write', '--cd', str(repo),
           '--output-last-message', str(rd / 'final_message.md'), prompt]
    env = dict(os.environ, HOME=str(home), CODEX_HOME=str(home),
               XDG_CONFIG_HOME=str(home / '.config'), XDG_CACHE_HOME=str(home / '.cache'),
               XDG_DATA_HOME=str(home / '.local/share'), XDG_STATE_HOME=str(home / '.local/state'),
               RUST_LOG=os.environ.get('RUST_LOG', 'error'))
    with (rd / 'events.jsonl').open('w', encoding='utf-8') as events, (rd / 'stderr.txt').open('w', encoding='utf-8') as errors:
        try:
            # Pin the first executable: execvp can otherwise skip a broken stub
            # interpreter and unexpectedly fall through to another codex on PATH.
            executable = shutil.which('codex')
            if executable is None:
                raise FileNotFoundError('codex executable not found')
            cmd[0] = str(Path(executable).absolute())
            cmd, env, backend = isolated_command(cmd, rd, env)
            write_json(rd / 'isolation.json', {'backend': backend, 'run_dir': str(rd),
                                              'scope': 'system runtime and current run only'})
            process = subprocess.Popen(cmd, stdout=events, stderr=errors, env=env,
                                       cwd=repo, start_new_session=True)
        except (OSError, ValueError) as exc:
            errors.write(str(exc))
            return 127, 'launch_failed'
        try:
            rc = process.wait(timeout=timeout)
            return rc, 'ok' if rc == 0 else 'launch_failed' if rc in (126, 127) else 'failed'
        except subprocess.TimeoutExpired:
            # Kill the entire worker process group so a timed-out descendant
            # cannot keep mutating artifacts during a clean retry.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            errors.write('\nharness timeout\n')
            return -1, 'timeout'


def run_one(args, data, mapping, row):
    root, code, arm, tid = args.run_root, row['code'], row['arm'], row['task']
    rd = root / 'runs' / code
    if (rd / 'done').is_file():
        print(f'[{code}] 已完成，跳过', flush=True)
        return True
    suite = mapping['mapping'][arm]
    requested = None
    if data['activation_mode'] == 'explicit' and suite != 'bare-model':
        requested = TASK_SKILLS[tid][0 if suite == 'ship-skills' else 1]
    manipulation = {'discovery_ok': False, 'discovery_source': 'validated_cell_installation',
                    'skills_installed': 0, 'available_skills': [], 'invoked_skills': [],
                    'invocation_status': 'not_applicable' if suite == 'bare-model' else 'unknown',
                    'requested_skill': requested, 'activation_mode': data['activation_mode']}
    execution = {'exit_code': 1, 'status': 'preflight_failed', 'wall_seconds': 0, 'token_usage': {}}
    start = time.monotonic()
    try:
        # Retry only incomplete cells; no stale home, event, output or fixture survives.
        if rd.is_symlink():
            rd.unlink()
        elif rd.exists():
            shutil.rmtree(rd)
        rd.mkdir(parents=True, mode=0o700)
        (rd / 'identity.tsv').write_text(f'{arm}\t{tid}\n', encoding='utf-8')
        names = prepare_home(root, arm, suite, rd / 'home')
        require(requested is None or requested in names, f'请求的技能未安装：{requested}')
        manipulation.update(discovery_ok=True, skills_installed=len(names), available_skills=names)
        prompt_path = (args.duel_dir / 'corpus/tasks' / tid / 'prompt.md' if tid.startswith('H')
                       else args.duel_dir / 'prompts' / f'{tid}.md')
        prompt = prompt_path.read_text(encoding='utf-8')
        if requested:
            prompt = f'请使用 ${requested} 处理以下任务。\n\n' + prompt
        (rd / 'prompt.md').write_text(prompt, encoding='utf-8')
        env = dict(os.environ, HOME=str(rd / 'home'), CODEX_HOME=str(rd / 'home'), GIT_OPTIONAL_LOCKS='0',
                   CORPUS_FIXTURES=str(args.fixtures_dir), CORPUS_DIR=str(args.duel_dir / 'corpus'),
                   DUEL_BUILD='1' if args.build else '0')
        repo = rd / 'repo'
        shell_task(args.duel_dir, 'build_task', (tid, repo), env)
        baseline = git(repo, 'rev-parse', 'HEAD').decode().strip()
        pre_hash = tree_hash(repo)
        (rd / 'baseline_head').write_text(baseline + '\n', encoding='utf-8')
        (rd / 'pre_tree_hash').write_text(pre_hash + '\n', encoding='utf-8')
        (rd / 'git_status_before.txt').write_bytes(git(repo, 'status', '--short'))
        worktree_patch(repo, baseline, rd / 'diff_before.patch')
        write_json(rd / 'manipulation.json', manipulation)
        print(f'[{code}] arm={arm} task={tid} 开始', flush=True)
        model_start = time.monotonic()
        rc, status = execute(repo, rd, rd / 'home', args.timeout)
        execution.update(exit_code=rc, status=status, wall_seconds=round(time.monotonic() - model_start, 1))
        invoked, usage = event_records(rd, names)
        execution['token_usage'] = usage
        manipulation['invoked_skills'] = invoked
        if suite != 'bare-model' and invoked:
            manipulation['invocation_status'] = 'confirmed'
        # Persist model outcome even if a subsequent artifact/oracle step fails.
        write_json(rd / 'execution.json', execution)
        write_json(rd / 'manipulation.json', manipulation)
        (rd / 'git_status_after.txt').write_bytes(git(repo, 'status', '--short'))
        worktree_patch(repo, baseline, rd / 'diff_after.patch')
        (rd / 'git_log_after.txt').write_bytes(git(repo, 'log', '--oneline', '-8'))
        with (rd / 'checks.json').open('w', encoding='utf-8') as checks:
            shell_task(args.duel_dir, 'mechanical_check', (tid, repo, rd, baseline, pre_hash), env, checks)
        if rc == 0 and status == 'ok':
            (rd / 'done').touch()
            print(f'[{code}] 完成', flush=True)
            return True
    except Exception as exc:
        # A failing worker must produce records and propagate failure to the parent.
        detail = str(exc)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            detail += '\n' + exc.stderr.decode('utf-8', errors='replace')
        execution['error'] = detail
        if execution['status'] == 'ok':
            execution.update(exit_code=1, status='artifact_failed')
        if execution['status'] == 'preflight_failed':
            manipulation.update(discovery_ok=False, discovery_error=detail)
            execution['wall_seconds'] = round(time.monotonic() - start, 1)
        rd.mkdir(parents=True, exist_ok=True)
        write_json(rd / 'execution.json', execution)
        write_json(rd / 'manipulation.json', manipulation)
        print(f'[{code}] {detail}', file=sys.stderr, flush=True)
    print(f'[{code}] 失败：{execution["status"]} exit={execution["exit_code"]}', file=sys.stderr, flush=True)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='command', required=True)
    seal = subparsers.add_parser('seal')
    seal.add_argument('--run-root', type=Path, required=True)
    run = subparsers.add_parser('run')
    run.add_argument('--duel-dir', type=Path, required=True)
    run.add_argument('--task-ids', required=True)
    run.add_argument('--preregistration', required=True)
    run.add_argument('--run-root', type=Path, required=True)
    run.add_argument('--tasks', type=identifiers)
    run.add_argument('--repeats', type=positive_int)
    run.add_argument('--raters', type=identifiers)
    run.add_argument('--activation-mode', choices=('natural', 'explicit'))
    run.add_argument('--only-code')
    run.add_argument('--fixtures-dir', type=Path, default=Path(os.environ.get('TMPDIR', '/tmp')) / 'ship-corpus')
    run.add_argument('--build', action='store_true')
    run.add_argument('--jobs', type=positive_int, default=1)
    run.add_argument('--timeout', type=positive_int, default=900)
    run.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        args.run_root = args.run_root.resolve()
        if args.command == 'seal':
            seal_templates(args.run_root)
            return 0
        args.duel_dir = args.duel_dir.resolve()
        args.fixtures_dir = args.fixtures_dir.resolve()
        require((args.run_root / 'sealed').is_dir(), '请先运行 setup.sh')
        expected = (args.run_root / 'sealed/preregistration.sha256').read_text().strip()
        require(expected == args.preregistration, '预注册指纹不一致：任务/量表已改动')
        mapping = read_json(args.run_root / 'sealed/arms.json')
        require(set(mapping['mapping']) == {'A', 'B', 'C'}
                and set(mapping['mapping'].values()) == {'ship-skills', 'dev-skills', 'bare-model'}, '无效 arms 映射')
        data = freeze_allocation(args, mapping)
        rows = [row for row in data['runs'] if args.only_code is None or row['code'] == args.only_code]
        if args.dry_run:
            print(f'{"code":<12}{"arm":<5}{"task":<6}repeat')
            for row in rows:
                print(f'{row["code"]:<12}{row["arm"]:<5}{row["task"]:<6}{row["repeat"]}')
            print(f'合计 {len(rows)} 次')
            return 0
        # Pool results are consumed in full: neither serial nor parallel failure
        # silently disappears, and other allocated cells still get their attempt.
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            results = list(pool.map(lambda row: run_one(args, data, mapping, row), rows))
        if all(results):
            print(f'跑批结束。下一步：bash {args.duel_dir}/bin/score.sh --run-root {args.run_root}')
            return 0
        return 1
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'[ERROR] {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

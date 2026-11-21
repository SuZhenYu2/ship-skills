#!/usr/bin/env bash
set -euo pipefail

exec python3 - "$@" <<'PY'
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def git(*args):
    return subprocess.run(['git', *args], check=True, stdout=subprocess.PIPE).stdout


def check_record(data, status, tree, path, slug, mode):
    fields = {}
    fence = None
    for line in data.decode('utf-8').split('\n'):
        line = line.rstrip('\r')
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if fence:
            if marker and marker[1].startswith(fence) and not marker[2].strip():
                fence = None
            continue
        if marker:
            fence = marker[1]
            continue
        field = re.fullmatch(r'> (Status|Date|Tree|Commit|Slug|Scope):[ \t]*(.*?)[ \t]*', line)
        if field:
            key, value = field.groups()
            if key in fields:
                raise ValueError(f'{path}: {key} 重复')
            fields[key] = value
    for key in ('Status', 'Date', 'Tree', 'Commit', 'Slug', 'Scope'):
        if not fields.get(key, '').strip():
            raise ValueError(f'{path}: {key} 必填')
    for key, expected in [('Status', status), ('Tree', tree), ('Slug', slug)]:
        if fields[key] != expected:
            raise ValueError(f'{path}: 需要 > {key}: {expected}')
    if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}', fields['Date']):
        raise ValueError(f'{path}: Date 格式须为 YYYY-MM-DD HH:mm')
    datetime.strptime(fields['Date'], '%Y-%m-%d %H:%M')
    if not (mode == 'handoff' and fields['Commit'] == 'pending'):
        if not re.fullmatch(rf'[0-9a-fA-F]{{{len(tree)}}}', fields['Commit']):
            raise ValueError(f'{path}: Commit 需要完整 SHA')


def run(args):
    options = {}
    for i in range(0, len(args), 2):
        key = args[i]
        if (key not in ('--repo', '--mode', '--base', '--slug') or key in options
                or i + 1 == len(args) or not args[i + 1] or args[i + 1].startswith('--')):
            raise ValueError(f'参数无效或缺值: {key}')
        options[key] = args[i + 1]
    mode = options.get('--mode')
    slug = options.get('--slug', '')
    if (mode not in ('handoff', 'finish') or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', slug)
            or (mode == 'finish') != ('--base' in options)):
        raise ValueError('用法: --mode handoff|finish --slug <slug> [--repo <path>]（finish 必传 --base <ref>）')
    os.chdir(options.get('--repo', '.'))
    os.chdir(os.fsdecode(git('rev-parse', '--show-toplevel').removesuffix(b'\n')))
    paths = [f'.ship/{kind}/{slug}.md' for kind in ('verify', 'review')]
    outside = git('status', '--porcelain=v1', '-z', '--no-renames', '--untracked-files=all',
                  '--ignore-submodules=none', '--', '.', ':(exclude).ship/**')
    for entry in outside.split(b'\0'):
        if entry and (mode == 'finish' or entry[1:2] != b' '):
            raise ValueError(f'.ship/ 外不干净: {entry!r}；运行 git status')
    if mode == 'handoff':
        if git('diff', '--cached', '--name-only', '-z', '--', '.ship'):
            raise ValueError('证据不能混入代码暂存区；运行 git restore --staged -- .ship')
        tree = git('write-tree').strip().decode()
        records = []
        for name in paths:
            p = Path(name)
            if p.resolve() != Path.cwd() / p or not p.is_file():
                raise ValueError(f'缺少常规记录文件: {name}')
            records.append(p.read_bytes())
    else:
        head = git('rev-parse', '--verify', 'HEAD^{commit}').strip().decode()
        base = git('rev-parse', '--verify', '--end-of-options', options['--base'] + '^{commit}').strip().decode()
        history = git('rev-list', '--topo-order', '--parents', f'{base}..{head}')
        tip = None
        record_paths = {p.encode() for p in paths}
        paired = None
        for row in history.decode().splitlines():
            commit, *parents = row.split()
            if len(parents) > 1:
                tip = tip or commit
                continue
            diff = git('diff-tree', '--root', '--no-renames', '--no-commit-id', '--name-only', '-r', '-z', commit)
            changed = set(diff.split(b'\0')) - {b''}
            evidence_only = bool(changed) and all(p.startswith(b'.ship/') for p in changed)
            if paired is None and changed & record_paths:
                paired = evidence_only and record_paths <= changed
            if not evidence_only:
                tip = tip or commit
        if not paired:
            raise ValueError('最近修改任务记录的提交必须是同时修改两份记录的纯证据提交')
        tree = git('rev-parse', (tip or head) + '^{tree}').strip().decode()
        records = []
        for name in paths:
            entry = git('ls-tree', head, '--', name)
            if not entry.startswith((b'100644 blob ', b'100755 blob ')):
                raise ValueError(f'HEAD 缺少常规记录文件: {name}')
            records.append(git('cat-file', 'blob', f'{head}:{name}'))
    for data, status, path in zip(records, ['PASS', 'READY'], paths):
        check_record(data, status, tree, path, slug, mode)
    print(f'PASS {mode} slug={slug} tree={tree}')


try:
    run(sys.argv[1:])
except (OSError, ValueError, subprocess.CalledProcessError) as exc:
    sys.exit(f'BLOCKED: {exc}\n检查 git status --short；必要时重跑 ship-verify、ship-review，并按两阶段流程固化证据。')
PY

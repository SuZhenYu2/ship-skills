#!/usr/bin/env bash
set -euo pipefail

exec python3 - "$@" <<'PY'
import hashlib
import os
import re
import stat
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def git(*args):
    return subprocess.run(['git', *args], check=True, stdout=subprocess.PIPE).stdout


IDENTITY_FIELDS = ('Task', 'Cycle', 'Round')
SNAPSHOT_EXCLUDES = {'.git', '.ship/tasks', '.ship/verify', '.ship/review'}
SNAPSHOT_EXCLUDE_FILES = {'.DS_Store', 'Thumbs.db'}


def file_digest(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot(root):
    root = Path(root)
    entries = []
    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = '' if rel_dir == '.' else rel_dir.replace(os.sep, '/')
        kept = []
        for name in sorted(dirnames):
            rel = f'{rel_dir}/{name}' if rel_dir else name
            full = os.path.join(dirpath, name)
            if name == '.git' or rel in SNAPSHOT_EXCLUDES:
                continue
            if os.path.islink(full):
                entries.append((rel, 'link', os.readlink(full)))
                continue
            kept.append(name)
        dirnames[:] = kept
        for name in sorted(filenames):
            rel = f'{rel_dir}/{name}' if rel_dir else name
            if name in SNAPSHOT_EXCLUDE_FILES:
                continue
            full = os.path.join(dirpath, name)
            info = os.lstat(full)
            if stat.S_ISLNK(info.st_mode):
                entries.append((rel, 'link', os.readlink(full)))
            elif stat.S_ISREG(info.st_mode):
                entries.append((rel, 'exec' if info.st_mode & 0o111 else 'file', file_digest(full)))
    digest = hashlib.sha256(b'ship-snapshot-v1\0')
    for rel, kind, value in sorted(entries, key=lambda item: item[0]):
        digest.update(rel.encode('utf-8') + b'\0' + kind.encode('utf-8') + b'\0' + value.encode('utf-8') + b'\0')
    return digest.hexdigest()


def detect_vcs(root):
    root = Path(root).resolve()
    try:
        output = subprocess.run(
            ['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ).stdout
    except (FileNotFoundError, subprocess.CalledProcessError):
        return 'none', root
    top = Path(os.fsdecode(output).strip()).resolve()
    if top != root:
        raise ValueError('--repo 必须指向 Git 工作区根目录或非 Git 项目根目录。')
    return 'git', top


def check_record(data, status, tree, path, slug, mode, vcs):
    fields = {}
    fence = None
    header_done = False
    # HTML 注释不构成记录头；先剔除，避免注释内容冒充引用行。
    text = re.sub(r'<!--.*?-->', '', data.decode('utf-8'), flags=re.S)
    for line in text.split('\n'):
        line = line.rstrip('\r')
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if fence:
            if marker and marker[1].startswith(fence) and not marker[2].strip():
                fence = None
            continue
        field = re.fullmatch(r'> (Status|Date|Tree|Commit|Slug|Scope|Task|Cycle|Round|Vcs):[ \t]*(.*?)[ \t]*', line)
        if field:
            key, value = field.groups()
            if header_done:
                raise ValueError(f'{path}: {key} 必须位于文档开头唯一的连续记录头')
            if key in fields:
                raise ValueError(f'{path}: {key} 重复')
            fields[key] = value
            continue
        if marker:
            if not header_done and not fields:
                raise ValueError(f'{path}: 记录头必须从文档开头直接开始，不能先写代码块')
            fence = marker[1]
            continue
        if line.strip():
            if not fields:
                raise ValueError(f'{path}: 记录头必须从文档开头直接开始，不能先写正文')
            header_done = True
    for key in ('Status', 'Date', 'Tree', 'Commit', 'Slug', 'Scope'):
        if not fields.get(key, '').strip():
            raise ValueError(f'{path}: {key} 必填')
    record_vcs = fields.get('Vcs')
    if record_vcs not in (None, 'git', 'none'):
        raise ValueError(f'{path}: Vcs 仅支持 git 或 none')
    if vcs == 'none':
        if record_vcs != 'none':
            raise ValueError(f'{path}: 非 Git 项目需要 > Vcs: none')
        if fields['Commit'] != 'none':
            raise ValueError(f'{path}: 非 Git 项目需要 > Commit: none')
        if not re.fullmatch(r'[0-9a-f]{64}', fields['Tree']):
            raise ValueError(f'{path}: 非 Git 项目的 Tree 必须是 64 位内容快照')
    else:
        if record_vcs == 'none':
            raise ValueError(f'{path}: Git 项目不能写 > Vcs: none')
        if not (mode == 'handoff' and fields['Commit'] == 'pending'):
            if not re.fullmatch(rf'[0-9a-fA-F]{{{len(tree)}}}', fields['Commit']):
                raise ValueError(f'{path}: Commit 需要完整 SHA')
    for key, expected in [('Status', status), ('Tree', tree), ('Slug', slug)]:
        if fields[key] != expected:
            raise ValueError(f'{path}: 需要 > {key}: {expected}')
    if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}', fields['Date']):
        raise ValueError(f'{path}: Date 格式须为 YYYY-MM-DD HH:mm')
    datetime.strptime(fields['Date'], '%Y-%m-%d %H:%M')
    identity = {key: fields[key] for key in IDENTITY_FIELDS if key in fields}
    return identity, record_vcs


def check_identity(pairs, paths, task, expected_loop, allow_legacy, vcs):
    identities = [identity for identity, _ in pairs]
    record_vcs = [value if value is not None else 'git' for _, value in pairs]
    if vcs == 'none':
        if allow_legacy:
            raise ValueError('非 Git 项目不支持旧版六字段兼容')
        for value, name in zip(record_vcs, paths):
            if value != 'none':
                raise ValueError(f'{name}: 非 Git 项目需要 > Vcs: none')
    else:
        for value, name in zip(record_vcs, paths):
            if value == 'none':
                raise ValueError(f'{name}: Git 项目不能写 > Vcs: none')
    if record_vcs[0] != record_vcs[1]:
        raise ValueError('两份记录的 Vcs 必须一致')
    if allow_legacy and not any(identities):
        return
    for fields, name in zip(identities, paths):
        for key in IDENTITY_FIELDS:
            if not fields.get(key):
                raise ValueError(f'{name}: {key} 必填；不混用新旧证据')
        if fields['Task'] != task:
            raise ValueError(f'{name}: 需要 > Task: {task}')
        cycle, round_no = fields['Cycle'], fields['Round']
        if expected_loop is not None:
            for key, value in zip(('Cycle', 'Round'), expected_loop):
                if fields[key] != value:
                    raise ValueError(f'{name}: 需要 > {key}: {value}')
        if (cycle, round_no) != ('none', 'none') and not (
                re.fullmatch(r'[0-9a-f]{32}', cycle) and re.fullmatch(r'[1-5]', round_no)):
            raise ValueError(f'{name}: Cycle/Round 必须为有效周期和轮次，或均为 none')
    if identities[0] != identities[1]:
        raise ValueError('两份记录的 Task/Cycle/Round 必须一致')


def run(args):
    options = {}
    args = iter(args)
    for key in args:
        if key in options:
            raise ValueError(f'参数重复: {key}')
        if key in ('--no-loop', '--allow-legacy'):
            options[key] = True
            continue
        value = next(args, '')
        if (key not in ('--repo', '--mode', '--base', '--slug', '--task', '--cycle', '--round')
                or not value or value.startswith('--')):
            raise ValueError(f'参数无效或缺值: {key}')
        options[key] = value
    mode = options.get('--mode')
    if mode not in ('handoff', 'finish', 'snapshot'):
        raise ValueError('用法: --mode handoff|finish|snapshot ...')
    if mode == 'snapshot':
        if any(key in options for key in ('--slug', '--task', '--base', '--cycle', '--round',
                                          '--no-loop', '--allow-legacy')):
            raise ValueError('snapshot 仅接受 --repo')
        root = Path(options.get('--repo', '.')).resolve()
        if not root.is_dir():
            raise ValueError('--repo 必须指向目录')
        print(f'SNAPSHOT {snapshot(root)}')
        return

    slug = options.get('--slug', '')
    task = options.get('--task', '')
    if (not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', slug)
            or len(task) > 100 or not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', task)):
        raise ValueError('用法: --mode handoff|finish --slug <slug> --task <id> [--repo <path>]（Git finish 必传 --base <ref>）')
    if mode == 'handoff' and '--base' in options:
        raise ValueError('handoff 不接受 --base')
    no_loop = '--no-loop' in options
    allow_legacy = '--allow-legacy' in options
    has_tokens = '--cycle' in options or '--round' in options
    expected_loop = ('none', 'none') if no_loop else None
    if allow_legacy and not no_loop:
        raise ValueError('--allow-legacy 仅适用于明确未启用 Loop 的任务（--no-loop）')
    if has_tokens:
        cycle, round_no = options.get('--cycle', ''), options.get('--round', '')
        if (mode != 'handoff' or no_loop or not re.fullmatch(r'[0-9a-f]{32}', cycle)
                or not re.fullmatch(r'[1-5]', round_no)):
            raise ValueError('handoff 的 --cycle/--round 必须成对提供且不与 --no-loop 同用')
        expected_loop = (cycle, round_no)
    if mode == 'handoff' and expected_loop is None:
        raise ValueError('handoff 必须提供本轮 --cycle/--round，或显式 --no-loop')

    root = Path(options.get('--repo', '.')).resolve()
    if not root.is_dir():
        raise ValueError('--repo 必须指向目录')
    vcs, cwd = detect_vcs(root)
    os.chdir(cwd)
    if mode == 'finish' and vcs == 'git' and '--base' not in options:
        raise ValueError('Git 项目 finish 必须提供 --base <ref>')

    paths = [f'.ship/{kind}/{slug}.md' for kind in ('verify', 'review')]
    if vcs == 'git':
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
                evidence_only = bool(changed) and all(
                    p.startswith(b'.ship/') and not p.startswith(b'.ship/tasks/') for p in changed)
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
    else:
        tree = snapshot(Path.cwd())
        records = []
        for name in paths:
            p = Path(name)
            if p.resolve() != Path.cwd() / p or not p.is_file():
                raise ValueError(f'缺少常规记录文件: {name}')
            records.append(p.read_bytes())

    pairs = [check_record(data, status, tree, name, slug, mode, vcs)
             for data, status, name in zip(records, ('PASS', 'READY'), paths)]
    check_identity(pairs, paths, task, expected_loop, allow_legacy, vcs)
    print(f'PASS {mode} slug={slug} tree={tree} vcs={vcs}')


try:
    run(sys.argv[1:])
except (OSError, ValueError, subprocess.CalledProcessError) as exc:
    sys.exit(f'BLOCKED: {exc}\n检查 git status --short；必要时重跑 ship-verify、ship-review，并按两阶段流程固化证据。')
PY

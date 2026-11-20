#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo '[ERROR] arena 状态工具需要 Python 3。' >&2; exit 1; }
python3 - "$@" <<'PY'
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import uuid

parser = argparse.ArgumentParser(description='任务级 arena 开关；状态输出不代表候选已经执行。')
parser.add_argument('--repo', default='.')
parser.add_argument('--task', required=True)
parser.add_argument('--stage')
parser.add_argument('--generation', help='派发候选时记录的开关批次，仅用于 check')
parser.add_argument('action', choices=['on', 'off', 'status', 'check'])
args = parser.parse_args()
strategies = {
    'ship-arena': '配置任务开关',
    'ship-auto': '只读导航',
    'ship-grill': '独立分析需求缺口，由 Lead 合并追问',
    'ship-spec': '独立分析验收条件，由 Lead 汇总 Spec',
    'ship-plan': '双候选方案比选',
    'ship-tdd': '测试设计与高风险策略比选，不并行业务实现',
    'ship-fix': '独立根因假设证伪与修复方案比选',
    'ship-verify': '同一最终快照独立验证，事实不投票',
    'ship-review': '独立双视角审查，有效 BLOCKER 必须阻断',
    'ship-commit': 'Lead 串行提交门禁，仅执行一次 Git 写操作',
    'ship-finish': '独立复核交付证据，Git 收尾仅由 Lead 串行执行',
}

def fail(message):
    print('[ERROR] ' + message, file=sys.stderr)
    sys.exit(1)

if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', args.task) or len(args.task) > 100:
    fail('task 必须为不超过 100 字符的小写字母、数字及分隔短横线。')
if args.stage and args.stage not in strategies:
    fail('未知 ship 阶段：' + args.stage)
if (args.action == 'check') != bool(args.generation):
    fail('check 必须提供 --generation；其他操作不得提供该参数。')
try:
    repo = pathlib.Path(args.repo).resolve(strict=True)
    result = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--show-toplevel'], capture_output=True, text=True, check=True)
    if pathlib.Path(result.stdout.strip()).resolve() != repo:
        fail('--repo 必须指向 Git 工作区根目录。')
    path = repo / '.ship' / 'tasks' / args.task / 'arena.json'
    for item in [repo / '.ship', repo / '.ship/tasks', path.parent, path]:
        if item.is_symlink():
            fail('状态路径不能包含符号链接：' + str(item))
    state = dict(version=1, enabled=False, policy='selective', candidates=2)
    if path.exists():
        state = json.loads(path.read_text(encoding='utf-8'))
        if (not isinstance(state, dict) or set(state) not in ({'version', 'enabled', 'policy', 'candidates'}, {'version', 'enabled', 'policy', 'candidates', 'generation'})
                or type(state.get('version')) is not int or state['version'] != 1
                or type(state.get('enabled')) is not bool or state.get('policy') != 'selective'
                or type(state.get('candidates')) is not int or state['candidates'] != 2):
            fail('arena 配置格式或版本无效；请明确修复后重试，不会静默覆盖。')
    if 'generation' in state and (not isinstance(state['generation'], str) or not re.fullmatch(r'[0-9a-f]{32}', state['generation'])):
        fail('arena generation 格式无效。')
    if args.action == 'check':
        if not state['enabled'] or not state.get('generation') or state['generation'] != args.generation:
            fail('候选批次已失效或未绑定；禁止接收旧结果。')
    if args.action in ('on', 'off'):
        # 本地排除规则不改变业务工作区，也适用于 linked worktree。
        exclude_result = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--git-path', 'info/exclude'], capture_output=True, text=True, check=True)
        exclude = pathlib.Path(exclude_result.stdout.strip())
        if not exclude.is_absolute():
            exclude = repo / exclude
        existing = exclude.read_text(encoding='utf-8') if exclude.exists() else ''
        if '/.ship/' not in existing.splitlines():
            exclude.parent.mkdir(parents=True, exist_ok=True)
            with exclude.open('a', encoding='utf-8') as handle:
                handle.write(('\n' if existing and not existing.endswith('\n') else '') + '/.ship/\n')
        state['enabled'] = args.action == 'on'
        state['generation'] = uuid.uuid4().hex
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as handle:
                temporary = handle.name
                json.dump(state, handle, ensure_ascii=False, indent=2)
                handle.write('\n')
            os.replace(temporary, path)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
    label = args.stage or 'ship'
    enabled = 'ON' if state['enabled'] else 'OFF'
    strategy = strategies[args.stage] if state['enabled'] and args.stage else ('selective' if state['enabled'] else '标准流程')
    print(f'[{label}] Arena: {enabled} | 范围: {args.task} | 计划策略: {strategy}')
    print('generation=' + state.get('generation', '未绑定批次；请显式 on 后再派发候选'))
    if args.action in ('on', 'off'):
        print('从下一阶段生效；不包含 Git 写操作授权。' if state['enabled'] else '停止派发新候选；已运行候选请求取消，不支持时忽略其后续输出。不回滚已有产物。')
except (OSError, ValueError, subprocess.SubprocessError) as error:
    fail('无法读取或更新 arena 状态：' + str(error))
PY

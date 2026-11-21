import json
import os
from pathlib import Path
import shutil
import sys


SYSTEM_ROOTS = ('/System', '/usr', '/bin', '/sbin', '/lib', '/lib64', '/Library',
                '/opt/homebrew', '/usr/local', '/private/etc', '/etc', '/dev',
                '/private/var/db/dyld')


def isolated_command(command, run_dir, env):
    root = Path(run_dir).resolve(strict=True)
    home = Path(env['CODEX_HOME']).resolve(strict=True)
    if not home.is_relative_to(root):
        raise ValueError('CODEX_HOME 必须位于当前 run 内')
    executable = shutil.which(command[0], path=env.get('PATH'))
    if not executable:
        raise ValueError(f'执行器不存在：{command[0]}')
    executable = Path(executable).resolve(strict=True)
    scratch = root / 'tmp'
    scratch.mkdir(exist_ok=True)
    child_env = dict(env, HOME=str(home), TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch))
    system = sorted({str(Path(p).resolve()) for p in SYSTEM_ROOTS if Path(p).exists()})
    if any(root.is_relative_to(p) for p in system):
        raise ValueError('run 目录不能位于公共运行时只读目录中')

    if sys.platform == 'darwin':
        backend = shutil.which('sandbox-exec')
        if not backend:
            raise ValueError('读取隔离不可用：需要 sandbox-exec')
        profile = ['(version 1)', '(allow default)', '(deny file-read*)', '(deny file-write*)',
                   '(allow file-read-metadata)', '(allow file-read* (literal "/"))',
                   '(allow file-write* (literal "/dev/null") (literal "/dev/tty"))']
        for directory in system:
            profile.append(f'(allow file-read* (subpath {json.dumps(directory)}))')
        profile += [f'(allow file-read* (literal {json.dumps(str(executable))}))',
                    f'(allow file-read* file-write* (subpath {json.dumps(str(root))}))']
        return [backend, '-p', '\n'.join(profile), *command], child_env, 'seatbelt'

    if sys.platform.startswith('linux'):
        backend = shutil.which('bwrap')
        if not backend:
            raise ValueError('读取隔离不可用：需要 bubblewrap 及可用的用户命名空间')
        prefix = [backend, '--die-with-parent', '--new-session', '--unshare-user', '--unshare-pid',
                  '--unshare-ipc', '--unshare-uts', '--proc', '/proc', '--dev', '/dev']
        for directory in system:
            if directory != '/dev':
                prefix += ['--ro-bind', directory, directory]
        for alias in ('/bin', '/sbin', '/lib', '/lib64'):
            p = Path(alias)
            if p.is_symlink():
                prefix += ['--symlink', os.readlink(p), alias]
        if not any(executable.is_relative_to(p) for p in system):
            prefix += ['--ro-bind', str(executable), str(executable)]
        prefix += ['--bind', str(root), str(root), '--chdir', str(root / 'repo'), '--']
        return [*prefix, *command], child_env, 'bubblewrap'

    raise ValueError(f'读取隔离尚不支持平台：{sys.platform}；禁止无隔离跑批')

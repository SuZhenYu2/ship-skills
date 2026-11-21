#!/usr/bin/env bash
# 双盲对比评测的共享函数。被 bin/ 下脚本 source。
set -euo pipefail

DUEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${DUEL_DIR}/../.." && pwd)"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"
}

# 稳定的内容指纹，用于预注册与锁分。
fingerprint() {
  python3 - "$@" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    files = sorted(p.rglob('*')) if p.is_dir() else [p]
    for f in files:
        if f.is_file():
            h.update(str(f.relative_to(p) if p.is_dir() else f.name).encode())
            h.update(b'\0')
            h.update(f.read_bytes())
            h.update(b'\0')
print(h.hexdigest())
PY
}

# 在隔离环境里初始化一个夹具 git 仓库，避免继承用户全局 git 配置。
fixture_git_init() {
  local dir="$1" branch="${2:-main}"
  mkdir -p "${dir}"
  git -C "${dir}" init -q -b "${branch}"
  git -C "${dir}" config user.name 'Fixture Bot'
  git -C "${dir}" config user.email 'fixture@example.invalid'
  git -C "${dir}" config commit.gpgsign false
  git -C "${dir}" config core.hooksPath /dev/null
}

fixture_commit_all() {
  local dir="$1" msg="$2"
  git -C "${dir}" add -A
  git -C "${dir}" commit -qm "${msg}"
}

# 把任意文本安全地写成 JSON 字符串。
json_str() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}
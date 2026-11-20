#!/usr/bin/env bash
# 并行补跑编译门禁：对已完成的运行目录执行 mvn compile 并回写 checks.json。
# 用法：bash evals/duel/bin/build-check.sh --run-root <dir> [--jobs 4] [--timeout 900]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

RUN_ROOT=""
JOBS=4
TIMEOUT=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -d "${RUN_ROOT}/runs" ]] || die '请指定含 runs/ 的 --run-root'
RUN_ROOT="$(cd "${RUN_ROOT}" && pwd)"
need_cmd mvn

export ROOT="${RUN_ROOT}" TIMEOUT
check_one() {
  local rd="$1"
  [[ -f "${rd}/done" && -d "${rd}/repo" ]] || return 0
  # 已有结果且时代码未变则跳过；允许 --force 通过删除 compile_ok 重跑。
  if python3 - "${rd}/checks.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if p.exists() and json.load(open(p, encoding='utf-8')).get('compile_ok') is not None:
    sys.exit(0)
sys.exit(1)
PY
  then
    return 0
  fi
  local log="${rd}/build-check.log"
  ( cd "${rd}/repo" && timeout "${TIMEOUT}" mvn -q -DskipTests compile > "${log}" 2>&1 )
  local rc=$?
  python3 - "${rd}/checks.json" "${rc}" "${log}" <<'PY'
import json, pathlib, sys
p, rc, log = pathlib.Path(sys.argv[1]), int(sys.argv[2]), pathlib.Path(sys.argv[3])
data = json.load(open(p, encoding='utf-8')) if p.exists() else {}
data['compile_ok'] = rc == 0
data['compile_tail'] = log.read_text(encoding='utf-8', errors='replace')[-500:] if log.exists() else ''
json.dump(data, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"[{'PASS' if rc == 0 else 'FAIL'}] {p.parent.parent.name}/{p.parent.name}")
PY
}
export -f check_one

while IFS= read -r -d '' marker; do
  # bash 3.2 无 wait -n，用轮询控制并发。
  while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "${JOBS}" ]]; do
    sleep 2
  done
  ( check_one "$(dirname "${marker}")" ) &
done < <(find "${RUN_ROOT}/runs" -maxdepth 2 -name done -print0)
wait
log "编译检查完成：$(find "${RUN_ROOT}/runs" -maxdepth 2 -name done | wc -l | tr -d ' ') 个已完成运行"
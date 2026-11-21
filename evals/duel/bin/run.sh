#!/usr/bin/env bash
# 随机化跑批：三臂 × 任务 × 重复，逐 cell 使用干净夹具与独立 HOME / CODEX_HOME。
# 用法：bash evals/duel/bin/run.sh --run-root <dir> [--tasks T01,T02] [--repeats 3]
#       [--raters r1,r2] [--activation-mode natural|explicit] [--jobs 1] [--dry-run]
# 真实执行还需 Seatbelt / bubblewrap 读取沙箱；不可用时拒绝启动。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${DUEL_DIR}/lib/tasks.sh"

# 保留现有任务/量表预注册，以及 tasks.sh 的夹具、历史回放与机械 oracle。
ACTUAL="$(fingerprint "${DUEL_DIR}/prompts" "${DUEL_DIR}/corpus/prompts" "${DUEL_DIR}/corpus/selection.json" \
  "${DUEL_DIR}/lib/tasks.sh" "${DUEL_DIR}/rubric.md")"
exec python3 -B "${DUEL_DIR}/lib/runner.py" run --duel-dir "${DUEL_DIR}" \
  --task-ids "${TASK_IDS[*]} ${HISTORICAL_IDS[*]}" --preregistration "${ACTUAL}" "$@"

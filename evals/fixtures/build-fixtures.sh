#!/usr/bin/env bash
set -euo pipefail

# 为校准用例 2/3/5/10 构建最小陷阱仓库。只写 <target-dir>，可在其中重复重建。
# 依赖：git、node（支持原生运行 TypeScript，用于用例 2 的复现测试）。

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/../.." && pwd -P)"

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  echo "Usage: bash evals/fixtures/build-fixtures.sh <target-dir>" >&2
  exit 2
fi
case "${TARGET}" in
  /*) ;;
  *) TARGET="$(pwd)/${TARGET}" ;;
esac
# 在任何写入前解析路径：向上找到已存在的祖先目录（解析符号链接），再拼接未存在部分
probe="${TARGET}"
tail=""
while [[ ! -d "${probe}" ]]; do
  tail="/$(basename "${probe}")${tail}"
  probe="$(dirname "${probe}")"
done
TARGET="$(cd -P "${probe}" && pwd -P)${tail}"
if [[ "${TARGET}" == "/" ]]; then
  echo "[ERROR] 目标目录不能是文件系统根目录。" >&2
  exit 2
fi
case "${TARGET}/" in
  "${REPO_ROOT}/"*)
    echo "[ERROR] 目标目录不能位于 ship-skills 仓库内部: ${TARGET}" >&2
    exit 2
    ;;
esac
mkdir -p "${TARGET}"
TARGET="$(cd -P "${TARGET}" && pwd -P)"
case "${TARGET}/" in
  "${REPO_ROOT}/"*)
    echo "[ERROR] 目标目录不能位于 ship-skills 仓库内部: ${TARGET}" >&2
    exit 2
    ;;
esac
if [[ "${TARGET}" == "/" ]]; then
  echo "[ERROR] 目标目录不能是文件系统根目录。" >&2
  exit 2
fi

init_repo() {
  local dir="$1" base_msg="${2:-feat(1000): base init}"
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" symbolic-ref HEAD refs/heads/master
  git -C "${dir}" config user.email "eval@example.invalid"
  git -C "${dir}" config user.name "Eval Fixture"
  printf 'base\n' > "${dir}/base.txt"
  git -C "${dir}" add base.txt
  git -C "${dir}" commit -qm "${base_msg}"
}

commit_file() {
  local dir="$1" file="$2" content="$3" msg="$4"
  printf '%s\n' "${content}" > "${dir}/${file}"
  git -C "${dir}" add "${file}"
  git -C "${dir}" commit -qm "${msg}"
}

write_readme() {
  local dir="$1" case_no="$2" trigger="$3" expect="$4"
  cat > "${dir}/README.md" <<EOF
# 校准用例 ${case_no} 夹具

触发提示（原样发给被测 agent）：

${trigger}

预期结果摘要：${expect}

完整 Pass/Fail 标准见 ship-skills 仓库 evals/calibration-cases.md 用例 ${case_no}。
重建本夹具：bash evals/fixtures/build-fixtures.sh <target-dir>
EOF
  git -C "${dir}" add README.md
  git -C "${dir}" commit -qm "docs(1000): eval fixture readme"
}

for c in case-2-order-refund case-3-buried-diff case-5-hidden-violation case-10-dirty-staging; do
  rm -rf "${TARGET}/${c}"
done

echo "==> 构建用例 2：上游 discount=undefined 根因陷阱"
CASE2="${TARGET}/case-2-order-refund"
init_repo "${CASE2}"
git -C "${CASE2}" checkout -qb "feature-20261120-order-refund-7056405076"
cat > "${CASE2}/order.ts" <<'TS'
export interface Order {
  amount: number;
  discount?: number;
}

export function createOrder(amount: number, discount?: number): Order {
  return { amount, discount };
}

export function calculateRefund(order: Order): number {
  return order.amount - Number((order.discount as number).toFixed(2));
}
TS
cat > "${CASE2}/order.test.ts" <<'TS'
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { calculateRefund, createOrder } from './order.ts';

describe('calculateRefund', () => {
  it('refund with discount', () => {
    assert.equal(calculateRefund(createOrder(100, 10)), 90);
  });

  it('normalizes missing discount', () => {
    assert.equal(calculateRefund(createOrder(100)), 100);
  });
});
TS
git -C "${CASE2}" add order.ts order.test.ts
git -C "${CASE2}" commit -qm "feat(7056405076): order add refund calc"
write_readme "${CASE2}" 2 \
  "用 ship-fix 排查并修复 calculateRefund 报错问题" \
  "先复现 TypeError，在上游 createOrder 归一化 discount 并补回归测试；仅在下游加判空属 Fail。"

echo "==> 构建用例 3：master 工作区埋雷 diff"
CASE3="${TARGET}/case-3-buried-diff"
init_repo "${CASE3}"
cat > "${CASE3}/service.py" <<'PY'
def sync_orders(orders):
    return [o["id"] for o in orders]


def parse(payload):
    return int(payload)
PY
printf '# Notes\n' > "${CASE3}/unrelated.md"
git -C "${CASE3}" add service.py unrelated.md
git -C "${CASE3}" commit -qm "feat(1000): order base service"
write_readme "${CASE3}" 3 \
  "用 ship-review 审查当前修改，准备提交" \
  "裁决 BLOCKED，精准定位循环内外部 IO、静默吞异常、调试残留三处埋雷与 master 分支/缺测试证据问题。"
cat > "${CASE3}/service.py" <<'PY'
def remote_fetch(order_id):
    return {"id": order_id, "status": "ok"}


def sync_orders(orders):
    result = []
    for o in orders:
        result.append(remote_fetch(o["id"]))
    return result


def parse(payload):
    try:
        return int(payload)
    except Exception:
        pass


print("DEBUG sync_orders loaded")
PY
printf '# Notes (edited)\n' > "${CASE3}/unrelated.md"

echo "==> 构建用例 5：5 条提交中第 3 条缺需求 ID"
CASE5="${TARGET}/case-5-hidden-violation"
init_repo "${CASE5}"
write_readme "${CASE5}" 5 \
  "用 ship-finish 收尾当前分支并准备合并到 master" \
  "逐条核验全部 5 条提交，精准揪出第 3 条缺需求 ID 的提交并判 BLOCKED；只看最新 1 条属 Fail。"
git -C "${CASE5}" checkout -qb "feature-20261120-order-cancel-7056405076"
commit_file "${CASE5}" f1.txt "step1" "feat(7056405076): order add step1"
commit_file "${CASE5}" f2.txt "step2" "feat(7056405076): order add step2"
commit_file "${CASE5}" f3.txt "step3" "chore: cleanup temp files"
commit_file "${CASE5}" f4.txt "step4" "feat(7056405076): order add step4"
commit_file "${CASE5}" f5.txt "step5" "feat(7056405076): order add step5"

echo "==> 构建用例 10：脏暂存与历史旧 ID 陷阱"
CASE10="${TARGET}/case-10-dirty-staging"
init_repo "${CASE10}" "feat(1111111111): pay legacy base"
write_readme "${CASE10}" 10 \
  "用 ship-commit 直接生成提交信息并按历史 ID 提交。" \
  "从分支末尾提取 7056405076，拒绝复用历史旧 ID 1111111111，指出暂存区混入调试文件，未获授权不执行 commit。"
git -C "${CASE10}" checkout -qb "feature-20261120-pay-refund-7056405076"
commit_file "${CASE10}" refund.py "def refund(amount):
    return amount" "feat(7056405076): pay add refund entry"
printf 'def refund(amount, fee=0):\n    return amount - fee\n' > "${CASE10}/refund.py"
printf 'DEBUG DUMP 2026-11-20\n' > "${CASE10}/debug_dump.log"
git -C "${CASE10}" add refund.py debug_dump.log

echo "完成：4 个夹具已构建于 ${TARGET}"
echo "  case-2-order-refund / case-3-buried-diff / case-5-hidden-violation / case-10-dirty-staging"

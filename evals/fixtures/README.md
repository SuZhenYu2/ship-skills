# 校准用例夹具（Cases 2/3/5/10）

为 `evals/calibration-cases.md` 中依赖前置仓库状态的用例提供可复现的最小陷阱仓库。

## 构建

```bash
bash evals/fixtures/build-fixtures.sh <target-dir>
```

只写 `<target-dir>`（禁止指向 ship-skills 仓库内部），可重复执行，重建会覆盖同名用例目录。依赖 git 与 python3。

## 用例映射

| 目录 | 用例 | 陷阱 | 预期裁决 |
| --- | --- | --- | --- |
| case-2-order-refund | 用例 2 | 上游 create_order 存入 discount=None，下游 calculate_refund 抛 TypeError | ship-fix 在上游修契约并补回归测试 |
| case-3-buried-diff | 用例 3 | master 工作区 diff 埋入 N+1 外部 IO、静默吞异常、调试 print 与无关文件改动 | ship-review 判 BLOCKED 并定位全部埋雷 |
| case-5-hidden-violation | 用例 5 | 合规分支 5 条提交中第 3 条缺需求 ID | ship-finish 判 BLOCKED 并定位第 3 条 |
| case-10-dirty-staging | 用例 10 | 合规分支末尾 7056405076，暂存区混入调试文件，历史含旧 ID 1111111111 | ship-commit 拒绝旧 ID、指出脏暂存、未授权不提交 |

每个夹具目录内的 README 含原样触发提示与预期摘要。完整 Pass/Fail 标准以 `evals/calibration-cases.md` 为准。

## 回归自检

```bash
bash evals/fixtures/test-fixtures.sh
```

在系统临时目录重建全部夹具并断言每个陷阱真实存在（用例 2 的 TypeError 复现、用例 3 的三处埋雷、用例 5 的 range 精准拦截、用例 10 的脏暂存与旧 ID）。CI 会运行本检查。

## 执行校准

按 `evals/calibration-cases.md` 末尾协议执行：同一模型/运行时/夹具快照，每例至少 3 次，用 `evals/results-template.md` 记录通过率与失败模式。用例 6/7/8/9 的夹具待补。

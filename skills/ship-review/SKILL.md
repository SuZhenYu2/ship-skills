---
name: ship-review
description: 提交前的独立风险审查门禁：对照 .ship/specs/ 与 git diff，按通用生产风险清单分级输出 BLOCKER/MAJOR/MINOR，并给出 READY/BLOCKED/INCOMPLETE 裁决。
---

# ship-review（提交前风险审查）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-review`，统一回显配置与计划策略，按共享协议执行并报告实际结果；失败暂停，不静默降级 off。候选派发及结果接收前重读状态，off 后取消运行请求，否则忽略结果。两路独立审查仍由 Lead 按证据裁决，不能以多数票跳过最终快照门禁。

## 核心原则

- 遵循 `references/dev-baseline.md`、`references/review-checklist.md` 与 `references/git-branch-policy.md`。
- 若项目 `AGENTS.md` 或 `references/stacks/` 配置了语言专项审查红线，一并纳入审查。
- **只看真实风险，不刷无意义风格意见**；在 Multi-Agent 模式下必须使用全新干净上下文（`Critic` / `Auditor`）执行，防止“自己写自己审”。
- **READY 只属于证据齐全的改动**：`ship-verify` 的必需门禁未运行或结论为 `PARTIAL` 时，输出 `INCOMPLETE`，不得用 READY 代替。
- **READY 必须对应同一代码快照**：`ship-verify` 证据中的 `HEAD` 与 `index tree` 必须与当前仓库一致；缺失证据对象或快照不一致时输出 `INCOMPLETE`，要求对当前快照重跑验证。

## 执行步骤

1. **收集审查输入**
   - 读取 `git status` 与 `git diff HEAD`（同时覆盖已暂存与未暂存改动），记录当前 `git rev-parse HEAD` 与 `git write-tree`。
   - 读取关联的 `.ship/specs/<slug>.md`、`.ship/plans/<slug>.md` 或 `.ship/fixes/<slug>.md`（如存在）以及最近一次 `ship-verify` 证据，核对证据对象的 `HEAD` / `index tree` 是否与当前一致。
2. **逐项对照风险清单审查**
   - 严格按 `references/review-checklist.md` 的六大维度检查：
     1. 正确性与数据一致性
     2. 并发、幂等与重入安全
     3. 性能与资源管理
     4. 错误处理与可观测性
     5. 兼容性与契约边界
     6. 改动范围、验证证据与 Git/飞书规范前置合规
3. **验证测试有效性与最高风险边界**
   - 新增或修改的测试必须在缺陷复现或修复回退时失败；只有状态码、Mock 恒等式或“不抛异常”的断言不算覆盖核心行为。
   - 对最高风险边界至少执行一个判别性测试或最小复现，并记录命令与原始结果；只读代码得出的结论标记为待验证。
4. **分级裁决**
   - 每条发现必须定位到 `<file>:<line>`，说明触发机理与最小修改建议，并标记 `BLOCKER` / `MAJOR` / `MINOR`。
   - **裁决规则**：
     - 存在任意 `BLOCKER` → 输出 `BLOCKED`（阻断提交，需修复后重新 `ship-verify` 并复审；注意遵循 `docs/multi-agent-policy.md` 的 2 轮熔断上限）。
     - 无 `BLOCKER`，但 `ship-verify` 必需门禁未运行、为 `PARTIAL`，或证据对象与当前 `HEAD` / `index tree` 不一致 → 输出 `INCOMPLETE`，列出缺失证据与补齐命令。
     - 无 `BLOCKER` 且必需证据齐全且快照一致 → 输出 `READY`（如有 `MAJOR` 需明确提醒用户确认是否先修再提交）。

## 输出格式（仅对话输出，不生成文件）

- **审查裁决**：`READY` / `BLOCKED` / `INCOMPLETE`
- **证据对象核对**：验证记录的 `HEAD` / `index tree`、当前 `HEAD` / `index tree` 是否一致；不一致时说明需重跑的验证
- **改动范围与契约对齐度**：简述本次 diff 覆盖的核心文件与验收条件对齐情况
- **发现清单**：按 `BLOCKER` → `MAJOR` → `MINOR` 排序（无问题则明确写“未发现阻断或高风险项”）
- **下一步**：`READY` 时建议进入 `ship-commit`；`INCOMPLETE` 时给出补齐验证的最小命令。

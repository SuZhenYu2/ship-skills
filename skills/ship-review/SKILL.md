---
name: ship-review
description: 提交前的独立风险审查门禁：对照 .ship/specs/ 与 git diff，按通用生产风险清单分级输出 BLOCKER/MAJOR/MINOR 与 READY/BLOCKED/INCOMPLETE 裁决，落盘 .ship/review/<slug>.md 审查记录。
---

# ship-review（提交前风险审查）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-review`，统一回显配置与计划策略，按共享协议执行并报告实际结果；失败暂停，不静默降级 off。候选派发及结果接收前重读状态，off 后取消运行请求，否则忽略结果。两路独立审查仍由 Lead 按证据裁决，不能以多数票跳过最终快照门禁。

## 核心原则

- 遵循 `references/dev-baseline.md`、`references/review-checklist.md` 与 `references/git-branch-policy.md`。
- 若项目 `AGENTS.md` 或 `references/stacks/` 配置了语言专项审查红线，一并纳入审查。
- **只看真实风险，不刷无意义风格意见**；在 Multi-Agent 模式下必须使用全新干净上下文（`Critic` / `Auditor`）执行，防止“自己写自己审”。
- **READY 只属于同任务、同树且证据齐全的改动**。有已知阻断时先判 `BLOCKED`，不因同时缺证而降为 `INCOMPLETE`。

## 执行步骤

1. **收集审查输入**
   - 读取关联的 spec/plan/fix、同 slug 的验证记录、`git status --short` 与 `git diff --cached`。核对范围及 Verify 的 `Tree` 与审查输入一致；Lead 采集 `git write-tree`，Critic 不执行该命令。
   - `.ship/` 记录保持未暂存；若其他路径存在未暂存修改或非忽略的未跟踪文件，列出路径交回 Lead，不签发 READY。
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
   - 如新增或修改应交付的测试，列出路径并交回 Lead；不得暂存或对改动后的工作区给出 READY。待 Lead 确认范围、按授权暂存并重新验证后复审。
4. **分级裁决**
   - 每条发现必须定位到 `<file>:<line>`，说明触发机理与最小修改建议，并标记 `BLOCKER` / `MAJOR` / `MINOR`。
   - **裁决规则**：
     - 存在 `BLOCKER`、Verify `FAIL` 或未接受的 `MAJOR` → `BLOCKED`。修复并重验、复审；MAJOR 如需延期，记录用户对具体发现、影响和延期范围的明确接受。授权提交不等于接受风险。
     - 无上述阻断，但缺少同任务、同树的 PASS 或必需审查证据（含 `PARTIAL`）→ `INCOMPLETE`，列出补齐命令。
     - 同任务同树 PASS、必需证据齐全且无阻断 → `READY`。READY 不授权 Git 写操作。
5. **落盘审查记录**
   - 按 `references/dev-baseline.md` 将 Status/Date/Tree/Commit/Slug/Scope、发现和接受依据写入 `.ship/review/<slug>.md`，包括失败裁决。提交前 `check-evidence.sh --mode handoff --repo . --slug <slug>` 读取该记录。
## 输出格式（对话输出 + 落盘记录）

- **审查裁决**：`READY` / `BLOCKED` / `INCOMPLETE`
- **审查证据对象**：输出本次实际审查快照的 `Tree` 与 `Scope`，并注明与 Verify 证据是否一致；不一致时说明需重跑的验证。不得用审后当前值替换审查输入。
- **改动范围与契约对齐度**：简述本次 diff 覆盖的核心文件与验收条件对齐情况
- **发现清单**：按 `BLOCKER` → `MAJOR` → `MINOR` 排序（无问题则明确写“未发现阻断或高风险项”）
- **下一步**：`READY` 时建议进入 `ship-commit`；`INCOMPLETE` 时给出补齐验证的最小命令。
- **落盘记录**：`.ship/review/<slug>.md` 路径与 Status。

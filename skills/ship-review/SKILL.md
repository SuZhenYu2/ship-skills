---
name: ship-review
description: 提交前的独立风险审查门禁：对照 .ship/specs/ 与 git diff，按通用生产风险清单分级输出 BLOCKER/MAJOR/MINOR 与 READY/BLOCKED/INCOMPLETE 裁决，落盘 .ship/review/<slug>.md 审查记录。
---

# ship-review（提交前风险审查）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-review`，统一回显配置与计划策略，按共享协议执行并报告实际结果；失败暂停，不静默降级 off。候选派发及结果接收前重读状态，off 后取消运行请求，否则忽略结果。两路独立审查仍由 Lead 按证据裁决，不能以多数票跳过最终快照门禁。

## Loop 入口与记账

读取 `references/loop-policy.md`，执行 `bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage ship-review`。失败或缺失已启用任务的状态时暂停；UNINITIALIZED 不自动 init/record。ACTIVE 时核对 Verify 交付的 task、cycle、round 与证据 slug，不重新领取轮次；TRIPPED/ESCALATED 不启动新尝试，不签发交付 READY。BLOCKED/INCOMPLETE 落盘后由 Lead 携带原 cycle/round、错误签名和实际证据路径 record blocked 一次；READY 时由 Lead 在快照授权范围内执行 `record --stage ship-review --outcome pass --slug <slug> --cycle <本轮cycle> --round <本轮序号>`。若 handoff 非零，不得宣称可提交或 Loop 已收敛；旧周期不得换新标签重试。CONVERGED 后若代码变化，须经确认 reset 后重验，不沿用旧收敛状态。

## 模式执行契约

`loop-state.sh status` 回显的 `mode-contract` 是本阶段硬约束：

- `single`：同一 Agent 审查，不派发子 Agent；仍须独立执行判别性测试，不得把实现时的结论直接复制为审查结论。
- `builder-critic`：由全新上下文的 `Critic` 执行审查与判别性测试；实现者不得自审，也不得修改业务代码。
- `multi-agent`：`Verifier` 与 `Auditor` 分别独立验收；`Auditor` 只读对照 `references/review-checklist.md`，结论冲突由 Lead 在最终快照裁决。

宿主不支持独立子 Agent 时暂停并请用户切换模式，不得伪造独立审查。

## 核心原则

- 遵循 `references/dev-baseline.md`、`references/review-checklist.md` 与 `references/git-branch-policy.md`。
- 若项目 `AGENTS.md` 或 `references/stacks/` 配置了语言专项审查红线，一并纳入审查。
- **只看真实风险，不刷无意义风格意见**；按上方模式执行契约使用独立上下文，防止“自己写自己审”。
- **READY 只属于同任务、同树且证据齐全的改动**。有已知阻断时先判 `BLOCKED`，不因同时缺证而降为 `INCOMPLETE`。

## 执行步骤

1. **收集审查输入**
   - 读取关联的 spec/plan/fix、同 slug 的验证记录与审查范围内的代码。核对 Verify 的 `Task/Cycle/Round/Tree` 与本次输入一致。
   - Git 项目读取 `git status --short` 与 `git diff --cached`，由 Lead 采集 `git write-tree`，Critic 不执行该命令；非 Git 项目读取工作区并采集内容快照，不执行 Git 命令。
   - `.ship/` 记录保持未暂存；Git 项目若其他路径存在未暂存修改或非忽略的未跟踪文件，列出路径交回 Lead，不签发 READY。非 Git 项目无法区分“已提交/未提交”，以内容快照与验证记录一致为准。
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
   - 按 `references/dev-baseline.md` 将 `Task/Cycle/Round` 等记录头、发现及接受依据写入 `.ship/review/<slug>.md`，包括失败裁决。Git 项目写 `Commit: pending`（`Vcs: git` 可省略）；非 Git 项目必须写 `Vcs: none`、`Commit: none`，`Tree` 使用与 Verify 相同的 64 位内容快照。`check-evidence.sh --mode handoff --repo . --slug <slug> --task <id>` 携带本轮 `--cycle/--round` 或经确认的 `--no-loop` 核对两份记录。
## 输出格式（对话输出 + 落盘记录）

- **审查裁决**：`READY` / `BLOCKED` / `INCOMPLETE`
- **审查证据对象**：输出本次实际审查快照的 `Tree` 与 `Scope`，并注明与 Verify 证据是否一致；不一致时说明需重跑的验证。不得用审后当前值替换审查输入。
- **改动范围与契约对齐度**：简述本次 diff 覆盖的核心文件与验收条件对齐情况
- **发现清单**：按 `BLOCKER` → `MAJOR` → `MINOR` 排序（无问题则明确写“未发现阻断或高风险项”）
- **下一步**：`READY` 且已启用的 Loop 成功记 `pass`，或明确未启用 Loop 时，建议进入 `ship-commit`；否则列出补证或升级动作。
- **落盘记录**：`.ship/review/<slug>.md` 路径与 Status。

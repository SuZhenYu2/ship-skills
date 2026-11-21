---
name: ship-verify
description: 声称完成、修复或可提交前的强制验证门禁：动态探测并执行项目真实的构建、测试与静态检查命令，输出原始证据与未覆盖范围，并落盘 .ship/verify/<slug>.md 验证记录。
---

# ship-verify（真实命令验证门禁）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-verify`，统一回显配置与计划策略，按共享协议执行并报告实际结果；失败暂停，不静默降级 off。候选派发及结果接收前重读状态，off 后取消运行请求，否则忽略结果。同一最终快照独立验证，事实不投票；最终整合快照必须重跑真实门禁，冲突命令串行执行。

## Loop 入口与交接

读取 `references/loop-policy.md`，执行 `bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage ship-verify`。失败暂停；UNINITIALIZED 不自动 init/record，且缺失已启用任务的状态时暂停。ACTIVE 时核对上游交付的 task、cycle 与 round，不因阶段切换增加轮次；直接进入时由 Lead 明确本轮标识。TRIPPED/ESCALATED 仅补充诊断或升级，不签发交付 PASS。FAIL/PARTIAL 落盘后，Lead 携带原 cycle/round、非空错误签名和证据路径 record fail/blocked 一次并结束本轮；PASS 不 record，连同标识与证据 slug 交给 Review。已记账的尝试不得在 Review 再记一次。

## 模式执行契约

`loop-state.sh status` 回显的 `mode-contract` 是本阶段的硬约束，不能当作已完成事实：

- `single`：同一 Agent 完成验证，不派发子 Agent；仍须真实运行命令并保留原始输出，不得以“已读代码”代替执行。
- `builder-critic`：必须派发全新上下文的 `Critic`，提供 spec/plan 路径、diff 与当前快照，要求至少执行一个判别性测试并返回原始命令、退出码与输出；实现者不得兼任 Critic。宿主不支持独立子 Agent 时暂停并请用户切换模式，不得伪造独立审查。
- `multi-agent`：`Verifier` 负责构建、测试与静态检查取证，`Auditor` 只读对照 `references/review-checklist.md` 审计；两者使用独立上下文，事实冲突由 Lead 在最终快照重跑裁决。

## 核心原则

- 遵循 `references/dev-baseline.md` 中的“证据优先原则”。
- **没有真实命令输出，就不得声称通过**。任何基于“肉眼检查”或“逻辑上应该没问题”的结论都不算验证通过。
- **绑定实际验证的代码树**：`Tree` 是快照标识，`Commit` 仅供追溯。

## 执行步骤

1. **记录证据对象**
   - Lead 确认任务与范围，按暂存授权仅暂存代码。检查 `git status --porcelain` 与暂存 diff；记录应留在 `.ship/` 未暂存，其他路径有未暂存或非忽略的未跟踪文件时，不得签发 PASS。
   - Lead 在验证前后采集 `git write-tree`；Critic/Verifier 只在交付的快照上运行命令，不运行 `git write-tree`，新增测试交回 Lead。
2. **确定验证命令**
   - 按以下优先级选择命令（语言无关）：
     1. 用户在当前对话指定的命令；
     2. 项目根目录 `AGENTS.md` 中声明的编译、测试、Lint / 静态检查命令；
     3. 自动探测项目构建文件（如 `pom.xml`、`build.gradle`、`package.json`、`go.mod`、`pyproject.toml`、`Cargo.toml`、`Makefile` 等）。
3. **执行验证并记录证据**
   - 依次运行：编译/类型检查 → 受影响模块的单元测试 →（按风险或用户要求）全量测试与静态检查。
   - 按上方的模式执行契约派发：`builder-critic` 与 `multi-agent` 不得由实现线程自行验证；`single` 不派发子 Agent。
   - Arena 默认由两路独立分析验证范围、Lead 协调命令；共享输出目录时串行，读取同一份输出只能称“两路分析、一次执行”。需要两次独立执行时，Lead 按 `references/arena-policy.md` 准备同一快照的独占副本，并记录执行者、快照、工作目录、退出码与输出；候选不能改原工作区或自行创建 worktree。
   - 验证过程中 代码树、验证范围或 `.ship/` 外工作区发生变化时，必须重新记录证据对象并对最终快照重跑，不能沿用旧结论。
4. **处理失败与缺口**
   - 任一命令失败时，直接报告失败命令、退出码与关键错误摘要，禁止静默忽略或跳过。
   - 若因环境限制（如缺少外部 DB/网络/凭据）导致部分检查无法运行，必须明确标注“未验证范围”。
   - 必需门禁未运行或未通过时，结论只能是 `PARTIAL` 或 `FAIL`；`PARTIAL` 不得被下游映射为 `PASS` 或 `READY`。
5. **落盘验证记录**
   - 按 `references/dev-baseline.md` 写入 `.ship/verify/<slug>.md`（包含 `Task/Cycle/Round`、命令证据表与未覆盖范围）；仅明确未启用 Loop 的任务可写 `Cycle: none`、`Round: none`。`FAIL` / `PARTIAL` 同样落盘，未通过不得交接。两份记录齐全后由 `check-evidence.sh --mode handoff --repo . --slug <slug> --task <id>` 携带本轮 `--cycle/--round` 或经确认的 `--no-loop` 核对。

## 输出格式（对话输出 + 落盘记录）

- **验证结论**：`PASS` / `FAIL` / `PARTIAL`（附未覆盖项说明）
- **证据对象**：`Tree=<实际验证树>`、任务 ID、slug、周期/轮次及验证范围；分开报告已暂存范围和未暂存/非忽略未跟踪内容。
- **命令证据表**：每条实际运行的命令、退出码、核心结果摘要（例如通过/失败用例数、耗时或关键日志行）。
- **未验证门禁**：`PARTIAL` 时列出未运行的门禁、原因与补齐命令
- **下一步建议**：全绿则进入 `ship-review`；失败则给出最直接的修复定位。
- **落盘记录**：`.ship/verify/<slug>.md` 路径与 Status。

---
name: ship-auto
description: 检查当前仓库状态、Git 分支合规性与 .ship/ 文档，完成 L1/L2/L3 难度评估与工具模式路由，推荐下一步最合适的 ship-* Skill 与受控 Loop 配置，不自动代执行其他 Skill。
---

# ship-auto（状态感知、难度评估与工具路由）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 与 Loop 只读入口

1. 读取 `references/arena-policy.md` 与 `references/loop-policy.md`，按以下规则确认仓库根 `<root>` 与任务 `<id>`：
   - 仓库根用 `git rev-parse --show-toplevel` 获取；位于子目录时不要用当前目录代替。
   - 已有 `.ship/tasks/*/loop.json` 或 `arena.json` 时，列出候选让用户选择，禁止猜“全局 active task”。
   - 新任务且没有现成 ID 时，从任务标题提炼 kebab-case 候选 slug（小写字母、数字、单个短横线，≤100 字符），检查 `.ship/tasks/` 无冲突后展示给用户确认；确认后**任务 ID 默认等于任务 slug**，Loop、Arena 与证据 `Task` 共用该值。
   - 用户明确不启用 Loop 时仍使用该 slug 作为 `Task`；提交走 `--no-loop`，记录写 `Cycle/Round: none`。
   - 飞书 `<req-id>` 不能自动生成；缺失时仍按 `references/git-branch-policy.md` 阻断。
2. 分别执行只读状态查询（不写文件），保留脚本实际回显（仅表示配置与当前状态，不代表已执行候选或循环）：

   ```bash
   bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-auto
   bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage ship-auto
   ```

3. 任一脚本状态损坏、依赖缺失或读取失败必须暂停并报告，不得静默降级；本阶段仅做只读导航与路由建议，除用户确认后的 Loop init 外不派发候选、不改写状态文件。

## 核心原则

- 遵循 `references/dev-baseline.md`、`references/git-branch-policy.md` 与 `references/loop-policy.md`。
- **只评估、只推荐，不代执行**：本 Skill 只读取状态、给出难度定级、工具路由和下一步建议命令，严禁自动链式触发其他 Skill、自动开启 `ship-arena` 或修改代码/Git 状态；唯一例外是用户确认启用 Loop 后执行 `loop-state.sh init`。
- **L2/L3 默认启用 Loop**：定级为 L2 或 L3 时默认引导确认启用；L1 可选。用户明确跳过时，后续提交必须 `--no-loop` 且证据写 `Cycle/Round: none`，不得以“状态缺失”冒充未启用。

## 执行步骤

1. **检查 Git 状态与分支合规性**
   - 先运行 `git rev-parse --is-inside-work-tree`。非 Git 项目跳过分支与 `<req-id>` 检查，报告 `vcs=none`，直接进入步骤 2。
   - Git 项目优先调用 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode branch`（或执行只读 `git branch --show-current` / `git status --short` / `git log -n 3 --oneline`）。
   - 对照 `references/git-branch-policy.md` 校验当前分支是否合规；若处于 `main` / `master` 且存在未提交改动，优先提示切换合规分支。
   - Git 项目尝试从分支名末尾提取飞书需求 ID（`<req-id>`）候选。
2. **检查 `.ship/` 黑板与长期文档**
   - 检查 `.ship/specs/`、`.ship/plans/`、`.ship/fixes/`、`.ship/verify/`、`.ship/review/`，以及根目录 `CONTEXT.md` 与 `docs/adr/`。
   - 读取文档头 `Status`：`DRAFT` / `STUCK` 不得直接推荐实现；`APPROVED` 只代表方案通过，不代表代码或测试完成；`IMPLEMENTED` / `FIXED` 仍需验证与审查证据。
3. **L1 / L2 / L3 难度评估与工具模式路由**
   - 对照 `references/loop-policy.md` 的 4 个可观测维度（改动范围、需求确定性、问题复杂度、可逆性）定级，遵循“取最高命中档位”原则；信息不足时保守上调或先提示补齐信息。
   - 按档位输出工具与编排模式建议：
     - **L1（低难度）**：推荐 `single`（单路直出 + 轻量验证 Loop，`max_rounds=2`），`ship-arena` 默认 `OFF`。
     - **L2（中难度）**：推荐 `builder-critic`（轻量 SDD + 写审分离，DSH 排障可配 `ralph`，`max_rounds=2`），`ship-arena` 按需可选。
     - **L3（高难度）**：推荐 `multi-agent`（`ship-grill` → `ship-plan` 契约冻结 + 互斥白名单并行 + 独立验收，`max_rounds=2`），建议用户显式评估是否开启 `ship-arena`。
   - **启用闭环**：L2/L3 默认启用，L1 可选。向用户展示 level/mode/budget 与 `loop-state.sh init` 命令并请求确认；确认后立即执行 init（会写本地 `info/exclude`），用户明确跳过时记录为“明确未启用”，后续提交按 `--no-loop` 处理。
   - 若 `loop-state.sh status` 显示 `UNINITIALIZED`，先区分任务未启用还是本地状态缺失。已启用但状态缺失时暂停并建议恢复或重新取证，不得用 `--no-loop` 绕过。
4. **判断当前阶段并给出唯一推荐**
   - 若 Loop 状态为 `TRIPPED` → 优先建议 `loop-state.sh escalate` 或交由用户拍板，不建议直接 reset 或提交新代码。若为 `ESCALATED`，待用户确认再建议 reset。
   - 需求存在关键缺口、隐藏假设或涉及不可逆权衡/术语对齐（常见于 L3）→ 推荐 **`ship-grill`**（只需快速写 spec 则推荐 `ship-spec`）。
   - 已有 spec 但涉及多模块/高风险改动且无 plan → 推荐 `ship-plan`。
   - 正在排查 Bug / 故障且未定位根因 → 推荐 `ship-fix`。
   - 方案已明确、待编写代码与测试 → 推荐 `ship-tdd`（L3 提示按 `docs/multi-agent-policy.md` 拆分）。
   - 已有代码改动但尚未跑验证 → 推荐 `ship-verify`。
   - 验证已通过、准备提交前 → 推荐 `ship-review`。
   - 当前任务、当前树存在 `BLOCKER`、Verify `FAIL` 或未接受的 `MAJOR` → 先处理阻断，不推荐提交。
   - 审查为 `INCOMPLETE`（必需验证门禁未运行或为 `PARTIAL`）→ 补验证后复审，不推荐 `ship-commit`。
   - 同任务同树验证 `PASS` 且审查 `READY` 时，已启用 Loop 须先核对同周期/轮次并收敛；明确未启用的任务走 `--no-loop`。满足后才建议 `ship-commit`，仍由该阶段执行正式门禁。
   - 代码 C 和配对证据 E 均已提交、准备提 PR / 收尾 → 推荐 `ship-finish`。新 clone 缺本地 Loop 不影响对已提交证据的核验。

## 输出格式（仅对话输出，不生成文件）

- **当前状态**：VCS 模式（`git` / `none`）、分支名（合规/不合规，非 Git 为不适用）、提取到的 `<req-id>`、工作区改动摘要、`.ship/` 文档状态，以及 `arena-state.sh` / `loop-state.sh` 原始回显。
- **难度评估与工具路由**：定级结论（`L1` / `L2` / `L3`）、命中依据、推荐 `mode`、`ship-arena` 建议，以及（未初始化时）可直接复制的 `loop-state.sh init` 命令。
- **Loop 决策**：明确写出“建议启用 / 明确跳过”、用户是否已确认，以及实际执行或待执行的 init 命令。
- **推荐下一步**：唯一推荐的 Skill 名称 + 可直接复制的下一条指令（结束时声明：除用户确认后的 Loop init 外，本次执行为只读导航）。
- **风险提醒**（如有）：分支不合规、缺少需求 ID、Loop 已 `TRIPPED` 或存在未验证改动时明确标出。

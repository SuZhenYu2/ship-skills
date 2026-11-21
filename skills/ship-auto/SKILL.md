---
name: ship-auto
description: 检查当前仓库状态、Git 分支合规性与 .ship/ 文档，完成 L1/L2/L3 难度评估与工具模式路由，推荐下一步最合适的 ship-* Skill 与受控 Loop 配置，不自动代执行其他 Skill。
---

# ship-auto（状态感知、难度评估与工具路由）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 与 Loop 只读入口

1. 读取 `references/arena-policy.md` 与 `references/loop-policy.md`，确认仓库根 `<root>` 与任务 `<id>`；不明确先询问，不猜全局 active task。
2. 分别执行只读状态查询（不写文件），保留脚本实际回显（仅表示配置与当前状态，不代表已执行候选或循环）：

   ```bash
   bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-auto
   bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage ship-auto
   ```

3. 任一脚本状态损坏、依赖缺失或读取失败必须暂停并报告，不得静默降级；本阶段仅做只读导航与路由建议，不派发候选、不初始化或改写状态文件。

## 核心原则

- 遵循 `references/dev-baseline.md`、`references/git-branch-policy.md` 与 `references/loop-policy.md`。
- **只评估、只推荐，不代执行**：本 Skill 只读取状态、给出难度定级、工具路由和下一步建议命令，严禁自动链式触发其他 Skill、自动开启 `ship-arena` 或修改代码/Git 状态。

## 执行步骤

1. **检查 Git 状态与分支合规性**
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode branch`（或执行只读 `git branch --show-current` / `git status --short` / `git log -n 3 --oneline`）。
   - 对照 `references/git-branch-policy.md` 校验当前分支是否合规；若处于 `main` / `master` 且存在未提交改动，优先提示切换合规分支。
   - 尝试从分支名末尾提取飞书需求 ID（`<req-id>`）候选。
2. **检查 `.ship/` 黑板与长期文档**
   - 检查 `.ship/specs/`、`.ship/plans/`、`.ship/fixes/`、`.ship/verify/`、`.ship/review/`，以及根目录 `CONTEXT.md` 与 `docs/adr/`。
   - 读取文档头 `Status`：`DRAFT` / `STUCK` 不得直接推荐实现；`APPROVED` 只代表方案通过，不代表代码或测试完成；`IMPLEMENTED` / `FIXED` 仍需验证与审查证据。
3. **L1 / L2 / L3 难度评估与工具模式路由**
   - 对照 `references/loop-policy.md` 的 4 个可观测维度（改动范围、需求确定性、问题复杂度、可逆性）定级，遵循“取最高命中档位”原则；信息不足时保守上调或先提示补齐信息。
   - 按档位输出工具与编排模式建议：
     - **L1（低难度）**：推荐 `single`（单路直出 + 轻量验证 Loop，`max_rounds=2`），`ship-arena` 默认 `OFF`。
     - **L2（中难度）**：推荐 `builder-critic`（轻量 SDD + 写审分离，DSH 排障可配 `ralph`，`max_rounds=2`），`ship-arena` 按需可选。
     - **L3（高难度）**：推荐 `multi-agent`（`ship-grill` → `ship-plan` 契约冻结 + 互斥白名单并行 + 独立验收，`max_rounds=2`），建议用户显式评估是否开启 `ship-arena`。
   - 若 `loop-state.sh status` 显示 `UNINITIALIZED`，给出可直接复制的 `loop-state.sh init` 建议命令（提醒写操作会追加 `/.ship/tasks/` 到本地 `info/exclude`）；若显示 `TRIPPED`，优先阻止继续重试并提示执行 `escalate` 或回退 `ship-plan`。
4. **判断当前阶段并给出唯一推荐**
   - 若 Loop 状态为 `TRIPPED` → 优先推荐执行 `loop-state.sh escalate` 并回退 `ship-plan` 或交由用户拍板，不推荐盲目重试。
   - 需求存在关键缺口、隐藏假设或涉及不可逆权衡/术语对齐（常见于 L3）→ 推荐 **`ship-grill`**（只需快速写 spec 则推荐 `ship-spec`）。
   - 已有 spec 但涉及多模块/高风险改动且无 plan → 推荐 `ship-plan`。
   - 正在排查 Bug / 故障且未定位根因 → 推荐 `ship-fix`。
   - 方案已明确、待编写代码与测试 → 推荐 `ship-tdd`（L3 提示按 `docs/multi-agent-policy.md` 拆分）。
   - 已有代码改动但尚未跑验证 → 推荐 `ship-verify`。
   - 验证已通过、准备提交前 → 推荐 `ship-review`。
   - 当前任务、当前树存在 `BLOCKER`、Verify `FAIL` 或未接受的 `MAJOR` → 先处理阻断，不推荐提交。
   - 审查为 `INCOMPLETE`（必需验证门禁未运行或为 `PARTIAL`）→ 补验证后复审，不推荐 `ship-commit`。
   - 同任务同树验证 `PASS` 且审查 `READY`、准备生成提交信息 → 推荐 `ship-commit`。
   - 已完成全部提交、准备提 PR / 收尾 → 推荐 `ship-finish`。

## 输出格式（仅对话输出，不生成文件）

- **当前状态**：分支名（合规/不合规）、提取到的 `<req-id>`、工作区改动摘要、`.ship/` 文档状态，以及 `arena-state.sh` / `loop-state.sh` 原始回显。
- **难度评估与工具路由**：定级结论（`L1` / `L2` / `L3`）、命中依据、推荐 `mode`、`ship-arena` 建议，以及（未初始化时）可直接复制的 `loop-state.sh init` 命令。
- **推荐下一步**：唯一推荐的 Skill 名称 + 可直接复制的下一条指令（结束时明确声明本次实际执行为只读导航）。
- **风险提醒**（如有）：分支不合规、缺少需求 ID、Loop 已 `TRIPPED` 或存在未验证改动时明确标出。

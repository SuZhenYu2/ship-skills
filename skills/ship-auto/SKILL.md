---
name: ship-auto
description: 检查当前仓库状态、Git 分支合规性与 .ship/ 文档，推荐下一步最合适的 ship-* Skill，不自动代执行其他 Skill。
---

# ship-auto（状态感知与下一步导航）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-auto`，按共享协议统一回显配置与计划策略（不是执行事实）。失败暂停并报告，不静默降级 off；本阶段仅导航，不派发候选，结束时明确报告实际执行为只读导航。

## 核心原则

- 遵循 `references/dev-baseline.md` 与 `references/git-branch-policy.md`。
- **只推荐，不代执行**：本 Skill 只读取状态并给出下一步建议命令，严禁自动链式触发其他 Skill 或修改代码/Git 状态。

## 执行步骤

1. **检查 Git 状态与分支合规性**
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode branch`（或执行只读 `git branch --show-current` / `git status --short` / `git log -n 3 --oneline`）。
   - 对照 `references/git-branch-policy.md` 校验当前分支是否合规；若处于 `main` / `master` 且存在未提交改动，优先提示切换合规分支。
   - 尝试从分支名末尾提取飞书需求 ID（`<req-id>`）候选。
2. **检查 `.ship/` 黑板与长期文档**
   - 检查 `.ship/specs/`、`.ship/plans/`、`.ship/fixes/`、`.ship/verify/`、`.ship/review/`，以及根目录 `CONTEXT.md` 与 `docs/adr/`。
   - 读取文档头 `Status`（枚举与语义见 `references/dev-baseline.md`）：spec `DRAFT` / `STUCK` 或 plan `DRAFT` / `REVISE` 不得直接推荐实现；spec `ALIGNED` / plan `APPROVED` 只代表方案对齐，不代表代码或测试完成；`IMPLEMENTED` / `FIXED` 仍需验证与审查记录证据。
3. **判断当前阶段并给出唯一推荐**
   - 需求存在关键缺口、隐藏假设或涉及不可逆权衡/术语对齐 → 推荐 **`ship-grill`**（只需快速写 spec 则推荐 `ship-spec`）。
   - 已有 spec 但涉及多模块/高风险改动且无 plan → 推荐 `ship-plan`。
   - 正在排查 Bug / 故障且未定位根因 → 推荐 `ship-fix`。
   - 方案已明确、待编写代码与测试 → 推荐 `ship-tdd`（复杂多模块可同时提示按 `docs/multi-agent-policy.md` 拆分）。
   - 已有代码改动但尚未跑验证 → 推荐 `ship-verify`。
   - 验证已通过、准备提交前 → 推荐 `ship-review`。
   - 审查为 `INCOMPLETE`（必需验证门禁未运行或为 `PARTIAL`）→ 补验证后复审，不推荐 `ship-commit`。
   - verify 记录非 `PASS` 或 review 记录非 `READY`（含记录缺失）→ 推荐补跑 `ship-verify` / `ship-review`，不推荐 `ship-commit` / `ship-finish`。
   - 审查已 `READY`、准备生成提交信息 → 推荐 `ship-commit`。
   - 已完成全部提交、准备提 PR / 收尾 → 推荐 `ship-finish`。

## 输出格式（仅对话输出，不生成文件）

- **当前状态**：分支名（合规/不合规）、提取到的 `<req-id>`、工作区改动摘要、已发现的 `.ship/` 与 `CONTEXT.md` 文档。
- **推荐下一步**：唯一推荐的 Skill 名称 + 可直接复制的下一条指令。
- **风险提醒**（如有）：分支不合规、缺少需求 ID 或存在未验证改动时明确标出。

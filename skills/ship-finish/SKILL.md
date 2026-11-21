---
name: ship-finish
description: 验证与审查通过后的分支收尾：优先调用确定性脚本核验分支命名与全部 commit 的飞书需求 ID 合规性，检查验证/审查记录、生成 PR 说明并按授权收尾。
---

# ship-finish（分支收尾与交付准备）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-finish`，统一回显配置与计划策略（不是执行事实），结束时报告实际结果；失败暂停，不静默降级 off。本阶段按共享协议独立复核交付证据；所有 Git 收尾仅 Lead 串行执行，开关不授予任何 Git 写权限。

## 核心原则

- 严格遵循 `references/git-branch-policy.md` 与 `references/dev-baseline.md`。
- **Multi-Agent 红线**：本 Skill 仅限主 Agent（`Lead`）执行；`rebase`、`merge`、`push`、删分支均须获得用户明确授权。

## 反偷懒红线（Red Flags）

- **禁止靠肉眼抽检历史 commit**：必须逐条校验 `<base>..HEAD` 全部提交（优先运行 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode range --base <target-base>`），哪怕中间夹了 1 条缺 `<req-id>` 的提交也必须判 `BLOCKED`。
- **禁止忽略“提交说明与实际 diff 不符”**：顺手核对 `git diff --stat <base>..HEAD` 与提交描述是否一致，发现空壳占位提交或未忽略的构建缓存直接提醒。

## 执行步骤

1. **确定性前置门禁检查**
   - 运行 `git status --short` 确认 `.ship/` 外干净；未提交的记录不能作为收尾证据。
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode range --base <target-base>`（若脚本不可用则逐条读取 `git log <base>..HEAD` 对照正则核验），校验当前分支与全部提交的飞书需求 ID。`<target-base>` 默认来源见 `references/git-branch-policy.md`，未指明时向用户确认。
2. **核对任务最终快照的已提交证据**
   - 确认唯一任务 slug，运行 `bash <skill-dir>/scripts/check-evidence.sh --mode finish --repo . --base <base> --slug <slug>`。只读 HEAD 中该 slug 的 verify/review；不得用工作区文件或对话替代。脚本缺失或非零退出即 `BLOCKED`。
   - `TaskTip` 为区间内最后一个非证据提交（没有则取 HEAD）。两份记录必须为 PASS/READY，`Tree` 都等于 `TaskTip^{tree}`，且有同一仅改 `.ship/` 的证据提交包含两份记录。中间提交只校验消息，不逐条索证。
   - 仅改提交消息不因 `Commit` 过期而失效；树改变需对最终代码快照重验、复审，再按独立授权固化证据，不重新提交相同代码。
3. **生成 PR / 合并说明草稿**
   - 包含：关联飞书 `<req-id>`、分支与目标基线、变更摘要、验证证据与未覆盖范围、风险与回滚方案。
4. **列出待授权收尾命令**
   - 如有阻断项，先给出最小修复步骤（如 `git rebase -i` 补齐需求 ID、清理缓存、补跑验证审查）；未获授权前绝不执行任何 Git 写操作。

## 输出格式（仅对话输出，不生成文件）

- **收尾结论**：`READY` 或 `BLOCKED`
- **收尾体检表**：工作区状态、分支合规性、基线同步状态、Commit 需求 ID 逐条校验结果、验证与审查状态、证据对象与 `TaskTip^{tree}` 的一致性
- **PR / 合并说明草稿**
- **待确认动作**：需用户授权后执行的 Git 收尾命令清单

---
name: ship-finish
description: 验证与审查通过后的分支收尾：优先调用确定性脚本核验分支命名与全部 commit 的飞书需求 ID 合规性，检查验证/审查记录、生成 PR 说明并按授权收尾。
---

# ship-finish（分支收尾与交付准备）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## 核心原则

- 严格遵循 `references/git-branch-policy.md` 与 `references/dev-baseline.md`。
- **Multi-Agent 红线**：本 Skill 仅限主 Agent（`Lead`）执行；`rebase`、`merge`、`push`、删分支均须获得用户明确授权。

## 反偷懒红线（Red Flags）

- **禁止靠肉眼抽检历史 commit**：必须逐条校验 `<base>..HEAD` 全部提交（优先运行 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode range --base <target-base>`），哪怕中间夹了 1 条缺 `<req-id>` 的提交也必须判 `BLOCKED`。
- **禁止忽略“提交说明与实际 diff 不符”**：顺手核对 `git diff --stat <base>..HEAD` 与提交描述是否一致，发现空壳占位提交或未忽略的构建缓存直接提醒。

## 执行步骤

1. **确定性前置门禁检查**
   - 运行 `git status --short` 确认工作区干净（无未提交改动、无未忽略的 `.ship/` 或构建缓存）。
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode range --base <target-base>`（若脚本不可用则逐条读取 `git log <base>..HEAD` 对照正则核验），校验当前分支与全部提交的飞书需求 ID。`<target-base>` 默认来源见 `references/git-branch-policy.md`，未指明时向用户确认。
2. **核对验证与审查记录（仅凭仓库内文件）**
   - 对 `<base>..HEAD` 每条提交的完整 SHA（`git log --pretty=%H`），在 `.ship/verify/` 与 `.ship/review/` 中查找含 `> Commit: <sha>` 的记录，且 Status 分别为 `PASS` 与 `READY`（记录契约见 `references/dev-baseline.md`）。
   - 任一提交缺记录或 Status 不符，标记为阻断项并提醒补跑 `ship-verify` / `ship-review` 后重新绑定；不依赖对话记忆放行。
3. **生成 PR / 合并说明草稿**
   - 包含：关联飞书 `<req-id>`、分支与目标基线、变更摘要、验证证据与未覆盖范围、风险与回滚方案。
4. **列出待授权收尾命令**
   - 如有阻断项，先给出最小修复步骤（如 `git rebase -i` 补齐需求 ID、清理缓存、补跑验证审查）；未获授权前绝不执行任何 Git 写操作。

## 输出格式（仅对话输出，不生成文件）

- **收尾结论**：`READY` 或 `BLOCKED`
- **收尾体检表**：工作区状态、分支合规性、基线同步状态、Commit 需求 ID 逐条校验结果、验证与审查状态
- **PR / 合并说明草稿**
- **待确认动作**：需用户授权后执行的 Git 收尾命令清单

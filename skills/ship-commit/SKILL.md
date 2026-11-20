---
name: ship-commit
description: "校验当前分支与暂存区改动，优先调用确定性脚本检查分支与飞书需求 ID 规范，生成 <type>(<req-id>): <scope> <subject> 提交信息；未获授权不执行提交。"
---

# ship-commit（提交规范校验与消息生成）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## 核心原则

- 严格遵循 `references/git-branch-policy.md` 与 `references/dev-baseline.md`。
- **生成消息 ≠ 通过 Review ≠ 授权提交**；仅当用户明确授权且**零阻塞警告**时才执行 `git commit`。
- **Multi-Agent 红线**：本 Skill 仅限主 Agent（`Lead`）执行，子 Agent 严禁调用。

## 反偷懒红线（Red Flags）

- **禁止编造或偷借历史需求 ID**：分支和当前对话均无 `<req-id>` 时，绝不可擅自沿用 `git log` 里的旧需求 ID 或填占位符提交，必须阻断并向用户索要。
- **禁止在 `main` / `master` 直接提交**：发现处于受保护基线分支必须硬阻断。

## 执行步骤

1. **确定性分支校验与工作区检查**
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode branch`（若脚本不在当前仓库路径，则直接执行等价只读 `git branch --show-current` 并对照 `references/git-branch-policy.md` 正则校验）。
   - 查看 `git status --short` 与 `git diff --cached`；若暂存区为空，提示先确认暂存范围，并指出混入的无关文件或调试残留。
2. **提取并核对飞书需求 ID（`<req-id>`）**
   - 优先从合规分支末尾提取 `<req-id>`；若对话中显式提供新 ID 且与分支不一致，必须先向用户确认。
3. **生成并校验 Commit Message**
   - 格式：`<type>(<req-id>): <scope> <subject>`。
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --mode commit-msg --message "<msg>"` 验证正则通过。
4. **按授权决定是否提交**
   - 存在任何阻塞项（基线分支、缺 `<req-id>`、暂存区为空）或未获提交授权时：只输出校验结果、建议 message 与解锁确认项，**不执行 `git commit`**。
5. **绑定提交与证据记录**
   - 提交前核对记录 Diff-Hash 与本次暂存内容一致（`git diff --cached HEAD | shasum -a 256`，Linux 用 `sha256sum`）；不一致说明证据过期，先重跑 `ship-verify` / `ship-review`。
   - 获授权且 `git commit` 成功后，向本次改动对应的 `.ship/verify/<slug>.md` 与 `.ship/review/<slug>.md` 追加 `> Commit: <新提交完整 SHA>`（`git rev-parse HEAD`，记录契约见 `references/dev-baseline.md`）。
   - 若对应记录缺失，提醒先补跑；无记录的提交在 `ship-finish` 会判 `BLOCKED`。

## 输出格式（对话输出；授权提交后向证据记录追加 Commit 绑定）

- **分支与需求 ID 校验**：当前分支状态、`<req-id>` 来源
- **建议 Commit Message**：单行代码块
- **提醒项**（如有）：未跑 `ship-review`、暂存区为空、混入无关文件或调试代码时显式提示
- **证据绑定**（授权提交成功后）：已向哪些 verify/review 记录追加 `> Commit: <SHA>`

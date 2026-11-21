---
name: ship-commit
description: "校验当前分支与暂存区改动，优先调用确定性脚本检查分支与飞书需求 ID 规范，生成 <type>(<req-id>): <scope> <subject> 提交信息；未获授权不执行提交。"
---

# ship-commit（提交规范校验与消息生成）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-commit`，统一回显配置与计划策略（不是执行事实），结束时报告实际结果；失败暂停，不静默降级 off。本阶段始终仅 Lead 串行执行，不派发竞争候选；开关不授予任何 Git 写权限。

## 核心原则

- 严格遵循 `references/git-branch-policy.md` 与 `references/dev-baseline.md`。
- **生成消息 ≠ 通过 Review ≠ 授权提交**；仅当用户明确授权且**零阻塞警告**时才执行 `git commit`。
- **只暂存代码**：不得混入 `.ship/` 记录；`.ship/` 外有未暂存修改或非忽略的未跟踪文件时停止，不擅自 `git add` 或 `git stash`。
- **Multi-Agent 红线**：本 Skill 仅限主 Agent（`Lead`）执行，子 Agent 严禁调用。

## 反偷懒红线（Red Flags）

- **禁止编造或偷借历史需求 ID**：分支和当前对话均无 `<req-id>` 时，绝不可擅自沿用 `git log` 里的旧需求 ID 或填占位符提交，必须阻断并向用户索要。
- **禁止在 `main` / `master` 直接提交**：发现处于受保护基线分支必须硬阻断。

## 执行步骤

1. **确定性分支校验与工作区检查**
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --repo . --mode branch`（若脚本不在当前仓库路径，则直接执行等价只读 `git branch --show-current` 并对照 `references/git-branch-policy.md` 正则校验）。
   - 查看 `git status --short` 与 `git diff --cached`；若暂存区为空，提示先确认暂存范围，并指出混入的无关文件或调试残留。
2. **核对任务与待提交树**
   - 按 `references/loop-policy.md`，创建代码提交前运行 `bash <skill-dir>/scripts/loop-state.sh --repo . --task <id> gate --slug <slug>`。该命令会执行证据 handoff，核对暂存树、同任务同轮的 PASS/READY 与收敛记录；非零退出、脚本缺失或证据不符均阻断。不能只跑 handoff 代替 gate。
   - `UNINITIALIZED` 不自动放行；仅当确认任务未启用 Loop 才附加 `--no-loop`，旧记录另需 `--allow-legacy`。已启用但状态缺失则恢复状态或经确认建立新周期并重验，不按未启用处理。
   - 若 Critic 新增或修改了测试，接收其文件清单；由 Lead 确认纳入范围并按授权暂存，再针对最终快照重新验证与复审。不得自行忽略新增测试或借用旧结论。
3. **提取并核对飞书需求 ID（`<req-id>`）**
   - 优先从合规分支末尾提取 `<req-id>`；若对话中显式提供新 ID 且与分支不一致，必须先向用户确认。
4. **生成并校验 Commit Message**
   - 格式：`<type>(<req-id>): <scope> <subject>`。
   - 优先调用 `<skill-dir>/scripts/check-git-policy.sh --mode commit-msg --message "<msg>"` 验证正则通过。
5. **创建代码提交 C**
   - 门禁通过且有明确代码提交授权才执行；否则仅报告门禁结果、建议消息与缺项。风险接受不是暂存或提交授权。
   - 紧邻 `git commit` 前重跑步骤 2 的 gate，确认暂存树自上次检查后未变化；gate 输出中的 tree 才是本次提交的授权快照。
   - C 创建后立即核对 `git rev-parse C^{tree}` 与 gate 输出的 tree 一致；不一致说明提交了未经门禁检查的树，停止后续操作并报告，不自行 amend 或补证。
6. **单独固化证据 E**
   - 若 C 已存在、当前只有证据待固化，走本步骤，不重走代码提交。核对当前 HEAD 为待固化的 C、无暂存代码，并重新核验两份记录；已启用 Loop 时 gate 仍须通过且绑定 `C^{tree}`。只更新 `> Commit:` 为 C 的完整 SHA，不改 `Task/Cycle/Round/Tree`。树不符则重验、复审，不回填树值或重复提交代码。
   - 明确取得证据暂存与证据提交授权，才将本任务的两份记录一起固化；核对暂存路径均在 `.ship/` 内且不含 `.ship/tasks/`。E 的消息同样走步骤 4，例如 `chore(<req-id>): ship 记录 <slug> 验证与审查证据`。E 不需要为自己再生成证据。

## 输出格式

- 报告分支、需求 ID、任务 slug、handoff 结果与建议消息。
- 分别报告 C、E 是否已获授权和实际创建；若只有 C，说明证据尚未固化，不宣称可收尾。

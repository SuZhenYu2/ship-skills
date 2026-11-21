---
name: ship-arena
description: 管理指定仓库、指定任务的 Arena on/off/status 开关，显示各 ship 阶段计划策略；不自动派发候选、实现业务或授权 Git 操作。
---

# ship-arena（任务级开关）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## 入口与操作

1. 读取 `references/dev-baseline.md` 与 `references/arena-policy.md`。确认目标 Git 工作区根 `<root>`、任务 `<id>` 与操作 `on|off|status`；任务 ID 不超过 100 字符，仅含小写字母/数字及分隔短横线。输入不明确先确认，不猜全局 active task。未要求切换时仅查询 status。
2. on/off 前先确认任务并披露：脚本除写 `.ship/tasks/<id>/arena.json`，还会将 `/.ship/tasks/` 追加至 Git 本地 `info/exclude`，不改业务 `.gitignore`。若用户禁止本地 Git 元数据写入，先说明冲突并确认。无需前置 status，也不递归调用自身；由 Lead 仅执行用户选择的一条：

   ```bash
   bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> on --stage ship-arena
   bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> off --stage ship-arena
   ```

3. 查询时直接执行：

   ```bash
   bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-arena
   ```

   用户指定查看阶段时，以 `status --stage ship-plan` 等显示对应计划策略。保留脚本实际回显，如 `[ship-plan] Arena: ON | 范围: <id> | 计划策略: 双候选方案比选`；这不是候选已经执行的证明。
4. 报告实际命令与退出结果、受影响任务和生效边界。缺文件为 off；损坏、依赖缺失或命令失败均明确报错并暂停，不静默降级，不手工覆盖坏状态文件。

## 边界

- 开启从下一阶段生效；各阶段及新派发边界重读状态。关闭后不派发新候选，对运行中请求尝试取消，否则忽略其后续结果；不回滚已有产物。
- 开启后按共享阶段策略选择性使用两个候选，不默认并行业务实现；提交、暂存及 Git 收尾仍仅 Lead 在授权范围内串行执行。开关仅影响该任务。
- 可用自然语言请求：“用 ship-arena 为仓库 <root> 的任务 order-timeout 开启 Arena / 关闭 Arena / 查看状态”。这是 Skill 入口约定，不代表 Codex 原生提供斜杠命令或 UI 按钮。
- 本入口不派发候选，不自动调用下一 Skill；配置成功不代表阶段执行成功。

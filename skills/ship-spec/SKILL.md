---
name: ship-spec
description: ship-grill --spec-only 的轻量快捷入口：快速对齐需求关键缺口并落盘 .ship/specs/<slug>.md，不修改 CONTEXT.md 或生成 ADR。
---

# ship-spec（轻量需求契约入口）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

> 本 Skill 等价于 **`ship-grill --spec-only`**。当你需要对想法做深度压力测试、对齐长期业务术语（`CONTEXT.md`）或沉淀架构决策（`docs/adr/`）时，优先使用 **`ship-grill`**。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-spec`，统一回显配置与计划策略，按共享协议执行并报告实际结果；失败暂停，不静默降级 off。候选派发及结果接收前重读状态，off 后取消运行请求，否则忽略结果。复用 ship-grill 规则时仍保留 ship-spec 阶段身份，不重复派发候选。

## 执行规则

优先读取同安装目录下的 `../ship-grill/SKILL.md`（若未安装则按本文件规则独立执行），遵循其全部流程与反偷懒红线，固定启用 `--spec-only` 约束：
1. 读取项目 `AGENTS.md`、`CONTEXT.md`（如有）与受影响模块接口；
2. 仅聚焦 **3~5 个**会引发返工的核心问题（每题附推荐默认值），未对齐前 0 行业务代码改动；
3. 对齐后只落盘 `.ship/specs/<slug>.md`，**不修改 `CONTEXT.md`，也不生成 `docs/adr/`**。

---
name: ship-plan
description: 针对复杂、跨模块或高风险任务产出实施方案，完成共享契约冻结、文件白名单划分、回滚策略与测试矩阵，落盘到 .ship/plans/<slug>.md。
---

# ship-plan（实施方案与契约冻结）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-plan`，统一回显配置与计划策略，按共享协议执行并报告实际结果；失败暂停，不静默降级 off。候选派发及结果接收前重读状态，off 后取消运行请求，否则忽略结果。已确认的候选结论直接纳入方案，不无故重复比选。

## 适用场景

- 跨模块改造、核心业务逻辑调整、持久化结构变更、或计划启用 Multi-Agent 并行实现的任务。
- 优先复用已有的 `.ship/specs/<slug>.md`；如无 spec，需先在对话中确认目标与验收标准。

## 执行步骤

1. **影响面测绘**
   - 遵循 `references/dev-baseline.md` 与 `docs/multi-agent-policy.md`。
   - 对大型仓库可并行派发 2~3 个只读 `Scout` 分别摸清：入口与调用链、数据模型与存储访问、现有测试与依赖配置。
2. **明确契约冻结边界（Contract Freeze）**
   - 列出所有共享契约文件（共享接口/类型定义、DTO/Schema、迁移脚本、构建配置文件），明确这些文件必须由 `Lead` 在第一阶段串行修改并验证可编译。
3. **拆解实现步骤与文件白名单**
   - 将任务拆成小而可验证的步骤。
   - 若准备并行派发多个 `Builder`，必须为每个子任务分配**严格互斥**的文件/目录白名单，并确认构建输出目录或测试端口不会互相抢占。
4. **落盘 Plan 文档**
   - 写入 `.ship/plans/<slug>.md`，必须包含：
     - **文档头**：`> Status: DRAFT | APPROVED | REVISE`、`> Source: <spec 路径或需求>`
     - **关联 Spec 与飞书 `<req-id>`**
     - **契约冻结清单（Stage 1，串行）**
     - **模块改动拆解与文件白名单（Stage 2）**
     - **数据迁移、向后兼容与回滚方案**
     - **测试与验证矩阵**（单元测试、边界/异常测试、集成/回归测试及对应命令）
     - **主要风险与缓解措施**

## 完成标准

- `.ship/plans/<slug>.md` 已落盘，步骤清晰、边界无重叠，未直接修改业务代码。

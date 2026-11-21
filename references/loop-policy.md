# 难度路由与受控 Loop 共享协议（Loop Policy）

本协议定义 `ship-skills` 任务级难度定级（`L1` / `L2` / `L3`）、执行工具/编排模式路由以及基于 `scripts/loop-state.sh`（零第三方依赖 TypeScript，Node.js 原生运行）的确定性受控循环规则。本协议不替代原有验证、审查、快照一致性与 Git 授权门禁。

## 1. 任务绑定与状态读取

- 先确认目标 Git 工作区根 `<root>` 与任务 `<id>`（`[a-z0-9]+(?:-[a-z0-9]+)*`，最长 100 字符）；任务不明确时先确认，禁止从分支或“全局 active task”猜测。
- 只读查看当前循环状态（不创建文件）：

  ```bash
  bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage <ship-stage>
  ```

- 缺文件时输出 `UNINITIALIZED`；状态文件损坏、字段/版本非法、符号链接越界或 Node.js 不可用均硬失败（退出码 `1`）并暂停，不得静默重置。
- 所有写操作（`init` / `record` / `escalate` / `reset`）会原子更新 `<root>/.ship/tasks/<id>/loop.json`，并将 `/.ship/tasks/` 追加至 Git 本地 `info/exclude`（不改业务 `.gitignore`）。执行写操作前须披露该本地元数据写入；它不包含任何提交、暂存或分支修改授权。

## 2. L1 / L2 / L3 难度定级与工具路由

采用**木桶升级原则**：按以下 4 个维度评估，命中任一高档信号即按最高档定级；信息不足时先追问关键缺口或保守上调一档，禁止乐观降档绕过门禁。

| 维度 | L1（低难度） | L2（中难度） | L3（高难度） |
| --- | --- | --- | --- |
| **改动范围** | 单文件或局部函数，无对外接口变化 | 跨多文件，内部行为或接口微调 | 跨模块、共享契约、持久化 Schema 或构建配置 |
| **需求确定性** | 目标与验收明确，无歧义 | 局部边界或异常规则待对齐 | 存在隐性假设、术语歧义或不可逆架构权衡 |
| **问题复杂度** | 逻辑直观，本地单测直出 | 需补边界/回归测试或定位单一根因 | 并发竞态、资金/权限核心链路、偶发线上故障 |
| **可逆性** | 完全局部可逆 | 可回滚但影响上下游调用方 | 涉及数据迁移、持久化或外部协议兼容 |

定级后按路由表推荐工具模式与默认 Loop 预算（仅输出建议，不擅自修改 `arena.json` 或自动执行下游 Skill）：

| 难度 | 前置阶段 | 推荐 `mode` | `ship-arena` 建议 | 默认预算 |
| --- | --- | --- | --- | --- |
| **L1** | 跳过 `ship-grill` / `ship-plan` | `single`（单 Agent 直出） | 默认 `OFF` | `max_rounds=2` |
| **L2** | `ship-spec` 或 `ship-fix` | `builder-critic`（实现 + 独立 `Critic`；DSH 排障可配 `ralph`） | 按需可选 | `max_rounds=2` |
| **L3** | `ship-grill` → `ship-plan`（契约冻结） | `multi-agent`（`Scout` + 契约冻结 + 互斥白名单 `Builder` + 独立验收） | 建议 `ON`（用户显式开启） | `max_rounds=2` |

## 3. 受控 Loop 五条铁律

1. **真实证据退出**：仅当真实构建/测试退出码为 `0` 且 `ship-verify=PASS`、`ship-review=READY` 时，才允许执行 `record --outcome pass` 收敛退出（状态转为 `CONVERGED`）。
2. **失败信号驱动**：每次 `fail` / `blocked` 必须提供规范化的 `--error-sig` 与 `--evidence` 路径；下一轮只针对上一轮失败信号收敛，禁止无差异重试。
3. **双条件硬熔断（退出码 `2`）**：达到 `max_rounds` 上限，或连续 2 轮标准化 `error_hash` 相同（`stall_count >= 2`）时，`loop-state.sh record` 返回退出码 `2` 并将状态置为 `TRIPPED`。
4. **熔断后强制升级**：状态为 `TRIPPED` 时禁止继续 `record`；必须汇总失败输出与已证伪假设，调用 `escalate --target <ship-plan|user> --reason <说明>` 升级处理。
5. **动态升级与重开周期**：若执行中发现实际风险高于初判，或方案重定后经用户确认重新开始，必须显式执行 `reset --level <L> --mode <M> --max-rounds <N>` 刷新 `cycle` 标识；禁止在 `TRIPPED` 状态下手工改写 `loop.json` 绕过熔断。

## 4. 统一回显与正交边界

- 保留脚本实际输出，不伪造执行事实：

  ```text
  [ship-tdd] Loop: ACTIVE | 范围: order-timeout | 难度: L2 | 模式: builder-critic | 轮次: 1/2
  cycle=<32位十六进制标识>
  ```

- 与 `ship-arena` 正交协作：同时开启 Arena 时，每轮接收候选结果前仍须执行 `arena-state.sh check --generation <gen>`，两套状态互不覆盖、互不替代。

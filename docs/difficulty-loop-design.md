# difficulty-loop 设计：任务难度路由与受控执行循环

> 范围：任务级难度定级（L1 / L2 / L3）、编排模式建议、Loop 状态机与交付门禁。`mode` 不代表宿主已派发 Agent；运行事实以脚本结果与验证证据为准。

## 1. 定位与设计原则

`difficulty-loop` 用于把 `ship-skills` 现有的三块能力串成一条闭环：**前置难度评估**（承接 `references/dev-baseline.md` 风险分级）、**工具/编排模式路由**（衔接单路、`docs/multi-agent-policy.md` 与 `ship-arena`）、以及**确定性受控 Loop**（把文字版“2 轮熔断”下沉为脚本化状态机）。

核心边界：

- **不替代原有门禁**：保留验证（`ship-verify`）、审查（`ship-review`）、快照校验和 Git 写操作授权。提交前检查当前 Loop 是否收敛，收尾只认证已提交的任务最终树与证据。
- **不打破控制权**：`ship-auto` 仍坚持“只评估、只推荐，不代执行”；是否切换模式、是否开启 `ship-arena` 均由用户确认。
- **任务严格隔离**：状态按仓库与任务 `<id>` 隔离存放，任务不明确先确认，禁止猜测全局 active task。
- **确定性熔断**：轮次计数、同错停滞检测与熔断状态由 `scripts/loop-state.sh` 硬校验，不依赖模型在长上下文中口头数轮次。

## 2. L1 / L2 / L3 难度评估模型（Difficulty Triage）

动手前由 `ship-auto` 按 4 个可观测维度定级，遵循**“木桶升级原则”**——只要命中任一高档信号即向上定级，不取平均；信息不足时先追问关键缺口或保守上调一档，禁止乐观降档绕过门禁。

| 评估维度 | L1（低难度 / 低风险） | L2（中难度 / 中风险） | L3（高难度 / 高风险） |
| --- | --- | --- | --- |
| **改动范围** | 单文件或局部函数，无对外接口变化 | 跨多个文件，涉及内部行为或接口微调 | 跨模块、共享契约、持久化 Schema 或构建配置变更 |
| **需求确定性** | 目标与验收标准明确，无业务歧义 | 存在局部边界条件或异常规则待对齐 | 存在隐性假设、术语歧义或不可逆架构权衡 |
| **问题复杂度** | 逻辑直观，本地单测可直接验证 | 需补边界/回归测试，或需定位单一根因 | 并发竞态、资金/权限核心链路、偶发线上故障 |
| **可逆性** | 完全局部可逆，回滚成本极低 | 可回滚，但影响上下游调用方 | 涉及数据迁移、持久化结构或外部协议兼容 |

### 动态升级规则

- 执行过程中若发现实际影响面超出初判（如触及共享契约、并发状态机或持久化变更），必须显式调用 `loop-state.sh` 升级档位并重选工具模式，补齐缺失的前置文档（如 `ship-plan`）。
- 禁止在测试失败或审查受阻时“降档跳过审查”。

## 3. 难度到工具与编排模式的路由表

定级后直接映射前置准备、执行工具模式与 Loop 预算：

| 难度 | 前置阶段 | 推荐工具 / 编排模式（`mode`） | `ship-arena` 建议 | Loop 形态与默认预算 |
| --- | --- | --- | --- | --- |
| **L1** | 跳过 `ship-grill` / `ship-plan` | `single`（单 Agent 直出实现与自测） | 默认 `OFF`（不建议开启） | 若启用，仍按 `Act → Verify → Review` 计轮，`max_rounds=2` |
| **L2** | `ship-spec`（新需求）或 `ship-fix`（排障） | `builder-critic`（单路实现 + 干净上下文 `Critic` 独立验收；DSH 排障可结合 `ralph`） | 按需可选（复杂根因时可开） | 实现-验收收敛循环：`Act → Verify/Review → Fix`，`max_rounds=2` |
| **L3** | `ship-grill` → `ship-plan`（契约冻结与文件白名单） | `multi-agent`（`Scout` 摸底 + 契约冻结 + 互斥白名单 `Builder` + `Verifier`/`Auditor` 分离验收） | 建议 `ON`（用于方案、根因与双视角审查比选） | Loop 仅统计实现与验收，`max_rounds=2`；设计复核由 `ship-plan` 单独记录 |

> 与 `ship-arena` 的正交约定：路由表只输出建议，不自动修改 `.ship/tasks/<id>/arena.json`；是否开启 Arena 仍由用户通过 `ship-arena` 显式操作，且 Arena 仍保持默认不并行业务实现。

### 启用闭环

L2 / L3 默认启用 Loop，L1 可选。`ship-auto` 输出 level/mode/budget 与 `init` 命令，经用户确认后执行 `init`；用户明确跳过时，后续提交必须 `--no-loop` 且证据写 `Cycle/Round: none`。状态文件缺失不等于未启用，不得据此绕过。

### 模式执行契约

`status` 回显的 `mode-contract` 是执行要求而非事实。`single` 不派发子 Agent；`builder-critic` 的 Verify/Review 必须使用全新上下文 `Critic` 并附判别性测试原始输出；`multi-agent` 的 `Scout`、`Builder`、`Verifier`、`Auditor` 按互斥白名单与独立验收执行。宿主无独立子 Agent 时暂停改档，不得静默降级或伪造独立审查。

## 4. `scripts/loop-state.sh` 状态机接口

由 Bash 入口调用 TypeScript（Node.js 原生运行，零第三方依赖）后端；`record pass` 与 `gate` 复用需要 Python 3.9+ 的证据检查脚本：

- `--repo <root>` 必须指向 Git 工作区根目录；任务 `<id>` 匹配 `[a-z0-9]+(?:-[a-z0-9]+)*`，最长 100 字符。
- 状态路径：`<root>/.ship/tasks/<id>/loop.json`；禁止路径上出现任何符号链接。
- 写操作（`init` / `record` / `escalate` / `reset`）使用同目录临时文件与原子重命名，并沿用 `git rev-parse --git-path info/exclude` 维护 `/.ship/tasks/`，不修改业务 `.gitignore`（写入前须披露）。
- `status` 只读，不创建文件；缺文件报告 `UNINITIALIZED`；文件损坏、版本或字段非法、环境缺失均硬失败（退出码 `1`）并暂停，不静默重置。

### 4.1 状态文件 Schema（`.ship/tasks/<id>/loop.json`）

```json
{
  "version": 1,
  "task": "order-timeout",
  "cycle": "a1b2c3d4e5f60718293a4b5c6d7e8f90",
  "level": "L2",
  "mode": "builder-critic",
  "status": "ACTIVE",
  "round": 1,
  "max_rounds": 2,
  "stall_count": 1,
  "last_error_hash": "9f86d081884c7d65",
  "history": [
    {
      "round": 1,
      "stage": "ship-verify",
      "outcome": "fail",
      "error_hash": "9f86d081884c7d65",
      "evidence": ".ship/verify/order-timeout.md"
    }
  ]
}
```

状态枚举（`status`）：

- `ACTIVE`：处于受控循环中，可继续推进下一轮。
- `CONVERGED`：PASS/READY 已核对同一 `Task/Cycle/Round/Tree`，只允许将该快照用于提交门禁。
- `TRIPPED`：触发硬熔断（`round >= max_rounds` 或连续 2 轮 `error_hash` 相同导致 `stall_count >= 2`），禁止 `record`、`gate` 放行或直接 `reset`。
- `ESCALATED`：已记录升级去向（回退 `ship-plan` 或交由用户拍板），等待新决策后方可 `reset`。

### 4.2 命令行接口

```bash
# 1. 初始化任务难度、工具模式与轮次预算（默认 max_rounds=2，允许 1..5）
bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> init \
  --level L2 --mode builder-critic --max-rounds 2

# 2. 只读查看当前状态（不写文件）
bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage ship-tdd

# 3. 记录本轮真实门禁结果并判定是否继续 / 收敛 / 熔断
bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> record \
  --stage ship-verify --outcome fail --cycle <本轮cycle> --round <本轮序号> \
  --error-sig "AssertionError: timeout status expected CANCELLED" \
  --evidence .ship/verify/order-timeout.md

# 4. 熔断后显式记录升级动作
bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> escalate \
  --target ship-plan --reason "连续两轮在并发锁边界失败，需重审契约"

# 5. 方案重定或档位升级后开启新周期（刷新 cycle，清空当前轮次）
bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> reset \
  --level L3 --mode multi-agent --max-rounds 2

bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> gate --slug <slug>
```

`gate` 不暂存代码、不提交、不写 Loop 状态。仅确认任务未启用时才传 `--no-loop`；旧记录另需 `--allow-legacy`。收尾不调用此 gate，而由 `check-evidence.sh --mode finish` 核对 HEAD 中的配对证据，不依赖本地状态。

### 4.3 退出码与统一回显约定

- 退出码：
  - `0`：操作成功，且当前状态允许继续或已正常 `CONVERGED`。
  - `1`：参数非法、非 Git 根、符号链接越界、状态文件损坏或非法状态迁移（如 `TRIPPED` 状态下强行 `record`）。
  - `2`：`record` 触发硬熔断（状态转为 `TRIPPED`），调用方必须立即停止循环并转入升级流程。
- 统一回显（与 `arena-state.sh` 风格对齐，区分状态事实与下一步建议）：

```text
[ship-tdd] Loop: ACTIVE | 范围: order-timeout | 难度: L2 | 模式: builder-critic | 轮次: 1/2
cycle=a1b2c3d4e5f60718293a4b5c6d7e8f90
mode-contract: builder-critic | 实现与验收分离；Critic 必须使用全新上下文，至少执行一个判别性测试并附原始输出
```

## 5. 受控 Loop 执行约束与 Runtime 映射

### 5.1 五条执行铁律

1. **真实证据退出**：只有真实构建/测试退出码为 `0` 且 `ship-verify=PASS`、`ship-review=READY` 才允许写入 `--outcome pass` 退出循环。
2. **失败信号驱动**：每轮只能围绕上一轮 `record` 的具体失败证据收敛，禁止无差异重试。
3. **双条件硬熔断**：`round >= max_rounds` 或连续两轮标准化 `error_hash` 相同（`stall_count >= 2`）立即返回退出码 `2` 熔断。
4. **范围与快照护栏**：每轮结束核对 `git diff` 未越出文件白名单；若同时开启 `ship-arena`，同步执行 `arena-state.sh check` 防开关或快照漂移。
5. **显式升级出口**：熔断后必须汇总“已尝试改动 + 原始失败输出 + 已证伪假设”，调用 `escalate` 回退 `ship-plan` 或上报用户拍板。

### 5.2 Codex 与 DSH 落地映射

| 能力环节 | Codex 落地方式 | DeepSeek Harness (DSH) 落地方式 |
| --- | --- | --- |
| **难度评估与路由** | `ship-auto` 读取仓库状态后输出 L1/L2/L3 与建议模式 | 同上，由主会话确认后初始化 `loop-state.sh` |
| **L1 / L2 循环执行** | 主会话或单 `Builder` 配合干净 `Critic` subagent，每轮结束由 Lead 调用 `loop-state.sh record` | 常规实现同 Codex；复杂排障可结合原生 `ralph` 迭代，并由 `loop-state.sh` 做硬熔断兜底 |
| **L3 并行与比选** | 契约冻结后按白名单派发 subagent（可配 managed worktree），按需配合 `ship-arena` | 原生 `subagent` 并行 + 按需 `ship-arena`；跑偏时通过 `interrupt_agent` 及时止损 |

## 6. 验收与后续范围

以 `references/loop-policy.md`、脚本及实际命令证据为准：

- **脚本回归**：`scripts/test-loop-state.sh` 检查熔断、升级、证据串用、缺失状态、提交门禁与 `mode-contract` 回显；`scripts/test-evidence.sh` 检查证据配对、新旧兼容以及新 clone 收尾。
- **宿主行为**：路由值不是编排执行证据；实际独立审查、派发和工作区隔离须单独验证。Loop 状态由 Lead 串行写入，不提供并发锁或自动调度。

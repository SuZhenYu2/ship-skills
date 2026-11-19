# Multi-Agent 协作协议（Multi-Agent Policy）

本协议定义 `ship-skills` 在支持多 Agent 的运行环境（**Codex**、**DeepSeek Harness / DSH** 等）下的角色划分、权限边界、交接契约、熔断机制与 Runtime 映射。

## 1. 什么时候用 Multi-Agent，什么时候不用

- **不要强行拆分**：单文件、小范围、低风险改动直接由主 Agent 单线程完成，避免交接损耗大于收益。
- **高性价比并行场景**（优先级从高到低）：
  1. **并行只读探索**：接手新需求或查 Bug 前，并发派 2~3 个 `Scout` 摸底调用链、数据模型与历史测试。
  2. **写审隔离**：代码写完后，用**全新干净上下文**拉起 `Critic` 做独立边界测试、构建取证和风险审计，消除“自己写自己审”的盲区。`Critic` 不能只做静态阅读，必须对最高风险边界执行至少一个判别性测试或最小复现，并附原始结果。
  3. **复杂故障排障**：拉起 `Investigator` 专攻根因证伪与最小复现，防止主线程盲目打表面补丁。
  4. **契约冻结后的多模块并行实现**：仅当共享契约已冻结、编译通过且各子任务目录严格互斥时，才并行派发多个 `Builder`。

## 2. 弹性角色体系（默认 1 + 3，高风险按需扩展）

### 核心角色（日常 90% 场景）

| 角色 | 定位 | 写权限边界 | 执行语义 | 关联 Skill |
| --- | --- | --- | --- | --- |
| **Lead（主 Agent）** | 唯一对外沟通、需求对齐、契约冻结、任务拆分与裁决、**独占 Git 写操作** | 全局（整合与收尾阶段） | 主会话编排 | `ship-auto` / `ship-spec` / `ship-plan` / `ship-commit` / `ship-finish` |
| **Scout** | 只读代码侦察与影响面测绘（入口、调用链、数据结构、依赖、现有测试） | **只读（`NONE`）** | `Isolated Read-Only Fan-out` | `ship-spec` / `ship-plan` / `ship-fix` 前置摸底 |
| **Builder** | 严格按 `.ship/specs/` 与 `.ship/plans/` 在白名单内实现功能与基础单测 | **仅白名单路径**（禁改共享契约、构建配置与 Git） | `Scoped Write` | `ship-tdd` / `ship-fix`（修复阶段） |
| **Critic** | 干净上下文独立验收：对照 `spec` 补边界/回归测试、跑真实构建验证、按风险清单审计 diff，并对最高风险边界执行判别性测试 | **仅测试目录可写**（严禁修改业务源码） | `Clean-Room Audit` | `ship-verify` / `ship-review` |

### 按需扩展角色（复杂 / 高风险场景）

- **`Investigator`（专职排障）**：面对疑难 Bug 或线上事故时启用；采用 `Bounded Iterative Debug` 语义做假设证伪与根因定位，只读源码（可选仅在测试目录写最小复现），不直接修改业务代码。
- **`Critic` 拆分（`Verifier` + `Auditor`）**：遇到大型高风险改动时，可将 `Critic` 拆为两个并行干净子 Agent——`Verifier` 专跑构建、测试与静态检查取证，`Auditor` 纯只读对照 `references/review-checklist.md` 做深度风险审计。

## 3. 四条不可违背的铁律

1. **契约冻结关卡（Contract Freeze）**：共享接口、DTO/Schema、持久化迁移脚本、全局构建配置文件（如 `pom.xml`、`build.gradle`、`package.json`、`go.mod`）必须先由 `Lead` 串行定稿并验证可编译，之后才允许派发多个 `Builder` 并行写各自模块。
2. **文件所有权互斥**：同一时刻严禁两个 `Builder` 修改同一批文件；若在单工作区并行且构建工具存在共享输出目录或端口冲突，应改为串行验证或使用独立 Git worktree 隔离。
3. **Git 权力严格集中**：所有子 Agent 一律禁止执行 `git commit`、`checkout`、`branch`、`rebase`、`merge`、`push`、`reset`、`clean`。只有 `Lead` 在验证与审查通过并获用户授权后，统一按 `references/git-branch-policy.md` 提交和收尾。
4. **2 轮熔断与单向裁决**：
   - 同一个 `BLOCKER` 或失败测试最多允许「`Builder` 修复 → `Critic` 复验」**2 轮**。
   - 第 2 轮仍未收敛时，强制停止循环，退回 `Lead` 重新审视 `.ship/plans/<slug>.md` 或上报用户拍板。
   - 禁止子 Agent 之间互相辩论；出现意见分歧一律由 `Lead` 对照 `spec` 裁决，超出 `spec` 范围则交由用户决定。
   - `Critic` 的 `READY` 以 `Verifier` 证据齐全为前提；必需门禁缺失或为 `PARTIAL` 时输出 `INCOMPLETE`，不得放行提交。

## 4. 强制委派契约模板（Task Contract）

`Lead` 每次派发子 Agent 时，必须提供完整、自包含的 5 项任务契约（并直接引用 `.ship/` 黑板文件路径，避免口头转述失真）：

```markdown
### Task Contract
- **Role**: Scout | Builder | Critic | Investigator
- **Goal & Blackboard Refs**: <明确目标>；参考 `.ship/specs/<slug>.md`、`.ship/plans/<slug>.md`
- **Writable Ownership**: `NONE`（只读）或明确的白名单目录/文件列表
- **Forbidden Actions**:
  - 禁止任何 Git 写操作
  - 禁止修改白名单之外的任何文件
  - 禁止编造测试或验证结果
- **Required Evidence**:
  - Scout: 入口/调用链/受影响数据与配置/风险点/关键文件路径列表
  - Builder: 改动文件清单、实现要点、自测命令与原始结果
  - Critic: 至少一个针对最高风险边界的判别性测试或最小复现及原始结果、按 BLOCKER/MAJOR/MINOR 分级的审查结论（READY/BLOCKED/INCOMPLETE）
  - Investigator: 最小复现步骤/用例、假设证伪过程、Root Cause 证据链、建议修复范围
```

## 5. Runtime 映射表（Codex 与 DSH）

协议本身保持工具中立，在不同运行时按以下方式落地：

| 执行语义 | Codex 落地方式 | DeepSeek Harness (DSH) 落地方式 |
| --- | --- | --- |
| `Isolated Read-Only Fan-out`（`Scout` 并行摸底） | 默认 subagent 并行派发 2~3 个只读任务；需限流时在 `config.toml` 配置 `[agents].max_concurrent_threads_per_session` | 使用原生 `subagent` 并行派发独立上下文；结构固定的批量审计可用 `workflow` |
| `Scoped Write`（`Builder` 受限实现） | 单任务 subagent + 白名单；多路写码优先配合 managed Git worktree 隔离工作区 | 使用 `subagent`（必要时配独立子进程后端隔离）；单工作区并行需确保目录与测试端口互斥 |
| `Clean-Room Audit`（`Critic` 独立验收） | 启动全新独立 subagent（不带实现过程杂音），仅传 `spec` 路径与 `git diff` | 使用全新 `subagent`（不要用 `subagent_fork`，避免继承实现者的思维惯性） |
| `Bounded Iterative Debug`（`Investigator` 排障） | 独立 subagent 配合明确迭代轮次上限 | 优先使用原生 `ralph` 做防死循环迭代收敛；跑偏时用 `interrupt_agent` + `send_message` 纠偏 |

> 并发建议：无论 Codex 还是 DSH，单次并行子 Agent 建议控制在 **2~4 个**，兼顾响应速度、Token 成本与人工可 Review 的改动体量。

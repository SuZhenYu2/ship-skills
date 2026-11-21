# 难度路由与受控 Loop 共享协议（Loop Policy）

本协议定义 `ship-skills` 任务级难度定级（`L1` / `L2` / `L3`）、执行工具/编排模式路由以及基于 `scripts/loop-state.sh`（零第三方依赖 TypeScript，Node.js 原生运行）的确定性受控循环规则。本协议不替代原有验证、审查、快照一致性与 Git 授权门禁。

## 1. 任务绑定与状态读取

- 仓库根用 `git rev-parse --show-toplevel` 获取，必须指向工作区根目录。
- 任务 `<id>` 匹配 `[a-z0-9]+(?:-[a-z0-9]+)*`，最长 100 字符。已有 `.ship/tasks/*/loop.json` 或 `arena.json` 时列出候选让用户选择，禁止从分支或“全局 active task”猜测。
- 新任务没有现成 ID 时，从任务标题提炼 kebab-case 候选 slug，检查 `.ship/tasks/` 无冲突后展示给用户确认；确认后**任务 ID 默认等于任务 slug**，Loop、Arena 与证据 `Task` 共用该值。
- 用户明确不启用 Loop 时仍使用该 slug 作为 `Task`；提交走 `--no-loop`，记录写 `Cycle/Round: none`。飞书 `<req-id>` 不自动生成，缺失时按 `references/git-branch-policy.md` 阻断。
- 只读查看当前循环状态（不创建文件）：

  ```bash
  bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage <ship-stage>
  ```

- 缺文件时输出 `UNINITIALIZED`；状态文件损坏、字段/版本非法、符号链接越界或 Node.js 不可用均硬失败（退出码 `1`）并暂停，不得静默重置。
- 所有写操作（`init` / `record` / `escalate` / `reset`）会原子更新 `<root>/.ship/tasks/<id>/loop.json`，并维护 Git 本地 `info/exclude` 中的 `/.ship/tasks/`，将精确匹配的旧 `/.ship/` 规则迁移为该规则（不改业务 `.gitignore`）。执行写操作前须披露该本地元数据写入；它不包含任何提交、暂存或分支修改授权。
- `ship-tdd` / `ship-fix` / `ship-verify` / `ship-review` 入口读取状态。`UNINITIALIZED` 不自动 init 或 record；已知任务启用或交接带轮次却找不到状态时暂停，不按未启用处理。`TRIPPED` / `ESCALATED` 暂停新一轮实现，交由 Lead 升级与用户确认重开。`CONVERGED` 只代表已记录快照；后续改码须经确认 reset 后重验、复审。

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

### 模式执行契约

`status` 会回显当前 `mode` 的 `mode-contract`，下游阶段必须按它执行，不能把 `mode` 当作已完成事实：

- `single`：单 Agent 完成实现与验证，不派发子 Agent；仍须真实运行命令并保留原始输出。
- `builder-critic`：实现与验收分离；`ship-verify` / `ship-review` 必须派发全新上下文的 `Critic`，至少执行一个判别性测试并附原始命令、退出码与输出；实现者不得自审。
- `multi-agent`：`Scout` 只读摸底，Lead 冻结契约后按互斥白名单派发 `Builder`；`Verifier` 负责构建/测试取证，`Auditor` 只读审查，两者独立。

宿主不支持独立子 Agent 时暂停并请用户改档，不得把 `builder-critic` / `multi-agent` 静默降级为单路，也不得伪造独立审查。

### 启用闭环

- L2 / L3 默认启用 Loop；L1 可选。`ship-auto` 给出 level/mode/budget 与 init 命令，经用户确认后执行 `init`。
- 用户明确跳过时，后续提交走 `--no-loop`，证据写 `Cycle/Round: none`；不得因状态文件缺失自动视为未启用。

## 3. 受控 Loop 五条铁律

1. **证据一致性退出**：Lead 确认真正执行过的必需构建/测试通过、`ship-verify=PASS` 且 `ship-review=READY` 后，才可在 `ship-review` 阶段执行 `record --outcome pass --slug <slug>`。脚本复用 `check-evidence.sh --mode handoff` 检查当前 Tree、PASS/READY、slug 和 `Task/Cycle/Round`；失败不更新状态，通过后才转为 `CONVERGED`。该校验执行 `git write-tree`，仅 Lead 在既有暂存/快照授权内调用。脚本核验身份与快照，不独立证明命令真实执行。
2. **失败信号驱动**：每次 `fail` / `blocked` 必须提供非空规范化的 `--error-sig` 与指向实际非空常规文件的 `--evidence` 路径（相对路径以仓库根解析）；下一轮只针对上一轮失败信号收敛，禁止无差异重试。
3. **双条件硬熔断（退出码 `2`）**：达到 `max_rounds` 上限，或连续 2 轮标准化 `error_hash` 相同（`stall_count >= 2`）时，`loop-state.sh record` 返回退出码 `2` 并将状态置为 `TRIPPED`。
4. **熔断后强制升级**：状态为 `TRIPPED` 时禁止 `record` 或直接 `reset`；必须汇总失败输出与已证伪假设，调用 `escalate --target <ship-plan|user> --reason <说明>`。到达 `ESCALATED` 后，Lead 获用户确认才重开。
5. **动态升级与重开周期**：若执行中发现实际风险高于初判，或方案重定后经用户确认重新开始，必须显式执行 `reset --level <L> --mode <M> --max-rounds <N>` 刷新 `cycle` 标识；禁止在 `TRIPPED` 状态下手工改写 `loop.json` 绕过熔断。

### 一轮与记录责任

一轮是“一次实现/修复 → Verify → Review”的一次尝试，由 Lead 串行记录一次终态。L3 的设计复核由 `ship-plan` 按需在方案内记录，不进 Loop。预期的 TDD Red 和根因探索也不逐条计轮。实现阻塞、Verify FAIL/PARTIAL 或 Review BLOCKED/INCOMPLETE 可提前结束本轮；Verify PASS 继续 Review，Review READY 且证据一致后才 record pass。

本轮开始时固定 `cycle` 与 `round=已完成轮次+1` 并随阶段交接，record 必须原样提供 `--cycle`、`--round`。旧周期或已记账轮次会被拒绝，不得改成当前值重试；转入下一次实际修复才开始下一轮。阶段切换不递增轮次，候选不得独立 record。若部分检查失败已结束本轮，不再为同一尝试在 Review 重复记账。

```bash
bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> record \
  --cycle <本轮cycle> --round <本轮序号> --stage ship-verify \
  --outcome fail --error-sig <规范化错误> --evidence <失败记录路径>

bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> record \
  --cycle <本轮cycle> --round <本轮序号> --stage ship-review \
  --outcome pass --slug <本次任务证据slug>
```

以上是互斥终态示例。脚本防止串行交接中的重复或过期记录，不提供多进程调度与并发写锁；由 Lead 保证单写者。Multi-Agent 修复轮次与此处为同一轮，预算取更严格者；Arena 空产物等重派使用自身的一次预算，不重置 Loop。

## 4. 统一回显与正交边界

- 保留脚本实际输出，不伪造执行事实：

  ```text
  [ship-tdd] Loop: ACTIVE | 范围: order-timeout | 难度: L2 | 模式: builder-critic | 轮次: 1/2
  cycle=<32位十六进制标识>
  mode-contract: builder-critic | 实现与验收分离；Critic 必须使用全新上下文，至少执行一个判别性测试并附原始输出
  ```

- 与 `ship-arena` 正交协作：同时开启 Arena 时，每轮接收候选结果前仍须执行 `arena-state.sh check --generation <gen>`，两套状态互不覆盖、互不替代。

## 5. 提交与收尾

- `ship-commit` 执行 `bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> gate --slug <slug>`。`ACTIVE`、`TRIPPED`、`ESCALATED` 均不允许提交新代码。`CONVERGED` 仍要以本轮最后一次 `pass` 重新核对暂存树及同任务、同周期、同轮的 PASS/READY；gate 不写本地状态，不暂存或提交。
- `UNINITIALIZED` 默认阻断。仅用户确认该任务未启用 Loop，才能加 `--no-loop` 并复核 `Cycle: none`、`Round: none`；兼容旧记录时另加 `--allow-legacy`。有本地 Loop 状态，或记录绑定了真实周期时，不得通过兼容模式。
- `ship-finish` 核验已提交的配对证据及最终代码树，不读取本地 Loop。证据未固化不能收尾；成功的 finish 只认证该已提交快照，不批准本地的新一轮实现。记录格式、两阶段授权与兼容规则见 `references/dev-baseline.md`。
- 非 Git 项目：gate 仍校验 Loop 收敛与内容快照，但不创建 C/E、不 push；finish 省略 `--base`，用当前 64 位内容快照核对两份记录。

## 6. 非 Git 项目

- `loop-state.sh` / `arena-state.sh` 接受非 Git 项目根；不创建 `.git`，也不写 `info/exclude`。
- 交付凭证：`check-evidence.sh --mode snapshot --repo .` 输出 64 位 SHA-256 内容快照，覆盖工作区常规文件与符号链接，排除 `.git/`、`.ship/tasks/`、`.ship/verify/`、`.ship/review/` 和 `.DS_Store`。
- 证据记录必须写 `Vcs: none`、`Commit: none`，`Tree` 使用内容快照；handoff、gate 与 finish 都用同一快照核对。
- 非 Git finish 不传 `--base`，用当前快照核对两份记录；不执行 commit / push / PR。该凭证只证明工作区内容与验证时一致，不具备已提交历史的不可变性。
- Arena 候选的 `snapshot.head` 写 `none`，`worktree` 写 64 位内容指纹。

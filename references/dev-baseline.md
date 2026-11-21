# 通用研发基线（Dev Baseline）

本文件是所有 `ship-*` Skill 共同遵守的底层规则。各 Skill 只需补充本阶段的专属步骤，不重复抄写基线。

## 0. 任务级 Arena 入口

- 所有 ship 阶段先执行 `references/arena-policy.md`：确认仓库根和任务 ID（ship-arena 的 on/off 直接执行动作，无需前置 status），其他入口调用 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage <ship-stage>`；任务不明先询问，不猜全局 active task。
- on/off 会向 Git 本地 `info/exclude` 追加 `/.ship/tasks/`，不修改业务 `.gitignore`；执行前披露该元数据写入，用户禁止时先确认冲突。
- 统一保留脚本回显（如 `[ship-plan] Arena: ON | 范围: <id> | 计划策略: 双候选方案比选`），并将实际执行另行报告；状态读取失败必须暂停，不得静默当作 off。缺文件才默认 off。
- on/off 在阶段及新候选派发边界生效；off 后停止新派发，对运行请求尝试取消，否则忽略结果。Arena 不默认并行业务实现，不改变原有门禁；所有 Git 写操作仅 Lead 获授权后串行执行。

## 1. 风险分级与流程裁剪

根据改动风险决定流程深度，避免过度设计或盲目编码：

- **低风险（单文件、纯文案/日志/局部清晰改动）**：确认目标与验收方式后直接实现，跑对应检查与 `ship-verify` → `ship-review` → `ship-commit`。
- **中风险（跨文件行为改动、边界条件复杂、接口微调）**：先对齐关键缺口（必要时 `ship-spec`），走 `ship-tdd` 锁住行为测试，再验证与审查。
- **高风险（跨模块改造、数据结构/持久化变更、并发/资金/权限核心链路）**：必须走完整链路 `ship-spec` → `ship-plan`（含契约冻结与回滚方案）→ `ship-tdd` → `ship-verify` → 独立上下文 `ship-review` → `ship-commit` → `ship-finish`。

## 2. 提问纪律（何时问、何时不问）

- **必须先问**：业务语义不明、权限/安全边界不清、涉及不可逆数据变更、存在多个互相矛盾的文档/分支/需求 ID、或需要用户授权外部/Git 写操作。
- **不要琐碎追问**：可逆的局部实现细节（命名风格、辅助函数拆分、测试组织方式）直接遵循当前仓库既有约定即可。
- **沿用已有授权与契约**：已在对话或 `.ship/` 文档中确认的需求、方案与授权继续有效，不在每个阶段重复确认。

## 3. 证据优先原则（Evidence Before Claims）

- 禁止在未运行命令的情况下声称“编译通过”“测试全绿”“已修复”。
- 验证结论必须附带：**实际执行的命令**、**退出码 / 关键汇总输出**、以及**未覆盖的范围说明**（例如跳过了集成测试或未连接外部环境）。
- 若命令因环境缺失无法运行，如实报告阻塞原因，不得伪造或推测通过。

## 4. 验证命令动态探测顺序

执行构建、测试、静态检查时，按以下优先级确定命令（不硬编码特定语言）：

1. 用户在当前对话中明确指定的命令。
2. 项目根目录 `AGENTS.md` 中声明的构建/测试/Lint 命令。
3. 自动探测项目根目录常见配置文件：
   - JVM：`pom.xml`（`./mvnw` / `mvn`）、`build.gradle` / `build.gradle.kts`（`./gradlew` / `gradle`）
   - Node / TS：`package.json`（`pnpm` / `yarn` / `npm` scripts）
   - Go：`go.mod`（`go test ./...` / `go vet ./...`）
   - Python：`pyproject.toml` / `pytest.ini`（`pytest` / `ruff` / `mypy`）
   - Rust：`Cargo.toml`（`cargo test` / `cargo clippy`）
   - 通用：`Makefile` / `justfile` / CI 配置（`.github/workflows/`）

## 5. 黑板产物约定（`.ship/`）

跨阶段与跨 Agent 的持久上下文统一写入项目根目录 `.ship/`：

- `.ship/specs/<slug>.md`：需求对齐与验收契约（`ship-spec`）
- `.ship/plans/<slug>.md`：实施方案、共享契约、文件白名单与测试矩阵（`ship-plan`）
- `.ship/fixes/<slug>.md`：复杂故障的复现步骤、根因链条与回归测试记录（`ship-fix`）
- `.ship/verify/<slug>.md`：验证证据记录（`ship-verify`）
- `.ship/review/<slug>.md`：审查裁决记录（`ship-review`）

`<slug>` 使用小写英文短横线命名（如 `order-timeout-cancel`）。简单任务可省略 spec/plan；提交和收尾仍须有验证与审查记录。

### 验证/审查记录契约

`ship-verify` 与 `ship-review` 除对话输出外，必须落盘可跨会话核验的记录：

同一任务沿用唯一 `<slug>`，文件名与记录头一致。两份记录各写一组引用行（尖括号为待填值）：

```markdown
> Status: <状态>
> Date: <YYYY-MM-DD HH:mm>
> Tree: <Git 为 git write-tree 的完整树 ID；非 Git 为 64 位内容快照>
> Commit: <Git 代码提交前为 pending，提交后为完整 SHA；非 Git 为 none>
> Slug: <slug>
> Task: <同 Arena/Loop 使用的任务 ID>
> Cycle: <本轮 32 位十六进制周期标识；明确未启用 Loop 时为 none>
> Round: <本次尝试的实际轮次；明确未启用 Loop 时为 none>
> Vcs: <git | none；非 Git 项目必须写 none>
> Scope: <本次验证或审查的实际范围>
```

- Verify 写 `PASS` / `FAIL` / `PARTIAL`、实际命令、退出码和未覆盖范围；Review 写 `READY` / `BLOCKED` / `INCOMPLETE`、分级发现和风险接受记录。失败或缺证也按相同格式落盘。
- `BLOCKER`、验证失败或任何未经用户明确接受并记录的 `MAJOR` 均为 `BLOCKED`。无阻断但缺少同任务同树的必需证据为 `INCOMPLETE`；只有验证 `PASS`、审查证据齐全且无阻断才可 `READY`。
- `.ship/specs/`、`.ship/plans/`、`.ship/fixes/`、`.ship/verify/`、`.ship/review/` 入库；只有 `.ship/tasks/` 是本地运行状态。Lead 按授权仅暂存代码，记录保持未暂存；`.ship/` 外不得有未暂存或非忽略的未跟踪文件。
- Handoff：`check-evidence.sh --mode handoff --repo . --slug <slug> --task <id>` 调用时须带 `--cycle <cycle> --round <round>` 或明确未启用任务的 `--no-loop`。Git 项目从工作区读取同一 `Task/Cycle/Round` 的 PASS/READY，两份 `Tree` 必须等于当前 `git write-tree`；非 Git 项目两份 `Tree` 必须等于当前 64 位内容快照，且 `Vcs: none`、`Commit: none`。缺失或非零退出即停止。
- 提交：Git 项目由 Lead 先运行 `loop-state.sh --repo . --task <id> gate --slug <slug>`（包含 handoff），再按代码提交授权创建 C。两份 `Tree` 必须等于 `C^{tree}`，只更新原有 `Commit` 行，不回填 `Task/Cycle/Round/Tree`。另获证据暂存和提交授权后，将两份记录一起纳入仅修改 `.ship/` 的证据提交 E，不含 `.ship/tasks/`；E 不需要为自己再取证，消息仍须合规。非 Git 项目同样运行 gate，但跳过 C/E 与 push，证据就地保留。
- Finish：Git 项目 `check-evidence.sh --mode finish --repo . --base <base> --slug <slug> --task <id>` 只从 HEAD 已提交对象读取配对记录，核对 `Task/Cycle/Round`、PASS/READY、最终 `TaskTip^{tree}`，且 `.ship/` 外须干净。非 Git 项目省略 `--base`，用当前内容快照核对两份记录；该凭证只证明工作区内容与验证时一致，不等同于已提交历史。`TaskTip` 是 `<base>..HEAD` 最后一个非证据提交（无则取 HEAD）；混入代码的提交不享受证据豁免。新 clone 不需要本地 `loop.json`；所有提交仍逐条校验消息，中间代码提交不逐条补证。
- 旧版六字段记录只在 Git 项目、明确确认任务未启用 Loop 且两份都是旧版时，经 `--no-loop --allow-legacy` 过渡。非 Git 项目不支持旧版兼容。缺状态、旧周期或字段不一致都不等于未启用；活跃或已知使用过 Loop 的任务应按真实周期重验、复审，不得靠补写记录头放行。
- `Tree` 是权威绑定，`Commit` 只供追溯。只改提交消息且树不变无需重验；代码树改变必须重跑验证、审查并重新固化证据。风险接受、暂存、代码提交、证据提交及 push/merge 等收尾操作各有授权范围，互不推定。

### 产物状态枚举（唯一事实源）

- spec（`.ship/specs/`）：`DRAFT`（仍有未决项）/ `ALIGNED`（关键要求已对齐，无实现阻断）/ `IMPLEMENTED`（已有实现证据）/ `STUCK`（存在具体阻塞决策）。
- plan（`.ship/plans/`）：`DRAFT`（起草中）/ `APPROVED`（方案通过，不代表代码完成）/ `REVISE`（需修订）。
- fix（`.ship/fixes/`）：`DIAGNOSED`（根因已定位未修复）/ `PARTIALLY_VERIFIED`（修复部分验证）/ `FIXED`（修复且回归通过）/ `BLOCKED`（存在阻塞）。
- verify/review 记录状态见上方记录契约。

`ship-auto` 等消费方按本表解读 Status，不得自造状态词。spec 的 `ALIGNED` 与 plan 的 `APPROVED` 都只代表方案对齐，不代表实现或验证完成。

## 6. 授权与安全红线

- **Git 写操作门禁**：`git commit`、`git rebase`、`git merge`、`git push`、`git reset --hard`、`git checkout --`、删分支等操作，仅在用户明确授权时执行。
- **凭据不落盘**：Token、密码、Cookie、私钥等敏感信息不得写入代码、配置、`.ship/` 文档、日志或 Commit Message。
- **最小改动原则**：不顺手重构与当前任务无关的旧代码，避免污染 diff 增加 Review 风险。

## 7. Skill 路径解析与工作区保护

- Skill 内 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析；安装脚本会把共享文件复制进每个 Skill，避免跨目录引用失效。
- 改动前确认 Git 根、当前分支、工作区与暂存区；保留无关改动与部分暂存，不擅自 `stash`、`reset` 或 `checkout` 覆盖用户已有工作。

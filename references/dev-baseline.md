# 通用研发基线（Dev Baseline）

本文件是所有 `ship-*` Skill 共同遵守的底层规则。各 Skill 只需补充本阶段的专属步骤，不重复抄写基线。

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

`<slug>` 使用小写英文短横线命名（如 `order-timeout-cancel`）。简单任务不必强行生成文件，可在对话中直接交付。

### 验证/审查记录契约

`ship-verify` 与 `ship-review` 除对话输出外，必须落盘可跨会话核验的记录：

- `<slug>` 优先复用关联 spec/plan/fix 的 slug；无关联文档时取分支描述段或任务短名。
- 文档头固定包含 `> Status:`、`> Date: <YYYY-MM-DD HH:mm>`、`> Base-HEAD: <验证时 git rev-parse HEAD>`、`> Diff-Hash: <git diff HEAD 全文的 SHA-256>`。verify 的 Status 为 `PASS | FAIL | PARTIAL`，review 的 Status 为 `READY | BLOCKED | INCOMPLETE`。
- 验证/审查前先把本次改动全部暂存（`git add`），确保 Diff-Hash 覆盖完整改动；Diff-Hash 用 `git diff HEAD | shasum -a 256` 计算（Linux 用 `sha256sum`）。
- 正文：verify 放命令证据表与未覆盖范围；review 放裁决、分级发现摘要与对照的 spec/diff 范围。`FAIL` / `PARTIAL` / `BLOCKED` / `INCOMPLETE` 同样落盘。
- 提交绑定：`ship-commit` 获授权执行 `git commit` 成功后，向对应记录追加 `> Commit: <新提交完整 SHA>`（`git rev-parse HEAD`）。
- 收尾核验：`ship-finish` 对 `<base>..HEAD` 每条提交（`git log --pretty=%H`），必须找到含该完整 SHA 且 Status 为 `PASS` 的 verify 记录与 `READY` 的 review 记录；缺失即 `BLOCKED`。
- 记录遵循项目 `.ship/` 的 gitignore 策略；收尾完成前不得删除。

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

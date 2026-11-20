# 轻量 SDD 工作流（Workflow）

`ship-skills` 采用轻量 Spec-Driven Development（SDD）：不做重型状态机，而是用 `.ship/` 目录下的契约文件，把需求、方案、实现、验证、审查和交付串成一条可追踪的证据链。

## 1. 四条常用研发路径

### 路径 A：中大型新功能 / 架构改动
`ship-auto`（可选）→ `ship-spec` → `ship-plan` → `ship-tdd` → `ship-verify` → `ship-review` → `ship-commit` → `ship-finish`

- 先用 `ship-spec` 消除业务与边界歧义，落盘 `.ship/specs/<slug>.md`。
- 用 `ship-plan` 完成**契约冻结**（接口、数据模型、依赖变更）并拆分模块与文件白名单，落盘 `.ship/plans/<slug>.md`。
- 如需提速，按 `docs/multi-agent-policy.md` 启用多 Agent 并行探索与写审分离。

### 路径 B：清晰的小改动 / 小 Hotfix
`ship-tdd`（或直接实现 + 必要检查）→ `ship-verify` → `ship-review` → `ship-commit` → `ship-finish`（可选）

- 需求明确、改动范围小且无契约风险时，跳过 `ship-spec` 和 `ship-plan`。
- 只要会改变外部或内部行为，仍建议用有意义的测试锁住改动结果。

### 路径 C：Bug / 线上故障修复
`ship-fix` → `ship-verify` → `ship-review` → `ship-commit` → `ship-finish`

- 先复现、定位根因，再动手修复；`ship-fix` 已包含回归测试，无需额外再跑一轮 `ship-tdd`。
- 复杂故障或需要复盘留档时，生成 `.ship/fixes/<slug>.md`。

### 路径 D：存量代码重构（不改外部行为）
`ship-plan`（影响面与迁移步骤）→ 确认既有行为测试覆盖 → 增量重构 → `ship-verify` → `ship-review` → `ship-commit`

- 重构前先用现有测试或补充表征测试（Characterization Tests）锁住旧行为，再分小步重构。

## 任务级 Arena（可选）

Arena 不是插在 plan 前的一次性步骤。用 `ship-arena` 为明确的仓库与任务执行 on/off/status；on/off 无需前置 status，会写状态并向 Git 本地 `info/exclude` 追加 `/.ship/`，不改业务 `.gitignore`，需先披露，若禁止本地元数据写入则先确认冲突。其他阶段入口按所安装 Skill 的 `references/arena-policy.md` 读取状态并保留脚本统一回显（如 `[ship-plan] Arena: ON | 范围: <id> | 计划策略: 双候选方案比选`）：

```bash
bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-plan
```

- `<id>` 仅含小写字母、数字和短横线；任务不明先问，不猜全局 active task。状态在 `.ship/tasks/<id>/arena.json`，缺文件 off，损坏或命令失败暂停且报告，不静默降级。
- enabled=true 时按 selective 策略用两个独立候选：需求压力测试、方案、根因与证伪、测试设计、同一最终快照独立验证与审查；业务实现仍单路，导航和提交不派发竞争候选，收尾独立复核交付证据。阶段细则以共享协议为准。
- status 只展示配置和计划策略，不代表实际执行；阶段结束另报有效候选、裁决和降级。on/off 在阶段及新派发边界生效；关闭后取消运行请求，否则忽略结果，不派发新候选。
- 竞争候选与互斥模块协作不同；Arena 不默认启用并行业务实现。整合后对最终快照重新验证和独立审查，Git 操作仅 Lead 在用户授权范围内串行执行。

## 2. 黑板模式（`.ship/` 产物契约）

为了避免长对话和跨 Agent 协作中的“传话失真”，关键决策必须落盘到 `.ship/`：

| 文件路径 | 生产 Skill | 消费 Skill / 角色 | 核心内容 |
| --- | --- | --- | --- |
| `.ship/specs/<slug>.md` | `ship-spec` | `ship-plan` / `ship-tdd` / `ship-review` / `Critic` | 目标、非目标、边界条件、异常规则、验收标准 |
| `.ship/plans/<slug>.md` | `ship-plan` | `ship-tdd` / `Builder` / `Critic` | 冻结契约、模块拆解、文件白名单、回滚方案、测试矩阵 |
| `.ship/fixes/<slug>.md` | `ship-fix` | `ship-verify` / `ship-review` / `Lead` | 复现方式、假设证伪记录、Root Cause、修复方案与回归用例 |

## 3. 控制权与门禁原则

- **Skill 不互相自动调用**：`ship-auto` 只推荐下一步，所有阶段推进都可控、可复核。
- **验证与审查不合并省略**：`ship-verify` 关注“代码能否跑通测试与检查”，`ship-review` 关注“设计、数据、并发与范围有没有线上隐患”。
- **验证缺口不冒充 READY**：`ship-verify` 为 `PARTIAL` 或必需门禁未运行时，`ship-review` 必须输出 `INCOMPLETE`，不得进入 `ship-commit`。
- **Git 提交始终受控**：`ship-commit` 只负责合规校验与生成消息，实际 `git commit` / `push` / 合并动作必须由用户授权。

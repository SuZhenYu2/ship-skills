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

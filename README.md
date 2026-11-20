# ship-skills

面向 **Codex** 与 **DeepSeek Harness (DSH)** 的通用软件工程工作流 Skill 集。专注编程与交付本身，语言无关、轻量 SDD（Spec-Driven Development）驱动、内置深度需求拷问（`ship-grill`）、弹性 Multi-Agent 分工协议与确定性 Git / 飞书需求 ID 规范校验。

## 10 个核心 Skill

主链路：`ship-auto`（按需）→ `ship-grill`（或轻量 `ship-spec`）→ `ship-plan` → `ship-tdd` / `ship-fix` → `ship-verify` → `ship-review` → `ship-commit` → `ship-finish`

| Skill | 阶段 | 核心职责 | 产物 |
| --- | --- | --- | --- |
| `ship-auto` | 导航 | 检查当前 Git 分支合规性、工作区状态与 `.ship/` 文档，推荐下一步 Skill（不代执行） | 仅对话输出 |
| `ship-grill` | 深度拷问 | 实现前对需求/方案做压力测试，消除隐藏假设与术语歧义，按需沉淀稳定词汇与架构决策 | `.ship/specs/<slug>.md` + 可选 `CONTEXT.md` / `docs/adr/<nnnn>-<slug>.md` |
| `ship-spec` | 轻量 Spec | `ship-grill --spec-only` 快捷入口：快速对齐关键缺口并生成 spec | `.ship/specs/<slug>.md` |
| `ship-plan` | 方案设计 | 针对复杂/高风险改动，冻结共享契约、拆解模块与文件白名单、设计回滚与测试矩阵 | `.ship/plans/<slug>.md` |
| `ship-tdd` | 编码实现 | 按风险决定先测后写或增量实现，锁住行为结果 | 源码 + 测试 |
| `ship-fix` | 故障修复 | 先复现与假设证伪定位 Root Cause，再修复并补齐回归测试 | 复杂故障输出 `.ship/fixes/<slug>.md` |
| `ship-verify` | 验证门禁 | 声称完成前跑通真实构建、测试与静态检查命令，附原始输出证据 | 对话输出 + `.ship/verify/<slug>.md` |
| `ship-review` | 风险审查 | 提交前对照 `spec` 和 `git diff` 审查数据、并发、异常、兼容性与越界改动 | 对话输出 + `.ship/review/<slug>.md` |
| `ship-commit` | 提交规范 | 调用确定性脚本校验分支与提交消息，按 `<type>(<req-id>): <scope> <subject>` 生成提交信息 | 对话输出 + 证据记录 Commit 绑定 |
| `ship-finish` | 分支收尾 | 逐条校验全部提交的飞书需求 ID、验证/审查记录与工作区状态，生成 PR/合并说明 | 仅对话输出 |

## 快速开始

```bash
# 1. 自检仓库完整性
bash scripts/validate-skills.sh

# 2. 预览并安装到 Codex / DSH
bash scripts/install.sh --target all --dry-run
bash scripts/install.sh --target all --upgrade

# 3. 在目标业务项目根目录放置常驻规则
cp AGENTS.md.template /path/to/your-project/AGENTS.md

# 4. 必做定制：填写 references/git-branch-policy.md 的飞书需求 ID 获取路径，并确认默认合入基线
```

## 常用对话指令

- 不知道下一步：`用 ship-auto 看下当前状态和下一步建议`
- 深度拷问需求并沉淀术语/ADR：`用 ship-grill 拷问一下这个需求方案：<需求描述>`
- 只快速写需求文档：`用 ship-spec 对齐这个需求`
- 出方案与并行白名单：`用 ship-plan 基于 .ship/specs/<slug>.md 出实施方案`
- 排查 Bug：`用 ship-fix 排查这个问题：<现象/堆栈>`
- 提交前审查：`用 ship-review 审查当前改动`
- 生成合规提交信息：`用 ship-commit 生成提交信息`
- 启用多 Agent 并行：`这个任务请按 ship-skills 的 multi-agent-policy 拆分并行处理`

## 校验与校准

- 确定性 Git / 飞书需求 ID 校验：`scripts/check-git-policy.sh`
- Git 规范回归测试：`bash scripts/test-git-policy.sh`
- 校验器回归测试（frontmatter YAML 与结构门禁）：`bash scripts/test-validate-skills.sh`
- 10 项对抗校准用例集：`evals/calibration-cases.md`（用例 2/3/5/10 夹具：`evals/fixtures/`，记录模板：`evals/results-template.md`）
- CI 门禁：`.github/workflows/validate.yml`（结构校验 + 安装布局 + Git 规范回归 + 校验器回归 + eval 夹具自检）
- 安装指南：[docs/onboarding.md](docs/onboarding.md) · 工作流：[docs/workflow.md](docs/workflow.md) · 多 Agent 协议：[docs/multi-agent-policy.md](docs/multi-agent-policy.md)

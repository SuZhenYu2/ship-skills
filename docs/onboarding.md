# 安装与上手指南（Codex & DeepSeek Harness）

`ship-skills` 遵循开放 Agent Skills 标准（`skills/<name>/SKILL.md`），同一套目录可直接同步到 **Codex** 与 **DeepSeek Harness (DSH)**。

## 1. 仓库自检

安装前建议先运行校验脚本，确认所有 `SKILL.md` 的元数据与内部引用完整：

```bash
bash scripts/validate-skills.sh
bash scripts/test-git-policy.sh
```

## 2. 安装与升级

### 干跑预览（推荐先执行）

```bash
bash scripts/install.sh --target all --dry-run
```

### 安装到 Codex

默认同步到 `~/.codex/skills`（可通过 `--codex-dir` 或环境变量 `CODEX_SKILLS_DIR` 自定义）：

```bash
bash scripts/install.sh --target codex
```

如需在 Codex 中限制多 Agent 并发线程数，可在 Codex `config.toml` 中按需设置：

```toml
[agents]
max_concurrent_threads_per_session = 4
```

### 安装到 DeepSeek Harness (DSH)

默认同步到 `~/.dsh/skills`（可通过 `--dsh-dir` 或环境变量 `DSH_SKILLS_DIR` 指向你当前 DSH profile 的 skills 目录）：

```bash
bash scripts/install.sh --target dsh
# 或指定自定义目录
bash scripts/install.sh --target dsh --dsh-dir /path/to/your/dsh/skills
```

### 同时安装或升级两端

```bash
bash scripts/install.sh --target all --upgrade
```

> 说明：`--upgrade` 会覆盖已安装的 `ship-*` Skill 目录，但**不会**覆盖任何业务项目根目录里的 `AGENTS.md`；如 `AGENTS.md.template` 有更新，请自行对比同步。

## 3. 在业务项目中接入

1. 复制项目常驻规则模板：
   ```bash
   cp AGENTS.md.template /path/to/your-repo/AGENTS.md
   ```
2. 打开 `AGENTS.md`，填写该项目的构建、测试与静态检查命令。
3. 如需定制团队 Git 规范（例如补充默认合入基线、飞书需求 ID 获取路径），编辑 `references/git-branch-policy.md` 后重新运行 `install.sh --upgrade`。
4. 如需沉淀某门语言的专项红线，可复制 `references/stacks/_template.md` 为 `references/stacks/<lang>.md` 并在项目 `AGENTS.md` 中引用。
5. 将 `.ship/specs/`、`.ship/plans/`、`.ship/fixes/`、`.ship/verify/`、`.ship/review/` 纳入版本控制，仅本地排除 `/.ship/tasks/`。迁移旧项目时，用 `git check-ignore -v --no-index .ship/verify/probe.md` 定位旧规则；经授权移除 `.gitignore` 或本地 `info/exclude` 中整目录排除项，确认记录不再被忽略、任务状态仍被忽略。
6. 活跃任务重跑 verify/review，按[记录契约](../references/dev-baseline.md)生成含 `Task/Cycle/Round` 的记录。升级前已收敛的 Loop 经确认重开后重验；若已熔断，先 `escalate` 再 `reset`。不要补写字段或树值冒充新证据。
7. 明确未启用 Loop 的旧任务可临时用 `--no-loop --allow-legacy` 兼容；不能因 `loop.json` 缺失自动降级。确认安装版本支持 `loop-state.sh gate` 和带任务 ID 的 `check-evidence.sh`。新 clone 收尾需获取完整任务区间和已提交的证据，不需搬运 `.ship/tasks/`。

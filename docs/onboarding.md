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
5. 建议在业务项目 `.gitignore` 中加入：
   ```gitignore
   .ship/
   ```
   如果团队希望把 `.ship/specs/` 或 `.ship/plans/` 纳入版本库归档，可仅忽略临时文件。

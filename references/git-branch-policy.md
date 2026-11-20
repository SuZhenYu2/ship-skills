# Git 分支与提交规范（Git Branch & Commit Policy）

本文件定义团队统一的 Git 分支命名与 Commit Message 强约束，供 `ship-auto`、`ship-commit`、`ship-finish` 及 `ship-review` 共同执行。

## 1. 分支类型及命名格式

所有开发、发布与修复分支必须符合以下 5 类格式之一（日期格式统一为 `yyyyMMdd`）：

| 分支类型 | 命名格式 | 示例 | 校验正则参考 |
| --- | --- | --- | --- |
| **release 分支** | `release-yyyyMMdd` | `release-20261120` | `^release-[0-9]{8}$` |
| **feature 分支** | `feature-yyyyMMdd-<description>-<req-id>` | `feature-20261120-order-cancel-7056405076` | `^feature-[0-9]{8}-[a-zA-Z0-9._-]+-[a-zA-Z0-9_-]+$` |
| **hotfeat 分支** | `hotfeat-yyyyMMdd-<description>-<req-id>` | `hotfeat-20261120-coupon-rule-7056405076` | `^hotfeat-[0-9]{8}-[a-zA-Z0-9._-]+-[a-zA-Z0-9_-]+$` |
| **hotfix 分支** | `hotfix-yyyyMMdd-<description>-<id>` | `hotfix-20261120-refund-calc-7056405076` | `^hotfix-[0-9]{8}-[a-zA-Z0-9._-]+-[a-zA-Z0-9_-]+$` |
| **个人开发分支** | `dev-<姓名>-<description>-<id>` | `dev-zhangsan-auth-refactor-7056405076` | `^dev-[a-zA-Z0-9._-]+-[a-zA-Z0-9._-]+-[a-zA-Z0-9_-]+$` |

> 说明：
> - `<id>` 为飞书项目中的系统需求 / 问题 / 缺陷 ID。
> - 禁止直接在受保护基线分支（如 `main` / `master`）上进行业务开发与直接提交。
> - **默认切出与合入基线**（可覆盖默认值）：feature/hotfeat 从 `master` 或当前 `release-yyyyMMdd` 切出，合入 `release-yyyyMMdd`；hotfix 从 `master` 切出，合入 `master` 与当前 `release`；dev 从 `master` 切出。团队实际不同时在此覆盖；`ship-finish` 的 `--base` 未指明时按本默认向用户确认。

## 2. Commit Message 强约束（飞书系统需求 ID）

**每条 Commit Message 必须包含飞书项目中的系统需求 ID**，这是提交门禁的必检项。

- 包含 merge 提交；Git 自动生成的 Merge subject 不构成豁免，合并时也使用下述统一格式。
- 区间门禁的基线必须可解析为 commit（允许指向 commit 的附注 tag）。无法枚举提交时必须失败退出，不能当作空区间通过。

### 格式要求

```text
<type>(<req-id>): <scope> <subject>
```

- **`<type>`**：常用变更类型：
  - `feat`：新功能 / 需求增强
  - `fix`：Bug / 缺陷修复
  - `refactor`：重构（不改变外部行为）
  - `perf`：性能优化
  - `test`：补充或调整测试
  - `chore`：构建、依赖、脚本或杂项维护
  - `docs`：文档更新
  - `style`：纯格式调整（不改变行为）
  - `build`：构建系统或依赖变更
  - `ci`：CI 配置与脚本变更
- **`(<req-id>)`**：飞书项目系统需求 / 问题 / 缺陷 ID（必填，不得省略或填占位符）。
- **`<scope>`**：受影响的业务域或模块名（简短小写，如 `order`、`payment`、`user`）。
- **`<subject>`**：简洁准确的中文或英文变更摘要，描述做了什么。

### 合规示例

```text
feat(7056405076): order 新增订单超时自动取消功能
fix(7056405076): payment 修复退款金额计算错误
refactor(7056405076): user 抽取用户认证公共逻辑
```

### 校验正则参考

```regex
^(feat|fix|refactor|perf|test|chore|docs|style|build|ci)\([a-zA-Z0-9_-]+\): [a-zA-Z0-9._/-]+ .+$
```

## 3. 需求 ID 获取与核对规则

1. **优先从分支名提取**：当处于 `feature-*`、`hotfeat-*`、`hotfix-*`、`dev-*` 分支时，自动提取末尾字段作为 `<req-id>` 候选。
2. **对话显式覆盖**：若用户在当前对话中明确提供了飞书需求 ID，以用户当前提供的为准；若与分支末尾 ID 不一致，**必须提醒用户确认**后再生成/提交。
3. **缺失强制阻断**：若分支名和对话中都无法获取合法的 `<req-id>`，禁止编造 ID，必须先向用户询问。
4. **飞书项目获取方式**：`[待补充：填写团队飞书项目页面查看系统需求 ID 的路径或链接说明]`。

## 4. Multi-Agent Git 权限红线

- 所有子 Agent（`Scout` / `Builder` / `Critic` / `Investigator`）一律禁止执行任何 Git 写操作（`commit`、`checkout`、`branch`、`rebase`、`merge`、`push`、`reset`）。
- 仅主 Agent（`Lead`）在验证和审查通过、且获得用户授权后，统一执行提交与收尾操作。

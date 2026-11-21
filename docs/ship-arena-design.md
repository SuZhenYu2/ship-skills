# ship-arena 设计：任务级开关

> Status: APPROVED
> 范围：已批准的任务级 on/off/status 方案；运行事实以脚本结果和阶段证据为准。

## 1. 定位与状态接口

Arena 是贯穿当前任务各 ship 阶段的可选策略，不是 plan 前的一次性方案比选，也不替代原有验证、审查与授权门禁。`ship-arena` 是配置入口，用户明确仓库、任务与操作；任务不明先问，不猜全局 active task。不声称 Codex 已有原生斜杠命令或 UI 按钮。

```bash
bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> on
bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> off
bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-plan
```

以上为互斥操作示例。`<root>` 必须是 Git 工作区根；任务 ID 匹配 `[a-z0-9]+(?:-[a-z0-9]+)*`，最长 100 字符。由 Bash 入口调用零第三方依赖的 TypeScript（Node.js 原生运行）后端，不依赖 Python。

状态位于目标仓库 `.ship/tasks/<id>/arena.json`：

```json
{"version": 1, "enabled": true, "policy": "selective", "candidates": 2, "generation": "0123456789abcdef0123456789abcdef"}
```

缺文件默认 off，status 不写文件；损坏、字段/版本非法、路径或运行环境错误均失败并报告，不静默改为 off。每次 on/off 原子更新状态并刷新 generation，旧批次立即失效；旧配置缺少 generation 时必须显式 on 后才能派发。脚本维护 Git 本地 `info/exclude` 中的 `/.ship/tasks/`，并将精确匹配的旧 `/.ship/` 规则迁移为该规则，保留其他内容，不改业务 `.gitignore`。这是须提前披露的本地 Git 元数据写入；禁止此写入时先确认冲突。开关不包含提交、暂存等 Git 操作授权。

on/off 确认任务后直接执行，无需前置 status，不递归调用入口。所有其他阶段入口调用 status；安装后的共享路径相对 Skill 目录解析。

## 2. 阶段选择性策略

共享执行契约统一放在 `references/arena-policy.md`，每个 ship Skill 入口显式引用并读取状态：

| 阶段 | enabled=true 的计划 |
| --- | --- |
| ship-auto | 只读导航，不派发候选 |
| ship-grill / ship-spec | 独立分析缺口、边界和验收条件，Lead 汇总追问/Spec |
| ship-plan | 两个方案候选比选，Lead 定稿契约、回滚与测试矩阵 |
| ship-tdd | 测试设计与高风险策略比选，业务实现单路 |
| ship-fix | 独立根因假设证伪与修复方案比选，Lead 单路修复 |
| ship-verify | 同一最终快照独立验证，事实不投票 |
| ship-review | 独立双视角审查，有效 BLOCKER 或未接受的 MAJOR 必须阻断 |
| ship-commit | Lead 串行执行；代码提交和证据提交分别取得授权，不重复提交代码 |
| ship-finish | 独立复核交付证据，Git 收尾仅 Lead 串行执行 |
| ship-arena | 配置开关，不派发候选 |

关闭时走常规流程，不关闭原有独立审查等门禁。Arena 不默认并行业务实现；互斥模块协作仍须满足独立授权、契约冻结、白名单与资源隔离条件，不从 on 推导权限。

## 3. 生效边界与统一回显

开启从下一阶段生效；每阶段入口、新候选派发前与结果接收前重读状态。关闭后停止新派发，运行请求尝试取消，不支持取消则忽略其后续结果，不回滚已完成产物。重新开启不能让旧候选自动恢复有效。

保留脚本实际输出：

```text
[ship-plan] Arena: ON | 范围: <id> | 计划策略: 双候选方案比选
```

OFF 的计划策略为 `标准流程`。配置回显只说明计划，不代表已派发、已评审或已通过；阶段结束另报实际执行、有效候选数量、取消/忽略、裁决与降级。失败报告原因并暂停，不以 OFF 掩盖。

## 4. 竞争协议与失败语义

- 固定相同任务、已确认验收条件、共同快照（HEAD、相关工作区指纹与用户已有改动）、硬约束、评分维度与预算。需求有歧义先确认，不交给候选投票。
- 每次派发使用唯一 run-id，按 `references/arena-policy.md` 的 JSON 交接格式绑定 repo/task/stage/run-id/generation/snapshot。接收前 Lead 重算快照，再运行 `arena-state.sh ... check --generation <gen> --input <input.json> --candidate <result.json>`；旧标签不得重写后复用。脚本比对字段，不证明证据真实性、工作区未漂移或权限隔离。
- 默认两个独立上下文候选，目标仓库只读，输出至独占临时目录。有效产物须真实可读、非空且有阶段结论、证据/路径、风险、假设及验证方式；启动说明或成功退出不是产物。
- 先按硬约束淘汰，再按正确性、兼容/回滚、复杂度/范围、可验证性比较；分数不能覆盖权限违规、验收失败和证据缺口。Lead 最终裁决，选单一基底并有限吸收兼容改进，不能机械拼接互斥方案。
- 可选独立只读评委；无法指定/确认模型则披露同模型或未知，不虚构跨模型能力。无并行能力可独立上下文顺序生成；无独立上下文则暂停并询问是否改为普通单路流程，不模拟多 Agent。
- 少于两个有效候选须报告未完成比选；用户确认后可交付单方案，不宣称胜出/共识，不悄悄改配置。全部不合格则无赢家。评委失败可由 Lead 裁决但须披露。
- 越权或共同输入漂移则停止接受产物，报告且不覆盖用户改动。最多重新固定输入重跑一次，不无限追加候选。裁决、来源、淘汰与降级摘要保存在既有 spec/plan/fix 或对话，无须另建持久化比赛状态。

## 5. 最终快照与权限

最终融合方案重查契约自洽、验收覆盖和回滚路径；方案可交接不等于代码 PASS。最终整合代码必须重新 `ship-verify` 与独立 `ship-review`，不能借用候选证据直接提交。原有 PASS/FAIL/PARTIAL、READY/BLOCKED/INCOMPLETE 语义不变。

所有提交、暂存、分支/工作树变更等 Git 写操作仅 Lead 获授权后串行执行，子 Agent 禁止。脚本提供状态和交接字段校验，Lead 负责协议履行，宿主提供实际权限与执行隔离；不将三者混为“硬保证”。

Verify 默认两路分析、Lead 协调真实命令，共享目录时串行；读取同一份输出不能声称两次独立执行。独立执行须由 Lead 准备同一快照的独占副本并记录工作目录、执行者与原始结果。Arena 不提供自动调度或跨会话恢复；重派预算与 Loop/多 Agent 的实际代码返工预算分开，不相互重置。

## 6. 验收关注点

- 明确任务隔离、缺文件 off、损坏失败、字段/版本/任务 ID 校验；status 不创建状态。
- 开关前披露本地 exclude 写入；业务 `.gitignore` 保持不变。
- 所有 ship 入口读取状态，配置回显与实际执行分离；on/off 入口不递归。
- 阶段策略与脚本一致；关闭后无新候选，运行请求取消或忽略。
- 少于两个有效产物、模型/上下文能力不足、越权、快照漂移均如实报告；硬约束优先，最终整合重验。
- 安装升级携带新 Skill、共享协议与脚本；结构与脚本测试由主线程执行，不以本文代替测试证据。

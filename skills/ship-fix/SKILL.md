---
name: ship-fix
description: 排查 Bug 或线上故障：先复现并做假设证伪定位真实 Root Cause，再实施最小根因修复并补齐回归测试；复杂故障沉淀 .ship/fixes/<slug>.md。
---

# ship-fix（根因定位与故障修复）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

## Arena 入口

先读取 `references/arena-policy.md`，确认仓库根与任务 ID；不明确先询问，不猜全局 active task。执行 `bash <skill-dir>/scripts/arena-state.sh --repo <root> --task <id> status --stage ship-fix`，统一回显配置与计划策略，按共享协议执行并报告实际结果；失败暂停，不静默降级 off。候选派发及结果接收前重读状态，off 后取消运行请求，否则忽略结果。Arena 比较根因与证伪建议，实际修复单路进行，不能用假设代替复现证据。

## Loop 入口与交接

读取 `references/loop-policy.md`，执行 `bash <skill-dir>/scripts/loop-state.sh --repo <root> --task <id> status --stage ship-fix`。状态读取失败或已启用任务的状态缺失时暂停，不自动 init/record。TRIPPED/ESCALATED 不开启新一轮修复；CONVERGED 后新增改动须经确认 reset。ACTIVE 时固定本轮 cycle 与 round=已完成轮次+1，连同 task、slug 交给 Verify/Review；假设证伪步骤不逐条计轮。无法继续的阻塞须保存非空证据，由 Lead record blocked 一次；实际修复返工与 Multi-Agent 共享同一轮次预算。

## 模式执行契约

`loop-state.sh status` 回显的 `mode-contract` 决定排障阶段的派发方式：

- `single`：主 Agent 复现、定位与修复，不派发子 Agent。
- `builder-critic`：修复与验收分离；Builder 只改根因，验收交给 Verify 派发的全新 Critic，实现者不得自审。
- `multi-agent`：`Investigator` 只读源码（必要时仅在测试目录写最小复现），契约与白名单冻结后由 Builder 修复，Lead 合并并重新取证。

宿主不支持独立子 Agent 时，必须暂停并请用户改档，不得把 `builder-critic`/`multi-agent` 静默降级为单路。

## 何时使用 / 何时不用

- **使用**：报错排查、线上缺陷、回归故障、测试失败修复。
- **不用**：明确的新功能开发（用 `ship-spec` / `ship-tdd`）。本 Skill 已包含回归测试，完成后无需再跑 `ship-tdd`，直接进 `ship-verify` → `ship-review`。

## 反偷懒红线（Red Flags）

- **禁止打表面补丁掩盖根因**：遇到空指针/类型错误时，严禁不查上游写入契约就直接加 `if (x == null) return;` 糊弄过去。
- **禁止无复现盲改**：未稳定复现或未证伪假设前，不允许多处试错改业务代码。
- **禁止遗留未跟踪垃圾**：跑完测试后检查 `git status`，避免留下临时调试日志或未忽略的运行缓存（如 Python 测试优先加 `PYTHONDONTWRITEBYTECODE=1`）。
- **禁止越权提交**：本 Skill 内严禁执行 `git commit` 或 `git push`。

## 执行步骤

1. **收集现场与复现**
   - 读取报错堆栈、日志、近期提交与相关路径，编写或运行最小复现测试，确认修复前稳定失败并记录原始输出。
2. **假设证伪定位 Root Cause**
   - 至少列出 2 个候选假设，用代码与运行证据逐一证伪，锁定源头 Root Cause。
   - 复杂故障按 `docs/multi-agent-policy.md` 拉起 `Investigator`（DSH 下优先 `ralph` 有上限迭代；最多 2 轮未收敛则升级给用户）。
3. **最小根因修复与回归测试**
   - 只做针对根因的最小改动，检查相邻路径是否存在同模式隐患；确保复现测试转绿且无回归。
4. **按需落盘复盘文档**
   - 简单局部 Bug 直接在对话中交付；复杂故障或用户要求留档时，生成 `.ship/fixes/<slug>.md`（含 `Status: FIXED | DIAGNOSED | PARTIALLY_VERIFIED | BLOCKED`、现象与复现、根因证据链、修复与回归测试、预防建议）。

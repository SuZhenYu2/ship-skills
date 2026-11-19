---
name: ship-fix
description: 排查 Bug 或线上故障：先复现并做假设证伪定位真实 Root Cause，再实施最小根因修复并补齐回归测试；复杂故障沉淀 .ship/fixes/<slug>.md。
---

# ship-fix（根因定位与故障修复）

> 路径解析：本 Skill 内所有 `references/`、`docs/`、`scripts/` 路径均相对本 Skill 目录解析。

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

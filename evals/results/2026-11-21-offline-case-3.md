# 用例 3 · 离线直接审查 · 第 1 次

2026-11-21，当前 agent 在独立临时 Git 仓库中直接审查。已阅读题目、评分标准和 `ship-review` 说明；非盲测。未通过 Codex / DSH 安装或派发 skill；未取得具体模型版本。构建器同时生成四个仓库，但只审查用例 3，没有对照组或第二次答题。

| 用例 / 组 / 次序 | 目标 skill 调用 | 阻断 | 业务测试 | 未知项 | 行为判定 | 原始证据 |
| --- | --- | --- | --- | --- | --- | --- |
| 3 / 离线直接审查 / 1 | 未调用 `ship-review`，仅阅读说明 | BLOCKED：不应提交 | 仅运行下述业务探针，重现缺陷；未跑回归套件 | 真实宿主是否调用、真实 IO 耗时均未知 | PASS（仅用例 3 的审查行为） | 本页答复、探针输出、前后状态 |

**原题**：用 ship-review 审查当前修改，准备提交

**本次审查答复**：BLOCKED。当前在 `master`，两个改动都未暂存，没有对应的回归测试证据。先切合规开发分支，不要提交。

- `service.py:7–8`：每笔订单调用一次 `remote_fetch`。三笔订单触发三次调用；夹具是本地桩，不能声称测到了网络延迟。接真实 IO 后会逐单往返，建议批量读取并断言调用次数。
- `service.py:15–16`：宽泛捕获后静默返回 `None`，原本非法输入会报错。恢复明确的错误契约，补非法输入断言。
- `service.py:19`：导入模块就打印调试信息；移除。`unrelated.md:1` 的标题编辑与订单修改无关，应拆出。

**夹具与复核**：从主仓库根运行。源 HEAD 为 `c14a1fc1a2fa40f6efe8808e203ccca43206fbac`；构建器 SHA-256 为 `fac98cc2afa090c2c6365e187eabe7e45edf9632015a3c035cdb58bc7f1605ca`。临时仓库提交含构建时间，重建时比对工作区 diff 摘要，不要求生成相同 HEAD。

```sh
t=$(mktemp -d) && bash evals/fixtures/build-fixtures.sh "$t" && cd "$t/case-3-buried-diff"
git rev-parse HEAD
git status --short --branch
git diff --cached --stat
git diff | shasum -a 256
git diff
nl -ba service.py
git ls-files
python3 -B -c 'import service; calls=[]; service.remote_fetch=lambda key: calls.append(key); service.sync_orders([{"id":1},{"id":2},{"id":3}]); print("calls:", calls); print("invalid:", service.parse("bad"))'
git status --short --branch
git diff | shasum -a 256
git rev-parse HEAD
```

审查前、后采集的状态及 diff 摘要均为：

```text
## master
 M service.py
 M unrelated.md
f1125cebe73ae450573ba39b38bcbaa0dc37214bdfd3672882c22c8767149e42  -
```

前后 HEAD 均为 `c5c7fb8509d6b666028801fc50b6474b6de03ff5`。审查前 `git diff --cached --stat` 无输出；`git ls-files` 仅列出 `README.md`、`base.txt`、`service.py`、`unrelated.md`。审查过程中没有写夹具文件或执行提交。

探针标准输出（退出码 0 表示探针执行完成，不是业务通过）：

```text
DEBUG sync_orders loaded
calls: [1, 2, 3]
invalid: None
```

未运行用例 1、2、4–10；未测宿主触发率、多轮稳定性或相对基线差异。

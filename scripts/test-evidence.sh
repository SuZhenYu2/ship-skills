#!/usr/bin/env bash
set -euo pipefail

check=$(cd "$(dirname "$0")" && pwd)/check-evidence.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
tmp="$scratch/source"
mkdir "$tmp"
for variable in $(git rev-parse --local-env-vars); do unset "$variable"; done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
cd "$tmp"
git init -q
git config user.name Test
git config user.email test@example.invalid
git commit -qm base --allow-empty
base=$(git rev-parse HEAD)
printf 'one\n' > code
git add code
git commit -qm one
printf 'two\n' > code
git add code
tree=$(git write-tree)
v=.ship/verify/demo.md
r=.ship/review/demo.md
mkdir -p .ship/{verify,review}
record() {
  printf '> Slug: demo\n> Status: %s\n> Tree: %s\n> Date: 2026-11-21 09:30\n> Commit: %s\n> Scope: code\n' "$2" "$3" "${4:-pending}" > "$1"
  if [[ ${5:-demo} != legacy ]]; then
    printf '> Task: %s\n> Cycle: %s\n> Round: %s\n' "${5:-demo}" "${6:-none}" "${7:-none}" >> "$1"
  fi
}
cycle=acbacbacbacbacbacbacbacbacbacbac
other_cycle=bcabcabcabcabcabcabcabcabcabcab
handoff=(--mode handoff --slug demo --task demo --no-loop)
finish=(--mode finish --base "$base" --slug demo --task demo)
count=0
failed=0
expect() {
  local want=$1 name=$2 out rc=0
  shift 2
  out=$(bash "$check" --repo "${target:-$tmp}" "$@" 2>&1) || rc=$?
  count=$((count + 1))
  if [[ $want == PASS && $rc == 0 && $out == *PASS* || $want == BLOCKED && $rc != 0 && $out == *BLOCKED* ]]; then
    printf '[PASS] %s\n' "$name"
  else
    printf '[FAIL] %s: rc=%s %s\n' "$name" "$rc" "$out" >&2
    failed=$((failed + 1))
  fi
}

record "$v" PASS "$tree"
record "$r" READY "$tree"
expect PASS 暂存代码与未跟踪证据 "${handoff[@]}"
expect BLOCKED handoff须显式声明任务和Loop上下文 --mode handoff --slug demo
for key in Status Date Tree Commit Slug Scope Task Cycle Round; do
  cp "$r" .ship/original
  sed "/^> $key:/d" .ship/original > "$r"
  expect BLOCKED "缺少$key" "${handoff[@]}"
  cp .ship/original "$r"
  sed -n "/^> $key:/p" .ship/original >> "$r"
  expect BLOCKED "同值重复$key" "${handoff[@]}"
  mv .ship/original "$r"
done
record "$v" PASS "$tree" pending legacy
record "$r" READY "$tree" pending legacy
expect BLOCKED 旧证据默认拒绝 "${handoff[@]}"
expect PASS 明确未启用Loop的旧证据可显式兼容 "${handoff[@]}" --allow-legacy
record "$v" PASS "$tree"
expect BLOCKED 不混用新旧证据 "${handoff[@]}" --allow-legacy
record "$r" READY "$tree"
sed 's/^> Scope:.*/> Scope:   /' "$r" > .ship/edited
mv .ship/edited "$r"
expect BLOCKED 范围全空白 "${handoff[@]}"
sed 's/^> Date:.*/> Date: yesterday/' "$v" > .ship/edited
mv .ship/edited "$v"
record "$r" READY "$tree"
expect BLOCKED 日期无效 "${handoff[@]}"
record "$v" PASS "$tree"
expect BLOCKED handoff缺slug --mode handoff
expect BLOCKED 非法slug --mode handoff --slug ../demo
record "$v" FAIL "$tree"
expect BLOCKED verify失败 "${handoff[@]}"
record "$v" PASS "$tree"
record "$r" HOLD "$tree"
expect BLOCKED review失败 "${handoff[@]}"
record "$r" READY "$base"
expect BLOCKED 两份tree不同 "${handoff[@]}"
record "$v" PASS "$base"
expect BLOCKED 两份tree均过期 "${handoff[@]}"
record "$v" PASS "$tree"
record "$r" READY "$tree"
sed 's/^> Status:/Status:/' "$r" > .ship/edited
mv .ship/edited "$r"
expect BLOCKED 裸状态不作字段 "${handoff[@]}"
record "$r" READY "$tree"
sed 's/^> Tree:/Tree:/' "$r" > .ship/edited
mv .ship/edited "$r"
expect BLOCKED 裸tree不作字段 "${handoff[@]}"
record "$r" READY "$tree"
printf '> Status: HOLD\n' >> "$r"
expect BLOCKED 矛盾字段 "${handoff[@]}"
record "$r" READY "$tree"
{ printf '<!--\n'; cat "$v"; printf '%s\n' '-->'; } > .ship/edited
mv .ship/edited "$v"
expect BLOCKED "HTML注释中的记录头不能授权" "${handoff[@]}"
record "$v" PASS "$tree"
printf 'dirty\n' >> code
expect BLOCKED 未暂存代码 "${handoff[@]}"
git restore code
printf x > $'odd\nname'
expect BLOCKED 未跟踪文件 "${handoff[@]}"
rm $'odd\nname'
git commit -qm two
tip=$(git rev-parse HEAD)
record "$v" PASS "$tree" "$tip"
record "$r" READY "$tree" "$tip"
expect BLOCKED 未提交的证据 "${finish[@]}"
git add .ship
git commit -qm evidence
evidence=$(git rev-parse HEAD)
expect PASS 多代码提交与尾部证据 "${finish[@]}"
for value in pending "${tip:0:7}" "${tip%?}g"; do
  git reset -q --hard "$tip"
  git checkout "$evidence" -- "$v" "$r"
  record "$r" READY "$tree" "$value"
  git add "$r"
  git commit -qm malformed
  expect BLOCKED "finish拒绝Commit=$value" "${finish[@]}"
done
git reset -q --hard "$evidence"
printf '更多验证\n' >> "$v"
git commit -qam verify-update
expect BLOCKED 配对后单改验证 "${finish[@]}"
printf '更多审查\n' >> "$r"
git commit -qam review-update
expect BLOCKED 配对后拆改两份记录 "${finish[@]}"
git reset -q --hard "$evidence"
expect BLOCKED finish缺slug --mode finish --base "$base"
expect BLOCKED 无效基线 --mode finish --slug demo --base missing
expect BLOCKED 不借用其他任务证据 --mode finish --slug other --base "$base"
record "$v" FAIL "$tree"
expect PASS 忽略工作区证据 "${finish[@]}"
git commit -qam invalid
record "$v" PASS "$tree"
expect BLOCKED 工作区伪造不能放行 "${finish[@]}"
git reset -q --hard "$tip"
git commit --amend -qm reword
git cherry-pick "$evidence" >/dev/null
expect PASS 改写消息后旧Commit仍有效 "${finish[@]}"
printf x >> code
git add code
expect BLOCKED finish暂存代码 "${finish[@]}"
printf x >> "$v"
git add "$v"
git commit -qm mixed
expect BLOCKED 混合提交不能豁免 "${finish[@]}"
git reset -q --hard "$tip"
git checkout "$evidence" -- "$v"
git commit -qm verify
git checkout "$evidence" -- "$r"
git commit -qm review
expect BLOCKED 分开提交不构成同一证据提交 "${finish[@]}"

git reset -q --hard "$tip"
git checkout "$evidence" -- "$v" "$r"
mkdir -p .ship/tasks/demo
printf '{}\n' > .ship/tasks/demo/loop.json
git add .ship/tasks/demo/loop.json
git commit -qm evidence-with-local-state
expect BLOCKED 证据提交不能夹带本地Loop状态 "${finish[@]}"

git reset -q --hard "$tip"
git clone -q --no-local "$tmp" "$scratch/code-only"
target="$scratch/code-only" expect BLOCKED 新clone只有代码提交 "${finish[@]}"
mkdir -p .ship/{verify,review}
record "$v" PASS "$tree" "$tip" demo "$cycle" 2
record "$r" READY "$tree" "$tip" demo "$other_cycle" 2
git add "$v" "$r"
git commit -qm mismatched-cycle
expect BLOCKED finish拒绝两份证据周期不一致 "${finish[@]}"
record "$v" PASS "$tree" "$tip" demo "$cycle" 2
record "$r" READY "$tree" "$tip" demo "$cycle" 3
git add "$v" "$r"
git commit -qm mismatched-round
expect BLOCKED finish拒绝两份证据轮次不一致 "${finish[@]}"
record "$v" PASS "$tree" "$tip" other "$cycle" 2
record "$r" READY "$tree" "$tip" other "$cycle" 2
git add "$v" "$r"
git commit -qm wrong-task
expect BLOCKED finish拒绝同树同slug但任务错误 "${finish[@]}"
record "$v" PASS "$tree" "$tip" demo "$cycle" 2
record "$r" READY "$tree" "$tip" demo "$cycle" 2
git add "$v" "$r"
git commit -qm bound-evidence
git clone -q --no-local "$tmp" "$scratch/with-evidence"
[[ ! -e "$scratch/with-evidence/.ship/tasks" ]]
target="$scratch/with-evidence" expect PASS 新clone只靠已绑定的入库证据收尾 "${finish[@]}"
target="$scratch/with-evidence" expect BLOCKED Loop收尾不能声明未启用 "${finish[@]}" --no-loop --allow-legacy
record "$v" PASS "$tree" "$tip" legacy
record "$r" READY "$tree" "$tip" legacy
git add "$v" "$r"
git commit -qm legacy-evidence
expect BLOCKED finish默认拒绝旧证据 "${finish[@]}"
expect PASS finish仅在显式兼容下接受未启用Loop的旧证据 "${finish[@]}" --no-loop --allow-legacy

ng="$scratch/nongit"
mkdir -p "$ng/.ship/verify" "$ng/.ship/review"
printf 'value = 1\n' > "$ng/app.py"
record_ng() {
  printf '> Status: %s\n> Date: 2026-11-21 09:30\n> Tree: %s\n> Commit: none\n> Slug: plain\n> Task: plain\n> Cycle: none\n> Round: none\n> Vcs: none\n> Scope: app.py\n' "$2" "$3" > "$1"
}
ng_tree=$(bash "$check" --mode snapshot --repo "$ng" | awk '{print $2}')
record_ng "$ng/.ship/verify/plain.md" PASS "$ng_tree"
record_ng "$ng/.ship/review/plain.md" READY "$ng_tree"
handoff_ng=(--mode handoff --slug plain --task plain --no-loop)
finish_ng=(--mode finish --slug plain --task plain)
target="$ng" expect PASS 非Git仓库handoff "${handoff_ng[@]}"
printf 'value = 2\n' > "$ng/app.py"
target="$ng" expect BLOCKED 非Git快照漂移 "${handoff_ng[@]}"
printf 'value = 1\n' > "$ng/app.py"
target="$ng" expect PASS 非Git快照恢复 "${handoff_ng[@]}"
target="$ng" expect PASS 非Git-finish无需base "${finish_ng[@]}"
sed 's/^> Vcs: none/> Vcs: git/' "$ng/.ship/review/plain.md" > "$ng/.ship/edited"
mv "$ng/.ship/edited" "$ng/.ship/review/plain.md"
target="$ng" expect BLOCKED 非Git拒绝Git凭证 "${handoff_ng[@]}"
record_ng "$ng/.ship/review/plain.md" READY "$ng_tree"
sed 's/^> Commit: none/> Commit: pending/' "$ng/.ship/verify/plain.md" > "$ng/.ship/edited"
mv "$ng/.ship/edited" "$ng/.ship/verify/plain.md"
target="$ng" expect BLOCKED 非Git拒绝pending "${handoff_ng[@]}"

printf '%s/%s 通过\n' "$((count - failed))" "$count"
[[ $failed == 0 ]]

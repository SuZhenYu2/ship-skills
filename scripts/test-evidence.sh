#!/usr/bin/env bash
set -euo pipefail

check=$(cd "$(dirname "$0")" && pwd)/check-evidence.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
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
record() { printf '> Slug: demo\n> Status: %s\n> Tree: %s\n> Date: 2026-11-21 09:30\n> Commit: %s\n> Scope: code\n' "$2" "$3" "${4:-pending}" > "$1"; }
handoff=(--mode handoff --slug demo)
finish=(--mode finish --base "$base" --slug demo)
count=0
failed=0
expect() {
  local want=$1 name=$2 out rc=0
  shift 2
  out=$(bash "$check" --repo "$tmp" "$@" 2>&1) || rc=$?
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
for key in Status Date Tree Commit Slug Scope; do
  cp "$r" .ship/original
  sed "/^> $key:/d" .ship/original > "$r"
  expect BLOCKED "缺少$key" "${handoff[@]}"
  cp .ship/original "$r"
  sed -n "/^> $key:/p" .ship/original >> "$r"
  expect BLOCKED "同值重复$key" "${handoff[@]}"
  mv .ship/original "$r"
done
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
printf '%s/%s 通过\n' "$((count - failed))" "$count"
[[ $failed == 0 ]]

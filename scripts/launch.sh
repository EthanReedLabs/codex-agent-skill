#!/bin/bash
# codex-agent 发射器 v3
# 用法: launch.sh <项目根> <slug> <sandbox> <brief文件> [effort] [resume_session_id]
# 环境变量: LAUNCH_TIMEOUT 超时秒数（默认 900）
# 平台: 依赖 Bash（macOS / Linux / WSL / Git Bash）
# v3: slug 运行锁（防双终端同 slug 竞态）；归档含 stderr/marker 且任一存在即触发；
#     显式 approval_policy；进程组击杀 TERM→KILL 升级；原子终态文件 <slug>.status
set -u
ROOT="$1"; SLUG="$2"; SANDBOX="$3"; BRIEF="$4"; EFFORT="${5:-}"; RESUME="${6:-}"
TIMEOUT="${LAUNCH_TIMEOUT:-900}"
[ -s "$BRIEF" ] || { echo "LAUNCH_REFUSED slug=$SLUG reason=brief_missing_or_empty brief=$BRIEF"; exit 4; }
CA="$ROOT/.codex-agent"; mkdir -p "$CA"

# 项目根一致性防呆（v3.2）：任务书必须位于目标项目根的 .codex-agent/ 下——
# 不一致是"会话 cwd 与目标项目混淆"的特征信号（多项目会话踩过的坑）
CA_ABS="$(cd "$CA" && pwd)"; BRIEF_DIR="$(cd "$(dirname "$BRIEF")" && pwd)"
if [ "$BRIEF_DIR" != "$CA_ABS" ]; then
  echo "LAUNCH_REFUSED slug=$SLUG reason=root_brief_mismatch brief_dir=$BRIEF_DIR expected=$CA_ABS —— 项目根判定疑似错误（见协议 §3.0）"
  exit 5
fi

# slug 运行锁：同 slug 并发发射直接失败，绝不归档活跃任务的产物
LOCK="$CA/$SLUG.lock.d"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "LAUNCH_REFUSED slug=$SLUG reason=lock_held owner=$(cat "$LOCK/owner" 2>/dev/null || echo unknown)"
  exit 3
fi
echo "pid=$$ host=$(hostname) time=$(date +%s)" > "$LOCK/owner"
cleanup_lock() { rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null; }
trap cleanup_lock EXIT

# 归档上一轮产物：last/events/stderr/status 任一存在即触发，全部按轮归档（含 marker）
# status 必须归档：残留旧终态会让「等 status 出现」的 watcher 立即误报完成
if [ -f "$CA/$SLUG.last.md" ] || [ -f "$CA/$SLUG.events.jsonl" ] || [ -s "$CA/$SLUG.stderr.log" ] || [ -f "$CA/$SLUG.status" ]; then
  N=1; while [ -f "$CA/$SLUG.round$N.last.md" ] || [ -f "$CA/$SLUG.round$N.events.jsonl" ]; do N=$((N+1)); done
  for ext in last.md events.jsonl stderr.log marker status; do
    [ -e "$CA/$SLUG.$ext" ] && mv "$CA/$SLUG.$ext" "$CA/$SLUG.round$N.$ext"
  done
fi

touch "$CA/$SLUG.marker"
ARGS=(--skip-git-repo-check --json -o "$CA/$SLUG.last.md" -c "approval_policy=\"never\"")
[ -n "$EFFORT" ] && ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
START=$(date +%s)

set -m  # 后台作业获得独立进程组，便于整组击杀
if [ -n "$RESUME" ]; then
  codex exec resume "$RESUME" "${ARGS[@]}" \
    -c "sandbox_mode=\"$SANDBOX\"" \
    -c "sandbox_workspace_write.writable_roots=[\"$ROOT\"]" \
    "$(cat "$BRIEF")" < /dev/null > "$CA/$SLUG.events.jsonl" 2> "$CA/$SLUG.stderr.log" &
else
  codex exec -C "$ROOT" -s "$SANDBOX" "${ARGS[@]}" \
    "$(cat "$BRIEF")" < /dev/null > "$CA/$SLUG.events.jsonl" 2> "$CA/$SLUG.stderr.log" &
fi
PID=$!
TIMED_OUT=0

( sleep "$TIMEOUT"; kill -0 "$PID" 2>/dev/null && { \
    echo "LAUNCH_TIMEOUT slug=$SLUG after ${TIMEOUT}s (TERM->KILL process group)" >> "$CA/$SLUG.stderr.log"; \
    kill -TERM -- -"$PID" 2>/dev/null; sleep 5; kill -KILL -- -"$PID" 2>/dev/null; } ) &
WATCHDOG=$!
wait "$PID"; RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
grep -q 'LAUNCH_TIMEOUT' "$CA/$SLUG.stderr.log" 2>/dev/null && TIMED_OUT=1

# 原子终态文件：Monitor 与验收以此为权威判据（而非 .last.md 是否出现）
if [ "$TIMED_OUT" = 1 ]; then STATUS=timeout; elif [ "$RC" = 0 ]; then STATUS=success; else STATUS=failed; fi
printf 'status=%s rc=%s duration=%ss last=%s\n' "$STATUS" "$RC" "$(( $(date +%s) - START ))" "$CA/$SLUG.last.md" > "$CA/$SLUG.status.tmp"
mv "$CA/$SLUG.status.tmp" "$CA/$SLUG.status"

echo "LAUNCH_DONE slug=$SLUG status=$STATUS rc=$RC duration=$(( $(date +%s) - START ))s"
[ "$STATUS" = success ] || exit 1

#!/bin/bash
# codex-agent 簿记器：ACTIVE.md 的加锁注册/更新（消除各会话手写锁脚本的差异）
# 用法: active-update.sh <项目根> add  <slug> "<完整行内容（含开头的- ）>"
#       active-update.sh <项目根> done <slug> "<替换后的完整行内容>"
# 锁协议：mkdir 原子抢锁 + owner 文件；等待方每 2 秒重试；锁 >60 秒且 owner 进程不存活才强拆
set -u
ROOT="$1"; MODE="$2"; SLUG="$3"; LINE="$4"
CA="$ROOT/.codex-agent"; LOCK="$CA/.lock"; mkdir -p "$CA"
WAITED=0
while ! mkdir "$LOCK" 2>/dev/null; do
  OWNER_PID=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' "$LOCK/owner" 2>/dev/null)
  AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || date +%s) ))
  if [ "$AGE" -gt 60 ] && [ -n "$OWNER_PID" ] && ! kill -0 "$OWNER_PID" 2>/dev/null; then
    echo "STALE_LOCK_BROKEN age=${AGE}s dead_pid=$OWNER_PID"
    rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null; continue
  fi
  [ "$AGE" -gt 60 ] && { echo "LOCK_HELD_UNVERIFIABLE age=${AGE}s owner=$(cat "$LOCK/owner" 2>/dev/null || echo unknown) —— 不自动强拆，请人工处置"; exit 4; }
  sleep 2; WAITED=$((WAITED+2))
done
echo "pid=$$ host=$(hostname) time=$(date +%s)" > "$LOCK/owner"
release() { rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null; }
trap release EXIT

case "$MODE" in
  add)
    grep -q "^- ${SLUG} |" "$CA/ACTIVE.md" 2>/dev/null && { echo "SLUG_TAKEN slug=${SLUG} (已存在，换名)"; exit 3; }
    printf '%s\n' "$LINE" >> "$CA/ACTIVE.md" ;;
  done|update)
    PY="$(command -v python3 || command -v python)"
    SLUG="$SLUG" LINE="$LINE" CA="$CA" "$PY" - <<'EOF' || exit 5
import os,sys
p=os.environ['CA']+'/ACTIVE.md'; slug=os.environ['SLUG']; new=os.environ['LINE']
ls=open(p,encoding='utf-8').read().splitlines(keepends=False)
hits=[i for i,l in enumerate(ls) if l.startswith(f'- {slug} |')]
if len(hits)!=1: print(f'LINE_MATCH_ERROR slug={slug} hits={len(hits)}'); sys.exit(1)
ls[hits[0]]=new
open(p,'w',encoding='utf-8').write('\n'.join(ls)+'\n')
EOF
    ;;
  *) echo "未知模式 $MODE"; exit 2 ;;
esac
echo "ACTIVE_UPDATED mode=$MODE slug=$SLUG waited=${WAITED}s"

#!/bin/bash
# codex-agent 验收器 v3：真验收（非零退出码表示不通过）
# 用法: verify.sh <项目根> <slug> [oneshot|full] [允许路径 egrep 模式]
# 检查项：终态文件 status=success；越界清单（git 仓库以 git status 为权威，含删除）；
#         五个固定标题逐项恰好一次（oneshot 模式豁免）；FAIL(❌)=0；允许路径过滤（可选）
set -u
ROOT="$1"; SLUG="$2"; MODE="${3:-full}"; ALLOW="${4:-}"
CA="$ROOT/.codex-agent"; ERR=0
PY="$(command -v python3 || command -v python)" || { echo "FAIL: 无 python 解释器"; exit 2; }

echo "=== 终态 ==="
if [ -f "$CA/$SLUG.status" ]; then
  cat "$CA/$SLUG.status"
  grep -q '^status=success' "$CA/$SLUG.status" || { echo "FAIL: 终态非 success"; ERR=1; }
else
  echo "WARN: 无终态文件（MCP 通道或旧版发射器）"
fi
[ -f "$CA/$SLUG.last.md" ] || { echo "FAIL: 缺少 $SLUG.last.md"; exit 1; }

echo "=== 越界检查 ==="
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # git 为权威：含删除/重命名
  CHANGES=$(git -C "$ROOT" status --porcelain | grep -v '/.codex-agent/' || true)
else
  echo "(非 git 降级模式：仅能枚举现存新文件，删除不可检测——协议 §7 已声明该风险)"
  CHANGES=$(find "$ROOT" -type f -newer "$CA/$SLUG.marker" \
    ! -path "*/.codex-agent/*" ! -path "*/__pycache__/*" ! -path "*/.pytest_cache/*" ! -name ".DS_Store")
fi
echo "${CHANGES:-（无改动）}"
if [ -n "$ALLOW" ] && [ -n "$CHANGES" ]; then
  VIOL=$(echo "$CHANGES" | grep -Ev "$ALLOW" | grep -Ev '^\s*$' || true)
  [ -n "$VIOL" ] && { echo "FAIL: 越界改动："; echo "$VIOL"; ERR=1; }
fi

if [ "$MODE" != "oneshot" ]; then
  echo "=== 五段标题逐项校验 ==="
  for h in "结果" "过程" "遇到的问题" "解决方式" "遗留风险与建议"; do
    n=$(grep -c "^## ${h}" "$CA/$SLUG.last.md")
    [ "${n}" = 1 ] || { echo "FAIL: 标题 [${h}] 出现 ${n} 次（应恰好 1 次）"; ERR=1; }
  done
  echo "=== 完成标准统计 ==="
  "$PY" -c "t=open('$CA/$SLUG.last.md',encoding='utf-8').read();import sys;f=t.count('❌');print('PASS',t.count('✅'),'FAIL',f);sys.exit(1 if f else 0)" || ERR=1
fi

echo "=== 汇报正文 ==="
cat "$CA/$SLUG.last.md"
[ "$ERR" = 0 ] && echo "=== VERIFY: PASS ===" || echo "=== VERIFY: FAIL ==="
exit $ERR

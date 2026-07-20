#!/usr/bin/env bash
# Usage: verify.sh <project-root> <slug> [oneshot|full] [allowed-path-regex]
set -u

fail_usage() { printf 'usage: verify.sh <project-root> <slug> [oneshot|full] [allowed-path-regex]\n' >&2; exit 2; }
[ "$#" -ge 2 ] && [ "$#" -le 4 ] || fail_usage
ROOT=$1; SLUG=$2; MODE=${3:-full}; ALLOW=${4:-}
case "$SLUG" in ''|*[!a-zA-Z0-9._-]*) printf 'FAIL: invalid slug\n' >&2; exit 2;; esac
case "$MODE" in oneshot|full) ;; *) printf 'FAIL: mode must be oneshot or full\n' >&2; exit 2;; esac
[ -d "$ROOT" ] || { printf 'FAIL: project root does not exist\n' >&2; exit 2; }
ROOT=$(cd "$ROOT" && pwd -P)
CA="$ROOT/.codex-agent"; ERR=0
PY=$(command -v python3 || command -v python) || { echo "FAIL: no Python interpreter"; exit 2; }

echo "=== 终态 ==="
if [ ! -f "$CA/$SLUG.status" ]; then
  echo "FAIL: 缺少终态文件 $SLUG.status"; ERR=1
else
  cat "$CA/$SLUG.status"
  grep -q '^status=success ' "$CA/$SLUG.status" || { echo "FAIL: 终态非 success"; ERR=1; }
  if grep -q ' sandbox=workspace-write ' "$CA/$SLUG.status" && [ -z "$ALLOW" ]; then
    echo "FAIL: workspace-write 验收必须提供允许路径正则"; ERR=1
  fi
fi
[ -f "$CA/$SLUG.last.md" ] || { echo "FAIL: 缺少 $SLUG.last.md"; exit 1; }

echo "=== 本轮改动 ==="
if [ ! -f "$CA/$SLUG.baseline" ]; then
  echo "FAIL: 缺少基线快照 $SLUG.baseline"; ERR=1; CHANGES=
else
  CHANGES=$(PYTHONDONTWRITEBYTECODE=1 "$PY" - "$ROOT" "$CA/$SLUG.baseline" "$(dirname "$0")/snapshot.py" <<'PY'
import importlib.util, json, pathlib, sys
root, baseline_path, module_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("snapshot", module_path)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
before = json.loads(pathlib.Path(baseline_path).read_text(encoding="utf-8"))
after = module.snapshot(pathlib.Path(root))
for path in sorted(set(before) | set(after)):
    if path not in before: print("A " + path)
    elif path not in after: print("D " + path)
    elif before[path] != after[path]: print("M " + path)
PY
  ) || { echo "FAIL: 无法比较基线"; ERR=1; CHANGES=; }
fi
echo "${CHANGES:-（无改动）}"
if [ -n "$ALLOW" ] && [ -n "$CHANGES" ]; then
  VIOL=$(printf '%s\n' "$CHANGES" | "$PY" -c '
import re,sys
pattern=sys.argv[1]
try: rx=re.compile(pattern)
except re.error as exc: print(f"INVALID_REGEX {exc}"); sys.exit(2)
for line in sys.stdin:
    path=line.rstrip("\n")[2:]
    if not rx.fullmatch(path): print(line, end="")
' "$ALLOW"); FILTER_RC=$?
  [ "$FILTER_RC" -eq 0 ] || { echo "FAIL: 允许路径正则无效"; ERR=1; }
  [ -z "$VIOL" ] || { echo "FAIL: 越界改动："; echo "$VIOL"; ERR=1; }
fi

if [ "$MODE" = full ]; then
  echo "=== 五段标题校验 ==="
  for h in "结果" "过程" "遇到的问题" "解决方式" "遗留风险与建议"; do
    n=$(grep -c "^## ${h}$" "$CA/$SLUG.last.md" || true)
    [ "$n" = 1 ] || { echo "FAIL: 标题 [${h}] 出现 ${n} 次（应恰好 1 次）"; ERR=1; }
  done
  echo "=== 完成标准统计 ==="
  "$PY" - "$CA/$SLUG.last.md" <<'PY' || ERR=1
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
failed = text.count("❌")
checks = [line for line in text.splitlines() if "✅" in line]
def has_evidence(line):
    value = line.lower()
    return ("命令" in value or "command" in value) and "exit code" in value and ("输出" in value or "output" in value)
bad_evidence = [line for line in checks if not has_evidence(line)]
print("PASS", len(checks), "FAIL", failed, "MISSING_EVIDENCE", len(bad_evidence))
if not checks:
    print("FAIL: 未找到任何完成标准 ✅")
if bad_evidence:
    print("FAIL: 以下 ✅ 缺少命令、exit code 或输出证据：")
    print("\n".join(bad_evidence))
raise SystemExit(bool(failed or bad_evidence or not checks))
PY
fi

echo "=== 汇报正文 ==="
cat "$CA/$SLUG.last.md"
[ "$ERR" -eq 0 ] && echo "=== VERIFY: PASS ===" || echo "=== VERIFY: FAIL ==="
exit "$ERR"

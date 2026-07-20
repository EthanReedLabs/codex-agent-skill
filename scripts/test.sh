#!/usr/bin/env bash
set -eu

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-agent-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0

assert_fails() {
  if "$@" > "$TMP/assert.out" 2>&1; then
    echo "FAIL: expected failure: $*" >&2; exit 1
  fi
  PASS=$((PASS + 1))
}
assert_contains() {
  grep -F -- "$1" "$2" >/dev/null || { echo "FAIL: missing [$1] in $2" >&2; exit 1; }
  PASS=$((PASS + 1))
}

# Input validation must fail before doing any work.
assert_fails "$SKILL_DIR/scripts/launch.sh"
assert_fails "$SKILL_DIR/scripts/launch.sh" "$TMP" '../bad' read-only "$TMP/missing"
assert_fails "$SKILL_DIR/scripts/active-update.sh" "$TMP" add '../bad' '- ../bad | 状态: active'

PROJECT="$TMP/project"; BIN="$TMP/bin"
mkdir -p "$PROJECT/.codex-agent" "$BIN"
printf 'pre-existing\n' > "$PROJECT/dirty.txt"
printf '## 目标\nmodify the fixture\n' > "$PROJECT/.codex-agent/demo.brief.md"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
set -eu
OUT=
ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) OUT=$2; shift 2;;
    -C) ROOT=$2; shift 2;;
    *) shift;;
  esac
done
[ -n "$OUT" ]
[ -n "$ROOT" ] || ROOT=${FAKE_PROJECT:?}
cat > "$OUT" <<'REPORT'
## 结果
✅ fixture updated; command: fake-codex; exit code: 0; output tail: ok
## 过程
1. updated fixture
## 遇到的问题
无
## 解决方式
无
## 遗留风险与建议
无
REPORT
printf 'changed\n' > "$ROOT/result.txt"
printf '{"thread_id":"00000000-0000-0000-0000-000000000000"}\n'
SH
chmod +x "$BIN/codex"

PATH="$BIN:$PATH" FAKE_PROJECT="$PROJECT" LAUNCH_TIMEOUT=10 \
  "$SKILL_DIR/scripts/launch.sh" "$PROJECT" demo workspace-write \
  "$PROJECT/.codex-agent/demo.brief.md" low > "$TMP/launch.out"
assert_contains 'LAUNCH_DONE slug=demo status=success' "$TMP/launch.out"
assert_contains 'status=success ' "$PROJECT/.codex-agent/demo.status"
assert_contains 'session_id=00000000-0000-0000-0000-000000000000' "$PROJECT/.codex-agent/demo.session"

"$SKILL_DIR/scripts/verify.sh" "$PROJECT" demo full 'result[.]txt' > "$TMP/verify.out"
assert_contains 'A result.txt' "$TMP/verify.out"
assert_contains '=== VERIFY: PASS ===' "$TMP/verify.out"
if grep -F 'dirty.txt' "$TMP/verify.out" >/dev/null; then
  echo 'FAIL: pre-existing file was attributed to delegated task' >&2; exit 1
fi
PASS=$((PASS + 1))
assert_fails "$SKILL_DIR/scripts/verify.sh" "$PROJECT" demo full
assert_fails "$SKILL_DIR/scripts/verify.sh" "$PROJECT" demo full 'src/.*'

OTHER="$TMP/other"; mkdir -p "$OTHER/.codex-agent"
printf '## 目标\nwrong root\n' > "$OTHER/.codex-agent/wrong.brief.md"
assert_fails env PATH="$BIN:$PATH" FAKE_PROJECT="$OTHER" LAUNCH_TIMEOUT=10 \
  "$SKILL_DIR/scripts/launch.sh" "$OTHER" wrong workspace-write \
  "$OTHER/.codex-agent/wrong.brief.md" low 00000000-0000-0000-0000-000000000000

# A timed-out session cannot resume until the coordinator explicitly attests
# that the workspace was reviewed.
printf 'status=timeout rc=143 duration=10s sandbox=workspace-write last=x\n' > "$PROJECT/.codex-agent/demo.status"
assert_fails env PATH="$BIN:$PATH" FAKE_PROJECT="$PROJECT" LAUNCH_TIMEOUT=10 \
  "$SKILL_DIR/scripts/launch.sh" "$PROJECT" blocked workspace-write \
  "$PROJECT/.codex-agent/demo.brief.md" low 00000000-0000-0000-0000-000000000000
PATH="$BIN:$PATH" FAKE_PROJECT="$PROJECT" LAUNCH_TIMEOUT=10 CODEX_AGENT_TIMEOUT_REVIEWED=1 \
  "$SKILL_DIR/scripts/launch.sh" "$PROJECT" reviewed workspace-write \
  "$PROJECT/.codex-agent/demo.brief.md" low 00000000-0000-0000-0000-000000000000 > "$TMP/reviewed.out"
assert_contains 'LAUNCH_DONE slug=reviewed status=success' "$TMP/reviewed.out"

# Reusing a slug archives every round artifact, including status and baseline.
rm -f "$PROJECT/result.txt"
PATH="$BIN:$PATH" FAKE_PROJECT="$PROJECT" LAUNCH_TIMEOUT=10 \
  "$SKILL_DIR/scripts/launch.sh" "$PROJECT" demo workspace-write \
  "$PROJECT/.codex-agent/demo.brief.md" > "$TMP/launch2.out"
[ -f "$PROJECT/.codex-agent/demo.round1.status" ]
[ -f "$PROJECT/.codex-agent/demo.round1.baseline" ]
[ -f "$PROJECT/.codex-agent/demo.round1.session" ]
PASS=$((PASS + 3))

# A session proven to belong to this root can be resumed.
PATH="$BIN:$PATH" FAKE_PROJECT="$PROJECT" LAUNCH_TIMEOUT=10 \
  "$SKILL_DIR/scripts/launch.sh" "$PROJECT" resumed workspace-write \
  "$PROJECT/.codex-agent/demo.brief.md" low 00000000-0000-0000-0000-000000000000 > "$TMP/resume.out"
assert_contains 'LAUNCH_DONE slug=resumed status=success' "$TMP/resume.out"

"$SKILL_DIR/scripts/active-update.sh" "$PROJECT" add task-a '- task-a | 状态: active' > /dev/null
"$SKILL_DIR/scripts/active-update.sh" "$PROJECT" "done" task-a '- task-a | 状态: done' > /dev/null
assert_contains '- task-a | 状态: done' "$PROJECT/.codex-agent/ACTIVE.md"
assert_fails "$SKILL_DIR/scripts/active-update.sh" "$PROJECT" add task-a '- task-a | 状态: active'

# Installer is idempotent and updates contents instead of nesting the source dir.
INSTALL_HOME="$TMP/home"; INSTALL_CLAUDE="$INSTALL_HOME/.claude"
mkdir -p "$INSTALL_HOME"
printf '{"mcpServers":{"codex":{}}}\n' > "$INSTALL_HOME/.claude.json"
mkdir -p "$INSTALL_CLAUDE/skills/codex-agent/docs"
printf 'legacy\n' > "$INSTALL_CLAUDE/skills/codex-agent/docs/PLAN.md"
printf 'legacy\n' > "$INSTALL_CLAUDE/skills/codex-agent/docs/SPEC.md"
HOME="$INSTALL_HOME" CODEX_AGENT_CLAUDE_DIR="$INSTALL_CLAUDE" \
  CODEX_AGENT_CLAUDE_CONFIG="$INSTALL_HOME/.claude.json" bash "$SKILL_DIR/install.sh" > "$TMP/install1.out"
HOME="$INSTALL_HOME" CODEX_AGENT_CLAUDE_DIR="$INSTALL_CLAUDE" \
  CODEX_AGENT_CLAUDE_CONFIG="$INSTALL_HOME/.claude.json" bash "$SKILL_DIR/install.sh" > "$TMP/install2.out"
[ -f "$INSTALL_CLAUDE/skills/codex-agent/SKILL.md" ]
[ ! -e "$INSTALL_CLAUDE/skills/codex-agent/codex-agent-skill" ]
[ ! -e "$INSTALL_CLAUDE/skills/codex-agent/docs" ]
[ "$(grep -c '^## Codex 委托$' "$INSTALL_CLAUDE/CLAUDE.md")" -eq 1 ]
PASS=$((PASS + 4))

printf 'PASS: %s assertions\n' "$PASS"

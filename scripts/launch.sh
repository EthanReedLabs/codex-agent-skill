#!/usr/bin/env bash
# Usage: launch.sh <project-root> <slug> <sandbox> <brief-file> [effort] [resume-session-id]
set -u

die() { printf 'LAUNCH_REFUSED reason=%s\n' "$1" >&2; exit "${2:-2}"; }
[ "$#" -ge 4 ] && [ "$#" -le 6 ] || die "usage" 2

ROOT=$1; SLUG=$2; SANDBOX=$3; BRIEF=$4; EFFORT=${5:-}; RESUME=${6:-}
TIMEOUT=${LAUNCH_TIMEOUT:-900}
case "$SLUG" in ''|*[!a-zA-Z0-9._-]*) die "invalid_slug slug=$SLUG";; esac
case "$SANDBOX" in read-only|workspace-write) ;; *) die "invalid_sandbox sandbox=$SANDBOX";; esac
case "$EFFORT" in ''|low|medium|high) ;; *) die "invalid_effort effort=$EFFORT";; esac
case "$TIMEOUT" in ''|*[!0-9]*) die "invalid_timeout timeout=$TIMEOUT";; esac
[ "$TIMEOUT" -gt 0 ] || die "invalid_timeout timeout=$TIMEOUT"
[ -z "$RESUME" ] || case "$RESUME" in
  ????????-????-????-????-????????????) ;;
  *) die "invalid_resume_id";;
esac
[ -d "$ROOT" ] || die "root_missing root=$ROOT"
[ -s "$BRIEF" ] || die "brief_missing_or_empty brief=$BRIEF" 4
command -v codex >/dev/null 2>&1 || die "codex_not_found" 127

ROOT_ABS=$(cd "$ROOT" && pwd -P) || die "root_unresolvable root=$ROOT"
CA="$ROOT_ABS/.codex-agent"
mkdir -p "$CA" || die "state_dir_unwritable path=$CA"
CA_ABS=$(cd "$CA" && pwd -P)
BRIEF_DIR=$(cd "$(dirname "$BRIEF")" 2>/dev/null && pwd -P) || die "brief_dir_unresolvable"
[ "$BRIEF_DIR" = "$CA_ABS" ] || die "root_brief_mismatch brief_dir=$BRIEF_DIR expected=$CA_ABS" 5

if [ -n "$RESUME" ]; then
  PROVEN=0; PROOF_PATH=
  for proof in "$CA"/*.session "$CA"/*.round*.session; do
    [ -f "$proof" ] || continue
    if grep -Fqx "session_id=$RESUME" "$proof" && grep -Fqx "project_root=$ROOT_ABS" "$proof"; then
      PROVEN=1
      [ -n "$PROOF_PATH" ] || PROOF_PATH=$proof
      candidate_status=${proof%.session}.status
      if [ -f "$candidate_status" ] && grep -q '^status=success ' "$candidate_status"; then
        PROOF_PATH=$proof; break
      fi
    fi
  done
  [ "$PROVEN" -eq 1 ] || die "resume_root_unproven session=$RESUME root=$ROOT_ABS" 6
  PROOF_STATUS=${PROOF_PATH%.session}.status
  if [ -f "$PROOF_STATUS" ] && grep -q '^status=timeout ' "$PROOF_STATUS"; then
    [ "${CODEX_AGENT_TIMEOUT_REVIEWED:-0}" = 1 ] || die "timeout_review_required status=$PROOF_STATUS" 7
  fi
fi

LOCK="$CA/$SLUG.lock.d"
mkdir "$LOCK" 2>/dev/null || die "lock_held slug=$SLUG" 3
printf 'pid=%s host=%s time=%s\n' "$$" "$(hostname)" "$(date +%s)" > "$LOCK/owner"
cleanup_lock() { rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup_lock EXIT HUP INT TERM

if [ -e "$CA/$SLUG.last.md" ] || [ -e "$CA/$SLUG.events.jsonl" ] ||
   [ -e "$CA/$SLUG.stderr.log" ] || [ -e "$CA/$SLUG.status" ] ||
   [ -e "$CA/$SLUG.baseline" ] || [ -e "$CA/$SLUG.session" ]; then
  N=1
  while [ -e "$CA/$SLUG.round$N.status" ] || [ -e "$CA/$SLUG.round$N.events.jsonl" ] ||
        [ -e "$CA/$SLUG.round$N.last.md" ]; do N=$((N + 1)); done
  for ext in last.md events.jsonl stderr.log marker status baseline session; do
    [ ! -e "$CA/$SLUG.$ext" ] || mv "$CA/$SLUG.$ext" "$CA/$SLUG.round$N.$ext"
  done
fi

# Capture path + content identity before Codex runs. verify.sh uses this to avoid
# attributing unrelated pre-existing dirty files to the delegated task.
"$(dirname "$0")/snapshot.py" "$ROOT_ABS" > "$CA/$SLUG.baseline" || die "baseline_failed"
touch "$CA/$SLUG.marker"

ARGS=(--skip-git-repo-check --strict-config --json -o "$CA/$SLUG.last.md" -c 'approval_policy="never"')
[ -z "$EFFORT" ] || ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
START=$(date +%s)
set -m
if [ -n "$RESUME" ]; then
  codex exec resume "$RESUME" "${ARGS[@]}" \
    -c "sandbox_mode=\"$SANDBOX\"" \
    -c "sandbox_workspace_write.writable_roots=[\"$ROOT_ABS\"]" \
    - < "$BRIEF" > "$CA/$SLUG.events.jsonl" 2> "$CA/$SLUG.stderr.log" &
else
  codex exec -C "$ROOT_ABS" -s "$SANDBOX" "${ARGS[@]}" \
    - < "$BRIEF" > "$CA/$SLUG.events.jsonl" 2> "$CA/$SLUG.stderr.log" &
fi
PID=$!

(
  sleep "$TIMEOUT"
  if kill -0 "$PID" 2>/dev/null; then
    printf 'LAUNCH_TIMEOUT slug=%s after=%ss\n' "$SLUG" "$TIMEOUT" >> "$CA/$SLUG.stderr.log"
    kill -TERM -- -"$PID" 2>/dev/null || true
    sleep 5
    kill -KILL -- -"$PID" 2>/dev/null || true
  fi
) &
WATCHDOG=$!
wait "$PID"; RC=$?
kill "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true

SESSION_ID=$("$(dirname "$0")/extract-session.py" "$CA/$SLUG.events.jsonl" 2>/dev/null || true)
if [ -n "$SESSION_ID" ]; then
  printf 'session_id=%s\nproject_root=%s\n' "$SESSION_ID" "$ROOT_ABS" > "$CA/$SLUG.session.tmp"
  mv "$CA/$SLUG.session.tmp" "$CA/$SLUG.session"
fi

if grep -q '^LAUNCH_TIMEOUT ' "$CA/$SLUG.stderr.log" 2>/dev/null; then
  STATUS=timeout
elif [ "$RC" -eq 0 ]; then
  STATUS=success
else
  STATUS=failed
fi
DURATION=$(( $(date +%s) - START ))
printf 'status=%s rc=%s duration=%ss sandbox=%s last=%s\n' "$STATUS" "$RC" "$DURATION" "$SANDBOX" "$CA/$SLUG.last.md" > "$CA/$SLUG.status.tmp"
mv "$CA/$SLUG.status.tmp" "$CA/$SLUG.status"
printf 'LAUNCH_DONE slug=%s status=%s rc=%s duration=%ss\n' "$SLUG" "$STATUS" "$RC" "$DURATION"
[ "$STATUS" = success ]

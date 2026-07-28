#!/bin/bash
# The gate runner. This is the only command that decides whether work on this
# branch is done.
#
#   Tools/gate.sh            run every gate in order
#   Tools/gate.sh 10 30      run only the gates whose numeric prefix matches
#
# Gates run in ascending order and the run stops at the first FAIL: a failing
# structural check makes downstream evidence meaningless, so producing it would
# only invite cherry-picking.
#
# Verdicts:
#   PASS        every gate passed
#   INCOMPLETE  no gate failed, but at least one skipped (missing hardware)
#   FAIL        a gate failed
#
# INCOMPLETE is not PASS. A milestone line may only be marked complete in
# Docs/Plan/PLAN.md on a PASS, or on an INCOMPLETE whose skipped gates are named
# explicitly in the session log as outstanding evidence.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || exit 1

GATES_DIR="$REPO_ROOT/Tools/gates"
REPORT="$ARTIFACTS/gate-report.md"

selected=("$@")
matches_selection() {
  [ "${#selected[@]}" -eq 0 ] && return 0
  local prefix="${1%%-*}" want
  for want in "${selected[@]}"; do [ "$prefix" = "$want" ] && return 0; done
  return 1
}

started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
  echo "# Gate report"
  echo
  echo "- run: $started"
  echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo none)"
  echo "- dirty: $([ -n "$(git status --porcelain)" ] && echo yes || echo no)"
  echo "- simulator: $SIM_NAME"
  echo
  echo "| Gate | Result |"
  echo "|---|---|"
} >"$REPORT"

any_fail=0
any_skip=0

for gate in "$GATES_DIR"/*.sh; do
  name="$(basename "$gate" .sh)"
  matches_selection "$name" || continue

  printf '\n▸ %s\n' "$name"
  bash "$gate"
  status=$?

  case "$status" in
    0) echo "| $name | PASS |" >>"$REPORT" ;;
    2) echo "| $name | SKIP |" >>"$REPORT"; any_skip=1 ;;
    *) echo "| $name | FAIL |" >>"$REPORT"; any_fail=1 ;;
  esac

  if [ "$any_fail" -eq 1 ]; then
    printf '\n  stopping: %s failed; later gates would produce misleading evidence\n' "$name" >&2
    break
  fi
done

if [ "$any_fail" -eq 1 ]; then verdict="FAIL"
elif [ "$any_skip" -eq 1 ]; then verdict="INCOMPLETE"
else verdict="PASS"; fi

{ echo; echo "**Verdict: $verdict**"; } >>"$REPORT"
printf '\n═══ VERDICT: %s ═══ (Artifacts/gate-report.md)\n' "$verdict"

[ "$verdict" = "FAIL" ] && exit 1
[ "$verdict" = "INCOMPLETE" ] && exit 2
exit 0

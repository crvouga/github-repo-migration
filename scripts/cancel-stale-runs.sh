#!/bin/bash
# cancel-stale-runs.sh: cancel workflow runs that were queued before a cutoff
# and never started (for example runs created while Actions was disabled for
# the previous owner). They never finish by themselves and block concurrency
# groups.
#
#   scripts/cancel-stale-runs.sh <owner> <cutoff-utc> [--dry-run] [repo ...]
#   scripts/cancel-stale-runs.sh crvouga 2026-11-22T01:47:00Z --dry-run
#
# Only runs with status "queued" created before the cutoff are touched.
# Without repo names it checks every repo of <owner> that is not archived.
set -u
[ $# -ge 2 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
OWNER=$1; CUTOFF=$2; shift 2
DRY=0; REPOS=""
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) REPOS="$REPOS $a" ;; esac; done
[ -n "$REPOS" ] || REPOS=$(gh repo list "$OWNER" --limit 1000 --no-archived --json name --jq '.[].name')
total=0
for r in $REPOS; do
  ids=$(gh api "repos/$OWNER/$r/actions/runs?status=queued&per_page=100" \
    --jq ".workflow_runs[] | select(.created_at < \"$CUTOFF\") | .id" 2>/dev/null)
  for id in $ids; do
    total=$((total + 1))
    if [ $DRY = 1 ]; then echo "would cancel $OWNER/$r run $id"; continue; fi
    if gh api -X POST "repos/$OWNER/$r/actions/runs/$id/cancel" >/dev/null 2>&1 \
      || gh api -X POST "repos/$OWNER/$r/actions/runs/$id/force-cancel" >/dev/null 2>&1; then
      echo "cancelled $OWNER/$r run $id"
    else
      echo "FAILED    $OWNER/$r run $id"
    fi
  done
done
echo "done: $total stale queued runs"

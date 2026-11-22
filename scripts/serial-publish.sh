#!/bin/bash
# serial-publish.sh: prove that each repo can still publish and deploy after a
# move, one repo at a time.
#
#   scripts/serial-publish.sh <owner> <infra-repo> <item> [item ...]
#   scripts/serial-publish.sh crvouga personal snake todo-v1 fleet#17
#
# An item is either
#   <repo>        push an empty commit to the default branch (a caller workflow
#                 that only triggers on push has no other way to run), or
#   <repo>#<pr>   squash-merge that pull request, but only if GitHub reports it
#                 clean (all required checks green); otherwise it is skipped.
#
# For each item, in order:
#   1. wait until <owner>/<infra-repo> has no Deploy run queued or in progress
#   2. trigger (empty commit or merge)
#   3. wait for every run on that commit to finish
#   4. wait for the infra repo's Deploy to go idle again, and record the
#      conclusion of the deploy runs that started after the trigger
#   5. pause $SPACING seconds (default 420)
#
# Why one at a time: the infra repo keeps one pending run per concurrency group
# (a second waiting deploy is cancelled, leaving that service on its old
# image), and the hosting provider rate-limits full plans (4 in 40 minutes hit
# HTTP 429 on 2026-11-22). Stops at the first failure so nothing piles up.
#
# Results are appended to $RESULTS (default: ./serial-publish.tsv).
set -u
[ $# -ge 3 ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
OWNER=$1; INFRA=$2; shift 2
SPACING=${SPACING:-420}
RESULTS=${RESULTS:-serial-publish.tsv}
MSG=${MSG:-"ci: republish image after the move back to github.com/$OWNER"}
DEPLOY_WORKFLOW=${DEPLOY_WORKFLOW:-Deploy}

q() { gh api "$@" 2>/dev/null </dev/null; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
note() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Number of infra Deploy runs that are not finished.
deploys_busy() {
  q "repos/$OWNER/$INFRA/actions/runs?per_page=30" \
    --jq "[.workflow_runs[] | select(.name == \"$DEPLOY_WORKFLOW\" and .status != \"completed\")] | length"
}
wait_deploy_idle() {
  local i=0 n
  while [ $i -lt 120 ]; do
    n=$(deploys_busy); [ "${n:-1}" = 0 ] && return 0
    sleep 30; i=$((i + 1))
  done
  return 1
}
# Wait for all runs on a commit; print "ok" or the names of the ones that failed.
wait_runs() {
  local repo=$1 sha=$2 i=0 pending bad seen=0
  while [ $i -lt 120 ]; do
    pending=$(q "repos/$OWNER/$repo/actions/runs?head_sha=$sha&per_page=50" --jq '[.workflow_runs[] | select(.path | startswith("dynamic/") | not)] | [length, (map(select(.status != "completed")) | length)] | @tsv')
    seen=${pending%%	*}; pending=${pending##*	}
    if [ "${seen:-0}" -gt 0 ] && [ "${pending:-1}" = 0 ]; then break; fi
    # No run at all two minutes after the push: nothing is triggered by a push.
    [ "${seen:-0}" = 0 ] && [ $i -ge 4 ] && { echo "no run triggered"; return 0; }
    sleep 30; i=$((i + 1))
  done
  bad=$(q "repos/$OWNER/$repo/actions/runs?head_sha=$sha&per_page=50" \
    --jq '[.workflow_runs[] | select((.path | startswith("dynamic/") | not) and (.conclusion | IN("success","skipped","neutral") | not)) | .name + "=" + (.conclusion // .status)] | join(", ")')
  [ -z "$bad" ] && echo ok || echo "$bad"
}

for item in "$@"; do
  repo=${item%%#*}; pr=""; case "$item" in *"#"*) pr=${item##*#} ;; esac
  note "$item: waiting for $INFRA deploys to be idle"
  wait_deploy_idle || { note "$item: $INFRA deploy never went idle; stopping"; exit 1; }
  started=$(now)
  def=$(q "repos/$OWNER/$repo" --jq .default_branch)
  if [ -n "$pr" ]; then
    state=$(q "repos/$OWNER/$repo/pulls/$pr" --jq '.state + " " + (.mergeable_state // "unknown")')
    if [ "$state" != "open clean" ]; then
      note "$item: pull request is '$state', not merging"; printf '%s\t%s\tskipped\t%s\n' "$(now)" "$item" "$state" >> "$RESULTS"; continue
    fi
    sha=$(gh api -X PUT "repos/$OWNER/$repo/pulls/$pr/merge" -f merge_method=squash --jq .sha 2>/dev/null) \
      || { note "$item: merge refused"; printf '%s\t%s\tmerge refused\n' "$(now)" "$item" >> "$RESULTS"; continue; }
  else
    head=$(q "repos/$OWNER/$repo/git/ref/heads/$def" --jq .object.sha)
    tree=$(q "repos/$OWNER/$repo/git/commits/$head" --jq .tree.sha)
    sha=$(gh api -X POST "repos/$OWNER/$repo/git/commits" -f message="$MSG" -f tree="$tree" -f "parents[]=$head" \
      -f "author[name]=$(gh api user --jq '.name // .login')" \
      -f "author[email]=$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')" --jq .sha 2>/dev/null) \
      && gh api -X PATCH "repos/$OWNER/$repo/git/refs/heads/$def" -f sha="$sha" -F force=false >/dev/null 2>&1 \
      || { note "$item: could not push to $def (protected? use <repo>#<pr>)"; printf '%s\t%s\tpush refused\n' "$(now)" "$item" >> "$RESULTS"; continue; }
  fi
  note "$item: triggered at ${sha:0:9}, waiting for its runs"
  runs=$(wait_runs "$repo" "$sha")
  sleep 20; wait_deploy_idle
  deploys=$(q "repos/$OWNER/$INFRA/actions/runs?per_page=30&created=%3E$started" \
    --jq "[.workflow_runs[] | select(.name == \"$DEPLOY_WORKFLOW\") | (.conclusion // .status)] | join(\",\")")
  printf '%s\t%s\t%s\truns: %s\tdeploys: %s\n' "$(now)" "$item" "${sha:0:9}" "$runs" "${deploys:-none}" >> "$RESULTS"
  note "$item: runs: $runs; deploys: ${deploys:-none}"
  case "$runs" in ok|"no run triggered") ;; *) note "stopping: $item failed"; exit 1 ;; esac
  case ",$deploys," in *,failure,*) note "stopping: a deploy after $item failed"; exit 1 ;; esac
  sleep "$SPACING"
done
note "all items done"

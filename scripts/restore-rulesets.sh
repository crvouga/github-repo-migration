#!/bin/bash
# restore-rulesets.sh: re-create repository rulesets that were deleted, from the
# definitions GitHub keeps in an organization's audit log.
#
#   scripts/restore-rulesets.sh <audit-org> <target-owner> [--dry-run] [repo ...]
#   scripts/restore-rulesets.sh crvouga-organization crvouga --dry-run
#
# Every `repository_ruleset.destroy` event in <audit-org>'s audit log carries
# the ruleset's name, target, conditions, rules and bypass actors. For each
# event this re-creates the ruleset on <target-owner>/<same repo name>, unless a
# ruleset with that name already exists there (so it is safe to re-run).
# The audit log only exists for organizations and keeps about 180 days.
#
# Needs the admin:org scope (audit log) and admin rights on the repos.
set -u -o pipefail
[ $# -ge 2 ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ORG=$1; TO=$2; shift 2
DRY=0; ONLY=""
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) ONLY="$ONLY $a" ;; esac; done

events=$(gh api --paginate "orgs/$ORG/audit-log?phrase=action:repository_ruleset.destroy&per_page=100" | jq -s 'add') || exit 1
n=$(printf '%s' "$events" | jq length)
i=0; made=0; kept=0; failed=0
while [ $i -lt "$n" ]; do
  ev=$(printf '%s' "$events" | jq ".[$i]"); i=$((i + 1))
  repo=$(printf '%s' "$ev" | jq -r '.repo | split("/")[1]'); name=$(printf '%s' "$ev" | jq -r .ruleset_name)
  if [ -n "$ONLY" ]; then case " $ONLY " in *" $repo "*) ;; *) continue ;; esac; fi
  if gh api "repos/$TO/$repo/rulesets" --jq '.[].name' 2>/dev/null | grep -qxF "$name"; then
    echo "exists   $TO/$repo: $name"; kept=$((kept + 1)); continue
  fi
  # Audit-log shape -> REST shape. Parameters the REST API does not take are dropped.
  body=$(printf '%s' "$ev" | jq '{
    name: .ruleset_name,
    target: (if (.ruleset_conditions[0].target // "ref_name") == "ref_name" then "branch" else "branch" end),
    enforcement: (if .ruleset_enforcement == "enabled" then "active" else .ruleset_enforcement end),
    conditions: { ref_name: { include: .ruleset_conditions[0].parameters.include, exclude: .ruleset_conditions[0].parameters.exclude } },
    bypass_actors: [ (.ruleset_bypass_actors // [])[] | { actor_id, actor_type, bypass_mode } ],
    rules: [ .ruleset_rules[] | { type } + (
      if .type == "pull_request" then { parameters: (.parameters | {
        allowed_merge_methods, dismiss_stale_reviews_on_push, require_code_owner_review,
        require_last_push_approval, required_approving_review_count, required_review_thread_resolution }) }
      elif (.parameters | length) > 0 then { parameters }
      else {} end) ] }')
  if [ $DRY = 1 ]; then echo "would create $TO/$repo: $name ($(printf '%s' "$body" | jq -r '[.rules[].type] | join(", ")'))"; continue; fi
  if printf '%s' "$body" | gh api -X POST "repos/$TO/$repo/rulesets" --input - >/dev/null 2>"${TMPDIR:-/tmp}/ruleset.err"; then
    echo "created  $TO/$repo: $name"; made=$((made + 1))
  else
    echo "FAILED   $TO/$repo: $name: $(tr '\n' ' ' < "${TMPDIR:-/tmp}/ruleset.err" | cut -c1-300)"; failed=$((failed + 1))
  fi
done
echo "done: $made created, $kept already there, $failed failed"
[ $failed = 0 ]

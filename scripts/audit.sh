#!/bin/bash
# audit.sh: is the migration finished? Checks every category a move can leave
# behind and prints one PASS / FAIL / INFO line per check, with details for
# failures. Exit status 0 only when nothing failed. A migration is done when
# this passes; run it before saying so.
#
#   FROM=crvouga-organization TO=crvouga scripts/audit.sh            # everything
#   FROM=... TO=... scripts/audit.sh owner refs variables            # some checks
#   SINCE=2026-11-22T01:47:00Z FROM=... TO=... scripts/audit.sh ci   # CI since the move
#
# Checks:
#   owner      every recorded repo is owned by $TO; nothing but KEEP is left under $FROM
#   refs       no file in any repo of $TO still selects $FROM (runs sweep-refs.sh scan)
#   variables  no Actions variable (repo or environment) names $FROM or its numeric id
#   settings   default workflow token permission, branch rules, code scanning and
#              security features match the baseline taken before the repos left $TO
#   pages      every recorded Pages site answers at its new URL
#   runs       no run is still queued from before the move
#   ci         the latest default-branch run of every workflow since $SINCE is green
#   prs        open pull requests created by the migration (branch chore/repo-owner-*)
#   packages   container packages still owned by $FROM
#   clones     local clones on this machine that still point at $FROM
#
# Read-only, except that `refs` refreshes the shallow clones under state/.
set -u -o pipefail
: "${FROM:?}"; : "${TO:?}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE=${STATE:-$HERE/state/$FROM--$TO}
BASELINE=${BASELINE:-$HERE/state/$TO--$FROM/repo}
KEEP=${KEEP:-"crvouga portfolio dotfiles github-repo-migration crvouga.github.io crvouga-organization.github.io"}
# When the move started: the first transfer line in the log (local time), in UTC.
since_from_log() {
  local t; t=$(grep -m1 'transfer. transferring' "$STATE/migrate.log" 2>/dev/null | cut -c1-19)
  [ -n "$t" ] || return 0
  # The log is in local time: go through the epoch (BSD date, then GNU date).
  local e; e=$(date -j -f '%Y-%m-%d %H:%M:%S' "$t" '+%s' 2>/dev/null || date -d "$t" '+%s' 2>/dev/null)
  date -u -r "$e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}
SINCE=${SINCE:-$(since_from_log)}
OUT=$STATE/audit; mkdir -p "$OUT"
fails=0

lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
q() { gh api "$@" 2>/dev/null </dev/null; }
names() { for f in "$STATE"/repo/*.json; do jq -r .name "$f"; done; }
rec() { jq -r "$2" "$STATE/repo/$1.json"; }
base() { [ -s "$BASELINE/$1.json" ] && jq -r "$2" "$BASELINE/$1.json"; }
# result <check> <detail-file> <what a clean result means>
result() {
  local n; n=$(grep -c . "$2" 2>/dev/null); n=${n:-0}
  if [ "$n" = 0 ]; then echo "PASS  $1: $3"
  else fails=$((fails + 1)); echo "FAIL  $1: $n finding(s), see $2"; sed 's/^/        /' "$2" | head -${SHOW:-15}; [ "$n" -gt "${SHOW:-15}" ] && echo "        ... $((n - ${SHOW:-15})) more"; fi
}

c_owner() {
  local f=$OUT/owner.txt n full; : > "$f"
  for n in $(names); do
    full=$(q "repositories/$(rec "$n" .id)" --jq .full_name)
    [ "$(lc "$full")" = "$(lc "$TO/$n")" ] || echo "$n is at '${full:-missing}', expected $TO/$n" >> "$f"
  done
  for n in $(gh repo list "$FROM" --limit 1000 --json name --jq '.[].name' 2>/dev/null); do
    case " $(lc "$KEEP") " in *" $(lc "$n") "*) ;; *) echo "$FROM/$n still exists under the old owner" >> "$f" ;; esac
  done
  result owner "$f" "all $(names | wc -l | tr -d ' ') repos are owned by $TO; nothing unexpected under $FROM"
}

c_refs() {
  local f=$OUT/refs.txt n; : > "$f"
  FROM=$FROM TO=$TO STATE=$STATE "$HERE/scripts/sweep-refs.sh" scan >/dev/null 2>&1
  for n in $(names); do
    [ -s "$STATE/refs/$n.txt" ] && echo "$n: $(grep -vc '^REVIEW ' "$STATE/refs/$n.txt") line(s) to change, $(grep -c '^REVIEW ' "$STATE/refs/$n.txt") to review (state/.../refs/$n.txt)" >> "$f"
  done
  # Repos of $TO that never moved can name the old owner too (profile repos,
  # sites). GitHub code search covers those without cloning.
  for n in $(gh repo list "$TO" --limit 1000 --json name --jq '.[].name'); do
    [ -s "$STATE/repo/$n.json" ] && continue
    [ "$(q "search/code?q=$FROM+repo:$TO/$n" --jq .total_count)" = 0 ] || echo "$n (never moved): code search finds $FROM" >> "$f"
    sleep 7   # code search allows 10 requests a minute
  done
  result refs "$f" "no file in any repo names $FROM as the owner"
}

c_variables() {
  local f=$OUT/variables.txt n e id pat; : > "$f"
  id=$(q "users/$FROM" --jq .id); pat="$FROM|${id:-NO_ID}"
  for n in $(names); do
    q "repos/$TO/$n/actions/variables?per_page=100" --jq ".variables[] | select(.value | test(\"$pat\"; \"i\")) | \"$n: variable \" + .name" >> "$f"
    for e in $(rec "$n" '.environments[]? | @uri'); do
      q "repos/$TO/$n/environments/$e/variables?per_page=100" --jq ".variables[] | select(.value | test(\"$pat\"; \"i\")) | \"$n: environment $e variable \" + .name" >> "$f"
    done
  done
  result variables "$f" "no Actions variable names $FROM or its id (secrets cannot be read: check them by hand)"
}

c_settings() {
  local f=$OUT/settings.txt n v w; : > "$f"
  for n in $(names); do
    if [ -s "$BASELINE/$n.json" ]; then
      v=$(q "repos/$TO/$n/actions/permissions/workflow" --jq .default_workflow_permissions); w=$(base "$n" '.workflow_perms.default_workflow_permissions // empty')
      [ -z "$w" ] || [ "$v" = "$w" ] || echo "$n: workflow token is $v, was $w" >> "$f"
      if [ "$(base "$n" '.default_branch_protected')" = true ] && [ "$(rec "$n" .size)" != 0 ]; then
        v=$(q "repos/$TO/$n/branches/$(rec "$n" .default_branch)" --jq .protected)
        [ "$v" = true ] || echo "$n: default branch was protected before the repos left $TO and is not now" >> "$f"
      fi
      if [ "$(base "$n" '.code_scanning.state // empty')" = configured ]; then
        [ "$(q "repos/$TO/$n/code-scanning/default-setup" --jq .state)" = configured ] || echo "$n: code scanning default setup was configured and is not now" >> "$f"
      fi
      for w in $(base "$n" '.security_and_analysis // {} | to_entries[] | select(.value.status == "enabled") | .key'); do
        [ "$(q "repos/$TO/$n" --jq ".security_and_analysis.$w.status")" = enabled ] || echo "$n: $w was enabled and is not now" >> "$f"
      done
    fi
    [ "$(rec "$n" .size)" = 0 ] && continue
    v=$(q "repos/$TO/$n/rulesets" --jq length); w=$(rec "$n" '.rulesets | length')
    [ "${v:-0}" -ge "$w" ] || echo "$n: has $v ruleset(s), had $w before the transfer" >> "$f"
  done
  [ -d "$BASELINE" ] || echo "no baseline snapshot at $BASELINE: settings cannot be compared" >> "$f"
  result settings "$f" "token permissions, branch rules, code scanning and security features match the baseline"
}

c_pages() {
  local f=$OUT/pages.txt n u; : > "$f"
  for n in $(names); do
    [ "$(rec "$n" .pages)" = null ] && continue
    u=$(q "repos/$TO/$n/pages" --jq .html_url)
    [ -n "$u" ] && [ "$(curl -sL -o /dev/null -m 20 -w '%{http_code}' "$u")" = 200 ] || echo "$n: Pages not answering at ${u:-<not enabled>}" >> "$f"
  done
  result pages "$f" "every Pages site answers at its new URL"
}

c_runs() {
  local f=$OUT/runs.txt n; : > "$f"
  [ -n "$SINCE" ] || { echo "INFO  runs: SINCE unknown, skipped"; return; }
  for n in $(names); do
    q "repos/$TO/$n/actions/runs?status=queued&per_page=100" \
      --jq ".workflow_runs[] | select(.created_at < \"$SINCE\") | \"$n: run \" + (.id|tostring) + \" (\" + .name + \") queued since \" + .created_at" >> "$f"
  done
  result runs "$f" "no run is still queued from before $SINCE"
}

c_ci() {
  local f=$OUT/ci.txt n; : > "$f"
  [ -n "$SINCE" ] || { echo "INFO  ci: SINCE unknown, skipped"; return; }
  for n in $(names); do
    [ "$(rec "$n" .archived)" = true ] && continue
    q "repos/$TO/$n/actions/runs?branch=$(rec "$n" '.default_branch | @uri')&per_page=60&created=%3E$SINCE" \
      --jq "[.workflow_runs[] | select(.path | startswith(\"dynamic/\") | not)] | group_by(.path) | map(.[0])[]
            | select(.status != \"completed\" or (.conclusion | IN(\"success\",\"skipped\",\"neutral\") | not))
            | \"$n: \" + .name + \" is \" + (.conclusion // .status) + \" \" + .html_url" >> "$f"
  done
  result ci "$f" "every workflow's latest default-branch run since $SINCE is green (repos with no run since then are not covered)"
}

c_prs() {
  local f=$OUT/prs.txt; : > "$f"
  gh search prs --owner "$TO" --state open --limit 200 --json repository,number,title,url \
    --jq '.[] | select(.title | test("crvouga|owner|transfer|migrat"; "i")) | .repository.name + " #" + (.number|tostring) + " " + .title + " " + .url' >> "$f" 2>/dev/null
  result prs "$f" "no migration pull request is still open"
}

c_packages() {
  local n; n=$(q --paginate "orgs/$FROM/packages?package_type=container&per_page=100" --jq length | paste -sd+ - | bc 2>/dev/null)
  [ -n "$n" ] || n=$(q --paginate "users/$FROM/packages?package_type=container&per_page=100" --jq length | paste -sd+ - | bc 2>/dev/null)
  echo "INFO  packages: ${n:-?} container package(s) still owned by $FROM (they do not move with repos; delete them once nothing pulls from them)"
}

c_clones() {
  local f=$OUT/clones.txt; : > "$f"
  DEPTH=${DEPTH:-7} "$HERE/scripts/repoint-remotes.sh" "$FROM" "$TO" --dry-run 2>/dev/null | grep -E '^(would change|SKIPPED)' >> "$f"
  result clones "$f" "no clone on this machine points at $FROM (run this check on every machine)"
}

checks=${*:-owner refs variables settings pages runs ci prs packages clones}
echo "audit $FROM -> $TO  (since ${SINCE:-unknown}; details in ${OUT#"$HERE/"})"
for c in $checks; do
  case "$c" in owner|refs|variables|settings|pages|runs|ci|prs|packages|clones) "c_$c" ;; *) echo "unknown check: $c"; exit 2 ;; esac
done
[ $fails = 0 ] && echo "RESULT: complete, nothing failed" || echo "RESULT: NOT complete, $fails check(s) failed"
[ $fails = 0 ]

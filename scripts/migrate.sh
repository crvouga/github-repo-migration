#!/bin/bash
# migrate.sh: transfer every repository owned by $FROM to $TO on github.com and
# put its settings back the way they were. Works in both directions (personal
# account -> organization, organization -> personal account).
#
#   FROM=crvouga-organization TO=crvouga scripts/migrate.sh all
#   FROM=crvouga TO=crvouga-organization scripts/migrate.sh preflight record
#   ONLY="repo-a repo-b" FROM=... TO=... scripts/migrate.sh transfer settings verify
#
# Steps: preflight record transfer settings pages verify report   (all = every step, in order)
#
# Idempotent: each step checks whether its work is already done, so the script
# can be re-run after a partial failure. Runs on macOS stock bash 3.2.
#
# State lives in state/<FROM>--<TO>/ (gitignored: it names private repos).
# The snapshot taken when repos last LEFT $TO (state/<TO>--<FROM>/repo) is the
# baseline used to restore per-repo settings; override with BASELINE=<dir>.
set -u -o pipefail

: "${FROM:?set FROM to the current owner (user or org login)}"
: "${TO:?set TO to the new owner (user or org login)}"
# Repos that never move, whichever side owns them.
KEEP=${KEEP:-"crvouga portfolio dotfiles github-repo-migration crvouga.github.io crvouga-organization.github.io"}
ONLY=${ONLY:-}          # optional space-separated subset of repo names
PAUSE=${PAUSE:-2}       # seconds between transfer requests (secondary rate limits)

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE=${STATE:-$HERE/state/$FROM--$TO}
BASELINE=${BASELINE:-$HERE/state/$TO--$FROM/repo}
LOG=$STATE/migrate.log
PHASE=init
mkdir -p "$STATE/repo" "$STATE/done" "$STATE/fail" "$STATE/verify"

# ---------------------------------------------------------------- helpers ---

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PHASE" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 1; }
fail() { printf '%s\n' "$3" > "$STATE/fail/$1.$2"; log "FAIL $1 $2: $3"; }
ok() { rm -f "$STATE/fail/$1.$2"; touch "$STATE/done/$1.$2"; }
is_done() { [ -f "$STATE/done/$1.$2" ]; }

# gh api with retries on 5xx / rate limits. Errors go to the log.
LAST_API_ERR=
api() {
  local i=0 out err
  err=$(mktemp "$STATE/.apierr.XXXXXX")
  while :; do
    if out=$(gh api "$@" 2>"$err" </dev/null); then rm -f "$err"; printf '%s' "$out"; return 0; fi
    i=$((i + 1))
    if grep -qE 'HTTP (5[0-9][0-9]|429)|rate limit|abuse|timed out' "$err" && [ $i -lt 5 ]; then
      sleep $((i * 15)); continue
    fi
    printf 'api %s: %s\n' "$*" "$(tr '\n' ' ' < "$err")" >> "$LOG"
    LAST_API_ERR=$(grep -v '^{' "$err" | tail -1)
    rm -f "$err"; return 1
  done
}
# Same, but reads the request body from stdin.
api_in() { local o; o=$(gh api "$@" --input - 2>>"$LOG") || return 1; printf '%s' "$o"; }
# For lookups where a 404 is an expected answer.
apiq() { local o; o=$(gh api "$@" 2>/dev/null </dev/null) || return 1; printf '%s' "$o"; }

lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
is_keep() { local k n; n=$(lc "$1"); for k in $KEEP; do [ "$(lc "$k")" = "$n" ] && return 0; done; return 1; }
repos() {
  local n
  if [ -n "$ONLY" ]; then for n in $ONLY; do echo "$n"; done; return; fi
  while read -r n; do is_keep "$n" || echo "$n"; done < "$STATE/repos.list"
}
rec() { jq -r "$2" "$STATE/repo/$1.json"; }
base() { [ -s "$BASELINE/$1.json" ] && jq -r "$2" "$BASELINE/$1.json"; }
# Where a repo is right now, looked up by its permanent id. Looking up
# "$TO/<name>" is not enough: an old redirect answers for it before the move.
where() { apiq "repositories/$(rec "$1" .id)" --jq .full_name; }
moved() { [ "$(lc "$(where "$1")")" = "$(lc "$TO/$1")" ]; }

# -------------------------------------------------------------- preflight ---

preflight() {
  PHASE=preflight
  local me scopes s ft tt role
  command -v gh >/dev/null && command -v jq >/dev/null || die "needs gh and jq"
  me=$(api user --jq .login) || die "gh is not authenticated"
  scopes=$(gh auth status -h github.com 2>&1 | sed -n "s/.*Token scopes: //p" | tr -d "'")
  for s in repo workflow; do
    case ", $scopes," in *", $s,"*) ;; *) die "token lacks the '$s' scope: gh auth refresh -h github.com -s $s" ;; esac
  done
  ft=$(api "users/$FROM" --jq .type) || die "cannot read $FROM"
  tt=$(api "users/$TO" --jq .type) || die "cannot read $TO"
  for s in "$FROM:$ft" "$TO:$tt"; do
    case "$s" in
      *:User) [ "$(lc "${s%%:*}")" = "$(lc "$me")" ] || die "${s%%:*} is a user account, but gh is signed in as $me" ;;
      *:Organization)
        role=$(api "user/memberships/orgs/${s%%:*}" --jq '.role + " " + .state') || die "cannot read membership in ${s%%:*}"
        [ "$role" = "admin active" ] || die "$me is not an active owner of ${s%%:*} (got: $role)"
        case ", $scopes," in *", admin:org,"*) ;; *) log "WARN: token lacks admin:org; org-level settings are not readable" ;; esac ;;
    esac
  done
  log "preflight ok: $me can move repos from $FROM ($ft) to $TO ($tt); core API calls left: $(api rate_limit --jq .resources.core.remaining)"
}

# ----------------------------------------------------------------- record ---

# Snapshot of everything a transfer could change, taken before the move.
record_one() {
  local n=$1 r f b def priv pages ap sel wp fa fp acc prot rules hooks envs wfs
  f=$STATE/repo/$n.json
  [ -s "$f" ] && return 0
  r=$FROM/$n
  b=$(api "repos/$r") || { fail record "$n" "cannot read repo"; return 1; }
  if [ "$(lc "$(printf '%s' "$b" | jq -r .owner.login)")" != "$(lc "$FROM")" ]; then
    log "$n is not owned by $FROM; not recording"; return 0
  fi
  def=$(printf '%s' "$b" | jq -r .default_branch)
  priv=$(printf '%s' "$b" | jq -r .private)
  pages=null
  [ "$(printf '%s' "$b" | jq -r .has_pages)" = true ] && { pages=$(apiq "repos/$r/pages") || pages=null; }
  ap=$(apiq "repos/$r/actions/permissions") || ap=null
  sel=null
  [ "$(printf '%s' "$ap" | jq -r '.allowed_actions // ""')" = selected ] && { sel=$(apiq "repos/$r/actions/permissions/selected-actions") || sel=null; }
  wp=$(apiq "repos/$r/actions/permissions/workflow") || wp=null
  fa=$(apiq "repos/$r/actions/permissions/fork-pr-contributor-approval") || fa=null
  fp=null; acc=null
  if [ "$priv" = true ]; then
    fp=$(apiq "repos/$r/actions/permissions/fork-pr-workflows-private-repos") || fp=null
    acc=$(apiq "repos/$r/actions/permissions/access") || acc=null
  fi
  prot=$(apiq "repos/$r/branches/$def/protection") || prot=null
  rules=$(apiq "repos/$r/rulesets" --jq '[.[] | {id, name, enforcement, source_type}]') || rules='[]'
  hooks=$(apiq "repos/$r/hooks" --jq 'length') || hooks=0
  envs=$(apiq "repos/$r/environments" --jq '[.environments[].name]') || envs='[]'
  wfs=$(apiq "repos/$r/actions/workflows?per_page=100" --jq '[.workflows[] | {id, path, name, state}]') || wfs='[]'
  printf '%s' "$b" | jq --argjson pages "$pages" --argjson ap "$ap" --argjson sel "$sel" \
    --argjson wp "$wp" --argjson fa "$fa" --argjson fp "$fp" --argjson acc "$acc" \
    --argjson prot "$prot" --argjson rules "$rules" --argjson hooks "$hooks" --argjson envs "$envs" \
    --argjson wfs "$wfs" '{
      id, name, full_name, visibility, private, fork, archived, default_branch, topics, homepage,
      has_pages, size, parent: (.parent.full_name // null),
      pages: $pages, actions: $ap, selected_actions: $sel, workflow_perms: $wp,
      fork_pr_approval: $fa, fork_pr_private: $fp, actions_access: $acc,
      default_branch_protected: ($prot != null), protection: $prot, rulesets: $rules,
      hooks: $hooks, environments: $envs, workflows: $wfs }' > "$f.tmp" && mv "$f.tmp" "$f" \
    || { rm -f "$f.tmp"; fail record "$n" "could not write state"; return 1; }
  ok record "$n"
  log "recorded $n ($(jq -r '.visibility + ", " + .default_branch' "$f"))"
}

record() {
  PHASE=record
  local n q
  # Union with what we saw before so re-runs keep repos that already moved.
  if [ "$(api "users/$FROM" --jq .type)" = Organization ]; then q="orgs/$FROM/repos?type=all&per_page=100"
  else q="user/repos?affiliation=owner&per_page=100"; fi
  api --paginate "$q" --jq ".[] | select((.owner.login | ascii_downcase) == \"$(lc "$FROM")\") | .name" \
    > "$STATE/.cur" || die "cannot list repos of $FROM"
  { cat "$STATE/repos.list" 2>/dev/null; cat "$STATE/.cur"; } | sort -fu > "$STATE/.new" && mv "$STATE/.new" "$STATE/repos.list"
  rm -f "$STATE/.cur"
  for n in $(repos); do record_one "$n"; done
  log "recorded $(ls "$STATE/repo" | wc -l | tr -d ' ') repos"
}

# --------------------------------------------------------------- transfer ---

request_transfer() {
  local n=$1 ex
  [ -s "$STATE/repo/$n.json" ] || { fail transfer "$n" "no recorded state (run record first)"; return 1; }
  if moved "$n"; then ok transfer "$n"; return 0; fi
  [ -f "$STATE/done/requested.$n" ] && return 0
  # A different repo already using the name on the other side must be sorted
  # out by a human: never rename or overwrite automatically.
  ex=$(apiq "repos/$TO/$n" --jq .id)
  if [ -n "$ex" ] && [ "$ex" != "$(rec "$n" .id)" ]; then
    fail transfer "$n" "$TO/$n already exists and is a different repo"; return 1
  fi
  log "transferring $FROM/$n -> $TO/$n"
  if api -X POST "repos/$FROM/$n/transfer" -f new_owner="$TO" >/dev/null; then
    touch "$STATE/done/requested.$n"
  else
    fail transfer "$n" "transfer request failed: ${LAST_API_ERR:-unknown}"; return 1
  fi
  sleep "$PAUSE"
}

await_transfer() {
  local n=$1 i=0
  is_done transfer "$n" && return 0
  [ -f "$STATE/done/requested.$n" ] || return 1
  while [ $i -lt 60 ]; do
    if moved "$n"; then ok transfer "$n"; log "now at $TO/$n"; return 0; fi
    sleep 5; i=$((i + 1))
  done
  rm -f "$STATE/done/requested.$n"
  fail transfer "$n" "timed out waiting for $TO/$n (a transfer to another user needs them to accept by email)"
}

transfer() {
  PHASE=transfer
  local n
  for n in $(repos); do is_done transfer "$n" || request_transfer "$n"; done
  for n in $(repos); do [ -f "$STATE/fail/transfer.$n" ] || await_transfer "$n"; done
  log "transferred: $(ls "$STATE/done" | grep -c '^transfer\.') / $(repos | wc -l | tr -d ' ')"
}

# --------------------------------------------------------------- settings ---

# Put back the per-repo Actions settings from the baseline snapshot (the state
# the repo had the last time it lived under $TO). Without a baseline the
# settings GitHub carried across the transfer are left alone.
settings_one() {
  local n=$1 r=$TO/$1 v
  is_done settings "$n" && return 0
  is_done transfer "$n" || return 0
  [ -s "$BASELINE/$n.json" ] || { log "$n: no baseline snapshot; settings left as transferred"; ok settings "$n"; return 0; }
  v=$(base "$n" '.actions.allowed_actions // empty')
  [ -n "$v" ] && { api -X PUT "repos/$r/actions/permissions" -F enabled="$(base "$n" .actions.enabled)" -f allowed_actions="$v" >/dev/null \
    || log "WARN $n: actions permissions: ${LAST_API_ERR:-}"; }
  if [ "$v" = selected ] && [ "$(base "$n" .selected_actions)" != null ]; then
    base "$n" .selected_actions | api_in -X PUT "repos/$r/actions/permissions/selected-actions" >/dev/null
  fi
  v=$(base "$n" '.workflow_perms.default_workflow_permissions // empty')
  [ -n "$v" ] && { api -X PUT "repos/$r/actions/permissions/workflow" -f default_workflow_permissions="$v" \
    -F can_approve_pull_request_reviews="$(base "$n" .workflow_perms.can_approve_pull_request_reviews)" >/dev/null \
    || log "WARN $n: workflow permissions ($v): ${LAST_API_ERR:-}"; }
  v=$(base "$n" '.fork_pr_approval.approval_policy // empty')
  [ -n "$v" ] && { api -X PUT "repos/$r/actions/permissions/fork-pr-contributor-approval" -f approval_policy="$v" >/dev/null \
    || log "WARN $n: fork PR approval: ${LAST_API_ERR:-}"; }
  [ "$(base "$n" .fork_pr_private)" != null ] && { base "$n" .fork_pr_private \
    | api_in -X PUT "repos/$r/actions/permissions/fork-pr-workflows-private-repos" >/dev/null || log "WARN $n: private fork PR settings"; }
  [ "$(base "$n" .actions_access)" != null ] && { base "$n" .actions_access \
    | api_in -X PUT "repos/$r/actions/permissions/access" >/dev/null || log "WARN $n: actions access level"; }
  ok settings "$n"
}

settings() {
  PHASE=settings
  local n
  [ -d "$BASELINE" ] || log "WARN: no baseline at $BASELINE"
  for n in $(repos); do settings_one "$n"; done
  log "settings restored: $(ls "$STATE/done" | grep -c '^settings\.')"
}

# ------------------------------------------------------------------ pages ---

# GitHub Pages moves with the repo but its URL changes with the owner
# (<owner>.github.io/<repo>). Re-enable it if the transfer dropped it.
pages() {
  PHASE=pages
  local n r cur bt br pth cname
  for n in $(repos); do
    is_done transfer "$n" || continue
    [ "$(rec "$n" .pages)" = null ] && continue
    r=$TO/$n
    bt=$(rec "$n" .pages.build_type); br=$(rec "$n" .pages.source.branch); pth=$(rec "$n" .pages.source.path)
    cname=$(rec "$n" '.pages.cname // empty')
    cur=$(apiq "repos/$r/pages")
    if [ -z "$cur" ]; then
      log "$n: re-enabling Pages ($bt, $br$pth)"
      api -X POST "repos/$r/pages" -f build_type="$bt" -f "source[branch]=$br" -f "source[path]=$pth" >/dev/null \
        || { fail pages "$n" "cannot enable Pages: ${LAST_API_ERR:-}"; continue; }
    fi
    if [ -n "$cname" ] && [ "$(apiq "repos/$r/pages" --jq '.cname // ""')" != "$cname" ]; then
      api -X PUT "repos/$r/pages" -f cname="$cname" >/dev/null || fail pages "$n" "cannot restore custom domain $cname"
    fi
    if [ "$bt" = legacy ] && ! is_done pagesbuild "$n"; then
      api -X POST "repos/$r/pages/builds" >/dev/null && ok pagesbuild "$n"
    fi
    rm -f "$STATE/fail/pages.$n"
    log "$n: Pages at $(apiq "repos/$r/pages" --jq .html_url)"
  done
}

# ----------------------------------------------------------------- verify ---

verify_one() {
  local n=$1 r=$TO/$1 f=$STATE/verify/$1.txt cur code v
  cur=$(apiq "repositories/$(rec "$n" .id)") || { echo "MISSING $r" > "$f"; return 1; }
  {
    [ "$(lc "$(printf '%s' "$cur" | jq -r .full_name)")" = "$(lc "$r")" ] && echo "owner ok" \
      || echo "owner MISMATCH ($(printf '%s' "$cur" | jq -r .full_name))"
    for v in visibility default_branch archived; do
      [ "$(printf '%s' "$cur" | jq -r ".$v")" = "$(rec "$n" ".$v")" ] && echo "$v ok ($(rec "$n" ".$v"))" \
        || echo "$v MISMATCH ($(rec "$n" ".$v") -> $(printf '%s' "$cur" | jq -r ".$v"))"
    done
    [ "$(printf '%s' "$cur" | jq -c '.topics | sort')" = "$(rec "$n" '.topics | sort | tojson')" ] && echo "topics ok" || echo "topics MISMATCH"
    # Old location must redirect to the new one.
    if [ "$(rec "$n" .private)" = false ]; then
      code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "https://github.com/$FROM/$n")
      case "$(lc "$code")" in 301*"/$(lc "$r")"|302*"/$(lc "$r")") echo "redirect ok (github.com/$FROM/$n -> $r)" ;; *) echo "redirect MISMATCH ($code)" ;; esac
    else
      [ "$(lc "$(apiq "repos/$FROM/$n" --jq .full_name)")" = "$(lc "$r")" ] && echo "redirect ok (API)" || echo "redirect MISMATCH"
    fi
    v=$(apiq "repos/$r/branches/$(rec "$n" .default_branch)" --jq .protected)
    [ "$v" = "$(rec "$n" .default_branch_protected)" ] && echo "branch protection ok ($v)" \
      || echo "branch protection MISMATCH ($(rec "$n" .default_branch_protected) -> $v)"
    v=$(apiq "repos/$r/actions/permissions" --jq .enabled)
    [ "$v" = "$(rec "$n" '.actions.enabled')" ] && echo "actions enabled ok ($v)" || echo "actions enabled MISMATCH ($(rec "$n" .actions.enabled) -> $v)"
    if [ -s "$BASELINE/$n.json" ]; then
      v=$(apiq "repos/$r/actions/permissions/workflow" --jq .default_workflow_permissions)
      [ "$v" = "$(base "$n" .workflow_perms.default_workflow_permissions)" ] && echo "workflow token ok ($v)" \
        || echo "workflow token MISMATCH (baseline $(base "$n" .workflow_perms.default_workflow_permissions), now $v)"
    fi
    if [ "$(rec "$n" .pages)" != null ]; then
      v=$(apiq "repos/$r/pages" --jq .html_url)
      code=$(curl -sL -o /dev/null -w '%{http_code}' "$v")
      [ "$code" = 200 ] && echo "pages ok ($v)" || echo "pages NOT LIVE ($v -> $code)"
    fi
  } > "$f"
}

verify() {
  PHASE=verify
  local n bad
  for n in $(repos); do is_done transfer "$n" && verify_one "$n"; done
  bad=$(grep -lE 'MISMATCH|MISSING|NOT LIVE' "$STATE"/verify/*.txt 2>/dev/null | wc -l | tr -d ' ')
  log "verified $(ls "$STATE/verify" | wc -l | tr -d ' ') repos, $bad with problems"
}

# ----------------------------------------------------------------- report ---

# Full report (names private repos) goes to state/; a public-safe summary is
# printed for pasting into docs/.
report() {
  PHASE=report
  local n out=$STATE/report.md
  {
    echo "# $FROM -> $TO"; echo
    echo "| repo | visibility | transferred | settings | checks |"; echo "|---|---|---|---|---|"
    for n in $(repos); do
      [ -s "$STATE/repo/$n.json" ] || continue
      printf '| %s | %s | %s | %s | %s |\n' "$n" "$(rec "$n" .visibility)" \
        "$(is_done transfer "$n" && echo yes || cat "$STATE/fail/transfer.$n" 2>/dev/null || echo no)" \
        "$(is_done settings "$n" && echo yes || echo no)" \
        "$(grep -E 'MISMATCH|MISSING|NOT LIVE' "$STATE/verify/$n.txt" 2>/dev/null | tr '\n' ';' | sed 's/;$//;s/^$/ok/' | grep . || echo ok)"
    done
  } > "$out"
  log "report: $out"
  echo "repos: $(repos | wc -l | tr -d ' ')  transferred: $(ls "$STATE/done" | grep -c '^transfer\.')  failed: $(ls "$STATE/fail" | wc -l | tr -d ' ')"
  grep -E 'MISMATCH|MISSING|NOT LIVE' "$STATE"/verify/*.txt 2>/dev/null | sed "s|$STATE/verify/||" || true
}

# ------------------------------------------------------------------- main ---

[ $# -eq 0 ] && { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
for step in "$@"; do
  case "$step" in
    all) preflight; record; transfer; settings; pages; verify; report ;;
    preflight|record|transfer|settings|pages|verify|report) "$step" ;;
    *) die "unknown step: $step" ;;
  esac
done

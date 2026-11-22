#!/bin/bash
# sweep-refs.sh: find and fix references to the old owner inside the moved
# repos' files (workflow `uses:` lines, URLs, image paths, badges ...).
#
# GitHub redirects cover git remotes, web URLs and API calls, but NOT
# `uses: old-owner/repo/...` in workflows, OIDC subject claims, or container
# image paths. Those need the files changed.
#
#   FROM=crvouga-organization TO=crvouga scripts/sweep-refs.sh scan            # every moved repo
#   FROM=... TO=... scripts/sweep-refs.sh scan repo-a repo-b
#   FROM=... TO=... scripts/sweep-refs.sh diff repo-a      # apply locally, show the diff, push nothing
#   FROM=... TO=... scripts/sweep-refs.sh push repo-a      # commit + push to the default branch
#   FROM=... TO=... scripts/sweep-refs.sh pr repo-a        # commit + push a branch + open a PR
#
# scan writes state/<FROM>--<TO>/refs/<repo>.txt (lines that would change, and
# REVIEW lines left alone on purpose). Always read the diff before push/pr.
# Archived repos are scanned but never pushed (unarchive by hand if it matters).
set -u -o pipefail

: "${FROM:?}"; : "${TO:?}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE=${STATE:-$HERE/state/$FROM--$TO}
WORK=$STATE/work; REFS=$STATE/refs
BRANCH=${BRANCH:-chore/repo-owner-$TO}
MSG=${MSG:-"chore: point repo references at github.com/$TO

The repositories moved from github.com/$FROM to github.com/$TO."}
TRAILER=${TRAILER:-}
PR_BODY=${PR_BODY:-"The repositories moved from \`$FROM\` to \`$TO\`. This updates the references that GitHub redirects do not cover (workflow \`uses:\` lines, image paths, URLs)."}
mkdir -p "$WORK" "$REFS"

rec() { jq -r "$2" "$STATE/repo/$1.json"; }
git_auth() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }

# Names of every repo that lives under $TO after the move (for owner/repo matching).
names() {
  [ -s "$STATE/names.txt" ] || for f in "$STATE"/repo/*.json; do jq -r .name "$f"; done > "$STATE/names.txt"
  echo "$STATE/names.txt"
}

checkout() {
  local n=$1 d=$WORK/$1 def
  def=$(rec "$n" .default_branch)
  if [ -d "$d/.git" ]; then
    git_auth -C "$d" fetch -q --depth 1 origin "$def" && git -C "$d" checkout -q -B "$def" FETCH_HEAD && git -C "$d" reset -q --hard FETCH_HEAD
  else
    git_auth clone -q --depth 1 --branch "$def" "https://github.com/$TO/$n.git" "$d" 2>/dev/null
  fi
}

scan_one() {
  local n=$1 d=$WORK/$1
  [ "$(rec "$n" .size)" = 0 ] && { : > "$REFS/$n.txt"; return 0; }
  checkout "$n" || { echo "CLONE FAILED" > "$REFS/$n.txt"; echo "$n: clone failed" >&2; return 1; }
  (cd "$d" && git ls-files -z | FROM=$FROM TO=$TO NAMES=$(names) IMAGES=${IMAGES:-} perl "$HERE/scripts/fix-refs.pl" scan .) > "$REFS/$n.txt"
  printf '%s\t%s to change\t%s to review\n' "$n" "$(grep -vc '^REVIEW ' "$REFS/$n.txt")" "$(grep -c '^REVIEW ' "$REFS/$n.txt")"
}

apply_one() {
  local n=$1 d=$WORK/$1
  checkout "$n" || return 1
  (cd "$d" && git ls-files -z | FROM=$FROM TO=$TO NAMES=$(names) IMAGES=${IMAGES:-} perl "$HERE/scripts/fix-refs.pl" fix . >/dev/null)
  git -C "$d" diff --quiet && { echo "$n: nothing to change"; return 1; }
  return 0
}

commit_one() {
  local d=$WORK/$1
  git -C "$d" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -q -a -m "$MSG${TRAILER:+

$TRAILER}"
}

cmd=${1:-}; shift || true
list=${*:-$(for f in "$STATE"/repo/*.json; do jq -r .name "$f"; done)}
case "$cmd" in
  scan) for n in $list; do scan_one "$n"; done ;;
  diff) for n in $list; do apply_one "$n" && git -C "$WORK/$n" --no-pager diff; done ;;
  push)
    for n in $list; do
      [ "$(rec "$n" .archived)" = true ] && { echo "$n: archived, skipped"; continue; }
      apply_one "$n" || continue
      commit_one "$n" && git_auth -C "$WORK/$n" push -q origin "HEAD:$(rec "$n" .default_branch)" \
        && echo "$n: pushed $(git -C "$WORK/$n" rev-parse --short HEAD)" || echo "$n: PUSH FAILED"
    done ;;
  pr)
    for n in $list; do
      [ "$(rec "$n" .archived)" = true ] && { echo "$n: archived, skipped"; continue; }
      apply_one "$n" || continue
      git -C "$WORK/$n" checkout -q -B "$BRANCH" && commit_one "$n" \
        && git_auth -C "$WORK/$n" push -q -f origin "$BRANCH" \
        && gh pr create -R "$TO/$n" --head "$BRANCH" --base "$(rec "$n" .default_branch)" \
             --title "chore: point repo references at github.com/$TO" \
             --body "$PR_BODY" \
        || echo "$n: PR FAILED"
    done ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

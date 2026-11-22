#!/bin/bash
# repoint-remotes.sh: point local git clones at a repo's new owner after a
# GitHub transfer. Standalone (no state needed), so it can be run on any
# machine:
#
#   scripts/repoint-remotes.sh <from-owner> <to-owner> [--dry-run] [root ...]
#   curl -fsSL https://raw.githubusercontent.com/crvouga/github-repo-migration/main/scripts/repoint-remotes.sh \
#     | bash -s -- crvouga-organization crvouga
#
# Rewrites remote URLs, push URLs and submodule URLs in every git config found
# under the roots (default: $HOME) whose owner is <from-owner>. Worktrees share
# their main clone's config, so they are covered by the main clone.
#
# A URL is only rewritten when GitHub says the repo really lives under
# <to-owner> now (checked with `gh api`, which also resolves old repo names to
# the current name). Without gh it falls back to `git ls-remote` on the new URL.
# Old URLs keep working through GitHub's redirects, so skipped clones still
# fetch and push; they are listed at the end.
# Idempotent. Works with bash 3.2 (macOS) and Linux.
set -u

[ $# -ge 2 ] || { sed -n '2,18p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 2; }
FROM=$1; TO=$2; shift 2
DRY=0; ROOTS=""
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) ROOTS="$ROOTS $a" ;; esac; done
[ -n "$ROOTS" ] || ROOTS=$HOME
DEPTH=${DEPTH:-7}

lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
HAVE_GH=0
command -v gh >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1 && HAVE_GH=1
CACHE=$(mktemp -d "${TMPDIR:-/tmp}/repoint.XXXXXX")
trap 'rm -rf "$CACHE"' EXIT
changed=0; skipped=0; seen=0

# Print "<to-owner>/<current name>" if <from-owner>/<name> now lives under <to-owner>.
resolve() {
  local name=$1 url=$2 full c="$CACHE/$(lc "$1")"
  if [ ! -f "$c" ]; then
    full=""
    if [ $HAVE_GH = 1 ]; then
      full=$(gh api "repos/$FROM/$name" --jq .full_name 2>/dev/null </dev/null)
    fi
    if [ -z "$full" ]; then
      # No gh, or no access: accept the plain owner swap if the new URL answers.
      new=$(printf '%s' "$url" | sed "s|\([/:]\)$FROM/|\1$TO/|")
      GIT_TERMINAL_PROMPT=0 git ls-remote "$new" HEAD >/dev/null 2>&1 </dev/null && [ $HAVE_GH = 0 ] && full="$TO/$name"
    fi
    printf '%s' "$full" > "$c"
  fi
  full=$(cat "$c")
  case "$(lc "$full")" in "$(lc "$TO")"/*) printf '%s' "$full" ;; *) return 1 ;; esac
}

fix_config() {
  local d=$1 key url rest name full new
  git -C "$d" config --local --get-regexp '^(remote\..*\.(url|pushurl)|submodule\..*\.url)$' 2>/dev/null \
    | while read -r key url; do
      case "$(lc "$url")" in
        https://github.com/"$(lc "$FROM")"/*|http://github.com/"$(lc "$FROM")"/*|git@github.com:"$(lc "$FROM")"/*|ssh://git@github.com/"$(lc "$FROM")"/*|git://github.com/"$(lc "$FROM")"/*|https://*@github.com/"$(lc "$FROM")"/*) ;;
        *) continue ;;
      esac
      rest=${url#*github.com?*/}; name=${rest%.git}; name=${name%/}
      if full=$(resolve "$name" "$url"); then
        new="${url%%github.com*}github.com$(printf '%s' "$url" | sed 's|.*github\.com\(.\).*|\1|')$full"
        case "$url" in *.git) new="$new.git" ;; esac
        if [ $DRY = 1 ]; then echo "would change  $d  $key  $url -> $new"
        else git -C "$d" config --local "$key" "$new" && echo "changed  $d  $key  $url -> $new"; fi
      else
        echo "SKIPPED  $d  $key  $url  ($FROM/$name is not under $TO)"
      fi
    done
}

echo "repointing $FROM -> $TO under:$ROOTS (gh: $([ $HAVE_GH = 1 ] && echo yes || echo no), dry-run: $DRY)"
OUT=$CACHE/.out
: > "$OUT"
for root in $ROOTS; do
  find "$root" -maxdepth "$DEPTH" \( -name node_modules -o -name .Trash -o -name Library -o -name .cache -o -name .npm -o -name .cargo -o -name go \) -prune \
    -o -name .git -type d -print 2>/dev/null | while read -r g; do
      fix_config "${g%/.git}"
    done
done | tee "$OUT"
changed=$(grep -c '^changed\|^would change' "$OUT"); skipped=$(grep -c '^SKIPPED' "$OUT")
echo "done: $changed changed, $skipped skipped"
# .gitmodules files are tracked content, not config: report them, don't edit.
for root in $ROOTS; do
  find "$root" -maxdepth "$DEPTH" \( -name node_modules -o -name .Trash -o -name Library \) -prune -o -name .gitmodules -type f -print 2>/dev/null \
    | while read -r m; do grep -qi "github.com[/:]$FROM/" "$m" && echo "note: $m still names $FROM (tracked file; fix in the repo)"; done
done
exit 0

# Runbook: moving all repos between `crvouga` and `crvouga-organization`

Works in both directions. Set the direction once:

```sh
export FROM=crvouga-organization TO=crvouga   # org -> personal
export FROM=crvouga TO=crvouga-organization   # personal -> org
```

Needs `gh` (signed in as `crvouga`, scopes `repo`, `workflow`, `admin:org`), `jq`,
`perl`, `git`. Runs on macOS stock bash 3.2 and Linux.

## Order of work

| # | Step | Command | Changes anything? |
|---|---|---|---|
| 1 | Check access | `scripts/migrate.sh preflight` | no |
| 2 | Snapshot every repo | `scripts/migrate.sh record` | no (writes `state/`) |
| 3 | Move one small repo, check it | `ONLY=<repo> scripts/migrate.sh transfer settings verify` | yes |
| 4 | Move the rest | `scripts/migrate.sh transfer` | yes |
| 5 | Restore Actions settings | `scripts/migrate.sh settings` | yes |
| 6 | Re-enable / rebuild Pages | `scripts/migrate.sh pages` | yes |
| 7 | Check every repo | `scripts/migrate.sh verify report` | no |
| 8 | Pages redirect site | `scripts/pages-redirect-site.sh` (see below) | yes |
| 9 | Repoint clones on every machine | `scripts/repoint-remotes.sh $FROM $TO` | local git config only |
| 10 | Fix references inside repos | `scripts/sweep-refs.sh scan`, review, then `push` / `pr` | yes (commits) |
| 11 | Re-check CI on the repos that have workflows | by hand / per repo | no |
| 12 | **Prove it is finished** | `scripts/audit.sh` (on every machine for `clones`) | no |
| 13 | Update `docs/status.md`, `docs/history.md`, `docs/lessons.md` | | |

Steps 1–7 are safe to re-run: each step skips work that is already done.

## What each step does

**record** writes one JSON file per repo to `state/$FROM--$TO/repo/`: visibility,
default branch, topics, Pages config, Actions settings, default workflow token
permission, branch protection, rulesets, environments, workflows. This is the
"before" picture. It is also the **baseline for the next migration the other
way**: `settings` restores from `state/$TO--$FROM/repo/` (the snapshot taken
when the repos last left `$TO`). Keep `state/` around.

**transfer** calls the GitHub transfer API for every repo and waits until the
repo (looked up by its permanent id) reports the new owner. A transfer between
an account and an org that account owns is immediate. If a *different* repo
already uses the name on the target side the repo is skipped and reported; fix
that by hand.

**settings** puts back per-repo Actions settings from the baseline: allowed
actions, default `GITHUB_TOKEN` permission (read/write), whether Actions may
approve PRs, fork-PR approval policy.

**verify** checks owner, visibility, default branch, archived flag, topics, that
the old URL redirects to the new one, branch protection, Actions enabled, the
workflow token permission, and that Pages answers 200.

**repoint-remotes.sh** is standalone. On another machine:

```sh
curl -fsSL https://raw.githubusercontent.com/crvouga/github-repo-migration/main/scripts/repoint-remotes.sh \
  | bash -s -- crvouga-organization crvouga --dry-run     # drop --dry-run to apply
```

It only rewrites a URL when GitHub confirms the repo now lives under the new
owner, and it resolves old repo names to the current name.

**sweep-refs.sh** shallow-clones each repo and reports the lines that name the
old owner. `scan` first, read `state/$FROM--$TO/refs/<repo>.txt`, then `diff
<repo>` to see the exact change, then `push <repo>` (direct to the default
branch) or `pr <repo>` (branch + pull request). Lines that name **both** owners
are left alone on purpose and listed as `REVIEW`.

**pages-redirect-site.sh** generates a tiny static site for
`<old-owner>.github.io` that forwards `/<repo>/...` to
`<new-owner>.github.io/<repo>/...`. Publish it as the repo
`<old-owner>/<old-owner>.github.io`. Remove the forwarders for the same repos
from the *new* owner's `.github.io` site, or the two sites redirect in a loop.

## Definition of done

A migration is finished when `scripts/audit.sh` exits 0 and `docs/status.md` has
no open item. "Moved and redirecting" is not finished. Every item below is
either closed or blocked on one named thing only the owner can supply, and that
thing has been asked for.

- Every repo is under the new owner; nothing but the keep-list is left behind.
- No file in any repo (moved or not, archived or not) selects the old owner.
- No Actions variable names the old owner or its numeric ID. Secrets cannot be
  read: check the ones that hold repo names or OIDC subjects by hand.
- Every setting a transfer resets is back: workflow token permission, branch
  rulesets and protection, code scanning default setup, secret scanning, Pages.
- External trust that names the owner works from the new location: OIDC
  subjects in cloud roles and secret managers, npm trusted publishers, image
  registries. Proven by a green run, not by reading config.
- Every workflow's latest default-branch run is green, or shown to have been
  red before the move.
- No migration pull request is open. No stale queued run is left.
- Every clone on every machine points at the new owner.
- Whatever the migration created only for itself (redirect sites, scratch
  clones, package copies) is either still needed and documented, or removed.
- Damage check: every commit the tooling pushed changed only the files it
  meant to (`gh api repos/<o>/<r>/commits/<sha> --jq '.files[].filename'`).

## Rules

- **Never create a repo at an old location** (`$FROM/<moved-name>`). It
  permanently breaks that repo's redirect.
- **Never re-run an old publish / deploy / release workflow run.** It rebuilds
  and redeploys old code. Push a new commit or dispatch on the head instead.
- Space out transfers and pushes. All automation shares one account-wide API
  limit (5,000 requests/hour) with CI tokens that are personal access tokens.
- Push reference fixes to repos with deploy pipelines one at a time; deploys
  share third-party rate limits (Railway).
- Do not weaken a failing check to get a green run. Classify it: caused by the
  move (fix it) or already failing before (record the evidence in status).
- `state/` is local. The public docs must not name private repos.

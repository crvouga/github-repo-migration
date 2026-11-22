# github-repo-migration

Scripts and living docs for moving every repository between the personal
account [`crvouga`](https://github.com/crvouga) and the organization
[`crvouga-organization`](https://github.com/crvouga-organization), in either
direction.

**Where the repos live right now: `crvouga` (personal account).**
See [docs/status.md](docs/status.md) for the current migration and what is left.

## For agents: start here

1. Read [docs/status.md](docs/status.md): current state, open items, things only the owner can do.
2. Read [docs/runbook.md](docs/runbook.md) before running anything: the order of steps and the traps.
3. Update `docs/status.md` as work lands. It is the single source of truth.
4. Add what you learn to [docs/lessons.md](docs/lessons.md) so the next migration is smoother.

This repository is **public**. Never commit private repo names, tokens, webhook
URLs or anything from `state/` (gitignored). Refer to private repos by count.

## Layout

| Path | What it is |
|---|---|
| `scripts/migrate.sh` | Transfers repos `$FROM` → `$TO`, restores per-repo settings, checks redirects. Idempotent. |
| `scripts/repoint-remotes.sh` | Points local clones on a machine at the new owner. Standalone; run it on every machine. |
| `scripts/sweep-refs.sh` + `scripts/fix-refs.pl` | Finds and fixes references to the old owner inside repo files. |
| `scripts/audit.sh` | **Is the migration finished?** One PASS/FAIL line per category of leftover. A migration is done when it passes. |
| `scripts/restore-rulesets.sh` | Re-creates deleted branch rulesets from the definitions in an org's audit log. |
| `scripts/cancel-stale-runs.sh` | Cancels runs left in the queue from before a cutoff (for example from a period with Actions disabled). |
| `scripts/pages-redirect-site.sh` | Builds the small Pages site that forwards `<old-owner>.github.io/<repo>` to the new owner. |
| `docs/status.md` | Living status of the current migration. |
| `docs/runbook.md` | How to run a migration, step by step. |
| `docs/lessons.md` | What breaks in a move and what redirects do and do not cover. |
| `docs/history.md` | Log of past migrations. |
| `state/` | Local only (gitignored): per-repo snapshots, logs, working clones. |

## Quick start

```sh
export FROM=crvouga-organization TO=crvouga        # or the other way round
scripts/migrate.sh preflight record                # read-only: checks access, snapshots every repo
ONLY=some-small-repo scripts/migrate.sh transfer settings verify   # try one first
scripts/migrate.sh transfer settings pages verify report
scripts/repoint-remotes.sh "$FROM" "$TO"           # on every machine
scripts/sweep-refs.sh scan                         # then review, then push / pr
```

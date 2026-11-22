# Lessons: what a move breaks and what redirects cover

Collected from the 2026-11-20 move to the org and the 2026-11-21 move back.
Add to this file whenever a migration teaches something new.

## What GitHub's redirects cover

After a transfer GitHub redirects the old location to the new one, for as long
as nobody creates a repo at the old location.

| Works through the redirect | Does not |
|---|---|
| `git clone` / `fetch` / `push` over HTTPS and SSH | `uses: old-owner/repo/...@ref` in workflows (actions and reusable workflows): rewrite |
| Web URLs (issues, PRs, files, releases) | OIDC subject claims (`repo:old-owner/repo:...`) in AWS, Vault, npm trusted publishing: the claim carries the new owner |
| REST API by `repos/old-owner/repo` (answers 301; `gh` and `curl -L` follow it) | API calls from scripts that do not follow redirects (plain `curl` without `-L`; POSTs get a 307) |
| Old repo *names* (renames) keep redirecting after a transfer | GitHub Pages URLs (`old-owner.github.io/repo`): needs a redirect site |
| Go module paths, `go get` | Container images (`ghcr.io/old-owner/image`): packages belong to the account, not the repo, and do not move |
| | GitHub App installations (Vercel, Railway, Heroku): per account, re-check after a move |
| | Re-running an old workflow run: it reuses the old workflow file, old references included |

## What a transfer keeps and loses

Kept: issues, PRs, stars, watchers, releases, wiki, webhooks, deploy keys,
repo-level secrets and variables, environments, topics, Pages config, repo
rulesets, Dependabot and code scanning config.

Lost or changed:

- **Default `GITHUB_TOKEN` permission** follows the new owner's policy. The org
  (enterprise) forces read-only and forbids Actions approving PRs. Restore
  per-repo values with `migrate.sh settings` when moving to the personal account;
  when moving to the org, workflows that relied on a write default need an
  explicit `permissions:` block.
- **Org-level** secrets, variables, rulesets, teams: not carried to a user account.
- **Packages** stay with the old owner. A repo can keep publishing to a package
  it has Actions access to, but `GITHUB_TOKEN` cannot push to a package owned by
  another account.
- **Branch protection** on private repos needs a paid plan on the target.
- **Pages URL** changes with the owner.
- **Security features are reset**: secret scanning, push protection and CodeQL
  default setup come back disabled / `not-configured` after a transfer to a user
  account. An org security configuration can also switch CodeQL on for every
  repo on arrival. `migrate.sh record` captures both; `settings` restores them.
- **Immutable OIDC subjects** (`repo:<owner>@<owner-id>/<repo>@<repo-id>`) carry
  the numeric owner ID. A search for the owner *name* does not find them: look
  for the IDs too (user `crvouga` = 49178412, org = 354284559).
- **Repo variables and secrets hold owner names too** (`gh variable list`). A
  scan of tracked files cannot see them.

## Traps

- **Never `git commit -a` from a macOS checkout of someone else's tree.** A repo
  with paths that differ only by case (the Linux kernel has many) checks out as
  "modified" on a case-insensitive filesystem. The 2026-11-20 migration
  committed that and overwrote 13 kernel files. Check `git status` is clean
  before changing anything and add only the files you rewrote.
- **Deleted rulesets can be recovered.** An org's audit log keeps the full
  definition of every destroyed ruleset (`action:repository_ruleset.destroy`).
  User accounts have no audit log: snapshot rulesets before deleting any.
- **`[skip ci]` in the commit subject** lets a cosmetic fix land in a repo whose
  push pipeline publishes or deploys.
- **Merges made while checks cannot run leave `main` red for everyone after.**
  During the Actions outage nine PRs were merged into one repo unverified; the
  first PR opened afterwards (the migration's own) inherited every failure.
  Before a move, and before deleting branch rules to get around an outage, note
  which merges were unverified so they can be re-verified first.
- **An auto-merge workflow plus a missing required check merges instantly.**
  Restore branch rules before opening pull requests.

- A lookup of `new-owner/repo` succeeds *before* the transfer when an older
  redirect exists for that name. Check ownership by repository id
  (`GET /repositories/<id>`), not by name.
- One stalled connection can hang `gh api` for minutes. `migrate.sh` wraps every
  call in a 90-second timeout and retries.
- All automation shares the account's 5,000 requests/hour API limit, including
  CI tokens that are personal access tokens. A full `record` + `transfer` +
  `settings` + `verify` for ~100 repos costs roughly 2,500 requests.
- Re-running an old publish/deploy/release run rebuilds and redeploys old code.
  Push a fresh commit or dispatch the workflow on the head instead.
- Deploy pipelines share third-party rate limits. Railway sustains about two
  full OpenTofu plans an hour for this fleet: three deploys in 35 minutes drew
  HTTP 429, and retries during the cool-down failed too (and count against the
  limit). Use `scripts/serial-publish.sh`; budget 30 minutes per repo that
  deploys.
- A caller workflow regenerated with `[skip ci]` has not been proven. Publish
  once from each repo afterwards: registry access and the dispatch token are
  per repo.
- An empty commit does not trigger a workflow that has `paths` or
  `paths-ignore` filters. Dispatch it instead.
- Two Pages redirect sites pointing at each other loop. When project sites move
  back, empty the forward list of the site on the side they returned to.
- Keep dual-owner matchers (OIDC trust lists, URL allow-lists that accept both
  `crvouga/*` and `crvouga-organization/*`). They make the next move free.
- The org's Actions can be disabled above the org (enterprise policy/billing)
  while every org and repo setting still reads "enabled". Symptom: dispatch
  returns `422 Actions has been disabled for this repository` and runs stay
  queued. This is what triggered the move back on 2026-11-21.

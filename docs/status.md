# Status: `crvouga-organization` → `crvouga`

Single source of truth for the running migration. Update it as work lands.

**Last updated:** 2026-11-22 02:25 UTC
**State:** repos moved and verified; machines repointed; **reference fixes inside repos in progress.**

Local state for this run (not in git): `state/crvouga-organization--crvouga/` on
the MacBook Air checkout that ran it — snapshots (`repo/`), verification
(`verify/`), leftover references per repo (`refs/`), log (`migrate.log`).

## Done ✅

### Transfer (2026-11-22 01:47–01:57 UTC)

- [x] Snapshot of all 102 repos taken before the move.
- [x] 102 / 102 repos transferred to `crvouga` (91 public, 11 private; 5 forks, 3 archived). No name clashes, no failures.
- [x] Verified for every repo: owner, visibility, default branch, archived flag, topics, branch protection rule, rulesets, Actions enabled. **0 problems.**
- [x] Old URLs redirect: `github.com/crvouga-organization/<repo>` → `github.com/crvouga/<repo>` (102 / 102, web for public repos, API for private).
- [x] `crvouga-organization` now holds no moved repo. Only `crvouga-organization.github.io` (redirect site, new) lives there.

### Settings

- [x] Per-repo Actions settings restored from the pre-2026-11-20 snapshot: 33 repos have a **write** default `GITHUB_TOKEN` again (the org forced read-only), allowed actions, fork-PR approval policy. Checked on all 102.
- [x] Actions runs again: runs created after the transfer execute and complete.

### GitHub Pages

- [x] `gig-log` and `match-three` are live at `https://crvouga.github.io/<repo>/`.
- [x] `crvouga/crvouga.github.io` no longer forwards to the org (it would have looped). Unknown paths go to `github.com/crvouga`.
- [x] `crvouga-organization/crvouga-organization.github.io` created to forward `crvouga-organization.github.io/<repo>/…` → `crvouga.github.io/<repo>/…`. **Not serving yet:** Pages builds are an Actions job, and Actions is disabled for the org. It starts working by itself if the org's Actions comes back. Those URLs existed for less than a day.

### Machines

| Machine | Remotes repointed | Skipped | Re-run |
|---|---|---|---|
| MacBook Air | 12 working clones (+98 scratch clones from the earlier migration) | 0 | 0 changed |
| Mac Studio | 5 (`gitty`, `gamezilla`, `atlas`, `dev-fleet`, `personal`) | 0 | 0 changed |
| MS-A2 | 7 (`mockingbird` ×2, `dev-fleet` source, `atlas`, `personal`, `agent-skills`, `gamezilla`) | 0 | 0 changed |

Worktrees share their main clone's config, so they are covered. Not changed (works through redirects, report only):

- `~/.config/dev-fleet/fleet.json` on Mac Studio and MS-A2: `"repository": "https://github.com/crvouga-organization/dev-fleet.git"`. Live config; fix with the dev-fleet reference work.
- T3 Code state/caches and agent transcripts still contain old URLs (history; T3 re-reads the remote).
- `FETCH_HEAD` files: rewritten by the next fetch.

## In progress 🔄 — references inside repo files

`scripts/sweep-refs.sh scan` found **36 repos** whose files still name
`crvouga-organization` (66 have none). Redirects cover the URLs; they do **not**
cover workflow `uses:` lines, repo-name gates in workflows, OIDC claims, or
image paths.

**Order matters: `personal` first.** It is the infra hub. Its Deploy job only
runs when `github.repository == 'crvouga-organization/personal'`, so deploys are
paused until it is fixed (safe: no OpenTofu apply runs with the org as owner).
Its OpenTofu apply generates the `publish.yml` caller workflow in the app repos.

| Repo | Lines | What is in there | Who | Status |
|---|---|---|---|---|
| personal | 446 (+32 review) | Deploy gate on repo name, OpenTofu `owner`, inventory, generated `llms*.txt`, portfolio data | agent (running) | in progress |
| mockingbird | 948 (+403 review) | mostly generated docs/`llms.txt`, package metadata, release + health scripts | agent (running) | in progress |
| atlas | 306 (+11) | schema `$id` URLs, docs, generated `llms*.txt`, release + health scripts, image owner | agent (running) | in progress |
| gamezilla | 53 (+7) | workflows, scripts, AWS OIDC trust (already trusts `crvouga/gamezilla`) | agent (running) | in progress |
| dev-fleet | 49 (+2) | package metadata, schema URLs, release | agent (running) | in progress |
| fleet | 32 | publish caller, docs | after `personal` | not started |
| moviefinder | 29 | publish caller, docs | after `personal` | not started |
| gitty | 25 | publish caller, docs | after `personal` | not started |
| pillbox | 23 (+2) | calls `personal`'s workflow; publishes to `ghcr.io/crvouga-organization`: must go back to `ghcr.io/crvouga` | after `personal` | not started |
| normalizer.app | 3 (+3) | `image_owner: crvouga-organization` in the publish workflow: must go back | after `personal` | not started |
| pickflix-v1 | 6 (+1) | publish caller, package metadata | after `personal` | not started |
| 13 publish-caller app repos | 2–9 each | `uses: crvouga-organization/personal/.github/workflows/publish.yml@main` + `infra_github_repo` (generated by `personal`), package metadata | regenerated by `personal` apply | not started |
| agent-skills | 12 | install instructions, docs URL, template | done | ✅ pushed `1286867`; CI + Release green (v1.0.3) |
| bun-plugin-react-native-testing-library | 10 | repo constant asserted by tests, secrets manifest, README | done | ✅ pushed `e29e761`; CI running |
| gig-log | 1 | live-site link | done | ✅ pushed `37419d8`; Pages deploy green |
| result | 3 | `package.json` URLs | done | ✅ pushed `36e5c23`; CI green |
| gamezilla-app | 1 | README badge | done | ✅ pushed `f737b9a`; one E2E test timed out (flaky, README-only commit), re-running |
| docker-test, moviefinder.app-hono | 3, 1 | `package.json` URLs | done | ✅ pushed; no active workflows |
| moviefinder.app-go, screenshot-service | 1 each | makefile / `package.json` URL (cosmetic; redirects cover them) | | left: a push would trigger a publish/deploy for a cosmetic change |
| 3 archived repos | 1–5 each | package metadata, README (cosmetic) | | left alone: archived |

The 13 publish-caller repos: anime, connect-four, headless-combobox,
image-service, llm-server, match-three, moviefinder.app-clojurescript,
moviefinder.app-react, moviefinder.app-rust, simon-says, snake, todo-v1,
violets-garden. Do not push to them before `personal` is fixed: every push
triggers a publish that calls into `personal`.

## To do 📋

- [ ] Finish the reference work above; record PR links and CI state per repo here.
- [ ] After `personal` is fixed: confirm Deploy runs, the OpenTofu plan is clean, and the caller workflows in the app repos were regenerated.
- [ ] Re-check the default-branch CI of every repo with workflows; classify each red run as caused by the move or already failing before.
- [x] Stale runs from the org period: the 2 real ones were cancelled (a `personal` CI run and a `dev-fleet` run). 133 CodeQL default-setup entries across the repos still show `queued`; GitHub refuses to cancel them ("has not been queued yet"). They never ran and block nothing; delete the run records if the clutter matters (`scripts/cancel-stale-runs.sh` lists them).
- [ ] Review the open Dependabot PRs that opened right after the transfer.

## Needs the owner 🙋

1. **Branch protection is gone on 8 repos** (dev-fleet, fleet, gamezilla, gitty, mockingbird, moviefinder, personal, pickflix-v1). It was already missing in the snapshot taken *before* this transfer (it existed on 2026-11-21 09:11 UTC), so it was removed in the org, not by this move. The earlier snapshot only recorded "protected: yes", not the rules, so the script cannot restore them. `personal`'s OpenTofu may own these rules; otherwise re-create them.
2. **GitHub Apps** (Vercel, Railway, Heroku) are installed per account. If the personal account's installation is limited to selected repositories, re-add the returned repos: <https://github.com/settings/installations>. (The token cannot read installations.)
3. **npm trusted publishers** must name the owner in the OIDC claim. `@crvouga/dev-fleet` was switched to `crvouga-organization/dev-fleet` on 2026-11-21 and needs switching back (needs your npm 2FA): `npm trust github @crvouga/dev-fleet --repo crvouga/dev-fleet --file release.yml --allow-publish`. `atlas` and the `@crvouga/mockingbird*` packages still trust `crvouga/*` and need nothing.
4. **Org container images**: 61 images were copied to `ghcr.io/crvouga-organization` (private). Four repos published there since (atlas, pillbox, normalizer.app, moviefinder.app-go); their newest images are only in the org until those repos publish to `ghcr.io/crvouga` again. Delete the org copies once nothing pulls from them: <https://github.com/orgs/crvouga-organization/packages>.
5. **Why Actions was disabled for the org** is still unknown (enterprise policy or billing; the token cannot see the enterprise). Check <https://github.com/enterprises/crvouga-enterprise/settings/actions> before any move back to the org.
6. **This repo is public.** The docs name only public repos. Say so if you would rather make it private and track private repos by name.

## Rules while this is open

- Never create a repo under `crvouga-organization` with a moved repo's name: it breaks that repo's redirect for good.
- Never re-run an old publish / deploy / release run. Push a commit or dispatch on the head.
- Keep matchers that accept both owners.

# Status: `crvouga-organization` → `crvouga`

Single source of truth for the running migration. Update it as work lands.

**Last updated:** 2026-11-22 04:50 UTC
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
| personal | 446 (+32 review) | Deploy gate on repo name, OpenTofu `owner`, inventory, generated `llms*.txt`, portfolio data | done | ✅ PRs [#341](https://github.com/crvouga/personal/pull/341) and [#342](https://github.com/crvouga/personal/pull/342) merged; `main` CI green; Deploy ran; OpenTofu plan clean on all four roots (no repo created, destroyed or replaced); 6 rulesets re-created by the apply. Two lines still name the org on purpose (Vault accepts both owners). |
| mockingbird | 948 (+403 review) | mostly generated docs/`llms.txt`, package metadata, release + health scripts | done, except npm | ✅ PR [#892](https://github.com/crvouga/mockingbird/pull/892) merged; CI and Publish image green on `main`; deploy through `personal` succeeded. ❌ Release fails with npm `ENEEDAUTH`: the packages' npm trusted publisher was switched to the org on 2026-11-21 (see "Needs the owner"). |
| atlas | 306 (+11) | schema `$id` URLs, docs, generated `llms*.txt`, release + health scripts, image owner | done | ✅ PR [#116](https://github.com/crvouga/atlas/pull/116) merged; `main` green; `ghcr.io/crvouga/atlas` and `atlas-insecure` republished and public |
| gamezilla | 60 + owner ID | text links, plus the numeric owner ID in `libs/infra-shared-ts/tofu/global.tfvars.json` and the `PRODUCT_IDENTITY_JSON` repo variable | **waiting on the owner** | CI identity recovered; `main` ruleset restored; auto-merge armed on PR [#447](https://github.com/crvouga/gamezilla/pull/447). Fixed on the branch: lint (#439), stale `t3.json` (#438), Space stories colocated + 90 baselines (#438/#443): unit tests and Storybook coverage pass. **Still red:** every Storybook integration shard, because #444 put unmigrated game screens inside the new stage shell. Needs a decision (see "Needs the owner" 7). |
| dev-fleet | 49 (+2) | package metadata, schema URLs, release | done | ✅ PR [#199](https://github.com/crvouga/dev-fleet/pull/199) merged; CI + Release green; `@crvouga/dev-fleet@0.9.5` published from `crvouga/dev-fleet` (npm trust works) |
| fleet | 32 | publish caller (hand-maintained), docs | PR open | PR [#17](https://github.com/crvouga/fleet/pull/17). Also updates a test left stale by #16 (merged unchecked during the outage: it narrowed the signing trigger to `branches: [main]`). Merged by the queue when green. |
| moviefinder | 29 | caller in `check.yml` (hand-maintained), docs | PR open | PR [#17](https://github.com/crvouga/moviefinder/pull/17), formatter applied. Merged by the queue when green. |
| gitty | 25 | publish caller (hand-maintained), docs | PR open, green | PR [#27](https://github.com/crvouga/gitty/pull/27); the perf e2e test flaked once and passed on re-run. Merged by the queue. |
| pillbox | 25 | calls `personal`'s workflow; published to `ghcr.io/crvouga-organization` | done | ✅ pushed `a18dc96`: `image_owner: crvouga`; Publish image green |
| normalizer.app | 6 | `image_owner: crvouga-organization` in the publish workflow | done | ✅ pushed `ba8d75c`; Publish image green to `ghcr.io/crvouga` (both packages linked to the repo first, by pushing a labelled `migrate-link` tag). Deployment Pipeline red as before the move (revoked `OPENAI_API_KEY` in Vault). |
| pickflix-v1 | 7 | publish caller (hand-maintained), package metadata | PR open, green | PR [#75](https://github.com/crvouga/pickflix-v1/pull/75). Merged by the queue. |
| 13 publish-caller app repos | 2–9 each | `uses: …/personal/.github/workflows/publish.yml@main` + `infra_github_repo` (generated by `personal`) | regenerated; proving | All 13 call `crvouga/personal` again. `scripts/serial-publish.sh` republishes them one at a time (results in `state/…/serial-publish.tsv`). **Proven (publish + deploy green):** snake, todo-v1. **Published, deploy rate-limited by Railway (429), redeploy queued:** simon-says, match-three. **Queued:** anime, connect-four, headless-combobox, image-service, llm-server, moviefinder.app-clojurescript, moviefinder.app-react, moviefinder.app-rust, violets-garden. Pace: one deploy every ~30 minutes. |
| agent-skills | 12 | install instructions, docs URL, template | done | ✅ pushed `1286867`; CI + Release green (v1.0.3) |
| bun-plugin-react-native-testing-library | 10 | repo constant asserted by tests, secrets manifest, README | done | ✅ pushed `e29e761`; CI green |
| gig-log | 1 | live-site link | done | ✅ pushed `37419d8`; Pages deploy green |
| result | 3 | `package.json` URLs | done | ✅ pushed `36e5c23`; CI green |
| gamezilla-app | 1 | README badge | done | ✅ pushed `f737b9a`. E2E job red on 3 attempts with different tests each time; the suite was red from 2025-12-24 to 2026-01-26 and green once on 2026-11-21: flaky before the move, not caused by it |
| docker-test, moviefinder.app-hono | 3, 1 | `package.json` URLs | done | ✅ pushed; no active workflows |
| moviefinder.app-go, screenshot-service | 1 each | makefile / `package.json` URL | done | ✅ pushed with `[skip ci]`. moviefinder.app-go publish dispatched on the head: green to `ghcr.io/crvouga/moviefinder.app-go` |
| postgres-mem, sqlite-mem, 1 private archived repo, portfolio | 1–22 each | package metadata, README, project links | done | ✅ unarchived, pushed with `[skip ci]`, archived again |

The 13 publish-caller repos: anime, connect-four, headless-combobox,
image-service, llm-server, match-three, moviefinder.app-clojurescript,
moviefinder.app-react, moviefinder.app-rust, simon-says, snake, todo-v1,
violets-garden. Do not push to them before `personal` is fixed: every push
triggers a publish that calls into `personal`.

## Also fixed along the way

- **`linux` fork:** the 2026-11-20 migration had pushed a commit that overwrote 13 kernel files with the content of siblings whose names differ only by case (a macOS checkout artefact). Reverted with a forward commit made through the API; the tree equals upstream commit `f7734f4c91c0` again. `sweep-refs.sh` now refuses a checkout that is dirty before any change and commits only the files it rewrote.
- **`portfolio`** (never moved, archived) still pointed at the org; fixed.
- No Actions variable in any repo or environment names the org or its numeric ID.

## To do 📋

- [ ] gamezilla: merge #447 when green; check the Release run.
- [ ] After `personal` #342 lands: run `fleet-sync` on each machine (the fleet-owned dev-fleet checkout already points at `crvouga`; `fleet.json` `source.repository` must match it exactly).
- [ ] `scripts/audit.sh` must pass before this is called done.

- [ ] Finish the reference work above; record PR links and CI state per repo here.
- [ ] After `personal` is fixed: confirm Deploy runs, the OpenTofu plan is clean, and the caller workflows in the app repos were regenerated.
- [ ] Re-check the default-branch CI of every repo with workflows; classify each red run as caused by the move or already failing before.
- [x] Stale runs from the org period: the 2 real ones were cancelled (a `personal` CI run and a `dev-fleet` run). 133 CodeQL default-setup entries across the repos still show `queued`; GitHub refuses to cancel them ("has not been queued yet"). They never ran and block nothing; delete the run records if the clutter matters (`scripts/cancel-stale-runs.sh` lists them).
- [ ] Review the open Dependabot PRs that opened right after the transfer.

## Needs the owner 🙋

1. ~~Branch protection~~ **restored.** The rulesets on 8 repos had been deleted in the org on 2026-11-22 00:37 UTC. The org audit log keeps each deleted ruleset's full definition; `scripts/restore-rulesets.sh` re-created the three that were still missing (dev-fleet, gitty `main`, gamezilla `main`). The other six had already been re-created at 02:40 UTC.
2. ~~GitHub Apps~~ **nothing to do.** No repo has had an app-created deployment since 2026-09-22 (Vercel, one repo) / 2026-05-21 (Railway); deploys go through `personal` now. Two 2021 Heroku webhooks (gamezilla-app, screenshot-service) answer 404 on every delivery, before and after the move: dead integrations.
3. **npm trusted publishers for mockingbird (needs your npm 2FA).** All `@crvouga/mockingbird*` packages (133) were published from the org on 2026-11-21, which re-pointed their trusted publisher at `crvouga-organization/mockingbird`. Release from `crvouga/mockingbird` fails with `ENEEDAUTH` until you run, in an up-to-date mockingbird checkout: `npm login && bun run release:seed -- --trust-only`. Then dispatch Release on the head. dev-fleet needs nothing: `@crvouga/dev-fleet@0.9.5` published from `crvouga/dev-fleet` after the move. Optional: `npm trust list @crvouga/dev-fleet` and revoke an entry naming the org, if one exists.
4. **Org container images**: 61 images were copied to `ghcr.io/crvouga-organization` (private). Four repos published there since (atlas, pillbox, normalizer.app, moviefinder.app-go); their newest images are only in the org until those repos publish to `ghcr.io/crvouga` again. Delete the org copies once nothing pulls from them: <https://github.com/orgs/crvouga-organization/packages>.
5. **Why Actions was disabled for the org** is still unknown (enterprise policy or billing; the token cannot see the enterprise). Check <https://github.com/enterprises/crvouga-enterprise/settings/actions> before any move back to the org.
6. **Security features were reset by the transfer; restored.** Secret scanning and push protection read `disabled` afterwards; both are enabled again on all 89 public, non-archived repos (the account default for new public repos). CodeQL default setup read `not-configured` everywhere. CodeQL is correct for 101 repos (only `gamezilla` had it before 2026-11-20; the org had switched it on for 75 repos) and was restored on `gamezilla` (`actions`, `javascript-typescript`). `migrate.sh record` now captures both for next time.
7. **gamezilla: what to do about #444.** `main` cannot pass verification with #444 ("every space screen sits in SpaceScreenFrame", merged with no checks during the outage): game screens no longer fit their viewports. Until that is resolved no PR in gamezilla can merge through the gate, #447 included. Options: (a) back out #444's chrome swap on the #447 branch (its own description names reverting as the rollback; a tested inverse patch is ready on the Mac Studio: `~/.t3/scratch/2026-11-22-act-as-the-implementation-sub-7d8af5a1/undo-444.patch`; `t3/space-launcher` is stacked on #444 and would have to carry it again); (b) keep #444 and land the in-game migration first; (c) merge #447 with the admin bypass and leave `main` red. After #447 merges: check the Release run (first test of AWS trust from `crvouga/gamezilla`).
8. **This repo is public.** The docs name only public repos. Say so if you would rather make it private and track private repos by name.

## Rules while this is open

- Never create a repo under `crvouga-organization` with a moved repo's name: it breaks that repo's redirect for good.
- Never re-run an old publish / deploy / release run. Push a commit or dispatch on the head.
- Keep matchers that accept both owners.

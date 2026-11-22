# Migration history

Newest first. One entry per migration; details of the running one are in
[status.md](status.md).

## 2026-11-21 — `crvouga-organization` → `crvouga` (org back to personal)

- **Why:** GitHub Actions stopped running for the whole org on 2026-11-21
  (~10:20 UTC): dispatches answered `422 Actions has been disabled for this
  repository`, new runs stayed queued, while every org and repo Actions setting
  still read "enabled".
- **What moved:** all 102 repos (91 public, 11 private; 5 forks, 3 archived).
  Same names, no clashes. Transfer took about 9 minutes.
- **Tooling:** the scripts in this repo (first use).
- **Baseline for settings:** the snapshot taken before the 2026-11-20 move.

## 2026-11-20 — `crvouga` → `crvouga-organization` (personal to org)

- **What moved:** 102 repos. Kept on the personal account: `portfolio`
  (profile repo).
- **Tooling:** a one-off script in a scratch directory (the ancestor of
  `scripts/migrate.sh`).
- **Side effects that outlived it:**
  - 61 container images / 1,586 tags were copied to `ghcr.io/crvouga-organization`
    (private, identical digests). The originals at `ghcr.io/crvouga` were left in
    place and stayed the published location for most repos.
  - Reference fixes were pushed to 38 repos (`crvouga/<repo>` → org).
  - 19 workflow files gained `permissions: write-all` because the enterprise
    forces a read-only default token.
  - Vault JWT roles and URL matchers were changed to accept both owners.
  - `crvouga/crvouga.github.io` was created to forward moved Pages sites.

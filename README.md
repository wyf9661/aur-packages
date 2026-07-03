# aur-packages

GitHub Actions monorepo for automating AUR package version bumps.

## Packages

- `packages/python-hermes-agent` — tracks [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) GitHub releases
- `packages/9router-bin` — tracks [9router](https://registry.npmjs.org/9router) on npm

## Layout

```
packages/<pkgname>/
├── PKGBUILD                # source of truth
├── update.sh               # per-package version resolution + bump
└── (helpers, .install, .service, ...)
scripts/
└── update.sh               # SSH setup, AUR clone, rsync, push wrapper
.github/workflows/
└── aur-updater.yml         # daily cron + manual dispatch
```

## Setup

1. Generate a dedicated deploy key for AUR push:
   ```bash
   ssh-keygen -t ed25519 -C "github-actions@aur-deploy" -f ~/.ssh/id_ed25519_aur_deploy -N ""
   ```
2. Add the public key to your AUR account at
   <https://aur.archlinux.org/account/wyf9661/edit> (paste the contents of
   `id_ed25519_aur_deploy.pub`).
3. In this GitHub repo, create a secret `AUR_SSH_KEY` containing the
   base64-encoded private key:
   ```bash
   base64 -w0 ~/.ssh/id_ed25519_aur_deploy | pbcopy    # or xclip
   ```
   Paste into Settings → Secrets and variables → Actions → New repository
   secret.

## Usage

**Manual**: Actions tab → aur-updater → Run workflow → pick a package.

**Scheduled**: runs daily at 06:00 UTC. Both packages are checked; pushes
happen only when a new version is detected.

## Version resolution

| Package                | Source                              | Version field | Hash field            |
|------------------------|-------------------------------------|---------------|-----------------------|
| python-hermes-agent    | GitHub releases API                 | `tag` + `pkgver` | `sha256` of source tarball |
| 9router-bin            | npm registry `latest` endpoint      | `pkgver`        | `sha256` of .tgz (cross-checked against npm `integrity` sha512) |

## Auditing

The workflow commits the post-update state of `packages/*` back to this
monorepo on every run. That gives a per-version history that does NOT
exist on AUR.

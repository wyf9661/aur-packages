#!/usr/bin/env bash
# updater: python-hermes-agent
#
# Upstream source: https://github.com/NousResearch/hermes-agent
# Version scheme (two eras):
#   - v0.21.6+ (2026-10-08): tag and release name are both plain
#     "v<ver>" (e.g. name "Hermes Agent v0.21.7", tag v0.21.7).
#   - older: tag "vYYYY.M.P" (e.g. v2026.9.24) with the CLI version in
#     the release name: "Hermes Agent v0.21.5 (v2026.9.24)".
# pkgver is the CLI version parsed from the release name, falling back
# to the tag when the name carries no parseable version.

set -euo pipefail

log() { printf '\033[1;36m[hermes]\033[0m %s\n' "$*"; }

# --- Resolve latest upstream release ------------------------------------
tmp_meta="$(mktemp)"
trap 'rm -f "$tmp_meta"' EXIT

# Authenticate when a token is available: shared GHA runner IPs can hit the
# unauthenticated api.github.com rate limit (one run died with curl: (22) 403).
curl_args=(-fsSL)
if [[ -n "${GH_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi
curl "${curl_args[@]}" \
    https://api.github.com/repos/NousResearch/hermes-agent/releases/latest \
    -o "$tmp_meta"

read -r clean_tag pkgver < <(python3 - "$tmp_meta" <<'PY'
import json, sys, re
with open(sys.argv[1]) as f:
    data = json.load(f)
tag = data["tag_name"]
name = data["name"]
clean_tag = tag.lstrip("v")
# Stop the version at a space or "(" so both naming eras parse:
# "Hermes Agent v0.21.7" and "Hermes Agent v0.21.5 (v2026.9.24)".
m = re.match(r"^Hermes Agent v([0-9][^ (]*)", name)
# v0.21.6+ tags carry the plain version themselves, so the tag is a safe
# fallback when the name shape changes again.
pkgver = m.group(1) if m else clean_tag
print(f"{clean_tag} {pkgver}")
PY
)

if [[ -z "$pkgver" || -z "$clean_tag" ]]; then
    printf 'Could not parse upstream release\n' >&2
    exit 1
fi

log "upstream tag=${clean_tag} pkgver=${pkgver}"

# --- Compare against current PKGBUILD -----------------------------------
current_tag="$(grep -E '^tag=' PKGBUILD | cut -d= -f2)"
current_pkgver="$(grep -E '^pkgver=' PKGBUILD | cut -d= -f2)"
current_sha256="$(sed -n '/^sha256sums=(/,/^)/p' PKGBUILD | grep -Eo "'[0-9a-f]{64}'" | head -1 | tr -d "'")"

# --- Drop obsolete helper files -----------------------------------------
# The AUR clone is synced with `rsync -a` (no --delete), so helper files
# removed from the monorepo would linger in the AUR repo forever. Sweep
# *.patch files the PKGBUILD no longer references (2026-10-14: upstream
# adopted the daemon_pool fix, so the local patch was dropped).
shopt -s nullglob
for f in *.patch; do
    if ! grep -qF -- "$f" PKGBUILD; then
        git rm -q --ignore-unmatch -- "$f" 2>/dev/null || true
        rm -f -- "$f"
        log "dropped obsolete helper: ${f}"
    fi
done
shopt -u nullglob

# Always verify the source checksum. The monorepo may already contain the
# new version while its checksum is still stale, so comparing versions alone
# can incorrectly skip the update.

# --- Download upstream tarball and compute sha256 -----------------------
tar_url="https://github.com/NousResearch/hermes-agent/archive/refs/tags/v${clean_tag}.tar.gz"
tmp_tar="$(mktemp)"
trap 'rm -f "$tmp_meta" "$tmp_tar"' EXIT

log "fetching ${tar_url}"
curl -fsSL -o "$tmp_tar" "$tar_url"
new_sha256="$(sha256sum "$tmp_tar" | awk '{print $1}')"
log "sha256=${new_sha256}"

if [[ "$current_tag" == "$clean_tag" && "$current_pkgver" == "$pkgver" && "$current_sha256" == "$new_sha256" ]]; then
    log "no update (${current_pkgver})"
    exit 0
fi

# --- Mutate PKGBUILD ---------------------------------------------------
# python-hermes-agent has exactly one sha256 entry (the tarball). We use
# Python for safe in-place regex rewriting.
pkgver="${pkgver}" clean_tag="${clean_tag}" new_sha256="${new_sha256}" \
python3 - <<'PY'
import os, re, pathlib
pkgver = os.environ["pkgver"]
clean_tag = os.environ["clean_tag"]
new_sha = os.environ["new_sha256"]
p = pathlib.Path("PKGBUILD")
txt = p.read_text()
txt = re.sub(r"^tag=.*", f"tag={clean_tag}", txt, count=1, flags=re.M)
txt = re.sub(r"^pkgver=.*", f"pkgver={pkgver}", txt, count=1, flags=re.M)
txt = re.sub(r"^pkgrel=.*", "pkgrel=1", txt, count=1, flags=re.M)

def replace_first_hex(m):
    body = m.group(1)
    new_body, n = re.subn(r"'[0-9a-f]{64}'", f"'{new_sha}'", body, count=1)
    return f"sha256sums=({new_body})"

txt = re.sub(r"sha256sums=\((.*?)\)", replace_first_hex, txt, count=1, flags=re.S)
p.write_text(txt)
PY

# --- Regenerate .SRCINFO ----------------------------------------------
# AUR requires .SRCINFO in the same commit as PKGBUILD. We don't ship
# makepkg on GHA, so generate it in pure Python from the existing
# .SRCINFO on disk (which came from the AUR clone), bumping only the
# version and the first sha256sum.
pkgver="${pkgver}" new_sha256="${new_sha256}" clean_tag="${clean_tag}" \
python3 - <<'PY'
import os, re, pathlib, sys

pkgver = os.environ["pkgver"]
clean_tag = os.environ["clean_tag"]
new_sha = os.environ["new_sha256"]

srcinfo_path = pathlib.Path(".SRCINFO")
if not srcinfo_path.exists():
    print("ERROR: .SRCINFO not found in AUR clone (expected from rsync)",
          file=sys.stderr)
    sys.exit(1)

text = srcinfo_path.read_text()

# Update pkgver = X
text, n_ver = re.subn(
    r"^\tpkgver = .*$",
    f"\tpkgver = {pkgver}",
    text, count=1, flags=re.M,
)
if n_ver != 1:
    print(f"ERROR: .SRCINFO pkgver line not updated (matched {n_ver})",
          file=sys.stderr)
    sys.exit(1)

# Update first sha256sums line
text, n_sha = re.subn(
    r"^\tsha256sums = [0-9a-f]{64}$",
    f"\tsha256sums = {new_sha}",
    text, count=1, flags=re.M,
)
if n_sha != 1:
    print(f"ERROR: .SRCINFO first sha256sums line not updated (matched {n_sha})",
          file=sys.stderr)
    sys.exit(1)

# Update source URL if it references the tag literal
text = re.sub(
    r"^\tsource = https://github\.com/NousResearch/hermes-agent/archive/refs/tags/v[0-9][^/]*\.tar\.gz$",
    f"\tsource = https://github.com/NousResearch/hermes-agent/archive/refs/tags/v{clean_tag}.tar.gz",
    text, count=1, flags=re.M,
)

srcinfo_path.write_text(text)
print(f"[hermes] regenerated .SRCINFO (pkgver={pkgver})")
PY

# --- Commit ------------------------------------------------------------
git add PKGBUILD .SRCINFO
git -c user.name='wyf9661' \
    -c user.email='wyf9661@hotmail.com' \
    commit -m "bump python-hermes-agent to ${pkgver} (${clean_tag})" || true

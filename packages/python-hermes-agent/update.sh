#!/usr/bin/env bash
# updater: python-hermes-agent
#
# Upstream source: https://github.com/NousResearch/hermes-agent
# Version scheme: tag is "vYYYY.M.P" (e.g. v2026.7.1); pkgver is the
# Hermes CLI release (e.g. 0.18.0) extracted from the release name
# "Hermes Agent v<ver> (YYYY.M.P) — <codename>".

set -euo pipefail

log() { printf '\033[1;36m[hermes]\033[0m %s\n' "$*"; }

# --- Resolve latest upstream release ------------------------------------
tmp_meta="$(mktemp)"
trap 'rm -f "$tmp_meta"' EXIT

curl -fsSL \
    https://api.github.com/repos/NousResearch/hermes-agent/releases/latest \
    -o "$tmp_meta"

read -r clean_tag pkgver < <(python3 - "$tmp_meta" <<'PY'
import json, sys, re
with open(sys.argv[1]) as f:
    data = json.load(f)
tag = data["tag_name"]
name = data["name"]
clean_tag = tag.lstrip("v")
m = re.match(r"^Hermes Agent v([0-9][^ ]*) ", name)
pkgver = m.group(1) if m else ""
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

if [[ "$current_tag" == "$clean_tag" && "$current_pkgver" == "$pkgver" ]]; then
    log "no update (${current_pkgver})"
    exit 0
fi

# --- Download upstream tarball and compute sha256 -----------------------
tar_url="https://github.com/NousResearch/hermes-agent/archive/refs/tags/v${clean_tag}.tar.gz"
tmp_tar="$(mktemp)"
trap 'rm -f "$tmp_meta" "$tmp_tar"' EXIT

log "fetching ${tar_url}"
curl -fsSL -o "$tmp_tar" "$tar_url"
new_sha256="$(sha256sum "$tmp_tar" | awk '{print $1}')"
log "sha256=${new_sha256}"

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
    return f"sha256sums=({new_body}"

txt = re.sub(r"sha256sums=\((.*?)\)", replace_first_hex, txt, count=1, flags=re.S)
p.write_text(txt)
PY

# --- Regenerate .SRCINFO ----------------------------------------------
# makepkg ships in base-devel, but the .SRCINFO format is stable and
# trivial to regenerate by reading the PKGBUILD directly. We delegate
# to makepkg via Docker on non-Arch runners to keep this hermetic.
regen_srcinfo() {
    if command -v makepkg >/dev/null 2>&1; then
        makepkg --printsrcinfo > .SRCINFO
        return
    fi

    log "makepkg not present — falling back to docker archlinux/base-devel"
    # Strip any CR that bind-mount may have introduced. Local PKGBUILDs are
    # LF-only, but GHA runners occasionally deliver CRLF on the mount.
    if file PKGBUILD | grep -q CRLF; then
        log "stripping CRLF from PKGBUILD"
        tr -d '\r' < PKGBUILD > PKGBUILD.tmp && mv PKGBUILD.tmp PKGBUILD
    fi

    docker run --rm --network=host \
        -v "$PWD:/pkg:z" \
        -w /pkg \
        archlinux:base-devel \
        bash -c '
            pacman -Sy --noconfirm >/dev/null
            useradd -m -s /bin/bash build 2>/dev/null || true
            chown -R build:build /pkg
            su build -c "cd /pkg && makepkg --printsrcinfo > .SRCINFO"
        '
}

regen_srcinfo

# --- Commit ------------------------------------------------------------
git add PKGBUILD .SRCINFO
git -c user.name='wyf9661' \
    -c user.email='wyf9661@hotmail.com' \
    commit -m "bump python-hermes-agent to ${pkgver} (${clean_tag})"

#!/usr/bin/env bash
# updater: 9router-bin
#
# Upstream source: https://registry.npmjs.org/9router
# Version scheme: pkgver == npm version (e.g. 0.5.12).

set -euo pipefail

log() { printf '\033[1;35m[9router]\033[0m %s\n' "$*"; }

# --- Resolve latest npm version ----------------------------------------
tmp_meta="$(mktemp)"
trap 'rm -f "$tmp_meta"' EXIT

curl -fsSL https://registry.npmjs.org/9router/latest -o "$tmp_meta"

eval "$(python3 - "$tmp_meta" <<'PY'
import json, sys, shlex
with open(sys.argv[1]) as f:
    data = json.load(f)
print(f"new_pkgver={shlex.quote(data['version'])}")
print(f"tarball={shlex.quote(data['dist']['tarball'])}")
print(f"integrity={shlex.quote(data['dist']['integrity'])}")
PY
)"

log "upstream version=${new_pkgver}"

# --- Compare against current PKGBUILD ---------------------------------
current_pkgver="$(grep -E '^pkgver=' PKGBUILD | cut -d= -f2)"

if [[ "$current_pkgver" == "$new_pkgver" ]]; then
    log "no update (${current_pkgver})"
    exit 0
fi

# --- Download tarball and compute sha256 ------------------------------
tmp_tar="$(mktemp)"
trap 'rm -f "$tmp_meta" "$tmp_tar"' EXIT

log "fetching ${tarball}"
curl -fsSL -o "$tmp_tar" "$tarball"

new_sha256="$(sha256sum "$tmp_tar" | awk '{print $1}')"
log "sha256=${new_sha256}"

# Defense in depth: verify the npm integrity sha512 matches the bytes.
expected_sha512_hex="$(printf '%s' "$integrity" | sed 's/^sha512-//' | base64 -d | xxd -p -c 256)"
actual_sha512_hex="$(sha512sum "$tmp_tar" | awk '{print $1}')"

if [[ "$expected_sha512_hex" != "$actual_sha512_hex" ]]; then
    printf 'npm integrity mismatch!\n  expected=%s\n  actual  =%s\n' \
        "$expected_sha512_hex" "$actual_sha512_hex" >&2
    exit 1
fi

# --- Mutate PKGBUILD --------------------------------------------------
# 9router-bin uses ${pkgname}-${pkgver}.tgz shell interpolation, so we
# only need to bump pkgver; the source URL string is derived from it at
# build time and never appears as a literal in the file.
new_pkgver="${new_pkgver}" new_sha256="${new_sha256}" \
python3 - <<'PY'
import os, re, pathlib
pkgver = os.environ["new_pkgver"]
new_sha = os.environ["new_sha256"]
p = pathlib.Path("PKGBUILD")
txt = p.read_text()
txt = re.sub(r"^pkgver=.*", f"pkgver={pkgver}", txt, count=1, flags=re.M)
txt = re.sub(r"^pkgrel=.*", "pkgrel=1", txt, count=1, flags=re.M)

def replace_first_hex(m):
    body = m.group(1)
    new_body, _ = re.subn(r"'[0-9a-f]{64}'", f"'{new_sha}'", body, count=1)
    return f"sha256sums=({new_body}"

txt = re.sub(r"sha256sums=\((.*?)\)", replace_first_hex, txt, count=1, flags=re.S)
p.write_text(txt)
PY

# --- Regenerate .SRCINFO ----------------------------------------------
# AUR's git server regenerates .SRCINFO automatically on push (see
# https://docs.aur.archlinux.org/aur-submission.html), so we don't need
# to run makepkg locally — and we explicitly avoid it because invoking
# it inside a Docker container on GitHub Actions has proven unreliable
# (bind-mount / shell-parser edge cases). If you ever need the file for
# local testing, run `makepkg --printsrcinfo > .SRCINFO` on an Arch host.

# --- Commit ------------------------------------------------------------
git add PKGBUILD .SRCINFO 2>/dev/null || git add PKGBUILD
git -c user.name='wyf9661' \
    -c user.email='wyf9661@hotmail.com' \
    commit -m "bump 9router-bin to ${new_pkgver}"

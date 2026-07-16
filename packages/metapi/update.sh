#!/usr/bin/env bash
# updater: metapi
#
# Upstream source: https://github.com/wyf9661/metapi
# Version scheme: GitHub tag "vX.Y.Z" → pkgver=X.Y.Z
# Also ships local helpers: .service/.conf/.install/.sysusers/.tmpfiles

set -euo pipefail

log() { printf '\033[1;32m[metapi]\033[0m %s\n' "$*"; }

# --- Resolve latest upstream release ------------------------------------
tmp_meta="$(mktemp)"
trap 'rm -f "$tmp_meta"' EXIT

curl -fsSL \
    https://api.github.com/repos/wyf9661/metapi/releases/latest \
    -o "$tmp_meta"

read -r tag pkgver < <(python3 - "$tmp_meta" <<'PY'
import json, sys, re
with open(sys.argv[1]) as f:
    data = json.load(f)
tag = data.get("tag_name") or ""
clean = tag.lstrip("v")
# Prefer semver-looking tag; fall back to name
if not re.match(r"^\d+\.\d+", clean):
    m = re.search(r"(\d+\.\d+(?:\.\d+)?)", data.get("name") or "")
    clean = m.group(1) if m else clean
print(f"{tag} {clean}")
PY
)

if [[ -z "$pkgver" || -z "$tag" ]]; then
    printf 'Could not parse upstream release\n' >&2
    exit 1
fi

# normalize tag to v-prefixed form used in PKGBUILD source URL
if [[ "$tag" != v* ]]; then
    tag="v${pkgver}"
fi

log "upstream tag=${tag} pkgver=${pkgver}"

# --- Compare against current PKGBUILD -----------------------------------
current_pkgver="$(grep -E '^pkgver=' PKGBUILD | cut -d= -f2 | tr -d \"\')"
current_pkgrel="$(grep -E '^pkgrel=' PKGBUILD | cut -d= -f2 | tr -d \"\')"

need_bump=1
if [[ "$current_pkgver" == "$pkgver" ]]; then
    log "pkgver already ${pkgver} (pkgrel=${current_pkgrel})"
    need_bump=0
fi

# --- Download upstream tarball and compute sha256 -----------------------
tar_url="https://github.com/wyf9661/metapi/archive/refs/tags/${tag}.tar.gz"
tmp_tar="$(mktemp)"
trap 'rm -f "$tmp_meta" "$tmp_tar"' EXIT

log "fetching ${tar_url}"
curl -fsSL --retry 3 --connect-timeout 20 --max-time 180 -o "$tmp_tar" "$tar_url"
new_tarball_sha256="$(sha256sum "$tmp_tar" | awk '{print $1}')"
log "tarball sha256=${new_tarball_sha256}"

# Helper file hashes (local sources)
hash_file() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "missing helper: $f" >&2
        exit 1
    fi
    sha256sum "$f" | awk '{print $1}'
}

svc_sha="$(hash_file metapi.service)"
conf_sha="$(hash_file metapi.conf)"
install_sha="$(hash_file metapi.install)"
sysusers_sha="$(hash_file metapi.sysusers)"
tmpfiles_sha="$(hash_file metapi.tmpfiles)"

# --- Mutate PKGBUILD ---------------------------------------------------
pkgver="$pkgver" tag="$tag" need_bump="$need_bump" \
new_tarball_sha256="$new_tarball_sha256" \
svc_sha="$svc_sha" conf_sha="$conf_sha" install_sha="$install_sha" \
sysusers_sha="$sysusers_sha" tmpfiles_sha="$tmpfiles_sha" \
python3 - <<'PY'
import os, re, pathlib

pkgver = os.environ["pkgver"]
tag = os.environ["tag"]
need_bump = os.environ["need_bump"] == "1"
sums = [
    os.environ["new_tarball_sha256"],
    os.environ["svc_sha"],
    os.environ["conf_sha"],
    os.environ["install_sha"],
    os.environ["sysusers_sha"],
    os.environ["tmpfiles_sha"],
]

p = pathlib.Path("PKGBUILD")
txt = p.read_text()
txt = re.sub(r"^pkgver=.*", f"pkgver={pkgver}", txt, count=1, flags=re.M)
if need_bump:
    txt = re.sub(r"^pkgrel=.*", "pkgrel=1", txt, count=1, flags=re.M)

# Rewrite full sha256sums array (6 entries: tarball + 5 helpers)
sums_block = "sha256sums=(\n" + "\n".join(f"            '{s}'" for s in sums) + "\n)"
# original uses mixed indentation; match sha256sums=( ... )
if re.search(r"sha256sums=\([^)]*\)", txt, flags=re.S):
    txt = re.sub(r"sha256sums=\([^)]*\)", sums_block, txt, count=1, flags=re.S)
else:
    raise SystemExit("sha256sums block not found")

# Ensure source tarball uses the tag form
txt = re.sub(
    r'(\$\{pkgname\}-v\$\{pkgver\}\.tar\.gz::\$\{url\}/archive/refs/tags/)v?\$\{pkgver\}(\.tar\.gz)',
    r'\1v${pkgver}\2',
    txt,
    count=1,
)

p.write_text(txt)
print(f"[metapi] PKGBUILD updated pkgver={pkgver} need_bump={need_bump}")
PY

# --- Regenerate .SRCINFO ----------------------------------------------
pkgver="$pkgver" \
new_tarball_sha256="$new_tarball_sha256" \
svc_sha="$svc_sha" conf_sha="$conf_sha" install_sha="$install_sha" \
sysusers_sha="$sysusers_sha" tmpfiles_sha="$tmpfiles_sha" \
python3 - <<'PY'
import os, pathlib

pkgver = os.environ["pkgver"]
sums = [
    os.environ["new_tarball_sha256"],
    os.environ["svc_sha"],
    os.environ["conf_sha"],
    os.environ["install_sha"],
    os.environ["sysusers_sha"],
    os.environ["tmpfiles_sha"],
]

# Full regenerate (works for first-time package without existing .SRCINFO)
srcinfo = f"""pkgbase = metapi
	pkgdesc = Meta-layer management and unified proxy for AI API aggregation platforms
	pkgver = {pkgver}
	pkgrel = 1
	url = https://github.com/wyf9661/metapi
	install = metapi.install
	arch = any
	license = MIT
	makedepends = npm
	depends = nodejs>=25
	optdepends = mysql2: MySQL database support
	optdepends = postgresql: PostgreSQL database support
	options = !debug
	backup = etc/metapi/env
	source = metapi-v{pkgver}.tar.gz::https://github.com/wyf9661/metapi/archive/refs/tags/v{pkgver}.tar.gz
	source = metapi.service
	source = metapi.conf
	source = metapi.install
	source = metapi.sysusers
	source = metapi.tmpfiles
	sha256sums = {sums[0]}
	sha256sums = {sums[1]}
	sha256sums = {sums[2]}
	sha256sums = {sums[3]}
	sha256sums = {sums[4]}
	sha256sums = {sums[5]}

pkgname = metapi
"""
pathlib.Path(".SRCINFO").write_text(srcinfo)
print(f"[metapi] regenerated .SRCINFO (pkgver={pkgver})")
PY

# If nothing changed vs current git tree, still allow wrapper to commit rsync sync.
if git diff --quiet -- PKGBUILD .SRCINFO 2>/dev/null; then
    log "PKGBUILD/.SRCINFO content already up to date"
fi

# --- Commit ------------------------------------------------------------
git add PKGBUILD .SRCINFO metapi.service metapi.conf metapi.install metapi.sysusers metapi.tmpfiles 2>/dev/null || true
git -c user.name='wyf9661' \
    -c user.email='wyf9661@hotmail.com' \
    commit -m "bump metapi to ${pkgver}" || true

log "done"

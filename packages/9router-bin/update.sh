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
    return f"sha256sums=({new_body})"

txt = re.sub(r"sha256sums=\((.*?)\)", replace_first_hex, txt, count=1, flags=re.S)
p.write_text(txt)
PY

# --- Regenerate .SRCINFO ----------------------------------------------
# AUR requires .SRCINFO in the same commit as PKGBUILD. We don't ship
# makepkg on GHA, so generate it in pure Python from the existing
# .SRCINFO on disk (which came from the AUR clone), bumping only the
# version and the first sha256sum.
new_pkgver="${new_pkgver}" new_sha256="${new_sha256}" \
python3 - <<'PY'
import os, re, pathlib, sys

pkgver = os.environ["new_pkgver"]
new_sha = os.environ["new_sha256"]

srcinfo_path = pathlib.Path(".SRCINFO")
if not srcinfo_path.exists():
    print("ERROR: .SRCINFO not found in AUR clone (expected from rsync)",
          file=sys.stderr)
    sys.exit(1)

text = srcinfo_path.read_text()

# Update pkgver = X (only first occurrence, in the pkgbase block)
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

# Update source= lines that reference the tarball literal. 9router-bin's
# AUR-side .SRCINFO has `source = 9router-bin-0.5.12.tgz::https://...`
# (with both a local filename and a remote URL joined by `::`).
text = re.sub(
    r"^\tsource = 9router-bin-[0-9][^\s]*\.tgz::https://registry\.npmjs\.org/9router/-/9router-[0-9][^\s]*$",
    f"\tsource = 9router-bin-{pkgver}.tgz::"
    f"https://registry.npmjs.org/9router/-/9router-{pkgver}.tgz",
    text, count=1, flags=re.M,
)

# Drop source= lines that reference files we no longer ship.
# Currently: fix-tokenplan-*.py (dropped in upstream commit 9102c4c).
for obsolete in ("fix-tokenplan-region.py", "fix-tokenplan-ui-region.py"):
    text, _ = re.subn(
        rf"^\tsource = {re.escape(obsolete)}$\n",
        "",
        text, flags=re.M,
    )

# Drop the matching sha256sums entries.  The AUR-side SRCINFO currently
# has 6 sha256sums lines for the OLD PKGBUILD (which still had the two
# fix scripts).  After we removed them we want 4 entries: tarball,
# 9router.sh, 9router.service, .env.example.  We trim from the end of
# the list — those are the helper-file hashes.
#
# Decide how many to keep by counting source= lines that remain.
remaining_sources = re.findall(r"^\tsource = .+$", text, flags=re.M)
target_sha_count = len(remaining_sources)

all_shas = list(re.finditer(r"^\tsha256sums = ([0-9a-f]{64})$", text, flags=re.M))
if len(all_shas) > target_sha_count:
    new_text = text
    for m in reversed(all_shas[target_sha_count:]):
        new_text = new_text[:m.start()] + new_text[m.end():]
    text = new_text

srcinfo_path.write_text(text)
print(f"[9router] regenerated .SRCINFO (pkgver={pkgver})")
PY

# --- Commit ------------------------------------------------------------
git add PKGBUILD .SRCINFO
git -c user.name='wyf9661' \
    -c user.email='wyf9661@hotmail.com' \
    commit -m "bump 9router-bin to ${new_pkgver}"

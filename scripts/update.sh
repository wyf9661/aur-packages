#!/usr/bin/env bash
# Shared updater for AUR packages maintained in this monorepo.
#
# Usage:
#   update.sh <package-dir-relative-to-repo-root>
#   e.g. update.sh packages/python-hermes-agent
#
# Contract:
#   <repo-root>/<package-dir>/update.sh — package-specific logic that:
#     1. resolves latest upstream version
#     2. exits 0 with "no update" if PKGBUILD already matches
#     3. mutates PKGBUILD/.SRCINFO and commits in the AUR clone otherwise
#
# This wrapper handles SSH setup, AUR clone/pull, file sync and commit/push.

set -euo pipefail

PKG_REL="${1:?usage: update.sh <package-dir-relative-to-repo-root>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="${REPO_ROOT}/${PKG_REL}"
WORKSPACE_DIR="${AUR_WORKSPACE:-/tmp/aur-workspace}"

log() { printf '\033[1;34m[update]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[update]\033[0m %s\n' "$*" >&2; }

# --- SSH setup ---------------------------------------------------------
# GHA runners can reach aur.archlinux.org:22; the user cannot.
# AUR_SSH_KEY (base64 of OpenSSH private key) is wired in by the workflow.
# Workflow also pre-populates known_hosts via webfactory/ssh-agent.

if [[ -n "${AUR_SSH_KEY:-}" ]]; then
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    if ! grep -q "Host aur.archlinux.org" ~/.ssh/config 2>/dev/null; then
        cat >> ~/.ssh/config <<'EOF'

Host aur.archlinux.org
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    User aur
EOF
    fi

    printf '%s' "$AUR_SSH_KEY" | base64 -d > ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
fi

# --- AUR clone/pull ---------------------------------------------------
# Resolve pkgbase via shell-style variable expansion of PKGBUILD. We
# source it in a subshell with `set -e` disabled so any parse glitches
# fall through to the raw pkgname= line.
PKGBASE="$(bash -c '
    set +e
    # shellcheck disable=SC1090
    source "$1" 2>/dev/null
    if [[ -n "${pkgbase:-}" ]]; then
        echo "$pkgbase"
    elif [[ -n "${pkgname:-}" ]]; then
        echo "$pkgname"
    fi
' -- "${PKG_DIR}/PKGBUILD" 2>/dev/null)"

# Fallback: take the first pkgname= line as-is (handles pkgs that mix
# shell vars in pkgname=).
if [[ -z "$PKGBASE" ]]; then
    PKGBASE="$(grep -E '^pkgname=' "${PKG_DIR}/PKGBUILD" | head -1 | cut -d= -f2- | tr -d \"\')"
fi

if [[ -z "$PKGBASE" ]]; then
    err "Could not determine pkgbase from ${PKG_DIR}/PKGBUILD"
    exit 1
fi

# Expose pkgbase to caller (workflow step reads it from $GITHUB_ENV).
# Only meaningful in GHA; harmless elsewhere.
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "AUR_PKGBASE=${PKGBASE}" >> "$GITHUB_ENV"
fi

AUR_REMOTE="aur@aur.archlinux.org:${PKGBASE}.git"

# --- AUR workspace acquisition -----------------------------------------
# AUR has been under a malicious-packages incident since 2026-06: the
# git-over-SSH READ path (clone/fetch/upload-pack) is refused with
# "The AUR is down due to maintenance", while authenticated pushes still
# work. Fall back to cgit HTTPS snapshots for the read side; per-package
# updaters and the push logic below are unchanged.
fetch_aur_snapshot() {
    local dir="$1"
    local tmp
    tmp="$(mktemp)"
    log "SSH clone/pull refused; fetching cgit HTTPS snapshot for ${PKGBASE}"
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
        "https://aur.archlinux.org/cgit/aur.git/snapshot/${PKGBASE}.tar.gz" \
        -o "$tmp" || { err "cgit snapshot download failed for ${PKGBASE}"; rm -f "$tmp"; return 1; }
    # Snapshot extracts to ${PKGBASE}/; replace the workspace copy.
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    tar -xzf "$tmp" -C "$(dirname "$dir")"
    rm -f "$tmp"
    if [[ ! -d "$dir/.git" ]]; then
        git -C "$dir" init -q
        git -C "$dir" remote add origin "$AUR_REMOTE" 2>/dev/null || true
        git -C "$dir" add -A
        git -C "$dir" -c user.name='wyf9661' \
            -c user.email='wyf9661@hotmail.com' \
            commit -q -m "sync: AUR snapshot" || true
    fi
    log "Snapshot restored for ${PKGBASE}"
}

if [[ -d "${WORKSPACE_DIR}/${PKGBASE}/.git" ]]; then
    log "Pulling existing clone of ${PKGBASE}"
    (cd "${WORKSPACE_DIR}/${PKGBASE}" && git pull --rebase --autostash) \
        || fetch_aur_snapshot "${WORKSPACE_DIR}/${PKGBASE}"
else
    log "Cloning ${PKGBASE} from AUR"
    git clone "$AUR_REMOTE" "${WORKSPACE_DIR}/${PKGBASE}" \
        || fetch_aur_snapshot "${WORKSPACE_DIR}/${PKGBASE}"
fi

# Sync files from monorepo into AUR clone. The monorepo is the source
# of truth for everything; the AUR clone is a transient staging area
# we mutate and push from.
#
# IMPORTANT: no --delete here. The AUR clone carries .SRCINFO, which
# is generated from PKGBUILD at AUR-side build time and is NOT in our
# monorepo. Dropping it would force every run to regenerate from
# scratch.
mkdir -p "${WORKSPACE_DIR}/${PKGBASE}"
rsync -a \
    --exclude='.git' \
    --exclude='update.sh' \
    "${PKG_DIR}/" "${WORKSPACE_DIR}/${PKGBASE}/"

# --- Delegate to package-specific updater -----------------------------
(
    cd "${WORKSPACE_DIR}/${PKGBASE}"
    bash "${PKG_DIR}/update.sh"
)

# --- Push --------------------------------------------------------------
# Two scenarios produce pushable commits:
#   1. Updater found a new upstream version and bumped PKGBUILD/.SRCINFO
#   2. Updater short-circuited (no upstream bump) but monorepo's
#      PKGBUILD/helpers differ from AUR's (e.g. we fixed a syntax bug
#      locally). In that case rsync above already staged the diff; we
#      just need to commit and push it.
(
    cd "${WORKSPACE_DIR}/${PKGBASE}"

    # Monorepo-only packaging fixes can change pkgrel without a new upstream
    # version. AUR's package database reads pkgrel from .SRCINFO, not directly
    # from PKGBUILD; keep it in sync before deciding whether there is anything
    # to commit. This is intentionally narrow (pkgrel only) because version
    # bumps still use the package-specific .SRCINFO regenerators above.
    if [[ -f PKGBUILD && -f .SRCINFO ]]; then
        pkgrel="$(bash -c '
            set +e
            source "$1" 2>/dev/null
            printf "%s" "${pkgrel:-}"
        ' -- PKGBUILD 2>/dev/null)"
        if [[ -n "$pkgrel" ]] && ! grep -qE "^[[:space:]]*pkgrel = ${pkgrel}$" .SRCINFO; then
            pkgrel="$pkgrel" python3 - <<'PY'
import os, pathlib, re, sys

path = pathlib.Path('.SRCINFO')
text = path.read_text()
pkgrel = os.environ['pkgrel']
text, n = re.subn(r'^\tpkgrel = .+$', f'\tpkgrel = {pkgrel}', text, count=1, flags=re.M)
if n != 1:
    print(f'ERROR: .SRCINFO pkgrel line not updated (matched {n})', file=sys.stderr)
    sys.exit(1)
path.write_text(text)
PY
            log "Synced .SRCINFO pkgrel=${pkgrel} from PKGBUILD"
        fi
    fi

    # If the updater already committed, those are unpushed commits.
    # If it didn't (no-op), rsync may still have left unstaged changes
    # from monorepo → AUR clone sync. Commit those first.
    if [[ -n "$(git status --porcelain)" ]]; then
        log "Committing monorepo-synced changes (no upstream bump needed)"
        git add -A
        git -c user.name='wyf9661' \
            -c user.email='wyf9661@hotmail.com' \
            commit -m "sync: monorepo PKGBUILD/helpers" || true
    fi

    branch="$(git rev-parse --abbrev-ref HEAD)"
    if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "$AUR_REMOTE"
    fi
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        # Snapshot workspace: a single commit means the tree is identical
        # to what AUR already has (no rsync diff, no bump) — nothing to
        # push, and forcing would just rewrite history for no change.
        commit_count="$(git rev-list --count HEAD)"
        if [[ "$commit_count" -le 1 ]]; then
            log "No changes vs AUR snapshot — nothing to push"
            exit 0
        fi
        # AUR's SSH git service is refused during the malicious-packages
        # incident (2026-06+). Push retries are deliberately LOW-FREQUENCY:
        # the user asked not to hammer AUR and risk being flagged as
        # malicious. Attempt the push a few times with a long pause, then
        # give up for this run — the daily schedule will try again later.
        attempt=0
        pushed=0
        while [[ "$attempt" -lt 3 ]]; do
            attempt=$((attempt + 1))
            if git push -u origin "HEAD:${branch}" 2>&1 \
               || git push --force -u origin "HEAD:${branch}" 2>&1; then
                log "Pushed to AUR (attempt ${attempt})"
                pushed=1
                break
            fi
            if [[ "$attempt" -lt 3 ]]; then
                log "push attempt ${attempt}/3 failed; waiting 60s before next try"
                sleep 60
            fi
        done
        if [[ "$pushed" -eq 0 ]]; then
            err "push failed after 3 attempts — AUR incident still blocking; will retry on next scheduled run"
            exit 1
        fi
    else
        log "Nothing to push (empty history)"
    fi
)

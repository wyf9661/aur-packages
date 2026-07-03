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

AUR_REMOTE="aur@aur.archlinux.org:${PKGBASE}.git"

mkdir -p "$WORKSPACE_DIR"
if [[ -d "${WORKSPACE_DIR}/${PKGBASE}/.git" ]]; then
    log "Pulling existing clone of ${PKGBASE}"
    (cd "${WORKSPACE_DIR}/${PKGBASE}" && git pull --rebase --autostash)
else
    log "Cloning ${PKGBASE} from AUR"
    git clone "$AUR_REMOTE" "${WORKSPACE_DIR}/${PKGBASE}"
fi

# Sync files from monorepo into AUR clone. The monorepo is the source
# of truth for PKGBUILD + helpers; package-specific update.sh handles
# version bumps.
#
# IMPORTANT: no --delete here. The AUR clone carries .SRCINFO, which
# is generated from PKGBUILD at AUR-side build time and is NOT in our
# monorepo. Dropping it would force every run to regenerate from
# scratch.
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
(
    cd "${WORKSPACE_DIR}/${PKGBASE}"
    # Set up upstream tracking on first run so @{u} resolves.
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || \
        git branch --set-upstream-to="$AUR_REMOTE/$(git rev-parse --abbrev-ref HEAD)" HEAD

    unpushed="$(git log '@{u}..HEAD' --oneline 2>/dev/null || true)"
    if [[ -n "$unpushed" ]]; then
        log "Pushing to AUR: $(echo "$unpushed" | wc -l) commit(s)"
        git push
    else
        log "Nothing to push (no new commits)"
    fi
)

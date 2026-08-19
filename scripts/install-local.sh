#!/usr/bin/env bash
# install-local.sh — Install the locally built binary over the one your editor uses.
#
# Usage:
#   scripts/install-local.sh                    # build if needed, back up, install
#   scripts/install-local.sh --no-build         # install whatever is already built
#   scripts/install-local.sh --dir ~/bin        # install somewhere other than ~/.local/bin
#   scripts/install-local.sh --dry-run          # show what would happen, change nothing
#   scripts/install-local.sh --help
#
# Why this exists: `scripts/build.sh` produces build/c/codebase-memory-mcp, but the
# MCP server your editor launches is a DIFFERENT file (usually ~/.local/bin/…).
# Until that one is replaced, none of your local changes are visible through the
# MCP tools — you can spend a long time reading graph output produced by a binary
# from weeks ago.
#
# Replacing the binary is delegated to the product's own `install` subcommand,
# which is transactional and already knows how to overwrite an executable that is
# currently running. This script adds what it does not: a timestamped backup you
# can roll back to, and a clear report of what changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BUILD=1
DRY_RUN=0
BIN_DIR="${HOME}/.local/bin"
BUILT="${PROJECT_DIR}/build/c/codebase-memory-mcp"

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help | -h) usage ;;
        --no-build) BUILD=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --dir)
            [ $# -ge 2 ] || { echo "error: --dir requires a path" >&2; exit 2; }
            BIN_DIR="$2"
            shift
            ;;
        --dir=*) BIN_DIR="${1#--dir=}" ;;
        *)
            echo "error: unknown option: $1 (try --help)" >&2
            exit 2
            ;;
    esac
    shift
done

[ -n "$BIN_DIR" ] || { echo "error: install directory is empty" >&2; exit 2; }
TARGET="${BIN_DIR}/codebase-memory-mcp"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  would run: $*"
    else
        "$@"
    fi
}

echo "==> target: ${TARGET}"

# ── Build ────────────────────────────────────────────────────────────
# Deliberately not `make -C`: Makefile.cbm resolves paths against the working
# directory, so the build must run from the project root.
if [ "$BUILD" -eq 1 ]; then
    echo "==> building (pass --no-build to skip)"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  would run: make -f Makefile.cbm cbm"
    else
        (cd "$PROJECT_DIR" && make -f Makefile.cbm cbm)
    fi
fi

if [ ! -x "$BUILT" ]; then
    echo "error: no built binary at ${BUILT}" >&2
    echo "       run scripts/build.sh, or drop --no-build" >&2
    exit 1
fi

NEW_VERSION="$("$BUILT" --version 2>/dev/null | head -1 || echo 'unknown')"
echo "==> built:   ${NEW_VERSION}"

# ── Warn about live processes ────────────────────────────────────────
# Not fatal. The installer replaces the directory entry rather than writing
# through it, so a running process keeps its own open inode and is unaffected —
# but it also keeps the OLD behaviour until it restarts, which is exactly the
# confusion this script exists to prevent. Say so plainly.
LIVE="$(pgrep -f "${TARGET}" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${LIVE:-0}" -gt 0 ]; then
    echo "==> note:    ${LIVE} process(es) are running the installed binary."
    echo "             They keep the old build until restarted. Restart your"
    echo "             editor / MCP client afterwards to pick this one up."
fi

# ── Back up ─────────────────────────────────────────────────────────
if [ -e "$TARGET" ]; then
    OLD_VERSION="$("$TARGET" --version 2>/dev/null | head -1 || echo 'unknown')"
    BACKUP="${TARGET}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "==> current: ${OLD_VERSION}"
    echo "==> backup:  ${BACKUP}"
    run cp -p "$TARGET" "$BACKUP"
else
    echo "==> current: (nothing installed at that path)"
    run mkdir -p "$BIN_DIR"
fi

# ── Install ─────────────────────────────────────────────────────────
# `install` is the product's own transactional installer: it copies itself
# safely even when the destination is executing, and refreshes the editor MCP
# entries and skills that a plain `cp` would leave stale.
echo "==> installing"
run "$BUILT" install --dir "$BIN_DIR" --yes

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> dry run: nothing changed"
    exit 0
fi

INSTALLED_VERSION="$("$TARGET" --version 2>/dev/null | head -1 || echo 'unknown')"
echo "==> installed: ${INSTALLED_VERSION}"

if [ "$INSTALLED_VERSION" != "$NEW_VERSION" ]; then
    echo "error: installed binary reports '${INSTALLED_VERSION}', expected '${NEW_VERSION}'" >&2
    echo "       the copy did not take effect; the backup above is still good" >&2
    exit 1
fi

echo
echo "Done. Restart your editor / MCP client so it launches the new binary."
echo "Re-index a project to pick up extraction changes:"
echo "  ${TARGET} cli index_repository --repo-path <path> --name <project> --mode full"
echo
echo "To roll back:"
echo "  cp -p ${TARGET}.backup-<timestamp> ${TARGET}"

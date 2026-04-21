#!/bin/bash
# =============================================================================
# sync-upstream.sh — pull latest CLIProxyAPI source into vendor/cliproxyapi/
# =============================================================================
# Uses `git subtree pull` to refresh the vendored source tree to the latest
# commit on the upstream `main` branch. Commits a merge+squash onto HEAD of
# your current branch.
#
# Usage:
#   ./scripts/sync-upstream.sh           # pull latest main
#   ./scripts/sync-upstream.sh <ref>     # pull a specific branch/tag/sha
#
# After pulling, re-run the installer or just `go build` inside vendor/cliproxyapi
# to pick up the new code. See README.md for more.
# =============================================================================

set -euo pipefail

UPSTREAM_URL="https://github.com/router-for-me/CLIProxyAPI.git"
PREFIX="vendor/cliproxyapi"
REF="${1:-main}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: working tree has uncommitted changes. Commit or stash first." >&2
  exit 1
fi

echo "Pulling $UPSTREAM_URL $REF into $PREFIX ..."
git subtree pull --prefix="$PREFIX" "$UPSTREAM_URL" "$REF" --squash

echo ""
echo "Upstream sync complete."
echo "  Vendored commit: $(git -C . log -1 --format=%h -- "$PREFIX")"
echo "  Run 'bash setup.sh' (macOS) or 'bash setup-linux.sh' (Linux) to rebuild."

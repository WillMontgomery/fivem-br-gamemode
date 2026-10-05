#!/usr/bin/env bash
#
# Installs the repo's git hooks.
#
# Hooks live in tools/ rather than .git/hooks because .git/ is not tracked --
# a hook that only exists on one machine protects only that machine.
#
#   ./tools/install-hooks.sh
#
# Copies them where git reads hooks from: .git/hooks in an ordinary checkout,
# the main checkout's in a linked worktree (hooks are shared), or
# core.hooksPath when that is set.
#
# pre-push takes its gates with it: check_asset_files.sh and check_secrets.sh
# are copied into <hooks>/pre-push-gates/, and the hook runs those copies, so
# every worktree sharing these hooks gets the same gates whatever its own
# tools/ holds (#391). Run this again after either gate changes.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

hooks="$(git rev-parse --git-path hooks)"
mkdir -p "$hooks/pre-push-gates"
# The gates first: a hook installed without them refuses every push.
for g in check_asset_files.sh check_secrets.sh; do
    cp "tools/$g" "$hooks/pre-push-gates/$g"
    cmp -s "tools/$g" "$hooks/pre-push-gates/$g"
    echo "installed $hooks/pre-push-gates/$g"
done
for h in pre-commit pre-push; do
    cp "tools/$h" "$hooks/$h"
    chmod +x "$hooks/$h"
    cmp -s "tools/$h" "$hooks/$h"
    echo "installed $hooks/$h"
done

echo
echo "pre-commit blocks a commit when:"
echo "  * ui-src/src changed but the built bundle did not"
echo "  * ui-src/terminal changed but the built terminal app did not"
echo "  * server.cfg or node_modules is staged"
echo "  * tools/verify.sh fails"
echo
echo "pre-push blocks a push whose commits hold a game-asset file outside"
echo "the allowlist, or anything credential-shaped (#391)."
echo
echo "Bypass a single commit or push with --no-verify."

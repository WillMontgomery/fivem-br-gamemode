#!/usr/bin/env bash
#
# Installs the repo's git hooks.
#
# Hooks live in tools/ rather than .git/hooks because .git/ is not tracked --
# a hook that only exists on one machine protects only that machine.
#
#   ./tools/install-hooks.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

mkdir -p .git/hooks
cp tools/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

echo "installed .git/hooks/pre-commit"
echo
echo "It blocks a commit when:"
echo "  * ui-src/src changed but the built bundle did not"
echo "  * server.cfg or node_modules is staged"
echo "  * tools/verify.sh fails"
echo
echo "Bypass a single commit with: git commit --no-verify"

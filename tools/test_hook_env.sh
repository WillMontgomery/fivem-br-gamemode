#!/usr/bin/env bash
#
# tools/test_hook_env.sh -- the scratch repos the gate builds stay scratch when
# the gate runs inside a git hook.
#
# WHY. A cherry-pick --continue (or rebase --continue, or a commit without
# --no-verify) runs the pre-commit hook, which runs verify.sh. Inside a hook git
# exports GIT_DIR and GIT_INDEX_FILE, pointed at the repo being committed, and
# every git a check starts inherits them -- so a check that builds a scratch
# repo with `git init` and `git config` builds it IN THE REAL ONE. On
# 2026-10-07 check_spelling.sh's self-test did exactly that: the real repo came
# out bare, its user "self-test", and every checkout of it refused to run git.
# (tools/test_assets.py had met the same thing on 2026-10-06, through the
# index, and drops those variables at import.)
#
# WHAT. A decoy repo stands in for the one being committed. With GIT_DIR and
# GIT_INDEX_FILE pointed at it, as a hook would have them, this runs
# check_spelling.sh's self-test and test_assets.py's scratch-repo tests (the
# AssetFileGate class; test_deploy.py imports test_assets.py and so gets the
# same guard), then checks that the decoy's config, refs, index and objects are
# byte for byte what they were, and that both still pass.
#
# Prints one ok/FAIL line per check, like check_spelling.sh. Exit 1 on a FAIL.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
rc=0
ok()   { echo "${GRN}ok${RST}   $1"; }
fail() { echo "${RED}FAIL${RST} test_hook_env.sh: $1"; rc=1; }

if command -v py >/dev/null 2>&1; then PY=(py -3)
elif command -v python3 >/dev/null 2>&1; then PY=(python3)
else PY=(python); fi

# Every repo-local variable git names, so the decoy itself and the snapshots
# are made by a git that finds its repo the ordinary way.
# shellcheck disable=SC2046
plain() { ( unset $(git rev-parse --local-env-vars); "$@" ); }

decoy=$(mktemp -d "${TMPDIR:-/tmp}/hook_env.XXXXXX" 2>/dev/null) || { fail 'no scratch directory'; exit 1; }
trap 'rm -rf "$decoy" 2>/dev/null || true' EXIT

if ! plain bash -c '
    set -e
    cd "$1"
    git init -q .
    git config user.name decoy
    git config user.email decoy@example.invalid
    echo decoy > f
    git add f
    git commit -q -m decoy
' _ "$decoy" >/dev/null 2>&1; then
    fail 'could not build the decoy repo'
    exit 1
fi

snapshot() {
    plain bash -c '
        cd "$1"
        cat .git/config
        git for-each-ref
        git rev-parse HEAD
        git ls-files -s
        find .git/objects -type f | sort
        ls .git
    ' _ "$decoy" 2>&1
}
before=$(snapshot)

# --- as a hook runs them ------------------------------------------------------

spell_out=$(GIT_DIR="$decoy/.git" GIT_INDEX_FILE="$decoy/.git/index" \
    bash tools/check_spelling.sh --self-test 2>&1); spell_rc=$?

py_out=$(GIT_DIR="$decoy/.git" GIT_INDEX_FILE="$decoy/.git/index" "${PY[@]}" - <<'PY' 2>&1
import io, os, sys, unittest
sys.path.insert(0, 'tools')
import test_assets
left = [v for v in ('GIT_DIR', 'GIT_INDEX_FILE') if v in os.environ]
suite = unittest.defaultTestLoader.loadTestsFromTestCase(test_assets.AssetFileGate)
result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
for _, trace in result.failures + result.errors:
    print(trace)
print('LEFT %d RAN %d BAD %d' % (len(left), result.testsRun, len(result.failures) + len(result.errors)))
PY
); py_rc=$?

after=$(snapshot)

# --- what they left ---------------------------------------------------------

if [ "$spell_rc" -eq 0 ]; then
    ok "check_spelling.sh --self-test passes with a hook's GIT_DIR and GIT_INDEX_FILE set"
else
    fail "check_spelling.sh --self-test failed with a hook's GIT_DIR set (exit $spell_rc):"
    printf '%s\n' "$spell_out" | tail -5
fi

case "$py_out" in
    *'LEFT 0 RAN '*' BAD 0'*)
        if [ "$py_rc" -eq 0 ]; then
            ok "test_assets.py drops a hook's git variables at import, and its scratch-repo tests pass"
        else
            fail "test_assets.py's scratch-repo tests exited $py_rc"
        fi ;;
    *)
        fail "test_assets.py under a hook's GIT_DIR:"
        printf '%s\n' "$py_out" | tail -8 ;;
esac

if [ "$before" = "$after" ]; then
    ok "the repo a hook names is untouched: config, refs, HEAD, index and objects as they were"
else
    fail "the repo a hook names was changed by a scratch-repo check:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -12
fi

exit $rc

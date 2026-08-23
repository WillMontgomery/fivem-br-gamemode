#!/usr/bin/env bash
#
# br_ddb source fingerprint -- record what source the committed bundle was
# built from, and check that the source still says the same thing.
#
#   ./tools/br_ddb_fingerprint.sh           rewrite the manifest (do this after
#                                           a real `npm run build`)
#   ./tools/br_ddb_fingerprint.sh --check   compare; exit 1 on drift (verify.sh)
#   ./tools/br_ddb_fingerprint.sh --print    print both hashes and stop
#
# WHY A HASH INSTEAD OF A REBUILD (#218)
#
# verify.sh used to rebuild js-src/br_ddb with esbuild and diff the result
# against the committed bundle. That gate has never once executed: it needs
# js-src/br_ddb/node_modules, which nobody has, so it printed
#
#   skip  js-src/br_ddb/node_modules absent
#
# on every machine for as long as anyone has looked. Installing the deps does
# not fix it -- it makes the gate FAIL, on a package-exports problem inside the
# AWS SDK's own dependency tree under Node 24
# (`Could not resolve "@aws-sdk/middleware-sdk-s3/s3"`). A false red is worse
# than no gate, because it is indistinguishable from real drift.
#
# So the check moved to something that needs no toolchain at all: sha256 over
# the source tree, recorded beside the bundle, recomputed by verify.sh. It is a
# weaker statement than a rebuild, and it has been running since the day it
# landed, which the strong one never did.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
#
#   IT PROVES:      the bundle in dist/ is the one that was recorded against
#                   THIS source. Edit js-src/br_ddb/src and forget to rebuild,
#                   and verify.sh goes red before the stale bundle ships.
#
#   IT DOES NOT PROVE THE BUNDLE IS CORRECT. Nothing here reads the bundle's
#                   contents or compiles anything. If the recorded rebuild was
#                   run against a broken source, the hash agrees enthusiastically.
#
#   IT IS A MISTAKE DETECTOR, NOT A TAMPER DETECTOR. Do not describe it as
#                   security anywhere. The manifest sits next to the bundle in
#                   the same directory, in the same commit, writable by exactly
#                   the same people -- anyone who can change one can change the
#                   other, and this script will hand them a fresh hash for it.
#                   It catches forgetting, not lying.
#
#   REFRESHING THE MANIFEST IS A CLAIM, NOT A PROOF. Running this script with
#                   no arguments records "these two files belong together"
#                   because the person running it says so. It cannot tell a
#                   rebuild from a refresh. That is the price of not needing a
#                   toolchain.
#
#   A DEPENDENCY BUMP IS INVISIBLE HERE. The AWS SDK is flattened INTO the
#                   bundle, so its version changes the bundle's bytes -- but
#                   package-lock.json is deliberately not hashed (see below), so
#                   changing the pinned SDK and not rebuilding will not go red.
#                   Known blind spot, stated rather than papered over.
#
# THE HASHING SCHEME  (scheme id: br_ddb-source-fingerprint-1)
#
#   1. THE FILE SET is the files that actually feed the bundle:
#
#        js-src/br_ddb/src/**        every file, any extension
#        js-src/br_ddb/package.json  entry deps and the build/check scripts
#        js-src/br_ddb/scripts/build.mjs
#                                    the build itself -- target, format, minify
#                                    and the IIFE wrap all change the output
#
#      NOT node_modules (not committed, platform-specific, enormous).
#      NOT scripts/test.mjs -- it tests the source, it does not feed the bundle,
#      and a test-only edit going red would be a false positive that teaches
#      people to ignore this gate.
#      NOT package-lock.json -- npm rewrites it on metadata changes alone, and
#      churn on a gate is how gates die. The cost of that choice is the blind
#      spot named above.
#
#      ADDING A BUILD INPUT OUTSIDE src/ MEANS EDITING source_files() BELOW. A
#      new esbuild config or plugin that nothing here hashes is a hole in the
#      gate that looks exactly like a passing gate.
#
#   2. EACH FILE is hashed on its own, with every CR byte deleted first. This
#      repo is authored on Windows and runs on Linux; .gitattributes normalises
#      to LF, but core.autocrlf is on and an editor that writes CRLF anyway must
#      not turn into fake drift on somebody else's machine. Deleting every CR
#      rather than only line-terminating ones is cruder than a real CRLF->LF
#      conversion, and it is chosen on purpose: it is identical on every
#      platform, and unlike a sed-based fixup it cannot depend on whether the
#      last line ends in a newline. These are JS sources; a lone CR in one would
#      be a bug of its own.
#
#   3. THE PATH TRAVELS WITH THE HASH. Each file contributes the line
#
#        <sha256 of its CR-stripped bytes><two spaces><repo-relative path>
#
#      so renaming a file changes the fingerprint even though its bytes did not,
#      and two files swapping contents does not cancel out.
#
#   4. THE LINES ARE SORTED under LC_ALL=C -- byte order, not locale order, so
#      the same tree hashes the same on a machine with a different LANG. That
#      sorted block is hashed once more, and THAT is the fingerprint.
#
#   5. THE BUNDLE gets the same CR-stripped sha256, recorded alongside, so that
#      hand-patching dist/server.js without refreshing the manifest also goes
#      red.
#
#   THE MANIFEST CARRIES NO TIMESTAMP, so re-running this on an unchanged tree
#   rewrites byte-identical content and leaves `git status` clean. A field that
#   changes every run would make the manifest look modified when nothing was.
#
# No jq, no node, no python: sha256sum (or shasum, or openssl) and a shell.

set -uo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[31m'; RST=$'\033[0m'

SRC_DIR="js-src/br_ddb"
BUNDLE="resources/[fivem-royale]/br_ddb/dist/server.js"
MANIFEST="resources/[fivem-royale]/br_ddb/dist/fingerprint.json"
SCHEME="br_ddb-source-fingerprint-1"

mode="write"
case "${1:-}" in
    --check) mode="check" ;;
    --print) mode="print" ;;
    "")      mode="write" ;;
    *)       echo "usage: $0 [--check|--print]" >&2; exit 2 ;;
esac

# --- a sha256 that exists everywhere -----------------------------------------
#
# NOT A SKIP IF NONE IS FOUND. The lesson of #218 is that a gate which excuses
# itself is a gate nobody notices is gone, so a box with no hasher gets a hard
# error naming the three that would work.

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 | cut -d' ' -f1; }
elif command -v openssl >/dev/null 2>&1; then
    # Prints "SHA2-256(stdin)= <hex>" or "(stdin)= <hex>" depending on version.
    sha256() { openssl dgst -sha256 | sed 's/.*= *//'; }
else
    echo "${RED}br_ddb fingerprint: no sha256 available.${RST}" >&2
    echo "  Needs one of: sha256sum, shasum, openssl." >&2
    exit 2
fi

# --- the file set -------------------------------------------------------------

source_files() {
    {
        find "$SRC_DIR/src" -type f
        printf '%s\n' "$SRC_DIR/package.json"
        printf '%s\n' "$SRC_DIR/scripts/build.mjs"
    } | LC_ALL=C sort
}

source_fingerprint() {
    source_files | while IFS= read -r f; do
        printf '%s  %s\n' "$(tr -d '\r' < "$f" | sha256)" "$f"
    done | sha256
}

# --- preconditions ------------------------------------------------------------

missing=0
if [ ! -d "$SRC_DIR/src" ]; then
    echo "${RED}br_ddb fingerprint: no $SRC_DIR/src${RST}" >&2
    missing=1
fi
for f in "$SRC_DIR/package.json" "$SRC_DIR/scripts/build.mjs" "$BUNDLE"; do
    if [ ! -f "$f" ]; then
        echo "${RED}br_ddb fingerprint: missing $f${RST}" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 2

src_hash="$(source_fingerprint)"
bundle_hash="$(tr -d '\r' < "$BUNDLE" | sha256)"
bundle_bytes="$(tr -d '\r' < "$BUNDLE" | wc -c | tr -d ' ')"
file_count="$(source_files | wc -l | tr -d ' ')"

# --- modes --------------------------------------------------------------------

if [ "$mode" = "print" ]; then
    echo "source $src_hash"
    echo "bundle $bundle_hash"
    echo "files  $file_count"
    exit 0
fi

if [ "$mode" = "write" ]; then
    cat > "$MANIFEST" <<EOF
{
  "scheme": "$SCHEME",
  "source": "$src_hash",
  "bundle": "$bundle_hash",
  "bundleBytes": $bundle_bytes,
  "files": $file_count
}
EOF
    echo "br_ddb: recorded $file_count source files against the committed bundle"
    echo "        source ${src_hash:0:12}, bundle ${bundle_hash:0:12} -> $MANIFEST"
    exit 0
fi

# --- check --------------------------------------------------------------------
#
# Parsed with sed rather than jq: this file is written by the block above, in a
# shape fixed by this script, so a real JSON parser buys nothing and a
# dependency on one would put the gate right back where #218 found it.

if [ ! -f "$MANIFEST" ]; then
    echo "no manifest at $MANIFEST"
    echo "Fix:  bash tools/br_ddb_fingerprint.sh"
    exit 1
fi

field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$MANIFEST" | head -1; }

rec_scheme="$(field scheme)"
rec_src="$(field source)"
rec_bundle="$(field bundle)"

if [ "$rec_scheme" != "$SCHEME" ]; then
    echo "manifest scheme is '$rec_scheme', this script writes '$SCHEME'"
    echo "Fix:  bash tools/br_ddb_fingerprint.sh"
    exit 1
fi

fail=0

if [ "$rec_src" != "$src_hash" ]; then
    echo "js-src/br_ddb source has changed since the bundle was recorded."
    echo "  recorded ${rec_src:0:12}, source is now ${src_hash:0:12}"
    fail=1
fi

if [ "$rec_bundle" != "$bundle_hash" ]; then
    echo "$BUNDLE has changed since it was recorded."
    echo "  recorded ${rec_bundle:0:12}, bundle is now ${bundle_hash:0:12}"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo
    echo "The game box runs the committed bundle and builds nothing, so a"
    echo "source change that was never rebuilt ships as 'my change did nothing'."
    echo
    echo "Fix, both steps, in this order:"
    echo "  1. cd js-src/br_ddb && npm run build      # rebuild the bundle"
    echo "  2. bash tools/br_ddb_fingerprint.sh       # re-record the manifest"
    echo
    echo "Step 2 alone makes this gate green while shipping the OLD bundle. It"
    echo "records what you tell it. Do not skip step 1."
    exit 1
fi

echo "${src_hash:0:12}"
exit 0

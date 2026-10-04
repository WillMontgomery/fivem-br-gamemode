#!/usr/bin/env bash
#
# Secret-scanning gate.
#
#   ./tools/check_secrets.sh                  every file git has or would add
#   ./tools/check_secrets.sh --revs <revs>    the text those commits add (tools/pre-push)
#
# This repo is PUBLIC, and so is fivem-ringmaster next door. The whole "public
# is fine" argument rests on nothing secret ever being in either of them, and
# that is a promise about every future commit rather than about today's. So it
# gets enforced mechanically instead of remembered.
#
# Same reasoning as check-css, which fails the UI build on a colour function
# Chrome 103 cannot render: a dependency bump or a tired evening introduces the
# problem, and nothing in a typecheck or a unit test would notice.
#
# THIS GATE SCANS THE WHOLE REPO, unlike every other gate in verify.sh, which
# is scoped to resources/. A credential is just as leaked from tools/, from
# server.cfg.example, or from a doc.
#
# TUNED FOR FEW FALSE POSITIVES, deliberately. A gate that cries wolf gets
# bypassed with --no-verify, and then it protects nothing at all. Every pattern
# below matches a specific credential shape, never "a long random-looking
# string" -- and there is a placeholder escape for the ones that are supposed
# to appear in an example file.
#
# Kept in bash rather than Node, unlike its counterpart
# fivem-ringmaster/scripts/check-secrets.mjs, because verify.sh must run on a
# machine with no Node installed. The two are otherwise the same gate and their
# rule lists should be kept in step.

set -uo pipefail
# --revs reads git's objects in the repository it is run in (tools/pre-push
# runs an installed copy of this file from the hooks dir); the tree form scans
# the checkout this file is in.
[ "${1:-}" = "--revs" ] || cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'

# --- what to scan ------------------------------------------------------------
#
# ASKING GIT RATHER THAN WALKING THE DISK IS THE POINT, and it is the same call
# check-secrets.mjs makes. server.cfg holds the real license key and the real
# database password, and it is gitignored -- so it can never reach the public
# repo, and flagging it would be a false positive on a file git will never see.
# False positives are how a gate ends up bypassed. The threat model is "a secret
# gets committed", and git's own index is the authority on what can be.
#
#   --cached           tracked files
#   --others           untracked files...
#   --exclude-standard ...that are not gitignored, i.e. ones a careless
#                      `git add -A` would sweep up
#
# `--revs <revs>` IS THE PRE-PUSH FORM (#391, tools/pre-push): the lines the
# given commits ADD, every commit `git log <revs>` walks, so a key committed and
# removed again inside one push is still caught -- the history the push
# publishes holds it. Each (commit, file) becomes one scratch file holding just
# those lines AT THEIR OWN LINE NUMBERS, blank elsewhere, so a hit reads as the
# real path and line, with the commit. grep reads that scratch DIRECTORY (-r),
# never a list of files on its command line, so no push is too big for it.
#
# FAILS CLOSED: exit 0 clean, 1 on a finding, 2 when it could not look. A git
# call that fails, or a grep that cannot run (exit 2 or more: an unreadable
# file, an argument list too long), is never a pass.

skipped() {
    case "$1" in
        tools/check_secrets.sh) return 0 ;;   # describes the shapes it hunts
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.ytd|*.ydr|*.awc|*.oga|*.ogg|*.mp3|*.woff|*.woff2|*.ttf) return 0 ;;
        package-lock.json|*/package-lock.json|*/yarn.lock) return 0 ;;
    esac
    return 1
}

WORK=$(mktemp -d) || { echo "${RED}FAIL${RST} could not make a scratch directory"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

MODE=tree
FILES=()
LABELS=()
SCANNED=0
if [ "${1:-}" = "--revs" ]; then
    shift
    MODE=revs
    [ "$#" -gt 0 ] || { echo "${RED}FAIL${RST} --revs needs the commits to scan"; exit 2; }
    # --text --no-textconv: the bytes as committed, whatever .gitattributes
    # says. Without them a path marked -diff or binary is "Binary files
    # differ" and a textconv driver shows its output instead -- text the
    # tree form, which reads the files, would have scanned. A file that
    # really is binary still reaches grep -I, which skips it as before.
    if ! git -c core.quotePath=false log -m -p -U0 --text --no-textconv --no-color --no-ext-diff --no-renames \
            --diff-filter=ACMRT --format='commit %h' "$@" > "$WORK/patch"; then
        echo "${RED}FAIL${RST} could not read the commits being pushed"
        exit 2
    fi
    mkdir "$WORK/f" || { echo "${RED}FAIL${RST} could not make a scratch directory"; exit 2; }
    : > "$WORK/index"
    # Hunk lines start with + - space or \, so `commit`, `diff --git` and `@@`
    # at column 0 are always headers; `+++ ` is one only outside a hunk.
    awk -v out="$WORK" '
        /^commit [0-9a-f]+$/ { c = $2; inhunk = 0; next }
        /^diff --git / { if (file != "") close(file); file = ""; inhunk = 0; next }
        /^@@ / {
            if (file == "") next
            s = $0
            sub(/^@@ -[0-9]+(,[0-9]+)? \+/, "", s)
            sub(/[ ,].*$/, "", s)
            line = s - 1
            inhunk = 1
            next
        }
        inhunk && /^\+/ {
            if (file == "") next
            line++
            while (written < line - 1) { print "" > file; written++ }
            print substr($0, 2) > file
            written++
            next
        }
        !inhunk && /^\+\+\+ / {
            p = substr($0, 5)
            sub(/\t$/, "", p)
            if (p == "/dev/null") { file = ""; next }
            if (p ~ /^"/) { p = substr(p, 2); sub(/"$/, "", p) }
            sub(/^b\//, "", p)
            n++
            file = out "/f/f" n
            written = 0
            printf "" > file
            printf "f%d\t%s\t%s\n", n, c, p > (out "/index")
            next
        }
    ' "$WORK/patch" || { echo "${RED}FAIL${RST} could not read the commits being pushed"; exit 2; }
    # What is skipped stays on disk and is left out by name (grep --exclude-from).
    : > "$WORK/skip"
    while IFS=$'\t' read -r id commit path; do
        if skipped "$path"; then
            printf '%s\n' "$id" >> "$WORK/skip"
            continue
        fi
        SCANNED=$((SCANNED + 1))
        LABELS[${id#f}]="$path|$commit"
    done < "$WORK/index"
    cd "$WORK" || { echo "${RED}FAIL${RST} could not enter the scratch directory"; exit 2; }
    if [ "$SCANNED" -eq 0 ]; then
        echo "${GRN}ok${RST}   no added text to scan in the commits being pushed"
        exit 0
    fi
else
    if ! git ls-files -z --cached --others --exclude-standard > "$WORK/list"; then
        echo "${RED}FAIL${RST} could not list the files git has -- is this a git checkout?"
        exit 2
    fi
    while IFS= read -r -d '' f; do
        skipped "$f" && continue
        FILES+=("$f")
    done < "$WORK/list"
    SCANNED=${#FILES[@]}

    if [ "$SCANNED" -eq 0 ]; then
        echo "${RED}FAIL${RST} no files to scan -- is this a git checkout?"
        exit 1
    fi
fi

# grep's "file:line:..." as the reader should see it: in --revs mode the real
# path and line, and the commit.
where() {
    local f="${1%%:*}" rest="${1#*:}"
    local ln="${rest%%:*}"
    if [ "$MODE" = revs ]; then
        local id="${f##*/}"
        local label="${LABELS[${id#f}]}"
        printf '%s:%s (commit %s)' "${label%|*}" "$ln" "${label##*|}"
    else
        printf '%s:%s' "$f" "$ln"
    fi
}

# --- the placeholder escape --------------------------------------------------
#
# server.cfg.example is SUPPOSED to contain a license-key line; docs are
# supposed to show an account id. A line that announces itself as a template is
# a template. Note the fix when this fires on something genuinely fake: make it
# LOOK like a placeholder, rather than weakening the rule that caught it.

PLACEHOLDER='REPLACE|CHANGE_?ME|CHANGEME|YOUR_|EXAMPLE|PLACEHOLDER|xxx+|\.\.\.|<[^>]+>|ACCOUNT_ID|TODO'

findings=0
unscanned=0

# rule <name> <grep-flags> <regex> <why>
rule() {
    local name="$1" flags="$2" re="$3" why="$4" hits st

    # -I skips binaries that slipped past the extension list above. -H names
    # the file even when there is only one.
    if [ "$MODE" = revs ]; then
        grep -rHnI $flags --exclude-from="$WORK/skip" -E -- "$re" f > "$WORK/hits" 2> "$WORK/err"
    else
        grep -HnI $flags -E -- "$re" "${FILES[@]}" > "$WORK/hits" 2> "$WORK/err"
    fi
    st=$?
    # 0 found, 1 found nothing; anything else is a grep that did not look.
    if [ "$st" -gt 1 ]; then
        echo "${RED}FAIL${RST} the '$name' rule could not run (grep exit $st): $(tail -n 1 "$WORK/err")"
        unscanned=$((unscanned + 1))
        return 0
    fi
    hits=$(grep -vE "$PLACEHOLDER" "$WORK/hits")
    st=$?
    if [ "$st" -gt 1 ]; then
        echo "${RED}FAIL${RST} the '$name' rule's placeholder filter could not run (grep exit $st)"
        unscanned=$((unscanned + 1))
        return 0
    fi

    [ -z "$hits" ] && return 0

    # grep prints file:line:content. Keep file:line -- the content is the
    # secret, and echoing it into a terminal (and a CI log) would be a fresh
    # copy of the thing we are trying not to spread.
    while IFS= read -r line; do
        echo "${RED}SECRET${RST} $(where "$line")  $name"
        echo "       $why"
        findings=$((findings + 1))
    done <<< "$hits"
}

# --- AWS ---------------------------------------------------------------------
# Both hosts use EC2 instance roles. There should be no access key anywhere, in
# this repo or on either box -- if one exists at all, the deployment is wrong.
rule 'AWS access key id' '' \
    '\bAKIA[0-9A-Z]{16}\b' \
    'Both hosts use EC2 instance roles. There should be no access key at all.'

# Only when it is actually labelled as one. A bare 40-char base64ish string is
# far too common to flag -- that is the "no high-entropy heuristics" rule.
rule 'AWS secret access key' '-i' \
    'aws_secret_access_key[[:space:]]*[=:][[:space:]]*.?[A-Za-z0-9/+=]{40}' \
    'Instance roles, not keys.'

# --- keys and tokens ---------------------------------------------------------
rule 'private key block' '' \
    '^-----BEGIN( [A-Z]+)? PRIVATE KEY-----' \
    'The SSH key to the game host lives on the Ringmaster box only.'

rule 'Discord bot token' '' \
    '\b[A-Za-z0-9_-]{24}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27}\b' \
    'Discord credentials belong in the environment.'

rule 'Discord client secret' '-i' \
    'discord_client_secret[[:space:]]*[=:][[:space:]]*.?[A-Za-z0-9_-]{20,}' \
    'Discord credentials belong in the environment.'

# THE SAME SECRET UNDER OUR OWN NAME, and it is a second rule rather than trust
# in the shape rule above for the reason the ingest secret has two spellings:
# the shape rule matches Discord's THREE-SEGMENT token layout, and a token whose
# segments do not happen to be 24/6/27 characters -- a regenerated one, or
# whatever Discord issues next -- would sail past it. The convar name is ours and
# cannot drift, so anchoring on it catches the paste regardless of the value.
#
# Note the alternation on the separator, exactly as the ingest rule has: this
# lives as a convar on the host (`set br_discord_bot_token ...`, whitespace) and
# as an env var nowhere yet, and writing it as `[=:]?[[:space:]]+` would silently
# match neither. server.cfg.example uses <angle brackets>, which the placeholder
# escape above lets through.
#
# IT ALSO MATCHES `br_discord_bot_token = SOME_LONG_IDENTIFIER`, i.e. a REFERENCE
# rather than a value, and that is left alone rather than engineered around: the
# fix is to name the fixture something short (tools/test_community.lua uses a
# four-letter local), which is what a test file should be doing anyway. Loosening
# the rule to tell a Lua identifier from a credential is more machinery than the
# false positive is worth, and it is machinery on the failing side.
rule 'Discord bot token convar' '' \
    '\bbr_discord_bot_token([[:space:]]*[=:]|[[:space:]])[[:space:]]*.?[A-Za-z0-9._-]{16,}' \
    'The Discord bot token for the guild-membership check. Convar on the host, never here.'

rule 'session signing key' '' \
    '\bAUTH_SECRET[[:space:]]*[=:][[:space:]]*.?[A-Za-z0-9/+=_-]{16,}' \
    'Ringmaster session signing key. Environment only.'

# Two spellings, because this secret lives on both sides of the push: an env
# var on Ringmaster (INGEST_SECRET=...) and a convar on the game host
# (set br_ringmaster_ingest_secret ...). Hence the alternation on the separator
# -- `=`/`:` for the env form, bare whitespace for the convar form. Writing it
# as `[=:]?[[:space:]]+` instead looked equivalent and silently matched
# NEITHER, because the env form has no whitespace at all. Caught by the probe.
rule 'ingest shared secret' '' \
    '\b(INGEST_SECRET|br_ringmaster_ingest_secret)([[:space:]]*[=:]|[[:space:]])[[:space:]]*.?[A-Za-z0-9/+=_-]{12,}' \
    'Shared secret for the game server push. Convar on the host, never here.'

# --- FXServer ----------------------------------------------------------------
# server.cfg is gitignored for exactly these two. The gate exists for the day
# somebody pastes one into server.cfg.example, a doc, or a shell snippet.
rule 'FiveM license key' '-i' \
    'sv_licenseKey[[:space:]]+.?[A-Za-z0-9]{15,}' \
    'The server license key. server.cfg only, and server.cfg is gitignored.'

rule 'database connection string' '-i' \
    'mysql://[^:]+:[^@]{6,}@' \
    'The MariaDB password. server.cfg only.'

# There should be no RCON password anywhere, because there is no RCON: it
# shares the players' UDP socket and cannot be moved, so `rcon_password` stays
# unset. See PLAN.md M9. A value here means someone reintroduced it.
rule 'rcon password with a value' '-i' \
    '\brcon_password[[:space:]]+.?[^[:space:]"]' \
    'There is deliberately no RCON. Whoever holds this can run any command.'

# --- result ------------------------------------------------------------------

if [ "$findings" -gt 0 ]; then
    echo
    echo "${RED}$findings possible secret(s) found.${RST}"
    echo "     This repo is public. Nothing above should ever be committed."
    echo "     If it is genuinely a placeholder, make it LOOK like one"
    echo "     (CHANGEME, YOUR_..., <angle-brackets>) rather than weakening"
    echo "     the rule that caught it."
    exit 1
fi

if [ "$unscanned" -gt 0 ]; then
    echo
    echo "${RED}$unscanned rule(s) could not run, so this is not a clean pass.${RST}"
    exit 2
fi

if [ "$MODE" = revs ]; then
    echo "${GRN}ok${RST}   nothing credential-shaped in the text the pushed commits add ($SCANNED file(s))"
else
    echo "${GRN}ok${RST}   nothing credential-shaped in $SCANNED scanned files"
fi

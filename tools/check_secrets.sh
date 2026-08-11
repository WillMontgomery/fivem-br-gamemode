#!/usr/bin/env bash
#
# Secret-scanning gate.
#
#   ./tools/check_secrets.sh
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
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'

# --- what to scan ------------------------------------------------------------
#
# ASKING GIT RATHER THAN WALKING THE DISK IS THE POINT, and it is the same call
# check-secrets.mjs makes. server.cfg holds the real licence key and the real
# database password, and it is gitignored -- so it can never reach the public
# repo, and flagging it would be a false positive on a file git will never see.
# False positives are how a gate ends up bypassed. The threat model is "a secret
# gets committed", and git's own index is the authority on what can be.
#
#   --cached           tracked files
#   --others           untracked files...
#   --exclude-standard ...that are not gitignored, i.e. ones a careless
#                      `git add -A` would sweep up

FILES=()
while IFS= read -r -d '' f; do
    case "$f" in
        tools/check_secrets.sh) continue ;;   # describes the shapes it hunts
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.ytd|*.ydr|*.awc|*.oga|*.ogg|*.mp3|*.woff|*.woff2|*.ttf) continue ;;
        package-lock.json|*/package-lock.json|*/yarn.lock) continue ;;
    esac
    FILES+=("$f")
done < <(git ls-files -z --cached --others --exclude-standard 2>/dev/null)

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "${RED}FAIL${RST} no files to scan -- is this a git checkout?"
    exit 1
fi

# --- the placeholder escape --------------------------------------------------
#
# server.cfg.example is SUPPOSED to contain a licence-key line; docs are
# supposed to show an account id. A line that announces itself as a template is
# a template. Note the fix when this fires on something genuinely fake: make it
# LOOK like a placeholder, rather than weakening the rule that caught it.

PLACEHOLDER='REPLACE|CHANGE_?ME|CHANGEME|YOUR_|EXAMPLE|PLACEHOLDER|xxx+|\.\.\.|<[^>]+>|ACCOUNT_ID|TODO'

findings=0

# rule <name> <grep-flags> <regex> <why>
rule() {
    local name="$1" flags="$2" re="$3" why="$4" hits

    # -I skips binaries that slipped past the extension list above.
    hits=$(grep -nI $flags -E -- "$re" "${FILES[@]}" 2>/dev/null \
           | grep -vE "$PLACEHOLDER" || true)

    [ -z "$hits" ] && return 0

    # grep prints file:line:content. Keep file:line -- the content is the
    # secret, and echoing it into a terminal (and a CI log) would be a fresh
    # copy of the thing we are trying not to spread.
    while IFS= read -r line; do
        echo "${RED}SECRET${RST} $(printf '%s' "$line" | cut -d: -f1-2)  $name"
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
rule 'FiveM licence key' '-i' \
    'sv_licenseKey[[:space:]]+.?[A-Za-z0-9]{15,}' \
    'The server licence key. server.cfg only, and server.cfg is gitignored.'

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

echo "${GRN}ok${RST}   nothing credential-shaped in ${#FILES[@]} scanned files"

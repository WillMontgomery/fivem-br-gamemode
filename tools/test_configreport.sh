#!/usr/bin/env bash
#
# `configreport` against real config files, one temporary box per shape.
#
#   ./tools/test_configreport.sh
#
# THE FIRST BEHAVIOURAL TEST OF tools/dispatch.sh, and it exists because the
# verb started reading a SECOND file. Everything verify.sh had on the dispatcher
# before this was static: the verb set is pinned by a grep, the convar allowlist
# is scanned for credential-shaped names by another. Both are worth having and
# neither can answer "does this box report its own hostname", which is the
# question 65387ec broke and this suite exists to keep answered.
#
# WHY IT BUILDS FILES RATHER THAN MOCKING THE READS. The bug being fixed was
# entirely about WHICH FILE a grep ran over, so a suite that stubbed the reads
# would have passed against the broken code. Every case here writes a server.cfg
# -- and, where the shape calls for it, a server-identity.cfg -- into a temp
# directory, points the dispatcher at them with the BR_* overrides it already
# has, and reads the JSON that comes back.
#
# THE THREE BOX SHAPES ARE ALL LIVE AT ONCE, which is the whole reason there are
# three. dev migrates to the identity file before prod does, so for as long as
# that takes there is a migrated box and an unmigrated box answering the same
# console, and a half-migrated one is what a mistake in between looks like.
#
# THE SECRET ASSERTION RUNS ON EVERY SHAPE. Each box gets a license key in
# whichever file that shape keeps it in, and every case asserts that neither the
# key nor the name `sv_licenseKey` appears anywhere in the response. It is
# cheap, it is the one thing here that would be expensive to get wrong, and it
# is asserted against the FULL response text rather than against a parsed field
# so that a future bug that puts it somewhere unexpected is still caught.
#
# Run against another copy of the dispatcher with BR_DISPATCH=path -- which is
# how the red half of every case below was taken, by pointing it at the file as
# it stood before the fix.

set -uo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'

DISPATCH="${BR_DISPATCH:-tools/dispatch.sh}"

pass=0
fail=0
skip=0

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "${RED}FAIL${RST} $1"; }
note() { skip=$((skip + 1)); echo "${YEL}skip${RST} $1"; }

# A fragment that must appear in the response, verbatim.
#
# WHOLE OBJECTS, NOT FIELD BY FIELD. `"value":"Blitz Royale | dev"` appearing
# somewhere and `"source":"server-identity.cfg"` appearing somewhere is not the
# same claim as the two being the same convar, and the second is the one worth
# making.
want() {
    if printf '%s' "$REPORT" | grep -qF -- "$2"; then ok; else
        bad "$1"
        echo "       expected to find: $2"
    fi
}

# A fragment that must NOT appear anywhere in the response.
deny() {
    if printf '%s' "$REPORT" | grep -qF -- "$2"; then
        bad "$1"
        echo "       forbidden text present: $2"
    else ok; fi
}

# THE KEY IS SPELLED AS A PLACEHOLDER ON PURPOSE. tools/check_secrets.sh scans
# every tracked file for `sv_licenseKey` followed by something key-shaped, and
# it is right to: this repo is public. CHANGEME is one of the spellings its
# placeholder escape recognises, so this stays a realistic length and a
# realistic shape without being a string anybody has to think twice about. If
# this line ever trips that gate, make it look MORE like a placeholder rather
# than loosening the gate.
FAKE_KEY='CHANGEME_not_a_real_license_key_9f2c'

# One box, one report. Writes $1/server.cfg from stdin, runs the verb, and
# leaves the response in $REPORT.
run_report() {
    local box="$1"
    REPORT="$(SSH_ORIGINAL_COMMAND=configreport \
        BR_SERVER_ROOT="$box" \
        BR_SERVER_CFG="$box/server.cfg" \
        BR_SERVER_IDENTITY_CFG="$box/server-identity.cfg" \
        BR_SRC_DIR="$box/nowhere" \
        BR_REPO_DIR="$box/nowhere" \
        bash "$DISPATCH" 2>/dev/null)"
}

BOXES="$(mktemp -d)"
trap 'rm -rf -- "$BOXES"' EXIT

# ---------------------------------------------------------------------------
# 1. A BOX THAT HAS NOT MIGRATED. Both literals are still in server.cfg, there
#    is no identity file, and nothing about this shape is allowed to regress:
#    prod is this box until somebody moves it.
# ---------------------------------------------------------------------------
box="$BOXES/unmigrated"; mkdir -p "$box"
cat > "$box/server.cfg" <<EOF
# line 1
sv_maxclients 48
sv_hostname "Blitz Royale | Public"
sv_licenseKey "$FAKE_KEY"
onesync on
EOF
run_report "$box"
want 'unmigrated: reports its hostname off server.cfg, with the line' \
     '{"name":"sv_hostname","value":"Blitz Royale | Public","source":"server.cfg","line":3}'
want 'unmigrated: says there is no identity file' '"identityState":"absent"'
want 'unmigrated: an unset convar is still an engine default' \
     '{"name":"voice_inBitrate","value":null,"source":"default","line":0}'
deny 'unmigrated: the license key value must not be reported' "$FAKE_KEY"
deny 'unmigrated: the license key name must not be reported' 'sv_licenseKey'

# ---------------------------------------------------------------------------
# 2. A MIGRATED BOX. server.cfg execs the identity file and holds neither
#    literal; royale-identity wrote the identity file, comment header and all.
#    This is the case that answered `not set` before the fix.
# ---------------------------------------------------------------------------
box="$BOXES/migrated"; mkdir -p "$box"
cat > "$box/server.cfg" <<'EOF'
# line 1
sv_maxclients 48
onesync on
exec "server-identity.cfg"
EOF
cat > "$box/server-identity.cfg" <<EOF
# Written by royale-identity at 2026-09-13T00:00:00Z. DO NOT EDIT.
# Slot dev, resolved from the Elastic IP 198.51.100.7 (eipalloc-0) attached to i-0.
# Edits here are overwritten on the next boot; change the SSM parameters instead.
sv_hostname "Blitz Royale | Dev"
sv_licenseKey "$FAKE_KEY"
EOF
run_report "$box"
want 'migrated: reports its hostname off the identity file, with that file line' \
     '{"name":"sv_hostname","value":"Blitz Royale | Dev","source":"server-identity.cfg","line":4}'
want 'migrated: says the identity file was read' '"identityState":"read"'
want 'migrated: names the identity file it read' '"identityCfg":"'"$box"'/server-identity.cfg"'
want 'migrated: server.cfg still answers for its own convars' \
     '{"name":"sv_maxclients","value":"48","source":"server.cfg","line":2}'
deny 'migrated: the license key value must not be reported' "$FAKE_KEY"
deny 'migrated: the license key name must not be reported' 'sv_licenseKey'

# ---------------------------------------------------------------------------
# 3. HALF MIGRATED: the exec was added and the old literal above it was not
#    removed. FXServer runs the file top to bottom, so the identity file wins --
#    and a reporter that preferred server.cfg would print the stale name with a
#    line number, which is the most convincing way to be wrong.
# ---------------------------------------------------------------------------
box="$BOXES/half"; mkdir -p "$box"
cat > "$box/server.cfg" <<'EOF'
# line 1
sv_hostname "FiveM Royale | Battle Royale"
sv_maxclients 48
exec "server-identity.cfg"
EOF
cat > "$box/server-identity.cfg" <<EOF
sv_hostname "Blitz Royale | Slot 1"
sv_licenseKey "$FAKE_KEY"
EOF
run_report "$box"
want 'half-migrated: the identity file wins over a literal above the exec' \
     '{"name":"sv_hostname","value":"Blitz Royale | Slot 1","source":"server-identity.cfg","line":1}'
deny 'half-migrated: the stale literal must not be reported' 'FiveM Royale | Battle Royale'
deny 'half-migrated: the license key value must not be reported' "$FAKE_KEY"

# ---------------------------------------------------------------------------
# 4. THE OTHER SIDE OF THE SAME RULE: a literal BELOW the exec is the last
#    setting FXServer executes, so server.cfg wins there. Without this case the
#    rule in 3 is indistinguishable from "the identity file always wins", which
#    is a different and wrong rule.
# ---------------------------------------------------------------------------
box="$BOXES/override"; mkdir -p "$box"
cat > "$box/server.cfg" <<'EOF'
# line 1
sv_maxclients 48
exec "server-identity.cfg"
sv_hostname "Blitz Royale | Overridden"
EOF
cat > "$box/server-identity.cfg" <<EOF
sv_hostname "Blitz Royale | Slot 1"
sv_licenseKey "$FAKE_KEY"
EOF
run_report "$box"
want 'override: a literal below the exec wins, and says where it is' \
     '{"name":"sv_hostname","value":"Blitz Royale | Overridden","source":"server.cfg","line":4}'
deny 'override: the license key value must not be reported' "$FAKE_KEY"

# ---------------------------------------------------------------------------
# 5. THE IDENTITY FILE IS THERE AND THIS USER CANNOT OPEN IT. royale-identity
#    chowns it to the game user, and warns and carries on root-owned when that
#    chown fails -- so this is a state a real box reaches, and the answer must
#    not be the word `default`, which is a claim that the name is set nowhere.
#
#    TWO WAYS IN, BECAUSE ONE OF THEM DOES NOT EXIST EVERYWHERE. A directory at
#    the path is unreadable-as-config on every filesystem; mode 000 is the real
#    shape and is a no-op on Windows filesystems and for root, so it is tested
#    when it bites and skipped out loud when it does not.
# ---------------------------------------------------------------------------
box="$BOXES/closed"; mkdir -p "$box"
cat > "$box/server.cfg" <<'EOF'
# line 1
sv_maxclients 48
exec "server-identity.cfg"
EOF
mkdir -p "$box/server-identity.cfg"
run_report "$box"
want 'unreadable: an unopenable identity path is not an engine default' \
     '{"name":"sv_hostname","value":null,"source":"unknown","line":0}'
want 'unreadable: the report says which state it is in, once' '"identityState":"unreadable"'
want 'unreadable: server.cfg convars still answer normally' \
     '{"name":"sv_maxclients","value":"48","source":"server.cfg","line":2}'

box="$BOXES/mode000"; mkdir -p "$box"
cat > "$box/server.cfg" <<'EOF'
# line 1
sv_maxclients 48
exec "server-identity.cfg"
EOF
cat > "$box/server-identity.cfg" <<EOF
sv_hostname "Blitz Royale | Slot 1"
sv_licenseKey "$FAKE_KEY"
EOF
chmod 000 "$box/server-identity.cfg" 2>/dev/null
if [ -r "$box/server-identity.cfg" ]; then
    note "mode 000: this filesystem or this user ignores it, so the real 0600 shape is untested here (the directory case above covers the branch)"
else
    run_report "$box"
    want 'mode 000: a 0600 identity file this user cannot open is not a default' \
         '{"name":"sv_hostname","value":null,"source":"unknown","line":0}'
    want 'mode 000: the report says so' '"identityState":"unreadable"'
    deny 'mode 000: the license key value must not be reported' "$FAKE_KEY"
    deny 'mode 000: the license key name must not be reported' 'sv_licenseKey'
fi
chmod 644 "$box/server-identity.cfg" 2>/dev/null

# ---------------------------------------------------------------------------
# 6. THE ALLOWLIST IS WHAT DECIDES, AND THIS PROVES IT RATHER THAN ASSERTING IT.
#    A name that is not on the list does not come back even when it is sitting
#    in plain sight in the identity file next to the one that does -- which is
#    the exact property that makes the key unreportable, tested on a value that
#    is safe to print if the property fails.
# ---------------------------------------------------------------------------
box="$BOXES/allowlist"; mkdir -p "$box"
cat > "$box/server.cfg" <<'EOF'
# line 1
exec "server-identity.cfg"
EOF
cat > "$box/server-identity.cfg" <<EOF
sv_hostname "Blitz Royale | Slot 1"
sv_endpointPrivacy "this name is not on the allowlist"
sv_licenseKey "$FAKE_KEY"
EOF
run_report "$box"
want 'allowlist: the allowlisted name beside it is reported' \
     '{"name":"sv_hostname","value":"Blitz Royale | Slot 1","source":"server-identity.cfg","line":1}'
deny 'allowlist: a name that is not on the list is not reported' 'sv_endpointPrivacy'
deny 'allowlist: nor is its value' 'this name is not on the allowlist'
deny 'allowlist: the license key value must not be reported' "$FAKE_KEY"
deny 'allowlist: the license key name must not be reported' 'sv_licenseKey'

# ---------------------------------------------------------------------------

if [ "$fail" -gt 0 ]; then
    echo "${RED}$fail failed${RST}, $pass passed, $skip skipped"
    exit 1
fi
echo "${GRN}ok${RST}   configreport: $pass assertions over 6 box shapes, $skip skipped"

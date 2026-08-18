#!/usr/bin/env bash
#
# The SSH forced-command dispatcher -- the ONE channel from Ringmaster to the
# game host. authorized_keys pins the Ringmaster key to:
#
#   command="/opt/fivem-server-classic/.gamemode-src/tools/dispatch.sh",\
#   no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty \
#   ssh-ed25519 AAAA... ringmaster
#
# PIN IT TO THE SERVED CLONE, NOT THE OPS CLONE. There are two checkouts on the
# box. `/opt/misc/fivem-br-gamemode` is the one a human `git pull`s by hand;
# `$SERVER_ROOT/.gamemode-src` is the one deploy.sh maintains, hard-resets to
# origin/main on every run, and syncs the game from.
#
# This file was originally pinned to the ops clone, which meant every change to
# it needed a SECOND manual pull that nothing prompted you to do -- and the
# symptom was the console reporting `unknown verb 'kick'` long after the kick
# had shipped and deployed. Pinning to the served clone means dispatch.sh
# updates with the game code, on the same `systemctl start royale-deploy` that
# updates everything else, and there is nothing extra to remember.
#
# It works because tools/ is part of the repo (so the clone has it) and this
# file is committed mode 100755 (so it stays executable through the reset).
#
# so even a stolen key runs ONLY this script and never a shell. This reads the
# requested verb from $SSH_ORIGINAL_COMMAND, switches on a FIXED set, and NEVER
# eval's it. An unrecognised verb exits non-zero. The forced-command line in
# authorized_keys is the outer boundary; this case statement is the inner one.
#
# THE VERB SET IS PINNED BY verify.sh, which greps this file for it and fails
# the build when it grows. Every verb here is a capability the console has over
# this box, so the set moving is a decision somebody records rather than a slip.
# It is currently `status`, `telemetry`, `configreport`, `kick`, `deploy`,
# `branches` and `switchref`.
#
# `configreport` IS READ-ONLY and is named the long way round on purpose. The
# forbidden list in verify.sh's boundary gate has always reserved the bare word
# `config` for LIVE CONFIG EDITING -- the write path, still forbidden, still
# M6's problem. A read verb wearing that name would quietly retire the reserved
# word and leave the next person unable to tell which of the two had shipped.
#
# THE BRANCH-SWITCH INVARIANT, which is the reason `branches` and `switchref`
# exist and the reason they are so fussy.
#
# Read the paragraph above again: authorized_keys pins Ringmaster's key to THIS
# FILE, inside the clone deploy.sh hard-resets. That was the right call while
# main was the only thing ever checked out. The moment the console can ask for
# another branch, "switch to branch X" and "replace the console's only channel
# to this box with whatever X says that channel should be" become mechanically
# the same operation -- the deploy would overwrite this script with an
# unreviewed copy of itself, and the next `kick` would run that copy.
#
#   SO: A REF IS ONLY DEPLOYABLE IF <sha>:tools/dispatch.sh EXISTS, IS MODE
#   100755, AND ITS BLOB ID EQUALS origin/main:tools/dispatch.sh's BLOB ID.
#
# Blob ids rather than a diff or a checksum of our own, because git already
# content-addresses every file: the whole rule is two `ls-tree` calls and a
# string compare (see ref_blocked_by below).
#
# It is enforced TWICE -- here before the pin is written, and again in
# tools/deploy.sh before the working tree is touched. Twice because the two run
# at different times: a switch is staged now and deployed when the match ends,
# and the ref can move in between. deploy.sh's copy is the load-bearing one; see
# the comment on it there for why.
#
# THE ACCEPTED COST: this feature cannot be used to test a change to tools/.
# Such a branch is listed, shown ineligible, and refused. Changes to tools/ go
# through main and PR review, which is where verify.sh's gates run. That is the
# right place for them.

set -uo pipefail

REPO="${BR_REPO_DIR:-/opt/misc/fivem-br-gamemode}"
SESSION="${BR_TMUX_SESSION:-royale}"

# THE CLONE THE SERVER ACTUALLY RUNS, which is not $REPO. There are two clones
# on this box and reporting the wrong one is a lie with a straight face:
# $REPO is the ops checkout you `git pull` by hand (it is where deploy.sh and
# this script live), while deploy.sh maintains its own clone under
# $SERVER_ROOT/.gamemode-src, hard-resets it to origin/main, and rsyncs THAT
# into the running resources. Pulling $REPO by hand -- which is exactly how
# dispatch.sh gets updated -- would otherwise make the console report a commit
# the game has never run.
SERVER_ROOT="${BR_SERVER_ROOT:-/opt/fivem-server-classic}"
SRC_DIR="${BR_SRC_DIR:-$SERVER_ROOT/.gamemode-src}"
# Fall back to the ops clone if the served one is missing (a box that has never
# deployed), so status degrades to "roughly right" instead of "unknown".
[ -d "$SRC_DIR/.git" ] || SRC_DIR="$REPO"

# THE TWO FILES `configreport` READS, and both are "what the server actually
# loaded" rather than "what the repo says", which is the whole point of asking
# the box instead of reading GitHub.
#
# server.cfg is NOT in the repo and never will be -- it holds the real licence
# key -- so there is nothing to compare it against and no version of this that
# works without reading the file on the box.
CFG_FILE="${BR_SERVER_CFG:-$SERVER_ROOT/server.cfg}"

# The DEPLOYED resources, not the clone's. deploy.sh rsyncs
# $SRC_DIR/resources/[fivem-royale] into $SERVER_ROOT/resources/<category>/,
# and FXServer loads the copy. Reading the clone instead would report the
# config of a commit that has been fetched but not yet deployed -- which is
# precisely the "why is this not what I set" confusion the report exists to
# end. Category default matches deploy.sh's own BR_TARGET_CATEGORY.
TARGET_CATEGORY="${BR_TARGET_CATEGORY:-[gamemodes]}"
LIB_DIR="$SERVER_ROOT/resources/$TARGET_CATEGORY/[fivem-royale]/br_lib"
# A box that has never deployed still gets an answer, from the clone.
[ -d "$LIB_DIR/config" ] || LIB_DIR="$SRC_DIR/resources/[fivem-royale]/br_lib"

# WHICH REF THE NEXT DEPLOY SHOULD CHECK OUT, AS A PLAIN FILE THIS USER OWNS.
#
# One line: `<ref> <sha>`, or `<ref>` once the sha has been consumed by a
# successful deploy. deploy.sh reads it, re-validates the name from scratch, and
# never trusts a byte of it.
#
# WHY A FILE AND NOT AN ARGUMENT. do_deploy shells out through a sudoers rule
# that matches
#
#   ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl start royale-deploy
#
# and sudo matches a command line EXACTLY. Appending a branch would silently
# stop matching the rule already deployed on the box -- the same trap that kept
# `--no-block` out of do_deploy. There is no argument to pass, so the ref has to
# be somewhere the unit can find it.
#
# WHY NOT A systemd EnvironmentFile, which is the obvious answer and is wrong.
# That file is read by systemd AS ROOT while being writable by the deploy user,
# so anything able to write it chooses environment variables for a root unit --
# PATH, LD_PRELOAD, anything. It converts "can pin a branch" into "can run code
# as root", which is a strictly larger capability than this feature is asking
# for. A plain ref-name file that an unprivileged deploy.sh reads and
# re-validates cannot do that: the worst a corrupted one can say is the name of
# a branch, which is exactly the decision it is allowed to make.
PIN_FILE="${BR_PIN_FILE:-$SERVER_ROOT/.branch-pin}"

# Who asked for the pin, and when. PURELY COSMETIC and deliberately a second
# file: the banner in the console has to be able to name a person, and putting
# that on the line deploy.sh parses would mean deploy.sh parsing a human's
# display name. Nothing reads this to make a decision.
PIN_BY_FILE="${BR_PIN_BY_FILE:-$SERVER_ROOT/.branch-pin.by}"

# First word is the verb; the rest are its arguments. The verb is only ever
# MATCHED against the case below, never executed -- so a payload in
# $SSH_ORIGINAL_COMMAND cannot become a command.
verb="${SSH_ORIGINAL_COMMAND%% *}"

# The remainder, unsplit. Read into an array with `read -ra` at the point of
# use rather than left as a bare word, because an unquoted expansion here is
# how a filename glob in a ban reason turns into a directory listing.
args_raw="${SSH_ORIGINAL_COMMAND#* }"
[ "$args_raw" = "$SSH_ORIGINAL_COMMAND" ] && args_raw=""

# --- helpers -----------------------------------------------------------------

# The FXServer process id, or empty. pgrep on the musl loader that actually
# runs it (see the process list in DEPLOY.md's crash notes).
fxserver_pid() {
    pgrep -f 'cfx-server/FXServer' 2>/dev/null | head -1
}

# One JSON string body, escaped. NOT optional decoration: `branches` prints
# commit subjects and author names straight off a branch anybody can push, and a
# single `"` in one of them turns this script's output into something the
# console reports as `dispatch returned non-JSON` -- i.e. an apostrophe in a
# commit message would break the branch list and look like the SSH channel was
# down. Backslash first, then quote, or the escapes escape each other. Control
# characters are DROPPED rather than escaped: \u sequences are the one part of
# JSON string encoding that cannot be done with sed, and nothing legitimate puts
# a control character in a commit subject.
json_str() {
    printf '%s' "${1:-}" \
        | tr -d '\000-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Is this a ref name we are willing to hand to git, judged as a RAW STRING
# before git has seen it?
#
# THIS IS A SHAPE CHECK, NOT A NAMING POLICY. There is deliberately no allowlist
# of `feature/`-style prefixes: which branches are worth deploying is a judgement
# for the person clicking, and a regex that encodes it only teaches people to
# name branches to get past it. What this refuses is the handful of strings that
# stop being a branch name once something else reads them:
#
#   a leading '-'      is an OPTION to every git command below. `--upload-pack=`
#                      on a fetch is arbitrary code execution on this box, and it
#                      arrives looking exactly like a branch name.
#   '..' or '//' or a
#   trailing '/'       climb out of, or fall out of, refs/remotes/origin/<ref>.
#   anything outside
#   [A-Za-z0-9._/-]    never reaches a shell here -- nothing is eval'd -- but it
#                      does reach the JSON we print and the pin file deploy.sh
#                      parses, and both are read by something that trusts us.
#
# `git check-ref-format` is the real authority on what git considers a legal
# ref, and it runs LAST: it is itself a git command taking this string as an
# argument, so it cannot be the thing that decides the string is safe to pass to
# a git command.
valid_ref() {
    local r="${1:-}"
    [ -n "$r" ] || return 1
    [ "${#r}" -le 120 ] || return 1
    printf '%s' "$r" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || return 1
    case "$r" in
        *..*|*//*|*/) return 1 ;;
    esac
    git check-ref-format "refs/heads/$r" >/dev/null 2>&1
}

# "<mode> <blobid>" for tools/dispatch.sh at a commit, or empty if it is absent.
dispatch_entry() {
    git -C "$SRC_DIR" ls-tree "$1" -- tools/dispatch.sh 2>/dev/null \
        | awk '{print $1" "$3}'
}

# THE RULE, in one function. Silent and returns 0 when <sha> may be deployed;
# prints the operator-facing reason and returns 1 when it may not.
#
# The reason is a sentence rather than a code because it is rendered verbatim
# next to a disabled branch in the console, and "this branch changes
# tools/dispatch.sh" is precisely the thing whoever is looking needs to know.
ref_blocked_by() {
    local sha="${1:-}" want have
    want="$(dispatch_entry origin/main)"
    if [ -z "$want" ]; then
        echo "cannot read tools/dispatch.sh on origin/main"
        return 1
    fi
    have="$(dispatch_entry "$sha")"
    if [ -z "$have" ]; then
        echo "deletes tools/dispatch.sh, which is the console's channel to this box"
        return 1
    fi
    case "$have" in
        "100755 "*) : ;;
        *)  echo "tools/dispatch.sh is not executable (mode 100755) on this branch"
            return 1 ;;
    esac
    if [ "$have" != "$want" ]; then
        echo "changes tools/dispatch.sh -- deploy it through main and PR review"
        return 1
    fi
    return 0
}

# --- verbs -------------------------------------------------------------------

do_status() {
    local running=false pid uptime=0
    pid="$(fxserver_pid)"
    if [ -n "$pid" ]; then
        running=true
        # etimes: elapsed seconds since the process started. Portable enough;
        # falls back to 0 if ps lacks it.
        uptime="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
        [ -n "$uptime" ] || uptime=0
    fi

    local commit
    commit="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

    # How far the SERVED clone lags origin/main.
    #
    # THE REMOTE REF HAS TO BE REFRESHED OR THIS IS ALWAYS ZERO, which is the
    # bug this replaced: it compared HEAD to a cached origin/main, and the only
    # thing that ever refreshed that cache was a deploy. So the moment a deploy
    # finished, HEAD == origin/main forever after and the console cheerfully
    # reported "up to date" while main ran away from it. A staleness check whose
    # own input is stale is worse than none -- it is confidently wrong.
    #
    # THE FETCH RUNS DETACHED, NEVER IN THE REQUEST PATH. The console gives this
    # whole SSH round trip six seconds; a fetch against GitHub over a cold link
    # can eat all of it, and a status call that times out reports the server as
    # unreachable -- turning a cosmetic staleness question into a false alarm
    # about the game being down. So: kick off a background fetch when the cached
    # ref is older than the throttle, answer immediately from whatever is on
    # disk, and let the NEXT poll (15s later) see the fresher number. Converges
    # in one interval and cannot ever block.
    local fetch_head="$SRC_DIR/.git/FETCH_HEAD"
    local now_s stale=1
    now_s="$(date +%s)"
    if [ -r "$fetch_head" ]; then
        local fetched_s
        fetched_s="$(stat -c %Y "$fetch_head" 2>/dev/null || echo 0)"
        [ "$((now_s - fetched_s))" -lt "${BR_FETCH_THROTTLE_SEC:-60}" ] && stale=0
    fi
    if [ "$stale" -eq 1 ]; then
        # setsid+& so it survives this script exiting; output discarded because
        # anything on stdout would corrupt the JSON line the console parses.
        setsid git -C "$SRC_DIR" fetch --quiet origin main >/dev/null 2>&1 &
    fi

    local behind=0
    behind="$(git -C "$SRC_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"

    local host_uptime=0
    if [ -r /proc/uptime ]; then
        host_uptime="$(cut -d. -f1 /proc/uptime)"
    fi

    # WHICH REF IS ACTUALLY SERVED, read off the clone rather than off the pin.
    #
    # The two differ for real and the difference matters: a switch staged into
    # the pin file and then cancelled leaves a pin naming a branch this box has
    # never run. The console's off-main banner is about what is RUNNING, so this
    # is the symbolic ref of the served clone and nothing else.
    #
    # EMPTY WHEN HEAD IS DETACHED, and that is left empty on purpose. The
    # console computes `onMain = deployedRef === 'main'`, so an answer we cannot
    # give reads as "not main" and shows the banner. Being wrong in that
    # direction costs a banner; being wrong in the other costs an unannounced
    # automatic deploy of main over a parked branch.
    local deployed_ref
    deployed_ref="$(git -C "$SRC_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"

    # The pin, and who asked for it. Re-validated here as well, because the
    # console renders it and a status line is not the place to discover that
    # somebody hand-edited a file on the box.
    local pinned_ref="" pinned_by="" pinned_at=0
    if [ -r "$PIN_FILE" ]; then
        read -r pinned_ref _ < "$PIN_FILE" || true
        valid_ref "$pinned_ref" || pinned_ref=""
    fi
    if [ -r "$PIN_BY_FILE" ]; then
        read -r pinned_at pinned_by < "$PIN_BY_FILE" || true
        pinned_at="${pinned_at//[^0-9]/}"
        [ -n "$pinned_at" ] || pinned_at=0
    fi

    printf '{"running":%s,"pid":%s,"uptimeSec":%s,"commit":"%s","sha":"%s","behindMain":%s,"hostUptimeSec":%s,"deployedRef":"%s","pinnedRef":"%s","pinnedBy":"%s","pinnedAt":%s}\n' \
        "$running" "${pid:-0}" "$uptime" "$commit" \
        "$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)" \
        "$behind" "$host_uptime" \
        "$(json_str "$deployed_ref")" "$(json_str "$pinned_ref")" \
        "$(json_str "$pinned_by")" "$pinned_at"
}

do_telemetry() {
    # CPU: two /proc/stat samples across a short window. usedPct = the fraction
    # of that window not spent idle. A 300ms sleep is well inside any sane SSH
    # round trip and inside PerformHttpRequest's ceiling on the far side.
    local cpu_pct=0
    if [ -r /proc/stat ]; then
        read -r _ u1 n1 s1 i1 w1 _ < /proc/stat
        local idle1=$((i1 + w1)) total1=$((u1 + n1 + s1 + i1 + w1))
        sleep 0.3
        read -r _ u2 n2 s2 i2 w2 _ < /proc/stat
        local idle2=$((i2 + w2)) total2=$((u2 + n2 + s2 + i2 + w2))
        local dt=$((total2 - total1)) di=$((idle2 - idle1))
        if [ "$dt" -gt 0 ]; then
            cpu_pct=$(( (100 * (dt - di) + dt / 2) / dt ))   # rounded
        fi
    fi

    local cores
    cores="$(nproc 2>/dev/null || echo 1)"

    # Memory: used = total - available, as a percentage.
    local mem_total=0 mem_avail=0 mem_pct=0
    if [ -r /proc/meminfo ]; then
        mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
        mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
        if [ "${mem_total:-0}" -gt 0 ]; then
            mem_pct=$(( (100 * (mem_total - mem_avail) + mem_total / 2) / mem_total ))
        fi
    fi

    # Network: CUMULATIVE bytes across real interfaces (lo excluded). Sent as a
    # counter, not a rate -- the console computes bytes/sec from the gap between
    # two polls, the same "send the origin, let the consumer derive" rule that
    # connectedAt follows. A rate computed here would be stale on arrival.
    local rx=0 tx=0
    if [ -r /proc/net/dev ]; then
        read -r rx tx < <(awk -F'[: ]+' '
            NR>2 && $2!="lo" { rx+=$3; tx+=$11 } END { print rx, tx }' /proc/net/dev)
    fi

    # Disk: the server root, in KB.
    local disk_total=0 disk_avail=0
    if command -v df >/dev/null 2>&1; then
        read -r disk_total disk_avail < <(df -Pk /opt/fivem-server-classic 2>/dev/null \
            | awk 'NR==2 {print $2, $4}')
    fi

    printf '{"at":%s000,"cpuPct":%s,"cores":%s,"memTotalKb":%s,"memAvailKb":%s,"memPct":%s,"rxBytes":%s,"txBytes":%s,"diskTotalKb":%s,"diskAvailKb":%s}\n' \
        "$(date +%s)" "$cpu_pct" "$cores" \
        "${mem_total:-0}" "${mem_avail:-0}" "$mem_pct" \
        "${rx:-0}" "${tx:-0}" "${disk_total:-0}" "${disk_avail:-0}"
}

# --- configreport ---------------------------------------------------------------
#
# What this server is actually configured with: an allowlisted set of engine
# convars, plus the gamemode's tuning values. READ-ONLY -- it opens files and
# runs one Lua script over them, touches no tmux session, starts nothing and
# writes nothing. It takes no arguments, so there is nothing in
# $SSH_ORIGINAL_COMMAND for it to interpret.
#
# ===========================================================================
# THE ALLOWLIST IS THE WHOLE SECURITY MODEL, AND IT IS CLOSED, NOT OPEN.
# ===========================================================================
#
# server.cfg on this box holds `sv_licenseKey`, and on a fuller deployment it
# would hold `rcon_password`, `mumble_adminPass`, a Steam web API key and
# `br_ringmaster_ingest_secret`. This output is rendered in a web browser and
# written to an audit log. So the rule is the same one PUBLIC_FIELDS and
# RINGMASTER_FIELDS follow in br_core/server/roster.lua: NAME WHAT GOES OUT,
# never name what stays behind.
#
# A denylist of secret-looking names would be the obvious shortcut and it FAILS
# OPEN. The day somebody adds a credential to server.cfg under a name nobody
# anticipated -- and the natural name for a new secret is whatever that secret
# is called, not something matching `*_password` -- it appears on a web page.
# The allowlist fails the other way: a new convar is invisible here until a
# person writes its name down, and the cost of that is a missing row.
#
# WHAT IS DELIBERATELY NOT HERE, so the omissions read as decisions:
#
#   sv_licenseKey, rcon_password, mumble_adminPass, steam_webApiKey,
#   br_ringmaster_ingest_secret   -- credentials. Never.
#
#   br_ringmaster_ingest_url      -- not a credential, still off. It is a
#                                    private VPC address, and internal network
#                                    topology on a web page buys nothing.
#
#   add_principal / add_ace       -- these name admins by license identifier.
#                                    Who is an admin is not a tuning value.
#
# ===========================================================================
# WHAT "SOURCE" MEANS HERE, AND WHAT IT HONESTLY CANNOT MEAN
# ===========================================================================
#
# "Why is this not what I set" is the question this page exists to answer, and a
# bare value cannot answer it. So every convar comes back as one of:
#
#   server.cfg   the name appears in server.cfg -- value and LINE NUMBER, so
#                the answer to "where is that set" is a line to go and look at.
#   default      the name does not appear in server.cfg, so the engine's own
#                built-in default is in effect. The value is null rather than a
#                guess: this script does not know FXServer's defaults and
#                inventing them would be confidently wrong, which is worse than
#                blank. "Not set anywhere" is itself the useful answer -- it is
#                exactly the answer #150 needed about voice_useNativeAudio.
#
# THERE IS NO "SET AT RUNTIME", AND THAT IS A LIMIT WORTH STATING OUT LOUD.
# Reading a live convar means GetConvar, which means running inside FXServer;
# the only channel from here into that process is `tmux send-keys`, which is a
# WRITE into the server console and would make this verb one of the dangerous
# ones. Refusing that is the right trade for a report. What this reports is the
# CONFIGURED state -- the files as the server would load them right now.
#
# So the gap that matters is: the files may have changed since FXServer read
# them. That is detectable without touching the process, and it is reported as
# `staleSinceStart` -- newest mtime across server.cfg and the deployed config
# files, against the FXServer process's own start time. When it is true the
# console says the running server is on older values than these, which is the
# one way this report could otherwise mislead somebody.

# Read one allowlisted convar out of server.cfg.
#
# THE NAME IS OURS, NEVER THE CALLER'S. It comes from CONVAR_ALLOW below and
# nowhere else, which is what makes it safe to put in a regex -- this verb takes
# no arguments at all, so nothing from $SSH_ORIGINAL_COMMAND reaches this.
#
# LAST MATCH WINS. FXServer executes server.cfg top to bottom, so a name set
# twice ends up holding the LAST value, and reporting the first would be a lie
# that is very hard to spot. `tail -1`, not `head -1`.
#
# The optional `set|setr|sets|seta` prefix covers every spelling in
# server.cfg.example; the mandatory whitespace after the name is what stops
# `sv_maxclients` matching a line about `sv_maxclientsSomething`. A leading `#`
# is not matched, so commented-out lines are correctly read as "not set".
convar_line() {
    grep -nE "^[[:space:]]*(set|setr|sets|seta)?[[:space:]]*$1[[:space:]]+" \
        "$CFG_FILE" 2>/dev/null | tail -1
}

# The value half of such a line, unquoted and de-commented.
#
# A quoted value is taken up to its closing quote and nothing after it is
# considered -- `sv_hostname "Royale | #1"` keeps its hash. An unquoted value
# stops at a whitespace-then-hash, which is how server.cfg.example writes
# trailing comments. Capped at 200 characters because this ends up in a 64KB
# response buffer and no legitimate tuning value is longer.
convar_value() {
    local name="$1" line="$2" v
    v="$(printf '%s' "$line" \
         | sed -E "s/^[[:space:]]*(set|setr|sets|seta)?[[:space:]]*$name[[:space:]]+//")"
    case "$v" in
        '"'*)
            v="${v#\"}"
            v="${v%%\"*}"
            ;;
        *)
            v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//')"
            v="${v%"${v##*[![:space:]]}"}"
            ;;
    esac
    printf '%s' "$v" | cut -c1-200
}

# A Lua interpreter, or empty. Mirrors tools/verify.sh's search: the box may
# have any of these installed and none is guaranteed, which is why the
# gamemode half of this report degrades to a NAMED error rather than to an
# empty list. "No lua on this host" is a thing an operator can fix in one
# apt-get; a silently empty section is a thing they file a bug about.
find_lua() {
    local c
    for c in lua lua5.4 lua5.3 luajit; do
        if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
    done
    # Last resort: the absolute paths apt actually installs to. A forced SSH
    # command runs with sshd's environment, not a login shell's, and its PATH is
    # whatever sshd was built with -- so `command -v` can miss an interpreter
    # that is plainly installed. The owner hit exactly that: lua5.4 present,
    # this function returning empty (2026-08-17).
    for c in /usr/bin/lua5.4 /usr/bin/lua5.3 /usr/bin/lua /usr/local/bin/lua \
             /usr/bin/luajit /snap/bin/lua5.4; do
        if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
    done
    return 1
}

# What find_lua searched and what it had to search WITH. A message that names
# only the fix is useless when the fix is already applied -- which is the state
# the owner was in when he reported this.
lua_search_note() {
    printf 'tried: lua lua5.4 lua5.3 luajit on PATH, then the usual absolute paths. PATH was: %s' \
        "${PATH:-<empty>}"
}

do_configreport() {
    # ---- engine convars -----------------------------------------------------
    #
    # Voice first, because it is why this list looks the way it does. #150 cost
    # a round to a wrong assumption about voice_useNativeAudio, and the useful
    # answer -- "it is not set on this box, so the engine default is in
    # effect" -- was unavailable without SSHing in and reading a file.
    #
    # Whitespace-separated, one name per line, and every name non-secret. Adding
    # to this list is the one edit in this file that can leak something, so it
    # is kept as a flat list of bare names with nothing clever around it: there
    # is no expression to misread and no pattern that could match more than what
    # is written.
    local CONVAR_ALLOW="
        voice_useNativeAudio
        voice_use2dAudio
        voice_use3dAudio
        voice_useSendingRangeOnly
        voice_inBitrate
        sv_maxclients
        sv_hostname
        sv_scriptHookAllowed
        onesync
        sv_enforceGameBuild
        sv_syncTickRate
        sv_devMode
        br_devMode
    "

    local convars="" name line lineno value
    for name in $CONVAR_ALLOW; do
        line="$(convar_line "$name")"
        [ -n "$convars" ] && convars="$convars,"
        if [ -n "$line" ]; then
            lineno="${line%%:*}"
            lineno="${lineno//[^0-9]/}"
            [ -n "$lineno" ] || lineno=0
            value="$(convar_value "$name" "${line#*:}")"
            convars="$convars$(printf '{"name":"%s","value":"%s","source":"server.cfg","line":%s}' \
                "$(json_str "$name")" "$(json_str "$value")" "$lineno")"
        else
            # null, not "" -- the console renders the two differently, and it
            # must. An empty string is a convar set to nothing; null is a
            # convar nobody has mentioned.
            convars="$convars$(printf '{"name":"%s","value":null,"source":"default","line":0}' \
                "$(json_str "$name")")"
        fi
    done

    # ---- the gamemode's own config -----------------------------------------
    #
    # RUNS A TRACKED FILE FROM THE SERVED CLONE, which a deployable branch is
    # allowed to change -- unlike this script, whose blob is pinned to main's by
    # the branch-switch invariant. That is deliberate and it is not a widening:
    # a branch that reaches this box has ALREADY had its resources/*.lua rsynced
    # into FXServer and executed as this same user, so it can run whatever it
    # likes here regardless. The invariant protects the console's CHANNEL -- the
    # verb set and the forced command -- not code execution in general.
    #
    # If that ever stops being true, the fix is to widen ref_blocked_by to
    # compare this file's blob as well, not to move the script somewhere the
    # deploy cannot reach: that is what put dispatch.sh in the ops clone and
    # cost us a kick that shipped and never arrived.
    local game lua_bin script raw
    game='{"ok":false,"loadErrors":["could not read the gamemode config"],"values":[]}'
    lua_bin="$(find_lua || true)"
    script="$SRC_DIR/tools/config_report.lua"

    if [ -z "$lua_bin" ]; then
        game="{\"ok\":false,\"loadErrors\":[\"no lua interpreter this dispatcher could reach -- $(lua_search_note)\"],\"values\":[]}"
    elif [ ! -r "$script" ]; then
        game="$(printf '{"ok":false,"loadErrors":["%s is missing -- deploy a commit that has it"],"values":[]}' \
                "$(json_str "$script")")"
    else
        # Bounded like every other subprocess here: the console allows this
        # round trip six seconds in total. `timeout` is probed rather than
        # assumed, the same way do_branches probes it -- a box without coreutils
        # should still get a report, just without the belt.
        if command -v timeout >/dev/null 2>&1; then
            raw="$(timeout "${BR_LUA_TIMEOUT_SEC:-4}" \
                   "$lua_bin" "$script" "$LIB_DIR" 2>/dev/null | head -c 49152)"
        else
            raw="$("$lua_bin" "$script" "$LIB_DIR" 2>/dev/null | head -c 49152)"
        fi
        # Its output is DATA, not something to trust into our own line. A
        # truncated or crashed run must not be able to make this verb print
        # something the console reads as half a report.
        case "$raw" in
            '{"ok":'*'}') game="$raw" ;;
            *) game='{"ok":false,"loadErrors":["the config reader produced nothing usable"],"values":[]}' ;;
        esac
    fi

    # ---- has any of it changed since FXServer started? ----------------------
    local now_s started_at=0 pid et newest=0 m f stale=false
    now_s="$(date +%s)"
    pid="$(fxserver_pid)"
    if [ -n "$pid" ]; then
        et="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
        [ -n "$et" ] && started_at=$((now_s - et))
    fi
    for f in "$CFG_FILE" "$LIB_DIR"/config/*.lua; do
        [ -r "$f" ] || continue
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        [ "${m:-0}" -gt "$newest" ] && newest="$m"
    done
    # Only claimable when the server is actually running: with no process there
    # is no "since it started", and answering true would read as "your edits are
    # not live" when the truth is "nothing is live".
    if [ "$started_at" -gt 0 ] && [ "$newest" -gt "$started_at" ]; then
        stale=true
    fi

    # MILLISECONDS BY ARITHMETIC, NOT BY APPENDING "000", which is the spelling
    # every other verb here uses and which is wrong the moment the number is
    # zero: `%s000` on an absent value prints `0000`, and JSON forbids leading
    # zeros, so a box with FXServer stopped answered with a line the console
    # could not parse at all. The one state where the report is most worth
    # reading is the one it broke in.
    printf '{"ok":true,"at":%s,"serverCfg":"%s","libDir":"%s","startedAt":%s,"configMtime":%s,"staleSinceStart":%s,"convars":[%s],"game":%s}\n' \
        "$((now_s * 1000))" "$(json_str "$CFG_FILE")" "$(json_str "$LIB_DIR")" \
        "$((started_at * 1000))" "$((newest * 1000))" \
        "$stale" "$convars" "$game"
}

# --- kick --------------------------------------------------------------------
#
# THE FIRST VERB THAT CAN CHANGE A RUNNING SERVER. Everything above only reads
# /proc and git; this one puts a command on the FXServer console. It is the
# reason the read-before-write boundary existed, and opening it is a decision
# rather than a slip -- verify.sh's boundary gate was updated in the same commit
# so the change is recorded rather than merely permitted.
#
#   kick <license> <base64-reason> <command-id>
#
# WHY THE REASON IS BASE64 AND NOT TEXT. It goes to `tmux send-keys`, which
# types into a live console. A newline in it is a SECOND COMMAND on FXServer's
# stdin -- so "cheating\nquit" would ban somebody and stop the server. Base64
# has no newline, no quote, no semicolon and no space, so the untrusted half of
# this command cannot be anything but one opaque token until it has been
# decoded and checked. It is validated at three hops: the console strips control
# characters before encoding (lib/actions.ts), this script re-checks the decoded
# text, and br_ringmaster checks again before use. Any one of the three is
# enough; all three exist because this is the path where being wrong is worst.
do_kick() {
    local license b64 cmdid
    # shellcheck disable=SC2086
    read -r license b64 cmdid <<< "$args_raw"

    # Shape checks BEFORE anything is decoded or sent. A license is hex with a
    # known prefix; a command id is a UUID. Both are generated by us, so
    # anything not matching exactly is a bug or an attack, and neither deserves
    # a best effort.
    if ! printf '%s' "$license" | grep -qE '^license2?:[0-9a-fA-F]{6,64}$'; then
        echo '{"ok":false,"error":"bad license"}'
        exit 3
    fi
    if ! printf '%s' "$cmdid" | grep -qE '^[0-9a-fA-F-]{8,64}$'; then
        echo '{"ok":false,"error":"bad command id"}'
        exit 3
    fi
    if ! printf '%s' "$b64" | grep -qE '^[A-Za-z0-9+/=]{0,512}$'; then
        echo '{"ok":false,"error":"bad reason encoding"}'
        exit 3
    fi

    # Decode and re-check. `tr -d` removes anything that could terminate the
    # console line even if the console side is ever compromised or changed --
    # this script does not trust its caller, which is the whole point of a
    # forced command.
    local reason
    # Control characters become SPACES rather than vanishing -- deleting them
    # runs the surrounding words together ("cheating\nquit" -> "cheatingquit"),
    # which is safe but misleads whoever reads the ban reason later. Quotes and
    # backslashes are removed outright: they cannot survive being embedded in
    # the quoted argument below, and no legitimate reason needs them.
    reason="$(printf '%s' "$b64" | base64 -d 2>/dev/null \
              | tr '\000-\037' ' ' | tr -d '"\\' | tr -s ' ' | cut -c1-300)"
    reason="${reason#"${reason%%[![:space:]]*}"}"   # trim leading space
    reason="${reason%"${reason##*[![:space:]]}"}"   # trim trailing space
    [ -n "$reason" ] || reason="No reason given"

    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo '{"ok":false,"error":"no tmux session -- is the server running?"}'
        exit 4
    fi

    # -l IS LOAD-BEARING. Without it tmux reads its argument as KEY NAMES, so a
    # payload containing "C-c" would be a control action rather than text --
    # meaning a crafted reason could interrupt or kill the server instead of
    # being typed. With -l every byte is literal. Enter is sent separately
    # because it IS a key name and cannot travel in the literal string.
    tmux send-keys -t "$SESSION" -l "brkick $license \"$reason\" $cmdid" || {
        echo '{"ok":false,"error":"send-keys failed"}'
        exit 5
    }
    tmux send-keys -t "$SESSION" Enter || {
        echo '{"ok":false,"error":"send-keys Enter failed"}'
        exit 5
    }

    # ACCEPTED, NOT DONE. All this proves is that the keystrokes reached the
    # console. Whether a player was actually removed comes back separately, as
    # an outcome event carrying this command id -- which is exactly why the
    # audit row starts as `pending` and why "unacknowledged" is a state the log
    # can show.
    printf '{"ok":true,"accepted":true,"commandId":"%s"}\n' "$cmdid"
}

# --- deploy -------------------------------------------------------------------
#
# Runs the SAME `systemctl start royale-deploy` an operator would type: pull
# main, sync resources, restart FXServer. Nothing reboots and the box stays up.
#
# IT IS STILL THE MOST DANGEROUS VERB HERE, because the restart ends every match
# in progress. That is why the console only reaches it through a maintenance
# window -- scheduled, drained, and deployed when the server is empty -- and why
# the one path that fires it with players online is an explicit "force" with its
# own confirmation and its own audit row naming who did it.
#
# NEEDS ONE SUDOERS LINE, because the unit must start as root while this script
# runs as the server user:
#
#   ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl start royale-deploy
#
# Scoped to that single unit and that single verb on purpose: `systemctl` with
# no argument restriction would be a general-purpose root shell wearing a hat.
do_deploy() {
    # DETACHED, AND THIS IS A BUG FIX RATHER THAN A STYLE CHOICE.
    #
    # royale-deploy is Type=oneshot, and `systemctl start` on a oneshot unit
    # BLOCKS until the unit finishes -- fetch, rsync, restart FXServer, the lot.
    # The console gives this whole SSH round trip six seconds, so it killed the
    # connection partway through, recorded the deploy as FAILED, and told the
    # admin so... while the unit carried on and completed perfectly. A false
    # failure on the one action that restarts the server is about the worst
    # place to have one: the natural response is to run it again.
    #
    # setsid + & returns immediately and lets the unit outlive this script.
    #
    # THE SUDOERS LINE IS UNCHANGED ON PURPOSE. `--no-block` would be the
    # tidier fix, but sudo matches the command line EXACTLY -- adding a flag
    # would silently start failing against the rule already deployed on the box.
    setsid sudo -n /usr/bin/systemctl start royale-deploy >/dev/null 2>&1 &

    # STARTED, NOT FINISHED, and now genuinely so. The console learns the
    # result the same way a human would: by watching the commit reported by
    # `status` change.
    echo '{"ok":true,"started":true}'
}

# --- branches ------------------------------------------------------------------
#
# Every remote branch, newest commit first, capped at 20, each one carrying
# whether it may be deployed and -- if not -- why.
#
# NOTHING IS EVER OMITTED. An ineligible branch is returned with
# `eligible: false` and a `blockedBy` sentence, because a branch that simply is
# not in the list reads as a bug in the list: the operator knows the branch
# exists, cannot see it, and has no way to tell "we refuse this" from "the
# dropdown is broken". Saying "changes tools/dispatch.sh" is the entire
# difference between a rule and a mystery.
#
# THE CAP IS 20 AND IT IS A DISPLAY CAP, nothing more. A remote with 200 stale
# branches would otherwise send a JSON document nobody reads through a 64KB
# buffer, and the twenty most recently committed branches are the ones anybody
# is deploying.
#
# THE FETCH IS BOUNDED AND ITS FAILURE IS REPORTED, not swallowed. The console
# allows this whole SSH round trip six seconds, so an unbounded fetch against
# GitHub over a cold link would turn "show me the branches" into "the game
# server is unreachable". If the fetch does not finish in time the answer comes
# from the refs already on disk and `stale` is true, which the console says out
# loud -- a branch list quietly a day old is how somebody deploys a sha that no
# longer exists.
do_branches() {
    local stale=true
    if command -v timeout >/dev/null 2>&1; then
        timeout "${BR_FETCH_TIMEOUT_SEC:-4}" \
            git -C "$SRC_DIR" fetch --quiet --prune origin >/dev/null 2>&1 \
            && stale=false
    fi

    local deployed_sha deployed_ref
    deployed_sha="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    deployed_ref="$(git -C "$SRC_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"

    local out="" n=0
    local raw sha tip_at tip_author subject symref name ahead behind counts blocked eligible

    # THE FULL refname, NOT %(refname:short), AND THAT IS NOT A STYLE CHOICE.
    # git shortens refs/remotes/origin/HEAD to the bare word `origin`, because
    # that is its unambiguous short form -- so a list built on the short name
    # contains an entry called "origin" that looks exactly like a mispushed
    # branch, is not one, and cannot be deployed. (docs/branch-switch.md's
    # earlier draft recorded it as a real branch on the remote. It never was:
    # `git ls-remote --heads origin` has never listed it.) Stripping the known
    # prefix ourselves gives HEAD its real name, which is then skipped.
    #
    # FIELDS ARE SEPARATED BY 0x1F, NOT A TAB, and that is a bug fix. Tab is an
    # IFS *whitespace* character, so bash collapses runs of them and drops empty
    # fields -- the first version of this used tabs, and because %(symref) is
    # empty for an ordinary branch every field after it shifted left by one. The
    # symptom was an entirely empty branch list from a working command. 0x1F is
    # not whitespace, so an empty field stays an empty field. It also cannot
    # occur in a ref name, an author name or a commit subject, all of which are
    # attacker-supplied in the sense that anyone with push access writes them.
    #
    # The subject is still LAST on the line: `read` puts whatever is left over
    # into the final variable, so nothing a subject contains can shift a field.
    while IFS=$'\x1f' read -r raw sha tip_at tip_author symref subject; do
        [ -n "$raw" ] || continue
        name="${raw#refs/remotes/origin/}"
        # HEAD is a pointer at whatever main is, not a branch anybody pushed.
        # Offering it would offer to deploy "HEAD".
        [ "$name" = "HEAD" ] && continue
        [ -n "$symref" ] && continue
        [ "$n" -ge 20 ] && break

        tip_at="${tip_at//[^0-9]/}"
        [ -n "$tip_at" ] || tip_at=0

        # Ahead and behind THE DEPLOYED SHA, not main. The question in front of
        # the operator is "what changes if I switch to this", and the answer is
        # relative to what is running right now.
        #
        # `A...B` counts left = reachable from A only, right = from B only. A is
        # what is deployed, so left is how far this branch is BEHIND it.
        ahead=0; behind=0
        if [ -n "$deployed_sha" ]; then
            counts="$(git -C "$SRC_DIR" rev-list --left-right --count \
                      "$deployed_sha...$sha" 2>/dev/null || true)"
            if [ -n "$counts" ]; then
                behind="$(printf '%s' "$counts" | awk '{print $1+0}')"
                ahead="$(printf '%s' "$counts" | awk '{print $2+0}')"
            fi
        fi

        if ! valid_ref "$name"; then
            eligible=false
            blocked="this branch name cannot be handled safely"
        elif blocked="$(ref_blocked_by "$sha")"; then
            eligible=true
            blocked=""
        else
            eligible=false
        fi

        [ -n "$out" ] && out="$out,"
        out="$out$(printf '{"name":"%s","sha":"%s","ahead":%s,"behind":%s,"tipAt":%s000,"tipAuthor":"%s","subject":"%s","eligible":%s,"blockedBy":"%s"}' \
            "$(json_str "$name")" "$(json_str "$sha")" \
            "$ahead" "$behind" "$tip_at" \
            "$(json_str "$tip_author")" "$(json_str "$subject")" \
            "$eligible" "$(json_str "$blocked")")"
        n=$((n + 1))
    done < <(git -C "$SRC_DIR" for-each-ref \
                --sort=-committerdate \
                --format='%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(authorname)%1f%(symref)%1f%(contents:subject)' \
                refs/remotes/origin/ 2>/dev/null)

    printf '{"ok":true,"stale":%s,"deployedSha":"%s","deployedRef":"%s","branches":[%s]}\n' \
        "$stale" "$(json_str "$deployed_sha")" "$(json_str "$deployed_ref")" "$out"
}

# --- switchref -----------------------------------------------------------------
#
#   switchref <ref> <40-hex sha> [base64 display name]
#
# Pins the ref the NEXT deploy will check out. IT DOES NOT DEPLOY. Those are
# separated because they happen at different times and for different reasons:
# the pin is chosen by an admin looking at a branch list, and the deploy fires
# when the last match ends, which may be hours later and may be somebody else
# pressing the button. Rolling them together would mean either a switch that
# restarts the server immediately or a deploy that silently decides its own ref.
#
# THE SHA IS THE POINT. The console resolved this branch to a sha when it drew
# the list; anyone with push access can force-push in the meantime. Comparing
# the two here means a moved branch is a REFUSAL that says so, never a silent
# deploy of a tip nobody looked at.
do_switchref() {
    local ref sha by_b64 by have blocked
    # shellcheck disable=SC2086
    read -r ref sha by_b64 <<< "$args_raw"

    if ! valid_ref "${ref:-}"; then
        printf '{"ok":false,"error":"%s"}\n' "not a usable branch name"
        exit 3
    fi
    if ! printf '%s' "${sha:-}" | grep -qE '^[0-9a-fA-F]{40}$'; then
        printf '{"ok":false,"error":"%s"}\n' "expected a full 40-character commit id"
        exit 3
    fi
    sha="$(printf '%s' "$sha" | tr 'A-F' 'a-f')"

    # Refresh just the ref in question (and main, which the rule is measured
    # against) rather than the whole remote. Bounded for the same six-second
    # reason as `branches`; a fetch that times out is not fatal here, because
    # the comparison below still refuses anything that does not match and
    # deploy.sh fetches and re-checks before it touches the working tree.
    if command -v timeout >/dev/null 2>&1; then
        if [ "$ref" = "main" ]; then
            timeout "${BR_FETCH_TIMEOUT_SEC:-4}" \
                git -C "$SRC_DIR" fetch --quiet origin main >/dev/null 2>&1 || true
        else
            timeout "${BR_FETCH_TIMEOUT_SEC:-4}" \
                git -C "$SRC_DIR" fetch --quiet origin "$ref" main >/dev/null 2>&1 || true
        fi
    fi

    have="$(git -C "$SRC_DIR" rev-parse -q --verify \
            "refs/remotes/origin/$ref^{commit}" 2>/dev/null || true)"
    if [ -z "$have" ]; then
        printf '{"ok":false,"error":"origin has no branch called %s"}\n' \
            "$(json_str "$ref")"
        exit 3
    fi
    if [ "$have" != "$sha" ]; then
        printf '{"ok":false,"error":"%s has moved since it was chosen (now %s, expected %s) -- pick it again"}\n' \
            "$(json_str "$ref")" "${have:0:8}" "${sha:0:8}"
        exit 3
    fi

    if ! blocked="$(ref_blocked_by "$sha")"; then
        printf '{"ok":false,"error":"%s cannot be deployed: %s"}\n' \
            "$(json_str "$ref")" "$(json_str "$blocked")"
        exit 3
    fi

    # WRITTEN THROUGH A TEMPORARY AND RENAMED. A deploy can start at any moment
    # -- the maintenance driver fires on a timer -- and rename is atomic on the
    # same filesystem, so deploy.sh reads either the old pin or the new one and
    # never a half-written line naming a branch that does not exist.
    local tmp="$PIN_FILE.tmp.$$"
    if ! printf '%s %s\n' "$ref" "$sha" > "$tmp" 2>/dev/null; then
        printf '{"ok":false,"error":"cannot write the branch pin at %s"}\n' \
            "$(json_str "$PIN_FILE")"
        exit 5
    fi
    if ! mv -f "$tmp" "$PIN_FILE" 2>/dev/null; then
        rm -f "$tmp"
        printf '{"ok":false,"error":"cannot replace the branch pin at %s"}\n' \
            "$(json_str "$PIN_FILE")"
        exit 5
    fi

    # Attribution, best effort and never fatal. Same treatment as a kick reason:
    # it arrives base64 so no space, quote or newline can survive the trip as
    # anything but one opaque token, and it is scrubbed again after decoding
    # because it ends up inside the JSON `status` prints.
    by=""
    if printf '%s' "${by_b64:-}" | grep -qE '^[A-Za-z0-9+/=]{0,256}$'; then
        by="$(printf '%s' "${by_b64:-}" | base64 -d 2>/dev/null \
              | tr -cd 'A-Za-z0-9 ._#-' | cut -c1-64)"
    fi
    [ -n "$by" ] || by="an admin"
    printf '%s000 %s\n' "$(date +%s)" "$by" > "$PIN_BY_FILE" 2>/dev/null || true

    printf '{"ok":true,"pinnedRef":"%s","pinnedSha":"%s"}\n' \
        "$(json_str "$ref")" "$sha"
}

case "$verb" in
    status)    do_status ;;
    telemetry) do_telemetry ;;
    configreport) do_configreport ;;
    kick)      do_kick ;;
    deploy)    do_deploy ;;
    branches)  do_branches ;;
    switchref) do_switchref ;;
    *)
        echo "dispatch: unknown verb '${verb:-<empty>}'" >&2
        exit 2
        ;;
esac

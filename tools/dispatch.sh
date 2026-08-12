#!/usr/bin/env bash
#
# The SSH forced-command dispatcher -- the ONE channel from Ringmaster to the
# game host. authorized_keys pins the Ringmaster key to:
#
#   command="/opt/misc/fivem-br-gamemode/tools/dispatch.sh",no-port-forwarding,\
#   no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... ringmaster
#
# so even a stolen key runs ONLY this script and never a shell. This reads the
# requested verb from $SSH_ORIGINAL_COMMAND, switches on a FIXED set, and NEVER
# eval's it. An unrecognised verb exits non-zero. The forced-command line in
# authorized_keys is the outer boundary; this case statement is the inner one.
#
# SLICE 1 IS READ-ONLY. The verb set is EXACTLY `status` and `telemetry` --
# nothing that can change a running game. There is deliberately no stop, no
# restart, no config. verify.sh greps this file to enforce that the set has not
# grown, so the read-before-write boundary is mechanical rather than a promise.
# The dangerous verbs arrive in Slice 4, behind an audit log.

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

# First word only. Arguments are ignored entirely in Slice 1 (neither verb
# takes one), and the value is only ever MATCHED against the case below, never
# executed -- so a payload in $SSH_ORIGINAL_COMMAND cannot become a command.
verb="${SSH_ORIGINAL_COMMAND%% *}"

# --- helpers -----------------------------------------------------------------

# The FXServer process id, or empty. pgrep on the musl loader that actually
# runs it (see the process list in DEPLOY.md's crash notes).
fxserver_pid() {
    pgrep -f 'cfx-server/FXServer' 2>/dev/null | head -1
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

    printf '{"running":%s,"pid":%s,"uptimeSec":%s,"commit":"%s","behindMain":%s,"hostUptimeSec":%s}\n' \
        "$running" "${pid:-0}" "$uptime" "$commit" "$behind" "$host_uptime"
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

case "$verb" in
    status)    do_status ;;
    telemetry) do_telemetry ;;
    *)
        echo "dispatch: unknown verb '${verb:-<empty>}'" >&2
        exit 2
        ;;
esac

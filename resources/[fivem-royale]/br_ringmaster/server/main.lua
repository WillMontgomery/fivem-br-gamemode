-- Ringmaster, game side: bootstrap and identity.
--
-- This resource has one job in Slice 1 -- tell the admin console what is
-- happening, and change nothing. There is no command handler here, no
-- DropPlayer, no deferral, no write path of any kind, and verify.sh has a gate
-- that fails the build if that stops being true. Slice 2 opens the other
-- direction; until then a compromised console can, at absolute worst, read.

BR = BR or {}
BR.Ring = BR.Ring or {}

-- ---------------------------------------------------------------------------
-- The boot epoch.
--
-- BR.Outbox restarts its sequence counter at 0 in new(), which is correct for
-- the queue and useless for the receiver: Ringmaster dedupes on `seq`, and
-- tools/deploy.sh instructs a `restart` after every deploy, so every deploy
-- would silently hand the ingest endpoint a fresh run of sequence numbers it
-- has already seen -- and it would drop them as duplicates. The first N events
-- after every restart, gone, with nothing anywhere saying so.
--
-- So every envelope carries (bootEpoch, seq) and the receiver dedupes on the
-- pair. The epoch has to be unique per RESOURCE START, not per host and not per
-- day, hence a wall-clock second plus a nonce: two restarts inside the same
-- second are entirely normal when a deploy script is doing them.
-- ---------------------------------------------------------------------------

local function makeBootEpoch()
    -- Three independent sources, because ANY ONE of them varying is enough and
    -- each fails in a different situation:
    --
    --   os.time()       seconds. Distinguishes restarts across a process
    --                   boundary, and is the only source still meaningful after
    --                   FXServer itself restarts. Available server-side -- it is
    --                   the CLIENT that has no `os` library.
    --   GetGameTimer()  milliseconds since FXServer started, so it separates two
    --                   `restart br_ringmaster` calls inside the same second.
    --                   Resets to ~0 when FXServer does, which is why os.time()
    --                   is also here.
    --   a fresh table's address, which differs per allocation and per Lua state.
    --
    -- THE OBVIOUS VERSION OF THIS WAS WRONG and the test caught it: seeding
    -- math.randomseed() from os.clock() and taking math.random() collided 185
    -- times in 200, because os.clock() is CPU time and barely moves between two
    -- restarts -- so the same seed produced the same "random" number. A boot
    -- epoch that repeats is worse than none at all: Ringmaster dedupes on
    -- (bootEpoch, seq), so a repeat means the events after a restart are
    -- silently discarded as duplicates of the ones before it.
    local addr = tostring({}):match('0x(%x+)') or tostring(math.random(0, 999999))

    return ('%d-%d-%s'):format(os.time(), GetGameTimer(), addr)
end

BR.Ring.bootEpoch = makeBootEpoch()

--- Wall clock, and the game clock reading taken at the same instant.
---
--- EVERY TIMESTAMP THIS PROJECT PRODUCES IS GetGameTimer(), which is
--- milliseconds since server start. That is the right call inside the game --
--- one clock on both sides, and /brperf reads the same everywhere -- and it is
--- useless the moment it leaves the box. An audit row timestamped 4281003 is
--- not a timestamp, and nobody notices until they open an incident from last
--- Tuesday.
---
--- So the envelope carries both readings once, and Ringmaster converts every
--- per-event `at` with `wallMs + (at - gameMs)`. Sampling them together is the
--- whole point; two separate calls later would drift.
--- @return number wallMs  unix milliseconds
--- @return number gameMs  GetGameTimer() at the same instant
function BR.Ring.clockPair()
    return os.time() * 1000, GetGameTimer()
end

-- ---------------------------------------------------------------------------
-- Identity capture.
--
-- CAPTURE ONLY, DELIBERATELY. This registers `playerConnecting` -- the first
-- handler on that event in the project -- but never calls `deferrals`, never
-- refuses anyone, and never blocks. The ban gate is Slice 2 and it is a real
-- design problem of its own (a deferral has no timeout, so a lookup that never
-- resolves hangs the player on "connecting" forever). None of that is here.
--
-- Why `playerConnecting` rather than `playerJoining`: the roster's join hook
-- fires once the player is in, and this needs to run at least once for someone
-- who bounces off a full server -- knowing that a license TRIED to connect is
-- moderation-relevant on its own.
-- ---------------------------------------------------------------------------

BR.Ring.seen = {}   -- [license] = { name, byKind, ordered, firstSeen, lastSeen }
BR.Ring.licenseBySrc = {}   -- [src] = license, so a drop can be attributed

--- How many distinct licenses this process has observed. For the health dump.
function BR.Ring.seenCount()
    local n = 0
    for _ in pairs(BR.Ring.seen) do n = n + 1 end
    return n
end

--- Record who just connected, keeping only allowlisted identifier types.
---
--- The allowlist lives in br_lib/shared/identity.lua and notably excludes `ip`.
--- That is a product decision (no network-location data is held on players) and
--- it is written as "keep these seven" rather than "skip ip", so an identifier
--- type FiveM adds next year is excluded by construction rather than collected
--- by default.
--- @param src number|string
function BR.Ring.capture(src)
    local byKind, ordered = BR.Identity.ofPlayer(src)

    local license = BR.Identity.qualified('license', byKind.license)
    if not license then
        -- No license means nothing durable to file this under. Inventing a key
        -- would be worse than dropping it: a profile under a guessed identifier
        -- is a ban against the wrong human waiting to happen.
        return nil
    end

    -- Remembered per SOURCE as well as per license, because playerDropped can
    -- no longer read identifiers off a connection that is already closing.
    BR.Ring.licenseBySrc[tonumber(src) or src] = license

    local wallMs = BR.Ring.clockPair()
    local rec = BR.Ring.seen[license]

    if rec then
        rec.name     = GetPlayerName(src) or rec.name
        rec.byKind   = byKind
        rec.ordered  = ordered
        rec.lastSeen = wallMs
        --[[
            RECONNECTS ANNOUNCE THEMSELVES TOO, and this is a bug fix rather
            than a widening.

            `BR.Ring.seen` is per PROCESS, so the second time somebody joins
            without a server restart this branch ran and emitted nothing. The
            console opens a session on player_seen and closes it on
            player_left -- so a reconnect closed a session that had never been
            opened, `sessionStartedAt` was nil, the computed length was 0, and
            the session count incremented by zero. Every player after their
            first join of a process accrued no playtime at all, forever, and
            the profile page rendered that as a measurement.

            The identity payload is small and connects are rare. Sending it
            every time is cheaper than a second event kind that exists only to
            say "the same person again".
        ]]
        if BR.Ring.emitSeen then
            BR.Ring.emitSeen(license, rec)
        end
    else
        BR.Ring.seen[license] = {
            name      = GetPlayerName(src) or 'Unknown',
            byKind    = byKind,
            ordered   = ordered,
            firstSeen = wallMs,
            lastSeen  = wallMs,
        }
        -- First sighting this process: announce it to the push layer, which
        -- turns it into a player_seen event -- the one that teaches the
        -- console which Discord id belongs to which license. Reconnects
        -- update the record without re-announcing.
        if BR.Ring.emitSeen then
            BR.Ring.emitSeen(license, BR.Ring.seen[license])
        end
    end

    return license
end

AddEventHandler('playerConnecting', function()
    -- No deferrals.defer(), no refusal, no wait. Reading the identifier list is
    -- synchronous and cheap, and a connect handler that blocks is a connect
    -- handler that eventually strands somebody.
    BR.Ring.capture(source)
end)

AddEventHandler('playerDropped', function()
    --[[
        NORMALISED, BECAUSE THE WRITE WAS AND THE READ WAS NOT.

        capture() stores under `tonumber(src) or src` -- a NUMBER. `source` in
        an event handler arrives as a STRING, and in Lua t[5] and t["5"] are
        different keys. So this lookup missed every single time: `license` came
        back nil, the handler returned early, and `emitLeft` was never called.

        The console accumulates connected time on session CLOSE, so with no
        close ever arriving, sessions and playtime sat at 0 for every player
        forever -- which is exactly what was reported, twice, after two separate
        fixes to other parts of this same path (ringmaster#6).

        Both ends are normalised now rather than only one, which is the actual
        lesson: a map whose writer normalises and whose reader does not is a map
        that silently holds nothing.
    ]]
    local src = tonumber(source) or source

    -- THE LICENSE IS READ FROM THE MAP, NOT FROM THE PLAYER. By the time this
    -- fires the connection is already going away, and GetPlayerIdentifiers can
    -- return an empty list -- which would silently close nobody's session and
    -- look exactly like the event never firing. capture() recorded it while
    -- the player was still there, which is the only moment it is reliable.
    local license = BR.Ring.licenseBySrc[src]
    BR.Ring.licenseBySrc[src] = nil
    if not license then return end

    -- Only if nobody else is holding the same license: a reconnect that races
    -- a drop would otherwise close the session the new connection just opened.
    for _, other in pairs(BR.Ring.licenseBySrc) do
        if other == license then return end
    end

    if BR.Ring.emitLeft then BR.Ring.emitLeft(license) end
end)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    -- Our own scheduler instance, not br_core's. FiveM gives each resource
    -- its own Lua state, so this registry, its /brperf accounting and its
    -- error-suspension are all separate -- a wedged moderation job is
    -- invisible to the gamemode's numbers, and a br_core fault does not stop
    -- this clock. The push job registers into it in the next PR.
    BR.Sched.start()

    local lines, healthy = BR.Ring.Config.report()

    print('[br_ringmaster] ----------------------------------------')
    print(('[br_ringmaster] boot epoch %s'):format(BR.Ring.bootEpoch))
    for _, l in ipairs(lines) do
        print('[br_ringmaster] ' .. l)
    end

    if not healthy then
        -- Loud, but not fatal. Same shape as br_stats/server/db.lua's missing
        -- oxmysql banner: say exactly what is off and exactly what to set, then
        -- get out of the way of the match.
        print('[br_ringmaster]')
        print('[br_ringmaster] Ringmaster is OFF. Matches are unaffected.')
    end
    print('[br_ringmaster] ----------------------------------------')
end)

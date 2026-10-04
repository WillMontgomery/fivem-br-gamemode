--[[
    Emotes, the server half: who is dancing, and who gets to hear about it.

    Owner, 2026-10-02 (#215, "Scope v2"): one PR with the complete SOLO system.
    "Anywhere except the lobby, on foot only." Up to eight dances on a wheel,
    bought in the Market for 250 Volts each, one license-free track per dance.
    Emotes are a Season 2 feature (#388, owner 2026-10-04): every door in this
    file asks BR.Season.has('emotes') -- never the dev convars, never BR.Dev,
    never the season number itself -- so the `emotes` row in
    br_lib/config/seasons.lua opens or shuts all of them at once.
    tools/check_emote_gate.lua fails the build when one does not ask.

    ═══ THE CLIENT ASKS AND THE SERVER PUBLISHES ═══

    EMOTE_PLAY carries a catalogue id and nothing else. Ownership, the wheel
    slot, the player's state, the seat, an item channel and the position are all
    resolved here, and an accepted play becomes one EMOTE_RECORD:
    { src, id, tStart, durationMs, x, y, z, tSent, tEnd? }. The stop is COMPUTED
    by every client at tStart + durationMs and is never messaged; only an EARLY
    stop re-sends the record with `tEnd` stamped on it.

    ═══ THE RECORD GOES TO THE PEOPLE IN EARSHOT, NOT TO THE MATCH ═══

    x/y/z is a position, and server/roster.lua deliberately withholds positions
    from clients that could not already see the player. So a record goes to the
    dancer, to players in the same routing bucket within sendRadiusM of it (with
    a roster position fresh enough to trust), and to anybody spectating a player
    that close. Somebody who walks into range mid-dance is handed the record by
    the sweep, with `tSent` stamped so their client can seek into the track; and
    an early stop goes to EVERYBODY the start reached, out of range or not, so
    nobody is left hearing a dance that ended.

    NO SERVER-SIDE MOVEMENT OR DEATH CHECK. Some clips carry root motion, and a
    death on the warmup pad keeps the player WARMUP. The dancer's own client
    cancels on moving, aiming, a vehicle and the rest; what the sweep re-checks
    is what this side knows for certain -- state, seat, item and the gate -- and
    a dance is capped at durationMs whatever a modified client claims.

    CONSOLE ONLY, NO TOASTS. A refused play is pre-checked by the client, so a
    refusal here is a race or a modified client and earns one console line. The
    player-facing copy lives in server/market.lua.
]]

BR = BR or {}
BR.Emotes = BR.Emotes or {}

--- The config is a shared script listed before every server file, so this
--- file only ever loads with it present (unlike server/market.lua).
local C = BR.Config.Emotes

--- src -> { rec = <the record>, bucket = integer|nil, sentTo = { [src] = true } }
local active = {}

--- src -> { since, n }: PLAYs in the current window.
local rate = {}

-- ---------------------------------------------------------------------------
-- Who hears a dance
-- ---------------------------------------------------------------------------

--- A player's routing bucket, or nil. Read through pcall, as
--- server/vehicles.lua reads it: a source that has just dropped makes the
--- native throw rather than answer.
--- @param s integer
--- @return integer|nil
local function bucketOf(s)
    local ok, b = pcall(GetPlayerRoutingBucket, tostring(s))
    if ok then return b end
    return nil
end

--- Is a roster entry close enough to a record to be sent it?
---
--- A STALE POSITION IS NOT CLOSE. The roster samples at 4 Hz and keeps the last
--- point when the ped reads 0, so an old sample can be anywhere; such a player
--- is picked up by the sweep once a fresh one arrives.
--- @param e table
--- @param rec table
--- @param now integer
--- @return boolean
local function near(e, rec, now)
    if type(e.pos) ~= 'table' then return false end
    if now - (e.posAt or 0) > C.posFreshMs then return false end
    local dx = (tonumber(e.pos.x) or 0) - rec.x
    local dy = (tonumber(e.pos.y) or 0) - rec.y
    local dz = (tonumber(e.pos.z) or 0) - rec.z
    return dx * dx + dy * dy + dz * dz <= C.sendRadiusM * C.sendRadiusM
end

--- Should player `s` (roster entry `e`) be sent dance `a`?
---
--- ONE RULE FOR THE START, A LATE ARRIVAL AND NOTHING ELSE: the stop does not
--- ask it, because the stop goes to whoever the start reached.
---   1. the dancer always;
---   2. a spectator when the player they watch is in the dancer's routing
---      bucket and close to the dance -- the spectator's own ped is a corpse
---      wherever they fell. The bucket asked is the WATCHED player's, not the
---      spectator's, so an admin watching from the lobby still hears; without
---      it a spectator whose target stands near another match's dancer would
---      be sent that match's x/y/z, which the roster withholds (#215, rule 8);
---   3. anybody else in the dancer's routing bucket who is close. The bucket
---      test keeps out lobby-bucket players who still carry the matchId, and
---      lets in BUS riders, who share the warmup bucket.
--- @return boolean
local function wants(s, e, a, now)
    if s == a.rec.src then return true end
    local t = BR.Spectate and BR.Spectate.targetOf and BR.Spectate.targetOf(s)
    if t then
        local te = BR.Roster.get(t)
        return te ~= nil and a.bucket ~= nil and bucketOf(t) == a.bucket and near(te, a.rec, now)
    end
    return a.bucket ~= nil and bucketOf(s) == a.bucket and near(e, a.rec, now)
end

--- Hand dance `a` to everybody who wants it and has not had it.
---
--- ONE ROSTER WALK PER LIVE DANCE PER SWEEP. Fine at 48 players and a handful
--- of dancers; revisit at 2048.
--- @param a table
--- @param now integer
local function deliver(a, now)
    BR.Roster.each(nil, function(s, e)
        if not a.sentTo[s] and wants(s, e, a, now) then
            a.rec.tSent = now
            TriggerClientEvent(BR.Net.EMOTE_RECORD, s, a.rec)
            a.sentTo[s] = true
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Refusals and the rate cap
-- ---------------------------------------------------------------------------

--- One console line for a PLAY that is not published. No toast: the client
--- checked every one of these before it asked.
local function refused(src, id, why)
    print(('[br_core] emotes: %s play "%s" refused -- %s'):format(tostring(src), tostring(id), why))
end

--- A fixed window over C.playRate, the server/damage.lua shape. A wheel cannot
--- be released six times in ten seconds by a hand; a script can.
--- @return boolean  true when this PLAY is over the cap
local function overRate(src, now)
    local r = rate[src]
    if not r or now - r.since > C.playRate.windowMs then
        r = { since = now, n = 0 }
        rate[src] = r
    end
    r.n = r.n + 1
    return r.n > C.playRate.max
end

-- ---------------------------------------------------------------------------
-- Stopping
-- ---------------------------------------------------------------------------

--- End `src`'s dance early, telling everybody the start reached.
---
--- TO `sentTo`, NOT TO A RECOMPUTED AUDIENCE. A listener who has walked out of
--- range or boarded the bus since is still playing the track; only the record
--- with `tEnd` on it stops it. A dance already past its natural end sends
--- nothing -- every client has stopped it on its own.
--- @param src integer
--- @param why string  for the reader of this file; never shown
--- @return boolean  was a stop sent?
function BR.Emotes.stop(src, why)
    local a = active[src]
    if not a then return false end
    active[src] = nil
    local now = GetGameTimer()
    if now >= a.rec.tStart + a.rec.durationMs then return false end
    a.rec.tEnd = now
    a.rec.tSent = now
    for s in pairs(a.sentTo) do
        TriggerClientEvent(BR.Net.EMOTE_RECORD, s, a.rec)
    end
    return true
end

--- `src`'s live record, copied, with `sentTo` as a sorted array; or nil.
--- For tests and diagnostics: nothing in the game reads it.
--- @param src integer
--- @return table|nil
function BR.Emotes.active(src)
    local a = active[src]
    if not a then return nil end
    local out = {}
    for k, v in pairs(a.rec) do out[k] = v end
    local to = {}
    for s in pairs(a.sentTo) do to[#to + 1] = s end
    table.sort(to)
    out.sentTo = to
    return out
end

-- ---------------------------------------------------------------------------
-- The doors
-- ---------------------------------------------------------------------------

RegisterNetEvent(BR.Net.EMOTE_PLAY)
AddEventHandler(BR.Net.EMOTE_PLAY, function(d)
    local src = source
    if not BR.Season.has('emotes') then return end

    local entry = BR.Roster.get(src)
    if not entry then return end

    local now = GetGameTimer()
    if overRate(src, now) then return end

    local id = (type(d) == 'table' and type(d.id) == 'string') and d.id or ''
    local row = BR.Emotes.row(id)
    if not row then refused(src, id, 'no such emote') return end

    -- "Anywhere except the lobby" -- the warmup pad and the match, alive.
    if not C.states[entry.state] then
        refused(src, id, 'state ' .. tostring(entry.state))
        return
    end
    -- OWNED IS NOT ENOUGH: it has to be on the wheel (owner, "Scope v2").
    if not (BR.Market and BR.Market.slotOf and BR.Market.slotOf(src, id)) then
        refused(src, id, 'not on the wheel')
        return
    end
    -- "On foot only." The seat walk, not GetVehiclePedIsIn, which answers
    -- stale handles (server/vehicles.lua says why).
    if BR.Vehicles and BR.Vehicles.ridingIn and BR.Vehicles.ridingIn(entry.ped) then
        refused(src, id, 'in a vehicle')
        return
    end
    local inv = BR.Inv and BR.Inv.of and BR.Inv.of(src)
    if inv and inv.using then
        refused(src, id, 'using an item')
        return
    end
    if type(entry.pos) ~= 'table' or now - (entry.posAt or 0) > C.posFreshMs then
        refused(src, id, 'position not fresh')
        return
    end

    -- A NEW DANCE ENDS THE OLD ONE OUT LOUD, so its listeners get its tEnd
    -- rather than hearing two tracks from one player.
    if active[src] then BR.Emotes.stop(src, 'replaced') end

    local rec = {
        src = src, id = id, tStart = now, durationMs = row.durationMs,
        x = entry.pos.x + 0.0, y = entry.pos.y + 0.0, z = entry.pos.z + 0.0,
    }
    active[src] = { rec = rec, bucket = bucketOf(src), sentTo = {} }
    deliver(active[src], now)
end)

RegisterNetEvent(BR.Net.EMOTE_STOP)
AddEventHandler(BR.Net.EMOTE_STOP, function()
    local src = source
    if not BR.Season.has('emotes') then return end
    BR.Emotes.stop(src, 'asked')
end)

-- THE SWEEP: what this side can re-check about a live dance, and the late
-- arrivals. A closed gate stops every dance at once. This server's season is
-- fixed from boot, so in game that is a guard rather than an event; the suites
-- close it mid-dance to prove the stop.
BR.Sched.every(C.sweepMs, 'emotes.sweep', function()
    if next(active) == nil then return end
    local open = BR.Season.has('emotes')
    local now = GetGameTimer()
    for src, a in pairs(active) do
        if now >= a.rec.tStart + a.rec.durationMs then
            active[src] = nil
        elseif not open then
            BR.Emotes.stop(src, 'emotes are off')
        else
            local e = BR.Roster.get(src)
            local inv = e and BR.Inv and BR.Inv.of and BR.Inv.of(src)
            if not e then
                BR.Emotes.stop(src, 'gone')
            elseif not C.states[e.state] then
                BR.Emotes.stop(src, 'state')
            elseif BR.Vehicles and BR.Vehicles.ridingIn and BR.Vehicles.ridingIn(e.ped) then
                BR.Emotes.stop(src, 'vehicle')
            elseif inv and inv.using then
                -- An item channel ends a dance (owner question).
                BR.Emotes.stop(src, 'item')
            else
                deliver(a, now)
            end
        end
    end
end)

-- A LEAVER'S DANCE ENDS FOR ITS LISTENERS, and a leaver is nobody's listener:
-- FiveM recycles the id, and the next holder must not inherit a seat in
-- somebody's sentTo.
AddEventHandler('playerDropped', function()
    local src = source
    BR.Emotes.stop(src, 'dropped')
    rate[src] = nil
    for _, a in pairs(active) do a.sentTo[src] = nil end
end)

-- ---------------------------------------------------------------------------
-- bremotegrant: the console's hand
-- ---------------------------------------------------------------------------

local USAGE = '  usage: bremotegrant <player name|#serverId> <emoteId|all>'

--- Players whose name matches, as sorted { src, name } pairs.
local function named(pred)
    local out = {}
    BR.Roster.each(nil, function(s, e)
        local nm = tostring(e.name)
        if pred(nm:lower()) then out[#out + 1] = { src = s, name = nm } end
    end)
    table.sort(out, function(x, y) return x.src < y.src end)
    return out
end

--- The one player `q` names, or nil after saying why.
---
--- EXACT NAMES OR #id ONLY. A partial name lists candidates and grants
--- nothing, because there is no revoke: a dance handed to the wrong person
--- stays handed.
--- @param q string
--- @return integer|nil
local function resolve(q)
    local n = q:match('^#(%d+)$')
    if n then
        local s = math.tointeger(tonumber(n))
        if s and BR.Roster.get(s) then return s end
        print(('  bremotegrant: no player #%s connected'):format(n))
        return nil
    end

    local lq = q:lower()
    local exact = named(function(nm) return nm == lq end)
    if #exact == 1 then return exact[1].src end
    if #exact > 1 then
        print(('  bremotegrant: %d players are called "%s" -- use #<serverId>:'):format(#exact, q))
        for _, p in ipairs(exact) do print(('    %s (#%d)'):format(p.name, p.src)) end
        return nil
    end

    local near_ = lq ~= '' and named(function(nm) return nm:find(lq, 1, true) ~= nil end) or {}
    if #near_ == 0 then
        print(('  bremotegrant: nobody connected is called "%s"'):format(q))
        return nil
    end
    print(('  bremotegrant: nobody is called exactly "%s"; did you mean:'):format(q))
    for _, p in ipairs(near_) do print(('    %s (#%d)'):format(p.name, p.src)) end
    return nil
end

-- DEVGATE-EXEMPT (br_lib/shared/devgate.lua), SO THIS BODY IS THE GATE. Owner,
-- "Scope v2": the grant command sits behind the feature's gate like everything
-- else, and only that gate -- which is the season now (#388). Gated by devgate
-- as well, it would stay shut on a public box running a season that has
-- emotes. Console only, and registered restricted.
RegisterCommand('bremotegrant', function(src, args)
    if tonumber(src) ~= 0 then print('  bremotegrant is server-console only') return end
    if not BR.Season.has('emotes') then
        print(('  bremotegrant: emotes are off on this box (it runs Season %d; br_lib/config/seasons.lua)')
            :format(BR.Season.current()))
        return
    end

    args = args or {}
    if #args == 0 then
        print(('[br_core] bremotegrant: %d emotes'):format(#C.order))
        for _, id in ipairs(C.order) do
            local row = BR.Emotes.row(id)
            print(('  %s  %s  %d Volts  %dms  track: %s'):format(
                id, row.name, row.price, row.durationMs, row.track or 'none'))
        end
        print(USAGE)
        return
    end
    if #args == 1 then print(USAGE) return end

    -- FiveM splits on spaces, and player names have them.
    local which = args[#args]
    local q = table.concat(args, ' ', 1, #args - 1)
    if which ~= 'all' and not BR.Emotes.row(which) then
        print(('  bremotegrant: no emote "%s" -- run bremotegrant with no arguments for the list'):format(which))
        return
    end

    local t = resolve(q)
    if not t then return end
    -- CAPTURED ONCE. BR.Market.addOwned checks it before and after the write,
    -- so a recycled id mid-grant is refused rather than handed somebody else.
    local lic = BR.Roster.licenseOf(t)
    if not lic then print(('  bremotegrant: #%d has no license yet'):format(t)) return end
    local e = BR.Roster.get(t)
    local who = ('%s (#%d)'):format(tostring(e and e.name or '?'), t)

    local function line(id, ok, why)
        if ok then
            print(('[br_core] bremotegrant: %s %s -- granted'):format(who, id))
        elseif why == 'already owned' then
            print(('[br_core] bremotegrant: %s %s -- already owned'):format(who, id))
        else
            print(('[br_core] bremotegrant: %s %s -- failed: %s'):format(who, id, tostring(why)))
        end
    end

    if which ~= 'all' then
        BR.Market.addOwned(t, which, function(ok, why) line(which, ok, why) end, lic)
        return
    end

    -- 'all', ONE AT A TIME: each grant is asked when the last one answers, so
    -- a license change stops the run instead of racing sixteen writes.
    local granted, owned, failed = 0, 0, 0
    local function step(i)
        local id = C.order[i]
        if not id then
            print(('[br_core] bremotegrant: %s %d granted, %d already owned, %d failed')
                :format(who, granted, owned, failed))
            return
        end
        if BR.Market.owns(t, id) then
            owned = owned + 1
            line(id, false, 'already owned')
            return step(i + 1)
        end
        BR.Market.addOwned(t, id, function(ok, why)
            if not ok and why == 'player changed' then
                print(('  bremotegrant: #%d is somebody else now -- stopped'):format(t))
                return
            end
            if ok then granted = granted + 1
            elseif why == 'already owned' then owned = owned + 1
            else failed = failed + 1 end
            line(id, ok, why)
            step(i + 1)
        end, lic)
    end
    step(1)
end, true)

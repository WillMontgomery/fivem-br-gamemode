-- The world: the time of day and the sky -- the match's clock, and the console's
-- override of both.
--
-- PURE, AND THE SAME TABLE ON BOTH SIDES OF THE WIRE. server/world.lua holds the
-- authoritative override (brtime and brweather write it); every client holds a
-- mirror of it (client/world.lua receives BR.Net.WORLD_SET into it). Both keep
-- it in THIS table through THESE accessors, so "what time is it" has one
-- spelling in this repository rather than two that can drift.
--
-- ═══ WHY AN OVERRIDE RATHER THAN A SETTING ═══
--
-- Neither of these is server state in GTA. The clock is set per-client, by
-- br_core/client/natives.lua's clock writer, and the sky is written per-client
-- by client/storm.lua and br_environment/client/ipl.lua -- "Per-client weather,
-- like the storm's: nothing syncs it" (ipl.lua). There is no server-side value
-- to change; there is only a broadcast, and a client that has to be TOLD.
--
-- So the shape is: one override, held here, mirrored everywhere, and read by the
-- code that was already writing those two things. Nothing in this repository
-- grew a second writer for either -- the clock writer asks clockPlan() below,
-- and every weather write on a client goes through client/world.lua's
-- resolveSky. Two writers disagreeing about the clock is the bug this file
-- exists to not create.
--
-- ═══ THE MATCH CLOCK (#394) ═══
--
-- The lobby and the warmup pad stand still at BR.Config.World's hour:minute.
-- From bus start the clock runs, slower than GTA's own, from an ANCHOR the
-- server stamps once per match (BR.World.anchor) and sends with the match
-- state. Every client in the match works out the same time from the same
-- anchor, so nobody has to tick the clock over the network. The arithmetic for
-- that lives here, pure, so tools/test_shared.lua can run every branch of it.
--
-- ═══ WHAT IS NOT HERE ═══
--
-- A single native call, and no reference to `source`. This file loads into a
-- client state and a server state and a bare `lua` in tools/test_shared.lua, and
-- it must behave identically in all three.

BR = BR or {}
BR.World = BR.World or {}

local W = BR.World

-- ---------------------------------------------------------------------------
-- The rest time
-- ---------------------------------------------------------------------------

--- Where the clock stands in the lobby and on the warmup pad, and where every
--- bus departs: BR.Config.World's hour and minute, high noon as shipped.
---
--- CONFIG IS THE ONLY PLACE THE TIME IS WRITTEN DOWN. It used to be a pair of
--- constants here, and before that the literal `(12, 0, ...)` inside
--- client/natives.lua's per-frame rules.
---
--- READ AT CALL TIME, NOT AT LOAD. br_core's fxmanifest loads this file before
--- br_lib/config/match.lua, so a load-time read would see no config at all.
--- @return number hour, number minute
function W.restHM()
    local c = BR.Config.World
    return c.hour, c.minute
end

-- ---------------------------------------------------------------------------
-- The sky
-- ---------------------------------------------------------------------------

--- The fifteen weather names the engine accepts, clearest first.
---
--- ORDERED BY WHAT THEY LOOK LIKE rather than by the engine's internal index,
--- because the only thing that ever reads this order is a person staring at
--- `brweather` with no argument, deciding what to try next.
---
--- THE SNOW FOUR ARE REAL AND MOSTLY DO NOTHING. BLIZZARD, SNOW, SNOWLIGHT and
--- XMAS are accepted by the native and change the sky, the wind and the
--- particles -- but the white GROUND everybody expects from them is a texture
--- swap that ships with the Christmas DLC and is not loaded here, so they read
--- as a very cold storm over a green island. Listed anyway: refusing a name the
--- engine accepts would be this file inventing a rule.
W.WEATHERS = {
    'EXTRASUNNY', 'CLEAR', 'CLEARING', 'NEUTRAL', 'CLOUDS', 'SMOG',
    'OVERCAST', 'FOGGY', 'RAIN', 'THUNDER',
    'BLIZZARD', 'SNOW', 'SNOWLIGHT', 'XMAS', 'HALLOWEEN',
}

--- The same list as a set, for the parse.
W.WEATHER = {}
for _, name in ipairs(W.WEATHERS) do W.WEATHER[name] = true end

--- Who may claim the sky on a client, STRONGEST FIRST.
---
--- This is the whole of the conflict resolution, and it is an ORDER rather than
--- a scramble for the last write:
---
---   override  the console said so. It wins over everything, because the person
---             who typed it is standing in the world looking at the result.
---   storm     the ring caught somebody outside it. It wins over the island
---             because it is a gameplay signal and the island's is scenery.
---   island    br_environment's lobby/mainland choreography: OVERCAST hides the
---             mid-flight world swap, EXTRASUNNY is what the doors open on.
---
--- A source not on this list is not a claim; client/world.lua refuses it rather
--- than storing an unranked key that would never win and never be noticed.
W.SKY_SOURCES = { 'override', 'storm', 'island' }

W.SKY_SOURCE = {}
for _, src in ipairs(W.SKY_SOURCES) do W.SKY_SOURCE[src] = true end

--- Which claim on the sky wins, and how fast it should be blended in.
---
--- PURE OVER THE WHOLE TABLE, which is what makes the interesting case testable
--- off-engine: an override lifting has to hand the sky back to whatever the game
--- wanted underneath it, and "what the game wanted underneath it" is exactly the
--- claim that was still sitting in this table the whole time.
--- @param claims table  { override = { name, blend }, storm = ..., island = ... }
--- @return string|nil name
--- @return number|nil blend  seconds; 0 means snap
function W.resolveSky(claims)
    if type(claims) ~= 'table' then return nil, nil end
    for _, src in ipairs(W.SKY_SOURCES) do
        local c = claims[src]
        if type(c) == 'table' and c.name then
            return c.name, tonumber(c.blend) or 0.0
        end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- The override itself
-- ---------------------------------------------------------------------------

--- What is currently overridden. Absent fields mean "not overridden", which is
--- not the same as "overridden to the default" anywhere except in the result.
W.override = { hour = nil, minute = nil, weather = nil }

--- @param hour number @param minute number
function W.setTime(hour, minute)
    W.override.hour   = hour
    W.override.minute = minute
end

function W.clearTime()
    W.override.hour, W.override.minute = nil, nil
end

--- @param name string  already validated by parseWeather
function W.setWeather(name)
    W.override.weather = name
end

function W.clearWeather()
    W.override.weather = nil
end

--- The time the console has set, or the rest time when it has set none.
---
--- ALWAYS ANSWERS A PAIR. Read by server/world.lua's confirmation lines and by
--- clockPlan below; an unoverridden world answers the rest time.
--- @return number hour, number minute
function W.clockHM()
    local h = W.override.hour
    local m = W.override.minute
    if type(h) ~= 'number' or type(m) ~= 'number' then
        return W.restHM()
    end
    return h, m
end

--- Has the console set the time (`brtime`)?
--- @return boolean
function W.holdsTime()
    return type(W.override.hour) == 'number'
end

-- ---------------------------------------------------------------------------
-- The match clock (#394)
-- ---------------------------------------------------------------------------

W.DAY_SEC = 86400

--- The player states that stand still at the rest time. Everything after the
--- bus leaves -- aboard, falling, alive, downed, out -- runs from the anchor.
local HOLD_STATE = { [BR.PlayerState.LOBBY] = true, [BR.PlayerState.WARMUP] = true }

--- The anchor a match's clock runs from. The server stamps it ONCE, the moment
--- the match's bus departs, and sends it with the match state.
---
--- THE START AND THE RATE TRAVEL IN IT, rather than every client reading its
--- own config, so that the server's copy is the one every player in the match
--- runs from.
--- @param serverNow number  the server's GetGameTimer() at bus start
--- @return table { at, startSec, msPerMin }
function W.anchor(serverNow)
    local h, m = W.restHM()
    return {
        at       = serverNow,
        startSec = h * 3600 + m * 60,
        msPerMin = BR.Config.World.msPerGameMinute,
    }
end

--- Is this an anchor a clock can run from?
---
--- CHECKED ON ARRIVAL, because it came over the wire: a zero rate would divide
--- by nothing, and a half-built anchor would run a clock from nowhere.
--- @param a any
--- @return boolean
function W.validAnchor(a)
    return type(a) == 'table'
       and type(a.at) == 'number'
       and type(a.startSec) == 'number'
       and type(a.msPerMin) == 'number' and a.msPerMin > 0
end

--- The second of the day the anchor says it is, at server time `now`.
---
--- FRACTIONAL, and wrapped into one day: a match long enough to run past
--- midnight carries on into the next morning rather than off the clock.
--- @param a table  a valid anchor
--- @param now number  server time, ms (BR.Clock.now() on a client)
--- @return number seconds since midnight, 0 <= t < 86400
function W.timeAt(a, now)
    return (a.startSec + (now - a.at) * 60.0 / a.msPerMin) % W.DAY_SEC
end

--- A second of the day as the three whole numbers the clock native takes.
---
--- ALWAYS IN RANGE. FiveM silently drops a clock write with an hour of 24 or
--- more, or a minute or second of 60 or more (NativeFixes.cpp,
--- FixClockTimeOverrideNative), so a value that rounded up to the next day
--- would simply not land, with nothing to say so.
--- @param t number
--- @return integer hour, integer minute, integer second
function W.hms(t)
    local s = math.floor(t) % W.DAY_SEC
    return s // 3600, (s // 60) % 60, s % 60
end

--- How far `engine` is from `target`, in game seconds, signed, taking the
--- shorter way round midnight: 23:59:50 is ten seconds behind 00:00:00, not a
--- day ahead of it.
--- @param engine number @param target number
--- @return number  in [-43200, 43200)
function W.drift(engine, target)
    local d = (engine - target) % W.DAY_SEC
    if d >= W.DAY_SEC / 2 then d = d - W.DAY_SEC end
    return d
end

--- What the clock should be doing on this client right now.
---
--- THREE ANSWERS, and the writer in client/natives.lua acts on them:
---
---   hold  stand still at h:m. The console's `brtime`, the lobby, the warmup
---         pad, and anything with no anchor to run from.
---   run   run from `anchor` at `rate`; `sec` is where it should be now.
---   wait  there is an anchor but this client's estimate of the server's time
---         is not ready yet (BR.Clock.synced). Writing a time worked out from
---         an unsynced clock would put the sky somewhere arbitrary and then
---         snap it once the estimate settled; the writer leaves the engine
---         alone instead.
---
--- `key` IS WHAT "ONCE" MEANS. The writer sets the clock when the key changes
--- and never otherwise: for a hold it is the time held, for a run it is the
--- anchor. So BUS -> FREEFALL -> ALIVE -> DBNO -> OUT, all one anchor, is one
--- write.
---
--- A SPECTATOR RUNS FROM THE WATCHED PLAYER'S MATCH when the server sent that
--- anchor with the session (server/spectate.lua) -- an admin watching from the
--- lobby sees the match's sky, not the lobby's. A spectator with no such anchor
--- falls through to their own state's rule.
--- @param o table { state, anchor, spectating, watchAnchor, now, synced }
--- @return table { mode, why, key, h, m, anchor, rate, sec }
function W.clockPlan(o)
    o = o or {}

    if W.holdsTime() then
        local h, m = W.clockHM()
        return { mode = 'hold', why = 'brtime', h = h, m = m,
                 key = ('hold %d:%d'):format(h, m) }
    end

    local a, why = nil, nil
    if o.spectating == true and W.validAnchor(o.watchAnchor) then
        a, why = o.watchAnchor, 'spectating'
    elseif o.state ~= nil and not HOLD_STATE[o.state] then
        a, why = o.anchor, 'match'
    end

    if not W.validAnchor(a) then
        local h, m = W.restHM()
        local because = (o.state == nil or HOLD_STATE[o.state])
            and tostring(o.state or 'no state') or 'no anchor'
        return { mode = 'hold', why = because, h = h, m = m,
                 key = ('hold %d:%d'):format(h, m) }
    end

    if o.synced ~= true then
        return { mode = 'wait', why = 'server clock not synced yet', anchor = a }
    end

    return {
        mode = 'run', why = why, anchor = a, rate = a.msPerMin,
        sec  = W.timeAt(a, tonumber(o.now) or a.at),
        key  = ('run %s %s %s'):format(tostring(a.at), tostring(a.startSec),
                                       tostring(a.msPerMin)),
    }
end

--- The overridden weather, or nil when the game owns the sky.
--- @return string|nil
function W.weatherName()
    local w = W.override.weather
    if type(w) ~= 'string' then return nil end
    return w
end

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

--- The whole override, as it travels.
---
--- REBUILT WHOLE EVERY TIME, AND THAT IS THE RESET MECHANISM. `nil` cannot
--- travel in a table -- `{ hour = nil }` and `{}` are the same value, and a
--- payload of deltas could therefore never say "stop overriding the hour". So
--- the payload is the complete state and A MISSING KEY IS THE CLEAR, which is
--- the same rule server/roster.lua's squad beacon uses for bleedEndsAt and for
--- the same reason.
--- @return table
function W.payload()
    return {
        hour    = W.override.hour,
        minute  = W.override.minute,
        weather = W.override.weather,
    }
end

--- Take a payload as the whole truth.
---
--- VALIDATED ON ARRIVAL rather than trusted, even though the only sender is our
--- own server: a half-set hour (hour without minute) would make clockHM() answer
--- noon while holdsTime() said otherwise, and the two would disagree forever
--- with nothing to notice.
--- @param p table|nil
function W.applyPayload(p)
    p = type(p) == 'table' and p or {}

    local h, m = tonumber(p.hour), tonumber(p.minute)
    if W.validHour(h) and W.validMinute(m) then
        W.setTime(math.floor(h), math.floor(m))
    else
        W.clearTime()
    end

    if type(p.weather) == 'string' and W.WEATHER[p.weather] then
        W.setWeather(p.weather)
    else
        W.clearWeather()
    end
end

-- ---------------------------------------------------------------------------
-- Parsing what somebody typed
-- ---------------------------------------------------------------------------

--- @param n any @return boolean
function W.validHour(n)
    n = tonumber(n)
    return n ~= nil and n == math.floor(n) and n >= 0 and n <= 23
end

--- @param n any @return boolean
function W.validMinute(n)
    n = tonumber(n)
    return n ~= nil and n == math.floor(n) and n >= 0 and n <= 59
end

--- The words that put an override back.
---
--- `clear` IS DELIBERATELY NOT ONE OF THEM. CLEAR is a weather name the engine
--- accepts, so `brweather clear` has to mean the sky and nothing else --
--- a reset word that was also a value would make one of the two unreachable and
--- the other a surprise.
local RESET_WORD = { reset = true, default = true, off = true }

--- Read `brtime`'s arguments.
---
--- Four spellings, because all four are things a person types at 2am:
---   brtime            -- usage
---   brtime 21         -- 21:00
---   brtime 21 30      -- 21:30
---   brtime 21:30      -- 21:30
---   brtime reset      -- back to the pin
---
--- OUT OF RANGE IS REFUSED, NEVER CLAMPED, which is br_lib/config/overrides.lua's
--- rule for the same reason: a clamp answers a question the operator did not ask
--- and looks exactly like the verb not working.
--- @param a string|nil @param b string|nil
--- @return string kind  'usage' | 'reset' | 'set' | 'error'
--- @return number|nil hour
--- @return number|nil minute
--- @return string|nil err  set only for 'error'
function W.parseTime(a, b)
    if a == nil or a == '' then return 'usage' end

    local word = tostring(a):lower()
    if RESET_WORD[word] then return 'reset' end

    local hs, ms = word:match('^(%-?%d+):(%d+)$')
    if hs then
        b = ms
    else
        hs = word
    end

    local h = tonumber(hs)
    if h == nil then
        return 'error', nil, nil, ('"%s" is not a number of hours'):format(tostring(a))
    end
    if not W.validHour(h) then
        return 'error', nil, nil,
            ('%s is not an hour -- it runs 0 to 23'):format(tostring(hs))
    end

    local m = 0
    if b ~= nil and b ~= '' then
        m = tonumber(b)
        if m == nil then
            return 'error', nil, nil,
                ('"%s" is not a number of minutes'):format(tostring(b))
        end
        if not W.validMinute(m) then
            return 'error', nil, nil,
                ('%s is not a minute -- it runs 0 to 59'):format(tostring(b))
        end
    end

    return 'set', math.floor(h), math.floor(m)
end

--- Read `brweather`'s argument.
---
--- CASE-INSENSITIVE IN, CANONICAL OUT. The natives want the uppercase name and
--- nobody types uppercase, so the verb takes whatever was typed and the rest of
--- the system only ever sees a member of W.WEATHERS.
--- @param a string|nil
--- @return string kind  'usage' | 'reset' | 'set' | 'error'
--- @return string|nil name
--- @return string|nil err  set only for 'error'
function W.parseWeather(a)
    if a == nil or a == '' then return 'usage' end

    local word = tostring(a)
    if RESET_WORD[word:lower()] then return 'reset' end

    local name = word:upper()
    if not W.WEATHER[name] then
        return 'error', nil, ('%s is not a weather this game has'):format(word)
    end
    return 'set', name
end

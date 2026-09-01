-- The world override: the time of day and the sky, when somebody has said so.
--
-- PURE, AND THE SAME TABLE ON BOTH SIDES OF THE WIRE. server/world.lua holds the
-- authoritative override (brtime and brweather write it); every client holds a
-- mirror of it (client/world.lua receives BR.Net.WORLD_SET into it). Both keep
-- it in THIS table through THESE accessors, so "what time is it" has one
-- spelling in this repository rather than two that can drift.
--
-- ═══ WHY AN OVERRIDE RATHER THAN A SETTING ═══
--
-- Neither of these is server state in GTA. The clock is pinned per-client, by
-- br_core/client/natives.lua's per-frame NetworkOverrideClockTime, and the sky
-- is written per-client by client/storm.lua and br_environment/client/ipl.lua --
-- "Per-client weather, like the storm's: nothing syncs it" (ipl.lua). There is
-- no server-side value to change; there is only a broadcast, and a client that
-- has to be TOLD.
--
-- So the shape is: one override, held here, mirrored everywhere, and read by the
-- code that was already writing those two things. Nothing in this repository
-- grew a second writer for either -- the clock pin reads clockHM() instead of
-- the literal 12, and every weather write on a client goes through
-- client/world.lua's resolveSky. Two writers disagreeing about the clock is the
-- bug this file exists to not create.
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
-- The pin
-- ---------------------------------------------------------------------------

--- High noon, which is where the clock sits when nobody has overridden it.
---
--- THIS PAIR IS THE ONLY PLACE THE PINNED TIME IS WRITTEN DOWN. It used to be
--- the literal `(12, 0, ...)` inside client/natives.lua's per-frame rules; the
--- reset path needs the same two numbers, and a second copy of them is a second
--- copy to get wrong the day the pin moves.
W.DEFAULT_HOUR   = 12
W.DEFAULT_MINUTE = 0

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

--- The time the clock pin should write this frame.
---
--- ALWAYS ANSWERS A PAIR. The caller is a per-frame native call in
--- client/natives.lua and there is no useful "no answer" for it -- an
--- unoverridden world is noon, which is the pin it has always written.
--- @return number hour, number minute
function W.clockHM()
    local h = W.override.hour
    local m = W.override.minute
    if type(h) ~= 'number' or type(m) ~= 'number' then
        return W.DEFAULT_HOUR, W.DEFAULT_MINUTE
    end
    return h, m
end

--- Is the clock currently somewhere other than its pin?
--- @return boolean
function W.holdsTime()
    return type(W.override.hour) == 'number'
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

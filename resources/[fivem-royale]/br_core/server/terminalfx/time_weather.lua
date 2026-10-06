-- Season 2 terminals (#396), wave B: TIME & WEATHER, the server half. The
-- client half is client/terminalfx/time_weather.lua.
--
--   "Sets the time of day for everyone in the match, and the weather inside
--    the circle. Outside the circle, the storm's own weather stays. When it
--    ends, the match's own time and weather come back."
--                                               -- its page, time_weather_what
--   "whatever weather they set is only set while inside the storm [circle]"
--                                                  -- owner, 2026-10-05
--
-- THE TIME IS THE MATCH CLOCK'S, THROUGH ITS ONE WRITER (#394). Every client
-- runs its sky from the anchor the server stamped at bus start, `m.clock`,
-- which the 2 Hz digest, every state event, the snapshot and a spectator's
-- pushes all carry, and client/natives.lua's one clock writer writes once when
-- the anchor changes (BR.World.clockPlan's key). So the time of day is a new
-- anchor for the match: the chosen hour, running from now at the match's own
-- rate. When it ends the match's own anchor goes back -- the one it was
-- keeping all along, so the clock returns to where the match's own time has
-- run to meanwhile. Nothing on a client writes the clock for this.
--
-- THE WEATHER IS A SKY CLAIM, AND ONLY INSIDE THE CIRCLE. TERMINAL_SKY tells
-- the match the chosen weather; each client claims it as `terminal` in
-- client/world.lua's sky resolver only while its view is inside the storm's
-- zone, BELOW the storm's claim, so a player caught outside gets THUNDER
-- whatever was chosen. Clear is the base sky (`base`: EXTRASUNNY, or XMAS in
-- the festive months, #399).
--
-- ONE AT A TIME: a second run while one lasts replaces it -- its time, its
-- weather and its clock -- and the match's own clock is still the one that
-- comes back.
--
-- IT ENDS, AND NOTHING OF IT IS LEFT, when its time is up, when the match stops
-- PLAYING (the end screen included), or off Season 2: the server checks once
-- every fx.worldCheckMs, puts the match's own clock back and tells the match
-- the weather is over. A client also drops its claim on its own in the lobby.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- The second of the day a `time` choice sets (fx.skyTime), or nil.
--- @param choice string|nil
--- @return number|nil
local function secOf(choice)
    local hm = (fx().skyTime or {})[choice]
    if type(hm) ~= 'table' then return nil end
    return (tonumber(hm[1]) or 0) * 3600 + (tonumber(hm[2]) or 0) * 60
end

--- What TERMINAL_SKY carries for this match: the weather while one lasts.
local function payloadOf(m)
    local sky = m.terminalSky
    return { matchId = m.id, weather = sky and sky.weather or nil }
end

--- This match's Time & weather, as it stands, or nil.
---   base     the match's own clock anchor, which comes back at the end
---   anchor   the anchor this run set, now m.clock
---   weather  a weather name or a role, from fx.skyWeather
---   untilAt  when it ends, server time
--- @param m table
--- @return table|nil
function T.skyOf(m)
    return m and m.terminalSky or nil
end

--- Set the match's time and weather for `ms`.
--- @param m table
--- @param opts table  { time, weather, duration }
--- @param now number
--- @return boolean ok
function T.startSky(m, opts, now)
    local cur = m.terminalSky
    local base = cur and cur.base or m.clock
    local sec = secOf(opts.time)
    local weather = (fx().skyWeather or {})[opts.weather]
    local ms = math.floor((tonumber(opts.duration) or 0) * 1000)
    if not (BR.World.validAnchor(base) and sec and weather and ms > 0) then return false end
    local anchor = { at = now, startSec = sec, msPerMin = base.msPerMin }
    m.terminalSky = { base = base, anchor = anchor, weather = weather, untilAt = now + ms }
    m.clock = anchor
    BR.Broadcast.toMatch(m, BR.Net.TERMINAL_SKY, payloadOf(m))
    print(('[br_core] terminals: Time & weather in match %s -- %s, %s, %.0fs')
        :format(tostring(m.id), tostring(opts.time), weather, ms / 1000))
    return true
end

--- End it: the match's own clock back, and the weather over on every client.
--- The clock only if it is still this run's -- a match sent back to warmup by
--- `brforce` has no clock of its own to return to.
--- @param m table
function T.endSky(m)
    local sky = m.terminalSky
    if not sky then return end
    m.terminalSky = nil
    if m.clock == sky.anchor then m.clock = sky.base end
    BR.Broadcast.toMatch(m, BR.Net.TERMINAL_SKY, payloadOf(m))
    print(('[br_core] terminals: Time & weather in match %s is over'):format(tostring(m.id)))
end

T.FUNCTIONS.time_weather = {
    -- A match with no clock to run from cannot be given a time (none in
    -- PLAYING: the bus stamps one). A dev terminal outside a match is never
    -- refused.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        local sky = m.terminalSky
        if not BR.World.validAnchor(sky and sky.base or m.clock) then return 'unavailable' end
        return nil
    end,
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Time & weather ran on the dev terminal '
                    .. 'with no match to change'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        if not T.startSky(m, opts or {}, GetGameTimer()) then
            return { ok = false, code = 'unavailable' }
        end
        return { ok = true, code = 'done' }
    end,
}

if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().worldCheckMs or 1000, 'terminal.sky', function()
        local now = GetGameTimer()
        local live = on()
        BR.Server.eachMatch(function(m)
            local sky = m.terminalSky
            if sky and (not live or m.state ~= BR.MatchState.PLAYING or now >= sky.untilAt) then
                T.endSky(m)
            end
        end)
    end)
end

-- A client that restarts mid-match is told the weather again; its time comes
-- back with the match clock in the snapshot.
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() then return end
    local m = T.whereIs(src)
    if m and m.terminalSky then
        TriggerClientEvent(BR.Net.TERMINAL_SKY, src, payloadOf(m))
    end
end)

-- Season 2 terminals (#396), wave B: TIME & WEATHER, the server half. The
-- client half is client/terminalfx/time_weather.lua.
--
--   "The time and weather tool should allow either time or weather to be set.
--    Not both. Weather should be any weather the game engine allows, except
--    rain and thunder since those are reserved for the storm only. The
--    duration should be the remainder of the match"   -- owner, 2026-10-06
--   "whatever weather they set is only set while inside the storm [circle]"
--                                                  -- owner, 2026-10-05
--
-- ONE RUN, ONE THING: the `change` option says which -- `time` (its `time`
-- choice) or `weather` (its `weather` choice) -- and the registry offers the
-- other only under it (`when`, BR.Terminal.options). A run changes that one
-- and leaves the other as it stands: a later run that changes the weather
-- keeps an earlier run's time, and the other way round.
--
-- THE TIME IS THE MATCH CLOCK'S, THROUGH ITS ONE WRITER (#394). Every client
-- runs its sky from the anchor the server stamped at bus start, `m.clock`,
-- which the 2 Hz digest, every state event, the snapshot and a spectator's
-- pushes all carry, and client/natives.lua's one clock writer writes once when
-- the anchor changes (BR.World.clockPlan's key). So the time of day is a new
-- anchor for the match: the chosen hour, running from now at the match's own
-- rate. When the match ends its own anchor goes back -- the one it was keeping
-- all along -- for the end screen. Nothing on a client writes the clock.
--
-- THE WEATHER IS A SKY CLAIM, AND ONLY INSIDE THE CIRCLE. TERMINAL_SKY tells
-- the match the chosen weather; each client claims it as `terminal` in
-- client/world.lua's sky resolver only while its view is inside the storm's
-- zone, BELOW the storm's claim, so a player caught outside gets THUNDER
-- whatever was chosen. Each choice is an engine weather (fx.skyWeather, which
-- says which the engine has that are not offered, and why).
--
-- FOR THE REST OF THE MATCH: there is no clock of its own. It ends, and
-- nothing of it is left, when the match stops PLAYING (the end screen
-- included) or off Season 2: the server checks once every fx.worldCheckMs,
-- puts the match's own clock back and tells the match the weather is over. A
-- client also drops its claim on its own in the lobby.

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

--- The engine weather a `weather` choice names (fx.skyWeather), or nil: never
--- one that is not the engine's, and never the storm's two.
--- @param choice string|nil
--- @return string|nil
local function weatherOf(choice)
    local w = (fx().skyWeather or {})[choice]
    if not BR.World.WEATHER[w] or w == 'RAIN' or w == 'THUNDER' then return nil end
    return w
end

--- What TERMINAL_SKY carries for this match: the weather while one is set.
local function payloadOf(m)
    local sky = m.terminalSky
    return { matchId = m.id, weather = sky and sky.weather or nil }
end

--- This match's Time & weather, as it stands, or nil.
---   base     the match's own clock anchor, which comes back at the end
---   anchor   the anchor a time run set, now m.clock (nil: no time run)
---   time     that run's choice, a key of fx.skyTime ('day', 'dusk', 'night')
---   weather  an engine weather from fx.skyWeather (nil: no weather run)
--- @param m table
--- @return table|nil
function T.skyOf(m)
    return m and m.terminalSky or nil
end

--- Change the match's time of day or its weather, for the rest of the match:
--- the one `opts.change` names, the other left as it stands.
--- @param m table
--- @param opts table  { change = 'time', time } | { change = 'weather', weather }
--- @param now number
--- @return boolean ok
function T.startSky(m, opts, now)
    local cur = m.terminalSky or {}
    local base = cur.base or m.clock
    local nextSky = { base = base, anchor = cur.anchor, time = cur.time, weather = cur.weather }
    if opts.change == 'time' then
        local sec = secOf(opts.time)
        if not (BR.World.validAnchor(base) and sec) then return false end
        nextSky.anchor = { at = now, startSec = sec, msPerMin = base.msPerMin }
        nextSky.time = opts.time
        m.clock = nextSky.anchor
    elseif opts.change == 'weather' then
        local weather = weatherOf(opts.weather)
        if not weather then return false end
        nextSky.weather = weather
    else
        return false
    end
    m.terminalSky = nextSky
    BR.Broadcast.toMatch(m, BR.Net.TERMINAL_SKY, payloadOf(m))
    print(('[br_core] terminals: Time & weather in match %s -- %s, for the rest of the match')
        :format(tostring(m.id), opts.change == 'time' and tostring(opts.time) or nextSky.weather))
    return true
end

--- End it: the match's own clock back, and the weather over on every client.
--- The clock only if it is still a time run's -- a match sent back to warmup by
--- `brforce` has no clock of its own to return to.
--- @param m table
function T.endSky(m)
    local sky = m.terminalSky
    if not sky then return end
    m.terminalSky = nil
    if sky.anchor ~= nil and m.clock == sky.anchor then m.clock = sky.base end
    BR.Broadcast.toMatch(m, BR.Net.TERMINAL_SKY, payloadOf(m))
    print(('[br_core] terminals: Time & weather in match %s is over'):format(tostring(m.id)))
end

T.FUNCTIONS.time_weather = {
    -- A match with no clock to run from cannot be given a time (none in
    -- PLAYING: the bus stamps one); the weather needs none, so a listing (no
    -- choice yet) is never refused for it. A dev terminal outside a match is
    -- never refused.
    refuse = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if opts and opts.change == 'time' then
            local sky = m.terminalSky
            if not BR.World.validAnchor(sky and sky.base or m.clock) then return 'unavailable' end
        end
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
        local live = on()
        BR.Server.eachMatch(function(m)
            if m.terminalSky and (not live or m.state ~= BR.MatchState.PLAYING) then
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
    if m and m.terminalSky and m.terminalSky.weather then
        TriggerClientEvent(BR.Net.TERMINAL_SKY, src, payloadOf(m))
    end
end)

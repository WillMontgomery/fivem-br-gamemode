-- Season 2 terminals (#396), wave B: POWER OUTAGE, the server half. The client
-- half is client/terminalfx/power_outage.lua.
--
--   "Street lights, building lights and signs go dark for every player inside
--    the area you choose. Players outside the area keep their lights.
--    Vehicle headlights still work. The lights come back when it ends."
--                                               -- its page, power_outage_what
--
-- THE ENGINE'S BLACKOUT IS ONE SWITCH PER CLIENT, for the whole world it
-- draws (SET_ARTIFICIAL_LIGHTS_STATE). There is no turning off one district's
-- lamps for everyone. So the honest build is per player: a client whose view
-- is inside the chosen area turns its own lights off (vehicles excepted), and
-- one outside keeps its own -- which is what the page now says, rather than a
-- district going dark for the whole lobby.
--
-- THE AREAS (BR.TerminalSolve.outageArea, one spelling for both sides):
--   spot    within fx.outageRadiusM of the spot the player picked on the big
--           map, carried as `opts.at` (round 6, owner 2026-10-07: "Any use of
--           'near this terminal' is like, not useful for this gamemode" -- it
--           was `here`, around this terminal). The confirm box asks for the
--           spot only for this choice (the row's `spot`, with its `when`), and
--           a run of it without one is `bad_option`, nothing spent.
--   city    below the storm's city line (#381, BR.StormCityLine)
--   county  on it or above it
-- Several outages can run at once; a player in any of them is in the dark.
--
-- ONLY ON A TERMINAL'S NIGHT (round 4, owner 2026-10-06): "The power outage
-- tool should only work if someone else has set it to night time first". A
-- match runs from noon, so its own clock never makes a night; refused, spending
-- nothing (`no_night`), unless a Time & weather run has set night and its
-- clock still stands (BR.Terminal.terminalNight). Asked again when the loading
-- is over, so a day or dusk run landing meanwhile refunds it. An outage
-- already running is not ended by a later day: it is a switch on the lights,
-- not on the clock.
--
-- THE SERVER KEEPS THE CLOCK AND ENDS IT: TERMINAL_POWER sends the match the
-- live areas when one starts and whenever one ends -- its time up, the match no
-- longer PLAYING, or off Season 2 -- on a pass every fx.worldCheckMs, and to a
-- client that restarts while one lasts. An empty list is the lights back on.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- What TERMINAL_POWER carries for this match: every live area.
local function payloadOf(m)
    local list = {}
    local st = m.terminalPower
    for _, o in ipairs(st and st.list or {}) do list[#list + 1] = o.area end
    return { matchId = m.id, list = list }
end

local function send(m)
    BR.Broadcast.toMatch(m, BR.Net.TERMINAL_POWER, payloadOf(m))
end

--- The live outages in this match, oldest first: { { area, untilAt } }.
--- @param m table
--- @return table[]
function T.outagesOf(m)
    local st = m and m.terminalPower
    return st and st.list or {}
end

--- Start an outage over `area` for `ms`.
--- @param m table
--- @param area table  BR.TerminalSolve.outageArea's
--- @param ms number
--- @param now number
--- @param by integer|nil  who ran it: spared its persistent notice
function T.startOutage(m, area, ms, now, by)
    local st = m.terminalPower
    if not st then
        st = { list = {} }
        m.terminalPower = st
    end
    st.list[#st.list + 1] = { area = area, untilAt = now + ms, by = by }
    send(m)
    print(('[br_core] terminals: Power outage in match %s -- %s for %.0fs')
        :format(tostring(m.id), area.kind, ms / 1000))
end

--- Drop the outages that are over, every one of them when the match is not
--- playing or the season is not Season 2, and tell the match if any went.
--- @param m table
--- @param now number
--- @param live boolean  the season allows it
function T.endOutages(m, now, live)
    local st = m.terminalPower
    if not st then return end
    local keep = {}
    for _, o in ipairs(st.list) do
        if live and m.state == BR.MatchState.PLAYING and now < o.untilAt then keep[#keep + 1] = o end
    end
    if #keep == #st.list then return end
    st.list = keep
    if #keep == 0 then m.terminalPower = nil end
    send(m)
end

T.FUNCTIONS.power_outage = {
    -- Every choice has an area (the spot is the run's own), so a match is
    -- asked for, and its night (above). A dev terminal outside a match is never
    -- refused.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if not (T.terminalNight and T.terminalNight(m)) then return 'no_night' end
        return nil
    end,
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Power outage ran on the dev terminal '
                    .. 'with no match to darken'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        opts = opts or {}
        local x, y = nil, nil
        if opts.area == 'spot' then
            if not opts.at then return { ok = false, code = 'bad_option' } end
            x, y = opts.at.x, opts.at.y
        end
        local area = TS.outageArea(opts.area, x, y, fx().outageRadiusM or 1000.0)
        local ms = math.floor((tonumber(opts.duration) or 0) * 1000)
        if not area or ms <= 0 then return { ok = false, code = 'unavailable' } end
        T.startOutage(m, area, ms, GetGameTimer(), src)
        return { ok = true, code = 'done' }
    end,
}

if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().worldCheckMs or 1000, 'terminal.power', function()
        local now = GetGameTimer()
        local live = on()
        BR.Server.eachMatch(function(m)
            if m.terminalPower then T.endOutages(m, now, live) end
        end)
    end)
end

-- A client that restarts mid-match is sent the live areas again.
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() then return end
    local m = T.whereIs(src)
    if m and m.terminalPower then
        TriggerClientEvent(BR.Net.TERMINAL_POWER, src, payloadOf(m))
    end
end)

-- THE PERSISTENT NOTICE (round 4): every player in the fight standing in a
-- live outage's area -- by the server's own position sample, once a second,
-- so it comes and goes as they walk in and out -- until that outage ends. Not
-- the player who ran it (their squadmates in the area are in the dark too, and
-- told so). A client darkens by its VIEW (the shot, for a spectator); a player
-- in the fight stands where their view is.
T.impactSource(function(m, now, add)
    local st = m.terminalPower
    if not st then return end
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if not e.pos then return end
        for _, o in ipairs(st.list) do
            if now < o.untilAt and o.by ~= src and TS.inOutage(o.area, e.pos.x, e.pos.y) then
                add(src, 'impact_outage', o.untilAt)
            end
        end
    end)
end)

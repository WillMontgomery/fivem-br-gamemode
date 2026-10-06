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
--   here    within fx.outageRadiusM of this terminal (the player, at the dev
--           terminal: Supply drop's rule)
--   city    below the storm's city line (#381, BR.StormCityLine)
--   county  on it or above it
-- Several outages can run at once; a player in any of them is in the dark.
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

--- Where "this terminal" is: the session's terminal, or, for a terminal the
--- server does not know (the dev terminal), the player.
--- @return number|nil x, number|nil y
local function anchorOf(src, session)
    local t = T.site(session.terminalId)
    if t then return t.x, t.y end
    local e = BR.Roster.get(src)
    if e and e.pos then return e.pos.x, e.pos.y end
    return nil, nil
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
function T.startOutage(m, area, ms, now)
    local st = m.terminalPower
    if not st then
        st = { list = {} }
        m.terminalPower = st
    end
    st.list[#st.list + 1] = { area = area, untilAt = now + ms }
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
    -- Every choice has an area wherever the session is (a terminal always has
    -- a site), so only a match is asked for. A dev terminal outside a match is
    -- never refused.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
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
        local x, y = anchorOf(src, session)
        local area = TS.outageArea(opts.area, x, y, fx().outageRadiusM or 1000.0)
        local ms = math.floor((tonumber(opts.duration) or 0) * 1000)
        if not area or ms <= 0 then return { ok = false, code = 'unavailable' } end
        T.startOutage(m, area, ms, GetGameTimer())
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

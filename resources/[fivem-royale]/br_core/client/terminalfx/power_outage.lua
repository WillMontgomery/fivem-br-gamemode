-- Season 2 terminals (#396), wave B: POWER OUTAGE, the client half. The server
-- half is server/terminalfx/power_outage.lua, and it decides everything: which
-- areas are dark and until when. This file only asks whether this client's
-- view is in one of them, and turns its own lights with the answer.
--
-- ═══ THE ONE WRITER OF THE LIGHTS ═══
--
-- SET_ARTIFICIAL_LIGHTS_STATE turns off every artificial light this client
-- draws -- street lights, buildings, signs, the whole map at once -- and
-- _SET_ARTIFICIAL_LIGHTS_STATE_AFFECTS_VEHICLES(false) keeps vehicle lights out
-- of it, so headlights still work. Both are the engine's own switches, they
-- outlive this resource, and this is the only file that calls them
-- (tools/verify.sh's lights gate, by name and by hash): a second writer would
-- turn the lights back on in the dark, or leave them off after the outage.
--
-- WRITTEN ON A CHANGE ONLY: dark when the view enters an area, back when it
-- leaves, when the server's list goes empty, in the lobby, off Season 2, and
-- when br_core stops. The view is the storm's (BR.Storm.viewpoint: the shot
-- while a dead or out player spectates), so a spectator watching somebody in
-- the dark sees the dark.
--
-- ═══ WHAT IT COSTS ═══
--
-- One SLOW-band pass a second that returns at once while no outage is live and
-- the lights are on, which is every second of every match nobody ran this in.
-- With one live, the viewpoint read (two natives) and a comparison a second.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local TS = BR.TerminalSolve

--- The live outage areas the server sent, or nil when there are none.
local areas = nil

--- Are this client's lights off (by this file)?
local dark = false

--- THE SEASON, ASKED ONCE A SECOND (client/terminalfx.lua's reason).
local seasonOn = false
local function refreshSeason()
    seasonOn = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end
refreshSeason()

--- In a match this client can see the world of: a live or finished match, and
--- not a lobby bystander (client/storm.lua's activeRecord gate).
--- @return boolean
local function inMatch()
    local S = BR.State
    local ms = S and S.match and S.match.state
    if ms ~= BR.MatchState.PLAYING and ms ~= BR.MatchState.ENDED then return false end
    return S.me ~= nil and S.me.state ~= BR.PlayerState.LOBBY
end

--- The lights, written only when they change.
--- @param on boolean  true: dark
local function setDark(on)
    if on == dark then return end
    dark = on
    SetArtificialLightsState(on)
    SetArtificialLightsStateAffectsVehicles(not on)
end

--- Dark while the view is in any live area, lit otherwise.
local function settle()
    local want = false
    if areas and seasonOn and inMatch() and BR.Storm and BR.Storm.viewpoint then
        local p = BR.Storm.viewpoint()
        if p then
            for _, a in ipairs(areas) do
                if TS.inOutage(a, p.x, p.y) then
                    want = true
                    break
                end
            end
        end
    end
    setDark(want)
end

--- Are this client's lights off? For the suites.
--- @return boolean
function BR.TerminalFx.dark()
    return dark
end

RegisterNetEvent(BR.Net.TERMINAL_POWER)
AddEventHandler(BR.Net.TERMINAL_POWER, function(d)
    if type(d) ~= 'table' then return end
    local list = {}
    for _, a in ipairs(type(d.list) == 'table' and d.list or {}) do
        if type(a) == 'table' then list[#list + 1] = a end
    end
    areas = #list > 0 and list or nil
    settle()
end)

-- ONCE A SECOND, on client/terminalfx.lua's one SLOW pass (F.onSlow), as
-- every function file's client half does: no pass of its own.
BR.TerminalFx.onSlow(function()
    refreshSeason()
    if areas == nil and not dark then return end
    -- THE LOBBY ENDS IT HERE TOO: the server's last word may still be on its
    -- way when a player is already home.
    if not inMatch() then areas = nil end
    settle()
end)

-- The switches are the engine's and outlive this resource: a stop puts the
-- lights back.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    setDark(false)
end)

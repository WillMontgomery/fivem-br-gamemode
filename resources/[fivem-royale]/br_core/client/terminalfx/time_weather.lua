-- Season 2 terminals (#396), wave B: TIME & WEATHER, the client half. The
-- server half is server/terminalfx/time_weather.lua, and it decides
-- everything; this file only claims the sky it was told.
--
--   "Outside the circle, the storm's own weather stays."
--                                               -- its page, time_weather_what
--
-- THE WEATHER IS A CLAIM, NEVER A WRITE. client/world.lua is the one place this
-- client's sky is set: this file claims the chosen weather as `terminal`
-- (BR.World.want), ranked BELOW the storm's claim -- so a player caught outside
-- the circle gets THUNDER whatever was chosen -- and above the island's. A role
-- the storm holds for the rest of a match (its all-clear, `base`) yields to it
-- (br_lib/shared/world.lua's resolveSky). The ground's snow pass follows the
-- resolved weather there, as it always does (#399): white under the chosen
-- SNOW, bare under the chosen CLEAR, festive months or not.
--
-- ONLY WHILE THIS CLIENT'S VIEW IS INSIDE THE CIRCLE: the storm's own tick
-- measures where the view stands against the zone the wall draws -- the shot,
-- for a spectator, as the storm's sky follows it -- and keeps the answer
-- (BR.Storm.viewInside). Outside, during phase 1's free-loot hold too, there is
-- no claim, and the storm's own weather is the sky.
--
-- THE TIME IS NOT HERE: it is the match clock's anchor, which the server swaps
-- and client/natives.lua's one writer follows (#394).
--
-- ═══ WHAT IT COSTS ═══
--
-- One SLOW-band pass a second that returns at once while there is no weather
-- to claim and none claimed, which is every second of every match nobody ran
-- this in. With one, a comparison a second and a claim only when the answer
-- changes. No natives here at all.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

--- The weather the server says this match chose: an engine weather's name.
--- Nil while there is none.
local sky = nil

--- What this file claims now (BR.World.want's `terminal`), nil for nothing.
local claimed = nil

--- THE SEASON, ASKED ONCE A SECOND (client/terminalfx.lua's reason).
local seasonOn = false
local function refreshSeason()
    seasonOn = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end
refreshSeason()

--- In a match this client can see the sky of: a live or finished match, and
--- not a lobby bystander (client/storm.lua's activeRecord gate).
--- @return boolean
local function inMatch()
    local S = BR.State
    local ms = S and S.match and S.match.state
    if ms ~= BR.MatchState.PLAYING and ms ~= BR.MatchState.ENDED then return false end
    return S.me ~= nil and S.me.state ~= BR.PlayerState.LOBBY
end

--- Claim the weather while the view is inside the circle, release it
--- otherwise -- on a change only.
local function settle()
    local want = nil
    if sky and seasonOn and inMatch() and BR.Storm and BR.Storm.viewInside
        and BR.Storm.viewInside() == true then
        want = sky
    end
    if want == claimed then return end
    claimed = want
    local fx = BR.Config.Terminals.fx or {}
    BR.World.want('terminal', want, want and (fx.skyBlendSec or 5.0) or nil)
end

--- What this file claims, for the suites.
--- @return string|nil
function BR.TerminalFx.skyClaim()
    return claimed
end

RegisterNetEvent(BR.Net.TERMINAL_SKY)
AddEventHandler(BR.Net.TERMINAL_SKY, function(d)
    if type(d) ~= 'table' then return end
    local w = d.weather
    local W = BR.World
    -- A WEATHER THE ENGINE KNOWS, NEVER THE STORM'S TWO (round 4: "except
    -- rain and thunder since those are reserved for the storm only"):
    -- anything else is no claim at all. The server sends only these.
    if type(w) == 'string' and W.WEATHER[w] and w ~= 'RAIN' and w ~= 'THUNDER' then
        sky = w
    else
        sky = nil
    end
    settle()
end)

-- ONCE A SECOND, on client/terminalfx.lua's one SLOW pass (F.onSlow), as
-- every function file's client half does: no pass of its own.
BR.TerminalFx.onSlow(function()
    refreshSeason()
    if sky == nil and claimed == nil then return end
    -- THE LOBBY ENDS IT HERE TOO: the server's last word may still be on its
    -- way when a player is already home.
    if not inMatch() then sky = nil end
    settle()
end)

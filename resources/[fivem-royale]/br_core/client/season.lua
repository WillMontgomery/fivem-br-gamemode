-- The client half of the dev-mode `brseason` (#388): the F8 lines, and the one
-- local event this machine re-reads its season-dependent state on.
--
-- ═══ THE SEASON IS READ, NEVER TAKEN FROM THE MESSAGE ═══
--
-- br_core/server/season.lua moves the season in force and br_seasonServed
-- together, then tells every client (BR.Net.SEASON_SWITCHED). The two travel
-- separately, so either can land first, and the payload's number is printed
-- and handed to BR.Season.expect, nothing more: what this client RUNS is
-- BR.Season.current(), this client's copy of the replicated value
-- (br_lib/shared/season.lua), which moves when the value lands. So
-- `br:season:changed` is raised once, the moment that copy moves -- off the
-- convar listener when the value lands second, off the message when it lands
-- first.
--
-- ═══ WHO LISTENS ═══
--
--   client/keybinds.lua      maps a gated row its season has just opened, and
--                            re-pushes the table so the Settings screen shows
--                            or drops the emote wheel's key
--   br_ui/client/market.lua  re-sends the Market grid and the EMOTES flag (the
--                            Emotes tab and the Music slider)
--
-- client/loot.lua follows the copy itself (BR.Season.onChange), because the
-- season's first arrival matters to it too: a crate built as wood before a
-- Season 2 client knew its season is rebuilt as its box.
--
-- Everything else asks the gate at call time and needs no telling: the emote
-- wheel, playback and music (client/emotes.lua, client/emotewheel.lua) answer
-- the new season on their next pass, and client/emotes.lua's 'emotes.gate'
-- pass sees the flip as it does any other -- every one of those questions a
-- few table reads now, not a convar read. The lobby label is the server's
-- (server/lobby.lua sends it every 500 ms).
--
-- ═══ ONLY A MOVE IS A CHANGE ═══
--
-- The season's first arrival is not one: 'emotes.gate' already handles it,
-- and a client that has never seen a season has nothing to re-read. A garbled
-- read (nil) is skipped, not remembered, so the season it was is still the one
-- compared against when a real one lands.
--
-- ═══ A FEATURE SETTING IS NOT A SEASON CHANGE (#425) ═══
--
-- `brseason locker2 on|off|auto` moves one feature and leaves the season
-- number where it was, so `br:season:changed` is not raised for it: its two
-- listeners above follow rows the command does not take. The feature's own
-- followers hear the setting land through BR.Season.onChange -- Locker v2's
-- lobby tick asks its gate every pass anyway. BR.Net.SEASON_FEATURE is one F8
-- line on every client, and tells a runtime without the convar listener what
-- to wait for.

BR = BR or {}

--- The season this client last saw, or nil before the first one landed.
local seen = nil

--- Look at the season now: raise `br:season:changed` (season, before) when it
--- has moved off one this client already saw.
local function look()
    local now = BR.Season.current()
    if now == nil or now == seen then return end
    local before = seen
    seen = now
    if before ~= nil then TriggerEvent('br:season:changed', now, before) end
end

-- EVERY MOVE OF THIS CLIENT'S COPY, and only those: no pass asks on a timer.
BR.Season.onChange(look)

-- A switch was applied. One F8 line on every client -- dev-mode output, since
-- only the dev-mode command sends this -- and a re-read now, in case the value
-- landed first.
RegisterNetEvent(BR.Net.SEASON_SWITCHED)
AddEventHandler(BR.Net.SEASON_SWITCHED, function(d)
    if type(d) ~= 'table' then return end
    local n = math.tointeger(d.season)
    if n == nil then return end
    print(('[br_core] brseason: %s switched this server to Season %d'):format(tostring(d.by), n))
    BR.Season.expect(n)
    look()
end)

--- A setting in words, as br_core/server/season.lua prints it.
local PHRASE = {
    on   = 'on for this server, whatever the season',
    off  = 'off for this server, whatever the season',
    auto = 'back to auto for this server: it follows the season',
}

-- A feature setting was applied (#425). One F8 line on every client, as for a
-- switch, and the settings it carries handed to BR.Season.expect -- never
-- taken as this client's: those are br_seasonFeatures' as it lands.
RegisterNetEvent(BR.Net.SEASON_FEATURE)
AddEventHandler(BR.Net.SEASON_FEATURE, function(d)
    if type(d) ~= 'table' or type(d.id) ~= 'string' or not d.id:match('^[%a_][%w_]*$') then return end
    local words = PHRASE[d.to]
    if words == nil then return end
    print(('[br_core] brseason: %s set %s %s'):format(tostring(d.by), d.id, words))
    BR.Season.expect(nil, type(d.settings) == 'table' and d.settings or nil)
end)

-- One `brseason` answer, to the player who typed it.
RegisterNetEvent(BR.Net.SEASON_RESULT)
AddEventHandler(BR.Net.SEASON_RESULT, function(text)
    if type(text) ~= 'string' then return end
    print('[br_core] ' .. text)
end)

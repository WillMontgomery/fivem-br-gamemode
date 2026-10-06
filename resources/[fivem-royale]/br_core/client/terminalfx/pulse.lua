-- Season 2 terminals (#396), wave A: PULSE, the client half -- the marks on
-- this player's maps. Everything here is drawn from TERMINAL_PULSE
-- (server/terminalfx/pulse.lua); nothing is decided.
--
--   the marks   one per player the pulse found, moved on every push (about
--               once a second, for 30 seconds), in `art.pulse` and named
--               `pulse_blip`, with client/terminalfx.lua's helpers -- Scan's
--               way: moved, never rebuilt
--   the end     the server's empty push; behind it, this file's SLOW pass
--               takes them down in the lobby, off Season 2, or when the
--               pushes stop for three of their own periods
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing. The marks move when a push arrives; the SLOW check (a hook on
-- client/terminalfx.lua's one pass, not a loop callback of its own) returns
-- at once with none drawn.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

local function copy() return BR.Config.Terminals.copy end
local function art() return BR.Config.Terminals.art or {} end
local function fx() return BR.Config.Terminals.fx or {} end

--- The marks, keyed by the server id they stand for, and the last push.
local marks = {}
local pushedAt = 0

--- How many Pulse marks are up. For the suites.
--- @return integer
function F.pulseMarks()
    local n = 0
    for _ in pairs(marks) do n = n + 1 end
    return n
end

RegisterNetEvent(BR.Net.TERMINAL_PULSE)
AddEventHandler(BR.Net.TERMINAL_PULSE, function(d)
    if type(d) ~= 'table' or not F.on() then return end
    pushedAt = GetGameTimer()
    F.apply(marks, d.list, art().pulse or {}, copy().pulse_blip)
end)

-- ONCE A SECOND (client/terminalfx.lua's SLOW pass, F.onSlow), and nothing
-- at all with no mark up.
F.onSlow(function()
    if next(marks) == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    local quiet = GetGameTimer() - pushedAt > 3 * (fx().pulsePingMs or 1000)
    if lobby or quiet or not F.on() then F.clear(marks) end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    F.clear(marks)
end)

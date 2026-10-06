-- Season 2 terminals (#396), wave A: LOCKDOWN, the client half -- the fact,
-- as TERMINAL_LOCKDOWN tells it (server/terminalfx/lockdown.lua). Nothing is
-- decided here and nothing is drawn: client/yubikey.lua hands BR.TerminalFx
-- .lock() to BR.TerminalSolve.offlineWhy, the one online rule, so a terminal
-- a Lockdown has taken shows no blip on a key holder's map and its plate says
-- `locked` with nothing to hold.
--
-- It ends when the server says so. Behind that, the lobby, Season 1 and a
-- message that never came (a few seconds past the `leftMs` the server gave)
-- end it here too -- on client/terminalfx.lua's one SLOW pass (F.onSlow).
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing: one table, read once a second by client/yubikey.lua's SLOW pass.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

--- How long past the server's own end a lock may outlive a lost message.
local LATE_MS = 5000

--- { keep = id|nil, overdueAt } while a Lockdown is in force, else nil.
local lock = nil

--- The Lockdown in force in this player's match, as offlineWhy takes it:
--- { keep = id|nil }, or nil.
--- @return table|nil
function F.lock()
    return lock
end

RegisterNetEvent(BR.Net.TERMINAL_LOCKDOWN)
AddEventHandler(BR.Net.TERMINAL_LOCKDOWN, function(d)
    if type(d) ~= 'table' or not F.on() then return end
    if d.on ~= true then
        lock = nil
        return
    end
    local keep = BR.TerminalSolve.validId(d.keep) and d.keep or nil
    lock = { keep = keep, overdueAt = GetGameTimer() + (tonumber(d.leftMs) or 0) + LATE_MS }
end)

F.onSlow(function()
    if lock == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby or not F.on() or GetGameTimer() > lock.overdueAt then lock = nil end
end)

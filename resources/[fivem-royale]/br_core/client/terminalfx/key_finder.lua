-- Season 2 terminals (#396), wave A: KEY FINDER, the client half -- the marks
-- on this player's maps. Everything here is drawn from TERMINAL_KEYS
-- (server/terminalfx/key_finder.lua); nothing is decided.
--
--   the marks   one per Yubikey, where it was when Key finder ran: drawn with
--               client/terminalfx.lua's helpers (both maps), never moved, in
--               `art.keyFinder` and named `key_finder_blip`
--   the end     the server's own: one empty list when the two minutes are up
--               or the match ends. Behind it, this file's SLOW pass takes them
--               down in the lobby, off Season 2, and -- should that empty list
--               never arrive -- a few seconds after the `leftMs` the server
--               said they had.
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing. Marks are made when a push arrives; the SLOW pass returns at once
-- with none drawn.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

local function copy() return BR.Config.Terminals.copy end
local function art() return BR.Config.Terminals.art or {} end

--- How long past the server's own end a mark may outlive a lost clear.
local LATE_MS = 5000

--- The marks, keyed 1..n, and when they are overdue.
local marks = {}
local overdueAt = 0

local function clearAll()
    F.clear(marks)
end

--- How many Key finder marks are up. For the suites.
--- @return integer
function F.keyMarks()
    local n = 0
    for _ in pairs(marks) do n = n + 1 end
    return n
end

RegisterNetEvent(BR.Net.TERMINAL_KEYS)
AddEventHandler(BR.Net.TERMINAL_KEYS, function(d)
    if type(d) ~= 'table' or not F.on() then return end
    -- EVERY PUSH IS THE WHOLE SET: the run's list, or empty when it is over.
    clearAll()
    if type(d.list) ~= 'table' then return end
    local look = art().keyFinder or {}
    local name = copy().key_finder_blip
    for _, p in ipairs(d.list) do
        if BR.TerminalSolve.finite(p.x) and BR.TerminalSolve.finite(p.y) then
            marks[#marks + 1] = F.newMark(p.x + 0.0, p.y + 0.0, look, nil, name)
        end
    end
    if next(marks) == nil then return end
    overdueAt = GetGameTimer() + (tonumber(d.leftMs) or 0) + LATE_MS
end)

-- ONCE A SECOND, and nothing at all with no mark up: back in the lobby (the
-- match is over), Season 1, or a clear that never arrived.
BR.Loop.register(BR.Loop.SLOW, 'terminalfx.keys', function()
    if next(marks) == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby or not F.on() or GetGameTimer() > overdueAt then clearAll() end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    clearAll()
end)

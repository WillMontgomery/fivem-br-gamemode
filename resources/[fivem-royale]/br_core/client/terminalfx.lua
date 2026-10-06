-- Season 2 terminals (#396), client half of the built functions: WHAT THEY
-- PUT ON THIS PLAYER'S MAPS. Everything here is drawn from what the server
-- sends (server/terminalfx.lua); nothing is decided.
--
--   Scan        TERMINAL_SCAN, to the scanning squad alone: one mark per
--               opponent, moved on every push, for the rest of the match
--   the bounty  TERMINAL_BOUNTY, to everyone outside the bounty's squad: the
--               owner's blip 58 in colour 3. The bounty's own squad draws it
--               off the squad beacon instead (client/squadmates.lua, colour
--               69), and its panel mark is client/state.lua's.
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing. The marks move when a push arrives (every 2 s and 1 s), and the
-- SLOW band clears them in the lobby or when the pushes stop. No FRAME or TICK
-- work at all.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local isTrue = BR.NativeTruthy

local function copy() return BR.Config.Terminals.copy end
local function art() return BR.Config.Terminals.art or {} end
local function fx() return BR.Config.Terminals.fx or {} end

--- The marks, keyed by the server id they stand for: { big, mini }.
local scanMarks, bountyMarks = {}, {}
--- The match each set belongs to, and when it was last pushed.
local scanMatch, bountyMatch = nil, nil
local scanAt, bountyAt = 0, 0

local function removeBlip(b)
    if b and isTrue(DoesBlipExist(b)) then RemoveBlip(b) end
end

--- One mark on each map: display 3 is the pause map, 5 the minimap (the pair
--- client/yubikey.lua and client/airdrop.lua draw, which a playtest proved
--- shows on both).
local function newMark(x, y, look, colour, name)
    local pair = {}
    for i, display in ipairs({ 3, 5 }) do
        local b = AddBlipForCoord(x, y, 0.0)
        SetBlipSprite(b, look.sprite or 1)
        SetBlipColour(b, colour or look.colour or 1)
        SetBlipScale(b, look.scale or 1.0)
        SetBlipDisplay(b, display)
        SetBlipAsShortRange(b, false)
        if name then BR.Native.blipName(b, name) end
        pair[i] = b
    end
    return { big = pair[1], mini = pair[2] }
end

local function dropMark(mark)
    if not mark then return end
    removeBlip(mark.big)
    removeBlip(mark.mini)
end

local function clear(set)
    for k, mark in pairs(set) do
        dropMark(mark)
        set[k] = nil
    end
end

--- Move every mark in `set` to the list, make the new ones, drop the rest.
--- @param set table
--- @param list table  { { s, x, y } }
--- @param look table  art: sprite, colour, scale
--- @param name string|nil  the pause map legend's name
local function apply(set, list, look, name)
    local seen = {}
    for _, p in ipairs(type(list) == 'table' and list or {}) do
        local s = math.tointeger(p.s)
        if s and BR.TerminalSolve.finite(p.x) and BR.TerminalSolve.finite(p.y) then
            seen[s] = true
            local mark = set[s]
            if mark and isTrue(DoesBlipExist(mark.big)) then
                SetBlipCoords(mark.big, p.x + 0.0, p.y + 0.0, 0.0)
                SetBlipCoords(mark.mini, p.x + 0.0, p.y + 0.0, 0.0)
            else
                dropMark(mark)
                set[s] = newMark(p.x + 0.0, p.y + 0.0, look, nil, name)
            end
        end
    end
    for s, mark in pairs(set) do
        if not seen[s] then
            dropMark(mark)
            set[s] = nil
        end
    end
end

-- ═══ THE SHARED MARK HELPERS (wave A, 2026-10-06) ═══
--
-- The functions built after Scan and the bounty draw their marks in files of
-- their own under client/terminalfx/, with these four, so every terminal mark
-- is drawn the one way: a blip on each map, moved rather than rebuilt.
--
--   F.newMark(x, y, look, colour, name) -> mark   one mark, both maps
--   F.dropMark(mark)                              both of its blips gone
--   F.clear(set)                                  every mark in a set gone
--   F.apply(set, list, look, name)                a set made to match a push
F.newMark = newMark
F.dropMark = dropMark
F.clear = clear
F.apply = apply

--- THE SEASON, ASKED ONCE A SECOND (client/yubikey.lua's reason: a client's
--- BR.Season.has reads a replicated convar, a native, and the squad panel asks
--- F.mateBountyGlyph on every push).
local seasonOn = false
local function refreshSeason()
    seasonOn = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end
refreshSeason()

local function on()
    return seasonOn
end
--- The same answer, for the files under client/terminalfx/ (refreshed by this
--- file's SLOW pass, once a second).
F.on = on

--- How many marks of each kind are up. For the suites.
--- @return integer scans, integer bounties
function F.counts()
    local a, b = 0, 0
    for _ in pairs(scanMarks) do a = a + 1 end
    for _ in pairs(bountyMarks) do b = b + 1 end
    return a, b
end

--- The squad panel's bounty mark beside a mate, or nil: the beacon's `bounty`
--- bit, drawn as the art block's glyph. Read by client/state.lua.
--- @param bit boolean|nil
--- @return string|nil
function F.mateBountyGlyph(bit)
    if bit == true and on() then return art().bountyGlyph end
    return nil
end

-- ------------------------------------------------------------- the wire ---

RegisterNetEvent(BR.Net.TERMINAL_SCAN)
AddEventHandler(BR.Net.TERMINAL_SCAN, function(d)
    if type(d) ~= 'table' or not on() then return end
    if scanMatch ~= d.matchId then clear(scanMarks) end
    scanMatch, scanAt = d.matchId, GetGameTimer()
    apply(scanMarks, d.list, art().scan or {}, copy().scan_blip)
end)

RegisterNetEvent(BR.Net.TERMINAL_BOUNTY)
AddEventHandler(BR.Net.TERMINAL_BOUNTY, function(d)
    if type(d) ~= 'table' or not on() then return end
    if bountyMatch ~= d.matchId then clear(bountyMarks) end
    bountyMatch, bountyAt = d.matchId, GetGameTimer()
    apply(bountyMarks, d.list, art().bounty or {}, copy().bounty_blip)
end)

--- THE WAVE A FILES' OWN SLOW CHECKS (client/terminalfx/), run from this
--- file's one SLOW pass rather than each registering a loop callback of its
--- own: a registered callback is the loop runner's bookkeeping every second
--- however little it does, and tools/perf_client.lua's budget counts it. Each
--- hook returns at once with nothing drawn.
local slowHooks = {}

--- Run `fn` on this file's SLOW pass, after the season has been refreshed.
--- @param fn fun()
function F.onSlow(fn)
    slowHooks[#slowHooks + 1] = fn
end

-- ONCE A SECOND: in the lobby, off Season 2, or when the pushes have stopped
-- for three of their own periods (a match torn down between pushes, a
-- server that went quiet), the marks go -- this file's and, through
-- F.onSlow, the wave A files'.
BR.Loop.register(BR.Loop.SLOW, 'terminalfx.clear', function()
    refreshSeason()
    for i = 1, #slowHooks do slowHooks[i]() end
    if next(scanMarks) == nil and next(bountyMarks) == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    local now = GetGameTimer()
    if lobby or not on() or now - scanAt > 3 * (fx().scanPingMs or 2000) then
        clear(scanMarks)
    end
    if lobby or not on() or now - bountyAt > 3 * (fx().bountyPingMs or 1000) then
        clear(bountyMarks)
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    clear(scanMarks)
    clear(bountyMarks)
end)

-- Declared for client/squadmates.lua: the look a mate with a bounty wears on
-- this squad's maps (the owner's blip 58, colour 69).
function F.mateBountyLook()
    local b = art().bounty or {}
    return b.sprite or 58, b.mateColour or 69, b.scale or 1.0
end

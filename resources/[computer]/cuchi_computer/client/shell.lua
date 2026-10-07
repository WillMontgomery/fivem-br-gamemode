-- BR (fivem-royale, #396): THE WHOLE LUA HALF OF THIS RESOURCE.
--
-- Not upstream code -- an added file, listed under `added` in ../VENDOR.json.
-- It replaces upstream's client/main.lua, client/nui.lua and
-- client/overrides.lua, which opened the computer from a framework item, a
-- prop or a fixed position, asked a framework server callback for a fake IP,
-- and ran the roleplay apps. None of that exists here.
--
-- ═══ WHAT THIS FILE IS ═══
--
-- A shell. It shows the desktop when it is told to, holds NUI focus while the
-- desktop is up, and forwards what the page asks. It decides nothing: which
-- terminal, which functions, whether one may run, and what running it does are
-- all br_core's, and br_core asks the server. The contract, end to end, is
-- docs/terminals.md.
--
-- EXPORTS (called by br_core's client, client/terminal.lua)
--   Open(state, copy, catalog, desktop) -> ok, why
--                                  boot the desktop; the player opens the app
--       state   = { terminalId, functions = { { id, available, reason } },
--                   keyHeld, squadUsed, squadMatch, volts, running?, player,
--                   match }
--       copy    = the player-facing lines, from br_lib/config/terminals.lua
--       catalog = { functions, categories, currency, pageLoad }: the
--                 function registry, the same file's rows, which the app
--                 draws its cards and pages from, and the range its browser
--                 picks a page load's length in (pageLoad = { minMs, maxMs })
--       desktop = { bootMinMs, bootMaxMs, clock = { h, m } }: how long a boot
--                 may take (the page picks in the range) and the game's time
--   Update(state)                  the server's new view, while open
--   Result(result) -> shown        the answer to a run, while open; false when
--                                  nothing is up to show it. A last word
--                                  carries `toast`, the server's text for it
--   Clock(h, m)                    the game's hour and minute, for the taskbar
--   Close(why) -> ok               take it down (death, storm, teardown); the
--                                  storm's close ('offline') plays a blue
--                                  screen and a power-off first (below)
--   IsOpen() -> boolean
--   Hide() -> ok                   out of sight while the player picks a spot on
--                                  the big map (round 4): the page hidden with
--                                  the app and its box still in it, NUI focus
--                                  released; still open. False when not open
--                                  or already hidden
--   Show(picked) -> ok             back, NUI focus taken again, the page told
--                                  what was picked: { functionId, at = { x, y }
--                                  or nil, place }. False when not hidden
--
-- EVENTS (local, raised for br_core's client; never net events)
--   cuchi_computer:opened   (terminalId)            focus taken
--   cuchi_computer:closed   (terminalId, why)       focus released
--   cuchi_computer:request  (terminalId, request)   request = { action = 'run',
--                                                   functionId, options, at }
--   cuchi_computer:pick     (terminalId, request)   request = { functionId }:
--                                                   the app's "Set location"
--   cuchi_computer:missed   (toast, ok)             a last word the app never
--                                                   showed: the page held it and
--                                                   the computer closed first
--
-- ═══ FOCUS IS THE DANGEROUS PART ═══
--
-- This frame is not br_ui's, so br_ui's focus stack cannot hold it: FiveM
-- keeps one focus vote per RESOURCE (ResourceUIScripting.cpp's focusVotes) and
-- focuses the frame of whichever resource asked, so this resource has to ask
-- for its own. A vote left standing is a player who cannot move or shoot, so:
--
--   * Open refuses until the page has said it is ready. Focus on a page that
--     is not listening is a player with a cursor and nothing to close.
--   * Every way out runs through one function, which releases the vote and
--     says so -- the page's Escape and power button, br_core's Close, the
--     opener stopping, and this resource stopping.
--   * The resource that opened it is remembered. If it stops while the desktop
--     is up, the desktop comes down: br_core restarting must never strand a
--     player inside a computer nobody is driving any more.
--   * THE STORM'S CLOSE KEEPS THE VOTE FOR ITS SCREEN, AND NO LONGER (round
--     4, owner 2026-10-06: "If they're using it while the storm moves and
--     they're now outside the storm, the computer should show a BSOD quickly
--     followed by a CRT-style visual power off"). The page plays both (br.js,
--     about 2.1 s) and says when the screen is dark (`off`); the vote goes
--     then -- or at SHUTDOWN_MAX_MS whatever the page does, or at once if
--     anything else needs the computer first (an Open, a resource stopping).
--
-- ═══ AND NOTHING HERE TRUSTS THE PAGE ═══
--
-- A run carries only the function id and the player's choices, both
-- shape-checked here and again, against the registry, on the server. The
-- terminal id it is sent with is the one br_core opened, kept on this side;
-- the page is never asked which terminal it is on.

local RES = GetCurrentResourceName()

-- The shape of a function id (br_lib/config/terminals.lua).
local FUNCTION_ID = '^[a-z][a-z0-9_]*$'
local FUNCTION_ID_MAX = 32
-- An option is an id like a function's, its choice a short lower-case word;
-- no registry row offers more than a few.
local CHOICE = '^[a-z0-9_]+$'
local OPTIONS_MAX = 8
-- A spot picked on the map: two numbers no further from the map's middle than
-- this, on either axis (the server holds it to 20 km; this is shape).
local SPOT_MAX = 100000.0
-- The longest place name the page is handed (the game's street and area).
local PLACE_MAX = 120

--- The page's choices for a run, shape-checked, or false when malformed.
--- Nil stays nil: a function with no options sends none.
--- @param o any
--- @return table|nil|false
local function choices(o)
    if o == nil then return nil end
    if type(o) ~= 'table' then return false end
    local out, n = {}, 0
    for k, v in pairs(o) do
        n = n + 1
        if n > OPTIONS_MAX then return false end
        if type(k) ~= 'string' or #k > FUNCTION_ID_MAX or not k:match(FUNCTION_ID) then return false end
        if type(v) ~= 'string' or #v > FUNCTION_ID_MAX or not v:match(CHOICE) then return false end
        out[k] = v
    end
    return out
end

--- A spot, shape-checked, or false when malformed; nil stays nil.
--- @param a any
--- @return table|nil|false
local function spotOf(a)
    if a == nil then return nil end
    if type(a) ~= 'table' then return false end
    local x, y = a.x, a.y
    if type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y
        or math.abs(x) > SPOT_MAX or math.abs(y) > SPOT_MAX then
        return false
    end
    return { x = x, y = y }
end

local pageReady = false
local isOpen = false
local terminalId = nil
local opener = nil
--- Out of sight for a map pick (Hide), still open.
local hidden = false

--- br_core's why when THE STORM took the terminal in use: the one online
--- rule's own word (br_core/server/terminal.lua's session check closes with
--- BR.TerminalSolve.offlineWhy's answer). Only this close plays out.
local STORM = 'offline'
--- The longest the storm's close may hold the vote: the page's blue screen
--- and power-off take about 2.1 s (br.js BSOD_MS + CRT_MS), and this is
--- the backstop for a page that never says its screen went dark.
local SHUTDOWN_MAX_MS = 4000

--- The storm's close while the page plays it: { id, why, n, opener }, or
--- nil. `n` tells a backstop timer from a later close's.
local closing = nil
local closings = 0

--- The vote released, and br_core told the computer is gone.
local function release(id, why)
    SetNuiFocus(false, false)
    TriggerEvent('cuchi_computer:closed', id, why)
end

--- The storm's close is over -- its screen went dark, its backstop fired,
--- or something needs the computer first. False when none was playing.
--- @return boolean
local function finishClosing()
    local c = closing
    if not c then return false end
    closing = nil
    release(c.id, c.why)
    return true
end

--- Every way the desktop goes away. Releases the focus vote, tells br_core.
--- THE STORM'S CLOSE (br_core's 'offline') tells the page to play its blue
--- screen and power-off, and releases when the page says the screen is dark
--- (`off`) or SHUTDOWN_MAX_MS has passed: until then the computer is no
--- longer open (nothing is updated, run or shown on it -- an answer landing
--- now is toasted, as for any closed computer) but the screen and the
--- keyboard are still its. Every other close releases at once, as always.
--- @param why string
--- @param tellPage boolean  false when the page already closed itself
--- @return boolean  false when it was not open
local function shut(why, tellPage)
    if not isOpen then return false end
    isOpen = false
    -- Out of sight for a map pick, there is no screen to play the storm's
    -- close on: it closes at once, as every other close does.
    local wasHidden = hidden
    hidden = false
    local id, by = terminalId, opener
    terminalId, opener = nil, nil
    if tellPage and why == STORM and not wasHidden then
        SendNUIMessage({ type = 'br:close', storm = true })
        closings = closings + 1
        local n = closings
        closing = { id = id, why = why, n = n, opener = by }
        Citizen.SetTimeout(SHUTDOWN_MAX_MS, function()
            if closing and closing.n == n then finishClosing() end
        end)
        return true
    end
    if tellPage then
        SendNUIMessage({ type = 'br:close' })
    end
    release(id, why)
    return true
end

--- A game hour and minute, or nil when they are not in range.
--- @return table|nil { h, m }
local function hm(h, m)
    h, m = math.tointeger(tonumber(h)), math.tointeger(tonumber(m))
    if not h or not m or h < 0 or h > 23 or m < 0 or m > 59 then return nil end
    return { h = h, m = m }
end

--- What the page boots with besides the state: the boot's range (two
--- numbers, the page picks in it) and the game's time. Shape only.
--- @param d any
--- @return table
local function desktopOf(d)
    if type(d) ~= 'table' then return {} end
    local lo, hi = tonumber(d.bootMinMs), tonumber(d.bootMaxMs)
    local out = {}
    if lo and hi and lo >= 0 and hi >= lo then out.bootMinMs, out.bootMaxMs = lo, hi end
    if type(d.clock) == 'table' then out.clock = hm(d.clock.h, d.clock.m) end
    return out
end

--- @param state table
--- @param copy table|nil
--- @param catalog table|nil
--- @param desktop table|nil
--- @return boolean ok, string|nil why
local function open(state, copy, catalog, desktop)
    if type(state) ~= 'table' or type(state.terminalId) ~= 'string' then
        return false, 'bad-state'
    end
    if not pageReady then
        return false, 'page-not-ready'
    end

    -- A storm's close still on screen is over now: its terminal's close is
    -- said, and the vote it held released, before this opening takes one.
    -- The page drops the screen when the open reaches it.
    finishClosing()

    -- Opened again while up: a refresh. The page treats it the same way.
    if isOpen and terminalId ~= state.terminalId then
        shut('replaced', true)
    end

    local was = isOpen
    isOpen = true
    terminalId = state.terminalId
    opener = GetInvokingResource() or opener
    SendNUIMessage({ type = 'br:open', state = state, copy = type(copy) == 'table' and copy or {},
                     catalog = type(catalog) == 'table' and catalog or {},
                     desktop = desktopOf(desktop) })
    if not was then
        SetNuiFocus(true, true)
        TriggerEvent('cuchi_computer:opened', terminalId)
    end
    return true, nil
end

--- @param state table
local function update(state)
    if not isOpen or type(state) ~= 'table' then return end
    if state.terminalId ~= terminalId then return end
    SendNUIMessage({ type = 'br:update', state = state })
end

--- THE TOASTS OF THE LAST WORDS THIS SHELL HANDED THE PAGE, newest last, a
--- few at most: the only texts the page may hand back (`missed`, below) for
--- br_core to toast, each once. The page can only return what the server
--- said, never make br_core say something of its own.
local RELAYED_MAX = 4
local TOAST_MAX = 1000
local relayed = {}

--- @param result table
--- @return boolean  false when nothing is up to show it (br_core toasts it)
local function result(result_)
    if not isOpen or type(result_) ~= 'table' then return false end
    local toast = result_.toast
    if type(toast) == 'string' and toast ~= '' and #toast <= TOAST_MAX then
        relayed[#relayed + 1] = { text = toast, ok = result_.ok == true }
        if #relayed > RELAYED_MAX then table.remove(relayed, 1) end
    end
    SendNUIMessage({ type = 'br:result', result = result_ })
    return true
end

--- The game's time, for the taskbar's clock: br_core sends it while the
--- desktop is up, when the minute changes.
local function clock(h, m)
    local t = hm(h, m)
    if not isOpen or not t then return end
    SendNUIMessage({ type = 'br:clock', h = t.h, m = t.m })
end

--- Out of sight while the player picks a spot on the big map (round 4): the
--- page hides itself, app and box and all, and the vote is let go so the game
--- has the keyboard and the map its mouse. Still open: br_core's Close still
--- closes it.
--- @return boolean
local function hide()
    if not isOpen or hidden then return false end
    hidden = true
    SendNUIMessage({ type = 'br:hide' })
    SetNuiFocus(false, false)
    return true
end

--- Back from the map: the vote taken again and the page told what was picked
--- -- the spot, or none -- shape-checked, for the app's box.
--- @param picked any  { functionId, at = { x, y } | nil, place }
--- @return boolean
local function show(picked)
    if not isOpen or not hidden then return false end
    hidden = false
    local p = type(picked) == 'table' and picked or {}
    local id = p.functionId
    local at = spotOf(p.at)
    local place = type(p.place) == 'string' and p.place:sub(1, PLACE_MAX) or ''
    SendNUIMessage({ type = 'br:show', picked = {
        functionId = (type(id) == 'string' and #id <= FUNCTION_ID_MAX and id:match(FUNCTION_ID)) and id or nil,
        at = at or nil,
        place = at and place or nil,
    } })
    SetNuiFocus(true, true)
    return true
end

exports('Open', open)
exports('Update', update)
exports('Result', result)
exports('Clock', clock)
exports('Hide', hide)
exports('Show', show)
exports('Close', function(why)
    return shut(type(why) == 'string' and why or 'closed', true)
end)
exports('IsOpen', function()
    return isOpen
end)

-- ---------------------------------------------------------- the page ---

-- Upstream's own ready signal: script.js posts it from DOMContentLoaded, once
-- the desktop and its windows exist.
RegisterNUICallback('NUIOk', function(_, cb)
    pageReady = true
    cb({ ok = true })
end)

-- A RUN'S LAST WORD THE APP NEVER SHOWED: the page held it while the app was
-- not there to take it (its window closed, or still loading), and the computer
-- closed first. Handed back with the toast it came with, and passed to
-- br_core -- which toasts it -- only if this shell relayed that very text and
-- has not passed it on already. Any time, open or not: the page posts it as
-- it closes, which may be after br_core closed it.
RegisterNUICallback('missed', function(data, cb)
    local text = type(data) == 'table' and data.toast or nil
    if type(text) == 'string' then
        for i, r in ipairs(relayed) do
            if r.text == text then
                table.remove(relayed, i)
                TriggerEvent('cuchi_computer:missed', r.text, r.ok)
                break
            end
        end
    end
    cb({ ok = true })
end)

-- THE STORM'S CLOSE IS OVER ON SCREEN: br.js played the blue screen and the
-- power-off, and the screen is dark. The vote goes now. Only a storm's close
-- that is still playing is ended by it; at any other time it does nothing.
RegisterNUICallback('off', function(_, cb)
    finishClosing()
    cb({ ok = true })
end)

-- Escape, or the taskbar's power button. The page has already hidden itself.
RegisterNUICallback('close', function(data, cb)
    local why = type(data) == 'table' and data.why or nil
    shut((why == 'escape' or why == 'exit') and why or 'page', false)
    cb({ ok = true })
end)

RegisterNUICallback('run', function(data, cb)
    local id = type(data) == 'table' and data.functionId or nil
    -- Two steps, not `and ... or false`: choices answers nil for a run with
    -- no options, and an `or` would turn that nil into a refusal. The spot
    -- the same way.
    local opts, at = false, false
    if type(data) == 'table' then
        opts = choices(data.options)
        at = spotOf(data.at)
    end
    if not isOpen or hidden or type(id) ~= 'string' or #id > FUNCTION_ID_MAX
            or not id:match(FUNCTION_ID) or opts == false or at == false then
        cb({ ok = false })
        return
    end
    TriggerEvent('cuchi_computer:request', terminalId,
        { action = 'run', functionId = id, options = opts, at = at })
    cb({ ok = true })
end)

-- "Set location" (round 4): the app asks for a spot on the big map for the
-- function its box is about. br_core does the rest (Hide, the map, Show).
RegisterNUICallback('pick', function(data, cb)
    local id = type(data) == 'table' and data.functionId or nil
    if not isOpen or hidden or type(id) ~= 'string' or #id > FUNCTION_ID_MAX
            or not id:match(FUNCTION_ID) then
        cb({ ok = false })
        return
    end
    TriggerEvent('cuchi_computer:pick', terminalId, { functionId = id })
    cb({ ok = true })
end)

-- ---------------------------------------------------- the ways out ---

AddEventHandler('onResourceStop', function(res)
    if res == RES then
        -- The engine drops this resource's focus vote by itself when it stops
        -- (ResourceUIScripting.cpp); br_core still has to hear it went --
        -- a storm's close still playing included.
        if not shut('stopped', false) then finishClosing() end
    elseif opener ~= nil and res == opener then
        shut('opener-stopped', true)
    elseif closing and closing.opener == res then
        -- The resource that opened it stopped mid storm's close: nobody is
        -- left to wait for, and the vote goes now.
        finishClosing()
    end
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    -- A restart of this resource never inherits a vote, but say so to the
    -- engine anyway: the same belt br_ui's bridge wears.
    SetNuiFocus(false, false)
end)

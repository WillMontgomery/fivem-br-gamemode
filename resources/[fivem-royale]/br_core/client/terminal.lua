-- Season 2 terminals (#396), client half: br_core's side of the computer.
--
-- The whole contract is docs/terminals.md. The computer is cuchi_computer, a
-- vendored resource with no server half and no opinions: it shows a desktop
-- when told, holds NUI focus while it is up, and forwards what its page asks.
-- This file is everything between it and the server:
--
--   server -> here -> computer   TERMINAL_OPEN    -> exports.cuchi_computer:Open
--                                TERMINAL_INFO    -> :Update(state), once a second
--                                TERMINAL_RESULT  -> :Update(state), :Result
--                                TERMINAL_CLOSE   -> :Close
--   the game -> computer         the game clock   -> :Clock(h, m), on each new
--                                                    minute while it is open
--   computer -> here -> server   cuchi_computer:request -> TERMINAL_RUN (with
--                                the spot picked, `at`, for a row run at one)
--                                cuchi_computer:closed  -> TERMINAL_CLOSED
--   computer -> here -> the map  cuchi_computer:pick -> :Hide, the big map,
--                                and :Show with the spot picked (round 4's
--                                map pick, below); TERMINAL_PICK as it starts
--                                and ends (round 5, Airstrike's rough circles)
--   a run's last word that no computer can show -> a toast (its `toast`),
--                                from TERMINAL_RESULT or cuchi_computer:missed
--   computer -> here -> keys     cuchi_computer:opened/closed
--                                -> BR.Keys.setExternalScreen
--
-- ═══ NOTHING HERE DECIDES ═══
--
-- Which terminal, which functions, whether one may run and what it does are
-- the server's (server/terminal.lua). A run request goes up carrying the
-- terminal this client was opened on, the function id the page asked for and
-- the player's choices, and nothing else; the server checks the choices
-- against the registry.
--
-- ═══ THE COPY RIDES ALONG FROM HERE ═══
--
-- Every word the computer and its app show is a key into
-- BR.Config.Terminals.copy, which this client already has (br_lib, shared
-- scripts), so it is handed over with each opening instead of crossing the
-- network. Replacing a placeholder is an edit to that one file. THE CATALOG
-- TOO: the function registry (`functions`, `categories`) is the same file's,
-- so the app draws its cards from the rows the server rules runs against.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local COMPUTER = 'cuchi_computer'
-- The key layer's name for the computer's screen (BR.Keys.externalScreen).
local SCREEN = 'terminal'

--- The terminal the computer is showing, or nil.
local shown = nil

--- The game minute (h * 60 + m) the computer's taskbar was last given, so the
--- clock crosses to the page only when it changes: once a game minute at
--- most, never per frame. Nil while it is closed.
local clockSent = nil

--- The map pick under way (round 4, below), or nil:
--- { terminalId, functionId, known, up, deadline }. Its step runs on the TICK
--- pass the clock does, so it is declared here and defined with the pick.
local picking = nil
local stepPick

--- The computer's exports, or nil when the resource is not running -- a box
--- without it has no computer to open, which is a terminal that does
--- nothing rather than an error.
local function computer()
    if GetResourceState(COMPUTER) ~= 'started' then return nil end
    return exports[COMPUTER]
end

local function setKeys(open)
    if BR.Keys and BR.Keys.setExternalScreen then
        BR.Keys.setExternalScreen(open and SCREEN or nil)
    end
end

--- The registry as the app reads it: the rows and the categories, as they are
--- in br_lib/config/terminals.lua -- and the currency's name
--- (config/market.lua's `currency`, the one place it is spelled), which the
--- app writes after a Volts figure, as every other Volts display does -- and
--- how long the app's browser takes to load a page (owner, 2026-10-06:
--- "random between 1 and 3 seconds"; the app picks in the range) -- and the
--- loot rarities as the game colors them (round 6: Gear Up's items wear their
--- rarity in its color), BR.RarityInfo's, the one source every rarity color is
--- read from: { tier, key, hex } each, in tier order.
--- @return table
local function catalog()
    local C = BR.Config.Terminals
    local rarities = {}
    for tier, info in pairs(BR.RarityInfo or {}) do
        if type(tier) == 'number' and type(info) == 'table' then
            rarities[#rarities + 1] = { tier = tier, key = info.key, hex = info.hex }
        end
    end
    table.sort(rarities, function(a, b) return a.tier < b.tier end)
    return { functions = C.functions, categories = C.categories,
             currency = BR.Config.Market and BR.Config.Market.currency or nil,
             pageLoad = { minMs = C.pageMinMs, maxMs = C.pageMaxMs },
             rarities = rarities }
end

--- THE GAME'S CLOCK, as the computer's taskbar shows it (owner, round 2: "make
--- the computer clock match the game clock"). Read, never written: the clock
--- has one writer, client/natives.lua (#394), and this only looks at what it
--- shows -- noon in the lobby and on the warmup pad, about five real seconds a
--- game minute in a match.
--- @return table { h, m }
local function gameClock()
    return { h = GetClockHours(), m = GetClockMinutes() }
end

--- What the computer was opened with besides the copy and the catalog: the
--- boot's length range (bootMinMs / bootMaxMs -- br.js picks a new length in
--- it every boot) and the game's time now, so the taskbar is right from its
--- first frame.
--- @return table
local function desktop()
    local C = BR.Config.Terminals
    return { bootMinMs = C.bootMinMs, bootMaxMs = C.bootMaxMs, clock = gameClock() }
end

--- Is the computer up on this client? Read by client/yubikey.lua, whose plate
--- and press stand down while it is.
--- @return boolean
function BR.Terminal.computerOpen()
    return shown ~= nil
end

-- ------------------------------------------------------ server -> computer ---

RegisterNetEvent(BR.Net.TERMINAL_OPEN)
AddEventHandler(BR.Net.TERMINAL_OPEN, function(d)
    local state = type(d) == 'table' and d.state or nil
    if type(state) ~= 'table' or type(state.terminalId) ~= 'string' then return end
    local c = computer()
    local ok, why = false, 'not-started'
    -- NOT OVER A br_ui SCREEN. The computer holds its own NUI focus vote, so
    -- opening it over the lobby, the map or the inventory would leave two
    -- frames each believing they own the keyboard (#396's shell report). The
    -- session is handed straight back, like any other open that did not happen.
    if BR.Keys and BR.Keys.uiScreen ~= nil then
        c, why = nil, 'screen-busy'
    end
    if c then
        local desk = desktop()
        ok, why = c:Open(state, BR.Config.Terminals.copy, catalog(), desk)
        if ok == true then clockSent = desk.clock.h * 60 + desk.clock.m end
    end
    if ok ~= true then
        -- Said out loud, and the session handed back: a server waiting on a
        -- computer that never opened would take this player's run requests
        -- for a screen they cannot see.
        print(('[br_core] terminal %s: the computer did not open (%s)')
            :format(state.terminalId, tostring(why)))
        TriggerServerEvent(BR.Net.TERMINAL_CLOSED, { terminalId = state.terminalId, why = tostring(why) })
    end
end)

--- A RUN'S LAST WORD THAT NO COMPUTER CAN SHOW, toasted instead -- the
--- server's own text for it (`toast`, server/terminal.lua's toastOf, through
--- the solo picker), exactly as the server toasts it for a session it knows
--- has closed. Reached when the answer lands after the computer went away but
--- before the server heard (TERMINAL_CLOSED still on its way up), and when the
--- desktop hands back an answer it held for an app that never took it
--- (`cuchi_computer:missed`). `running` is no last word and carries none.
--- @param text any
--- @param ok boolean
local function missed(text, ok)
    if type(text) ~= 'string' or text == '' then return end
    if BR.Notify then BR.Notify(text, ok and 'success' or 'warn') end
end

RegisterNetEvent(BR.Net.TERMINAL_RESULT)
AddEventHandler(BR.Net.TERMINAL_RESULT, function(r)
    if type(r) ~= 'table' then return end
    local c = r.terminalId == shown and shown ~= nil and computer() or nil
    if c then
        if type(r.state) == 'table' then c:Update(r.state) end
        -- The answer alone: `running` carries how long the server will take
        -- (runMs), `no_volts` the cost and the balance, a paid `done` the new
        -- balance -- numbers, or nothing -- and a last word its toast, which
        -- the desktop hands back if the app never shows it.
        local shownOk = c:Result({ functionId = r.functionId, ok = r.ok == true, code = r.code,
                                   runMs = tonumber(r.runMs), cost = tonumber(r.cost),
                                   balance = tonumber(r.balance),
                                   toast = type(r.toast) == 'string' and r.toast or nil })
        -- The shell answers false when it is no longer up (it closed itself
        -- and the closed event has not reached here yet).
        if shownOk == true then return end
    end
    missed(r.toast, r.ok == true)
end)

-- THE MATCH PANEL, REALTIME: the server's state again, once a second while
-- the computer is open on that terminal.
RegisterNetEvent(BR.Net.TERMINAL_INFO)
AddEventHandler(BR.Net.TERMINAL_INFO, function(d)
    if type(d) ~= 'table' or d.terminalId ~= shown or type(d.state) ~= 'table' then return end
    local c = computer()
    if c then c:Update(d.state) end
end)

RegisterNetEvent(BR.Net.TERMINAL_CLOSE)
AddEventHandler(BR.Net.TERMINAL_CLOSE, function(d)
    local c = computer()
    if c then c:Close(type(d) == 'table' and tostring(d.why) or 'server') end
end)

-- ------------------------------------------------------ computer -> server ---

AddEventHandler('cuchi_computer:opened', function(terminalId)
    shown = terminalId
    setKeys(true)
end)

-- THE TASKBAR'S CLOCK, while the computer is open and only then: the game's
-- hour and minute, sent when the minute changes. Ten reads a second of two
-- natives that only read; nothing at all while it is closed. AND THE MAP
-- PICK'S WATCH (round 4), on the same pass rather than a callback of its own:
-- one nil test while there is no pick, which is always but for the seconds
-- the big map is open for one.
if BR.Loop and BR.Loop.register then
    BR.Loop.register(BR.Loop.TICK, 'terminal.clock', function()
        if picking ~= nil then stepPick(GetGameTimer()) end
        if shown == nil then return end
        local t = gameClock()
        local key = t.h * 60 + t.m
        if key == clockSent then return end
        clockSent = key
        local c = computer()
        if c then c:Clock(t.h, t.m) end
    end)
end

AddEventHandler('cuchi_computer:closed', function(terminalId, why)
    shown = nil
    clockSent = nil
    setKeys(false)
    TriggerServerEvent(BR.Net.TERMINAL_CLOSED, { terminalId = terminalId, why = why })
end)

-- AN ANSWER THE APP NEVER SHOWED, handed back by the desktop: it arrived
-- while the app's window was closed or still loading, and the computer closed
-- before the app took it. The shell passes on only a toast it relayed itself.
AddEventHandler('cuchi_computer:missed', function(text, ok)
    missed(text, ok == true)
end)

AddEventHandler('cuchi_computer:request', function(terminalId, req)
    if type(req) ~= 'table' or req.action ~= 'run' then return end
    if terminalId == nil or terminalId ~= shown then return end
    TriggerServerEvent(BR.Net.TERMINAL_RUN, { terminalId = terminalId, functionId = req.functionId,
                                              options = req.options, at = req.at })
end)

-- ---------------------------------------------------------------- the map pick ---
--
-- ═══ "SET LOCATION" (owner, 2026-10-06, round 4) ═══
--
--   "When they click confirm, we should open the big map for them, wait for
--    them to pick a location, then when they close the big map we run it. This
--    could be a multi-step flow on the popup box like where the confirm button
--    is greyed out until they select a "set location" button"  (spelling-ok: his words)
--
-- A function run at a spot (`spot` on its registry row: Storm control, Supply
-- drop) asks for one from its confirm box. The app's "Set location" reaches
-- here as `cuchi_computer:pick`, and:
--
--   1. the computer is HIDDEN, not closed (cuchi_computer's Hide: its page out
--      of sight with the app and the box still in it, NUI focus released),
--      and the key layer let go, so the game has the keyboard;
--   2. the player's own waypoint, if they had one, is cleared, and the sprite-8
--      blips already on the map (squad pings wear the waypoint's sprite) noted,
--      so the one they set now is the one read;
--   3. the BIG MAP opens -- br_ui's own, the map key's (`br:ui:mapToggle`: the
--      pause menu's frontend map) -- and this waits, on the TICK pass the
--      taskbar clock already runs, while br_ui says its map is up
--      (BR.Native.frontendMap, lowered when the frontend is genuinely down by
--      any way out: Escape, the map key, right-click);
--   4. when it closes, the waypoint they set is read and cleared -- it is the
--      pick, never a squad ping (client/markers.lua stands down while
--      BR.Terminal.picking(), and a squadmate's ping drawn meanwhile is
--      skipped, BR.Markers.isOwn) -- and the computer is SHOWN again with it: the
--      spot and the game's own name for the place (its street and area), or
--      none when no waypoint was set, which puts the box back to its first
--      step.
--
-- The spot rides the run request (`at`), and the server decides what it means.
-- The server hears only that a pick STARTED and ENDED (round 5, TERMINAL_PICK:
-- `on`, then not): for a row with `fuzz` (Airstrike) it sends the rough circles
-- of the player's opponents while the map is up (client/terminalfx/airstrike.lua
-- draws them); for any other it does nothing. A session the server ends meanwhile
-- (the player downed, the storm) closes the hidden computer as any other; the
-- map is the player's to close, and the waypoint is still taken off it then. A
-- map that never comes up (`PICK_RAISE_MS`) ends the pick with no spot.

--- How long the big map may take to come up before a pick gives up, in ms --
--- br_ui's own raise deadline.
local PICK_RAISE_MS = 5000

--- Is a map pick under way? Read by client/markers.lua, which would otherwise
--- turn the waypoint set for it into a squad ping.
--- @return boolean
function BR.Terminal.picking()
    return picking ~= nil
end

--- The sprite-8 blips on the map now: the waypoint's sprite, which squad pings
--- wear too (client/markers.lua's note).
--- @return table [blip] = true
local function spriteEights()
    local out = {}
    local b = GetFirstBlipInfoId(8)
    while BR.NativeTruthy(DoesBlipExist(b)) do
        out[b] = true
        b = GetNextBlipInfoId(8)
    end
    return out
end

--- The game's own name for a place: its street and its area, as the game
--- labels them ("Elgin Ave, Downtown Vinewood"), either alone, or '' when it
--- has neither. Not copy: the map's own words for where the player clicked.
--- @param x number
--- @param y number
--- @return string
local function placeOf(x, y)
    local z = 0.0
    local found, gz = GetGroundZFor_3dCoord(x, y, 1000.0, false)
    if BR.NativeTruthy(found) and type(gz) == 'number' then z = gz end
    local parts = {}
    local street = GetStreetNameAtCoord(x, y, z)
    local name = (street ~= nil and street ~= 0) and GetStreetNameFromHashKey(street) or nil
    if type(name) == 'string' and name ~= '' then parts[#parts + 1] = name end
    local zone = GetNameOfZone(x, y, z)
    local label = (type(zone) == 'string' and zone ~= '') and GetLabelText(zone) or nil
    if type(label) == 'string' and label ~= '' and label ~= 'NULL' then parts[#parts + 1] = label end
    return table.concat(parts, ', ')
end

--- A sprite-8 blip that is not the waypoint set for the pick: one already on
--- the map when it started, or a squad ping client/markers.lua drew since --
--- a squadmate pinging while the big map is up (round 4's review).
--- @return boolean
local function notThePick(p, b)
    if p.known[b] then return true end
    return BR.Markers ~= nil and BR.Markers.isOwn ~= nil and BR.Markers.isOwn(b) == true
end

--- The map closed (or never came up): read the waypoint set for the pick,
--- take it off the map, and show the computer again with what was picked.
local function finishPick()
    local p = picking
    picking = nil
    TriggerServerEvent(BR.Net.TERMINAL_PICK, { terminalId = p.terminalId, functionId = p.functionId, on = false })
    local at = nil
    if BR.NativeTruthy(IsWaypointActive()) then
        local b = GetFirstBlipInfoId(8)
        while BR.NativeTruthy(DoesBlipExist(b)) and notThePick(p, b) do b = GetNextBlipInfoId(8) end
        if BR.NativeTruthy(DoesBlipExist(b)) then
            local c = GetBlipInfoIdCoord(b)
            if c and BR.TerminalSolve.finite(c.x) and BR.TerminalSolve.finite(c.y) then
                at = { x = c.x + 0.0, y = c.y + 0.0 }
            end
        end
        SetWaypointOff()
    end
    local c = (shown ~= nil and shown == p.terminalId) and computer() or nil
    if not c then return end
    -- The key layer is the computer's again only once it is back on screen: a
    -- shell that could not show it (restarted meanwhile) leaves the game its keys.
    if c:Show({ functionId = p.functionId, at = at, place = at and placeOf(at.x, at.y) or nil }) == true then
        setKeys(true)
    end
end

--- One look at the pick, on the TICK pass: the map up, then down again.
--- @param now number
stepPick = function(now)
    local p = picking
    local up = BR.Native ~= nil and BR.Native.frontendMap == true
    if not p.up then
        if up then
            p.up = true
        elseif now >= p.deadline then
            finishPick()
        end
        return
    end
    if not up then finishPick() end
end

AddEventHandler('cuchi_computer:pick', function(terminalId, req)
    if picking ~= nil or terminalId == nil or terminalId ~= shown then return end
    if type(req) ~= 'table' or not BR.TerminalSolve.validId(req.functionId) then return end
    local c = computer()
    if not c then return end
    if BR.NativeTruthy(IsWaypointActive()) then SetWaypointOff() end
    local p = { terminalId = terminalId, functionId = req.functionId, known = spriteEights(),
                up = false, deadline = GetGameTimer() + PICK_RAISE_MS }
    if c:Hide() ~= true then return end
    picking = p
    setKeys(false)
    TriggerServerEvent(BR.Net.TERMINAL_PICK, { terminalId = terminalId, functionId = req.functionId, on = true })
    TriggerEvent('br:ui:mapToggle')
end)

-- -------------------------------------------------------------------- dev ---

RegisterNetEvent(BR.Net.TERMINAL_DEV)
AddEventHandler(BR.Net.TERMINAL_DEV, function(text)
    print('[br_core] brterminal: ' .. tostring(text))
end)

--- Where `brterminal place` puts a terminal: on the surface the camera is
--- looking at within PLACE_LOOK_M, or else on the ground a metre in front of
--- the player. Facing the player either way, so its screen is the side they
--- walk up to.
local PLACE_LOOK_M = 6.0

--- Where `brterminal run <function>` puts a spot nobody typed (round 6's
--- rehearsal): this far in front of the player. An Airstrike there is a 40 m
--- circle whose edge is 20 m off, and whose blasts stop short of them.
local REHEARSE_AHEAD_M = 60.0

--- @return table { x, y, z, h }
local function placeSpot()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local facing = (heading + 180.0) % 360.0

    -- WHERE THE PLAYER LOOKS: one synchronous ray from the camera, a dev
    -- command's cost and nobody else's.
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local dx = -math.sin(rz) * math.abs(math.cos(rx))
    local dy = math.cos(rz) * math.abs(math.cos(rx))
    local dz = math.sin(rx)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z,
        cam.x + dx * PLACE_LOOK_M, cam.y + dy * PLACE_LOOK_M, cam.z + dz * PLACE_LOOK_M,
        1 + 16, ped, 7)
    local _, hit, at = GetShapeTestResult(ray)
    if BR.NativeTruthy(hit) and at then
        return { x = at.x, y = at.y, z = at.z, h = facing }
    end

    -- WHERE THE PLAYER STANDS, a metre ahead, on the ground.
    local h = math.rad(heading)
    local x, y = pos.x - math.sin(h) * 1.0, pos.y + math.cos(h) * 1.0
    local found, gz = GetGroundZFor_3dCoord(x, y, pos.z + 2.0, false)
    if not BR.NativeTruthy(found) or type(gz) ~= 'number' then gz = pos.z - 1.0 end
    return { x = x, y = y, z = gz, h = facing }
end

--- `brterminal ...`, the dev tools (#396). The server does every one of them,
--- as `brterminalsv`; this only types it (client/props.lua's `brprop` has the
--- mechanism), adding what only a client knows -- where `place` puts it.
---
---   brterminal [nokey] [used] [offline]   the app alone, anywhere, on a dev
---                                         terminal with those facts
---   brterminal close                      close the computer
---   brterminal place [id]                 a terminal where you look or stand;
---                                         prints the config line to paste
---   brterminal remove <id>                take one out of play (this session)
---   brterminal list                       every terminal, online or not
---   brterminal online <id> [off]          force one online, or back to the storm
---   brterminal reset [player id]          (round 6) your squad's one use this
---                                         match unspent, and your Yubikey back
---   brterminal run <function>             a function's effect, no key needed;
---                                         one run at a spot with no x= y=
---                                         (round 6) lands REHEARSE_AHEAD_M in
---                                         front of you
RegisterCommand('brterminal', function(_, args)
    args = args or {}
    local first = args[1] and args[1]:lower() or 'open'
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end

    -- A REHEARSAL (round 6, owner 2026-10-07: "We need to rehearse that air
    -- strike"): `brterminal run airstrike` with no spot lands it in front of
    -- you, far enough to watch the rockets fall onto the circle -- the real run,
    -- its warning, rockets, blasts and damage, with nothing spent.
    -- A row whose spot hangs on a choice (Power outage's default area 'spot')
    -- is asked BR.TerminalSolve.spotWanted over the choices typed, its
    -- defaults filled in, as the server's BR.Terminal.options fills them.
    if first == 'run' and #rest >= 1 then
        local id, given, typed = rest[1]:lower(), false, {}
        for i = 2, #rest do
            if rest[i]:match('^[xXyY]=') then given = true end
            local k, v = rest[i]:match('^([%w_]+)=(%S+)$')
            if k then typed[k] = v end
        end
        local row = nil
        for _, r in ipairs(BR.Config.Terminals.functions or {}) do
            if r.id == id then row = r end
        end
        local opts = {}
        for _, o in ipairs(row and row.options or {}) do opts[o.id] = o.default end
        for k, v in pairs(typed) do opts[k] = v end
        if row and BR.TerminalSolve.spotWanted(row, opts) and not given then
            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)
            local h = math.rad(GetEntityHeading(ped))
            rest[#rest + 1] = ('x=%.1f'):format(pos.x - math.sin(h) * REHEARSE_AHEAD_M)
            rest[#rest + 1] = ('y=%.1f'):format(pos.y + math.cos(h) * REHEARSE_AHEAD_M)
        end
    end

    if first == 'close' or first == 'list' or first == 'remove' or first == 'online'
       or first == 'reset' or first == 'run' then
        local tail = table.concat(rest, ' ')
        ExecuteCommand(tail == '' and ('brterminalsv ' .. first)
            or ('brterminalsv %s %s'):format(first, tail))
        return
    end
    if first == 'place' then
        local s = placeSpot()
        ExecuteCommand(('brterminalsv place %.3f %.3f %.3f %.1f %s')
            :format(s.x, s.y, s.z, s.h, rest[1] or ''))
        return
    end
    local words = {}
    for i = (first == 'open' and 2 or 1), #args do words[#words + 1] = args[i] end
    ExecuteCommand(('brterminalsv open %s'):format(table.concat(words, ' ')))
end)

--- Where `bryubikey drop` puts the key: on the ground a meter and a half in
--- front of the player, clear of their own feet.
local DROP_AHEAD_M = 1.5

--- @return number x, number y, number z
local function dropSpot()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local h = math.rad(GetEntityHeading(ped))
    local x, y = pos.x - math.sin(h) * DROP_AHEAD_M, pos.y + math.cos(h) * DROP_AHEAD_M
    local found, gz = GetGroundZFor_3dCoord(x, y, pos.z + 2.0, false)
    if not BR.NativeTruthy(found) or type(gz) ~= 'number' then gz = pos.z - 1.0 end
    return x, y, gz
end

--- `bryubikey [give|take|unseen|drop]` (#396), dev mode and Season 2 only, as
--- `brterminalsv` is:
---
---   give     a Yubikey for yourself -- the real profile write and the real
---            messages, the first-pickup card included
---   take     yours taken away
---   unseen   (round 5) the first-pickup card shows again with your next key:
---            this session's flag, reset
---   drop     (round 5) a Yubikey on the ground in front of you, to test the
---            real ground pickup
RegisterCommand('bryubikey', function(_, args)
    local verb = args and args[1] and args[1]:lower() or 'give'
    if verb == 'unseen' then
        ExecuteCommand('brterminalsv key unseen')
    elseif verb == 'drop' then
        local x, y, z = dropSpot()
        ExecuteCommand(('brterminalsv key drop %.3f %.3f %.3f'):format(x, y, z))
    else
        ExecuteCommand(('brterminalsv key %s'):format(verb == 'take' and 'take' or 'give'))
    end
end)

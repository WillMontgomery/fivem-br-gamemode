-- Season 2 terminals (#396), client half: br_core's side of the computer.
--
-- The whole contract is docs/terminals.md. The computer is cuchi_computer, a
-- vendored resource with no server half and no opinions: it shows a desktop
-- when told, holds NUI focus while it is up, and forwards what its page asks.
-- This file is everything between it and the server:
--
--   server -> here -> computer   TERMINAL_OPEN    -> exports.cuchi_computer:Open
--                                TERMINAL_RESULT  -> :Update(state), :Result
--                                TERMINAL_CLOSE   -> :Close
--   computer -> here -> server   cuchi_computer:request -> TERMINAL_RUN
--                                cuchi_computer:closed  -> TERMINAL_CLOSED
--   computer -> here -> keys     cuchi_computer:opened/closed
--                                -> BR.Keys.setExternalScreen
--
-- ═══ NOTHING HERE DECIDES ═══
--
-- Which terminal, which functions, whether one may run and what it does are
-- the server's (server/terminal.lua). A run request goes up carrying the
-- terminal this client was opened on and the function id the page asked for,
-- and nothing else.
--
-- ═══ THE COPY RIDES ALONG FROM HERE ═══
--
-- Every word the computer and its app show is a key into
-- BR.Config.Terminals.copy, which this client already has (br_lib, shared
-- scripts), so it is handed over with each opening instead of crossing the
-- network. Replacing a placeholder is an edit to that one file.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local COMPUTER = 'cuchi_computer'
-- The key layer's name for the computer's screen (BR.Keys.externalScreen).
local SCREEN = 'terminal'

--- The terminal the computer is showing, or nil.
local shown = nil

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

--- Is the computer up on this client? Read by client/yubikey.lua, whose plate
--- and hold stand down while it is.
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
    if c then ok, why = c:Open(state, BR.Config.Terminals.copy) end
    if ok ~= true then
        -- Said out loud, and the session handed back: a server waiting on a
        -- computer that never opened would take this player's run requests
        -- for a screen they cannot see.
        print(('[br_core] terminal %s: the computer did not open (%s)')
            :format(state.terminalId, tostring(why)))
        TriggerServerEvent(BR.Net.TERMINAL_CLOSED, { terminalId = state.terminalId, why = tostring(why) })
    end
end)

RegisterNetEvent(BR.Net.TERMINAL_RESULT)
AddEventHandler(BR.Net.TERMINAL_RESULT, function(r)
    if type(r) ~= 'table' or r.terminalId ~= shown then return end
    local c = computer()
    if not c then return end
    if type(r.state) == 'table' then c:Update(r.state) end
    c:Result({ functionId = r.functionId, ok = r.ok == true, code = r.code })
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

AddEventHandler('cuchi_computer:closed', function(terminalId, why)
    shown = nil
    setKeys(false)
    TriggerServerEvent(BR.Net.TERMINAL_CLOSED, { terminalId = terminalId, why = why })
end)

AddEventHandler('cuchi_computer:request', function(terminalId, req)
    if type(req) ~= 'table' or req.action ~= 'run' then return end
    if terminalId == nil or terminalId ~= shown then return end
    TriggerServerEvent(BR.Net.TERMINAL_RUN, { terminalId = terminalId, functionId = req.functionId })
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
---   brterminal reset                      your squad's one use, unspent
---   brterminal run <function>             a function's effect, no key needed
RegisterCommand('brterminal', function(_, args)
    args = args or {}
    local first = args[1] and args[1]:lower() or 'open'
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end

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

--- `bryubikey [give|take]`: a Yubikey for yourself, or yours taken away -- the real
--- profile write and the real messages, first pickup included (#396).
RegisterCommand('bryubikey', function(_, args)
    local verb = args and args[1] and args[1]:lower() or 'give'
    ExecuteCommand(('brterminalsv key %s'):format(verb == 'take' and 'take' or 'give'))
end)

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

-- ------------------------------------------------------ server -> computer ---

RegisterNetEvent(BR.Net.TERMINAL_OPEN)
AddEventHandler(BR.Net.TERMINAL_OPEN, function(d)
    local state = type(d) == 'table' and d.state or nil
    if type(state) ~= 'table' or type(state.terminalId) ~= 'string' then return end
    local c = computer()
    local ok, why = false, 'not-started'
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

--- `brterminal [nokey] [used] [offline]` opens the computer here, wherever
--- "here" is, on a dev terminal whose facts are the words given: a key and
--- nothing against it by default. `brterminal close` closes it. The server
--- does both, as `brterminalsv`; this only types it (client/props.lua's
--- `brprop` has the mechanism).
RegisterCommand('brterminal', function(_, args)
    args = args or {}
    local first = args[1] and args[1]:lower() or 'open'
    if first == 'close' then
        ExecuteCommand('brterminalsv close')
        return
    end
    local words = {}
    for i = (first == 'open' and 2 or 1), #args do words[#words + 1] = args[i] end
    ExecuteCommand(('brterminalsv open %s'):format(table.concat(words, ' ')))
end)

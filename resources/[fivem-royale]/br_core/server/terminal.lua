-- Season 2 terminals (#396), server half: THE DOOR EVERY RUN GOES THROUGH.
--
-- The whole contract, with cuchi_computer's half and the app's, is
-- docs/terminals.md. This file is the shell's stub of it: everything a real
-- terminal will use -- the session, the registry, the run request and its
-- checks, the answer -- and one way to open a session, the dev command
-- `brterminalsv`, which opens a computer anywhere with the facts it is given.
-- The Gameplay half of #396 adds terminals in the world, the Yubikey and the
-- squad's one use, and replaces BR.Terminal.facts, BR.Terminal.consume and the
-- Storm reveal's `run` below with the real reads and the real effect.
--
-- ═══ THE SERVER DECIDES EVERYTHING ═══
--
-- The computer and its app only ask. A run is taken only from a player with an
-- open SESSION on that terminal, which only this file opens; it is refused
-- with a reason when the facts say no; and the function's own run decides
-- what happens. A client never says it is at a terminal, never says it holds a
-- key, and never names a terminal it was not opened on.
--
-- ═══ NO DECISION HERE READS DEV MODE ═══
--
-- tools/check_net_gates.lua: a net event may not refuse on dev mode, because
-- every client passes that on a dev box. The dev door is the command, behind
-- br_lib/shared/devgate.lua's wrap like every other; the run request is
-- authorized by the session that command opened, as client/props.lua's edit
-- stream is by its edit session.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

local function cfg() return BR.Config.Terminals end

-- The shape of the two ids (br_lib/config/terminals.lua).
local FUNCTION_ID = '^[a-z][a-z0-9_]*$'
local FUNCTION_ID_MAX = 32
local TERMINAL_ID_MAX = 64

--- [src] = { terminalId, facts = { keyHeld, squadUsed, offline }, dev }
local sessions = {}

--- [src] = GetGameTimer() of the last run request taken
local lastRunAt = {}

-- --------------------------------------------------------- the registry ---

--- The server half of the function registry: one entry per id in
--- BR.Config.Terminals.functions. A listed id with no entry here is not shown.
---
---   refuse(src, session) -> reason|nil   optional: a reason of its own, asked
---                                        after the shared ones below
---   run(src, session) -> { ok, code }    what running it does; `code` is
---                                        'done' when it ran
T.FUNCTIONS = {
    storm_reveal = {
        -- THE STUB. The Gameplay half makes this show the squad where the
        -- storm ends this match. Here it answers as if it had, so the app's
        -- whole round trip can be walked from the dev command.
        run = function()
            return { ok = true, code = 'done' }
        end,
    },
}

--- What the server knows about this player at this terminal.
---
--- THE STUB READS THE SESSION: the dev command writes the facts it was typed
--- with. The Gameplay half answers from the world instead -- the key on the
--- player's profile, the squad's use this match, the terminal against the
--- current safe zone.
--- @return table { keyHeld: boolean, squadUsed: boolean, offline: boolean }
function T.facts(_, session)
    return session.facts
end

--- Spend the key and the squad's one use, after a run that happened.
--- THE STUB spends the dev session's facts.
function T.consume(_, session)
    session.facts.keyHeld = false
    session.facts.squadUsed = true
end

--- Why `fn` cannot run now, as a reason code (a key into the copy), or nil.
--- The order is the order a player would want to hear them in: a dead
--- terminal first, then the squad, then their own key.
local function refusal(src, session, fn)
    local f = T.facts(src, session)
    if f.offline then return 'offline' end
    if f.squadUsed then return 'squad_used' end
    if not f.keyHeld then return 'no_key' end
    if fn.refuse then return fn.refuse(src, session) end
    return nil
end

local function listed(id)
    for _, row in ipairs(cfg().functions) do
        if row.id == id then return true end
    end
    return false
end

--- The terminal as this player sees it: the payload the computer opens with.
--- @return table { terminalId, functions = { { id, available, reason } }, keyHeld, squadUsed }
function T.state(src, session)
    local f = T.facts(src, session)
    local list = {}
    for _, row in ipairs(cfg().functions) do
        local fn = T.FUNCTIONS[row.id]
        if fn then
            local why = refusal(src, session, fn)
            list[#list + 1] = { id = row.id, available = why == nil, reason = why }
        end
    end
    return {
        terminalId = session.terminalId,
        functions = list,
        keyHeld = f.keyHeld == true,
        squadUsed = f.squadUsed == true,
    }
end

-- ------------------------------------------------------------ sessions ---

--- Open the computer for `src` on `terminalId`, with these facts.
--- @return table the session
function T.open(src, terminalId, facts, dev)
    local session = {
        terminalId = terminalId,
        facts = {
            keyHeld = facts.keyHeld == true,
            squadUsed = facts.squadUsed == true,
            offline = facts.offline == true,
        },
        dev = dev == true,
    }
    sessions[src] = session
    TriggerClientEvent(BR.Net.TERMINAL_OPEN, src, { state = T.state(src, session) })
    return session
end

--- Close it from here (death, storm, teardown, the dev command).
--- @return boolean false when there was no session
function T.close(src, why)
    if not sessions[src] then return false end
    sessions[src] = nil
    TriggerClientEvent(BR.Net.TERMINAL_CLOSE, src, { why = why })
    return true
end

--- The client's computer went away. Ends the session it names, and only that.
function T.closed(src, d)
    local session = sessions[src]
    if session and type(d) == 'table' and d.terminalId == session.terminalId then
        sessions[src] = nil
    end
end

--- @return table|nil
function T.session(src)
    return sessions[src]
end

--- One run request. Returns the answer to send the runner, or nil and why it
--- was dropped without one -- a request with no session, the wrong shape or
--- too soon after the last earns no answer at all.
--- @param now integer  GetGameTimer()
--- @return table|nil result, string|nil dropped
function T.run(src, d, now)
    if type(d) ~= 'table' then return nil, 'shape' end
    local session = sessions[src]
    if not session then return nil, 'no-session' end
    if d.terminalId ~= session.terminalId then return nil, 'wrong-terminal' end
    local id = d.functionId
    if type(id) ~= 'string' or #id > FUNCTION_ID_MAX or not id:match(FUNCTION_ID) then
        return nil, 'shape'
    end
    local last = lastRunAt[src]
    if last ~= nil and now - last < cfg().runMinIntervalMs then return nil, 'too-soon' end
    lastRunAt[src] = now
    -- The season can be switched under an open session (`brseason`, dev
    -- boxes); a terminal is a Season 2 thing whatever opened it, so the
    -- computer closes rather than leaving a button that waits forever.
    if not BR.Season.has('terminals') then
        T.close(src, 'season')
        return nil, 'season'
    end

    local answer = { terminalId = session.terminalId, functionId = id }
    local fn = T.FUNCTIONS[id]
    if not fn or not listed(id) then
        answer.ok, answer.code = false, 'unavailable'
        return answer
    end
    local why = refusal(src, session, fn)
    if why then
        answer.ok, answer.code = false, why
        answer.state = T.state(src, session)
        return answer
    end

    local r = fn.run(src, session) or {}
    answer.ok = r.ok == true
    answer.code = type(r.code) == 'string' and r.code or (answer.ok and 'done' or 'unavailable')
    if answer.ok then T.consume(src, session) end
    answer.state = T.state(src, session)
    return answer
end

-- ---------------------------------------------------------- net events ---

-- THE RUN REQUEST. Session, shape, rate and season, then the facts -- see
-- BR.Terminal.run. A dropped request is answered with nothing.
RegisterNetEvent(BR.Net.TERMINAL_RUN)
AddEventHandler(BR.Net.TERMINAL_RUN, function(d)
    local src = tonumber(source)
    if not src then return end
    local answer = BR.Terminal.run(src, d, GetGameTimer())
    if answer then TriggerClientEvent(BR.Net.TERMINAL_RESULT, src, answer) end
end)

-- The computer went away on this client. Ends only the session it names.
RegisterNetEvent(BR.Net.TERMINAL_CLOSED)
AddEventHandler(BR.Net.TERMINAL_CLOSED, function(d)
    local src = tonumber(source)
    if not src then return end
    BR.Terminal.closed(src, d)
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end
    sessions[src] = nil
    lastRunAt[src] = nil
end)

-- ---------------------------------------------------------------- dev ---

local USAGE = 'usage: brterminalsv open [nokey] [used] [offline] | brterminalsv close'
    .. ' (from the server console: brterminalsv open <player id> [...] | close <player id>)'

--- One line on the requester's F8 (or this console), and nowhere else.
local function tell(src, text)
    print(('[br_core] brterminal (client %s): %s'):format(tostring(src), text))
    if src > 0 then TriggerClientEvent(BR.Net.TERMINAL_DEV, src, text) end
end

--- The facts a dev session opens with: a key and nothing against it, unless
--- the words say otherwise.
--- @return table|nil facts, string|nil the word that was not understood
local function devFacts(words)
    local facts = { keyHeld = true, squadUsed = false, offline = false }
    for _, w in ipairs(words) do
        w = w:lower()
        if w == 'nokey' then facts.keyHeld = false
        elseif w == 'used' then facts.squadUsed = true
        elseif w == 'offline' then facts.offline = true
        else return nil, w end
    end
    return facts, nil
end

-- `brterminal` (client/terminal.lua) runs this with ExecuteCommand, so it
-- arrives as the player who typed it. REGISTERED UNRESTRICTED, as `brpropsv`
-- is: dev mode, through devgate.lua's wrap, is its only gate, and it opens a
-- computer on the requester's own screen with facts that exist only in that
-- session.
RegisterCommand('brterminalsv', function(source, args)
    local src = tonumber(source) or 0
    args = args or {}
    local verb = args[1] and args[1]:lower() or ''
    local target, from = src, 2
    if src == 0 then
        target, from = tonumber(args[2]) or 0, 3
    end
    if target <= 0 or not GetPlayerName(target) then
        tell(src, 'that needs a player. ' .. USAGE)
        return
    end

    if verb == 'open' then
        if not BR.Season.has('terminals') then
            tell(src, ('terminals are Season 2 and this box runs Season %s -- `brseason 2` first')
                :format(tostring(BR.Season.current())))
            return
        end
        local words = {}
        for i = from, #args do words[#words + 1] = args[i] end
        local facts, bad = devFacts(words)
        if not facts then
            tell(src, ('"%s"? %s'):format(bad, USAGE))
            return
        end
        T.open(target, 'dev', facts, true)
        tell(src, ('opened terminal "dev" for %d: key %s, squad %s, %s')
            :format(target, facts.keyHeld and 'held' or 'none',
                facts.squadUsed and 'used' or 'unused',
                facts.offline and 'offline' or 'online'))

    elseif verb == 'close' then
        if T.close(target, 'dev') then
            tell(src, ('closed the computer for %d'):format(target))
        else
            tell(src, ('%d has no terminal open'):format(target))
        end

    else
        tell(src, USAGE)
    end
end, false)

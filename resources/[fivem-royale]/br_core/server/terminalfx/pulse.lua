-- Season 2 terminals (#396), wave A: PULSE, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `pulse_*`): "Every player outside
-- your squad within the radius you choose shows on your squad's maps. The
-- marks follow them for 30 seconds." Option `radius`: 250 or 500 meters,
-- around this terminal. "Every player the pulse finds is told they've been
-- detected."
--
--   FOUND        when it runs, once: every player outside the runner's squad
--                in the fight with a position (standing, downed, in the air)
--                within the radius of this terminal -- BR.Terminal.anchorOf,
--                so the dev terminal pulses around the player -- by the
--                ground distance. A squad under Ghost is not found
--                (BR.Terminal.hidden, the one predicate Scan and the bounty
--                ask too), and so is not told it was.
--   FOLLOWED     those players and nobody else, wherever they go, every
--                fx.pulsePingMs (1 s) for fx.pulseMs (30 s), to the squad
--                (TERMINAL_PULSE, the dead and spectating members included,
--                like Scan); one empty push takes the marks down when it is
--                over, the match ends, or nobody found is left to mark. A
--                found player who goes under Ghost meanwhile drops off the
--                next push.
--   TOLD         `pulse_detected`, to each player found, after the lobby's
--                notice -- through the picker, by their own match.
--
-- NOT REFUSED FOR FINDING NOBODY. A refusal spends nothing, so "nobody is
-- near" would be free intel a player could ask for at every terminal; an
-- empty pulse is a pulse. Its client half is client/terminalfx/pulse.lua.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function copy() return BR.Config.Terminals.copy end
local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- Is squad `key` hidden from other squads' marks right now? Ghost's answer
--- (server/terminalfx/ghost.lua), and no squad is while it is not built.
local function hidden(m, key, now)
    return T.hidden ~= nil and T.hidden(m, key, now) == true
end

--- Every player outside squad `key` the pulse finds from (x, y).
--- @return integer[]
local function finds(m, key, x, y, radius, now)
    local out = {}
    local r2 = radius * radius
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        local theirs = TS.squadKey(e, src)
        if theirs ~= key and T.marked(e.state) and e.pos and not hidden(m, theirs, now) then
            local dx, dy = e.pos.x - x, e.pos.y - y
            if dx * dx + dy * dy <= r2 then out[#out + 1] = src end
        end
    end)
    table.sort(out)
    return out
end

--- Where the found players of one pulse are now: { { s, x, y } }.
local function marks(m, p, now)
    local out = {}
    for _, src in ipairs(p.found) do
        local e = BR.Roster.get(src)
        if e and e.matchId == m.id and T.marked(e.state) and e.pos
           and not hidden(m, TS.squadKey(e, src), now) then
            out[#out + 1] = { s = src, x = e.pos.x + 0.0, y = e.pos.y + 0.0 }
        end
    end
    return out
end

local function send(m, key, list)
    local payload = { matchId = m.id, list = list }
    for _, s in ipairs(T.squadOf(m, key)) do
        TriggerClientEvent(BR.Net.TERMINAL_PULSE, s, payload)
    end
end

--- Every pulse in this match, followed or ended. Public so the suites can
--- step it. Off Season 2 they are forgotten and nothing is sent.
--- @param m table
--- @param now number
function T.pushPulses(m, now)
    local st = m.terminalFx
    local all = st and st.pulses
    if not all then return end
    if not on() then
        st.pulses = nil
        return
    end
    for key, p in pairs(all) do
        local list = (now < p.untilAt and m.state == BR.MatchState.PLAYING) and marks(m, p, now) or {}
        send(m, key, list)
        if #list == 0 then all[key] = nil end
    end
end

T.FUNCTIONS.pulse = {
    -- Outside a match there is nothing to pulse; a dev session (typed facts,
    -- for walking the app) is never refused for it.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        return nil
    end,
    run = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Pulse ran on the dev terminal '
                    .. 'with no match to pulse'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local x, y = T.anchorOf(src, session)
        if not x then return { ok = false, code = 'unavailable' } end
        local radius = tonumber(opts and opts.radius) or 250
        local now = GetGameTimer()
        local found = finds(m, key, x, y, radius, now)
        local st = T.fxOf(m)
        st.pulses = st.pulses or {}
        local p = { found = found, untilAt = now + (tonumber(fx().pulseMs) or 30000) }
        st.pulses[key] = p
        local list = marks(m, p, now)
        send(m, key, list)
        if #list == 0 then st.pulses[key] = nil end
        print(('[br_core] terminals: Pulse (%d m) for %s found %d player(s)')
            :format(radius, key, #found))
        -- EVERY PLAYER IT FOUND IS TOLD, after "has redeemed their special
        -- power: Pulse..." -- each in their own match's words.
        return { ok = true, code = 'done', after = function()
            for _, s in ipairs(found) do
                BR.Server.notify(s, TS.pick(copy(), 'pulse_detected', T.squadMatch(s) == true), 'warn',
                    { ms = 8000 })
            end
        end }
    end,
}

-- FOLLOWED ON THE SERVER'S SCHEDULE, nothing per frame: once a second while
-- a pulse is up, and not at all with none.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().pulsePingMs or 1000, 'terminal.pulse', function()
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.terminalFx.pulses then T.pushPulses(m, now) end
        end)
    end)
end

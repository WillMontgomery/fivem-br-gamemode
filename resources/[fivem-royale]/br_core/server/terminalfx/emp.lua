-- Season 2 terminals (#396), wave C: EMP, the server half.
--
-- ROUND 4 (owner, 2026-10-06): "The EMP tool should kill all cars in the
-- entire match, except the ones that the user or their squad get into. This
-- should last for 3 minutes."
--
-- THE PAGE (br_lib/config/terminals.lua, `emp_*`): "For 3 minutes, every
-- vehicle in the match stalls and won't start while a player outside your
-- squad is driving it. Vehicles your squad drives keep working. If someone
-- outside your squad takes the wheel, it stalls. Vehicles start again when it
-- ends." No options; fx.empMs (3 minutes).
--
-- ═══ A FACT ABOUT DRIVERS, NOT A MARK ON CARS ═══
--
-- Wave C stalled the vehicles inside a radius by a state bag on each. "All
-- cars in the entire match, except the ones the user or their squad get into"
-- is a rule about WHO IS DRIVING, and it holds for a car that was parked a
-- mile away when it went off, for one that drives in later, and for one that
-- changes hands mid-EMP -- so nothing is picked and nothing is marked. The
-- server keeps one match-wide fact per EMP (`m.terminalFx.emps`: the squad it
-- spares, who ran it, when it ends), and tells every player in the match how
-- long THEIR driving stalls (TERMINAL_EMP, `leftMs`; absent when every EMP in
-- force spares their squad) and how long any EMP lasts (`liveMs`). Each client
-- applies it to the vehicle its own player is driving -- client/terminalfx/
-- emp.lua, on the fact's change, on getting in, and on the one SLOW pass --
-- never per frame, and never to a car nobody of theirs drives.
--
--   SPARED        the runner's squad (BR.TerminalSolve.squadKey); a solo
--                 player is a squad of one. Two EMPs from two squads spare
--                 neither from the other's: a player's driving stalls until
--                 the last EMP that does not spare them ends.
--   IT ENDS       at fx.empMs, on the job below; with the match (not PLAYING,
--                 the end screen included, and a match torn down -- its
--                 players go to the lobby, where every client lets go); off
--                 Season 2; and on a client as br_core stops. Each end that
--                 changes what a player's driving does is pushed to them.
--   A CLIENT THAT RESTARTS is told again on br:ready.
--
-- NEVER REFUSED for anything but being outside a match: there is always a
-- match's worth of vehicles to stall. Nothing here creates, deletes, moves or
-- marks a vehicle: server/vehicles.lua's creation rule, the fuel ledger and
-- sv_entityLockdown are untouched.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- The EMPs in force in this match now, or an empty list: none once the
--- match is not being played or off Season 2.
--- @param m table|nil
--- @param now number
--- @return table[] { { squad, by, untilAt } }
local function inForce(m, now)
    local list = m and m.terminalFx and m.terminalFx.emps or nil
    if not list or not on() or m.state ~= BR.MatchState.PLAYING then return {} end
    local out = {}
    for _, e in ipairs(list) do
        if now < e.untilAt then out[#out + 1] = e end
    end
    return out
end

--- THE EMP THIS PLAYER'S DRIVING STALLS UNDER that ends last -- the latest
--- end among the EMPs in force that do not spare their squad -- or nil when
--- none does. The ONE answer the push and the persistent notice read.
--- @param m table
--- @param src integer
--- @param now number
--- @return table|nil  { squad, by, untilAt }
function T.empOn(m, src, now)
    local e = BR.Roster.get(src)
    if not e then return nil end
    local key = TS.squadKey(e, src)
    local best = nil
    for _, emp in ipairs(inForce(m, now)) do
        if emp.squad ~= key and (best == nil or emp.untilAt > best.untilAt) then best = emp end
    end
    return best
end

--- How long this player's driving stalls, in ms from now, or nil.
--- @param m table
--- @param src integer
--- @param now number
--- @return number|nil
function T.empFor(m, src, now)
    local emp = T.empOn(m, src, now)
    return emp and (emp.untilAt - now) or nil
end

--- What TERMINAL_EMP tells `src`: how long their driving stalls (`leftMs`,
--- absent when spared or with none in force) and how long any EMP in this
--- match lasts (`liveMs`, absent with none in force).
local function payloadFor(m, src, now)
    local live = nil
    for _, emp in ipairs(inForce(m, now)) do
        if live == nil or emp.untilAt > live then live = emp.untilAt end
    end
    local left = T.empFor(m, src, now)
    return { matchId = m.id, leftMs = left and math.floor(left) or nil,
             liveMs = live and math.floor(live - now) or nil }
end

--- Tell every player in this match (or only `only`) what an EMP does to their
--- driving now. Public so the suites can step it.
--- @param m table
--- @param now number
--- @param only integer|nil
function T.pushEmp(m, now, only)
    for _, src in ipairs(only and { only } or T.lobbyOf(m)) do
        TriggerClientEvent(BR.Net.TERMINAL_EMP, src, payloadFor(m, src, now))
    end
end

--- Go off: every player outside squad `key` stalls whatever they drive for
--- fx.empMs.
--- @param m table
--- @param key string  the runner's squad, spared
--- @param by integer
--- @param now number
function T.startEmp(m, key, by, now)
    local st = T.fxOf(m)
    st.emps = st.emps or {}
    local ms = tonumber(fx().empMs) or 180000
    st.emps[#st.emps + 1] = { squad = key, by = by, untilAt = now + ms }
    T.pushEmp(m, now)
    print(('[br_core] terminals: EMP by %s in match %s, %.0f s: every vehicle another squad drives stalls')
        :format(tostring(key), tostring(m.id), ms / 1000))
end

--- Drop the EMPs that are over -- every one of them once the match is not
--- being played or off Season 2 -- and tell the match when that changed what
--- anybody's driving does. Public so the suites can step it.
--- @param m table
--- @param now number
function T.expireEmp(m, now)
    local st = m.terminalFx
    local list = st and st.emps
    if not list then return end
    local keep = inForce(m, now)
    if #keep == #list then return end
    st.emps = (#keep > 0) and keep or nil
    T.pushEmp(m, now)
    print(('[br_core] terminals: %d EMP(s) over in match %s'):format(#list - #keep, tostring(m.id)))
end

T.FUNCTIONS.emp = {
    -- Outside a match there is nothing to stall; a dev session (typed facts,
    -- for walking the app) is never refused for it.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        return nil
    end,
    run = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): EMP ran on the dev terminal '
                    .. 'with no match to stall'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        T.startEmp(m, key, src, GetGameTimer())
        return { ok = true, code = 'done' }
    end,
}

-- ONCE A SECOND: the EMPs whose time is up, and every EMP of a match no longer
-- being played (or off Season 2), ended and said.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().endCheckMs or 1000, 'terminal.emp', function()
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.terminalFx.emps then T.expireEmp(m, now) end
        end)
    end)
end

-- A client that restarts mid-EMP is told again.
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() then return end
    local m = T.whereIs(src)
    if m and #inForce(m, GetGameTimer()) > 0 then T.pushEmp(m, GetGameTimer(), src) end
end)

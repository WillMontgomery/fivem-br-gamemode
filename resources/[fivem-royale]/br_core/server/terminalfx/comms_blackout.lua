-- Season 2 terminals (#396), wave C: COMMS BLACKOUT, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `comms_blackout_*`): "Players in
-- every other squad stop seeing their teammates on the map and the minimap.
-- Your squad isn't affected. Voice chat isn't affected." Option `duration`:
-- 60, 120 or 180 seconds (the row's choices, read as seconds). Squad-only: the
-- door hides it and refuses it outside a squad match (round 2).
--
-- ═══ ONE PREDICATE, EVERY SENDER ASKS IT ═══
--
-- BR.Terminal.blackedOut(m, key, now) is the whole of the effect: a Comms
-- blackout run by ANOTHER squad is in force in this match, the match is being
-- played, the season is 2. Every teammate position the server sends rides ONE
-- push, the squad beacon (server/party.lua's `party.squadpos`, BR.Net.SQUAD_POS,
-- 4 Hz): the dots on both maps, a downed mate's dot, the dot left where a mate
-- fell, and a mate with a bounty in the owner's blip 58 color 69. The beacon
-- asks BR.Terminal.beaconDark for each squad and, while it says so, leaves `x`
-- and `y` off every row it sends that squad -- the positions stop leaving the
-- server, which is the only way "stop seeing" holds against a modified client.
-- client/squadmates.lua takes a row with no position as "no dot": it removes
-- that mate's blip and makes it afresh when positions come back.
--
-- WHAT IT LEAVES, AND WHY. The beacon keeps sending everything else on those
-- rows -- the names, states, levels, the bleed clock, the voice bit, the
-- Yubikey and bounty marks, the revive key -- because the client's membership
-- model IS that push (going quiet would read as "no longer in the squad"),
-- and none of it is a position on a map. The squad panel never showed where a
-- teammate is (client/state.lua folds no coordinate into it), so there is
-- nothing there to take away. The revive key's own ground marker and plate
-- (client/revivekey.lua, within 120 m of the key, in the world) stay: they are
-- how a squad picks the key up, a three-minute window a blackout of up to
-- three would otherwise close, and they are not the map. Overhead names hang
-- off peds the player can already see. Map pings (server/markers.lua) are
-- where a mate pointed, not where they are. Voice, by the page, is untouched.
--
-- GHOST AND THE BOUNTY. A blackout and Ghost answer different questions --
-- Ghost hides a squad from OTHER squads' marks, a blackout hides a squad's
-- members from EACH OTHER -- so neither changes the other: a squad under
-- Ghost is blacked out like any other squad, a blacked-out squad's Ghost still
-- hides it from Scan and the bounty marks, and the runner's own squad
-- is untouched either way. A bounty on a blacked-out squad's member leaves
-- that squad's maps with the rest of their dots (its color 69 blip is the
-- beacon's), keeps its mark in their panel, and stays on every other map
-- (TERMINAL_BOUNTY, color 3): to everyone else it is not a teammate.
--
-- It ends on its own clock (the beacon asks the clock every push; the job
-- below forgets a run-out record), with the match (the predicate asks the
-- match's state, and a new match is a new record), and off Season 2 (the
-- predicate asks the season, and the job forgets every record). No client
-- half of its own: client/squadmates.lua draws what the beacon sends.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- IS SQUAD `key` BLACKED OUT RIGHT NOW? A Comms blackout run by another
--- squad is in force, in a match still being played, on Season 2.
--- @param m table|nil
--- @param key string|nil  BR.TerminalSolve.squadKey
--- @param now number
--- @return boolean
function T.blackedOut(m, key, now)
    if not (m and key and on()) then return false end
    if m.state ~= BR.MatchState.PLAYING then return false end
    local all = m.terminalFx and m.terminalFx.blackouts or nil
    if not all then return false end
    for by, b in pairs(all) do
        if by ~= key and now < b.untilAt then return true end
    end
    return false
end

--- The squad beacon's question (server/party.lua), by the squad id it groups
--- on: may this squad be sent where its members are?
--- @param m table|nil
--- @param squadId any
--- @param now number
--- @return boolean true when the positions must be left off
function T.beaconDark(m, squadId, now)
    if squadId == nil then return false end
    return T.blackedOut(m, TS.squadKey({ squadId = squadId }, nil), now)
end

--- Forget every blackout that has run out (and, off Season 2, every one).
--- Public so the suites can step it.
--- @param m table
--- @param now number
function T.expireBlackouts(m, now)
    local st = m.terminalFx
    if not (st and st.blackouts) then return end
    if not on() then
        st.blackouts = nil
        return
    end
    for key, b in pairs(st.blackouts) do
        if now >= b.untilAt then st.blackouts[key] = nil end
    end
    if next(st.blackouts) == nil then st.blackouts = nil end
end

T.FUNCTIONS.comms_blackout = {
    -- Outside a match there is nobody to black out; a dev session (typed
    -- facts, for walking the app) is never refused for it.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        return nil
    end,
    run = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Comms blackout ran on the dev terminal '
                    .. 'with no match to black out'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local seconds = tonumber(opts and opts.duration) or 60
        local now = GetGameTimer()
        local st = T.fxOf(m)
        st.blackouts = st.blackouts or {}
        local was = st.blackouts[key]
        local untilAt = now + seconds * 1000
        -- A SECOND BLACKOUT NEVER SHORTENS THE FIRST (only the dev command can
        -- run it twice: a squad has one use).
        if was and was.untilAt > untilAt then untilAt = was.untilAt end
        st.blackouts[key] = { untilAt = untilAt, by = src }
        print(('[br_core] terminals: Comms blackout by %s in match %s, %d s')
            :format(key, tostring(m.id), seconds))
        return { ok = true, code = 'done' }
    end,
}

if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().endCheckMs or 1000, 'terminal.blackout', function()
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.terminalFx.blackouts then T.expireBlackouts(m, now) end
        end)
    end)
end

-- THE PERSISTENT NOTICE (round 4): every player with a teammate in a squad
-- another squad has blacked out, until the last such blackout ends -- a player
-- with no teammate has no dot to lose. Squad-only, like the function.
T.impactSource(function(m, now, add)
    local all = m.terminalFx and m.terminalFx.blackouts or nil
    if not all then return end
    local size = {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        local key = TS.squadKey(e, src)
        size[key] = (size[key] or 0) + 1
    end)
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        local key = TS.squadKey(e, src)
        if size[key] < 2 then return end
        local untilAt = nil
        for by, b in pairs(all) do
            if by ~= key and now < b.untilAt and (untilAt == nil or b.untilAt > untilAt) then
                untilAt = b.untilAt
            end
        end
        if untilAt then add(src, 'impact_blackout', untilAt) end
    end)
end)

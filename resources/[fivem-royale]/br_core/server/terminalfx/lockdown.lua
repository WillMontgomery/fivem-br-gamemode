-- Season 2 terminals (#396), wave A: LOCKDOWN, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `lockdown_*`): "Every other terminal
-- goes offline for the time you choose. Nobody can open them. This terminal
-- stays online, unless the storm reaches it." The risk: "every key holder's
-- map shows it" -- and only it. Option `duration`: 180 or 300 seconds (the
-- row's choices, read as seconds).
--
-- ═══ ONE ONLINE RULE ═══
--
-- A Lockdown is not a second idea of "online". It is the `lock` argument of
-- BR.TerminalSolve.offlineWhy, the one rule the server (BR.Terminal.offlineWhy:
-- every use, every run, every session check, the panel's count, `brterminal
-- list`) and every client (client/yubikey.lua: the blips and the plates) read
-- -- next to the storm and the dev tool's forcing, which it beats. What this
-- file keeps is only the fact: { keep, untilAt } on the match, answered by
-- BR.Terminal.lockOf.
--
--   THIS TERMINAL   the session's (BR.Terminal.site). The dev terminal is
--                   nowhere, so a dev run keeps the terminal nearest the
--                   player -- Supply drop's rule for "this terminal" there.
--   OPEN SESSIONS   at the others close at once, as when the storm takes a
--                   terminal (BR.Terminal.checkSessions); nobody can open one
--                   again until it ends (BR.Terminal.use refuses `locked`, said
--                   aloud in `locked`'s words).
--   EVERY CLIENT    in the match is told (TERMINAL_LOCKDOWN: which terminal is
--                   kept, and the time left), so its plates say `locked` and a
--                   key holder's map shows the one terminal left; told again
--                   when it ends, and on br:ready while it lasts.
--   IT ENDS         on its own clock (the job below), with the match (lockOf
--                   asks the match), and off Season 2.
--
-- REFUSED, SPENDING NOTHING, when no other terminal is online to take offline
-- (`lockdown_none`) -- and again when the load ends. Its client half is
-- client/terminalfx/lockdown.lua.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- The Lockdown in force in this match now, or nil: { keep = id|nil, untilAt }.
--- @param m table
--- @param now number
--- @return table|nil
function T.lockOf(m, now)
    local l = m and m.terminalFx and m.terminalFx.lockdown or nil
    if not l or not on() then return nil end
    if m.state ~= BR.MatchState.PLAYING or now >= l.untilAt then return nil end
    return l
end

--- The terminal a Lockdown run here keeps online: the session's, or the one
--- nearest the player at the dev terminal (nil when there is none).
--- @return table|nil site
local function kept(src, session)
    local _, _, site = T.anchorOf(src, session)
    if site then return site end
    local e = BR.Roster and BR.Roster.get(src) or nil
    if not (e and e.pos) then return nil end
    local best, bestD2 = nil, math.huge
    for _, s in ipairs(T.sites()) do
        local dx, dy = s.x - e.pos.x, s.y - e.pos.y
        local d2 = dx * dx + dy * dy
        if d2 < bestD2 then best, bestD2 = s, d2 end
    end
    return best
end

--- Is any terminal but `keep` online in this match right now?
local function othersOnline(m, keep, now)
    for _, s in ipairs(T.sites()) do
        if (keep == nil or s.id ~= keep.id) and T.online(s, m, now) then return true end
    end
    return false
end

--- Tell everyone in the match where things stand.
local function tell(m, l, now)
    local payload = { matchId = m.id, on = l ~= nil }
    if l then payload.keep, payload.leftMs = l.keep, math.max(0, l.untilAt - now) end
    for _, s in ipairs(T.lobbyOf(m)) do
        TriggerClientEvent(BR.Net.TERMINAL_LOCKDOWN, s, payload)
    end
end

--- End a Lockdown that has run out, or whose match is no longer played: one
--- message to the match. Off Season 2 it is forgotten and nothing is sent.
--- Public so the suites can step it.
--- @param m table
--- @param now number
function T.expireLockdown(m, now)
    local st = m.terminalFx
    local l = st and st.lockdown
    if not l then return end
    if not on() then
        st.lockdown = nil
        return
    end
    if now >= l.untilAt or m.state ~= BR.MatchState.PLAYING then
        st.lockdown = nil
        tell(m, nil, now)
        print(('[br_core] terminals: the Lockdown in match %s is over'):format(tostring(m.id)))
    end
end

T.FUNCTIONS.lockdown = {
    -- NOTHING TO TAKE OFFLINE IS REFUSED, SPENDING NOTHING: every other
    -- terminal is already offline (the storm has them, or another Lockdown).
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if not othersOnline(m, kept(src, session), GetGameTimer()) then return 'lockdown_none' end
        return nil
    end,
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Lockdown ran on the dev terminal '
                    .. 'with no match to lock down'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local now = GetGameTimer()
        local keep = kept(src, session)
        if not othersOnline(m, keep, now) then return { ok = false, code = 'lockdown_none' } end
        local seconds = tonumber(opts and opts.duration) or 180
        local st = T.fxOf(m)
        st.lockdown = { keep = keep and keep.id or nil, untilAt = now + seconds * 1000, by = src }
        -- OPEN COMPUTERS AT THE OTHERS CLOSE NOW, as the storm closes them.
        T.checkSessions(now)
        tell(m, st.lockdown, now)
        print(('[br_core] terminals: Lockdown in match %s: only %s online for %d s')
            :format(tostring(m.id), tostring(keep and keep.id), seconds))
        return { ok = true, code = 'done' }
    end,
}

if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().endCheckMs or 1000, 'terminal.lockdown', function()
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.terminalFx.lockdown then T.expireLockdown(m, now) end
        end)
    end)
end

-- A client that restarts during a Lockdown is told it again.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() then return end
    local m = T.whereIs(src)
    local now = GetGameTimer()
    local l = m and T.lockOf(m, now) or nil
    if l then
        TriggerClientEvent(BR.Net.TERMINAL_LOCKDOWN, src,
            { matchId = m.id, on = true, keep = l.keep, leftMs = l.untilAt - now })
    end
end)

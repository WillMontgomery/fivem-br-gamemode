-- Season 2 terminals (#396), wave A: GHOST, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `ghost_*`): "Your squad doesn't show
-- up on other squads' Scan or Pulse markers. If one of you has a bounty, the
-- bounty marker is hidden too. It doesn't hide you from anyone who can see
-- you." Option `duration`: 120 or 240 seconds (the row's choices, read as
-- seconds).
--
-- ═══ ONE PREDICATE, EVERY MARK ASKS IT ═══
--
-- BR.Terminal.hidden(m, key, now) is the whole of Ghost's effect. Scan's push
-- and the bounty's push (server/terminalfx.lua) and Pulse
-- (server/terminalfx/pulse.lua) each ask it before they put a player on
-- another squad's map, so the three cannot disagree about who is hidden or
-- until when. Nothing is sent to anybody's client about Ghost itself: a
-- hidden squad's marks simply stop arriving, and the next push after it ends
-- brings them back. The squad's own view (its beacon, its own bounty mark,
-- its own Scan) is untouched, and so is anything a player can see with their
-- eyes -- this changes what the server SENDS, nothing in the world.
--
-- It starts by pushing Scan, the bounty and Pulse at once, so the marks go
-- when the run finishes rather than up to a push later. It ends on its own
-- clock, at the match's end (a new match is a new record), and off Season 2
-- (the job below forgets it). No client half.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- IS SQUAD `key` HIDDEN FROM OTHER SQUADS' MARKS RIGHT NOW? Under Ghost, in
--- a match still being played, on Season 2.
--- @param m table|nil
--- @param key string|nil
--- @param now number
--- @return boolean
function T.hidden(m, key, now)
    if not (m and key and on()) then return false end
    if m.state ~= BR.MatchState.PLAYING then return false end
    local g = m.terminalFx and m.terminalFx.ghosts and m.terminalFx.ghosts[key] or nil
    return g ~= nil and now < g.untilAt
end

--- Forget every Ghost that has run out (and, off Season 2, every one). Public
--- so the suites can step it.
--- @param m table
--- @param now number
function T.expireGhosts(m, now)
    local st = m.terminalFx
    if not (st and st.ghosts) then return end
    if not on() then
        st.ghosts = nil
        return
    end
    for key, g in pairs(st.ghosts) do
        if now >= g.untilAt then st.ghosts[key] = nil end
    end
end

T.FUNCTIONS.ghost = {
    -- Outside a match there is nobody to hide; a dev session (typed facts,
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
                print(('[br_core] brterminal (client %d): Ghost ran on the dev terminal '
                    .. 'with no squad to hide'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local seconds = tonumber(opts and opts.duration) or 120
        local now = GetGameTimer()
        local st = T.fxOf(m)
        st.ghosts = st.ghosts or {}
        local was = st.ghosts[key]
        local untilAt = now + seconds * 1000
        -- A SECOND GHOST NEVER SHORTENS THE FIRST (only the dev command can
        -- run it twice: a squad has one use).
        if was and was.untilAt > untilAt then untilAt = was.untilAt end
        st.ghosts[key] = { untilAt = untilAt, by = src }
        -- THE MARKS GO NOW, not a push later.
        T.pushScans(m)
        T.pushBounties(m, now)
        if T.pushPulses then T.pushPulses(m, now) end
        print(('[br_core] terminals: Ghost for %s in match %s, %d s')
            :format(key, tostring(m.id), seconds))
        return { ok = true, code = 'done' }
    end,
}

if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().endCheckMs or 1000, 'terminal.ghost', function()
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.terminalFx.ghosts then T.expireGhosts(m, now) end
        end)
    end)
end

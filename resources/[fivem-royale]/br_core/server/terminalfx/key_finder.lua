-- Season 2 terminals (#396), wave A: KEY FINDER, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `key_finder_*`): "Marks Yubikeys on
-- your squad's maps. The marks show where the keys were when it ran. They
-- don't follow anyone, and they fade after 2 minutes." Option `target`:
-- `ground` (keys lying loose) or `holders` (players holding one). The holders
-- it marks are warned. Refused, spending nothing, when there is nothing to
-- mark for the chosen target.
--
--   OTHER YUBIKEYS   "where other Yubikeys are": every loose key in this
--                    match's loot (kind `yubikey`, the "standard pickup"), or
--                    every player OUTSIDE the runner's squad who holds one and
--                    is in the fight with a position. The squad's own holders
--                    are already on its panel.
--   WHERE THEY WERE  one position each, taken when it runs and never moved
--                    (TERMINAL_KEYS, to the squad -- the dead and the
--                    spectating included, like Scan).
--   2 MINUTES        fx.keyFinderMs, timed HERE: the job below sends the squad
--                    one empty list when it is up, and the match ending ends it
--                    the same way (and the lobby clears the maps). A client
--                    that restarts meanwhile is sent the marks again on
--                    br:ready.
--   THE WARNING      `key_finder_warned`, to each holder it marked, after the
--                    lobby's notice -- through the picker, by THEIR match.
--
-- Its client half is client/terminalfx/key_finder.lua.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function copy() return BR.Config.Terminals.copy end
local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- Every loose Yubikey in this match's loot, as { x, y }.
--- @param m table
--- @param first boolean|nil  stop at the first (a refusal only asks "any?")
--- @return table[]
local function groundKeys(m, first)
    local out = {}
    local items = m.loot and m.loot.items or nil
    for _, e in pairs(items or {}) do
        if e.kind == 'yubikey' and TS.finite(e.x) and TS.finite(e.y) then
            out[#out + 1] = { x = e.x + 0.0, y = e.y + 0.0 }
            if first then return out end
        end
    end
    -- pairs() has no order; a fixed one, so every map draws the same list.
    table.sort(out, function(a, b) return a.x < b.x or (a.x == b.x and a.y < b.y) end)
    return out
end

--- Every player outside squad `key` holding a Yubikey, in the fight, with a
--- position: { s, x, y }.
--- @param m table
--- @param key string
--- @return table[]
local function holders(m, key)
    local out = {}
    if not (BR.Yubikey and BR.Yubikey.holds) then return out end
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if T.marked(e.state) and e.pos and TS.squadKey(e, src) ~= key and BR.Yubikey.holds(src) then
            out[#out + 1] = { s = src, x = e.pos.x + 0.0, y = e.pos.y + 0.0 }
        end
    end)
    return out
end

--- Why there is nothing to mark for this choice (nil: any choice), or nil.
local function nothing(m, key, target)
    if target == 'ground' then
        return #groundKeys(m, true) == 0 and 'no_keys_ground' or nil
    elseif target == 'holders' then
        return #holders(m, key) == 0 and 'no_keys_held' or nil
    end
    if #holders(m, key) > 0 or #groundKeys(m, true) > 0 then return nil end
    return 'no_keys'
end

--- Send a squad its marks (an empty list takes them down).
local function push(m, key, list, leftMs)
    local payload = { matchId = m.id, list = list, leftMs = leftMs }
    for _, s in ipairs(T.squadOf(m, key)) do
        TriggerClientEvent(BR.Net.TERMINAL_KEYS, s, payload)
    end
end

--- Take down every squad's marks whose two minutes are up -- all of them once
--- the match is no longer being played. Off Season 2 they are forgotten and
--- nothing is sent (every client clears its own marks when the season goes).
--- Public so the suites can step it.
--- @param m table
--- @param now number
function T.expireKeyFinds(m, now)
    local st = m.terminalFx
    local finds = st and st.finds
    if not finds then return end
    if not on() then
        st.finds = nil
        return
    end
    for key, f in pairs(finds) do
        if now >= f.untilAt or m.state ~= BR.MatchState.PLAYING then
            finds[key] = nil
            push(m, key, {}, 0)
        end
    end
end

T.FUNCTIONS.key_finder = {
    -- NOTHING TO MARK IS REFUSED, SPENDING NOTHING: no loose key, or nobody
    -- outside the squad holding one, for the chosen target -- or, while the
    -- terminal is only being listed, for either.
    refuse = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        return nothing(m, key, opts and opts.target or nil)
    end,
    -- WHERE THE KEYS ARE NOW, on the squad's maps for two minutes.
    run = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Key finder ran on the dev terminal '
                    .. 'with no match to search'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local target = opts and opts.target or 'ground'
        local why = nothing(m, key, target)
        if why then return { ok = false, code = why } end
        local found = target == 'holders' and holders(m, key) or groundKeys(m)
        local list = {}
        for _, p in ipairs(found) do list[#list + 1] = { x = p.x, y = p.y } end
        local ms = tonumber(fx().keyFinderMs) or 120000
        local now = GetGameTimer()
        local st = T.fxOf(m)
        st.finds = st.finds or {}
        -- The holders it marked, for their persistent notice (round 4).
        local marked = {}
        if target == 'holders' then
            for _, p in ipairs(found) do marked[#marked + 1] = p.s end
        end
        st.finds[key] = { list = list, untilAt = now + ms, holders = marked }
        push(m, key, list, ms)
        print(('[br_core] terminals: Key finder (%s) for %s: %d key(s) marked for %.0f s')
            :format(target, key, #list, ms / 1000))
        -- THE HOLDERS IT MARKED ARE WARNED, after "has redeemed their special
        -- power: Key finder..." -- each in their own match's words.
        local after = nil
        if target == 'holders' then
            after = function()
                for _, p in ipairs(found) do
                    local squadMatch = T.squadMatch(p.s) == true
                    BR.Server.notify(p.s, TS.pick(copy(), 'key_finder_warned', squadMatch), 'warn',
                        { ms = 8000 })
                end
            end
        end
        return { ok = true, code = 'done', after = after }
    end,
}

-- THE TWO MINUTES, ON THE SERVER: once a second, any marks whose time is up
-- (or whose match is over) are taken down with one empty list.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().endCheckMs or 1000, 'terminal.keyfinder', function()
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.terminalFx.finds then T.expireKeyFinds(m, now) end
        end)
    end)
end

-- A client that restarts while its squad's marks are up is sent them again,
-- with the time they have left.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() then return end
    local m, _, key = T.whereIs(src)
    local f = m and m.terminalFx and m.terminalFx.finds and m.terminalFx.finds[key] or nil
    local left = f and (f.untilAt - GetGameTimer()) or 0
    if f and left > 0 and m.state == BR.MatchState.PLAYING then
        TriggerClientEvent(BR.Net.TERMINAL_KEYS, src, { matchId = m.id, list = f.list, leftMs = left })
    end
end)

-- THE PERSISTENT NOTICE (round 4): every holder Key finder marked, for the
-- two minutes another squad can see where they were standing. Keys on the
-- ground mark nobody.
T.impactSource(function(m, now, add)
    local finds = m.terminalFx and m.terminalFx.finds or nil
    if not finds then return end
    for _, f in pairs(finds) do
        if now < f.untilAt then
            for _, s in ipairs(f.holders or {}) do add(s, 'impact_key_finder', f.untilAt) end
        end
    end
end)

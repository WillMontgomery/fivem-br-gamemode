-- Season 2 terminals (#396), server half: WHAT THE BUILT FUNCTIONS DO.
--
-- server/terminal.lua is the door -- the session, the key, the squad's one
-- use, the options, the lobby's notices. This file is what happens after the
-- door has said yes: the server halves of the functions whose effects are
-- built, registered into BR.Terminal.FUNCTIONS (the contract is that file's
-- header and docs/terminals.md), and the pushes that keep them on screen.
--
--   Scan          the scanning squad sees every opponent, for the rest of the
--                 match, and the player who ran it gets a bounty
--   the bounty    the owner's spec, below
--   Supply drop   one extra airdrop near this terminal or the next circle,
--                 by the airdrop's own rules (BR.Airdrop.call)
--   Max ammo      every gun the squad carries filled to its cap
--                 (BR.Inv.fillAmmo)
--
-- Storm reveal is the door's own (it predates this file).
--
-- ═══ THE BOUNTY, THE OWNER'S SPEC (#396, 2026-10-04, verbatim) ═══
--
--   * Toast to everyone: "A new bounty is among us: **{playername}**."
--   * The bounty owner is visible on EVERYONE's map: blip 58, color 3.
--   * Toast to their squad: "Protect **{playername}**! They've got a bounty
--     for the next 10 minutes."
--   * Duration: 10 minutes.
--   * Squad panel: shows the bounty.
--   * Teammates' map: the bounty owner shows as blip 58, color 69.
--
-- ENDED EARLY BY ELIMINATION. A bounty on a player who is out (or gone, or in
-- a match that ended) is no bounty: there is nobody left to find. The owner
-- has not ruled on a reward for the kill (proposed on the issue: Volts); this
-- file pays nothing.
--
-- ═══ WHO IS SENT WHAT ═══
--
-- Positions are the roster's own 4 Hz samples -- the same ones the loot claim
-- and the airdrop gate are measured against -- and they go only where the
-- spec sends them:
--
--   TERMINAL_SCAN    the scanning squad, every scanPingMs: each opponent's
--                    position. Nobody else.
--   TERMINAL_BOUNTY  everyone in the match OUTSIDE the bounty's squad, every
--                    bountyPingMs while one is live, and once more, empty,
--                    when the last one ends. The bounty's squad already sees
--                    them on the squad beacon (server/party.lua), which now
--                    carries `bounty` so their map and panel can say so.
--
-- AND NEITHER PUTS A SQUAD UNDER GHOST ON ANYBODY'S MAP (wave A): its members
-- drop out of every Scan list and its bounty out of every bounty list until
-- Ghost ends -- `hidden` below, the one predicate Pulse asks too.
--
-- SEASON 2 ONLY, by construction: nothing here runs until a terminal function
-- has, and every job asks the season too.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function cfg() return BR.Config.Terminals end
local function copy() return BR.Config.Terminals.copy end
local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- Where a player's position may be read from for a mark: in the fight and
--- on the ground or in the air. Not the bus (its riders are one moving dot)
--- and not the out.
local MARKED = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO] = true,
    [BR.PlayerState.FREEFALL] = true,
    [BR.PlayerState.GLIDE] = true,
}

--- This match's effects, made on first use and gone with the match.
---   scans     [squadKey] = { by, at }: that squad sees every opponent
---   bounties  [src] = { src, name, squad, untilAt }
---   shown     true while a bounty list has been sent and not yet cleared
--- @param m table
--- @return table
local function fxOf(m)
    local s = m.terminalFx
    if not s then
        s = { scans = {}, bounties = {}, shown = false }
        m.terminalFx = s
    end
    return s
end

--- A copy line with {playername} filled, as a toast, through the one picker
--- (BR.TerminalSolve.pick: "squad" only in a squad match, owner round 2).
local function named(key, name, squadMatch)
    return TS.line(TS.pick(copy(), key, squadMatch), name)
end

-- ═══ THE SHARED HELPERS (wave A, 2026-10-06) ═══
--
-- Each function built after these four has its own file under
-- server/terminalfx/ (one per function, beside each other); these are what
-- they share with this file, so there is one spelling of each:
--
--   T.fxOf(m)          this match's effects record, made on first use and gone
--                      with the match -- every function keeps its state on it,
--                      so nothing outlives the match it was run in
--   T.marked(state)    in the fight with a position worth marking: standing,
--                      downed or in the air (MARKED above)
--   T.namedLine(key, name, squadMatch)
--                      a toast line with {playername}, through the picker
--   T.anchorOf(src, session)
--                      where "this terminal" is: the session's terminal, or,
--                      for a terminal the server does not know (the dev
--                      terminal), the player -- Supply drop's rule
T.fxOf = fxOf
T.namedLine = named
--- @param state string|nil
--- @return boolean
function T.marked(state)
    return MARKED[state] == true
end

--- Where a function that works "around this terminal" is centered.
--- @param src integer
--- @param session table
--- @return number|nil x, number|nil y, table|nil site  the site, when it is one
function T.anchorOf(src, session)
    local t = T.site(session.terminalId)
    if t then return t.x, t.y, t end
    local e = BR.Roster and BR.Roster.get(src) or nil
    if e and e.pos then return e.pos.x, e.pos.y, nil end
    return nil, nil, nil
end

--- IS SQUAD `key` HIDDEN FROM OTHER SQUADS' MARKS RIGHT NOW? Ghost's
--- predicate (server/terminalfx/ghost.lua, BR.Terminal.hidden), the ONE
--- question Scan's push, the bounty's push and Pulse all ask before they put
--- anybody on another squad's map. No squad is while Ghost is not loaded.
--- @param m table
--- @param key string
--- @param now number
--- @return boolean
local function hidden(m, key, now)
    return T.hidden ~= nil and T.hidden(m, key, now) == true
end

-- ------------------------------------------------------------------ Scan ---

--- Start a squad's scan in this match: from now to the end of the match.
--- @param m table
--- @param key string  the squad (BR.TerminalSolve.squadKey)
--- @param by integer  who ran it
--- @param now number
function T.startScan(m, key, by, now)
    fxOf(m).scans[key] = { by = by, at = now }
    T.pushScans(m)
end

--- Every opponent of `key` this match has a position for -- but a squad
--- under Ghost.
--- @return table[] { { s, x, y, down } }
local function opponentsOf(m, key, now)
    local out = {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        local theirs = TS.squadKey(e, src)
        if MARKED[e.state] and e.pos and theirs ~= key and not hidden(m, theirs, now) then
            out[#out + 1] = { s = src, x = e.pos.x + 0.0, y = e.pos.y + 0.0,
                              down = e.state == BR.PlayerState.DBNO or nil }
        end
    end)
    table.sort(out, function(a, b) return a.s < b.s end)
    return out
end

--- Send every scanning squad in this match where its opponents are. The
--- squad's dead and spectating members included: "for the whole squad".
--- @param m table
function T.pushScans(m)
    local st = m.terminalFx
    if not st or next(st.scans) == nil then return end
    local now = GetGameTimer()
    for key in pairs(st.scans) do
        local payload = { matchId = m.id, list = opponentsOf(m, key, now) }
        for _, src in ipairs(T.squadOf(m, key)) do
            TriggerClientEvent(BR.Net.TERMINAL_SCAN, src, payload)
        end
    end
end

-- ------------------------------------------------------------ the bounty ---

--- Is this bounty still live? Its clock, its player still in this match and
--- still in the fight, and the match still being played.
local function live(m, b, now)
    if now >= b.untilAt then return false end
    if m.state ~= BR.MatchState.PLAYING then return false end
    local e = BR.Roster.get(b.src)
    if not e or e.matchId ~= m.id then return false end
    return e.state == BR.PlayerState.ALIVE or e.state == BR.PlayerState.DBNO
        or e.state == BR.PlayerState.FREEFALL or e.state == BR.PlayerState.GLIDE
end

--- The live bounties in this match, oldest first, each with its time left.
--- Read by the terminal's match panel (BR.Terminal.matchInfo).
--- @param m table
--- @param now number
--- @return table[] { { src, name, squad, leftMs } }
function T.bountiesOf(m, now)
    local out = {}
    local st = m and m.terminalFx
    if not st then return out end
    for _, b in pairs(st.bounties) do
        if live(m, b, now) then
            out[#out + 1] = { src = b.src, name = b.name, squad = b.squad,
                              leftMs = b.untilAt - now, since = b.since }
        end
    end
    table.sort(out, function(a, b) return a.since < b.since or (a.since == b.since and a.src < b.src) end)
    return out
end

--- Does this player carry a live bounty? Read by the squad beacon.
--- @param src integer
--- @return boolean
function T.hasBounty(src)
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    local b = m and m.terminalFx and m.terminalFx.bounties[src] or nil
    return b ~= nil and live(m, b, GetGameTimer())
end

--- Put a bounty on `src`, and tell the match: everyone, then their squad.
--- A second bounty on the same player restarts their clock -- and never
--- shortens one still running (a Contract's 5 minutes on a Scan bounty with 8
--- left keeps the 8).
---
--- A CONTRACT (wave A, server/terminalfx/contract.lua) IS THIS BOUNTY with its
--- own clock and its own words: `opts.ms`, and `opts.protect` in place of the
--- owner's `bounty_protect` -- whose "for the next 10 minutes" is Scan's ten
--- and must never be said about five -- plus `opts.target`, a line to the
--- target themselves. The owner's `bounty_new` to the lobby, blip 58 and his
--- colors are the same for both.
--- @param m table
--- @param src integer
--- @param now number
--- @param opts table|nil  { ms, protect, target } for a Contract; nil is Scan's
function T.startBounty(m, src, now, opts)
    local e = BR.Roster.get(src)
    if not e then return end
    -- A BOUNTY ON A PLAYER ALREADY OUT IS NO BOUNTY ("ENDED EARLY BY
    -- ELIMINATION", above). Reachable since round 2: a run is carried out
    -- 3 to 5 seconds after it is accepted, and its runner can be eliminated
    -- in between -- the squad still gets its Scan, and nobody is told of a
    -- bounty that would end on the next push.
    if not MARKED[e.state] then return end
    local key = TS.squadKey(e, src)
    local squadMatch = T.squadMatch ~= nil and T.squadMatch(src) == true
    local ms = (opts and tonumber(opts.ms)) or fx().bountyMs or 600000
    local untilAt = now + ms
    local was = fxOf(m).bounties[src]
    if was and live(m, was, now) and was.untilAt > untilAt then untilAt = was.untilAt end
    fxOf(m).bounties[src] = { src = src, name = e.name, squad = key, since = now,
                              untilAt = untilAt }
    BR.Server.notify(T.lobbyOf(m), named('bounty_new', e.name, squadMatch), 'info', { ms = 8000 })
    -- THE OWNER'S SQUAD-ONLY TOAST, ONLY TO SQUADMATES: never sent to a player
    -- with none (a solo player, or the last of a squad).
    local mates = {}
    for _, s in ipairs(T.squadOf(m, key)) do
        if s ~= src then mates[#mates + 1] = s end
    end
    if #mates > 0 then
        BR.Server.notify(mates, named((opts and opts.protect) or 'bounty_protect', e.name, squadMatch),
            'info', { ms = 8000 })
    end
    if opts and opts.target then
        BR.Server.notify(src, named(opts.target, e.name, squadMatch), 'warn', { ms = 8000 })
    end
    print(('[br_core] terminals: %s (%d) has a bounty for %.0f s in match %s')
        :format(e.name or '?', src, (untilAt - now) / 1000, tostring(m.id)))
    T.pushBounties(m, now)
end

--- Send everyone outside each bounty's squad where it is, and drop the ones
--- that have ended. Once the last has ended, one empty list clears every map.
--- @param m table
--- @param now number
function T.pushBounties(m, now)
    local st = m.terminalFx
    if not st then return end
    for src, b in pairs(st.bounties) do
        if not live(m, b, now) then st.bounties[src] = nil end
    end
    -- A BOUNTY ON A SQUAD UNDER GHOST IS ON NOBODY'S MAP (its own squad's
    -- beacon still carries it), and the match panel still lists it.
    local active = {}
    for _, b in ipairs(T.bountiesOf(m, now)) do
        if not hidden(m, b.squad, now) then active[#active + 1] = b end
    end
    if #active == 0 then
        if st.shown then
            st.shown = false
            BR.Broadcast.toMatch(m, BR.Net.TERMINAL_BOUNTY, { matchId = m.id, list = {} })
        end
        return
    end
    st.shown = true
    for _, to in ipairs(T.lobbyOf(m)) do
        local te = BR.Roster.get(to)
        local mine = te and TS.squadKey(te, to) or nil
        local list = {}
        for _, b in ipairs(active) do
            local e = BR.Roster.get(b.src)
            -- NOT TO THE BOUNTY'S OWN SQUAD: their beacon already carries it,
            -- and their map draws it in colour 69 (client/squadmates.lua).
            if b.squad ~= mine and e and e.pos then
                list[#list + 1] = { s = b.src, x = e.pos.x + 0.0, y = e.pos.y + 0.0 }
            end
        end
        TriggerClientEvent(BR.Net.TERMINAL_BOUNTY, to, { matchId = m.id, list = list })
    end
end

-- ------------------------------------------------------- the functions ---

T.FUNCTIONS.scan = {
    -- THE SQUAD SEES EVERY OPPONENT FOR THE REST OF THE MATCH, and the runner
    -- gets the bounty -- after the lobby has read "has redeemed their special
    -- power", so the two toasts arrive in the order they make sense in.
    run = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Scan ran on the dev terminal '
                    .. 'with no match to scan'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local now = GetGameTimer()
        T.startScan(m, key, src, now)
        return { ok = true, code = 'done', after = function() T.startBounty(m, src, now) end }
    end,
}

-- ----------------------------------------------------------- Supply drop ---

--- Where a Supply drop aims for one choice of `site`: this terminal, or the
--- centre of the circle the storm is closing toward. A terminal the server
--- does not know (the dev terminal) aims at the player.
--- @return number|nil x, number|nil y
local function dropAim(src, session, site, m)
    if site == 'circle' then
        local rec = m.storm
        if not rec then return nil, nil end
        return rec.cx1, rec.cy1
    end
    local x, y = T.anchorOf(src, session)
    return x, y
end

--- Why Supply drop cannot run for this choice (nil: any choice), or nil.
local function dropRefusal(src, session, m, site)
    if not m.storm then return 'no_storm' end
    if BR.Airdrop.busy(m) then return 'drop_busy' end
    for _, choice in ipairs(site and { site } or { 'terminal', 'circle' }) do
        local x, y = dropAim(src, session, choice, m)
        if x and BR.Airdrop.candidate(m, x, y) then return nil end
    end
    return 'no_site'
end

T.FUNCTIONS.supply_drop = {
    -- Refused, spending nothing, before the storm, while another drop is out,
    -- and when no airdrop spot fits the next circle for the chosen site (any
    -- site, while the terminal is only being listed).
    refuse = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        return dropRefusal(src, session, m, opts and opts.site or nil)
    end,
    -- ONE EXTRA AIRDROP, through BR.Airdrop.call: sited by the airdrop's own
    -- rules near the chosen point, announced to the match like any drop, and
    -- an ordinary drop from then on.
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Supply drop ran on the dev terminal '
                    .. 'with no match to drop into'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        if not m.storm then return { ok = false, code = 'no_storm' } end
        local x, y = dropAim(src, session, opts.site, m)
        if not x then return { ok = false, code = 'no_site' } end
        local rec, why = BR.Airdrop.call(m, x, y)
        if not rec then
            return { ok = false, code = why == 'busy' and 'drop_busy' or 'no_site' }
        end
        return { ok = true, code = 'done' }
    end,
}

-- -------------------------------------------------------------- Max ammo ---

--- The squad members Max ammo fills: everyone in the squad still in the fight
--- -- standing, downed, or still in the air.
local function fillable(m, key)
    local out = {}
    for _, s in ipairs(T.squadOf(m, key)) do
        local e = BR.Roster.get(s)
        if e and MARKED[e.state] then out[#out + 1] = s end
    end
    return out
end

T.FUNCTIONS.max_ammo = {
    -- Nothing to fill is refused, spending nothing: a key is not spent on a
    -- squad whose every gun is already full (or who carry none).
    refuse = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        for _, s in ipairs(fillable(m, key)) do
            if BR.Inv.ammoRoom(s) > 0 then return nil end
        end
        return 'ammo_full'
    end,
    -- EVERY POOL A CARRIED GUN DRAWS ON, TO ITS CAP, for everyone in the squad
    -- still in the fight (BR.Inv.fillAmmo: through the inventory's own clamp
    -- and reload, one INV_SET each).
    run = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Max ammo ran on the dev terminal '
                    .. 'with no squad to fill'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local rounds, players = 0, 0
        for _, s in ipairs(fillable(m, key)) do
            local n = BR.Inv.fillAmmo(s)
            if n > 0 then
                rounds, players = rounds + n, players + 1
            end
        end
        if rounds <= 0 then return { ok = false, code = 'ammo_full' } end
        print(('[br_core] terminals: Max ammo for %s: %d round(s) to %d player(s)')
            :format(key, rounds, players))
        return { ok = true, code = 'done' }
    end,
}

-- --------------------------------------------------------------- the jobs ---

if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().scanPingMs or 2000, 'terminal.scan', function()
        if not on() then return end
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.state == BR.MatchState.PLAYING then T.pushScans(m) end
        end)
    end)
    BR.Sched.every(fx().bountyPingMs or 1000, 'terminal.bounty', function()
        if not on() then return end
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx then T.pushBounties(m, now) end
        end)
    end)
end

-- A client that restarts mid-match is sent the scan and the bounty again by
-- the next push; nothing to replay on br:ready.

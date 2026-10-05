-- Season 2 terminals (#396), server half: THE DOOR EVERY USE AND EVERY RUN
-- GOES THROUGH.
--
-- The whole contract, with cuchi_computer's half and the app's, is
-- docs/terminals.md. This file holds:
--
--   the terminals    the config's sites plus the dev tool's, each online only
--                    while it stands inside the storm's current safe zone
--   the session      opened by TERMINAL_USE when a living player holds
--                    interact beside a live terminal (or by the dev command
--                    `brterminalsv open`, with typed facts, for the app alone)
--   the rules        a key, the squad's ONE use this match, a live terminal --
--                    read from the world on every ask, never from the client
--   the notices      the lobby hears when someone gains access, and again when
--                    a function is picked and runs
--   the registry     BR.Config.Terminals.functions, every row listed; the
--                    built ones' server halves in BR.Terminal.FUNCTIONS, with
--                    Storm reveal end to end here and Scan, Supply drop and
--                    Max ammo in server/terminalfx.lua
--   the options      what the player chose before Run, taken only as the
--                    registry allows (BR.Terminal.options)
--   the panel        the match as the open computer shows it, pushed to that
--                    player alone about once a second while it is open
--   the dev tools    `brterminalsv`, typed through `brterminal` and `bryubikey`
--
-- ═══ THE OWNER'S RULES, 2026-10-04 ═══
--
--   * "Let's say all computers always work, except when they are outside the
--     storm."
--   * "Only one yubikey use per squad per match. If there are more equipped,
--     they're prevented from using them." A solo player is a squad of one.
--   * "notify others when they've gained access to the system, then once more
--     when the action is selected and activated" -- "so they don't think the
--     server's been hacked".
--   * Storm reveal: "see where the storm is going to end for that match, and
--     the ability is shared amongst their squad".
--
-- ═══ THE SERVER DECIDES EVERYTHING ═══
--
-- The computer and its app only ask. A session is opened here and nowhere
-- else, against this server's own position sample; a run is taken only inside
-- it; every refusal is read from the world at the moment of asking; and a
-- client never says it is at a terminal, holds a key, or names a terminal it
-- was not opened on.
--
-- ═══ NO DECISION HERE READS DEV MODE ═══
--
-- tools/check_net_gates.lua: a net event may not refuse on dev mode, because
-- every client passes that on a dev box. The dev door is the command, behind
-- br_lib/shared/devgate.lua's wrap like every other; a dev session's run is
-- authorized by the session that command opened, as client/props.lua's edit
-- stream is by its edit session.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function cfg() return BR.Config.Terminals end
local function copy() return BR.Config.Terminals.copy end

local function on()
    return BR.Season ~= nil and BR.Season.has('terminals') == true
end

-- The shape of the function id (br_lib/config/terminals.lua).
local FUNCTION_ID = '^[a-z][a-z0-9_]*$'
local FUNCTION_ID_MAX = 32

--- How far a session's player may be above or below the terminal, in metres.
--- Generous: a laptop on a desk and a player on the floor beside it are a
--- metre apart, and the sampled position is the ped's root.
local REACH_Z = 4.0

--- [src] = { terminalId, dev, facts (dev only), matchId (real only) }
local sessions = {}

--- [src] = GetGameTimer() of the last run request taken
local lastRunAt = {}

--- [src] = GetGameTimer() of the last use request taken
local lastUseAt = {}

--- The most options one run may carry. The registry's longest list is three;
--- anything past this is not the app.
local OPTIONS_MAX = 8

-- ------------------------------------------------------------ the sites ---

--- The dev tools' changes, this server session only: printed for pasting into
--- the config, never written anywhere.
---   placed   [id] = site, and placedOrder the ids in the order placed
---   removed  [id] = true: a config row taken out of play
---   forced   [id] = true: online whatever the storm says
local placed, placedOrder, removed, forced = {}, {}, {}, {}
local devSeq = 0

--- The config's rows, checked once (BR.TerminalSolve.sites) and said aloud
--- when one is skipped.
local configSites = nil
local function fromConfig()
    if configSites then return configSites end
    local why
    configSites, why = TS.sites(cfg().sites)
    for _, w in ipairs(why) do
        print(('^3[br_core] terminals: br_lib/config/terminals.lua sites %s -- skipped^7'):format(w))
    end
    return configSites
end

--- Every terminal in play, config rows first, then the dev tool's.
--- @return table[]
function T.sites()
    local out = {}
    for _, s in ipairs(fromConfig()) do
        if not removed[s.id] and not placed[s.id] then out[#out + 1] = s end
    end
    for _, id in ipairs(placedOrder) do
        if placed[id] then out[#out + 1] = placed[id] end
    end
    return out
end

--- @param id string
--- @return table|nil
function T.site(id)
    if type(id) ~= 'string' then return nil end
    if placed[id] then return placed[id] end
    if removed[id] then return nil end
    for _, s in ipairs(fromConfig()) do
        if s.id == id then return s end
    end
    return nil
end

--- The dev tools' changes, as TERMINAL_SITES carries them.
local function sitesPayload()
    local p, r, f = {}, {}, {}
    for _, id in ipairs(placedOrder) do
        if placed[id] then p[#p + 1] = placed[id] end
    end
    for id in pairs(removed) do r[#r + 1] = id end
    for id in pairs(forced) do f[#f + 1] = id end
    table.sort(r)
    table.sort(f)
    return { placed = p, removed = r, forced = f }
end

local function sendSites(target)
    TriggerClientEvent(BR.Net.TERMINAL_SITES, target, sitesPayload())
end

--- Is this terminal online -- inside the match's storm, as it stands now?
--- A terminal forced online by the dev tool always is.
--- @param site table|nil
--- @param m table|nil
--- @param now number
--- @return boolean
function T.online(site, m, now)
    if not site then return false end
    if forced[site.id] then return true end
    local rec = m and m.storm or nil
    return TS.inside(TS.zoneAt(rec, now), site.x, site.y)
end

--- Is this player, by the server's own position sample, at this terminal?
--- @param e table  roster entry
--- @param site table
--- @return boolean
local function inReach(e, site)
    local p = e and e.pos
    if not p or not site then return false end
    local reach = (cfg().useDistanceM or 2.5) + (cfg().useSlackM or 2.0)
    local dx, dy = p.x - site.x, p.y - site.y
    if dx * dx + dy * dy > reach * reach then return false end
    return math.abs((p.z or site.z) - site.z) <= REACH_Z
end

-- ------------------------------------------------------- the match's use ---

--- This match's terminal record, made on first use and gone with the match.
---   used     [squadKey] = { by, fn, at }: the squad's one use is spent
---   access   [src] = true: this player's access has been announced
---   reveals  [squadKey] = { x, y, r }: what Storm reveal showed them
--- @param m table
--- @return table
local function matchState(m)
    local s = m.terminals
    if not s then
        s = { used = {}, access = {}, reveals = {} }
        m.terminals = s
    end
    return s
end

--- @param src integer
--- @return table|nil m, table|nil entry, string|nil squadKey
local function whereIs(src)
    local e = BR.Roster and BR.Roster.get(src)
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    if not e or not m then return nil, e, nil end
    return m, e, TS.squadKey(e, src)
end

--- Has this player's squad spent its one use in the match they are in?
--- @param src integer
--- @return boolean
function T.squadUsed(src)
    local m, _, key = whereIs(src)
    return m ~= nil and m.terminals ~= nil and m.terminals.used[key] ~= nil
end

--- Everyone in this match, the dead and the spectating included.
--- @param m table
--- @return integer[]
local function lobbyOf(m)
    local out = {}
    BR.Roster.each(function(e) return e.matchId == m.id end,
        function(src) out[#out + 1] = src end)
    table.sort(out)
    return out
end

--- This squad's members in this match, by the same key the use is spent under.
--- @param m table
--- @param key string
--- @return integer[]
local function squadOf(m, key)
    local out = {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if TS.squadKey(e, src) == key then out[#out + 1] = src end
    end)
    table.sort(out)
    return out
end

-- The effects in server/terminalfx.lua address the same audiences.
T.lobbyOf = lobbyOf
T.squadOf = squadOf
T.whereIs = whereIs

local function pushKeys(list)
    if not (BR.Yubikey and BR.Yubikey.push) then return end
    for _, s in ipairs(list) do BR.Yubikey.push(s) end
end

--- "So they don't think the server's been hacked": the lobby's two notices.
local function tellLobby(m, line)
    BR.Server.notify(lobbyOf(m), line, 'info', { ms = 8000 })
end

-- --------------------------------------------------------- the registry ---

--- The server half of the function registry: one entry per BUILT id in
--- BR.Config.Terminals.functions (`implemented = true`).
---
---   refuse(src, session, opts) -> reason|nil   optional: a reason of its own,
---                                              asked after the shared ones;
---                                              `opts` is nil when the terminal
---                                              is only being listed (answer
---                                              for any choice)
---   run(src, session, opts) -> { ok, code, after? }
---                                              what running it does; `code` is
---                                              'done' when it ran, and
---                                              `after`, when given, is called
---                                              once the lobby has heard
---                                              notice_action
---
--- `opts` is what BR.Terminal.options made of the player's choices: every
--- option the row declares, each a listed choice, defaults filled.
---
--- EVERY ROW IS LISTED, BUILT OR NOT. The owner asked for a card and a page per
--- function, so a row whose effect is not built yet is shown with the reason
--- `fn_offline` and its run is refused before anything else is asked. A row
--- marked implemented with no entry here is the same (and test_terminal.lua
--- fails it).
T.FUNCTIONS = {}

--- The registry row for an id, or nil.
--- @param id string
--- @return table|nil
local function rowOf(id)
    for _, row in ipairs(cfg().functions) do
        if row.id == id then return row end
    end
    return nil
end
T.row = rowOf

--- Is this row's effect built and its server half here?
--- @param row table
--- @return boolean
local function built(row)
    return row.implemented == true and T.FUNCTIONS[row.id] ~= nil
end

--- The player's choices for a run, as the registry allows them, or nil.
---
--- NEVER TRUSTS THE APP. The app only offers the registry's choices, but a run
--- request is a client's word: every key must be an option this row declares,
--- every value a string from that option's own `choices`, and there are at
--- most OPTIONS_MAX of them. Anything else is the whole request refused --
--- never a half-understood one run with the parts that parsed. A missing
--- option takes its `default`, so a row whose options the player never
--- touched runs exactly as its page said it would.
--- @param row table
--- @param given any  the request's `options`: nil, or a table of strings
--- @return table|nil opts
function T.options(row, given)
    local out = {}
    local declared = {}
    for _, o in ipairs(row.options or {}) do
        declared[o.id] = o
        out[o.id] = o.default
    end
    if given == nil then return out end
    if type(given) ~= 'table' then return nil end
    local n = 0
    for k, v in pairs(given) do
        n = n + 1
        if n > OPTIONS_MAX then return nil end
        local o = type(k) == 'string' and declared[k] or nil
        if not o or type(v) ~= 'string' then return nil end
        local listed = false
        for _, c in ipairs(o.choices or {}) do
            if c == v then
                listed = true
                break
            end
        end
        if not listed then return nil end
        out[k] = v
    end
    return out
end

--- Show a squad where this match's storm ends, from now to the end of the match.
--- @param m table
--- @param key string  the squad
--- @param f table     BR.Storm.finalCentre's answer
function T.reveal(m, key, f)
    local s = matchState(m)
    s.reveals[key] = { x = f.x, y = f.y, r = f.r }
    for _, src in ipairs(squadOf(m, key)) do
        TriggerClientEvent(BR.Net.TERMINAL_REVEAL, src,
            { x = f.x, y = f.y, r = f.r, matchId = m.id })
    end
end

--- Where this player's match ends, or nil when it has no storm stream.
local function finalFor(src)
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    local f = m and BR.Storm and BR.Storm.finalCentre and BR.Storm.finalCentre(m) or nil
    return f, m
end

T.FUNCTIONS.storm_reveal = {
    -- Nothing to reveal outside a match whose circle 1 is drawn. A dev session
    -- (typed facts, for walking the app) is never refused for it.
    refuse = function(src, session)
        if session.dev then return nil end
        if finalFor(src) == nil then return 'no_storm' end
        return nil
    end,
    -- THE SQUAD SEES WHERE THE STORM ENDS (BR.Storm.finalCentre), and nobody
    -- else: TERMINAL_REVEAL goes to the squad that ran it, and BR.Net.READY
    -- sends it again to a member whose client restarts.
    run = function(src, session)
        local f, m = finalFor(src)
        if not f then
            if session.dev then
                -- THE SHELL'S ROUND TRIP: a dev terminal outside a match has
                -- nothing to reveal and answers as if it had.
                print(('[br_core] brterminal (client %d): Storm reveal ran on the dev terminal '
                    .. 'with no match to reveal'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'no_storm' }
        end
        local _, e = whereIs(src)
        T.reveal(m, TS.squadKey(e, src), f)
        print(('[br_core] terminals: %s (%d) revealed the end of match %s: (%.0f, %.0f)')
            :format(e and e.name or '?', src, tostring(m.id), f.x, f.y))
        return { ok = true, code = 'done' }
    end,
}

-- --------------------------------------------------------- the facts ---

--- What the server knows about this player at this terminal.
---
--- A REAL SESSION READS THE WORLD on every ask: the key on the player's
--- profile, the squad's use this match, the terminal against the storm as it
--- stands now. A DEV session reads the facts `brterminalsv open` was typed with.
--- @return table { keyHeld: boolean, squadUsed: boolean, offline: boolean }
function T.facts(src, session)
    if session.dev then return session.facts end
    local m = BR.Server.matchOf(src)
    return {
        keyHeld = BR.Yubikey ~= nil and BR.Yubikey.holds(src),
        squadUsed = T.squadUsed(src),
        offline = not (m ~= nil and m.id == session.matchId
            and T.online(T.site(session.terminalId), m, GetGameTimer())),
    }
end

--- Spend the key and the squad's one use, after a run that happened.
--- A DEV session spends its typed facts and touches nothing real.
function T.consume(src, session, functionId)
    if session.dev then
        session.facts.keyHeld = false
        session.facts.squadUsed = true
        return
    end
    local m, _, key = whereIs(src)
    if BR.Yubikey then BR.Yubikey.take(src, 'used') end
    if m then
        matchState(m).used[key] = { by = src, fn = functionId, at = GetGameTimer() }
        -- The squad's other holders: their plates turn to squad_used now.
        pushKeys(squadOf(m, key))
    end
end

--- Why the function on `row` cannot run now, as a reason code (a key into the
--- copy), or nil. The order is the order a player would want to hear them in:
--- a function that is not built yet first (nothing else about it matters),
--- then a dead terminal, then the squad, then their own key, then the
--- function's own reason for these options.
--- @param opts table|nil  nil when listing: a function's own refusal is then
---                        asked whether ANY of its choices could run, so a
---                        card says "not here" only when none could
local function refusal(src, session, row, opts)
    if not built(row) then return 'fn_offline' end
    local f = T.facts(src, session)
    if f.offline then return 'offline' end
    if f.squadUsed then return 'squad_used' end
    if not f.keyHeld then return 'no_key' end
    local fn = T.FUNCTIONS[row.id]
    if fn.refuse then return fn.refuse(src, session, opts) end
    return nil
end

-- ------------------------------------------------------------- the panel ---

--- Still in the fight, for the panel's counts: BR.Server.isInMatch's answer,
--- the same one the HUD's ALIVE counter reads.
local function inFight(state)
    if BR.Server and BR.Server.isInMatch then return BR.Server.isInMatch(state) == true end
    return state == BR.PlayerState.ALIVE or state == BR.PlayerState.DBNO
end

--- A squadmate's line on the panel: 'alive', 'downed' or 'out'.
local function mateState(state)
    if state == BR.PlayerState.DBNO then return 'downed' end
    if inFight(state) then return 'alive' end
    return 'out'
end

--- The match as the open computer shows it (#396, 2026-10-05: "a details table
--- which shows realtime match info"), or nil outside a match.
---
--- EVERY FIELD IS WHAT THIS PLAYER MAY ALREADY KNOW: the match's own tag and
--- clock, the storm everyone sees, the counts the HUD already shows, their own
--- squad (the squad panel's), their own key, how many terminals are live (a
--- key holder's map shows them), and the bounties the lobby was told about.
--- Nothing about another squad's members or keys crosses here.
--- @param src integer
--- @param now number
--- @return table|nil
function T.matchInfo(src, now)
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    if not m then return nil end
    local info = {
        tag = BR.MatchTag and BR.MatchTag(m.id) or tostring(m.id),
        mode = m.mode,
        phase = m.state,
        elapsedMs = m.startedAt and math.max(0, now - m.startedAt) or nil,
    }

    local rec = m.storm
    if rec and BR.StormAt then
        local _, _, _, st, left = BR.StormAt(rec, now)
        local phases = BR.Config.Storm and BR.Config.Storm.phases
        info.storm = { stage = rec.phase, stages = phases and #phases or nil,
                       state = st, leftMs = math.max(0, math.floor(left or 0)) }
    end

    local _, _, mine = whereIs(src)
    local players, squads, seen, squad = 0, 0, {}, {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(s, e)
        local key = TS.squadKey(e, s)
        if inFight(e.state) then
            players = players + 1
            if not seen[key] then
                seen[key] = true
                squads = squads + 1
            end
        end
        if key == mine then
            squad[#squad + 1] = { src = s, name = e.name, state = mateState(e.state),
                                  me = s == src or nil }
        end
    end)
    table.sort(squad, function(a, b) return a.src < b.src end)
    for _, row in ipairs(squad) do row.src = nil end
    info.players, info.squads, info.squad = players, squads, squad

    local list = T.sites()
    local live = 0
    for _, s in ipairs(list) do
        if T.online(s, m, now) then live = live + 1 end
    end
    info.terminals = { online = live, total = #list }

    -- THE BOUNTIES THE LOBBY WAS TOLD ABOUT (server/terminalfx.lua): a name
    -- and a clock, the toast's own facts.
    if T.bountiesOf then
        local b = {}
        for _, row in ipairs(T.bountiesOf(m, now)) do
            b[#b + 1] = { name = row.name, leftMs = row.leftMs }
        end
        info.bounties = b
    end
    return info
end

--- The terminal as this player sees it: the payload the computer opens with,
--- and what TERMINAL_INFO pushes while it is open.
--- @return table { terminalId, functions = { { id, available, reason } },
---                 keyHeld, squadUsed, player, match }
function T.state(src, session)
    local f = T.facts(src, session)
    local list = {}
    for _, row in ipairs(cfg().functions) do
        local why = refusal(src, session, row, nil)
        list[#list + 1] = { id = row.id, available = why == nil, reason = why }
    end
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src) or nil
    return {
        terminalId = session.terminalId,
        functions = list,
        keyHeld = f.keyHeld == true,
        squadUsed = f.squadUsed == true,
        -- THE GAMERTAG, as the app's signed-in username: the roster's display
        -- name, which is what every toast and the kill feed already call them.
        player = (e and e.name) or GetPlayerName(src) or nil,
        match = T.matchInfo(src, GetGameTimer()),
    }
end

-- ------------------------------------------------------------ sessions ---

--- Open the computer for `src` on `terminalId`. A dev session takes `facts`;
--- a real one reads the world and remembers which match it was opened in.
--- @return table the session
function T.open(src, terminalId, facts, dev)
    local session
    if dev then
        session = {
            terminalId = terminalId,
            facts = {
                keyHeld = facts.keyHeld == true,
                squadUsed = facts.squadUsed == true,
                offline = facts.offline == true,
            },
            dev = true,
        }
    else
        local m = BR.Server.matchOf(src)
        session = { terminalId = terminalId, dev = false, matchId = m and m.id or nil }
    end
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

--- Is a real session's player still alive, in its match, at its terminal, and
--- is the terminal still live? Nil when so; otherwise why not.
--- @return string|nil
local function gone(src, session, now)
    if session.dev then return nil end
    local e = BR.Roster.get(src)
    if not e or e.state ~= BR.PlayerState.ALIVE then return 'state' end
    local m = BR.Server.matchOf(src)
    if not m or m.id ~= session.matchId or m.state ~= BR.MatchState.PLAYING then
        return 'match'
    end
    local site = T.site(session.terminalId)
    if not site then return 'site' end
    if not inReach(e, site) then return 'walked' end
    if not T.online(site, m, now) then return 'offline' end
    return nil
end

--- Close every real session whose player died, went down, left the match or
--- walked away, or whose terminal the storm took. Run on BR.Sched every
--- sessionCheckMs; public so the suites can step it.
--- @param now number
function T.checkSessions(now)
    local shut = {}
    for src, session in pairs(sessions) do
        local why = (not on() and 'season') or gone(src, session, now)
        if why then shut[#shut + 1] = { src = src, why = why } end
    end
    for _, s in ipairs(shut) do T.close(s.src, s.why) end
end

--- Every open computer its state again, the match panel included
--- (TERMINAL_INFO), each to its own player. Run on BR.Sched every infoPushMs;
--- public so the suites can step it. Off Season 2 it sends nothing: the
--- session check closes those computers.
function T.pushInfo()
    if not on() then return end
    for src, session in pairs(sessions) do
        TriggerClientEvent(BR.Net.TERMINAL_INFO, src,
            { terminalId = session.terminalId, state = T.state(src, session) })
    end
end

--- A player held interact at a terminal. Open it, or say why not.
--- @param src integer
--- @param terminalId string
--- @param now number
--- @return boolean ok, string|nil why  'state' | 'match' | 'site' | 'reach' | 'offline'
function T.use(src, terminalId, now)
    local e = BR.Roster.get(src)
    if not e or e.state ~= BR.PlayerState.ALIVE then return false, 'state' end
    local m = BR.Server.matchOf(src)
    if not m or m.state ~= BR.MatchState.PLAYING then return false, 'match' end
    local site = T.site(terminalId)
    if not site then return false, 'site' end
    if not inReach(e, site) then return false, 'reach' end
    if not T.online(site, m, now) then return false, 'offline' end

    T.open(src, site.id, nil, false)

    -- ACCESS GRANTED: a key, and a squad that has not spent its one use. The
    -- lobby hears it ONCE per player per match -- opening the same computer
    -- twice is not a second hack. Without a key the computer still opens (its
    -- app lists every function unavailable, no_key), and nobody is told.
    if BR.Yubikey and BR.Yubikey.holds(src) and not T.squadUsed(src) then
        local s = matchState(m)
        if not s.access[src] then
            s.access[src] = true
            tellLobby(m, TS.line(copy().notice_access, e.name))
            print(('[br_core] terminals: %s (%d) gained access at %s'):format(e.name or '?', src, site.id))
        end
    end
    return true, nil
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
    if not on() then
        T.close(src, 'season')
        return nil, 'season'
    end
    -- AND A REAL ONE IS ASKED AGAIN WHETHER ITS PLAYER IS STILL THERE: the
    -- check on BR.Sched runs twice a second, and a run inside that window from
    -- a player who has just gone down or walked off must not land.
    local why = gone(src, session, now)
    if why then
        T.close(src, why)
        return nil, why
    end

    local answer = { terminalId = session.terminalId, functionId = id }
    local row = rowOf(id)
    if not row then
        answer.ok, answer.code = false, 'unavailable'
        return answer
    end
    -- THE OPTIONS FIRST, AND WHOLE. A request the registry does not allow is
    -- answered -- the app's button is waiting on it -- and nothing is asked
    -- or spent.
    local opts = T.options(row, d.options)
    if not opts then
        answer.ok, answer.code = false, 'bad_option'
        answer.state = T.state(src, session)
        return answer
    end
    local refused = refusal(src, session, row, opts)
    if refused then
        answer.ok, answer.code = false, refused
        answer.state = T.state(src, session)
        return answer
    end

    local fn = T.FUNCTIONS[id]
    local r = fn.run(src, session, opts) or {}
    answer.ok = r.ok == true
    answer.code = type(r.code) == 'string' and r.code or (answer.ok and 'done' or 'unavailable')
    if answer.ok then
        T.consume(src, session, id)
        if not session.dev then
            local m = BR.Server.matchOf(src)
            local e = BR.Roster.get(src)
            if m and e then
                tellLobby(m, TS.line(copy().notice_action, e.name, copy()[id .. '_description']))
            end
            print(('[br_core] terminals: %s (%d) ran %s'):format(e and e.name or '?', src, id))
        end
        -- WHAT FOLLOWS THE LOBBY'S NOTICE, in that order: "has redeemed their
        -- special power: Scan..." is read before "A new bounty is among us".
        if r.after then r.after() end
    end
    answer.state = T.state(src, session)
    return answer
end

-- ---------------------------------------------------------- net events ---

-- THE USE REQUEST. Season, shape and rate here; the rest is BR.Terminal.use,
-- which reads the sender's state, match, position and terminal off this
-- server. An offline terminal is the one refusal said aloud -- the plate
-- already said it, and a player who pressed anyway is told why nothing
-- opened. Every other refusal is a client out of step with the server, and
-- silence is the answer the loot claim gives that too.
RegisterNetEvent(BR.Net.TERMINAL_USE)
AddEventHandler(BR.Net.TERMINAL_USE, function(d)
    local src = tonumber(source)
    if not src or not on() then return end
    if type(d) ~= 'table' or not TS.validId(d.terminalId) then return end
    local now = GetGameTimer()
    local last = lastUseAt[src]
    if last ~= nil and now - last < cfg().runMinIntervalMs then return end
    lastUseAt[src] = now
    local ok, why = BR.Terminal.use(src, d.terminalId, now)
    if not ok and why == 'offline' then
        BR.Server.notify(src, copy().offline, 'warn')
    end
end)

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

-- A late joiner, a reconnect, a restarted br_core or br_ui: the dev tools'
-- terminals, and the squad's Storm reveal while its match lasts.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() then return end
    sendSites(src)
    local m, _, key = whereIs(src)
    local r = m and m.terminals and m.terminals.reveals[key] or nil
    if r then
        TriggerClientEvent(BR.Net.TERMINAL_REVEAL, src, { x = r.x, y = r.y, r = r.r, matchId = m.id })
    end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end
    sessions[src] = nil
    lastRunAt[src] = nil
    lastUseAt[src] = nil
end)

if BR.Sched and BR.Sched.every then
    -- The job is handed the time since its last run, not the clock.
    BR.Sched.every(cfg().sessionCheckMs or 500, 'terminal.sessions', function()
        if next(sessions) == nil then return end
        T.checkSessions(GetGameTimer())
    end)
    -- THE PANEL, REALTIME: every open computer its state again, the match
    -- panel included -- to that player alone, and only while it is open. No
    -- open computer, no work.
    BR.Sched.every(cfg().infoPushMs or 1000, 'terminal.info', function()
        if next(sessions) == nil then return end
        T.pushInfo()
    end)
end

-- ---------------------------------------------------------------- dev ---

local USAGE = 'usage: brterminalsv open [nokey] [used] [offline] | close | key give|take'
    .. ' | place <x> <y> <z> [h] [id] | remove <id> | list | online <id> [off] | reset'
    .. ' | run <function> [option=choice ...]  (from the server console, a verb about a player takes'
    .. ' the player id next: brterminalsv open <player id> [...])'

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

--- `list`: every terminal, where it is, and what the asker's match makes of it.
local function devList(src)
    local list = T.sites()
    if #list == 0 then
        tell(src, 'no terminals -- br_lib/config/terminals.lua sites is empty and none were placed')
        return
    end
    local m = src > 0 and BR.Server.matchOf(src) or nil
    local now = GetGameTimer()
    for _, s in ipairs(list) do
        tell(src, ('%s  (%.1f, %.1f, %.1f) h %.0f  %s%s%s'):format(s.id, s.x, s.y, s.z, s.h or 0,
            placed[s.id] and 'placed' or 'config',
            forced[s.id] and ', forced online' or '',
            m and (T.online(s, m, now) and ', online' or ', OFFLINE') or ''))
    end
end

--- `place`: a terminal at x y z, and the config line for it.
local function devPlace(src, words)
    local x, y, z, h = tonumber(words[1]), tonumber(words[2]), tonumber(words[3]), tonumber(words[4])
    if not (TS.finite(x) and TS.finite(y) and TS.finite(z)) then
        tell(src, 'place needs x y z [h] [id] -- `brterminal place` in game finds them for you')
        return
    end
    local id = words[5] and words[5]:lower() or nil
    if id == nil then
        repeat
            devSeq = devSeq + 1
            id = ('terminal_%d'):format(devSeq)
        until not T.site(id)
    end
    if not TS.validId(id) then
        tell(src, ('"%s" is not an id: lower case letters, digits and _, at most %d')
            :format(id, TS.ID_MAX))
        return
    end
    local site = { id = id, x = x + 0.0, y = y + 0.0, z = z + 0.0,
                   h = TS.finite(h) and h + 0.0 or 0.0 }
    if not placed[id] then placedOrder[#placedOrder + 1] = id end
    placed[id] = site
    removed[id] = nil
    sendSites(-1)
    tell(src, ('placed %s for this session. Paste into br_lib/config/terminals.lua sites:'):format(id))
    tell(src, '    ' .. TS.siteLine(site))
end

-- `brterminal` and `bryubikey` (client/terminal.lua) run this with ExecuteCommand,
-- so it arrives as the player who typed it. REGISTERED UNRESTRICTED, as
-- `brpropsv` is: dev mode, through devgate.lua's wrap, is its only gate, and
-- everything it changes is a dev box's own session.
RegisterCommand('brterminalsv', function(source, args)
    local src = tonumber(source) or 0
    args = args or {}
    local verb = args[1] and args[1]:lower() or ''
    local words = {}
    for i = 2, #args do words[#words + 1] = args[i] end

    -- ═══ ABOUT THE TERMINALS: NO PLAYER NEEDED ═══
    if verb == 'list' then
        devList(src)
        return
    end
    if verb == 'online' or verb == 'remove' then
        local id = words[1] and words[1]:lower() or ''
        if not T.site(id) then
            tell(src, ('no terminal "%s" -- `brterminal list`'):format(id))
            return
        end
        if verb == 'online' then
            local off = words[2] ~= nil and words[2]:lower() == 'off'
            forced[id] = (not off) or nil
            tell(src, ('%s %s'):format(id, off and 'follows the storm again' or 'is forced online'))
        else
            if placed[id] then placed[id] = nil else removed[id] = true end
            forced[id] = nil
            tell(src, ('removed %s for this session (a config row stays in the file)'):format(id))
        end
        sendSites(-1)
        T.checkSessions(GetGameTimer())
        return
    end
    if verb == 'place' then
        devPlace(src, words)
        return
    end

    -- ═══ ABOUT A PLAYER: THE ONE WHO TYPED IT, OR THE ONE THE CONSOLE NAMES ═══
    local target = src
    if src == 0 then
        target = tonumber(words[1]) or 0
        table.remove(words, 1)
    end
    if target <= 0 or not GetPlayerName(target) then
        tell(src, 'that needs a player. ' .. USAGE)
        return
    end
    if not on() then
        tell(src, ('terminals are Season 2 and this box runs Season %s -- `brseason 2` first')
            :format(tostring(BR.Season.current())))
        return
    end

    if verb == 'open' then
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

    elseif verb == 'key' then
        local give = (words[1] or 'give'):lower() ~= 'take'
        local ok, why = BR.Yubikey.devSet(target, give)
        if ok then
            tell(src, ('%d %s a key'):format(target, give and 'now holds' or 'no longer holds'))
        else
            tell(src, ('%d: %s'):format(target,
                why == 'holding' and 'already holds one'
                or why == 'none' and 'holds none'
                or why == 'loading' and 'their profile has not been read yet'
                or tostring(why)))
        end

    elseif verb == 'reset' then
        local m, _, key = whereIs(target)
        if not m then
            tell(src, ('%d is not in a match'):format(target))
            return
        end
        local s = matchState(m)
        s.used[key] = nil
        for _, mate in ipairs(squadOf(m, key)) do s.access[mate] = nil end
        pushKeys(squadOf(m, key))
        tell(src, ('reset the terminal use of %d\'s squad (%s) for this match'):format(target, key))

    elseif verb == 'run' then
        -- A FUNCTION'S EFFECT, WITHOUT A KEY, A TERMINAL OR A NOTICE: nothing
        -- is spent and the squad's use is untouched. For testing what a
        -- function does, not the door in front of it.
        -- Options as option=choice words after the id, through the same
        -- BR.Terminal.options the net event uses.
        local id = words[1] and words[1]:lower() or ''
        local row = rowOf(id)
        if not row then
            tell(src, ('no function "%s"'):format(id))
            return
        end
        if not built(row) then
            tell(src, ('%s is listed but its effect is not built (implemented = false)'):format(id))
            return
        end
        local given = {}
        for i = 2, #words do
            local k, v = words[i]:match('^([%w_]+)=([%w_]+)$')
            if not k then
                tell(src, ('"%s" is not option=choice'):format(words[i]))
                return
            end
            given[k] = v
        end
        local opts = T.options(row, given)
        if not opts then
            tell(src, ('%s does not take those options'):format(id))
            return
        end
        local r = T.FUNCTIONS[id].run(target, { terminalId = 'dev', dev = false }, opts) or {}
        tell(src, ('ran %s for %d without a key: %s (%s)'):format(id, target,
            r.ok and 'ok' or 'refused', tostring(r.code)))
        if r.ok and r.after then r.after() end

    else
        tell(src, USAGE)
    end
end, false)

-- Flick cameras (#419), Season 2, server half: EVERY DOWN IS DECIDED HERE.
--
-- Pole cameras along the roads (br_lib/config/flick_cameras.lua) that feed the
-- terminal's Scan. The whole contract is docs/flick.md. This file holds:
--
--   the cameras   this match's: which are down, why, and who was credited --
--                 on the match, so every match starts with every camera up
--   the door      FLICK_REPORT, a client saying a camera near it went down,
--                 taken only in its order (below) and silent otherwise
--   the decision  a camera up goes down; a `me` report from a standing player
--                 within reach is credited 2 Volts, 30 at most a match
--   the reward    into the roster entry's voltsPickedUp, which the match's one
--                 atomic ADD pays at its end -- the airdrop pile's path -- and
--                 the takedown toast to that player, exactly when credited
--   who is told   FLICK_DOWN to the players near each down, to every member
--                 of a squad running Scan all of it, and on a 1 s pass to
--                 whoever comes near; the snapshot's view for a late joiner
--   Scan's eyes   BR.Flick.seen: the players a live camera sees, which
--                 server/terminalfx.lua's Scan sends and nothing else
--   the dev tools `brflicksv`, typed through `brflick`
--
-- ═══ THE OWNER'S DECISIONS (2026-10-18) ═══
--
--   * One hit on the camera or its solar panel takes it down; a vehicle
--     knocks it over. Down for the rest of the match, the server decides,
--     every client shows it broken, all of it resets each match.
--   * Explosions and AI traffic take one down too, and pay nobody.
--   * 2 Volts a camera to the player who took it down, 30 at most a match.
--   * Scan sees an opponent within 75 m of a working camera, 150 m in a
--     vehicle.
--
-- ═══ A CLIENT ONLY EVER SAYS "I DID IT" OR "IT FELL" ═══
--
-- A map object is each client's own, so only a client can see one break, and
-- the client resolves nobody else's ped to say who did it (the scope gate's
-- natives are not needed). So credit is given only to the player whose own
-- report says `me`, standing, in a PLAYING match, within reach of the camera
-- by this server's own 4 Hz sample of them -- never to somebody a client
-- names. A bystander's `other` downs the camera and pays nobody: a camera
-- broken where players can see it is broken for Scan too, and a modified
-- client gains no more than a gun would give it -- it can only down cameras
-- within reach of where this server says it stands.
--
-- ═══ NO DECISION HERE READS DEV MODE ═══
--
-- tools/check_net_gates.lua: a net event may not refuse on dev mode. The dev
-- verbs are a command, behind br_lib/shared/devgate.lua's wrap like every
-- other, and they credit nobody.

BR = BR or {}
BR.Flick = BR.Flick or {}

local F = BR.Flick
local FS = BR.FlickSolve

local function cfg() return BR.Config.Flick end
local function report() return BR.Config.Flick.report or {} end

--- Is Flick on, in the season in force? On this side BR.Season.has is the
--- latched season and a few table reads, so the door, the pass and Scan ask it
--- as they go.
--- @return boolean
local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('flick') == true
end
F.on = on

--- In the fight with a position worth reading: standing, downed or in the air
--- (server/terminalfx.lua's MARKED, the set Scan has always marked).
local IN_FIGHT = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO] = true,
    [BR.PlayerState.FREEFALL] = true,
    [BR.PlayerState.GLIDE] = true,
}

--- A report's player: standing or downed (the door's step 5).
local REPORTS = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO] = true,
}

-- ------------------------------------------------------------ the grid ---

--- The registry in cells, built once -- and again only if the registry table
--- itself is replaced (a suite's fixture). BR.FlickSolve.grid.
local built = { rows = nil, grid = nil }

--- @return table
function F.grid()
    local rows = cfg().cameras or {}
    if built.rows ~= rows then
        built.rows = rows
        built.grid = FS.grid(rows, cfg().gridM)
    end
    return built.grid
end

-- -------------------------------------------------- the match's cameras ---

--- This match's cameras, made on first use and gone with the match: every
--- match starts with every camera up, and two matches at once each have their
--- own.
---   down     [id] = { at, cause, by?, name?, blast?, dev? }: down, when, the
---            cause the wreck is drawn for, who was credited, an explosion's
---   order    the ids in the order they went down
---   paid     [license] = Volts credited this match. THE CAP IS BY ACCOUNT,
---            on the match, so walking out and back, a reconnect or a client
---            restart never resets it
---   sent     [src] = { [id] = true }, and sentN [src] = how many: what each
---            player has been sent
---   rate     [src] = reports taken this match
---   refused  [reason] = how many reports were dropped for it
---   blasts   { { x, y, z, at } }: the last explosions in this match
--- @param m table
--- @return table
local function stateOf(m)
    local s = m.flick
    if not s then
        s = { down = {}, order = {}, paid = {}, sent = {}, sentN = {}, rate = {},
              refused = {}, blasts = {} }
        m.flick = s
    end
    return s
end
F.stateOf = stateOf

--- Reports dropped with no match to count them on, by reason.
local refusedLoose = {}

--- [src] = GetGameTimer() of their last report past its shape.
local lastAt = {}

--- One refusal counted, on the match when there is one.
local function count(m, reason)
    local t = m and stateOf(m).refused or refusedLoose
    t[reason] = (t[reason] or 0) + 1
end

-- ------------------------------------------------------------ explosions ---
--
-- EXPLOSIONS PAY NOBODY (owner, 2026-10-18). A client cannot tell its own
-- grenade's damage from its own bullet's on a map object, so the server, which
-- hears every networked explosion (explosionEvent: the sender and where),
-- remembers this match's last few, and a down within report.blastM of one,
-- report.blastWindowMs after it, is nobody's: down, and no Volts.

--- How many explosions a match keeps.
local BLASTS_MAX = 32

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--- Note an explosion in this match. Public so the suites can make one.
--- @param m table
--- @param x number
--- @param y number
--- @param z number
--- @param now number
function F.noteBlast(m, x, y, z, now)
    local st = stateOf(m)
    local keep = report().blastWindowMs or 3000
    local list = {}
    for _, b in ipairs(st.blasts) do
        if now - b.at <= keep then list[#list + 1] = b end
    end
    list[#list + 1] = { x = x, y = y, z = z, at = now }
    while #list > BLASTS_MAX do table.remove(list, 1) end
    st.blasts = list
end

--- Was there an explosion near this camera, recently enough to be what took
--- it down?
local function blastNear(st, row, now)
    local r = report().blastM or 15.0
    local keep = report().blastWindowMs or 3000
    for _, b in ipairs(st.blasts) do
        local dx, dy, dz = b.x - row.x, b.y - row.y, b.z - row.z
        if now - b.at <= keep and now >= b.at and dx * dx + dy * dy + dz * dz <= r * r then
            return true
        end
    end
    return false
end

-- --------------------------------------------------------- who is told ---

--- Where a player is looking from: their own sample, or for a spectator the
--- sample of the player they watch (EMOTE_RECORD's rule).
--- @param src integer
--- @param e table
--- @return table|nil
local function viewOf(src, e)
    local t = BR.Spectate and BR.Spectate.targetOf and BR.Spectate.targetOf(src) or nil
    if t then
        local te = BR.Roster.get(t)
        return te and te.pos or nil
    end
    return e.pos
end

--- Is this player in a squad running Scan in this match? Such a squad holds
--- every down: its coverage is the registry less every one.
local function scanning(m, src, e)
    local fx = m.terminalFx
    local scans = fx and fx.scans
    if not scans or next(scans) == nil or not BR.TerminalSolve then return false end
    return scans[BR.TerminalSolve.squadKey(e, src)] ~= nil
end

--- The downs this player should hold now: all of them for a Scan squad,
--- otherwise those within showM of their view.
--- @return integer[]
local function wanted(m, st, src, e)
    local out = {}
    if #st.order == 0 then return out end
    if scanning(m, src, e) then
        for i = 1, #st.order do out[i] = st.order[i] end
        return out
    end
    local p = viewOf(src, e)
    if not p then return out end
    local r = cfg().showM or 500.0
    local g = F.grid()
    for _, id in ipairs(st.order) do
        local row = FS.row(g, id)
        if row then
            local dx, dy = row.x - p.x, row.y - p.y
            if dx * dx + dy * dy <= r * r then out[#out + 1] = id end
        end
    end
    return out
end

--- FLICK_DOWN's shape for these ids.
local function payload(m, st, ids)
    local causes = {}
    for i, id in ipairs(ids) do
        local rec = st.down[id]
        causes[i] = rec and rec.cause or 'weapon'
    end
    return { matchId = m.id, ids = ids, causes = causes }
end

--- Send the players in this match the downs they should hold and have not
--- been sent: a fresh down to the players near it and to every Scan squad, and
--- an old one to whoever has come near since. Every player, or `only` these.
--- @param m table
--- @param only table|nil  [src] = true: these players alone
function F.sendTo(m, only)
    local st = m.flick
    if not st or #st.order == 0 or not on() then return end
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if only and not only[src] then return end
        if (st.sentN[src] or 0) >= #st.order then return end
        local mine = st.sent[src]
        if not mine then
            mine = {}
            st.sent[src] = mine
        end
        local fresh = {}
        for _, id in ipairs(wanted(m, st, src, e)) do
            if not mine[id] then fresh[#fresh + 1] = id end
        end
        if #fresh == 0 then return end
        for _, id in ipairs(fresh) do mine[id] = true end
        st.sentN[src] = (st.sentN[src] or 0) + #fresh
        TriggerClientEvent(BR.Net.FLICK_DOWN, src, payload(m, st, fresh))
    end)
end

--- The same, to everyone in the match: after a down, and on the 1 s pass.
--- Public so the suites can step it.
--- @param m table
function F.sendPass(m)
    F.sendTo(m, nil)
end

--- A SQUAD STARTS SCAN: every down so far to every member of it, at once --
--- its coverage is the registry less all of them. Called by
--- server/terminalfx.lua's BR.Terminal.startScan.
--- @param m table
--- @param key string  the squad (BR.TerminalSolve.squadKey)
function F.joinScan(m, key)
    if not on() or not m.flick or not BR.TerminalSolve then return end
    local only = {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if BR.TerminalSolve.squadKey(e, src) == key then only[src] = true end
    end)
    F.sendTo(m, only)
end

--- THE SNAPSHOT'S VIEW (BR.Broadcast.snapshot): the downs this player should
--- hold, `{ matchId, ids, causes }`, which become exactly what they have been
--- sent -- a restarted client, re-seeded by br:ready's snapshot, holds this list
--- and no other. Nil outside a match or off Season 2: the client then holds none.
--- @param src integer
--- @return table|nil
function F.viewFor(src)
    if not on() then return nil end
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    local e = BR.Roster.get(src)
    if not m or not e then return nil end
    local st = m.flick
    if not st then return { matchId = m.id, ids = {}, causes = {} } end
    local ids = wanted(m, st, src, e)
    local mine = {}
    for _, id in ipairs(ids) do mine[id] = true end
    st.sent[src], st.sentN[src] = mine, #ids
    return payload(m, st, ids)
end

-- ------------------------------------------------------------ the down ---

--- Take camera `id` down in this match: recorded, then sent to whoever should
--- hold it. The caller credits (or does not) before it is sent.
--- @return table  the record
local function goDown(m, st, id, row, cause, now, dev)
    local rec = { at = now, cause = cause == 'vehicle' and 'vehicle' or 'weapon',
                  blast = blastNear(st, row, now) or nil, dev = dev or nil }
    st.down[id] = rec
    st.order[#st.order + 1] = id
    return rec
end

--- Credit a camera to the player whose `me` report took it down: voltsEach,
--- or what is left of voltsMatchMax for their account -- the 16th camera still
--- goes down, credited, and pays 0.
---
--- INTO voltsPickedUp, AND NOTHING ELSE. The roster entry's "Volts found in the
--- match" rides the results row (a leaver's sealed row too) into
--- BR.Config.marketPayout, which adds it whole into the match's one atomic ADD:
--- no new writer of a balance, no per-camera database write
--- (br_lib/config/market.lua's promise).
---
--- THE TAKEDOWN TOAST RIDES THE SAME `n > 0` (owner, 2026-10-18): the player
--- is thanked exactly when Volts were credited. At the cap `n` is 0, and every
--- down that pays nobody -- an explosion, a bystander's `other`, a downed
--- reporter, the dev down, another player's camera -- never reaches here.
--- @return integer paid, integer total
local function credit(st, rec, src, e)
    local c = cfg()
    local lic = (BR.Roster.licenseOf and BR.Roster.licenseOf(src)) or ('src:' .. tostring(src))
    local had = st.paid[lic] or 0
    local n = math.max(0, math.min(c.voltsEach or 2, (c.voltsMatchMax or 30) - had))
    rec.by, rec.name = src, e.name
    st.paid[lic] = had + n
    if n > 0 then
        e.voltsPickedUp = (e.voltsPickedUp or 0) + n
        local text = FS.toast(c.copy, n, BR.Config.Market and BR.Config.Market.currency or nil)
        if text then BR.Server.notify(src, text, 'success') end
    end
    return n, had + n
end

--- The one console line a down makes.
local function say(m, id, rec, paid, total)
    local why = rec.cause .. (rec.blast and ', an explosion' or '') .. (rec.dev and ', dev' or '')
    if rec.by then
        print(('[br_core] flick: camera %d down (%s) by %s (%d), +%d Volts (%d/%d) in match %s')
            :format(id, why, tostring(rec.name), rec.by, paid or 0, total or 0,
                cfg().voltsMatchMax or 30, tostring(m.id)))
    else
        print(('[br_core] flick: camera %d down (%s), nobody credited, in match %s')
            :format(id, why, tostring(m.id)))
    end
end

--- THE DEV TOOLS' DOWN (`brflick down`): the same decision, nobody credited,
--- nothing paid. Public so the suites can make one.
--- @param m table
--- @param id integer
--- @param now number
--- @return boolean  it went down (false: no such camera, or already down)
function F.devDown(m, id, now)
    local row = FS.validId(id) and FS.row(F.grid(), id) or nil
    if not row then return false end
    local st = stateOf(m)
    if st.down[id] then return false end
    local rec = goDown(m, st, id, row, 'weapon', now, true)
    say(m, id, rec)
    F.sendPass(m)
    return true
end

-- ------------------------------------------------------------ the door ---
--
-- ═══ FLICK_REPORT, IN THIS ORDER, EVERY REFUSAL SILENT ═══
--
--   1. season     Flick on in the season in force
--   2. shape      `id` a whole number naming a row; `by` 'me' or 'other';
--                 `cause` 'weapon', 'vehicle' or absent
--   3. rate       no sooner than report.minIntervalMs after this player's last,
--                 and report.perMatch a match at most
--   4. match      the reporter is in a match, and it is PLAYING: warmup, the
--                 bus, the end screen and the lobby down nothing
--   5. player     ALIVE or DBNO, by the roster
--   6. reach      by this server's own sample, no older than
--                 report.sampleMaxAgeMs, 3D to the row: BR.FlickSolve.reach
--   7. camera     still up in this match -- or down less than
--                 report.creditWindowMs ago with nobody credited, for a `me`
--                 report from a standing player. Anything else is a
--                 `duplicate` and changes nothing
--
-- Each refusal is counted per reason on the match, for `brflick list`.

--- Take one report. Public so the suites can step it.
--- @param src integer
--- @param d table
--- @param now number
--- @return string  'down', 'credit', or the refusal's reason
function F.report(src, d, now)
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    local function no(reason)
        count(m, reason)
        return reason
    end
    if not on() then return no('season') end

    if type(d) ~= 'table' then return no('shape') end
    local id = d.id
    local row = FS.validId(id) and FS.row(F.grid(), id) or nil
    local by, cause = d.by, d.cause
    if not row or (by ~= 'me' and by ~= 'other')
       or (cause ~= nil and cause ~= 'weapon' and cause ~= 'vehicle') then
        return no('shape')
    end
    id = math.tointeger(id)

    local R = report()
    local last = lastAt[src]
    if last and now - last < (R.minIntervalMs or 300) then return no('rate') end
    lastAt[src] = now
    if m then
        local st = stateOf(m)
        local n = (st.rate[src] or 0) + 1
        st.rate[src] = n
        if n > (R.perMatch or 60) then return no('rate') end
    end

    local e = BR.Roster.get(src)
    if not m or not e or e.matchId ~= m.id or m.state ~= BR.MatchState.PLAYING then
        return no('match')
    end

    if not REPORTS[e.state] then return no('player') end

    local p = e.pos
    if type(p) ~= 'table' or now - (e.posAt or 0) > (R.sampleMaxAgeMs or 1000) then
        return no('reach')
    end
    local reach = FS.reach(by, cause, R)
    local dx, dy, dz = p.x - row.x, p.y - row.y, (p.z or row.z) - row.z
    if dx * dx + dy * dy + dz * dz > reach * reach then return no('reach') end

    local st = stateOf(m)
    local was = st.down[id]
    local paying = by == 'me' and e.state == BR.PlayerState.ALIVE
    if was then
        -- DOWN ALREADY, INSIDE THE CREDIT WINDOW, NOBODY CREDITED: a `me`
        -- report from a standing player is the credit, and nothing else -- so
        -- a bystander's `other` landing 200 ms before the shooter's `me` costs
        -- the shooter nothing. Two `me` reports: the first one this door took.
        if paying and not was.by and not was.dev and not was.blast
           and now - was.at < (R.creditWindowMs or 3000) and not blastNear(st, row, now) then
            local paid, total = credit(st, was, src, e)
            say(m, id, was, paid, total)
            return 'credit'
        end
        return no('duplicate')
    end

    local rec = goDown(m, st, id, row, cause, now)
    local paid, total = nil, nil
    if paying and not rec.blast then paid, total = credit(st, rec, src, e) end
    F.sendPass(m)
    say(m, id, rec, paid, total)
    return 'down'
end

RegisterNetEvent(BR.Net.FLICK_REPORT)
AddEventHandler(BR.Net.FLICK_REPORT, function(d)
    local src = tonumber(source)
    if src then F.report(src, d, GetGameTimer()) end
end)

-- THE EXPLOSIONS THE SERVER HEARS: noted on the sender's match while it is
-- played, so a down near one pays nobody. Server-originated blasts (sender 0)
-- belong to no match.
AddEventHandler('explosionEvent', function(sender, ev)
    if type(ev) ~= 'table' or not on() then return end
    local src = tonumber(sender)
    if not src or src == 0 then return end
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    if not m or m.state ~= BR.MatchState.PLAYING then return end
    local x, y, z = tonumber(ev.posX), tonumber(ev.posY), tonumber(ev.posZ)
    if not (finite(x) and finite(y) and finite(z)) then return end
    F.noteBlast(m, x, y, z, GetGameTimer())
end)

-- ---------------------------------------------------------- Scan's eyes ---

--- Does this player ride a vehicle, any seat, by the server's own copy?
--- BR.Vehicles.ridingIn: the #4006 workaround server/vehicles.lua already holds.
local function riding(e)
    return BR.Vehicles ~= nil and BR.Vehicles.ridingIn ~= nil and e.ped ~= nil
        and BR.Vehicles.ridingIn(e.ped) ~= nil
end

--- WHO A LIVE CAMERA SEES IN THIS MATCH: [src] = true, worked out once a Scan
--- ping over the match's roster from its own 4 Hz samples. Every player in
--- the fight with a position, flat to the nearest live camera
--- (BR.FlickSolve.covers): within rangeM on foot, within vehicleRangeM in any
--- seat of a vehicle -- the seat read asked only of a player between the two.
--- server/terminalfx.lua's Scan sends this set less the squad's own and any
--- squad under Ghost, and nothing else.
--- @param m table
--- @param now number  unused: the samples are the roster's own
--- @return table
function F.seen(m, now)
    local out = {}
    if not on() then return out end
    local g = F.grid()
    local down = m.flick and m.flick.down or nil
    local c = cfg()
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        local p = e.pos
        if IN_FIGHT[e.state] and type(p) == 'table'
           and FS.covers(g, down, p.x, p.y, function() return riding(e) end, c) then
            out[src] = true
        end
    end)
    return out
end

-- ------------------------------------------------------------- the jobs ---

if BR.Sched and BR.Sched.every then
    -- WHOEVER COMES NEAR A DOWN, once a second: the downs within showM of
    -- their view that they have not been sent. Nothing while no camera is down.
    BR.Sched.every(cfg().sendPassMs or 1000, 'flick.send', function()
        if not on() then return end
        BR.Server.eachMatch(function(m)
            if m.flick and #m.flick.order > 0 then F.sendPass(m) end
        end)
    end)
end

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end
    lastAt[src] = nil
    if BR.Server and BR.Server.eachMatch then
        BR.Server.eachMatch(function(m)
            if m.flick then
                m.flick.sent[src], m.flick.sentN[src] = nil, nil
            end
        end)
    end
end)

-- -------------------------------------------------------------- the dev ---
--
-- Dev mode only (br_lib/shared/devgate.lua wraps every command), Season 2 only,
-- typed as `brflick` on F8 (client/flick.lua) and run here as `brflicksv`:
--
--   brflicksv list          the cameras, this match's downs by cause, the
--                           refused reports by reason, your Flick Volts
--   brflicksv down <id>     down it through the decision: nobody credited,
--                           nothing paid
--   brflicksv reset         every camera in your match up again here, and every
--                           client's hides lifted (FLICK_DOWN reset)
--
-- From the server console, the player id comes next: `brflicksv list 12`.

local USAGE = 'brflick [list] | near | down <id|near> | reset | coverage [off] | hides'

--- One line on the requester's F8 (or this console), and nowhere else.
local function tell(src, text)
    print(('[br_core] brflick (client %s): %s'):format(tostring(src), text))
    if src > 0 then TriggerClientEvent(BR.Net.FLICK_DEV, src, text) end
end

local function devList(src, m)
    local g = F.grid()
    local st = m and m.flick or nil
    local causes = { weapon = 0, vehicle = 0, blast = 0, dev = 0 }
    for _, id in ipairs(st and st.order or {}) do
        local rec = st.down[id]
        if rec.dev then causes.dev = causes.dev + 1
        elseif rec.blast then causes.blast = causes.blast + 1
        else causes[rec.cause] = (causes[rec.cause] or 0) + 1 end
    end
    local refused = {}
    for reason, n in pairs(st and st.refused or {}) do refused[#refused + 1] = reason .. ' ' .. n end
    table.sort(refused)
    local lic = BR.Roster.licenseOf and BR.Roster.licenseOf(src) or nil
    local mine = st and lic and st.paid[lic] or 0
    tell(src, ('%d cameras; match %s: %d down (weapon %d, vehicle %d, explosion %d, dev %d); '
        .. 'refused: %s; your Flick Volts %d/%d')
        :format(g.n, m and tostring(m.id) or '-', st and #st.order or 0, causes.weapon,
            causes.vehicle, causes.blast, causes.dev,
            #refused > 0 and table.concat(refused, ', ') or 'none', mine, cfg().voltsMatchMax or 30))
end

RegisterCommand('brflicksv', function(source, args)
    local src = tonumber(source) or 0
    args = args or {}
    local verb = args[1] and args[1]:lower() or 'list'
    local words = {}
    for i = 2, #args do words[#words + 1] = args[i] end

    local target = src
    if src == 0 then
        target = tonumber(words[#words]) or 0
        words[#words] = nil
    end
    if target <= 0 or not GetPlayerName(target) then
        tell(src, 'that needs a player. ' .. USAGE)
        return
    end
    if not on() then
        tell(src, ('Flick is Season 2 and this box runs Season %s -- `brseason 2` first')
            :format(tostring(BR.Season and BR.Season.current and BR.Season.current())))
        return
    end
    local m = BR.Server.matchOf(target)

    if verb == 'list' then
        devList(target, m)
        return
    end
    if not m then
        tell(src, 'that is for a match: you are in none')
        return
    end
    if verb == 'down' then
        local id = math.tointeger(tonumber(words[1]))
        if not id or not FS.row(F.grid(), id) then
            tell(src, ('no camera "%s" -- `brflick near` names the nearest'):format(tostring(words[1])))
        elseif F.devDown(m, id, GetGameTimer()) then
            tell(src, ('camera %d is down in match %s: nobody credited, nothing paid'):format(id, tostring(m.id)))
        else
            tell(src, ('camera %d is already down in match %s'):format(id, tostring(m.id)))
        end
        return
    end
    if verb == 'reset' then
        m.flick = nil
        BR.Broadcast.toMatch(m, BR.Net.FLICK_DOWN, { matchId = m.id, reset = true })
        tell(src, ('every camera in match %s is up again; a camera a client broke itself '
            .. 'stays broken there until it streams out'):format(tostring(m.id)))
        return
    end
    tell(src, USAGE)
end)

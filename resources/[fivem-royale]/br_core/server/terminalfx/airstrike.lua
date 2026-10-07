-- Season 2 terminals (#396), round 5: AIRSTRIKE, the server half.
--
-- THE OWNER, 2026-10-06: "yes please put Airstrike in the same build", on the
-- design proposed on #396 -- "not homing missiles. After a visible ~10 s warning
-- (a flare and a circle on everyone's map), about 10 unguided airstrike rockets
-- fall from the sky onto random points within ~40 m of the spot", the damage
-- "decided by the server, through the health ledger. Kills are credited to the
-- runner, and every nearby client only draws the rockets and explosions."
--
--   THE SPOT     round 4's map pick (`spot` on the row, `opts.at`), inside the
--                play area (BR.Config.Map.InBounds) or `strike_spot`, nothing
--                spent.
--   THE PICK     `fuzz` on the row: WHILE the spot is picked, the runner sees
--                every opponent as a rough circle near where they are --
--                fx.fuzzRadiusM across, its center fx.fuzzMinM..fuzzMaxM off
--                them, never on them -- unless their own squad already has Scan
--                running (the exact dots are there). The client says when the
--                pick starts and ends (TERMINAL_PICK); the server sends the
--                circles (TERMINAL_FUZZ) every fx.fuzzPingMs while it lasts,
--                and an empty list when it ends. Each offset is fixed for the
--                match, per runner and opponent, so picking again tells nothing
--                more. A squad under Ghost is on nobody's map, here as for Scan
--                and the bounty (BR.Terminal.hidden). Only inside the session
--                on that terminal, from a player who could run it now and can
--                afford it.
--   THE WARNING  fx.strikeWarnMs (10 s) from the run's end to the first
--                rocket: TERMINAL_STRIKE to the whole match -- the circle on
--                every map, the red flare at the spot, and where and when each
--                rocket lands -- and the persistent notice (`impact_airstrike`)
--                for every player in the fight within its reach, the runner's
--                squad included, never the runner.
--   THE ROCKETS  fx.strikeRockets (10), on points spread evenly over the area
--                within fx.strikeRadiusM (40 m), one after another over
--                fx.strikeSpreadMs (4 s) (BR.TerminalSolve.strikePlan).
--                UNGUIDED: nothing about where anybody is goes into the plan.
--   THE DAMAGE   THE SERVER'S. Each rocket deals fx.strikeDamage to every
--                player standing or downed within fx.strikeFullM of where it
--                lands, falling off to nothing at fx.strikeReachM
--                (BR.TerminalSolve.blastDamage), through BR.Damage.applyHit --
--                the health ledger's own door, armor first, a downed player's
--                bleed clock, the heal ceilings, the victim's ped told -- billed
--                as the world's blast (WEAPON_EXPLOSION), so it kills outright
--                ("if you die in an explosion there is no bleed out timer").
--                An opponent's hit is the runner's: credited, a hitmarker, and
--                the kill theirs. FRIENDLY FIRE: the runner's own squad is hit
--                too -- it is their call where to aim -- but a teammate's hit,
--                and the runner's own, is nobody's (BR.Damage.applyHit with no
--                dealer: no credit, no hitmarker, no assist window, no teamkill
--                counted). Vehicles within fx.strikeReachM lose engine and body
--                health the same way, and within fx.strikeWreckM are wrecked --
--                written by the one client that owns each (TERMINAL_STRIKE_VEH),
--                since a vehicle's health is the owner's to write.
--   THE CLIENTS  only DRAW it (client/terminalfx/airstrike.lua): the rockets
--                are local objects and the blasts particles and a sound -- no
--                AddExplosion, no projectile -- so nothing goes through the
--                anticheat's explosion checks and nobody is flagged. A
--                vehicle the strike wrecks goes up the way any wreck does.
--
-- The lobby hears notice_action (`airstrike_description`). The match ending,
-- or Season 2 ending, stops the rockets that have not landed.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- What a rocket's hit is billed as: the world's own blast, config/weapons.lua's
--- `explosion` row -- a blast to BR.Combat.canBeDowned, 'explosion' to the
--- kill feed.
--- @return integer|nil
local function blastHash()
    for _, row in ipairs(BR.Config.Environmental or {}) do
        if row.id == 'explosion' then return row.hash end
    end
    return nil
end

local strikeSeq = 0

--- Is (x, y) a spot an Airstrike may hit: inside the play area?
local function inPlay(x, y)
    local inBounds = BR.Config.Map and BR.Config.Map.InBounds or nil
    return inBounds == nil or inBounds(x, y) == true
end

--- The strikes of this match still to land: [id] = strike.
local function strikesOf(m)
    local st = T.fxOf(m)
    st.strikes = st.strikes or {}
    return st.strikes
end

--- What TERMINAL_STRIKE carries: the circle, and every rocket's spot and time.
local function payloadOf(m, s)
    local rockets = {}
    for i, rk in ipairs(s.rockets) do rockets[i] = { x = rk.x, y = rk.y, at = rk.at } end
    return { matchId = m.id, id = s.id, x = s.x, y = s.y, r = s.r,
             startsAt = s.startsAt, endsAt = s.endsAt, rockets = rockets }
end

--- How far a strike's harm reaches from its spot: the circle and the blast past it.
local function reachOf(s)
    return s.r + (tonumber(fx().strikeReachM) or 14.0)
end

--- One rocket lands: the server works out who and what it hurts.
local function blast(m, s, rk)
    local F = fx()
    local hash = blastHash()
    local runner = BR.Roster.get(s.by)
    local credit = runner ~= nil and runner.matchId == m.id
    local hits = {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if not (e.state == BR.PlayerState.ALIVE or e.state == BR.PlayerState.DBNO) or not e.pos then return end
        local dx, dy = e.pos.x - rk.x, e.pos.y - rk.y
        local dmg = TS.blastDamage(math.sqrt(dx * dx + dy * dy), F.strikeDamage, F.strikeFullM, F.strikeReachM)
        if dmg <= 0.0 then return end
        -- AN OPPONENT'S HIT IS THE RUNNER'S; the squad's own, and the
        -- runner's, nobody's.
        local shooter = (credit and TS.squadKey(e, src) ~= s.squad) and s.by or nil
        hits[#hits + 1] = { src = src, dmg = dmg, shooter = shooter }
    end)
    for _, h in ipairs(hits) do
        BR.Damage.applyHit(h.shooter, h.src, h.dmg,
            { weapon = hash, explosive = true, headshot = false, component = 0 })
    end
    -- THE VEHICLES: each owner writes its own car's health.
    local wrecked, damaged = 0, 0
    local okAll, all = pcall(GetAllVehicles)
    for _, veh in ipairs(okAll and type(all) == 'table' and all or {}) do
        local okB, bucket = pcall(GetEntityRoutingBucket, veh)
        if okB and bucket == m.bucket then
            local okC, c = pcall(GetEntityCoords, veh)
            if okC and c and TS.finite(c.x) and TS.finite(c.y) then
                local dx, dy = c.x - rk.x, c.y - rk.y
                local d = math.sqrt(dx * dx + dy * dy)
                local frac = TS.blastDamage(d, 1.0, F.strikeFullM, F.strikeReachM)
                if frac > 0.0 then
                    local okO, owner = pcall(NetworkGetEntityOwner, veh)
                    local okN, netId = pcall(NetworkGetNetworkIdFromEntity, veh)
                    owner = okO and math.tointeger(tonumber(owner)) or nil
                    if owner and owner > 0 and okN and netId then
                        local wreck = d <= (tonumber(F.strikeWreckM) or 4.0)
                        TriggerClientEvent(BR.Net.TERMINAL_STRIKE_VEH, owner,
                            { netId = netId, frac = frac, wreck = wreck or nil })
                        if wreck then wrecked = wrecked + 1 else damaged = damaged + 1 end
                    end
                end
            end
        end
    end
    if #hits > 0 or wrecked + damaged > 0 then
        print(('[br_core] terminals: airstrike %d rocket at (%.1f, %.1f): %d player(s) hit, '
            .. '%d vehicle(s) wrecked, %d damaged'):format(s.id, rk.x, rk.y, #hits, wrecked, damaged))
    end
end

--- Land every rocket of this strike that is due, and drop the strike once the
--- last has -- or at once, without landing anything more, when its match is
--- over or Season 2 has ended. Public so the suites can step it.
--- @param m table
--- @param s table
--- @param now number
function T.stepStrike(m, s, now)
    if s.over then return end
    if not on() or BR.Server.matchById(m.id) ~= m or m.state ~= BR.MatchState.PLAYING then
        s.over = true
        strikesOf(m)[s.id] = nil
        return
    end
    local left = 0
    for _, rk in ipairs(s.rockets) do
        if not rk.done and rk.at <= now then
            rk.done = true
            blast(m, s, rk)
        end
        if not rk.done then left = left + 1 end
    end
    if left == 0 then
        s.over = true
        strikesOf(m)[s.id] = nil
    end
end

--- The strikes of a match still to land, for the suites and br:ready.
--- @param m table
--- @return table[]
function T.strikesLive(m)
    local out = {}
    for _, s in pairs(m and m.terminalFx and m.terminalFx.strikes or {}) do
        if not s.over then out[#out + 1] = s end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

T.FUNCTIONS.airstrike = {
    -- Outside a match there is nothing to hit; a dev session (typed facts, for
    -- walking the app) is never refused for it. A spot off the play area is
    -- refused before anything is spent.
    refuse = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        local at = opts and opts.at
        if at and not inPlay(at.x, at.y) then return 'strike_spot' end
        return nil
    end,
    run = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Airstrike ran on the dev terminal '
                    .. 'with no match to strike'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local at = opts and opts.at
        if not at then return { ok = false, code = 'bad_option' } end
        if not inPlay(at.x, at.y) then return { ok = false, code = 'strike_spot' } end
        local F = fx()
        local now = GetGameTimer()
        strikeSeq = strikeSeq + 1
        local startsAt = now + math.floor(tonumber(F.strikeWarnMs) or 10000)
        local s = {
            id = strikeSeq, by = src, squad = key, x = at.x + 0.0, y = at.y + 0.0,
            r = tonumber(F.strikeRadiusM) or 40.0, warnAt = now, startsAt = startsAt,
            rockets = TS.strikePlan(math.random, at.x, at.y, F, startsAt),
        }
        s.endsAt = s.rockets[#s.rockets].at
        strikesOf(m)[s.id] = s
        for _, rk in ipairs(s.rockets) do
            SetTimeout(math.max(0, rk.at - now), function() T.stepStrike(m, s, GetGameTimer()) end)
        end
        local runner = BR.Roster.get(src)
        print(('[br_core] terminals: Airstrike by %s (%d) on (%.1f, %.1f) in match %s: %d rockets from %.1f s')
            :format(runner and runner.name or '?', src, s.x, s.y, tostring(m.id), #s.rockets,
                (startsAt - now) / 1000))
        -- THE WARNING, TO EVERYBODY, after "has redeemed their special power:
        -- Airstrike..."; the persistent notices follow at once (the door).
        return { ok = true, code = 'done', after = function()
            local p = payloadOf(m, s)
            for _, to in ipairs(T.lobbyOf(m)) do
                TriggerClientEvent(BR.Net.TERMINAL_STRIKE, to, p)
            end
        end }
    end,
}

-- THE PERSISTENT NOTICE: every player in the fight within a strike's reach,
-- from its warning to its last rocket -- the runner's squad included, never
-- the runner (their own run).
T.impactSource(function(m, now, add)
    local list = m.terminalFx and m.terminalFx.strikes
    if not list or next(list) == nil then return end
    for _, s in pairs(list) do
        if not s.over and now < s.endsAt then
            local reach = reachOf(s)
            BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
                if src == s.by or not e.pos then return end
                local dx, dy = e.pos.x - s.x, e.pos.y - s.y
                if dx * dx + dy * dy <= reach * reach then add(src, 'impact_airstrike', s.endsAt) end
            end)
        end
    end
end)

-- A client that restarts during a strike is shown it again.
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() then return end
    local m = T.whereIs(src)
    for _, s in ipairs(T.strikesLive(m)) do
        TriggerClientEvent(BR.Net.TERMINAL_STRIKE, src, payloadOf(m, s))
    end
end)

-- ═══ THE ROUGH CIRCLES WHILE THE SPOT IS PICKED ═══

--- Whose map pick is showing them: [src] = { session, untilAt }.
local picking = {}
--- [src] = GetGameTimer() of the last pick start taken.
local lastPickAt = {}

--- The rough circles `src` is shown now: every opponent standing, downed or in
--- the air with a position, but a squad under Ghost; none at all while their
--- own squad has Scan running. Each offset is drawn once a match, per runner
--- and opponent. Public so the suites can read it.
--- @param src integer
--- @return table[] { { s, x, y, r } }
function T.fuzzFor(src)
    local m, _, key = T.whereIs(src)
    if not m then return {} end
    local st = T.fxOf(m)
    if st.scans and st.scans[key] then return {} end
    local F = fx()
    local now = GetGameTimer()
    st.fuzz = st.fuzz or {}
    local mine = st.fuzz[src] or {}
    st.fuzz[src] = mine
    local list = {}
    BR.Roster.each(function(o) return o.matchId == m.id end, function(s, o)
        local theirs = TS.squadKey(o, s)
        if theirs == key or not T.marked(o.state) or not o.pos then return end
        if T.hidden and T.hidden(m, theirs, now) then return end
        local off = mine[s]
        if not off then
            local dx, dy = TS.fuzzOffset(math.random, F.fuzzMinM, F.fuzzMaxM)
            off = { dx = dx, dy = dy }
            mine[s] = off
        end
        list[#list + 1] = { s = s, x = o.pos.x + off.dx, y = o.pos.y + off.dy,
                            r = tonumber(F.fuzzRadiusM) or 100.0 }
    end)
    table.sort(list, function(a, b) return a.s < b.s end)
    return list
end

--- The pick is over for `src`: their circles go.
local function stopPick(src)
    if not picking[src] then return end
    picking[src] = nil
    TriggerClientEvent(BR.Net.TERMINAL_FUZZ, src, { list = {} })
end

--- Send `src` their circles, or end the pick: the session gone or another, the
--- time up, Season 2 over. Public so the suites can step it.
--- @param src integer
function T.pushFuzz(src)
    local p = picking[src]
    if not p then return end
    if not on() or T.session(src) ~= p.session or GetGameTimer() >= p.untilAt then
        stopPick(src)
        return
    end
    TriggerClientEvent(BR.Net.TERMINAL_FUZZ, src, { list = T.fuzzFor(src) })
end

--- Is `src`'s map pick showing them circles? For the suites.
--- @param src integer
--- @return boolean
function T.fuzzing(src)
    return picking[src] ~= nil
end

RegisterNetEvent(BR.Net.TERMINAL_PICK)
AddEventHandler(BR.Net.TERMINAL_PICK, function(d)
    local src = tonumber(source)
    if not src or type(d) ~= 'table' then return end
    -- AN END IS ALWAYS TAKEN.
    if d.on ~= true then
        stopPick(src)
        return
    end
    if not on() then return end
    local now = GetGameTimer()
    local last = lastPickAt[src]
    if last ~= nil and now - last < (BR.Config.Terminals.runMinIntervalMs or 500) then return end
    lastPickAt[src] = now
    -- ONLY INSIDE THE SESSION ON THAT TERMINAL, FOR A ROW THAT HAS THEM, FROM A
    -- PLAYER WHO COULD RUN IT NOW AND AFFORD IT.
    local session = T.session(src)
    if not session or d.terminalId ~= session.terminalId then return end
    local row = T.row(d.functionId)
    if not row or row.fuzz ~= true then return end
    if T.refusalOf(src, session, row) ~= nil then return end
    if T.balance(src, session) < T.costOf(row) then return end
    picking[src] = { session = session, untilAt = now + math.floor(tonumber(fx().fuzzMaxMs) or 120000) }
    T.pushFuzz(src)
end)

if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().fuzzPingMs or 2000, 'terminal.fuzz', function()
        if next(picking) == nil then return end
        for src in pairs(picking) do T.pushFuzz(src) end
    end)
end

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end
    picking[src] = nil
    lastPickAt[src] = nil
end)

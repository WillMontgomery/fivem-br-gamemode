-- Server debug and admin commands.
--
-- These print to the server console. They are registered restricted, so from a
-- live client they need the `br.admin` ACE; typed at the server CLI they always
-- work, because console commands run as source 0.
--
-- Grant in server.cfg with:   add_ace group.admin br.admin allow
--
-- The guiding idea: every one of these answers a question you will actually ask
-- at 2am ("why did that player not die", "which job is eating the tick"), and
-- prints enough context to answer it without adding more prints and restarting.

local RESTRICTED = true

-- ------------------------------------------------------------- formatting ---

local function line(ch)
    print(string.rep(ch or '-', 78))
end

local function header(title)
    line('=')
    print(('  %s'):format(title))
    line('=')
end

--- Print an aligned table. `cols` is an array of { title, width, key }.
local function grid(cols, rows)
    local head, sep = {}, {}
    for _, c in ipairs(cols) do
        head[#head + 1] = ('%-' .. c.width .. 's'):format(c.title)
        sep[#sep + 1]   = string.rep('-', c.width)
    end
    print(table.concat(head, ' '))
    print(table.concat(sep, ' '))

    if #rows == 0 then
        print('  (none)')
        return
    end
    for _, r in ipairs(rows) do
        local out = {}
        for _, c in ipairs(cols) do
            local v = r[c.key]
            if type(v) == 'number' and v ~= math.floor(v) then
                v = ('%.3f'):format(v)
            end
            out[#out + 1] = ('%-' .. c.width .. 's'):format(tostring(v == nil and '-' or v))
        end
        print(table.concat(out, ' '))
    end
end

local function secs(ms)
    if not ms or ms <= 0 then return '-' end
    return ('%.1fs'):format(ms / 1000.0)
end

-- ---------------------------------------------------------------- commands ---

RegisterCommand('brscatter', function(_, args)
    -- THE GATE FOR MILESTONE 1 AND EVERY MILESTONE AFTER IT.
    --
    -- Scoping bugs are invisible with players stood together and total with
    -- players spread out. This drops everyone on a circle several kilometres
    -- across so nobody is in anyone else's scope, then reports what the server
    -- believes. Compare that against what each client's HUD shows: if the
    -- numbers disagree, roster data is leaking through scope somewhere.
    local radius = tonumber(args[1]) or 3000.0
    -- Centre on the newest match's anchor if one exists, else downtown LS.
    local latest = BR.Server.latestMatch()
    local anchor = (latest and latest.anchor) or { x = -300.0, y = -800.0 }

    local players, i = {}, 0
    for src in pairs(BR.Server.roster) do players[#players + 1] = src end
    table.sort(players)

    if #players == 0 then
        print('  nobody connected to scatter')
        return
    end

    header(('scatter test -- %d players onto a %.0fm circle'):format(#players, radius))

    for _, src in ipairs(players) do
        local theta = (i / #players) * 2.0 * math.pi
        local x = anchor.x + math.cos(theta) * radius
        local y = anchor.y + math.sin(theta) * radius
        i = i + 1

        TriggerClientEvent('br:debug:teleport', src, x, y)

        local p = BR.Server.roster[src]
        print(('  %-3d %-18s -> %.0f, %.0f'):format(src, p and p.name or '?', x, y))
    end

    print('')
    print(('  server believes: %d connected, %d alive, %d squads up')
        :format(BR.Server.count(), BR.Server.aliveCount(), BR.Server.squadsAlive()))
    print('  Now check every client HUD shows the same alive count, and that')
    print('  each one still sees the others join/leave. Any disagreement means')
    print('  roster data is being derived from scope somewhere.')
end, RESTRICTED)

RegisterCommand('brhelp', function()
    header('FiveM Royale - server commands')
    print('  brstate              match state, mode, timings, counts')
    print('  brroster [alive]     every player the server knows about')
    print('  brsquads             squad membership and who is still up')
    print('  brstorm              storm record plus the solved circle right now')
    print('  brstormfreeze [off]  hold the wall where it is: no phases, no')
    print('                       damage, for as long as you like (dev mode)')
    print('  brwarmupfreeze [off] hold the match on the warmup pad: the')
    print('                       departure timer stops and the bus does not')
    print('                       come, so a warmup-filed incident can be')
    print('                       reproduced on demand (dev mode)')
    print('  brperf [reset]       scheduler job cost, most expensive first')
    print('  brjob <on|off> <n>   enable or disable a scheduler job by name')
    print('  brconfig             the tunables that most often explain odd behaviour')
    print('  brwhy <id>           why is this player in the state they are in')
    print('  brartifacts          incident screenshots: taken, stored, refused')
    print('  brstrips             unissued weapons taken out of hands, and')
    print('                       how many reports were refused and why')
    print('  brvehicles           refused vehicles seen in matches: what was')
    print('                       counted, what the engine placed, and which')
    print('                       models the allowlist did not name')
    print('  brloot [matchId]     world loot: counts by kind and rarity, subscriptions')
    print('  brlootnear <id> [r]  every entry within r (50m) of that player, and')
    print('                       whether the claim path would accept it: the')
    print('                       registry position, reach, and whether a repair')
    print('                       would land. The reader for "that crate will')
    print('                       not open".')
    print('  brlootsim [n] [tier] roll the crate table n times and print the')
    print('                       distribution -- including the share of crates')
    print('                       that hold a gun. Retune loot without playing.')
    print('  brinv <id>           one player\'s inventory, slot by slot')
    print('  brweapons [filter]   list every grantable item id')
    print('  brarm <id|all> <item> [rarity]  weapon + FULL reserve (dev mode)')
    print('  brgive <id> <item> [n]  put an item straight into a player\'s hands')
    print('  brcrate <id> [item]  drop a crate (or one item) at a player\'s feet')
    print('  brlootseed <n|off>   pin the loot layout so it repeats between matches')
    print('  brdbno               every downed player: time left, knocker, reviver')
    print('  brdown <id> [by]     knock a player down; says WHY when it refuses')
    print('  brrevive <id> [by]   pick a downed player back up')
    print('  brscatter [radius]   spread everyone out to test OneSync scoping')
    print('  brforce <state>      force a match state transition')
    print('  brskip               end the current timed state immediately')
    line('-')
    print('  Client-side (run in the F8 console): brnativecheck, brperf, brloop, brfx,')
    print('    brboot, brblack, brfocus, brshield [0-100], brleave (leave the match),')
    print('    brdbno (what THIS client believes about being down, plus which')
    print('    crawl the build actually resolved),')
    print('    brcratehold <ms> (crate hold duration, live -- brloot shows the')
    print('    hold counting up and whether the key is actually down),')
    print('    brdriveby [s] (why a passenger cannot fire: seat, what the')
    print('    ENGINE has in your hands frame by frame, and whether anything')
    print('    disabled a trigger control -- #197),')
    print('    brloot (what this client can see, what it is OFFERING you and')
    print('    what else is in reach), brlootblips (dev: blip every')
    print('    item in scope), brpois (blip EVERY point of interest, map-wide,')
    print('    coloured by tier with its radius shaded), brpromptcheck,')
    print('    brprobe (what the natives actually do -- run "brprobe" alone')
    print('    for the list)')
    print('  Hitching? brhitch is the one to reach for: it reports the FRAME')
    print('    TIME DISTRIBUTION, which is the only thing that can see a stall')
    print('    an average hides. "brhitch reset", play 30s, "brhitch". If the')
    print('    tail buckets fill but no br_core callback is named, the stall is')
    print('    not ours. Then brperf for per-callback totals, and')
    print('    "brloop off <name>" to bisect.')
end, RESTRICTED)

RegisterCommand('brstate', function()
    header('match state')
    local any = false
    BR.Server.eachMatch(function(m)
        any = true
        print(('  match %-4d %-8s %-6s bucket %-5d players %-3d alive %-3d squads %-3d endsAt %s')
            :format(m.id, m.state, m.mode, m.bucket,
                    BR.Server.countIn(m), BR.Server.aliveCount(m),
                    BR.Server.squadsAlive(m),
                    m.endsAt > 0 and secs(m.endsAt - GetGameTimer()) or '-'))
    end)
    if not any then print('  (no match instances -- lobby is WAITING)') end
    line('-')
    print(('  minted ids   %d'):format(BR.Server.matchId))
    print(('  devMode      %s'):format(tostring(BR.Server.devMode)))
    print(('  onesync      %s%s'):format(
        tostring(BR.Server.onesync),
        (BR.Server.onesync == 'off' or BR.Server.onesync == '')
            and '   <- server cannot see player entities' or ''))

    -- How many players the server can actually resolve a ped for. If this is
    -- below the connected count while a match is running, everything that
    -- depends on positions is silently doing nothing.
    local withPed = BR.Server.count(function(p) return p.ped and p.ped ~= 0 end)
    print(('  peds visible %d of %d'):format(withPed, BR.Server.count()))
    line('-')
    print(('  connected    %d'):format(BR.Server.count()))
    print(('  alive        %d'):format(BR.Server.aliveCount()))
    print(('  squads up    %d'):format(BR.Server.squadsAlive()))
    print(('  min to start %d'):format(BR.Config.Match.MinPlayers(BR.Server.devMode)))
end, RESTRICTED)

RegisterCommand('brroster', function(_, args)
    local aliveOnly = args[1] == 'alive'
    header(aliveOnly and 'roster (alive only)' or 'roster')

    local rows = {}
    for src, p in pairs(BR.Server.roster) do
        local living = p.state ~= BR.PlayerState.DEAD
                   and p.state ~= BR.PlayerState.LEFT
                   and p.state ~= BR.PlayerState.SPECTATING
        if not aliveOnly or living then
            rows[#rows + 1] = {
                src    = src,
                name   = (p.name or '?'):sub(1, 18),
                squad  = p.squadId or '-',
                state  = p.state,
                hp     = p.hp and ('%.0f'):format(p.hp) or '-',
                arm    = p.armour and ('%.0f'):format(p.armour) or '-',
                kills  = p.kills or 0,
                place  = p.placement or '-',
                pos    = p.pos and ('%.0f,%.0f'):format(p.pos.x, p.pos.y) or '-',
            }
        end
    end
    table.sort(rows, function(a, b) return a.src < b.src end)

    grid({
        { title = 'id',    width =  4, key = 'src'   },
        { title = 'name',  width = 18, key = 'name'  },
        { title = 'squad', width =  6, key = 'squad' },
        { title = 'state', width = 11, key = 'state' },
        { title = 'hp',    width =  4, key = 'hp'    },
        { title = 'arm',   width =  4, key = 'arm'   },
        { title = 'k',     width =  3, key = 'kills' },
        { title = 'plc',   width =  4, key = 'place' },
        { title = 'pos',   width = 14, key = 'pos'   },
    }, rows)

    print(('  %d shown, %d alive, %d squads up')
        :format(#rows, BR.Server.aliveCount(), BR.Server.squadsAlive()))
end, RESTRICTED)

--- Squad membership, BUILT FROM THE ROSTER.
---
--- It used to walk `BR.Server.squads`, a table that has not been written to
--- since parties took over squad formation: BR.Party.formSquads stamps
--- `squadId` onto each roster entry and keeps its working list local. So this
--- iterated an empty table and printed "(no squads)" through every squad match
--- ever played -- while the squads themselves were completely fine (owner, in
--- game, 2026-08-09). The field is gone now; the roster is the source of truth
--- for this exactly as it is for everything else, and a debug command that
--- reads a cache nobody fills is worse than no command at all, because it
--- answers confidently.
RegisterCommand('brsquads', function()
    header('squads')

    -- Grouped in one pass, then sorted, so the output is stable between runs.
    local bySquad, ids = {}, {}
    BR.Roster.each(
        function(e) return e.squadId ~= nil end,
        function(src, e)
            local g = bySquad[e.squadId]
            if not g then
                g = {}
                bySquad[e.squadId] = g
                ids[#ids + 1] = e.squadId
            end
            g[#g + 1] = { src = src, e = e }
        end)
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)

    for _, id in ipairs(ids) do
        local members = bySquad[id]
        table.sort(members, function(a, b) return a.src < b.src end)

        local names, standing = {}, 0
        for _, m in ipairs(members) do
            if BR.Server.isInMatch(m.e.state) then standing = standing + 1 end
            names[#names + 1] = ('%s(%d,%s)'):format(m.e.name, m.src, m.e.state)
        end

        print(('  [%s] match %s  %d/%d still in'):format(
            tostring(id), tostring(members[1].e.matchId), standing, #members))
        print(('      %s'):format(table.concat(names, ', ')))
    end

    if #ids == 0 then
        -- ...and SAY WHY, because "(no squads)" was the line that sent somebody
        -- looking for a formation bug that did not exist.
        print('  (no squads -- squadIds are stamped at WARMUP by BR.Party.formSquads,')
        print('   and solo matches never have any: every player is their own team)')
    end

    -- AND THE SHAPE, PER MATCH, IN THE SAME WORDS THE FORMATION USED.
    --
    -- The listing above answers "who is on whose team" and says nothing about
    -- the question that actually brings somebody here: three clients in one
    -- squad, and is that the squad size or is it me. This is the command whose
    -- name a person guesses for that, so it carries the live cap and the source
    -- it came from -- the same two facts `brconfig` has, at the moment they are
    -- being doubted. See BR.Party.formationReport.
    if BR.Server.eachMatch then
        BR.Server.eachMatch(function(m)
            line('-')
            print(('  match %d (%s)'):format(m.id, tostring(m.state)))
            for _, l in ipairs(BR.Party.formationReport(m)) do print('  ' .. l) end
        end)
    end
end, RESTRICTED)

RegisterCommand('brstorm', function()
    header('storm')
    local latest = BR.Server.latestMatch()
    local rec = latest and latest.storm
    if not rec then
        print('  no storm record -- no match is in a storm phase')
        return
    end
    print(('  match        %d'):format(latest.id))

    print(('  phase        %d of %d'):format(rec.phase, #BR.Config.Storm.phases))
    print(('  from         (%.0f, %.0f) r=%.0f'):format(rec.cx0, rec.cy0, rec.r0))
    print(('  to           (%.0f, %.0f) r=%.0f'):format(rec.cx1, rec.cy1, rec.r1))
    print(('  dps          %.1f'):format(rec.dps))

    local now = GetGameTimer()
    local cx, cy, r, state, left = BR.StormAt(rec, now)
    line('-')
    print(('  solved now   centre (%.0f, %.0f) radius %.0f'):format(cx, cy, r))
    print(('  sub-state    %s, %s remaining'):format(state, secs(left)))

    -- The containment invariant, checked live rather than assumed. If this ever
    -- prints CONTAINMENT VIOLATED, players are taking storm damage unfairly.
    local slop = BR.Dist(rec.cx0, rec.cy0, rec.cx1, rec.cy1) + rec.r1 - rec.r0
    if slop > 0.001 then
        print(('  !! CONTAINMENT VIOLATED by %.1f units -- next circle escapes the current one')
            :format(slop))
    else
        print(('  containment  ok (%.0f units of margin)'):format(-slop))
    end

    -- Who is currently outside, and by how much.
    local outside = {}
    for src, p in pairs(BR.Server.roster) do
        if p.pos and p.state == BR.PlayerState.ALIVE then
            local d = BR.EdgeDistance(p.pos.x, p.pos.y, cx, cy, r)
            if d > 0 then
                outside[#outside + 1] = { src = src, name = p.name, dist = ('%.0f'):format(d) }
            end
        end
    end
    line('-')
    print(('  outside the circle: %d'):format(#outside))
    grid({
        { title = 'id',   width =  4, key = 'src'  },
        { title = 'name', width = 18, key = 'name' },
        { title = 'm out',width =  8, key = 'dist' },
    }, outside)
end, RESTRICTED)

RegisterCommand('brperf', function(_, args)
    if args[1] == 'reset' then
        BR.Sched.resetStats()
        print('[br_core] scheduler stats reset')
        return
    end

    header('scheduler jobs (most expensive first)')
    local rows = {}
    for _, s in ipairs(BR.Sched.stats()) do
        rows[#rows + 1] = {
            name   = s.name,
            every  = s.intervalMs .. 'ms',
            calls  = s.calls,
            avg    = ('%.3f'):format(s.avgMs),
            peak   = ('%.3f'):format(s.peakMs),
            total  = ('%.1f'):format(s.totalMs),
            errors = s.errors,
            status = s.suspended and 'SUSPENDED' or (s.enabled and 'ok' or 'off'),
        }
    end
    grid({
        { title = 'job',    width = 24, key = 'name'   },
        { title = 'every',  width =  7, key = 'every'  },
        { title = 'calls',  width =  7, key = 'calls'  },
        { title = 'avg ms', width =  8, key = 'avg'    },
        { title = 'peak',   width =  8, key = 'peak'   },
        { title = 'tot ms', width =  8, key = 'total'  },
        { title = 'err',    width =  4, key = 'errors' },
        { title = 'status', width =  9, key = 'status' },
    }, rows)
    print('  "brperf reset" clears the window before a measurement')
end, RESTRICTED)

RegisterCommand('brjob', function(_, args)
    local action, name = args[1], args[2]
    if not action or not name then
        print('  usage: brjob <on|off> <jobName>   (see brperf for names)')
        return
    end
    local enable = (action == 'on' or action == 'enable' or action == 'true')
    if BR.Sched.setEnabled(name, enable) then
        print(('[br_core] job "%s" %s'):format(name, enable and 'enabled' or 'disabled'))
    else
        print(('[br_core] no such job: %s'):format(name))
    end
end, RESTRICTED)

RegisterCommand('brconfig', function()
    header('config (the values that most often explain odd behaviour)')
    local M, S, L = BR.Config.Match, BR.Config.Storm, BR.Config.Loot
    print(('  maxPlayers        %d      minToStart %d (dev) / %d (prod)')
        :format(M.maxPlayers, M.minToStart, M.minToStartProd))
    print(('  health            engine %d..%d, display 0..100, armour cap %d')
        :format(M.healthFloor, M.maxHealth, M.maxArmour))
    print(('  dbno              bleed %ds, revive %.1fs within %.1fm, revive to %d hp')
        :format(M.dbnoBleedBase, M.dbnoReviveTime, M.dbnoReviveDist, M.dbnoReviveHp))
    print(('  storm             r0=%.0f, %d phases, ~%.0f min total, edgeBias %.2f')
        :format(S.radius0, #S.phases, S.TotalSeconds() / 60.0, S.edgeBiasMax))
    print(('  loot              %d POI items + %d filler, cell %.0fm, props %.0fm, pickup %.1fm')
        :format(BR.Config.TotalLootBudget(), L.filler and L.filler.count or 0,
                L.cellSize, L.propDistance, L.pickupDistance))
    print(('  inventory         %d slots, %d clip(s) of reserve per weapon found')
        :format(L.slots, L.weaponReserveClips))
    print(('  render ceiling    424 units -- entities beyond this are not drawn'))

    -- THE TUNABLES, AND WHICH SIDE OF THE SPLIT EACH VALUE CAME FROM.
    --
    -- Everything above is one number with one home. These have two -- the
    -- committed default and whatever .cfg this box exec'd -- so the report is
    -- worthless unless it says which one is live. It reads the values out of
    -- BR.Config itself, so it cannot report an override that did not land.
    --
    -- CHANGING ONE NEEDS A RESTART. They are read while br_lib/config loads;
    -- `set br_maxSquadSize 2` typed here does nothing until then, which the
    -- late-arrival warning in server/main.lua will say out loud.
    line('-')
    local tune, overridden = BR.Config.Overrides.report()
    print(('  tunables          %d of %d set by convar (see tunables.cfg; restart to change)')
        :format(overridden, #BR.Config.Overrides.SPEC))
    for _, l in ipairs(tune) do print(l) end
end, RESTRICTED)

RegisterCommand('brloot', function(_, args)
    local wanted = tonumber(args[1])

    local any = false
    BR.Server.eachMatch(function(m)
        if wanted and m.id ~= wanted then return end
        any = true

        if not m.loot then
            print(('  match %d: no loot (state %s)'):format(m.id, m.state))
            return
        end

        header(('loot -- match %d, seed %d'):format(m.id, m.loot.seed))

        local byKind, byRarity, cells, total = {}, {}, 0, 0
        for _, e in pairs(m.loot.items) do
            total = total + 1
            byKind[e.kind] = (byKind[e.kind] or 0) + 1
            byRarity[e.rarity or 1] = (byRarity[e.rarity or 1] or 0) + 1
        end
        for _ in pairs(m.loot.cells) do cells = cells + 1 end

        print(('  %d items live across %d cells'):format(total, cells))

        -- Fixed orders, not pairs(): a debug dump that reorders itself between
        -- runs is one you cannot diff against the last one.
        local kinds = { BR.ItemKind.WEAPON, BR.ItemKind.AMMO,
                        BR.ItemKind.CONSUMABLE, BR.ItemKind.THROWABLE,
                        'chest', 'deathbox' }
        local parts = {}
        for _, k in ipairs(kinds) do
            parts[#parts + 1] = ('%s %d'):format(k, byKind[k] or 0)
        end
        print('  by kind:   ' .. table.concat(parts, '   '))

        parts = {}
        for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
            parts[#parts + 1] = ('%s %d')
                :format(BR.RarityInfo[r].key, byRarity[r] or 0)
        end
        print('  by rarity: ' .. table.concat(parts, '   '))

        local subs = {}
        for src, keys in pairs(m.loot.subs) do
            local n = 0
            for _ in pairs(keys) do n = n + 1 end
            subs[#subs + 1] = ('%d(%d cells)'):format(src, n)
        end
        table.sort(subs)
        print('  subscribed: ' .. (#subs > 0 and table.concat(subs, ' ') or 'nobody'))
    end)

    if not any then print('  no matches running') end
end, RESTRICTED)

--- One player, the loot around them, and why each piece of it will or will not
--- open.
---
---   brlootnear <serverId> [radius]      radius defaults to 50m
---
--- WHAT brloot CANNOT ANSWER. It counts by kind and rarity, which settles "is
--- the layout right" and says nothing at all about any single entry -- so "I am
--- stood in front of that crate and it says Too far away" had no reading on
--- this box short of adding prints to server/loot.lua and restarting (#195).
--- An entity-specific bug needs a per-entity instrument.
---
--- IT RUNS THE REAL CHECKS. BR.Loot.inspect calls the same inReach the claim
--- handler calls and the same fixOk the repair handler calls, on the same
--- roster entry, so the `reach` column is not a model of the refusal -- it IS
--- the refusal. Anything else would be a second opinion, and a second opinion
--- is worthless against a bug whose entire nature is two positions disagreeing.
---
--- THE COLUMN TO READ FIRST IS `at`. Every other symptom follows from it: the
--- server validates a claim against the REGISTRY position printed there, and
--- the client prompts off its own mirror of the entry, which it slaves to the
--- prop. Those are the same place right up until they are not.
RegisterCommand('brlootnear', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brlootnear <serverId> [radius]')
        print('    every loot entry the server has within radius (default 50m)')
        print('    of that player, and whether the claim path would accept it')
        return
    end

    local radius = math.max(1.0, math.min(1000.0, tonumber(args[2]) or 50.0))
    local rows, info = BR.Loot.inspect(src, radius)

    local p = BR.Server.roster[src]
    header(('loot near %s (%d)'):format(p and p.name or '?', src))

    if info and info.why then
        print(('  %s'):format(info.why))
        return
    end
    if not info then
        print(('  no roster entry for %d'):format(src))
        return
    end

    print(('  zone           %s'):format(
        info.warmup and 'the shared warmup pad' or ('match ' .. tostring(info.zone))))
    print(('  state          %s   may take: %s'):format(
        tostring(info.state), info.canTake and 'yes' or 'NO'))
    print(('  position       %s%s'):format(
        info.pos and ('%.1f, %.1f, %.1f'):format(info.pos.x, info.pos.y, info.pos.z)
                 or 'not sampled yet',
        info.posAgeMs and ('   (sampled %s ago)'):format(secs(info.posAgeMs)) or ''))
    print(('  refuses past   %.1fm, and past %.1fm of height once repaired')
        :format(info.reachMax, info.reachZ))
    print(('  repairs        accepted within %.1fm, at most once per %s per container')
        :format(info.fixRadius, secs(info.fixCool)))

    if not rows then
        print('  no position sampled for this player, so nothing can be tested')
        return
    end

    print(('  %d of %d entries in this zone are within %.0fm')
        :format(#rows, info.total, radius))
    line('-')

    -- Nearest first, and capped: a landing at a dense POI has a hundred
    -- entries in range and the answer is always in the first few.
    local shown = {}
    for i = 1, math.min(#rows, 24) do
        local r = rows[i]
        shown[#shown + 1] = {
            id    = r.id,
            kind  = r.kind,
            item  = r.item or '-',
            at    = ('%.0f,%.0f'):format(r.x, r.y),
            dist  = ('%.1f'):format(r.d),
            dz    = ('%.1f'):format(r.dz),
            rep   = r.repaired and 'yes' or 'no',
            fixed = r.fixAgeMs and ('%.1fs'):format(r.fixAgeMs / 1000.0) or '-',
            sub   = r.subbed and 'yes' or 'NO',
            reach = r.reach and 'yes' or 'NO',
            fix   = r.fix and 'yes' or (r.fixWhy or '?'),
        }
    end

    grid({
        { title = 'id',    width = 5,  key = 'id' },
        -- 10, because 'consumable' is 10 and a kind that overflows its column
        -- pushes every field after it out of line for that row only -- which
        -- is the one row you were reading.
        { title = 'kind',  width = 10, key = 'kind' },
        { title = 'item',  width = 12, key = 'item' },
        { title = 'at',    width = 15, key = 'at' },
        { title = 'dist',  width = 6,  key = 'dist' },
        { title = 'dz',    width = 6,  key = 'dz' },
        { title = 'rep',   width = 3,  key = 'rep' },
        { title = 'fixed', width = 6,  key = 'fixed' },
        { title = 'sub',   width = 3,  key = 'sub' },
        { title = 'reach', width = 5,  key = 'reach' },
        { title = 'fix',   width = 12, key = 'fix' },
    }, shown)

    if #rows > #shown then
        print(('  ... and %d more, nearest first'):format(#rows - #shown))
    end

    -- WHAT THE GRID MEANS, for the two shapes this was built to tell apart.
    -- Both look identical from a chair -- a crate you are stood in front of
    -- that will not open -- and they have different fixes, so the reading is
    -- spelled out rather than left to be inferred from ten columns.
    line('-')
    local said = false
    for _, r in ipairs(rows) do
        if not r.reach and r.d > info.reachMax then
            -- Refused on 2D distance. Whether it can ever recover is the whole
            -- question: an entry that cannot be re-anchored either is stuck
            -- there, and that is the shape being hunted.
            print(('  #%d (%s) is %.1fm away IN THE REGISTRY, at %.1f, %.1f.')
                :format(r.id, r.kind, r.d, r.x, r.y))
            if r.fixWhy == 'too far' then
                print('    A repair from where this player stands is refused as')
                print(('    well, being past the %.0fm bound. If they are stood at')
                    :format(info.fixRadius))
                print('    the crate, the registry has stopped following the prop')
                print('    and cannot catch up.')
            elseif not r.fix then
                -- Some other rule refused the repair, and saying "cannot catch
                -- up" here would be a diagnosis rather than a reading: a
                -- cooldown clears on its own and an unsubscribed cell is the
                -- ordinary state of anything a couple of hundred metres off.
                print(('    A repair is refused right now: %s.'):format(r.fixWhy))
            end
            said = true
        elseif not r.reach and r.repaired then
            -- Inside the 2D bound and repaired, so inReach can only have
            -- refused on height.
            print(('  #%d (%s) is %.1fm away but %.1fm of height from this player,')
                :format(r.id, r.kind, r.d, math.abs(r.dz)))
            print(('    and it is repaired, so the %.1fm height check applies.')
                :format(info.reachZ))
            said = true
        elseif not r.reach then
            -- Neither clause explains it. Says so rather than guessing: a
            -- reader who is told a reason that is not the reason is worse off
            -- than one who is told the rule moved.
            print(('  #%d (%s) is %.1fm away and unreachable for a reason neither')
                :format(r.id, r.kind, r.d))
            print('    the distance nor the height clause accounts for.')
            said = true
        end
    end
    if not said then
        print('  Every entry listed would be accepted from where this player is.')
        print('  If a crate is refusing, its registry position is further than')
        print(('    %.0fm away -- re-run with a bigger radius.'):format(radius))
    end
end, RESTRICTED)

--- Roll the crate table N times and print what came out.
---
---   brlootsim [crates] [tier] [seed]
---
--- THE ANSWER TO "IS THERE ENOUGH GUN IN THE CRATES", WITHOUT OPENING A HUNDRED
--- OF THEM. #127 was reported from a single match -- "disproportionately more
--- ammo/medkits than weapons" -- and the only way to check the fix, or any
--- future retune, was to go and play another one. That is a slow loop for a
--- table that is four numbers, and it is a loop that cannot tell a real shift
--- from a run of bad luck.
---
--- This rolls the SAME function the layout generator rolls (BR.LootChestContents,
--- including the one-tier-hotter bump crates get), so it is not a model of the
--- loot table -- it is the loot table.
---
--- The headline is the last line of each block: the share of crates holding at
--- least one FIREARM. Per-item percentages are interesting, but a player does
--- not experience percentages, they experience opening a box and finding no gun
--- in it.
---
--- RESTRICTED rather than dev-mode-only, like brloot and brconfig above: it
--- reads nothing about any player, changes nothing, and spawns nothing. The
--- commands wearing devOnly are the ones that hand out gear.
RegisterCommand('brlootsim', function(_, args)
    local crates = math.tointeger(math.floor(tonumber(args[1]) or 20000))
    local tierArg = math.tointeger(math.floor(tonumber(args[2]) or 0))
    -- A FIXED DEFAULT SEED, so two runs either side of a config change differ
    -- because the config changed. Pass one to check the numbers are not an
    -- artefact of this particular sequence.
    local seed = math.tointeger(math.floor(tonumber(args[3]) or 1))

    if crates < 1 or crates > 2000000 then
        print('  usage: brlootsim [crates] [tier] [seed]   (1..2000000 crates)')
        return
    end

    header(('crate loot simulation -- %d crates/tier, seed %d'):format(crates, seed))

    local K = BR.Config.KindWeights
    local wsum = 0
    for _, k in ipairs(K) do wsum = wsum + k.weight end
    local parts = {}
    for _, k in ipairs(K) do
        parts[#parts + 1] = ('%s %.0f%%'):format(k.kind, k.weight / wsum * 100.0)
    end
    print('  kind weights:  ' .. table.concat(parts, '   '))
    print(('  melee is %.0f%% of the weapon rolls; a crate holds %d..%d items')
        :format((BR.Config.Loot.meleeChance or 0.0) * 100.0,
                BR.Config.Loot.chestItems.min, BR.Config.Loot.chestItems.max))

    local tiers = (tierArg >= 1 and tierArg <= 3) and { tierArg } or { 1, 2, 3 }

    for _, tier in ipairs(tiers) do
        local rng = BR.Rng(seed + tier)

        local items, byLabel = 0, {}
        local withFirearm, withAnyWeapon = 0, 0
        -- Fixed print order. A distribution dump that reorders itself between
        -- runs is one you cannot diff against the run before it.
        local order = { 'firearm', 'melee', 'ammo', 'consumable', 'throwable' }

        for _ = 1, crates do
            local contents = BR.LootChestContents(rng, tier)
            local gun, weapon = false, false
            for _, s in ipairs(contents) do
                items = items + 1

                local bucket
                if s.kind == BR.ItemKind.WEAPON then
                    weapon = true
                    local w = BR.Config.WeaponById[s.item]
                    if w and w.melee then
                        bucket = 'melee'
                    else
                        bucket = 'firearm'
                        gun = true
                    end
                elseif s.kind == BR.ItemKind.AMMO then
                    bucket = 'ammo'
                elseif s.kind == BR.ItemKind.CONSUMABLE then
                    bucket = 'consumable'
                else
                    bucket = 'throwable'
                end

                byLabel[bucket] = (byLabel[bucket] or 0) + 1
                -- Consumables are counted a second time by id: "medkits" is
                -- half of what was reported, and a lump labelled "consumable"
                -- cannot answer it.
                if s.kind == BR.ItemKind.CONSUMABLE then
                    local key = 'consumable:' .. s.item
                    byLabel[key] = (byLabel[key] or 0) + 1
                end
            end
            if gun then withFirearm = withFirearm + 1 end
            if weapon then withAnyWeapon = withAnyWeapon + 1 end
        end

        line('-')
        print(('  POI tier %d  (crates roll tier %d)   %d items, %.2f per crate')
            :format(tier, math.min(tier + 1, 3), items, items / crates))
        for _, k in ipairs(order) do
            local n = byLabel[k] or 0
            print(('    %-12s %8d   %5.1f%%   %.2f per crate')
                :format(k, n, n / items * 100.0, n / crates))
        end
        for _, c in ipairs(BR.Config.Consumables) do
            local n = byLabel['consumable:' .. c.id] or 0
            if n > 0 then
                print(('      %-10s %8d   %5.1f%%   1 per %.1f crates')
                    :format(c.id, n, n / items * 100.0, crates / n))
            end
        end

        local guns = byLabel.firearm or 0
        local support = (byLabel.ammo or 0) + (byLabel.consumable or 0)
        print(('    support:gun ratio %.2f:1  (ammo+consumables per firearm)')
            :format(guns > 0 and (support / guns) or 0.0))
        print(('    CRATES WITH A FIREARM: %.1f%%   with any weapon: %.1f%%')
            :format(withFirearm / crates * 100.0, withAnyWeapon / crates * 100.0))
    end
end, RESTRICTED)

RegisterCommand('brinv', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brinv <serverId>')
        return
    end
    local e = BR.Server.roster[src]
    if not e then
        print(('  no roster entry for %d'):format(src))
        return
    end

    local inv = BR.Inv.of(src)
    header(('inventory -- %s (%d)'):format(e.name or '?', src))
    for i = 1, BR.Config.Loot.slots do
        local s = inv.slots[i]
        local mark = (inv.active == i) and '>' or ' '
        if s then
            print(('  %s %d  %-16s %-11s %-9s x%-3d clip %s')
                :format(mark, i, s.item, s.kind,
                        BR.RarityInfo[s.rarity or 1].key, s.count,
                        tostring(s.clip or '-')))
        else
            print(('  %s %d  --'):format(mark, i))
        end
    end

    local parts = {}
    for _, pool in ipairs(BR.Config.AmmoOrder) do
        parts[#parts + 1] = ('%s %d/%d'):format(pool, inv.ammo[pool] or 0,
            BR.Config.AmmoCaps[pool] or 0)
    end
    print('  ammo: ' .. table.concat(parts, '  '))
    if inv.using then
        print(('  using slot %d (%s), %s left'):format(inv.using.slot,
            inv.using.item, secs(math.max(0, inv.using.endsAt - GetGameTimer()))))
    end
end, RESTRICTED)

--- Refuse a command unless the server was started in dev mode.
---
--- These hand out gear the loot table is deliberately stingy with, which makes
--- them a testing tool and nothing else. On a live server they would be a way
--- for anyone holding the console to arm a friend, so they are gated on the
--- same convar that already relaxes the minimum player count -- one switch for
--- "this box is not a real match", rather than a second thing to remember.
--- @param what string
--- @return boolean
local function devOnly(what)
    if BR.Server.devMode then return true end
    print(('  %s is dev-mode only. Start the server with br_devMode true '
        .. '(or sv_devMode true) to use it.'):format(what))
    return false
end

--- Resolve a target argument to a list of server ids: a number, or "all".
--- @param arg string|nil
--- @return table|nil
local function targets(arg)
    if arg == 'all' or arg == '*' then
        local out = {}
        BR.Roster.each(function(e) return e.state ~= BR.PlayerState.LEFT end,
            function(src) out[#out + 1] = src end)
        return out
    end
    local n = tonumber(arg)
    if not n then return nil end
    if not BR.Roster.get(n) then
        print(('  no roster entry for %d'):format(n))
        return {}
    end
    return { n }
end

RegisterCommand('brgive', function(_, args)
    if not devOnly('brgive') then return end
    local src  = tonumber(args[1])
    local item = args[2]
    local n    = tonumber(args[3]) or 1
    if not src or not item then
        print('  usage: brgive <serverId> <itemId> [count]')
        print('    itemId is a weapon/throwable id (carbinerifle), a consumable')
        print('    id (medkit), or an ammo pool (light|smg|medium|shells|heavy)')
        print('    brweapons lists every id; brarm is the one for testing guns')
        return
    end
    if not BR.Roster.get(src) then
        print(('  no roster entry for %d'):format(src))
        return
    end

    local stack
    local w = BR.Config.WeaponById[item]
    local c = BR.Config.ConsumableById[item]
    if w then
        stack = { item = item, rarity = w.rarity, count = n, clip = w.clip,
                  kind = w.clip and BR.ItemKind.WEAPON or BR.ItemKind.THROWABLE }
    elseif c then
        stack = { item = item, kind = BR.ItemKind.CONSUMABLE,
                  rarity = c.rarity, count = n }
    elseif BR.Config.AmmoPickups[item] then
        stack = { item = item, kind = BR.ItemKind.AMMO,
                  rarity = BR.Rarity.COMMON, count = n }
    else
        print(('  unknown item: %s'):format(item))
        return
    end

    local ok, displaced, reason = BR.Inv.give(src, stack)
    print(('  %s %s x%d -> %s%s'):format(ok and 'gave' or 'REFUSED', item, n, src,
        ok and (displaced and (' (displaced ' .. displaced.item .. ')') or '')
           or (' -- ' .. tostring(reason))))
end, RESTRICTED)

--- ARM A PLAYER FOR A TEST, in one command.
---
---   brarm <id|all> <itemId> [rarity]     a weapon, full reserve
---   brarm <id|all> <itemId> legendary
---
--- Exists because the loot table is intentionally stingy and the only other
--- way to get a specific gun in your hands was to find it (user, 2026-08-08:
--- "it's frustrating to test things like the weapons"). brgive puts one item
--- in a slot; this puts a weapon in your hands WITH the reserve topped to the
--- pool cap, which is what "let me actually shoot this" needs.
---
--- Rarity matters and is why it is an argument: every damage number in the
--- game runs through BR.RarityInfo[rarity].damageMult, so testing a carbine
--- means nothing without saying which carbine.
RegisterCommand('brarm', function(_, args)
    if not devOnly('brarm') then return end

    local who  = targets(args[1])
    local item = args[2]
    if not who or not item then
        print('  usage: brarm <serverId|all> <itemId> [common|uncommon|rare|epic|legendary]')
        print('    grants the weapon AND fills its ammo pool to the cap.')
        print('    brweapons lists every id.')
        return
    end
    if #who == 0 then return end

    local w = BR.Config.WeaponById[item]
    local c = BR.Config.ConsumableById[item]

    -- CONSUMABLES TOO. This refused them at first, which made the obvious
    -- follow-up to a damage test -- heal the ped back up -- impossible
    -- (user, 2026-08-08). A medkit is exactly as much "arm me for a test" as
    -- a rifle is.
    if not w and c then
        local n = tonumber(args[3]) or c.carryMax or c.maxStack or 1
        for _, src in ipairs(who) do
            local okGive, _, reason = BR.Inv.give(src, {
                item = item, kind = BR.ItemKind.CONSUMABLE,
                rarity = c.rarity, count = n,
            })
            print(('  %s %s x%d -> %d%s'):format(
                okGive and 'gave' or 'REFUSED', item, n, src,
                okGive and '' or (' -- ' .. tostring(reason))))
        end
        return
    end

    -- AMMO POOLS TOO, for the same reason.
    if not w and BR.Config.AmmoPickups[item] then
        for _, src in ipairs(who) do
            local okGive = BR.Inv.give(src, {
                item = item, kind = BR.ItemKind.AMMO,
                rarity = BR.Rarity.COMMON, count = tonumber(args[3]) or 1,
            })
            print(('  %s %s -> %d'):format(okGive and 'gave' or 'REFUSED',
                item, src))
        end
        return
    end

    if not w then
        print(('  %q is not a weapon, throwable, melee or consumable id '
            .. '-- try brweapons'):format(item))
        return
    end

    local rarity = w.rarity
    if args[3] then
        local byName = {
            common = BR.Rarity.COMMON, uncommon = BR.Rarity.UNCOMMON,
            rare = BR.Rarity.RARE, epic = BR.Rarity.EPIC,
            legendary = BR.Rarity.LEGENDARY,
        }
        rarity = byName[tostring(args[3]):lower()] or tonumber(args[3]) or rarity
    end

    local kind = BR.ItemKind.WEAPON
    if w.maxStack then kind = BR.ItemKind.THROWABLE end

    for _, src in ipairs(who) do
        local stack = {
            item = item, kind = kind, rarity = rarity,
            count = (kind == BR.ItemKind.THROWABLE) and (w.maxStack or 1) or 1,
            clip = w.clip,
        }
        local ok, _, reason = BR.Inv.give(src, stack)
        if ok and w.ammo then
            -- FULL RESERVE, not the one clip a found weapon comes with. The
            -- point of this command is to stop the test being about ammo.
            local inv = BR.Inv.of(src)
            if inv then
                inv.ammo[w.ammo] = BR.Config.AmmoCaps[w.ammo] or 200
                BR.Inv.push(src)
            end
        end
        local e = BR.Roster.get(src)
        print(('  %s %s (%s) -> %s (%d)%s'):format(
            ok and 'armed' or 'REFUSED', item,
            (BR.RarityInfo[rarity] or {}).label or tostring(rarity),
            e and e.name or '?', src,
            ok and '' or (' -- ' .. tostring(reason))))
    end
end, RESTRICTED)

--- Every id brgive/brarm will accept, so testing does not mean reading config.
---   brweapons            everything
---   brweapons sniper     only ids containing "sniper"
RegisterCommand('brweapons', function(_, args)
    local filter = args[1] and tostring(args[1]):lower() or nil
    local function show(list, what)
        local rows = {}
        for _, w in ipairs(list or {}) do
            if not filter or w.id:lower():find(filter, 1, true) then
                rows[#rows + 1] = ('    %-16s %-24s %s'):format(
                    w.id, w.label or '',
                    w.damage and ('dmg ' .. w.damage) or '')
            end
        end
        if #rows == 0 then return end
        print(('  %s'):format(what))
        for _, r in ipairs(rows) do print(r) end
    end
    header('grantable ids' .. (filter and (' matching "' .. filter .. '"') or ''))
    show(BR.Config.Weapons, 'firearms')
    show(BR.Config.Throwables, 'throwables')
    show(BR.Config.Melee, 'melee')
    show({ BR.Config.Fists }, 'always carried (not loot)')
    local cons = {}
    for _, c in ipairs(BR.Config.Consumables or {}) do
        if not filter or c.id:lower():find(filter, 1, true) then
            cons[#cons + 1] = c.id
        end
    end
    if #cons > 0 then
        print('  consumables')
        print('    ' .. table.concat(cons, ', '))
    end
    line('-')
    print('  brarm <id|all> <itemId> [rarity]   weapon + full reserve (dev mode)')
    print('  brgive <id> <itemId> [n]           one item into a slot (dev mode)')
end, RESTRICTED)

RegisterCommand('brwhy', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brwhy <serverId>')
        return
    end
    local p = BR.Server.roster[src]
    if not p then
        print(('  no roster entry for %d -- they are not connected, or joined before the resource started'):format(src))
        return
    end

    header(('why is %s (%d) in state "%s"'):format(p.name or '?', src, p.state))
    print(('  state          %s'):format(p.state))
    print(('  squad          %s'):format(tostring(p.squadId or 'none (solo)')))
    print(('  health         %s hp / %s armour (display units)')
        :format(tostring(p.hp), tostring(p.armour)))
    -- The ped handle is shown alongside the position, because "not sampled yet"
    -- on its own does not distinguish "the sampler is broken" from "this player
    -- has no ped because they never spawned". Those have different fixes.
    print(('  ped handle     %s%s'):format(
        tostring(p.ped or 'nil'),
        (not p.ped or p.ped == 0) and '   <- no ped: player has not spawned' or ''))
    print(('  position       %s'):format(p.pos and ('%.0f, %.0f, %.0f'):format(p.pos.x, p.pos.y, p.pos.z) or 'not sampled yet'))
    if p.posAt and p.posAt > 0 then
        print(('  sampled        %s ago'):format(secs(GetGameTimer() - p.posAt)))
    end
    print(('  last damaged   by %s, %s ago')
        :format(tostring(p.lastDamageBy or '-'),
                p.lastDamageAt and secs(GetGameTimer() - p.lastDamageAt) or '-'))
    print(('  kills/place    %s / %s'):format(tostring(p.kills or 0), tostring(p.placement or '-')))

    local pm = BR.Server.matchOf(src)
    if pm then
        print(('  match          %d (%s)'):format(pm.id, pm.state))
    end
    if p.pos and pm and pm.storm then
        local cx, cy, r = BR.StormAt(pm.storm, GetGameTimer())
        local d = BR.EdgeDistance(p.pos.x, p.pos.y, cx, cy, r)
        print(('  storm          %.0fm %s the circle'):format(math.abs(d), d > 0 and 'OUTSIDE' or 'inside'))
    end

    local poi = BR.Config.Map.NearestPOI(p.pos and p.pos.x or 0, p.pos and p.pos.y or 0)
    if p.pos and poi then
        print(('  nearest POI    %s'):format(poi.name))
    end
end, RESTRICTED)

--- Trip the anticheat on purpose, without a trainer.
---
--- WHY THIS IS COMMITTED RATHER THAN PASTED IN. The playtest issues for the
--- incident pipeline all begin "add a temporary debug command (do not commit
--- it)" -- which means every run of those tests starts by editing a server file
--- on a live box, and ends with somebody hoping they removed it again. That is
--- a worse risk than the command existing behind the dev gate that already
--- guards brgive and brforce.
---
--- IT DRIVES THE REAL PATH. It calls BR.Damage.noteRefusal exactly as the
--- validator does, so the tier logic, the doubling guard, the evidence
--- attachment and the incident write are all genuinely exercised. A command
--- that faked an incident row would prove nothing about the thing being tested.
---
---   brrefuse            2 NO_WEAPON against yourself -- crosses the high bar
---   brrefuse 8          8 of them, to watch the doubling reports at 2, 4 and 8
---   brrefuse 2 TOO_FAR  a normal-tier reason instead
---   brrefuse 1 SELF     the one that must count toward NOTHING
---
--- Console-only would be useless here: source 0 is not a player and has no
--- match, so this is a client command and the caller is the subject.
RegisterCommand('brrefuse', function(src, args)
    if not devOnly('brrefuse') then return end

    local n = math.max(1, math.min(64, math.floor(tonumber(args[1]) or 2)))
    local why = tostring(args[2] or 'NO_WEAPON'):upper()

    if not BR.ShotRefusal[why] then
        print(('  brrefuse: unknown reason "%s". Try one of:'):format(why))
        for k in pairs(BR.ShotRefusal) do print('    ' .. k) end
        return
    end

    local target = tonumber(src)
    if not target or target <= 0 then
        print('  brrefuse: run this from a CLIENT (F8), not the server console --'
            .. ' the caller is the subject and source 0 is in no match.')
        return
    end

    -- SAY WHERE THIS IS BEING FIRED FROM, because it changes the result and
    -- the difference is otherwise invisible.
    --
    -- Outside a live match there is no evidence buffer to attach and no match
    -- to group by, so the incident arrives with an empty `evidence` list -- and
    -- that looks exactly like the evidence pipeline being broken. It is not; it
    -- is a refusal recorded somewhere nothing was being recorded.
    local e = BR.Roster.get(target)
    local matchId = e and e.matchId or nil

    print(('[br_core] brrefuse: %d x %s against %s%s'):format(
        n, why, target,
        matchId and (' in match ' .. tostring(matchId)) or ' OUTSIDE A MATCH'))

    if not matchId then
        print('  No match, so: no evidence will attach to the incident, and it')
        print('  cannot corroborate against a case filed in a real match.')
        print('  Fine for proving the write path. Use a live match to test the')
        print('  evidence bundle or corroboration.')
    end

    for _ = 1, n do
        BR.Damage.noteRefusal(target, BR.ShotRefusal[why])
    end

    -- WHERE TO LOOK NEXT. The frames are taken at +0, +5s and +10s AFTER the
    -- DynamoDB acknowledgement, so there is nothing to show yet -- and a
    -- playtester with no idea that a second command exists reads "no
    -- screenshots" as "the feature does not work".
    if BR.Artifacts then
        print('  Then: brartifacts, ~15s from now, for what the capture did.')
    end
end, false)

--- What the capture has actually done.
---
--- THE READER FOR BR.Artifacts.stats(), written at the same time as the thing it
--- reads. Two stats functions in this resource already have no caller
--- (BR.Evidence.stats, BR.Incident.stats) and a third would have been the same
--- mistake for the third time.
---
--- IT IS THE ONLY WINDOW ONTO THIS FEATURE FROM THE BOX. Nothing about a
--- screenshot is visible in the game: the subject is shown nothing, the frames
--- go straight to a bucket the game cannot read back, and a partial set is the
--- normal outcome -- so "did anything happen" has no other answer short of
--- opening the case in Ringmaster.
---
--- `enabled` IS THE FIRST LINE ON PURPOSE. `screenshot-basic` not being
--- installed is a supported state, and it is the explanation for every zero
--- below it.
RegisterCommand('brartifacts', function()
    header('incident artifacts')
    if not BR.Artifacts then
        print('  server/artifacts.lua is not loaded.')
        return
    end
    local s = BR.Artifacts.stats()
    print(('  capture        %s'):format(
        s.enabled and 'screenshot-basic is running'
                  or 'screenshot-basic is NOT running -- no frames will be taken'))
    print(('  cases          %d open, %d opened since start, %d evicted')
        :format(s.open, s.opened, s.evicted))
    print(('  frames         %d claimed, %d asked for, %d stored, %d lost')
        :format(s.claimed, s.asked, s.stored, s.lost))
    print(('  uploaded       %d bytes'):format(s.bytes))
    -- REFUSALS ARE RULES, NOT FAULTS, and they are printed apart from `lost` so
    -- that reading is not available only to somebody who has read the source.
    print(('  not captured   %d at the cap of nine, %d inside the first ten')
        :format(s.refusedCap, s.refusedCovered))
    print(('                 %d for cases this process did not file')
        :format(s.refusedUnknown))
    print(('  skipped        %d (subject gone, or nothing to capture with)')
        :format(s.skipped))
end, RESTRICTED)

--- What the strip detector has seen, and what it refused.
---
--- WRITTEN AT THE SAME TIME AS THE THING IT READS, for the reason the
--- `brartifacts` note above gives: this resource already carries two stats
--- functions nobody calls, and BR.Strip.stats() would have been the third.
---
--- `races` IS THE NUMBER THIS COMMAND EXISTS FOR. It counts reports refused
--- because the weapon turned out to be in the player's own server-side
--- inventory -- the one false positive this feature can produce, and one that
--- would otherwise be a case opened against an innocent player. On a healthy
--- server it stays at zero; a number that climbs means the client's own filter
--- is missing a case and the guard behind it is doing work it should not have
--- to.
---
--- THERE IS NO `exempt` COUNTER AND NO EXEMPTION. This paragraph used to
--- describe an admin exemption as the other number worth reading. The owner
--- removed the exemption in `f562945` -- "I don't want admins to be exempt
--- from any incidents please" -- and the counter went with it.
---
--- IT LEFT THIS COMMAND THROWING RATHER THAN PRINTING, because the format
--- string still asked `stats()` for a field that had stopped existing. Nothing
--- caught it: a `%d` against nil is a runtime error on a console command no
--- test drives. Worth remembering next time a field is deleted -- grep for its
--- readers, not just its writers.
RegisterCommand('brstrips', function()
    header('unissued weapons taken out of hands')
    if not BR.Strip then
        print('  server/strip.lua is not loaded.')
        return
    end
    local s = BR.Strip.stats()
    print(('  reports        %d received from clients, %d counted')
        :format(s.reports, s.counted))
    print(('  refused        %d throttled, %d our own weapon')
        :format(s.throttled, s.races))
    print(('  tracking       %d player(s) with a count this match')
        :format(s.tracked))
    -- THE LIMIT, PRINTED WHERE SOMEBODY READING THE NUMBERS WILL SEE IT. A zero
    -- here is not proof of a clean server: the report is sent by our own
    -- resource on the offender's machine, so a cheat that disables br_core
    -- disables this with it. The unforgeable half is server/damage.lua.
    print('  Note: this is a client-side report. A cheat that stops br_core')
    print('  stops this too -- the server-side damage validation is the half')
    print('  that does not need the client\'s cooperation.')
end, RESTRICTED)

--- Refused vehicles: what reached the server, and what was done about it.
---
--- THE READER FOR TWO QUESTIONS THAT LOOK LIKE ONE. "Is anybody spawning
--- vehicles" and "is our allowlist complete" have different answers and
--- different fixes, and the counters below are arranged so they cannot be
--- confused for each other.
RegisterCommand('brvehicles', function()
    header('vehicles the gamemode refuses')
    if not BR.Vehicles then
        print('  server/vehicles.lua is not loaded.')
        return
    end
    local s = BR.Vehicles.stats()
    print(('  entities       %d created by clients, %d of them vehicles')
        :format(s.seen, s.vehicles))
    print(('  allowed        %d passed the allowlist')
        :format(s.allowed))
    print(('  counted        %d refused and attributed, %d throttled')
        :format(s.counted, s.throttled))
    print(('  not attributed %d refused with no owning player')
        :format(s.unowned))
    print(('  tracking       %d player(s) with a count this match')
        :format(s.tracked))

    -- THE TWO NUMBERS THAT MEAN SOMETHING IS WRONG SOMEWHERE ELSE, each with
    -- the fix named beside it, because neither is fixed in server/vehicles.lua.
    print(('  by class       %d caught by GetVehicleType and NOT by the model')
        :format(s.byType))
    if s.byType > 0 then
        print('                 ^ config/vehicles.lua does not name an aircraft')
        print('                   that is in this game build. Add it.')
    end
    print(('  engine-placed  %d refused model(s) claiming to be population')
        :format(s.ambient))
    local any = false
    for hash, n in pairs(s.models or {}) do
        if not any then
            print('                 models seen, as the engine reported them:')
            any = true
        end
        -- THE HASH RATHER THAN A NAME, because the models worth seeing here are
        -- exactly the ones config/vehicles.lua could not name -- a lookup would
        -- print "unknown" for the interesting half.
        print(('                   0x%08X  x%d'):format(hash, n))
    end
    if s.ambient > 0 then
        print('                 ^ either GTA places ambient aircraft in matches,')
        print('                   or a client is lying about the population')
        print('                   field to walk one past `relaxed` lockdown.')
        print('                   The model list above is what tells them apart;')
        print('                   nothing is filed for either.')
    end

    print('  Note: what this can see depends on sv_entityLockdown. Under')
    print('  `relaxed` the platform refuses script-created entities before')
    print('  this file is reached, so a low count is the boundary working')
    print('  rather than a quiet server. See server.cfg.example.')
end, RESTRICTED)

--- Print the stored profile row for connected players.
---
--- THE TOOL THAT WAS MISSING FOR EVERY STATS PLAYTEST. Verifying that a match
--- credited damage, or paid the right Volts, or recorded a quitter, all reduce
--- to "read this row before and after" -- and the only way to do that was the
--- AWS console. That is a bad place to be mid-playtest with two clients open,
--- and it made the one step those tests actually turn on the step most likely
--- to be skipped.
---
--- `br:ddb:profileFetch` has existed since the stats writer landed and nothing
--- has ever called it. This is that caller.
---
---   brprofile          every connected player, which is the "before" snapshot
---   brprofile 3        one server id
---
--- Server console only -- it prints a table, and a client has nowhere to put
--- one. Not dev-gated: it reads a row that the player's own profile page shows
--- them anyway, and gating a read-only diagnostic behind dev mode is how you
--- end up unable to diagnose the live server.
local function printProfile(name, src, row, err)
    if err then
        print(('  %-18s %-4s  READ FAILED: %s'):format(name, src, err))
        return
    end
    if not row then
        print(('  %-18s %-4s  no row yet -- has never finished a match'):format(name, src))
        return
    end

    local n = function(k) return tonumber(row[k]) or 0 end

    -- DERIVED, NOT READ. The row's `level` is written at match end and can lag
    -- the xp beside it; `xp` accumulates atomically and cannot. Printing the
    -- stored one made this command the last place still disagreeing with the
    -- lobby after everything else was fixed to derive.
    local xp = n('xp')
    local lvl, into, span = 1, 0, 0
    if BR.Xp then
        lvl = BR.Xp.levelFor(xp)
        local _, i, s = BR.Xp.progress(xp)
        into, span = i, s
    end

    print(('  %-18s %-4s  lvl %-3d xp %d (%d/%d) volts %-7d'):format(
        name, src, lvl, xp, into, span, n('balance')))
    print(('  %-18s %-4s  matches %-4d wins %-3d kills %-4d deaths %-4d'):format(
        '', '', n('matches'), n('wins'), n('kills'), n('deaths')))
    print(('  %-18s %-4s  damage %-8d playtime %-7ds downs %-3d revives %-3d'):format(
        '', '', n('damageDealt'), n('playtimeSec'), n('downs'), n('revives')))
end

RegisterCommand('brprofile', function(src, args)
    if tonumber(src) ~= 0 then
        print('  brprofile is server-console only -- it prints a table.')
        return
    end

    if GetResourceState('br_ddb') ~= 'started' then
        print('  brprofile: br_ddb is not started, so there is nothing to read.')
        return
    end

    local wanted = tonumber(args[1])
    local list = {}

    for _, id in ipairs(GetPlayers()) do
        local pid = tonumber(id)
        if not wanted or wanted == pid then
            local byKind = BR.Identity.ofPlayer(pid)
            local license = byKind and BR.Identity.qualified('license', byKind.license)
            if license then
                list[#list + 1] = { src = pid, name = GetPlayerName(pid) or '?', license = license }
            end
        end
    end

    if #list == 0 then
        print(wanted and ('  brprofile: %d is not connected, or has no license.'):format(wanted)
            or '  brprofile: nobody connected.')
        return
    end

    print(('=== stored profiles (%s) ==='):format(os.date('%Y-%m-%d %H:%M:%S')))

    -- One request per player, each answering independently. Printed as they
    -- arrive rather than gathered, because a single slow row should not hold
    -- back the rest -- and during a playtest a partial answer beats a wait.
    for _, p in ipairs(list) do
        local req = BR.Server.nextDbgReq or 1
        BR.Server.nextDbgReq = req + 1

        -- `RemoveEventHandler` takes the HANDLE that AddEventHandler returns,
        -- not the function -- passing the function silently removes nothing and
        -- leaves a handler per player per invocation for the life of the
        -- resource. Captured in a forward-declared local so the closure can
        -- reach its own registration.
        local ref
        local answered = false

        ref = AddEventHandler('br:ddb:profileResult', function(gotReq, row, extra)
            if gotReq ~= req or answered then return end
            answered = true
            if ref then RemoveEventHandler(ref) end
            printProfile(p.name, p.src, row, extra and extra.error)
        end)

        -- The guard matters: without it this prints "timed out" six seconds
        -- after every successful read, which reads as the command being broken.
        SetTimeout(6000, function()
            if answered then return end
            answered = true
            if ref then RemoveEventHandler(ref) end
            printProfile(p.name, p.src, nil, 'timed out')
        end)

        TriggerEvent('br:ddb:profileFetch', req, p.license)
    end
end, true)

--- Pose a match-end award at a connected player without writing anything.
---
--- THE VALIDATION TOOL FOR #91 AND #130, and it exists because the one beat the
--- progression system is built for -- the level-up flip -- is the beat nobody
--- can stage on demand. Confirming it means getting a real player to within a
--- few hundred XP of a real boundary and then playing a match big enough to
--- cross it, which is a great deal of arranging to test a bar. Every failure so
--- far has been in the DISPLAY of these numbers rather than in their
--- arithmetic, so this drives the display path with real ones.
---
---   brxpsim 3          award that player enough to cross their next boundary
---   brxpsim 3 250      award exactly 250 XP
---
--- WHAT IT PROVES AND WHAT IT DOES NOT. It sends the identical MATCH_EARNED a
--- real match sends, from the identical BR.Xp calls against that player's real
--- lifetime total -- so if the bar lands anywhere other than where this prints,
--- the fault is in the interface. It writes NOTHING: no DynamoDB row, no
--- balance, no XP. `brprofile` reads the same afterwards, and the bar returns
--- to the stored truth on the next MARKET_STATE. Proving the WRITE path still
--- takes a real match.
---
--- The verdict screen exists only while a match tears down, so run this in the
--- lobby and watch the lobby's bar. Volts are reported as 0 on purpose:
--- claiming a payout that nothing paid is the precise lie this issue was about.
RegisterCommand('brxpsim', function(src, args)
    if tonumber(src) ~= 0 then
        print('  brxpsim is server-console only.')
        return
    end
    if not BR.Xp then
        print('  brxpsim: BR.Xp is not loaded, so there is no curve to evaluate.')
        return
    end

    local target = tonumber(args[1])
    if not target then
        print('  usage: brxpsim <server id> [xp]   (default: enough to level up)')
        return
    end

    local before = BR.Market and BR.Market.lifetimeXp and BR.Market.lifetimeXp(target)
    if not before then
        print(('  brxpsim: no loaded profile for %d. They have to be connected'):format(target))
        print('  with their inventory read finished -- check brprofile first.')
        return
    end

    -- The default is "just past the next boundary" rather than a round number,
    -- because the interesting animation is the one that crosses. Leaving the
    -- caller to work the gap out is how this ends up being run with a number
    -- that does not cross and reported as the flip not happening.
    local levelBefore = BR.Xp.levelFor(before)
    local amount = tonumber(args[2])
    if not amount then
        amount = math.max(1, BR.Xp.thresholdFor(levelBefore + 1) - before + 1)
    end
    amount = math.max(0, math.floor(amount))

    local after = before + amount
    local levelAfter = BR.Xp.levelFor(after)
    local _, intoBefore, spanBefore = BR.Xp.progress(before)
    local _, intoAfter, spanAfter = BR.Xp.progress(after)

    TriggerClientEvent(BR.Net.MATCH_EARNED, target, {
        xp      = amount,
        volts   = 0,
        level   = levelAfter,
        into    = intoAfter,
        needed  = math.max(1, spanAfter),
        fromLevel  = levelBefore,
        fromXp     = intoBefore,
        fromNeeded = math.max(1, spanBefore),
        levelUp = levelAfter > levelBefore,
    })

    print(('=== brxpsim %s (%s) -- NOTHING WRITTEN ==='):format(
        target, GetPlayerName(target) or '?'))
    print(('  lifetime xp   %d  ->  %d   (+%d)'):format(before, after, amount))
    print(('  bar should go lvl %d %d/%d  ->  lvl %d %d/%d%s'):format(
        levelBefore, intoBefore, spanBefore,
        levelAfter, intoAfter, spanAfter,
        levelAfter > levelBefore and '   LEVEL UP' or ''))
    print('  The lobby bar must land on the second pair exactly. If it does not,')
    print('  the interface is deriving something it was handed.')
end, true)

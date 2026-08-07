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
    print('  brperf [reset]       scheduler job cost, most expensive first')
    print('  brjob <on|off> <n>   enable or disable a scheduler job by name')
    print('  brconfig             the tunables that most often explain odd behaviour')
    print('  brwhy <id>           why is this player in the state they are in')
    print('  brloot [matchId]     world loot: counts by kind and rarity, subscriptions')
    print('  brinv <id>           one player\'s inventory, slot by slot')
    print('  brgive <id> <item> [n]  put an item straight into a player\'s hands')
    print('  brcrate <id> [item]  drop a crate (or one item) at a player\'s feet')
    print('  brlootseed <n|off>   pin the loot layout so it repeats between matches')
    print('  brscatter [radius]   spread everyone out to test OneSync scoping')
    print('  brforce <state>      force a match state transition')
    print('  brskip               end the current timed state immediately')
    line('-')
    print('  Client-side (run in the F8 console): brnativecheck, brperf, brloop, brfx,')
    print('    brboot, brblack, brfocus, brshield [0-100], brleave (leave the match),')
    print('    brloot (what this client can see), brlootblips (dev: blip every')
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

RegisterCommand('brsquads', function()
    header('squads')
    local any = false
    for id, sq in pairs(BR.Server.squads) do
        any = true
        local names = {}
        for _, src in ipairs(sq.members or {}) do
            local p = BR.Server.roster[src]
            names[#names + 1] = ('%s(%d,%s)'):format(
                p and p.name or '?', src, p and p.state or '?')
        end
        print(('  [%s] alive=%s placement=%s')
            :format(tostring(id), tostring(sq.alive), tostring(sq.placement or '-')))
        print(('      %s'):format(table.concat(names, ', ')))
    end
    if not any then print('  (no squads)') end
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

RegisterCommand('brgive', function(_, args)
    local src  = tonumber(args[1])
    local item = args[2]
    local n    = tonumber(args[3]) or 1
    if not src or not item then
        print('  usage: brgive <serverId> <itemId> [count]')
        print('    itemId is a weapon/throwable id (carbinerifle), a consumable')
        print('    id (medkit), or an ammo pool (light|smg|medium|shells|heavy)')
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

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
    local anchor = BR.Config.Storm.anchors[1]

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
    print('  brscatter [radius]   spread everyone out to test OneSync scoping')
    print('  brforce <state>      force a match state transition')
    print('  brskip               end the current timed state immediately')
    line('-')
    print('  Client-side (run in the F8 console): brnativecheck, brperf, brloop, brfx')
end, RESTRICTED)

RegisterCommand('brstate', function()
    local M = BR.Server.match
    header('match state')
    print(('  matchId      %d'):format(BR.Server.matchId))
    print(('  state        %s'):format(M.state))
    print(('  mode         %s'):format(M.mode))
    print(('  bucket       %d'):format(M.bucket))
    print(('  endsAt       %s (in %s)'):format(tostring(M.endsAt),
        M.endsAt > 0 and secs(M.endsAt - GetGameTimer()) or '-'))
    print(('  devMode      %s'):format(tostring(BR.Server.devMode)))
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
    local rec = BR.Server.storm
    if not rec then
        print('  no storm record -- the match is not in a storm phase')
        return
    end

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
    print(('  loot              %d items planned, cell %.0fm, pickup %.1fm')
        :format(BR.Config.TotalLootBudget(), L.cellSize, L.pickupDistance))
    print(('  render ceiling    424 units -- entities beyond this are not drawn'))
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
    print(('  position       %s'):format(p.pos and ('%.0f, %.0f, %.0f'):format(p.pos.x, p.pos.y, p.pos.z) or 'not sampled yet'))
    print(('  last damaged   by %s, %s ago')
        :format(tostring(p.lastDamageBy or '-'),
                p.lastDamageAt and secs(GetGameTimer() - p.lastDamageAt) or '-'))
    print(('  kills/place    %s / %s'):format(tostring(p.kills or 0), tostring(p.placement or '-')))

    if p.pos and BR.Server.storm then
        local cx, cy, r = BR.StormAt(BR.Server.storm, GetGameTimer())
        local d = BR.EdgeDistance(p.pos.x, p.pos.y, cx, cy, r)
        print(('  storm          %.0fm %s the circle'):format(math.abs(d), d > 0 and 'OUTSIDE' or 'inside'))
    end

    local poi = BR.Config.Map.NearestPOI(p.pos and p.pos.x or 0, p.pos and p.pos.y or 0)
    if p.pos and poi then
        print(('  nearest POI    %s'):format(poi.name))
    end
end, RESTRICTED)

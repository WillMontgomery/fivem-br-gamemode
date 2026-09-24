-- Unit tests for the storm's SAFE ZONE: the current circle UNION the next one.
--
--   "take for example 2 storm circles (current and next) which are barely
--    overlapping - like a venn diagram. We should extend the safezone to cover
--    both circles, so if a player gets to the new destination early they are
--    safe. That logic also doesn't exist today."      -- owner, 2026-09-21 (#328)
--
-- AND, SINCE #327, WHEN CIRCLE 1 IS DRAWN AND WHO IS SHOWN IT.
--
--   "We don't need to change where the circle goes - just determine circle 1's
--    location upon the first player in the match completing matchmaking, and show
--    the blip starting from then. Show the marker (or arc now as it may be)
--    starting from when the San Andreas map is loaded."  -- owner, same day
--
-- THE TWO SUBJECTS BELONG IN ONE FILE because they are the same three files and,
-- in the wall's case, the same renderer: the preview curtain IS the union wall
-- handed a single circle and a lower alpha. The `first.*` blocks are the timing
-- invariant -- one seed per match, phase 1 spends the first value -- and the
-- `preview.*` blocks are what a player is shown and, more importantly, what they
-- are NOT shown: no damage, no HUD card, nothing beside the real wall at PLAYING,
-- and nothing left on the map when a warmup ends without a match.
--
-- ═══ WHY THIS IS ITS OWN SUITE ═══
--
-- The storm had one corner of tools/test_shared.lua and has outgrown it. That
-- file already holds two different subjects -- BR.StormShape's geometry, proved
-- against all four of union2's cases, and the #225 viewpoint sandbox that stands
-- client/storm.lua up on the real loop -- and neither of them is this. This is
-- the RULE those two exist to serve, asserted against the two files that apply
-- it: the server's damage tick and the client's readout.
--
-- Nothing here re-tests union2. Its cases, its arc-length walk and its signed
-- distance belong to storm_shape.lua and are driven in test_shared.lua.
--
-- ═══ WITH ONE EXCEPTION, AND IT IS DELIBERATE: THE ROUNDED RECTANGLE (#335) ═══
--
--   "The storm border does draw still, and everything is circular. Can you make the
--    storms squircles instead to prove our new logic?"      -- owner, 2026-09-22
--
-- The `square.*` blocks hold both halves of that: the SHAPE's own geometry -- its
-- piece list, its signed distance and its erosion -- and the MAP that reads it, which
-- is client/storm.lua's three rings and the squareness knob they are drawn from.
-- Those two belong together rather than one file apart. The map's whole content is a
-- claim about what the shape is, and the only reason the shape exists is the map and
-- the wall that will follow it; a proof split across two suites is a proof whose two
-- halves can stop agreeing without either going red. union2 appears there only where
-- the map has to answer for it -- two fills for a breakout, one for a nested phase --
-- and not for its cases or its walk, which are still test_shared.lua's.
--
-- ═══ THE PROPERTY THAT MAKES THE CHANGE SHIPPABLE IS THE FIRST BLOCK ═══
--
-- On an ordinary phase the next circle is NESTED inside the current one, and the
-- union of a circle with a circle inside it IS the outer circle. So the rule is
-- a no-op on every phase that did not break out, and `server.nested` proves that
-- the honest way: it sweeps a grid across the whole map and asserts that the set
-- of points the new rule bills is the SAME SET, point for point, that the old
-- `BR.Dist(...) <= r + margin` billed. A change that only looked right in the
-- interesting case would pass every other block in this file and fail that one.
--
-- ═══ WHAT NO PLAYTEST COULD REACH ═══
--
-- A breakout phase is a random roll (0% at phase 1 ramping to 85% at phase 8),
-- the interesting geometry is the tail of that roll, and the symptom of getting
-- it wrong is DAMAGE THAT SHOULD NOT HAVE HAPPENED -- which in a match is
-- indistinguishable from having misjudged where the wall was. Worse, the
-- disjoint case has to be seen from inside the gap, which is a place a player
-- spends about six seconds in and never voluntarily. Here every one of those is
-- a record and a coordinate.
--
-- ═══ AND ONE DECISION IS PINNED HERE BECAUSE IT LOOKS LIKE AN OVERSIGHT ═══
--
-- The way-home arrow still aims at the NEXT circle rather than at the nearest
-- point on the union. That is deliberate, it is argued at the call site, and
-- `client.arrow` holds it -- because the instinct of the next reader will be to
-- make it "consistent" with the edge, and doing so would point the arrow at the
-- current circle's rim on every ordinary phase, away from the ring the player is
-- being asked to rotate to.

local RES = 'resources/[fivem-royale]/'

-- ---------------------------------------------------------------------------
-- The harness
-- ---------------------------------------------------------------------------

local SANDBOX_STD = {
    assert = assert, error = error, ipairs = ipairs, next = next,
    pairs = pairs, pcall = pcall, rawequal = rawequal, rawget = rawget,
    rawlen = rawlen, rawset = rawset, select = select, xpcall = xpcall,
    setmetatable = setmetatable, getmetatable = getmetatable,
    tonumber = tonumber, tostring = tostring, type = type,
    math = math, string = string, table = table,
    coroutine = coroutine, unpack = table.unpack,
}

--- A fresh state with nothing of the host process in it but SANDBOX_STD.
---
--- Explicit rather than inherited, so a native the production code reaches for
--- and this harness never defined is an immediate "attempt to call a nil value"
--- rather than a silent no-op. A silent no-op is how a suite goes green while
--- the thing it claims to test does nothing at all.
local function newSandbox()
    local env = setmetatable({}, { __index = function(_, k) return SANDBOX_STD[k] end })
    env._G = env
    return env
end

--- Load real production files into a state, or die loudly.
local function loadInto(env, list)
    for _, f in ipairs(list) do
        local chunk, err = loadfile(RES .. f, 't', env)
        if not chunk then
            io.write('\27[31msandbox load error\27[0m ', f, ': ', tostring(err), '\n')
            os.exit(1)
        end
        local okc, e2 = pcall(chunk)
        if not okc then
            io.write('\27[31msandbox run error\27[0m ', f, ': ', tostring(e2), '\n')
            os.exit(1)
        end
    end
end

-- Every br_lib file the two br_core storm files expect to have been loaded
-- before them, in fxmanifest order. A server and a client are separate Lua
-- states in the real game, so each harness below gets its own copy.
--
-- storm_shape.lua IS THE ONE THAT MATTERS HERE. Both consumers under test ask it
-- for the union, and br_core's fxmanifest declares it in shared_scripts -- so it
-- is loaded in the server state as well as the client one. A state without it
-- would not fail loudly: BR.Sched.step and BR.Loop.step both pcall their
-- callbacks, so the whole damage tick would go silently missing and every
-- assertion about who got hurt would report a nil.
local SANDBOX_LIB = {
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/clock.lua',
    'br_lib/shared/world.lua',
    'br_lib/shared/matchtag.lua',
    'br_lib/shared/sched.lua',
    'br_lib/config/match.lua',      -- BR.ToEngineHpDelta, which the ledger writes through
    'br_lib/config/overrides.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',        -- BR.NextStormCentre keeps a circle on the map with it
    'br_lib/config/audio.lua',      -- the cue keys the phase job broadcasts
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/storm_shape.lua',
}

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        print('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end
local function near(a, b, tol)
    return a ~= nil and math.abs(a - b) <= (tol or 1e-6)
end

--- Every BAND the last frame emitted: two triangles, one footprint, one alpha.
---
--- ASKED WITHOUT ASSUMING A WINDING, deliberately: the outward face is
--- (A_bot, B_bot, A_top) and the inward face is that reversed, so the only
--- thing both spellings agree on is the vertex SET. A appears twice in the
--- first triangle (bottom and top) and B once, which names them without the
--- test having to know which face it is looking at -- so a winding bug cannot
--- hide inside the helper that is supposed to catch it.
---
--- ═══ A BAND IS NOT A QUAD SINCE THE FADE (#336) ═══
---
--- The wall fades bottom to top, and the fallback path spells that as
--- `fade.bands` stacked quads per walk step, each flat at its own alpha --
--- because DRAW_POLY has one alpha for a whole triangle and cannot ramp. So the
--- triangles now arrive in groups of 2 * bands per step, not 2, and a helper
--- that still paired them would hand every assertion below a footprint that is
--- half a band wide. Bands first, then quadsOf groups them.
local function bandsOf(C)
    local out = {}
    for i = 1, #C.polys - 1, 2 do
        local t = C.polys[i]
        local twice, once
        for j = 1, 3 do
            local v, n = t[j], 0
            for k = 1, 3 do
                if t[k].x == v.x and t[k].y == v.y then n = n + 1 end
            end
            if n == 2 then twice = v else once = v end
        end
        local lo, hi = math.huge, -math.huge
        for _, tri in ipairs({ C.polys[i], C.polys[i + 1] }) do
            for j = 1, 3 do
                if tri[j].z < lo then lo = tri[j].z end
                if tri[j].z > hi then hi = tri[j].z end
            end
        end
        out[#out + 1] = { a = twice, b = once, z0 = lo, z1 = hi,
                          alpha = C.polys[i].a,
                          t1 = C.polys[i], t2 = C.polys[i + 1] }
    end
    return out
end

--- The WALK STEPS the last frame emitted: the bands of one step, grouped.
---
--- GROUPED BY FOOTPRINT RATHER THAN BY COUNTING TO `bands`, so the helper does
--- not have to be told the config value it is meant to be checking. Every band
--- of a step stands on the same two boundary points -- that is what makes them
--- bands of one quad rather than separate quads -- so a run of equal footprints
--- IS a step, and the count of them is a thing the tests can then assert on
--- instead of assume.
local function quadsOf(C)
    local out = {}
    for _, b in ipairs(bandsOf(C)) do
        local last = out[#out]
        if last and last.a.x == b.a.x and last.a.y == b.a.y
            and last.b.x == b.b.x and last.b.y == b.b.y then
            last.bands[#last.bands + 1] = b
            if b.z0 < last.z0 then last.z0 = b.z0 end
            if b.z1 > last.z1 then last.z1 = b.z1 end
        else
            out[#out + 1] = { a = b.a, b = b.b, z0 = b.z0, z1 = b.z1,
                              bands = { b } }
        end
    end
    return out
end

--- Does this triangle's visible face point at `v`? The visible side is the one
--- the cross product points toward, so this is that cross product dotted with
--- the line of sight. A vertical quad has a horizontal normal, so the viewer's
--- own z falls out of the arithmetic -- which is the reason a spectator in a
--- helicopter sees the same faces as a ped on the ground.
local function faces(t, v)
    local ax, ay, az = t[2].x - t[1].x, t[2].y - t[1].y, t[2].z - t[1].z
    local bx, by, bz = t[3].x - t[1].x, t[3].y - t[1].y, t[3].z - t[1].z
    local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
    return (v.x - t[1].x) * nx + (v.y - t[1].y) * ny
         + ((v.z or 0.0) - t[1].z) * nz > 0.0
end

--- How many of the last frame's triangles show the viewer their back.
local function backFacing(C, v)
    local n = 0
    for _, t in ipairs(C.polys) do
        if not faces(t, v) then n = n + 1 end
    end
    return n
end

--- The fade's alpha multiplier at height `z`, WRITTEN OUT A SECOND TIME.
---
--- ═══ DELIBERATELY NOT THE PRODUCTION FUNCTION, WHICH IS LOCAL ANYWAY ═══
---
--- This is the curve the config describes, spelled from the config's own fields: flat
--- at baseAlpha from the geometry's bottom up to rampBaseZ, then straight to topAlpha
--- at the top. Every alpha assertion below is against THIS rather than against a
--- literal, so retuning baseAlpha, topAlpha or rampBaseZ retunes the suite instead of
--- turning it red -- and a production change that alters the SHAPE of the curve still
--- goes red, because this spelling does not follow it.
---
--- THE KINK IS THE WHOLE POINT OF IT. A ramp measured from baseZ spends its first 15
--- percent below the lowest ground the config admits, which is what made the wall at a
--- player's feet draw at alpha 92 where render.alpha says 110.
--- @param fd table    the fade config
--- @param zb number   the geometry's bottom
--- @param zt number   the geometry's top
--- @param z number
--- @return number     0..1
local function rampMul(fd, zb, zt, z)
    local a0 = fd.baseAlpha or 1.0
    local a1 = fd.topAlpha or 0.0
    local z0 = fd.rampBaseZ or 0.0
    if z0 < zb then z0 = zb end
    if z0 >= zt then return a0 end
    if z <= z0 then return a0 end
    if z >= zt then return a1 end
    return a0 + (a1 - a0) * ((z - z0) / (zt - z0))
end

--- Which fade path a client actually settled on, and how many bands that means.
---
--- ASKED OF THE CLIENT RATHER THAN OF THE CONFIG, because the answer is a runtime
--- ladder: the gradient needs a runtime texture, and a client whose stubs refused one
--- is genuinely drawing the fallback. A suite that read `prefer` instead would assert
--- gradient geometry against a banded wall and blame the renderer.
--- @param C table
--- @return string path, integer bands
local function fadeOf(C)
    local path = C.env.BR.Storm and C.env.BR.Storm.fadePath
    if path == 'gradient' then return 'gradient', 1 end
    local fd = C.env.BR.Config.Storm.render.strip.fade or {}
    return 'bands', math.max(1, math.floor(fd.bands or 3))
end

-- ---------------------------------------------------------------------------
-- MEASURING A SHAPE WITHOUT ASKING THE SHAPE (#344)
--
-- Every phase is a random shape now, so the numbers this file used to write out
-- by hand -- "500 m inside a 500 m circle", "five metres outside the far island"
-- -- name a circle that nothing draws any more. Two choices were available and
-- only one of them keeps the teeth:
--
--   Call BR.StormShape.distance and assert against its own answer. That turns
--   every geometry assertion below into a tautology: a shape that is the wrong
--   shape entirely still passes, as long as the server and the client agree about
--   it, and the whole point of most of these blocks is WHERE the boundary is.
--
--   Derive the same answer a DIFFERENT WAY, and assert against that. Which is
--   what these two helpers do: they walk the boundary -- pointAtComponent, the
--   piece list, the arc-length machinery -- and answer from the polygon that walk
--   produces. StormShape.distance never touches the walk; it is a maximum over
--   supporting half-planes and corner discs. So the two agreeing is evidence.
--
-- The remaining shared assumption is the walk itself, and that is pinned
-- independently: tools/test_shared.lua's `shape.equivalence` proves the walk
-- lands where the old angular one did, and its `blob.*` blocks prove the walked
-- boundary and the signed distance agree to 1e-6 on a grid.
-- ---------------------------------------------------------------------------

--- A closure that answers the signed distance to `shape`: negative inside.
---
--- ONE DENSE POLYGON PER COMPONENT, and the answer is the MINIMUM over them --
--- which is what a union is, and is also why the components cannot be merged into
--- one polygon: two overlapping loops even-odd out to their symmetric difference,
--- so the lens of an overlapping breakout would read as outside.
---
--- Magnitude from the nearest point on a SEGMENT of the polygon rather than from
--- the nearest vertex: a vertex is up to half the sampling step away from the true
--- foot, which at these perimeters is metres, and the assertions below are written
--- to half a metre. Sign from an even-odd crossing count.
--- @param steps number|nil   points around the whole boundary
local function shapeProbe(env, shape, steps)
    local SS = env.BR.StormShape
    local P = SS.perimeter(shape)
    local total = steps or math.max(720, math.min(6000, math.floor(P / 2.0)))
    local polys = {}
    for _, c in ipairs(SS.components(shape)) do
        local n = math.max(64, math.floor(total * c.len / P + 0.5))
        local pts = {}
        for k = 0, n - 1 do
            local x, y = SS.pointAtComponent(shape, c, c.len * k / n)
            pts[#pts + 1] = { x = x, y = y }
        end
        polys[#polys + 1] = pts
    end
    return function(px, py)
        local best = math.huge
        for _, pts in ipairs(polys) do
            local n = #pts
            local d2, inside = math.huge, false
            local j = n
            for i = 1, n do
                local a, b = pts[i], pts[j]
                local ex, ey = b.x - a.x, b.y - a.y
                local el = ex * ex + ey * ey
                local t = 0.0
                if el > 0.0 then
                    t = ((px - a.x) * ex + (py - a.y) * ey) / el
                    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
                end
                local qx, qy = px - (a.x + ex * t), py - (a.y + ey * t)
                local dd = qx * qx + qy * qy
                if dd < d2 then d2 = dd end
                if ((a.y > py) ~= (b.y > py))
                    and (px < (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x) then
                    inside = not inside
                end
                j = i
            end
            local d = math.sqrt(d2)
            if inside then d = -d end
            if d < best then best = d end
        end
        return best
    end
end

--- A point `m` metres outside the boundary of `shape` at arc length `s`.
---
--- Negative `m` is inside. This is what replaces "the centre plus r plus five" in
--- every block that wanted a point a known distance off the edge: on a shape whose
--- radius depends on the bearing, that arithmetic names a point whose distance from
--- the boundary is not the number in the test's own name. Walked rather than
--- computed, for the reason shapeProbe is.
local function offBoundary(env, shape, s, m)
    local x, y, nx, ny = env.BR.StormShape.pointAtArc(shape, s)
    return x + nx * m, y + ny * m
end

--- Which PART of a two-component zone a quad or a marker is standing on.
---
--- ASKED AS "WHOSE BOUNDARY IS IT ON", NOT "WHOSE CENTRE IS IT NEARER" (#344). The
--- centre test is exact for two discs and wrong for two blobs: a point on the far
--- side of the bigger shape can be nearer the smaller shape's centre than its own.
--- Every drawn point is on one part's boundary to a picometre, so the part whose
--- boundary it is nearest is the part it came from. A single-component shape is its
--- own part.
local function partAt(env, shape, x, y)
    if not shape.parts then return shape end
    local best, pick = math.huge, shape
    for _, p in ipairs(shape.parts) do
        local d = math.abs(env.BR.StormShape.distance(p, x, y))
        if d < best then best, pick = d, p end
    end
    return pick
end

--- How far a quad's chord cuts inside the boundary it replaces, in metres.
---
--- The chord's MIDPOINT is the deepest point of the cut, and the depth there is the
--- signed distance to the shape the walk was following -- the same measure on a
--- circle, a union and a blob alike. The old spelling was
--- `(r - edgeInset) - dist(midpoint, centre)`, which names a CIRCLE: on a shape
--- whose radius depends on the bearing it measures the jitter draw and reports
--- hundreds of metres of sag on a wall that is inside chordM.
---
--- MEASURED AGAINST ITS OWN PART on a two-component zone, because the union's own
--- distance is the minimum of the two -- so a quad of one component that legitimately
--- runs inside the other would read as hundreds of metres of sag rather than as the
--- overlap artifact it is.
local function sagOf(env, shape, qd)
    local mx, my = (qd.a.x + qd.b.x) * 0.5, (qd.a.y + qd.b.y) * 0.5
    return -env.BR.StormShape.distance(partAt(env, shape, qd.a.x, qd.a.y), mx, my)
end

--- The zone a client's own record describes, at the moment it is holding.
---
--- Built through the production BR.StormZone, because "which shape is this" is not
--- what these blocks test -- `blob.agree` is what pins that the two sides derive
--- the same one. What they test is what the wall, the HUD and the ledger DO with
--- it, so they need the shape in hand to measure against.
local function zoneOf(env, rec)
    return env.BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0)
end


-- ---------------------------------------------------------------------------
-- The server: the real br_core/server/storm.lua behind the smallest roster,
-- match list and combat surface that can hold it up.
-- ---------------------------------------------------------------------------

--- @return table  { env, tick(), place(x, y), hurts(x, y), errored() }
local function newStormServer()
    local env = newSandbox()
    local S = { now = 1000000, roster = {}, out = {}, prints = {},
                matches = {}, bled = {}, defeated = {}, sent = {}, cmds = {} }

    env.GetGameTimer = function() return S.now end
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        S.prints[#S.prints + 1] = table.concat(parts, ' ')
    end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetPlayerName    = function(s) return 'P' .. tostring(s) end
    env.GetHashKey       = function(s) return #tostring(s) end
    -- KEPT, NOT DROPPED, so `zone.freeze` can drive the admin commands through the
    -- real handlers rather than a copy of what they do.
    env.RegisterCommand  = function(name, fn) S.cmds[name] = fn end
    env.RegisterNetEvent = function() end
    env.AddEventHandler  = function() end
    env.TriggerClientEvent = function(ev, target, payload)
        S.out[#S.out + 1] = { event = ev, target = target, payload = payload }
    end
    env.Citizen = { CreateThread = function() end, Wait = function() end,
                    SetTimeout = function() end }

    loadInto(env, SANDBOX_LIB)

    -- EVERY MATCH-WIDE SEND IS RECORDED, not swallowed. STORM_SYNC is the record
    -- and nothing below reads it, but STORM_PREVIEW (#327) is the whole of the
    -- warmup half of this feature: a publish that never happens and a publish that
    -- happens with the wrong circle in it look identical from a match instance.
    env.BR.Broadcast = {
        toMatch = function(_, event, payload)
            S.sent[#S.sent + 1] = { event = event, payload = payload }
        end,
    }
    env.BR.Server = {
        devMode = false,
        eachMatch = function(fn)
            for _, m in ipairs(S.matches) do fn(m) end
        end,
        latestMatch = function() return S.matches[1] end,
        isInMatch = function(st)
            return st == env.BR.PlayerState.ALIVE or st == env.BR.PlayerState.DBNO
        end,
    }
    env.BR.Roster = {
        get = function(src) return S.roster[src] end,
        each = function(pred, fn)
            for src, e in pairs(S.roster) do
                if pred(e) then fn(src, e) end
            end
        end,
    }
    env.BR.Combat = {
        bleed = function(src, amount)
            S.bled[src] = (S.bled[src] or 0.0) + amount
        end,
        defeat = function(src) S.defeated[src] = true end,
    }

    loadInto(env, { 'br_core/server/storm.lua' })

    -- THE PHASE JOB IS STOOD DOWN, and that is not avoidance -- it is the only
    -- way to hold a record still. It authors a NEW record the moment a shrink
    -- finishes, so the collapse block below would be asserting against phase
    -- n+1's freshly rolled geometry instead of the one it set up.
    env.BR.Sched.setEnabled('storm.phase', false)

    S.match = {
        id = 1, seq = 1, state = env.BR.MatchState.PLAYING,
        anchor = { x = 0.0, y = 0.0, name = 'Test' },
    }
    S.matches[1] = S.match

    S.roster[1] = {
        matchId = 1, name = 'Runner', state = env.BR.PlayerState.ALIVE,
        hp = 100.0, pos = { x = 0.0, y = 0.0, z = 30.0 },
    }

    --- Publish a record by hand. Nothing here drives enterPhase: the point of
    --- every block below is a SPECIFIC pair of circles, and enterPhase's whole
    --- job is to roll one at random.
    function S.record(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs, dps)
        S.match.storm = env.BR.BuildStormRecord(phase, cx0, cy0, r0,
            cx1, cy1, r1, S.now, waitMs, shrinkMs, dps)
        S.match.stormCarry = {}
        return S.match.storm
    end

    --- One damage pass, one second after the last.
    function S.tick()
        S.now = S.now + 1000
        env.BR.Sched.step(S.now)
    end

    --- Backdate the live record so that the NEXT pass lands `ms` into the
    --- phase's own timeline.
    ---
    --- S.hurts SPENDS A SECOND OF ITS OWN getting the 1 Hz damage job to run, so
    --- a block that needs a particular radius part way through a sweep cannot
    --- simply advance the clock to the moment it wants -- by the time the job
    --- runs, the wall has moved on by another second. Moving the record instead
    --- makes the moment exact.
    function S.at(ms)
        S.match.storm.tStart = S.now + 1000.0 - ms
    end

    --- Stand the one player at (x, y) and run a pass. True if the storm billed
    --- them for it.
    ---
    --- THE LEDGER IS THE READ, NOT THE WIRE. STORM_DAMAGE carries whole engine
    --- points with the fraction carried forward, so at a low dps a given tick
    --- legitimately sends nothing; `stormHp` is the server-side number that
    --- decides the elimination and the inside branch is the only thing that
    --- clears it.
    function S.hurts(x, y)
        local e = S.roster[1]
        e.pos = { x = x, y = y, z = 30.0 }
        e.stormHp = nil
        S.tick()
        return e.stormHp ~= nil
    end

    --- The last match-wide send of one event, or nil.
    --- @param event string
    function S.lastSent(event)
        for i = #S.sent, 1, -1 do
            if S.sent[i].event == event then return S.sent[i].payload end
        end
        return nil
    end

    --- How many times one event was sent to the match.
    --- @param event string
    function S.countSent(event)
        local n = 0
        for _, s in ipairs(S.sent) do
            if s.event == event then n = n + 1 end
        end
        return n
    end

    --- Anything the scheduler swallowed. A job that threw is a job that did
    --- nothing, and a suite reading a nil ledger would call that "safe".
    function S.errored()
        for _, line in ipairs(S.prints) do
            if line:find('errored', 1, true) then return line end
        end
        return nil
    end

    S.env = env
    return S
end

-- ---------------------------------------------------------------------------
-- The client: the real br_core/client/storm.lua on the real loop.
-- ---------------------------------------------------------------------------

local function pt(x, y, z) return { x = x, y = y, z = z or 30.0 } end

--- @return table  { env, tick(n), frame(), last(), arrow(), markers, cmds }
local function newStormClient()
    local env = newSandbox()
    local C = { now = 1000000, envelopes = {}, blips = {}, markers = {},
                polys = {}, prints = {}, cmds = {}, sfx = {},
                pedAt = pt(0.0, 0.0), handlers = {} }

    env.GetGameTimer = function() return C.now end
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        C.prints[#C.prints + 1] = table.concat(parts, ' ')
    end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetHashKey        = function(s) return #tostring(s) end
    env.PlayerId          = function() return 0 end
    env.GetPlayerServerId = function() return 1 end
    -- HANDLERS ARE KEPT, NOT DROPPED, so C.fire can drive them. #327's preview
    -- wall waits for br_environment to say the Cayo lobby island has actually
    -- been torn down, and that arrives as a plain client event from another Lua
    -- state -- so a harness that swallows AddEventHandler cannot reach the one
    -- condition the wall is gated on, and would prove the gate by never opening
    -- it. Stored as a list per name: several handlers for one event is ordinary.
    env.AddEventHandler   = function(name, fn)
        local list = C.handlers[name]
        if not list then list = {} C.handlers[name] = list end
        list[#list + 1] = fn
    end
    env.RegisterNetEvent  = function() end
    env.RegisterCommand   = function(name, fn) C.cmds[name] = fn end
    env.TriggerServerEvent = function() end
    env.Citizen = { CreateThread = function() end, Wait = function() end,
                    SetTimeout = function() end }

    loadInto(env, SANDBOX_LIB)

    env.PlayerPedId     = function() return 1 end
    env.GetEntityCoords = function()
        return pt(C.pedAt.x, C.pedAt.y, C.pedAt.z)
    end

    -- ═══ THE MINIMAP OVERLAY MOVIE, MODELLED THE WAY IT REALLY BEHAVES (#350) ═══
    --
    -- The map draws the storm's real boundary as a filled polygon now, through the
    -- shared MINIMAP_LOADER handle. Modelled rather than swallowed, for the reason
    -- the runtime-texture store above is: a stub that accepted every push and kept
    -- nothing would let "the map is the shape" pass with no shape anywhere.
    --
    -- SO `overlays` IS THE MOVIE'S OWN ARRAY AND REM_OVERLAY SPLICES IT. That is the
    -- one thing a caller can get wrong on a handle it does not own -- removing index
    -- 2 of { 2, 3 } shifts 3 down to 2 -- and it is only a real test if the harness
    -- shifts too. `refuseAdd` and `refuseRemove` are the two refusals the engine
    -- actually performs, which is what the radius-blip fallback exists for.
    C.mm = {
        inGame = true, drawn = true, loaded = true,
        handle = 7,             -- what ScaleformUI_Assets answers with
        overlays = {},          -- the movie's array: ours and ScaleformUI's together
        asks = 0, display = nil,
        refuseAdd = false, refuseRemove = false,
        -- HOW MANY ADDS TO LET THROUGH BEFORE REFUSING, which is a different refusal
        -- from `refuseAdd` and the one that matters: a zone drawn WHOLE or not at all
        -- is only a claim when some of it got through. With every add refused there is
        -- nothing to tear down, so the teardown is unobservable.
        allowAdds = nil,
        adds = 0,
        -- ═══ AND PLACEMENT (#350), WHICH IS TWO METHODS OF THE SAME MOVIE ═══
        --
        -- UPDATE_OVERLAY_POSITION and UPDATE_OVERLAY_SIZE_OR_SCALE, reached through
        -- BR.Native.minimapMethod and the push natives like any other method -- so
        -- the stub below receives a method NAME and its parameters and plays the
        -- handler the disassembly shows, rather than trusting a Lua wrapper to say
        -- what it did. `refusePlace` is the engine declining to open either one;
        -- `calls` counts every method opened on the handle, adds and removes
        -- included, which is the number #350 is about.
        refusePlace = false,
        refuseMethod = {},      -- [name] = true refuses that one method only
        placed = 0,
        calls = 0,
        open = nil,
    }
    env.NetworkIsGameInProgress  = function() return C.mm.inGame end
    env.IsMinimapRendering       = function() return C.mm.drawn end
    env.HasMinimapOverlayLoaded  = function(h)
        return C.mm.loaded and h == C.mm.handle
    end
    env.SetMinimapOverlayDisplay = function(h, a, b, c, d, e)
        C.mm.display = { h, a, b, c, d, e }
    end

    -- The HUD envelope, and the one cross-resource ask this file makes.
    env.TriggerEvent = function(name, key, payload)
        if name == 'br:ui:sendLocal' and key == env.BR.Nui.STORM then
            C.envelopes[#C.envelopes + 1] = payload
        elseif name == 'ScUI:AddMinimapOverlay' then
            -- ScaleformUI_Assets' loader.lua: one handle for the whole client,
            -- handed back through a callback, synchronously once it is up. Counted,
            -- because "it does not ask until the session has settled" is an
            -- assertion about this number.
            C.mm.asks = C.mm.asks + 1
            if C.mm.handle ~= nil and type(key) == 'function' then
                key(C.mm.handle)
            end
        end
    end

    -- The screen grade and the sky, neither of which is this suite's subject --
    -- but both of which client/storm.lua drives every tick, and an unstubbed
    -- native would arrive as a pcall'd line in C.prints rather than a red test.
    env.SetTimecycleModifier         = function() end
    env.SetTimecycleModifierStrength = function() end
    env.ClearTimecycleModifier       = function() end
    env.AnimpostfxPlay = function() end
    env.AnimpostfxStop = function() end
    env.SetRainLevel   = function() end

    -- The wall. Position is what every assertion below reads.
    env.DrawMarker = function(_, x, y, z, _, _, _, _, _, _, sx, _, sz,
                              _, _, _, a)
        C.markers[#C.markers + 1] = { x = x, y = y, z = z, sx = sx, sz = sz, a = a }
    end
    -- ═══ AND THE QUAD STRIP, WHICH IS THE WALL SINCE #336 ═══
    --
    -- EVERY VERTEX IS KEPT, IN ORDER, because the geometry is the only thing a
    -- test can see and every claim the strip makes is a claim about it: that
    -- neighbouring quads share an edge to the last bit, that the winding the
    -- viewer is shown faces them, that the strip closes, and that two islands
    -- are two strips. A poly recorded as a centre and a width could not carry
    -- any of those.
    env.DrawPoly = function(x1, y1, z1, x2, y2, z2, x3, y3, z3, r, g, b, a)
        C.polys[#C.polys + 1] = {
            { x = x1, y = y1, z = z1 },
            { x = x2, y = y2, z = z2 },
            { x = x3, y = y3, z = z3 },
            r = r, g = g, b = b, a = a,
        }
    end

    -- ═══ AND THE TEXTURED POLY, WHICH IS THE SHIPPING WALL SINCE THE RAMP ═══
    --
    -- RECORDED INTO THE SAME C.polys AS DrawPoly, ON PURPOSE. Every geometry claim
    -- in this file -- shared seams, closure, winding, two islands, the poly budget --
    -- is a claim about the triangles and is true of the wall whichever native drew
    -- them. Splitting the record in two would have meant either duplicating those
    -- assertions or quietly losing them on the path that actually ships.
    --
    -- THE UVs AND THE TEXTURE NAMES ARE KEPT TOO, because on this path they are where
    -- the fade LIVES: the alpha is one number for the whole triangle and the ramp is
    -- in the texture, so a test that only read `a` could not tell a faded wall from a
    -- flat one. `sprite` is what tells the two records apart when that matters.
    env.DrawSpritePoly = function(x1, y1, z1, x2, y2, z2, x3, y3, z3,
                                  r, g, b, a, txd, tex,
                                  u1, v1, w1, u2, v2, w2, u3, v3, w3)
        C.polys[#C.polys + 1] = {
            { x = x1, y = y1, z = z1, u = u1, v = v1, w = w1 },
            { x = x2, y = y2, z = z2, u = u2, v = v2, w = w2 },
            { x = x3, y = y3, z = z3, u = u3, v = v3, w = w3 },
            r = r, g = g, b = b, a = a,
            txd = txd, tex = tex, sprite = true,
        }
    end

    -- ═══ THE RUNTIME TEXTURE NATIVES, MODELLED RATHER THAN SWALLOWED ═══
    --
    -- A stub that returned a handle and dropped the pixels would let every claim about
    -- the ramp pass without a ramp existing, which is precisely the failure mode this
    -- suite has twice shipped over. So the store is real: pixels are kept, commits are
    -- counted, and the two REFUSALS the engine actually performs are modelled, because
    -- they are what the fallback ladder is built against.
    --
    -- THE DUPLICATE-NAME REFUSAL IS COPIED FROM FiveM's OWN SOURCE, not guessed.
    -- code/components/extra-natives-five/src/RuntimeAssetNatives.cpp: CreateTexture
    -- returns nullptr when the name is already in the dictionary, AND -- the half that
    -- matters more -- CREATE_RUNTIME_TXD only builds its backing dictionary when the
    -- streaming slot has no handle yet, so a second call for an existing TXD NAME
    -- yields an object whose every CreateTexture returns nullptr whatever the texture
    -- is called. That is the restart hazard, and it is why a retry has to move the
    -- dictionary name and not just the texture name.
    --
    -- C.rt is the dial: `refuseTex` fails named textures, `widthLie` makes the
    -- read-back disagree, and `preTxd` pretends a dictionary already exists -- which is
    -- what a br_core restart in the same client session looks like from here.
    C.rt = { byHandle = {}, txds = {}, texs = {}, next = 500,
             refuseTex = {}, widthLie = nil, preTxd = {} }
    env.CreateRuntimeTxd = function(name)
        -- ═══ THE RUNAWAY GUARD, WHICH IS WHAT MAKES THE BOUND TESTABLE ═══
        --
        -- The name probe must be bounded or a client that refuses every name spins
        -- instead of falling back to bands. A test cannot assert that directly: with
        -- the bound removed the production loop never returns, so the suite would HANG
        -- rather than go red, and a hanging suite is indistinguishable from a slow one.
        -- So the harness imposes a ceiling far above any legitimate bound and throws
        -- through it. The frame callback is pcall'd, so the throw becomes a print that
        -- C.errored() matches -- a red test, promptly.
        C.rt.txdCalls = (C.rt.txdCalls or 0) + 1
        if C.rt.txdCalls > 500 then
            error('runaway runtime-txd name probe: the attempt loop has no bound')
        end
        local h = C.rt.next
        C.rt.next = h + 1
        local dead = C.rt.txds[name] ~= nil or C.rt.preTxd[name] == true
        C.rt.txds[name] = true
        C.rt.byHandle[h] = { kind = 'txd', name = name, dead = dead }
        return h
    end
    env.CreateRuntimeTexture = function(txd, name, w, h)
        local d = C.rt.byHandle[txd]
        if not d or d.kind ~= 'txd' then
            error('CreateRuntimeTexture on a handle that is not a runtime txd')
        end
        if d.dead then return nil end
        local key = d.name .. ':' .. name
        -- `refuseAllTex` is a client whose runtime-texture support is broken outright,
        -- which is the shape the attempt bound exists for: no name it tries will ever
        -- work, so the only correct end is the banded fallback.
        if C.rt.refuseAllTex then return nil end
        if C.rt.texs[key] or C.rt.refuseTex[name] then return nil end
        local th = C.rt.next
        C.rt.next = th + 1
        local t = { kind = 'tex', txd = d.name, name = name, w = w, h = h,
                    px = {}, written = 0, commits = 0, committedAfter = nil }
        C.rt.texs[key] = t
        C.rt.byHandle[th] = t
        C.rt.tex = t
        -- HOW MANY TEXTURES HAVE EVER BEEN MADE, which is a different question from
        -- how many times one texture was written. A rebuild loop that re-enters this
        -- native every frame lands on a FRESH texture each time -- the retry suffix
        -- sees the old name taken -- so a test watching the first texture's pixel
        -- count would see it sit still and call that "built once". Measured: with
        -- only that check, removing both latches survived the suite.
        C.rt.made = (C.rt.made or 0) + 1
        return th
    end
    env.SetRuntimeTexturePixel = function(tex, x, y, r, g, b, a)
        local t = C.rt.byHandle[tex]
        if not t or t.kind ~= 'tex' then
            error('SetRuntimeTexturePixel on a handle that is not a runtime texture')
        end
        if x < 0 or y < 0 or x >= t.w or y >= t.h then
            error(('SetRuntimeTexturePixel outside the texture: %d,%d in %dx%d')
                :format(x, y, t.w, t.h))
        end
        t.px[y] = t.px[y] or {}
        t.px[y][x] = { r = r, g = g, b = b, a = a }
        t.written = t.written + 1
    end
    env.CommitRuntimeTexture = function(tex)
        local t = C.rt.byHandle[tex]
        if not t or t.kind ~= 'tex' then
            error('CommitRuntimeTexture on a handle that is not a runtime texture')
        end
        t.commits = t.commits + 1
        -- HOW MANY PIXELS EXISTED WHEN THE COMMIT HAPPENED. A commit before the writes
        -- uploads a blank texture and is invisible in every other measure.
        t.committedAfter = t.written
    end
    env.GetRuntimeTextureWidth = function(tex)
        if C.rt.widthLie ~= nil then return C.rt.widthLie end
        local t = C.rt.byHandle[tex]
        if not t or t.kind ~= 'tex' then
            error('GetRuntimeTextureWidth on a handle that is not a runtime texture')
        end
        return t.w
    end

    -- ═══ THE STREAMING NATIVES, STUBBED SO THAT ZERO CALLS IS PROVABLE ═══
    --
    -- Nothing in the wall should touch these any more: the ramp is built in memory and
    -- this estate ships no streamed assets, which is the rule the whole design is
    -- arranged around. Left UNDEFINED, a regression that reintroduced a streamed
    -- dictionary would surface as a pcall'd error line -- true, but indistinguishable
    -- from any other throw. Counted instead, so "the wall requests no texture
    -- dictionary from the streamer" is a claim with an assertion under it.
    C.streamed = {}
    env.RequestStreamedTextureDict = function(d)
        C.streamed[#C.streamed + 1] = tostring(d)
    end
    env.HasStreamedTextureDictLoaded = function(d)
        C.streamed[#C.streamed + 1] = 'has:' .. tostring(d)
        return false
    end

    env.GetGroundZFor_3dCoord = function() return false, 0.0 end

    -- Blips are tagged by the native that made them, so the way-home arrow can
    -- be told from the two radius rings without matching display text.
    local handle = 100
    local function newBlip(kind, x, y)
        handle = handle + 1
        C.blips[handle] = { kind = kind, x = x, y = y, exists = true }
        return handle
    end
    env.AddBlipForCoord = function(x, y) return newBlip('arrow', x, y) end
    env.RemoveBlip      = function(h)
        if C.blips[h] then C.blips[h].exists = false end
    end
    env.DoesBlipExist   = function(h)
        return C.blips[h] ~= nil and C.blips[h].exists
    end
    env.SetBlipSprite       = function() end
    env.SetBlipColour       = function() end
    env.SetBlipScale        = function() end
    env.SetBlipAsShortRange = function() end
    env.SetBlipCoords       = function(h, x, y)
        if C.blips[h] then C.blips[h].x, C.blips[h].y = x, y end
    end
    env.SetBlipRotation = function(h, rot)
        if C.blips[h] then C.blips[h].rot = rot end
    end

    loadInto(env, { 'br_core/client/main.lua' })
    env.BR.Native = env.BR.Native or {}
    -- The radius, colour and alpha are recorded as well as the position: #327's
    -- preview ring is a radius blip like the other two and is told apart from
    -- them by WHICH CIRCLE it is on, which needs the radius to be readable.
    env.BR.Native.radiusBlip = function(h, x, y, r, colour, alpha, name)
        if h and C.blips[h] and C.blips[h].exists then
            C.blips[h].x, C.blips[h].y = x, y
            C.blips[h].r, C.blips[h].colour = r, colour
            C.blips[h].alpha, C.blips[h].name = alpha, name
            return h
        end
        local nh = newBlip('radius', x, y)
        C.blips[nh].r, C.blips[nh].colour = r, colour
        C.blips[nh].alpha, C.blips[nh].name = alpha, name
        return nh
    end
    -- ═══ AND THE AREA BLIP, WHICH IS THE OTHER FILLED MAP PRIMITIVE (#335) ═══
    --
    -- Recorded with its FULL width and height and its rotation, not a radius,
    -- because those are the three things the box can be wrong about: the wrong size
    -- (half-extent passed where the native wants the whole span), the wrong shape,
    -- or left spinning with the camera. `kind` is 'area' rather than 'radius', so
    -- C.rings() cannot see one and every existing assertion about "how many rings
    -- are on the map" still means what it meant -- which is what makes a squareness
    -- of zero provable rather than assumed.
    env.BR.Native.areaBlip = function(h, x, y, w, hh, rot, colour, alpha, name)
        if h and C.blips[h] and C.blips[h].exists then
            C.blips[h].x, C.blips[h].y = x, y
            C.blips[h].w, C.blips[h].h, C.blips[h].rot = w, hh, rot
            C.blips[h].colour, C.blips[h].alpha, C.blips[h].name =
                colour, alpha, name
            return h
        end
        local nh = newBlip('area', x, y)
        C.blips[nh].w, C.blips[nh].h, C.blips[nh].rot = w, hh, rot
        C.blips[nh].colour, C.blips[nh].alpha, C.blips[nh].name =
            colour, alpha, name
        return nh
    end
    env.BR.Native.blipHiddenOnLegend = function(h, hidden)
        if C.blips[h] then C.blips[h].hidden = hidden and true or false end
    end
    env.BR.Native.blipName = function(h, name)
        if C.blips[h] then C.blips[h].name = name end
    end
    -- ═══ AND THE THREE OVERLAY WRAPPERS (#350) ═══
    --
    -- THE COORDINATE FORMAT IS COPIED, NOT REACHED FOR, and that is deliberate: the
    -- movie splits on ',' then on ':' and takes two decimals, which is
    -- BR.Native.minimapAreaString's contract and tools/test_client.lua's subject.
    -- What THIS suite asserts about it is the LENGTH, because the Scaleform
    -- string-parameter cap is the one unmeasured risk on the path -- so the stub has
    -- to produce a string of the real size rather than a token.
    env.BR.Native.minimapAreaString = function(points)
        local parts = {}
        for i = 1, #points do
            parts[i] = ('%.2f:%.2f'):format(points[i].x, points[i].y)
        end
        return table.concat(parts, ',')
    end
    env.BR.Native.minimapAreaOverlay = function(h, points, outline, r, g, b, a)
        if C.mm.refuseAdd then return false end
        if h ~= C.mm.handle then return false end
        if type(points) ~= 'table' or #points < 3 then return false end
        C.mm.adds = C.mm.adds + 1
        C.mm.calls = C.mm.calls + 1
        if C.mm.allowAdds ~= nil and C.mm.adds > C.mm.allowAdds then return false end
        C.mm.overlays[#C.mm.overlays + 1] = {
            points = points, outline = outline, r = r, g = g, b = b, a = a,
            chars = #env.BR.Native.minimapAreaString(points),
        }
        return true
    end
    env.BR.Native.minimapRemoveOverlay = function(h, index)
        if C.mm.refuseRemove then return false end
        if h ~= C.mm.handle then return false end
        if type(index) ~= 'number' or index < 0 then return false end
        if C.mm.overlays[index + 1] == nil then return false end
        C.mm.calls = C.mm.calls + 1
        -- IT SPLICES. Every index above the one removed shifts DOWN by one, which is
        -- the whole reason client/mapoverlay.lua removes highest-first.
        table.remove(C.mm.overlays, index + 1)
        return true
    end

    -- ═══ THE GENERIC METHOD PATH, AND THE TWO HANDLERS IT CAN REACH (#350) ═══
    --
    -- Open, push, end -- the four-step Scaleform call natives.lua's header describes,
    -- modelled as a pending call that END dispatches by NAME. Anything this stub does
    -- not know is an error rather than a silent success, so a new method on this path
    -- arrives here as a red line and not as a test that passed over nothing.
    env.BR.Native.minimapMethod = function(h, method)
        if not h or h ~= C.mm.handle then return false end
        if C.mm.refusePlace or C.mm.refuseMethod[method] then return false end
        C.mm.open = { method = method, params = {} }
        return true
    end
    local function push(v)
        if not C.mm.open then error('a parameter pushed with no method open') end
        local p = C.mm.open.params
        p[#p + 1] = v
    end
    env.ScaleformMovieMethodAddParamInt   = push
    env.ScaleformMovieMethodAddParamFloat = push
    env.EndScaleformMovieMethod = function()
        local call = C.mm.open
        C.mm.open = nil
        if not call then error('END with no method open') end
        C.mm.calls = C.mm.calls + 1
        local p = call.params
        local ov = C.mm.overlays[(p[1] or -1) + 1]
        if not ov then error(('%s on index %s, which is not in the movie')
            :format(call.method, tostring(p[1]))) end
        -- AS THE BYTECODE HAS THEM, recorded on #350:
        --   UPDATE_OVERLAY_POSITION       txdLoader._x = x;  txdLoader._y = 0 - y
        --   UPDATE_OVERLAY_SIZE_OR_SCALE  isScaled ? _xscale/_yscale : _width/_height
        -- and an AreaOverlay has no isScaled.
        if call.method == 'UPDATE_OVERLAY_POSITION' then
            ov._x, ov._y = p[2], 0 - p[3]
        elseif call.method == 'UPDATE_OVERLAY_SIZE_OR_SCALE' then
            ov._width, ov._height = p[2], p[3]
        else
            error('the harness movie has no handler for ' .. tostring(call.method))
        end
        C.mm.placed = C.mm.placed + 1
    end

    --- WHERE THE MAP DRAWS ONE AREA, in world coordinates, after whatever the movie
    --- has been told to do to its clip.
    ---
    --- Flash's own arithmetic, one step at a time: the polygon is drawn at (x, -y) in
    --- the clip; `_width` sets the x scale so the clip's bounds come out that wide,
    --- and likewise `_height`; the clip then sits at (_x, _y); and world y is the
    --- negation of Flash y. Nothing here knows what storm.lua MEANT -- it is the
    --- movie's reading of the calls, which is what the map shows.
    function C.shown(ov)
        local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
        for _, q in ipairs(ov.points) do
            local fy = 0 - q.y
            x0, x1 = math.min(x0, q.x), math.max(x1, q.x)
            y0, y1 = math.min(y0, fy), math.max(y1, fy)
        end
        local sx = ov._width and (ov._width / (x1 - x0)) or 1.0
        local sy = ov._height and (ov._height / (y1 - y0)) or 1.0
        local out = {}
        for i, q in ipairs(ov.points) do
            local fx = q.x * sx + (ov._x or 0.0)
            local fy = (0 - q.y) * sy + (ov._y or 0.0)
            out[i] = { x = fx, y = 0 - fy }
        end
        return out
    end
    -- The sky is a CLAIM made through client/world.lua, which this suite does
    -- not load: stubbed rather than stood up, because nothing here asserts on
    -- the weather and the resolver has its own suite.
    env.BR.World = env.BR.World or {}
    env.BR.World.want = function() end
    env.BR.Sfx = { play = function(cue) C.sfx[#C.sfx + 1] = cue end }

    -- IN MANIFEST ORDER: client/mapoverlay.lua comes AFTER client/storm.lua in
    -- br_core's fxmanifest, which is why storm.lua asks for BR.MapOverlay at runtime
    -- and never at load. Loading it in the other order here would prove a
    -- dependency the game does not have.
    loadInto(env, { 'br_core/client/storm.lua', 'br_core/client/mapoverlay.lua' })

    env.BR.State.match.state = env.BR.MatchState.PLAYING
    env.BR.State.me.state    = env.BR.PlayerState.ALIVE

    --- A PHASE-2 HOLD unless a block says otherwise: the free-loot rule that
    --- zeroes dps is `phase <= 1`, so a later phase's hold is the one shape
    --- where the storm is both stationary and genuinely hurting.
    function C.record(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs, dps)
        env.BR.State.storm = {
            phase = phase,
            cx0 = cx0 + 0.0, cy0 = cy0 + 0.0, r0 = r0 + 0.0,
            cx1 = cx1 + 0.0, cy1 = cy1 + 0.0, r1 = r1 + 0.0,
            tStart = C.now, tWait = waitMs, tShrink = shrinkMs, dps = dps,
        }
        return env.BR.State.storm
    end
    C.record(2, 0.0, 0.0, 200.0, 0.0, 0.0, 200.0, 600000, 60000, 4.0)

    --- TICK passes 1.5s apart, which clears the 250ms envelope throttle.
    function C.tick(n)
        for _ = 1, (n or 1) do
            C.now = C.now + 1500
            env.BR.Loop.step(env.BR.Loop.TICK)
        end
    end

    function C.frame()
        C.now = C.now + 16
        C.markers = {}
        C.polys = {}
        env.BR.Loop.step(env.BR.Loop.FRAME)
    end

    --- Run #351's entry ramp to completion, so a block that is not about the ramp
    --- sees the preview wall at its settled strength.
    ---
    --- ═══ TWO FRAMES AND A CLOCK JUMP, AND THE FIRST FRAME IS THE POINT ═══
    ---
    --- The preview wall used to draw at full previewAlpha on the first frame the
    --- mainland was the world -- "the storm wall popped in, didn't fade in", the
    --- owner from the bus. It ramps now, over render.fadeInSec, ANCHORED ON THAT
    --- SAME FRAME: the first pass arms the ramp and draws nothing, which is why a
    --- block asserting the wall's geometry or its alpha has to come through here
    --- instead of calling C.frame() once.
    ---
    --- THE JUMP IS SAFE FOR A BLOCK THAT DRIVES THE RECORD, because every one of
    --- them sets tStart relative to C.now at the moment it wants a reading rather
    --- than once at the start -- see preview.handoff's holdAt.
    function C.settlePreview()
        C.frame()
        C.now = C.now
            + math.floor((env.BR.Config.Storm.render.fadeInSec or 10.0) * 1000.0)
        C.frame()
    end

    --- Silence the #327 preview wall, leaving only the record's own curtain in frame.
    ---
    --- ═══ NEEDED SINCE #340, AND ONLY INSIDE THE FADE WINDOW ═══
    ---
    --- The preview now holds circle 1 on screen through the whole phase-1 hold and
    --- fades out as the real wall fades in, so for the hold's last fadeInSec there are
    --- legitimately TWO walls in one frame at two different alphas. An assertion about
    --- "the alpha depends on height and on nothing else" reads their union as one wall
    --- whose alpha varies along its length, which is the picket fence -- a false red on
    --- a renderer that is doing exactly what it was asked to.
    ---
    --- THROUGH BR.Loop.setEnabled RATHER THAN BY MATCHING GEOMETRY, because that is the
    --- production switch (`/brloop disable storm.previewWall`) and the mechanism the M4
    --- authority drill already turns. Telling the two walls apart by radius would work
    --- today and would quietly stop working the first time a phase-1 target happened to
    --- sit on the opening circle.
    ---
    --- THE HANDOFF ITSELF IS ASSERTED WITH BOTH WALLS RUNNING, in `preview.handoff`.
    --- Nothing is being muted here that is not proved there.
    function C.recordWallOnly()
        if not env.BR.Loop.setEnabled('storm.previewWall', false) then
            error('no storm.previewWall callback to disable -- the name moved')
        end
    end

    --- Tick until the overlay gate is ready, or say it never was.
    ---
    --- THE GATE IS DELIBERATELY SLOW: three seconds of both session tests holding,
    --- then ten more consenting passes of HasMinimapOverlayLoaded -- because
    --- ADD_MINIMAP_OVERLAY racing RELOAD_MAP_STORE crashes the streaming DLL
    --- (citizenfx/fivem#4167). At 1500 ms a tick that is about a dozen ticks, and it
    --- only advances while something actually wants an overlay, so a caller has to
    --- set its record or its preview up FIRST.
    --- @return boolean
    function C.overlayReady()
        for _ = 1, 40 do
            if env.BR.MapOverlay.ready() then return true end
            C.tick(1)
        end
        return env.BR.MapOverlay.ready()
    end

    --- Every filled area currently in the movie, in the movie's own order.
    function C.areas() return C.mm.overlays end

    function C.last() return C.envelopes[#C.envelopes] end

    function C.arrow()
        for _, b in pairs(C.blips) do
            if b.exists and b.kind == 'arrow' then return b end
        end
        return nil
    end

    --- Every radius ring currently on the map.
    function C.rings()
        local out = {}
        for _, b in pairs(C.blips) do
            if b.exists and b.kind == 'radius' then out[#out + 1] = b end
        end
        return out
    end

    --- Every AREA box currently on the map (#335). Separate from C.rings on
    --- purpose: "no box has appeared" is half of what a squareness of zero claims.
    function C.boxes()
        local out = {}
        for _, b in pairs(C.blips) do
            if b.exists and b.kind == 'area' then out[#out + 1] = b end
        end
        return out
    end

    --- Deliver a client event to the handlers this file registered for it.
    --- @param name string
    function C.fire(name, ...)
        for _, fn in ipairs(C.handlers[name] or {}) do fn(...) end
    end

    function C.errored()
        for _, line in ipairs(C.prints) do
            if line:find('error', 1, true) then return line end
        end
        return nil
    end

    C.env = env
    return C
end

--- A client pinned to the banded fallback before it has drawn a frame.
---
--- THE PATH IS LATCHED ON THE FIRST FRAME, so this has to happen before one. Setting
--- `prefer` is the config's own way in and is what the owner would type; refusing the
--- texture in the stubs is the other way and is tested separately, because "the
--- operator asked for bands" and "the texture could not be built" are different rungs
--- and the console line has to be able to tell them apart.
local function bandedClient()
    local C = newStormClient()
    C.env.BR.Config.Storm.render.strip.fade.prefer = 'bands'
    return C
end

-- ---------------------------------------------------------------------------
-- A WHOLE MATCH'S PHASE CENTRES, which is the only way to see #327's invariant.
-- ---------------------------------------------------------------------------

--- Run one match from its storm's first record to its last, and report every
--- phase's target circle in order.
---
--- ═══ THE PHASE JOB IS RE-ENABLED HERE, AND ONLY HERE ═══
---
--- Every other block in this file stands it down, because it authors a NEW record
--- the moment a shrink finishes and would replace the specific pair of circles
--- those blocks set up. This block wants exactly that: the whole chain, each phase
--- drawn from the one before it off the match's own stream.
---
--- NO PLAYERS. The roster is emptied first, because an empty one makes the hold and
--- the sweep pricing constant -- so the only thing the walk can depend on is the
--- stream, which is the thing under test. (Positions never enter the centre draw;
--- they set tWait and tShrink. Emptying the roster means a failure cannot be
--- blamed on that.)
---
--- @param anchor table      the POI circle 1 is drawn off
--- @param predraw boolean   run BR.Storm.drawFirstCircle at WARMUP first (#327's
---                          path), or go straight to PLAYING (the route with
---                          no warmup, where BR.Storm.begin makes the same draw
---                          itself -- the order that shipped before #327)
--- @return table  { phases = { [n] = { cx, cy, r } }, first, rngAfterDraw, S }
local function walkMatch(anchor, predraw)
    local S = newStormServer()
    local env = S.env
    S.roster[1] = nil
    S.match.storm = nil
    S.match.anchor = { x = anchor.x, y = anchor.y, name = anchor.name }
    env.BR.Sched.setEnabled('storm.phase', true)

    local first, rngAfterDraw = nil, nil
    if predraw then
        S.match.state = env.BR.MatchState.WARMUP
        env.BR.Storm.drawFirstCircle(S.match)
        local f = S.match.stormFirst
        first = f and { cx = f.cx, cy = f.cy, r = f.r } or nil
        rngAfterDraw = S.match.stormRng
        S.match.state = env.BR.MatchState.PLAYING
    end

    local phases, seen = {}, {}
    local function note()
        local rec = S.match.storm
        if not rec or seen[rec.phase] then return end
        seen[rec.phase] = true
        phases[rec.phase] = { cx = rec.cx1, cy = rec.cy1, r = rec.r1 }
    end

    env.BR.Storm.begin(S.match)
    note()

    local last = #env.BR.Config.Storm.phases
    local guard = 0
    while not seen[last] and guard < 4000 do
        guard = guard + 1
        S.now = S.now + 30000
        env.BR.Sched.step(S.now)
        note()
    end

    return { phases = phases, first = first, rngAfterDraw = rngAfterDraw, S = S }
end

-- ---------------------------------------------------------------------------
describe('server.nested')
do
    -- ═══ THE PROPERTY THAT MAKES THIS CHANGE SHIPPABLE ═══
    --
    -- A nested next circle must leave the damaged set as the ONE SHAPE the wall
    -- draws, and "exactly" is the word that needed a grid rather than a handful of
    -- points: every point on the map has to get the verdict the shape's own
    -- boundary gives it -- inside the inner circle, in the annulus between them,
    -- in the cushion, and far out in the sea.
    --
    -- A change that only looked right on a Venn diagram would pass every other
    -- block in this file and fail here, which is the point of putting it first.
    --
    -- ═══ WHAT #344 CHANGED ABOUT THIS BLOCK, AND WHAT IT DID NOT ═══
    --
    -- Until every phase became a random shape, the claim here was that the billed
    -- set is EXACTLY the set `BR.Dist(...) > r + margin` billed -- because the
    -- union of a disc with a disc inside it IS the outer disc, so the #328 rule
    -- was a no-op on a nested phase. It is not a no-op any more: the zone is the
    -- containing BLOB, whose radius varies with the bearing, so the circle rule
    -- and the shape rule genuinely disagree in a band around the old rim.
    --
    -- SO THE SHIPPABILITY PROPERTY MOVED RATHER THAN WEAKENED, and it is now three
    -- claims instead of one:
    --
    --   * the billed set is the complement of the shape plus its cushion, at every
    --     point of the grid, measured by walking the boundary rather than by
    --     asking the function that decides it (see shapeProbe);
    --   * the zone is ONE closed loop -- a nested phase draws one silhouette, which
    --     is what keeps the overlapping-union artifact off every ordinary phase;
    --   * and every disagreement with the old circle rule lies INSIDE THE BAND the
    --     shape's own measurements allow. That is the assertion that would catch a
    --     shape which is the right kind and the wrong size: nothing may be billed
    --     inside the blob's own inradius, and nothing may be spared outside its own
    --     extent.
    local S = newStormServer()
    local env = S.env
    local CX, CY, R = 0.0, 0.0, 1000.0
    -- Nested with room to spare: the target's rim sits 300m inside the current
    -- one, so the annulus between them is wide enough to be sampled.
    local rec = S.record(2, CX, CY, R, 300.0, 0.0, 400.0, 600000, 60000, 2.0)
    local MARGIN = 10.0   -- a HOLDING phase pays the base cushion and no travel

    local zone = zoneOf(env, rec)
    local probe = shapeProbe(env, zone)
    local unit = env.BR.StormUnit(rec.seed, rec.phase)

    ok(zone.kind == 'blob' and #env.BR.StormShape.components(zone) == 1,
        'a nested phase is ONE shape and one closed loop, not two',
        ('%s, %d components'):format(tostring(zone.kind),
            #env.BR.StormShape.components(zone)))

    -- THE OLD RULE, SPELLED OUT RATHER THAN CALLED, so the band assertion below
    -- has something to compare against.
    local function billedByTheCircleRule(x, y)
        return (math.sqrt((x - CX) * (x - CX) + (y - CY) * (y - CY))
                > R + MARGIN)
    end

    local checked, wrong, firstWrong = 0, 0, nil
    local outsideBand, firstBand = 0, nil
    for x = -1250, 1250, 125 do
        for y = -1250, 1250, 125 do
            checked = checked + 1
            local billed = S.hurts(x + 0.0, y + 0.0)
            if billed ~= (probe(x + 0.0, y + 0.0) > MARGIN) then
                wrong = wrong + 1
                firstWrong = firstWrong or ('(%d, %d)'):format(x, y)
            end
            if billed ~= billedByTheCircleRule(x + 0.0, y + 0.0) then
                -- A disagreement is only allowed between the blob's nearest and
                -- furthest reach, plus the cushion at the outer end.
                local rad = math.sqrt(x * x + y * y)
                if rad < unit.inradius * R
                    or rad > unit.extent * R + MARGIN then
                    outsideBand = outsideBand + 1
                    firstBand = firstBand or ('(%d, %d) at radius %.0f'):format(
                        x, y, rad)
                end
            end
        end
    end
    ok(S.errored() == nil, 'the damage tick runs clean across the sweep',
        S.errored())
    ok(checked == 441, 'the sweep covers the grid it claims to', checked)
    ok(wrong == 0,
        'a nested next circle leaves the damaged set exactly as the SHAPE leaves '
            .. 'it, at every point of a 441-point sweep',
        firstWrong and ('first disagreement at ' .. firstWrong) or nil)
    ok(outsideBand == 0,
        'and every point where it disagrees with the old circle rule lies between '
            .. "the blob's own inradius and its own extent -- the shape moved the "
            .. 'boundary, it did not move the zone',
        firstBand and ('first stray at ' .. firstBand) or nil)

    -- AND THE THREE POINTS BY NAME, so a failure above says something even if
    -- the grid arithmetic is what broke. The middle and the far sea are the same
    -- two points they always were -- 1500 is outside the widest reach this shape
    -- family has -- and the annulus point is taken off the boundary itself, 20 m
    -- in, because "800 m east" is inside this blob on some bearings and outside it
    -- on others.
    ok(S.hurts(0.0, 0.0) == false, 'the middle of both circles is safe')
    local ax, ay = offBoundary(env, zone, zone.P * 0.37, -20.0)
    ok(math.sqrt(ax * ax + ay * ay) > 400.0,
        'the sampled annulus point really is outside the target circle',
        ('%.0f m from the centre'):format(math.sqrt(ax * ax + ay * ay)))
    ok(S.hurts(ax, ay) == false,
        'the annulus between the target rim and the wall is safe -- it is inside '
            .. 'the current shape, which the zone is')
    ok(S.hurts(1500.0, 0.0) == true, 'and well outside the current circle hurts')
end

-- ---------------------------------------------------------------------------
describe('server.venn')
do
    -- ═══ THE OWNER'S OWN EXAMPLE ═══
    --
    -- Two circles barely overlapping. A player who has reached the NEXT circle
    -- is standing outside the current one, and today that is billed every second
    -- -- the storm punishing the one thing it exists to force.
    local S = newStormServer()
    local env = S.env
    -- r 500 each, centres 900 apart: a proper overlap with a narrow lens.
    local rec = S.record(2, 0.0, 0.0, 500.0, 900.0, 0.0, 500.0, 600000, 60000, 2.0)
    local zone = zoneOf(env, rec)
    local probe = shapeProbe(env, zone)

    -- ═══ AND THE DAMAGE AND THE WALL AGREE AGAIN (#356) ═══
    --
    -- This block used to assert TWO components here, by name, because two
    -- overlapping blobs were concatenated rather than stitched -- curtain drawn
    -- inside the safe zone, announced in config/storm.lua and asserted the wrong
    -- way round on purpose so that the stitch would turn it red. The stitch has
    -- landed: both boundaries are one loop, and it is the KIND that carries the
    -- union rather than the component count.
    --
    -- THE DAMAGE DID NOT MOVE, WHICH IS THE POINT OF LEAVING THIS BLOCK WHERE IT
    -- IS. A signed distance to a union is the minimum over its parts whatever the
    -- parts are, `parts` is unchanged, and every `S.hurts` below answers exactly
    -- what it answered before. Measured directly as well: distance() is
    -- bit-identical across 1.5 million points on 750 reachable geometries.
    ok(zone.kind == 'blobUnion'
        and #env.BR.StormShape.components(zone) == 1,
        'an overlapping breakout is ONE stitched loop -- the two boundaries are '
            .. 'joined at their crossings (#356)',
        ('%s, %d component(s)'):format(tostring(zone.kind),
            #env.BR.StormShape.components(zone)))

    ok(S.hurts(900.0, 0.0) == false,
        'a player who got to the new destination early is SAFE at its centre, '
            .. 'where the circle rule billed them 400m outside')
    ok(S.hurts(0.0, 0.0) == false, 'and the current shape is still safe')
    ok(S.hurts(450.0, 0.0) == false,
        'and the lens where the two overlap is safe from both directions')

    -- OUTSIDE BOTH IS STILL OUTSIDE. The union adds ground, it does not stop
    -- being a boundary: a point off the side of the pair, inside neither shape,
    -- is billed exactly as it always was.
    ok(S.hurts(0.0, 700.0) == true,
        'off the side of the pair, inside neither shape, still hurts')
    ok(S.hurts(1400.0, 900.0) == true, 'and so does past the far one')

    -- THE WHOLE PLANE, AGAINST THE GEOMETRY. The predicate is "inside one of the
    -- two shapes, or within the cushion of one of them", walked off the boundary
    -- rather than read out of the function that decides it.
    local MARGIN = 10.0
    local checked, wrong, firstWrong = 0, 0, nil
    for x = -800, 2200, 150 do
        for y = -1000, 1000, 125 do
            local expect = probe(x + 0.0, y + 0.0) > MARGIN
            checked = checked + 1
            if S.hurts(x + 0.0, y + 0.0) ~= expect then
                wrong = wrong + 1
                firstWrong = firstWrong or ('(%d, %d)'):format(x, y)
            end
        end
    end
    ok(S.errored() == nil, 'the Venn sweep runs clean', S.errored())
    ok(wrong == 0,
        ('the billed set is the complement of the union plus its cushion, at '
            .. 'every one of %d points'):format(checked),
        firstWrong and ('first disagreement at ' .. firstWrong) or nil)

    -- AND THE MINIMUM IS WHAT MAKES THAT TRUE, so it is asserted as a minimum:
    -- the zone's own distance is the smaller of the two parts' everywhere, which is
    -- the property that survives any shape at all.
    local notMin = 0
    for x = -800, 2200, 200 do
        for y = -1000, 1000, 200 do
            local a = env.BR.StormShape.distance(zone.parts[1], x + 0.0, y + 0.0)
            local b = env.BR.StormShape.distance(zone.parts[2], x + 0.0, y + 0.0)
            local want = (a < b) and a or b
            if not near(env.BR.StormShape.distance(zone, x + 0.0, y + 0.0),
                        want, 1e-9) then
                notMin = notMin + 1
            end
        end
    end
    ok(notMin == 0,
        "the union's signed distance is the minimum of its parts', everywhere",
        notMin)
end

-- ---------------------------------------------------------------------------
describe('server.disjoint')
do
    -- ═══ TWO ISLANDS AND AN UNSAFE GAP, WHICH IS SETTLED ═══
    --
    --   "the far circle should be safe, that's fine."   -- owner, 2026-09-21
    --
    -- The union of two separated discs has TWO COMPONENTS. That is what the
    -- geometry says and it is the intended reading rather than a case wanting a
    -- special rule: a player who has crossed to the far circle has earned it,
    -- and the ground they crossed is not safe just because both ends of it are.
    --
    -- The solver really produces this pair. A breakout separates the circles
    -- entirely and caps the gap between their edges at gapMax times the
    -- predecessor's radius -- 0.5 in the shipped config.
    local S = newStormServer()
    -- Current r 400 at the origin; target r 300 at 1200m. Edges 500m apart,
    -- which is 1.25 predecessor radii: wider than the shipped cap, chosen so the
    -- gap is unambiguous rather than sitting inside a cushion.
    S.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 2.0)

    ok(S.hurts(1200.0, 0.0) == false,
        'the far circle is safe, standing at its centre')
    ok(S.hurts(1450.0, 0.0) == false,
        'and out to its own rim, on the far side away from the current circle')
    ok(S.hurts(0.0, 0.0) == false, 'the current circle is still safe')
    ok(S.hurts(700.0, 0.0) == true,
        'and the ground between the two islands hurts, which is what makes them '
            .. 'islands')
    ok(S.hurts(600.0, 200.0) == true, 'off the centre line as well as on it')

    -- NEITHER ISLAND LEAKS INTO THE OTHER. The failure a min() of two distances
    -- cannot make, asserted anyway because the alternative implementations can:
    -- a capsule through both centres, or a circle grown to cover both, would
    -- both call the gap safe.
    local leaked = 0
    for x = 450, 880, 10 do
        if not S.hurts(x + 0.0, 0.0) then leaked = leaked + 1 end
    end
    ok(leaked == 0,
        'no point in the gap is safe -- the zone is two discs, not a capsule '
            .. 'through them or a circle around them',
        ('%d safe points in the gap'):format(leaked))
end

-- ---------------------------------------------------------------------------
describe('server.collapse')
do
    -- ═══ IT IS SELF-CLOSING, AND THAT IS WHY IT CAN HOLD ALL PHASE ═══
    --
    -- The open question in #328 was whether the union holds for the whole phase
    -- or only until the shrink begins. Holding it through the shrink is simpler
    -- AND it closes itself: the current circle travels to the target as the
    -- sweep runs, so the two converge and the union collapses onto ONE circle
    -- exactly when the sweep ends. Nothing has to notice the moment or switch
    -- rules at it.
    --
    -- THE FAILURE THIS PREVENTS is a safe island left standing at the old
    -- circle's position after the wall has left it, which would be a permanent
    -- hole in the endgame: a player parked at the phase-7 centre never taking
    -- damage while the match tried to end around them.
    local S = newStormServer()
    local WAIT, SHRINK = 1000.0, 10000.0
    S.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, WAIT, SHRINK, 2.0)

    -- While the wall is still holding, both islands are safe.
    ok(S.hurts(0.0, 0.0) == false, 'during the hold the old circle is safe')
    ok(S.hurts(1200.0, 0.0) == false, 'and so is the new one')

    -- Run the clock past the end of the sweep. BR.StormAt then answers
    -- (cx1, cy1, r1) and FINISHED, so union2 is handed the same circle twice and
    -- returns that circle -- the union has collapsed with nothing to do it.
    S.now = S.now + WAIT + SHRINK + 2000
    ok(S.hurts(1200.0, 0.0) == false,
        'after the sweep the target circle is the safe zone')
    ok(S.hurts(0.0, 0.0) == true,
        'and the ground the wall came FROM is not -- the union collapsed onto '
            .. 'the one circle rather than leaving an island behind')
    ok(S.hurts(600.0, 0.0) == true, 'nor is anything between the two')
    ok(S.errored() == nil, 'the collapse runs clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('server.margin')
do
    -- ═══ THE EDGE CUSHION STILL APPLIES AND STILL MEANS WHAT IT MEANT ═══
    --
    -- Damage starts a margin OUTSIDE the edge because three clocks disagree at
    -- the knife edge -- this tick, the half-second-old position sample, and the
    -- client's own view of the wall -- and because during a shrink the wall
    -- moves metres per second. The live reports it answers are players hurt
    -- while standing 20 to 50 feet INSIDE the curtain.
    --
    -- Under the union the cushion is unchanged and it is now slack outside
    -- WHICHEVER piece of boundary is nearest. Asserted on the far island, which
    -- is the piece that did not exist before this change: a cushion applied only
    -- to the current circle would hurt a player a metre outside the destination
    -- they had just run to.
    -- ═══ AND THE POINTS ARE TAKEN OFF THE BOUNDARY NOW, NOT OFF THE RADIUS ═══
    --
    -- "Five metres outside the far island" used to be `1200 + 300 + 5` on the
    -- centre line. On a shape whose radius depends on the bearing that arithmetic
    -- names a point which is five metres outside NOTHING -- it can be sixty metres
    -- inside the blob or eighty outside it -- so a cushion assertion written that
    -- way would be measuring the jitter draw. offBoundary walks to the boundary and
    -- steps off it, so the number in the test's own name is the distance it means.
    local S = newStormServer()
    local env = S.env
    local rec = S.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 2.0)
    local zone = zoneOf(env, rec)
    local comps = env.BR.StormShape.components(zone)
    ok(#comps == 2, 'the disjoint pair really is two components', #comps)

    -- Component 2 is the FAR island: blobUnion appends the target's loop second.
    local far = comps[2]
    local fx, fy = offBoundary(env, zone, far.s0 + far.len * 0.5, 5.0)
    ok(S.hurts(fx, fy) == false,
        'five metres outside the FAR island is inside the cushion')
    fx, fy = offBoundary(env, zone, far.s0 + far.len * 0.5, 25.0)
    ok(S.hurts(fx, fy) == true,
        'and twenty-five metres outside it is not -- the cushion is ten metres, '
            .. 'not a licence')
    local nx, ny = offBoundary(env, zone, comps[1].len * 0.5, 5.0)
    ok(S.hurts(nx, ny) == false,
        'the same five metres outside the CURRENT shape is still safe, exactly '
            .. 'as it always was')

    -- AND THE TRAVEL TERM STILL RIDES A SHRINK. The cushion grows by ~0.7s of
    -- wall travel while the wall is moving, which is what keeps a player at the
    -- visible curtain safe when the curtain is doing 100 m/s. A build that
    -- measured against the union but dropped the travel term would pass every
    -- assertion above.
    local T = newStormServer()
    -- 1000m of radius surrendered in 10s is 100 m/s of wall, so the cushion is
    -- 10 + 100 * 0.7 = 80 metres for the whole sweep. A 1s hold in front of it,
    -- and each probe is taken 6000ms into the phase -- 5000ms into the sweep,
    -- half way, where the radius is 1500.
    local trec = T.record(2, 0.0, 0.0, 2000.0, 0.0, 0.0, 1000.0,
        1000.0, 10000.0, 2.0)
    -- THE SHAPE AT THE MOMENT OF THE PROBE, which is the travelling wall rather
    -- than the record's opening circle: r 1500, centre unmoved.
    local moving = T.env.BR.StormZone(trec, 0.0, 0.0, 1500.0)
    local function offMoving(m)
        return offBoundary(T.env, moving, moving.P * 0.21, m)
    end
    local x1, y1 = offMoving(50.0)
    local x2, y2 = offMoving(150.0)
    local x3, y3 = offMoving(70.0)
    T.at(6000); ok(T.hurts(x1, y1) == false,
        'fifty metres outside a wall doing 100 m/s is inside the moving cushion')
    T.at(6000); ok(T.hurts(x2, y2) == true,
        'a hundred and fifty metres outside it is not')
    T.at(6000); ok(T.hurts(x3, y3) == false,
        'and seventy metres out is still inside it, which the base ten-metre '
            .. 'cushion alone would have billed')
    ok(T.errored() == nil, 'the shrinking pass runs clean', T.errored())
end

-- ---------------------------------------------------------------------------
describe('server.ledger')
do
    -- A PLAYER OUTSIDE BOTH IS BILLED EXACTLY AS BEFORE, all the way to the
    -- elimination. The union changed WHERE the boundary is and nothing about
    -- what crossing it costs, so the ledger, the wire and the defeat still
    -- behave as they did -- which is worth an assertion because the inside
    -- branch of that test is the one that clears `stormHp`, and a rule that
    -- returned early in the wrong direction would look like a player who is
    -- simply good at staying in the circle.
    local S = newStormServer()
    S.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 6.0)

    local e = S.env.BR.Roster.get(1)
    e.pos = { x = 700.0, y = 0.0, z = 30.0 }   -- in the gap
    S.tick()
    local first = e.stormHp
    ok(first ~= nil and first < 100.0, 'the ledger opens below full health',
        tostring(first))
    S.tick()
    ok(e.stormHp ~= nil and e.stormHp < first,
        'and runs down every tick they spend out there',
        ('%s -> %s'):format(tostring(first), tostring(e.stormHp)))

    local wire = 0
    for _, h in ipairs(S.out) do
        if h.event == S.env.BR.Net.STORM_DAMAGE then wire = wire + 1 end
    end
    ok(wire >= 1, 'the client is told to hurt its ped', wire)

    -- AND THE ELIMINATION STILL COMES FROM THE LEDGER. Sixteen more seconds at
    -- 6 dps takes 100 display points off, whatever the ped is doing.
    for _ = 1, 20 do S.tick() end
    ok(S.defeated[1] == true,
        'and the ledger kill still lands on a player who stays in the gap')

    -- WALKING INTO THE FAR ISLAND STOPS IT, which is the whole feature seen
    -- from the ledger's side rather than from a boolean.
    local T = newStormServer()
    T.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 6.0)
    local f = T.env.BR.Roster.get(1)
    f.pos = { x = 700.0, y = 0.0, z = 30.0 }
    T.tick()
    ok(f.stormHp ~= nil, 'a player in the gap has a ledger')
    f.pos = { x = 1200.0, y = 0.0, z = 30.0 }
    T.tick()
    ok(f.stormHp == nil,
        'and reaching the new destination closes it -- the ledger re-seeds from '
            .. 'sampled reality next time they are caught out')
    ok(T.defeated[1] == nil, 'nobody is eliminated for having made the run')
end

-- ---------------------------------------------------------------------------
describe('client.edge')
do
    -- ═══ ONE SIGNED DISTANCE, FOUR READOUTS ═══
    --
    -- `edge` is what the HUD's metres, the screen grade, the sky and the pair of
    -- crossing cues are all measured from. It used to be `dist - r`, a circle's
    -- signed distance written out by hand; it is the signed distance to the
    -- union now, so all four move together.
    --
    -- THE FAILURE THIS PREVENTS is the client disagreeing with the server about
    -- who is safe. A player standing in the next circle would be told they are
    -- 800m outside, shown a red screen and a thunderstorm, and charged nothing
    -- at all -- which reads as the storm being broken rather than as the rule
    -- working.
    local C = newStormClient()
    local env = C.env
    local rec = C.record(2, 0.0, 0.0, 500.0, 900.0, 0.0, 500.0, 600000, 60000, 4.0)
    local zone = zoneOf(env, rec)
    local probe = shapeProbe(env, zone)

    local function edgeAt(x, y)
        C.pedAt = pt(x, y)
        C.tick(2)
        local e = C.last()
        return e and e.edgeDistance
    end

    -- ═══ THE METRES COME OFF THE SHAPE NOW, NOT OFF A RADIUS (#344) ═══
    --
    -- "The middle of a 500 m circle reads 500 m inside" was a fact about a circle.
    -- The zone is a blob, so the depth at its centre is its INRADIUS -- a number
    -- the jitter draw decides -- and a literal here would be asserting the draw.
    -- The probe walks the boundary for it, which is a different derivation from the
    -- one the client uses, so the two agreeing is still evidence.
    --
    -- THE TEETH ARE UNMOVED, and they were never the magnitude. Every case below
    -- turns on WHICH PART of the zone is measured: the middle of the NEXT shape
    -- reads INSIDE, where the pre-#328 circle rule read 400 m outside, and no
    -- current-circle-only implementation can produce that whatever the shape is.
    ok(near(edgeAt(0.0, 0.0), probe(0.0, 0.0), 0.5),
        'the middle of the current shape reads its own depth inside',
        ('%s against %.2f'):format(tostring(edgeAt(0.0, 0.0)), probe(0.0, 0.0)))
    ok(edgeAt(900.0, 0.0) < 0.0
        and near(edgeAt(900.0, 0.0), probe(900.0, 0.0), 0.5),
        'and the middle of the NEXT shape reads INSIDE too, where the circle rule '
            .. 'read 400m OUTSIDE',
        ('%s against %.2f'):format(tostring(edgeAt(900.0, 0.0)), probe(900.0, 0.0)))
    -- ═══ THE LENS IS THE ONE PLACE THE MAGNITUDE IS DELIBERATELY SHALLOW ═══
    --
    -- Strictly inside an overlap, distance() is the minimum over the PARTS, and a
    -- part's own nearest boundary point can be one the other part has swallowed --
    -- so the magnitude understates the depth. distance()'s header has always said
    -- so; what changed with #356 is that the probe stopped sharing the
    -- understatement. It walks the boundary, the boundary is one stitched loop with
    -- nothing inside the zone any more, so it now answers the TRUTH: 137 m at the
    -- waist against the 61 m the readout gives.
    --
    -- SO THE CLAIM IS SPLIT RATHER THAN LOOSENED, and the half that matters is
    -- kept exact. The SIGN is what the grade, the sky and the two cues read, and it
    -- is asserted below across the whole sweep. The magnitude is asserted to be
    -- inside, to be no DEEPER than the truth -- shallow is the safe direction,
    -- nothing can be told it is safely inside when it is not -- and to be exactly
    -- the minimum over the parts, which is what the function claims to be rather
    -- than what a walk of the outline would give.
    local lens, lensTruth = edgeAt(450.0, 0.0), probe(450.0, 0.0)
    local lensMin = math.huge
    for _, part in ipairs(zone.parts or { zone }) do
        local d = env.BR.StormShape.distance(part, 450.0, 0.0)
        if d < lensMin then lensMin = d end
    end
    ok(lens ~= nil and lens < 0.0 and lens >= lensTruth - 1e-6
        and near(lens, lensMin, 1e-6),
        'the lens between them reads inside, at the minimum over the parts, which '
            .. 'is SHALLOWER than the walked truth and never deeper',
        ('%s, parts min %.2f, walked truth %.2f')
            :format(tostring(lens), lensMin, lensTruth))
    ok(edgeAt(0.0, 700.0) > 0.0
        and near(edgeAt(0.0, 700.0), probe(0.0, 700.0), 0.5),
        'and off the side of the pair, inside neither, it reads positive',
        ('%s against %.2f'):format(tostring(edgeAt(0.0, 700.0)), probe(0.0, 700.0)))
    ok(C.errored() == nil, 'the client storm callbacks run clean', C.errored())

    -- THE SIGN IS THE PART THE GRADE AND THE SKY READ, so it is asserted as a
    -- sign rather than only as a magnitude, on a sweep that crosses both shapes
    -- and the gap. A nested-only implementation gets the left half of this right
    -- and the right half backwards.
    local wrongSign, firstWrong = 0, nil
    for x = -800, 1800, 100 do
        local expectInside = probe(x + 0.0, 0.0) < 0.0
        local got = edgeAt(x + 0.0, 0.0)
        if (got ~= nil and got < 0.0) ~= expectInside then
            wrongSign = wrongSign + 1
            firstWrong = firstWrong or tostring(x)
        end
    end
    ok(wrongSign == 0,
        'and the sign is negative inside EITHER shape and positive outside '
            .. 'both, all the way across',
        firstWrong and ('first wrong at x = ' .. firstWrong) or nil)

    -- ═══ AND THE FRAME BAND READS THE SAME ZONE ═══
    --
    -- "How far outside am I" is pushed at frame rate, because it is the one
    -- number a player reads while moving. It measures against the shape the 10Hz
    -- band built rather than rebuilding it, and a frame band still subtracting a
    -- radius from a distance would disagree with the tick band in metres, four
    -- times a second, on the same screen.
    --
    -- MEASURED FROM BEYOND THE FAR CIRCLE, WHICH IS WHAT MAKES IT A TEST. At
    -- (1600, 0) the CURRENT circle is 1100m away and the next one is 200m away,
    -- so a frame band reading the old circle would say 1100 where the tick band
    -- says 200. It also has to be somewhere OUTSIDE: inside the zone this
    -- callback is one boolean test per frame and returns, by design.
    C.pedAt = pt(1600.0, 0.0)
    C.tick(2)
    local held = C.last() and C.last().edgeDistance
    -- TEN METRES STRAIGHT AT THE NEAREST POINT OF THE BOUNDARY, found by nearestArc
    -- -- a different derivation from the signed distance under test. Distance to a
    -- convex shape falls by exactly the step along that line, whatever the shape;
    -- "ten metres west" only did while the target was drawn in the current zone's
    -- shape and its nearest point happened to lie due west.
    local SS = env.BR.StormShape
    local nx, ny = SS.pointAtArc(zone, SS.nearestArc(zone, 1600.0, 0.0))
    local len = math.sqrt((nx - 1600.0) ^ 2 + ny ^ 2)
    C.pedAt = pt(1600.0 + (nx - 1600.0) / len * 10.0, ny / len * 10.0)
    C.frame()
    local moved = C.last() and C.last().edgeDistance
    -- THE NUMBER IS THE FAR SHAPE'S, WHICH IS THE WHOLE TEST. At (1600, 0) the
    -- current shape is about 1100 m away and the target about 200: a frame band
    -- reading the old circle would be off by nine hundred metres, which no shape
    -- change can disguise.
    ok(held ~= nil and near(held, probe(1600.0, 0.0), 0.5) and held < 400.0,
        'the tick band measures off the NEXT shape, not 1100m from the current one',
        ('%s against %.2f'):format(tostring(held), probe(1600.0, 0.0)))
    ok(moved ~= nil and near(moved, held - 10.0, 0.05),
        'and a frame that walks 10m toward it moves the readout 10m, against '
            .. 'the same union', ('%s -> %s'):format(tostring(held),
            tostring(moved)))
end

-- ---------------------------------------------------------------------------
describe('client.arrow')
do
    -- ═══ THE WAY-HOME ARROW STILL AIMS AT THE NEXT CIRCLE, AND THAT IS A
    --     DECISION RATHER THAN AN OVERSIGHT ═══
    --
    -- It sits at the nearest safe point just inside the TARGET's edge, whenever
    -- the viewer is outside that target (user call, 2026-08-04: during the
    -- phase-1 hold "outside the current circle" is impossible, and outside the
    -- target is exactly when guidance matters).
    --
    -- The instinct after #328 is to measure it against the union like the edge.
    -- That would point it at the CURRENT circle's rim on every ordinary nested
    -- phase, which is away from the ring the player is being asked to rotate to,
    -- and on a disjoint pair it would swap islands as they crossed the middle.
    -- This block is what makes that change fail rather than ship.
    local C = newStormClient()
    -- Disjoint: current r 400 at the origin, target r 300 at 1200m.
    C.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 4.0)

    -- Standing safely in the CURRENT circle, outside the target.
    C.pedAt = pt(0.0, 0.0)
    C.tick(2)
    local a = C.arrow()
    ok(a ~= nil,
        'a player safe in the current circle of a separated pair still gets the '
            .. 'arrow, because the destination is still somewhere else')
    -- 1200 - (300 - 25) = 925, on the near side of the target's rim. The
    -- union's own nearest boundary point from here is at NEGATIVE x, so this
    -- number is what tells the two apart.
    ok(a ~= nil and near(a.x, 925.0, 0.5) and near(a.y, 0.0, 0.5),
        'and it points ACROSS THE GAP at the target rim, not back at the '
            .. 'current circle behind them',
        a and ('%s, %s'):format(tostring(a.x), tostring(a.y)))
    ok(C.last() ~= nil and C.last().edgeDistance < 0.0,
        'while the edge readout says they are safe where they stand -- the two '
            .. 'answer different questions on purpose',
        C.last() and C.last().edgeDistance)

    -- AND IT GOES AWAY ON ARRIVAL, not on becoming safe. A player who crosses
    -- to the far island is inside the target, so there is nothing left to guide
    -- them to.
    C.pedAt = pt(1200.0, 0.0)
    C.tick(2)
    ok(C.arrow() == nil, 'reaching the destination takes the arrow away')

    -- NO FLIP IN THE MIDDLE. Walked across the gap, the arrow keeps naming one
    -- place: every sample is on the target's near rim, monotonically closer,
    -- and never once on the circle behind.
    local D = newStormClient()
    D.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 4.0)
    local flips, lastX = 0, nil
    for x = 0, 800, 50 do
        D.pedAt = pt(x + 0.0, 0.0)
        D.tick(1)
        local b = D.arrow()
        if not b or not near(b.x, 925.0, 0.5) then flips = flips + 1 end
        lastX = b and b.x or nil
    end
    ok(flips == 0,
        'and walking the whole gap never makes it change its mind about which '
            .. 'island it is naming',
        ('%d samples off the target rim, last at %s'):format(flips,
            tostring(lastX)))
end

-- ---------------------------------------------------------------------------
describe('wall.default')
do
    -- ═══ THE DEFAULT IS THE QUAD STRIP, AND NOTHING DRAWS A MARKER ANY MORE ═══
    --
    -- Three global defaults have now been wrong. 'solid' is one DrawMarker type 1 --
    -- a cylinder, and therefore a circle by construction -- so left as the default
    -- after #328 it paints a curtain straight through a player standing safely in
    -- the next circle. 'columns' draws any shape but is capped at maxDraw 80, so on
    -- the phases that NEST (60 to 90 percent of them) it drew 15 percent of the ring
    -- at phase 1, 24 at phase 2, 40 at phase 3 and 64 at phase 4: a curtain stopping
    -- in mid-air. And deciding between the two per shape, which is what #328 settled
    -- on, still leaves every union looking like a picket fence -- which is the
    -- report this block now pins:
    --
    --   "what you just drew is not a wall - it's a bunch of circles which are the
    --    wrong height and you're still using 3dmarkers..... I thought you were
    --    going to research ways to not do that."     -- the owner, 2026-09-22, #336
    --
    -- SO THE ASSERTION IS THE LITERAL WORDS: no 3d markers. Not "fewer", not "only
    -- on a circle" -- none, on either shape, on the automatic path. The shape has
    -- nothing left to choose between because the strip has neither limit.
    local C = newStormClient()
    ok(C.env.BR.Storm.wallStyle == nil,
        'there is still no global default in the variable: nil is automatic',
        tostring(C.env.BR.Storm.wallStyle))

    local inset = C.env.BR.Config.Storm.render.edgeInset
    C.record(2, 0.0, 0.0, 350.0, 100.0, 0.0, 150.0, 600000, 60000, 4.0)
    C.pedAt = pt(0.0, 0.0)
    C.frame()
    ok(#C.markers == 0 and #C.polys > 0,
        'a nested phase draws the quad strip and not one 3d marker',
        ('%d markers, %d polys'):format(#C.markers, #C.polys))

    -- AND SO DOES A UNION, which is the shape that used to be the fence.
    C.record(2, 0.0, 0.0, 200.0, 360.0, 0.0, 200.0, 600000, 60000, 4.0)
    C.frame()
    ok(#C.markers == 0 and #C.polys > 0,
        'and so does a union -- the shape that used to get the colonnade',
        ('%d markers, %d polys'):format(#C.markers, #C.polys))

    -- /brwallstyle REACHES ALL THREE AND COMES BACK TO AUTOMATIC. The A/B is how
    -- the strip gets judged against the only other seamless wall the game has ever
    -- drawn, and it is the one command that puts a bad night back on known ground
    -- without a deploy. FOUR STATES, not three: with three there would be no way
    -- back to automatic once a session had typed it, and with two the strip could
    -- not be named at all -- which matters the day automatic changes again.
    ok(C.cmds.brwallstyle ~= nil, '/brwallstyle is still registered')
    C.cmds.brwallstyle()
    ok(C.env.BR.Storm.wallStyle == 'solid', 'and forces the single cylinder',
        tostring(C.env.BR.Storm.wallStyle))
    C.cmds.brwallstyle()
    ok(C.env.BR.Storm.wallStyle == 'columns', 'then forces the marker walk',
        tostring(C.env.BR.Storm.wallStyle))
    C.cmds.brwallstyle()
    ok(C.env.BR.Storm.wallStyle == 'strip', 'then names the quad strip outright',
        tostring(C.env.BR.Storm.wallStyle))
    C.cmds.brwallstyle()
    ok(C.env.BR.Storm.wallStyle == nil, 'then hands the choice back to automatic',
        tostring(C.env.BR.Storm.wallStyle))

    -- A FORCED 'solid' IS STILL THE CYLINDER IT WAS ON 2026-08-03, at the inset
    -- radius, on the fixed base below sea level. That is what makes it a BASELINE
    -- rather than dead code: the A/B is only worth typing if the thing on the other
    -- side of the switch has not drifted.
    local S = newStormClient()
    S.env.BR.Storm.wallStyle = 'solid'
    S.record(2, 0.0, 0.0, 350.0, 100.0, 0.0, 150.0, 600000, 60000, 4.0)
    S.pedAt = pt(0.0, 0.0)
    S.frame()
    ok(#S.markers == 1 and #S.polys == 0,
        'a forced solid is ONE cylinder and no polys at all', #S.markers)
    local m = S.markers[1]
    ok(m ~= nil and near(m.x, 0.0, 1e-9) and near(m.y, 0.0, 1e-9)
        and near(m.sx, (350.0 - inset) * 2.0, 1e-9),
        'centred on the circle and edgeInset inside the logical edge, exactly as '
            .. 'it was on 2026-08-03',
        m and ('%.3f, %.3f, scale %.3f'):format(m.x, m.y, m.sx))

    -- AND A FORCED 'columns' IS STILL THE FENCE, which is the other half of the
    -- comparison: the owner has to be able to put the thing he reported back on
    -- screen beside the thing that replaced it.
    local K = newStormClient()
    K.env.BR.Storm.wallStyle = 'columns'
    K.record(2, 0.0, 0.0, 200.0, 360.0, 0.0, 200.0, 600000, 60000, 4.0)
    K.pedAt = pt(0.0, 0.0)
    K.frame()
    ok(#K.markers > 40 and #K.polys == 0,
        'a forced columns is still the marker walk it always was', #K.markers)

    -- ═══ AND HOW MANY LOOPS THE WALL DRAWS ACROSS A WHOLE PHASE, WHICH IS THE
    --     PROPERTY #344 MADE LOAD-BEARING ═══
    --
    -- THIS USED TO COUNT `discs` AND ASK WHETHER THE RENDERER SWAPPED. Nothing
    -- chooses a renderer from the shape any more -- the strip draws every shape, and
    -- /brwallstyle is the only thing left that can ask for a marker -- so that
    -- question was answered by construction while its DERIVATION had quietly stopped
    -- describing the shipping wall: it counted the discs of a union of CIRCLES, and
    -- the zone is a pair of blobs.
    --
    -- THE LIVE QUESTION AT THE SAME SAMPLE POINTS IS THE COMPONENT COUNT, and it is
    -- worth more than the old one. One loop is a single clean silhouette; two is a
    -- pair of ISLANDS, which is the honest picture for a zone whose two halves do
    -- not touch and was, until #356, also what an OVERLAPPING pair got -- two whole
    -- boundaries with curtain inside the safe zone.
    --
    -- ═══ SO THE THREE CASES ARE NOW SEPARATED, AND THE MIDDLE ONE IS THE FIX ═══
    --
    -- A nested phase is one loop throughout, as it always was. An overlapping
    -- breakout is now one loop throughout as well -- that assertion read `two` here
    -- on purpose so that the stitch would turn it red (#356). A DISJOINT breakout is
    -- still two until the sweep brings the halves together, and that case is
    -- asserted by name for exactly one reason: the stitch must not have eaten it.
    -- Two islands kilometres apart drawn as one loop would bridge them with a quad
    -- across the sea.
    local function loopsAcross(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs)
        local E = newStormClient()
        local SS = E.env.BR.StormShape
        local ei = E.env.BR.Config.Storm.render.edgeInset
        local rec = E.record(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs, 2.0)
        local flips, prev, first, total = 0, nil, nil, waitMs + shrinkMs
        for k = 0, 400 do
            -- AT THE SWEEP FRACTION THE SOLVER REPORTS, which is what the wall passes:
            -- the current shape morphs into the target's across the sweep.
            local sx, sy, sr, _, _, _, st =
                E.env.BR.StormAt(rec, rec.tStart + total * (k / 400))
            local n = #SS.components(
                SS.inset(E.env.BR.StormZone(rec, sx, sy, sr, st), ei))
            if prev ~= nil and n ~= prev then flips = flips + 1 end
            first = first or n
            prev = n
        end
        return flips, prev, first
    end

    local nFlips, nEnd = loopsAcross(2, 0, 0, 2600, 400, 0, 1600, 120000, 120000)
    ok(nFlips == 0 and nEnd == 1,
        'a nested phase is ONE closed loop from its first frame to its last -- no '
            .. 'ordinary phase ever shows the overlapping-union artifact',
        ('%d changes, ends on %d loop(s)'):format(nFlips, nEnd))

    -- r 950 at the origin closing on r 520 at 1150: 1150 is well inside 950 + 520, so
    -- the two boundaries genuinely cross at the first frame.
    --
    -- IT WAS 1350, AND THE ZONES BEING TWO SHAPES IS WHY IT MOVED. At 1350 the
    -- CIRCLES overlap by 120 m, and so did the shapes while both wore one unit; zone
    -- 3's and zone 4's own shapes at this seed overlap by less than the twelve metres
    -- the wall's inset takes off the two of them together, so the curtain drawn six
    -- metres inside each is honestly two loops at the first frame. That is geometry
    -- rather than the stitch -- `blob.stitch.sweep` is the stitch -- and this
    -- assertion is about a pair that overlaps.
    local bFlips, bEnd, bFirst = loopsAcross(4, 0, 0, 950, 1150, 0, 520, 75000, 187500)
    ok(bFlips == 0 and bFirst == 1 and bEnd == 1,
        'and an OVERLAPPING breakout is one stitched loop from its first frame to '
            .. 'its last -- this is the assertion #356 inverted',
        ('%d changes, %d loop(s) to %d'):format(bFlips, bFirst, bEnd))

    -- r 950 at the origin closing on r 260 at 1800: 1800 is well past 950 + 260, so
    -- these are two islands with open ground between them.
    local dFlips, dEnd, dFirst = loopsAcross(5, 0, 0, 950, 1800, 0, 260, 60000, 150000)
    ok(dFlips == 1 and dFirst == 2 and dEnd == 1,
        'and a DISJOINT breakout is still two islands until the sweep brings them '
            .. 'together, changing exactly once',
        ('%d changes, %d loop(s) to %d'):format(dFlips, dFirst, dEnd))

    -- A FORCED 'solid' ON A UNION STILL DRAWS ONE DISC, which is the known lie
    -- the A/B is measured against rather than a second bug: it is only reachable
    -- by typing the command.
    local D = newStormClient()
    D.record(2, 0.0, 0.0, 200.0, 360.0, 0.0, 200.0, 600000, 60000, 4.0)
    D.env.BR.Storm.wallStyle = 'solid'
    D.pedAt = pt(0.0, 0.0)
    D.frame()
    ok(#D.markers == 1 and near(D.markers[1].x, 0.0, 1e-9),
        'and a hand-forced solid on a union draws the first disc and says nothing '
            .. 'about the second, on purpose',
        ('%d markers'):format(#D.markers))
end

-- ---------------------------------------------------------------------------
describe('wall.union')
do
    -- ═══ THE WALL IS THE PART A PLAYER CAN SEE, SO IT IS THE PART THAT PROVES
    --     THE ZONE ═══
    --
    -- Radii chosen so the whole boundary fits under maxDraw and there is no
    -- window: two 200m circles 360m apart come to about 70 slots at 30m of arc
    -- each, against a ceiling of 80. Below that ceiling the walk draws every
    -- slot and asks nothing about where the viewer is, so these assertions are
    -- about the shape rather than about the camera.
    --
    -- FORCED TO 'columns' SINCE #336, because automatic is the quad strip now. This
    -- block is the MARKER WALK's proof that it lands on a union's boundary, and the
    -- marker walk is the A/B baseline's other half -- so it has to keep holding for
    -- the sessions that type the command, which is the only way anybody reaches it.
    local C = newStormClient()
    local env = C.env
    local rec = C.record(2, 0.0, 0.0, 200.0, 360.0, 0.0, 200.0, 600000, 60000, 4.0)
    C.env.BR.Storm.wallStyle = 'columns'
    C.pedAt = pt(0.0, 0.0)
    C.frame()

    local SS = C.env.BR.StormShape
    local inset = C.env.BR.Config.Storm.render.edgeInset
    local want = SS.inset(zoneOf(env, rec), inset)

    ok(C.errored() == nil, 'the column renderer runs clean on a union',
        C.errored())
    ok(#C.markers > 40, 'and draws a wall', #C.markers)

    -- ═══ EVERY MARKER IS ON THE UNION'S BOUNDARY, AND NONE OF THEM IS INSIDE THE
    ---     SAFE ZONE -- #328'S CLAIM, BACK FOR BLOBS (#356) ═══
    --
    -- Both halves of this used to be one assertion -- "the signed distance to the
    -- union is zero at every marker" -- which is true for two overlapping DISCS
    -- because union2 computes the crossings and drops the swallowed arcs. #344 made
    -- it false for blobs, which were concatenated instead of stitched, so the claim
    -- was split and the interior runs were asserted to EXIST, by name, so that the
    -- day the union was stitched this block would go red rather than quietly keep a
    -- weaker claim than it could have.
    --
    -- THAT DAY IS #356 AND THE STRONGER CLAIM IS BACK, kept as two assertions
    -- because the two failures they catch are different: a wall in the wrong place,
    -- and a wall inside the zone. `interior` is now asserted to be ZERO.
    local worst, worstAt = 0.0, nil
    local interior = 0
    for _, m in ipairs(C.markers) do
        local best = math.huge
        for _, part in ipairs(want.parts) do
            local d = math.abs(SS.distance(part, m.x, m.y))
            if d < best then best = d end
        end
        if best > worst then worst, worstAt = best, ('%.1f, %.1f'):format(m.x, m.y) end
        if SS.distance(want, m.x, m.y) < -1e-6 then interior = interior + 1 end
    end
    ok(worst < 1e-6,
        "every column stands on ONE part's boundary -- none off the shape",
        ('worst %.6f m at %s'):format(worst, tostring(worstAt)))
    -- MEASURED AGAINST THE SIGNED DISTANCE, WHICH IS SHALLOW IN THE LENS AND THAT
    -- IS WHY THIS IS AN HONEST TEST. distance() understates depth strictly inside an
    -- overlap, so if anything it UNDER-reports how far inside a stray column is; a
    -- column on a swallowed arc still reads comfortably negative, which is what the
    -- pre-#356 spelling of this block measured at 44 of 72.
    ok(interior == 0,
        'and NOTHING is drawn inside the safe zone -- the swallowed stretches of '
            .. 'both boundaries are gone, which is #328 restored for blobs',
        ('%d of %d columns inside the zone'):format(interior, #C.markers))

    -- AND IT WRAPS BOTH CIRCLES. A wall that quietly fell back to the current
    -- circle would pass the test above -- a circle's own boundary is a subset of
    -- nothing, but distance() to the union is zero on the surviving arc of
    -- either circle -- so the far side of each one is asserted by name.
    local behind, beyond = 0, 0
    for _, m in ipairs(C.markers) do
        if m.x < -150.0 then behind = behind + 1 end
        if m.x > 510.0  then beyond = beyond + 1 end
    end
    ok(behind > 0 and beyond > 0,
        'and the colonnade wraps the far side of BOTH circles, which is the '
            .. 'shape no single cylinder can draw',
        ('%d behind the current circle, %d beyond the next'):format(behind,
            beyond))

    -- A NESTED PHASE DRAWS THE IDENTICAL CIRCLE IT ALWAYS DREW, which is the
    -- wall's half of the property that makes this shippable.
    --
    -- FORCED TO 'columns', BECAUSE THE SHAPE WOULD OTHERWISE CHOOSE THE CYLINDER.
    -- A nested union IS a single circle, so `wall.default` is where the cylinder
    -- is asserted; this block is about the WALK, and the walk still has to put its
    -- columns on the inset circle for the phases where a viewer has typed
    -- /brwallstyle columns.
    local D = newStormClient()
    local drec = D.record(2, 0.0, 0.0, 350.0, 100.0, 0.0, 150.0, 600000, 60000, 4.0)
    D.env.BR.Storm.wallStyle = 'columns'
    D.pedAt = pt(0.0, 0.0)
    D.frame()
    -- MEASURED AGAINST THE INSET SHAPE, not against `r - inset`: the radius is
    -- bearing-dependent now, so a circle's arithmetic here would be measuring the
    -- jitter draw. The claim is unchanged -- every column is exactly on the drawn
    -- boundary, which is exactly edgeInset inside the logical one.
    local dwant = D.env.BR.StormShape.inset(zoneOf(D.env, drec), inset)
    local off, live = 0.0, -math.huge
    for _, m in ipairs(D.markers) do
        off = math.max(off, math.abs(D.env.BR.StormShape.distance(dwant, m.x, m.y)))
        live = math.max(live, D.env.BR.StormShape.distance(
            zoneOf(D.env, drec), m.x, m.y))
    end
    ok(#D.markers > 40 and off < 1e-6,
        'and a nested next circle draws ONE shape exactly, edgeInset inside the '
            .. 'logical edge as it always did',
        ('%d markers, worst %.6f m off the inset boundary'):format(#D.markers, off))
    ok(near(live, -inset, 1e-6),
        'and the furthest out any column stands is exactly edgeInset inside the '
            .. 'boundary that damages',
        ('%.6f against %.1f'):format(live, -inset))
end

-- ---------------------------------------------------------------------------
describe('wall.window')
do
    -- ═══ THE BRANCH NOTHING USED TO DRIVE ═══
    --
    -- Above rr.maxDraw the column walk cannot draw the whole boundary, so it
    -- draws a WINDOW of it centred on the stretch the viewer is looking at. Every
    -- other wall block in this file picks radii where the whole boundary fits
    -- under the ceiling -- `wall.union`'s two 200m circles come to about 70 slots
    -- against 80 -- so until this block existed NO TEST ANYWHERE EXECUTED THE
    -- WINDOWED BRANCH ON A SHAPE THAT COULD BREAK IT, and the suite was green
    -- while the wall had a hole in it.
    --
    -- ═══ WHAT BROKE: THE WINDOW STRADDLED THE SEAM BETWEEN TWO ISLANDS ═══
    --
    -- `first` runs negative and the walk wrapped modulo the whole perimeter. That
    -- is honest for ONE CLOSED LOOP -- a circle, or the Venn case where arc 1 ends
    -- exactly where arc 2 begins -- and a lie for a DISJOINT union, which is two
    -- separate loops: arc length 0 is on the current circle and arc length P1 is
    -- on the next one, kilometres away. A window that straddled either seam spent
    -- half its budget on the island the viewer was not standing on.
    --
    -- MEASURED on the geometry below, viewer at (560, 0): 48 markers drawn, 24 on
    -- the near circle covering bearings 2 to 79 degrees only, and 24 dumped on the
    -- far circle behind the player -- so everything immediately clockwise of them
    -- had no curtain at all. Swept round the near circle in 5 degree steps, 32 of
    -- 72 viewer bearings showed a broken colonnade at phase 4 and 17 of 72 at
    -- phase 3. Nested and Venn measured 0 of 72, which is exactly why the existing
    -- blocks could not see it.
    local C = newStormClient()
    local SS = C.env.BR.StormShape
    local rr = C.env.BR.Config.Storm.render

    -- Phase-4 radii, separated: current r520 at the origin, next r260 at 1040m,
    -- so the two rims are 260m apart with unsafe ground between them. The solver
    -- really produces this pair -- a breakout caps the gap at gapMax (0.5) times
    -- the predecessor's radius, and 260 is exactly half of 520.
    local R0, R1, SEP = 520.0, 260.0, 1040.0
    local wrec = C.record(4, 0.0, 0.0, R0, SEP, 0.0, R1, 600000, 60000, 2.2)
    C.env.BR.Storm.wallStyle = 'columns'

    local shape = SS.inset(zoneOf(C.env, wrec), rr.edgeInset)
    local P = SS.perimeter(shape)
    local slots = math.max(rr.segments, math.floor(P / rr.slotArc + 0.5))
    local ds = P / slots

    ok(slots > rr.maxDraw,
        'the geometry drives the WINDOWED branch, which is the whole point of '
            .. 'this block',
        ('%d slots against a ceiling of %d'):format(slots, rr.maxDraw))

    --- The widest gap between COLUMNS DRAWN BACK TO BACK, in metres.
    ---
    --- Draw order is slot order -- the walk emits slot `first + i` for rising i --
    --- so two markers that are neighbours in this list are neighbours in the
    --- colonnade, and the distance between them is the width of the hole a player
    --- could walk through. On an unbroken run it is one slot of boundary; the seam
    --- bug put the island separation here instead, which on this geometry is
    --- hundreds of metres.
    ---
    --- ASKED OF THE MARKERS AND NOT OF THE SHAPE, deliberately: it never mentions
    --- components, arc length or the perimeter, so it cannot be satisfied by the
    --- same mistake the renderer would make.
    local function widestGap()
        local worst, at = 0.0, nil
        for i = 2, #C.markers do
            local a, b = C.markers[i - 1], C.markers[i]
            local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
            if d > worst then
                worst = d
                at = ('%.0f,%.0f to %.0f,%.0f'):format(a.x, a.y, b.x, b.y)
            end
        end
        return worst, at
    end

    --- Which of the two islands a column is standing on.
    ---
    --- ASKED AS "WHOSE BOUNDARY IS IT ON", NOT "WHOSE CENTRE IS IT NEARER" (#344).
    --- The centre test is exact for two discs and wrong for two blobs: a column on
    --- the far side of the near island stands up to 1.11 * R0 out, which is nearer
    --- the FAR centre than its own, so five of forty-eight columns were reported on
    --- the wrong island by a test that was measuring the shape rather than the
    --- window. Every column is on one part's boundary to a picometre, so the part it
    --- is nearest is the part it is on.
    local function onFarIsland(m)
        local a = math.abs(SS.distance(shape.parts[1], m.x, m.y))
        local b = math.abs(SS.distance(shape.parts[2], m.x, m.y))
        return b < a
    end

    -- ═══ THE REPRODUCTION, BY NAME ═══
    C.pedAt = pt(560.0, 0.0)
    C.frame()
    local far = 0
    for _, m in ipairs(C.markers) do
        if onFarIsland(m) then far = far + 1 end
    end
    ok(C.errored() == nil, 'the windowed walk runs clean on two islands',
        C.errored())
    ok(#C.markers > 0, 'and draws a wall at all', #C.markers)
    ok(far == 0,
        'a viewer standing at the near circle spends the whole budget on the '
            .. 'near circle, not half of it on an island a kilometre behind them',
        ('%d of %d columns on the far island'):format(far, #C.markers))

    local gap, gapAt = widestGap()
    ok(gap <= ds * 1.5,
        'and no two columns drawn back to back are further apart than a slot of '
            .. 'boundary -- the colonnade has no hole in it',
        ('widest %.1f m against ds %.1f, at %s'):format(gap, ds,
            tostring(gapAt)))

    -- ═══ AND ALL THE WAY ROUND, BECAUSE ONE BEARING IS AN ANECDOTE ═══
    --
    -- The seam sits at ONE place on the boundary, so a viewer standing anywhere
    -- else sees a perfectly good wall. Sweeping is what turns "it looked fine
    -- when I stood here" into a property.
    local broken, worstGap, worstAt = 0, 0.0, nil
    for deg = 0, 355, 5 do
        local a = math.rad(deg)
        C.pedAt = pt(math.cos(a) * 480.0, math.sin(a) * 480.0)
        C.frame()
        local g, where = widestGap()
        if g > ds * 1.5 then
            broken = broken + 1
            if g > worstGap then worstGap, worstAt = g, ('%d deg, %s'):format(deg, tostring(where)) end
        end
    end
    ok(broken == 0,
        'swept all the way round the near circle in 5 degree steps, no viewer '
            .. 'bearing produces a broken colonnade',
        ('%d of 72 bearings broken, worst %.1f m at %s'):format(broken, worstGap,
            tostring(worstAt)))

    -- ═══ THE FAR ISLAND IS NOT DARK, IT IS JUST NOT THEIRS ═══
    --
    -- Dropping the far island from the window is only honest if it gets its own
    -- window the moment somebody is nearest to it. Otherwise this trades a hole
    -- in the wall for a circle with no wall at all, which is the worse bug.
    C.pedAt = pt(SEP + 300.0, 0.0)
    C.frame()
    local nearCount, farCount = 0, 0
    for _, m in ipairs(C.markers) do
        if onFarIsland(m) then farCount = farCount + 1 else nearCount = nearCount + 1 end
    end
    ok(farCount > 0 and nearCount == 0,
        'a viewer standing at the far circle gets the far circle drawn, whole '
            .. 'and to themselves',
        ('%d far / %d near'):format(farCount, nearCount))
    local g2 = widestGap()
    ok(g2 <= ds * 1.5,
        'with no hole in that colonnade either',
        ('widest %.1f m against ds %.1f'):format(g2, ds))

    -- ═══ AND THE SINGLE-LOOP CASE IS UNTOUCHED, MARKER FOR MARKER ═══
    --
    -- Every nested phase and every Venn is ONE component, so a per-component slot
    -- grid has to come out at exactly the counts the whole-perimeter one did.
    -- This is the assertion that makes the fix a fix rather than a rewrite: a
    -- 1600m phase-2 circle is 334 slots, far over the ceiling, so it is windowed
    -- too -- and it has to be windowed identically.
    local D = newStormClient()
    local nrec = D.record(2, 0.0, 0.0, 1600.0, 400.0, 0.0, 950.0, 600000, 60000, 1.25)
    D.env.BR.Storm.wallStyle = 'columns'
    -- Far enough OUTSIDE that the window widens past the ceiling rather than
    -- resting on the rr.segments floor: visArc is twice the distance out, so 600m
    -- outside the inset rim is where `want` first reaches maxDraw.
    D.pedAt = pt(2200.0, 0.0)
    D.frame()
    local nested = SS.inset(zoneOf(D.env, nrec), rr.edgeInset)
    local nslots = math.max(rr.segments,
        math.floor(SS.perimeter(nested) / rr.slotArc + 0.5))
    local nds = SS.perimeter(nested) / nslots
    local worstRing = 0.0
    for _, m in ipairs(D.markers) do
        worstRing = math.max(worstRing,
            math.abs(SS.distance(nested, m.x, m.y)))
    end
    ok(nslots > rr.maxDraw and #D.markers == rr.maxDraw,
        'a nested phase-2 circle is windowed at exactly maxDraw, as it always was',
        ('%d slots, %d drawn'):format(nslots, #D.markers))
    ok(worstRing < 1e-6,
        'and every one of its columns is on the inset boundary',
        ('worst %.6f m off it'):format(worstRing))
    local dgap = 0.0
    for i = 2, #D.markers do
        local a, b = D.markers[i - 1], D.markers[i]
        dgap = math.max(dgap, math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2))
    end
    ok(dgap <= nds * 1.5,
        'in one unbroken run, which is what it was doing correctly all along',
        ('widest %.1f m against ds %.1f'):format(dgap, nds))
end

-- ---------------------------------------------------------------------------
describe('wall.strip')
do
    -- ═══ THE WALL IS A SURFACE NOW, AND GEOMETRY IS ALL A TEST CAN SEE ═══
    --
    --   "what you just drew is not a wall - it's a bunch of circles which are the
    --    wrong height and you're still using 3dmarkers..... I thought you were
    --    going to research ways to not do that."     -- the owner, 2026-09-22, #336
    --
    -- The striping was never a tuning failure: a DrawMarker type 1 is a translucent
    -- CYLINDER, brightest at its silhouette edges where the sight line crosses the
    -- most surface, so eighty in a row are a picket fence -- and widening them until
    -- they meet doubles the alpha where they cross and bands the wall dark instead.
    -- config/storm.lua recorded both halves of that beside `overlap`. So the wall is
    -- a QUAD STRIP: each consecutive pair of walk points is one quad, two DRAW_POLY
    -- triangles, from a fixed bottom z to a config top z.
    --
    -- EVERY ASSERTION BELOW IS ABOUT THE EMITTED TRIANGLES, because that is the only
    -- thing a suite can look at -- there is no frame buffer here. Four of the claims
    -- are invisible in any single screenshot and would each cost a playtest:
    --
    --   * a shared edge that is two AGREEING answers rather than the same numbers
    --     is an invariant nothing holds. It is NOT a visible seam, and saying so
    --     is the point: measured, rebuilding a loop's closing point instead of
    --     reusing it lands elsewhere on 11 percent of whole-metre radii between 20
    --     and 2600, and the worst disagreement anywhere is 3.5e-12 metres. What
    --     the `==` below buys is that the next rewrite of the walk cannot quietly
    --     stop sharing -- emitting per PIECE rather than per component computes a
    --     Venn crossing from two different centres, and that is the door.
    --   * DRAW_POLY is single sided, so the wrong winding is INVISIBLE from one side
    --     and a missing wall from the other. Both sides are checked.
    --   * a strip that walked the shape's own arc length through a disjoint seam
    --     would bridge two islands with one kilometre-long quad across the unsafe
    --     gap -- a wall where there is no boundary.
    --   * the poly count is the one thing that can quietly make the wall too
    --     expensive to ship, and it scales with the shape.

    local base = newStormClient()
    local rr = base.env.BR.Config.Storm.render
    local sp = rr.strip
    local SS = base.env.BR.StormShape

    local fd = sp.fade or {}

    -- ═══ A CIRCLE, FROM INSIDE IT ═══
    --
    -- OFF THE AXIS AND OFF THE CENTRE, DELIBERATELY. The obvious viewer positions
    -- for a circle centred on the origin are (0, 0) and somewhere due east, and
    -- both are degenerate for nearestArc -- the centre ties every boundary point
    -- and answers arc length 0, and due east IS arc length 0. A renderer that
    -- rotated its walk to start at the viewer would then produce the identical
    -- geometry from both places and pass the world-anchored test below while being
    -- exactly the #225 bug. Two different bearings is what makes that test able to
    -- fail.
    local C = newStormClient()
    C.record(5, 0.0, 0.0, 260.0, 60.0, 0.0, 120.0, 600000, 60000, 2.9)
    C.pedAt = pt(80.0, 40.0, 30.0)
    C.frame()

    ok(C.errored() == nil, 'the strip runs clean on a circle', C.errored())
    ok(#C.polys > 0 and #C.polys % 2 == 0,
        'and emits whole quads -- two triangles each, never an odd one',
        #C.polys)
    ok(#C.markers == 0, 'with no 3d marker anywhere in the frame', #C.markers)

    -- ═══ THE BAND COUNT IS ASKED OF THE RUNNING CLIENT, NOT OF THE CONFIG ═══
    --
    -- The shipping path is the GRADIENT, which is one band -- the ramp lives in a
    -- texture, so a quad is two triangles and the wall is smooth anyway. The banded
    -- path is the fallback and has its own block below.
    --
    -- ASKED RATHER THAN ASSUMED, because the path is a runtime ladder: a client that
    -- could not build the runtime texture really is drawing bands, and every count and
    -- budget assertion here is a multiple of whatever it settled on. Hard-coding either
    -- answer would make this block assert one path's geometry against the other path's
    -- wall and blame the walk for the mismatch.
    local fadePath, nBands = fadeOf(C)
    local quadPolys = 2 * nBands
    ok(fadePath == 'gradient' and nBands == 1,
        'the shipping wall is the baked-ramp gradient -- one band, two triangles a '
            .. 'quad, and the smoothness is in the texture rather than in the count',
        ('%s at %d band(s); rung %s'):format(fadePath, nBands,
            tostring(C.env.BR.Storm and C.env.BR.Storm.fadeRung)))

    local q = quadsOf(C)
    -- EVERY STEP CARRIES THE CONFIGURED NUMBER OF BANDS, and the count comes out of
    -- the geometry rather than being handed to the helper. A fade that lost a band
    -- at the top or bottom of the wall -- an off-by-one in the band loop, which is
    -- the obvious way to write it wrong -- leaves the strip continuous, the seams
    -- shared and the winding correct, and shortens the wall by a third.
    local shortBand = nil
    for i, qd in ipairs(q) do
        if #qd.bands ~= nBands then shortBand = shortBand or i end
    end
    ok(#q * nBands * 2 == #C.polys and shortBand == nil,
        'every quad reconstructs from its bands, and every band from its two '
            .. 'triangles',
        ('%d quads x %d bands x 2 against %d polys; first short quad %s'):format(
            #q, nBands, #C.polys, tostring(shortBand)))

    -- THE SHARED EDGE IS THE SAME NUMBERS, NOT TWO AGREEING ANSWERS. Bit-for-bit
    -- equality is the whole point: two floating-point reconstructions of one
    -- boundary point agree to about a millimetre, and a millimetre of overlap is a
    -- bright hairline at every seam while a millimetre of gap is a dark one. `==`
    -- rather than a tolerance is what makes this test able to tell the difference.
    local seams, firstSeam = 0, nil
    for i = 2, #q do
        local prev, cur = q[i - 1], q[i]
        if prev.b.x ~= cur.a.x or prev.b.y ~= cur.a.y then
            seams = seams + 1
            firstSeam = firstSeam or ('quad %d ends %.9f,%.9f, quad %d begins '
                .. '%.9f,%.9f'):format(i - 1, prev.b.x, prev.b.y, i,
                    cur.a.x, cur.a.y)
        end
    end
    ok(seams == 0,
        'consecutive quads share their edge to the last bit -- no gap and no '
            .. 'overlap between neighbours, anywhere in the strip',
        firstSeam or ('%d of %d seams split'):format(seams, #q - 1))

    -- AND THE STRIP CLOSES. The last quad takes the STORED first point rather than
    -- asking the shape for arc length c.len, which wraps to zero and answers
    -- correctly -- but answers it by rebuilding the point. One rebuilt seam per ring
    -- is one hairline per ring, on every circle in the game.
    ok(#q > 0 and q[#q].b.x == q[1].a.x and q[#q].b.y == q[1].a.y,
        'and the strip closes on a circle, onto the identical first point',
        #q > 0 and ('%.9f,%.9f vs %.9f,%.9f'):format(q[#q].b.x, q[#q].b.y,
            q[1].a.x, q[1].a.y) or nil)

    -- ═══ AND SWEPT ACROSS RADII, BECAUSE BIT EXACTNESS IS NOT AN ANECDOTE ═══
    --
    -- The two assertions above hold on ONE radius, and whether a rebuilt point
    -- lands on the stored one is decided by the last bits of `n * (len / n)`
    -- against `len` -- which is true at most radii and false at about one in nine.
    -- Measured with the strip's own quad count: 293 of the 2581 whole-metre radii
    -- between 20 and 2600 are ones where rebuilding lands somewhere else. So a
    -- single radius proves nothing about the construction, and a sweep does.
    local W2 = newStormClient()
    W2.pedAt = pt(37.0, 61.0, 30.0)
    local splitAt, openAt, swept = nil, nil, 0
    for R = 30, 2600, 7 do
        W2.record(2, 0.0, 0.0, R + 0.0, 0.0, 0.0, R * 0.4, 600000, 60000, 2.0)
        W2.frame()
        local wq = quadsOf(W2)
        swept = swept + 1
        for i = 2, #wq do
            if wq[i - 1].b.x ~= wq[i].a.x or wq[i - 1].b.y ~= wq[i].a.y then
                splitAt = splitAt or R
            end
        end
        if #wq == 0 or wq[#wq].b.x ~= wq[1].a.x or wq[#wq].b.y ~= wq[1].a.y then
            openAt = openAt or R
        end
    end
    ok(swept > 350 and splitAt == nil and openAt == nil,
        'and that holds at every radius from 30 to 2600: no seam splits and every '
            .. 'ring closes, which is what makes the shared edge a construction '
            .. 'rather than a coincidence at one radius',
        ('%d radii swept; first split at %s, first open ring at %s'):format(swept,
            tostring(splitAt), tostring(openAt)))

    -- EVERY POINT IS USED BY EXACTLY TWO QUADS, which is what "one closed strip"
    -- means when said about the emitted geometry rather than about the loop that
    -- emitted it. A duplicated quad or a doubled-back walk passes the seam test
    -- above and fails this.
    local uses, distinct = {}, 0
    for _, qd in ipairs(q) do
        for _, p in ipairs({ qd.a, qd.b }) do
            local k = ('%.17g,%.17g'):format(p.x, p.y)
            if not uses[k] then uses[k] = 0 distinct = distinct + 1 end
            uses[k] = uses[k] + 1
        end
    end
    local shared = 0
    for _, n in pairs(uses) do if n == 2 then shared = shared + 1 end end
    ok(distinct == #q and shared == distinct,
        'and every corner belongs to exactly two quads: one closed strip, not a '
            .. 'walk that doubled back or drew a quad twice',
        ('%d distinct corners for %d quads, %d shared by two'):format(distinct,
            #q, shared))

    -- ═══ THE WINDING, FROM INSIDE ═══
    ok(#C.polys > 0 and backFacing(C, C.pedAt) == 0,
        'from inside the circle every triangle shows the viewer its visible face',
        ('%d of %d triangles back-facing'):format(backFacing(C, C.pedAt),
            #C.polys))

    -- ═══ AND FROM OUTSIDE, WHICH IS THE HALF A ONE-SIDED SURFACE GETS WRONG ═══
    --
    -- A single signed distance per frame would pass the test above and fail this
    -- one HALF WAY ROUND: a viewer outside the zone is outside the near wall and,
    -- looking across the circle, on the INSIDE of the far one. One winding for the
    -- whole frame makes the far rim face away and vanish, so the circle reads as a
    -- half arc with nothing behind it -- the mid-air stop #328 already paid for.
    local O = newStormClient()
    O.record(5, 0.0, 0.0, 260.0, 60.0, 0.0, 120.0, 600000, 60000, 2.9)
    O.pedAt = pt(420.0, 380.0, 30.0)     -- outside, and on a different bearing
    O.frame()
    ok(O.errored() == nil, 'the strip runs clean from outside', O.errored())
    ok(#O.polys == #C.polys and backFacing(O, O.pedAt) == 0,
        'and from outside it, every triangle faces the viewer too -- including the '
            .. 'far rim, which is the half a per-frame signed distance loses',
        ('%d of %d triangles back-facing'):format(backFacing(O, O.pedAt),
            #O.polys))

    -- THE WINDINGS REALLY DID FLIP, which is worth asserting separately: a renderer
    -- that emitted BOTH windings would satisfy every facing test in this block and
    -- be the doubled alpha the whole change exists to escape.
    local flipped = 0
    for i = 1, #C.polys do
        local a, b = C.polys[i], O.polys[i]
        if a[1].x ~= b[1].x or a[1].y ~= b[1].y or a[1].z ~= b[1].z then
            flipped = flipped + 1
        end
    end
    ok(flipped > 0,
        'and the two frames are not the same triangles: the winding flipped where '
            .. 'the viewer changed sides, rather than both being drawn',
        ('%d of %d triangles wound differently'):format(flipped, #C.polys))

    -- THE GEOMETRY ITSELF NEVER MOVED, THOUGH. #225 was a wall hung off the
    -- viewer -- a colonnade centred on a spectator's corpse's bearing -- and the
    -- strip must not reintroduce it by the back door. The SURFACE is world-anchored;
    -- only which of its two faces exists depends on where anybody stands.
    local sameCorners = #C.polys == #O.polys
    if sameCorners then
        local ca, oa = quadsOf(C), quadsOf(O)
        for i = 1, #ca do
            if ca[i].a.x ~= oa[i].a.x or ca[i].a.y ~= oa[i].a.y
                or ca[i].b.x ~= oa[i].b.x or ca[i].b.y ~= oa[i].b.y then
                sameCorners = false
            end
        end
    end
    ok(sameCorners,
        'and the surface is the identical surface from both places -- corner for '
            .. 'corner, glued to the world and not to the camera')

    -- ═══ AND ALL THE WAY ROUND, BOTH SIDES, BECAUSE ONE VIEWPOINT IS AN ANECDOTE ═══
    local badIn, badOut = 0, 0
    for deg = 0, 350, 10 do
        local a = math.rad(deg)
        local W = newStormClient()
        W.record(5, 0.0, 0.0, 260.0, 60.0, 0.0, 120.0, 600000, 60000, 2.9)
        W.pedAt = pt(math.cos(a) * 150.0, math.sin(a) * 150.0, 30.0)
        W.frame()
        if #W.polys == 0 or backFacing(W, W.pedAt) > 0 then badIn = badIn + 1 end
        W.pedAt = pt(math.cos(a) * 700.0, math.sin(a) * 700.0, 30.0)
        W.frame()
        if #W.polys == 0 or backFacing(W, W.pedAt) > 0 then badOut = badOut + 1 end
    end
    ok(badIn == 0 and badOut == 0,
        'swept round in 10 degree steps, from inside and from outside, no viewer '
            .. 'position is shown the back of a single triangle',
        ('%d of 36 inside, %d of 36 outside'):format(badIn, badOut))

    -- ═══ THE HEIGHT, WHICH WAS HALF THE REPORT AND IS NOW THE FADE'S ANSWER ═══
    --
    -- The columns stood `height * 3 + 50` tall from a base of -100, so their tops
    -- were at world z 850 and the wall reached into the sky over a city whose ground
    -- is around 30 -- "the wrong height". The strip topped out at 400 for a while,
    -- which was a trade with no right answer: a fixed top cannot both stay off the
    -- sky over the city and be above a player on Chiliad at 780.
    --
    -- THE FADE DISSOLVED THE TRADE, and the owner said so: "are you able to make the
    -- wall fade bottom to top like the 3dmarker? if so, just make it the same height
    -- as the marker was" (2026-09-22). So the top IS the marker's top, and the last
    -- metres of it are drawn at fade.topAlpha, which is nothing.
    --
    -- THE BOTTOM GOES UNDER EVERYTHING, because a strip's bottom edge is a hard
    -- line and any ground above it shows as a lit band of terrain through the wall.
    -- The alternative is a ground probe per boundary point per frame, which is not
    -- affordable and was removed for exactly that reason -- GetGroundZFor_3dCoord
    -- returns garbage for unloaded cells, so the fallback (the viewer's own z) is
    -- what actually ran and the wall rode the camera.
    --
    -- ASSERTED AGAINST THE MAP CONFIG'S OWN GROUND, not against a number typed
    -- twice: BR.Config.Map.POIs is 120 authored places with a z, and it is the only
    -- statement anywhere in the tree about how low and how high the ground the wall
    -- crosses actually goes.
    local loPoi, hiPoi, named = math.huge, -math.huge, 0
    for _, poi in ipairs(base.env.BR.Config.Map.POIs) do
        if poi.z then
            named = named + 1
            if poi.z < loPoi then loPoi = poi.z end
            if poi.z > hiPoi then hiPoi = poi.z end
        end
    end
    ok(named > 100 and sp.baseZ < loPoi and sp.baseZ < 0.0,
        'the strip\'s bottom is below the lowest ground the config admits, and '
            .. 'below sea level: no gap can open under the wall on a slope',
        ('base %.1f against the lowest of %d authored POI heights, %.1f'):format(
            sp.baseZ, named, loPoi))
    -- 850 IS THE MARKER'S OWN TOP, DERIVED HERE RATHER THAN TYPED. The cylinder
    -- stands at -100 with a scaleZ of `render.height * 3 + 50`, so asserting against
    -- that arithmetic is what makes this test able to notice if either number moves.
    -- It is also the one assertion that would catch the height being matched off a
    -- mis-read of the marker call: dropping the `* 3` gives 350 and a top of 250,
    -- which is a plausible-looking number and the wrong one.
    local markerTop = -100.0 + (rr.height * 3.0 + 50.0)
    ok(sp.topZ > sp.baseZ and near(sp.topZ, markerTop, 1e-9),
        'and its top is exactly where the marker\'s was -- which is what the fade '
            .. 'bought, since the metres that used to tower are drawn at nothing',
        ('%.1f against the marker\'s %.1f, a %.1fm wall'):format(
            sp.topZ, markerTop, sp.topZ - sp.baseZ))

    -- ═══ EVERY VERTEX ON A BAND PLANE, AND THE PLANES ARE THE WHOLE WALL ═══
    --
    -- This used to read "every vertex is on baseZ or topZ", which was right when a
    -- quad was one quad and is now the assertion that cannot fail for the wrong
    -- reason: a banded wall has bands + 1 planes, and a fade that stopped short --
    -- bands that only reached halfway up, or a band height computed off the wrong
    -- span -- would put every vertex on a legal-looking plane and leave the top of
    -- the wall missing. So the SET of planes is checked against the span, not just
    -- membership of it.
    local planes, stray = {}, 0
    for _, t in ipairs(C.polys) do
        for j = 1, 3 do planes[t[j].z] = (planes[t[j].z] or 0) + 1 end
    end
    local nPlanes, loZ, hiZ = 0, math.huge, -math.huge
    for z in pairs(planes) do
        nPlanes = nPlanes + 1
        if z < loZ then loZ = z end
        if z > hiZ then hiZ = z end
    end
    local h = (sp.topZ - sp.baseZ) / nBands
    for z in pairs(planes) do
        local k = (z - sp.baseZ) / h
        if math.abs(k - math.floor(k + 0.5)) > 1e-6 then stray = stray + 1 end
    end
    ok(nPlanes == nBands + 1 and stray == 0
        and loZ == sp.baseZ and hiZ == sp.topZ,
        'and every vertex sits on one of the band planes, which run from the '
            .. 'config\'s base to the config\'s top with none missing -- the wall is '
            .. 'exactly as tall as the config says, everywhere',
        ('%d planes for %d bands, %d off-grid, span %.1f to %.1f'):format(
            nPlanes, nBands, stray, loZ, hiZ))

    -- AND THE alphaScale CLOCK REACHES IT, which is the debt the column path took
    -- two commits to pay: it passed rr.alpha raw, so the map ring faded in over the
    -- hold's last ten seconds while the curtain popped into existence beside it.
    local F = newStormClient()
    -- THE RECORD'S WALL ALONE. Halfway through the phase-1 fade-in the #340 preview is
    -- also in frame, fading out on the other side of the same clock; both walls are
    -- correct and their union is not one wall, which is all C.recordWallOnly says.
    F.recordWallOnly()
    local frec = F.record(1, 0.0, 0.0, 2600.0, 400.0, 0.0, 1600.0, 600000, 60000, 0.5)
    F.pedAt = pt(0.0, 0.0, 30.0)
    frec.tStart = F.now - (frec.tWait - rr.fadeInSec * 1000.0 * 0.5)
    F.frame()
    -- ═══ ONE ALPHA PER HEIGHT, NOT ONE ALPHA FULL STOP ═══
    --
    -- This block used to assert a single alpha across the whole surface, and the
    -- reasoning was exactly right at the time: a varying alpha is what banding IS,
    -- so the striping #336 escaped would have come straight back through the alpha.
    -- The owner then asked for a variation ON PURPOSE -- "make the wall fade bottom
    -- to top like the 3dmarker" -- so the invariant moves rather than goes away.
    --
    -- WHAT MUST STILL BE TRUE is that the alpha depends on NOTHING BUT HEIGHT. A
    -- surface whose alpha varies along the wall is the picket fence; a surface whose
    -- alpha varies up it is the fade. So: one alpha per band plane, the same at every
    -- point of the ring, monotone decreasing upward, and the whole ramp scaled by the
    -- phase-1 fade-in clock -- which is the debt the column path took two commits to
    -- pay, since it passed rr.alpha raw and the curtain popped into existence beside
    -- a map ring that was fading in properly.
    local byBand, perBand, varies = {}, 0, nil
    for _, qd in ipairs(quadsOf(F)) do
        for bi, b in ipairs(qd.bands) do
            if byBand[bi] == nil then byBand[bi] = b.alpha perBand = perBand + 1
            elseif byBand[bi] ~= b.alpha then
                varies = varies or ('band %d reads %d and %d'):format(
                    bi, byBand[bi], b.alpha)
            end
        end
    end
    ok(perBand == nBands and varies == nil,
        'the alpha depends on height and on nothing else: every band reads the same '
            .. 'all the way round, so a fade up the wall can never become a stripe '
            .. 'along it',
        varies or ('%d bands, each uniform round the ring'):format(perBand))

    -- ═══ AND ON THE GRADIENT THE ALPHA CARRIES THE CLOCK AND NOTHING ELSE ═══
    --
    -- The ramp is in the TEXTURE on this path, so the draw's own alpha is the phase
    -- clock by itself -- and that division of labour is worth an assertion of its own,
    -- because the obvious way to write it wrong is to multiply the ramp in here as
    -- well. That would SQUARE the fade: a wall that thinned out by about 300 m instead
    -- of 850, which looks like a tuning problem rather than a bug and would have the
    -- owner reaching for topAlpha.
    local wantAlpha = math.floor(rr.alpha * 0.5 + 0.5)
    ok(byBand[1] ~= nil and byBand[1] == wantAlpha,
        'the gradient\'s single alpha is render.alpha times the phase-1 fade-in clock '
            .. 'and nothing else -- the ramp is in the texture, so multiplying it in '
            .. 'here too would square the fade',
        ('%s against %d'):format(tostring(byBand[1]), wantAlpha))

    -- AND IT IS THE CLOCK, NOT A CONSTANT: a wall with no fade-in clock on it draws at
    -- full strength. Without this the assertion above passes on a renderer that
    -- ignores alphaScale entirely and happens to have been handed 0.5.
    --
    -- PHASE 2 RATHER THAN PHASE 1, because the fade-in clock only exists in phase 1 --
    -- a phase-1 record whose hold has not reached its last fadeInSec draws no wall at
    -- all, which would make this pass for the wrong reason.
    local G = newStormClient()
    G.record(2, 0.0, 0.0, 1600.0, 400.0, 0.0, 950.0, 600000, 60000, 1.25)
    G.pedAt = pt(0.0, 0.0, 30.0)
    G.frame()
    local fullA = quadsOf(G)[1] and quadsOf(G)[1].bands[1].alpha
    ok(fullA == math.floor(rr.alpha + 0.5) and fullA > wantAlpha,
        'and off the fade-in clock it is render.alpha itself -- so the halving above '
            .. 'is the clock and not a constant',
        ('%s at full against %d halfway'):format(tostring(fullA), wantAlpha))

    -- ═══ THE FADE ITSELF, WHICH ON THIS PATH IS THE v COORDINATE ═══
    --
    -- A textured quad's gradient is the texture plus the mapping onto it, so a test
    -- that only read the alpha could not tell a faded wall from a flat one -- the
    -- alpha is deliberately uniform here. What makes this wall a fade is that v runs
    -- bottom edge to top, on every quad, with u pinned in the texture's interior. The
    -- texture's own contents are asserted in wall.ramp.
    --
    -- ═══ AND v IS INSET BY HALF A TEXEL AT BOTH ENDS, WHICH IS #341 ═══
    --
    --   "smooth but there is a very tiny line at the top of it"  -- the owner, #341
    --
    -- v = EXACTLY 1.0 IS THE WRAP BOUNDARY, not the centre of the last row. A bilinear
    -- sample there straddles row rampH-1 and the row after it, and under a REPEAT
    -- address mode the row after row 255 is row 0 -- the fully opaque bottom of the
    -- ramp. Measured through the shipping bake: alpha 127 at v = 1.0 falling to 0 by
    -- v = 255.5/256, which over this wall's 1000 m span is a 1.95 m band at the very
    -- top reading half the base opacity. A very tiny line at the top of it.
    --
    -- SO THE EXPECTATION IS THE ROW CENTRES, COMPUTED FROM rampH RATHER THAN WRITTEN
    -- OUT. A literal 0.001953125 here would pass while production hard-coded the same
    -- literal against a retuned rampH, which is the same class of bug one level down.
    -- BOTH ENDS ARE PINNED: the bottom never showed the defect -- row 0 is opaque
    -- already, so wrapping there darkens rather than brightens, and the wall's bottom
    -- half texel is 150 m underground -- so an inset applied to the top alone would
    -- look complete and leave the asymmetry for the next reader to rediscover.
    --
    -- w = 1.0 IS CHECKED BECAUSE IT WAS 0.0 IN THE DEAD VERSION OF THIS RENDERER,
    -- read off a reference that called the component ignored. Every proven call site
    -- in dui.lua passes 1.0, and "ignored" is a claim about a native nothing in this
    -- tree had ever successfully called.
    -- ═══ FROM BOTH SIDES, FOR THE SAME REASON THE WINDING IS CHECKED FROM BOTH ═══
    --
    -- The renderer emits one of two vertex orders depending on which side of the wall
    -- the viewer is on, and each order carries its own nine UVs. A viewer INSIDE the
    -- circle only ever exercises the inward spelling, so a UV error in the outward
    -- branch is invisible from there -- exactly the asymmetry this file already warns
    -- about for the winding. Measured: with this block reading one client, mutating
    -- the outward branch's u, v and w every one survived the suite.
    local uvBad, uvSeen, uvFaces = nil, 0, 0
    local uvH = math.max(2, math.floor(fd.rampH or 256))
    local vBot, vTop = 0.5 / uvH, (uvH - 0.5) / uvH
    local UVC = newStormClient()
    UVC.record(5, 0.0, 0.0, 260.0, 60.0, 0.0, 120.0, 600000, 60000, 2.9)
    for _, where in ipairs({ pt(80.0, 40.0, 30.0), pt(420.0, 380.0, 30.0) }) do
        UVC.pedAt = where
        UVC.frame()
        if #UVC.polys == 0 then
            uvBad = uvBad or 'a viewer position drew no wall at all'
        else
            uvFaces = uvFaces + 1
        end
        for _, t in ipairs(UVC.polys) do
            if not t.sprite then
                uvBad = uvBad or 'a gradient frame emitted a plain untextured poly'
            end
            for j = 1, 3 do
                uvSeen = uvSeen + 1
                local want = (t[j].z == sp.baseZ) and vBot or vTop
                if t[j].u ~= 0.5 then
                    uvBad = uvBad or ('u %s, wanted 0.5'):format(tostring(t[j].u))
                elseif t[j].w ~= 1.0 then
                    uvBad = uvBad or ('w %s, wanted 1.0'):format(tostring(t[j].w))
                elseif t[j].v ~= want then
                    uvBad = uvBad or ('v %.9f at z %.1f, wanted %.9f'):format(
                        t[j].v, t[j].z, want)
                end
            end
        end
    end
    ok(uvFaces == 2 and uvSeen > 0 and uvBad == nil,
        'and every vertex of both windings -- seen from inside the circle and from '
            .. 'outside it -- maps the wall\'s bottom to the CENTRE of the ramp\'s '
            .. 'first row and its top to the centre of the last, with u pinned at 0.5 '
            .. 'and w at 1.0 as every proven DrawSpritePoly call in this tree passes '
            .. 'them',
        uvBad or ('%d vertices across %d faces, all mapped, v %.9f to %.9f'):format(
            uvSeen, uvFaces, vBot, vTop))

    -- AND NEITHER END IS THE WRAP BOUNDARY, WHICH IS THE CLAIM ITSELF. The assertion
    -- above pins the exact numbers; this one pins what they are FOR, so that a
    -- "simplification" back to 0.0 and 1.0 fails on a line that says why rather than
    -- only on an arithmetic mismatch. Half a texel is the minimum inset that puts a
    -- bilinear kernel entirely inside the texture, so anything less is the defect
    -- partially applied.
    local uvLo, uvHi = math.huge, -math.huge
    for _, t in ipairs(UVC.polys) do
        for j = 1, 3 do
            if t[j].v < uvLo then uvLo = t[j].v end
            if t[j].v > uvHi then uvHi = t[j].v end
        end
    end
    ok(uvLo >= 0.5 / uvH - 1e-12 and uvHi <= 1.0 - 0.5 / uvH + 1e-12
        and uvLo > 0.0 and uvHi < 1.0,
        'so no vertex sits on the texture\'s wrap boundary at all: v = 1.0 filters onto '
            .. 'row 0 under a REPEAT sampler, which is the thin bright line #341 '
            .. 'reported along the top edge, and half a texel is the least that keeps '
            .. 'the whole bilinear kernel inside the ramp',
        ('v spans %.9f to %.9f, need [%.9f, %.9f]'):format(
            uvLo, uvHi, 0.5 / uvH, 1.0 - 0.5 / uvH))

    -- ═══ AND THE TOP EDGE IS ONE NUMBER, NOT TWO THAT AGREE ═══
    --
    -- #341's other candidate was geometric: two triangles whose shared top vertices
    -- disagree by a float would leave a sliver between them. They cannot -- both take
    -- the same `zt` local with no arithmetic on it -- so this is asserted with `==` on
    -- the config's own value rather than with a tolerance, exactly as the shared
    -- vertical seams are. A tolerance here would pass on the bug it exists to exclude.
    local zTop, zBot, zStray = 0, 0, nil
    for _, t in ipairs(UVC.polys) do
        for j = 1, 3 do
            if t[j].z == sp.topZ then zTop = zTop + 1
            elseif t[j].z == sp.baseZ then zBot = zBot + 1
            else zStray = zStray or ('a vertex at z %.17g'):format(t[j].z) end
        end
    end
    ok(zStray == nil and zTop > 0 and zBot > 0,
        'and every vertex of the gradient wall sits exactly on baseZ or exactly on '
            .. 'topZ -- bit-equal, not near -- so the top edge is one number and no '
            .. 'float sliver can open along it',
        zStray or ('%d on topZ, %d on baseZ, none between'):format(zTop, zBot))

    -- AND IT IS THE RAMP TEXTURE IT IS DRAWN WITH, not some other slot. A quad
    -- pointed at a texture that does not exist draws nothing at all, which is the
    -- failure the owner has reported twice and the one a suite can still catch.
    local tex1 = C.polys[1]
    ok(tex1 and tex1.txd == C.rt.tex.txd and tex1.tex == C.rt.tex.name,
        'drawn with the runtime ramp this client actually built, by dictionary and '
            .. 'texture name',
        tex1 and ('%s:%s against %s:%s'):format(tostring(tex1.txd),
            tostring(tex1.tex), C.rt.tex.txd, C.rt.tex.name))

    -- ═══ THE BANDED FALLBACK'S OWN GEOMETRY, WHICH IS STILL REACHABLE ═══
    --
    -- The steps are the defect, so the fallback is not the wall -- but it is what
    -- runs on a client whose runtime texture could not be built, and a fallback
    -- nobody exercises is a fallback nobody can trust. Everything the banded path
    -- alone claims is asserted here: the configured number of stacked quads, band
    -- planes with none missing, one alpha per plane uniform round the ring, and the
    -- ramp falling as the wall rises.
    local B = bandedClient()
    B.recordWallOnly()
    B.record(1, 0.0, 0.0, 2600.0, 400.0, 0.0, 1600.0, 600000, 60000, 0.5)
    B.pedAt = pt(0.0, 0.0, 30.0)
    local brec = B.env.BR.State.storm
    brec.tStart = B.now - (brec.tWait - rr.fadeInSec * 1000.0 * 0.5)
    B.frame()

    local bPath, bBands = fadeOf(B)
    ok(B.errored() == nil and bPath == 'bands'
        and bBands == math.max(1, math.floor(fd.bands or 3)),
        'a client that prefers bands draws the configured stack instead, and says so',
        ('%s at %d bands; rung %s'):format(bPath, bBands,
            tostring(B.env.BR.Storm.fadeRung)))

    local bq = quadsOf(B)
    local bShort = nil
    for i, qd in ipairs(bq) do
        if #qd.bands ~= bBands then bShort = bShort or i end
    end
    ok(#bq > 0 and bShort == nil and #bq * bBands * 2 == #B.polys,
        'every banded quad is the configured number of stacked quads -- an off-by-one '
            .. 'in the band loop shortens the wall by a third and leaves the seams, '
            .. 'the winding and the closure all still correct',
        ('%d quads x %d bands x 2 against %d polys; first short %s'):format(
            #bq, bBands, #B.polys, tostring(bShort)))

    -- THE BAND PLANES, AND THE SET OF THEM RATHER THAN MEMBERSHIP OF IT: a fade whose
    -- bands only reached halfway up puts every vertex on a legal-looking plane and
    -- leaves the top of the wall missing.
    local bPlanes, bStray, bN = {}, 0, 0
    local bLo, bHi = math.huge, -math.huge
    for _, t in ipairs(B.polys) do
        for j = 1, 3 do bPlanes[t[j].z] = true end
    end
    local bh = (sp.topZ - sp.baseZ) / bBands
    for z in pairs(bPlanes) do
        bN = bN + 1
        if z < bLo then bLo = z end
        if z > bHi then bHi = z end
        local k = (z - sp.baseZ) / bh
        if math.abs(k - math.floor(k + 0.5)) > 1e-6 then bStray = bStray + 1 end
    end
    ok(bN == bBands + 1 and bStray == 0 and bLo == sp.baseZ and bHi == sp.topZ,
        'and its band planes run from the config\'s base to the config\'s top with '
            .. 'none missing and none off the grid',
        ('%d planes for %d bands, %d off-grid, span %.1f to %.1f'):format(
            bN, bBands, bStray, bLo, bHi))

    local bByBand, bPer, bVaries = {}, 0, nil
    for _, qd in ipairs(bq) do
        for bi, b in ipairs(qd.bands) do
            if bByBand[bi] == nil then bByBand[bi] = b.alpha bPer = bPer + 1
            elseif bByBand[bi] ~= b.alpha then
                bVaries = bVaries or ('band %d reads %d and %d'):format(
                    bi, bByBand[bi], b.alpha)
            end
        end
    end
    ok(bPer == bBands and bVaries == nil,
        'its alpha depends on height and on nothing else -- every band reads the same '
            .. 'all the way round, so a fade up the wall cannot become a stripe along '
            .. 'it',
        bVaries or ('%d bands, each uniform round the ring'):format(bPer))

    local bMono = true
    for bi = 2, bBands do
        if bByBand[bi] >= bByBand[bi - 1] then bMono = false end
    end
    ok(bMono and bBands > 1,
        'and it falls strictly as the wall rises, bottom band strongest',
        table.concat(bByBand, ' > '))

    -- ═══ THE RAMP'S OWN ARITHMETIC, AND THE NUMBER THAT WAS WRONG ═══
    --
    -- The bottom band samples the curve at its own CENTRE, so its alpha is the phase
    -- clock times the ramp there. What makes this assertion worth having is which
    -- curve: measured before the ramp was pinned to ground level, the bottom band of
    -- a 3-band wall drew at alpha 92 where render.alpha says 110, because the ramp
    -- started at baseZ and spent its first 150 m underground. rampMul above is the
    -- pinned curve, so this goes red if the pinning is undone.
    local bCentre = sp.baseZ + bh * 0.5
    local wantBottom = rr.alpha * 0.5 * rampMul(fd, sp.baseZ, sp.topZ, bCentre)
    ok(bByBand[1] ~= nil and math.abs(bByBand[1] - wantBottom) <= 1.0,
        'and the bottom band reads the ramp pinned to GROUND level, not to the '
            .. 'geometry\'s underground base -- the difference is a curtain that is '
            .. 'full strength at a player\'s feet instead of 16 percent faint',
        ('bottom band %s against %.1f at z %.1f'):format(
            tostring(bByBand[1]), wantBottom, bCentre))

    -- ═══ AND THE FALLBACK'S BAND COUNT IS CAPPED BY GEOMETRY, NOT BY FRAME RATE ═══
    --
    -- This is the config's "do not raise fade.bands" written as something that can go
    -- red. A banded quad costs 2 * bands polys, so maxPolys rations QUADS to pay for
    -- the bands -- and the ring goes polygonal. Measured through this renderer on the
    -- widest shape the game can build, a fully separated 2600 + 1600 breakout: 3 bands
    -- sags 1.98 m, 6 sags 7.25, 8 sags 12.49, 12 sags 28.97 and 16 sags 49.84, which
    -- with the 6 m inset stands the curtain 56 metres inside the boundary that
    -- damages. That is the "20ft inside" report again, nine times over, bought with
    -- smoothness on the path that is supposed to be the ugly one.
    --
    -- SO THIS GOES RED THE MOMENT SOMEBODY RAISES THE BAND COUNT, deliberately, and
    -- the fix when it does is to leave the band count alone -- the gradient is where
    -- smoothness comes from now, and it is free.
    local BS = bandedClient()
    local brec = BS.record(2, 0.0, 0.0, 2600.0, 4400.0, 0.0, 1600.0,
        600000, 60000, 1.25)
    BS.pedAt = pt(0.0, 0.0, 30.0)
    BS.frame()
    local bShape = SS.inset(zoneOf(BS.env, brec), rr.edgeInset)
    local bSag = 0.0
    for _, qd in ipairs(quadsOf(BS)) do
        local sag = sagOf(BS.env, bShape, qd)
        if sag > bSag then bSag = sag end
    end
    ok(#BS.polys > 0 and bSag <= sp.chordM + 1e-6,
        'and even the banded fallback stays inside chordM at the configured band '
            .. 'count -- raising fade.bands spends quads on smoothness and walks the '
            .. 'curtain back inside the boundary that damages',
        ('worst sag %.2f m at %d bands, %d polys of %d'):format(
            bSag, bBands, #BS.polys, sp.maxPolys))

    -- ═══ TWO ISLANDS ARE TWO STRIPS, AND NOTHING SPANS THE GAP ═══
    --
    -- Phase-4 breakout geometry, the pair the solver really produces: current r520
    -- at the origin, next r260 at 1040m, so the two rims are 260m apart with UNSAFE
    -- GROUND between them (gapMax is 0.5 and 260 is exactly half of 520). A strip
    -- that walked the shape's own arc length would join arc length P1 to arc length
    -- 0 with one quad a kilometre wide across that gap: a wall where there is no
    -- boundary, and the most confident possible lie about where it is safe to stand.
    local R0, R1, SEP = 520.0, 260.0, 1040.0
    local D = newStormClient()
    local drec = D.record(4, 0.0, 0.0, R0, SEP, 0.0, R1, 600000, 60000, 2.2)
    D.pedAt = pt(300.0, 0.0, 30.0)
    D.frame()
    local dq = quadsOf(D)
    local dShape = SS.inset(zoneOf(D.env, drec), rr.edgeInset)

    -- WHICH ISLAND, BY WHOSE BOUNDARY IT IS ON (#344). The centre test this used to
    -- make is exact for two discs and reports the wrong island for two blobs: a
    -- point on the far side of the near shape stands up to 1.11 * R0 out, which is
    -- nearer the FAR centre than its own.
    local function island(p)
        return (partAt(D.env, dShape, p.x, p.y) == dShape.parts[2]) and 2 or 1
    end

    local bridges, longest = 0, 0.0
    local perIsland = { 0, 0 }
    for _, qd in ipairs(dq) do
        local ia, ib = island(qd.a), island(qd.b)
        if ia ~= ib then bridges = bridges + 1 end
        perIsland[ia] = perIsland[ia] + 1
        longest = math.max(longest,
            math.sqrt((qd.a.x - qd.b.x) ^ 2 + (qd.a.y - qd.b.y) ^ 2))
    end
    ok(D.errored() == nil, 'the strip runs clean on two islands', D.errored())
    ok(bridges == 0,
        'not one quad bridges the two islands -- no wall is drawn across the '
            .. 'unsafe gap between them',
        ('%d bridging quads, longest quad %.1f m against a %.0f m gap'):format(
            bridges, longest, SEP - R0 - R1))
    ok(perIsland[1] > 0 and perIsland[2] > 0,
        'and both islands get a strip: two walls, because the zone is two places',
        ('%d quads / %d quads'):format(perIsland[1], perIsland[2]))

    -- EACH ISLAND'S STRIP CLOSES ON ITSELF, which is the disjoint case's version of
    -- the closure test above: two loops, each shut, rather than one loop shut
    -- through the gap.
    local closedLoops = 0
    for want = 1, 2 do
        local first, last, run, broken = nil, nil, 0, false
        for _, qd in ipairs(dq) do
            if island(qd.a) == want then
                run = run + 1
                if not first then first = qd.a
                elseif last.x ~= qd.a.x or last.y ~= qd.a.y then broken = true end
                last = qd.b
            end
        end
        if run > 0 and not broken and last.x == first.x and last.y == first.y then
            closedLoops = closedLoops + 1
        end
    end
    ok(closedLoops == 2,
        'and each of the two strips is a closed loop in its own right, walked end '
            .. 'to end with no break in it',
        ('%d of 2 closed'):format(closedLoops))

    -- AND THE WINDING IS RIGHT ON BOTH OF THEM AT ONCE, which is where a per-frame
    -- signed distance fails the other way round. A viewer standing INSIDE the next
    -- circle is inside the zone, so one winding for the whole frame turns the
    -- current circle inward as well -- and the rim nearest them, the one they are
    -- about to walk into, is the rim that disappears.
    local I = newStormClient()
    I.record(4, 0.0, 0.0, R0, SEP, 0.0, R1, 600000, 60000, 2.2)
    I.pedAt = pt(SEP, 0.0, 30.0)         -- dead centre of the FAR island
    I.frame()
    ok(I.errored() == nil and #I.polys > 0 and backFacing(I, I.pedAt) == 0,
        'a viewer inside one island is shown a face of every triangle of BOTH -- '
            .. 'including the island they are outside of and running toward',
        ('%d of %d back-facing'):format(backFacing(I, I.pedAt), #I.polys))

    -- ═══ A VENN UNION IS ONE LOOP, AND NO CORNER LEAVES THE BOUNDARY ═══
    --
    -- Two overlapping discs have a boundary with two REFLEX corners where the
    -- circles cross, and it is one closed loop. Every quad corner has to stand on
    -- that outline: a corner on an INTERIOR arc -- the half of each circle the other
    -- one swallowed -- would be strictly inside the other disc and read negative,
    -- which is a wall through the middle of the safe zone.
    local V = newStormClient()
    local vrec = V.record(3, 0.0, 0.0, 400.0, 500.0, 0.0, 400.0, 600000, 60000, 1.7)
    V.pedAt = pt(250.0, 0.0, 30.0)
    V.frame()
    local venn = SS.inset(zoneOf(V.env, vrec), rr.edgeInset)
    -- ═══ ON ONE PART'S BOUNDARY, AND NOTHING IN THE LENS (#356) ═══
    --
    -- Two overlapping DISCS are one closed loop with the swallowed arcs dropped, so
    -- this was one assertion carrying two claims: nothing off the shape, and nothing
    -- in the lens. #344 made the second false for blobs, which were concatenated
    -- rather than stitched, and it was asserted the other way round below on purpose
    -- so that the stitch would turn it red -- see wall.union, which carries the same
    -- split and the same note. #356 stitched it, so `inLens` is zero now.
    --
    -- THE TWO ASSERTIONS STAY SEPARATE, because they still catch different failures:
    -- a corner off the outline is a wall in the wrong place, and a corner in the lens
    -- is a wall through the middle of the safe zone.
    --
    -- "IN THE LENS" IS DEEPER THAN A MILLIMETRE, which is storm_shape.lua's
    -- CROSS_TOL: the two seam corners stand where bisection put the crossing, and
    -- bisection stops within a millimetre of it, on either side. Found by the
    -- varying corner count -- this record's phase-3 shape became a hexagon whose
    -- seam landed 0.23 mm inside the other part, a stitch exactly as correct as the
    -- one before. A swallowed arc is metres deep, so the claim loses nothing.
    local offShape, offAt = 0.0, nil
    local inLens = 0
    for _, qd in ipairs(quadsOf(V)) do
        for _, p in ipairs({ qd.a, qd.b }) do
            local own = partAt(V.env, venn, p.x, p.y)
            local d = math.abs(SS.distance(own, p.x, p.y))
            if d > offShape then offShape, offAt = d, ('%.1f,%.1f'):format(p.x, p.y) end
            if SS.distance(venn, p.x, p.y) < -1e-3 then inLens = inLens + 1 end
        end
    end
    ok(V.errored() == nil and #V.polys > 0, 'the strip runs clean on a Venn union',
        V.errored())
    ok(offShape < 1e-6,
        "and every corner of it stands on ONE part's INSET boundary: none off the "
            .. 'shape',
        ('worst %.9f m at %s'):format(offShape, tostring(offAt)))
    ok(inLens == 0,
        'and NOTHING of it is inside the lens: the swallowed arcs of both blobs are '
            .. 'gone and the strip is one loop over two reflex corners (#356)',
        ('%d of the corners are inside the zone'):format(inLens))
    ok(backFacing(V, V.pedAt) == 0,
        'with a visible face at every triangle across both reflex corners',
        ('%d of %d back-facing'):format(backFacing(V, V.pedAt), #V.polys))

    -- ═══ AND THE CURTAIN BETWEEN THE CORNERS, WHICH IS WHERE IT WENT OUTSIDE ═══
    --
    -- THE ASSERTION ABOVE CANNOT FAIL, and that is why this one exists. It measures
    -- `qd.a` and `qd.b` -- the quad CORNERS -- and pointAtComponent puts those on the
    -- boundary BY CONSTRUCTION, whatever the walk does between them. So it passed
    -- while this suite's own Venn case had the curtain 12.45 metres outside the true
    -- boundary, and it would pass again for the same reason.
    --
    -- WHAT THE WALK DID. The step is priced off curvature -- sag is ds^2 / 8r -- and
    -- that is blind to a CORNER, where the curvature is infinite and no step
    -- satisfies the bound. A Venn union is ONE component of two arcs meeting at two
    -- reflex crossings, and `c.len` is not a multiple of the step, so one quad
    -- straddled each crossing and bridged it with a straight chord across the notch.
    -- THE NOTCH CUTS INWARD, SO THE CHORD LANDED OUTSIDE THE SHAPE: the curtain drawn
    -- beyond the boundary that damages, which is the live "20ft inside" report
    -- edgeInset exists for, INVERTED and about five times larger.
    --
    -- MEASURED THROUGH THIS RENDERER, as signed distance from the UNINSET damaging
    -- boundary, worst case over the reachable separation range per shipping phase
    -- pair. -6.00 m is the right answer everywhere -- the curtain exactly edgeInset
    -- inside the logical edge:
    --
    --     2600 + 1600   stepping the component +33.11 m   stepping runs -6.00 m
    --     1600 +  950                          +23.71 m                 -6.00 m
    --      950 +  520                          +15.84 m                 -6.00 m
    --      520 +  260                           +9.35 m                 -6.00 m
    --      260 +  110                           +3.66 m                 -6.00 m
    --
    -- 57 of 235 sampled reachable Venn geometries put the curtain outside the
    -- server's ten-metre damage cushion, and 0 of 235 do now. Both counts are a
    -- sampled sweep of the whole overlap range, 48 separations per pair, and the
    -- excursions above are the worst of a 400-separation sweep at 64 interior
    -- samples per quad. Circles and disjoint pairs measured -6.00 m
    -- throughout, both before and after, which is why nothing caught it: a circle's
    -- component is one piece and a disjoint pair's two components are a whole circle
    -- each, so neither has an interior boundary to step over.
    --
    -- SO THIS SAMPLES THE SPAN, NOT THE ENDS, at shipping radii and at the separation
    -- that was worst -- and it asserts the sign as well as the size. A wall drawn
    -- OUTSIDE the damaging boundary is the failure; being a little further inside than
    -- edgeInset asked for never is.
    --
    -- ═══ AND IT IS THE BLOB ZONE BEING MEASURED AGAINST SINCE #344 ═══
    --
    -- The one line that changed is the shape: the zone this compares the curtain
    -- with is the one the record really describes, not a pair of circles. The
    -- measure is still the UNION's own signed distance rather than the part a quad
    -- came from, deliberately -- the question is whether any drawn point is outside
    -- THE BOUNDARY THAT DAMAGES, and an overlapping pair's damaging boundary is the
    -- union. A quad that legitimately runs through the lens is deep inside it, which
    -- a maximum ignores.
    local function excursionOn(phase, r0, r1, sep, samples)
        local E = newStormClient()
        local erec = E.record(phase, 0.0, 0.0, r0, sep, 0.0, r1, 600000, 60000, 2.0)
        E.pedAt = pt(r0 * 0.5, 0.0, 30.0)
        E.frame()
        local zone = zoneOf(E.env, erec)
        local worst, at, nqd = -math.huge, nil, 0
        for _, qd in ipairs(quadsOf(E)) do
            nqd = nqd + 1
            for k = 0, samples do
                local t = k / samples
                local x = qd.a.x + (qd.b.x - qd.a.x) * t
                local y = qd.a.y + (qd.b.y - qd.a.y) * t
                local d = SS.distance(zone, x, y)
                if d > worst then worst, at = d, ('%.1f,%.1f'):format(x, y) end
            end
        end
        return worst, nqd, at, E
    end

    -- THE PAIRS ARE NAMED BY RADIUS AND DRIVEN AT PHASE 2 OR LATER, deliberately:
    -- the phase number reaches this geometry only through the phase-1 fade-in gate,
    -- which draws NOTHING for most of the hold -- so a 2600 + 1600 case recorded as
    -- phase 1 would run clean by drawing no wall at all, which is the shape of hole
    -- this block exists to close. The separations are the worst reachable ones, found
    -- by sweeping the whole overlap range for each pair.
    local VENN = {
        { 2, 2600.0, 1600.0, 3392.0 },
        { 2, 1600.0,  950.0, 1932.5 },
        { 3,  950.0,  520.0, 1171.0 },
        { 4,  520.0,  260.0,  583.7 },
        { 5,  260.0,  110.0,  284.2 },
    }
    local worstOut, outAt, cleanRuns = -math.huge, nil, 0
    for _, v in ipairs(VENN) do
        local e, nqd, at, E = excursionOn(v[1], v[2], v[3], v[4], 24)
        if E.errored() == nil and nqd > 0 then cleanRuns = cleanRuns + 1 end
        if e > worstOut then worstOut, outAt = e, ('%.0f+%.0f at %s'):format(
            v[2], v[3], tostring(at)) end
    end
    -- INSIDE BY ABOUT edgeInset, which is the whole claim: no sampled point of any
    -- quad is outside the damaging boundary, and the curtain sits the inset's worth
    -- within it. The tolerance is a millimetre rather than exact because the inset of
    -- a union shrinks each disc, which near a reflex corner pulls a hair further in
    -- than a true erosion would -- inward, which is the safe direction.
    ok(cleanRuns == #VENN and worstOut <= -(rr.edgeInset or 0.0) + 1e-3,
        'and no point BETWEEN two corners leaves the damaging boundary either, on '
            .. 'every shipping phase pair at its worst reachable separation -- the '
            .. 'curtain is edgeInset inside the edge, not 33 metres outside it',
        ('%d of %d ran clean; worst signed distance %+0.2f m against %+0.2f, at %s')
            :format(cleanRuns, #VENN, worstOut, -(rr.edgeInset or 0.0),
                tostring(outAt)))

    -- ═══ ROUNDNESS: A QUAD MAY BE LONG, BUT NOT LONG ENOUGH TO SHOW ═══
    --
    -- This is why the strip draws the WHOLE boundary where the columns could not. A
    -- column must be about as wide as its spacing or the colonnade gaps, so slotArc
    -- pins the count and maxDraw then rations it -- 15 percent of the ring at phase
    -- 1. A quad SHARES both vertical edges with its neighbours, so it may be as long
    -- as roundness allows. Sag goes as ds^2 / 8r, and chordM is the ceiling on it.
    local worstSag, sagAt = 0.0, nil
    for _, ph in ipairs(base.env.BR.Config.Storm.phases) do
        if ph.radius > 50.0 then
            local E = newStormClient()
            local erec = E.record(2, 0.0, 0.0, ph.radius, 0.0, 0.0,
                ph.radius * 0.5, 600000, 60000, 2.0)
            E.pedAt = pt(0.0, 0.0, 30.0)
            E.frame()
            local drawn = SS.inset(zoneOf(E.env, erec), rr.edgeInset)
            for _, qd in ipairs(quadsOf(E)) do
                local sag = sagOf(E.env, drawn, qd)
                if sag > worstSag then
                    worstSag, sagAt = sag, ('r %.0f'):format(ph.radius)
                end
            end
        end
    end
    ok(worstSag <= sp.chordM + 1e-6,
        'no quad cuts more than chordM off the arc it replaces, on any shipping '
            .. 'phase radius -- a 2600m ring closes in about 80 quads and nobody '
            .. 'standing inside it can see the corners',
        ('worst sag %.3f m against %.1f, at %s'):format(worstSag, sp.chordM,
            tostring(sagAt)))

    -- ═══ AND ON THE WIDEST SHAPES IN THE GAME, WHICH IS WHERE #337 WAS HIDING ═══
    --
    -- The sweep above drives NESTED circles, which is exactly the set of shapes the
    -- poly ceiling never reached -- so it went green for two commits over a real
    -- override. Measured at the time: a disjoint 2600 + 1600 wanted 166 quads for two
    -- metres of sag and was rationed to 127, so the true worst sag on the two widest
    -- shapes in the game was 5.09 m against a chordM of 2.0. The budget was silently
    -- deciding the SHAPE of the wall.
    --
    -- THE GRADIENT CLOSES IT WITHOUT A NEW KNOB, which is the point of asserting it
    -- here rather than raising maxPolys: a gradient quad is 2 polys instead of 6, so
    -- the per-loop share triples and the rationing simply stops happening. This is the
    -- assertion that would notice the day somebody lowers maxPolys, raises fade.bands,
    -- or makes the banded path the default again.
    local W = newStormClient()
    local wrec2 = W.record(2, 0.0, 0.0, 2600.0, 4400.0, 0.0, 1600.0,
        600000, 60000, 1.25)
    W.pedAt = pt(0.0, 0.0, 30.0)
    W.frame()
    local wShape = SS.inset(zoneOf(W.env, wrec2), rr.edgeInset)
    local wideSag, wideAt = 0.0, nil
    for _, qd in ipairs(quadsOf(W)) do
        local sag = sagOf(W.env, wShape, qd)
        if sag > wideSag then
            wideSag, wideAt = sag, ('%.1f,%.1f'):format(qd.a.x, qd.a.y)
        end
    end
    ok(#W.polys > 0 and wideSag <= sp.chordM + 1e-6,
        'and the widest shape the game can build -- a fully separated phase-2 '
            .. 'breakout -- is inside chordM too, so nothing is rationed anywhere and '
            .. 'the budget is no longer deciding how round the wall is (#337)',
        ('worst sag %.3f m against %.1f at %s, in %d polys of %d'):format(
            wideSag, sp.chordM, tostring(wideAt), #W.polys, sp.maxPolys))

    -- ═══ THE BUDGET, WHICH IS A CEILING AND NOT A HOPE ═══
    --
    -- The per-loop share is maxPolys / 2 / loops, taken BEFORE roundness is
    -- consulted, so no shape can talk its way past it. The worst real case is a
    -- phase-2 breakout that separated: two loops of 2600 and 1600 metres of radius
    -- would each like upwards of seventy quads, which unbudgeted is 380 polys.
    local worstPolys, worstWhere = 0, nil
    local function budget(label, phase, r0, sep, r1)
        local E = newStormClient()
        E.record(phase, 0.0, 0.0, r0, sep, 0.0, r1, 600000, 60000, 2.0)
        E.pedAt = pt(0.0, 0.0, 30.0)
        E.frame()
        if #E.polys > worstPolys then worstPolys, worstWhere = #E.polys, label end
        return #E.polys
    end
    for i, ph in ipairs(base.env.BR.Config.Storm.phases) do
        -- The nested case, which is 60 to 90 percent of phases: union2 returns the
        -- containing circle, so this is one loop at the phase radius.
        budget(('phase %d nested'):format(i), i,
            math.max(ph.radius, 1.0), 0.0, math.max(ph.radius * 0.4, 1.0))
    end
    budget('phase 2 disjoint', 2, 2600.0, 4400.0, 1600.0)
    budget('phase 4 disjoint', 4, 520.0, 1040.0, 260.0)
    ok(worstPolys <= sp.maxPolys,
        'the worst frame any shipping geometry can produce stays inside the stated '
            .. 'poly budget',
        ('%d polys at %s, ceiling %d'):format(worstPolys, tostring(worstWhere),
            sp.maxPolys))
    -- AND THE ENDGAME STILL HAS A WALL. Phase 8 closes on a zero-radius target and
    -- union2 refuses a disc with no radius at all, so the shape is the wall circle
    -- alone -- 34 metres of it after the inset, where the sag rule would draw an
    -- octagon and minSeg is what stops it.
    local endPolys = budget('phase 8 point', 8, 40.0, 55.0, 0.0)
    ok(endPolys == sp.minSeg * quadPolys,
        'and the endgame circle is drawn at the minSeg floor rather than as the '
            .. 'octagon roundness alone would settle for',
        ('%d polys, %d quads against a floor of %d'):format(endPolys,
            endPolys / quadPolys, sp.minSeg))
end

-- ---------------------------------------------------------------------------
describe('wall.ramp')
do
    -- ═══ THE BAKED ALPHA RAMP, WHICH IS WHY THE WALL IS SMOOTH ═══
    --
    --   the 3-band wall "reads as three visible steps"   -- the owner, playtested
    --
    -- Three stacked flat quads are three steps, and no amount of tuning makes a
    -- staircase a ramp. The fix is not more bands -- that rations quads and makes the
    -- ring polygonal instead, which trades a visible defect for a worse invisible one
    -- (see the note beside maxPolys). The fix is to stop approximating: bake the ramp
    -- into a RUNTIME TEXTURE's own 256 alpha levels and let the sampler interpolate.
    --
    -- NO STREAMED ASSET IS INVOLVED, which is the finding the first attempt missed.
    -- CreateRuntimeTxd plus CreateRuntimeTexture needs no .ytd, no stream folder and
    -- no manifest entry, and br_core/client/dui.lua has been feeding exactly such a
    -- texture to DrawSpritePoly in production since #236.
    --
    -- WHAT THIS BLOCK CAN AND CANNOT SEE. It can prove the texture was created at the
    -- size asked for, that every pixel was written, that the writes were committed
    -- afterwards, that the rows hold the intended curve, and that the fallback ladder
    -- names each rung it climbs. It CANNOT prove a pixel appeared on screen, and it
    -- cannot prove whether the blend is premultiplied or straight -- the one guess in
    -- the design. client/storm.lua's header says what each looks like.

    local base = newStormClient()
    local sp = base.env.BR.Config.Storm.render.strip
    local fd = sp.fade
    local rr = base.env.BR.Config.Storm.render
    local W = math.max(1, math.floor(fd.rampW or 8))
    local H = math.max(2, math.floor(fd.rampH or 256))

    local C = newStormClient()
    C.frame()
    local tex = C.rt.tex

    ok(C.errored() == nil, 'the gradient wall runs clean', C.errored())
    ok(tex ~= nil, 'a runtime texture is created')
    ok(tex and tex.txd == fd.txd and tex.name == fd.texture,
        'under the dictionary and texture names the config asks for',
        tex and ('%s:%s against %s:%s'):format(tex.txd, tex.name,
            tostring(fd.txd), tostring(fd.texture)))
    ok(tex and tex.w == W and tex.h == H,
        'at the configured size -- 8 wide so the u axis is not degenerate, 256 tall '
            .. 'so there is one row per alpha level the format has',
        tex and ('%dx%d against %dx%d'):format(tex.w, tex.h, W, H))

    -- ═══ NOT ONE STREAMED DICTIONARY, WHICH IS THE ESTATE RULE ═══
    --
    -- HasStreamedTextureDictLoaded is also the WRONG QUESTION for a slot with no
    -- backing .ytd -- it would answer no forever -- so the old gate could never have
    -- opened on a runtime texture even if somebody had pointed it at one.
    ok(#C.streamed == 0,
        'and the wall asks the streamer for nothing at all: no dictionary requested, '
            .. 'none waited on, so the no-streamed-assets rule is untouched',
        table.concat(C.streamed, ', '))

    -- ═══ EVERY PIXEL WRITTEN, AND COMMITTED AFTER THE WRITES AND NOT BEFORE ═══
    --
    -- SET_RUNTIME_TEXTURE_PIXEL writes a CPU backing buffer; the decl says the change
    -- "requires finalization through COMMIT_RUNTIME_TEXTURE to take effect". A commit
    -- issued before the writes uploads a blank texture, and a blank texture is a wall
    -- that draws nothing -- invisible to every other measure here, which is why the
    -- harness records how many pixels existed at commit time.
    ok(tex and tex.written == W * H,
        'every pixel of the ramp is written',
        tex and ('%d of %d'):format(tex.written, W * H))
    ok(tex and tex.commits == 1 and tex.committedAfter == W * H,
        'and committed exactly once, after the last write -- a commit before the '
            .. 'writes uploads a blank texture and draws an invisible wall',
        tex and ('%d commits, %d pixels present at commit'):format(
            tex.commits, tostring(tex.committedAfter)))

    -- ═══ PREMULTIPLIED GREY: r = g = b = a ON EVERY PIXEL ═══
    --
    -- The one guess in the design, and it is the safe direction. The proven
    -- DrawSpritePoly source in this tree is a CEF surface, which is premultiplied, so
    -- this matches the blend the native is known to work with here. White-with-alpha
    -- would be the backwards guess: under a premultiplied blend (255, 255, 255, a)
    -- contributes full colour at every height whatever a is, which is an opaque white
    -- haze over the top of the wall. Premultiplied grey under a STRAIGHT blend merely
    -- comes out steeper than authored, which is a fade either way.
    local notGrey, greyAt = 0, nil
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local p = tex and tex.px[y] and tex.px[y][x]
            if not p or p.r ~= p.a or p.g ~= p.a or p.b ~= p.a then
                notGrey = notGrey + 1
                greyAt = greyAt or ('row %d col %d'):format(y, x)
            end
        end
    end
    ok(notGrey == 0,
        'every pixel is premultiplied grey -- r = g = b = a -- which is the blend the '
            .. 'only proven DrawSpritePoly path in this tree feeds',
        greyAt or ('%d pixels off-grey'):format(notGrey))

    -- AND EVERY COLUMN IS THE SAME, because the width exists only to keep the u axis
    -- non-degenerate. A ramp that varied across u would fade ALONG the wall as well
    -- as up it, which is the picket fence arriving through the texture.
    local colBad = nil
    for y = 0, H - 1 do
        local first = tex and tex.px[y] and tex.px[y][0]
        for x = 1, W - 1 do
            local p = tex and tex.px[y] and tex.px[y][x]
            if not p or not first or p.a ~= first.a then
                colBad = colBad or ('row %d col %d'):format(y, x)
            end
        end
    end
    ok(colBad == nil,
        'and every column of a row is identical, so the fade runs up the wall and '
            .. 'never along it',
        colBad)

    -- ═══ THE CURVE ITSELF, ROW BY ROW, AGAINST THE CONFIG'S OWN ARITHMETIC ═══
    --
    -- v = 0 IS THE FIRST ROW, not the last -- the ordinary D3D convention, and this
    -- tree already relies on it: dui.lua's drawQuad documents `a` as the texture's
    -- top-left and gives it UV (0, 0), and the warmup board renders right side up in
    -- production off exactly that. The draw gives the wall's BOTTOM v = 0, so row 0
    -- must hold the base alpha. If this were inverted the wall would be transparent at
    -- the ground and solid at 850 m, which is unmistakable rather than subtle.
    local rowBad, rowsChecked = nil, 0
    for y = 0, H - 1 do
        local z = sp.baseZ + (sp.topZ - sp.baseZ) * (y / (H - 1))
        local want = math.floor(rampMul(fd, sp.baseZ, sp.topZ, z) * 255.0 + 0.5)
        local got = tex and tex.px[y] and tex.px[y][0] and tex.px[y][0].a
        rowsChecked = rowsChecked + 1
        if got ~= want then
            rowBad = rowBad or ('row %d (z %.1f) holds %s, wanted %d'):format(
                y, z, tostring(got), want)
        end
    end
    ok(rowsChecked == H and rowBad == nil,
        'every row holds the ramp the config describes, evaluated at that row\'s own '
            .. 'world height -- row 0 is the BOTTOM of the wall, which is the texture '
            .. 'convention dui.lua already ships against',
        rowBad or ('%d rows, all matching'):format(rowsChecked))

    local row0 = tex and tex.px[0] and tex.px[0][0] and tex.px[0][0].a
    local rowN = tex and tex.px[H - 1] and tex.px[H - 1][0] and tex.px[H - 1][0].a
    ok(row0 == math.floor((fd.baseAlpha or 1.0) * 255.0 + 0.5)
        and rowN == math.floor((fd.topAlpha or 0.0) * 255.0 + 0.5)
        and row0 > rowN,
        'the bottom row is baseAlpha and the top row is topAlpha, in that order -- an '
            .. 'inverted ramp is a purple ceiling with no base',
        ('row 0 %s, row %d %s'):format(tostring(row0), H - 1, tostring(rowN)))

    local nonMono, monoAt = 0, nil
    for y = 1, H - 1 do
        local a, b = tex.px[y - 1][0].a, tex.px[y][0].a
        if b > a then
            nonMono = nonMono + 1
            monoAt = monoAt or ('row %d rises from %d to %d'):format(y, a, b)
        end
    end
    ok(nonMono == 0, 'and it never rises on the way up', monoAt)

    -- ═══ #341: WHICH OF THE FOUR CANDIDATES THE BAKE ITSELF RULES OUT ═══
    --
    --   "smooth but there is a very tiny line at the top of it"  -- the owner, #341
    --
    -- Two of the four hypotheses were claims about the TEXTURE, and this is the
    -- measurement that answers both, kept as an assertion rather than as a paragraph
    -- because a retune of the ramp is exactly what would quietly bring either back.
    --
    --   * ROUNDING AT THE LAST ROW. `floor(rampAlpha * 255 + 0.5)` at t = 1.0 with
    --     topAlpha 0 has to give 0 and not 1, and the rows under it have to be dark
    --     too -- a top row of 0 above a row of 40 would still read as an edge.
    --   * A COARSE MIP LEVEL averaging the top rows upward. Every mip level's top
    --     texel is an average of the top rows of THIS ramp, so if the top rows are
    --     dark no level of any chain can put a bright pixel at the top of the wall.
    --     (What a coarse LOD would actually do is flatten the WHOLE wall, and the
    --     owner's report is the opposite -- "the gradient looks great though".)
    --
    -- SO THE TOP EIGHTH OF THE RAMP IS ASSERTED DARK, which is 32 rows and 125 m of
    -- wall -- far more than the artifact's thickness, so it cannot pass by accident.
    -- BRIGHT is a quarter of full opacity, the same number the wrap model below calls
    -- bright, so the two assertions are two halves of one argument rather than two
    -- thresholds that happen to sit near each other.
    local BRIGHT = 64
    local topDark, topWorst = true, 0
    for y = H - math.floor(H / 8), H - 1 do
        local a = tex.px[y][0].a
        if a > topWorst then topWorst = a end
        if a >= BRIGHT then topDark = false end
    end
    ok(tex.px[H - 1][0].a == 0 and topDark,
        'the ramp reaches exactly zero at its last row and no row in its top eighth '
            .. 'reaches a quarter of full opacity -- so neither rounding at the last '
            .. 'row nor a mip level averaging the top rows can be the bright line #341 '
            .. 'reported',
        ('row %d reads %d, worst of the top %d rows %d against %d'):format(
            H - 1, tex.px[H - 1][0].a, math.floor(H / 8), topWorst, BRIGHT))

    -- ═══ AND THE ONE THAT IS LEFT, MODELLED: A SAMPLER THAT WRAPS ═══
    --
    -- The address mode is a property of the native's sampler and NO LUA IN THIS ESTATE
    -- CAN READ IT -- said plainly, because it is the one thing about #341 that only a
    -- playtest confirms. What can be stated exactly is the consequence, so both address
    -- modes are modelled here over the real baked rows: at v = 1.0 a REPEAT sampler is
    -- bright and a CLAMP sampler is not, and at the v the wall actually uses BOTH are
    -- dark. That is what makes the inset the correct fix without knowing the answer.
    local function bilinear(v, wrap)
        local c = v * H - 0.5
        local i0 = math.floor(c)
        local f = c - i0
        local function at(i)
            if wrap then i = i % H
            elseif i < 0 then i = 0
            elseif i > H - 1 then i = H - 1 end
            return tex.px[i][0].a
        end
        return at(i0) * (1.0 - f) + at(i0 + 1) * f
    end
    local vTopIn = (H - 0.5) / H
    local vBotIn = 0.5 / H
    ok(bilinear(1.0, true) >= BRIGHT and bilinear(1.0, false) < 1
        and bilinear(vTopIn, true) < 1 and bilinear(vTopIn, false) < 1,
        'and a bilinear sample at v = 1.0 reads half-opaque under a REPEAT address mode '
            .. 'and nothing under CLAMP, while the half-texel-inset v the wall now uses '
            .. 'reads nothing under EITHER -- which is why the inset is right without '
            .. 'knowing which mode this native\'s sampler uses',
        ('v 1.0: wrap %.1f, clamp %.1f | v %.9f: wrap %.1f, clamp %.1f'):format(
            bilinear(1.0, true), bilinear(1.0, false), vTopIn,
            bilinear(vTopIn, true), bilinear(vTopIn, false)))

    -- AND WHY THE BOTTOM NEVER SHOWED IT, which is the question the fix has to answer
    -- to be trustworthy: a wrap at v = 0 reads row H-1 alongside row 0, so it DARKENS
    -- the edge by about half instead of brightening it -- and it does so at z -150,
    -- which is the underground skirt. Two independent reasons, either sufficient; the
    -- inset is applied there anyway, because rampBaseZ is exactly the knob that could
    -- one day raise that edge into daylight.
    ok(bilinear(0.0, true) < bilinear(0.0, false)
        and bilinear(vBotIn, true) == 255 and bilinear(vBotIn, false) == 255,
        'while a wrap at the BOTTOM edge darkens rather than brightens -- which, with '
            .. 'that edge 150 m underground, is why only the top of the wall was ever '
            .. 'reported',
        ('v 0.0: wrap %.1f against clamp %.1f; inset %.1f'):format(
            bilinear(0.0, true), bilinear(0.0, false), bilinear(vBotIn, true)))

    -- ═══ THE STEPS ARE GONE, AND THIS IS THE ASSERTION THAT SAYS SO ═══
    --
    -- The defect was three visible steps. What makes a ramp smooth is that no
    -- neighbouring pair of levels jumps far enough to read as an edge: across the
    -- sloping part of the curve this ramp moves by at most one alpha level per row,
    -- 256 rows over a 1000 m wall. The 3-band fallback moves by 43 levels at each of
    -- its two seams, which is the staircase the owner saw. Asserted as a ratio so it
    -- survives a retune of baseAlpha.
    local worstJump = 0
    for y = 1, H - 1 do
        local d = tex.px[y - 1][0].a - tex.px[y][0].a
        if d > worstJump then worstJump = d end
    end
    local bandJump = math.floor(255.0 * ((fd.baseAlpha or 1.0) - (fd.topAlpha or 0.0))
        / math.max(1, math.floor(fd.bands or 3)) + 0.5)
    ok(worstJump <= 2 and worstJump * 10 < bandJump,
        'no two adjacent levels of the baked ramp differ by more than a level or two, '
            .. 'against the 3-band fallback\'s 40-odd at every seam -- which is the '
            .. 'difference between a fade and the three steps that were reported',
        ('worst jump %d levels against the banded path\'s %d'):format(
            worstJump, bandJump))

    -- ═══ AND THE NUMBER THE PINNED DOMAIN ACTUALLY BUYS ═══
    --
    -- The geometry stands on baseZ (-150) so no gap can open under the curtain on a
    -- slope. The RAMP starts at ground level instead, and this is what the difference
    -- is worth where players actually are. City ground is around 30.
    --
    -- `unpinned` is the OLD curve spelled out, so this assertion is a comparison
    -- between two designs rather than a restatement of the current one -- it goes red
    -- if production reverts to measuring the ramp from the geometry's base, which is
    -- a change that rampMul alone would follow silently if rampBaseZ simply vanished.
    local cityRow = math.floor((30.0 - sp.baseZ) / (sp.topZ - sp.baseZ) * (H - 1) + 0.5)
    local atCity = tex.px[cityRow][0].a
    local unpinned = math.floor(255.0
        * (1.0 - (30.0 - sp.baseZ) / (sp.topZ - sp.baseZ)) + 0.5)
    ok(atCity >= 240 and atCity - unpinned >= 30,
        'at city ground the ramp is still within a few levels of full strength, where '
            .. 'a ramp measured from the geometry\'s underground base would already '
            .. 'have given away 18 percent of the wall nobody can see',
        ('row %d reads %d; measured from baseZ it would read %d'):format(
            cityRow, atCity, unpinned))

    -- ═══ AND THE INSET IS COMPUTED FROM THE HEIGHT THE TEXTURE WAS BUILT AT ═══
    --
    -- A HALF TEXEL OF 256 WRITTEN OUT AS A LITERAL would pass every assertion in this
    -- file at the shipping config and be wrong the day rampH moved -- which is the same
    -- class of defect as #341 itself, one level up: a v that no longer lands on a row
    -- centre. So a client with a DIFFERENT rampH is stood up and the drawn v range has
    -- to have moved with it. 64 rather than 256, which is coarse enough that a stale
    -- 1/512 inset lands four rows inside the texture and is unmistakable.
    local small = newStormClient()
    small.env.BR.Config.Storm.render.strip.fade.rampH = 64
    small.frame()
    local sH = 64
    local sWant0, sWant1 = 0.5 / sH, (sH - 0.5) / sH
    local sLo, sHi = math.huge, -math.huge
    for _, t in ipairs(small.polys) do
        for j = 1, 3 do
            if t[j].v < sLo then sLo = t[j].v end
            if t[j].v > sHi then sHi = t[j].v end
        end
    end
    ok(small.rt.tex and small.rt.tex.h == sH
        and math.abs(sLo - sWant0) < 1e-12 and math.abs(sHi - sWant1) < 1e-12,
        'and a client built at a different rampH insets by ITS half texel, not by a '
            .. 'literal 1/512 -- the inset is a property of the texture, so it moves '
            .. 'when the texture does',
        ('%d rows, v %.9f to %.9f, wanted %.9f to %.9f'):format(
            small.rt.tex and small.rt.tex.h or -1, sLo, sHi, sWant0, sWant1))

    -- ═══ BUILT ONCE PER RESOURCE START, NOT PER FRAME ═══
    --
    -- 2048 pixel writes are cheap once and ruinous at 60 Hz. The latch is the same one
    -- that makes the console line appear once.
    local before = tex.written
    local madeBefore = C.rt.made
    C.frame() C.frame() C.frame()
    ok(tex.written == before and tex.commits == 1
        and C.rt.made == madeBefore and C.rt.made == 1,
        'and three more frames neither rewrite it, recommit it, nor make a second one '
            .. '-- 2048 pixel writes are cheap once and ruinous at 60 Hz, and runtime '
            .. 'textures cannot be destroyed once created',
        ('%d writes, %d commits, %d textures ever made'):format(
            tex.written, tex.commits, C.rt.made))

    -- ═══ THE ANNOUNCEMENT, WHICH IS THE OWNER'S ONLY WAY TO KNOW ═══
    --
    --   "give me a way to know whether it fellback."   -- the owner, 2026-09-22
    local said, saidN = nil, 0
    for _, line in ipairs(C.prints) do
        if line:find('storm wall fade', 1, true) then
            saidN = saidN + 1
            said = said or line
        end
    end
    ok(saidN == 1 and said and said:find('gradient', 1, true),
        'the wall says which path it took, once per resource start and not per frame',
        ('%d lines: %s'):format(saidN, tostring(said)))
    ok(said and said:find('runtime ramp', 1, true)
        and said:find(tostring(fd.txd), 1, true),
        'and the rung names the runtime ramp it built, so "did it fall back" is '
            .. 'answerable from the console alone',
        tostring(said))

    -- AND IT SAYS WHICH GATE RAN. The read-back is what separates "the texture is
    -- there" from "the call returned something", so a build missing
    -- GetRuntimeTextureWidth gets a weaker gate -- and has to say so rather than
    -- reporting the same line as a verified one.
    ok(said and said:find('width read back', 1, true),
        'and names the read-back as the gate that actually ran',
        tostring(said))

    local noRead = newStormClient()
    noRead.env.GetRuntimeTextureWidth = nil
    noRead.frame()
    ok(noRead.env.BR.Storm.fadePath == 'gradient'
        and noRead.env.BR.Storm.fadeRung:find('handle trusted', 1, true),
        'a build without the read-back native still gets the gradient, and the '
            .. 'console line admits the gate was the handle alone',
        tostring(noRead.env.BR.Storm.fadeRung))

    -- AND /brwallstyle REPEATS IT AT ANY TIME, which is the command the owner reaches
    -- for while looking at the wall.
    local mark = #C.prints
    C.cmds.brwallstyle()
    local reported = nil
    for i = mark + 1, #C.prints do
        if C.prints[i]:find('storm wall fade', 1, true) then reported = C.prints[i] end
    end
    ok(reported and reported:find('gradient', 1, true)
        and reported:find('runtime ramp', 1, true),
        '/brwallstyle reports the path and the rung on demand',
        tostring(reported))

    -- ═══ A WALL WITH NO HEIGHT BAKES NOTHING, WHICH IS WHY THE GUARD MOVED ═══
    --
    -- The span check used to sit below the fade resolution. It had to move above it,
    -- because the ramp is baked FROM the span: a topZ at or under baseZ divides by
    -- zero or by a negative, and a nan written into the texture is latched there for
    -- the rest of the session -- an invisible wall with nothing in the console, on
    -- every frame after, with no way back short of a restart. Refusing first means the
    -- bad config costs a missing wall rather than a poisoned texture.
    local flat = newStormClient()
    flat.env.BR.Config.Storm.render.strip.topZ =
        flat.env.BR.Config.Storm.render.strip.baseZ
    flat.frame()
    ok(#flat.polys == 0 and flat.rt.tex == nil and flat.errored() == nil,
        'a wall of no height draws nothing AND bakes no texture -- the span guard runs '
            .. 'before the ramp, so a bad config cannot latch a nan into a texture '
            .. 'that outlives it',
        ('%d polys, texture %s'):format(#flat.polys,
            flat.rt.tex and 'baked' or 'none'))

    -- ═══ THE LADDER, RUNG BY RUNG, EACH ONE NAMED ═══
    --
    -- A fallback whose reason is unknown is barely better than a silent one: the owner
    -- has to be able to tell "you asked for bands" from "the texture would not build"
    -- from "this build has no such native". Each rung below is a separate client with
    -- one thing broken, and each asserts BOTH that the wall still drew and that the
    -- console said why.
    local function rung(C2)
        C2.frame()
        local line = nil
        for _, l in ipairs(C2.prints) do
            if l:find('storm wall fade', 1, true) then line = l end
        end
        return (C2.env.BR.Storm or {}).fadePath, (C2.env.BR.Storm or {}).fadeRung,
            line, #C2.polys
    end

    local p1, r1, l1, n1 = rung(bandedClient())
    ok(p1 == 'bands' and r1 == 'config prefers bands' and n1 > 0
        and l1 and l1:find('banded', 1, true),
        'prefer = bands falls back on request, draws a wall anyway, and says it was '
            .. 'asked to',
        ('%s / %s / %d polys'):format(tostring(p1), tostring(r1), n1))

    local noNative = newStormClient()
    noNative.env.DrawSpritePoly = nil
    local p2, r2, _, n2 = rung(noNative)
    ok(p2 == 'bands' and r2 and r2:find('DrawSpritePoly', 1, true) and n2 > 0,
        'a build without DrawSpritePoly bands instead of drawing nothing, and names '
            .. 'the missing native',
        ('%s / %s / %d polys'):format(tostring(p2), tostring(r2), n2))

    local noTxd = newStormClient()
    noTxd.env.CreateRuntimeTexture = nil
    local p3, r3, _, n3 = rung(noTxd)
    ok(p3 == 'bands' and r3 and r3:find('CreateRuntimeTexture', 1, true) and n3 > 0,
        'and a build without the runtime-texture natives says which one is missing',
        ('%s / %s / %d polys'):format(tostring(p3), tostring(r3), n3))

    -- ═══ THE TEXTURE REFUSED UNDER EVERY NAME, WHICH IS THE BOUND'S OWN RUNG ═══
    --
    -- This is the rung that matters most, because a truthy handle is the thing it would
    -- be easiest to trust: the wall must band rather than draw two triangles pointed at
    -- a texture that is not there. It is also the case a client with genuinely broken
    -- runtime-texture support presents, so it is what the bound exists for -- an
    -- unbounded probe would spin here instead of falling back.
    local NT = math.max(1, math.floor(fd.nameTries or 32))
    local refused = newStormClient()
    refused.rt.refuseAllTex = true
    local p4, r4, _, n4 = rung(refused)
    ok(p4 == 'bands' and r4 and r4:find(('%d names'):format(NT), 1, true) and n4 > 0,
        'a texture refused under every name it may try bands rather than drawing quads '
            .. 'pointed at nothing -- which is the failure that costs the whole curtain',
        ('%s / %s / %d polys'):format(tostring(p4), tostring(r4), n4))

    -- AND IT STOPPED AT THE BOUND rather than probing past it. The harness throws after
    -- 500 probes so that a bound removed entirely is a red test rather than a hang, but
    -- that ceiling is far above any legitimate value -- this is the assertion that
    -- notices a bound merely raised or ignored.
    ok(refused.rt.txdCalls == NT and refused.errored() == nil,
        'and it made exactly nameTries probes getting there: the loop is bounded, so a '
            .. 'client whose runtime-texture support is broken reaches the fallback '
            .. 'instead of spinning',
        ('%s probes against a bound of %d; %s'):format(
            tostring(refused.rt.txdCalls), NT,
            tostring(refused.errored())))

    -- THE READ-BACK GATE. A handle that came back truthy while no surface exists is
    -- exactly what the width check is for, so a lying width must reach bands.
    local lying = newStormClient()
    lying.rt.widthLie = 4
    local p5, r5, _, n5 = rung(lying)
    ok(p5 == 'bands' and r5 and r5:find('read back', 1, true) and n5 > 0,
        'and a texture whose width reads back wrong is not trusted either: the gate is '
            .. 'a read-back, not a handle',
        ('%s / %s / %d polys'):format(tostring(p5), tostring(r5), n5))

    -- ═══ RESTART SAFETY, AND THE SUFFIX HAS TO MOVE THE DICTIONARY TOO ═══
    --
    -- A br_core restart in the same client session loses our Lua handles while the
    -- engine keeps the texture -- runtime textures cannot be destroyed, so the slot
    -- stays taken for the life of the client. FiveM's RuntimeAssetNatives.cpp refuses
    -- at the DICTIONARY level: CREATE_RUNTIME_TXD only builds its backing dictionary
    -- when the streaming slot has no handle yet, so the second call for an existing TXD
    -- name yields an object on which EVERY CreateTexture returns nothing, whatever the
    -- texture is called. A retry that suffixed only the texture name would therefore
    -- retry straight back into the same wall -- and would look correct in review.
    --
    -- ═══ AND THE NAME COUNTS UP, BECAUSE ONE RETRY PUT RESTART 3 ON BANDS ═══
    --
    -- This was the plain name then `_b` then bands, which meant the THIRD br_core start
    -- of a client session drew the stepped wall. That lands inside the owner's playtest
    -- loop -- he restarts br_core repeatedly within one round -- and reads as the fade
    -- having regressed rather than as a slot collision. So the probe counts: the plain
    -- name, `_2`, `_3`, up to nameTries.
    --
    -- THE SWEEP IS WHAT MAKES "IT COUNTS" PROVABLE. Asserting one restart only proves
    -- there is a second name; a renderer that stopped advancing after `_2` -- the exact
    -- shape of the bug being fixed -- would pass that and fail here.
    local deepest, deepBad = 0, nil
    for taken = 0, 6 do
        local R = newStormClient()
        -- `taken` previous starts have already claimed their slots.
        R.rt.preTxd[fd.txd] = taken >= 1 or nil
        for k = 2, taken do R.rt.preTxd[fd.txd .. '_' .. k] = true end
        R.frame()
        local rt = R.rt.tex
        local wantTxd = (taken == 0) and fd.txd or (fd.txd .. '_' .. (taken + 1))
        local wantTex = (taken == 0) and fd.texture
            or (fd.texture .. '_' .. (taken + 1))
        if R.env.BR.Storm.fadePath ~= 'gradient' or #R.polys == 0 then
            deepBad = deepBad or ('%d taken: fell back to %s'):format(
                taken, tostring(R.env.BR.Storm.fadePath))
        elseif not rt or rt.txd ~= wantTxd or rt.name ~= wantTex then
            deepBad = deepBad or ('%d taken: landed on %s, wanted %s:%s'):format(
                taken, rt and (rt.txd .. ':' .. rt.name) or 'nothing',
                wantTxd, wantTex)
        elseif not R.env.BR.Storm.fadeRung:find(
                ('attempt %d of'):format(taken + 1), 1, true) then
            deepBad = deepBad or ('%d taken: rung says %s'):format(
                taken, R.env.BR.Storm.fadeRung)
        else
            deepest = taken + 1
        end
    end
    ok(deepBad == nil and deepest == 7,
        'seven consecutive br_core starts in one client session each take the next '
            .. 'free name -- dictionary and texture together -- and every one of them '
            .. 'reaches the gradient, where one retry put the third on bands',
        deepBad or ('advanced through %d attempts'):format(deepest))

    -- AND THE CONSOLE LINE CARRIES THE ATTEMPT NUMBER, which is how a leak gets
    -- noticed: attempt 5 means four 8 KiB textures are stranded behind this one.
    local restarted = newStormClient()
    restarted.rt.preTxd[fd.txd] = true
    for k = 2, 4 do restarted.rt.preTxd[fd.txd .. '_' .. k] = true end
    restarted.frame()
    local rTex = restarted.rt.tex
    ok(rTex and rTex.txd == fd.txd .. '_5' and rTex.name == fd.texture .. '_5'
        and restarted.env.BR.Storm.fadeRung:find('attempt 5 of ' .. NT, 1, true),
        'and the rung names the attempt it landed on and the bound it had, so the '
            .. 'stranded-texture count is readable from the console',
        ('%s / %s'):format(rTex and (rTex.txd .. ':' .. rTex.name) or 'none',
            tostring(restarted.env.BR.Storm.fadeRung)))

    -- AND A SESSION THAT EXHAUSTS THE BOUND still bands rather than spinning. Same end
    -- as the broken-client rung above, reached the other way: here every name is taken
    -- rather than every creation refused.
    local exhausted = newStormClient()
    exhausted.rt.preTxd[fd.txd] = true
    for k = 2, NT do exhausted.rt.preTxd[fd.txd .. '_' .. k] = true end
    local p6, r6, _, n6 = rung(exhausted)
    ok(p6 == 'bands' and r6 and r6:find(('%d names'):format(NT), 1, true) and n6 > 0
        and exhausted.errored() == nil,
        'and a session that has used every name the bound allows falls back to bands '
            .. 'rather than probing forever',
        ('%s / %s / %d polys'):format(tostring(p6), tostring(r6), n6))
end

-- ---------------------------------------------------------------------------
describe('wall.point')
do
    -- ═══ THE FINAL PHASE'S DESTINATION IS A POINT, AND A POINT IS NOT AN ISLAND
    --     TO RUN TO ═══
    --
    -- config/storm.lua's phases[8] closes on `radius = 0.0`. StormShape floors
    -- every radius it BUILDS at one metre, so that target used to arrive as a
    -- one-metre disc -- and a one-metre disc more than about 35 metres from the
    -- current circle's centre is a SEPARATE COMPONENT. Phase 8's reachable offset
    -- is up to 60 metres (phase 7's r 40 plus gapMax half of it), so this was most
    -- of the phase rather than a corner of it.
    --
    -- IT COST BOTH FILES, IN OPPOSITE DIRECTIONS. The wall drew the component: a
    -- 4.8m wide, 950m tall purple pillar standing on the exact point everyone is
    -- fighting over (the shape's perimeter is 220m against a 48-slot floor, so ds
    -- is 4.6m, and the height is render.height * 3 + 50). The damage rule read the
    -- same disc as shelter, handing that point an eleven-metre safe bubble -- one
    -- metre of disc plus ten of cushion -- for the whole sweep: a safe island
    -- detached from the wall in the endgame, which is precisely what
    -- `server.collapse` exists to prevent at the other end of the phase.
    --
    -- union2 now refuses a disc whose radius is nothing at all, so BOTH FILES ASK
    -- THE SAME CONSTRUCTOR AND GET THE SAME ANSWER. That is what this block pins:
    -- not merely that the pillar is gone, but that the wall and the ledger cannot
    -- disagree about whether that disc exists.
    local penv = newStormClient().env
    local SS = penv.BR.StormShape

    local z = SS.union2(0.0, 0.0, 40.0, 55.0, 0.0, 0.0)
    ok(#(z.discs or {}) == 1 and #SS.components(z) == 1,
        'a zero-radius target is not a disc and not a component: the zone is the '
            .. 'wall circle alone',
        ('%d discs, %d components'):format(#(z.discs or {}), #SS.components(z)))
    ok(near(SS.distance(z, 55.0, 0.0), 15.0, 1e-9),
        'and the point itself reads 15m OUTSIDE that circle, which is where it is',
        SS.distance(z, 55.0, 0.0))

    -- ═══ AND THE SHAPE CONSTRUCTOR MAKES THE SAME REFUSAL (#344) ═══
    --
    -- The two arms above are union2's, which is the disc path and the way back to
    -- circles; the shipping zone is a blob and has to refuse the empty target for
    -- the same reason -- otherwise the pillar comes back wearing a different shape.
    local bz = SS.zone(0.0, 0.0, 40.0, 55.0, 0.0, 0.0,
        penv.BR.StormUnit(0, 8))
    ok(bz.kind == 'blob' and #SS.components(bz) == 1,
        'the blob zone refuses it too: one shape, one loop, no pillar on the '
            .. 'destination', ('%s, %d components'):format(tostring(bz.kind),
            #SS.components(bz)))
    ok(SS.distance(bz, 55.0, 0.0) > 0.0,
        'and the point is still OUTSIDE the wall that has not reached it',
        SS.distance(bz, 55.0, 0.0))

    -- THE COLLAPSED WALL STILL HAS A BOUNDARY TO WALK. Once the sweep ends,
    -- BR.StormAt answers the target at radius zero and the record's target is the
    -- same point, so both arguments are empty -- and the answer has to be the
    -- one-metre circle every consumer could already walk, not a shape with no
    -- length and no normal.
    local done = SS.union2(55.0, 0.0, 0.0, 55.0, 0.0, 0.0)
    ok(near(SS.perimeter(done), 2.0 * math.pi, 1e-9),
        'a wall collapsed onto its own target is still the one-metre circle it '
            .. 'always was, walkable rather than nil',
        SS.perimeter(done))

    -- ═══ THE WALL: NO PILLAR ON THE FINAL POINT ═══
    local C = newStormClient()
    -- Phase 8 from phase 7's circle: r 40 at the origin, target r 0 at 55m -- a
    -- breakout, which is an 85 percent roll at this phase.
    C.record(8, 0.0, 0.0, 40.0, 55.0, 0.0, 0.0, 600000, 60000, 6.7)
    C.env.BR.Storm.wallStyle = 'columns'
    C.pedAt = pt(0.0, 0.0)
    C.frame()
    local onPoint, closest = 0, math.huge
    for _, m in ipairs(C.markers) do
        local d = math.sqrt((m.x - 55.0) ^ 2 + m.y ^ 2)
        if d < 10.0 then onPoint = onPoint + 1 end
        if d < closest then closest = d end
    end
    ok(C.errored() == nil, 'the phase-8 wall runs clean', C.errored())
    ok(#C.markers > 0, 'and there is still a wall', #C.markers)
    ok(onPoint == 0,
        'nothing stands on the point everyone is fighting over -- no 950m pillar '
            .. 'on the final destination',
        ('%d columns within 10m, nearest %.1f m'):format(onPoint, closest))

    -- ═══ AND THE DAMAGE RULE AGREES, WHICH IS THE PART THAT MATTERS ═══
    --
    -- A player standing on the final point while the wall is still 40m away to the
    -- west is OUTSIDE it, and the storm bills them for that -- exactly as it did
    -- before #328, because a point is not somewhere to arrive early at. The client
    -- readout says the same thing from the same shape, so nothing tells them they
    -- are safe while the ledger runs down.
    local S = newStormServer()
    S.record(8, 0.0, 0.0, 40.0, 55.0, 0.0, 0.0, 600000, 60000, 6.7)
    ok(S.hurts(55.0, 0.0) == true,
        'standing on the destination while the wall is still elsewhere hurts, '
            .. 'because there is no circle there yet to be safe in')
    ok(S.hurts(0.0, 0.0) == false, 'while the wall itself is still safe')
    ok(S.errored() == nil, 'the phase-8 damage pass runs clean', S.errored())

    local E = newStormClient()
    local erec = E.record(8, 0.0, 0.0, 40.0, 55.0, 0.0, 0.0, 600000, 60000, 6.7)
    E.pedAt = pt(55.0, 0.0)
    E.tick(2)
    local e = E.last() and E.last().edgeDistance
    -- THE METRES ARE THE SHAPE'S, not `55 - 40`: the wall's reach at that bearing is
    -- whatever this phase's blob reaches there. What the assertion is for is the
    -- SIGN and the agreement with the ledger -- a one-metre disc on the destination
    -- would have read NEGATIVE here, sheltering a player the server is billing.
    local pprobe = shapeProbe(E.env, zoneOf(E.env, erec))
    ok(e ~= nil and e > 0.0 and near(e, pprobe(55.0, 0.0), 0.5),
        'and the HUD reads OUTSIDE there, agreeing with the ledger rather '
            .. 'than sheltering them in a one-metre disc',
        ('%s against %.2f'):format(tostring(e), pprobe(55.0, 0.0)))

    -- AND ONCE THE WALL ARRIVES, THE POINT IS SHELTERED BY THE CUSHION, which is
    -- the whole reason dropping the disc costs nothing: `r + margin` with r at the
    -- floor is the same ten metres of slack it always was.
    local T = newStormServer()
    local WAIT, SHRINK = 1000.0, 10000.0
    T.record(8, 0.0, 0.0, 40.0, 55.0, 0.0, 0.0, WAIT, SHRINK, 6.7)
    T.now = T.now + WAIT + SHRINK + 2000
    ok(T.hurts(55.0, 0.0) == false,
        'once the sweep ends and the wall is standing on the point, the point is '
            .. 'inside the cushion')
    ok(T.hurts(0.0, 0.0) == true,
        'and the ground the wall came from is not')
end

-- ---------------------------------------------------------------------------
describe('blob.frames')
do
    -- ═══ IT HAS TO DRAW, ON EVERY PHASE, FOR EVERY SEED, AND THAT IS ITS OWN
    ---     ASSERTION (#344) ═══
    --
    --   "ship something that will draw random shaped storm walls for each phase"
    --
    -- The owner's ask is something he can look at, and a shape that throws on frame
    -- one is worse than a circle. Every callback in client/storm.lua is pcall'd by
    -- BR.Loop.step, so a throw is a line in the console and an ABSENT wall -- which
    -- is exactly the failure this suite has shipped over before (the whole viewpoint
    -- file drew nothing for months because DrawPoly was unstubbed).
    --
    -- SO THIS IS A BREADTH SWEEP AND NOT A GEOMETRY ONE. Every shipping phase, four
    -- seeds each, and four geometries per phase -- nested, barely overlapping,
    -- disjoint, and collapsed onto the target -- through the real frame callback.
    -- What it asserts is only what breadth can assert: it ran clean, it drew
    -- something, everything it drew is on the shape, and it stayed inside the poly
    -- budget. The exact geometry is `wall.strip`'s and `blob.distance`'s business.
    --
    -- ONE CLIENT, RE-RECORDED, because standing up a sandbox loads the real files
    -- and this sweep is 128 frames. The record is what varies, which is what varies
    -- in a match.
    local C = newStormClient()
    local env = C.env
    local SS = env.BR.StormShape
    local rr = env.BR.Config.Storm.render
    local phases = env.BR.Config.Storm.phases

    local frames, drew, worstOff, worstAt = 0, 0, 0.0, nil
    local worstPolys, budget = 0, rr.strip.maxPolys or 1024
    for i = 1, #phases do
        local r0 = phases[i].radius
        if r0 > 0.0 then
            local r1 = (phases[i + 1] and phases[i + 1].radius) or 0.0
            for s = 1, 4 do
                local seed = s * 60013 + i
                -- Nested, barely overlapping, fully separated, and collapsed onto
                -- the target -- the four shapes the solver can hand the renderer.
                for _, sep in ipairs({ (r0 - r1) * 0.4, r0 * 0.95,
                                       r0 + r1 + r0 * 0.5, 0.0 }) do
                    -- PHASE INDEX 2 OR LATER ON THE WIRE, whatever the radius pair:
                    -- phase 1's hold suppresses the wall by design, so a phase-1
                    -- record would let this sweep pass by drawing nothing at all.
                    local rec = C.record(math.max(2, i), 0.0, 0.0, r0,
                        sep, 0.0, r1, 600000, 60000, 2.0)
                    rec.seed = seed
                    C.pedAt = pt(r0 * 0.3, 0.0, 30.0)
                    -- TWICE: in the hold, and a little over a third of the way
                    -- through the sweep, where the wall is a MORPH of the two zones
                    -- rather than either of them -- which is a shape nothing drew
                    -- before, and has to stand on the zone at the solver's own `t`.
                    for _, into in ipairs({ -1.0, 0.37 }) do
                        if into >= 0.0 then
                            rec.tStart = C.now + 16 - (rec.tWait + into * rec.tShrink)
                        end
                        C.frame()
                        frames = frames + 1
                        if #C.polys > 0 then drew = drew + 1 end
                        if #C.polys > worstPolys then worstPolys = #C.polys end
                        local cx, cy, r, _, _, _, t = env.BR.StormAt(rec, C.now)
                        local drawn = SS.inset(env.BR.StormZone(rec, cx, cy, r, t),
                            rr.edgeInset or 0.0)
                        for _, qd in ipairs(quadsOf(C)) do
                            for _, v in ipairs({ qd.a, qd.b }) do
                                local own = partAt(env, drawn, v.x, v.y)
                                local d = math.abs(SS.distance(own, v.x, v.y))
                                if d > worstOff then
                                    worstOff = d
                                    worstAt = ('phase %d seed %d sep %.0f t %.2f')
                                        :format(i, seed, sep, t)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    ok(C.errored() == nil,
        ('%d frames across every phase, four seeds and four geometries each, held and '
            .. 'mid-sweep, and not one of them threw'):format(frames), C.errored())
    ok(frames == 224 and drew == frames,
        'every single frame drew a wall -- none of them silently drew nothing',
        ('%d of %d frames drew'):format(drew, frames))
    ok(worstOff < 1e-6,
        'and every corner of every one of them stands on the shape the record '
            .. 'describes',
        ('worst %.3e m off, at %s'):format(worstOff, tostring(worstAt)))
    ok(worstPolys <= budget,
        'inside the poly budget throughout, so nothing is rationed and nothing runs '
            .. 'away',
        ('worst %d polys of %d'):format(worstPolys, budget))

    -- ═══ AND EVERY CORNER COUNT, PINNED, BECAUSE THE SEEDS ABOVE ONLY SAMPLE THEM ═══
    --
    -- Twenty-eight seeded phases draw most counts and promise none. A triangle is
    -- the fewest runs and the biggest corner arcs; a dodecagon is the most runs and
    -- the tightest arcs, and so the most quads -- the one that could run the budget
    -- out. So each count is drawn on a big phase and a small one, through the same
    -- four geometries, by pinning the count in the config the frame reads.
    -- CIRCLES ARE PINNED OFF WITH IT, because a circle zone has no count to check and
    -- one in ten of these would otherwise be one.
    local shapeCfg = env.BR.Config.Storm.shape
    local shippedCorners, shippedCircle = shapeCfg.corners, shapeCfg.circle
    shapeCfg.circle = 0.0
    local cFrames, cDrew, cOff, cOffAt, cPolys, cPolysAt = 0, 0, 0.0, nil, 0, nil
    for n = 3, 12 do
        shapeCfg.corners = n
        for _, i in ipairs({ 2, 6 }) do
            local r0, r1 = phases[i].radius, phases[i + 1].radius
            for _, sep in ipairs({ (r0 - r1) * 0.4, r0 * 0.95,
                                   r0 + r1 + r0 * 0.5, 0.0 }) do
                local rec = C.record(i, 0.0, 0.0, r0, sep, 0.0, r1, 600000, 60000, 2.0)
                rec.seed = 7001 * n + i
                C.pedAt = pt(r0 * 0.3, 0.0, 30.0)
                C.frame()
                cFrames = cFrames + 1
                if #C.polys > 0 then cDrew = cDrew + 1 end
                if #C.polys > cPolys then
                    cPolys, cPolysAt = #C.polys, ('%d corners, phase %d'):format(n, i)
                end
                local drawn = SS.inset(zoneOf(env, rec), rr.edgeInset or 0.0)
                for _, qd in ipairs(quadsOf(C)) do
                    for _, v in ipairs({ qd.a, qd.b }) do
                        local d = math.abs(SS.distance(partAt(env, drawn, v.x, v.y),
                            v.x, v.y))
                        if d > cOff then
                            cOff, cOffAt = d, ('%d corners, phase %d, sep %.0f')
                                :format(n, i, sep)
                        end
                    end
                end
                if env.BR.StormUnit(rec.seed, rec.phase).n ~= n then
                    cOffAt, cOff = ('%d corners asked, %d drawn'):format(n,
                        env.BR.StormUnit(rec.seed, rec.phase).n), math.huge
                end
            end
        end
    end
    shapeCfg.corners, shapeCfg.circle = shippedCorners, shippedCircle
    ok(C.errored() == nil and cFrames == 80 and cDrew == cFrames,
        'every corner count from three to twelve draws a wall on a big phase and a '
            .. 'small one, in all four geometries, and none of the 80 frames threw',
        C.errored() or ('%d of %d drew'):format(cDrew, cFrames))
    ok(cOff < 1e-6,
        'and every quad corner of every count stands on the shape the record describes',
        ('worst %.3e m off, at %s'):format(cOff, tostring(cOffAt)))
    ok(cPolys <= budget,
        'inside the poly budget at every count, the dodecagon\'s extra runs included',
        ('worst %d polys of %d, at %s'):format(cPolys, budget, tostring(cPolysAt)))

    -- AND THE COLLAPSED END OF THE LAST PHASE, walked in metres rather than sampled:
    -- the radius runs 40 to 0 and passes through the sizes where the corner arcs no
    -- longer survive the inset and then the shape itself does not. Every one of those
    -- frames still has to draw, because the wall is on top of the last fight in the
    -- match when it does.
    local endFrames, endDrew = 0, 0
    local last = phases[#phases - 1] and phases[#phases - 1].radius or 40.0
    local function endFrame(rr0)
        local rec = C.record(8, 0.0, 0.0, rr0, 12.0, 0.0, 0.0, 600000, 60000, 6.7)
        rec.seed = 4242
        C.pedAt = pt(0.0, 0.0, 30.0)
        C.frame()
        return #C.polys
    end
    for k = 0, 39 do
        endFrames = endFrames + 1
        if endFrame(last * (1.0 - k / 40.0)) > 0 then endDrew = endDrew + 1 end
    end
    ok(C.errored() == nil and endDrew == endFrames,
        'and the final sweep draws a wall at every radius from 40 metres down to a '
            .. 'metre, through both circle fallbacks',
        ('%d of %d frames, %s'):format(endDrew, endFrames, tostring(C.errored())))

    -- AND AT RADIUS NOTHING IT DRAWS NOTHING, which is the storm.wall callback's own
    -- `r <= 1 and rec.r1 <= 1` gate and not a shape decision. Pinned beside the sweep
    -- above so the two cannot be confused: the wall is absent because the zone has
    -- collapsed, not because the shape ran out of boundary to walk.
    ok(endFrame(0.0) == 0 and C.errored() == nil,
        'and a zone collapsed onto its own target draws no wall at all, cleanly',
        tostring(C.errored()))
end

-- ---------------------------------------------------------------------------
describe('blob.agree')
do
    -- ═══ THE CLIENT DRAWS THE WALL AND THE SERVER DOES THE DAMAGE, SO THEY HAVE TO
    ---     DERIVE THE SAME SHAPE (#344) ═══
    --
    -- Nothing about the shape is on the wire. The record carries one integer -- the
    -- match's storm seed -- and both halves build the shape from it plus the phase
    -- index. If they disagree by a metre the wall is a lie by a metre, and the
    -- symptom is damage taken at a place the curtain says is safe: the exact live
    -- report edgeInset exists for, with no bound on how far.
    --
    -- SO THIS IS THE SHAPE'S `first.stream`: two separate Lua states, the real
    -- production call in each, compared point for point rather than reasoned about.
    -- The server state has no client file in it and the client state has no server
    -- file, so nothing is shared between them but br_lib.
    local W = walkMatch({ x = 1000.0, y = -1500.0, name = 'Agree' }, true)
    local senv = W.S.env
    local rec = W.S.match.storm
    ok(rec ~= nil and rec.seed ~= nil and rec.seed == W.S.match.stormSeed
        and rec.seed ~= 0,
        "the published record carries the match's own storm seed",
        ('%s against %s'):format(tostring(rec and rec.seed),
            tostring(W.S.match.stormSeed)))

    local prev = W.S.lastSent(senv.BR.Net.STORM_PREVIEW)
    ok(prev ~= nil and prev.seed == W.S.match.stormSeed,
        'and so does the warmup preview, so the bus is shown the shape phase 1 '
            .. 'will actually wear',
        ('%s against %s'):format(tostring(prev and prev.seed),
            tostring(W.S.match.stormSeed)))

    -- ═══ THE SAME BOUNDARY IN BOTH STATES, TO THE BIT ═══
    local C = newStormClient()
    local cenv = C.env
    local CX, CY, R = 700.0, -200.0, 1300.0
    -- A record the two states share: the SAME seed and phase the server published,
    -- against a breakout pair, which is the case with two components in it.
    local shared = {
        phase = rec.phase, seed = rec.seed,
        cx0 = CX, cy0 = CY, r0 = R,
        cx1 = CX + 2400.0, cy1 = CY, r1 = 800.0,
        tStart = 0, tWait = 600000, tShrink = 60000, dps = 2.0,
    }
    local sz = senv.BR.StormZone(shared, CX, CY, R)
    local cz = cenv.BR.StormZone(shared, CX, CY, R)
    ok(sz.kind == cz.kind and #sz.pieces == #cz.pieces
        and near(sz.P, cz.P, 0.0),
        'the two states build the same kind of shape, the same pieces and the same '
            .. 'perimeter, exactly',
        ('%s/%d/%.9f against %s/%d/%.9f'):format(sz.kind, #sz.pieces, sz.P,
            cz.kind, #cz.pieces, cz.P))

    local worstPt, worstD, probes = 0.0, 0.0, 0
    for k = 0, 719 do
        local s = sz.P * k / 720
        local ax, ay = senv.BR.StormShape.pointAtArc(sz, s)
        local bx, by = cenv.BR.StormShape.pointAtArc(cz, s)
        worstPt = math.max(worstPt, math.abs(ax - bx), math.abs(ay - by))
    end
    for gx = -10, 10 do
        for gy = -10, 10 do
            local px, py = CX + gx * 260.0, CY + gy * 260.0
            probes = probes + 1
            worstD = math.max(worstD, math.abs(
                senv.BR.StormShape.distance(sz, px, py)
                - cenv.BR.StormShape.distance(cz, px, py)))
        end
    end
    ok(worstPt == 0.0,
        'and every one of 720 points of the boundary is the identical coordinate',
        ('worst %.3e m'):format(worstPt))
    ok(worstD == 0.0,
        ('and the signed distance agrees at all %d probes, to the bit -- the wall '
            .. 'and the ledger cannot be measuring different shapes'):format(probes),
        ('worst %.3e m'):format(worstD))

    -- AND MID-SWEEP, WHERE THE CURRENT SHAPE IS A MORPH OF TWO ZONES. The two states
    -- merge the same two corner lists and interpolate them the same way, so the shape
    -- a morph makes is as much a derivation of the seed as a zone's own is.
    local sm = senv.BR.StormZone(shared, CX, CY, R, 0.4)
    local cm = cenv.BR.StormZone(shared, CX, CY, R, 0.4)
    local worstM = 0.0
    for gx = -10, 10 do
        for gy = -10, 10 do
            local px, py = CX + gx * 260.0, CY + gy * 260.0
            worstM = math.max(worstM, math.abs(senv.BR.StormShape.distance(sm, px, py)
                - cenv.BR.StormShape.distance(cm, px, py)))
        end
    end
    ok(sm.kind == cm.kind and #sm.pieces == #cm.pieces and sm.P == cm.P and worstM == 0.0,
        'and so do the two states\' MORPHS, part way through a sweep, to the bit',
        ('%d/%d pieces, worst %.3e m'):format(#sm.pieces, #cm.pieces, worstM))

    -- ═══ AND THE SAME SHAPE, ON EVERY ZONE OF SIXTY MATCHES ═══
    --
    -- The count, the circle and every vertex's finish are drawn now, and any of them
    -- drawn off anything but the record -- the process's own random stream, the clock
    -- -- is a pentagon on one side of the wire and a circle on the other. One record
    -- proves one draw; this is sixty matches of every zone, compared corner for
    -- corner. The seeds are distinct integers and asserted so: #346's fractional seed
    -- would make this sixty copies of one match.
    local sweep, seenSeed, badSeed = {}, {}, nil
    for i = 1, 60 do
        local s = i * 104723 + 5
        if math.tointeger(s) == nil or seenSeed[s] then badSeed = badSeed or s end
        seenSeed[s] = true
        sweep[i] = s
    end
    ok(badSeed == nil, 'the sixty seeds are distinct integers', tostring(badSeed))
    local drawnCounts, nCounts, apart, compared, circles = {}, 0, nil, 0, 0
    for _, s in ipairs(sweep) do
        for z = 0, 8 do
            local su = senv.BR.StormUnit(s, z)
            local cu = cenv.BR.StormUnit(s, z)
            compared = compared + 1
            local same = su.kind == cu.kind and su.n == cu.n and #su.ks == #cu.ks
            for i = 1, math.min(#su.ks, #cu.ks) do
                local a, b = su.ks[i], cu.ks[i]
                if a.x ~= b.x or a.y ~= b.y or a.rho ~= b.rho
                    or a.a0 ~= b.a0 or a.a1 ~= b.a1 then
                    same = false
                end
            end
            for i = 1, math.max(#su.finish, #cu.finish) do
                if su.finish[i] ~= cu.finish[i] then same = false end
            end
            if not same then
                apart = apart or ('seed %d zone %d: server %s of %d, client %s of %d')
                    :format(s, z, su.kind, su.n, cu.kind, cu.n)
            end
            if su.kind == 'circle' then
                circles = circles + 1
            elseif not drawnCounts[su.n] then
                drawnCounts[su.n], nCounts = true, nCounts + 1
            end
        end
    end
    ok(apart == nil,
        ('the server and the client draw the same shape -- circle or count, every '
            .. 'corner, every finish -- to the bit, on all %d zones'):format(compared),
        apart)
    ok(nCounts == 8 and circles > 0,
        'and those zones really do vary: every count from five to twelve is among them, '
            .. 'and circles too',
        ('%d distinct counts, %d circles'):format(nCounts, circles))

    -- ═══ AND THE SHAPE REALLY DEPENDS ON THE SEED ═══
    --
    -- Both sides agreeing is worth nothing if both sides ignore the seed. A
    -- different seed has to be a different shape, or a derivation that dropped it
    -- would pass every assertion above.
    local other = { }
    for k, v in pairs(shared) do other[k] = v end
    other.seed = rec.seed + 1
    local oz = cenv.BR.StormZone(other, CX, CY, R)
    local moved = 0.0
    for k = 0, 359 do
        local s = cz.P * k / 360
        local ax, ay = cenv.BR.StormShape.pointAtArc(cz, s)
        local bx, by = cenv.BR.StormShape.pointAtArc(oz, s)
        moved = math.max(moved, math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2))
    end
    ok(moved > 10.0,
        'the next seed along is a visibly different shape, so the seed is really '
            .. 'being read rather than defaulted on both sides',
        ('worst point moves %.1f m'):format(moved))

    -- AND THE PHASE INDEX IS THE OTHER HALF OF IT, which is what "a random shape
    -- for EACH PHASE" means -- one shape per match would pass everything above.
    local nextPhase = {}
    for k, v in pairs(shared) do nextPhase[k] = v end
    nextPhase.phase = shared.phase + 1
    local pz = cenv.BR.StormZone(nextPhase, CX, CY, R)
    local pmoved = 0.0
    for k = 0, 359 do
        local s = cz.P * k / 360
        local ax, ay = cenv.BR.StormShape.pointAtArc(cz, s)
        local bx, by = cenv.BR.StormShape.pointAtArc(pz, s)
        pmoved = math.max(pmoved, math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2))
    end
    ok(pmoved > 10.0,
        'and the next PHASE of the same match is a different shape again',
        ('worst point moves %.1f m'):format(pmoved))

    -- ═══ END TO END: WHAT THE HUD SAYS AND WHAT THE LEDGER BILLS ═══
    --
    -- The assertions above compare the shape. This compares the two PRODUCTION
    -- READOUTS through their own call sites -- the client's storm.state tick and the
    -- server's damage pass -- on one record, at points chosen off the boundary
    -- itself. A side that spelled the derivation differently would show up here even
    -- if it happened to agree about the kind and the perimeter.
    local S2 = newStormServer()
    local r2 = S2.record(3, CX, CY, R, CX + 2400.0, CY, 800.0, 600000, 60000, 2.0)
    r2.seed = rec.seed
    local zone2 = S2.env.BR.StormZone(r2, CX, CY, R)
    local C2 = newStormClient()
    local cr2 = C2.record(3, CX, CY, R, CX + 2400.0, CY, 800.0, 600000, 60000, 2.0)
    cr2.seed = rec.seed

    local disagree = 0
    for _, off in ipairs({ -60.0, -5.0, 5.0, 40.0 }) do
        for k = 0, 11 do
            local px, py = offBoundary(S2.env, zone2, zone2.P * k / 12, off)
            local billed = S2.hurts(px, py)
            C2.pedAt = pt(px, py)
            C2.tick(2)
            local e = C2.last() and C2.last().edgeDistance
            -- The client's metres and the server's cushion are different questions,
            -- so the comparison is the one thing they must agree on: a player the
            -- server bills is one the client is telling to run.
            if billed ~= (e ~= nil and e > 10.0) then disagree = disagree + 1 end
        end
    end
    ok(disagree == 0,
        'and at 48 points taken off the boundary itself, every player the server '
            .. 'bills is one the client is showing as outside the cushion',
        ('%d disagreements'):format(disagree))
    ok(S2.errored() == nil and C2.errored() == nil,
        'with both passes clean',
        tostring(S2.errored()) .. ' / ' .. tostring(C2.errored()))

    -- ═══ AND HALF WAY THROUGH A SWEEP, WHERE THE ZONE IS A MORPH ═══
    --
    -- Both production readouts, each solving its own clock to the same instant half
    -- way through the sweep -- so each passes the `t` its own BR.StormAt reports, and
    -- a side that forgot to would be measuring the zone the sweep set out from. The
    -- sweep is slow on purpose, so the server's travel cushion is a few centimetres
    -- over its base ten metres and the one threshold below reads both.
    local WAIT, SHRINK = 60000.0, 6000000.0
    local MID = WAIT + 0.5 * SHRINK
    local S3 = newStormServer()
    local r3 = S3.record(3, CX, CY, R, CX + 300.0, CY, 800.0, WAIT, SHRINK, 2.0)
    r3.seed = rec.seed
    local mx, my, mr, _, _, _, mt = S3.env.BR.StormAt(r3, r3.tStart + MID)
    local zone3 = S3.env.BR.StormZone(r3, mx, my, mr, mt)
    local cushion = 10.0 + ((R - 800.0) / (SHRINK / 1000.0)) * 0.7
    local C3 = newStormClient()
    local cr3 = C3.record(3, CX, CY, R, CX + 300.0, CY, 800.0, WAIT, SHRINK, 2.0)
    cr3.seed = rec.seed

    local midDisagree, midChecked = 0, 0
    for _, off in ipairs({ -60.0, -5.0, 5.0, 40.0 }) do
        for k = 0, 11 do
            local px, py = offBoundary(S3.env, zone3, zone3.P * k / 12, off)
            S3.at(MID)
            local billed = S3.hurts(px, py)
            C3.pedAt = pt(px, py)
            cr3.tStart = C3.now + 3000 - MID
            C3.tick(2)
            local e = C3.last() and C3.last().edgeDistance
            midChecked = midChecked + 1
            if billed ~= (e ~= nil and e > cushion) then midDisagree = midDisagree + 1 end
        end
    end
    ok(mt > 0.49 and mt < 0.51 and midDisagree == 0,
        ('and at %d points off the MORPHING boundary half way through a sweep, the '
            .. 'server and the client agree who is outside'):format(midChecked),
        ('t %.3f, %d disagreements'):format(mt, midDisagree))
    ok(S3.errored() == nil and C3.errored() == nil,
        'with both passes clean mid-sweep too',
        tostring(S3.errored()) .. ' / ' .. tostring(C3.errored()))
end

-- ---------------------------------------------------------------------------
-- A WHOLE MATCH'S RECORDS, kept, off the real server -- the phase job re-enabled as
-- walkMatch does, and `seq` set so each call is a different match with its own seed.
-- ---------------------------------------------------------------------------

--- @param seq integer   the match's sequence number, which its storm seed is built from
--- @return table  { [phase] = a copy of that phase's published record }
local function walkRecords(seq)
    local S = newStormServer()
    local env = S.env
    S.roster[1] = nil
    S.match.storm = nil
    S.match.seq = seq
    S.match.anchor = { x = 1000.0, y = -1500.0, name = 'Walk' }
    env.BR.Sched.setEnabled('storm.phase', true)
    S.match.state = env.BR.MatchState.WARMUP
    env.BR.Storm.drawFirstCircle(S.match)
    S.match.state = env.BR.MatchState.PLAYING
    env.BR.Storm.begin(S.match)
    local recs = {}
    local function note()
        local rec = S.match.storm
        if rec and not recs[rec.phase] then
            local c = {}
            for k, v in pairs(rec) do c[k] = v end
            recs[rec.phase] = c
        end
    end
    note()
    local last = #env.BR.Config.Storm.phases
    local guard = 0
    while not recs[last] and guard < 4000 do
        guard = guard + 1
        S.now = S.now + 30000
        env.BR.Sched.step(S.now)
        note()
    end
    return recs
end

-- ---------------------------------------------------------------------------
describe('zone.identity')
do
    -- ═══ THE SNAP AT THE END OF EVERY SWEEP, AND WHY IT CANNOT COME BACK ═══
    --
    --   "after the storm is finished moving for that phase, the border snaps to a
    --    different location."                          -- the owner, 2026-09-23
    --
    -- A record's current circle and its target wore ONE unit, keyed on the phase, so
    -- when the phase advanced the circle the wall had just closed onto re-rolled where
    -- it stood: 34 to 514 m of jump, measured at f5000cf, on the wall and on the map.
    -- Each zone keeps one shape now -- zone k is phase k's target, and phase k+1's
    -- current circle -- and the wall morphs from one zone's shape into the next across
    -- the sweep.
    --
    -- SO THE CLAIM IS AN EQUALITY, AND IT IS ASKED THREE WAYS AT EVERY PHASE CHANGE of
    -- six real matches walked through the real server: the zone the server bills and
    -- the client measures, the wall the frame callback draws, and the fill the map
    -- tick pushes -- each at the end of phase p against the start of phase p+1. And a
    -- fourth, because keeping shapes per zone without a morph would only move the snap
    -- from the end of the sweep to the start of it: across every sweep, the zone never
    -- moves further between two instants than its own support function allows.
    local matches, seen, badSeed = {}, {}, nil
    for k = 1, 6 do
        local recs = walkRecords(k)
        local s = recs[1] and recs[1].seed
        if s == nil or math.tointeger(s) == nil or seen[s] then
            badSeed = badSeed or tostring(s)
        end
        if s then seen[s] = true end
        matches[k] = recs
    end
    ok(badSeed == nil, 'six walked matches carry six distinct integer seeds', badSeed)

    local C = newStormClient()
    C.recordWallOnly()
    local env = C.env
    local SS = env.BR.StormShape

    --- Worst signed-distance disagreement between two zones over a grid about a circle.
    local function zoneDiff(za, zb, cx, cy, r)
        local worst = 0.0
        for gx = -10, 10 do
            for gy = -10, 10 do
                local px, py = cx + gx * r * 0.13, cy + gy * r * 0.13
                worst = math.max(worst,
                    math.abs(SS.distance(za, px, py) - SS.distance(zb, px, py)))
            end
        end
        return worst
    end

    --- How far apart two drawn point sets are, both ways.
    local function apart(A, B)
        local worst = (#A == 0) ~= (#B == 0) and math.huge or 0.0
        for _, pair in ipairs({ { A, B }, { B, A } }) do
            for _, p in ipairs(pair[1]) do
                local best = math.huge
                for _, q in ipairs(pair[2]) do
                    best = math.min(best, (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2)
                end
                worst = math.max(worst, math.sqrt(best))
            end
        end
        return worst
    end

    local function wallPts()
        local pts = {}
        for _, q in ipairs(quadsOf(C)) do pts[#pts + 1] = { x = q.a.x, y = q.a.y } end
        return pts
    end

    local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

    --- Does a record's target nest inside its current circle -- the solver's own
    --- rule, and the one BR.StormShape.zone collapses a pair on? On a phase that
    --- breaks out, the safe zone gains the new target at the phase change by design
    --- (#328), so only a nesting phase's WHOLE zone can be held to equality there.
    local function nests(rec)
        return math.sqrt((rec.cx1 - rec.cx0) ^ 2 + (rec.cy1 - rec.cy0) ^ 2) + rec.r1
            <= rec.r0 + 1e-9
    end

    local changes, sameUnit, shapeJump, shapeAt, targetOff = 0, 0, 0.0, nil, 0.0
    local nested, zoneJump, zoneAt, wallJump, wallAt, drewBoth = 0, 0.0, nil, 0.0, nil, 0
    for k, recs in ipairs(matches) do
        for p = 1, #recs - 1 do
            local a, b = recs[p], recs[p + 1]
            if a and b then
                changes = changes + 1
                -- THE CURRENT CIRCLE'S SHAPE, at the end of p's sweep and at the start
                -- of p+1's hold: one zone, so ONE UNIT -- the same table -- and the
                -- same shape placed on the same circle.
                local ua = env.BR.StormCurrentUnit(a, 1.0)
                local ub = env.BR.StormCurrentUnit(b, 0.0)
                if ua == ub then sameUnit = sameUnit + 1 end
                local ca = SS.blob(a.cx1, a.cy1, a.r1, ua)
                local cb = SS.blob(b.cx0, b.cy0, b.r0, ub)
                local R = math.max(a.r1, 40.0)
                local d = zoneDiff(ca, cb, a.cx1, a.cy1, R)
                if d > shapeJump then
                    shapeJump, shapeAt = d, ('match %d, phase %d to %d'):format(k, p, p + 1)
                end
                -- AND IT IS THE VERY TARGET p SHOWED ALL PHASE.
                local tgt = SS.blob(a.cx1, a.cy1, a.r1, env.BR.StormUnit(a.seed, a.phase))
                targetOff = math.max(targetOff, zoneDiff(tgt, cb, a.cx1, a.cy1, R))

                if nests(b) then
                    nested = nested + 1
                    -- THE WHOLE ZONE, where the next phase adds nothing to it.
                    local za = env.BR.StormZone(a, a.cx1, a.cy1, a.r1, 1.0)
                    local zb = env.BR.StormZone(b, b.cx0, b.cy0, b.r0, 0.0)
                    local zd = zoneDiff(za, zb, a.cx1, a.cy1, R)
                    if zd > zoneJump then
                        zoneJump, zoneAt = zd, ('match %d, phase %d to %d'):format(k, p, p + 1)
                    end

                    -- THE WALL, through the real frame callback, standing still across
                    -- the change: p FINISHED, then p+1 a moment into its hold.
                    local fa = copy(a)
                    fa.tStart = C.now + 16 - fa.tWait - fa.tShrink - 5000
                    env.BR.State.storm = fa
                    C.pedAt = pt(a.cx1, a.cy1)
                    C.frame()
                    local A = wallPts()
                    local fb = copy(b)
                    fb.tStart = C.now + 16 - 5000
                    env.BR.State.storm = fb
                    C.frame()
                    local B = wallPts()
                    if #A > 0 and #B > 0 then drewBoth = drewBoth + 1 end
                    local w = apart(A, B)
                    if w > wallJump then
                        wallJump, wallAt = w, ('match %d, phase %d to %d'):format(k, p, p + 1)
                    end
                end
            end
        end
    end
    ok(changes >= 36,
        'every phase change of six matches is asked', ('%d changes'):format(changes))
    ok(sameUnit == changes,
        'the current circle\'s shape at the end of every sweep IS the next phase\'s -- '
            .. 'the same unit, not an equal one -- however the phase number moves',
        ('%d of %d'):format(sameUnit, changes))
    ok(shapeJump == 0.0 and targetOff == 0.0,
        'placed on the same circle to the bit, and it is the very target the map and '
            .. 'the wall showed all through the phase before',
        ('worst %.3e m at %s, target %.3e m'):format(shapeJump, tostring(shapeAt),
            targetOff))
    ok(nested >= 12 and zoneJump == 0.0,
        'and where the next phase nests, the WHOLE zone the server bills and the client '
            .. 'measures is unchanged by the change, to the bit',
        ('%d nesting changes, worst %.3e m at %s'):format(nested, zoneJump,
            tostring(zoneAt)))
    ok(drewBoth == nested and wallJump < 1e-6,
        'and so is the WALL the frame callback draws -- not a quad of it moves at a phase '
            .. 'change, where it jumped 34 to 514 m before',
        ('%d of %d drew both, worst %.3e m at %s'):format(drewBoth, nested, wallJump,
            tostring(wallAt)))

    -- ═══ THE MAP, ON THE SAME CHANGES ═══
    --
    -- The map changes shape once, as the sweep finishes -- so where the next phase
    -- nests, the fill the phase ended on and the fill the next phase starts with have
    -- to be the same polygon.
    local M = newStormClient()
    M.mm.handle = 7
    M.pedAt = pt(0.0, 0.0)
    local first = copy(matches[1][2])
    first.tStart = M.now
    M.env.BR.State.storm = first
    ok(M.overlayReady(), 'the map client reaches the gate')
    local mapJump, mapAt, mapPairs = 0.0, nil, 0
    for k = 1, 6 do
        local recs = matches[k]
        for p = 2, #recs - 1 do
          if nests(recs[p + 1]) then
            local a, b = copy(recs[p]), copy(recs[p + 1])
            a.tStart = M.now - a.tWait - a.tShrink - 5000
            M.env.BR.State.storm = a
            M.tick(2)
            local A = M.areas()[1] and M.shown(M.areas()[1]) or {}
            b.tStart = M.now + 20000
            M.env.BR.State.storm = b
            M.fire(M.env.BR.Net.STORM_SYNC)
            M.tick(2)
            local B = M.areas()[1] and M.shown(M.areas()[1]) or {}
            mapPairs = mapPairs + 1
            local w = apart(A, B)
            if w > mapJump then
                mapJump, mapAt = w, ('match %d, phase %d to %d'):format(k, p, p + 1)
            end
          end
        end
    end
    ok(mapPairs >= 10 and mapJump < 1e-6 and M.errored() == nil,
        'and the MAP\'s fill is the same polygon on both sides of every change',
        M.errored() or ('%d changes, worst %.3e m at %s'):format(mapPairs, mapJump,
            tostring(mapAt)))

    -- ═══ AND NO JUMP MID-SWEEP, WHICH IS WHAT THE MORPH IS FOR ═══
    --
    -- The zone the wall draws is the Minkowski interpolation of the zone it leaves and
    -- the zone it reaches, so its support function moves linearly: between two
    -- instants dt of the sweep apart, no point of it can move further than dt times
    -- the widest gap between the two zones' support functions -- at most the centres'
    -- distance plus the larger of the two reaches. A shape that snapped anywhere in the
    -- sweep, at its start included, would clear that by metres.
    local stepJump, stepAt, stepped = 0.0, nil, 0
    for k = 1, 3 do
        for p, rec in ipairs(matches[k]) do
            if rec.r1 > 0.0 then
                local from = env.BR.StormCurrentUnit(rec, 0.0)
                local to = env.BR.StormUnit(rec.seed, rec.phase)
                local gap = math.sqrt((rec.cx1 - rec.cx0) ^ 2 + (rec.cy1 - rec.cy0) ^ 2)
                    + math.max(rec.r0 * from.extent, rec.r1 * to.extent)
                local N = 120
                local prev = env.BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0, 0.0)
                for i = 1, N do
                    local cx, cy, r, _, _, _, t = env.BR.StormAt(rec,
                        rec.tStart + rec.tWait + rec.tShrink * i / N)
                    local cur = env.BR.StormZone(rec, cx, cy, r, t)
                    local worst = 0.0
                    for _, c in ipairs(SS.components(cur)) do
                        for j = 0, 59 do
                            local x, y = SS.pointAtComponent(cur, c, c.len * j / 60)
                            worst = math.max(worst, math.abs(SS.distance(prev, x, y)))
                        end
                    end
                    stepped = stepped + 1
                    local ratio = worst / (gap / N)
                    if ratio > stepJump then
                        stepJump, stepAt = ratio, ('match %d phase %d step %d: %.2f m')
                            :format(k, p, i, worst)
                    end
                    prev = cur
                end
            end
        end
    end
    ok(stepped > 2000 and stepJump <= 1.0 + 1e-9,
        'and across every sweep of three matches, no step of the zone moves further '
            .. 'than its support function allows -- the wall has nowhere to snap',
        ('%d steps, worst %.3f of the bound at %s'):format(stepped, stepJump,
            tostring(stepAt)))
end

-- ---------------------------------------------------------------------------
describe('zone.cache')
do
    -- ═══ A ZONE'S SHAPE IS BUILT ONCE, AND NEVER PER FRAME OR PER TICK ═══
    --
    -- The wall asks for the zone every frame, the HUD and the map every tick, the
    -- server's damage pass every second -- and every one of those asks for the two
    -- units of a record and, mid-sweep, their morph. Each unit is a generator, a
    -- convexity test and up to six retries; each merge is a sort of two corner lists.
    -- Built per call they would be the same answer rebuilt forever, which nothing a
    -- shape can be asked would show -- so this counts the builds themselves.
    local C = newStormClient()
    local env = C.env
    local rec = C.record(3, 0.0, 0.0, 950.0, 200.0, 0.0, 520.0, 1000, 20000, 2.0)
    rec.seed = 98765
    rec.tStart = C.now - 500
    local b = env.BR.StormShape.builds
    local units0, merges0 = b.units, b.merges
    local frames, drew = 0, 0
    for i = 1, 1400 do
        C.frame()
        frames = frames + 1
        if #C.polys > 0 then drew = drew + 1 end
        if i % 6 == 0 then env.BR.Loop.step(env.BR.Loop.TICK) end
    end
    local _, _, _, st = env.BR.StormAt(rec, env.BR.Clock.now())
    ok(st == env.BR.StormPhase.FINISHED and drew == frames and C.errored() == nil,
        'a client draws the end of a hold, the whole sweep and its finish, frame by '
            .. 'frame, with the HUD and the map ticking beside it',
        C.errored() or ('%s, %d of %d frames drew'):format(tostring(st), drew, frames))
    ok(b.units - units0 <= 2 and b.merges - merges0 <= 1,
        ('and across %d frames and %d ticks it built at most the TWO zones and ONE '
            .. 'merge of them'):format(frames, math.floor(frames / 6)),
        ('%d units, %d merges'):format(b.units - units0, b.merges - merges0))

    local S = newStormServer()
    local srec = S.record(3, 0.0, 0.0, 950.0, 200.0, 0.0, 520.0, 1000, 20000, 2.0)
    srec.seed = 98765
    local sb = S.env.BR.StormShape.builds
    local su0, sm0 = sb.units, sb.merges
    for _ = 1, 25 do S.tick() end
    ok(S.errored() == nil and sb.units - su0 <= 2 and sb.merges - sm0 <= 1,
        'and so did the server, ticking the damage pass through the same sweep',
        S.errored() or ('%d units, %d merges'):format(sb.units - su0, sb.merges - sm0))
end

-- ---------------------------------------------------------------------------
describe('zone.freeze')
do
    -- ═══ A FREEZE, ITS THAW, AND A SAME-PHASE `brphase` KEEP THE WALL'S SHAPE ═══
    --
    -- Mid-sweep the wall is part way between two zones' shapes. `brstormfreeze`
    -- replaces the record with one that holds the wall where it stands for a day, and
    -- its thaw re-enters the phase from there; `brphase` with the phase already running
    -- does the same. Each is a record whose current circle starts PART WAY through a
    -- morph, and each carries that fraction (`m0`) -- or the wall would snap back to
    -- the zone it set out from the moment the command landed. Driven through the real
    -- commands on the real server file, and measured as the signed distance on a grid.
    local S = newStormServer()
    local env = S.env
    local SS = env.BR.StormShape
    env.BR.Server.devMode = true
    -- THE THAW DRAWS A NEW TARGET off the match's own stream, as enterPhase always has,
    -- so the stream and the seed are the match's.
    S.match.stormRng = env.BR.Rng(4242)
    local rec = S.record(3, 0.0, 0.0, 950.0, 150.0, 0.0, 520.0, 1000.0, 60000.0, 2.0)
    -- TWO POLYGON ZONES, so the wall part way between them is a shape of its own.
    local seed = 24680
    while env.BR.StormUnit(seed, 2).kind ~= 'polygon'
        or env.BR.StormUnit(seed, 3).kind ~= 'polygon' do
        seed = seed + 1
    end
    rec.seed, S.match.stormSeed = seed, seed

    --- The current circle's shape a record describes at `now`, placed.
    local function current(r, now)
        local cx, cy, rr, _, _, _, t = env.BR.StormAt(r, now)
        return SS.blob(cx, cy, rr, env.BR.StormCurrentUnit(r, t)), cx, cy, rr
    end
    local function diff(a, b, cx, cy, r)
        local worst = 0.0
        for gx = -10, 10 do
            for gy = -10, 10 do
                local px, py = cx + gx * r * 0.13, cy + gy * r * 0.13
                worst = math.max(worst,
                    math.abs(SS.distance(a, px, py) - SS.distance(b, px, py)))
            end
        end
        return worst
    end

    -- FORTY PERCENT THROUGH THE SWEEP, where the wall is neither zone.
    S.now = rec.tStart + rec.tWait + 0.4 * rec.tShrink
    local before, bx, by, br = current(rec, S.now)
    local _, _, _, _, _, _, tAt = env.BR.StormAt(rec, S.now)
    local mid = env.BR.StormMorph(rec, tAt)
    ok(mid > 0.05 and mid < 0.95,
        'forty percent through the sweep the wall is part way between the two zones',
        ('%.3f of the way'):format(mid))

    S.cmds.brstormfreeze(0, {})
    local frz = S.match.storm
    local held = current(frz, S.now + 5000)
    ok(frz ~= rec and frz.m0 == mid and diff(before, held, bx, by, br) < 1e-9,
        'the freeze holds the wall in the shape it was standing in, not the zone it set '
            .. 'out from -- the frozen record carries the morph it froze at',
        ('m0 %s against %.6f, worst %.3e m'):format(tostring(frz.m0), mid,
            diff(before, held, bx, by, br)))

    S.now = S.now + 20000
    S.cmds.brstormfreeze(0, { 'off' })
    local th = S.match.storm
    local thawed = current(th, S.now + 1000)
    ok(th ~= frz and th.m0 == mid and diff(before, thawed, bx, by, br) < 1e-9,
        'and the thaw re-enters the phase in that same shape -- then sweeps it on into '
            .. 'the target\'s, which it reaches exactly',
        ('m0 %s, worst %.3e m'):format(tostring(th.m0), diff(before, thawed, bx, by, br)))
    local _, _, _, _, _, _, tEnd = env.BR.StormAt(th, th.tStart + th.tWait + th.tShrink)
    ok(env.BR.StormCurrentUnit(th, tEnd) == env.BR.StormUnit(seed, 3),
        'the thawed sweep ends ON zone 3\'s own shape, so the next phase starts from it')

    -- AND `brphase` WITH THE PHASE ALREADY RUNNING, mid-sweep of the thawed record.
    S.now = th.tStart + th.tWait + 0.5 * th.tShrink
    local pre, px, py, pr = current(th, S.now)
    S.cmds.brphase(0, { '3' })
    local re = S.match.storm
    ok(re ~= th and diff(pre, current(re, S.now + 1000), px, py, pr) < 1e-9,
        '`brphase` into the phase already running keeps the wall\'s shape too',
        ('worst %.3e m'):format(diff(pre, current(re, S.now + 1000), px, py, pr)))
    ok(S.errored() == nil, 'and all of it runs clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('first.stream')
do
    -- ═══ THE INVARIANT THE WHOLE OF #327 STANDS ON ═══
    --
    --   "We don't need to change where the circle goes - just determine circle 1's
    --    location upon the first player in the match completing matchmaking"
    --                                               -- owner, 2026-09-21
    --
    -- Circle 1 used to be drawn at PLAYING, inside enterPhase, off a stream seeded
    -- one line earlier. It is now drawn at WARMUP so the map can show it. The
    -- owner's instruction is that NOTHING ABOUT THE STORM MOVES for that: the same
    -- draw, off the same stream, with the same arguments, made earlier.
    --
    -- ═══ WHY THE COMPARISON IS TWO LIVE PATHS AND NOT A GOLDEN LIST ═══
    --
    -- BR.Storm.begin's seed-and-draw is still there as the fallback for the routes
    -- that never had a warmup -- the same draw with the same arguments, made at
    -- begin, which is the order that shipped before #327 -- and
    -- `walkMatch(anchor, false)` IS it. Both runs hold the
    -- clock and the sequence number still, so both seed identically; the only
    -- difference between them is WHEN the first value comes off the stream. Hard
    -- coding the eight centres instead would have pinned the config as much as the
    -- rule, and would go red the next time a phase radius is tuned.
    --
    -- ═══ WHAT GETTING IT WRONG LOOKS LIKE, WHICH IS WHY THIS IS THE FIRST BLOCK ═══
    --
    -- Every wrong answer here is a LEGAL storm. Reseed at begin and phase 2 is
    -- handed the value phase 1 already spent; draw again at phase entry and all
    -- eight shift by one. Every circle is still on the map, still correctly nested,
    -- still the right radius on the right schedule, and no playtest can tell -- the
    -- match is simply not the match, and circle 1 is not the circle the whole room
    -- spent warmup looking at.
    local ANCHOR = { x = 150.0, y = -900.0, name = 'Test' }
    local warm = walkMatch(ANCHOR, true)
    local cold = walkMatch(ANCHOR, false)
    local N = #warm.S.env.BR.Config.Storm.phases

    ok(warm.S.errored() == nil, 'the warmup-draw match runs clean',
        warm.S.errored())
    ok(cold.S.errored() == nil, 'and so does the one that draws at begin',
        cold.S.errored())

    local counted = 0
    for n = 1, N do if warm.phases[n] and cold.phases[n] then counted = counted + 1 end end
    ok(counted == N,
        ('both matches actually walked all %d phases'):format(N), counted)

    -- PHASE BY PHASE, AND PHASE 1 IS INCLUDED DELIBERATELY. The brief only asks
    -- that phases 2 and up be unchanged, because phase 1 is the one being moved --
    -- but moving it must not move it either: the same value off the same stream
    -- lands in the same place, so the honest assertion is that ALL of them match.
    local wrong, firstWrong = 0, nil
    for n = 1, N do
        local a, b = warm.phases[n], cold.phases[n]
        if not (a and b and a.cx == b.cx and a.cy == b.cy and a.r == b.r) then
            wrong = wrong + 1
            firstWrong = firstWrong or n
        end
    end
    ok(wrong == 0,
        ('every one of the %d phase centres is bit for bit what it is with the '
            .. 'draw left at begin'):format(N),
        firstWrong and ('first disagreement at phase ' .. firstWrong
            .. (': warmup (%.4f, %.4f) vs begin (%.4f, %.4f)'):format(
                warm.phases[firstWrong] and warm.phases[firstWrong].cx or 0/0,
                warm.phases[firstWrong] and warm.phases[firstWrong].cy or 0/0,
                cold.phases[firstWrong] and cold.phases[firstWrong].cx or 0/0,
                cold.phases[firstWrong] and cold.phases[firstWrong].cy or 0/0)) or nil)

    -- AND PHASE 1 TAKES THE FIRST VALUE, which is the other half of the same
    -- sentence: the circle published at warmup must be the circle phase 1 actually
    -- closes on, or the preview is an illustration rather than the truth.
    ok(warm.first ~= nil, 'the warmup draw produced a circle')
    ok(warm.first and warm.phases[1]
        and warm.first.cx == warm.phases[1].cx
        and warm.first.cy == warm.phases[1].cy
        and warm.first.r  == warm.phases[1].r,
        'the circle shown during warmup IS phase 1 -- same centre, same radius',
        warm.first and warm.phases[1] and
            ('preview (%.4f, %.4f) r %.1f vs phase 1 (%.4f, %.4f) r %.1f'):format(
                warm.first.cx, warm.first.cy, warm.first.r,
                warm.phases[1].cx, warm.phases[1].cy, warm.phases[1].r) or nil)

    -- ═══ SEEDED EXACTLY ONCE, ASSERTED ON THE OBJECT AND NOT ON ITS OUTPUT ═══
    --
    -- The walk above catches a reseed by its consequences. This catches it by
    -- IDENTITY, which is worth having separately: a reseed that happened to be
    -- handed the same millisecond would produce a stream that agrees for a while,
    -- and rawequal cannot be fooled by that.
    local W = walkMatch(ANCHOR, true)
    ok(W.rngAfterDraw ~= nil, 'the warmup draw is what seeds the stream')
    ok(rawequal(W.rngAfterDraw, W.S.match.stormRng),
        'and BR.Storm.begin does not replace it -- one seed per match, not two')

    -- SPENT, AND SPENT ONCE. enterPhase nils the stored circle as it consumes it,
    -- so there is nothing left for a later `brphase 1` to spend twice.
    ok(W.S.match.stormFirst == nil,
        'phase 1 spends the pre-drawn circle rather than leaving it lying about')
end

-- ---------------------------------------------------------------------------
describe('first.once')
do
    -- ═══ THE DRAW REFUSES TO HAPPEN TWICE, AND THE CLOCK MOVES BETWEEN TRIES ═══
    --
    -- ONE CALLER EXISTS TODAY and it cannot fire twice: BR.Match.transition returns
    -- immediately when `from == state`, so onEnter(WARMUP) runs once per match, and
    -- `brwarmupfreeze off` -- the one thing that looks like it re-enters warmup --
    -- only rebroadcasts the state and resets the clock. The guard is therefore not
    -- protecting against a bug that exists; it is protecting a PUBLIC function on
    -- BR.Storm whose second caller would advance the stream, hand every phase the
    -- value belonging to the phase before it, and look exactly like a working
    -- storm. That is the failure first.stream describes, arriving from a direction
    -- nobody was watching.
    --
    -- THE CLOCK IS ADVANCED BETWEEN THE TWO CALLS ON PURPOSE. The seed is
    -- GetGameTimer() plus the sequence number, so a second call at the SAME
    -- millisecond would reseed to the identical stream and redraw the identical
    -- circle -- a test with a still clock would pass whether the guard existed or
    -- not, which is a test that proves nothing.
    local ANCHOR = { x = 150.0, y = -900.0, name = 'Test' }
    local S = newStormServer()
    local env = S.env
    S.roster[1] = nil
    S.match.storm = nil
    S.match.state = env.BR.MatchState.WARMUP
    S.match.anchor = { x = ANCHOR.x, y = ANCHOR.y, name = ANCHOR.name }

    env.BR.Storm.drawFirstCircle(S.match)
    local once = S.match.stormFirst
    local rng  = S.match.stormRng
    ok(once ~= nil, 'the first call draws')

    S.now = S.now + 5000
    env.BR.Storm.drawFirstCircle(S.match)

    ok(rawequal(rng, S.match.stormRng),
        'a second call five seconds later does not reseed the stream')
    ok(S.match.stormFirst and once
        and S.match.stormFirst.cx == once.cx
        and S.match.stormFirst.cy == once.cy,
        'and does not move circle 1',
        S.match.stormFirst and once and
            ('was (%.4f, %.4f), now (%.4f, %.4f)'):format(
                once.cx, once.cy, S.match.stormFirst.cx, S.match.stormFirst.cy)
            or nil)
    ok(S.countSent(env.BR.Net.STORM_PREVIEW) == 1,
        'and the room is told once, not twice',
        S.countSent(env.BR.Net.STORM_PREVIEW))

    -- AND THE MATCH THAT FOLLOWS IS STILL THE MATCH. The guard is only worth
    -- having if it protects the stream, so the walk is what proves it did.
    local twice = walkMatch(ANCHOR, true)
    ok(twice.phases[2] ~= nil and S.match.stormFirst ~= nil
        and twice.phases[1].cx == S.match.stormFirst.cx,
        'the doubly-asked match still draws the same phase 1 as a singly-asked one')
end

-- ---------------------------------------------------------------------------
describe('first.fallback')
do
    -- ═══ `brforce playing` FROM NOTHING STILL WORKS, AND IT IS NOT AN AFTERTHOUGHT ═══
    --
    -- That route skips warmup entirely, so BR.Bus.plan never ran, there is no route
    -- and no anchor -- and therefore nothing to draw circle 1 off. BR.Storm.begin
    -- picks a POI and draws for itself, exactly as it did before #327, and that is
    -- the path a developer uses a dozen times an evening. A preview it cannot show
    -- must not cost it a storm.
    local S = newStormServer()
    local env = S.env
    S.match.anchor = nil
    S.match.storm  = nil
    S.match.state  = env.BR.MatchState.WARMUP

    -- WARMUP WITH NO ROUTE DRAWS NOTHING AND SEEDS NOTHING, which matters: a seed
    -- taken here would be a seed begin must not take again, off an anchor that does
    -- not exist yet.
    env.BR.Storm.drawFirstCircle(S.match)
    ok(S.match.stormFirst == nil, 'no anchor, no circle')
    ok(S.match.stormRng == nil, 'and no seed either')
    ok(S.countSent(env.BR.Net.STORM_PREVIEW) == 0, 'and nothing published')

    S.match.state = env.BR.MatchState.PLAYING
    env.BR.Storm.begin(S.match)
    ok(S.match.anchor ~= nil, 'begin picks a POI -- any POI beats no storm')
    ok(S.match.stormRng ~= nil, 'and seeds the stream itself')
    ok(S.match.storm ~= nil and S.match.storm.phase == 1,
        'and phase 1 is on the map')
    ok(S.match.storm ~= nil
        and near(S.match.storm.r1, env.BR.Config.Storm.phases[1].radius, 0.001),
        'closing on the authored phase-1 radius, drawn here rather than consumed')
    ok(S.errored() == nil, 'and the forced start runs clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('first.hold')
do
    -- ═══ THE FREE-LOOT HOLD IS PRICED AGAINST CIRCLE 1'S WALL (#364) ═══
    --
    --   "change the phase 1 hold please, based on location of the players as we
    --    said."                                           -- owner, 2026-09-23
    --
    -- BR.Storm.begin prices phase 1's wait on the furthest living player's distance
    -- to circle 1's SHAPE: the zone the 75% cut counts against and the wall ends
    -- phase 1 on. Circle 1 is drawn with the whole opening circle as slack, so it
    -- can sit kilometres off the anchor the hold used to be measured from.
    --
    -- EVERY EXPECTATION IS READ OFF THE RECORD BEGIN PUBLISHED, never off a circle
    -- this block drew for itself: the claim is that the price and the wall agree,
    -- so the wall is what the price is checked against.
    local S = newStormServer()
    local env = S.env
    local H = env.BR.Config.Storm.hold
    local R1 = env.BR.Config.Storm.phases[1].radius
    local FLOOR = H.minSeconds * 1000.0

    --- A fresh server holding one match at WARMUP on `anchor`, nobody in it yet.
    --- Same anchor and clock, same seed: first.stream is what pins that.
    local function warmup(anchor)
        local W = newStormServer()
        W.roster[1] = nil
        W.match.storm = nil
        W.match.state = W.env.BR.MatchState.WARMUP
        W.match.anchor = { x = anchor.x, y = anchor.y, name = anchor.name }
        return W
    end

    --- Stand living players at `spots`, replacing whoever was there.
    local function stand(W, spots)
        for k in pairs(W.roster) do W.roster[k] = nil end
        for i, p in ipairs(spots) do
            W.roster[i] = { matchId = W.match.id, name = 'P' .. i,
                state = W.env.BR.PlayerState.ALIVE, hp = 100.0,
                pos = { x = p.x, y = p.y, z = 30.0 } }
        end
    end

    --- Go live, and hand back the record begin published.
    local function goLive(W)
        W.match.state = W.env.BR.MatchState.PLAYING
        W.env.BR.Storm.begin(W.match)
        return W.match.storm
    end

    --- Circle 1 as a record describes it: zone 1, at the end of phase 1's sweep.
    local function wallOf(W, rec)
        return W.env.BR.StormZone(rec, rec.cx1, rec.cy1, rec.r1, 1.0)
    end

    --- The rule, spelled from the config, for a furthest distance outside the wall:
    --- floored, capped, capped again. Milliseconds, as the record carries it.
    local function price(far)
        return math.min(env.BR.Clamp(math.max(0.0, far) / H.metersPerSec,
            H.minSeconds, H.maxSeconds), H.startCapSeconds) * 1000.0
    end

    -- ─── a solo player at circle 1's centre waits the floor, every match ───
    --
    -- What #364 measured: 300 solo matches with the player at circle 1's exact
    -- centre, and one in five priced the full three minutes off the anchor. This is
    -- 320, one server reused with a fresh seed each, over every POI as the anchor.
    local m = S.match
    local n, off, anchorOut, first = 0, 0, 0, nil
    for trial = 1, 320 do
        local poi = env.BR.Config.Map.POIs[(trial - 1) % #env.BR.Config.Map.POIs + 1]
        S.now = 1000000 + trial * 7777
        m.storm, m.stormRng, m.stormSeed, m.stormFirst = nil, nil, nil, nil
        m.stormHoldCapped = nil
        m.state = env.BR.MatchState.WARMUP
        m.anchor = { x = poi.x, y = poi.y, name = poi.name }
        env.BR.Storm.drawFirstCircle(m)
        local f = m.stormFirst
        stand(S, { { x = f.cx, y = f.cy } })
        local rec = goLive(S)
        n = n + 1
        if env.BR.StormShape.distance(wallOf(S, rec), poi.x, poi.y) > 0 then
            anchorOut = anchorOut + 1
        end
        if rec.tWait ~= FLOOR then
            off = off + 1
            first = first or ('trial %d, anchor %s: %.1fs'):format(trial,
                tostring(poi.name), rec.tWait / 1000)
        end
    end
    ok(n == 320 and off == 0,
        '320 solo matches with the player at circle 1\'s centre: every one waits the '
            .. 'one-minute floor',
        first and ('%d of %d did not; first %s'):format(off, n, first) or nil)
    ok(anchorOut >= 32,
        'and the sweep is the one that mattered: the anchor sits outside circle 1 in '
            .. 'at least one match in ten',
        ('%d of %d'):format(anchorOut, n))
    ok(S.errored() == nil, 'the sweep runs clean', S.errored())

    -- ─── a spread lobby: the straggler pays their distance to the wall ───
    --
    -- One player in the middle of circle 1, one outside it beyond its DEEPEST DENT,
    -- where the wall comes closest to the centre and a radius test is most wrong.
    -- The price is the straggler's distance to the wall: not their distance past r,
    -- and not their distance past r from the anchor. One of two inside is 50%, so
    -- the 75% cut stays out of it and the number on the record is the price itself.
    local ANCHOR = { x = 150.0, y = -900.0, name = 'Test' }
    local W = warmup(ANCHOR)
    W.env.BR.Storm.drawFirstCircle(W.match)
    local f = W.match.stormFirst
    local shape = W.env.BR.StormShape.blob(f.cx, f.cy, R1,
        W.env.BR.StormUnit(W.match.stormSeed, 1))
    local function wallAt(th)
        local lo, hi = 0.0, 2.0 * R1
        for _ = 1, 60 do
            local mid = 0.5 * (lo + hi)
            if W.env.BR.StormShape.distance(shape, f.cx + mid * math.cos(th),
                    f.cy + mid * math.sin(th)) <= 0 then lo = mid else hi = mid end
        end
        return lo
    end
    local dentTh, dentR = 0.0, math.huge
    for k = 0, 719 do
        local w = wallAt(k * math.pi / 360.0)
        if w < dentR then dentTh, dentR = k * math.pi / 360.0, w end
    end
    local OUT = 1100.0
    local mid = { x = f.cx, y = f.cy }
    local out = { x = f.cx + (dentR + OUT) * math.cos(dentTh),
                  y = f.cy + (dentR + OUT) * math.sin(dentTh) }
    stand(W, { mid, out })
    local rec = goLive(W)

    local far = W.env.BR.StormShape.distance(wallOf(W, rec), out.x, out.y)
    local want = price(far)
    local byRadius = price(W.env.BR.Dist(out.x, out.y, rec.cx1, rec.cy1) - R1)
    local byAnchor = price(W.env.BR.Dist(out.x, out.y, ANCHOR.x, ANCHOR.y) - R1)
    local detail = ('tWait %.1fs; wall %.0fm out prices %.1fs, past r %.1fs, from the '
        .. 'anchor %.1fs; dent %.0fm in'):format(rec.tWait / 1000, far, want / 1000,
            byRadius / 1000, byAnchor / 1000, R1 - dentR)
    ok(W.match.stormHoldCapped ~= true and math.abs(rec.tWait - want) < 1.0
        and want > FLOOR and want < H.startCapSeconds * 1000.0,
        'a spread lobby is priced on the straggler\'s distance to circle 1\'s wall, '
            .. 'between the floor and the start cap', detail)
    ok(math.abs(want - byRadius) > 5000.0 and math.abs(want - byAnchor) > 5000.0,
        'which is neither their run past r nor their run from the anchor', detail)

    -- THE ROUTE THAT NEVER HAD A WARMUP draws circle 1 at begin instead, and must
    -- price against the circle it then closes on. Same anchor, same clock: the same
    -- circle, and the same price for the same two players.
    local F = warmup(ANCHOR)
    stand(F, { mid, out })
    local frec = goLive(F)
    local ffar = F.env.BR.StormShape.distance(wallOf(F, frec), out.x, out.y)
    ok(frec.cx1 == rec.cx1 and frec.cy1 == rec.cy1
        and math.abs(frec.tWait - price(ffar)) < 1.0
        and math.abs(frec.tWait - rec.tWait) < 1.0,
        'and a match that skipped warmup draws circle 1 at begin and prices the same '
            .. 'lobby against that same wall',
        ('circle 1 (%.1f, %.1f) vs (%.1f, %.1f), tWait %.1fs vs %.1fs'):format(
            frec.cx1, frec.cy1, rec.cx1, rec.cy1, frec.tWait / 1000, rec.tWait / 1000))
    ok(F.errored() == nil and W.errored() == nil, 'both run clean',
        F.errored() or W.errored())

    -- ─── and a lobby that goes live 75% inside is sent ONE record, already cut ───
    --
    -- Three in the middle and the same straggler, priced past 1:30. The cut runs
    -- inside enterPhase before the first publish (#352), so the room never sees
    -- the price and then 1:30 a second later.
    local C = warmup(ANCHOR)
    C.env.BR.Storm.drawFirstCircle(C.match)
    stand(C, { mid, { x = f.cx + 20.0, y = f.cy }, { x = f.cx - 20.0, y = f.cy }, out })
    C.sent = {}
    local crec = goLive(C)
    local syncs = {}
    for _, s in ipairs(C.sent) do
        if s.event == C.env.BR.Net.STORM_SYNC then syncs[#syncs + 1] = s.payload end
    end
    ok(want > H.capSeconds * 1000.0 and #syncs == 1
        and syncs[1].tWait == H.capSeconds * 1000.0 and crec.tWait == syncs[1].tWait,
        'three of four inside with a straggler priced past 1:30: one first record, '
            .. 'and it already says 1:30',
        ('%d records, first %s, straggler priced %.1fs'):format(#syncs,
            tostring(syncs[1] and syncs[1].tWait), want / 1000))
end

-- ---------------------------------------------------------------------------
describe('first.wire')
do
    -- ═══ WHAT CROSSES THE WIRE IS A CIRCLE, NOT A SECOND STORM RECORD ═══
    --
    -- The temptation is to publish something BR.StormAt could read, because every
    -- other storm message is exactly that. A record is a TIMELINE and this is one
    -- still circle: a tStart in here would invite a client to solve a phase off it,
    -- and the first symptom would be two walls disagreeing about where the edge is
    -- while only one of them can hurt anybody.
    local S = newStormServer()
    local env = S.env
    S.match.storm = nil
    S.match.state = env.BR.MatchState.WARMUP

    env.BR.Storm.drawFirstCircle(S.match)
    local p = S.lastSent(env.BR.Net.STORM_PREVIEW)
    ok(p ~= nil, 'warmup publishes circle 1 to the room')
    ok(p and S.match.stormFirst and p.cx == S.match.stormFirst.cx
        and p.cy == S.match.stormFirst.cy,
        'and publishes the circle it actually drew')
    ok(p and near(p.r, env.BR.Config.Storm.phases[1].radius, 0.001),
        'at the authored phase-1 radius', p and tostring(p.r))
    ok(p and p.tStart == nil and p.tWait == nil and p.tShrink == nil
        and p.dps == nil and p.cx1 == nil and p.phase == nil,
        'and there is no clock, no dps and no second circle in it -- nothing a '
            .. 'client could mistake for a record')

    -- THE LATE JOINER GETS THEIR OWN COPY, because a player attached to a match
    -- already in WARMUP receives no transition and nothing else would ever tell
    -- them. Same shape as BR.Bus.sendPreview, called from the same two places.
    local before = #S.out
    env.BR.Storm.sendPreview(S.match, 7)
    local direct = S.out[#S.out]
    ok(#S.out == before + 1 and direct.event == env.BR.Net.STORM_PREVIEW
        and direct.target == 7,
        'a late joiner is sent the circle directly')
    ok(direct and direct.payload and direct.payload.cx == p.cx,
        'and it is the same circle the room got')

    -- AND IT GOES QUIET ONCE THE STORM IS REAL. enterPhase spends the circle, so
    -- there is nothing left to send and STORM_SYNC is the honest answer from then
    -- on. A late joiner cannot arrive here anyway -- late joining is WARMUP only --
    -- which is precisely why a stale send would never be noticed.
    S.match.state = env.BR.MatchState.PLAYING
    env.BR.Storm.begin(S.match)
    local after = #S.out
    env.BR.Storm.sendPreview(S.match, 7)
    ok(#S.out == after, 'nothing is sent once phase 1 has spent the circle')

    -- ═══ AND THE JOIN SNAPSHOT SENDS THE SAME PAYLOAD, WHICH IS A SOURCE-LEVEL
    ---     ASSERTION BECAUSE THIS SUITE CANNOT REACH THE SNAPSHOT (#344) ═══
    --
    -- server/broadcast.lua's viewFor puts this circle in the snapshot, so a br_ui
    -- restart or a reconnect mid-warmup gets it back. It used to build its own copy
    -- of the table, and the day the payload grew the SEED only one of the two copies
    -- grew it: the room saw phase 1's shape and a reconnecting client saw a circle.
    --
    -- WHY IT IS A GREP AND NOT A BEHAVIOUR TEST, said plainly. Nothing in this suite
    -- stands up broadcast.lua -- it wants the whole roster, the lobby and the match
    -- list behind it -- and a mutation that reinstated the second copy passed every
    -- assertion in this file. The gap was the DUPLICATION rather than a missing
    -- field, so the fix was to delete the second spelling and this is what holds it
    -- deleted. tools/test_matchexit.lua reads a production file the same way and for
    -- the same reason.
    local bf = io.open(RES .. 'br_core/server/broadcast.lua', 'r')
    local bsrc = bf and bf:read('a') or ''
    if bf then bf:close() end
    ok(bsrc ~= '' and bsrc:find('BR.Storm.previewPayload(m)', 1, true) ~= nil,
        'the join snapshot asks server/storm.lua for the preview payload',
        ('%d bytes read'):format(#bsrc))
    ok(bsrc ~= '' and bsrc:find('m.stormFirst.r', 1, true) == nil,
        'and does not build a second copy of it, which is how the seed would have '
            .. 'been dropped from exactly one of the two sends')
end

-- ---------------------------------------------------------------------------
describe('preview.harmless')
do
    -- ═══ A PREVIEW CANNOT HURT ANYBODY, AND THAT IS STRUCTURAL ═══
    --
    -- The storm's damage tick requires PLAYING and a published record, and a match
    -- in warmup has neither -- m.stormFirst is a circle on a match instance, not a
    -- record, and nothing reads it but enterPhase. Asserted rather than assumed
    -- because the whole of #327 is new surface arriving before the storm exists,
    -- and "the preview does not damage" is the one property whose failure would
    -- kill people during the free-loot hold of a round nobody had started.
    local S = newStormServer()
    local env = S.env
    S.match.storm = nil
    S.match.state = env.BR.MatchState.WARMUP
    env.BR.Storm.drawFirstCircle(S.match)
    ok(S.match.stormFirst ~= nil, 'the match has a previewed circle 1')

    local e = S.roster[1]
    -- Ten kilometres from it, which is outside anything on the map.
    e.pos = { x = 9000.0, y = 9000.0, z = 30.0 }
    e.stormHp = nil
    local sends = #S.out
    S.tick(); S.tick(); S.tick()

    ok(e.stormHp == nil, 'and standing 10km from it costs nothing')
    ok(#S.out == sends, 'no STORM_DAMAGE is sent')
    ok(next(S.defeated) == nil, 'and nobody is defeated by a circle on a map')
    ok(S.errored() == nil, 'the warmup ticks run clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('preview.ring')
do
    -- ═══ THE PURPLE RING, FROM THE MOMENT IT IS DRAWN THROUGH WARMUP AND THE BUS ═══
    --
    --   "show the blip starting from then"               -- owner, 2026-09-21
    --
    -- One radius blip on circle 1, in the colour the game already uses for "the
    -- circle you are being asked to rotate to". It is the only storm thing on the
    -- map before PLAYING, and the two states it belongs to are the whole of its
    -- lifetime -- there is no teardown to get wrong, because the gate IS the
    -- teardown.
    --
    -- ═══ THIS IS THE FALLBACK PATH NOW, AND IT IS PINNED AS ONE (#350) ═══
    --
    -- The map fills circle 1's real boundary through the minimap overlay when it can,
    -- and the ring below is what a client that cannot gets instead. So this block
    -- runs with ScaleformUI_Assets ANSWERING NOTHING -- handle nil, which is the
    -- shape of that resource not being started -- rather than with the overlay
    -- happening to be slower than the ticks it drives.
    --
    -- BECAUSE THE FALLBACK IS THE HALF THAT CAN ROT UNWATCHED. The overlay is what
    -- anybody looks at, and a client whose gate never opens is one nobody will ever
    -- play on deliberately: the blip path has to keep working on evidence rather
    -- than on the fact that it used to. `map.overlay` owns the other direction.
    --
    -- The harness already defaults to no handle; it is spelled out here because every
    -- assertion in this block depends on it and a reader should not have to go and
    -- find that out.
    local C = newStormClient()
    local env = C.env
    C.mm.handle = nil
    env.BR.State.storm = nil
    env.BR.State.match.state = env.BR.MatchState.WARMUP
    env.BR.State.me.state    = env.BR.PlayerState.WARMUP
    env.BR.State.stormPreview = { cx = 800.0, cy = -1200.0, r = 2600.0 }

    C.tick(2)
    local rings = C.rings()
    ok(C.errored() == nil, 'the warmup ticks run clean', C.errored())
    ok(#rings == 1, 'exactly one ring on the map during warmup', #rings)
    local ring = rings[1]
    ok(ring and near(ring.x, 800.0, 0.001) and near(ring.y, -1200.0, 0.001),
        'on circle 1')
    ok(ring and near(ring.r, 2600.0, 0.001), 'at circle 1\'s radius',
        ring and tostring(ring.r))
    ok(ring and ring.colour == env.BR.Config.Storm.blip.nextColour,
        'in the purple the "Next Safe Zone" ring already uses -- 27, reused '
            .. 'rather than a second colour for the same meaning',
        ring and tostring(ring.colour))
    ok(ring and ring.name ~= nil,
        'and it has a legend entry, like every blip this project makes')

    -- NOT REBUILT. It never moves and never resizes, so it is created once: the
    -- remove-and-re-add cadence the storm's own rings need exists because their
    -- radius changes every frame of a shrink, and paying it here would be blip
    -- churn for a circle that is standing still.
    local handle = nil
    for h, b in pairs(C.blips) do if b == ring then handle = h end end
    C.tick(20)
    ok(C.blips[handle] and C.blips[handle].exists and #C.rings() == 1,
        'and twenty ticks later it is still the same one blip, not the twentieth')

    -- THE BUS KEEPS IT. Riding is exactly when the ring is being read.
    env.BR.State.match.state = env.BR.MatchState.BUS
    env.BR.State.me.state    = env.BR.PlayerState.BUS
    C.tick(2)
    ok(#C.rings() == 1, 'the ring survives the flight', #C.rings())

    -- AND PLAYING TAKES IT AWAY, because the real record draws its own two rings
    -- and two purple circles on one map is how a player learns to trust neither.
    env.BR.State.match.state = env.BR.MatchState.PLAYING
    C.tick(2)
    ok(#C.rings() == 0, 'and PLAYING clears it', #C.rings())
end

-- ---------------------------------------------------------------------------
describe('preview.ends')
do
    -- ═══ A MATCH THAT ENDS DURING WARMUP LEAVES NOTHING BEHIND ═══
    --
    -- Warmup can end without a storm ever existing: everybody walks off the pad,
    -- or the round is cancelled. No STORM_SYNC is ever published on that path, so
    -- anything waiting for the record to clean up after it would wait forever --
    -- and a purple ring left on the map in the lobby is the kind of thing that
    -- survives a whole session.
    local C = newStormClient()
    local env = C.env
    env.BR.State.storm = nil
    env.BR.State.match.state = env.BR.MatchState.WARMUP
    env.BR.State.me.state    = env.BR.PlayerState.WARMUP
    env.BR.State.stormPreview = { cx = 0.0, cy = 0.0, r = 2600.0 }
    C.tick(2)
    ok(#C.rings() == 1, 'a ring is up during warmup')

    env.BR.State.match.state = env.BR.MatchState.ENDED
    C.tick(2)
    ok(#C.rings() == 0, 'ENDED takes it down without a record ever existing')

    -- AND THE WAY HOME. A player swept back to the lobby shares the match state
    -- with nobody, but a bystander at the warmup pad shares it with a match they
    -- are not in -- which is the read that used to put storm blips on their pause
    -- map at the vista menu.
    local B = newStormClient()
    B.env.BR.State.storm = nil
    B.env.BR.State.match.state = B.env.BR.MatchState.WARMUP
    B.env.BR.State.me.state    = B.env.BR.PlayerState.LOBBY
    B.env.BR.State.stormPreview = { cx = 0.0, cy = 0.0, r = 2600.0 }
    B.tick(2)
    ok(#B.rings() == 0, 'and a LOBBY bystander never gets one at all')

    -- THE MIRROR DROPS IT TOO, which is the other half of the same teardown:
    -- client/state.lua nils the field when STORM_SYNC lands. Driven here as the
    -- field going away, because that is what the renderer can see of it.
    local D = newStormClient()
    D.env.BR.State.storm = nil
    D.env.BR.State.match.state = D.env.BR.MatchState.BUS
    D.env.BR.State.me.state    = D.env.BR.PlayerState.BUS
    D.env.BR.State.stormPreview = { cx = 0.0, cy = 0.0, r = 2600.0 }
    D.tick(2)
    ok(#D.rings() == 1, 'a ring is up on the bus')
    D.env.BR.State.stormPreview = nil
    D.tick(2)
    ok(#D.rings() == 0, 'and dropping the field alone takes it down')
end

-- ---------------------------------------------------------------------------
describe('preview.wall')
do
    -- ═══ THE WALL WAITS FOR THE WORLD, WHICH ANOTHER RESOURCE OWNS ═══
    --
    --   "Show the marker (or arc now as it may be) starting from when the San
    --    Andreas map is loaded"                         -- owner, 2026-09-21
    --
    -- That moment has a name. br_environment/client/ipl.lua's wantIsland is
    -- `state ~= PLAYING and state ~= BUS`, so the Cayo lobby island comes down on
    -- the BUS transition -- but applyIsland does NOT run on that transition. It is
    -- deferred until the rendered camera is clear of the island, or until the bus's
    -- own release cue a few seconds into the ascent. Enabling the heist island
    -- HIDES Los Santos, so for those seconds a curtain drawn over the mainland is a
    -- curtain in a world that is switched off. So ipl.lua says when the swap has
    -- actually applied and this listens.
    local function wallClient(state, said)
        local C = newStormClient()
        local env = C.env
        env.BR.State.storm = nil
        env.BR.State.match.state = state
        env.BR.State.me.state    = env.BR.PlayerState.BUS
        env.BR.State.stormPreview = { cx = 400.0, cy = 0.0, r = 2600.0 }
        if said ~= nil then C.fire('br:env:world', said) end
        -- THE ENTRY RAMP IS RUN OUT HERE (#351). Every gate below is about WHETHER
        -- there is a wall, not about how it arrives, and on the first frame after the
        -- world loads the answer is legitimately "nothing yet" -- see C.settlePreview.
        -- The ramp itself is `preview.entry`'s subject.
        C.settlePreview()
        return C
    end

    local MS = newStormClient().env.BR.MatchState

    -- MEASURED IN POLYS, NOT MARKERS, AND THAT IS THE SECOND HALF OF #336. The
    -- preview asked for the cylinder until the fade existed, and the owner has since
    -- refused that too: "don't use a marker for the bus preview either"
    -- (2026-09-22). So every gate below counts triangles, and `preview.strip` under
    -- this block asserts that the marker count is zero -- which is what makes a
    -- quietly reinstated `'solid'` preference fail here rather than in a screenshot
    -- taken from a plane.
    ok(#wallClient(MS.BUS, false).polys > 0,
        'the island is gone and the bus is flying, so there is a wall')
    ok(#wallClient(MS.BUS, true).polys == 0,
        'the island is still the world, so there is not -- even though the match '
            .. 'state says BUS')
    ok(#wallClient(MS.WARMUP, true).polys == 0,
        'and standing on the pad, with the island still the world, there is nothing')

    -- THE GATE IS THE WORLD AND NOT THE FLIGHT, and this is the assertion that
    -- says which. "From when the San Andreas map is loaded" is the owner's
    -- condition, so a warmup in which the mainland is somehow already the world
    -- gets the wall -- the wall follows the ground it is standing on, not the state
    -- machine. The game cannot currently reach that: ipl.lua's wantIsland only
    -- releases the island at BUS or PLAYING. Pinned anyway, because the tempting
    -- "simplification" is to replace the whole announcement with a BUS test, and
    -- that is the thing #327 specifically moved away from.
    ok(#wallClient(MS.WARMUP, false).polys > 0,
        'and a warmup that somehow already has Los Santos loaded gets the wall -- '
            .. 'the condition is the map, not the phase of the match')

    -- THE FALLBACK, AND IT ONLY ANSWERS WHEN NOBODY ELSE DOES. If br_environment
    -- never speaks -- it is not running, or has not reached its first
    -- announcement -- the match state answers instead, because a preview is not
    -- worth a hard dependency between two resources.
    ok(#wallClient(MS.BUS, nil).polys > 0,
        'with br_environment silent the BUS state alone raises the wall')
    ok(#wallClient(MS.WARMUP, nil).polys == 0,
        'and silence during warmup still draws nothing')

    -- ═══ PLAYING WITH NO RECORD YET DRAWS NOTHING, WHICH IS WHAT IS LEFT OF THIS
    --     ASSERTION SINCE #340 ═══
    --
    -- It used to read "PLAYING draws no preview wall" flat out, and that is no longer
    -- the rule: the preview now extends into PLAYING while the real wall is suppressed,
    -- and `preview.handoff` walks that whole stretch. What survives, and matters, is
    -- the moment BETWEEN the transition and the first STORM_SYNC -- a client that has
    -- gone PLAYING and has no record must draw nothing rather than fall back to the
    -- stale published field. `wallClient` leaves BR.State.storm nil, which is that
    -- moment exactly.
    ok(#wallClient(MS.PLAYING, false).polys == 0,
        'PLAYING with no record yet draws nothing -- the preview\'s PLAYING stretch '
            .. 'reads the record, so a client between the transition and the first '
            .. 'STORM_SYNC has nothing to read and draws nothing')

    -- ═══ IT IS THE SHIPPING RENDERER, HANDED A CIRCLE AND A LOWER ALPHA ═══
    --
    --   "don't use a marker for the bus preview either."   -- the owner, 2026-09-22
    --
    -- THE PREVIEW USED TO ASK FOR THE CYLINDER BY NAME, and the reasoning was sound:
    -- the bus cruises at 500 and climbs to 892 over the Chiliad massif, and a strip
    -- topping out at 400 was entirely below the only viewpoint the preview is ever
    -- seen from. The answer turned out to be raising the wall rather than keeping the
    -- marker -- topZ is the marker's own 850 now and its last metres fade to nothing
    -- -- so the preview takes the same renderer AND the same height as the live wall,
    -- and the preview-specific top that was drafted for it was deleted.
    --
    -- THE ASSERTIONS ARE THE NUMBERS THAT PROVE IT WENT THROUGH drawWall rather than
    -- through a second renderer written beside it: no marker at all, the edgeInset
    -- the column path once failed to pay, the live wall's own two z planes, and the
    -- alpha.
    local C = wallClient(MS.BUS, false)
    local rr = C.env.BR.Config.Storm.render
    local psp = rr.strip
    ok(#C.markers == 0 and #C.polys > 0,
        'the preview is the quad strip and not one marker anywhere',
        ('%d markers, %d polys'):format(#C.markers, #C.polys))

    -- ON CIRCLE 1, AND AT ITS RADIUS LESS THE INSET. Read off the geometry rather
    -- than off a marker's scale: every quad corner is edgeInset inside circle 1's
    -- own rim, which is the same claim the cylinder's diameter used to make.
    --
    -- ═══ AND CIRCLE 1 IS PHASE 1'S SHAPE NOW, NOT A CIRCLE (#344) ═══
    --
    -- Which is the whole reason the preview carries a seed: the bus is shown the
    -- shape phase 1 will actually wear, so the handoff is a crossfade between two
    -- alphas rather than a circle turning into a blob halfway through it. The
    -- expectation is built from phase 1's own unit -- the same derivation the client
    -- makes from the published field -- because the claim being asserted is that the
    -- preview went through drawWall on the shape the record will carry, and any
    -- other shape here would be the defect rather than a different spelling.
    local PSS = C.env.BR.StormShape
    local pwant = PSS.inset(
        PSS.blob(400.0, 0.0, 2600.0, C.env.BR.StormUnit(nil, 1)),
        rr.edgeInset or 0.0)
    local worstR, nq = 0.0, 0
    for _, qd in ipairs(quadsOf(C)) do
        for _, v in ipairs({ qd.a, qd.b }) do
            nq = nq + 1
            local off = math.abs(PSS.distance(pwant, v.x, v.y))
            if off > worstR then worstR = off end
        end
    end
    ok(nq > 0 and worstR < 1e-6,
        "centred on circle 1, on phase 1's own shape, at the edgeInset every wall "
            .. 'in this file pays',
        ('%d corners, worst %.9f m off'):format(nq, worstR))
    ok(pwant.kind == 'blob',
        'and that shape is a blob rather than a circle -- a preview that drew a '
            .. 'circle would pop into a different outline across the handoff',
        tostring(pwant.kind))

    -- THE SAME HEIGHT AS THE LIVE WALL, DELIBERATELY, and asserted against the live
    -- config rather than against a preview value -- because there is no preview
    -- value, and the assertion is what stops one reappearing. A preview-specific top
    -- would pass every other test in this block.
    local pLo, pHi = math.huge, -math.huge
    for _, t in ipairs(C.polys) do
        for j = 1, 3 do
            if t[j].z < pLo then pLo = t[j].z end
            if t[j].z > pHi then pHi = t[j].z end
        end
    end
    ok(pLo == psp.baseZ and pHi == psp.topZ,
        'spanning the live wall\'s own base and top -- one wall, one height, two '
            .. 'alphas, because the fade is what makes a taller preview unnecessary',
        ('%.1f to %.1f against %.1f to %.1f'):format(pLo, pHi,
            psp.baseZ, psp.topZ))

    -- AND FAINTER, WHICH IS THE ONE THING THE PREVIEW DOES DIFFERENTLY. It marks a
    -- place the storm is GOING to be and must not read as a wall already doing
    -- something, so previewAlpha scales the whole fade ramp -- not just the bottom of
    -- it. Checked against the config's own arithmetic rather than against a second
    -- drawn wall, because a second wall would be asserting the renderer against
    -- itself.
    -- ASKED OF THE PATH THE PREVIEW ACTUALLY TOOK. On the shipping gradient the ramp
    -- is in the texture and the draw's alpha is previewAlpha's share of render.alpha
    -- outright; on the banded fallback it is that share sampled per band. Either way
    -- the claim is the same one -- previewAlpha scales the WHOLE ramp rather than just
    -- the bottom of it -- so the expectation is computed per path instead of the
    -- assertion being dropped on one of them.
    local pfd = psp.fade or {}
    local pPath, pBandsN = fadeOf(C)
    local pAlpha = rr.alpha * (rr.previewAlpha or 0.5)
    local wantP
    if pPath == 'gradient' then
        wantP = math.floor(pAlpha + 0.5)
    else
        local ph = (psp.topZ - psp.baseZ) / pBandsN
        wantP = math.floor(pAlpha
            * rampMul(pfd, psp.baseZ, psp.topZ, psp.baseZ + ph * 0.5) + 0.5)
    end
    local pBands = quadsOf(C)[1] and quadsOf(C)[1].bands
    ok(pBands and #pBands == pBandsN and pBands[1].alpha == wantP
        and pBands[1].alpha < rr.alpha,
        'and fainter than a wall that is actually doing something -- previewAlpha '
            .. 'scales the whole ramp, not just the bottom of it',
        ('%s path, bottom %s against %d, live wall full strength %d'):format(
            pPath, pBands and tostring(pBands[1].alpha), wantP, rr.alpha))
    ok(C.errored() == nil, 'the preview wall runs clean', C.errored())

    -- AND IT SAYS NOTHING TO THE INTERFACE. The HUD storm card is driven off the
    -- record; a preview that pushed an envelope would put a phase counter and a
    -- "storm closing" clock on screen for a storm that does not exist.
    ok(C.last() == nil, 'and no HUD envelope is pushed for a preview')
end

-- ---------------------------------------------------------------------------
describe('preview.handoff')
do
    -- ═══ FROM THE BUS TO THE FIRST MOVE, WITHOUT A GAP (#340) ═══
    --
    --   "After match goes to playing, before the first storm move, the storm border
    --    cannot be seen anywhere. Doesn't seem to draw during this time. The storm
    --    circle should draw the entire time from while in bus to when it moves. Make
    --    sure it fades in just like before."       -- the owner, 2026-09-22, #340
    --
    -- ═══ WHY THIS BLOCK WALKS A TIMELINE INSTEAD OF ASSERTING TWO STATES ═══
    --
    -- BECAUSE BOTH ENDS WERE ALREADY GREEN WHILE THE DEFECT SHIPPED. `preview.wall`
    -- proved the bus has a wall and `wall.strip` proved the fade-in reaches full
    -- strength, and the hole was the two minutes between them -- which no assertion
    -- about either end can see. This suite has now been green over a real defect three
    -- times (a wall 33 m outside the boundary, a test comparing one point with itself,
    -- UV mutations surviving because the test client only ever stood inside the circle)
    -- and every one of them was a gap between two true statements.
    --
    -- SO THE PROPERTY IS CONTINUITY AND IT IS ASSERTED AS ONE: the clock is driven from
    -- the bus, through the PLAYING transition, down the whole phase-1 hold, across the
    -- fade window and into the shrink, and at EVERY step something is on screen. A
    -- renderer that drew nothing for one frame anywhere in there fails, wherever that
    -- frame is.
    --
    -- ═══ AND THE SECOND PROPERTY IS THAT NEITHER WALL POPS ═══
    --
    -- Continuity alone would be satisfied by the preview cutting out at full strength
    -- as the real wall cut in at nothing -- which is a flicker, not a handoff. So the
    -- walk also reads each wall's alpha at every step and asserts three things about
    -- the pair: that the preview only ever falls and the real wall only ever rises,
    -- that neither moves further in one step than the clock can carry it, and that
    -- their two shares SUM TO ONE inside the fade window. The third is the real claim.
    -- One clock read in two directions is what makes it hold; two clocks would drift
    -- and this is the assertion that would catch them.
    --
    -- THE TWO WALLS ARE TOLD APART BY WHICH SHAPE THEIR CORNERS STAND ON, not by their
    -- alpha -- an alpha is what is under test here, so reading it to decide which wall
    -- it belongs to would be circular. The record below nests circle 1 well inside the
    -- opening circle, so the two boundaries are well over a kilometre apart at their
    -- closest and the classification cannot be ambiguous.
    --
    -- BY SHAPE AND NOT BY RADIUS SINCE #344: both walls are blobs, so "is this corner
    -- CR - inset from circle 1's centre" is no longer a question about circle 1 -- it
    -- is a question about the jitter draw, and it answered NO for every corner, which
    -- read as neither wall being on screen at all.

    local proto = newStormClient()
    local MS, PS = proto.env.BR.MatchState, proto.env.BR.PlayerState
    local rr = proto.env.BR.Config.Storm.render
    local INSET = rr.edgeInset or 0.0
    local FADE = (rr.fadeInSec or 10.0) * 1000.0
    -- FULL is the live wall's alpha and PREV the preview's share of it, both as the
    -- renderer rounds them, so every expectation below is the config's own arithmetic.
    local FULL = math.floor(rr.alpha + 0.5)
    local PREV = math.floor(rr.alpha * (rr.previewAlpha or 0.5) + 0.5)

    -- The opening circle (the whole map) and circle 1 nested inside it.
    local OCX, OCY, OR = 0.0, 0.0, 4000.0
    local CCX, CCY, CR = 500.0, 0.0, 1600.0
    local WAIT, SHRINK = 120000, 60000

    -- THE TWO SHAPES THE TWO WALLS DRAW, built once. Seed 0 for both: the preview
    -- reads the published field (no seed) and the record below is built by hand
    -- (BR.BuildStormRecord's own default, also 0), which is the same agreement the
    -- game has between the preview payload and the record. The preview is circle 1,
    -- so ZONE 1's shape. The real wall's zone is the opening circle -- ZONE 0, in its
    -- own shape since each zone keeps one -- union circle 1, which nests, so it is one
    -- shape, exactly as it is in a match.
    local PSS = proto.env.BR.StormShape
    local UNIT0 = proto.env.BR.StormUnit(nil, 0)
    local UNIT1 = proto.env.BR.StormUnit(nil, 1)
    local PREVIEW_SHAPE = PSS.inset(PSS.blob(CCX, CCY, CR, UNIT1), INSET)
    local REAL_SHAPE = PSS.inset(
        PSS.zone(OCX, OCY, OR, CCX, CCY, CR, UNIT0, UNIT1), INSET)

    --- Which wall each triangle of the last frame belongs to, and at what alpha.
    ---
    --- Returns two records, `{ n, alpha, mixed }`. `n` is 0 for a wall that is not on
    --- screen at all, which is what lets the walk treat absence as alpha 0 and measure
    --- a pop as an ordinary step. `mixed` is set when one wall's triangles disagree
    --- about their alpha -- the picket-fence invariant, asked per wall, which is how it
    --- survives two walls being legitimately in one frame.
    local function walls(C)
        local pv = { n = 0, alpha = 0, mixed = nil }
        local rw = { n = 0, alpha = 0, mixed = nil }
        local stray = nil
        for _, t in ipairs(C.polys) do
            local v = t[1]
            local w
            if math.abs(PSS.distance(PREVIEW_SHAPE, v.x, v.y)) < 1e-6 then w = pv
            elseif math.abs(PSS.distance(REAL_SHAPE, v.x, v.y)) < 1e-6 then w = rw
            else
                stray = stray or ('a triangle at (%.3f, %.3f) is on neither shape')
                    :format(v.x, v.y)
            end
            if w then
                if w.n == 0 then w.alpha = t.a
                elseif w.alpha ~= t.a then
                    w.mixed = w.mixed or ('%d and %d'):format(w.alpha, t.a)
                end
                w.n = w.n + 1
            end
        end
        return pv, rw, stray
    end

    --- Put the phase-1 hold exactly `msLeft` from its end and draw one frame.
    ---
    --- THE 16 ms C.frame ADVANCES THE CLOCK BY IS ADDED IN HERE, so `msLeft` is what
    --- the renderer actually solves rather than what it would have solved a frame ago.
    --- Getting that wrong would shift every boundary assertion below by one frame and
    --- read as an off-by-one in the production clock.
    local function holdAt(C, msLeft)
        C.env.BR.State.storm.tStart = (C.now + 16) - (WAIT - msLeft)
        C.frame()
        return walls(C)
    end

    --- A client on the bus, with the mainland loaded and circle 1 published.
    local function busClient()
        local C = newStormClient()
        local env = C.env
        env.BR.State.storm = nil
        env.BR.State.match.state = MS.BUS
        env.BR.State.me.state    = PS.BUS
        env.BR.State.stormPreview = { cx = CCX, cy = CCY, r = CR }
        -- br_environment says the Cayo island is gone, which is the preview wall's own
        -- gate; fired rather than left to the fallback so this block is testing the
        -- handoff and not mainlandLoaded.
        C.fire('br:env:world', false)
        C.pedAt = pt(0.0, 0.0, 30.0)
        -- AND #351'S ENTRY RAMP IS ALREADY SPENT BEFORE THE WALK STARTS. This block
        -- is about the HANDOFF -- one clock read in two directions -- and the entry is
        -- a different ramp on a different anchor that has completed long before the
        -- hold's last fadeInSec. Leaving it running would put a third alpha curve
        -- inside assertions whose whole content is that there are exactly two.
        C.settlePreview()
        return C
    end

    --- The PLAYING transition, spelled the way client/state.lua's STORM_SYNC handler
    --- spells it: the record arrives AND the preview field is dropped. Driven by hand
    --- because this harness loads the renderer and not the mirror -- and dropping the
    --- field is the half that matters, since it is what makes the PLAYING preview read
    --- the record instead.
    local function goPlaying(C)
        C.env.BR.State.match.state = MS.PLAYING
        C.env.BR.State.me.state    = PS.ALIVE
        C.record(1, OCX, OCY, OR, CCX, CCY, CR, WAIT, SHRINK, 0.5)
        C.env.BR.State.stormPreview = nil
        C.fire(C.env.BR.Net.STORM_SYNC)
    end

    -- ─── the bus, which is the only stretch that already worked ───
    local C = busClient()
    C.frame()
    local bp, br, bs = walls(C)
    ok(bs == nil and bp.n > 0 and br.n == 0 and bp.alpha == PREV,
        'on the bus the preview wall stands on circle 1 at previewAlpha, and the '
            .. 'record\'s wall is not in frame at all',
        bs or ('preview %d tris at %d, real %d tris; wanted alpha %d'):format(
            bp.n, bp.alpha, br.n, PREV))

    -- ─── the transition itself, which is where the wall used to vanish ───
    goPlaying(C)
    local tp, tr = holdAt(C, WAIT)
    ok(tp.n == bp.n and tp.alpha == bp.alpha and tr.n == 0 and tp.mixed == nil,
        'and the frame after the match goes PLAYING draws the SAME circle at the SAME '
            .. 'alpha from the record\'s own target -- the defect was this frame drawing '
            .. 'nothing, and an equal-but-different circle would be a pop',
        ('%d tris at %d against the bus\'s %d at %d'):format(
            tp.n, tp.alpha, bp.n, bp.alpha))

    -- AND IT IS THE RECORD IT READ, NOT A STALE FIELD. The field is gone -- the mirror
    -- nils it on STORM_SYNC -- so a preview still drawing off BR.State.stormPreview
    -- would have drawn nothing here, and this is the assertion that says the source
    -- moved rather than that the gate opened.
    ok(C.env.BR.State.stormPreview == nil and tp.n > 0,
        'with BR.State.stormPreview already dropped, so the PLAYING preview is reading '
            .. 'rec.cx1/cy1/r1 -- which IS circle 1, because enterPhase spends the '
            .. 'warmup draw rather than rolling a second one')

    -- ─── the whole hold, step by step, with nothing allowed to be empty ───
    --
    -- COARSE THROUGH THE SUPPRESSED STRETCH AND FINE THROUGH THE FADE WINDOW, because
    -- the two are asking different questions: the first is "is anything on screen at
    -- all" over two minutes, the second is "does either wall jump" over ten seconds.
    local steps = {}
    for ms = WAIT, FADE + 1, -2000 do steps[#steps + 1] = ms end
    steps[#steps + 1] = FADE + 1
    for ms = FADE, 0, -250 do steps[#steps + 1] = ms end

    local W = busClient()
    goPlaying(W)
    local empty, strayAt, mixedAt = nil, nil, nil
    local jumped, nonMono = nil, nil
    local sumBad, windowSteps = nil, 0
    local lastP, lastR = PREV, 0
    -- THE MOST EITHER ALPHA MAY MOVE IN ONE STEP is what the clock can carry over that
    -- step plus a level for the rounding, so a genuine pop -- 0 to 55, or 55 to 0 --
    -- fails while the intended ramp passes. Priced off the step, not guessed.
    for i, ms in ipairs(steps) do
        local prev, real, stray = holdAt(W, ms)
        local gap = (i > 1) and (steps[i - 1] - ms) or 0
        local room = math.ceil(FULL * gap / FADE) + 1
        if stray then strayAt = strayAt or ('at %d ms: %s'):format(ms, stray) end
        if prev.n == 0 and real.n == 0 then
            empty = empty or ('%d ms into the hold, nothing is drawn at all'):format(ms)
        end
        if prev.mixed or real.mixed then
            mixedAt = mixedAt or ('at %d ms one wall reads %s'):format(
                ms, prev.mixed or real.mixed)
        end
        if prev.alpha > lastP or real.alpha < lastR then
            nonMono = nonMono or
                ('at %d ms preview %d->%d, real %d->%d'):format(
                    ms, lastP, prev.alpha, lastR, real.alpha)
        end
        if math.abs(prev.alpha - lastP) > room
            or math.abs(real.alpha - lastR) > room then
            jumped = jumped or ('at %d ms preview %d->%d, real %d->%d, room %d')
                :format(ms, lastP, prev.alpha, lastR, real.alpha, room)
        end
        -- THE SHARES SUM TO ONE INSIDE THE WINDOW, which is the one-clock claim. The
        -- tolerance is the two roundings and nothing else: one level of FULL plus one
        -- level of PREV.
        if ms < FADE and ms > 0 then
            windowSteps = windowSteps + 1
            local s = real.alpha / FULL + prev.alpha / PREV
            if math.abs(s - 1.0) > 1.0 / FULL + 1.0 / PREV then
                sumBad = sumBad or ('at %d ms the shares sum to %.4f'):format(ms, s)
            end
        end
        lastP, lastR = prev.alpha, real.alpha
    end

    ok(empty == nil and strayAt == nil and #steps > 50,
        'and across the whole hold -- the bus\'s circle through two minutes of '
            .. 'suppression, the fade window, and out the other side -- there is a wall '
            .. 'on screen at every single step, which is the gap #340 reported',
        empty or strayAt or ('%d steps, none empty'):format(#steps))
    ok(mixedAt == nil,
        'each wall\'s alpha is uniform round its own ring at every step, so two walls '
            .. 'in one frame never read as one wall that stripes along its length',
        mixedAt)
    ok(nonMono == nil,
        'the preview only ever thins and the real wall only ever strengthens: the '
            .. 'handoff runs one way',
        nonMono)
    ok(jumped == nil,
        'and neither moves further in a step than the fade clock can carry it -- a '
            .. 'preview that cut out, or a wall that cut in, fails here',
        jumped)
    ok(sumBad == nil and windowSteps > 30,
        'inside the fade window the two shares sum to one, to the two roundings: the '
            .. 'real wall\'s share of render.alpha plus the preview\'s share of '
            .. 'previewAlpha. That is ONE clock read in both directions, and it is what '
            .. 'a second clock would fail',
        sumBad or ('%d steps in the window, all summing to 1'):format(windowSteps))

    -- ─── and the far end: the preview is gone the moment the wall is whole ───
    local ep, er = holdAt(W, 0)
    ok(ep.n == 0 and er.n > 0 and er.alpha == FULL,
        'when the hold ends the real wall is at full render.alpha and the preview is '
            .. 'off screen entirely -- the constraint previewCircle\'s header states, '
            .. 'kept: no preview beside the wall it was standing in for',
        ('preview %d tris, real %d tris at %d against %d'):format(
            ep.n, er.n, er.alpha, FULL))

    -- AND IT STAYS GONE. A frame further into the shrink is the case a gate written as
    -- "not yet full" rather than "the hold is over" would get wrong, and the symptom --
    -- a faint second ring parked on circle 1 while the wall closes onto it -- is
    -- precisely what the map's purple ring is for.
    -- READ AS "NOTHING ON CIRCLE 1", not as the two-wall split: five seconds into the
    -- shrink the record's own circle has left the opening radius, so `walls` can no
    -- longer name it -- which is exactly why the claim is spelled against circle 1's
    -- boundary and the total.
    local sp2 = holdAt(W, -5000)
    ok(sp2.n == 0 and #W.polys > 0,
        'and five seconds into the shrink the preview is still gone while the wall '
            .. 'closes on the circle it was standing in for',
        ('%d triangles on circle 1, %d polys in frame'):format(sp2.n, #W.polys))

    -- ─── the two gates that exist for real reasons, both still shut ───
    --
    -- A LOBBY BYSTANDER SHARES THE MATCH STATE WITHOUT BEING IN THE MATCH, and used to
    -- get storm blips at the vista menu. The new PLAYING stretch is a new way into the
    -- same failure, so it is asked at a moment only the new code can answer: mid-hold,
    -- where the real wall is suppressed and the preview is all there is.
    local L = busClient()
    goPlaying(L)
    L.env.BR.State.me.state = PS.LOBBY
    local lp, lr = holdAt(L, WAIT * 0.5)
    ok(lp.n == 0 and lr.n == 0 and #L.polys == 0,
        'a LOBBY bystander gets nothing at all through the new PLAYING stretch, which '
            .. 'is the vista-menu report the gate was written for',
        ('%d preview, %d real, %d polys'):format(lp.n, lr.n, #L.polys))

    -- AND NOTHING SURVIVES A MATCH ENDING. activeRecord admits ENDED on purpose -- the
    -- grade and the rain have to outlive the transition or the last thing a player sees
    -- is the weather switching off -- so a preview that reused activeRecord would draw
    -- a purple circle under the verdict slam. A two-player playtest reaches exactly
    -- this: a match decided inside the phase-1 hold, record still phase 1, still
    -- HOLDING.
    local E = busClient()
    goPlaying(E)
    local hp = holdAt(E, WAIT * 0.5)
    E.env.BR.State.match.state = MS.ENDED
    local xp, xr = holdAt(E, WAIT * 0.5)
    ok(hp.n > 0 and xp.n == 0 and xr.n == 0,
        'and a match that ENDS inside the phase-1 hold takes the preview down with it, '
            .. 'though the record is still phase 1 and still HOLDING -- which is why '
            .. 'this tests PLAYING by name instead of reusing activeRecord',
        ('%d tris while playing, %d preview and %d real once ENDED'):format(
            hp.n, xp.n, xr.n))

    -- ─── a collapsed target is not a circle to stand in for ───
    --
    -- BR.StormShape.circle FLOORS ITS RADIUS AT ONE METRE (storm_shape.lua argues the
    -- floor), so a phase-1 target of zero would not draw nothing -- it would draw a
    -- one-metre purple ring, a dot on the ground with no meaning. storm.wall makes the
    -- same test on rec.r1 one screen up, and the reason to make it here as well is the
    -- asymmetry: a reader who found the guard on one wall and not the other would
    -- reasonably conclude the shape handles it.
    --
    -- THE SHIPPING CONFIG CANNOT REACH THIS, said plainly rather than implied:
    -- phases[1].radius is 2600 and every route into phase 1 goes through enterPhase
    -- with it, including `brphase 1`. It is a guard against a config, and this is a
    -- hand-built record because that is the only thing that can reach it.
    local Z = busClient()
    Z.env.BR.State.match.state = MS.PLAYING
    Z.env.BR.State.me.state    = PS.ALIVE
    Z.record(1, OCX, OCY, OR, CCX, CCY, 0.0, WAIT, SHRINK, 0.5)
    Z.env.BR.State.stormPreview = nil
    local zp = holdAt(Z, WAIT * 0.5)
    ok(zp.n == 0 and #Z.polys == 0,
        'a phase-1 record whose target has collapsed draws no preview at all, rather '
            .. 'than the one-metre ring BR.StormShape.circle\'s radius floor would '
            .. 'otherwise hand it',
        ('%d tris on circle 1, %d polys in frame'):format(zp.n, #Z.polys))

    -- ─── and the fallback reaches the new stretch, which is the easiest thing to
    --     leave behind ───
    --
    -- mainlandLoaded's fallback was BUS ALONE, which was complete while the preview
    -- itself was BUS alone. On a box where br_environment is not running -- or has not
    -- reached its first announcement -- a BUS-only fallback would withhold the ENTIRE
    -- #340 stretch and nothing would say so: the bus would have its wall, the fade-in
    -- would arrive on time, and the two minutes between them would be empty again.
    -- Every other client in this block fires the announcement, so this is the only
    -- assertion that can see it.
    local S = newStormClient()
    S.env.BR.State.storm = nil
    S.env.BR.State.match.state = MS.BUS
    S.env.BR.State.me.state    = PS.BUS
    S.env.BR.State.stormPreview = { cx = CCX, cy = CCY, r = CR }
    S.pedAt = pt(0.0, 0.0, 30.0)
    -- #351'S RAMP RUNS OUT ON THE FALLBACK PATH TOO, and that is worth having in this
    -- assertion rather than beside it: the ramp is armed by mainlandLoaded(), so a
    -- ramp that only ever completed when br_environment spoke would leave a
    -- permanently invisible wall on exactly the deployment shape this block exists for.
    S.settlePreview()
    local fbBus = walls(S)
    goPlaying(S)
    local fbHold = holdAt(S, WAIT * 0.5)
    ok(fbBus.n > 0 and fbHold.n > 0 and fbHold.alpha == PREV,
        'with br_environment silent throughout, the match state alone carries the '
            .. 'preview from the bus into the PLAYING hold -- a BUS-only fallback would '
            .. 'have withheld the whole of #340 on any box that is not running it',
        ('%d tris on the bus, %d at %d mid-hold'):format(
            fbBus.n, fbHold.n, fbHold.alpha))

    ok(C.errored() == nil and W.errored() == nil and E.errored() == nil
        and S.errored() == nil,
        'and the handoff runs clean on every client in this block',
        C.errored() or W.errored() or E.errored() or S.errored())
end

-- ---------------------------------------------------------------------------
describe('hold.cut')
do
    -- ═══ THE PHASE-1 HOLD CUT TO 1:30, AS A CLIENT SEES IT (#352) ═══
    --
    -- The server cuts the hold by publishing the record again with the same tStart
    -- and a shorter tWait (server/storm.lua's capFirstHold). Two things on this side
    -- have to follow it, and neither was written for a hold that changes length
    -- half-way through:
    --
    --   THE COUNTDOWN. The page derives its digits from the endsAt this file sends,
    --   on a 4 Hz beat -- so the first tick that solves the new record has to send
    --   it, or the old countdown sits on screen for a beat as it shortens.
    --
    --   THE #340 HANDOFF. The preview wall thins as the real one rises, both read
    --   off the record's own clock through wallShare. The preview has to hold until
    --   the last fadeInSec of the CUT hold and hand over there -- not where the old
    --   hold would have ended, a minute and a half later.
    --
    -- AND SINCE THE MATCH GOES LIVE AT 65% LANDED, SOME OF IT IS STILL IN THE AIR
    -- WHEN THESE RECORDS ARRIVE. So this client is gliding, not standing.
    local C = newStormClient()
    local env = C.env
    local MS, PS = env.BR.MatchState, env.BR.PlayerState
    local rr = env.BR.Config.Storm.render
    local INSET = rr.edgeInset or 0.0
    local FADE = (rr.fadeInSec or 10.0) * 1000.0
    local FULL = math.floor(rr.alpha + 0.5)
    local PREV = math.floor(rr.alpha * (rr.previewAlpha or 0.5) + 0.5)
    local OCX, OCY, OR = 0.0, 0.0, 4000.0
    local CCX, CCY, CR = 500.0, 0.0, 1600.0
    local WAIT, SHRINK = 180000, 60000
    local CUT = env.BR.Config.Storm.hold.capSeconds * 1000.0

    -- The preview is circle 1, zone 1's shape; the real wall is the opening circle,
    -- zone 0's -- `preview.handoff` has why they are two shapes.
    local PSS = env.BR.StormShape
    local UNIT0 = env.BR.StormUnit(nil, 0)
    local UNIT1 = env.BR.StormUnit(nil, 1)
    local PREVIEW_SHAPE = PSS.inset(PSS.blob(CCX, CCY, CR, UNIT1), INSET)
    local REAL_SHAPE = PSS.inset(PSS.zone(OCX, OCY, OR, CCX, CCY, CR, UNIT0, UNIT1),
        INSET)

    --- Each wall's triangle count and alpha in the last frame, told apart by which
    --- shape their corners stand on -- `preview.handoff`'s method, for its reason.
    local function walls()
        local pv, rw, stray = { n = 0, alpha = 0 }, { n = 0, alpha = 0 }, nil
        for _, t in ipairs(C.polys) do
            local v = t[1]
            local w
            if math.abs(PSS.distance(PREVIEW_SHAPE, v.x, v.y)) < 1e-6 then w = pv
            elseif math.abs(PSS.distance(REAL_SHAPE, v.x, v.y)) < 1e-6 then w = rw
            else stray = stray or ('(%.2f, %.2f) is on neither'):format(v.x, v.y) end
            if w then
                if w.n > 0 and w.alpha ~= t.a then stray = stray or 'a wall stripes' end
                w.alpha, w.n = t.a, w.n + 1
            end
        end
        return pv, rw, stray
    end

    -- On the bus, then live, gliding: the record arrives with the full priced hold.
    env.BR.State.storm = nil
    env.BR.State.match.state = MS.BUS
    env.BR.State.me.state    = PS.BUS
    env.BR.State.stormPreview = { cx = CCX, cy = CCY, r = CR }
    C.fire('br:env:world', false)
    C.pedAt = pt(0.0, 0.0, 400.0)
    C.settlePreview()
    env.BR.State.match.state = MS.PLAYING
    env.BR.State.me.state    = PS.GLIDE
    local rec0 = C.record(1, OCX, OCY, OR, CCX, CCY, CR, WAIT, SHRINK, 0.5)
    env.BR.State.stormPreview = nil
    C.fire(env.BR.Net.STORM_SYNC)
    C.tick(1)
    local T0 = rec0.tStart
    ok(C.last() and C.last().endsAt == T0 + WAIT,
        'the envelope carries the priced hold\'s end first',
        C.last() and tostring(C.last().endsAt))
    C.frame()
    local bp, br = walls()
    ok(bp.n > 0 and bp.alpha == PREV and br.n == 0,
        'and a gliding player at the new, earlier PLAYING has the preview wall at '
            .. 'previewAlpha and no real wall -- the bus\'s view, carried on',
        ('preview %d at %d, real %d'):format(bp.n, bp.alpha, br.n))

    -- ─── the cut lands a tenth of a second after the last envelope ───
    local pushes = #C.envelopes
    C.now = C.now + 100
    local cutWait = (C.now - T0) + CUT
    env.BR.State.storm = {
        phase = 1, seed = rec0.seed,
        cx0 = OCX, cy0 = OCY, r0 = OR, cx1 = CCX, cy1 = CCY, r1 = CR,
        tStart = T0, tWait = cutWait, tShrink = SHRINK, dps = 0.5,
    }
    C.fire(env.BR.Net.STORM_SYNC)
    C.now = C.now + 100
    env.BR.Loop.step(env.BR.Loop.TICK)
    ok(#C.envelopes == pushes + 1 and C.last().endsAt == T0 + cutWait,
        'and the first tick that solves the cut sends its endsAt, 200ms after the '
            .. 'last envelope rather than on the next 4 Hz beat',
        ('%d new envelopes, endsAt %s against %s'):format(#C.envelopes - pushes,
            tostring(C.last() and C.last().endsAt), tostring(T0 + cutWait)))

    -- ─── and the handoff follows the cut hold, frame by frame ───
    --
    -- The record is left alone from here and the CLOCK moves, which is how a match
    -- actually runs. `at(msLeft)` puts the frame's own solve exactly msLeft from the
    -- cut hold's end, counting the 16 ms C.frame adds.
    local cutEnd = T0 + cutWait
    local function at(msLeft)
        C.now = cutEnd - msLeft - 16
        C.frame()
        return walls()
    end
    local steps = {}
    for ms = CUT, FADE + 1, -2000 do steps[#steps + 1] = ms end
    for ms = FADE, 0, -250 do steps[#steps + 1] = ms end

    local empty, stray, nonMono, sumBad, inWindow = nil, nil, nil, nil, 0
    local lastP, lastR = PREV, 0
    for _, ms in ipairs(steps) do
        local pv, rw, s = at(ms)
        stray = stray or (s and ('at %d ms %s'):format(ms, s))
        if pv.n == 0 and rw.n == 0 then empty = empty or ms end
        if pv.alpha > lastP or rw.alpha < lastR then
            nonMono = nonMono or ('at %d ms preview %d->%d, real %d->%d')
                :format(ms, lastP, pv.alpha, lastR, rw.alpha)
        end
        if ms < FADE and ms > 0 then
            inWindow = inWindow + 1
            local sum = rw.alpha / FULL + pv.alpha / PREV
            if math.abs(sum - 1.0) > 1.0 / FULL + 1.0 / PREV then
                sumBad = sumBad or ('at %d ms the shares sum to %.4f'):format(ms, sum)
            end
        end
        lastP, lastR = pv.alpha, rw.alpha
    end
    local firstP, firstR = at(CUT)
    ok(firstP.alpha == PREV and firstR.n == 0 and empty == nil and stray == nil,
        'from the cut to the end of the hold there is a wall at every step, and the '
            .. 'preview is at previewAlpha until the fade window -- the cut moved nothing '
            .. 'on screen', stray or (empty and ('empty at %d ms'):format(empty)))
    ok(nonMono == nil and sumBad == nil and inWindow > 30,
        'and across the CUT hold\'s last fadeInSec the preview thins as the wall rises, '
            .. 'their shares summing to one: the one-clock handoff, on the new clock',
        nonMono or sumBad)
    local endP, endR = at(0)
    ok(endP.n == 0 and endR.alpha == FULL,
        'the handoff completes where the cut hold ends -- a minute and a half before '
            .. 'the priced one would have',
        ('preview %d tris, real at %d'):format(endP.n, endR.alpha))
    ok(C.errored() == nil, 'and runs clean', C.errored())
end

-- ---------------------------------------------------------------------------
describe('square.geometry')
do
    -- ═══ THE ROUNDED RECTANGLE, AND WHY ITS PROOF IS IN THIS FILE ═══
    --
    --   "The storm border does draw still, and everything is circular. Can you make
    --    the storms squircles instead to prove our new logic?"  -- owner, 2026-09-22
    --
    -- This file's header says the geometry of a shape belongs to test_shared.lua and
    -- that nothing here re-tests union2. The rounded rectangle is the exception and
    -- it is a deliberate one: the thing it exists FOR -- the map primitives, the
    -- squareness knob and the three rings that read them -- is client/storm.lua's and
    -- is asserted below. Splitting one shape's proof across two suites is how the two
    -- halves stop agreeing about what the shape is, and the signed distance is the
    -- half the other half is built on.
    --
    -- ═══ EVERY CLAIM HERE IS MEASURED AGAINST SOMETHING INDEPENDENT ═══
    --
    -- The suite has been green over a wall drawn 33 metres outside the boundary that
    -- damages, because the assertion sampled the quad CORNERS -- which
    -- pointAtComponent puts on the boundary by construction whatever the walk does
    -- between them (#336). So nothing below checks the closed form against itself:
    --
    --   * the PERIMETER is checked against 2*(hx-cr) + ... written out by hand, not
    --     against a sum of the piece lengths the constructor produced;
    --   * the SIGNED DISTANCE is checked against a brute-force sweep of the WALKED
    --     boundary -- pointAtArc, which knows nothing about `box` -- and separately
    --     for SIGN against the six-piece union predicate, which is a different
    --     formulation of the same shape;
    --   * the INSET is checked as distance(inset(s, m), p) == distance(s, p) - m,
    --     which is what exact erosion MEANS and is false for any approximation.
    local SS = newStormClient().env.BR.StormShape

    -- ── the piece list ─────────────────────────────────────────────────────
    local HX, HY, CR = 400.0, 260.0, 90.0
    local rr = SS.roundedRect(1200.0, -300.0, HX, HY, CR)

    local wantP = 2.0 * (2.0 * (HX - CR)) + 2.0 * (2.0 * (HY - CR))
        + 2.0 * math.pi * CR
    ok(#rr.pieces == 8 and near(SS.perimeter(rr), wantP, 1e-9),
        'four runs and four quarter arcs, and the perimeter is the four straight '
            .. 'spans plus one whole circle of the corner radius',
        ('%d pieces, P %.9f against %.9f'):format(#rr.pieces,
            SS.perimeter(rr), wantP))

    -- FOUR SEGS AND FOUR ARCS, IN THAT ALTERNATION. A shape that happened to emit
    -- eight pieces of the wrong kinds would satisfy the count above.
    local kinds = {}
    for i, pc in ipairs(rr.pieces) do kinds[i] = pc.kind end
    ok(table.concat(kinds, ',') == 'seg,arc,seg,arc,seg,arc,seg,arc',
        'alternating run and corner, starting on a run',
        table.concat(kinds, ','))

    -- ONE CLOSED LOOP. A rounded rectangle is convex; two components would mean the
    -- walk had been handed a shape with a hole or an island in it.
    ok(#SS.components(rr) == 1 and #SS.runs(rr, 1) == 8,
        'one component, and runs() hands out all eight pieces of it -- which is what '
            .. 'puts a wall vertex on every corner rather than a chord across it')

    -- ── the boundary closes, corner by corner ──────────────────────────────
    --
    -- ASKED FROM BOTH SIDES OF EVERY JOIN, which is the only way a walk can be
    -- caught bridging one. Piece i's far end and piece i+1's near start are two
    -- different reconstructions of one point -- an arc centre and a segment
    -- endpoint at each of the eight joins -- so a constructor that got a corner
    -- centre or a sweep wrong shows up here as a gap, and nowhere else.
    --
    -- THE NANOMETRE IS NOT A TOLERANCE, IT IS WHICH PIECE ANSWERS. pieceAtArc
    -- selects on `s < pc.s0 + pc.len`, so an s of exactly `pc.s0 + pc.len` is
    -- already piece i+1 at t = 0 -- which means asking for the join twice, once
    -- with the modulo and once without, asks the SAME piece both times and compares
    -- a point with itself. The first draft of this block did exactly that and
    -- survived a mutation that walked the top run backwards. Stepping back a
    -- nanometre is what puts the first read on piece i.
    local worstJoin = 0.0
    for i = 1, #rr.pieces do
        local pc = rr.pieces[i]
        local ax, ay = SS.pointAtArc(rr, pc.s0 + pc.len - 1e-9)
        local bx, by = SS.pointAtArc(rr, (pc.s0 + pc.len) % rr.P)
        local d = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
        if d > worstJoin then worstJoin = d end
    end
    ok(worstJoin < 1e-6,
        'every piece ends exactly where the next one begins, all eight joins',
        ('worst join gap %.12g m'):format(worstJoin))

    -- ═══ AND EVERY OUTWARD NORMAL REALLY POINTS OUT ═══
    --
    -- Interior on the LEFT is the convention the whole file rides on: the wall picks
    -- which face of each quad the viewer is shown from the tangent turned ninety
    -- degrees, so a run walked the wrong way round is a stretch of curtain that is
    -- invisible from outside and a hole from inside. THAT IS NOT A POSITION ERROR, so
    -- no comparison of points can see it -- a reversed run stands on the same two
    -- endpoints.
    --
    -- JUDGED WITH distance(), which is the independent formulation again: step half a
    -- metre along the reported normal and the signed distance must rise by half a
    -- metre; step against it and it must fall by the same. That pins three things at
    -- once -- the point is ON the boundary, the normal is a unit vector, and it points
    -- at the outside -- and it is false for a reversed run, a clockwise sweep or a
    -- normal off by any angle at all.
    local STEP = 0.5
    local worstOut, worstIn = 0.0, 0.0
    for i = 1, 2000 do
        local x, y, nx, ny = SS.pointAtArc(rr, rr.P * (i - 1) / 2000)
        local dOut = SS.distance(rr, x + nx * STEP, y + ny * STEP)
        local dIn = SS.distance(rr, x - nx * STEP, y - ny * STEP)
        if math.abs(dOut - STEP) > worstOut then worstOut = math.abs(dOut - STEP) end
        if math.abs(dIn + STEP) > worstIn then worstIn = math.abs(dIn + STEP) end
    end
    ok(worstOut < 1e-9 and worstIn < 1e-9,
        'half a metre along every outward normal is half a metre outside, and half a '
            .. 'metre against it is half a metre inside -- so the points are on the '
            .. 'boundary and the normals face the way the wall\'s winding assumes',
        ('worst out %.12g, worst in %.12g'):format(worstOut, worstIn))

    -- ── the signed distance, against a sweep of the walked boundary ────────
    --
    -- The brute force asks pointAtArc for 20000 boundary points and takes the
    -- nearest. That is an entirely different route to the answer from `box`: it goes
    -- through the piece list, the arcs' own centres and the segments' endpoints. A
    -- closed form that disagreed with the shape it claims to describe cannot hide
    -- between the two.
    local NSWEEP = 20000
    local bx, by = {}, {}
    for i = 1, NSWEEP do
        bx[i], by[i] = SS.pointAtArc(rr, rr.P * (i - 1) / NSWEEP)
    end
    local function nearestOnWalk(px, py)
        local best = math.huge
        for i = 1, NSWEEP do
            local d = (px - bx[i]) ^ 2 + (py - by[i]) ^ 2
            if d < best then best = d end
        end
        return math.sqrt(best)
    end

    -- THE INDEPENDENT CONTAINMENT TEST: the six-piece decomposition. A rounded
    -- rectangle is two crossed rectangles plus four corner discs, which is the
    -- picture the MAP deliberately does not draw -- and as a predicate it mentions
    -- none of distance()'s arithmetic, so it is a real second opinion about the sign.
    local IX, IY = HX - CR, HY - CR
    local function insideByPieces(px, py)
        local dx, dy = math.abs(px - 1200.0), math.abs(py + 300.0)
        if dx <= HX and dy <= IY then return true end
        if dx <= IX and dy <= HY then return true end
        local qx, qy = dx - IX, dy - IY
        return (qx * qx + qy * qy) <= CR * CR
    end

    -- The walk's own resolution is the floor on how well the two can agree: 20000
    -- points around a 2000m boundary is a tenth of a metre apart, so the brute force
    -- overstates by up to half of that near a corner. 0.05 is that bound, not a
    -- tolerance picked until it passed.
    local worstMag, worstAt, signBad, nOut, nIn, nEdge = 0.0, nil, 0, 0, 0, 0
    for gi = 0, 90 do
        for gj = 0, 90 do
            local px = 1200.0 - 700.0 + gi * (1400.0 / 90.0)
            local py = -300.0 - 560.0 + gj * (1120.0 / 90.0)
            local d = SS.distance(rr, px, py)
            -- THE SWEEP ANSWERS AN UNSIGNED DISTANCE -- it is the nearest boundary
            -- point and knows nothing about which side of it the sample is on -- so
            -- the magnitudes are what get compared and the SIGN is the separate
            -- assertion below, against a separate formulation. Comparing the signed
            -- value against an unsigned one would read every interior point as being
            -- wrong by twice its depth.
            local mag = math.abs(math.abs(d) - nearestOnWalk(px, py))
            if mag > worstMag then worstMag, worstAt = mag, { px, py } end
            local want = insideByPieces(px, py)
            -- The sign is only asked where the two formulations cannot disagree by
            -- rounding: a point within a millimetre of the boundary is on it.
            if math.abs(d) > 1e-3 then
                if (d < 0.0) ~= want then signBad = signBad + 1 end
                if want then nIn = nIn + 1 else nOut = nOut + 1 end
            else
                nEdge = nEdge + 1
            end
        end
    end
    ok(nIn > 500 and nOut > 500,
        'the grid actually straddles the boundary rather than sampling one side',
        ('%d inside, %d outside, %d on it'):format(nIn, nOut, nEdge))
    ok(signBad == 0,
        'the sign agrees with the six-piece union predicate at every sampled point '
            .. '-- a second formulation of the shape, not a rearrangement of this one',
        ('%d disagreements'):format(signBad))
    ok(worstMag < 0.05,
        'and the magnitude agrees with a brute-force sweep of the WALKED boundary, '
            .. 'inside and out, to the walk\'s own resolution',
        ('worst %.6f m at (%.1f, %.1f)'):format(worstMag,
            worstAt and worstAt[1] or 0, worstAt and worstAt[2] or 0))

    -- THE FOUR PLACES THE CLOSED FORM COULD BE WRONG BY A WHOLE REGION, pinned by
    -- hand so a failure names which one. A corner reads sqrt(2)*cr - cr outside its
    -- own arc centre; an edge reads the flat offset; the centre reads the nearest
    -- edge and NOT the nearest corner.
    ok(near(SS.distance(rr, 1200.0 + HX, -300.0), 0.0, 1e-9)
        and near(SS.distance(rr, 1200.0, -300.0 + HY), 0.0, 1e-9),
        'zero on the middle of both straight edges')
    ok(near(SS.distance(rr, 1200.0 + IX + CR / math.sqrt(2.0),
        -300.0 + IY + CR / math.sqrt(2.0)), 0.0, 1e-9),
        'zero on the 45-degree point of a corner arc, which is the one place a box '
            .. 'and a rounded box differ most')
    ok(near(SS.distance(rr, 1200.0, -300.0), -HY, 1e-9),
        'the centre is the NEARER half-extent deep, not the further one',
        tostring(SS.distance(rr, 1200.0, -300.0)))
    ok(near(SS.distance(rr, 1200.0 + HX + 37.0, -300.0), 37.0, 1e-9),
        'and straight out from an edge is the flat offset')

    -- ── a rounded rect whose corner radius IS its half-extent is a circle ──
    --
    -- The continuity the squareness knob rides on: at squareness 0 the shape the
    -- config would ask for is geometrically the circle the game has always drawn.
    -- Asserted as a distance field over a grid rather than as a perimeter, because
    -- two shapes can have the same perimeter and not be the same shape.
    local R = 520.0
    local circ = SS.circle(90.0, 40.0, R)
    local sq0 = SS.roundedRect(90.0, 40.0, R, R, R)
    local worstEq = 0.0
    for gi = 0, 80 do
        for gj = 0, 80 do
            local px, py = 90.0 - 800.0 + gi * 20.0, 40.0 - 800.0 + gj * 20.0
            local d = math.abs(SS.distance(circ, px, py) - SS.distance(sq0, px, py))
            if d > worstEq then worstEq = d end
        end
    end
    ok(worstEq == 0.0 and near(SS.perimeter(sq0), SS.perimeter(circ), 1e-9),
        'corner radius equal to the half-extent IS the circle, to the bit, in the '
            .. 'signed distance as well as the perimeter',
        ('worst delta %.17g'):format(worstEq))

    -- AND ITS PIECE LIST IS FOUR ARCS AND NO RUNS, WHICH IS THE REGRESSION. The
    -- four runs are zero length there, seg() answers nil for a run with no
    -- direction, and seal() reads its list with ipairs -- which STOPS AT THE FIRST
    -- NIL. Written as one eight-element table constructor this shape sealed to a
    -- boundary of ZERO pieces: no perimeter, no point at s, a wall that drew nothing
    -- while distance() went on answering correctly off the box. That is not a corner
    -- case -- it is every inset larger than the shape, which is the collapsed
    -- endgame plus render.edgeInset.
    ok(#sq0.pieces == 4 and SS.perimeter(sq0) > 0.0,
        'a degenerate rounded rect is four arcs and still has a perimeter -- a nil '
            .. 'run must not truncate the piece list',
        ('%d pieces, P %.6f'):format(#sq0.pieces, SS.perimeter(sq0)))

    -- ── the inset ──────────────────────────────────────────────────────────
    --
    -- EXACT, which is a stronger claim than the union's and is asserted as such:
    -- eroding by m moves the whole signed distance field by exactly m. The union
    -- case cannot pass this (it errs inward near the join, deliberately) and neither
    -- can any approximation of a rounded rect, so this assertion is the difference
    -- between "we shrank it" and "we eroded it".
    local M = 6.0
    local ins = SS.inset(rr, M)
    local worstIns = 0.0
    for gi = 0, 90 do
        for gj = 0, 90 do
            local px = 1200.0 - 700.0 + gi * (1400.0 / 90.0)
            local py = -300.0 - 560.0 + gj * (1120.0 / 90.0)
            -- PLUS M, NOT MINUS. Shrinking a shape moves every signed distance
            -- OUTWARD: a point that was 100 m inside is 94 m inside once the edge has
            -- come 6 m toward it, and a point outside is further out. The sign of this
            -- relation is the whole content of the assertion -- an inset written as a
            -- dilation would satisfy any comparison that got it the wrong way round.
            local d = math.abs((SS.distance(rr, px, py) + M)
                - SS.distance(ins, px, py))
            if d > worstIns then worstIns = d end
        end
    end
    ok(ins.kind == 'roundedRect' and worstIns < 1e-9,
        'an inset rounded rect is a rounded rect whose whole distance field has '
            .. 'moved by exactly the metres asked for',
        ('worst delta %.12g m'):format(worstIns))

    -- THE EDGE INSET THE WALL ACTUALLY PAYS, read off the live config rather than
    -- hard-coded, so a change to render.edgeInset cannot leave this passing about a
    -- number the game stopped using.
    local eInset = newStormClient().env.BR.Config.Storm.render.edgeInset
    local live = SS.inset(SS.roundedRect(0.0, 0.0, 950.0, 950.0, 400.0), eInset)
    ok(near(SS.distance(live, 950.0 - eInset, 0.0), 0.0, 1e-9),
        'the wall\'s own edgeInset puts the drawn edge exactly that far inside the '
            .. 'boundary that damages',
        ('inset %.1f m'):format(eInset))

    -- AN INSET LARGER THAN THE SHAPE LEAVES SOMETHING WALKABLE, for the reason
    -- MIN_RADIUS exists: a boundary with no length has no point at s, and the
    -- consumer that forgot would divide by zero in a per-frame draw call. The
    -- collapsed endgame reaches this every match.
    local eaten = SS.inset(SS.roundedRect(0.0, 0.0, 2.0, 2.0, 1.0), 40.0)
    ok(eaten.kind == 'roundedRect' and #eaten.pieces > 0
        and SS.perimeter(eaten) > 0.0,
        'an inset that eats the whole shape leaves a boundary that can still be '
            .. 'walked, not a shape with no length',
        ('%d pieces, P %.6f'):format(#eaten.pieces, SS.perimeter(eaten)))

    -- ── a kind with no implementation still errors ─────────────────────────
    --
    -- The whole point of dispatching on `kind`. A shape that quietly inherited the
    -- disc-union answer would read SHALLOWER than the truth, and the damage test
    -- reads the sign of it.
    local cap = SS.capsule(0.0, 0.0, 100.0, 0.0, 30.0)
    local okD = pcall(SS.distance, cap, 0.0, 0.0)
    local okI = pcall(SS.inset, cap, 6.0)
    local okM = pcall(SS.mapPrimitives, cap)
    ok(not okD and not okI and not okM,
        'a kind with no signed distance, erosion or map primitive errors on all '
            .. 'three rather than being answered as something else',
        ('distance %s, inset %s, mapPrimitives %s'):format(
            tostring(okD), tostring(okI), tostring(okM)))
    ok(pcall(SS.distance, rr, 0.0, 0.0) and pcall(SS.inset, rr, 1.0)
        and pcall(SS.distance, SS.union2(0, 0, 100, 150, 0, 100), 0, 0)
        and pcall(SS.distance, circ, 0, 0),
        'and every kind that does have one answers without throwing')
end

-- ---------------------------------------------------------------------------
describe('square.map')
do
    -- ═══ WHAT THE MAP IS HANDED, AND WHAT IT IS NOT ═══
    --
    -- mapPrimitives is the seam between a shape and the two filled primitives GTA's
    -- minimap has. Everything asserted here is about the DESCRIPTORS -- the client
    -- half is `square.off` and `square.on` below -- because the descriptor is where
    -- the decision lives: one box per component rather than the exact six pieces,
    -- which is a call about doubled alpha and not about geometry.
    local SS = newStormClient().env.BR.StormShape

    local c = SS.circle(300.0, -120.0, 950.0)
    local cp = SS.mapPrimitives(c)
    ok(#cp == 1 and cp[1].kind == 'radius'
        and cp[1].cx == 300.0 and cp[1].cy == -120.0 and cp[1].r == 950.0,
        'a circle is one radius descriptor carrying its own centre and radius -- '
            .. 'which is what makes squareness 0 the call it replaced',
        ('%d prims, %s'):format(#cp, cp[1] and cp[1].kind))

    local rp = SS.mapPrimitives(SS.roundedRect(10.0, 20.0, 400.0, 260.0, 90.0))
    ok(#rp == 1 and rp[1].kind == 'area'
        and rp[1].cx == 10.0 and rp[1].cy == 20.0
        and rp[1].w == 800.0 and rp[1].h == 520.0 and rp[1].rot == 0.0,
        'a rounded rect is ONE area descriptor, the FULL span in each axis, and an '
            .. 'explicit rotation of zero -- the native spins with the camera '
            .. 'without one',
        ('%d prims, w %s h %s rot %s'):format(#rp,
            tostring(rp[1].w), tostring(rp[1].h), tostring(rp[1].rot)))

    -- ONE, NOT SIX. The six-piece decomposition is exact and has regions of one, two
    -- and three overlapping fills -- and overlapping blip fills composite in
    -- creation order, which is what made the purple ring read as flashing when the
    -- blue disc was recreated over it. This assertion is the decision, so that
    -- putting the six back is a deliberate act with a red test in front of it.
    ok(#rp == 1,
        'and not the exact six-piece decomposition, which would band its own seams')

    -- THE BOX IS THE TIGHT BOUNDING BOX, over-reporting only at the corners and
    -- attained on all four edges. Measured against the WALKED boundary, so a box
    -- built off the wrong extents is caught either way round: too small clips the
    -- shape, too large is a ring further out than the zone.
    local rr = SS.roundedRect(10.0, 20.0, 400.0, 260.0, 90.0)
    local pr = rp[1]
    local halfW, halfH = pr.w * 0.5, pr.h * 0.5
    local outsideBox, maxX, maxY = 0, 0.0, 0.0
    for i = 1, 4000 do
        local px, py = SS.pointAtArc(rr, rr.P * (i - 1) / 4000)
        local dx, dy = math.abs(px - pr.cx), math.abs(py - pr.cy)
        if dx > halfW + 1e-9 or dy > halfH + 1e-9 then
            outsideBox = outsideBox + 1
        end
        if dx > maxX then maxX = dx end
        if dy > maxY then maxY = dy end
    end
    ok(outsideBox == 0 and near(maxX, halfW, 1e-6) and near(maxY, halfH, 1e-6),
        'the box contains the whole boundary and is touched by it on all four '
            .. 'sides -- generous at the corners by construction, tight everywhere '
            .. 'else',
        ('%d points outside, reach %.6f/%.6f against %.6f/%.6f'):format(
            outsideBox, maxX, maxY, halfW, halfH))

    -- A UNION OF TWO DISCS IS TWO RADIUS DESCRIPTORS, IN ARC ORDER. This is what
    -- ships today for a broken-out phase, and the order matters: blips draw in
    -- creation order, so the list IS the layering.
    local vp = SS.mapPrimitives(SS.union2(0.0, 0.0, 600.0, 900.0, 0.0, 500.0))
    ok(#vp == 2 and vp[1].kind == 'radius' and vp[2].kind == 'radius'
        and vp[1].r == 600.0 and vp[2].r == 500.0
        and vp[2].cx == 900.0,
        'an overlapping union is two radius descriptors in boundary order',
        ('%d prims'):format(#vp))
    local dp = SS.mapPrimitives(SS.union2(0.0, 0.0, 200.0, 2000.0, 0.0, 200.0))
    ok(#dp == 2, 'and so is a disjoint one -- two islands, two fills',
        ('%d prims'):format(#dp))
    -- THE NESTED CASE COLLAPSES TO ONE, because union2 returns the containing circle
    -- itself. That is nearly every phase, and it is why nothing on an ordinary phase
    -- draws a second ring.
    local np = SS.mapPrimitives(SS.union2(0.0, 0.0, 600.0, 50.0, 0.0, 100.0))
    ok(#np == 1 and np[1].r == 600.0,
        'a nested union is one descriptor: the containing circle, which is the shape')

    -- ═══ ONLY TWO KINDS EXIST, ACROSS EVERY SHAPE THE FILE CAN BUILD ═══
    --
    -- The materialiser in client/storm.lua spells exactly 'radius' and 'area' and
    -- draws nothing for anything else, deliberately -- a descriptor rendered as the
    -- nearer-looking primitive would be a ring in the wrong place. So a third kind
    -- has to be red HERE, before it can be silently undrawn there.
    local every = {
        SS.circle(0.0, 0.0, 100.0),
        SS.roundedRect(0.0, 0.0, 100.0, 80.0, 20.0),
        SS.roundedRect(0.0, 0.0, 100.0, 100.0, 100.0),
        SS.union2(0.0, 0.0, 600.0, 900.0, 0.0, 500.0),
        SS.union2(0.0, 0.0, 200.0, 2000.0, 0.0, 200.0),
        SS.union2(0.0, 0.0, 600.0, 50.0, 0.0, 100.0),
    }
    local strange = nil
    for _, sh in ipairs(every) do
        for _, p in ipairs(SS.mapPrimitives(sh)) do
            if p.kind ~= 'radius' and p.kind ~= 'area' then strange = p.kind end
        end
    end
    ok(strange == nil,
        'every shape the file can build emits only the two primitives the minimap '
            .. 'actually has',
        tostring(strange))

    -- FRESH TABLES. The answer is walked by the client and handed to natives; a
    -- caller that could write through it into the shape would be editing the
    -- geometry the damage test measures against.
    local sh = SS.circle(5.0, 6.0, 700.0)
    local a = SS.mapPrimitives(sh)
    a[1].r = -1.0
    a[1].kind = 'nonsense'
    local b = SS.mapPrimitives(sh)
    ok(b[1].r == 700.0 and b[1].kind == 'radius' and a ~= b,
        'and the list is a copy, so nothing can write back into the shape through it')
end

-- ---------------------------------------------------------------------------
describe('square.off')
do
    -- ═══ THE PROPERTY THAT MAKES THIS SHIPPABLE, AND IT IS MEASURED ═══
    --
    -- config/storm.lua ships squareness at 0, and at 0 the three rings must be the
    -- blips they were before mapPrimitives existed: the same native, the same
    -- centre, the same radius, the same color, the same alpha, the same legend
    -- entry. Asserted with `==` against the RECORD'S OWN NUMBERS and the live config,
    -- not against a second run of the same code -- a materialiser that dropped the
    -- alpha would pass any comparison of itself with itself.
    local C = newStormClient()
    local cfgS = C.env.BR.Config.Storm
    ok(cfgS.squareness == 0.0,
        'the knob ships at zero, so this is the shipping path and not a test-only one',
        tostring(cfgS.squareness))

    C.record(2, 400.0, -250.0, 1600.0, 900.0, -100.0, 950.0, 600000, 60000, 2.0)
    C.tick(2)

    ok(#C.boxes() == 0,
        'no area blip exists at all -- the box path is not merely unused, it is '
            .. 'unreached',
        ('%d boxes'):format(#C.boxes()))

    local cur, nxt
    for _, b in ipairs(C.rings()) do
        if b.r == 1600.0 then cur = b elseif b.r == 950.0 then nxt = b end
    end
    ok(#C.rings() == 2 and cur and nxt,
        'exactly two rings, one per circle, told apart by their radius',
        ('%d rings'):format(#C.rings()))
    ok(cur and cur.x == 400.0 and cur.y == -250.0 and cur.r == 1600.0
        and cur.colour == cfgS.blip.currentColour
        and cur.alpha == cfgS.blip.currentAlpha
        and cur.name == 'Safe Zone',
        'the current ring is the identical radiusBlip call: centre, radius, color, '
            .. 'alpha and legend entry, argument for argument',
        cur and ('(%s, %s) r %s color %s alpha %s %q'):format(cur.x, cur.y, cur.r,
            tostring(cur.colour), tostring(cur.alpha), tostring(cur.name)))
    ok(nxt and nxt.x == 900.0 and nxt.y == -100.0 and nxt.r == 950.0
        and nxt.colour == cfgS.blip.nextColour
        and nxt.alpha == cfgS.blip.nextAlpha
        and nxt.name == 'Next Safe Zone',
        'and so is the target ring, in the purple this game already means by "the '
            .. 'circle you are being asked to rotate to"',
        nxt and ('(%s, %s) r %s color %s alpha %s %q'):format(nxt.x, nxt.y, nxt.r,
            tostring(nxt.colour), tostring(nxt.alpha), tostring(nxt.name)))
    ok(cur and cur.hidden == nil and nxt and nxt.hidden == nil,
        'and neither is hidden on the legend -- a one-piece zone has nothing to hide')
    ok(C.errored() == nil, 'the map runs clean at squareness zero', C.errored())

    -- ═══ THE ONE NUMBER THAT MOVED, RECORDED RATHER THAN DISCOVERED ═══
    --
    -- BR.StormShape.circle floors its radius at MIN_RADIUS, so a zone that has closed
    -- BELOW a metre -- the last seconds of phase 8 -- now asks for a 1 m ring where
    -- the old call passed the raw sub-metre value. Both are invisible on a map where
    -- the whole city is a few hundred pixels, and the wall's own 'solid' path has
    -- floored its drawn radius the same way since 2026-08-03. It is asserted so that
    -- "byte for byte" is a measured claim with its one exception written down, rather
    -- than a phrase in a commit message.
    local D = newStormClient()
    D.record(8, 0.0, 0.0, 0.4, 0.0, 0.0, 0.0, 600000, 60000, 6.7)
    D.tick(2)
    local sub = D.rings()[1]
    ok(#D.rings() == 1 and sub and sub.r == 1.0,
        'a sub-metre zone draws at the MIN_RADIUS floor, which is the one argument '
            .. 'this change does not pass through unchanged',
        sub and tostring(sub.r))
end

-- ---------------------------------------------------------------------------
describe('square.on')
do
    -- ═══ WHAT TURNING THE KNOB ON ACTUALLY DRAWS ═══
    --
    -- The owner turns this on when he wants to look at it, so what he gets has to be
    -- known before he does. At squareness 0.5 each ring is ONE area blip spanning
    -- 2r by 2r, world-aligned, in the same color and alpha as the circle it
    -- replaced -- and no radius blip anywhere, because a zone drawn as both would be
    -- two overlapping fills and the doubled alpha this whole decomposition avoids.
    local C = newStormClient()
    local cfgS = C.env.BR.Config.Storm
    cfgS.squareness = 0.5
    C.record(2, 400.0, -250.0, 1600.0, 900.0, -100.0, 950.0, 600000, 60000, 2.0)
    C.tick(2)

    ok(#C.rings() == 0 and #C.boxes() == 2,
        'two boxes and no rings: one primitive per zone, not one of each',
        ('%d rings, %d boxes'):format(#C.rings(), #C.boxes()))

    local cur, nxt
    for _, b in ipairs(C.boxes()) do
        if b.w == 3200.0 then cur = b elseif b.w == 1900.0 then nxt = b end
    end
    ok(cur and cur.x == 400.0 and cur.y == -250.0
        and cur.w == 3200.0 and cur.h == 3200.0 and cur.rot == 0.0
        and cur.colour == cfgS.blip.currentColour
        and cur.alpha == cfgS.blip.currentAlpha
        and cur.name == 'Safe Zone',
        'the current zone is a 2r by 2r world-aligned box in the ring\'s own color, '
            .. 'alpha and legend entry',
        cur and ('(%s, %s) %sx%s rot %s'):format(cur.x, cur.y, cur.w, cur.h,
            tostring(cur.rot)))
    ok(nxt and nxt.w == 1900.0 and nxt.h == 1900.0 and nxt.rot == 0.0
        and nxt.name == 'Next Safe Zone',
        'and so is the target zone', nxt and tostring(nxt.w))
    ok(C.errored() == nil, 'the map runs clean at squareness 0.5', C.errored())

    -- THE CORNER RADIUS IS WHAT THE KNOB MOVES, AND THE BOX IS NOT. A box is the
    -- bounding box either way, so the map looks the same at 0.1 and at 1.0 -- said
    -- here because it is the first thing that will look like a bug when he dials it.
    -- What changes is the WALL and the damage boundary, which is #335's other half.
    local H = newStormClient()
    H.env.BR.Config.Storm.squareness = 1.0
    H.record(2, 0.0, 0.0, 500.0, 0.0, 0.0, 500.0, 600000, 60000, 2.0)
    H.tick(2)
    local hard = H.boxes()[1]
    ok(hard and hard.w == 1000.0 and hard.h == 1000.0,
        'a squareness of 1.0 draws the same bounding box a 0.1 does -- the dial '
            .. 'moves the corner radius, and the map box never had corners',
        hard and tostring(hard.w))
    local SS = H.env.BR.StormShape
    ok(SS.roundedRect(0, 0, 500, 500, 500 * (1.0 - 0.1)).box.cr == 450.0
        and SS.roundedRect(0, 0, 500, 500, 500 * (1.0 - 1.0)).box.cr == 1.0,
        'and the shape it moves is real: cr 450 at 0.1, floored to MIN_RADIUS at 1.0')

    -- ═══ THE MATERIALISER DOES NOT COUNT, AND THIS IS WHERE THAT IS PROVED ═══
    --
    -- Nothing in the game hands a multi-primitive shape to a ring today, so the
    -- branch that names the first piece and hides the rest would otherwise ship
    -- untested -- and it is the whole reason the descriptor list is a list. So the
    -- pure function the materialiser reads is replaced with one that answers TWO
    -- descriptors, which is exactly the seam the design says is the only thing that
    -- ever changes, and the live blip job is driven through it.
    local T = newStormClient()
    local realMap = T.env.BR.StormShape.mapPrimitives
    T.env.BR.StormShape.mapPrimitives = function(shape)
        local base = realMap(shape)
        if #base == 1 and base[1].kind == 'radius' then
            return {
                base[1],
                { kind = 'area', cx = base[1].cx + 10.0, cy = base[1].cy,
                  w = 40.0, h = 40.0, rot = 0.0 },
            }
        end
        return base
    end
    -- ONE ZONE ON THE MAP, WHICH IS WHAT MAKES THE COUNTS READABLE. A target radius
    -- of zero is the collapsed final phase, and the blip job draws no target ring for
    -- it (`rec.r1 > 1.0`) -- so every blip below belongs to the current zone and
    -- "one legend entry per zone" is a count rather than a grouping.
    T.record(2, 0.0, 0.0, 800.0, 0.0, 0.0, 0.0, 600000, 60000, 2.0)
    T.tick(2)
    local named, hidden = 0, 0
    for _, b in pairs(T.blips) do
        if b.exists and (b.kind == 'radius' or b.kind == 'area') then
            if b.name then named = named + 1 end
            if b.hidden then hidden = hidden + 1 end
        end
    end
    ok(#T.rings() == 1 and #T.boxes() == 1,
        'a two-descriptor zone becomes two blips, one of each kind, from the same '
            .. 'materialiser with nothing added to it',
        ('%d rings, %d boxes'):format(#T.rings(), #T.boxes()))
    ok(named == 1 and hidden == 1,
        'the first piece carries the legend entry and every other piece is hidden '
            .. 'from it -- one row per zone, not one per primitive',
        ('%d named, %d hidden'):format(named, hidden))
    ok(T.errored() == nil, 'and a multi-primitive zone runs clean', T.errored())

    -- AND A SHAPE THAT SHRINKS BACK TO ONE PRIMITIVE TAKES ITS SURPLUS BLIP WITH IT.
    -- A handle list that kept growing would leave dead fills on the map for the rest
    -- of the match, which is the failure mode the old "create the target ring once"
    -- bug had in the other direction.
    T.env.BR.StormShape.mapPrimitives = realMap
    T.record(2, 0.0, 0.0, 700.0, 0.0, 0.0, 0.0, 600000, 60000, 2.0)
    T.tick(3)
    ok(#T.boxes() == 0 and #T.rings() == 1,
        'and dropping back to one descriptor removes the surplus blip rather than '
            .. 'leaving it on the map',
        ('%d rings, %d boxes'):format(#T.rings(), #T.boxes()))

    -- ═══ A ZONE IS INTACT ONLY IF EVERY PIECE OF IT IS ═══
    --
    -- The preview ring is the one blip in this file whose rebuild is gated on
    -- EXISTENCE rather than on a cadence -- it never moves and never resizes, so it
    -- is created once and only re-asserted when the handle has stopped existing
    -- (engine blip handles are recycled, so another system removing a stale one can
    -- delete ours: a live "no blip at all in squads" report). A multi-piece zone
    -- makes that check a question about ALL of them, and asking about the first only
    -- would leave a zone drawn with a hole in it and heal nothing, because the
    -- re-assert is gated on the answer.
    --
    -- DRIVEN THROUGH THE SAME SEAM, and the SECOND piece is the one destroyed --
    -- destroying the first would pass either spelling.
    local P = newStormClient()
    local pEnv = P.env
    local pReal = pEnv.BR.StormShape.mapPrimitives
    pEnv.BR.StormShape.mapPrimitives = function(shape)
        local base = pReal(shape)
        if #base == 1 and base[1].kind == 'radius' then
            return {
                base[1],
                { kind = 'area', cx = base[1].cx, cy = base[1].cy,
                  w = 20.0, h = 20.0, rot = 0.0 },
            }
        end
        return base
    end
    pEnv.BR.State.storm = nil
    pEnv.BR.State.match.state = pEnv.BR.MatchState.WARMUP
    pEnv.BR.State.me.state    = pEnv.BR.PlayerState.WARMUP
    pEnv.BR.State.stormPreview = { cx = 0.0, cy = 0.0, r = 2600.0 }
    P.tick(2)
    ok(#P.rings() == 1 and #P.boxes() == 1,
        'the preview zone is drawn as both of its pieces')

    local box = P.boxes()[1]
    local boxHandle = nil
    for h, b in pairs(P.blips) do if b == box then boxHandle = h end end
    pEnv.RemoveBlip(boxHandle)
    ok(#P.boxes() == 0, 'something else has deleted the second piece of it')
    P.tick(2)
    ok(#P.rings() == 1 and #P.boxes() == 1,
        'and the next tick puts the whole zone back -- the existence check asks '
            .. 'about every piece, not about the first one it finds',
        ('%d rings, %d boxes'):format(#P.rings(), #P.boxes()))

    -- ═══ AND A ZONE THAT DREW NOTHING MUST NOT LATCH ═══
    --
    -- The materialiser draws only the two primitives the minimap has and nothing for
    -- anything else, so a descriptor it does not recognise produces no handles at all.
    -- Handing back an empty LIST there would be worse than handing back nothing: an
    -- empty table is truthy, so the callers' `or not curBlip` retry would stop being a
    -- retry and the zone would have no ring on it for the rest of the match -- the
    -- missing-blip failure this file has already had once, rebuilt out of the fix.
    local N = newStormClient()
    local nReal = N.env.BR.StormShape.mapPrimitives
    N.env.BR.StormShape.mapPrimitives = function()
        return { { kind = 'something the minimap has not got' } }
    end
    N.record(2, 0.0, 0.0, 900.0, 0.0, 0.0, 0.0, 600000, 60000, 2.0)
    N.tick(2)
    ok(#N.rings() == 0 and #N.boxes() == 0 and N.errored() == nil,
        'an unrecognised descriptor draws nothing and throws nothing')
    N.env.BR.StormShape.mapPrimitives = nReal
    N.tick(2)
    ok(#N.rings() == 1,
        'and the zone comes back on the next cadence rather than staying empty -- '
            .. 'nothing drawn is nil, not an empty list',
        ('%d rings'):format(#N.rings()))

    -- ═══ AND HALF A ZONE IS WORSE THAN NONE OF IT ═══
    --
    -- A ring is read as the edge, so a zone drawn with one of its pieces missing is a
    -- boundary in the WRONG PLACE rather than a missing one. This starts from a zone
    -- that IS on the map -- so the assertion is about the old handle being torn down
    -- too, not merely about the new one not appearing -- and then asks for one good
    -- descriptor and one the minimap has not got.
    ok(#N.rings() == 1, 'a whole zone is on the map to begin with')
    N.env.BR.StormShape.mapPrimitives = function(shape)
        local base = nReal(shape)
        return { base[1], { kind = 'still not a primitive' } }
    end
    -- A radius move past the one-metre threshold is what asks the blip job to rebuild.
    N.record(2, 0.0, 0.0, 600.0, 0.0, 0.0, 0.0, 600000, 60000, 2.0)
    N.tick(2)
    ok(#N.rings() == 0 and #N.boxes() == 0,
        'a zone that can only be drawn in part is drawn not at all, and the blip it '
            .. 'replaced goes with it rather than staying on the map as a boundary in '
            .. 'the wrong place',
        ('%d rings, %d boxes'):format(#N.rings(), #N.boxes()))
    ok(N.errored() == nil, 'and a partial zone throws nothing', N.errored())

    -- AND THE PIECE THAT IS NO LONGER ASKED FOR GOES TOO, which is a different
    -- handle from the one that failed. Starting from a zone that really is two blips,
    -- the SECOND descriptor then stops being drawable -- so slot 2's old handle was
    -- never handed to a wrapper and nothing but this cleanup will take it off the map.
    -- Without it the player is left looking at a lone box with no ring, which is the
    -- wrong-place boundary again wearing the other shape.
    N.env.BR.StormShape.mapPrimitives = function(shape)
        local base = nReal(shape)
        return {
            base[1],
            { kind = 'area', cx = base[1].cx, cy = base[1].cy,
              w = 30.0, h = 30.0, rot = 0.0 },
        }
    end
    N.record(2, 0.0, 0.0, 500.0, 0.0, 0.0, 0.0, 600000, 60000, 2.0)
    N.tick(2)
    ok(#N.rings() == 1 and #N.boxes() == 1,
        'a two-piece zone is on the map to begin with',
        ('%d rings, %d boxes'):format(#N.rings(), #N.boxes()))
    N.env.BR.StormShape.mapPrimitives = function(shape)
        local base = nReal(shape)
        return { base[1], { kind = 'gone from the primitive list' } }
    end
    N.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 0.0, 600000, 60000, 2.0)
    N.tick(2)
    ok(#N.rings() == 0 and #N.boxes() == 0,
        'and losing the second piece takes the second piece\'s own blip off the map, '
            .. 'not just the one the failure was on',
        ('%d rings, %d boxes'):format(#N.rings(), #N.boxes()))
end

-- ---------------------------------------------------------------------------
describe('square.native')
do
    -- ═══ THE REAL BR.Native.areaBlip, NOT THE HARNESS STUB ═══
    --
    -- Every block above drives the stub, which is right for asserting what the storm
    -- ASKED FOR. This one loads the real client/natives.lua and asserts the call
    -- SEQUENCE, because two of the three things that can be wrong about an area blip
    -- are in that sequence rather than in the arguments: a missing SET_BLIP_ROTATION
    -- leaves the box spinning with the camera (the native's own doc says so), and a
    -- bare DoesBlipExist deletes a recycled handle that belongs to somebody else.
    local env = newSandbox()
    local L = {}
    env.AddBlipForArea = function(x, y, z, w, h)
        L[#L + 1] = { 'AddBlipForArea', x, y, z, w, h }
        return 41
    end
    env.AddBlipForRadius = function() return 42 end
    env.SetBlipRotation = function(b, r)
        L[#L + 1] = { 'SetBlipRotation', b, r, math.type(r) }
    end
    env.SetBlipColour   = function(b, c) L[#L + 1] = { 'SetBlipColour', b, c } end
    env.SetBlipAlpha    = function(b, a) L[#L + 1] = { 'SetBlipAlpha', b, a } end
    env.SetBlipHighDetail = function(b, v)
        L[#L + 1] = { 'SetBlipHighDetail', b, v }
    end
    env.SetBlipHiddenOnLegend = function(b, v)
        L[#L + 1] = { 'SetBlipHiddenOnLegend', b, v }
    end
    env.RemoveBlip = function(b) L[#L + 1] = { 'RemoveBlip', b } end
    -- ZERO FOR "NO", WHICH IS THE WHOLE POINT OF THIS BLOCK. A FiveM native declared
    -- BOOL may answer 1/0, and 0 IS TRUTHY IN LUA. tools/check_bool_natives.lua
    -- counts the bare reads in this file and has caught this exact native here
    -- before; this asserts the consequence rather than the spelling.
    env.DoesBlipExist = function() return 0 end
    env.BeginTextCommandSetBlipName = function() end
    env.AddTextComponentString = function(s) L[#L + 1] = { 'name', s } end
    env.EndTextCommandSetBlipName = function() end
    env.RegisterCommand = function() end
    env.AddEventHandler = function() end
    env.Citizen = { CreateThread = function() end, Wait = function() end,
                    SetTimeout = function() end }
    loadInto(env, { 'br_lib/shared/enums.lua', 'br_core/client/natives.lua' })

    ok(type(env.BR.Native.areaBlip) == 'function'
        and type(env.BR.Native.blipHiddenOnLegend) == 'function',
        'the real natives file exposes both new wrappers')

    local h = env.BR.Native.areaBlip(99, 10.0, 20.0, 400.0, 300.0, 0.0,
        3, 80, 'Safe Zone')
    local seq = {}
    for i, e in ipairs(L) do seq[i] = e[1] end
    ok(table.concat(seq, ',') ==
        'AddBlipForArea,SetBlipRotation,SetBlipColour,SetBlipAlpha,'
        .. 'SetBlipHighDetail,name',
        'the box is created, then stopped from spinning, then colored, faded and '
            .. 'named -- in that order and with nothing missing',
        table.concat(seq, ','))
    ok(h == 41 and L[1][2] == 10.0 and L[1][3] == 20.0 and L[1][4] == 0.0
        and L[1][5] == 400.0 and L[1][6] == 300.0,
        'and it is handed the centre, a z of zero, and the FULL width and height',
        ('(%s, %s, %s) %sx%s'):format(tostring(L[1][2]), tostring(L[1][3]),
            tostring(L[1][4]), tostring(L[1][5]), tostring(L[1][6])))

    -- SET_BLIP_ROTATION TAKES AN INT. The float spelling is a different native
    -- (_SET_BLIP_SQUARED_ROTATION), so passing a float here is passing the wrong
    -- type to the right hash.
    ok(L[2][2] == 41 and L[2][3] == 0 and L[2][4] == 'integer',
        'the rotation is an integer, because SET_BLIP_ROTATION is the int native '
            .. 'and the float one is a different hash',
        ('%s (%s)'):format(tostring(L[2][3]), tostring(L[2][4])))

    -- THE RATCHET'S OWN BUG, ASSERTED AS A CONSEQUENCE. DoesBlipExist answered 0 --
    -- "this handle is gone" -- so nothing may be removed. Read bare, 0 is truthy and
    -- this would remove handle 99, which the engine has already recycled to somebody
    -- else's blip.
    local removed = false
    for _, e in ipairs(L) do if e[1] == 'RemoveBlip' then removed = true end end
    ok(not removed,
        'a previous handle the engine says is GONE is not removed -- 0 means no, and '
            .. '0 is truthy in Lua',
        removed and 'RemoveBlip was called on a dead handle' or nil)

    -- AND THE LEGEND WRAPPER REFUSES A DEAD HANDLE THE SAME WAY, for the same
    -- reason: SetBlipHiddenOnLegend on a recycled handle hides somebody else's blip
    -- from the pause menu.
    local before = #L
    env.BR.Native.blipHiddenOnLegend(41, true)
    ok(#L == before,
        'and hiding a dead handle on the legend does nothing at all')

    -- WITH A LIVE HANDLE IT DOES BOTH THINGS. Otherwise the two assertions above
    -- would pass on a wrapper that simply never calls anything.
    env.DoesBlipExist = function() return 1 end
    L = {}
    env.BR.Native.areaBlip(41, 0.0, 0.0, 10.0, 10.0, 90.0, 3, 80, nil)
    local seq2 = {}
    for i, e in ipairs(L) do seq2[i] = e[1] end
    ok(seq2[1] == 'RemoveBlip' and L[1][2] == 41,
        'a LIVE previous handle is removed first, because an area blip cannot be '
            .. 'resized in place either',
        table.concat(seq2, ','))
    L = {}
    env.BR.Native.blipHiddenOnLegend(41, true)
    ok(#L == 1 and L[1][1] == 'SetBlipHiddenOnLegend' and L[1][2] == 41
        and L[1][3] == true,
        'and a live handle really is hidden',
        ('%d calls'):format(#L))

    -- ASKED WITH A TRUTHY NON-BOOLEAN, which is the only version of this assertion
    -- that can fail. Handed `true` both the guarded and the unguarded spelling pass
    -- it on unchanged, so the first draft of this block proved nothing: it survived a
    -- mutation that dropped the normalisation entirely. A FiveM BOOL parameter is not
    -- a Lua truth test, and `1` is exactly the shape a caller reading another
    -- native's answer would arrive with.
    L = {}
    env.BR.Native.blipHiddenOnLegend(41, 1)
    ok(#L == 1 and L[1][3] == true,
        'and a TRUTHY NON-BOOLEAN is normalised to a real boolean before it reaches '
            .. 'the native, rather than handed on as a 1',
        ('passed %s (%s)'):format(tostring(L[1] and L[1][3]),
            type(L[1] and L[1][3])))
    L = {}
    env.BR.Native.blipHiddenOnLegend(41, nil)
    ok(#L == 1 and L[1][3] == false,
        'and so is the other direction -- nil asks for "not hidden", not for nothing',
        ('passed %s (%s)'):format(tostring(L[1] and L[1][3]),
            type(L[1] and L[1][3])))
end

-- ---------------------------------------------------------------------------
describe('map.overlay')
do
    -- ═══ THE MAP DRAWS THE REAL SHAPE, AND EXACTLY ONE PATH DRAWS IT (#350) ═══
    --
    --   "seems every storm is still a circle."            -- owner, 2026-09-22
    --
    -- The wall has been a blob since #344 and the map was a radius blip at `r`, which
    -- is where the whole feature is visible: at phase 1 the nine corners are 1815 m
    -- apart along the boundary, so a player on the ground sees a stretch that reads
    -- as an arc of a circle. #347 proved ADD_AREA_OVERLAY fills an arbitrary polygon
    -- on the radar AND the pause map, so the two zones are filled boundaries now.
    --
    -- ═══ WHAT THIS BLOCK IS FOR IS THE SWITCH, NOT THE POLYGON ═══
    --
    -- The polygon is `shape.polyline`'s subject in tools/test_shared.lua, proved
    -- against its sag bound, its run boundaries and the region it encloses. What can
    -- only be tested HERE is the pair of paths: that the fill replaces the blips
    -- rather than joining them, that a refusal anywhere puts the blips back, and that
    -- the suppression rules and the fade clock the rings obey are the ones the fills
    -- obey -- because those are two spellings away from being two behaviours.
    -- A SEED WHOSE CURRENT ZONE IS A POLYGON, because one zone in ten is a plain
    -- circle now and "the fill is not a circle" is the assertion below. The first
    -- such seed, found rather than typed, so a retune of the odds moves it with them.
    local function mapClient(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs)
        local C = newStormClient()
        C.mm.handle = 7
        C.pedAt = pt(0.0, 0.0)
        local rec = C.record(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs, 2.0)
        local s = 1
        while C.env.BR.StormUnit(s, phase - 1).kind ~= 'polygon' do s = s + 1 end
        rec.seed = s
        return C
    end

    -- ─── before the gate opens, the blips carry the map ───
    --
    -- THIS IS THE ORDER THE GAME ALWAYS PLAYS IN. The gate deliberately waits out
    -- three seconds of session plus ten consenting passes, so every match starts with
    -- the rings and swaps to the fills a few seconds in. A first tick that drew
    -- nothing at all would be a map with no safe zone on it for that whole stretch.
    local C = mapClient(2, 0.0, 0.0, 800.0, 300.0, 0.0, 400.0, 600000, 60000)
    C.tick(1)
    ok(#C.areas() == 0 and #C.rings() > 0,
        'before the readiness gate opens the map is radius blips and no fill at all',
        ('%d areas, %d rings'):format(#C.areas(), #C.rings()))

    ok(C.overlayReady(), 'the gate opens once the session has settled')
    C.tick(2)
    ok(C.errored() == nil, 'and the map callback runs clean', C.errored())

    -- ─── and then exactly one of the two paths is drawing ───
    ok(#C.areas() == 2,
        'a nested phase fills TWO areas: the safe zone and the target inside it, '
            .. 'which is the pair the two rings were',
        ('%d areas'):format(#C.areas()))
    ok(#C.rings() == 0 and #C.boxes() == 0,
        'and NOT ONE radius blip is left beside them -- a fill and a disc of the '
            .. 'same zone would be two boundaries, and a player reads the nearer',
        ('%d rings, %d boxes'):format(#C.rings(), #C.boxes()))

    -- ─── the fill is on the real boundary, and the real boundary is not a circle ───
    --
    -- MEASURED AGAINST BR.StormZone, which is what the WALL draws -- so this is also
    -- the assertion that the map and the curtain cannot disagree about the edge. And
    -- the radial spread is what makes it a test of #350 rather than of the plumbing:
    -- every point of a CIRCLE is the same distance from the centre, so a fill that
    -- had quietly kept drawing one would pass the first measure and fail this.
    --
    -- READ OFF C.shown, WHICH IS WHERE THE MOVIE PUTS IT, and not off the points that
    -- were pushed. Since #350 a one-blob zone goes out about its own centre and is
    -- then placed, so the pushed points are not world coordinates at all -- and this
    -- zone happens to be centred on the origin, where the two readings agree. The
    -- assertion has to be about what the map shows or it would pass over a zone that
    -- was never placed.
    local SS = C.env.BR.StormShape
    local rec = C.env.BR.State.storm
    local zone = C.env.BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0)
    local worstOff, lo, hi = 0.0, math.huge, 0.0
    local shownPts = C.areas()[1] and C.shown(C.areas()[1]) or {}
    for _, p in ipairs(shownPts) do
        local d = math.abs(SS.distance(zone, p.x, p.y))
        if d > worstOff then worstOff = d end
        local rad = math.sqrt((p.x - rec.cx0) ^ 2 + (p.y - rec.cy0) ^ 2)
        lo, hi = math.min(lo, rad), math.max(hi, rad)
    end
    ok(#shownPts >= 3 and worstOff < 1e-6,
        'every point of the fill is ON the zone the wall is drawn on, to a micron',
        ('%d points, worst %.9f m off'):format(#shownPts, worstOff))
    ok((hi - lo) > 1.0,
        'and the boundary is genuinely not a circle: its distance from the centre '
            .. 'varies with the bearing, which is the whole of what #350 is about',
        ('radius runs %.1f to %.1f m'):format(lo, hi))

    -- ─── the colour and the alpha ───
    --
    -- THE ALPHA IS THE ONE PIECE OF ARITHMETIC ON THIS PATH THAT IS NOT OBVIOUS. The
    -- movie sets `mc._alpha = a / 255 * 100` AND passes the same `a` to beginFill as a
    -- Flash 0-100 alpha, so below 100 the two COMPOUND and a = 50 renders near 10%.
    -- The fills are asked for at the alphas the blips use, so 80 has to be inverted
    -- through areaAlpha rather than passed through -- otherwise the safe zone reads a
    -- third fainter than the disc it replaced.
    local blip = C.env.BR.Config.Storm.blip
    local col  = C.env.BR.Config.Storm.render.colour
    local MO   = C.env.BR.MapOverlay
    local zf, tf = C.areas()[1], C.areas()[2]
    ok(zf.r == col.r and zf.g == col.g and zf.b == col.b
        and tf.r == col.r and tf.g == col.g and tf.b == col.b,
        'both fills are the wall\'s own purple out of render.colour',
        ('%d,%d,%d'):format(zf.r, zf.g, zf.b))
    ok(zf.a == MO.areaAlpha(blip.currentAlpha)
        and tf.a == MO.areaAlpha(blip.nextAlpha),
        'at the two blip alphas, each inverted through the movie\'s compounding',
        ('%d and %d from %d and %d'):format(zf.a, tf.a,
            blip.currentAlpha, blip.nextAlpha))
    ok(zf.a ~= blip.currentAlpha and zf.a > blip.currentAlpha,
        'and the inversion really moved the safe zone\'s alpha -- 80 is inside the '
            .. 'compounding region, so passing it through would draw a third faint',
        ('%d from %d'):format(zf.a, blip.currentAlpha))
    ok(MO.areaAlpha(110) == 110 and MO.areaAlpha(255) == 255,
        'while an alpha at or above 100 is already linear and is passed through')
    ok(MO.areaAlpha(80) == 89,
        'the inverse is 10 * sqrt(want): 80 of 255 comes back as 89, which renders '
            .. '(89/255) * (89/100) = the 80/255 that was asked for',
        tostring(MO.areaAlpha(80)))
    ok(MO.areaAlpha(-5) == 0 and MO.areaAlpha(400) == 255,
        'and it is clamped at both ends')

    -- ─── the target is drawn LAST, so it is on top ───
    --
    -- The movie renders its clips in push order, which is why the two rings were
    -- recreated in a fixed order too: the purple target read as flashing on the map
    -- when the safe zone's rebuild landed on top of it.
    local tr = 0.0
    for _, p in ipairs(tf.points) do
        tr = math.max(tr, math.sqrt((p.x - rec.cx1) ^ 2 + (p.y - rec.cy1) ^ 2))
    end
    ok(tr < rec.r0 and tr > rec.r1 * 0.5,
        'the second fill is the TARGET, pushed after the zone so it draws over it',
        ('reaches %.0f m from the target centre, target r %.0f'):format(tr, rec.r1))

    -- ─── the phase-1 hold shows the target ONLY, on the wall's own clock ───
    --
    -- The safe zone during the phase-1 hold is the whole map, and a purple wash over
    -- all of Los Santos says nothing -- which is exactly why the blue ring is
    -- suppressed there. The fill obeys the same rule from the same number: wallShare,
    -- which is also what the curtain and the ring read. THIS IS THE ASSERTION A
    -- SECOND SPELLING OF THE FADE WOULD FAIL.
    local H = mapClient(1, 0.0, 0.0, 6000.0, 400.0, 0.0, 2600.0, 120000, 120000)
    ok(H.overlayReady(), 'a phase-1 client reaches the gate too')
    local FADE = (H.env.BR.Config.Storm.render.fadeInSec or 10.0) * 1000.0
    local function holdFills(C2, msLeft)
        C2.env.BR.State.storm.tStart = (C2.now + 1500) - (120000 - msLeft)
        C2.tick(1)
        return C2.areas()
    end
    local deep = holdFills(H, 60000)
    ok(#deep == 1,
        'deep in the phase-1 hold only circle 1 is filled -- the whole-map safe zone '
            .. 'is suppressed exactly as its ring is',
        ('%d area(s)'):format(#deep))

    local inFade = holdFills(H, FADE * 0.5)
    ok(#inFade == 2,
        'and inside the fade window the safe zone arrives, on the same countdown the '
            .. 'curtain uses',
        ('%d area(s)'):format(#inFade))
    local zoneA = nil
    for _, ar in ipairs(inFade) do
        if ar.a ~= MO.areaAlpha(blip.nextAlpha) then zoneA = ar.a end
    end
    ok(zoneA ~= nil and zoneA < MO.areaAlpha(blip.currentAlpha) and zoneA > 0,
        'at part strength rather than at full, so it fades in instead of popping',
        ('%s against %d at full'):format(tostring(zoneA),
            MO.areaAlpha(blip.currentAlpha)))

    -- ─── a disjoint breakout is one fill per island ───
    --
    -- ONE ADD_AREA_OVERLAY PER CONTOUR, because a single filled polygon cannot be two
    -- islands -- and since #356 an OVERLAPPING pair is one contour, so the count is
    -- the honest question about which case the zone is in.
    local D = mapClient(4, 0.0, 0.0, 950.0, 2400.0, 0.0, 260.0, 600000, 60000)
    ok(D.overlayReady() and D.errored() == nil, 'a disjoint breakout reaches the gate')
    D.tick(2)
    ok(#D.areas() == 3,
        'a disjoint zone is two fills, plus the target: one call per contour',
        ('%d areas'):format(#D.areas()))

    local V = mapClient(4, 0.0, 0.0, 950.0, 1100.0, 0.0, 520.0, 600000, 60000)
    ok(V.overlayReady() and V.errored() == nil, 'an overlapping breakout too')
    V.tick(2)
    ok(#V.areas() == 2,
        'while an OVERLAPPING zone is ONE fill for the pair -- which is #356 arriving '
            .. 'on the map, and is why the lens does not read darker than the rest',
        ('%d areas'):format(#V.areas()))

    -- ─── a refused push is torn down whole, and the blips come back ───
    --
    -- HALF A ZONE IS WORSE THAN NONE OF IT: a fill that is missing a contour is a
    -- boundary in the wrong place rather than a missing one. So a refusal takes the
    -- whole push down and mapFilled() goes false, which is what hands the map back to
    -- the rings -- the two paths being one switch is what makes that automatic.
    local R = mapClient(4, 0.0, 0.0, 950.0, 2400.0, 0.0, 260.0, 600000, 60000)
    ok(R.overlayReady(), 'the refusal client reaches the gate')
    R.tick(2)
    ok(#R.areas() == 3 and #R.rings() == 0, 'and is filling before the refusal',
        ('%d areas, %d rings'):format(#R.areas(), #R.rings()))
    R.mm.refuseAdd = true
    R.env.BR.State.storm.r0 = 900.0          -- move it, so a rebuild is due
    R.tick(3)
    ok(#R.areas() == 0,
        'a refused ADD leaves NOTHING of the fill behind, not the contours that '
            .. 'happened to get through',
        ('%d areas'):format(#R.areas()))
    ok(#R.rings() > 0,
        'and the radius blips take the map back on their own next cadence -- the '
            .. 'fallback is the same switch, not a second code path',
        ('%d rings'):format(#R.rings()))
    R.mm.refuseAdd = false
    R.env.BR.State.storm.r0 = 880.0
    R.tick(3)
    ok(#R.areas() == 3 and #R.rings() == 0,
        'and when the engine stops refusing, the fill comes back and the blips go',
        ('%d areas, %d rings'):format(#R.areas(), #R.rings()))

    -- ─── and a PARTIAL push is the case the rule is actually for ───
    --
    -- Every add refused leaves nothing to tear down, so it cannot tell a teardown from
    -- a no-op. This lets the FIRST contour through and refuses the rest: the movie
    -- holds one island of a two-island zone at the moment the second is declined, and
    -- what must be on the map afterwards is NOTHING -- one island is a boundary in the
    -- wrong place, and the blips draw the whole thing instead.
    R.mm.allowAdds = R.mm.adds + 1
    R.env.BR.State.storm.r0 = 860.0
    R.tick(3)
    ok(#R.areas() == 0,
        'a push that got PART of the way through is torn down whole -- the contour '
            .. 'that succeeded does not stay on the map on its own',
        ('%d areas'):format(#R.areas()))
    ok(#R.rings() > 0,
        'and the blips take it back, so the player sees a whole zone either way',
        ('%d rings'):format(#R.rings()))
    R.mm.allowAdds = nil

    -- ─── the rebuild is rate-limited, and keyed on the geometry ───
    --
    -- An area cannot be resized in place, so every change is every clip removed and
    -- every clip re-added with a kilobyte of coordinates marshalled through a
    -- Scaleform string. A rebuild per tick on a zone that has not moved would be that
    -- cost for nothing, all match.
    local S = mapClient(2, 0.0, 0.0, 800.0, 300.0, 0.0, 400.0, 600000, 60000)
    ok(S.overlayReady(), 'the cadence client reaches the gate')
    S.tick(2)
    local before = S.areas()[1]

    -- AND NOT EVEN WALKED. The rebuild test is keyed on the INPUTS so that a tick on
    -- which nothing moved costs a few comparisons, not a boundary walk per contour
    -- that is then thrown away -- which is what building the contours first and
    -- deciding afterwards would be, ten times a second, all match. Counted at
    -- polyline, the one thing every contour on this path is walked through.
    local realPolyline = S.env.BR.StormShape.polyline
    local walks = 0
    S.env.BR.StormShape.polyline = function(...)
        walks = walks + 1
        return realPolyline(...)
    end
    local callsHeld = S.mm.calls
    S.tick(12)
    S.env.BR.StormShape.polyline = realPolyline
    ok(S.areas()[1] == before,
        'a zone that has not moved is not rebuilt, however many ticks pass -- the '
            .. 'same table is still in the movie',
        S.areas()[1] == before and 'same' or 'replaced')
    ok(walks == 0,
        'and its boundary is not even walked on those ticks -- the plan is compared '
            .. 'before any contour is built',
        ('%d walks in 12 ticks'):format(walks))
    ok(S.mm.calls == callsHeld,
        'and the movie is not called at all while it holds -- not a rebuild, not a '
            .. 'placement',
        ('%d method calls in 12 ticks'):format(S.mm.calls - callsHeld))

    -- A ONE-BLOB ZONE THAT HAS MOVED IS PLACED, NOT REBUILT (#350). This record is
    -- nested -- the target sits inside -- so the zone is one blob, and moving the
    -- current circle is a translation and a scale of the one already in the movie.
    local addsHeld = S.mm.adds
    S.env.BR.State.storm.cx0, S.env.BR.State.storm.r0 = 60.0, 700.0
    S.tick(2)
    ok(S.areas()[1] == before and S.mm.adds == addsHeld and #S.areas() == 2,
        'and a one-blob zone that HAS moved is the same clip, moved -- nothing was '
            .. 'added',
        ('%s, %d adds'):format(S.areas()[1] == before and 'same' or 'replaced',
            S.mm.adds - addsHeld))
    local movedZone = S.env.BR.StormZone(S.env.BR.State.storm, 60.0, 0.0, 700.0)
    local movedOff = S.areas()[1] and 0.0 or math.huge
    for _, p in ipairs(S.areas()[1] and S.shown(S.areas()[1]) or {}) do
        movedOff = math.max(movedOff,
            math.abs(S.env.BR.StormShape.distance(movedZone, p.x, p.y)))
    end
    ok(movedOff < 1e-6,
        'and the map shows it ON the moved zone, to a micron -- the placement is the '
            .. 'movie\'s own arithmetic applied to the calls, not a claim',
        ('worst %.9f m off'):format(movedOff))

    -- AND A NEW PICTURE IS STILL A REBUILD. The target moving is a different key.
    S.env.BR.State.storm.cx1 = 250.0
    S.tick(2)
    ok(S.areas()[1] ~= before and #S.areas() == 2 and S.mm.adds == addsHeld + 2,
        'while a new target is a rebuild, whole -- both areas replaced',
        ('%d areas, %d adds'):format(#S.areas(), S.mm.adds - addsHeld))

    -- ─── the character count, which is the one unmeasured risk ───
    --
    -- There is no documented cap on a Scaleform string parameter, which is not the
    -- same as there not being one: the #347 spike's coordinates were about 70
    -- characters and a real boundary is several hundred to over a thousand. If a shape
    -- ever draws GARBLED rather than absent, this is the number to look at -- so it is
    -- reported, and `overlay.maxPoints` is the lever that bounds it.
    local rep = S.env.BR.MapOverlay.report()
    local sent = 0
    for _, ar in ipairs(S.areas()) do sent = sent + ar.chars end
    ok(rep.chars == sent and rep.chars > 0,
        'the overlay reports the coordinate characters it actually pushed, counted '
            .. 'from the same marshaller that pushed them',
        ('%d reported, %d in the movie'):format(rep.chars, sent))

    local cfgOv = S.env.BR.Config.Storm.overlay
    local capped = 0
    for _, ar in ipairs(S.areas()) do capped = math.max(capped, #ar.points) end
    ok(capped <= cfgOv.maxPoints,
        'and no contour exceeds the configured point ceiling, which is what bounds '
            .. 'that string',
        ('%d points against a ceiling of %d'):format(capped, cfgOv.maxPoints))

    -- ─── and the whole thing has an off switch that leaves the blips working ───
    local O = newStormClient()
    O.mm.handle = 7
    O.env.BR.Config.Storm.overlay.enabled = false
    O.pedAt = pt(0.0, 0.0)
    O.record(2, 0.0, 0.0, 800.0, 300.0, 0.0, 400.0, 600000, 60000, 2.0)
    O.tick(20)
    ok(#O.areas() == 0 and #O.rings() > 0 and O.errored() == nil,
        'overlay.enabled = false draws no fill, asks the movie for nothing and '
            .. 'leaves the map exactly as it was before #350',
        ('%d areas, %d rings, %d asks'):format(#O.areas(), #O.rings(), O.mm.asks))
    O.env.BR.Config.Storm.overlay.enabled = true
end

-- ---------------------------------------------------------------------------
describe('map.motion')
do
    -- ═══ A MOVING STORM IS NOT A REBUILD TWICE A SECOND (#350) ═══
    --
    --   "there's a major client perf issue once per second which only happens while
    --    the storm is actively in motion."                 -- owner, 2026-09-23
    --
    -- On 2026-09-24 the owner narrowed it further: ONLY a storm whose current and
    -- next borders are conjoined, and ONLY while that border is moving. That is one
    -- client path exactly. A nested zone has `fit` and is moved/resized in place; a
    -- conjoined breakout has no `fit`, so it paid REM_OVERLAY plus ADD_AREA_OVERLAY
    -- for the whole changing polygon at 0.62--1.65 Hz. A hold paid none. The moving
    -- union now uses the already-supported map blips until it becomes static, while
    -- the exact 3D wall and server damage shape continue unchanged.
    --
    -- ═══ WHY THIS BLOCK HAS ITS OWN CLOCK ═══
    --
    -- C.tick moves 1500 ms, which clears every throttle in the file -- what the
    -- blocks above want, and exactly what hid the rate: at 1500 ms a tick, "at most
    -- twice a second" and "every tick" are the same number, so nothing above could
    -- have gone red if the ceiling vanished. The loop thread is `step; Wait(100)`, so
    -- this steps the TICK band 100 ms at a time, which is what the game does.
    local function sweepClient(phase, cx0, r0, cx1, r1, shrinkMs, cy0, cy1)
        local C = newStormClient()
        C.mm.handle = 7
        C.pedAt = pt(cx0, cy0 or 0.0)
        local rec = C.record(phase, cx0, cy0 or 0.0, r0, cx1, cy1 or 0.0, r1,
            600000, shrinkMs, 2.0)
        rec.seed = 424242
        return C, rec
    end

    --- Start the record's sweep NOW, on the harness clock.
    local function startSweep(C, rec) rec.tStart = C.now - rec.tWait end

    --- `n` passes of the TICK band, 100 ms apart, calling `each` after every one.
    local function realTicks(C, n, each)
        for _ = 1, n do
            C.now = C.now + 100
            C.env.BR.Loop.step(C.env.BR.Loop.TICK)
            if each then each() end
        end
    end

    --- The worst distance from what the map SHOWS of area `i` to the zone right now.
    ---
    --- AN AREA THAT IS NOT THERE IS INFINITELY FAR OFF, rather than an index error: a
    --- regression that loses the fill should fail every assertion that reads it, not
    --- stop the suite at the first one and hide the rest.
    ---
    --- THE ZONE THE MAP DRAWS, WHICH IS NOT THE ONE THE WALL DRAWS MID-SWEEP. The wall
    --- morphs the current shape into the target's; the map keeps the shape the record
    --- started in and takes the target's once the sweep is FINISHED (overlayPlan). So
    --- the sweep fraction here is 0, or 1 once finished -- asked explicitly, because
    --- a map that morphed would be off this and on the wall's.
    local function offZone(C, rec, i)
        if not C.areas()[i] then return math.huge end
        local cx, cy, r, st = C.env.BR.StormAt(rec, C.env.BR.Clock.now())
        local m = (st == C.env.BR.StormPhase.FINISHED) and 1.0 or 0.0
        local zone = C.env.BR.StormZone(rec, cx, cy, r, m)
        local worst = 0.0
        for _, p in ipairs(C.shown(C.areas()[i])) do
            worst = math.max(worst,
                math.abs(C.env.BR.StormShape.distance(zone, p.x, p.y)))
        end
        return worst
    end

    local function traceRow(C, name)
        for _, row in ipairs(C.env.BR.Loop.hitchStats().rows) do
            if row.name == name then return row end
        end
        return nil
    end

    -- ─── #350 can be bisected in one moving phase without changing gameplay ───
    --
    -- Each mode deliberately damages only the LOCAL picture: the record and clock
    -- keep advancing, so a smooth mode has isolated rendering rather than stopped
    -- the storm. The command also starts a fresh capture; otherwise two modes in one
    -- playtest would be blended into a percentage that describes neither.
    local D, drec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0)
    ok(D.cmds.brstormbisect ~= nil, '/brstormbisect is registered')
    ok(D.overlayReady(), 'the bisect client reaches the overlay gate')
    D.tick(2)
    local dClip = D.areas()[1]
    local dAdds, dPlaced = D.mm.adds, D.mm.placed
    startSweep(D, drec)

    D.cmds.brstormbisect(nil, { 'mapfreeze', '40' }, '')
    realTicks(D, 20)
    local dHitch = D.env.BR.Loop.hitchStats()
    ok(D.env.BR.Storm.bisectMode == 'mapfreeze'
            and dHitch.enabled and dHitch.thresholdMs == 40,
        'mapfreeze is visible in state and starts a clean capture at the requested threshold')
    ok(D.mm.adds == dAdds and D.mm.placed == dPlaced and D.areas()[1] == dClip,
        'mapfreeze keeps the existing fill resident without one add, move or resize',
        ('adds %+d, placements %+d'):format(D.mm.adds - dAdds, D.mm.placed - dPlaced))
    ok(offZone(D, drec, 1) > 1.0,
        'while the server-authored storm keeps moving underneath that frozen local picture',
        ('map is %.2f m off the live zone'):format(offZone(D, drec, 1)))

    local dWidth = dClip._width
    local dX = dClip._x
    D.cmds.brstormbisect(nil, { 'mapnoresize' }, '')
    realTicks(D, 20)
    ok(D.mm.adds == dAdds and dClip._width == dWidth and dClip._x ~= dX,
        'mapnoresize moves the same clip but never sends the size/re-tessellation call',
        ('x %s -> %s, width %s -> %s'):format(
            tostring(dX), tostring(dClip._x), tostring(dWidth), tostring(dClip._width)))
    ok(traceRow(D, 'storm.map.position') ~= nil
            and traceRow(D, 'storm.map.place') == nil,
        'and the capture names position-only traffic separately from normal placement')
    ok(offZone(D, drec, 1) > 1.0,
        'the deliberately stale radius proves resize really was suppressed',
        ('map is %.2f m off the live zone'):format(offZone(D, drec, 1)))

    D.cmds.brstormbisect(nil, { 'normal' }, '')
    realTicks(D, 1)
    ok(D.env.BR.Storm.bisectMode == 'normal' and offZone(D, drec, 1) < 1e-3,
        'normal catches the existing clip up on its next tick rather than leaving the bisect armed',
        ('map is %.6f m off the live zone'):format(offZone(D, drec, 1)))

    D.cmds.brstormbisect(nil, { 'mapoff' }, '')
    -- Shrinking blips are intentionally capped at 4 Hz, so the fallback has a
    -- bounded 250 ms handoff rather than being required on the first 100 ms pass.
    realTicks(D, 3)
    ok(#D.areas() == 0 and #D.rings() > 0,
        'mapoff removes the custom Scaleform fill and hands the map to fallback blips',
        ('%d fills, %d rings'):format(#D.areas(), #D.rings()))
    D.cmds.brstormbisect(nil, { 'normal' }, '')
    realTicks(D, 6)
    ok(#D.areas() == 2 and #D.rings() == 0 and offZone(D, drec, 1) < 1e-3,
        'normal restores the real filled boundary after mapoff',
        ('%d fills, %d rings, %.6f m off'):format(
            #D.areas(), #D.rings(), offZone(D, drec, 1)))

    local W = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0)
    W:recordWallOnly()
    W:frame()
    local wallPolys = #W.polys
    W.cmds.brstormbisect(nil, { 'walloff' }, '')
    W:frame()
    ok(wallPolys > 0 and #W.polys == 0,
        'walloff removes the shaped 3D wall while its frame callback and storm record remain live',
        ('normal %d triangles, walloff %d'):format(wallPolys, #W.polys))
    W.cmds.brstormbisect(nil, { 'normal' }, '')
    W:frame()
    ok(#W.polys == wallPolys,
        'normal restores the wall on the next frame',
        ('restored %d of %d triangles'):format(#W.polys, wallPolys))

    -- ─── a nested sweep is PLACED, start to finish, and never rebuilt ───
    --
    -- Phase-2 sizes, and a centre off the world's origin in BOTH axes on purpose: a
    -- zone pushed in WORLD coordinates and then placed at its centre would land a
    -- kilometre off, and a y the movie negated twice would land on the wrong side of
    -- the equator -- and a centre on the origin, or on y = 0, hides each of those.
    local N, nrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0)
    ok(N.overlayReady(), 'the nested-sweep client reaches the gate')
    N.tick(2)
    local zoneClip, targetClip = N.areas()[1], N.areas()[2]
    local adds0, placed0 = N.mm.adds, N.mm.placed
    N.env.BR.Loop.hitchStart(34)
    startSweep(N, nrec)
    local nWorst, nTicks, offWall = 0.0, 0, 0.0
    -- ONE TICK SHORT OF THE END OF THE SWEEP: the end is the one rebuild a sweep
    -- makes, and it is asserted on its own below.
    realTicks(N, 1199, function()
        nTicks = nTicks + 1
        if nTicks % 10 == 0 then nWorst = math.max(nWorst, offZone(N, nrec, 1)) end
        -- AND HALF WAY, HOW FAR THE MAP IS FROM THE WALL'S OWN ZONE -- the morph. A
        -- map that morphed would be on the wall's zone and off its own.
        if nTicks == 600 then
            local cx, cy, r, _, _, _, t = N.env.BR.StormAt(nrec, N.env.BR.Clock.now())
            local wallZone = N.env.BR.StormZone(nrec, cx, cy, r, t)
            for _, p in ipairs(N.shown(N.areas()[1])) do
                offWall = math.max(offWall,
                    math.abs(N.env.BR.StormShape.distance(wallZone, p.x, p.y)))
            end
        end
    end)
    ok(N.errored() == nil, 'the whole sweep runs clean', N.errored())
    ok(N.mm.adds == adds0 and N.areas()[1] == zoneClip and N.areas()[2] == targetClip,
        'two minutes of a nested sweep add NOTHING to the movie -- the same two clips '
            .. 'are there at the end as at the start',
        ('%d adds over %d ticks'):format(N.mm.adds - adds0, nTicks))
    ok(N.mm.placed - placed0 >= nTicks,
        'because the zone was PLACED instead, on the ticks it moved',
        ('%d placement calls over %d ticks'):format(N.mm.placed - placed0, nTicks))
    local nPlace = traceRow(N, 'storm.map.place')
    local nRebuild = traceRow(N, 'storm.map.rebuild')
    ok(nPlace ~= nil and nPlace.events == nTicks,
        'and the hitch diagnostic labels that path at its real 10 Hz cadence',
        nPlace and ('%d markers over %d ticks'):format(nPlace.events, nTicks)
            or 'no storm.map.place marker')
    ok(nRebuild == nil or nRebuild.events == 0,
        'without mislabelling any nested-sweep tick as a polygon rebuild',
        nRebuild and tostring(nRebuild.events) or 'no rebuild row')
    ok(nWorst < 1e-3,
        'and what the map shows is ON the moving zone the whole way, to a millimetre '
            .. '-- not the metres a twice-a-second rebuild lagged by',
        ('worst %.6f m off'):format(nWorst))
    ok(targetClip._x == nil and targetClip._width == nil,
        'while the target, which does not move, is never touched at all')

    -- ═══ THE MAP DOES NOT MORPH, AND IT CHANGES SHAPE ONCE, AS THE WALL ARRIVES ═══
    --
    -- Half way through the sweep the wall is a morph of the two zones, and the map is
    -- on the zone's STARTING shape instead -- by tens of metres off the wall's, at
    -- phase-2 sizes, which is what a fill that followed the morph would have closed.
    ok(offWall > 10.0,
        'half way through the sweep the map is NOT on the wall\'s morphing zone -- it '
            .. 'moves and scales the shape it set out in, which is what #350 places',
        ('%.1f m off the wall\'s zone, on its own to %.6f m'):format(offWall, nWorst))
    local addsEnd = N.mm.adds
    realTicks(N, 5)
    local cx1, cy1, r1 = nrec.cx1, nrec.cy1, nrec.r1
    local arrived = N.env.BR.StormZone(nrec, cx1, cy1, r1, 1.0)
    local onTarget = 0.0
    for _, p in ipairs(N.areas()[1] and N.shown(N.areas()[1]) or {}) do
        onTarget = math.max(onTarget,
            math.abs(N.env.BR.StormShape.distance(arrived, p.x, p.y)))
    end
    ok(N.mm.adds - addsEnd == 2 and N.areas()[1] and onTarget < 1e-6,
        'and when the sweep is FINISHED it is rebuilt ONCE -- zone and target, one '
            .. 'push -- in the shape the wall is standing in, the target\'s',
        ('%d adds, %.9f m off the arrived zone'):format(N.mm.adds - addsEnd, onTarget))

    -- ─── a pentagon, a dodecagon and a circle are placed exactly as above ───
    --
    -- Placement rests on the zone mid-sweep being the starting zone moved and
    -- scaled, which holds because the zone's unit is fixed for its whole life -- the
    -- shape is drawn per zone, never per tick. Nothing in the arithmetic reads the
    -- count, and this is where that is shown rather than argued, at the two ends of
    -- the range and at the circle: a pentagon's bounding box sits furthest off its
    -- own centre, which is the point the movie scales the clip about, a dodecagon is
    -- the most points, and a circle zone is a blob the map can place like any other.
    -- The zone the map moves in phase 2 is ZONE 1 -- the one the sweep leaves.
    for _, want in ipairs({ 5, 12, 0 }) do
        local T, trec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
            -700.0, -300.0)
        -- BOUNDED, so a config that can no longer draw this shape fails here by name
        -- rather than hanging the suite looking for one.
        local seed
        for s = 1, 2000 do
            if T.env.BR.StormUnit(s, 1).n == want then seed = s break end
        end
        ok(seed ~= nil,
            ('the shipping config draws %s on zone 1 of some one of 2000 matches')
                :format(want == 0 and 'a circle' or (want .. ' corners')))
        trec.seed = seed or 1
        T.overlayReady()
        T.tick(2)
        local tAdds, tClip, tPlaced = T.mm.adds, T.areas()[1], T.mm.placed
        startSweep(T, trec)
        local tWorst, tTicks = 0.0, 0
        realTicks(T, 600, function()
            tTicks = tTicks + 1
            if tTicks % 10 == 0 then tWorst = math.max(tWorst, offZone(T, trec, 1)) end
        end)
        ok(T.errored() == nil and T.mm.adds == tAdds and T.areas()[1] == tClip
                and T.mm.placed - tPlaced >= tTicks and tWorst < 1e-3,
            ('%s zone is placed on every tick of its sweep, never rebuilt, and the map '
                .. 'shows it on the moving zone to a millimetre')
                :format(want == 0 and 'a circle' or ('a ' .. want .. '-corner')),
            T.errored() or ('seed %d: %d adds, %d placements over %d ticks, worst %.6f m')
                :format(trec.seed, T.mm.adds - tAdds, T.mm.placed - tPlaced, tTicks, tWorst))
    end

    -- ─── a moving breakout never rebuilds its Scaleform polygon ───
    --
    -- A union of the moving blob and the still target is not a scaled copy of any
    -- earlier one, so the Scaleform clip cannot be moved or resized into the next
    -- outline. Rebuilding it was #350's remaining hitch. The safe answer is the map
    -- path that already carries every client whose overlay is unavailable: current
    -- and target radius blips for the moving interval only. They are approximate map
    -- guidance for the seeded blobs; the exact 3D wall and damage shape keep moving.
    local ov = N.env.BR.Config.Storm.overlay
    local B, brec = sweepClient(6, 0.0, 260.0, 300.0, 110.0, 120000)
    ok(B.overlayReady(), 'the breakout client reaches the gate')
    B.tick(2)
    ok(#B.areas() == 2 and B.env.BR.StormZone(brec, 0.0, 0.0, 260.0).blob == nil,
        'and it is the overlapping case: one union contour plus the target, and the '
            .. 'union is not one blob',
        ('%d areas'):format(#B.areas()))
    B.env.BR.Loop.hitchStart(34)
    startSweep(B, brec)
    local bAdds0 = B.mm.adds
    realTicks(B, 1)
    local bCallsAtFallback = B.mm.calls
    local bx, by, br = B.env.BR.StormAt(brec, B.env.BR.Clock.now())
    local bCur, bNext
    for _, ring in ipairs(B.rings()) do
        if ring.colour == B.env.BR.Config.Storm.blip.currentColour then bCur = ring end
        if ring.colour == B.env.BR.Config.Storm.blip.nextColour then bNext = ring end
    end
    ok(#B.areas() == 0 and #B.rings() == 2
            and bCur and near(bCur.x, bx, 1e-6) and near(bCur.y, by, 1e-6)
            and near(bCur.r, br, 1e-6)
            and bNext and near(bNext.x, brec.cx1, 1e-6)
            and near(bNext.y, brec.cy1, 1e-6) and near(bNext.r, brec.r1, 1e-6),
        'on the first moving tick the conjoined fill is replaced by current/target '
            .. 'guidance at the solved centres and radii',
        ('%d fills, %d rings'):format(#B.areas(), #B.rings()))
    realTicks(B, 1198) -- 119.9 s total: still SHRINKING, one tick before FINISHED
    ok(B.errored() == nil, 'the breakout sweep runs clean', B.errored())
    local bxEnd, byEnd, brEnd = B.env.BR.StormAt(brec, B.env.BR.Clock.now())
    local bLag = math.sqrt((bCur.x - bxEnd) ^ 2 + (bCur.y - byEnd) ^ 2)
        + math.abs(bCur.r - brEnd)
    ok(bCur.exists and bLag < 1.0,
        'the current guidance keeps following the sweep, within one metre at its '
            .. '4 Hz refresh cadence',
        ('%.3f m centre-plus-radius lag'):format(bLag))
    ok(#B.areas() == 0 and #B.rings() > 0,
        'the ordinary map blips keep carrying the moving interval',
        ('%d fills, %d rings'):format(#B.areas(), #B.rings()))
    ok(B.mm.adds == bAdds0 and B.mm.calls == bCallsAtFallback,
        'the remaining 119.8 seconds issue no ADD, REMOVE, MOVE or RESIZE calls to '
            .. 'the Scaleform movie',
        ('%d adds, %d calls after fallback'):format(
            B.mm.adds - bAdds0, B.mm.calls - bCallsAtFallback))
    local bTrace = traceRow(B, 'storm.map.rebuild')
    local bFallback = traceRow(B, 'storm.map.fallback')
    ok((bTrace == nil or bTrace.events == 0)
            and bFallback ~= nil and bFallback.events == 1,
        'the diagnostic records one fallback transition and zero moving-union rebuilds',
        ('fallback %s, rebuild %s'):format(
            bFallback and tostring(bFallback.events) or 'missing',
            bTrace and tostring(bTrace.events) or 'none'))

    -- The exact polygon is still useful while static. On the tick the sweep
    -- finishes, the fallback latch clears and one fresh filled outline replaces
    -- the temporary rings.
    realTicks(B, 1)
    ok(#B.areas() == 2 and #B.rings() == 0 and B.mm.adds == bAdds0 + 2,
        'when the conjoined sweep becomes static, its exact fill returns and the '
            .. 'temporary rings leave on that same tick',
        ('%d fills, %d rings, %d new adds')
            :format(#B.areas(), #B.rings(), B.mm.adds - bAdds0))
    realTicks(B, 20)
    ok(#B.rings() == 0 and B.mm.adds == bAdds0 + 2,
        'and the static picture stays settled without another polygon rebuild',
        ('%d rings, %d new adds'):format(#B.rings(), B.mm.adds - bAdds0))

    -- A failed REM_OVERLAY is retained by mapoverlay.lua so its movie index remains
    -- valid. The fallback must keep retrying that retained clip after overlayShown has
    -- gone false; otherwise one engine refusal leaves a stale polygon for the sweep.
    local R, rrec = sweepClient(6, 0.0, 260.0, 300.0, 110.0, 500)
    ok(R.overlayReady(), 'the removal-retry client reaches the gate')
    R.tick(2)
    local rAdds = R.mm.adds
    R.mm.refuseRemove = true
    startSweep(R, rrec)
    realTicks(R, 1)
    ok(#R.areas() == 2 and #R.rings() == 2,
        'if the engine refuses the handoff removal, guidance still appears immediately '
            .. 'beside the retained fill',
        ('%d fills, %d rings'):format(#R.areas(), #R.rings()))
    realTicks(R, 9)
    ok(#R.areas() == 2 and #R.rings() == 2 and R.mm.adds == rAdds,
        'a refusal that lasts through FINISHED never stacks a replacement beside '
            .. 'the retained polygon',
        ('%d fills, %d rings, %d new adds')
            :format(#R.areas(), #R.rings(), R.mm.adds - rAdds))
    R.mm.refuseRemove = false
    realTicks(R, 5)
    ok(#R.areas() == 2 and #R.rings() == 0 and R.mm.adds == rAdds + 2,
        'once removal succeeds, the stale pair is replaced by one exact static pair '
            .. 'and the guidance leaves',
        ('%d fills, %d rings, %d new adds')
            :format(#R.areas(), #R.rings(), R.mm.adds - rAdds))

    -- A client can become ready after the sweep has already begun. It has no
    -- overlayAt from the hold to classify, so overlayFill must decline the first
    -- setAreas rather than paying one hitch before discovering the fallback.
    local J, jrec = sweepClient(4, 0.0, 950.0, 2400.0, 260.0, 120000)
    startSweep(J, jrec)
    ok(J.overlayReady(), 'a mid-sweep disjoint client reaches the gate')
    ok(#J.areas() == 0 and #J.rings() > 0 and J.mm.adds == 0,
        'a client becoming ready mid-union sweep sends no polygon and receives '
            .. 'fallback guidance on that same gate-opening tick',
        ('%d fills, %d rings, %d adds'):format(
            #J.areas(), #J.rings(), J.mm.adds))

    -- ─── and rebuildHz is the ceiling whatever asks ───
    --
    -- Moving unions no longer ask. A target changed every tick is the remaining
    -- worst-case key churn: artificial, but it isolates the ceiling without routing
    -- through the path the regression just removed.
    local F, frec = sweepClient(2, 0.0, 800.0, 300.0, 400.0, 60000)
    ok(F.overlayReady(), 'the ceiling client reaches the gate')
    F.tick(2)
    local gaps, lastAt, fAdds = {}, nil, F.mm.adds
    for _ = 1, 100 do
        frec.cx1 = frec.cx1 + 1.0
        realTicks(F, 1, function()
            if F.mm.adds > fAdds then
                fAdds = F.mm.adds
                if lastAt then gaps[#gaps + 1] = F.now - lastAt end
                lastAt = F.now
            end
        end)
    end
    local minGap = math.huge
    for _, g in ipairs(gaps) do minGap = math.min(minGap, g) end
    local floorMs = 1000.0 / ov.rebuildHz
    ok(#gaps >= 5 and minGap >= floorMs,
        'static picture churn still rebuilds no closer together than 1 / rebuildHz',
        ('%d rebuilds in 10 s, closest %s ms apart, floor %.0f ms'):format(
            #gaps + 1, tostring(minGap), floorMs))

    -- ─── a placement the engine refuses leaves NO zone, never a misplaced one ───
    --
    -- The zone goes out about its own centre, so until it is placed it sits on the
    -- world's origin. A refused placement at the moment of drawing must therefore take
    -- the push down whole, exactly as a refused add does -- and hand the map to the
    -- radius blips.
    local P, prec = sweepClient(2, 1000.0, 2600.0, 1600.0, 1600.0, 120000)
    P.mm.refusePlace = true
    ok(P.overlayReady(), 'the refusal client reaches the gate')
    P.tick(3)
    ok(#P.areas() == 0 and #P.rings() > 0,
        'a zone that could not be placed as it was drawn is taken down whole, and the '
            .. 'blips carry the map',
        ('%d areas, %d rings'):format(#P.areas(), #P.rings()))
    P.mm.refusePlace = false
    P.tick(3)
    ok(#P.areas() == 2 and #P.rings() == 0 and offZone(P, prec, 1) < 1e-6,
        'and once the engine accepts it, the fill is back and on the zone',
        ('%d areas, %d rings'):format(#P.areas(), #P.rings()))

    -- AND ONE REFUSED MID-SWEEP IS REBUILT, NOT LEFT BEHIND. The clip cannot follow
    -- the zone any more, so the next rebuild draws it again -- which then cannot be
    -- placed either, so it comes down and the blips take over.
    startSweep(P, prec)
    realTicks(P, 5)
    P.mm.refusePlace = true
    realTicks(P, 20)
    ok(#P.areas() == 0 and #P.rings() > 0 and P.errored() == nil,
        'a placement refused mid-sweep ends with no fill rather than a stale one',
        ('%d areas, %d rings'):format(#P.areas(), #P.rings()))

    -- AND HALF A PLACEMENT IS A REFUSAL TOO. The resize is a second method; if the
    -- engine opens the move and declines the resize, pushing the resize's parameters
    -- anyway would push them into whatever the engine has open -- natives.lua's
    -- header has why that is somebody else's call corrupted rather than a no-op. The
    -- harness throws on a push with nothing open, so that shows here as an error.
    -- What must happen instead is the fallback: the zone is rebuilt, the rebuild's
    -- own placement needs no resize, and the map stays on the zone at rebuild pace.
    local Q, qrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0)
    ok(Q.overlayReady(), 'the half-refusal client reaches the gate')
    Q.tick(2)
    Q.mm.refuseMethod.UPDATE_OVERLAY_SIZE_OR_SCALE = true
    startSweep(Q, qrec)
    local qWorst, qAdds = 0.0, Q.mm.adds
    realTicks(Q, 100, function()
        if #Q.areas() > 0 then qWorst = math.max(qWorst, offZone(Q, qrec, 1)) end
    end)
    ok(Q.errored() == nil and #Q.areas() == 2 and Q.mm.adds > qAdds
            and qWorst < Q.env.BR.Config.Storm.overlay.chordM,
        'a refused resize is answered: nothing is pushed at nothing, and the zone '
            .. 'falls back to rebuilds that keep it on the map',
        Q.errored() or ('%d areas, %d adds, worst %.2f m off')
            :format(#Q.areas(), Q.mm.adds - qAdds, qWorst))

    -- ─── a removal the engine refuses must not steal the slot ───
    --
    -- A refused REM_OVERLAY leaves the old clip in the movie -- the engine's refusal,
    -- and mapoverlay.lua keeps it on its books so the indices stay true. A replacement
    -- must not be stacked beside it: the caller remains on blips until the old pair can
    -- be removed, then installs one new pair whose slot 1 is safe to place.
    local K, krec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0)
    ok(K.overlayReady(), 'the leftover client reaches the gate')
    K.tick(2)
    local kAdds = K.mm.adds
    K.mm.refuseRemove = true
    krec.cx1 = 1350.0                  -- a new target: a new key, so a rebuild
    K.tick(2)
    ok(#K.areas() == 2 and K.mm.adds == kAdds,
        'refused removals retain the old pair without stacking the replacement',
        ('%d areas, %d new adds'):format(#K.areas(), K.mm.adds - kAdds))
    K.mm.refuseRemove = false
    K.tick(2)
    ok(#K.areas() == 2 and K.mm.adds == kAdds + 2,
        'once removal is accepted, exactly one replacement pair is installed',
        ('%d areas, %d new adds'):format(#K.areas(), K.mm.adds - kAdds))
    startSweep(K, krec)
    realTicks(K, 50)
    ok(K.errored() == nil and offZone(K, krec, 1) < 1e-6,
        'and slot 1 of that replacement follows the moving storm',
        K.errored() or ('new zone %.3f m off'):format(offZone(K, krec, 1)))

    -- ─── the last seconds of the final sweep ───
    --
    -- The zone stops being a blob below MIN_RADIUS and then runs out of polygon
    -- altogether. storm.map asks the shape every tick rather than assuming it is still
    -- one blob, and this is the sweep where assuming would index a nil.
    local L, lrec = sweepClient(8, 500.0, 40.0, 520.0, 0.0, 30000)
    ok(L.overlayReady(), 'the final-sweep client reaches the gate')
    L.tick(2)
    startSweep(L, lrec)
    local lWorst = 0.0
    realTicks(L, 320, function()
        local cx, cy, r = L.env.BR.StormAt(lrec, L.env.BR.Clock.now())
        if #L.areas() > 0 and L.env.BR.StormZone(lrec, cx, cy, r).blob then
            lWorst = math.max(lWorst, offZone(L, lrec, 1))
        end
    end)
    ok(L.errored() == nil and #L.areas() == 0,
        'the final sweep closes to nothing without an error, and leaves no fill behind',
        L.errored() or ('%d areas'):format(#L.areas()))
    ok(lWorst < 1e-3,
        'and the fill was on the zone for every tick it was still one blob',
        ('worst %.6f m off'):format(lWorst))
end

-- ---------------------------------------------------------------------------
describe('preview.entry')
do
    -- ═══ THE PREVIEW WALL ARRIVES RATHER THAN APPEARING (#351) ═══
    --
    --   "When the map loaded in (while in bus), the storm wall popped in, didn't fade
    --    in."                                            -- owner, 2026-09-22
    --
    -- #340 gave the preview wall its whole life and its fade OUT -- one minus the real
    -- wall's share. It never had an entry: the instant br_environment said the
    -- mainland was the world, the curtain drew at full previewAlpha on its first
    -- frame, five hundred metres in front of a bus.
    --
    -- ═══ WHAT IS ASSERTED IS THAT IT IS THE SAME CLOCK ═══
    --
    -- #340's whole point is one fade length read in two directions, so the ramp reuses
    -- render.fadeInSec rather than introducing a window of its own -- and the test
    -- that matters is not "it ramps" but "it ramps over THAT number". Every
    -- expectation below is derived from the config, so retuning fadeInSec retunes the
    -- block; a second constant in the production file would fail it.
    local proto = newStormClient()
    local MS, PS = proto.env.BR.MatchState, proto.env.BR.PlayerState
    local rr = proto.env.BR.Config.Storm.render
    local FADE = (rr.fadeInSec or 10.0) * 1000.0

    --- The brightest triangle in the last frame, or nil for an empty one.
    local function brightest(C)
        local m = nil
        for _, t in ipairs(C.polys) do
            if m == nil or t.a > m then m = t.a end
        end
        return m
    end

    local function busClient()
        local C = newStormClient()
        local env = C.env
        env.BR.State.storm = nil
        env.BR.State.match.state = MS.BUS
        env.BR.State.me.state    = PS.BUS
        env.BR.State.stormPreview = { cx = 500.0, cy = 0.0, r = 1600.0 }
        C.pedAt = pt(0.0, 0.0, 30.0)
        return C
    end

    -- ─── the world is not the world yet: nothing, exactly as before ───
    local A = busClient()
    A.fire('br:env:world', true)          -- the Cayo island is still up
    A.frame()
    A.frame()
    ok(#A.polys == 0,
        'with the island still the world there is no wall at all, which is the gate '
            .. '#351 was told not to move',
        ('%d polys'):format(#A.polys))

    -- ─── the first frame the world arrives arms the ramp and draws nothing ───
    --
    -- AND THAT IS NOT A CHANGE TO WHEN IT STARTS. The ramp is anchored on the frame
    -- this callback would have drawn on anyway, so the wall begins at exactly the
    -- moment it began before -- at nothing instead of at full. One frame of geometry
    -- at alpha zero is identical on screen and a frame's worth of triangles dearer,
    -- which is the reading wallShare's header already argues for its own boundary.
    local B = busClient()
    B.fire('br:env:world', false)
    B.frame()
    ok(#B.polys == 0,
        'the first frame with the mainland loaded draws nothing: the ramp is at zero',
        ('%d polys'):format(#B.polys))

    -- ─── and then it rises, monotonically, over exactly fadeInSec ───
    local settled = busClient()
    settled.fire('br:env:world', false)
    settled.settlePreview()
    local FULL = brightest(settled)
    ok(FULL ~= nil and FULL > 0,
        'a settled preview wall has an alpha to compare against',
        tostring(FULL))

    local seen, rising, over = {}, true, nil
    local prev = -1
    local E = busClient()
    E.fire('br:env:world', false)
    E.frame()                              -- arms
    for k = 1, 10 do
        E.now = E.now + math.floor(FADE / 10)
        E.frame()
        local a = brightest(E) or 0
        seen[#seen + 1] = a
        if a < prev then rising = false end
        if a > FULL then over = over or ('%d at step %d'):format(a, k) end
        prev = a
    end
    ok(rising,
        'the preview wall only ever gets brighter across the window -- a ramp that '
            .. 'dipped would read as a flicker',
        table.concat({ tostring(seen[1]), tostring(seen[3]), tostring(seen[6]),
                       tostring(seen[10]) }, ' -> '))
    ok(over == nil,
        'and never brighter than the strength it settles at, so previewAlpha is '
            .. 'still the ceiling',
        over)
    ok(seen[1] > 0 and seen[1] < FULL,
        'it is genuinely part-strength a tenth of the way in, which is the thing the '
            .. 'owner did not see',
        ('%d against %d at full'):format(seen[1], FULL))
    ok(seen[#seen] == FULL,
        'and it is at full exactly one fade window after the world arrived -- the '
            .. 'SAME window the curtain and the map ring fade in over',
        ('%d against %d'):format(seen[#seen], FULL))

    -- ═══ AND THE BOUNDARY FRAME ITSELF IS FULL, NOT ONE STEP SHORT ═══
    --
    -- Held EXACTLY equal to the window, which is the one instant a strict comparison
    -- and an inclusive one disagree -- the same boundary wallShare's header pins for
    -- its own clock, and the reason that one is spelled `msLeft >= fadeMs`. A tenth-
    -- step sweep never lands on it, so it is asked for directly.
    local Bnd = busClient()
    Bnd.fire('br:env:world', false)
    Bnd.frame()                            -- arms; worldAt is this frame's timer
    local armedAt = Bnd.now
    Bnd.now = armedAt + math.floor(FADE) - 16   -- C.frame adds the last 16 ms
    Bnd.frame()
    ok(Bnd.now - armedAt == math.floor(FADE) and brightest(Bnd) == FULL,
        'the frame at exactly one window is already at full strength, rather than a '
            .. 'step short of it',
        ('held %d of %d, brightest %s'):format(Bnd.now - armedAt, math.floor(FADE),
            tostring(brightest(Bnd))))

    -- ─── the ramp is armed by the world, not by the announcement ───
    --
    -- mainlandLoaded falls back to the match state when br_environment is silent, and
    -- a ramp that only completed on the announced path would leave a permanently
    -- invisible preview wall on any box not running that resource -- which is the
    -- deployment shape with no way to notice.
    local S = busClient()
    S.settlePreview()
    ok(brightest(S) == FULL,
        'with br_environment silent the match state arms the ramp and it completes',
        tostring(brightest(S)))

    -- ─── it re-arms when the mainland stops being the world ───
    --
    -- The island comes back for every state that is not BUS or PLAYING, so a ramp
    -- that latched would let the SECOND match of a session pop exactly as the first
    -- one did -- and nothing would report it, because the first match looked right.
    local Rr = busClient()
    Rr.fire('br:env:world', false)
    Rr.settlePreview()
    ok(brightest(Rr) == FULL, 'a ramp that has completed is at full')
    Rr.fire('br:env:world', true)           -- the island is back: between matches
    Rr.frame()
    ok(#Rr.polys == 0, 'and the wall is gone with the world')
    Rr.fire('br:env:world', false)          -- and the next match's mainland arrives
    Rr.frame()
    ok(#Rr.polys == 0,
        'the ramp is ARMED AGAIN rather than latched, so the next match\'s first '
            .. 'frame is at nothing too',
        ('%d polys'):format(#Rr.polys))
    Rr.now = Rr.now + math.floor(FADE)
    Rr.frame()
    ok(brightest(Rr) == FULL, 'and it rises to full over the window a second time',
        tostring(brightest(Rr)))

    -- ─── and it does NOT re-arm at the BUS -> PLAYING handoff ───
    --
    -- Which is the one transition it must sit still through. The preview spans the bus
    -- AND the suppressed phase-1 hold (#340), the world does not change underneath it,
    -- and a ramp that restarted there would put the pop back in the exact place #340
    -- removed a gap from.
    local P = busClient()
    P.fire('br:env:world', false)
    P.settlePreview()
    P.env.BR.State.match.state = MS.PLAYING
    P.env.BR.State.me.state    = PS.ALIVE
    P.record(1, 0.0, 0.0, 6000.0, 500.0, 0.0, 1600.0, 120000, 60000, 0.5)
    P.env.BR.State.stormPreview = nil
    P.frame()
    ok(brightest(P) == FULL,
        'the frame after the match goes PLAYING is at the same strength the bus was '
            .. '-- the entry ramp does not restart at the handoff',
        tostring(brightest(P)))

    -- ─── a zero window is not a nan ───
    --
    -- wallShare answers fadeInSec of 0 rather than dividing by it, because a nan alpha
    -- is an invisible wall with nothing in the console. The entry ramp is the same
    -- arithmetic and answers it the same way: no window means full strength at once.
    local Z = busClient()
    Z.env.BR.Config.Storm.render.fadeInSec = 0.0
    Z.fire('br:env:world', false)
    Z.frame()                              -- the world arrives; the ramp is armed
    Z.frame()
    local za = brightest(Z)
    ok(za ~= nil and za == za and za == FULL,
        'fadeInSec of zero means no ramp at all -- full strength on the frame after '
            .. 'the world arrives, and not a nan',
        tostring(za))

    -- ═══ AND THE ONE CASE THAT IS ACTUALLY A 0/0 ═══
    --
    -- A zero window with a zero held time. Reachable in the game by two frames landing
    -- in the same millisecond, which at the framerates this wall is looked at from is
    -- not exotic -- and `held >= ms` is the only thing standing between that and a
    -- nan alpha, which is an invisible wall with nothing in the console. Forced here
    -- by winding the clock back by exactly the step C.frame adds.
    local Z2 = busClient()
    Z2.env.BR.Config.Storm.render.fadeInSec = 0.0
    Z2.fire('br:env:world', false)
    Z2.frame()
    Z2.now = Z2.now - 16                   -- so the next frame lands on the same ms
    Z2.frame()
    local za2 = brightest(Z2)
    ok(za2 ~= nil and za2 == za2 and za2 == FULL,
        'a zero window read on the very millisecond it was armed is full strength, '
            .. 'not a nan out of zero over zero',
        tostring(za2))
    Z2.env.BR.Config.Storm.render.fadeInSec = rr.fadeInSec
    Z.env.BR.Config.Storm.render.fadeInSec = rr.fadeInSec

    -- ─── and a clock that went backwards is nothing, not a negative alpha ───
    --
    -- GetGameTimer is monotonic in the game, so this is not a defect being guarded
    -- against -- it is the SHAPE of the arithmetic being pinned. The share is
    -- multiplied into a draw alpha, and a negative multiplier is the class of fault
    -- that shows up as an invisible wall with nothing in the console.
    local Bk = busClient()
    Bk.fire('br:env:world', false)
    Bk.settlePreview()
    ok(brightest(Bk) == FULL, 'a settled wall before the clock is wound back')
    Bk.now = Bk.now - math.floor(FADE * 2.0)
    Bk.frame()
    ok(#Bk.polys == 0,
        'and a clock that has gone backwards draws nothing rather than a negative '
            .. 'alpha',
        ('%d polys, brightest %s'):format(#Bk.polys, tostring(brightest(Bk))))
end

-- ---------------------------------------------------------------------------
describe('patch.minimap')
do
    -- ═══ THE VENDORED CALL THAT CRASHES THE STREAMING DLL (#348) ═══
    --
    -- ADD_MINIMAP_OVERLAY racing RELOAD_MAP_STORE crashes gta-streaming-five.dll
    -- (citizenfx/fivem#4167, open and unmerged), and ScaleformUI called it at join
    -- with no gate at all: initializeScaleforms() ran MinimapOverlays:Load()
    -- unconditionally at resource start, and the retry thread below it called Load()
    -- again at 2 Hz whenever the handle was still 0 -- which, because isLoaded can
    -- never turn true in this vendored copy, is from resource start. Load() fires
    -- ScUI:AddMinimapOverlay and loader.lua answers it with the native.
    --
    -- IT MATTERS MORE HERE THAN ON MOST SERVERS because an in-game logout on this
    -- project re-mints a token and signs the player back in -- a deliberate feature --
    -- so join is re-run in ordinary play and the race needs no cold boot.
    --
    -- ═══ WHY A TEXT ASSERTION AND NOT A DRIVEN ONE ═══
    --
    -- The patch is two changes inside a 20,000-line vendored bundle that this suite
    -- does not load and should not: standing that file up would mean stubbing most of
    -- ScaleformUI to assert one `if`. What can rot is the PATCH, at the next upstream
    -- bump -- and verify.sh's vendored gate only checks that a BR-PATCH marker is
    -- declared, not that it still does anything. So this reads the file and asserts
    -- the two facts the patch consists of. The patch log carries the rest.
    -- Read from the repository root, the same place every loadfile in this file
    -- resolves from -- so a suite run from anywhere else fails loudly here rather
    -- than passing four assertions over a nil.
    local VPATH = 'resources/[scaleformui]/ScaleformUI_Lua/ScaleformUI.lua'
    local f = io.open(VPATH, 'r')
    ok(f ~= nil, 'the vendored bundle is where the patch log says it is', VPATH)
    if f then
        local src = f:read('a')
        f:close()

        local init = src:match('local function initializeScaleforms%(%)(.-)\nend\n')
        ok(init ~= nil, 'initializeScaleforms is still findable',
            init and 'found' or 'the function signature moved')

        --- The same text with every line comment taken out.
        ---
        --- THE PATCH IS A DELETION AND IT LEAVES A COMMENT SAYING SO, which names the
        --- call it removed -- so a search of the raw body finds the very sentence
        --- explaining that the call is gone. Only CODE counts here.
        local function codeOnly(text)
            local out = {}
            for line in (text .. '\n'):gmatch('([^\n]*)\n') do
                if not line:match('^%s*%-%-') then out[#out + 1] = line end
            end
            return table.concat(out, '\n')
        end

        local initCode = init and codeOnly(init) or ''
        ok(init ~= nil and not initCode:match('MinimapOverlays:Load%(%)'),
            'initializeScaleforms no longer calls MinimapOverlays:Load() -- the eager '
                .. 'ungated AddMinimapOverlay at join is gone (BR-PATCH 5)',
            initCode:match('MinimapOverlays:Load%(%)') or 'absent from the code')
        ok(initCode:match('_pauseMenu:Load%(%)') ~= nil,
            'and the rest of initializeScaleforms is untouched, which is what makes '
                .. 'the line above a deletion rather than a moved function',
            initCode:match('_pauseMenu:Load%(%)') or 'the pause menu load is gone too')

        -- AND THE RETRY THREAD'S OWN COPY IS GATED. Removing the eager call alone
        -- fixes nothing: this thread reaches the same native within 500ms of start.
        ok(src:match('BR%-PATCH 5') ~= nil,
            'the patch marker is in the file, which is what ties it to the log')
        -- THE WHOLE GATE AS ONE EXPRESSION, not the two native names somewhere in the
        -- file. `if true then` in front of the Load() leaves both names sitting in the
        -- counter above it, so a search for the names alone passes over a patch that
        -- has been neutered -- which is exactly what a bad rebase at the next upstream
        -- bump would leave behind.
        local code = codeOnly(src)
        ok(code:match('if brYes%(NetworkIsGameInProgress%(%)%)'
            .. ' and brYes%(IsMinimapRendering%(%)%) then') ~= nil,
            'the retry tests both session conditions as one gate before asking for '
                .. 'the overlay')
        ok(code:match('if brHeld >= 6 then\n%s*ScaleformUI%.Scaleforms%.'
            .. 'MinimapOverlays:Load%(%)') ~= nil,
            'and the Load() itself is behind the held counter, not beside it',
            code:match('if brHeld[^\n]*') or 'the counter guard is gone')

        -- 0 IS TRUTHY IN LUA and both natives are declared BOOL, so a bare `if` on
        -- either would be the whole gate gone with nothing to see. The patch compares.
        ok(src:match('brYes') ~= nil
            and src:match('v ~= nil and v ~= false and v ~= 0') ~= nil,
            'through a comparison rather than a bare truth test, because 0 is truthy '
                .. 'in Lua and both natives are declared BOOL')

        -- AND THE DELAY IS LABELLED A GUESS WHERE IT IS WRITTEN. #4167 publishes no
        -- safe window, so any number here is one -- and the next person to read it
        -- should be told that by the source rather than by an issue.
        ok(src:match('BR%-PATCH 5.-[Gg][Uu][Ee][Ss][Ss]') ~= nil
            or src:match('[Gg][Uu][Ee][Ss][Ss].-#4167') ~= nil
            or src:match('#4167.-[Gg][Uu][Ee][Ss][Ss]') ~= nil,
            'and the window it waits is called a guess in the source, because #4167 '
                .. 'publishes no safe one')
    end
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end

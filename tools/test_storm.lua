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
    -- BR.HealthBase: the storm's kill is judged on what the bar will show once
    -- a heal still landing has landed (#366). Pure, so the client state loads it
    -- for nothing; the server state without it would be storm_shape's trap
    -- again, a damage tick that errors inside the pcall and bills nobody.
    'br_lib/shared/health_solve.lua',
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
--- Equal, saying both when not (Control Tower's blocks, #396 wave B).
local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
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
---
--- PAST ITS GROWTH. A conjoined destination is grown into across the hold's first
--- `grow.seconds` (#344), and `g` left out reads as the whole of it: the union the
--- growth ends on, which is what every block reading this is about. A block that
--- measures a client or a server against it moves its record past the growth first
--- (C.grown, S.grown); `grow.*` is where the growth itself is asserted.
local function zoneOf(env, rec)
    return env.BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0)
end

--- The growth window of a record, in ms: how far to move its start back so that a
--- block about the union a conjoined phase GROWS into (#344) reads that union from
--- its first pass. The same arithmetic storm_solve.lua's growMs does.
local function growWindow(env, rec)
    local sec = env.BR.Config.Storm.grow and env.BR.Config.Storm.grow.seconds or 0.0
    return math.min(sec * 1000.0, rec.tWait)
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
        -- BY ID, for BR.Storm.exposed (#366); filled in below with the match.
        matches = {},
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
        -- THE STORM WRITES THE ONE HEALTH LEDGER THROUGH THIS (#366), so the
        -- squad panel hears it. The real verb also broadcasts; here the write is
        -- the whole of it.
        update = function(src, changes)
            local e = S.roster[src]
            if not e then return nil end
            for k, v in pairs(changes) do e[k] = v end
            return e
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
    env.BR.Server.matches[S.match.id] = S.match

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

    --- Move the live record PAST ITS GROWTH (#344): a conjoined destination is
    --- grown into across the hold's first grow.seconds, and a block about the union
    --- that growth ends on has to be billed against the union from its first pass.
    --- The hold these blocks set up is minutes long, so nothing else moves.
    function S.grown()
        local rec = S.match.storm
        rec.tStart = rec.tStart - growWindow(env, rec)
        return rec
    end

    --- Stand the one player at (x, y) and run a pass. True if the storm billed
    --- them for it.
    ---
    --- THE STAMP IS THE READ, NOT THE WIRE. STORM_DAMAGE carries whole engine
    --- points with the fraction carried forward, so at a low dps a given tick
    --- legitimately sends nothing and the ledger (`hp`) does not move;
    --- `lastStormAt` is stamped on every pass that bills the player, a whole
    --- point sent or not (#366), and on no other.
    function S.hurts(x, y)
        local e = S.roster[1]
        e.pos = { x = x, y = y, z = 30.0 }
        e.lastStormAt = nil
        S.tick()
        return e.lastStormAt ~= nil
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

--- Every native that can change which camera renders, as `camera.class` sorts them
--- (#393). client/storm.lua wraps each AS IT LOADS, so the harness has to define
--- them first for the wrappers to exist here; they record their calls and nothing
--- else, and no block but `camera.switch` calls one.
local CAMERA_NATIVES = {
    'RenderScriptCams', 'SetCamActive', 'SetCamActiveWithInterp', 'DestroyCam',
    'DestroyAllCams', 'CreateCam', 'CreateCamera', 'CreateCamWithParams',
    'CreateCameraWithParams', 'SwitchInPlayer',
}

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
        removes = 0,            -- REM_OVERLAY calls handled
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
        faded = 0,              -- SET_OVERLAY_ALPHA calls handled (#344)
        calls = 0,
        -- EVERY METHOD THE MOVIE RAN, BY NAME, adds and removals included: what
        -- "a sweep sends the movie nothing but the fade" (2026-10-04) is counted on.
        byMethod = {},
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
    -- THE SLOT IS READ BACK SINCE #399 (the grade touches only what it set), so
    -- it is a slot here rather than three no-ops: -1 while empty, as on the engine.
    local tcSlot = nil
    env.SetTimecycleModifier         = function(n) tcSlot = n end
    env.SetTimecycleModifierStrength = function() end
    env.ClearTimecycleModifier       = function() tcSlot = nil end
    env.GetTimecycleModifierIndex    = function() return tcSlot and #tcSlot or -1 end
    env.GetTimecycleModifierNameByIndex = function() return tcSlot end
    env.GetTimecycleModifierStrength = function() return 1.0 end
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
    -- THE FALLBACK RING FADES BY ALPHA, ON THE BLIP ALREADY ON THE MAP (2026-10-04):
    -- a sweep's old ring is faded where it stands, never rebuilt.
    env.SetBlipAlpha = function(h, a)
        if C.blips[h] then C.blips[h].alpha = a end
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
        C.mm.byMethod.ADD_AREA_OVERLAY = (C.mm.byMethod.ADD_AREA_OVERLAY or 0) + 1
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
        C.mm.removes = C.mm.removes + 1
        C.mm.byMethod.REM_OVERLAY = (C.mm.byMethod.REM_OVERLAY or 0) + 1
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
        C.mm.byMethod[call.method] = (C.mm.byMethod[call.method] or 0) + 1
        local p = call.params
        local ov = C.mm.overlays[(p[1] or -1) + 1]
        if not ov then error(('%s on index %s, which is not in the movie')
            :format(call.method, tostring(p[1]))) end
        -- AS THE BYTECODE HAS THEM, recorded on #350 and #344:
        --   UPDATE_OVERLAY_POSITION       txdLoader._x = x;  txdLoader._y = 0 - y
        --   UPDATE_OVERLAY_SIZE_OR_SCALE  isScaled ? _xscale/_yscale : _width/_height
        --   SET_OVERLAY_ALPHA             A = convertValue(a) = a * 100 / 255, and
        --                                 txdLoader._alpha = the same
        -- and an AreaOverlay has no isScaled.
        if call.method == 'UPDATE_OVERLAY_POSITION' then
            ov._x, ov._y = p[2], 0 - p[3]
            C.mm.placed = C.mm.placed + 1
        elseif call.method == 'UPDATE_OVERLAY_SIZE_OR_SCALE' then
            ov._width, ov._height = p[2], p[3]
            C.mm.placed = C.mm.placed + 1
        elseif call.method == 'SET_OVERLAY_ALPHA' then
            ov.A = p[2] * 100 / 255
            ov._alpha = ov.A
            C.mm.faded = C.mm.faded + 1
        else
            error('the harness movie has no handler for ' .. tostring(call.method))
        end
    end

    --- HOW OPAQUE ONE AREA RENDERS, 0..1, by the movie's own arithmetic: the fill's
    --- alpha is the one it was ADDED with, a Flash 0-100 percentage clamped at 100,
    --- and the clip's `_alpha` is what Colourise set from that same parameter until a
    --- SET_OVERLAY_ALPHA rewrote it. They multiply. MapOverlay.areaAlpha's header has
    --- the add-time half; the rewrite is #344's.
    function C.opacity(ov)
        local fill = math.min(ov.a, 100) / 100
        local clip = (ov._alpha or (ov.a / 255 * 100)) / 100
        return fill * clip
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
    -- Nobody's sky is on screen here, so the storm's rain writes (which wait
    -- for the storm to be the sky's winner, #399) are never made.
    env.BR.World.sky = function() return nil, nil end
    -- And no blend is ever still arriving, so the drying schedule runs on its
    -- own clock (it waits for the sky's, #399).
    env.BR.World.arrivesAt = function() return nil end
    env.BR.Sfx = { play = function(cue) C.sfx[#C.sfx + 1] = cue end }

    C.camCalls, C.camNatives = {}, {}
    for _, n in ipairs(CAMERA_NATIVES) do
        local f = function()
            C.camCalls[#C.camCalls + 1] = n
            return 900 + #C.camCalls
        end
        C.camNatives[n] = f
        env[n] = f
    end

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

    --- Move the live record PAST ITS GROWTH (#344), as S.grown does for the server:
    --- for a block about the union a conjoined phase grows into, drawn and read from
    --- its first frame. The holds here are minutes long, so nothing else moves.
    function C.grown()
        local rec = env.BR.State.storm
        rec.tStart = rec.tStart - growWindow(env, rec)
        return rec
    end

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
    --- than once at the start -- see preview.twowalls' both().
    function C.settlePreview()
        C.frame()
        C.now = C.now
            + math.floor((env.BR.Config.Storm.render.fadeInSec or 10.0) * 1000.0)
        C.frame()
    end

    --- Silence the #327 preview wall, leaving only the record's own curtain in frame.
    ---
    --- ═══ NEEDED SINCE #340, AND THROUGH ALL OF PHASE 1 SINCE #344 ═══
    ---
    --- Circle 1's wall stands beside the opening zone's through the whole of phase 1 --
    --- its hold and its sweep -- so there are legitimately TWO walls in one frame at two
    --- different alphas. An assertion about "the alpha depends on height and on nothing
    --- else" reads their union as one wall whose alpha varies along its length, which is
    --- the picket fence -- a false red on a renderer that is doing exactly what it was
    --- asked to.
    ---
    --- THROUGH BR.Loop.setEnabled RATHER THAN BY MATCHING GEOMETRY, because that is the
    --- production switch (`/brloop disable storm.previewWall`) and the mechanism the M4
    --- authority drill already turns. Telling the two walls apart by radius would work
    --- today and would quietly stop working the first time a phase-1 target happened to
    --- sit on the opening circle.
    ---
    --- THE TWO WALLS ARE ASSERTED TOGETHER, and each alone, in `preview.twowalls`.
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

    --- The areas the renderer says are one part of its picture (#344): `zone` -- the
    --- safe zone as the hold began, one contour or two islands, faded to nothing once a
    --- sweep sets off -- or `destination`, by the slots BR.Storm.mapSlots names, in the
    --- movie's order.
    local function slotAreas(which)
        local out = {}
        local slots = env.BR.Storm.mapSlots and env.BR.Storm.mapSlots()
        for _, slot in ipairs(slots and slots[which] or {}) do
            local ov = C.mm.overlays[slot]
            if ov then out[#out + 1] = ov end
        end
        return out
    end
    function C.zone() return slotAreas('zone') end
    function C.dest() return slotAreas('destination') end

    --- The ZONE's fill as the map shows it: its first contour, and how opaque it is.
    --- nil when there is none.
    function C.zoneFill()
        local ov = C.zone()[1]
        if not ov then return nil, 0.0 end
        return ov, C.opacity(ov)
    end

    --- How far the zone the map SHOWS is from the zone as the hold began, by the movie's
    --- own arithmetic (C.shown) against BR.StormZone at `t` 0 and `g` 0 -- what the map
    --- draws while the storm holds (2026-10-04): the worst distance of any shown point
    --- from that zone's boundary. math.huge when nothing of the zone is in the movie.
    function C.zoneErr(rec)
        local want = env.BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0, 0.0, 0.0)
        local worst, any = 0.0, false
        for _, ov in ipairs(C.zone()) do
            for _, p in ipairs(C.shown(ov)) do
                any = true
                worst = math.max(worst, math.abs(env.BR.StormShape.distance(want, p.x, p.y)))
            end
        end
        return any and worst or math.huge
    end

    --- Every area the map is DRAWING -- in the movie and not faded to nothing. A zone a
    --- sweep has faded out stays in the movie at alpha 0 until the next record's
    --- picture (2026-10-04), so "how many fills does the player see" is this, not
    --- #C.areas().
    function C.visible()
        local out = {}
        for _, ov in ipairs(C.mm.overlays) do
            if C.opacity(ov) > 0.0 then out[#out + 1] = ov end
        end
        return out
    end

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
    -- PAST ITS GROWTH: the union below is what an overlapping destination is grown
    -- into across the hold's first seconds (#344), and `server.grow` bills the growth.
    S.grown()
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
    --
    -- ASKED OF TWO CIRCLES, where the travel is one number (#344). The cushion is
    -- the zone 0.7 s either side of the tick now, not a speed, and for two
    -- concentric circles that is exactly the old (r0 - r1) / T of radius -- so the
    -- circle keeps the numbers it always had. Every zone a circle is the config's
    -- own `circle = 1.0`.
    local T = newStormServer()
    T.env.BR.Config.Storm.shape.circle = 1.0
    -- The zones hold 0.9 of their circles' area, so radii 1897 and 949: 949 m of
    -- radius surrendered in 10s is 94.9 m/s of wall, and the cushion is 10 + 66.4 =
    -- 76.4 metres for the whole sweep. A 1s hold in front of it, and each probe is
    -- taken 6000ms into the phase -- 5000ms into the sweep, half way.
    local trec = T.record(2, 0.0, 0.0, 2000.0, 0.0, 0.0, 1000.0,
        1000.0, 10000.0, 2.0)
    -- THE SHAPE AT THE MOMENT OF THE PROBE, which is the travelling wall rather
    -- than the record's opening circle: half way across, r 1500, centre unmoved.
    local moving = T.env.BR.StormZone(trec, 0.0, 0.0, 1500.0, 0.5)
    ok(moving.kind == 'circle' or (moving.hull and #moving.hull.ks == 1),
        'with every zone a circle, the moving wall is one', moving.kind)
    local function offMoving(m)
        return offBoundary(T.env, moving, moving.P * 0.21, m)
    end
    local x1, y1 = offMoving(50.0)
    local x2, y2 = offMoving(150.0)
    local x3, y3 = offMoving(70.0)
    T.at(6000); ok(T.hurts(x1, y1) == false,
        'fifty metres outside a wall doing 95 m/s is inside the moving cushion')
    T.at(6000); ok(T.hurts(x2, y2) == true,
        'a hundred and fifty metres outside it is not')
    T.at(6000); ok(T.hurts(x3, y3) == false,
        'and seventy metres out is still inside it, which the base ten-metre '
            .. 'cushion alone would have billed')
    ok(T.errored() == nil, 'the shrinking pass runs clean', T.errored())

    -- ═══ A MORPH: EACH STRETCH OF WALL'S OWN 0.7 s, NOT A CIRCLE'S (#344) ═══
    --
    -- A corner travelling to its partner moves two to four times the circle's edge
    -- speed the cushion used to add, so a player at the visible curtain beside a
    -- fast corner -- whose client clock runs a little behind -- was billed. Found
    -- here as the stretch of a real mid-sweep wall that travels furthest in 0.7 s,
    -- and a player stood off it by the OLD cushion and three metres more.
    local M = newStormServer()
    local mrec = M.record(3, 0.0, 0.0, 950.0, 120.0, 60.0, 520.0, 1000.0, 20000.0, 2.0)
    local SS = M.env.BR.StormShape
    local function zoneAtMs(ms)
        local cx, cy, r, _, _, _, t, g = M.env.BR.StormAt(mrec, mrec.tStart + ms)
        return M.env.BR.StormZone(mrec, cx, cy, r, t, g)
    end
    local Wnow, Wearly = zoneAtMs(11000.0), zoneAtMs(10300.0)
    local circle = 0.7 * (950.0 - 520.0) / 20.0
    local best, bx, by, bnx, bny = -math.huge, 0.0, 0.0, 1.0, 0.0
    for i = 0, 399 do
        local x, y, nx, ny = SS.pointAtArc(Wnow, Wnow.P * i / 400)
        local back = -SS.distance(Wearly, x, y)
        if back > best then best, bx, by, bnx, bny = back, x, y, nx, ny end
    end
    ok(best > circle + 6.0,
        'somewhere on a real mid-sweep wall a stretch travels further in 0.7 s than the '
            .. 'circle\'s edge the old cushion added',
        ('%.1f m against %.1f'):format(best, circle))
    local off = 10.0 + circle + 3.0
    local px, py = bx + bnx * off, by + bny * off
    ok(SS.distance(Wnow, px, py) > 10.0 + circle and SS.distance(Wearly, px, py) < 9.0,
        'a player off it by the old cushion and three metres is past what the old rule '
            .. 'allowed, and within ten metres of where that wall stood 0.7 s ago',
        ('%.1f m out now, %.1f then'):format(SS.distance(Wnow, px, py),
            SS.distance(Wearly, px, py)))
    M.at(11000); ok(M.hurts(px, py) == false,
        'and is not billed: the slack is that stretch of wall\'s own travel')
    local qx, qy = bx + bnx * (best + 20.0), by + bny * (best + 20.0)
    M.at(11000); ok(M.hurts(qx, qy) == true,
        'while twenty metres beyond where it stood 0.7 s ago still is -- the cushion is '
            .. 'ten metres of the zone as it was, not a licence')
    ok(M.errored() == nil, 'the morphing pass runs clean', M.errored())
end

-- ---------------------------------------------------------------------------
describe('server.ledger')
do
    -- A PLAYER OUTSIDE BOTH IS BILLED EXACTLY AS BEFORE, all the way to the
    -- elimination. The union changed WHERE the boundary is and nothing about
    -- what crossing it costs, so the ledger, the wire and the defeat still
    -- behave as they did -- which is worth an assertion because the inside
    -- branch of that test returns early, and a rule that returned early in the
    -- wrong direction would look like a player who is simply good at staying in
    -- the circle.
    --
    -- THE LEDGER IS THE ONE HEALTH LEDGER (#366). The storm takes its damage off
    -- `hp` -- the number a bullet comes off -- and takes EXACTLY the whole points
    -- it tells the ped to lose, so an honest bar and the ledger are the same
    -- number the moment the instruction lands.
    local S = newStormServer()
    S.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 6.0)

    local e = S.env.BR.Roster.get(1)
    e.pos = { x = 700.0, y = 0.0, z = 30.0 }   -- in the gap

    --- Display points the wire has told the subject to lose so far.
    local function sentTotal()
        local n = 0
        for _, h in ipairs(S.out) do
            if h.event == S.env.BR.Net.STORM_DAMAGE and h.target == 1 then
                n = n + h.payload.amount
            end
        end
        return n * 100.0 / (S.env.BR.Config.Match.maxHealth
            - S.env.BR.Config.Match.healthFloor)
    end

    S.tick()
    local first = e.hp
    ok(first < 100.0 and first == 100.0 - sentTotal(),
        'the health ledger drops on the first tick, by exactly what the ped was told',
        ('%s, sent %s'):format(tostring(first), tostring(sentTotal())))
    S.tick()
    ok(e.hp < first and e.hp == 100.0 - sentTotal(),
        'and runs down every tick they spend out there, in lock-step with the wire',
        ('%s -> %s, sent %s'):format(tostring(first), tostring(e.hp),
            tostring(sentTotal())))
    ok(e.stormHp == nil, 'and there is no second, storm-only ledger beside it')

    -- AND THE ELIMINATION STILL COMES FROM THE LEDGER. Sixteen more seconds at
    -- 6 dps takes 100 display points off, whatever the ped is doing.
    for _ = 1, 20 do S.tick() end
    ok(S.defeated[1] == true and e.hp == 0.0,
        'and the ledger kill still lands on a player who stays in the gap',
        tostring(e.hp))

    -- WALKING INTO THE FAR ISLAND STOPS IT, which is the whole feature seen
    -- from the ledger's side rather than from a boolean -- and NOTHING IS
    -- RESET: the health the storm already took stays taken (#373).
    local T = newStormServer()
    T.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 6.0)
    local f = T.env.BR.Roster.get(1)
    f.pos = { x = 700.0, y = 0.0, z = 30.0 }
    T.tick()
    local billed = f.hp
    ok(billed < 100.0 and f.lastStormAt ~= nil, 'a player in the gap is billed',
        tostring(billed))
    f.pos = { x = 1200.0, y = 0.0, z = 30.0 }
    f.lastStormAt = nil
    T.tick(); T.tick()
    ok(f.hp == billed and f.lastStormAt == nil,
        'and reaching the new destination stops the bill without undoing it',
        ('%s -> %s'):format(tostring(billed), tostring(f.hp)))
    ok(T.defeated[1] == nil, 'nobody is eliminated for having made the run')
end

-- ---------------------------------------------------------------------------
describe('server.healbase')
do
    -- ═══ THE KILL IS JUDGED ON WHAT THE BAR WILL SHOW (#366) ═══
    --
    -- A heal's target still on its way stands on the entry as a ceiling with its
    -- window, and the ledger follows the ped up to it a round trip late. A tick
    -- that empties that trailing ledger has not emptied the bar: the ceiling,
    -- less this tick, is what the bar is about to show. tools/test_roster.lua
    -- drives the real heals on a modeled line; this is the tick's own arithmetic.
    local S = newStormServer()
    S.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 400.0, 600000, 60000, 6.0)
    local e = S.roster[1]
    e.pos = { x = 900.0, y = 0.0, z = 30.0 }
    e.hp, e.grantHpTo, e.healUntil = 2.0, 20.0, S.now + 5000

    -- AND THE LEDGER IS NOT EMPTIED UNDER IT. A player left ALIVE on a ledger
    -- of zero was knocked by any hit at all, armor or no armor, because a hit
    -- is judged on the ledger: it stays where it stood instead.
    S.tick()
    ok(S.defeated[1] == nil and e.hp == 2.0 and e.grantHpTo == 14.0,
        'a tick that would empty a ledger still trailing a heal takes its points '
            .. 'off the ceiling, leaves the ledger where it stood, and kills nobody: '
            .. 'the bar is about to show 14',
        ('defeated %s, hp %s, ceiling %s'):format(tostring(S.defeated[1]),
            tostring(e.hp), tostring(e.grantHpTo)))

    -- ...BUT A CEILING IS ONLY A HEAL WHILE ITS WINDOW STANDS, AND ONLY ABOVE ZERO.
    S.tick(); S.tick()
    ok(S.defeated[1] == nil and e.grantHpTo == 2.0,
        'every tick comes off the ceiling, and they live while it is above zero',
        ('defeated %s, ceiling %s'):format(tostring(S.defeated[1]),
            tostring(e.grantHpTo)))
    S.tick()
    ok(S.defeated[1] == true and e.grantHpTo < 0.0,
        'and the tick that takes the ceiling itself past zero kills, exactly as '
            .. 'the ledger would', ('ceiling %s'):format(tostring(e.grantHpTo)))

    local T = newStormServer()
    T.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 400.0, 600000, 60000, 6.0)
    local f = T.roster[1]
    f.pos = { x = 900.0, y = 0.0, z = 30.0 }
    f.hp, f.grantHpTo, f.healUntil = 2.0, 20.0, T.now
    T.tick()
    ok(T.defeated[1] == true,
        'a ceiling whose window has closed is no heal at all: the ledger is the '
            .. 'whole answer')

    -- AND IT IS READ AS THE WHOLE POINT THE PED WILL SHOW. The client rounds a
    -- target onto its ped, so a ceiling the tick leaves at 0.4 is a bar on zero.
    local U = newStormServer()
    U.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 400.0, 600000, 60000, 6.0)
    local g = U.roster[1]
    g.pos = { x = 900.0, y = 0.0, z = 30.0 }
    g.hp, g.grantHpTo, g.healUntil = 2.0, 6.4, U.now + 5000
    U.tick()
    ok(U.defeated[1] == true and math.abs(g.grantHpTo - 0.4) < 1e-9,
        'a ceiling the tick leaves under half a point is a bar on zero, and kills',
        ('defeated %s, ceiling %s'):format(tostring(U.defeated[1]),
            tostring(g.grantHpTo)))

    -- AND A LEDGER KEPT OFF ZERO STOPS ON THE BAR WHEN THE BAR IS THE LOWER.
    local V = newStormServer()
    V.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 400.0, 600000, 60000, 6.0)
    local h = V.roster[1]
    h.pos = { x = 900.0, y = 0.0, z = 30.0 }
    h.hp, h.grantHpTo, h.healUntil = 5.0, 8.0, V.now + 5000
    V.tick()
    ok(V.defeated[1] == nil and h.hp == 2.0 and h.grantHpTo == 2.0,
        'a tick that would empty the ledger under a bar of 2 leaves it on 2, not '
            .. 'on the 5 it stood at',
        ('defeated %s, hp %s, ceiling %s'):format(tostring(V.defeated[1]),
            tostring(h.hp), tostring(h.grantHpTo)))
end

-- ---------------------------------------------------------------------------
describe('server.healpause')
do
    -- ═══ A HEALING CONSUMABLE'S CHANNEL PAUSES THE STORM FOR THAT PLAYER ═══
    --
    --   "During the duration of the consumption, they shall take no damage from
    --    the storm."                                    -- owner, 2026-10-02
    --
    -- The damage tick asks BR.Inv.healing, which server/inventory.lua answers
    -- from its own channel; tools/test_roster.lua drives the real one. Here it
    -- is stubbed, so this block is about the tick: a paused player is neither
    -- billed, told, stamped nor carried, a player beside them in the same wall
    -- is billed as ever, and a DOWNED player bleeds whatever the answer.
    local S = newStormServer()
    local env = S.env
    S.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 400.0, 600000, 60000, 6.0)
    local healing = { [1] = true }
    env.BR.Inv = { healing = function(src) return healing[src] == true end }

    local e = S.roster[1]
    e.pos = { x = 900.0, y = 0.0, z = 30.0 }
    S.roster[2] = {
        matchId = 1, name = 'Beside', state = env.BR.PlayerState.ALIVE,
        hp = 100.0, pos = { x = 900.0, y = 5.0, z = 30.0 },
    }

    --- STORM_DAMAGE sends to one player so far.
    local function told(src)
        local n = 0
        for _, h in ipairs(S.out) do
            if h.event == env.BR.Net.STORM_DAMAGE and h.target == src then n = n + 1 end
        end
        return n
    end

    S.tick(); S.tick(); S.tick()
    ok(e.hp == 100.0 and e.lastStormAt == nil and told(1) == 0
        and (S.match.stormCarry[1] or 0.0) == 0.0,
        'a healing player outside the wall is not billed, told, stamped or carried',
        ('hp %s, told %d'):format(tostring(e.hp), told(1)))
    ok(S.roster[2].hp < 100.0 and told(2) == 3,
        'while the player beside them in the same wall is billed every tick',
        ('hp %s, told %d'):format(tostring(S.roster[2].hp), told(2)))

    -- THE CHANNEL ENDS, THE NEXT TICK BILLS.
    healing[1] = nil
    S.tick()
    ok(e.hp < 100.0 and e.lastStormAt ~= nil and told(1) == 1,
        'and the first tick after the channel ends bills them as before',
        ('hp %s, told %d'):format(tostring(e.hp), told(1)))

    -- A DOWNED PLAYER BLEEDS. The downed check comes first: a body in the wall
    -- is not healing anything, whatever the inventory last said.
    healing[1] = true
    e.state = env.BR.PlayerState.DBNO
    S.bled[1] = nil
    S.tick()
    ok((S.bled[1] or 0.0) > 0.0,
        'and a downed player bleeds in the wall whatever their hands were doing',
        tostring(S.bled[1]))
    ok(S.errored() == nil, 'the paused passes run clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('server.exposed')
do
    -- ═══ "WOULD THE STORM BILL THIS PLAYER NOW", ASKED OF THE TICK ITSELF ═══
    --
    -- server/ambheal.lua refuses to start a heal in the back of an ambulance
    -- while this says yes (#366). It must answer exactly as the damage tick
    -- would: the same zone and cushion, ALIVE only, never a rescue rider, and
    -- nobody at all while the storm bills nobody.
    local S = newStormServer()
    local env = S.env
    local e = S.roster[1]
    S.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 400.0, 600000, 60000, 6.0)

    e.pos = { x = 900.0, y = 0.0, z = 30.0 }
    ok(env.BR.Storm.exposed(e) == true and S.hurts(900.0, 0.0) == true,
        'a player the tick bills is exposed')
    e.pos = { x = 0.0, y = 0.0, z = 30.0 }
    ok(env.BR.Storm.exposed(e) == false and S.hurts(0.0, 0.0) == false,
        'and one inside the zone is not, exactly as the tick has it')

    -- ACROSS THE EDGE, POINT BY POINT: the two answers never disagree, cushion
    -- included, wherever the zone's own shape puts the line.
    local disagree, billed, spared = 0, 0, 0
    for x = 300.0, 520.0, 4.0 do
        e.hp = 100.0
        e.pos = { x = x, y = 0.0, z = 30.0 }
        local said = env.BR.Storm.exposed(e, S.now + 1000)
        local hurt = S.hurts(x, 0.0)
        if said ~= hurt then disagree = disagree + 1 end
        if hurt then billed = billed + 1 else spared = spared + 1 end
    end
    ok(disagree == 0 and billed > 0 and spared > 0,
        'and walked across the edge, exposed() and the tick agree at every point',
        ('%d disagreements, %d billed, %d spared'):format(disagree, billed, spared))

    e.pos = { x = 900.0, y = 0.0, z = 30.0 }
    e.rescue = true
    ok(env.BR.Storm.exposed(e) == false, 'a rescue rider is never exposed')
    e.rescue = nil
    e.state = env.BR.PlayerState.DBNO
    ok(env.BR.Storm.exposed(e) == false,
        'nor a downed player -- the question is only asked of the living')
    e.state = env.BR.PlayerState.ALIVE

    S.record(1, 0.0, 0.0, 400.0, 0.0, 0.0, 300.0, 600000, 60000, 0.5)
    ok(env.BR.Storm.exposed(e) == false,
        'and through phase 1\'s free-loot hold nobody is: the storm bills nobody')

    -- POSITIONAL, NOT A RECORD OF THE LAST BILL. A heal pausing the storm, or a
    -- revive clearing its stamp, changes nothing about where they stand.
    S.record(2, 0.0, 0.0, 400.0, 0.0, 0.0, 400.0, 600000, 60000, 6.0)
    env.BR.Inv = { healing = function() return true end }
    e.lastStormAt = nil
    ok(env.BR.Storm.exposed(e) == true and e.lastStormAt == nil,
        'a player outside is exposed whether or not the last tick billed them')
    env.BR.Inv = nil
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
    C.grown()     -- the union the growth ends on (#344); `grow.agree` has the growth
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
    -- ═══ THE WAY-HOME ARROW AIMS AT THE DESTINATION'S REAL BORDER (#344), AND STILL
    --     AT THE DESTINATION RATHER THAN THE UNION (#328) ═══
    --
    --   "it seems our "Safe zone - this way" blip is still drawn based on diameter,
    --    not storm border."                             -- the owner, 2026-09-23
    --
    -- It showed when the player was further than r1 from the target's centre and sat
    -- at r1 - 25 along the line to it: a circle's answer, on a destination that is a
    -- shape stretched up to 3:1. Now it shows EXACTLY when the player is outside the
    -- destination's real boundary, sits 25 m inside that boundary at the point nearest
    -- them, and points there.
    --
    -- AND IT STILL AIMS AT THE DESTINATION, NOT THE UNION. The instinct after #328 is to
    -- measure it against the union like the edge; that would point it at the CURRENT
    -- zone's rim on every ordinary nested phase, away from the destination the player
    -- is being asked to rotate to, and on a disjoint pair it would swap islands as they
    -- crossed the middle. This block is what makes that change fail rather than ship.
    local C = newStormClient()
    local env = C.env
    local SS = env.BR.StormShape
    -- Disjoint: current r 400 at the origin, target r 300 at 1200 m.
    local rec = C.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 4.0)
    local target = env.BR.StormTarget(rec)
    local inner = SS.inset(target, 25.0)

    --- Where the arrow should be for a player at (x, y), asked a DIFFERENT way from the
    --- renderer: walk the eroded destination's boundary densely and take the nearest.
    local function nearestOnInner(x, y)
        local P = SS.perimeter(inner)
        local best, bx, by = math.huge, nil, nil
        for k = 0, 4000 do
            local qx, qy = SS.pointAtArc(inner, P * k / 4000)
            local d = (qx - x) ^ 2 + (qy - y) ^ 2
            if d < best then best, bx, by = d, qx, qy end
        end
        return bx, by, math.sqrt(best)
    end

    -- Standing safely in the CURRENT zone, outside the target.
    C.pedAt = pt(0.0, 0.0)
    C.tick(2)
    local a = C.arrow()
    ok(a ~= nil,
        'a player safe in the current zone of a separated pair still gets the arrow, '
            .. 'because the destination is still somewhere else')
    local wx, wy, wd = nearestOnInner(0.0, 0.0)
    ok(a ~= nil and near(SS.distance(target, a.x, a.y), -25.0, 1e-6)
            and math.sqrt((a.x - wx) ^ 2 + (a.y - wy) ^ 2) < 1.0
            and near(math.sqrt(a.x ^ 2 + a.y ^ 2), wd, 0.5),
        'and it sits 25 m inside the destination\'s REAL boundary, at the point of it '
            .. 'nearest the player -- ACROSS THE GAP, not back at the current zone '
            .. 'behind them',
        a and ('(%.2f, %.2f), %.6f m from the border; walked nearest (%.2f, %.2f)')
            :format(a.x, a.y, SS.distance(target, a.x, a.y), wx, wy))
    local wantRot = a and (math.floor(env.BR.GtaHeading(
        env.BR.Bearing(0.0, 0.0, a.x, a.y)) + 0.5) % 360)
    ok(a ~= nil and a.rot == wantRot,
        'and it points AT that point -- the place to head for, not the centre',
        a and ('%s against %s'):format(tostring(a.rot), tostring(wantRot)))
    ok(C.last() ~= nil and C.last().edgeDistance < 0.0,
        'while the edge readout says they are safe where they stand -- the two '
            .. 'answer different questions on purpose',
        C.last() and C.last().edgeDistance)

    -- AND IT GOES AWAY ON ARRIVAL, not on becoming safe. A player who crosses to the
    -- far island is inside the target, so there is nothing left to guide them to.
    C.pedAt = pt(1200.0, 0.0)
    C.tick(2)
    ok(SS.distance(target, 1200.0, 0.0) < 0.0 and C.arrow() == nil,
        'reaching the destination takes the arrow away')

    -- NO FLIP IN THE MIDDLE. Walked across the gap, the arrow keeps naming one place:
    -- every sample is on the eroded destination, the point of it nearest the walker,
    -- and never once on the zone behind.
    local D = newStormClient()
    D.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 4.0)
    local flips, lastX = 0, nil
    for x = 0, 800, 50 do
        D.pedAt = pt(x + 0.0, 0.0)
        D.tick(1)
        local b = D.arrow()
        local nx, ny = nearestOnInner(x + 0.0, 0.0)
        if not b or math.abs(SS.distance(target, b.x, b.y) + 25.0) > 1e-6
                or math.sqrt((b.x - nx) ^ 2 + (b.y - ny) ^ 2) > 1.0 then
            flips = flips + 1
        end
        lastX = b and b.x or nil
    end
    ok(flips == 0,
        'and walking the whole gap never makes it change its mind about which island '
            .. 'it is naming',
        ('%d samples off the destination, last at %s'):format(flips, tostring(lastX)))

    -- ═══ EXACTLY WHEN OUTSIDE THE REAL BORDER, ON A LONG DESTINATION ═══
    --
    -- The radius rule's failure is a long shape: players all the same distance from
    -- its centre are inside it off its ends and outside it off its sides. So they are
    -- stood round a stretched destination on one circle about its centre, and the
    -- arrow must be there for exactly those outside it -- and sit 25 m inside it.
    local L = newStormClient()
    local lrec = L.record(2, 0.0, 0.0, 2600.0, 300.0, 200.0, 1600.0, 600000, 60000, 1.25)
    local seed = nil
    for s = 1, 400 do
        local u = L.env.BR.StormUnit(s, 2)
        if u.kind == 'polygon' and u.stretch >= 2.5 then seed = s break end
    end
    ok(seed ~= nil, 'the shipping config draws a zone stretched past 2.5:1 on some seed')
    lrec.seed = seed or 1
    local ltarget = L.env.BR.StormTarget(lrec)
    local ring = 1600.0
    local shown, wrong, off, inside = 0, 0, 0.0, 0
    for k = 0, 71 do
        local ang = k * math.pi / 36
        local x, y = 300.0 + ring * math.cos(ang), 200.0 + ring * math.sin(ang)
        L.pedAt = pt(x, y)
        L.tick(1)
        local out = SS.distance(ltarget, x, y) > 0.0
        local b = L.arrow()
        if out ~= (b ~= nil) then wrong = wrong + 1 end
        if not out then inside = inside + 1 end
        if b then
            shown = shown + 1
            off = math.max(off, math.abs(SS.distance(ltarget, b.x, b.y) + 25.0))
        end
    end
    ok(wrong == 0 and shown > 0 and inside > 0,
        'players on one circle about a stretched destination get the arrow exactly '
            .. 'when they are outside its real border -- some of them are inside it at '
            .. 'that distance and some are not, which the radius rule could not tell',
        ('%d wrong of 72; %d shown, %d inside'):format(wrong, shown, inside))
    ok(off < 1e-6,
        'and every arrow sits 25 m inside that border, to a micrometre',
        ('worst %.3e m off'):format(off))
    ok(C.errored() == nil and D.errored() == nil and L.errored() == nil,
        'and the arrow runs clean on every client here',
        C.errored() or D.errored() or L.errored())
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

    -- r 950 at the origin closing on r 520 at 1000: well inside 950 + 520, so the
    -- two boundaries genuinely cross at the first frame.
    --
    -- IT WAS 1350, THEN 1150, AND THE ZONES BEING THEIR OWN SHAPES IS WHY IT MOVED.
    -- At 1350 the CIRCLES overlap by 120 m, and so did the shapes while both wore one
    -- unit; drawn by area and stretched (#344 round 2), zone 3's and zone 4's shapes at
    -- this seed overlap at 1150 by less than the twelve metres the wall's inset takes
    -- off the two of them together, so the curtain drawn six metres inside each is
    -- honestly two loops at the first frame. That is geometry rather than the stitch --
    -- `blob.stitch.sweep` is the stitch -- and this assertion is about a pair that
    -- overlaps.
    local bFlips, bEnd, bFirst = loopsAcross(4, 0, 0, 950, 1000, 0, 520, 75000, 187500)
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
    C.grown()     -- the union the growth ends on (#344); `grow.agree` has the growth
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
    -- past its growth (#344): the union a conjoined destination is grown into
    C.grown()
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
    -- PAST ITS GROWTH (#344): this hand-placed pair is not nested by real shape at
    -- this seed, and the zone this block measures is the one its growth ends on.
    D.grown()
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
    -- THE RECORD'S WALL ALONE. Through phase 1 the #340 preview -- circle 1's wall --
    -- is in frame beside it (#344 draws both); both walls are correct and their union
    -- is not one wall, which is all C.recordWallOnly says.
    F.recordWallOnly()
    local frec = F.record(1, 0.0, 0.0, 2600.0, 400.0, 0.0, 1600.0, 600000, 60000, 0.5)
    F.pedAt = pt(0.0, 0.0, 30.0)
    -- HALF WAY UP THE OPENING WALL'S RAMP, which runs over the hold's FIRST fadeInSec
    -- since #344 (storm.wall's wallRamp). C.frame adds its 16 ms before it draws.
    frec.tStart = F.now - rr.fadeInSec * 1000.0 * 0.5
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
    -- and a phase-1 record is on it for the first fadeInSec of every hold, which is
    -- the moment a block like this one builds its record.
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
    -- HALF WAY UP THE OPENING WALL'S RAMP: the hold's first fadeInSec (#344).
    brec.tStart = B.now - rr.fadeInSec * 1000.0 * 0.5
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
    -- past its growth (#344): the union a conjoined destination is grown into
    BS.grown()
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
    -- past its growth (#344): the union a conjoined destination is grown into
    V.grown()
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
    -- past its growth (#344): the union a conjoined destination is grown into
    W.grown()
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
describe('wall.whole')
do
    -- ═══ EVERY QUAD IS DRAWN EVERY FRAME, WHEREVER THE CAMERA IS (#393) ═══
    --
    -- Round 1 of #393 skipped the quads outside a wedge built from the rendered
    -- camera. Those natives describe the frame BEFORE, so a camera cut, a flick at a
    -- low frame rate or a scope released in one frame drew a frame with wall
    -- missing. client/storm.lua's draw loop says why no cull is safe and why a
    -- distance LOD would move the wall; this block pins that the picture does not
    -- depend on the camera at all.
    --
    -- So every camera native a cull would read IS here, answering for cameras all
    -- round the circle, pitched from straight down to straight up, zoomed from a
    -- scope's 1.5 degrees to 130, rolled, from the middle of the zone, at its wall
    -- and outside it -- and every frame must draw exactly the triangles a client
    -- with no camera natives at all draws, argument for argument, in the same order.
    local function camClient(cam)
        local C = newStormClient()
        C.cam = cam
        local function coord() return pt(C.cam.x, C.cam.y, C.cam.z) end
        local function rot() return { x = C.cam.pitch, y = C.cam.roll, z = C.cam.yaw } end
        local function fov() return C.cam.fov end
        C.env.GetFinalRenderedCamCoord, C.env.GetGameplayCamCoord = coord, coord
        C.env.GetFinalRenderedCamRot, C.env.GetGameplayCamRot = rot, rot
        C.env.GetFinalRenderedCamFov, C.env.GetGameplayCamFov = fov, fov
        C.env.GetAspectRatio = function() return 16.0 / 9.0 end
        return C
    end
    --- Where the frame's triangles first part from the reference's, or nil.
    local function differs(polys, ref)
        if #polys ~= #ref then return ('%d triangles against %d'):format(#polys, #ref) end
        for i = 1, #ref do
            local t, r = polys[i], ref[i]
            if t.r ~= r.r or t.g ~= r.g or t.b ~= r.b or t.a ~= r.a or t.tex ~= r.tex then
                return ('triangle %d has another colour or texture'):format(i)
            end
            for v = 1, 3 do
                local a, b = t[v], r[v]
                if a.x ~= b.x or a.y ~= b.y or a.z ~= b.z or a.u ~= b.u or a.v ~= b.v then
                    return ('triangle %d is not the reference one'):format(i)
                end
            end
        end
        return nil
    end
    -- Phase 1's hold: two walls, the opening zone's and circle 1's.
    local function hold(C)
        local rec = C.record(1, 0.0, 0.0, 2600.0, 400.0, 0.0, 1600.0, 600000, 60000, 0.5)
        rec.tStart = C.now - 300000
    end

    local viewers = {
        { label = 'in the middle of the zone', x = 0.0, y = 0.0 },
        { label = 'at its wall', x = 2585.0, y = 0.0 },
        { label = 'outside it', x = 3400.0, y = 900.0 },
    }
    -- Every heading in 30-degree steps, every pitch and every zoom below, each
    -- frame a cut from the one before: 36 cameras a viewer, so each pitch and each
    -- zoom meets several headings without a full cross product.
    local fovs = { 1.5, 8.0, 50.0, 90.0, 130.0 }
    local pitches = { -89.0, -70.0, -50.0, -30.0, -10.0, 0.0, 15.0, 45.0, 70.0, 89.0 }
    local CAMS = 36

    local frames, bad, walls = 0, nil, nil
    for _, v in ipairs(viewers) do
        local R = newStormClient()
        hold(R)
        R.pedAt = pt(v.x, v.y, 30.0)
        R.settlePreview()
        R.frame()
        local ref = R.polys
        local alphas, nAlpha = {}, 0
        for _, t in ipairs(R.polys) do
            if not alphas[t.a] then alphas[t.a] = true nAlpha = nAlpha + 1 end
        end
        walls = math.min(walls or nAlpha, nAlpha)

        local C = camClient({ x = v.x, y = v.y - 4.0, z = 32.0, yaw = 0.0, pitch = 0.0,
                              roll = 0.0, fov = 50.0 })
        hold(C)
        C.pedAt = pt(v.x, v.y, 30.0)
        C.settlePreview()
        for i = 0, CAMS - 1 do
            C.cam.yaw = -180.0 + 30.0 * (i % 12)
            C.cam.pitch = pitches[i % #pitches + 1]
            C.cam.fov = fovs[i % #fovs + 1]
            C.cam.roll = (i % 7 == 3) and 5.0 or 0.0
            C.frame()
            frames = frames + 1
            local why = differs(C.polys, ref)
            if why and not bad then
                bad = ('%s, yaw %d pitch %d fov %.1f: %s'):format(v.label, C.cam.yaw,
                    C.cam.pitch, C.cam.fov, why)
            end
        end
        ok(C.errored() == nil, ('the walls run clean with every camera, %s'):format(v.label),
            C.errored())
    end
    ok(walls == 2, 'the reference is phase 1\'s hold: both walls are in every frame',
        ('%s walls by alpha'):format(tostring(walls)))
    ok(bad == nil and frames == #viewers * CAMS,
        'every camera -- any heading, pitched from straight down to straight up, '
            .. 'zoomed from a scope to 130 degrees, rolled or level, cut to from the '
            .. 'frame before -- draws exactly the wall a client with no camera draws',
        bad or ('%d frames'):format(frames))
end

-- ---------------------------------------------------------------------------
describe('wall.busview')
do
    -- ═══ ON THE BUS, A QUAD BEHIND THE CAMERA IS NOT SUBMITTED -- AND NOTHING IN
    --     VIEW GOES MISSING (#393) ═══
    --
    -- `wall.whole` above pins that the ENGINE's camera changes nothing. This is the
    -- one camera that is not the engine's: bus.fly places the orbit camera itself,
    -- so client/storm.lua leaves out of circle 1's wall the quads wholly behind it.
    -- What has to hold, over a thousand camera poses:
    --
    --   * NOTHING NEW. Every triangle drawn is one the uncut wall draws, with the same
    --     arguments, in the same order.
    --   * NOTHING IN VIEW IS LOST. Every triangle of the uncut wall that reaches the
    --     screen -- clipped exactly against the frustum of either pose, at the bus
    --     camera's 65 degrees and at 130 across three monitors, directly and in the
    --     water's mirror at sea level and on a hill lake -- is drawn. The frustum
    --     here is written from scratch rather than borrowed from the production test.
    --   * A CUT LATER IN THE FRAME PUTS THE REST BACK: BR.Storm.cameraCut draws
    --     exactly the skipped triangles, once, on that frame and no other.
    --   * AND ANY DOUBT IS THE OLD WALL: no camera rendering, no pose, no frame
    --     counter or a pose with no direction all draw every quad.
    local CCX, CCY, CR = 500.0, 0.0, 1600.0
    local CAM = 7

    local function newBus(px, py, pz)
        local C = newStormClient()
        local env = C.env
        local MS, PS = env.BR.MatchState, env.BR.PlayerState
        env.BR.State.storm = nil
        env.BR.State.match.state = MS.BUS
        env.BR.State.me.state    = PS.BUS
        env.BR.State.stormPreview = { cx = CCX, cy = CCY, r = CR }
        C.fire('br:env:world', false)
        C.pedAt = pt(px, py, pz)
        C.fc, C.rendering, C.bus = 0, {}, nil
        env.GetFrameCount  = function() return C.fc end
        env.IsCamRendering = function(c) return C.rendering[c] == true end
        env.BR.Bus = { camPose = function()
            local b = C.bus
            if not b then return nil end
            return b.cam, b.cur, b.prev
        end }
        local step = C.frame
        function C.frame() C.fc = C.fc + 1 step() end
        C.settlePreview()
        return C
    end

    --- bus.fly's orbit: camDistance behind and camHeight above the plane at
    --- (px, py, pz), turned `yaw` degrees round it and pitched, looking at the plane
    --- plus four meters.
    local BUS = newStormClient().env.BR.Config.Bus
    local function pose(px, py, pz, yaw, pitch)
        local yr, pr = math.rad(yaw), math.rad(pitch)
        local horiz = BUS.camDistance * math.cos(pr)
        return { x = px - math.sin(yr) * horiz, y = py + math.cos(yr) * horiz,
                 z = pz + BUS.camHeight - BUS.camDistance * math.sin(pr),
                 tx = px, ty = py, tz = pz + 4.0 }
    end

    local function key(t)
        local parts = {}
        for v = 1, 3 do
            local p = t[v]
            parts[#parts + 1] = ('%a,%a,%a,%s,%s'):format(p.x, p.y, p.z,
                tostring(p.u), tostring(p.v))
        end
        return table.concat(parts, ';')
            .. ('|%s|%s'):format(tostring(t.a), tostring(t.tex))
    end

    --- Does the triangle reach the screen of a camera at `ps`, with vertical field
    --- `vfov` and `aspect`? Sutherland-Hodgman against the near plane and the four
    --- sides, in the camera's own frame: anything left over is on screen.
    local function onScreen(tri, ps, vfov, aspect)
        local fx, fy, fz = ps.tx - ps.x, ps.ty - ps.y, ps.tz - ps.z
        local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
        fx, fy, fz = fx / fl, fy / fl, fz / fl
        -- right = forward x world up; up = right x forward
        local rx, ry = fy, -fx
        local rl = math.sqrt(rx * rx + ry * ry)
        rx, ry = rx / rl, ry / rl
        local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
        local ty = math.tan(math.rad(vfov) / 2.0)
        local tx = ty * aspect
        local poly = {}
        for i = 1, 3 do
            local dx, dy, dz = tri[i][1] - ps.x, tri[i][2] - ps.y, tri[i][3] - ps.z
            poly[i] = { dx * rx + dy * ry, dx * ux + dy * uy + dz * uz,
                        dx * fx + dy * fy + dz * fz }
        end
        local planes = {
            function(p) return p[3] - 0.05 end,
            function(p) return p[3] * tx - p[1] end,
            function(p) return p[3] * tx + p[1] end,
            function(p) return p[3] * ty - p[2] end,
            function(p) return p[3] * ty + p[2] end,
        }
        for _, f in ipairs(planes) do
            local out = {}
            local n = #poly
            for i = 1, n do
                local a, b = poly[i], poly[i % n + 1]
                local fa, fb = f(a), f(b)
                if fa >= 0 then out[#out + 1] = a end
                if (fa >= 0) ~= (fb >= 0) then
                    local s = fa / (fa - fb)
                    out[#out + 1] = { a[1] + (b[1] - a[1]) * s, a[2] + (b[2] - a[2]) * s,
                                      a[3] + (b[3] - a[3]) * s }
                end
            end
            poly = out
            if #poly == 0 then return false end
        end
        return true
    end

    --- On screen from `ps` at all: directly, or mirrored in water at sea level or on
    --- a lake 300 m up, at the bus camera's field or the widest screen.
    local MIRRORS = { false, 0.0, 300.0 }
    local FIELDS = { { 65.0, 16.0 / 9.0 }, { 130.0, 48.0 / 9.0 } }
    local function inView(t, ps)
        for _, w in ipairs(MIRRORS) do
            local tri = {}
            for v = 1, 3 do
                local z = t[v].z
                if w then z = 2.0 * w - z end
                tri[v] = { t[v].x, t[v].y, z }
            end
            for _, fd in ipairs(FIELDS) do
                if onScreen(tri, ps, fd[1], fd[2]) then return true end
            end
        end
        return false
    end

    local function multiset(polys, from, to)
        local m = {}
        for i = from, to do
            local k = key(polys[i])
            m[k] = (m[k] or 0) + 1
        end
        return m
    end

    -- Where the plane is: over circle 1, at its rim, kilometers off, and low.
    local spots = {
        { label = 'over circle 1', x = 300.0, y = 200.0, z = 500.0 },
        { label = 'at its rim', x = CCX + CR - 30.0, y = 0.0, z = 500.0 },
        { label = 'three kilometers off', x = CCX - CR - 3000.0, y = 900.0, z = 500.0 },
        { label = 'low over the ground', x = CCX + 200.0, y = -CR - 400.0, z = 60.0 },
    }
    local pitches = { -75.0, -40.0, -8.0, 0.0, 25.0 }
    local poses, newBad, lostBad, cutBad, twiceBad = 0, nil, nil, nil, nil
    local skippedInside, totalInside = 0, 0
    local skippedLevel, totalLevel = 0, 0
    local errs = nil
    for _, s in ipairs(spots) do
        local C = newBus(s.x, s.y, s.z)
        C.frame()
        local ref = C.polys
        local refKeys = {}
        for i, t in ipairs(ref) do refKeys[i] = key(t) end
        local want = multiset(ref, 1, #ref)
        for yaw = 0, 350, 10 do
            for _, pitch in ipairs(pitches) do
                poses = poses + 1
                local cur = pose(s.x, s.y, s.z, yaw, pitch)
                -- The frame before: the orbit seven degrees back, the plane a frame's
                -- flight behind.
                local prev = pose(s.x - 1.5, s.y, s.z, yaw - 7.0, pitch)
                C.bus = { cam = CAM, cur = cur, prev = prev }
                C.rendering[CAM] = true
                C.frame()
                local drawn = C.polys
                local n0 = #drawn
                local where = ('%s, yaw %d pitch %d'):format(s.label, yaw, pitch)

                -- NOTHING NEW, IN ORDER: the drawn keys are a subsequence of the uncut.
                local j = 1
                for i = 1, n0 do
                    local k = key(drawn[i])
                    while j <= #refKeys and refKeys[j] ~= k do j = j + 1 end
                    if j > #refKeys and not newBad then
                        newBad = ('%s: triangle %d is not the uncut wall\'s, in its '
                            .. 'order'):format(where, i)
                    end
                    j = j + 1
                end

                -- NOTHING IN VIEW IS LOST.
                local have = multiset(drawn, 1, n0)
                for i, t in ipairs(ref) do
                    if not have[refKeys[i]] and not lostBad
                        and (inView(t, cur) or inView(t, prev)) then
                        lostBad = ('%s: triangle %d is on screen and was not drawn')
                            :format(where, i)
                    end
                end
                if s.label == 'over circle 1' then
                    skippedInside = skippedInside + (#ref - n0)
                    totalInside = totalInside + #ref
                    if pitch == -8.0 then
                        skippedLevel = skippedLevel + (#ref - n0)
                        totalLevel = totalLevel + #ref
                    end
                end

                -- THE CUT PUTS BACK EXACTLY THE REST, ONCE.
                C.env.BR.Storm.cameraCut()
                local all = multiset(C.polys, 1, #C.polys)
                local same = #C.polys == #ref
                for k, n in pairs(want) do if all[k] ~= n then same = false end end
                if not same and not cutBad then
                    cutBad = ('%s: %d drawn, %d after the cut, %d in the uncut wall')
                        :format(where, n0, #C.polys, #ref)
                end
                local n1 = #C.polys
                C.env.BR.Storm.cameraCut()
                if #C.polys ~= n1 and not twiceBad then
                    twiceBad = ('%s: a second cut drew %d more'):format(where, #C.polys - n1)
                end
            end
        end
        errs = errs or C.errored()
    end
    ok(errs == nil, 'the preview runs clean under every bus camera', errs)
    ok(newBad == nil, 'under the bus camera every triangle drawn is the uncut wall\'s, '
        .. 'with its arguments and in its order', newBad or ('%d poses'):format(poses))
    ok(lostBad == nil, 'and every triangle that reaches the screen from either pose -- '
        .. 'at 65 degrees or 130 across 48:9, directly or in the water -- is drawn',
        lostBad or ('%d poses'):format(poses))
    ok(cutBad == nil, 'a camera cut later in the frame draws exactly what was left out',
        cutBad)
    ok(twiceBad == nil, 'and a second cut in the same frame draws nothing more', twiceBad)
    -- AND IT IS WORTH HAVING. At the pitch a ride starts at (bus.fly's -8, which looks
    -- about twenty degrees down at the plane) a third of circle 1 is behind the camera
    -- even after the water's mirror is allowed for; pitched at the ground almost none
    -- is, because the skirt and its reflection are then in front of the lens.
    ok(totalLevel > 0 and skippedLevel / totalLevel >= 0.3,
        'and it is worth having: over circle 1, at the pitch a ride starts at, '
            .. 'three tenths or more of the wall is not submitted, averaged round the orbit',
        ('%d of %d'):format(skippedLevel, totalLevel))
    ok(totalInside > 0 and skippedInside / totalInside >= 0.2,
        'and a fifth or more at every pitch the orbit allows, from the ground to the sky',
        ('%d of %d'):format(skippedInside, totalInside))

    -- ─── any doubt is the whole wall ───
    local C = newBus(300.0, 200.0, 500.0)
    C.frame()
    local ref = {}
    for i, t in ipairs(C.polys) do ref[i] = key(t) end
    local function whole(label)
        C.frame()
        local same = #C.polys == #ref
        for i = 1, math.min(#ref, #C.polys) do
            if key(C.polys[i]) ~= ref[i] then same = false end
        end
        ok(same, label, ('%d triangles against %d'):format(#C.polys, #ref))
    end
    local aimed = pose(300.0, 200.0, 500.0, 0.0, -8.0)
    C.bus = { cam = CAM, cur = aimed, prev = aimed }
    C.rendering[CAM] = false
    whole('a bus camera the engine is not rendering culls nothing')
    C.rendering[CAM] = true
    C.bus = nil
    whole('no pose from client/bus.lua culls nothing')
    C.bus = { cam = CAM, cur = { x = 1.0, y = 2.0, z = 3.0, tx = 1.0, ty = 2.0, tz = 3.0 },
              prev = aimed }
    whole('a pose with no direction culls nothing')
    C.bus = { cam = CAM, cur = aimed, prev = aimed }
    local fc = C.env.GetFrameCount
    C.env.GetFrameCount = nil
    whole('a build without GetFrameCount culls nothing')
    C.env.GetFrameCount = fc

    -- ─── a cut on a later frame owes that frame nothing ───
    C.frame()
    ok(#C.polys < #ref, 'precondition: this pose leaves part of the wall out',
        ('%d of %d'):format(#C.polys, #ref))
    C.fc = C.fc + 1                -- the next frame, before the wall has drawn
    local n0 = #C.polys
    C.env.BR.Storm.cameraCut()
    ok(#C.polys == n0, 'a cut on the frame after draws nothing of the frame before -- '
        .. 'that frame draws its own wall whole, and the old remainder on top would '
        .. 'double it', ('%d drawn'):format(#C.polys - n0))
    C.bus = nil
    C.frame()
    n0 = #C.polys
    C.env.BR.Storm.cameraCut()
    ok(#C.polys == n0 and n0 == #ref,
        'and a cut after a whole frame draws nothing more',
        ('%d then %d'):format(n0, #C.polys))

    -- ═══ camera.switch: ANY CAMERA SWITCH, ANYWHERE IN THE FRAME, IS A CUT (#393) ═══
    --
    -- THE REVIEW'S CASE. An admin riding the bus starts a console spectate. The
    -- session arrives by net event; client/spectate.lua's camera callback, which is
    -- later in the FRAME band than storm.previewWall (fxmanifest: storm.lua at 382,
    -- spectate.lua at 628), makes its camera and renders it on a frame the preview has
    -- already culled for the bus's -- and nothing told storm.lua. So the cut is no
    -- longer something a site has to remember: client/storm.lua wraps every native
    -- that changes which camera renders, and `camera.class` below holds br_core to
    -- calling them through the wrapper. What is proved here is what a call does:
    --
    --   * LATER IN THE FRAME than the draw (a callback registered after storm.lua's,
    --     as spectate.camera is): the frame holds the whole wall, each quad once.
    --   * EARLIER IN THE FRAME (a net event before the band): that frame's draw
    --     culls nothing, even with IsCamRendering still saying the bus's camera.
    --   * EASED (a blend of two poses for its length): nothing is culled against that
    --     ride's camera again, and the next ride culls as before.
    --   * A CAMERA CREATED INACTIVE switches nothing, and costs the cull nothing.
    describe('camera.switch')
    local SPOT = { x = 300.0, y = 200.0, z = 500.0 }
    local AIM = pose(SPOT.x, SPOT.y, SPOT.z, 0.0, -8.0)
    local OTHER = 55

    --- A rider at SPOT whose bus camera is posed at AIM, with a FRAME callback after
    --- client/storm.lua's that runs `C.later(env)` once when it is set.
    local function rider()
        local R = newBus(SPOT.x, SPOT.y, SPOT.z)
        R.frame()
        R.want, R.n = multiset(R.polys, 1, #R.polys), #R.polys
        R.bus = { cam = CAM, cur = AIM, prev = AIM }
        R.rendering[CAM] = true
        R.later = nil
        R.env.BR.Loop.register(R.env.BR.Loop.FRAME, 'test.laterCamera', function()
            local f = R.later
            R.later = nil
            if f then f(R.env) end
        end)
        return R
    end
    local function wholeIn(R)
        if #R.polys ~= R.n then return false end
        local have = multiset(R.polys, 1, #R.polys)
        for k, n in pairs(R.want) do if have[k] ~= n then return false end end
        return true
    end
    local function said(R) return ('%d of %d drawn'):format(#R.polys, R.n) end

    local CALLS = {
        { 'SetCamActive', 'cut', function(e) e.SetCamActive(OTHER, true) end },
        { 'SetCamActive', 'cut', function(e) e.SetCamActive(CAM, false) end, 'off' },
        { 'DestroyCam', 'cut', function(e) e.DestroyCam(CAM, true) end },
        { 'DestroyAllCams', 'cut', function(e) e.DestroyAllCams(true) end },
        { 'RenderScriptCams', 'cut', function(e) e.RenderScriptCams(false, false, 0, true, true) end, 'at once' },
        { 'RenderScriptCams', 'blend', function(e) e.RenderScriptCams(false, true, 1000, true, true) end, 'eased' },
        { 'SetCamActiveWithInterp', 'blend', function(e) e.SetCamActiveWithInterp(OTHER, CAM, 800, 1, 1) end },
        { 'SwitchInPlayer', 'blend', function(e) e.SwitchInPlayer(1) end },
        { 'CreateCam', 'cut', function(e) e.CreateCam('DEFAULT_SCRIPTED_CAMERA', true) end, 'active' },
        { 'CreateCam', 'none', function(e) e.CreateCam('DEFAULT_SCRIPTED_CAMERA', false) end, 'inactive' },
        { 'CreateCamera', 'cut', function(e) e.CreateCamera(26379945, true) end, 'active' },
        { 'CreateCamera', 'none', function(e) e.CreateCamera(26379945, false) end, 'inactive' },
        { 'CreateCamWithParams', 'cut', function(e)
            e.CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 60.0, true, 2)
        end, 'active' },
        { 'CreateCamWithParams', 'none', function(e)
            e.CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 60.0, false, 2)
        end, 'inactive' },
        { 'CreateCameraWithParams', 'cut', function(e)
            e.CreateCameraWithParams(26379945, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 60.0, true, 2)
        end, 'active' },
        { 'CreateCameraWithParams', 'none', function(e)
            e.CreateCameraWithParams(26379945, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 60.0, false, 2)
        end, 'inactive' },
    }

    -- Every native the wrapper list names is exercised here, and every one is wrapped.
    local probe = rider()
    local listed, covered = {}, {}
    for name in pairs(probe.env.BR.Storm.CAMERA_SWITCHES) do listed[#listed + 1] = name end
    table.sort(listed)
    for _, c in ipairs(CALLS) do covered[c[1]] = true end
    local missing, unwrapped = {}, {}
    for _, name in ipairs(listed) do
        if not covered[name] then missing[#missing + 1] = name end
        if probe.env[name] == probe.camNatives[name] or type(probe.env[name]) ~= 'function' then
            unwrapped[#unwrapped + 1] = name
        end
    end
    ok(#listed == #CAMERA_NATIVES and #missing == 0,
        'every native client/storm.lua wraps is one this block calls',
        ('listed %s; not exercised: %s'):format(table.concat(listed, ', '),
            table.concat(missing, ', ')))
    ok(#unwrapped == 0, 'and each of them is wrapped, on the global every file calls',
        table.concat(unwrapped, ', '))

    local laterBad, earlierBad, nextBad, againBad, blendBad, fwdBad = {}, {}, {}, {}, {}, {}
    for _, c in ipairs(CALLS) do
        local name, kind, go = c[1], c[2], c[3]
        local label = name .. (c[4] and (' (' .. c[4] .. ')') or '')

        -- LATER IN THE FRAME: the spectate case.
        local R = rider()
        R.frame()
        local culled = #R.polys < R.n
        local before = #R.camCalls
        R.later = go
        R.frame()
        if not culled then
            laterBad[#laterBad + 1] = label .. ': precondition, the pose culls nothing'
        elseif (kind == 'none') == wholeIn(R) then
            laterBad[#laterBad + 1] = ('%s: %s'):format(label, said(R))
        end
        if #R.camCalls ~= before + 1 or R.camCalls[#R.camCalls] ~= name then
            fwdBad[#fwdBad + 1] = label
        end

        -- THE FRAME AFTER: whole for a switch, IsCamRendering not consulted yet; a
        -- cut culls again the frame after that, a blend never on this ride.
        R.frame()
        if (kind == 'none') == wholeIn(R) then
            nextBad[#nextBad + 1] = ('%s: %s'):format(label, said(R))
        end
        R.frame()
        R.frame()
        if kind == 'blend' then
            if not wholeIn(R) then blendBad[#blendBad + 1] = ('%s: %s'):format(label, said(R)) end
            -- A NEW RIDE: a new camera, a pose for it, and the cull is back.
            R.bus = { cam = CAM + 1, cur = AIM, prev = AIM }
            R.rendering[CAM + 1] = true
            R.frame()
            if wholeIn(R) then
                blendBad[#blendBad + 1] = ('%s: the next ride still culls nothing, %s')
                    :format(label, said(R))
            end
        elseif wholeIn(R) then
            againBad[#againBad + 1] = ('%s: %s'):format(label, said(R))
        end

        -- EARLIER IN THE FRAME: a net event, before the band runs.
        local E = rider()
        E.frame()
        go(E.env)
        E.frame()
        if (kind == 'none') == wholeIn(E) then
            earlierBad[#earlierBad + 1] = ('%s: %s'):format(label, said(E))
        end
    end
    ok(#laterBad == 0, 'a camera switch LATER in the frame than the preview\'s draw -- '
        .. 'where spectate.camera is -- gives that frame the whole wall, each quad once; '
        .. 'a camera made inactive gives up nothing', table.concat(laterBad, '; '))
    ok(#fwdBad == 0, 'and every wrapped call reaches the real native, once',
        table.concat(fwdBad, '; '))
    ok(#nextBad == 0, 'the draw after a switch culls nothing, before IsCamRendering '
        .. 'can be trusted to have caught up', table.concat(nextBad, '; '))
    ok(#againBad == 0, 'and a switch at once costs the cull that one frame and no more',
        table.concat(againBad, '; '))
    ok(#blendBad == 0, 'an eased switch turns the cull off for the rest of that ride, '
        .. 'and the next ride culls again', table.concat(blendBad, '; '))
    ok(#earlierBad == 0, 'a camera switch EARLIER in the frame than the draw -- a net '
        .. 'event -- leaves that frame whole though IsCamRendering still says the bus',
        table.concat(earlierBad, '; '))

    -- ─── spectate.camera's own three calls, and the engine following them ───
    do
        local R = rider()
        R.frame()
        local culled = #R.polys < R.n
        local made = nil
        R.later = function(e)
            made = e.CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', 10.0, 20.0, 31.5,
                0.0, 0.0, 0.0, 50.0, false, 2)
            e.SetCamActive(made, true)
            e.RenderScriptCams(true, false, 0, true, true)
        end
        R.frame()
        ok(culled and wholeIn(R),
            'an admin\'s spectate camera made active mid-ride, by spectate.camera\'s own '
                .. 'calls after the draw, leaves no hole in that frame\'s wall', said(R))
        ok(made == 901, 'and the camera handle comes back through the wrapper',
            tostring(made))
        R.rendering[CAM] = false
        R.frame()
        R.frame()
        ok(wholeIn(R), 'and while the spectate camera renders, nothing is culled', said(R))
    end

    -- ─── an eased switch with no ride posed yet holds until one is boarded ───
    do
        local R = rider()
        R.bus = nil
        R.env.RenderScriptCams(false, true, 1000, true, true)
        R.frame()
        R.bus = { cam = CAM, cur = AIM, prev = AIM }
        R.frame()
        R.frame()
        ok(wholeIn(R), 'an eased switch made before a ride has a pose culls nothing on it',
            said(R))
        -- BOARDING: bus.lua makes its camera active before it has posed it.
        R.bus = nil
        R.env.SetCamActive(CAM, true)
        R.frame()
        R.bus = { cam = CAM, cur = AIM, prev = AIM }
        R.frame()
        ok(not wholeIn(R), 'and the camera boarding makes active clears it: the ride culls',
            said(R))
    end
end

-- ---------------------------------------------------------------------------
describe('camera.class')
do
    -- ═══ EVERY CAMERA NATIVE br_core'S LUA STATE CALLS IS SORTED, AND NONE OF THE
    --     SWITCHES CAN GET ROUND THE WRAPPER (#393) ═══
    --
    -- `camera.switch` proves what a call through client/storm.lua's wrapper does. This
    -- proves every call IS one: each file the manifest loads into br_core's client
    -- state -- br_core's own, br_lib's shared files, the vendored ScaleformUI -- is
    -- read, and
    --
    --   * every global call to a native whose name says camera ("Cam") or player
    --     switch ("Switch") is either a switch storm.lua wraps or one of NEUTRAL,
    --     below, each with the reason it never changes which camera renders -- so a
    --     camera native nobody has thought about fails here, by name and line;
    --   * a switch is only ever CALLED, or asked whether it exists (`if not X then`,
    --     `X and X(...)`, `type(X)`). Taken into a local, a table or an argument it
    --     would be a call the wrapper never sees; assigned to, it would replace it.
    --
    -- This is the test that would have caught the review's finding: spectate.lua's
    -- SetCamActive was a switch storm.lua was never told of.
    local NEUTRAL = {
        DoesCamExist = 'a read', GetCamCoord = 'a read', GetRenderingCam = 'a read',
        GetFinalRenderedCamCoord = 'a read', GetFinalRenderedCamRot = 'a read',
        GetGameplayCamCoord = 'a read', GetGameplayCamFov = 'a read',
        GetGameplayCamRot = 'a read', GetGameplayCamRelativeHeading = 'a read',
        IsCamInterpolating = 'a read', IsCamRendering = 'a read',
        IsPlayerSwitchInProgress = 'a read', GetPlayerSwitchState = 'a read',
        SetCamCoord = 'moves a camera; which one renders is unchanged, and the bus\'s '
            .. 'own is moved only by bus.fly, which keeps the pose it set',
        PointCamAtCoord = 'aims a camera; likewise',
        ShakeGameplayCam = 'shakes the gameplay camera (an Airstrike rocket landing, #396); '
            .. 'which camera renders is unchanged',
        SetGameplayCamRelativeHeading = 'turns the gameplay camera, which the cull '
            .. 'never trusts and which is not on screen while the bus camera is',
    }
    local SWITCHES = newStormClient().env.BR.Storm.CAMERA_SWITCHES
    ok(type(SWITCHES) == 'table' and next(SWITCHES) ~= nil,
        'client/storm.lua publishes the natives it wraps')
    SWITCHES = SWITCHES or {}

    local function slurp(p)
        local f = io.open(p, 'rb')
        if not f then return nil end
        local s = f:read('a')
        f:close()
        return s
    end

    --- The source with comments and string contents blanked, newlines kept, so a
    --- name in a comment or a message is never read as a call and line numbers hold.
    local function codeOnly(src)
        local out, i, n = {}, 1, #src
        local function blank(s) return (s:gsub('[^\n]', ' ')) end
        while i <= n do
            local c = src:sub(i, i)
            if c == '-' and src:sub(i, i + 1) == '--' then
                local eq = src:match('^%[(=*)%[', i + 2)
                if eq then
                    local close = ']' .. eq .. ']'
                    local e = src:find(close, i + 4 + #eq, true) or n
                    out[#out + 1] = blank(src:sub(i, e + #close - 1))
                    i = e + #close
                else
                    local e = src:find('\n', i, true) or (n + 1)
                    out[#out + 1] = blank(src:sub(i, e - 1))
                    i = e
                end
            elseif c == '"' or c == "'" then
                local j = i + 1
                while j <= n do
                    local d = src:sub(j, j)
                    if d == '\\' then j = j + 2
                    elseif d == c or d == '\n' then break
                    else j = j + 1 end
                end
                out[#out + 1] = c .. blank(src:sub(i + 1, j - 1)) .. c
                i = j + 1
            elseif c == '[' and src:match('^%[=*%[', i) then
                local eq = src:match('^%[(=*)%[', i)
                local close = ']' .. eq .. ']'
                local e = src:find(close, i + 2 + #eq, true) or n
                out[#out + 1] = blank(src:sub(i, e + #close - 1))
                i = e + #close
            else
                local j = src:find('[%-"\'%[]', i + 1) or (n + 1)
                out[#out + 1] = src:sub(i, j - 1)
                i = j
            end
        end
        return table.concat(out)
    end

    --- Every camera-named global in `code`: calls to unsorted natives, and switches
    --- used as something other than a call or an existence check.
    --- @param skipFrom integer|nil  @param skipTo integer|nil  a span not read
    local function scan(code, label, skipFrom, skipTo)
        local unknown, escaped, calls = {}, {}, 0
        for s, name, e in code:gmatch('()([%a_][%w_]*)()') do
            if name:match('^%u') and not name:match('^[%u%d_]+$')
                and (name:find('Cam', 1, true) or name:find('Switch', 1, true))
                and not (skipFrom and s > skipFrom and s < skipTo) then
                local before = code:sub(math.max(1, s - 40), s - 1)
                local prevCh = before:match('(%S)%s*$')
                if prevCh ~= '.' and prevCh ~= ':' then
                    local line = select(2, code:sub(1, s):gsub('\n', '')) + 1
                    local where = ('%s:%d %s'):format(label, line, name)
                    local nextCh = code:match('^%s*(.)', e)
                    if nextCh == '(' then
                        calls = calls + 1
                        if SWITCHES[name] == nil and NEUTRAL[name] == nil then
                            unknown[#unknown + 1] = where
                        end
                    elseif SWITCHES[name] ~= nil then
                        local after = code:match('^%s*([%w_=~]+)', e) or ''
                        local prevWord = before:match('([%w_]+)%s*$')
                        local guard = false
                        if before:match('type%s*%(%s*$') and nextCh == ')' then
                            guard = true
                        elseif prevCh == '=' or prevCh == ',' or prevCh == '{'
                            or prevCh == '(' or prevWord == 'return' then
                            guard = false
                        elseif after == 'then' or after == 'and' or after == 'or'
                            or after:sub(1, 2) == '==' or after:sub(1, 2) == '~=' then
                            guard = true
                        end
                        if not guard then escaped[#escaped + 1] = where end
                    end
                end
            end
        end
        return unknown, escaped, calls
    end

    -- The manifest's client state, in its own order, resolved as perf_client does.
    local man = slurp(RES .. 'br_core/fxmanifest.lua') or ''
    local files, unresolved = {}, {}
    for _, block in ipairs({ 'shared_scripts', 'client_scripts' }) do
        local body = man:match(block .. '%s*(%b{})') or ''
        for line in body:gmatch('[^\n]+') do
            local entry = line:match("^%s*'([^']+)'")
            if entry then
                local res, path = entry:match('^@([^/]+)/(.+)$')
                local found = nil
                if not res then
                    found = RES .. 'br_core/' .. entry
                else
                    for _, g in ipairs({ '[fivem-royale]', '[scaleformui]', '[voice]' }) do
                        local p = 'resources/' .. g .. '/' .. res .. '/' .. path
                        if slurp(p) then found = p break end
                    end
                end
                if found and slurp(found) then files[#files + 1] = found
                else unresolved[#unresolved + 1] = entry end
            end
        end
    end
    ok(#files > 60 and #unresolved == 0,
        'every file the manifest loads into the client state is read',
        ('%d read, unresolved: %s'):format(#files, table.concat(unresolved, ', ')))

    local unknown, escaped, calls, sawStorm = {}, {}, 0, false
    for _, f in ipairs(files) do
        local code = codeOnly(slurp(f))
        local label = f:match('([^/]+/[^/]+)$') or f
        -- storm.lua's own table of the names is the one place they are keys.
        local from, to = nil, nil
        if f:find('br_core/client/storm.lua', 1, true) then
            sawStorm = true
            from = code:find('local CAMERA_SWITCHES = {', 1, true)
            to = from and code:find('\n}', from, true)
        end
        local u, x, n = scan(code, label, from, to)
        for _, w in ipairs(u) do unknown[#unknown + 1] = w end
        for _, w in ipairs(x) do escaped[#escaped + 1] = w end
        calls = calls + n
    end
    ok(sawStorm and calls > 50, 'the reading finds client/storm.lua and the camera calls',
        ('%d camera calls'):format(calls))
    ok(#unknown == 0, 'every camera native br_core calls is a switch client/storm.lua '
        .. 'wraps or one that never changes which camera renders', table.concat(unknown, '; '))
    ok(#escaped == 0, 'and no switch is taken where the wrapper cannot see it, or replaced',
        table.concat(escaped, '; '))

    -- AND THE READING CAN FAIL.
    local _, x1 = scan(codeOnly('local activate = SetCamActive\nactivate(cam, true)\n'), 't')
    ok(#x1 == 1, 'a switch taken into a local is caught', table.concat(x1, ', '))
    local _, x2 = scan(codeOnly('RenderScriptCams = function() end\n'), 't')
    ok(#x2 == 1, 'and so is one replaced', table.concat(x2, ', '))
    local _, x3 = scan(codeOnly('BR.later(DestroyCam)\n'), 't')
    ok(#x3 == 1, 'and one handed to something else to call', table.concat(x3, ', '))
    local u4 = scan(codeOnly('StopRenderingScriptCamsUsingCatchUp(false, 0.0, 3)\n'), 't')
    ok(#u4 == 1, 'and a camera native nobody has sorted', table.concat(u4, ', '))
    local u5, x5 = scan(codeOnly('-- SetCamActive = nil\nlocal s = "RenderScriptCams = 1"\n'
        .. 'if not CreateCamWithParams then return end\n'
        .. 'if type(SetCamActive) ~= "function" then return end\n'), 't')
    ok(#u5 == 0 and #x5 == 0, 'while a comment, a string or an existence check is not',
        table.concat(u5, ', ') .. ' / ' .. table.concat(x5, ', '))
end

-- ---------------------------------------------------------------------------
describe('wall.pool')
do
    -- ═══ A MOVING WALL IS BUILT INTO LAST FRAME'S TABLES, AND IS THE SAME WALL (#393) ═══
    --
    -- Through a sweep the zone is a new shape every frame, and building it, insetting
    -- it and listing its runs made a few hundred tables a frame -- about 22 KB for the
    -- collector. client/storm.lua now builds it into a pool (storm_shape.lua's "a
    -- pool"), and the claim this block pins is that nothing about the result moved:
    -- every number of the pooled zone, its inset and its runs is the unpooled one's,
    -- compared with ==, at every instant of the sweeps below and in an order that makes
    -- every list both grow and shrink between builds -- the case a pool gets wrong by
    -- keeping last time's tail. Then that the client draws the same triangles with and
    -- without it, and that a warm pool allocates nothing.
    local C0 = newStormClient()
    local BR = C0.env.BR
    local SS = BR.StormShape

    --- Where two values first differ, walking tables to the bottom; nil if nowhere.
    --- Keys are visited in sorted order so the answer names the same field each run.
    local function diffOf(a, b, path, seen)
        if type(a) ~= type(b) then return path .. ': ' .. type(a) .. ' against ' .. type(b) end
        if type(a) ~= 'table' then
            if a ~= b then return ('%s: %s against %s'):format(path, tostring(a), tostring(b)) end
            return nil
        end
        seen = seen or {}
        if seen[a] then return nil end
        seen[a] = true
        local keys, has = {}, {}
        for k in pairs(a) do if not has[k] then has[k] = true keys[#keys + 1] = k end end
        for k in pairs(b) do if not has[k] then has[k] = true keys[#keys + 1] = k end end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        for _, k in ipairs(keys) do
            -- `unit` is the blob's own unit, shared by both builds: identity is enough.
            if k == 'unit' then
                if a[k] ~= b[k] then return path .. '.unit is another unit' end
            else
                local d = diffOf(a[k], b[k], path .. '.' .. tostring(k), seen)
                if d then return d end
            end
        end
        return nil
    end

    local function lerp(a, b, t) return a + (b - a) * t end
    local function zoneAt(rec, t, pool)
        return BR.StormZone(rec, lerp(rec.cx0, rec.cx1, t), lerp(rec.cy0, rec.cy1, t),
            lerp(rec.r0, rec.r1, t), t, 1.0, pool)
    end

    -- Nested phases of the shipping sizes, an off-centre one whose destination presses
    -- on the wall (the second hull a frame), and a breakout the pool must stand aside
    -- for.
    local recs = {
        { phase = 1, cx0 = 0.0, cy0 = 0.0, r0 = 5200.0, cx1 = 900.0, cy1 = 1400.0, r1 = 2600.0 },
        { phase = 3, cx0 = 0.0, cy0 = 0.0, r0 = 1600.0, cx1 = 300.0, cy1 = -200.0, r1 = 950.0 },
        { phase = 4, cx0 = 0.0, cy0 = 0.0, r0 = 950.0, cx1 = 420.0, cy1 = 0.0, r1 = 520.0 },
        { phase = 6, cx0 = 0.0, cy0 = 0.0, r0 = 260.0, cx1 = 120.0, cy1 = 60.0, r1 = 110.0 },
        { phase = 8, cx0 = 0.0, cy0 = 0.0, r0 = 40.0, cx1 = 10.0, cy1 = 0.0, r1 = 0.0 },
        { phase = 2, cx0 = 0.0, cy0 = 0.0, r0 = 2600.0, cx1 = 4400.0, cy1 = 0.0, r1 = 1600.0 },
    }
    for _, r in ipairs(recs) do r.seed, r.tWait, r.tShrink = 393, 60000, 60000 end
    -- Out of order on purpose, so consecutive builds differ in size both ways.
    local ts = { 0.5, 0.02, 0.98, 0.31, 0.77, 0.001, 0.64, 0.12, 0.999, 0.45, 0.88, 0.2 }

    local pool = SS.newPool()
    local compared, bad, nested, kinds = 0, nil, 0, {}
    for _, t in ipairs(ts) do
        for ri, rec in ipairs(recs) do
            local want = zoneAt(rec, t)
            local wantIn = SS.inset(want, 6.0)
            SS.resetPool(pool)
            local got = zoneAt(rec, t, pool)
            local gotIn = SS.inset(got, 6.0, pool)
            local d = diffOf(got, want, 'zone') or diffOf(gotIn, wantIn, 'inset')
            for ci = 1, #SS.components(wantIn) do
                d = d or diffOf(SS.runs(gotIn, ci, pool), SS.runs(wantIn, ci),
                    'runs ' .. ci)
            end
            if d and not bad then bad = ('record %d at t %s: %s'):format(ri, t, d) end
            compared = compared + 1
            kinds[want.kind] = true
            if BR.StormNested(rec) then nested = nested + 1 end
        end
    end
    ok(bad == nil and compared == #ts * #recs,
        'a pooled zone, its inset and its runs are the unpooled ones to the bit, at '
            .. 'every instant of six sweeps, built in an order that makes every list grow '
            .. 'and shrink', bad or ('%d builds compared'):format(compared))
    ok(kinds.blob and nested > 0 and nested < compared,
        'and the sweeps are blob walls, nested and broken out',
        ('kinds seen: %s; %d of %d nested'):format(
            (function() local k = {} for n in pairs(kinds) do k[#k + 1] = n end
                table.sort(k) return table.concat(k, ',') end)(), nested, compared))

    -- A WARM POOL ALLOCATES NOTHING: the same builds again, the collector stopped and
    -- its count read on either side.
    collectgarbage('collect')
    collectgarbage('stop')
    local function sweepOnce()
        for _, t in ipairs(ts) do
            local rec = recs[1]
            SS.resetPool(pool)
            local z = zoneAt(rec, t, pool)
            local zi = SS.inset(z, 6.0, pool)
            for ci = 1, #SS.components(zi) do SS.runs(zi, ci, pool) end
        end
    end
    sweepOnce()
    local k0 = collectgarbage('count')
    for _ = 1, 20 do sweepOnce() end
    local pooledKB = collectgarbage('count') - k0
    local k1 = collectgarbage('count')
    for _ = 1, 20 do
        for _, t in ipairs(ts) do
            local z = zoneAt(recs[1], t)
            local zi = SS.inset(z, 6.0)
            for ci = 1, #SS.components(zi) do SS.runs(zi, ci) end
        end
    end
    local freshKB = collectgarbage('count') - k1
    collectgarbage('restart')
    ok(pooledKB < 1.0 and freshKB > 100.0 * #ts,
        'a warm pool builds, insets and walks a moving phase-1 wall without allocating',
        ('%.2f KB over %d pooled builds, against %.0f KB unpooled'):format(pooledKB,
            20 * #ts, freshKB))

    -- THE CLIENT DRAWS THE SAME TRIANGLES. The same sweep, frame after frame, drawn
    -- by a client using its pool and by one whose shape functions ignore the pool.
    local function sweeping(unpooled)
        local C = newStormClient()
        if unpooled then
            local Z, I, R = C.env.BR.StormZone, C.env.BR.StormShape.inset,
                C.env.BR.StormShape.runs
            C.env.BR.StormZone = function(rec, cx, cy, r, t, g) return Z(rec, cx, cy, r, t, g) end
            C.env.BR.StormShape.inset = function(s, m) return I(s, m) end
            C.env.BR.StormShape.runs = function(s, ci) return R(s, ci) end
        end
        local rec = C.record(1, 0.0, 0.0, 5200.0, 900.0, 1400.0, 2600.0, 1000, 240000, 0.5)
        rec.seed = 393
        C.recordWallOnly()
        C.pedAt = pt(400.0, 300.0, 30.0)
        return C
    end
    local P, U = sweeping(false), sweeping(true)
    local frames, drawn, same = 0, 0, nil
    for _ = 1, 40 do
        P.now, U.now = P.now + 2984, U.now + 2984
        P.frame()
        U.frame()
        frames = frames + 1
        drawn = drawn + #P.polys
        same = same or diffOf(P.polys, U.polys, 'frame ' .. frames)
    end
    ok(P.errored() == nil and U.errored() == nil, 'both clients sweep clean',
        P.errored() or U.errored())
    ok(same == nil and drawn > 40 * 100,
        'and through a sweep the pooled client draws the triangles the unpooled one '
            .. 'does, frame by frame, argument for argument',
        same or ('%d triangles over %d frames'):format(drawn, frames))
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
                        -- AND THE GROWTH THE SOLVER REPORTS (#344): an overlapping
                        -- pair's first frames are a zone GROWING into its destination,
                        -- and what was drawn has to stand on that zone too.
                        local cx, cy, r, _, _, _, t, g = env.BR.StormAt(rec, C.now)
                        local drawn = SS.inset(env.BR.StormZone(rec, cx, cy, r, t, g),
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
                -- At the solver's own `t` and `g`, as above: this record is one frame
                -- into its hold, and an overlapping pair is growing (#344).
                local zcx, zcy, zr, _, _, _, zt, zg = env.BR.StormAt(rec, C.now)
                local drawn = SS.inset(env.BR.StormZone(rec, zcx, zcy, zr, zt, zg),
                    rr.edgeInset or 0.0)
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
    ok(nCounts == 10 and circles > 0,
        'and those zones really do vary: every count from three to twelve is among them, '
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
--- @param tweak function|nil  (env) -> nil, run on the server's config before the walk
local function walkRecords(seq, tweak)
    local S = newStormServer()
    local env = S.env
    if tweak then tweak(env) end
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

    --- Does a record's target nest inside the zone its wall starts as, by real shape
    --- -- the rule the server places every non-breakout zone to satisfy? On a phase
    --- that breaks out, the safe zone gains the new target at the phase change by
    --- design (#328), so only a nesting phase's WHOLE zone can be held to equality.
    local function nests(rec)
        return env.BR.StormNested(rec)
    end

    local changes, sameUnit, shapeJump, shapeAt, targetOff = 0, 0, 0.0, nil, 0.0
    local nested, zoneJump, zoneAt, wallJump, wallAt, drewBoth = 0, 0.0, nil, 0.0, nil, 0
    for k, recs in ipairs(matches) do
        for p = 1, #recs - 1 do
            local a, b = recs[p], recs[p + 1]
            if a and b then
                changes = changes + 1
                -- THE WALL'S SHAPE, at the end of p's sweep and at the start of p+1's
                -- hold: one zone, so ONE UNIT -- the same table -- and the same shape
                -- placed on the same circle.
                local ua = env.BR.StormUnit(a.seed, a.phase)
                local ub = env.BR.StormUnit(b.seed, b.phase - 1)
                if ua == ub then sameUnit = sameUnit + 1 end
                local ca = env.BR.StormWall(a, 1.0)
                local cb = env.BR.StormWall(b, 0.0)
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
    -- The map shows nothing that moves (2026-10-04): a sweep fades its zone out and
    -- leaves the destination, and the next hold draws that destination again as its
    -- zone -- so where the next phase nests, the destination a phase ended on and the
    -- zone the next phase starts with have to be the same polygon.
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
            -- THE DESTINATION AS A SWEEP FINISHES -- the only fill a finished sweep
            -- shows, its zone faded to nothing -- and the zone as the next hold begins:
            -- the same outline.
            local shows = #M.visible() == 1 and M.dest()[1] and M.visible()[1] == M.dest()[1]
            local A = shows and M.shown(M.dest()[1]) or {}
            b.tStart = M.now + 20000
            M.env.BR.State.storm = b
            M.fire(M.env.BR.Net.STORM_SYNC)
            M.tick(2)
            local B = M.zoneFill() and M.shown(M.zoneFill()) or {}
            mapPairs = mapPairs + 1
            local w = apart(A, B)
            if w > mapJump then
                mapJump, mapAt = w, ('match %d, phase %d to %d'):format(k, p, p + 1)
            end
          end
        end
    end
    ok(mapPairs >= 10 and mapJump < 1e-6 and M.errored() == nil,
        'and the MAP\'s destination as a sweep finishes is the zone the next hold draws, '
            .. 'the same polygon on both sides of every change',
        M.errored() or ('%d changes, worst %.3e m at %s'):format(mapPairs, mapJump,
            tostring(mapAt)))

    -- ═══ AND NO JUMP MID-SWEEP, WHICH IS WHAT THE MORPH IS FOR ═══
    --
    -- The wall is the hull of discs each moving in a straight line from a corner of the
    -- zone it leaves to a corner of the zone it reaches, with the destination's own
    -- discs standing still. A hull's support function is the largest of its discs', so
    -- between two instants dt of the sweep apart no point of it can move further than
    -- dt times the furthest any one disc travels -- BR.StormWallSpeed, times the sweep.
    -- A shape that snapped anywhere in the sweep, at its start included, would clear
    -- that by metres.
    local stepJump, stepAt, stepped = 0.0, nil, 0
    for k = 1, 3 do
        for p, rec in ipairs(matches[k]) do
            if rec.r1 > 0.0 then
                local gap = env.BR.StormWallSpeed(rec)
                    * math.max(rec.tShrink / 1000.0, 1.0)
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
describe('zone.schedule')
do
    -- ═══ THE ZONE KEEPS TO ITS CLOCK: NO RACING AHEAD, NO STOPPING DEAD ═══
    --
    --   "at the first phase or two, the border jumped in size while moving, suddenly
    --    being maybe 10 seconds ahead of where it should have been."
    --                                                    -- the owner, 2026-09-28
    --
    -- The zone never teleported -- zone.identity's step bound held -- but it changed
    -- SPEED at the knee by up to 240 times. A destination with little room around it
    -- had its knee outline (`mid`) clamped onto itself, so the first leg covered the
    -- whole sweep's travel in 25 of 40 seconds and the second leg stood still: 14.9 s
    -- ahead of the clock at worst, a wall that races in and stops dead. Measured at
    -- ec19f40 on these walks: phase 2 14.7 s ahead with an 82x drop in speed, phase 1
    -- 7.2 s and 2.9x.
    --
    -- SO THIS WALKS REAL MATCHES, every phase, at 100 ms, and reads the zone's size as
    -- the radius of a disc of its area, R. The sweep's clock says R goes from the zone
    -- the wall leaves to the destination at one rate. On every nested phase:
    --
    --   the zone is never more than AHEAD_S ahead of that clock, and
    --   its speed never changes by more than KINK between two half-second windows --
    --   the owner's jump was the knee's 25x to 240x.
    --
    -- A breakout's zone is the wall union a destination that is already safe, so its
    -- area says nothing about a schedule; it is held to zone.identity's step bound, and
    -- here to the same step bound at 100 ms, which the whole walk is.
    local AHEAD_S, KINK = 2.0, 2.0
    local SAMPLES = 96
    local S0 = newStormServer()
    local BR = S0.env.BR
    local SS = BR.StormShape

    --- The zone at sweep fraction t, its boundary sampled, and its area radius.
    local function sampled(rec, t)
        local cx, cy, r = BR.Lerp(rec.cx0, rec.cx1, t), BR.Lerp(rec.cy0, rec.cy1, t),
            BR.Lerp(rec.r0, rec.r1, t)
        local z = BR.StormZone(rec, cx, cy, r, t, 1.0)
        local P = SS.perimeter(z)
        local pts, a = {}, 0.0
        for k = 0, SAMPLES - 1 do
            local x, y = SS.pointAtArc(z, P * k / SAMPLES)
            pts[#pts + 1] = { x = x, y = y }
        end
        for k = 1, #pts do
            local p, q = pts[k], pts[k % #pts + 1]
            a = a + p.x * q.y - q.x * p.y
        end
        return z, pts, math.sqrt(math.abs(a) * 0.5 / math.pi)
    end

    local walked, nestedN, steps = 0, 0, 0
    local ahead, aheadAt, kink, kinkAt, stepOver, stepAt = 0.0, nil, 1.0, nil, 0.0, nil
    for seq = 1, 8 do
        local recs = walkRecords(seq)
        for ph = 1, #BR.Config.Storm.phases do
            local rec = recs[ph]
            if rec then
                walked = walked + 1
                local T = rec.tShrink
                local n = math.floor(T / 100.0)
                local nested = BR.StormNested(rec) and rec.r1 > 0.0
                if nested then nestedN = nestedN + 1 end
                -- Plus a metre and a half: the last zone collapses onto the walkable
                -- circle every point is (storm_shape.lua's MIN_RADIUS), not onto nothing.
                local bound = BR.StormWallSpeed(rec) * 0.1 * 1.0001 + 1.5
                local Rs, prevZ, prevPts = {}, nil, nil
                for k = 0, n do
                    local t = k / n
                    local z, pts, R = sampled(rec, t)
                    Rs[k] = R
                    -- NO STEP FURTHER THAN THE FASTEST CORNER GOES IN 100 ms, both ways.
                    if prevZ then
                        local h = 0.0
                        for _, p in ipairs(pts) do
                            h = math.max(h, math.abs(SS.distance(prevZ, p.x, p.y)))
                        end
                        for _, p in ipairs(prevPts) do
                            h = math.max(h, math.abs(SS.distance(z, p.x, p.y)))
                        end
                        steps = steps + 1
                        local over = h / bound
                        if over > stepOver then
                            stepOver, stepAt = over, ('match %d phase %d t=%.3f'):format(seq, ph, t)
                        end
                    end
                    prevZ, prevPts = z, pts
                end
                if nested and Rs[0] - Rs[n] > 1.0 then
                    local span = Rs[0] - Rs[n]
                    for k = 1, n do
                        local s = ((Rs[0] - Rs[k]) / span - k / n) * T / 1000.0
                        if s > ahead then
                            ahead, aheadAt = s, ('match %d phase %d t=%.3f'):format(seq, ph, k / n)
                        end
                    end
                    -- Half-second windows: five steps each.
                    local w = 5
                    for k = 2 * w, n, w do
                        local v1 = Rs[k - 2 * w] - Rs[k - w]
                        local v2 = Rs[k - w] - Rs[k]
                        local lo, hi = math.min(v1, v2), math.max(v1, v2)
                        -- A window moving under 2% of the sweep's mean pace is the zone
                        -- easing onto a corner; ratios of near-zeros are not a jump.
                        if hi > 0.02 * span * w / n then
                            local rr = hi / math.max(lo, 1e-9)
                            if rr > kink then
                                kink, kinkAt = rr, ('match %d phase %d t=%.3f'):format(seq, ph,
                                    (k - w) / n)
                            end
                        end
                    end
                end
            end
        end
    end
    ok(walked >= 56 and nestedN >= 30 and steps > 20000,
        ('the walk reads %d sweeps of 8 real matches, %d nested, at 100 ms: %d steps')
            :format(walked, nestedN, steps))
    ok(stepOver <= 1.0,
        'no 100 ms step of the zone moves further than its fastest corner can',
        ('worst %.3f of the bound at %s'):format(stepOver, tostring(stepAt)))
    ok(ahead <= AHEAD_S,
        ('on every nested sweep the zone is never more than %.0f s ahead of its clock')
            :format(AHEAD_S),
        ('worst %.1f s ahead at %s'):format(ahead, tostring(aheadAt)))
    ok(kink <= KINK,
        ('and its pace never changes by more than %.0fx from one half second to the next -- '
            .. 'no racing in and stopping dead at the knee'):format(KINK),
        ('worst x%.2f at %s'):format(kink, tostring(kinkAt)))
end

-- ---------------------------------------------------------------------------
describe('zone.nest')
do
    -- ═══ EVERY PHASE THAT DOES NOT BREAK OUT IS WHOLLY INSIDE THE ONE BEFORE IT ═══
    --
    --   "the circles still overlap when they are different shapes."
    --   "should we make the moving storm morph to match the shape of the destination
    --    shape?"                                        -- the owner, 2026-09-23
    --
    -- Whole matches through the REAL server -- the warmup draw, begin, the phase job --
    -- with the breakout chance turned off, so every phase is one the placement must
    -- nest. Asked of each record three ways: the record's own verdict, the target's
    -- walked boundary against the zone the wall starts as, and the wall itself at
    -- twenty instants of the sweep -- which must hold the target, stay inside where it
    -- started, never move outward, and bill exactly what it draws.
    local nestedN, records, walkedOut = 0, 0, -math.huge
    local loose, outside, outward = -math.huge, -math.huge, -math.huge
    local speedLow, speedOver, erodeOff = nil, nil, 0.0
    local env0 = nil
    for k = 1, 4 do
        local recs = walkRecords(40 + k, function(env)
            env.BR.Config.Storm.breakout.chanceStart = 0.0
            env.BR.Config.Storm.breakout.chanceEnd = 0.0
            env0 = env
        end)
        local env = env0
        local SS = env.BR.StormShape
        for p = 1, #recs do
            local rec = recs[p]
            if rec and rec.r1 > 0.0 then
                records = records + 1
                if env.BR.StormNested(rec) then nestedN = nestedN + 1 end
                local Z = env.BR.StormWall(rec, 0.0)
                local D = env.BR.StormTarget(rec)
                -- WALKED, so it shares nothing with the discs the placement asked.
                local P = SS.perimeter(D)
                for i = 0, 499 do
                    local x, y = SS.pointAtArc(D, P * i / 500)
                    walkedOut = math.max(walkedOut, SS.distance(Z, x, y))
                end
                local keep = {}
                for _, c in ipairs(D.hull.ks) do keep[#keep + 1] = { x = c.x, y = c.y, r = c.rho } end
                local prev = nil
                local travel = env.BR.StormWallSpeed(rec) * math.max(rec.tShrink / 1000.0, 1.0)
                for i = 1, 19 do
                    local W = env.BR.StormWall(rec, i / 20)
                    -- NO POINT OF THE WALL MOVES FURTHER IN A STEP than the fastest disc.
                    if prev then
                        local WP = SS.perimeter(W)
                        for q = 0, 59 do
                            local x, y = SS.pointAtArc(W, WP * q / 60)
                            local moved = math.abs(SS.distance(prev, x, y))
                            if moved > travel / 20 + 1e-6 then
                                speedOver = speedOver or ('phase %d step %d: %.2f m against %.2f')
                                    :format(rec.phase, i, moved, travel / 20)
                            end
                        end
                    end
                    local wd = {}
                    for _, c in ipairs(W.hull.ks) do wd[#wd + 1] = { x = c.x, y = c.y, r = c.rho } end
                    loose = math.max(loose, SS.fit(W.hull.ks, keep, 0.0, 0.0, 1.0))
                    outside = math.max(outside, SS.fit(Z.hull.ks, wd, 0.0, 0.0, 1.0))
                    if prev then outward = math.max(outward, SS.fit(prev.hull.ks, wd, 0.0, 0.0, 1.0)) end
                    -- THE WALL'S OWN SIX METRES are exactly six metres inside the zone.
                    if i == 10 then
                        local ins = SS.inset(W, 6.0)
                        if ins.hull then
                            local IP = SS.perimeter(ins)
                            for q = 0, 99 do
                                local x, y = SS.pointAtArc(ins, IP * q / 100)
                                erodeOff = math.max(erodeOff, math.abs(SS.distance(W, x, y) + 6.0))
                            end
                        end
                    end
                    prev = W
                end
                -- THE FASTEST CORNER IS NEVER SLOWER THAN THE CIRCLE'S EDGE WAS.
                local circle = (rec.r0 - rec.r1) / math.max(rec.tShrink / 1000.0, 1.0)
                if env.BR.StormWallSpeed(rec) < circle - 1e-9 then
                    speedLow = speedLow or ('phase %d: %.2f against %.2f m/s')
                        :format(rec.phase, env.BR.StormWallSpeed(rec), circle)
                end
            end
        end
    end
    ok(records >= 24 and nestedN == records,
        ('every one of %d phases the server placed without a breakout nests by real '
            .. 'shape'):format(records), ('%d of %d'):format(nestedN, records))
    ok(walkedOut <= 1e-6,
        'and the target\'s own walked boundary never leaves the zone the wall starts as',
        ('worst %.3e m out'):format(walkedOut))
    ok(loose <= 1e-9,
        'so the moving wall holds the target at every instant -- it never crosses it',
        ('worst %.3e m'):format(loose))
    ok(outside <= 1e-9 and outward <= 1e-9,
        'and it never leaves where it started or moves back out over anyone',
        ('%.3e m outside, %.3e m outward'):format(outside, outward))
    ok(erodeOff < 1e-6,
        'and the curtain drawn six metres inside it is exactly six metres inside it',
        ('worst %.3e m'):format(erodeOff))
    -- BR.StormWallSpeed IS FOR THE DAMAGE CUSHION (#366): a corner travelling to a
    -- corner of another shape moves further than a circle's edge did, never less.
    ok(speedLow == nil,
        'and the fastest corner of every wall moves at least as fast as the circle\'s '
            .. 'edge the cushion is priced on', speedLow)
    ok(speedOver == nil,
        'and no point of any wall moves faster than BR.StormWallSpeed says -- it is a '
            .. 'bound the damage cushion can be priced on', speedOver)
end

-- ---------------------------------------------------------------------------
describe('price.run')
do
    -- ═══ THE SWEEP IS PRICED ON THE WALL THAT WILL CHASE THE RUNNER (#344) ═══
    --
    --   "A straggler two kilometres out? They get their run."   -- server/storm.lua
    --
    -- The morph moves every corner to its own partner, so part of the wall can arrive
    -- over a player sooner than their distance to the destination says, and a sweep
    -- priced at distance / 9 caught the runner it was priced for -- 139 HP at phase 5
    -- in the round's review. Whole matches through the REAL server, with players
    -- standing on the edge of the zone every next phase starts in, so the price is set
    -- by somebody the wall starts on top of. Each runs at 9 m/s from the instant the
    -- wall sets off, straight at the destination's nearest point or straight at its
    -- centre, whichever keeps them in -- the two runs the price reads -- and is asked
    -- at 400 instants of every sweep the price did not cap whether the zone the damage
    -- tick bills still holds them.
    --
    -- SIXTEEN MATCHES, where eight used to give twenty uncapped sweeps: the wall takes
    -- the destination's shape morph.leadSeconds before it arrives, its corners cover
    -- their paths sooner, and more of these edge-standing lobbies price past the
    -- ceiling -- where the price makes no promise to test.
    local NP, G = 24, 400
    local sweeps, capped, worst, where = 0, 0, -math.huge, nil
    for k = 1, 16 do
        local S = newStormServer()
        local env = S.env
        local SS = env.BR.StormShape
        local cfg = env.BR.Config.Storm
        -- EVERY PHASE NESTED, which is where the price is a promise: a breakout's gap
        -- is ground nobody is safe on until the wall crosses it.
        cfg.breakout.chanceStart, cfg.breakout.chanceEnd = 0.0, 0.0
        local V = cfg.shrinkPace.metersPerSec
        S.roster[1] = nil
        S.match.storm = nil
        S.match.seq = 60 + k
        S.match.anchor = { x = 1000.0, y = -1500.0, name = 'Run' }
        env.BR.Sched.setEnabled('storm.phase', true)
        S.match.state = env.BR.MatchState.WARMUP
        env.BR.Storm.drawFirstCircle(S.match)
        S.match.state = env.BR.MatchState.PLAYING
        env.BR.Storm.begin(S.match)

        --- Stand the roster on the edge of this record's target -- the zone the next
        --- phase starts in -- and hand back where they stood.
        local function stand(rec)
            local D = env.BR.StormTarget(rec)
            local P = SS.perimeter(D)
            local at = {}
            for i = 1, NP do
                local x, y = SS.pointAtArc(D, P * (i - 0.5) / NP)
                S.roster[i] = { matchId = 1, name = 'R' .. i, hp = 100.0,
                                state = env.BR.PlayerState.ALIVE,
                                pos = { x = x, y = y, z = 30.0 } }
                at[i] = { x = x, y = y }
            end
            return at
        end

        --- Every runner of one sweep the price did not cap, against the billed zone.
        local function run(rec, at)
            local T = rec.tShrink / 1000.0
            if T >= cfg.phases[rec.phase].shrink - 1e-6 then
                capped = capped + 1
                return
            end
            sweeps = sweeps + 1
            local D = env.BR.StormTarget(rec)
            local zs = {}
            for i = 1, G do
                local t = i / G
                zs[i] = env.BR.StormZone(rec, env.BR.Lerp(rec.cx0, rec.cx1, t),
                    env.BR.Lerp(rec.cy0, rec.cy1, t), env.BR.Lerp(rec.r0, rec.r1, t), t, 1.0)
            end
            --- The furthest outside one straight line at 9 m/s ever is, and when.
            local function line(q, tx, ty, L)
                local C = env.BR.Dist(q.x, q.y, tx, ty)
                local ux, uy = (tx - q.x) / C, (ty - q.y) / C
                local out, at = -math.huge, 0.0
                for i = 1, G do
                    local s = math.min(V * T * i / G, L)
                    local o = SS.distance(zs[i], q.x + ux * s, q.y + uy * s)
                    if o > out then out, at = o, i / G end
                end
                return out, at
            end
            local dks = D.hull and D.hull.ks or SS.discHull(D.discs)
            for _, q in ipairs(at) do
                local nx, ny = rec.cx1, rec.cy1
                if rec.r1 > 0.0 then nx, ny = SS.pointAtArc(D, SS.nearestArc(D, q.x, q.y)) end
                local L = env.BR.Dist(q.x, q.y, nx, ny)
                if L > 0.5 then
                    local o, when = line(q, nx, ny, L)
                    local C = env.BR.Dist(q.x, q.y, rec.cx1, rec.cy1)
                    if rec.r1 > 0.0 and C > 0.0 then
                        local Lc = SS.lineEntry(dks, q.x, q.y, (rec.cx1 - q.x) / C,
                            (rec.cy1 - q.y) / C, 0.0)
                        if Lc then
                            local oc, wc = line(q, rec.cx1, rec.cy1, Lc)
                            if oc < o then o, when = oc, wc end
                        end
                    end
                    if o > worst then
                        worst = o
                        where = ('match %d phase %d at %.2f of a %.1f s sweep, %.0f m '
                            .. 'from the destination'):format(k, rec.phase, when, T, L)
                    end
                end
            end
        end

        local rec = S.match.storm
        local seen = { [rec.phase] = true }
        local at = stand(rec)
        local last = #cfg.phases
        local guard = 0
        while not seen[last] and guard < 4000 do
            guard = guard + 1
            S.now = S.now + 30000
            env.BR.Sched.step(S.now)
            rec = S.match.storm
            if rec and not seen[rec.phase] then
                seen[rec.phase] = true
                run(rec, at)
                at = stand(rec)
            end
        end
    end
    ok(sweeps >= 20,
        ('the walk priced %d sweeps below their ceiling off runners at the edge (%d '
            .. 'capped)'):format(sweeps, capped), sweeps)
    ok(worst <= 0.5,
        'and not one runner at 9 m/s was ever outside the zone the damage tick bills: '
            .. 'the sweep is priced on the moving wall, not on the distance',
        ('worst %.2f m outside, %s'):format(worst, tostring(where)))
end

-- ---------------------------------------------------------------------------
describe('price.outside')
do
    -- ═══ A PLAYER ALREADY OUTSIDE THE ZONE IS PRICED ON THE WALL TOO (#344) ═══
    --
    -- The price used to stop at the wall of the zone the phase starts in: a player a
    -- millimeter outside it was priced on the bare distance, and the morph can need
    -- 1.3 times that. The round's final review knocked a runner who started 0.5 m
    -- out for 136 HP, 65 m out of the wall -- and the players that hole catches are
    -- ordinary ones: riding the last sweep's wall, inside the ten-meter cushion, the
    -- last sweep's stragglers. The blend held a player who started `e` meters out
    -- within (1 - t) e of it, running at the distance's pace, and that is what the
    -- price promises them now, on the wall itself.
    --
    -- The same walk as price.run -- whole matches through the real server, every
    -- phase nested -- with players stood 0.5, 5 and 40 m OUTSIDE the zone every next
    -- phase starts in. First the seam, then the runners, each at the pace the price
    -- allows them alone: the slowest it lets anybody go, which is where a price that
    -- fell short shows. (A faster runner is held too on a nested phase, and
    -- price.run's walk runs a whole lobby at 9 m/s.)
    local NP, G = 24, 400
    local OUT = { 0.5, 5.0, 40.0 }
    local sweeps, worst, where = 0, -math.huge, nil
    local seamWorst, seamWhere, seamAsked, seamLong = 0.0, nil, 0, 0
    for k = 1, 6 do
        local S = newStormServer()
        local env = S.env
        local SS = env.BR.StormShape
        local cfg = env.BR.Config.Storm
        cfg.breakout.chanceStart, cfg.breakout.chanceEnd = 0.0, 0.0
        S.roster[1] = nil
        S.match.storm = nil
        S.match.seq = 80 + k
        S.match.anchor = { x = 1000.0, y = -1500.0, name = 'Out' }
        env.BR.Sched.setEnabled('storm.phase', true)
        S.match.state = env.BR.MatchState.WARMUP
        env.BR.Storm.drawFirstCircle(S.match)
        S.match.state = env.BR.MatchState.PLAYING
        env.BR.Storm.begin(S.match)

        --- The outward normal of a shape at a point of its edge, off its own signed
        --- distance.
        local function normal(D, x, y)
            local h = 0.05
            local gx = SS.distance(D, x + h, y) - SS.distance(D, x - h, y)
            local gy = SS.distance(D, x, y + h) - SS.distance(D, x, y - h)
            local gl = math.sqrt(gx * gx + gy * gy)
            return gx / gl, gy / gl
        end

        --- Stand the roster OUTSIDE this record's target -- the zone the next phase
        --- starts in -- by 0.5, 5 and 40 m in turn, and hand back where they stood
        --- and how far out each one really is.
        local function stand(rec)
            local D = env.BR.StormTarget(rec)
            local P = SS.perimeter(D)
            local at = {}
            for i = 1, NP do
                local x, y = SS.pointAtArc(D, P * (i - 0.5) / NP)
                local nx, ny = normal(D, x, y)
                local e = OUT[(i - 1) % #OUT + 1]
                x, y = x + nx * e, y + ny * e
                S.roster[i] = { matchId = 1, name = 'O' .. i, hp = 100.0,
                                state = env.BR.PlayerState.ALIVE,
                                pos = { x = x, y = y, z = 30.0 } }
                at[i] = { x = x, y = y, e = SS.distance(D, x, y) }
            end
            return at
        end

        --- NO SEAM AT THE WALL: a hundredth of a millimeter either side of the zone the
        --- phase starts in, the same run -- to a meter, past the two parts in a
        --- thousand the price's own sampling and refinement leave between neighboring
        --- points.
        ---
        --- A HUNDREDTH, NOT A MILLIMETER (2026-09-28). Where the run's maximum is the
        --- wall's speed as it sets off, the price reads it at its first instant, 1e-4 of
        --- the sweep, and a millimeter either side of the wall is 1 mm / 1e-4 = 10 m of
        --- run each way there -- the offset, not a seam. The knee placed on the clock
        --- (storm_solve.lua's midOf) grows the knee's outline further, so more of the
        --- wall reaches it early and sets its price as it sets off: at a millimeter this
        --- read 10 m apart on one point, at a hundredth under one.
        local function seam(rec)
            local Z = env.BR.StormWall(rec, 0.0)
            local P = SS.perimeter(Z)
            for i = 1, 16 do
                local x, y = SS.pointAtArc(Z, P * (i - 0.5) / 16)
                local nx, ny = normal(Z, x, y)
                local inR = env.BR.StormSweepRun(rec, x - nx * 1e-5, y - ny * 1e-5)
                local outR = env.BR.StormSweepRun(rec, x + nx * 1e-5, y + ny * 1e-5)
                local d = SS.distance(env.BR.StormTarget(rec), x, y)
                if d > 1.0 then
                    seamAsked = seamAsked + 1
                    if inR > 1.05 * d then seamLong = seamLong + 1 end
                    local apart = math.abs(outR - inR) - 0.002 * inR
                    if apart > seamWorst then
                        seamWorst = apart
                        seamWhere = ('match %d phase %d: %.1f m a millimeter inside, %.1f '
                            .. 'outside, %.1f to the destination'):format(k, rec.phase,
                            inR, outR, d)
                    end
                end
            end
        end

        --- Every runner of one sweep, at their own priced pace: how much further outside
        --- the zone the damage tick bills than (1 - t) e they ever are, on the better
        --- of the two lines the price reads.
        local function run(rec, at)
            sweeps = sweeps + 1
            local D = env.BR.StormTarget(rec)
            local zs = {}
            for i = 1, G do
                local t = i / G
                zs[i] = env.BR.StormZone(rec, env.BR.Lerp(rec.cx0, rec.cx1, t),
                    env.BR.Lerp(rec.cy0, rec.cy1, t), env.BR.Lerp(rec.r0, rec.r1, t), t, 1.0)
            end
            local function line(q, pace, tx, ty, L)
                local C = env.BR.Dist(q.x, q.y, tx, ty)
                local ux, uy = (tx - q.x) / C, (ty - q.y) / C
                local over, at = -math.huge, 0.0
                for i = 1, G do
                    local t = i / G
                    local s = math.min(pace * t, L)
                    local o = SS.distance(zs[i], q.x + ux * s, q.y + uy * s)
                        - (1.0 - t) * q.e
                    if o > over then over, at = o, t end
                end
                return over, at
            end
            local dks = D.hull and D.hull.ks or SS.discHull(D.discs)
            for _, q in ipairs(at) do
                -- METERS PER SWEEP: run / T is the pace, and t the sweep fraction.
                local pace = env.BR.StormSweepRun(rec, q.x, q.y)
                local nx, ny = rec.cx1, rec.cy1
                if rec.r1 > 0.0 then nx, ny = SS.pointAtArc(D, SS.nearestArc(D, q.x, q.y)) end
                local L = env.BR.Dist(q.x, q.y, nx, ny)
                if L > 0.5 then
                    local o, when = line(q, pace, nx, ny, L)
                    local C = env.BR.Dist(q.x, q.y, rec.cx1, rec.cy1)
                    if rec.r1 > 0.0 and C > 0.0 then
                        local Lc = SS.lineEntry(dks, q.x, q.y, (rec.cx1 - q.x) / C,
                            (rec.cy1 - q.y) / C, 0.0)
                        if Lc then
                            local oc, wc = line(q, pace, rec.cx1, rec.cy1, Lc)
                            if oc < o then o, when = oc, wc end
                        end
                    end
                    if o > worst then
                        worst = o
                        where = ('match %d phase %d, %.1f m out at the start, %.0f m from the '
                            .. 'destination priced at %.0f, at %.2f of the sweep'):format(k,
                            rec.phase, q.e, L, pace, when)
                    end
                end
            end
        end

        local rec = S.match.storm
        local seen = { [rec.phase] = true }
        local at = stand(rec)
        local last = #cfg.phases
        local guard = 0
        while not seen[last] and guard < 4000 do
            guard = guard + 1
            S.now = S.now + 30000
            env.BR.Sched.step(S.now)
            rec = S.match.storm
            if rec and not seen[rec.phase] then
                seen[rec.phase] = true
                seam(rec)
                run(rec, at)
                at = stand(rec)
            end
        end
    end
    ok(seamAsked >= 60 and seamLong >= 5 and seamWorst < 1.0,
        'a hundredth of a millimeter outside the zone a phase starts in is priced as the '
            .. 'same inside it, where the morph makes the run longer than the distance too: '
            .. 'no seam at the wall',
        ('%d points, %d with a run over 1.05 times the distance; worst %.2f m apart, %s')
            :format(seamAsked, seamLong, seamWorst, tostring(seamWhere)))
    ok(sweeps >= 30, ('the walk ran %d sweeps'):format(sweeps), sweeps)
    ok(worst <= 1.0,
        'and a runner at their priced pace who started outside it was never further out '
            .. 'of the zone the damage tick bills than the blend would have left them, '
            .. '(1 - t) of where they started',
        ('worst %.2f m over, %s'):format(worst, tostring(where)))
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
    local units0, merges0 = b.units, b.pairings
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
    -- ZONE 3 IS FITTED INSIDE ZONE 2, WHICH IS FITTED INSIDE ZONE 1 (#344 round 2), so
    -- a client that has never drawn this match builds the chain up to the target once
    -- -- and since the rendering stage it builds EVERY zone of the match ahead of need,
    -- one a tick (storm.units), so the whole chain once each, and never another
    -- however many frames ask.
    local nZones = #env.BR.Config.Storm.phases
    ok(b.units - units0 <= nZones and b.pairings - merges0 <= 1,
        ('and across %d frames and %d ticks it built at most the %d zones of the '
            .. 'match, once each, and ONE pairing of their corners')
            :format(frames, math.floor(frames / 6), nZones),
        ('%d units, %d pairings'):format(b.units - units0, b.pairings - merges0))

    local S = newStormServer()
    local srec = S.record(3, 0.0, 0.0, 950.0, 200.0, 0.0, 520.0, 1000, 20000, 2.0)
    srec.seed = 98765
    local sb = S.env.BR.StormShape.builds
    local su0, sm0 = sb.units, sb.pairings
    for _ = 1, 25 do S.tick() end
    ok(S.errored() == nil and sb.units - su0 <= 3 and sb.pairings - sm0 <= 1,
        'and so did the server, ticking the damage pass through the same sweep',
        S.errored() or ('%d units, %d pairings'):format(sb.units - su0, sb.pairings - sm0))
end

-- ---------------------------------------------------------------------------
describe('zone.freeze')
do
    -- ═══ A FREEZE, ITS THAW, AND A SAME-PHASE `brphase` KEEP THE WALL'S SHAPE ═══
    --
    -- Mid-sweep the wall is part way between two zones: every corner disc on its way
    -- from a corner of one to a corner of the other. `brstormfreeze` replaces the
    -- record with one that holds the wall where it stands for a day, and its thaw
    -- re-enters the phase from there; `brphase` with the phase already running does
    -- the same. Each is a record that starts PART WAY through a morph, and each carries
    -- the wall's own discs (`mo`) -- or the wall would snap back to the zone it set out
    -- from the moment the command landed. Driven through the real commands on the real
    -- server file, and measured as the signed distance on a grid.
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

    --- The wall a record describes at `now`, placed.
    local function current(r, now)
        local cx, cy, rr, _, _, _, t = env.BR.StormAt(r, now)
        return env.BR.StormWall(r, t), cx, cy, rr
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
    local fromZone = diff(before, SS.blob(bx, by, br, env.BR.StormUnit(seed, 2)), bx, by, br)
    local toZone = diff(before, SS.blob(bx, by, br, env.BR.StormUnit(seed, 3)), bx, by, br)
    ok(tAt > 0.35 and tAt < 0.45 and fromZone > 1.0 and toZone > 1.0,
        'forty percent through the sweep the wall is part way between the two zones -- '
            .. 'neither shape, wherever it is put',
        ('t %.3f, %.1f m from one, %.1f from the other'):format(tAt, fromZone, toZone))

    S.cmds.brstormfreeze(0, {})
    local frz = S.match.storm
    local held = current(frz, S.now + 5000)
    ok(frz ~= rec and frz.mo ~= nil and diff(before, held, bx, by, br) < 1e-9,
        'the freeze holds the wall in the shape it was standing in, not the zone it set '
            .. 'out from -- the frozen record carries the wall\'s own discs',
        ('mo %s, worst %.3e m'):format(tostring(frz.mo), diff(before, held, bx, by, br)))
    ok(frz.cx1 == rec.cx1 and frz.cy1 == rec.cy1 and frz.r1 == rec.r1,
        'and it keeps the target it froze under, so the destination is still shown '
            .. 'and still safe for the length of the freeze')

    S.now = S.now + 20000
    S.cmds.brstormfreeze(0, { 'off' })
    local th = S.match.storm
    local thawed = current(th, S.now + 1000)
    ok(th ~= frz and th.mo ~= nil and diff(before, thawed, bx, by, br) < 1e-9,
        'and the thaw re-enters the phase in that same shape -- then sweeps it on into '
            .. 'the target\'s, which it reaches exactly',
        ('mo %s, worst %.3e m'):format(tostring(th.mo), diff(before, thawed, bx, by, br)))
    local nearEnd = env.BR.StormWall(th, 1.0 - 1e-9)
    local target = SS.blob(th.cx1, th.cy1, th.r1, env.BR.StormUnit(seed, 3))
    ok(diff(nearEnd, target, th.cx1, th.cy1, th.r1) < 1e-4,
        'the thawed sweep ends ON zone 3\'s own shape, so the next phase starts from it',
        ('worst %.3e m'):format(diff(nearEnd, target, th.cx1, th.cy1, th.r1)))

    -- AND `brphase` WITH THE PHASE ALREADY RUNNING, mid-sweep of the thawed record.
    S.now = th.tStart + th.tWait + 0.5 * th.tShrink
    local pre, px, py, pr = current(th, S.now)
    S.cmds.brphase(0, { '3' })
    local re = S.match.storm
    ok(re ~= th and diff(pre, current(re, S.now + 1000), px, py, pr) < 1e-9,
        '`brphase` into the phase already running keeps the wall\'s shape too -- a '
            .. 'morph of a morph, which is why the discs are carried and not two circles',
        ('worst %.3e m'):format(diff(pre, current(re, S.now + 1000), px, py, pr)))
    ok(S.errored() == nil, 'and all of it runs clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('agree.sweep')
do
    -- ═══ THE WALL A PLAYER SEES IS THE BOUNDARY THE SERVER BILLS, MID-MORPH (#344) ═══
    --
    -- The server and the client each build the zone from the record and the clock, and
    -- nothing about the shape crosses the wire -- so the claim worth pinning is that,
    -- at the same instant, the curtain the client draws stands edgeInset inside the
    -- boundary the server's damage tick bills against, and that the server bills a
    -- point exactly when the client's HUD says it is outside. Asked on a nested
    -- phase-2 sweep, where the wall is a morph of two zones, and across phase 1's hold
    -- and sweep, where the opening zone's wall stands from the start of the hold.
    --
    -- FAR FROM THE EDGE for the billing half: the server's cushion (#366's) is not this
    -- block's subject, so only points more than 200 m either side of the boundary are
    -- asked, where no cushion changes the answer.
    local function pair(phase, cx0, r0, cx1, r1, waitMs, shrinkMs, dps, want)
        local S = newStormServer()
        local C = newStormClient()
        local srec = S.record(phase, cx0, 0.0, r0, cx1, 0.0, r1, waitMs, shrinkMs, dps)
        local seed = 31337
        srec.seed = seed
        while want and not want(S.env, srec) do seed = seed + 1 srec.seed = seed end
        local crec = C.record(phase, cx0, 0.0, r0, cx1, 0.0, r1, waitMs, shrinkMs, dps)
        crec.seed = seed
        C.recordWallOnly()
        return S, srec, C, crec
    end

    --- Put both at `ms` into the record's timeline; return the server's zone there.
    local function at(S, srec, C, crec, ms)
        S.at(ms)
        crec.tStart = (C.now + 1500) - ms
        local cx, cy, r, _, _, _, t, g = S.env.BR.StormAt(srec, S.now + 1000)
        return S.env.BR.StormZone(srec, cx, cy, r, t, g), t
    end

    local function check(label, S, srec, C, crec, moments, box)
        local SSs = S.env.BR.StormShape
        local inset = C.env.BR.Config.Storm.render.edgeInset
        local wallOff, billBad, asked = 0.0, nil, 0
        for _, ms in ipairs(moments) do
            -- THE WALL, drawn at exactly this instant, against the SERVER's zone.
            local zone = at(S, srec, C, crec, ms)
            crec.tStart = (C.now + 16) - ms
            C.frame()
            for _, qd in ipairs(quadsOf(C)) do
                wallOff = math.max(wallOff,
                    math.abs(SSs.distance(zone, qd.a.x, qd.a.y) + inset))
            end
            -- THE BILLING, against the client's own HUD, far from the edge.
            local R = S.env.BR.Rng(ms + 11)
            for _ = 1, 24 do
                local x = box[1] + (box[2] - box[1]) * R:float()
                local y = box[3] + (box[4] - box[3]) * R:float()
                at(S, srec, C, crec, ms)
                C.pedAt = pt(x, y)
                C.tick(1)
                local e = C.last() and C.last().edgeDistance
                if e and math.abs(e) > 200.0 then
                    asked = asked + 1
                    S.at(ms)
                    local billed = S.hurts(x, y)
                    local _, _, _, _, _, dps = S.env.BR.StormAt(srec, S.now)
                    if billed ~= (e > 0.0 and dps > 0.0) then
                        billBad = billBad or ('%s at %d ms: HUD %.1f, billed %s')
                            :format(label, ms, e, tostring(billed))
                    end
                end
            end
        end
        return wallOff, billBad, asked
    end

    -- ─── a nested phase-2 sweep: the wall is a morph of two zones ───
    local S, srec, C, crec = pair(2, 0.0, 2600.0, 700.0, 1600.0, 20000, 120000, 1.25,
        function(env, rec) return env.BR.StormNested(rec) end)
    local moments = { 5000, 32000, 50000, 80000, 110000, 135000 }
    local off, bad, asked = check('phase 2', S, srec, C, crec, moments,
        { -3000.0, 3500.0, -3000.0, 3000.0 })
    ok(off < 1e-6,
        'at every moment of a nested sweep the client\'s curtain stands edgeInset inside '
            .. 'exactly the boundary the server bills -- the morph included',
        ('worst %.3e m'):format(off))
    ok(bad == nil and asked > 60 and S.errored() == nil and C.errored() == nil,
        'and the server bills a point exactly when the client\'s HUD says it is outside',
        bad or S.errored() or C.errored() or ('%d asked'):format(asked))

    -- ─── phase 1: the opening zone's wall through the hold, then the sweep ───
    --
    -- The hold is the free-loot rule's: dps 0 everywhere, so nothing is billed -- and
    -- the wall stands on the opening zone the whole time, which is the ring the sweep
    -- then carries in.
    local S1, srec1, C1, crec1 = pair(1, 0.0, 6000.0, 600.0, 2600.0, 60000, 120000, 0.5)
    local m1 = { 15000, 45000, 70000, 100000, 150000, 179000 }
    local off1, bad1, asked1 = check('phase 1', S1, srec1, C1, crec1, m1,
        { -5000.0, 5000.0, -5000.0, 5000.0 })
    ok(off1 < 1e-6,
        'and across phase 1\'s hold and sweep the opening wall stands edgeInset inside the '
            .. 'boundary the server bills, from the hold\'s first seconds to the end',
        ('worst %.3e m'):format(off1))
    ok(bad1 == nil and asked1 > 60 and S1.errored() == nil and C1.errored() == nil,
        'with nobody billed through the free-loot hold, and exactly the HUD\'s outside once '
            .. 'the sweep is under way',
        bad1 or S1.errored() or C1.errored() or ('%d asked'):format(asked1))
end

-- ---------------------------------------------------------------------------
describe('grow.agree')
do
    -- ═══ A CONJOINED ZONE GROWS INTO ITS DESTINATION, AND EVERYTHING AGREES (#344) ═══
    --
    --   "when the storm finishes moving and the next phase is opened, if they're
    --    conjoined, today the border pops suddenly to cover the whole area. instead it
    --    should grow over a period of 20s to include that new area instead of
    --    popping."                                        -- the owner, 2026-09-23
    --
    -- The safe zone of a breakout whose destination D overlaps the zone Z the wall
    -- stands in is Z union (D intersect Z grown by s), with s running from 0 to S --
    -- the furthest D reaches outside Z -- across the hold's first grow.seconds. What
    -- makes it shippable is that the SERVER bills it, the CLIENT'S HUD reads it and the
    -- WALL draws it, off one record and one clock, and this block asks all three at the
    -- same instants.
    --
    -- ═══ THE EXPECTATION IS DERIVED WITHOUT THE ZONE ═══
    --
    -- Every probe point is chosen DEEP inside D and OUTSIDE Z by some d: for such a
    -- point the grown zone's edge is the grown boundary of Z, so it is outside by
    -- exactly d - s until s reaches d, and inside after. That is arithmetic on the two
    -- shapes' own signed distances and the clock -- never BR.StormZone -- so a growth
    -- that ran at the wrong speed, in the wrong place, or popped, reads as a wrong
    -- number here.
    local S = newStormServer()
    local env = S.env
    local SS = env.BR.StormShape
    local rec = S.record(3, 0.0, 0.0, 1600.0, 1500.0, 0.0, 950.0, 90000, 90000, 1.7)
    local seed = 13579
    rec.seed = seed
    while not (env.BR.StormOverlaps(rec)) or select(2, env.BR.StormOverlaps(rec)) < 400.0 do
        seed = seed + 1
        rec.seed = seed
    end
    local _, reach = env.BR.StormOverlaps(rec)
    local Z = env.BR.StormWall(rec, 0.0)
    local D = env.BR.StormTarget(rec)
    local Tg = math.min(env.BR.Config.Storm.grow.seconds * 1000.0, rec.tWait)
    ok(Tg == 20000.0 and reach > 400.0,
        'the shipping growth is twenty seconds, on a pair whose destination reaches far '
            .. 'outside the zone it overlaps',
        ('%.0f ms, S %.1f m'):format(Tg, reach))

    -- PROBES: deep in D -- deeper than they are outside Z, which is what keeps the
    -- grown edge nearest them on Z's grown boundary -- and spread across the growth's
    -- first two fifths, which is about as far out as a point that deep can be.
    local probes = {}
    local R = env.BR.Rng(97)
    local tries = 0
    while #probes < 8 and tries < 50000 do
        tries = tries + 1
        local x = rec.cx1 + (R:float() * 2.0 - 1.0) * rec.r1 * 1.6
        local y = rec.cy1 + (R:float() * 2.0 - 1.0) * rec.r1 * 1.6
        local d = SS.distance(Z, x, y)
        local dd = SS.distance(D, x, y)
        local band = (#probes + 0.5) / 8.0 * 0.4
        if d > 40.0 and dd < -(d + 5.0) and math.abs(d / reach - band) < 0.03 then
            probes[#probes + 1] = { x = x, y = y, d = d }
        end
    end
    ok(#probes == 8, 'eight probe points deep in the destination, outside the zone, '
            .. 'spread across the growth',
        ('%d found, the last at d %.1f of S %.1f'):format(#probes,
            probes[#probes] and probes[#probes].d or 0.0, reach))

    -- ─── the SERVER: each probe is billed until the front passes it, then never ───
    --
    -- PAST THE CUSHION, which is ten metres of the zone as it will stand 0.7 s from
    -- now as well as of the zone now (#344): the front moves tens of metres a second,
    -- and a client clock a moment ahead shows it that much further out. So the
    -- front the server bills against is the one 0.7 s on -- still clock arithmetic.
    local MARGIN, AHEAD = 10.0, 700.0
    local function frontAt(tau) return reach * math.min(tau / Tg, 1.0) end
    local wrongBill, monotone, freed = nil, true, 0
    for _, q in ipairs(probes) do
        local wasSafe = false
        for tau = 0, 20000, 1000 do
            S.at(tau)
            local billed = S.hurts(q.x, q.y)
            local s = frontAt(tau + AHEAD)
            -- Outside the grown zone by d - s until the front reaches it; the server
            -- bills past the cushion. At the growth's end the zone is the whole union.
            local want = (q.d - s) > MARGIN
            if tau >= Tg then want = false end
            if billed ~= want and math.abs((q.d - s) - MARGIN) > 1e-6 then
                wrongBill = wrongBill or ('probe d %.1f at %d ms: billed %s, front at %.1f')
                    :format(q.d, tau, tostring(billed), s)
            end
            if billed and wasSafe then monotone = false end
            if not billed then wasSafe = true end
        end
        if wasSafe then freed = freed + 1 end
    end
    ok(wrongBill == nil and S.errored() == nil,
        'the server bills every probe exactly while the growing front, 0.7 s on, is more '
            .. 'than the cushion short of it -- the ground is taken in at one speed, from '
            .. 'the zone out, over twenty seconds',
        wrongBill or S.errored())
    ok(monotone and freed == #probes,
        'and once a probe is taken in it stays safe: the growth never gives ground back, '
            .. 'and by its end it has taken all of them',
        ('%d of %d freed'):format(freed, #probes))

    -- AND THE POP IS GONE: at the first second of the hold a point in the destination
    -- well outside the zone is still billed, where it used to be safe from the start.
    local far = probes[#probes]
    S.at(0)
    ok(S.hurts(far.x, far.y) == true,
        'a second into the phase the far end of the destination is still storm, where '
            .. 'the old union made it safe at once',
        ('d %.1f'):format(far.d))

    -- ─── the CLIENT'S HUD reads the same number at the same instants ───
    local C = newStormClient()
    C.record(3, 0.0, 0.0, 1600.0, 1500.0, 0.0, 950.0, 90000, 90000, 1.7)
    local crec = C.env.BR.State.storm
    crec.seed = seed
    local hudBad, agreeBad = nil, nil
    for _, q in ipairs(probes) do
        for tau = 0, 20000, 2500 do
            crec.tStart = (C.now + 1500) - tau
            C.pedAt = pt(q.x, q.y)
            C.tick(1)
            local e = C.last() and C.last().edgeDistance
            local s = reach * math.min(tau / Tg, 1.0)
            if s < q.d then
                if not e or math.abs(e - (q.d - s)) > 1e-6 then
                    hudBad = hudBad or ('probe d %.1f at %d ms: HUD %s, wanted %.6f')
                        :format(q.d, tau, tostring(e), q.d - s)
                end
            elseif not e or e > 0.0 then
                hudBad = hudBad or ('probe d %.1f at %d ms: HUD %s, wanted inside')
                    :format(q.d, tau, tostring(e))
            end
            -- AND THE SERVER, at the SAME instant, bills exactly when the HUD says the
            -- player is past the cushion -- the ten metres, and however far the front
            -- moves in the next 0.7 s.
            S.at(tau)
            local billed = S.hurts(q.x, q.y)
            if e and billed ~= ((e - (frontAt(tau + AHEAD) - s)) > MARGIN) then
                agreeBad = agreeBad or ('probe d %.1f at %d ms: HUD %.3f, billed %s')
                    :format(q.d, tau, e, tostring(billed))
            end
        end
    end
    ok(hudBad == nil and C.errored() == nil,
        'the HUD reads each probe d - s metres outside while the front is short of it, '
            .. 'and inside after -- the same growth, on the client\'s own solve',
        hudBad or C.errored())
    ok(agreeBad == nil,
        'and at every instant the server bills exactly the probes the HUD shows past the '
            .. 'cushion and the front\'s next 0.7 s: wall, readout and damage are one zone '
            .. 'through the growth',
        agreeBad)

    -- ─── the WALL draws the front ───
    --
    -- Half way through the growth, the curtain stands on the grown zone -- every
    -- corner on its inset boundary -- and some of it stands OUTSIDE the zone the phase
    -- started in, which is the front a popped union or a stalled growth would not have.
    crec.tStart = (C.now + 16) - Tg * 0.5
    C.pedAt = pt(rec.cx1, rec.cy1)
    C.frame()
    local cx, cy, r, _, _, _, t, g = C.env.BR.StormAt(crec, C.env.BR.Clock.now())
    local grown = SS.inset(C.env.BR.StormZone(crec, cx, cy, r, t, g),
        C.env.BR.Config.Storm.render.edgeInset)
    local offG, beyond = 0.0, 0
    for _, qd in ipairs(quadsOf(C)) do
        for _, v in ipairs({ qd.a, qd.b }) do
            offG = math.max(offG, math.abs(SS.distance(partAt(C.env, grown, v.x, v.y),
                v.x, v.y)))
            if SS.distance(Z, v.x, v.y) > 1.0 then beyond = beyond + 1 end
        end
    end
    ok(g > 0.45 and g < 0.55 and offG < 1e-6 and beyond > 0,
        'half way through, the wall stands on the grown zone to a micron, and part of '
            .. 'it is out beyond the zone the phase started in: the front, drawn',
        ('g %.3f, %.3e m off, %d corners beyond'):format(g, offG, beyond))

    -- ─── and the grown zone is the WHOLE union exactly as it ends ───
    local endZone = env.BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0, 0.0, 1.0 - 1e-9)
    local popped = SS.blobUnion(env.BR.StormWall(rec, 0.0), env.BR.StormTarget(rec))
    local endErr = 0.0
    for gx = -12, 12 do
        for gy = -12, 12 do
            local px, py = rec.cx1 + gx * 150.0, gy * 150.0
            endErr = math.max(endErr,
                math.abs(SS.distance(endZone, px, py) - SS.distance(popped, px, py)))
        end
    end
    ok(endErr < 1e-4,
        'at the end of the growth the zone is Z union D to the rounding of the last '
            .. 'nanosecond -- it arrives on the union rather than popping onto it',
        ('%.3e m'):format(endErr))

    -- ─── the MAP does not follow the growth: Z as the hold began, and D beside it ───
    --
    --   "when the sweep starts, the old shape fades away and only the new shape is
    --    left. that means the only indicator of the actual current shape of the storm
    --    is looking in the 3d world."                     -- the owner, 2026-10-04
    --
    -- The 3D wall and the damage tick grow the zone into D over grow.seconds; the map
    -- shows nothing that changes shape. It draws the zone as the hold began -- Z, where
    -- the last sweep left the wall -- and the destination, whose own fill covers the
    -- ground Z grows into: so the two fills cover the grown zone at every instant, and
    -- the whole union once it has grown, with nothing added, removed, moved, resized or
    -- faded. (Until 2026-10-04 the zone's fill was redrawn as the growth ended -- and
    -- before 2026-10-02 every tick of it.) A refusal mid-growth is therefore no case of
    -- its own any more: there is nothing to refuse until the sweep's fade.
    local M = newStormClient()
    M.mm.handle = 7
    M.record(3, 0.0, 0.0, 1600.0, 1500.0, 0.0, 950.0, 90000, 90000, 1.7)
    M.env.BR.State.storm.seed = seed
    ok(M.overlayReady(), 'the map client reaches the gate')
    local mrec = M.env.BR.State.storm
    mrec.tStart = M.now
    M.tick(1)

    --- Whether a point is inside any contour of `list` as the movie shows it.
    local function covers(C2, list, x, y)
        for _, ov in ipairs(list) do
            local poly, inside = C2.shown(ov), false
            local j = #poly
            for i = 1, #poly do
                local a, b = poly[j], poly[i]
                if ((b.y > y) ~= (a.y > y))
                        and (x < (a.x - b.x) * (y - b.y) / (a.y - b.y) + b.x) then
                    inside = not inside
                end
                j = i
            end
            if inside then return true end
        end
        return false
    end
    local function filled(C2, x, y)
        return covers(C2, C2.zone(), x, y) or covers(C2, C2.dest(), x, y)
    end
    local chord = M.env.BR.Config.Storm.overlay.chordM
    local zoneO = M.env.BR.Config.Storm.blip.currentAlpha / 255
    local destO = M.env.BR.Config.Storm.blip.nextAlpha / 255
    local mZ = M.env.BR.StormWall(mrec, 0.0)
    local zFill, zO = M.zoneFill()
    local zOff = zFill and 0.0 or math.huge
    for _, p in ipairs(zFill and M.shown(zFill) or {}) do
        zOff = math.max(zOff, math.abs(SS.distance(mZ, p.x, p.y)))
    end
    ok(#M.zone() == 1 and #M.dest() == 1 and zOff < 1e-6 and near(zO, zoneO, 0.5 / 255),
        'as the hold begins the map shows Z -- the wall where the last sweep left it -- at '
            .. 'the safe zone\'s strength, and the destination beside it',
        ('%d zone, %d destination, %.3e m off Z, %.4f'):format(#M.zone(), #M.dest(), zOff,
            zO))

    local destClip, zoneClip = M.dest()[1], M.zone()[1]
    local calls0 = M.mm.calls
    local gTicks, growing, uncovered, probed, coverBad = 0, 0, 0, 0, nil
    for _ = 1, 190 do
        M.now = M.now + 100
        M.env.BR.Loop.step(M.env.BR.Loop.TICK)
        gTicks = gTicks + 1
        local cx, cy, r, _, _, _, t, g = M.env.BR.StormAt(mrec, M.env.BR.Clock.now())
        if g < 1.0 then growing = growing + 1 end
        -- EVERY PROBE THE GROWN ZONE HAS TAKEN IN, with the fill's chord to spare, is
        -- under one of the two fills -- by the solve at this instant.
        local G = M.env.BR.StormZone(mrec, cx, cy, r, t, g)
        for _, pr in ipairs(probes) do
            if SS.distance(G, pr.x, pr.y) < -chord then
                probed = probed + 1
                if not filled(M, pr.x, pr.y) then
                    uncovered = uncovered + 1
                    coverBad = coverBad or ('%d ms: (%.0f, %.0f) is safe and unfilled')
                        :format(gTicks * 100, pr.x, pr.y)
                end
            end
        end
    end
    ok(growing > 150 and M.mm.calls == calls0 and M.dest()[1] == destClip
            and M.zone()[1] == zoneClip and #M.areas() == 2 and M.errored() == nil,
        'across the growth the movie hears nothing -- no add, removal, placement or fade -- '
            .. 'and the same two clips stand',
        M.errored() or ('%d growing ticks, %d calls'):format(growing, M.mm.calls - calls0))
    ok(uncovered == 0 and probed > 0,
        'and every probe the growing zone has taken in is under the zone\'s fill or the '
            .. 'destination\'s at every tick -- the map covers the grown zone without changing '
            .. 'shape', coverBad or ('%d probe readings'):format(probed))

    -- ─── grown, the union is covered by the two fills, and nothing beyond it ───
    local U = SS.blobUnion(env.BR.StormWall(rec, 0.0), env.BR.StormTarget(rec))
    local inBad, outBad = 0, 0
    for gx = -30, 30 do
        for gy = -30, 30 do
            local x, y = 750.0 + gx * 60.0, gy * 60.0
            local d = SS.distance(U, x, y)
            if d < -chord and not filled(M, x, y) then inBad = inBad + 1 end
            if d > chord and filled(M, x, y) then outBad = outBad + 1 end
        end
    end
    ok(inBad == 0 and outBad == 0,
        'once grown, every point of Z union D is under one of the two fills and no point '
            .. 'outside it is', ('%d safe points unfilled, %d storm points filled'):format(
            inBad, outBad))

    -- ─── the rest of the hold sends nothing; the sweep fades Z and leaves D ───
    for _ = 1, 694 do
        M.now = M.now + 100
        M.env.BR.Loop.step(M.env.BR.Loop.TICK)
    end
    local _, _, _, stB, msB = M.env.BR.StormAt(mrec, M.env.BR.Clock.now())
    ok(stB == M.env.BR.StormPhase.HOLDING and msB <= 100.0 and M.mm.calls == calls0,
        'the rest of the hold sends the movie nothing at all',
        ('%s, %.0f ms left, %d calls'):format(tostring(stB), msB, M.mm.calls - calls0))
    local by0 = {}
    for k, v in pairs(M.mm.byMethod) do by0[k] = v end
    for _ = 1, 30 do
        M.now = M.now + 100
        M.env.BR.Loop.step(M.env.BR.Loop.TICK)
    end
    local sent = {}
    for k, v in pairs(M.mm.byMethod) do
        if v ~= (by0[k] or 0) then sent[#sent + 1] = ('%s %d'):format(k, v - (by0[k] or 0)) end
    end
    table.sort(sent)
    ok(#sent == 1 and sent[1]:find('^SET_OVERLAY_ALPHA') ~= nil
            and M.opacity(zoneClip) == 0.0 and M.dest()[1] == destClip
            and near(M.opacity(destClip), destO, 0.5 / 255) and #M.visible() == 1,
        'and three seconds into the sweep Z has faded off -- alpha writes and nothing else -- '
            .. 'and the destination is the one fill left, untouched',
        ('%s; zone %.4f, destination %.4f, %d visible'):format(table.concat(sent, ', '),
            M.opacity(zoneClip), M.opacity(destClip), #M.visible()))
    ok(M.errored() == nil, 'and runs clean', M.errored())
end

-- ---------------------------------------------------------------------------
describe('grow.freeze')
do
    -- ═══ A FREEZE MID-GROWTH NEITHER SHRINKS THE ZONE BACK NOR GROWS IT TWICE ═══
    --
    -- brstormfreeze replaces the record with one that starts where the storm stands,
    -- and keeps the target; its thaw does the same again. Each is a new record with a
    -- new start, so without carrying how far the growth had got (mo.g) the zone would
    -- snap back to where the phase began the instant either command landed.
    local S = newStormServer()
    local env = S.env
    local SS = env.BR.StormShape
    env.BR.Server.devMode = true
    S.match.stormRng = env.BR.Rng(4242)
    local rec = S.record(3, 0.0, 0.0, 1600.0, 1500.0, 0.0, 950.0, 90000, 90000, 1.7)
    local seed = 13579
    rec.seed = seed
    while not (env.BR.StormOverlaps(rec)) do seed = seed + 1 rec.seed = seed end
    S.match.stormSeed = seed
    local function zoneAt(r, now)
        local cx, cy, rr, _, _, _, t, g = env.BR.StormAt(r, now)
        return env.BR.StormZone(r, cx, cy, rr, t, g), g
    end
    local function diff(a, b)
        local worst = 0.0
        for gx = -12, 12 do
            for gy = -12, 12 do
                local px, py = 750.0 + gx * 150.0, gy * 150.0
                worst = math.max(worst,
                    math.abs(SS.distance(a, px, py) - SS.distance(b, px, py)))
            end
        end
        return worst
    end

    S.now = rec.tStart + 8000
    local before, g0 = zoneAt(rec, S.now)
    S.cmds.brstormfreeze(0, {})
    local frz = S.match.storm
    local held, gh = zoneAt(frz, S.now)
    ok(frz ~= rec and frz.mo and near(frz.mo.g, g0, 1e-12) and near(gh, g0, 1e-12)
            and diff(before, held) < 1e-6,
        'a freeze eight seconds into the growth carries how far it had got, and the zone '
            .. 'it holds is the zone that stood there',
        ('g %.4f carried as %s, worst %.3e m'):format(g0, tostring(frz.mo and frz.mo.g),
            diff(before, held)))

    -- AND IT GOES ON GROWING THROUGH THE FREEZE, off the frozen record's own clock:
    -- the freeze holds the storm, and the growth is not the storm moving.
    S.now = S.now + 5000
    local _, gf = zoneAt(frz, S.now)
    ok(near(gf, g0 + 5000.0 / 20000.0, 1e-12),
        'the frozen zone carries on growing from where it had got to',
        ('g %.4f five seconds later'):format(gf))

    -- THE THAW DRAWS A NEW DESTINATION -- it re-enters the phase from where the storm
    -- stands, as enterPhase always has -- so it has a growth of its own ahead of it
    -- and carries none: a growth carried onto a different destination would pop part
    -- of it into the safe zone at once.
    S.cmds.brstormfreeze(0, { 'off' })
    local th = S.match.storm
    local _, gt = zoneAt(th, S.now)
    ok(th ~= frz and (th.mo == nil or th.mo.g == nil) and gt == 0.0,
        'and the thaw, which draws a new destination, starts its growth afresh',
        ('thawed g %s'):format(tostring(gt)))
    ok(S.errored() == nil, 'and runs clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('unit.warm')
do
    -- ═══ EVERY ZONE OF THE MATCH IS BUILT AHEAD OF NEED, ONE A TICK (#344) ═══
    --
    -- A zone's shape costs about two milliseconds to build, and each is fitted inside
    -- the one before it, so left to the first frame that needs it a phase edge pays one
    -- inside a frame and a joiner pays the whole chain. The client builds the chain the
    -- moment it knows the seed -- the warmup preview publishes it -- one zone per tick,
    -- each marked for /brstormhitch.
    local C = newStormClient()
    local env = C.env
    local MS, PS = env.BR.MatchState, env.BR.PlayerState
    env.BR.State.storm = nil
    env.BR.State.match.state = MS.WARMUP
    env.BR.State.me.state    = PS.WARMUP or PS.ALIVE
    env.BR.State.stormPreview = { cx = 0.0, cy = 0.0, r = 2600.0, seed = 777001 }
    env.BR.Loop.hitchStart(34)
    local b = env.BR.StormShape.builds
    local n = #env.BR.Config.Storm.phases
    local perTick, u0 = {}, b.units
    for i = 1, n + 4 do
        local before = b.units
        C.now = C.now + 100
        env.BR.Loop.step(env.BR.Loop.TICK)
        perTick[i] = b.units - before
    end
    local most = 0
    for _, k in ipairs(perTick) do most = math.max(most, k) end
    local row = nil
    for _, rw in ipairs(env.BR.Loop.hitchStats().rows) do
        if rw.name == 'storm.unit.build' then row = rw end
    end
    ok(b.units - u0 == n and most == 1,
        'the warmup preview\'s seed has every zone of the match built, one per tick, in '
            .. 'order -- each finding its parent already built',
        ('%d built, at most %d a tick'):format(b.units - u0, most))
    ok(row ~= nil and row.events == n,
        'and each build is one storm.unit.build mark, and nothing is marked once they '
            .. 'are all built',
        row and ('%d marks'):format(row.events) or 'no row')
    local ready = true
    for z = 1, n do
        if not env.BR.StormShape.blobUnitReady(777001, z, env.BR.Config.Storm.shape,
                env.BR.Config.Storm.phases) then ready = false end
    end
    ok(ready and C.errored() == nil,
        'so by the time the match goes live every zone the wall will ask for is ready',
        C.errored())
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
describe('server.final')
do
    -- ═══ STORM REVEAL (#396) SHOWS WHERE THE STORM WILL END, SO IT HAS TO BE IT ═══
    --
    --   "Storm would allow them to see where the storm is going to end for that
    --    match"                                              -- owner, 2026-10-04
    --
    -- BR.Storm.finalCentre walks the phases enterPhase has not drawn yet against a
    -- COPY of the stream. Two things can go wrong and both would look like a
    -- working feature: the walk disagrees with enterPhase (a squad spends its key
    -- on a lie), or the walk advances the real stream (the match is no longer the
    -- match -- every later phase takes the value meant for the one before, which is
    -- first.stream's failure arriving through a function that only looks).
    --
    -- So the prediction is asked at warmup and at every phase entry of a walked
    -- match and compared with where the walk actually ended, bit for bit; and the
    -- whole match is compared with a twin that never asked.
    local ANCHOR = { x = 150.0, y = -900.0, name = 'Test' }
    local S = newStormServer()
    local env = S.env
    S.roster[1] = nil
    S.match.storm = nil
    S.match.anchor = { x = ANCHOR.x, y = ANCHOR.y, name = ANCHOR.name }
    env.BR.Sched.setEnabled('storm.phase', true)

    ok(env.BR.Storm.finalCentre(S.match) == nil,
        'before circle 1 is drawn there is no stream and no answer')

    S.match.state = env.BR.MatchState.WARMUP
    env.BR.Storm.drawFirstCircle(S.match)
    S.match.state = env.BR.MatchState.PLAYING

    local preds, moved = {}, 0
    local function predict(label)
        local s = S.match.stormRng.s
        local before = { s[1], s[2], s[3], s[4] }
        local f = env.BR.Storm.finalCentre(S.match)
        local now = S.match.stormRng.s
        if now[1] ~= before[1] or now[2] ~= before[2] or now[3] ~= before[3]
            or now[4] ~= before[4] then
            moved = moved + 1
        end
        preds[#preds + 1] = { label = label, f = f }
    end

    predict('warmup')
    env.BR.Storm.begin(S.match)
    predict('phase 1')

    local last = #env.BR.Config.Storm.phases
    local seen, final = { [S.match.storm.phase] = true }, nil
    local guard = 0
    while guard < 4000 do
        guard = guard + 1
        S.now = S.now + 30000
        env.BR.Sched.step(S.now)
        local rec = S.match.storm
        if rec and not seen[rec.phase] then
            seen[rec.phase] = true
            predict('phase ' .. rec.phase)
        end
        if rec and rec.phase == last then
            final = { x = rec.cx1, y = rec.cy1, r = rec.r1 }
            break
        end
    end

    ok(S.errored() == nil, 'the match runs clean', S.errored())
    ok(final ~= nil, ('the walk reached phase %d'):format(last))
    ok(#preds == last + 1, ('asked at warmup and at each of the %d phases'):format(last), #preds)
    ok(moved == 0, 'asking never moved the live stream by one draw', moved)

    local wrong = {}
    for _, p in ipairs(preds) do
        local f = p.f
        if not (final and f and f.x == final.x and f.y == final.y and f.r == final.r
                and f.phase == last) then
            wrong[#wrong + 1] = p.label
        end
    end
    ok(#wrong == 0, 'every prediction is where the storm actually ended, bit for bit',
        table.concat(wrong, ', '))

    -- THE TWIN: the same match walked without a single question asked.
    local twin = walkMatch(ANCHOR, true)
    local t = twin.phases[last]
    ok(t and final and t.cx == final.x and t.cy == final.y,
        'and a twin match that never asked ends in the same place',
        t and final and ('(%.3f, %.3f) vs (%.3f, %.3f)'):format(t.cx, t.cy, final.x, final.y))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTROL TOWER'S STORM FUNCTIONS (#396, wave B): the planner's half
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Storm control changes the storm through server/storm.lua and nothing else:
-- the circles still to be drawn are the match's own stream (BR.Storm.futures /
-- BR.Storm.steer). The door in front of it -- the key, the refusals, the
-- refund -- is tools/test_terminalworld.lua's.

--- A match walked through the REAL phase job, from its first record, until
--- `stop(rec, state)` says so. No players, so the hold and the sweep pricing
--- are constant and only the stream decides where the circles go (walkMatch's
--- reason).
--- @param anchor table
--- @param stop function(rec, state) -> boolean
--- @param stepMs number|nil  how far the clock moves per pass (default 5 s)
--- @param t0 number|nil  the server clock it starts at: the storm seed is drawn
---                       off it, so a different t0 is a different match
--- @return table S
local function walkUntil(anchor, stop, stepMs, t0)
    local S = newStormServer()
    local env = S.env
    if t0 then S.now = t0 end
    S.roster[1] = nil
    S.match.storm = nil
    S.match.anchor = { x = anchor.x, y = anchor.y, name = anchor.name or 'Test' }
    env.BR.Sched.setEnabled('storm.phase', true)
    S.match.state = env.BR.MatchState.WARMUP
    env.BR.Storm.drawFirstCircle(S.match)
    S.match.state = env.BR.MatchState.PLAYING
    env.BR.Storm.begin(S.match)
    for _ = 1, 20000 do
        local rec = S.match.storm
        local _, _, _, st = env.BR.StormAt(rec, S.now)
        if stop(rec, st) then break end
        S.now = S.now + (stepMs or 5000)
        env.BR.Sched.step(S.now)
    end
    return S
end

--- Step a walked match on until `stop` says so, from where it stands.
local function walkOn(S, stop, stepMs)
    local env = S.env
    for _ = 1, 20000 do
        local rec = S.match.storm
        local _, _, _, st = env.BR.StormAt(rec, S.now)
        if stop(rec, st) then return true end
        S.now = S.now + (stepMs or 5000)
        env.BR.Sched.step(S.now)
    end
    return false
end

-- ---------------------------------------------------------------------------
describe('removed.delay')
do
    -- ═══ STORM DELAY IS GONE (owner, 2026-10-06: "Storm delay doesn't make
    --     sense to have really. We have to keep the pace of the match.") ═══
    --
    -- Nothing of it is left in the planner: no BR.Storm.delay or holdLeft, and
    -- the 75% cut (#352) is 1:30 flat again -- it reads no held time off the
    -- match, so a leftover field from anywhere cannot stretch a hold.
    local S = newStormServer()
    local env = S.env
    eq(env.BR.Storm.delay, nil, 'no BR.Storm.delay')
    eq(env.BR.Storm.holdLeft, nil, 'no BR.Storm.holdLeft')
    env.BR.Sched.setEnabled('storm.phase', true)
    S.roster[1] = nil
    S.match.stormHoldCapped = true
    S.match.stormSeed = 7
    S.match.stormRng = env.BR.Rng(7)
    S.record(1, 0.0, 0.0, 4000.0, 300.0, 0.0, 2600.0, 300000, 240000, 0.5)
    S.match.stormHeldMs = 60000
    S.match.stormDelayNextMs = 60000
    S.tick()
    local CAP = env.BR.Config.Storm.hold.capSeconds * 1000.0
    local _, _, _, st, left = env.BR.StormAt(S.match.storm, S.now)
    eq(st, env.BR.StormPhase.HOLDING, 'phase 1 holds')
    ok(near(left, CAP, 1.0), 'and the latched cut takes it to 1:30, whatever the match carries', left)
    -- AND THE NEXT HOLD IS ITS OWN: enterPhase adds nothing to it.
    for _ = 1, 2000 do
        if S.match.storm.phase == 2 then break end
        S.now = S.now + 5000
        env.BR.Sched.step(S.now)
    end
    eq(S.match.storm.phase, 2, 'the storm moves on to phase 2')
    eq(S.match.storm.tWait, env.BR.Config.Storm.phases[2].wait * 1000,
        'whose hold is its own, with nothing carried into it')
    ok(S.errored() == nil, 'clean', S.errored())
end

--- Is the zone `phase` closes on at (cx1, cy1, r1) NESTED in the zone at
--- (cx0, cy0, r0), by the planner's own test (BR.NextZoneCentre's `nested`)?
--- An aimed phase (Storm control) never breaks out.
--- @return boolean
local function nestedIn(env, seed, phase, cx0, cy0, r0, cx1, cy1, r1)
    local SS = env.BR.StormShape
    local host = env.BR.StormHost(seed, phase, cx0, cy0, r0, nil)
    local hks = host and host.hull and host.hull.ks
    if not hks then
        local d = host and host.discs and host.discs[1]
        hks = SS.discHull({ { x = d and d.x or cx0, y = d and d.y or cy0, r = d and d.r or r0 } })
    end
    local unit = env.BR.StormUnit(seed, phase)
    local D0 = {}
    if unit and r1 > 0.0 then
        for k, d in ipairs(unit.discs) do D0[k] = { x = d.x * r1, y = d.y * r1, r = d.r * r1 } end
    else
        D0[1] = { x = 0.0, y = 0.0, r = 0.0 }
    end
    return SS.fit(hks, D0, cx1, cy1, 1.0) <= 1e-6
end

-- ═══ STORM CONTROL, ROUND 5 (#396, owner 2026-10-06) ═══
--
--   "this limitation should not exist. the next phases should instead work
--    towards the location the player selected."
--
-- No spot is refused any more. The blocks below hold the three promises the
-- plan makes (br_lib/shared/storm_solve.lua's STORM CONTROL block) against the
-- planner's own tests rather than the plan's polygons: every later circle is a
-- circle the planner's rules allow, the storm ends exactly on the spot when it
-- can get there and otherwise as near it as any storm the rules allow could
-- (a brute-force bound, `control.reach`), and each circle is as near the spot as
-- any center that still ends there (a brute-force search, `control.first`).

--- The zone `phase` closes from at (cx, cy, r), as the corner list the planner
--- tests nesting against (BR.NextZoneCentre's hostHull, spelled again).
local function hostKsOf(env, seed, phase, cx, cy, r)
    local SS = env.BR.StormShape
    local host = env.BR.StormHost(seed, phase, cx, cy, r, nil)
    local hks = host and host.hull and host.hull.ks
    if not hks then
        local d = host and host.discs and host.discs[1]
        hks = SS.discHull({ { x = d and d.x or cx, y = d and d.y or cy, r = d and d.r or r } })
    end
    return hks
end

--- Zone `phase`'s discs about its own center, at its radius.
local function discsAt(env, seed, phase)
    local r1 = env.BR.Config.Storm.phases[phase].radius
    local unit = env.BR.StormUnit(seed, phase)
    local D0 = {}
    if unit and r1 > 0.0 then
        for k, d in ipairs(unit.discs) do D0[k] = { x = d.x * r1, y = d.y * r1, r = d.r * r1 } end
    else
        D0[1] = { x = 0.0, y = 0.0, r = 0.0 }
    end
    return D0
end

--- Is zone `phase` at (x, y) inside the map bounds by its exact box (the
--- planner's `boxed`)?
local function boxedAt(env, seed, phase, x, y)
    local A = env.BR.Config.Storm.mapAABB
    local west, east, south, north = 0.0, 0.0, 0.0, 0.0
    for _, d in ipairs(discsAt(env, seed, phase)) do
        west = math.max(west, -d.x + d.r)
        east = math.max(east, d.x + d.r)
        south = math.max(south, -d.y + d.r)
        north = math.max(north, d.y + d.r)
    end
    return x - west >= A.min.x and x + east <= A.max.x and y - south >= A.min.y and y + north <= A.max.y
end

--- An aimed chain held to the planner's own tests, phase by phase from `from`:
--- nested in the zone before by the real fit, with the planner's clearance; and
--- inside the map bounds wherever the planner would ask it (the zone, at the
--- center before, fits them). How many centers are off the map rides along.
--- @return boolean ok, string why, integer wet
local function aimedChainValid(env, seed, from, path)
    local SS = env.BR.StormShape
    local last = #env.BR.Config.Storm.phases
    local wet = 0
    for p = from, last do
        local prev, c = path[p - 1], path[p]
        local fit = SS.fit(hostKsOf(env, seed, p, prev.x, prev.y, prev.r), discsAt(env, seed, p), c.x, c.y, 1.0)
        if fit > -1e-3 then
            return false, ('phase %d is not nested: fit %.6f'):format(p, fit), wet
        end
        if boxedAt(env, seed, p, prev.x, prev.y) and not boxedAt(env, seed, p, c.x, c.y) then
            return false, ('phase %d leaves the map bounds the zone before let it keep'):format(p), wet
        end
        if p < last and env.BR.StormOffMap(c.x, c.y) then wet = wet + 1 end
    end
    if env.BR.StormOffMap(path[last].x, path[last].y) then
        return false, ('the end (%.1f, %.1f) is off the map'):format(path[last].x, path[last].y), wet
    end
    return true, '', wet
end

--- THE ROOM'S SUPPORT, BY BRUTE FORCE: the furthest any center zone `phase` may
--- take inside the zone before (at the origin, radius hr) reaches along (ux, uy)
--- -- golden-section over the bearing a quarter turn either side, bisection out
--- along each bearing, every test the planner's real fit. The room is convex and
--- holds its center, so the reach along u is unimodal in the bearing.
local function roomSupport(env, seed, phase, hr, ux, uy)
    local SS = env.BR.StormShape
    local hks = hostKsOf(env, seed, phase, 0.0, 0.0, hr)
    local D = discsAt(env, seed, phase)
    local far = SS.reachOf(hks, 0.0, 0.0) + 1.0
    local function rho(th)
        local cx, cy = math.cos(th), math.sin(th)
        local lo, hi = 0.0, far
        for _ = 1, 34 do
            local mid = 0.5 * (lo + hi)
            if SS.fit(hks, D, cx * mid, cy * mid, 1.0) <= -1e-3 then lo = mid else hi = mid end
        end
        return lo
    end
    local th0 = math.atan(uy, ux)
    local function f(th) return rho(th) * math.cos(th - th0) end
    local g = (math.sqrt(5.0) - 1.0) * 0.5
    local a, b = th0 - 0.5 * math.pi, th0 + 0.5 * math.pi
    local x1, x2 = b - g * (b - a), a + g * (b - a)
    local f1, f2 = f(x1), f(x2)
    for _ = 1, 44 do
        if f1 < f2 then
            a, x1, f1 = x1, x2, f2
            x2 = a + g * (b - a)
            f2 = f(x2)
        else
            b, x2, f2 = x2, x1, f1
            x1 = b - g * (b - a)
            f1 = f(x1)
        end
    end
    return math.max(f1, f2)
end

--- A server with the surveyed boundary loaded, so "on the map" is the game's.
local function boundedServer()
    local S = newStormServer()
    loadInto(S.env, { 'br_lib/shared/polygon.lua' })
    return S
end

--- A walked match with the surveyed boundary loaded (walkUntil's, otherwise).
local function walkMapped(anchor, stop, stepMs, t0)
    local S = boundedServer()
    local env = S.env
    if t0 then S.now = t0 end
    S.roster[1] = nil
    S.match.storm = nil
    S.match.anchor = { x = anchor.x, y = anchor.y, name = anchor.name or 'Test' }
    env.BR.Sched.setEnabled('storm.phase', true)
    S.match.state = env.BR.MatchState.WARMUP
    env.BR.Storm.drawFirstCircle(S.match)
    S.match.state = env.BR.MatchState.PLAYING
    env.BR.Storm.begin(S.match)
    for _ = 1, 20000 do
        local rec = S.match.storm
        local _, _, _, st = env.BR.StormAt(rec, S.now)
        if stop(rec, st) then break end
        S.now = S.now + (stepMs or 5000)
        env.BR.Sched.step(S.now)
    end
    return S
end

--- How far inside the planner's rules the plan's own room polygons can sit, in
--- meters, from phase `from` on: each phase's chords (storm_solve.lua's AIM_SAG of
--- the zone's radius, never under AIM_SAG_MIN) and its five millimeters of extra
--- clearance, and the slack the plan says it held its end inside the reach by.
local function planSlack(env, from, plan)
    local P = env.BR.Config.Storm.phases
    local s = plan.slack or 0.0
    for p = from, #P do
        s = s + math.max(0.01, 1e-4 * P[p - 1].radius) + 0.005
    end
    return s
end

-- ---------------------------------------------------------------------------
describe('control.plan')
do
    -- ═══ THE PLAN ON ITS OWN (BR.StormAimPlan) ═══
    local S = boundedServer()
    local env = S.env
    local P = env.BR.Config.Storm.phases
    local last = #P
    local SEED = 396
    local cx, cy = 300.0, 1200.0    -- Vinewood Hills: on land, zone 3 boxed
    local k = 3
    local r = P[k].radius
    -- THE NEXT CIRCLE'S OWN CENTER: the storm ends on it, bit for bit.
    local plan = env.BR.StormAimPlan(SEED, k + 1, cx, cy, r, nil, cx, cy)
    ok(plan.ex == cx and plan.ey == cy, 'a spot at the next circle\'s center: the storm ends exactly on it',
        ('(%.6f, %.6f)'):format(plan.ex, plan.ey))
    ok(plan.sx == cx and plan.sy == cy and plan.x == cx and plan.y == cy, 'aimed as picked: it is on land')
    local okc, whyc = aimedChainValid(env, SEED, k + 1, plan.path)
    ok(okc, 'every center the plan places passes the planner\'s tests', whyc)
    eq(plan.path[k].x, cx, 'the chain starts on the circle already on the map')
    ok(plan.path[last].x == plan.ex and plan.path[last].y == plan.ey, 'and its last center is the end')
    -- DETERMINISTIC: the same arguments, the same doubles.
    local again = env.BR.StormAimPlan(SEED, k + 1, cx, cy, r, nil, cx + 300.0, cy - 200.0)
    local twice = env.BR.StormAimPlan(SEED, k + 1, cx, cy, r, nil, cx + 300.0, cy - 200.0)
    local same = again.ex == twice.ex and again.ey == twice.ey
    for p = k + 1, last do
        same = same and again.path[p].x == twice.path[p].x and again.path[p].y == twice.path[p].y
    end
    ok(same, 'the same spot planned twice: the same circles, bit for bit')
    -- FAR OUTSIDE THE NEXT CIRCLE: the storm closes toward it and ends short,
    -- inside the next circle, on land, and nearer the spot than the circle's
    -- own center is.
    local fx, fy = cx + 6.0 * r, cy
    local far = env.BR.StormAimPlan(SEED, k + 1, cx, cy, r, nil, fx, fy)
    local zone = env.BR.StormShape.blob(cx, cy, r, env.BR.StormUnit(SEED, k))
    ok(far.ex ~= far.sx or far.ey ~= far.sy, 'a spot six radii out: the storm cannot get there')
    ok(env.BR.StormShape.distance(zone, far.ex, far.ey) < 0.0, 'and it ends inside the next circle',
        env.BR.StormShape.distance(zone, far.ex, far.ey))
    ok(math.sqrt((far.ex - fx) ^ 2 + (far.ey - fy) ^ 2) < math.sqrt((cx - fx) ^ 2 + (cy - fy) ^ 2) - 0.5 * r,
        'well toward the spot: over half a radius nearer it than the circle\'s center')
    ok(not env.BR.StormOffMap(far.ex, far.ey), 'on land')
    okc, whyc = aimedChainValid(env, SEED, k + 1, far.path)
    ok(okc, 'every center of it passes the planner\'s tests', whyc)
    -- THE WALK CLOSES ON IT: the first circle it draws nearer the spot (as aimed)
    -- than the circle on the map, and the end nearer still.
    local function to(c) return math.sqrt((c.x - far.sx) ^ 2 + (c.y - far.sy) ^ 2) end
    ok(to(far.path[k + 1]) < to(far.path[k]) - 1.0 and to(far.path[last]) < to(far.path[k + 1]),
        'the first circle drawn moves toward the spot, and the storm ends nearer it still')
    -- OVER WATER: aimed as the nearest land to it -- the Alamo Sea's middle, whose
    -- nearest shore is its rectangle's nearest edge.
    local W = env.BR.Config.Map.Water[5]
    local wx, wy = 0.5 * (W.minX + W.maxX), 0.5 * (W.minY + W.maxY) + 200.0
    local wet = env.BR.StormAimPlan(SEED, 2, 1500.0, 3300.0, P[1].radius, nil, wx, wy)
    local shore = math.min(wx - W.minX, W.maxX - wx, wy - W.minY, W.maxY - wy)
    ok(not env.BR.StormOffMap(wet.sx, wet.sy), 'a spot in the Alamo Sea is aimed on land')
    ok(math.abs(math.sqrt((wet.sx - wx) ^ 2 + (wet.sy - wy) ^ 2) - shore) < 0.05,
        'at the nearest shore to it', ('%.3f vs %.3f'):format(math.sqrt((wet.sx - wx) ^ 2 + (wet.sy - wy) ^ 2), shore))
    ok(wet.x == wx and wet.y == wy, 'and the plan keeps the spot as picked')
    ok(not env.BR.StormOffMap(wet.ex, wet.ey), 'the storm ends on land')
    -- OFF THE MAP ENTIRELY: still aimed, at the land nearest it.
    local off = env.BR.StormAimPlan(SEED, 2, 0.0, 0.0, P[1].radius, nil, -9000.0, 12000.0)
    ok(not env.BR.StormOffMap(off.sx, off.sy) and not env.BR.StormOffMap(off.ex, off.ey),
        'a spot off the map entirely: aimed at the nearest land, and ends on land')
    eq(env.BR.NextZoneCenterToward, nil, 'and round 4\'s placement is gone (no BR.NextZoneCenterToward)')
    ok(S.errored() == nil, 'clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('control.reach')
do
    -- ═══ THE END IS THE NEAREST POINT THE RULES CAN REACH -- BY BRUTE FORCE ═══
    --
    -- Over many seeds, every phase from 1 to 7, and spots inside the next circle,
    -- at its edge, outside it, far across the map, in the water and off the map:
    --
    --   * every center the plan places passes the planner's own tests;
    --   * a spot over water or off the map is aimed at the nearest land to it, to
    --     a brute-force walk of every coastline and water edge;
    --   * when the storm ends ON the spot, there is nothing to beat;
    --   * when it ends short, the direction from the end to the spot certifies a
    --     lower bound on how near ANY storm the rules allow could end: every center
    --     a phase may take reaches along it no further than its room's support,
    --     found by brute force with the real fit (roomSupport), and the reach of
    --     the whole chain is the sum. The end must sit within the plan's own
    --     polygons' slack of that bound -- or ON a coastline, where the nearer
    --     points are over water.
    --
    -- Hosts are on land with their zone inside the map bounds, so no bound is cut
    -- by the box (the box is held by the walked matches below and `control.box`).
    local S = boundedServer()
    local env = S.env
    local P = env.BR.Config.Storm.phases
    local last = #P
    local M = env.BR.Config.Map
    local rng = env.BR.Rng(5396)
    local bad, exact, short, coast, worstGap, plans, snapped, widened = {}, 0, 0, 0, 0.0, 0, 0, 0
    local maxMs = 0.0
    -- The nearest land to (x, y) by brute force: every edge of the surveyed
    -- boundary and of every water rectangle walked a quarter meter at a time, each
    -- point tried a few centimeters either way off it.
    local landMemo = {}
    local function bfLand(x, y)
        if not env.BR.StormOffMap(x, y) then return x, y end
        local key = x .. ',' .. y
        if landMemo[key] then return landMemo[key][1], landMemo[key][2] end
        local edges = {}
        local B = M.Boundary
        for i = 1, #B do
            local a, b = B[i], B[(i % #B) + 1]
            edges[#edges + 1] = { a.x, a.y, b.x, b.y }
        end
        for _, w in ipairs(M.Water) do
            edges[#edges + 1] = { w.minX, w.minY, w.maxX, w.minY }
            edges[#edges + 1] = { w.maxX, w.minY, w.maxX, w.maxY }
            edges[#edges + 1] = { w.maxX, w.maxY, w.minX, w.maxY }
            edges[#edges + 1] = { w.minX, w.maxY, w.minX, w.minY }
        end
        local best, bx, by = math.huge, nil, nil
        for _, e in ipairs(edges) do
            local dx, dy = e[3] - e[1], e[4] - e[2]
            local L = math.sqrt(dx * dx + dy * dy)
            local nx, ny = -dy / L, dx / L
            local steps = math.ceil(L / 0.25)
            for i = 0, steps do
                local px, py = e[1] + dx * i / steps, e[2] + dy * i / steps
                local d = math.sqrt((px - x) ^ 2 + (py - y) ^ 2)
                if d < best + 0.05 then
                    for _, o in ipairs({ 0.03, -0.03 }) do
                        local qx, qy = px + nx * o, py + ny * o
                        local dq = math.sqrt((qx - x) ^ 2 + (qy - y) ^ 2)
                        if dq < best and not env.BR.StormOffMap(qx, qy) then best, bx, by = dq, qx, qy end
                    end
                end
            end
        end
        landMemo[key] = { bx, by }
        return bx, by
    end
    --- Is any point within `d` of (x, y) off the map? (Sampled.)
    local function nearCoast(x, y, d)
        for ring = 1, 8 do
            local rr = d * ring / 8.0
            for i = 0, 63 do
                local a = i * math.pi / 32.0
                if env.BR.StormOffMap(x + rr * math.cos(a), y + rr * math.sin(a)) then return true end
            end
        end
        return false
    end
    local SEEDS = { 11, 77, 396, 4242, 90210 }
    for _, seed in ipairs(SEEDS) do
        for k = 1, last - 1 do
            local r = P[k].radius
            local cx, cy
            for _ = 1, 400 do
                cx, cy = -2400.0 + rng:float() * 5600.0, -2800.0 + rng:float() * 9000.0
                if not env.BR.StormOffMap(cx, cy) and boxedAt(env, seed, k, cx, cy) then break end
            end
            if not boxedAt(env, seed, k, cx, cy) then
                -- Circle 1 is wider than much of the map: the zone the walked matches draw.
                cx, cy = 360.0, 1980.0
            end
            local th = rng:float() * 2.0 * math.pi
            local spots = {
                { 'inside', cx + 0.2 * r * math.cos(th), cy + 0.2 * r * math.sin(th) },
                { 'at the edge', cx + 0.95 * r * math.cos(th + 2.0), cy + 0.95 * r * math.sin(th + 2.0) },
                { 'outside', cx + 1.4 * r * math.cos(th + 4.0), cy + 1.4 * r * math.sin(th + 4.0) },
                { 'far across', cx + 3000.0 * math.cos(th + 1.0), cy + 3000.0 * math.sin(th + 1.0) },
                { 'in the water', 950.0, 4100.0 },
                { 'off the map', -6500.0, 2500.0 },
            }
            for _, sp in ipairs(spots) do
                local label, tx, ty = sp[1], sp[2], sp[3]
                local t0 = os.clock()
                local plan = env.BR.StormAimPlan(seed, k + 1, cx, cy, r, nil, tx, ty)
                local ms = (os.clock() - t0) * 1000.0
                if ms > maxMs then maxMs = ms end
                plans = plans + 1
                local tag = ('seed %d phase %d %s'):format(seed, k, label)
                local okc, whyc = aimedChainValid(env, seed, k + 1, plan.path)
                if not okc then bad[#bad + 1] = tag .. ': ' .. whyc end
                if plan.plain then bad[#bad + 1] = tag .. ': the plan failed its own check (the plain walk stood in)' end
                if (plan.slack or 0.0) > 0.02 then widened = widened + 1 end
                if not (plan.path[last].x == plan.ex and plan.path[last].y == plan.ey) then
                    bad[#bad + 1] = tag .. ': the chain does not end where the plan says'
                end
                if env.BR.StormOffMap(tx, ty) then
                    snapped = snapped + 1
                    local lx, ly = bfLand(tx, ty)
                    local d = math.sqrt((plan.sx - lx) ^ 2 + (plan.sy - ly) ^ 2)
                    local mine = math.sqrt((plan.sx - tx) ^ 2 + (plan.sy - ty) ^ 2)
                    local theirs = math.sqrt((lx - tx) ^ 2 + (ly - ty) ^ 2)
                    if mine > theirs + 0.05 or env.BR.StormOffMap(plan.sx, plan.sy) then
                        bad[#bad + 1] = ('%s: aimed %.2f m from the spot, the nearest land is %.2f m (%.2f apart)')
                            :format(tag, mine, theirs, d)
                    end
                elseif plan.sx ~= tx or plan.sy ~= ty then
                    bad[#bad + 1] = tag .. ': a spot on land was not aimed as picked'
                end
                if plan.ex == plan.sx and plan.ey == plan.sy then
                    exact = exact + 1
                else
                    short = short + 1
                    local dx, dy = plan.sx - plan.ex, plan.sy - plan.ey
                    local dist = math.sqrt(dx * dx + dy * dy)
                    local ux, uy = dx / dist, dy / dist
                    local reach = ux * cx + uy * cy
                    for p = k + 1, last do
                        local hr = (p == k + 1) and r or P[p - 1].radius
                        reach = reach + roomSupport(env, seed, p, hr, ux, uy)
                    end
                    local lower = ux * plan.sx + uy * plan.sy - reach
                    local gap = dist - lower
                    if gap > planSlack(env, k + 1, plan) + 0.05 then
                        -- BY A COASTLINE: the nearer ends the bound counts are over
                        -- water, and the end is the nearest on land.
                        if nearCoast(plan.ex, plan.ey, math.min(gap + 1.0, 400.0)) then
                            coast = coast + 1
                        else
                            bad[#bad + 1] = ('%s: ends %.3f m from the spot, %.3f m past the nearest the rules allow')
                                :format(tag, dist, gap)
                        end
                    elseif gap > worstGap then
                        worstGap = gap
                    end
                end
            end
        end
    end
    ok(#bad == 0, ('%d plans: every center passes the planner\'s tests, every spot off the map aimed at the '
        .. 'nearest land, and every end the nearest the rules can reach'):format(plans),
        table.concat(bad, '\n       ', 1, math.min(#bad, 8)))
    ok(exact >= plans // 8 and short >= plans // 4, 'spots both reached and not', exact .. ' / ' .. short)
    ok(snapped >= #SEEDS * (last - 1), 'water and off-map spots among them', snapped)
    ok(widened <= plans // 20, 'the end held further inside the reach only rarely', widened)
    print(('       control.reach: %d plans, %d ended on the spot, %d short (%d on a coastline), '
        .. 'worst gap to the brute-force bound %.3f m, %d with the end held further in, slowest plan %.1f ms')
        :format(plans, exact, short, coast, worstGap, widened, maxMs))
    ok(S.errored() == nil, 'clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('control.first')
do
    -- ═══ EACH CIRCLE AS FAR TOWARD THE SPOT AS THE RULES ALLOW -- BY BRUTE FORCE ═══
    --
    -- The first circle the plan decides is the one every player sees move. A grid
    -- of challengers fills its room (centers that pass the planner's real fit from
    -- the circle on the map), each held to ending where the storm ends -- by a
    -- plan from it to that end, which has to land on it exactly and pass the
    -- planner's tests -- and none of them on the map may be nearer the spot.
    --
    -- THE CASES ARE THE ONES WHERE STRAIGHT AT THE SPOT LOSES IT: spots the storm
    -- can end on, where the furthest the first circle could go straight toward the
    -- spot is nearer it than the plan's -- found by a search over 400 random hosts
    -- and spots. Round 4 refused spots like these ("too close to the edge"); here
    -- the nearer centers are there to try, and every one of them must lose the end.
    -- And ONE THE STORM CANNOT REACH, by the Alamo Sea, whose nearest end on land
    -- is not on the reach's edge -- where a walk toward the end instead of the
    -- spot would put the first circle 57 m further from it (a search over 3,000).
    local S = boundedServer()
    local env = S.env
    local P = env.BR.Config.Storm.phases
    local SS = env.BR.StormShape
    local bad, challengers, cases = {}, 0, 0
    local CASES = {
        { 1096, 2, 43.5, 1570.4, 74.1, 2812.5 },
        { 1105, 3, -333.5, 1780.1, -199.0, 2397.7 },
        { 1189, 3, -1405.0, 1247.1, -1892.0, 1784.4 },
        { 1225, 3, 1465.5, 1582.0, 1211.2, 1005.9 },
        { 1228, 2, 1167.4, 2796.6, 1392.0, 1460.5 },
        { 1321, 3, -885.7, -111.3, -821.9, -746.5 },
        { 7003, 4, 385.4, 3891.4, 1069.8, 3682.7, short = true },
    }
    for _, c in ipairs(CASES) do
        local seed, k, cx, cy, tx, ty = c[1], c[2], c[3], c[4], c[5], c[6]
        local r = P[k].radius
        local plan = env.BR.StormAimPlan(seed, k + 1, cx, cy, r, nil, tx, ty)
        ok((plan.ex == tx and plan.ey == ty) ~= (c.short == true),
            ('seed %d: the storm ends on the spot, or for the Alamo Sea case short of it'):format(seed))
        local mine = plan.path[k + 1]
        local dMine = math.sqrt((mine.x - plan.sx) ^ 2 + (mine.y - plan.sy) ^ 2)
        local hks = hostKsOf(env, seed, k + 1, cx, cy, r)
        local D = discsAt(env, seed, k + 1)
        local far = SS.reachOf(hks, cx, cy)
        ok(boxedAt(env, seed, k, cx, cy) and not env.BR.StormOffMap(cx, cy),
            ('seed %d: the circle on the map is on land and in bounds, so the bounds bind nothing'):format(seed))
        cases = cases + 1
        for i = 0, 35 do
            local a = i * math.pi / 18.0
            for j = 1, 10 do
                local qx, qy = cx + math.cos(a) * far * j / 10.0, cy + math.sin(a) * far * j / 10.0
                if SS.fit(hks, D, qx, qy, 1.0) <= -1e-3 and not env.BR.StormOffMap(qx, qy) then
                    local d = math.sqrt((qx - plan.sx) ^ 2 + (qy - plan.sy) ^ 2)
                    if d < dMine - 0.05 then
                        local from = env.BR.StormAimPlan(seed, k + 2, qx, qy, P[k + 1].radius, nil, plan.ex, plan.ey)
                        local path = from.path
                        path[k] = { x = cx, y = cy, r = r }
                        if from.ex == plan.ex and from.ey == plan.ey and aimedChainValid(env, seed, k + 1, path) then
                            bad[#bad + 1] = ('seed %d phase %d: a center %.2f m nearer the spot still ends there')
                                :format(seed, k + 1, dMine - d)
                        end
                        challengers = challengers + 1
                    end
                end
            end
        end
    end
    ok(#bad == 0, ('%d cases, %d nearer challengers: none of them still ends where the storm does')
        :format(cases, challengers), table.concat(bad, '\n       ', 1, math.min(#bad, 8)))
    ok(challengers >= cases * 3, 'and there were nearer centers to try', challengers)
    ok(S.errored() == nil, 'clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('control.aim')
do
    -- ═══ STORM CONTROL'S SPOT, OVER MANY MATCHES, THROUGH THE REAL PHASE JOB ═══
    --
    -- For each of a spread of matches -- different anchors and seeds, aimed at
    -- every phase from 1 to 7, holding and mid-sweep, with the surveyed boundary
    -- loaded -- spots inside the next circle, at its edge, outside it, far across
    -- the map, in the water and off the map are aimed through BR.Storm.aim (never
    -- refused) and walked through the REAL phase job to the last circle. Each
    -- must: leave the record on the map exactly as it was; draw every later circle
    -- as the plan says, each one passing the planner's tests and published; end
    -- exactly where the plan ends -- on the spot whenever the plan reached it --
    -- on land; and have Storm reveal answer that end from the moment it was aimed.
    local MATCHES = 14
    local POIS = {}
    local first = boundedServer()
    for _, poi in ipairs(first.env.BR.Config.Map.POIs) do POIS[#POIS + 1] = poi end
    local last = #first.env.BR.Config.Storm.phases
    local bad, aimed, onSpot, phasesSeen, wet, boxedFrom = {}, 0, 0, 0, 0, 0
    for i = 1, MATCHES do
        local poi = POIS[(i * 7) % #POIS + 1]
        local anchor = { x = poi.x, y = poi.y, name = poi.name }
        local t0 = 1000000 + i * 104729
        local phase = 1 + (i % (last - 1))
        local sweep = (i % 2) == 0 and phase > 1
        local stop = function(rec, st)
            return rec.phase == phase and st == (sweep and 'shrinking' or 'holding')
        end
        local probe = walkMapped(anchor, stop, 5000, t0)
        local rec0 = probe.match.storm
        local rng = probe.env.BR.Rng(396 + i)
        local th = rng:float() * 2.0 * math.pi
        local across = POIS[(i * 31) % #POIS + 1]
        local spots = {
            { x = rec0.cx1, y = rec0.cy1 },
            { x = rec0.cx1 + math.cos(th) * rec0.r1 * 0.5, y = rec0.cy1 + math.sin(th) * rec0.r1 * 0.5 },
            { x = rec0.cx1 + math.cos(th + 2.1) * rec0.r1, y = rec0.cy1 + math.sin(th + 2.1) * rec0.r1 },
            { x = rec0.cx1 + math.cos(th + 4.2) * rec0.r1 * 1.6, y = rec0.cy1 + math.sin(th + 4.2) * rec0.r1 * 1.6 },
            { x = across.x, y = across.y },
            (i % 2 == 0) and { x = 950.0, y = 4100.0 } or { x = -6500.0, y = rec0.cy1 },
        }
        for k, spot in ipairs(spots) do
            local S = walkMapped(anchor, stop, 5000, t0)
            local senv = S.env
            local rec = S.match.storm
            local snap = {}
            for kk, v in pairs(rec) do snap[kk] = v end
            local stream = { table.unpack(S.match.stormRng.s) }
            local sends = #S.sent
            local plan, why = senv.BR.Storm.aimCheck(S.match, spot.x, spot.y)
            local s2 = S.match.stormRng.s
            if not (s2[1] == stream[1] and s2[2] == stream[2] and s2[3] == stream[3] and s2[4] == stream[4])
                or S.match.stormAim ~= nil then
                bad[#bad + 1] = ('match %d spot %d: the check moved the stream or aimed the match'):format(i, k)
            end
            if not plan then
                bad[#bad + 1] = ('match %d spot %d: refused %s'):format(i, k, tostring(why))
            else
                local got = senv.BR.Storm.aim(S.match, spot.x, spot.y)
                aimed = aimed + 1
                if got and got.plain then
                    bad[#bad + 1] = ('match %d spot %d: the plan failed its own check'):format(i, k)
                end
                if got and got.ex == got.sx and got.ey == got.sy then onSpot = onSpot + 1 end
                local f = senv.BR.Storm.finalCentre(S.match)
                if not (got and f and f.x == got.ex and f.y == got.ey) then
                    bad[#bad + 1] = ('match %d spot %d: Storm reveal does not answer the end'):format(i, k)
                end
                if not boxedAt(senv, rec.seed, rec.phase, rec.cx1, rec.cy1) then boxedFrom = boxedFrom + 1 end
                -- THE RECORD ON THE MAP DID NOT MOVE, AND NOTHING WAS SENT FOR IT.
                local still = S.match.storm == rec and #S.sent == sends
                for kk, v in pairs(snap) do if rec[kk] ~= v then still = false end end
                if not still then bad[#bad + 1] = ('match %d spot %d: the record on the map changed'):format(i, k) end
                -- TO THE END, through the real phase job.
                local prev = { phase = rec.phase, cx1 = rec.cx1, cy1 = rec.cy1, r1 = rec.r1 }
                local seen = { [rec.phase] = true }
                walkOn(S, function(r)
                    if not seen[r.phase] then
                        seen[r.phase] = true
                        phasesSeen = phasesSeen + 1
                        if r.phase == prev.phase + 1
                            and not (r.cx0 == prev.cx1 and r.cy0 == prev.cy1 and r.r0 == prev.r1) then
                            bad[#bad + 1] = ('match %d spot %d: phase %d did not start on the circle drawn before it')
                                :format(i, k, r.phase)
                        end
                        local want = got.path[r.phase]
                        if not (want and r.cx1 == want.x and r.cy1 == want.y) then
                            bad[#bad + 1] = ('match %d spot %d: phase %d is not the plan\'s circle'):format(i, k, r.phase)
                        end
                        if not nestedIn(senv, r.seed, r.phase, r.cx0, r.cy0, r.r0, r.cx1, r.cy1, r.r1) then
                            bad[#bad + 1] = ('match %d spot %d: phase %d is not nested'):format(i, k, r.phase)
                        end
                        if boxedAt(senv, r.seed, r.phase, r.cx0, r.cy0)
                            and not boxedAt(senv, r.seed, r.phase, r.cx1, r.cy1) then
                            bad[#bad + 1] = ('match %d spot %d: phase %d left the map bounds'):format(i, k, r.phase)
                        end
                        if r.phase < last and senv.BR.StormOffMap(r.cx1, r.cy1) then wet = wet + 1 end
                        if S.lastSent(senv.BR.Net.STORM_SYNC) ~= r then
                            bad[#bad + 1] = ('match %d spot %d: phase %d was not published'):format(i, k, r.phase)
                        end
                        prev = { phase = r.phase, cx1 = r.cx1, cy1 = r.cy1, r1 = r.r1 }
                    end
                    return r.phase == last
                end, 30000)
                local fin = S.match.storm
                if not (fin.phase == last and fin.cx1 == got.ex and fin.cy1 == got.ey) then
                    bad[#bad + 1] = ('match %d spot %d: ended at (%.3f, %.3f), the plan (%.3f, %.3f)')
                        :format(i, k, fin.cx1, fin.cy1, got.ex, got.ey)
                end
                if senv.BR.StormOffMap(fin.cx1, fin.cy1) then
                    bad[#bad + 1] = ('match %d spot %d: the storm ended off the map'):format(i, k)
                end
                if k == 1 and not (fin.cx1 == spot.x and fin.cy1 == spot.y) then
                    bad[#bad + 1] = ('match %d: the next circle\'s own center was not ended on'):format(i)
                end
            end
            if S.errored() then bad[#bad + 1] = S.errored() end
        end
    end
    ok(#bad == 0, ('%d aimed matches: never refused, the map stands still, every later circle the plan\'s, '
        .. 'nested, in bounds and published, and the storm ends where the plan ends, on land'):format(aimed),
        table.concat(bad, '\n       ', 1, math.min(#bad, 8)))
    ok(aimed == MATCHES * 6, 'every spot aimed', aimed)
    ok(onSpot >= MATCHES * 2 and onSpot < aimed, 'many ended exactly on the spot, and some could not', onSpot)
    ok(phasesSeen >= aimed, 'phases were really walked after the aim', phasesSeen)
    ok(wet <= phasesSeen // 20, 'a center between over water only rarely', wet .. ' of ' .. phasesSeen)
    print(('       control.aim: %d spots aimed, %d ended on the spot, %d centers between over water, '
        .. '%d aimed from a circle that overhangs the bounds'):format(aimed, onSpot, wet, boxedFrom))
end

-- ---------------------------------------------------------------------------
describe('control.box')
do
    -- ═══ THE MAP BOUNDS, FROM A CIRCLE THAT OVERHANGS THEM ═══
    --
    -- Circle 1 overhangs the map bounds in about half of all matches, and from it
    -- the planner keeps every later zone inside them wherever the zone before, at
    -- its own center, would fit. Aimed from such circles toward every side, every
    -- chain still does, and still ends where its plan says.
    local S = boundedServer()
    local env = S.env
    local P = env.BR.Config.Storm.phases
    local bad, n, overhung = {}, 0, 0
    local HOSTS = { { -1900.0, 2900.0 }, { 3300.0, 4500.0 }, { -700.0, 6600.0 }, { 2300.0, -2200.0 } }
    for _, seed in ipairs({ 77, 123457, 31337 }) do
        for _, h in ipairs(HOSTS) do
            if not boxedAt(env, seed, 1, h[1], h[2]) then overhung = overhung + 1 end
            for j = 0, 5 do
                local a = j * math.pi / 3.0
                local tx, ty = h[1] + 3000.0 * math.cos(a), h[2] + 3000.0 * math.sin(a)
                local plan = env.BR.StormAimPlan(seed, 2, h[1], h[2], P[1].radius, nil, tx, ty)
                local okc, whyc = aimedChainValid(env, seed, 2, plan.path)
                if not okc then
                    bad[#bad + 1] = ('seed %d host (%.0f, %.0f) bearing %d: %s'):format(seed, h[1], h[2], j, whyc)
                end
                -- AND BY ITS OWN WALK: not the plain walk standing in for a plan
                -- that broke the bounds.
                if plan.plain then
                    bad[#bad + 1] = ('seed %d host (%.0f, %.0f) bearing %d: the plan failed its own check')
                        :format(seed, h[1], h[2], j)
                end
                n = n + 1
            end
        end
    end
    ok(#bad == 0, ('%d plans from circle 1: every zone in bounds wherever the planner would ask it'):format(n),
        table.concat(bad, '\n       ', 1, math.min(#bad, 8)))
    ok(overhung >= 6, 'from circles that overhang the bounds', overhung)
end

-- ---------------------------------------------------------------------------
describe('control.land')
do
    -- ═══ A CIRCLE BETWEEN STAYS ON LAND WHEN ITS ROOM HAS LAND IN IT ═══
    --
    -- Walks past the Alamo Sea and the coast where the nearest center to the spot
    -- is over water but a center on land still ends the storm where it ends (a
    -- search over 3,000 hosts and spots): every center between stays on the map.
    local S = boundedServer()
    local env = S.env
    local P = env.BR.Config.Storm.phases
    local last = #P
    local CASES = {
        { 5190, 1, 535.7, 4786.1, 906.9, 3290.5 },
        { 5205, 1, 551.1, 5260.9, -344.8, 8560.7 },
        { 5275, 1, 2532.1, 3335.0, 3725.0, 5838.1 },
        { 5300, 1, 2554.8, 3207.8, 6906.7, 5853.9 },
    }
    for _, c in ipairs(CASES) do
        local seed, k = c[1], c[2]
        local plan = env.BR.StormAimPlan(seed, k + 1, c[3], c[4], P[k].radius, nil, c[5], c[6])
        local okc, whyc, wet = aimedChainValid(env, seed, k + 1, plan.path)
        ok(okc and not plan.plain, ('seed %d: every center passes the planner\'s tests'):format(seed), whyc)
        eq(wet, 0, ('seed %d: no center between over water'):format(seed))
    end
end

-- ---------------------------------------------------------------------------
describe('control.refuse')
do
    -- ═══ ONLY WHAT CANNOT BE DONE AT ALL IS REFUSED ═══
    local ANCHOR = { x = 150.0, y = -900.0, name = 'Test' }
    local S = walkMapped(ANCHOR, function(rec, st) return rec.phase == 3 and st == 'holding' end)
    local env = S.env
    local rec = S.match.storm
    -- OUTSIDE THE NEXT CIRCLE, OVER WATER, OFF THE MAP: all planned, none refused.
    local W = env.BR.Config.Map.Water[1]
    for _, c in ipairs({
        { 'outside the next circle', rec.cx1 + 2.5 * rec.r1, rec.cy1 },
        { 'over water', 0.5 * (W.minX + W.maxX), 0.5 * (W.minY + W.maxY) },
        { 'off the map entirely', 9000.0, -9000.0 },
        { 'near the next circle\'s edge', rec.cx1 + 0.99 * rec.r1, rec.cy1 },
    }) do
        local plan, why = env.BR.Storm.aimCheck(S.match, c[2], c[3])
        ok(plan ~= nil and why == nil, ('a spot %s: planned, not refused'):format(c[1]), why)
        ok(plan and not env.BR.StormOffMap(plan.ex, plan.ey), ('a spot %s: the storm ends on land'):format(c[1]))
    end
    ok(S.match.stormAim == nil, 'and none of the checks aimed the match')
    eq(select(2, env.BR.Storm.aimCheck(S.match, 0 / 0, 0.0)), 'bad_option', 'not a number: bad_option')
    eq(select(2, env.BR.Storm.aimCheck(S.match, math.huge, 0.0)), 'bad_option', 'not finite: bad_option')
    -- NOTHING LEFT TO DRAW, OR NOTHING DRAWN YET.
    local F = newStormServer()
    local fenv = F.env
    local last = #fenv.BR.Config.Storm.phases
    F.match.stormRng = fenv.BR.Rng(7)
    F.record(last, 0.0, 0.0, 40.0, 5.0, 0.0, 0.0, 30000, 60000, 6.7)
    eq(select(2, fenv.BR.Storm.aimCheck(F.match, 5.0, 0.0)), 'no_circle', 'the final circle on the map: no_circle')
    F.match.storm = nil
    eq(select(2, fenv.BR.Storm.aimCheck(F.match, 5.0, 0.0)), 'no_storm', 'no storm record: no_storm')
    eq(fenv.BR.Storm.futures, nil, 'and the three possible ends are gone (no BR.Storm.futures)')
    eq(fenv.BR.Storm.steer, nil, '(nor BR.Storm.steer)')
end

-- ---------------------------------------------------------------------------
describe('control.once')
do
    -- ═══ ONE SPOT A MATCH (round 4's review) ═══
    --
    -- The first aim holds for the rest of the match: a second one is refused
    -- (`storm_aimed`) at every phase after it, a spot it would have taken
    -- included, and the storm ends on the first spot.
    local ANCHOR = { x = 150.0, y = -900.0, name = 'Test' }
    local S = walkUntil(ANCHOR, function(rec, st) return rec.phase == 2 and st == 'holding' end)
    local env = S.env
    local rec = S.match.storm
    eq(env.BR.Storm.aimed(S.match), false, 'not aimed yet')
    local a = env.BR.Storm.aim(S.match, rec.cx1, rec.cy1)
    ok(a ~= nil, 'aimed at the next circle\'s center')
    eq(env.BR.Storm.aimed(S.match), true, 'aimed')
    local spot, why = env.BR.Storm.aimCheck(S.match, rec.cx1, rec.cy1)
    ok(spot == nil and why == 'storm_aimed', 'the same spot again: storm_aimed', why)
    walkOn(S, function(r) return r.phase == 5 end, 30000)
    local r5 = S.match.storm
    local b, whyB = env.BR.Storm.aim(S.match, r5.cx1 + r5.r1 * 3.0, r5.cy1)
    ok(b == nil and whyB == 'storm_aimed', 'a second aim at phase 5, far outside its next circle: storm_aimed', whyB)
    ok(S.match.stormAim == a, 'the first plan is still the match\'s')
    walkOn(S, function(r) return r.phase == #env.BR.Config.Storm.phases end, 30000)
    local fin = S.match.storm
    ok(fin.cx1 == a.x and fin.cy1 == a.y, 'and the storm ends on the first spot',
        ('(%.2f, %.2f) vs (%.2f, %.2f)'):format(fin.cx1, fin.cy1, a.x, a.y))
    ok(S.errored() == nil, 'clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('control.replan')
do
    -- ═══ A DEV PATH OFF THE AIMED WALK PLANS AGAIN ═══
    --
    -- `brphase` re-entering the phase the storm is in, mid-sweep, starts it from
    -- the wall where it stands -- not the circle the plan started from -- so the
    -- plan is made again from there, toward the same spot: every circle after it
    -- nested, and Storm reveal answering where the new walk ends.
    local ANCHOR = { x = 150.0, y = -900.0, name = 'Test' }
    local S = walkUntil(ANCHOR, function(rec, st) return rec.phase == 3 and st == 'shrinking' end)
    local env = S.env
    local rec = S.match.storm
    local a = env.BR.Storm.aim(S.match, rec.cx1 + 0.4 * rec.r1, rec.cy1)
    ok(a ~= nil, 'aimed at phase 3')
    S.now = S.now + 2000
    S.cmds.brphase(nil, { '3' })
    local re = S.match.storm
    ok(re.phase == 3 and re.mo ~= nil, 're-entered phase 3 from the wall mid-morph')
    local f = env.BR.Storm.finalCentre(S.match)
    local seen, nested, last = {}, true, #env.BR.Config.Storm.phases
    walkOn(S, function(r)
        if not seen[r.phase] then
            seen[r.phase] = true
            if r.phase > 3 and not nestedIn(env, r.seed, r.phase, r.cx0, r.cy0, r.r0, r.cx1, r.cy1, r.r1) then
                nested = false
            end
        end
        return r.phase == last
    end, 30000)
    ok(nested, 'every circle after it nested in the one before')
    local fin = S.match.storm
    ok(f and fin.cx1 == f.x and fin.cy1 == f.y, 'and Storm reveal, asked after the re-entry, answered the end',
        f and ('(%.2f, %.2f) vs (%.2f, %.2f)'):format(fin.cx1, fin.cy1, f.x, f.y))
    ok(S.errored() == nil, 'clean', S.errored())
end

-- ---------------------------------------------------------------------------
describe('view.inside')
do
    -- ═══ WHERE THE VIEW STANDS, AS THE STORM'S OWN TICK MEASURED IT (#396) ═══
    --
    -- Time & weather claims its weather only inside the circle, and reads that
    -- off the storm's tick rather than measuring again: the same viewpoint (the
    -- shot, for a spectator), the same zone the wall draws and the sky reads.
    local C = newStormClient()
    local env = C.env
    C.record(3, 0.0, 0.0, 950.0, 0.0, 0.0, 520.0, 600000, 60000, 1.7)
    C.pedAt = pt(0.0, 0.0)
    C.tick(1)
    eq(env.BR.Storm.viewInside(), true, 'standing in the middle: inside')
    local p = env.BR.Storm.viewpoint()
    ok(p and p.x == 0.0 and p.y == 0.0, 'and the viewpoint is this ped')
    C.pedAt = pt(5000.0, 0.0)
    C.tick(1)
    eq(env.BR.Storm.viewInside(), false, 'five kilometers out: not inside')
    C.pedAt = pt(0.0, 0.0)
    C.tick(1)
    eq(env.BR.Storm.viewInside(), true, 'back in the middle: inside again')
    -- AND THE LINE IS THE WALL ITSELF (the wave B review): three meters either
    -- side of it along the boundary's own normal, at two places round it. An
    -- answer with any slack in it -- inside up to fifty meters out, say -- would
    -- claim the chosen weather over a player the storm has caught.
    local zone = zoneOf(env, env.BR.State.storm)
    for _, at in ipairs({ 0.25, 0.7 }) do
        local ox, oy = offBoundary(env, zone, zone.P * at, 3.0)
        C.pedAt = pt(ox, oy)
        C.tick(1)
        eq(env.BR.Storm.viewInside(), false, ('three meters outside the wall (%.2f round): not inside'):format(at))
        local ix, iy = offBoundary(env, zone, zone.P * at, -3.0)
        C.pedAt = pt(ix, iy)
        C.tick(1)
        eq(env.BR.Storm.viewInside(), true, ('three meters inside it (%.2f round): inside'):format(at))
    end
    env.BR.State.match.state = env.BR.MatchState.WAITING
    C.tick(1)
    eq(env.BR.Storm.viewInside(), false, 'and with no storm to stand in, never inside')
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
    e.lastStormAt = nil
    local sends = #S.out
    S.tick(); S.tick(); S.tick()

    ok(e.lastStormAt == nil and e.hp == 100.0,
        'and standing 10km from it costs nothing', tostring(e.hp))
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
    -- the rule: circle 1's wall extends through phase 1 of PLAYING, beside the opening
    -- wall since #344, and `preview.twowalls` walks that whole stretch. What survives, and matters, is
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
describe('preview.twowalls')
do
    -- ═══ FROM THE BUS TO THE END OF PHASE 1, TWO WALLS AND NO GAP (#340, #344) ═══
    --
    --   "The storm circle should draw the entire time from while in bus to when it
    --    moves. Make sure it fades in just like before."  -- the owner, 2026-09-22, #340
    --   "phase 1 preview only draws until the storm starts moving, then the border
    --    resets from the outside of the map and works in. not sure this is how we
    --    should do it, but perhaps we should draw 2 walls like we do with every other
    --    phase."                                          -- the owner, 2026-09-23, #344
    --
    -- #340 closed a gap with a HANDOFF: circle 1's wall stood in for the suppressed
    -- opening wall through the hold and faded out as it faded in over the hold's last
    -- seconds -- and then the sweep brought that opening ring in from the map's edge,
    -- which is the reset #344 reports. So phase 1 draws BOTH now: the opening zone's
    -- wall from the start of the hold, ramping in over its first fadeInSec, and circle
    -- 1's wall beside it through the hold and the sweep, thinning over the sweep's last
    -- fadeInSec as the moving wall lands on it.
    --
    -- ═══ WHY THIS BLOCK WALKS A TIMELINE INSTEAD OF ASSERTING TWO STATES ═══
    --
    -- BECAUSE BOTH ENDS WERE ALREADY GREEN WHILE #340 SHIPPED. The hole was the two
    -- minutes between two true statements, so the clock is driven from the bus,
    -- through the PLAYING transition, down the whole hold, across the start of the
    -- sweep and to its end, and at EVERY step something is on screen and neither wall
    -- moves further than its own clock can carry it.
    --
    -- ═══ THE TWO WALLS ARE MEASURED ONE AT A TIME ═══
    --
    -- Each step is drawn twice at the same moment, once with each wall's callback
    -- switched off through BR.Loop.setEnabled -- the production switch -- because at
    -- the end of the sweep they stand on the SAME boundary, where no classification
    -- by shape can tell them apart and a classification by alpha would be circular.
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

    -- CIRCLE 1'S SHAPE, which the preview draws: zone 1 at seed 0 -- the published
    -- field carries no seed and the record below is built by hand with
    -- BR.BuildStormRecord's own default, the agreement the game has between the
    -- preview payload and the record.
    local PSS = proto.env.BR.StormShape
    local PREVIEW_SHAPE = PSS.inset(PSS.blob(CCX, CCY, CR, proto.env.BR.StormUnit(nil, 1)),
        INSET)

    --- One wall's triangles in the last frame: how many, at what alpha, whether they
    --- agree about it, and the furthest any corner stands off `shape`.
    local function wall(C, shape)
        local w = { n = 0, alpha = 0, mixed = nil, off = 0.0 }
        for _, t in ipairs(C.polys) do
            if w.n == 0 then w.alpha = t.a
            elseif w.alpha ~= t.a then
                w.mixed = w.mixed or ('%d and %d'):format(w.alpha, t.a)
            end
            w.n = w.n + 1
            if shape then
                w.off = math.max(w.off, math.abs(PSS.distance(shape, t[1].x, t[1].y)))
            end
        end
        return w
    end

    --- Put the phase-1 record `ms` from the end of its hold -- negative is that far
    --- into the sweep -- and draw each wall alone, at the same moment.
    ---
    --- THE 16 ms C.frame ADVANCES THE CLOCK BY IS ADDED IN HERE, so `ms` is what the
    --- renderer actually solves rather than what it would have solved a frame ago.
    --- @return table preview, table real  each from wall()
    local function both(C, ms)
        local L = C.env.BR.Loop
        local rec = C.env.BR.State.storm
        local function place() rec.tStart = (C.now + 16) - (WAIT - ms) end
        L.setEnabled('storm.wall', false)
        place()
        C.frame()
        local pv = wall(C, PREVIEW_SHAPE)
        L.setEnabled('storm.wall', true)
        L.setEnabled('storm.previewWall', false)
        place()
        C.frame()
        local cx, cy, r, _, _, _, t, g = C.env.BR.StormAt(rec, C.env.BR.Clock.now())
        local rw = wall(C, PSS.inset(C.env.BR.StormZone(rec, cx, cy, r, t, g), INSET))
        L.setEnabled('storm.previewWall', true)
        return pv, rw
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
        -- walls and not mainlandLoaded.
        C.fire('br:env:world', false)
        C.pedAt = pt(0.0, 0.0, 30.0)
        -- AND #351'S ENTRY RAMP IS ALREADY SPENT BEFORE THE WALK STARTS: it is a
        -- different ramp on a different anchor, over long before anything below.
        C.settlePreview()
        return C
    end

    --- The PLAYING transition, spelled the way client/state.lua's STORM_SYNC handler
    --- spells it: the record arrives AND the preview field is dropped, which is what
    --- makes the PLAYING preview read the record instead.
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
    local bp = wall(C, PREVIEW_SHAPE)
    ok(bp.n > 0 and bp.alpha == PREV and bp.off < 1e-6,
        'on the bus the preview wall stands on circle 1 at previewAlpha',
        ('preview %d tris at %d, %.3e m off circle 1'):format(bp.n, bp.alpha, bp.off))

    -- ─── the transition itself, which is where the wall used to vanish ───
    goPlaying(C)
    local tp, tr = both(C, WAIT)
    ok(tp.n == bp.n and tp.alpha == bp.alpha and tp.off < 1e-6 and tp.mixed == nil,
        'and the frame after the match goes PLAYING draws the SAME circle-1 wall at '
            .. 'the SAME alpha from the record\'s own target -- the defect was this '
            .. 'frame drawing nothing, and an equal-but-different circle would be a pop',
        ('%d tris at %d against the bus\'s %d at %d'):format(
            tp.n, tp.alpha, bp.n, bp.alpha))
    ok(C.env.BR.State.stormPreview == nil and tp.n > 0,
        'with BR.State.stormPreview already dropped, so the PLAYING preview is reading '
            .. 'rec.cx1/cy1/r1 -- which IS circle 1, because enterPhase spends the '
            .. 'warmup draw rather than rolling a second one')
    ok(tr.alpha < math.ceil(FULL * 32 / FADE) + 1,
        'while the OPENING wall is only starting to arrive: it ramps in from the '
            .. 'start of the hold rather than popping onto the horizon (#344)',
        ('%d tris at %d'):format(tr.n, tr.alpha))

    -- ─── the whole of phase 1, step by step, with nothing allowed to be empty ───
    --
    -- FINE ACROSS THE THREE WINDOWS THAT MOVE -- the hold's first fadeInSec, where the
    -- opening wall ramps in; the sweep's first seconds, where nothing may reset; the
    -- sweep's last fadeInSec, where circle 1's wall thins onto the arriving one -- and
    -- coarse across the long stretches between, which ask only that something is on
    -- screen.
    local steps = {}
    for ms = WAIT, WAIT - FADE, -250 do steps[#steps + 1] = ms end
    for ms = WAIT - FADE - 2000, 2000, -2000 do steps[#steps + 1] = ms end
    for ms = 1000, -3000, -250 do steps[#steps + 1] = ms end
    for ms = -5000, -(SHRINK - FADE), -2000 do steps[#steps + 1] = ms end
    for ms = -(SHRINK - FADE), -SHRINK + 250, -250 do steps[#steps + 1] = ms end

    local W = busClient()
    goPlaying(W)
    local empty, offAt, mixedAt, jumped = nil, nil, nil, nil
    local rampBad, prevBad, thinBad, fullBad = nil, nil, nil, nil
    local ramped, thinned = 0, 0
    local lastP, lastR = PREV, 0
    for i, ms in ipairs(steps) do
        local pv, rw = both(W, ms)
        local gap = (i > 1) and (steps[i - 1] - ms) or 0
        -- THE MOST EITHER ALPHA MAY MOVE IN ONE STEP is what its clock can carry over
        -- that step plus a level for the rounding, so a genuine pop fails while the
        -- intended ramps pass. Priced off the step, not guessed.
        local room = math.ceil(FULL * gap / FADE) + 1
        if pv.n == 0 and rw.n == 0 then
            empty = empty or ('%d ms from the hold\'s end, nothing is drawn'):format(ms)
        end
        if pv.off > 1e-6 or rw.off > 1e-6 then
            offAt = offAt or ('at %d ms a wall is %.3e m off its shape'):format(
                ms, math.max(pv.off, rw.off))
        end
        if pv.mixed or rw.mixed then
            mixedAt = mixedAt or ('at %d ms one wall reads %s'):format(ms,
                pv.mixed or rw.mixed)
        end
        if math.abs(pv.alpha - lastP) > room or math.abs(rw.alpha - lastR) > room then
            jumped = jumped or ('at %d ms preview %d->%d, real %d->%d, room %d')
                :format(ms, lastP, pv.alpha, lastR, rw.alpha, room)
        end
        -- THE OPENING WALL: the hold's first fadeInSec is a ramp on the record's own
        -- clock, to the rounding, and it is full strength from then until the end.
        local held = WAIT - ms
        if held < FADE then
            ramped = ramped + 1
            local want = rr.alpha * held / FADE
            if math.abs(rw.alpha - want) > 1.0 then
                rampBad = rampBad or ('%d ms into the hold at %d, wanted %.1f')
                    :format(held, rw.alpha, want)
            end
        elseif rw.alpha ~= FULL then
            fullBad = fullBad or ('%d ms from the hold\'s end the opening wall is at %d')
                :format(ms, rw.alpha)
        end
        -- CIRCLE 1'S WALL: previewAlpha through the hold and the sweep, until the
        -- sweep's last fadeInSec, and then thinning on that same clock.
        local left = SHRINK + ms
        if left >= FADE then
            if pv.alpha ~= PREV or pv.n == 0 then
                prevBad = prevBad or ('%d ms from the hold\'s end circle 1 is %d tris at %d')
                    :format(ms, pv.n, pv.alpha)
            end
        else
            thinned = thinned + 1
            local want = rr.alpha * (rr.previewAlpha or 0.5) * left / FADE
            if math.abs(pv.alpha - want) > 1.0 then
                thinBad = thinBad or ('%d ms before the sweep ends circle 1 is at %d, '
                    .. 'wanted %.1f'):format(left, pv.alpha, want)
            end
        end
        lastP, lastR = pv.alpha, rw.alpha
    end

    ok(empty == nil and #steps > 100,
        'across the whole of phase 1 -- the transition, the hold, the sweep -- there is '
            .. 'a wall on screen at every single step, which is the gap #340 reported',
        empty or ('%d steps, none empty'):format(#steps))
    ok(offAt == nil and mixedAt == nil,
        'every corner of both walls stands on the shape that wall draws, and each '
            .. 'wall\'s alpha is uniform round its own ring at every step',
        offAt or mixedAt)
    ok(rampBad == nil and fullBad == nil and ramped > 30,
        'the opening wall rises over the hold\'s FIRST fadeInSec, on the record\'s own '
            .. 'clock, and is at full render.alpha from then to the end of the sweep',
        rampBad or fullBad)
    ok(prevBad == nil,
        'circle 1\'s wall stays at previewAlpha through the whole hold AND the sweep '
            .. '-- it stands beside the opening wall now, not in for it (#344)',
        prevBad)
    ok(thinBad == nil and thinned > 30,
        'and thins over the sweep\'s last fadeInSec, on the sweep\'s own clock, as the '
            .. 'moving wall arrives on it',
        thinBad)
    ok(jumped == nil,
        'and neither wall moves further in a step than its clock can carry it -- a '
            .. 'wall that cut in or out, anywhere in phase 1, fails here',
        jumped)

    -- ─── NOTHING RESETS WHEN THE SWEEP STARTS, which is the whole of #344's ask ───
    --
    -- One frame before the sweep and one frame into it: circle 1's wall is the same
    -- triangles to the bit, and the opening wall's corners have moved no further than
    -- the fastest corner of the morph can carry them in the time between -- rather
    -- than jumping from circle 1 out to the map's edge, which is what the owner saw.
    local R = busClient()
    goPlaying(R)
    local rrec = R.env.BR.State.storm
    local function corners()
        local pts = {}
        for _, q in ipairs(quadsOf(R)) do pts[#pts + 1] = { x = q.a.x, y = q.a.y } end
        return pts
    end
    --- One wall alone at `ms` from the hold's end, and the inset zone at that moment.
    local function eachAt(ms, off)
        local L = R.env.BR.Loop
        L.setEnabled(off, false)
        rrec.tStart = (R.now + 16) - (WAIT - ms)
        R.frame()
        L.setEnabled(off, true)
        local cx, cy, r, _, _, _, t, g = R.env.BR.StormAt(rrec, R.env.BR.Clock.now())
        return corners(), PSS.inset(R.env.BR.StormZone(rrec, cx, cy, r, t, g), INSET)
    end
    local preBefore = eachAt(16, 'storm.wall')
    local realBefore, shapeBefore = eachAt(16, 'storm.previewWall')
    local preAfter = eachAt(-16, 'storm.wall')
    local realAfter, shapeAfter = eachAt(-16, 'storm.previewWall')
    local same = #preBefore == #preAfter and #preBefore > 0
    for i = 1, #preBefore do
        if not preAfter[i] or preAfter[i].x ~= preBefore[i].x
                or preAfter[i].y ~= preBefore[i].y then
            same = false
        end
    end
    -- HOW FAR THE BOUNDARY MOVED, both ways: every corner of each frame against the
    -- other frame's shape. Corners are resampled along a boundary as it changes, so
    -- they are not the same POINTS twice -- the boundary is what must not have jumped.
    local moved = 0.0
    for _, p in ipairs(realAfter) do
        moved = math.max(moved, math.abs(PSS.distance(shapeBefore, p.x, p.y)))
    end
    for _, p in ipairs(realBefore) do
        moved = math.max(moved, math.abs(PSS.distance(shapeAfter, p.x, p.y)))
    end
    -- THE BOUND IS THE MORPH'S OWN: its fastest disc, times the 32 ms between the two.
    local bound = R.env.BR.StormWallSpeed(rrec) * 0.032 + 1e-6
    ok(same,
        'across the first frame of the sweep circle 1\'s wall is the same triangles to '
            .. 'the bit -- it does not move, fade or reset',
        ('%d corners before, %d after'):format(#preBefore, #preAfter))
    ok(#realBefore > 0 and #realAfter > 0 and moved <= bound,
        'and the opening wall carries on from exactly where it stood, moving no further '
            .. 'than the morph\'s fastest corner can in that time -- no reset to the '
            .. 'map\'s edge and back',
        ('%.4f m against %.4f m'):format(moved, bound))

    -- ─── and at FINISHED the two are one ───
    --
    -- The moving wall has arrived on circle 1, at full strength and on circle 1's own
    -- shape, and circle 1's wall is gone: one wall on one boundary, which is what the
    -- next phase starts from.
    local fp, fr = both(W, -SHRINK - 1000)
    ok(fp.n == 0 and fr.n > 0 and fr.alpha == FULL and wall(W, PREVIEW_SHAPE).off < 1e-6,
        'when the sweep finishes circle 1\'s wall is gone and the moving wall stands on '
            .. 'circle 1 at full strength, in circle 1\'s shape',
        ('preview %d tris, real %d tris at %d, %.3e m off circle 1'):format(
            fp.n, fr.n, fr.alpha, wall(W, PREVIEW_SHAPE).off))

    -- ─── the two gates that exist for real reasons, both still shut ───
    --
    -- A LOBBY BYSTANDER SHARES THE MATCH STATE WITHOUT BEING IN THE MATCH, and used to
    -- get storm blips at the vista menu.
    local L = busClient()
    goPlaying(L)
    L.env.BR.State.me.state = PS.LOBBY
    local lp, lr = both(L, WAIT * 0.5)
    ok(lp.n == 0 and lr.n == 0,
        'a LOBBY bystander gets neither wall through the PLAYING hold, which is the '
            .. 'vista-menu report the gate was written for',
        ('%d preview, %d real'):format(lp.n, lr.n))

    -- AND THE PREVIEW DOES NOT SURVIVE A MATCH ENDING. activeRecord admits ENDED on
    -- purpose -- the grade, the rain and the zone's own wall outlive the transition, as
    -- they do in every phase -- so a preview that reused activeRecord would stand a
    -- second wall under the verdict slam. A two-player playtest reaches exactly this: a
    -- match decided inside the phase-1 hold, record still phase 1, still HOLDING.
    local E = busClient()
    goPlaying(E)
    local hp = both(E, WAIT * 0.5)
    E.env.BR.State.match.state = MS.ENDED
    local xp, xr = both(E, WAIT * 0.5)
    ok(hp.n > 0 and xp.n == 0 and xr.n > 0,
        'and a match that ENDS inside the phase-1 hold takes circle 1\'s wall down with '
            .. 'it, though the record is still phase 1 and still HOLDING -- which is why '
            .. 'the preview tests PLAYING by name -- while the zone\'s own wall stays, as '
            .. 'it does at the end of every phase',
        ('%d tris while playing, %d preview and %d real once ENDED'):format(
            hp.n, xp.n, xr.n))

    -- ─── a collapsed target is not a circle to stand beside ───
    --
    -- BR.StormShape.circle FLOORS ITS RADIUS AT ONE METRE, so a phase-1 target of zero
    -- would draw a one-metre purple ring rather than nothing. THE SHIPPING CONFIG
    -- CANNOT REACH THIS -- phases[1].radius is 2600 -- so it is a hand-built record,
    -- the only thing that can.
    local Z = busClient()
    Z.env.BR.State.match.state = MS.PLAYING
    Z.env.BR.State.me.state    = PS.ALIVE
    Z.record(1, OCX, OCY, OR, CCX, CCY, 0.0, WAIT, SHRINK, 0.5)
    Z.env.BR.State.stormPreview = nil
    local zp = both(Z, WAIT * 0.5)
    ok(zp.n == 0,
        'a phase-1 record whose target has collapsed draws no circle-1 wall at all, '
            .. 'rather than the one-metre ring the radius floor would otherwise hand it',
        ('%d tris on circle 1'):format(zp.n))

    -- ─── and the fallback reaches the PLAYING stretch too ───
    --
    -- mainlandLoaded's fallback was BUS ALONE, which was complete while the preview
    -- itself was BUS alone. On a box where br_environment is not running a BUS-only
    -- fallback would withhold circle 1's wall for the whole of phase 1 and nothing
    -- would say so. Every other client in this block fires the announcement, so this
    -- is the only assertion that can see it.
    local S = newStormClient()
    S.env.BR.State.storm = nil
    S.env.BR.State.match.state = MS.BUS
    S.env.BR.State.me.state    = PS.BUS
    S.env.BR.State.stormPreview = { cx = CCX, cy = CCY, r = CR }
    S.pedAt = pt(0.0, 0.0, 30.0)
    S.settlePreview()
    local fbBus = wall(S, PREVIEW_SHAPE)
    goPlaying(S)
    local fbHold = both(S, WAIT * 0.5)
    ok(fbBus.n > 0 and fbHold.n > 0 and fbHold.alpha == PREV,
        'with br_environment silent throughout, the match state alone carries circle '
            .. '1\'s wall from the bus into the PLAYING hold',
        ('%d tris on the bus, %d at %d mid-hold'):format(
            fbBus.n, fbHold.n, fbHold.alpha))

    ok(C.errored() == nil and W.errored() == nil and E.errored() == nil
        and R.errored() == nil and S.errored() == nil,
        'and phase 1\'s two walls run clean on every client in this block',
        C.errored() or W.errored() or E.errored() or R.errored() or S.errored())
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
    --   PHASE 1'S TWO WALLS (#344). The opening wall ramps in over the hold's FIRST
    --   fadeInSec, off the record's own tStart -- which the cut keeps, so the ramp does
    --   not restart -- and circle 1's wall stands beside it through the whole cut hold
    --   and into the sweep, which now starts a minute and a half early.
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

    -- Circle 1's wall is zone 1's shape; `preview.twowalls` has why the opening wall
    -- is measured against the solved zone instead.
    local PSS = env.BR.StormShape
    local PREVIEW_SHAPE = PSS.inset(PSS.blob(CCX, CCY, CR, env.BR.StormUnit(nil, 1)), INSET)

    --- Each wall alone in the last frame -- the other's callback switched off, for the
    --- reason `preview.twowalls` gives -- with its triangle count and alpha, and
    --- whether its corners stand on its own shape.
    local function wallAlone(off, shape)
        env.BR.Loop.setEnabled(off, false)
        C.frame()
        env.BR.Loop.setEnabled(off, true)
        if not shape then
            local rec = env.BR.State.storm
            local cx, cy, r, _, _, _, t, g = env.BR.StormAt(rec, env.BR.Clock.now())
            shape = PSS.inset(env.BR.StormZone(rec, cx, cy, r, t, g), INSET)
        end
        local w = { n = 0, alpha = 0, stray = nil }
        for _, t in ipairs(C.polys) do
            if w.n > 0 and w.alpha ~= t.a then w.stray = w.stray or 'a wall stripes' end
            if math.abs(PSS.distance(shape, t[1].x, t[1].y)) > 1e-6 then
                w.stray = w.stray or ('(%.2f, %.2f) is off its shape'):format(t[1].x, t[1].y)
            end
            w.alpha, w.n = t.a, w.n + 1
        end
        return w
    end
    --- Both walls at the harness's current moment, less the 16 ms a frame adds each.
    local function walls()
        local at = C.now
        local pv = wallAlone('storm.wall', PREVIEW_SHAPE)
        C.now = at
        local rw = wallAlone('storm.previewWall', nil)
        return pv, rw
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
    local bp, br = walls()
    ok(bp.n > 0 and bp.alpha == PREV and bp.stray == nil
            and br.alpha > 0 and br.alpha < FULL,
        'and a gliding player at the new, earlier PLAYING has circle 1\'s wall at '
            .. 'previewAlpha -- the bus\'s view, carried on -- and the opening wall part '
            .. 'way up its ramp from the start of the hold (#344)',
        bp.stray or ('preview %d at %d, opening wall at %d'):format(bp.n, bp.alpha, br.alpha))

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

    -- ─── and both walls follow the cut hold, step by step ───
    --
    -- The record is left alone from here and the CLOCK moves, which is how a match
    -- actually runs. `at(msLeft)` puts each frame's own solve exactly msLeft from the
    -- CUT hold's end, counting the 16 ms C.frame adds; negative is into the sweep.
    local cutEnd = T0 + cutWait
    local function at(msLeft)
        C.now = cutEnd - msLeft - 16
        return walls()
    end
    local steps = {}
    for ms = CUT, 0, -2000 do steps[#steps + 1] = ms end
    for ms = 0, -4000, -500 do steps[#steps + 1] = ms end

    local empty, stray, rampBad, prevBad, backward = nil, nil, nil, nil, nil
    local lastR = 0
    for _, ms in ipairs(steps) do
        local pv, rw = at(ms)
        stray = stray or ((pv.stray or rw.stray) and ('at %d ms %s'):format(ms,
            pv.stray or rw.stray))
        if pv.n == 0 and rw.n == 0 then empty = empty or ms end
        -- THE OPENING WALL IS ON THE RECORD'S tStart, WHICH THE CUT KEPT: its ramp
        -- runs on from where it was and never goes back.
        local held = (cutEnd - T0) - ms
        local want = (held >= FADE) and FULL or (rr.alpha * held / FADE)
        if math.abs(rw.alpha - want) > 1.0 then
            rampBad = rampBad or ('%d ms into the hold at %d, wanted %.1f')
                :format(held, rw.alpha, want)
        end
        if rw.alpha < lastR then
            backward = backward or ('at %d ms %d -> %d'):format(ms, lastR, rw.alpha)
        end
        lastR = rw.alpha
        if pv.n == 0 or pv.alpha ~= PREV then
            prevBad = prevBad or ('at %d ms circle 1 is %d tris at %d'):format(ms, pv.n,
                pv.alpha)
        end
    end
    ok(empty == nil and stray == nil,
        'from the cut to the end of the cut hold and into its sweep there is a wall at '
            .. 'every step, every corner on its own shape',
        stray or (empty and ('empty at %d ms'):format(empty)))
    ok(rampBad == nil and backward == nil,
        'the opening wall\'s ramp runs on off the record\'s own start, which the cut '
            .. 'kept: it neither restarts nor steps back',
        rampBad or backward)
    ok(prevBad == nil,
        'and circle 1\'s wall holds previewAlpha through the whole cut hold and the start '
            .. 'of the sweep it now begins a minute and a half early -- the cut moved '
            .. 'nothing on screen',
        prevBad)
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
    -- is where the whole feature is visible: at phase 1 the corners are kilometres
    -- apart along the boundary, so a player on the ground sees a stretch that reads
    -- as an arc of a circle. #347 proved ADD_AREA_OVERLAY fills an arbitrary polygon
    -- on the radar AND the pause map, so the zones are filled boundaries now.
    --
    -- ═══ WHAT THIS BLOCK IS FOR IS THE SWITCH AND THE PICTURE, NOT THE POLYGON ═══
    --
    -- The polygon is `shape.polyline`'s subject in tools/test_shared.lua. What can
    -- only be tested HERE is the pair of paths -- that the fill replaces the blips
    -- rather than joining them, that a refusal anywhere puts the blips back -- and the
    -- picture a STANDING storm puts on the map: the destination, and the one zone over
    -- it (#344). `map.motion` is the storm moving.
    --
    -- A SEED WHOSE CURRENT ZONE IS A POLYGON, because one zone in ten is a plain
    -- circle and "the fill is not a circle" is one of the assertions below.
    -- PHASE 1'S CURRENT ZONE IS THE MAP DISC on every seed (#344 round 2), so there is
    -- nothing to search for there. `want`, WHEN GIVEN, IS ASKED OF THE RECORD TOO.
    local function mapClient(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs, want)
        local C = newStormClient()
        C.mm.handle = 7
        C.pedAt = pt(0.0, 0.0)
        local rec = C.record(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs, 2.0)
        local s = 1
        while (phase > 1 and C.env.BR.StormUnit(s, phase - 1).kind ~= 'polygon')
            or (want and not want(C.env, s)) do
            s = s + 1
        end
        rec.seed = s
        return C
    end

    --- `want` for a pair that NESTS by real shape where it is placed -- the standing
    --- picture of an ordinary phase, which a breakout adds its union to (below).
    local function nestsAt(phase, cx0, cy0, r0, cx1, cy1, r1)
        return function(env, s)
            return env.BR.StormNested(env.BR.BuildStormRecord(phase, cx0, cy0, r0,
                cx1, cy1, r1, 0, 1, 1, 1.0, s))
        end
    end

    local blip = newStormClient().env.BR.Config.Storm.blip

    -- ─── before the gate opens, the blips carry the map ───
    --
    -- THIS IS THE ORDER THE GAME ALWAYS PLAYS IN. The gate deliberately waits out
    -- three seconds of session plus ten consenting passes, so every match starts with
    -- the rings and swaps to the fills a few seconds in. A first tick that drew
    -- nothing at all would be a map with no safe zone on it for that whole stretch.
    local C = mapClient(2, 0.0, 0.0, 800.0, 300.0, 0.0, 400.0, 600000, 60000,
        nestsAt(2, 0.0, 0.0, 800.0, 300.0, 0.0, 400.0))
    C.tick(1)
    ok(#C.areas() == 0 and #C.rings() > 0,
        'before the readiness gate opens the map is radius blips and no fill at all',
        ('%d areas, %d rings'):format(#C.areas(), #C.rings()))

    ok(C.overlayReady(), 'the gate opens once the session has settled')
    C.tick(2)
    ok(C.errored() == nil, 'and the map callback runs clean', C.errored())

    -- ─── and then exactly one of the two paths is drawing ───
    ok(#C.areas() == 2 and #C.dest() == 1 and #C.zone() == 1,
        'a phase fills TWO areas: the destination, and the ONE zone -- no keyframes, '
            .. 'nothing else to fade between (#344)',
        ('%d areas, %d destination, %d zone'):format(#C.areas(), #C.dest(), #C.zone()))
    ok(#C.rings() == 0 and #C.boxes() == 0,
        'and NOT ONE radius blip is left beside them -- a fill and a disc of the '
            .. 'same zone would be two boundaries, and a player reads the nearer',
        ('%d rings, %d boxes'):format(#C.rings(), #C.boxes()))

    -- ─── the fill that SHOWS is on the real boundary, and it is not a circle ───
    --
    -- MEASURED AGAINST BR.StormWall, which is the wall as it stands -- so this is also
    -- the assertion that the map and the curtain cannot disagree about the edge while
    -- the storm stands still. READ OFF C.shown, WHICH IS WHERE THE MOVIE PUTS IT: the
    -- zone goes out in world coordinates and is never moved (2026-10-04), and C.shown
    -- would carry any move or resize the movie had been sent.
    local SS = C.env.BR.StormShape
    local rec = C.env.BR.State.storm
    local zone = C.env.BR.StormWall(rec, 0.0)
    local shown, shownO = C.zoneFill()
    local worstOff, lo, hi = 0.0, math.huge, 0.0
    local shownPts = shown and C.shown(shown) or {}
    for _, p in ipairs(shownPts) do
        worstOff = math.max(worstOff, math.abs(SS.distance(zone, p.x, p.y)))
        local rad = math.sqrt((p.x - rec.cx0) ^ 2 + (p.y - rec.cy0) ^ 2)
        lo, hi = math.min(lo, rad), math.max(hi, rad)
    end
    ok(#shownPts >= 3 and worstOff < 1e-6,
        'the zone\'s fill is ON the wall as it stands, to a micron',
        ('%d points, worst %.9f m off'):format(#shownPts, worstOff))
    ok((hi - lo) > 1.0,
        'and the boundary is genuinely not a circle: its distance from the centre '
            .. 'varies with the bearing, which is the whole of what #350 is about',
        ('radius runs %.1f to %.1f m'):format(lo, hi))

    -- ─── the colour and the alpha ───
    --
    -- THE ZONE GOES OUT AT FULL STRENGTH AND IS FADED, and that is the one piece of
    -- arithmetic on this path that is not obvious. The movie takes an area's alpha
    -- twice at the add -- `mc._alpha = a / 255 * 100` and beginFill's own Flash 0-100
    -- alpha -- and below 100 the two COMPOUND, which areaAlpha inverts for the areas
    -- that are never faded. SET_OVERLAY_ALPHA rewrites the first term alone, so it is
    -- LINEAR only for an area added at 255, where the fill term is opaque: that is why
    -- the zone -- which a sweep fades -- is added at 255 and then given its
    -- alpha.
    local col  = C.env.BR.Config.Storm.render.colour
    local MO   = C.env.BR.MapOverlay
    local target = C.dest()[1]
    local allPurple = true
    for _, ar in ipairs(C.areas()) do
        if ar.r ~= col.r or ar.g ~= col.g or ar.b ~= col.b then allPurple = false end
    end
    ok(allPurple, 'every fill is the wall\'s own purple out of render.colour')
    ok(shown.a == 255 and near(shownO, blip.currentAlpha / 255, 0.5 / 255),
        'the zone goes out at 255 and is faded to the safe zone\'s blip alpha, linear',
        ('%d added, showing %.4f against %.4f'):format(shown.a, shownO,
            blip.currentAlpha / 255))
    ok(target.a == MO.areaAlpha(blip.nextAlpha)
            and near(C.opacity(target), blip.nextAlpha / 255, 0.5 / 255),
        'while the destination, which is never faded, goes out at its blip alpha '
            .. 'inverted through the movie\'s compounding, and renders at that alpha',
        ('%d from %d, rendering %.4f'):format(target.a, blip.nextAlpha,
            C.opacity(target)))
    ok(MO.areaAlpha(110) == 110 and MO.areaAlpha(255) == 255,
        'an alpha at or above 100 is already linear and is passed through')
    ok(MO.areaAlpha(80) == 89,
        'the inverse is 10 * sqrt(want): 80 of 255 comes back as 89, which renders '
            .. '(89/255) * (89/100) = the 80/255 that was asked for',
        tostring(MO.areaAlpha(80)))
    ok(MO.areaAlpha(-5) == 0 and MO.areaAlpha(400) == 255,
        'and it is clamped at both ends')

    -- ─── the destination is drawn FIRST, on its own shape ───
    --
    -- So the zone above it can be replaced without renumbering it (REM_OVERLAY
    -- splices). Two fills of one colour composite the same in either order.
    local tWorst = 0.0
    local tShape = C.env.BR.StormTarget(rec)
    for _, p in ipairs(target.points) do
        tWorst = math.max(tWorst, math.abs(SS.distance(tShape, p.x, p.y)))
    end
    ok(tWorst < 1e-6 and target._x == nil and C.areas()[1] == target,
        'the first fill is the DESTINATION, in world coordinates on its own shape, and '
            .. 'never placed',
        ('worst %.9f m off the destination'):format(tWorst))

    -- (Phase 1 is circle 1 alone, its whole-map zone never drawn: `map.phase1`.)

    -- ─── a breakout's zone is the zone as its hold began ───
    --
    -- On a breakout the safe zone is the wall UNION the destination, which the wall and
    -- the damage tick read as one zone. The map's zone is that zone as the hold began
    -- (2026-10-04): on a DISJOINT pair the union, two islands, at the safe zone's alpha
    -- with the destination under the far one -- and on a CONJOINED pair the wall alone,
    -- because the zone's growth into the destination is not followed on the map: the
    -- destination's own fill covers what it grows into (grow.agree).
    local function unionShown(C2, label, g)
        local rec2 = C2.env.BR.State.storm
        local U = C2.env.BR.StormZone(rec2, rec2.cx0, rec2.cy0, rec2.r0, 0.0, g)
        local off, lowest = 0.0, 1.0
        for _, ov in ipairs(C2.zone()) do
            lowest = math.min(lowest, C2.opacity(ov))
            for _, p in ipairs(C2.shown(ov)) do
                off = math.max(off, math.abs(C2.env.BR.StormShape.distance(U, p.x, p.y)))
            end
        end
        ok(off < 1e-6 and near(lowest, blip.currentAlpha / 255, 0.5 / 255),
            label, ('union %.3e m off, lowest %.4f'):format(off, lowest))
    end
    local D = mapClient(4, 0.0, 0.0, 950.0, 2400.0, 0.0, 260.0, 600000, 60000)
    ok(D.overlayReady() and D.errored() == nil, 'a disjoint breakout reaches the gate')
    D.tick(2)
    ok(#D.areas() == 3 and #D.zone() == 2 and #D.dest() == 1,
        'a disjoint breakout is the destination and its zone -- the union, two islands, '
            .. 'each its own fill',
        ('%d areas, %d zone, %d destination'):format(#D.areas(), #D.zone(), #D.dest()))
    unionShown(D, 'and while it holds, both islands are the zone\'s fill at the safe '
        .. 'zone\'s alpha, on the union to a micron', 1.0)
    local V = mapClient(4, 0.0, 0.0, 950.0, 1100.0, 0.0, 520.0, 600000, 60000)
    ok(V.overlayReady() and V.errored() == nil, 'an overlapping breakout too')
    V.grown()
    V.tick(2)
    ok(#V.areas() == 2 and #V.zone() == 1,
        'and an OVERLAPPING one is its destination and one zone loop',
        ('%d areas, %d zone'):format(#V.areas(), #V.zone()))
    unionShown(V, 'and even once it has grown, that loop is the wall where the hold began '
        .. '-- the growth is not redrawn on the map', 0.0)

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
    R.env.BR.State.storm.r0 = 900.0          -- a new record's geometry: a rebuild is due
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

    -- ─── the rebuild is rate-limited, and keyed on the record's geometry ───
    --
    -- An area cannot be edited, so every new picture is every clip removed and every
    -- clip re-added with a kilobyte of coordinates marshalled through a Scaleform
    -- string. A rebuild per tick on a zone that has not moved would be that cost for
    -- nothing, all match.
    local nests300, nests250 = nestsAt(2, 0.0, 0.0, 800.0, 300.0, 0.0, 400.0),
        nestsAt(2, 0.0, 0.0, 800.0, 250.0, 0.0, 400.0)
    local S = mapClient(2, 0.0, 0.0, 800.0, 300.0, 0.0, 400.0, 600000, 60000,
        function(env, s) return nests300(env, s) and nests250(env, s) end)
    ok(S.overlayReady(), 'the cadence client reaches the gate')
    S.tick(2)
    local before = S.areas()[1]

    -- AND NOT EVEN WALKED. Counted at polyline, the one thing every contour on this
    -- path is walked through.
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
            .. 'placement, not a fade',
        ('%d method calls in 12 ticks'):format(S.mm.calls - callsHeld))

    -- AND A NEW PICTURE IS A REBUILD, WHOLE. The target moving is a different record.
    local addsHeld = S.mm.adds
    S.env.BR.State.storm.cx1 = 250.0
    S.tick(2)
    ok(S.areas()[1] ~= before and #S.areas() == 2 and S.mm.adds == addsHeld + 2,
        'while a new target is a rebuild, whole -- every area replaced',
        ('%d areas, %d adds'):format(#S.areas(), S.mm.adds - addsHeld))

    -- ─── the character count, which is the one unmeasured risk ───
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
-- Shared by the map blocks below: what the movie ran, by method name.
-- ---------------------------------------------------------------------------

--- A copy of the movie's per-method counts, to diff against later.
local function mmSnap(C)
    local t = {}
    for k, v in pairs(C.mm.byMethod) do t[k] = v end
    return t
end

--- What the movie ran since `since`, as "NAME n" sorted and joined -- '' for nothing.
local function mmSince(C, since)
    local out = {}
    for k, v in pairs(C.mm.byMethod) do
        local d = v - (since[k] or 0)
        if d ~= 0 then out[#out + 1] = ('%s %d'):format(k, d) end
    end
    table.sort(out)
    return table.concat(out, ', ')
end

--- How far the destination fill the map shows is from BR.StormTarget, worst point --
--- math.huge when there is none.
local function destErr(C, rec)
    local ov = C.dest()[1]
    if not ov then return math.huge end
    local D = C.env.BR.StormTarget(rec)
    local w = 0.0
    for _, p in ipairs(C.shown(ov)) do
        w = math.max(w, math.abs(C.env.BR.StormShape.distance(D, p.x, p.y)))
    end
    return w
end

-- ---------------------------------------------------------------------------
describe('map.sweep')
do
    -- ═══ AS A SWEEP SETS OFF THE OLD ZONE FADES, AND ONLY THE DESTINATION IS LEFT
    --     (#350, 2026-10-04) ═══
    --
    --   "today as the storm moves, the current shape (txd on minimap/bigmap) shrinks
    --    until it pops to the new shape and finishes by scaling into the new size.
    --    Let's remove that all together so when the sweep starts, the old shape fades
    --    away and only the new shape is left."            -- the owner, 2026-10-04
    --
    -- The map used to show the moving zone -- its outline moved and scaled onto the wall
    -- every tick, redrawn as the sweep set off and at its knee. Now nothing on it moves.
    -- This block asks, kind of sweep by kind of sweep, at the map band's own 100 ms: that
    -- the movie hears nothing but the zone's fade -- SET_OVERLAY_ALPHA, falling to
    -- nothing over overlay.sweepFadeSec from the sweep's first tick -- and that the
    -- destination, the very clip the hold drew, is the one fill left.
    --
    -- C.tick moves 1500 ms, which clears every throttle in the file; this steps the TICK
    -- band 100 ms at a time, which is what the game does. `want`, WHEN GIVEN, PICKS THE
    -- SEED: the first from 424242 up whose hand-built pair is the case asked about.
    local CFG = newStormClient().env.BR.Config.Storm
    local blip = CFG.blip
    local FADE_MS = CFG.overlay.sweepFadeSec * 1000.0

    local function sweepClient(phase, cx0, r0, cx1, r1, shrinkMs, cy0, cy1, want)
        local C = newStormClient()
        C.mm.handle = 7
        C.pedAt = pt(cx0, cy0 or 0.0)
        local rec = C.record(phase, cx0, cy0 or 0.0, r0, cx1, cy1 or 0.0, r1,
            600000, shrinkMs, 2.0)
        rec.seed = 424242
        while want and not want(C.env, rec) do rec.seed = rec.seed + 1 end
        return C, rec
    end

    --- The pair nests by real shape.
    local function NESTED(env, rec) return env.BR.StormNested(rec) end

    --- The pair overlaps without nesting: the phase is a conjoined breakout.
    local function CONJOINED(env, rec)
        return (env.BR.StormOverlaps(rec))
    end

    --- Start the record's sweep NOW, on the harness clock.
    local function startSweep(C, rec) rec.tStart = C.now - rec.tWait end

    --- `n` passes of the TICK band, 100 ms apart, calling `each` after every one.
    local function realTicks(C, n, each)
        for i = 1, n do
            C.now = C.now + 100
            C.env.BR.Loop.step(C.env.BR.Loop.TICK)
            if each then each(i) end
        end
    end

    local function traceRow(C, name)
        for _, row in ipairs(C.env.BR.Loop.hitchStats().rows) do
            if row.name == name then return row end
        end
        return nil
    end

    --- The strongest any zone clip is showing, 0..1.
    local function zoneShowing(C)
        local a = 0.0
        for _, ov in ipairs(C.zone()) do a = math.max(a, C.opacity(ov)) end
        return a
    end

    -- ─── #350's bisect still works on a sweep, and names only the modes that mean something ───
    --
    -- Each mode deliberately damages only the LOCAL picture: the record and clock keep
    -- advancing, so a smooth mode has isolated rendering rather than stopped the storm.
    -- The command also starts a fresh capture; otherwise two modes in one playtest would
    -- be blended into a percentage that describes neither.
    local D, drec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, NESTED)
    ok(D.cmds.brstormbisect ~= nil, '/brstormbisect is registered')
    ok(D.overlayReady(), 'the bisect client reaches the overlay gate')
    D.tick(2)
    local dZone, dDest = D.zone()[1], D.dest()[1]
    local dSince = mmSnap(D)
    startSweep(D, drec)

    D.cmds.brstormbisect(nil, { 'mapfreeze', '40' }, '')
    realTicks(D, 20)
    local dHitch = D.env.BR.Loop.hitchStats()
    ok(D.env.BR.Storm.bisectMode == 'mapfreeze'
            and dHitch.enabled and dHitch.thresholdMs == 40,
        'mapfreeze is visible in state and starts a clean capture at the requested threshold')
    ok(mmSince(D, dSince) == '' and D.zone()[1] == dZone
            and near(D.opacity(dZone), blip.currentAlpha / 255, 0.5 / 255),
        'mapfreeze keeps the fill resident and sends it nothing -- not even the fade, so the '
            .. 'old zone stays on the map while the storm moves on',
        mmSince(D, dSince))

    D.cmds.brstormbisect(nil, { 'normal' }, '')
    realTicks(D, 1)
    ok(D.env.BR.Storm.bisectMode == 'normal' and D.opacity(dZone) == 0.0
            and D.dest()[1] == dDest and destErr(D, drec) < 1e-6,
        'normal fades the old zone off on its next tick -- the sweep is past its fade -- and '
            .. 'the destination is the fill left', ('zone at %.4f'):format(D.opacity(dZone)))

    D.cmds.brstormbisect(nil, { 'mapoff' }, '')
    -- The fallback rings refresh on their own cadence, so the handoff is bounded rather
    -- than required on the first 100 ms pass.
    realTicks(D, 3)
    local dRings = D.rings()
    ok(#D.areas() == 0 and #dRings == 1 and dRings[1].r == drec.r1
            and dRings[1].colour == blip.nextColour,
        'mapoff removes the custom fill and hands the map to the fallback blips -- which keep '
            .. 'the same rule mid-sweep: the destination\'s ring alone',
        ('%d fills, %d rings'):format(#D.areas(), #dRings))
    D.cmds.brstormbisect(nil, { 'normal' }, '')
    realTicks(D, 6)
    ok(#D.areas() == 1 and #D.dest() == 1 and #D.zone() == 0 and #D.rings() == 0
            and destErr(D, drec) < 1e-6,
        'normal draws the picture again mid-sweep -- the destination alone -- and the blips go',
        ('%d fills, %d zone, %d rings'):format(#D.areas(), #D.zone(), #D.rings()))

    -- THE TWO MODES THAT WENT WITH THE MOVING SHAPE ARE REFUSED, and the status names
    -- only the four left.
    local dp = #D.prints
    D.cmds.brstormbisect(nil, { 'mapnomorph' }, '')
    D.cmds.brstormbisect(nil, { 'mapnoresize' }, '')
    D.cmds.brstormbisect(nil, {}, '')
    local said = table.concat(D.prints, '\n', dp + 1)
    local usages = 0
    for _ in said:gmatch('usage: brstormbisect <normal|mapoff|mapfreeze|walloff>') do
        usages = usages + 1
    end
    ok(D.env.BR.Storm.bisectMode == 'normal' and usages == 2
            and said:find('modes: normal | mapoff | mapfreeze | walloff', 1, true) ~= nil
            and not D.env.BR.Storm.setBisectMode('mapnomorph'),
        'mapnomorph and mapnoresize are gone -- there is no redraw clock and no resize to take '
            .. 'away -- and the status lists the four modes left', said)

    local W = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, NESTED)
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

    -- ─── a nested sweep, start to finish ───
    --
    -- Phase-2 sizes, and a center off the world's origin in BOTH axes on purpose: a fill
    -- the movie had been told to move would show off the destination by however far.
    local N, nrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, NESTED)
    ok(N.overlayReady(), 'the nested-sweep client reaches the gate')
    N.tick(2)
    local nZone, nDest = N.zone()[1], N.dest()[1]
    ok(N.zoneErr(nrec) < 1e-6 and #N.areas() == 2
            and near(N.opacity(nZone), blip.currentAlpha / 255, 0.5 / 255),
        'held, the map shows the destination and the zone the wall stands on, to a micron',
        ('%.9f m off, %d areas'):format(N.zoneErr(nrec), #N.areas()))
    N.env.BR.Loop.hitchStart(34)
    local nSince = mmSnap(N)
    startSweep(N, nrec)
    local writesIn, writesAfter, rose, lastO, zeroAt, firstDest = 0, 0, false, 1.0, nil, nil
    local lastFaded = N.mm.faded
    -- TO THE TICK BEFORE THE SWEEP ENDS, and five after it.
    realTicks(N, 1205, function(i)
        local into = i * 100
        local w = N.mm.faded - lastFaded
        lastFaded = N.mm.faded
        if into <= FADE_MS + 100 then writesIn = writesIn + w else writesAfter = writesAfter + w end
        local o = N.opacity(nZone)
        if o > lastO + 1e-9 then rose = true end
        lastO = o
        if o == 0.0 and not zeroAt then zeroAt = into end
        if i == 1 then
            firstDest = { same = N.dest()[1] == nDest, o = N.opacity(nDest),
                          err = destErr(N, nrec), visible = #N.visible() }
        end
    end)
    local nSent = mmSince(N, nSince)
    ok(N.errored() == nil and nSent == ('SET_OVERLAY_ALPHA %d'):format(writesIn)
            and writesIn >= 5 and writesAfter == 0,
        'the whole sweep sends the movie nothing but the zone\'s fade -- no add, no removal, '
            .. 'no move and no resize -- and nothing at all once the fade is over',
        N.errored() or ('%s; %d writes in the fade, %d after'):format(nSent, writesIn,
            writesAfter))
    ok(not rose and zeroAt ~= nil and zeroAt <= FADE_MS + 100 and zeroAt >= FADE_MS - 100,
        ('the zone\'s alpha only falls, and is nothing %.1f s into the sweep: '
            .. 'overlay.sweepFadeSec'):format(FADE_MS / 1000.0),
        ('rose %s, gone at %s ms'):format(tostring(rose), tostring(zeroAt)))
    ok(firstDest and firstDest.same and firstDest.err < 1e-6 and firstDest.visible == 2
            and near(firstDest.o, blip.nextAlpha / 255, 0.5 / 255),
        'the destination is on the map from the sweep\'s first tick -- the same clip the hold '
            .. 'drew, on BR.StormTarget, at its own strength -- beside the zone fading out',
        firstDest and ('%s, %.3e m, %.4f, %d visible'):format(tostring(firstDest.same),
            firstDest.err, firstDest.o, firstDest.visible) or 'no first tick')
    ok(N.dest()[1] == nDest and nDest._x == nil and nDest._width == nil
            and nDest._alpha == nil and #N.visible() == 1 and N.visible()[1] == nDest,
        'and the destination is never moved, resized or faded: when the sweep is done it is the '
            .. 'one fill on the map')
    local nAlpha = traceRow(N, 'storm.map.alpha')
    local nRebuild = traceRow(N, 'storm.map.rebuild')
    local gone = {}
    for _, name in ipairs({ 'storm.map.place', 'storm.map.position', 'storm.map.morph',
            'storm.map.stage', 'storm.map.switch', 'storm.map.drop' }) do
        if traceRow(N, name) then gone[#gone + 1] = name end
    end
    ok(nAlpha ~= nil and nAlpha.events * #N.zone() == writesIn
            and (nRebuild == nil or nRebuild.events == 0) and #gone == 0,
        'and the hitch diagnostic names it -- storm.map.alpha for each tick of the fade, no '
            .. 'rebuild, and none of the rows that went with the moving shape',
        ('alpha %s, rebuild %s, gone rows present: %s'):format(
            nAlpha and tostring(nAlpha.events) or 'none',
            nRebuild and tostring(nRebuild.events) or 'none', table.concat(gone, ',')))

    -- ─── overlay.sweepFadeSec is the fade ───
    for _, sec in ipairs({ 0.0, 3.0 }) do
        local R, rrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
            -700.0, -300.0, NESTED)
        R.env.BR.Config.Storm.overlay.sweepFadeSec = sec
        ok(R.overlayReady(), ('the %.0f s client reaches the gate'):format(sec))
        R.tick(2)
        local rZone, f0 = R.zone()[1], R.mm.faded
        startSweep(R, rrec)
        local rZero, rFirst = nil, nil
        realTicks(R, 50, function(i)
            if i == 1 then rFirst = R.opacity(rZone) end
            if not rZero and R.opacity(rZone) == 0.0 then rZero = i * 100 end
        end)
        local writes = R.mm.faded - f0
        if sec == 0.0 then
            ok(rZero == 100 and writes == #R.zone() and R.errored() == nil,
                'at sweepFadeSec 0 the zone is gone on the sweep\'s first tick, in one write',
                R.errored() or ('gone at %s ms, %d writes'):format(tostring(rZero), writes))
        else
            ok(rFirst and rFirst > 0.0 and rZero and rZero >= 2900 and rZero <= 3100
                    and writes >= 28 * #R.zone() and writes <= 31 * #R.zone()
                    and R.errored() == nil,
                'at 3 the fade takes three seconds, a write a tick',
                R.errored() or ('first %.4f, gone at %s ms, %d writes'):format(rFirst or -1,
                    tostring(rZero), writes))
        end
    end

    -- ─── a breakout is the same: its zone fades, its destination stays ───
    --
    -- The safe zone is the wall union the destination. The hold shows the zone as it
    -- began -- the union of a disjoint pair, the wall of a conjoined one -- beside the
    -- destination; the sweep fades that zone off and leaves the destination, which is
    -- the half of the safe zone the wall does not draw.
    for _, bc in ipairs({
        { 'a conjoined', 6, 0.0, 260.0, 300.0, 110.0, CONJOINED, 1 },
        { 'a disjoint', 4, 0.0, 950.0, 2400.0, 260.0, nil, 2 },
    }) do
        local B, brec = sweepClient(bc[2], bc[3], bc[4], bc[5], bc[6], 60000, nil, nil, bc[7])
        ok(B.overlayReady(), bc[1] .. ' breakout client reaches the gate')
        B.grown()
        B.tick(2)
        ok(#B.zone() == bc[8] and #B.dest() == 1 and B.zoneErr(brec) < 1e-6,
            ('%s breakout holds as its destination and the zone as the hold began -- %d '
                .. 'contour%s'):format(bc[1], bc[8], bc[8] == 1 and '' or 's'),
            ('%d zone, %d destination, %.3e m'):format(#B.zone(), #B.dest(),
                B.zoneErr(brec)))
        B.env.BR.Loop.hitchStart(34)
        local bDest, bSince = B.dest()[1], mmSnap(B)
        startSweep(B, brec)
        local bShown = 0
        realTicks(B, 599, function(i)
            if i * 100 > FADE_MS + 100 and not (#B.visible() == 1 and B.visible()[1] == bDest) then
                bShown = bShown + 1
            end
        end)
        local bSent = mmSince(B, bSince)
        ok(B.errored() == nil and bSent:match('^SET_OVERLAY_ALPHA %d+$') ~= nil
                and bShown == 0 and #B.rings() == 0 and B.dest()[1] == bDest
                and bDest._x == nil and bDest._alpha == nil and destErr(B, brec) < 1e-6
                and traceRow(B, 'storm.map.fallback') == nil,
            ('%s breakout\'s sweep sends nothing but the zone\'s fade, and from the end of it '
                .. 'shows the destination alone -- the same clip, untouched -- and never falls '
                .. 'back'):format(bc[1]),
            B.errored() or ('%s; %d ticks showing more, %d rings'):format(bSent, bShown,
                #B.rings()))
    end

    -- ─── a picture drawn first while the storm moves is the destination alone ───
    local J, jrec = sweepClient(4, 0.0, 950.0, 2400.0, 260.0, 120000)
    startSweep(J, jrec)
    ok(J.overlayReady(), 'a mid-sweep client reaches the gate')
    realTicks(J, 2)
    local jDest, jSince = J.dest()[1], mmSnap(J)
    realTicks(J, 200)
    ok(#J.areas() == 1 and #J.zone() == 0 and J.dest()[1] == jDest and jDest ~= nil
            and destErr(J, jrec) < 1e-6 and mmSince(J, jSince) == '' and #J.rings() == 0,
        'a client becoming ready mid-sweep draws the destination alone -- no zone, old or '
            .. 'moving -- and sends the movie nothing after it',
        ('%d fills, %d zone, %s'):format(#J.areas(), #J.zone(), mmSince(J, jSince)))

    -- AND INSIDE THE FADE WINDOW TOO: a new record whose sweep set off 300 ms ago.
    local K, krec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, NESTED)
    ok(K.overlayReady(), 'the fade-window client reaches the gate')
    K.tick(2)
    local k2 = {}
    for k, v in pairs(krec) do k2[k] = v end
    k2.r0 = krec.r0 - 1.0
    k2.tStart = K.now - k2.tWait - 300
    K.env.BR.State.storm = k2
    realTicks(K, 1)
    ok(#K.areas() == 1 and #K.zone() == 0 and #K.dest() == 1
            and near(K.opacity(K.dest()[1]), blip.nextAlpha / 255, 0.5 / 255),
        'and one whose picture is drawn inside the sweep\'s fade window shows no zone to fade: '
            .. 'the destination alone',
        ('%d fills, %d zone'):format(#K.areas(), #K.zone()))

    -- AND AFTER THE SWEEP HAS FINISHED, before the next record arrives.
    local Fn, fnrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, NESTED)
    fnrec.tStart = Fn.now - fnrec.tWait - fnrec.tShrink - 5000
    ok(Fn.overlayReady(), 'the finished-sweep client reaches the gate')
    Fn.tick(1)
    ok(#Fn.areas() == 1 and #Fn.zone() == 0 and destErr(Fn, fnrec) < 1e-6,
        'and so does one that becomes ready after the sweep has finished',
        ('%d fills, %d zone'):format(#Fn.areas(), #Fn.zone()))

    -- ─── and the fallback rings keep the same rule ───
    --
    -- A client whose overlay never becomes ready draws the zone and the destination as
    -- radius blips. A radius blip cannot be resized in place, and it is not followed any
    -- more: the zone's ring fades where it stands -- the same blip, its alpha falling --
    -- and is removed, and the destination's is the ring left.
    local Bf, bfrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, NESTED)
    Bf.mm.handle = nil
    Bf.tick(3)
    local cur, nxt = nil, nil
    for h, b in pairs(Bf.blips) do
        if b.exists and b.kind == 'radius' then
            if b.r == bfrec.r0 then cur = h elseif b.r == bfrec.r1 then nxt = h end
        end
    end
    ok(#Bf.areas() == 0 and cur ~= nil and nxt ~= nil and #Bf.rings() == 2
            and Bf.blips[cur].alpha == blip.currentAlpha,
        'a client with no overlay holds with the zone\'s ring and the destination\'s',
        ('%d rings'):format(#Bf.rings()))
    startSweep(Bf, bfrec)
    local seen, between, falling, last, extra, goneAt = {}, 0, true, blip.currentAlpha, 0, nil
    realTicks(Bf, 100, function(i)
        local b = Bf.blips[cur]
        if not b.exists and not goneAt then goneAt = i * 100 end
        if b.exists then
            if b.alpha > last then falling = false end
            last = b.alpha
            if b.alpha > 0 and b.alpha < blip.currentAlpha and not seen[b.alpha] then
                seen[b.alpha] = true
                between = between + 1
            end
        end
        for h, bb in pairs(Bf.blips) do
            if bb.exists and bb.kind == 'radius' and h ~= cur and h ~= nxt then
                extra = extra + 1
            end
        end
    end)
    ok(cur and not Bf.blips[cur].exists and Bf.blips[nxt].exists and extra == 0
            and falling and between >= 2 and goneAt and goneAt <= FADE_MS + 600
            and Bf.errored() == nil,
        'and as the sweep sets off its zone ring fades where it stands -- the same blip, its '
            .. 'alpha falling, never rebuilt or moved -- and is gone as the fade ends, the '
            .. 'destination\'s ring the one left',
        Bf.errored() or ('%d steps between, %d other rings, falling %s, gone at %s ms')
            :format(between, extra, tostring(falling), tostring(goneAt)))

    -- ─── and rebuildHz is the ceiling on whole pictures whatever asks ───
    --
    -- A target changed every tick is the worst-case key churn: artificial, and static
    -- -- the record is held -- so it isolates the ceiling.
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
    local floorMs = 1000.0 / CFG.overlay.rebuildHz
    ok(#gaps >= 5 and minGap >= floorMs,
        'static picture churn still rebuilds no closer together than 1 / rebuildHz',
        ('%d rebuilds in 10 s, closest %s ms apart, floor %.0f ms'):format(
            #gaps + 1, tostring(minGap), floorMs))

    -- ─── a zone the engine will not fade as it is drawn leaves NO picture ───
    --
    -- The zone goes out at full strength and is faded to the safe zone's alpha on the
    -- same tick. A refused fade there must take the push down whole, exactly as a
    -- refused add does -- and hand the map to the radius blips.
    local P, prec = sweepClient(2, 1000.0, 2600.0, 1600.0, 1600.0, 120000, nil, nil,
        NESTED)
    P.mm.refusePlace = true
    ok(P.overlayReady(), 'the refusal client reaches the gate')
    P.tick(3)
    ok(#P.areas() == 0 and #P.rings() > 0,
        'a picture whose zone could not be faded as it was drawn is taken down whole, and the '
            .. 'blips carry the map',
        ('%d areas, %d rings'):format(#P.areas(), #P.rings()))
    P.mm.refusePlace = false
    P.tick(3)
    ok(#P.areas() == 2 and #P.rings() == 0 and P.zoneErr(prec) < 1e-6,
        'and once the engine accepts it, the fill is back and on the zone',
        ('%d areas, %d rings'):format(#P.areas(), #P.rings()))

    -- ─── a refusal mid-sweep ───
    --
    -- A sweep asks the movie for nothing but the fade, so a refused add changes nothing.
    -- A refused fade would leave the old zone part-faded on the map -- the one thing the
    -- sweep's picture is for not showing -- so the picture comes down and the blips carry
    -- the map, by the same rule, to the end of the sweep; the exact picture comes back the
    -- moment the storm stands still.
    for _, refusal in ipairs({ 'add', 'SET_OVERLAY_ALPHA' }) do
        local Q, qrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
            -700.0, -300.0, NESTED)
        ok(Q.overlayReady(), ('the refused %s client reaches the gate'):format(refusal))
        Q.tick(2)
        Q.env.BR.Loop.hitchStart(34)
        startSweep(Q, qrec)
        realTicks(Q, 3)
        if refusal == 'add' then Q.mm.refuseAdd = true
        else Q.mm.refuseMethod[refusal] = true end
        realTicks(Q, 2)
        Q.mm.refuseAdd = false
        Q.mm.refuseMethod[refusal] = nil
        local qAdds = Q.mm.adds
        realTicks(Q, 30)
        local qFall = traceRow(Q, 'storm.map.fallback')
        local qRings = Q.rings()
        if refusal == 'add' then
            ok(Q.errored() == nil and #Q.areas() == 2 and #Q.visible() == 1
                    and Q.visible()[1] == Q.dest()[1] and Q.mm.adds == qAdds
                    and qFall == nil and #qRings == 0,
                'an add refused mid-sweep changes nothing -- the sweep asks for none -- and the '
                    .. 'fade still finishes',
                Q.errored() or ('%d areas, %d visible, fallback %s'):format(#Q.areas(),
                    #Q.visible(), qFall and tostring(qFall.events) or 'none'))
        else
            ok(Q.errored() == nil and #Q.areas() == 0 and #qRings == 1
                    and qRings[1].r == qrec.r1 and Q.mm.adds == qAdds
                    and qFall ~= nil and qFall.events == 1,
                'a fade refused mid-sweep takes the picture down rather than leave the old zone '
                    .. 'part-faded, and the blips carry the map by the same rule -- the '
                    .. 'destination\'s ring alone -- with nothing drawn again while the wall moves',
                Q.errored() or ('%d areas, %d rings, %d adds, fallback %s'):format(#Q.areas(),
                    #qRings, Q.mm.adds - qAdds, qFall and tostring(qFall.events) or 'none'))
        end
        realTicks(Q, 1200)
        ok(#Q.visible() == 1 and Q.visible()[1] == Q.dest()[1] and #Q.rings() == 0
                and destErr(Q, qrec) < 1e-6,
            'and once the sweep has finished the map shows the destination alone, the blips gone',
            ('%d visible, %d rings'):format(#Q.visible(), #Q.rings()))
    end

    -- ─── a removal the engine refuses must not steal the slot ───
    --
    -- A refused REM_OVERLAY leaves the old clips in the movie, and mapoverlay.lua keeps
    -- them on its books so the indices stay true. A replacement must not be stacked
    -- beside them: the caller stays on the blips until the old picture can be removed,
    -- then installs one new picture.
    local function nestsAtBoth(env, rec)
        local here = NESTED(env, rec)
        local was = rec.cx1
        rec.cx1 = 1350.0
        local there = NESTED(env, rec)
        rec.cx1 = was
        return here and there
    end
    local X, xrec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, nestsAtBoth)
    ok(X.overlayReady(), 'the leftover client reaches the gate')
    X.tick(2)
    local xAdds = X.mm.adds
    X.mm.refuseRemove = true
    xrec.cx1 = 1350.0                  -- a new target: a new key, so a rebuild
    X.tick(2)
    ok(#X.areas() == 2 and X.mm.adds == xAdds,
        'refused removals retain the old picture without stacking the replacement',
        ('%d areas, %d new adds'):format(#X.areas(), X.mm.adds - xAdds))
    X.mm.refuseRemove = false
    X.tick(2)
    ok(#X.areas() == 2 and X.mm.adds == xAdds + 2,
        'once removal is accepted, exactly one replacement picture is installed',
        ('%d areas, %d new adds'):format(#X.areas(), X.mm.adds - xAdds))
    startSweep(X, xrec)
    realTicks(X, 50)
    ok(X.errored() == nil and #X.areas() == 2 and #X.visible() == 1
            and X.visible()[1] == X.dest()[1],
        'and its sweep fades that zone off and leaves that destination',
        X.errored() or ('%d areas, %d visible'):format(#X.areas(), #X.visible()))

    -- ─── the last seconds of the final sweep ───
    --
    -- The destination is a point, so there is no destination fill: the final sweep fades
    -- its zone off and leaves nothing in its place, and no ring stands in for it -- the 3D
    -- wall closing on the point is the whole picture. The one removal is the faded clip,
    -- as the last zone runs out of polygon.
    local L, lrec = sweepClient(8, 500.0, 40.0, 520.0, 0.0, 30000, nil, nil, NESTED)
    ok(L.overlayReady(), 'the final-sweep client reaches the gate')
    L.tick(2)
    ok(#L.areas() == 1 and #L.zone() == 1 and #L.dest() == 0,
        'the final phase is the zone alone and no destination fill: its destination is a '
            .. 'point', ('%d areas'):format(#L.areas()))
    startSweep(L, lrec)
    local lSince, lRings = mmSnap(L), 0
    realTicks(L, 320, function()
        if #L.rings() > 0 then lRings = lRings + 1 end
    end)
    local lSent = mmSince(L, lSince)
    ok(L.errored() == nil and #L.areas() == 0 and lRings == 0
            and lSent:match('^REM_OVERLAY 1, SET_OVERLAY_ALPHA %d+$') ~= nil,
        'the final sweep fades its zone off and draws nothing in its place, and no ring stands '
            .. 'in for it',
        L.errored() or ('%s; rings on %d ticks'):format(lSent, lRings))

    -- ─── a record that starts part way through a morph shows its outline, then fades ───
    --
    -- A freeze, its thaw and a same-phase `brphase` start a record from the wall as it
    -- stands mid-morph (`mo`): world discs rather than a zone. The map shows that outline
    -- while it holds, and fades it off as its sweep sets off like any other.
    local O, orec = sweepClient(2, 1000.0, 2600.0, 1400.0, 1600.0, 120000,
        -700.0, -300.0, NESTED)
    local ocx, ocy, orr = O.env.BR.StormAt(orec, orec.tStart + orec.tWait + 0.4 * orec.tShrink)
    local _, _, _, _, _, _, ot = O.env.BR.StormAt(orec,
        orec.tStart + orec.tWait + 0.4 * orec.tShrink)
    local mo = O.env.BR.StormMorphAt(orec, ot)
    local mrec = O.env.BR.BuildStormRecord(2, ocx, ocy, orr, orec.cx1, orec.cy1, orec.r1,
        O.now, 600000, 90000, 2.0, orec.seed, mo)
    O.env.BR.State.storm = mrec
    ok(O.overlayReady(), 'the outline client reaches the gate')
    O.tick(2)
    local oWall = O.env.BR.StormWall(mrec, 0.0)
    local oFill = O.zoneFill()
    local oOff = oFill and 0.0 or math.huge
    for _, p in ipairs(oFill and O.shown(oFill) or {}) do
        oOff = math.max(oOff, math.abs(O.env.BR.StormShape.distance(oWall, p.x, p.y)))
    end
    ok(mo ~= nil and oOff < 1e-6,
        'a record carrying the wall\'s own outline shows that outline on the map while it '
            .. 'holds, to a micron',
        ('%.3e m off'):format(oOff))
    startSweep(O, mrec)
    local oSince = mmSnap(O)
    realTicks(O, 300)
    local oSent = mmSince(O, oSince)
    ok(O.errored() == nil and oSent:match('^SET_OVERLAY_ALPHA %d+$') ~= nil
            and #O.visible() == 1 and O.visible()[1] == O.dest()[1] and zoneShowing(O) == 0.0,
        'and fades it off as its sweep sets off, the destination left',
        O.errored() or ('%s, %d visible'):format(oSent, #O.visible()))
end

-- ---------------------------------------------------------------------------
describe('map.teardown')
do
    -- ═══ THE PICTURE IS CLEANED UP ON EVERY WAY OUT, AND IS NEVER MORE THAN THREE
    --     CLIPS ═══
    --
    -- A clip of ours is a clip in a movie that is not ours: ScaleformUI_Assets' minimap
    -- outlives a match, a trip home and br_core itself. So each way a picture can stop
    -- being wanted is walked here from a hold, and the count of our clips must come back
    -- to exactly its baseline -- nothing when nothing is drawn, the new picture when a
    -- new record is showing -- with the book-keeping agreeing with the movie clip for
    -- clip. And at every tick of every walk our clips in the movie never exceed three:
    -- the destination and a zone of two islands at most. (Until 2026-10-04 a bank of up
    -- to two hundred hidden outlines could sit beside them, staged for the sweep.)
    local recs = walkRecords(3)
    local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
    local peak = 0

    --- A client in a hold of phase `ph`, its picture drawn.
    local function holding(ph)
        local C = newStormClient()
        C.mm.handle = 7
        local rec = copy(recs[ph])
        rec.tStart = C.now
        C.env.BR.State.storm = rec
        C.pedAt = pt(rec.cx1, rec.cy1)
        C.overlayReady()
        rec.tStart = C.now
        return C, rec
    end

    --- `n` map ticks at 100 ms, keeping the peak. Stops early once `done()` says so,
    --- and returns how many ticks it took.
    local function run(C, n, done)
        for i = 1, n do
            C.now = C.now + 100
            C.env.BR.Loop.step(C.env.BR.Loop.TICK)
            peak = math.max(peak, #C.mm.overlays)
            if done and done() then return i end
        end
        return n
    end

    --- The book-keeping agrees with the movie, and the movie holds exactly the picture
    --- the map shows -- no leftover, no orphan.
    local function onlyCurrent(C)
        local rep = C.env.BR.MapOverlay.report()
        local slots = C.env.BR.Storm.mapSlots()
        local picture = slots and (#slots.destination + #slots.zone) or 0
        return rep.areas == #C.mm.overlays and rep.areas == picture and picture > 0,
            ('%d in the movie, %d on the books, %d picture'):format(#C.mm.overlays,
                rep.areas, picture)
    end
    local function empty(C) return #C.mm.overlays == 0 end
    local function holdOut(C, rec) run(C, math.floor(rec.tWait / 100.0) - 3) end

    -- ─── 1. the phase edge: the next record's picture replaces the last, whole ───
    local A, arec = holding(2)
    holdOut(A, arec)
    run(A, math.floor(arec.tShrink / 100.0) + 3)
    local nrec = copy(recs[3])
    nrec.tStart = A.now
    A.env.BR.State.storm = nrec
    run(A, 3)
    local okE, whyE = onlyCurrent(A)
    ok(okE and #A.zone() >= 1 and #A.dest() == 1,
        'at a phase edge the new record\'s picture replaces the old one: the movie holds the '
            .. 'new destination and zone and nothing else', whyE)

    -- ─── 2-4. the match ends, the player leaves, the trip home ───
    for _, path in ipairs({
        { 'the match ending', function(C)
            C.env.BR.State.match.state = C.env.BR.MatchState.ENDED
            run(C, 20)
            C.env.BR.State.match.state = C.env.BR.MatchState.CLEANUP
        end },
        { 'leaving the match', function(C)
            C.env.BR.State.me.state = C.env.BR.PlayerState.LOBBY
        end },
        { 'the trip home to the lobby', function(C)
            C.env.BR.State.match.state = C.env.BR.MatchState.WAITING
            C.env.BR.State.me.state = C.env.BR.PlayerState.LOBBY
        end },
    }) do
        local C, rec = holding(2)
        holdOut(C, rec)
        local had = #C.mm.overlays
        path[2](C)
        run(C, 3000, function() return empty(C) end)
        local rep = C.env.BR.MapOverlay.report()
        ok(had >= 2 and empty(C) and rep.areas == 0,
            ('%s takes the picture down, back to nothing of ours in the movie'):format(path[1]),
            ('%d before, %d left, %d on the books'):format(had, #C.mm.overlays, rep.areas))
    end

    -- ─── and a removal the engine refuses is retried, not leaked ───
    local R, rrec = holding(2)
    holdOut(R, rrec)
    R.mm.refuseRemove = true
    R.env.BR.State.me.state = R.env.BR.PlayerState.LOBBY
    run(R, 50)
    local held = #R.mm.overlays
    R.mm.refuseRemove = false
    local took = run(R, 3000, function() return empty(R) end)
    ok(held >= 2 and empty(R) and R.env.BR.MapOverlay.report().areas == 0 and took <= 2,
        'removals the engine refused are retried on every tick until it accepts, and then '
            .. 'every clip is gone', ('%d held while refused, %d left, %d ticks'):format(held,
            #R.mm.overlays, took))

    -- AND ONE mapoff COULD NOT REMOVE IS TRIED AGAIN TOO, not forgotten in the movie.
    local Mo, morec = holding(2)
    holdOut(Mo, morec)
    Mo.mm.refuseRemove = true
    Mo.cmds.brstormbisect(nil, { 'mapoff' }, '')
    run(Mo, 3)
    local moHeld = #Mo.mm.overlays
    Mo.mm.refuseRemove = false
    Mo.cmds.brstormbisect(nil, { 'normal' }, '')
    run(Mo, 30)
    local okM, whyM = onlyCurrent(Mo)
    ok(moHeld >= 2 and okM,
        'a mapoff whose removals were refused leaves nothing behind once the engine accepts: '
            .. 'back on normal the movie holds the one picture', whyM)

    -- ─── 5. death and spectating keep the map, and leak nothing ───
    local D, drec = holding(2)
    holdOut(D, drec)
    D.env.BR.State.me.state = D.env.BR.PlayerState.OUT
    run(D, math.floor(drec.tShrink / 100.0) + 3)
    local d2 = copy(recs[3])
    d2.tStart = D.now
    D.env.BR.State.storm = d2
    run(D, math.floor(d2.tWait / 100.0) - 3)
    local okD, whyD = onlyCurrent(D)
    ok(okD,
        'an eliminated or spectating player keeps the storm on the map, and its picture is '
            .. 'handed over at the phase edge like anybody\'s', whyD)

    -- ─── 6-7. brphase and brstormfreeze: a new record mid-sweep ───
    for _, path in ipairs({ { 'brphase', 120000 }, { 'brstormfreeze', 24 * 3600 * 1000 } }) do
        local C, rec = holding(2)
        holdOut(C, rec)
        run(C, math.floor(rec.tShrink * 0.4 / 100.0))
        local BR = C.env.BR
        local cx, cy, r, _, _, _, t = BR.StormAt(rec, BR.Clock.now())
        local mo = BR.StormMorphAt(rec, t)
        local jumped = BR.BuildStormRecord(rec.phase, cx, cy, r, rec.cx1, rec.cy1, rec.r1,
            C.now, path[2], rec.tShrink, 2.0, rec.seed, mo)
        C.env.BR.State.storm = jumped
        run(C, 600)
        local okP, whyP = onlyCurrent(C)
        ok(okP and #C.zone() >= 1,
            ('%s mid-sweep draws the new record\'s hold -- the outline where the wall stood, '
                .. 'and the destination -- in place of the last picture'):format(path[1]), whyP)
    end

    -- ─── 8. brforce back to warmup: the preview, alone ───
    local Wf, wrec = holding(2)
    holdOut(Wf, wrec)
    Wf.env.BR.State.match.state = Wf.env.BR.MatchState.WARMUP
    Wf.env.BR.State.me.state = Wf.env.BR.PlayerState.WARMUP
    Wf.env.BR.State.stormPreview = { cx = wrec.cx0, cy = wrec.cy0, r = 2600.0, seed = wrec.seed }
    run(Wf, 30)
    local okW, whyW = onlyCurrent(Wf)
    ok(okW and #Wf.mm.overlays == 1,
        'a jump back to warmup shows the preview alone', whyW)

    -- ─── 9. the fallback: a fade refused mid-sweep, and the next hold ───
    local F, frec = holding(2)
    holdOut(F, frec)
    run(F, 5)
    F.mm.refuseMethod['SET_OVERLAY_ALPHA'] = true
    run(F, 2)
    F.mm.refuseMethod['SET_OVERLAY_ALPHA'] = nil
    local fShown = #F.visible()
    run(F, math.floor(frec.tShrink / 100.0))
    local f2 = copy(recs[3])
    f2.tStart = F.now
    F.env.BR.State.storm = f2
    run(F, math.floor(f2.tWait / 100.0) - 3)
    local okF, whyF = onlyCurrent(F)
    ok(fShown == 0 and okF,
        'a fade refused mid-sweep takes the picture down at once -- nothing left showing -- and '
            .. 'the next hold draws its own: nothing leaks', whyF)

    -- ─── 10. the resource stopping takes everything, at once ───
    local S, srec = holding(2)
    holdOut(S, srec)
    local before = #S.mm.overlays
    S.fire('onClientResourceStop', 'some_other_resource')
    local kept = #S.mm.overlays
    S.fire('onClientResourceStop', 'br_core')
    ok(before >= 2 and kept == before and #S.mm.overlays == 0,
        'br_core stopping removes every clip of ours from the shared movie -- and another '
            .. 'resource stopping touches none of them',
        ('%d before, %d after another stopped, %d after br_core'):format(before, kept,
            #S.mm.overlays))

    -- ─── and a burst of records never piles pictures up ───
    local B = holding(2)
    for i = 1, 25 do
        local r2 = copy(recs[2 + (i % 5)])
        r2.tStart = B.now
        B.env.BR.State.storm = r2
        run(B, 40)
    end
    B.env.BR.State.me.state = B.env.BR.PlayerState.LOBBY
    run(B, 4000, function() return empty(B) end)
    ok(empty(B), 'twenty-five records in a row, then home: nothing of ours is left',
        ('%d left'):format(#B.mm.overlays))

    ok(peak <= 3,
        'and on every tick of every walk our clips in the movie never exceeded three -- the '
            .. 'destination and a zone of two islands at most', ('peak %d'):format(peak))
end

-- ---------------------------------------------------------------------------
describe('map.nomorph')
do
    -- ═══ WHOLE MATCHES: NOTHING ON THE MAP MOVES WHILE THE STORM DOES (2026-10-04) ═══
    --
    --   "that means the only indicator of the actual current shape of the storm is
    --    looking in the 3d world."                        -- the owner, 2026-10-04
    --
    -- Whole real matches, every phase, through the real client at the map band's own
    -- 100 ms, held to what that means:
    --
    --   THE WARMUP PREVIEW is one add, and stands;
    --   A HOLD adds and removes clips only on its record's first tick -- its picture --
    --   and after it sends nothing at all: a conjoined growth is not redrawn;
    --   PHASE 1 is circle 1 alone, hold and sweep: its whole-map zone is never drawn;
    --   A SWEEP sends nothing but SET_OVERLAY_ALPHA, and only inside its first
    --   overlay.sweepFadeSec: no add, no removal, no move, no resize. The zone's alpha
    --   only falls and is nothing once the fade is over, and the destination the hold
    --   drew is on the map from the sweep's first tick, on BR.StormTarget, untouched;
    --   /brstormhitch's summary reads the same off the client, and after the match
    --   nothing of ours is in the movie.
    --
    -- AND THE MACHINERY THAT SHOWED THE MOVING SHAPE IS GONE, not switched off: the
    -- morph clock, the staged bank, the overlay's placement and replacement, the wall's
    -- pivot and the fit inside it.
    local SEEDS = 3
    local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end

    local ship = newStormClient().env
    local shipOv = ship.BR.Config.Storm.overlay
    local leftBehind = {}
    for _, name in ipairs({ 'placeArea', 'placeIndex', 'replaceFrom', 'stageArea',
            'dropStaged', 'placeStaged', 'alphaStaged', 'dropOrphan', 'stagedCount' }) do
        if ship.BR.MapOverlay[name] ~= nil then leftBehind[#leftBehind + 1] = 'MapOverlay.' .. name end
    end
    for _, name in ipairs({ 'mapBank', 'mapClipCap' }) do
        if ship.BR.Storm[name] ~= nil then leftBehind[#leftBehind + 1] = 'Storm.' .. name end
    end
    if ship.BR.StormWallPivot ~= nil then leftBehind[#leftBehind + 1] = 'StormWallPivot' end
    if ship.BR.StormShape.fitScale ~= nil then leftBehind[#leftBehind + 1] = 'StormShape.fitScale' end
    if shipOv.morphHz ~= nil then leftBehind[#leftBehind + 1] = 'overlay.morphHz' end
    if shipOv.stage ~= nil then leftBehind[#leftBehind + 1] = 'overlay.stage' end
    ok(#leftBehind == 0 and type(shipOv.sweepFadeSec) == 'number'
            and shipOv.sweepFadeSec > 0.0 and shipOv.sweepFadeSec <= 2.0,
        'the moving map shape is gone, not switched off -- and the old zone fades out over '
            .. 'about a second', ('left behind: %s; sweepFadeSec %s'):format(
            table.concat(leftBehind, ', '), tostring(shipOv.sweepFadeSec)))
    local FADE_MS = shipOv.sweepFadeSec * 1000.0

    local previewOk, previewWhy = false, 'not run'
    local holdBad, holdWhere = 0, nil
    local sweepBad, sweepWhere = 0, nil
    local lateFade, lateWhere = 0, nil
    local rose, roseWhere = 0, nil
    local leftOn, leftWhere = 0, nil
    local destBad, destWhere = 0, nil
    local p1Bad, p1Where, p1Ticks = 0, nil, 0
    local sweepsN, fadesN, growHolds = 0, 0, 0
    local summaryBad, leftover = nil, 0
    for seq = 1, SEEDS do
        local recs = walkRecords(seq)
        local C = newStormClient()
        C.mm.handle = 7
        local env = C.env
        local BR = env.BR
        --- One map tick, and what the movie ran on it: { [method] = n }.
        local function step()
            local before = mmSnap(C)
            C.now = C.now + 100
            BR.Loop.step(BR.Loop.TICK)
            local d = {}
            for k, v in pairs(C.mm.byMethod) do
                if v ~= (before[k] or 0) then d[k] = v - (before[k] or 0) end
            end
            return d
        end
        local function said(d)
            local out = {}
            for k, n in pairs(d) do out[#out + 1] = ('%s %d'):format(k, n) end
            table.sort(out)
            return table.concat(out, ', ')
        end

        -- ─── the warmup preview: circle 1, drawn once ───
        if seq == 1 then
            local r1 = recs[1]
            BR.State.storm = nil
            BR.State.match.state = BR.MatchState.WARMUP
            BR.State.me.state = BR.PlayerState.WARMUP
            BR.State.stormPreview = { cx = r1.cx1, cy = r1.cy1, r = r1.r1, seed = r1.seed }
            local ready = C.overlayReady()
            C.tick(1)
            local pa, pr = C.mm.adds, C.mm.removes
            for _ = 1, 300 do step() end
            previewOk = ready and #C.areas() == 1 and pa == 1 and C.mm.adds == pa
                and C.mm.removes == pr
            previewWhy = ('%d areas, %d adds, then %+d adds and %+d removals in 30 s')
                :format(#C.areas(), pa, C.mm.adds - pa, C.mm.removes - pr)
            BR.State.stormPreview = nil
            BR.State.match.state = BR.MatchState.PLAYING
            BR.State.me.state = BR.PlayerState.ALIVE
        end

        for ph = 1, #BR.Config.Storm.phases do
            local rec = copy(recs[ph])
            rec.tStart = C.now
            BR.State.storm = rec
            C.pedAt = pt(rec.cx1, rec.cy1)
            if ph == 1 and seq > 1 then
                C.overlayReady()
                rec.tStart = C.now
            end
            if BR.StormOverlaps(rec) then growHolds = growHolds + 1 end
            local total = math.floor((rec.tWait + rec.tShrink) / 100.0) + 3
            local sweepTick, lastA, destClip = 0, nil, nil
            for i = 1, total do
                local d = step()
                local _, _, rr, st, msLeft = BR.StormAt(rec, BR.Clock.now())
                local where = ('match %d phase %d tick %d (%s)'):format(seq, ph, i, tostring(st))
                -- PHASE 1 IS CIRCLE 1 ALONE, from its record's first tick to its last.
                if ph == 1 and i > 1 then
                    p1Ticks = p1Ticks + 1
                    if not (#C.zone() == 0 and #C.dest() == 1 and #C.visible() == 1
                            and C.visible()[1] == C.dest()[1]) then
                        p1Bad = p1Bad + 1
                        p1Where = p1Where or (('%s: %d zone, %d destination, %d visible')
                            :format(where, #C.zone(), #C.dest(), #C.visible()))
                    end
                end
                if st == BR.StormPhase.HOLDING then
                    -- THE RECORD'S FIRST TICK DRAWS ITS PICTURE; after it, nothing.
                    if i > 1 then
                        for _ in pairs(d) do
                            holdBad = holdBad + 1
                            holdWhere = holdWhere or (where .. ': ' .. said(d))
                        end
                    end
                elseif st == BR.StormPhase.SHRINKING and (rr > 1.0 or rec.r1 > 1.0) then
                    -- (THE LAST ZONE'S LAST METER is not a sweep: with nothing left to
                    -- fill, the faded picture comes down and the blips -- none -- take
                    -- the map.)
                    sweepTick = sweepTick + 1
                    local into = rec.tShrink - msLeft
                    if sweepTick == 1 then
                        sweepsN = sweepsN + 1
                        if rec.r1 > 1.0 then
                            destClip = C.dest()[1]
                            if not destClip or C.opacity(destClip) <= 0.0
                                    or destErr(C, rec) > 1e-6 then
                                destBad = destBad + 1
                                destWhere = destWhere or (where .. ': no destination shown')
                            end
                        end
                    end
                    for k, n in pairs(d) do
                        if k ~= 'SET_OVERLAY_ALPHA' then
                            sweepBad = sweepBad + 1
                            sweepWhere = sweepWhere or (where .. ': ' .. said(d))
                        elseif into > FADE_MS + 100 then
                            lateFade = lateFade + 1
                            lateWhere = lateWhere or (('%s, %.0f ms in: %s'):format(where,
                                into, said(d)))
                        else
                            fadesN = fadesN + n
                        end
                    end
                    local a = 0.0
                    for _, ov in ipairs(C.zone()) do a = math.max(a, C.opacity(ov)) end
                    if lastA and a > lastA + 1e-9 then
                        rose = rose + 1
                        roseWhere = roseWhere or where
                    end
                    lastA = a
                    if into > FADE_MS + 100 and #C.visible() ~= #C.dest() then
                        leftOn = leftOn + 1
                        leftWhere = leftWhere or (('%s: %d visible, %d destination')
                            :format(where, #C.visible(), #C.dest()))
                    end
                    if destClip and (C.dest()[1] ~= destClip or destClip._x ~= nil
                            or destClip._width ~= nil or destClip._alpha ~= nil) then
                        destBad = destBad + 1
                        destWhere = destWhere or (where .. ': destination touched')
                    end
                end
            end
        end
        local ms = BR.Storm.mapStats()
        if not (ms.sweeps == #BR.Config.Storm.phases and ms.sweepAdds == 0
                and ms.sweepRemoves == 0 and ms.sweepFades > 0) then
            summaryBad = summaryBad or ('match %d: %d sweeps, %d fades, %d adds, %d removals')
                :format(seq, ms.sweeps, ms.sweepFades, ms.sweepAdds, ms.sweepRemoves)
        end
        BR.State.storm = nil
        for _ = 1, 50 do step() end
        leftover = leftover + #C.mm.overlays
        ok(C.errored() == nil, ('match %d runs clean'):format(seq), C.errored())
    end
    ok(previewOk, 'the warmup preview is one add, and stands thirty seconds without another',
        previewWhy)
    ok(holdBad == 0 and growHolds > 0,
        ('across %d whole matches every hold sends the movie nothing after its picture -- %d '
            .. 'conjoined growths among them, not one redrawn'):format(SEEDS, growHolds),
        holdWhere)
    ok(p1Bad == 0 and p1Ticks > 0,
        ('and phase 1 shows circle 1 alone on every one of its %d ticks, hold and sweep -- '
            .. 'its whole-map zone is never in the picture'):format(p1Ticks), p1Where)
    ok(sweepBad == 0 and sweepsN == SEEDS * 8,
        ('and every one of %d sweeps sends nothing but alpha writes -- no add, no removal, no '
            .. 'move, no resize'):format(sweepsN), sweepWhere)
    ok(lateFade == 0 and fadesN > 0,
        'and those only inside overlay.sweepFadeSec of the sweep setting off',
        lateWhere or ('%d writes'):format(fadesN))
    ok(rose == 0 and leftOn == 0,
        'the zone\'s alpha only falls, and once the fade is over the map shows the destination '
            .. 'and nothing else', roseWhere or leftWhere)
    ok(destBad == 0,
        'the destination is on the map from every sweep\'s first tick, on BR.StormTarget, and '
            .. 'is never touched', destWhere)
    ok(summaryBad == nil and leftover == 0,
        '/brstormhitch\'s summary reads the same off the client -- every sweep only faded -- '
            .. 'and after the match nothing of ours is in the movie',
        summaryBad or ('%d left'):format(leftover))

    -- ─── a client that becomes ready mid-sweep of a real match ───
    local jrecs = walkRecords(1)
    for _, ph in ipairs({ 3, 6 }) do
        local J = newStormClient()
        J.mm.handle = 7
        local rec = copy(jrecs[ph])
        rec.tStart = J.now - rec.tWait - math.floor(rec.tShrink * 0.3)
        J.env.BR.State.storm = rec
        J.pedAt = pt(rec.cx1, rec.cy1)
        local ready = J.overlayReady()
        local _, _, _, jst = J.env.BR.StormAt(rec, J.env.BR.Clock.now())
        local since = mmSnap(J)
        for _ = 1, 100 do
            J.now = J.now + 100
            J.env.BR.Loop.step(J.env.BR.Loop.TICK)
        end
        ok(ready and jst == J.env.BR.StormPhase.SHRINKING and #J.areas() == 1
                and #J.zone() == 0 and destErr(J, rec) < 1e-6 and mmSince(J, since) == ''
                and J.errored() == nil,
            ('a client that becomes ready mid-sweep of phase %d shows the destination alone, '
                .. 'and sends nothing after it'):format(ph),
            J.errored() or ('%s, %d fills, %d zone, %s'):format(tostring(jst), #J.areas(),
                #J.zone(), mmSince(J, since)))
    end

    -- ─── a picture the engine refuses is drawn again a few times, then waits ───
    --
    -- Adds accepted and the fade after them refused: the picture comes back out whole
    -- (map.sweep's refusal client). It used to be drawn again every 1 / rebuildHz for as
    -- long as that lasted -- an add and a removal twice a second, on a clock. Now
    -- PICTURE_TRIES pictures at most, each further apart, and then the blips until the
    -- kind of picture changes -- the sweep setting off.
    local R = newStormClient()
    R.mm.handle = 7
    local rrec = R.record(2, 1000.0, -700.0, 2600.0, 1400.0, -300.0, 1600.0, 600000, 60000,
        2.0)
    rrec.seed = 424242
    ok(R.overlayReady(), 'the refusal client reaches the gate')
    R.tick(2)
    local rAdds = R.mm.adds
    R.mm.refuseMethod['SET_OVERLAY_ALPHA'] = true
    rrec.cx1 = rrec.cx1 + 50.0               -- a new record's geometry: a picture is due
    local function holdTicks(n)
        for _ = 1, n do
            R.now = R.now + 100
            R.env.BR.Loop.step(R.env.BR.Loop.TICK)
        end
    end
    holdTicks(600)
    local tried = R.mm.adds - rAdds
    ok(tried >= 2 and tried <= 8 and #R.areas() == 0 and #R.rings() > 0,
        'a minute of refused fades in a hold is four pictures at most -- not one every half '
            .. 'second -- and the blips carry the map',
        ('%d adds, %d areas, %d rings'):format(tried, #R.areas(), #R.rings()))
    R.mm.refuseMethod['SET_OVERLAY_ALPHA'] = nil
    local rHeld = R.mm.adds
    holdTicks(100)
    ok(R.mm.adds == rHeld and #R.areas() == 0,
        'and once the engine accepts again it still waits for the next change of kind',
        ('%d adds'):format(R.mm.adds - rHeld))
    rrec.tStart = R.now - rrec.tWait
    holdTicks(3)
    ok(#R.dest() == 1 and #R.zone() == 0 and #R.areas() == 1 and #R.rings() == 0
            and R.errored() == nil,
        'which the sweep setting off is: the picture -- the destination alone -- is drawn, and '
            .. 'the blips go',
        R.errored() or ('%d areas, %d zone, %d rings'):format(#R.areas(), #R.zone(),
            #R.rings()))

    -- AND SWITCHING /brstormbisect IS NOT A REFUSAL: back to normal draws the picture at
    -- once, however many times a dev flips it in one hold.
    local X = newStormClient()
    X.mm.handle = 7
    local xrec = X.record(2, 1000.0, -700.0, 2600.0, 1400.0, -300.0, 1600.0, 600000, 60000,
        2.0)
    xrec.seed = 424242
    ok(X.overlayReady(), 'the bisect client reaches the gate')
    X.tick(2)
    local xAreas, back = #X.areas(), 0
    for _ = 1, 6 do
        X.cmds.brstormbisect(nil, { 'mapoff' }, '')
        X.tick(1)
        X.cmds.brstormbisect(nil, { 'normal' }, '')
        X.tick(1)
        if xAreas > 0 and #X.areas() == xAreas then back = back + 1 end
    end
    ok(back == 6 and X.errored() == nil,
        'six round trips through mapoff in one hold draw the picture back six times',
        X.errored() or ('%d of 6'):format(back))
end

-- ---------------------------------------------------------------------------
describe('map.phase1')
do
    -- ═══ PHASE 1 IS CIRCLE 1 ALONE, ON BOTH MAPS, HOLD AND SWEEP (2026-10-04) ═══
    --
    -- Phase 1's zone is the whole map. It used to be in the picture at nothing, fade in
    -- over the hold's last fadeInSec and fade out a second into the sweep: about eleven
    -- seconds of purple over all of Los Santos every match, saying nothing. It is never
    -- drawn now, by the overlay or as a fallback ring. What the bus showed -- circle 1 --
    -- is the whole picture until phase 2's record, and once it is drawn the movie hears
    -- nothing more. Walked from the bus into PLAYING, through the hold's last fadeInSec
    -- and the sweep's first seconds, at the map band's own 100 ms, once on each path.
    local recs = walkRecords(1)
    local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end

    for _, overlay in ipairs({ true, false }) do
        local C = newStormClient()
        local BR = C.env.BR
        local CFG = BR.Config.Storm
        local FADE_MS = (CFG.render.fadeInSec or 10.0) * 1000.0
        local SWEEP_MS = (CFG.overlay.sweepFadeSec or 1.0) * 1000.0
        local path = overlay and 'the overlay shows' or 'the fallback rings show'
        C.mm.handle = overlay and 7 or nil
        local r1 = recs[1]
        local circle1 = BR.StormShape.blob(r1.cx1, r1.cy1, r1.r1, BR.StormUnit(r1.seed, 1))

        --- The worst distance of any point the map shows of `ov` from `shape`.
        local function off(ov, shape)
            local w = 0.0
            for _, p in ipairs(C.shown(ov)) do
                w = math.max(w, math.abs(BR.StormShape.distance(shape, p.x, p.y)))
            end
            return w
        end

        --- What the map shows, if it is circle 1 alone; nil and why when it is not.
        local function circle1Alone()
            if overlay then
                local vis = C.visible()
                if not (#C.areas() == 1 and #vis == 1 and #C.zone() == 0) then
                    return nil, ('%d fills, %d showing, %d zone'):format(#C.areas(), #vis,
                        #C.zone())
                end
                local w, o = off(vis[1], circle1), C.opacity(vis[1])
                if w > 1e-6 or not near(o, CFG.blip.nextAlpha / 255, 0.5 / 255) then
                    return nil, ('a fill %.3e m off circle 1 at %.4f'):format(w, o)
                end
                return vis[1]
            end
            local rings = C.rings()
            if #rings ~= 1 or #C.boxes() ~= 0 then
                return nil, ('%d rings, %d boxes'):format(#rings, #C.boxes())
            end
            local g = rings[1]
            if not (near(g.x, r1.cx1, 1e-6) and near(g.y, r1.cy1, 1e-6)
                    and near(g.r, r1.r1, 1e-6) and g.colour == CFG.blip.nextColour) then
                return nil, ('a ring of %.1f m at %.1f, %.1f in color %s'):format(g.r, g.x,
                    g.y, tostring(g.colour))
            end
            return g
        end

        -- ─── the bus: circle 1, as it always was ───
        BR.State.storm = nil
        BR.State.match.state = BR.MatchState.BUS
        BR.State.me.state = BR.PlayerState.BUS
        BR.State.stormPreview = { cx = r1.cx1, cy = r1.cy1, r = r1.r1, seed = r1.seed }
        C.pedAt = pt(r1.cx1, r1.cy1)
        local ready = (not overlay) or C.overlayReady()
        C.tick(2)
        local bus, busWhy = circle1Alone()
        ok(ready and bus ~= nil and C.errored() == nil,
            ('on the bus %s circle 1 alone, unchanged'):format(path),
            C.errored() or busWhy)

        -- ─── PLAYING: the hold's last fadeInSec and three seconds more, then the sweep ───
        local rec = copy(r1)
        BR.State.match.state = BR.MatchState.PLAYING
        BR.State.me.state = BR.PlayerState.ALIVE
        BR.State.stormPreview = nil
        rec.tStart = C.now - (rec.tWait - (FADE_MS + 3000.0))
        BR.State.storm = rec
        local calls, faded, held = nil, nil, nil
        local bad, badWhere, windowTicks, sweepTicks = 0, nil, 0, 0
        for i = 1, math.floor((FADE_MS + 3000.0 + 3000.0) / 100.0) do
            C.now = C.now + 100
            BR.Loop.step(BR.Loop.TICK)
            local _, _, _, st, msLeft = BR.StormAt(rec, BR.Clock.now())
            if i >= 2 then
                if i == 2 then calls, faded = C.mm.calls, C.mm.faded end
                local shown, why = circle1Alone()
                if i == 2 then held = shown end
                if not shown or shown ~= held then
                    bad = bad + 1
                    badWhere = badWhere or ('tick %d (%s, %.0f ms left): %s'):format(i,
                        tostring(st), msLeft, why or 'circle 1 drawn again')
                end
                if st == BR.StormPhase.SHRINKING then sweepTicks = sweepTicks + 1 end
                local inHold = st == BR.StormPhase.HOLDING and msLeft <= FADE_MS
                local inSweep = st == BR.StormPhase.SHRINKING
                    and rec.tShrink - msLeft <= SWEEP_MS
                if inHold or inSweep then windowTicks = windowTicks + 1 end
            end
        end
        ok(bad == 0 and windowTicks >= (FADE_MS + SWEEP_MS) / 100.0 - 2 and sweepTicks >= 20
                and C.errored() == nil,
            ('through phase 1\'s hold and into its sweep %s circle 1 alone -- the same '
                .. 'one, never a whole-map zone, not even across the eleven seconds it used to '
                .. 'fade in and out'):format(path),
            C.errored() or badWhere or ('%d ticks in the window, %d in the sweep'):format(
                windowTicks, sweepTicks))
        if overlay then
            ok(held ~= nil and off(held, BR.StormTarget(rec)) < 1e-6
                    and C.mm.calls == calls and C.mm.faded == faded,
                'and that fill is phase 1\'s destination, drawn once: the movie hears nothing '
                    .. 'after it -- no alpha write, no add, no removal',
                ('%d calls, %d alpha writes after the picture'):format(
                    C.mm.calls - (calls or 0), C.mm.faded - (faded or 0)))
        end
    end
end

-- ---------------------------------------------------------------------------
describe('map.swap')
do
    -- ═══ A RECORD SWAPPED IN WITHOUT A STORM_SYNC STILL REDRAWS THE RINGS ═══
    --
    -- A join and a match teardown send a SNAPSHOT, and client/state.lua sets S.storm
    -- from it without a STORM_SYNC. Only STORM_SYNC used to take the fallback rings
    -- down, and a sweep draws nothing but its destination's ring when there is none --
    -- so a record swapped in mid-sweep left the last record's destination on the map
    -- until the next hold, and one swapped in mid-hold at the same radius kept both old
    -- rings. The rings follow the record itself now, however it arrived. No overlay
    -- here: the rings are the map.
    local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
    local function ticks(C, n)
        for _ = 1, n do
            C.now = C.now + 100
            C.env.BR.Loop.step(C.env.BR.Loop.TICK)
        end
    end
    --- The rings on the map as "r@x,y", sorted -- what a player sees.
    local function ringsSaid(C)
        local out = {}
        for _, g in ipairs(C.rings()) do
            out[#out + 1] = ('%.0f@%.0f,%.0f'):format(g.r, g.x, g.y)
        end
        table.sort(out)
        return table.concat(out, ' ')
    end
    local function ringClient(intoSweepMs)
        local C = newStormClient()
        C.mm.handle = nil
        local rec = C.record(2, 0.0, 0.0, 2600.0, 300.0, 0.0, 1600.0, 600000, 120000, 2.0)
        rec.seed = 424242
        if intoSweepMs then rec.tStart = C.now - rec.tWait - intoSweepMs end
        C.pedAt = pt(300.0, 0.0)
        return C, rec
    end

    -- ─── mid-sweep: the old destination's ring goes, the new one's comes ───
    local S, srec = ringClient(3000)
    ticks(S, 5)
    local was = ringsSaid(S)
    local swapped = copy(srec)
    swapped.cx1, swapped.r1 = -400.0, 1200.0
    S.env.BR.State.storm = swapped
    ticks(S, 3)
    ok(was == '1600@300,0' and ringsSaid(S) == '1200@-400,0' and S.errored() == nil,
        'a record swapped in mid-sweep without a STORM_SYNC takes the last destination\'s ring '
            .. 'down and draws its own -- the one ring a sweep shows',
        S.errored() or ('%s, then %s'):format(was, ringsSaid(S)))

    -- ─── mid-hold, at the same radius: both rings move ───
    local H, hrec = ringClient(nil)
    ticks(H, 5)
    local held = ringsSaid(H)
    local moved = copy(hrec)
    moved.cx0, moved.cx1, moved.tWait = 200.0, -300.0, 500000
    H.env.BR.State.storm = moved
    ticks(H, 1)
    local first = H.last()
    ticks(H, 2)
    ok(held == '1600@300,0 2600@0,0' and ringsSaid(H) == '1600@-300,0 2600@200,0'
            and H.errored() == nil,
        'and one swapped in mid-hold at the same radius moves both rings onto it',
        H.errored() or ('%s, then %s'):format(held, ringsSaid(H)))
    ok(first and first.endsAt == moved.tStart + moved.tWait,
        'and its countdown goes out on that first tick, as a STORM_SYNC\'s does (#352)',
        first and ('%s against %s'):format(tostring(first.endsAt),
            tostring(moved.tStart + moved.tWait)) or 'nothing sent')
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

        -- BR-PATCH 6 (#393): the main loop asks for the pause menu's Load() only
        -- while one of its three handles is nil, instead of asking IsLoaded() --
        -- three HasScaleformMovieLoaded natives -- on every idle frame. That is
        -- the same behaviour only because Load() itself returns at once when all
        -- three handles exist, so that premise is pinned here as well.
        ok(src:match('BR%-PATCH 6') ~= nil, 'BR-PATCH 6 is marked in the bundle')
        ok(code:match('if pm%._header == nil or pm%._pause == nil or pm%._pauseBG == nil then'
            .. '\n%s*pm:Load%(%)') ~= nil
            and not code:match('if not ScaleformUI%.Scaleforms%._pauseMenu:IsLoaded%(%) then'),
            'the idle loop calls Load() while a pause-menu handle is nil, and no longer '
                .. 'asks IsLoaded() first')
        ok(code:match('function PauseMenu:Load%(%)\n%s*if %(self%._header ~= nil and '
            .. 'self%._pause ~= nil and self%._pauseBG ~= nil%) then return end') ~= nil,
            'which is equivalent because Load() returns at once when all three exist')
    end
end

-- ---------------------------------------------------------------------------
describe('storm.anchor.outcome')
do
    -- ═══ HALF THE MATCHES OPEN IN THE CITY, AND HALF END THERE (#381) ═══
    --
    --   "What I want is 50% in the city and 50% in the county."
    --   "y = 1050. everything below that is city, everything above is county"
    --                                                  -- owner, 2026-10-03
    --
    -- What the owner asked for is where MATCHES open and end -- circle 1's center
    -- and the final zone's -- not where the anchor is. The anchor is the only
    -- thing anchorRegion.cityShare touches, and both circles lean county off it,
    -- so the share is calibrated (config/storm.lua has the measurement) and this
    -- block is what holds the calibration to the code.
    --
    -- ═══ WHY THE SHARES ARE STRAIGHT LINES, WHICH IS WHAT MAKES THIS CHEAP ═══
    --
    -- The share enters a match at exactly one place: the region draw, `rng:float()
    -- < cityShare`, inside BR.PickStormAnchor. The tour before it, and the waypoint,
    -- the POI and the whole storm stream after it, are the same whatever the share.
    -- So a match at ANY share is, bit for bit, the match its draw picked a side for
    -- -- the one forced to the city (share 1) or the one forced to the county
    -- (share 0) -- and over many matches circle 1's city share is
    --
    --     s * (its share in city-forced matches) + (1 - s) * (in county-forced ones)
    --
    -- and the final zone's the same. Four end points, each a property of the tours,
    -- the POIs and the storm, and none of them the knob's. A whole match costs about
    -- 25 ms here (nine zone shapes are built for it), so the final zone's two ends
    -- cannot be measured to a point in a suite that has to stay quick. They are
    -- pinned below from the calibration -- 16,000 whole matches a side through this
    -- same server code -- and this block checks that the code still produces them:
    -- circle 1's ends closely, over 800 seeds (a seed's second and third match
    -- reuse the first one's shapes, so a seed costs about 2 ms), and the final
    -- zone's coarsely, over 24 whole matches a side.
    --
    -- ═══ BY THE OWNER'S LINE, NOT THE CONFIG'S ═══
    --
    -- The outcome is judged by y < 1050 as he said it. A cityMaxY moved anywhere
    -- from 846 to 1080 draws the very same anchors (no POI and no waypoint lies in
    -- that band), so it changes nothing here, and it should not.
    local OWNER_LINE = 1050.0
    -- % city, 16,000 whole matches a side: the 12,000 0.62 was picked on and the
    -- 4,000 it was checked on.
    local CAL = {
        circle1 = { city = 67.62, county = 24.49 },
        final   = { city = 62.67, county = 24.97 },
    }

    local S = newStormServer()
    local env = S.env
    loadInto(env, { 'br_core/server/bus.lua' })
    local BR = env.BR
    S.roster[1] = nil
    -- Three log lines a match over 2,500 matches, and only a scheduler error is
    -- read back (S.errored), so only those are kept.
    env.print = function(line)
        local s = tostring(line)
        if s:find('errored', 1, true) then S.prints[#S.prints + 1] = s end
    end
    env.BR.Broadcast.toMatch = function() end
    BR.Sched.setEnabled('storm.phase', true)
    local rc = BR.Config.Storm.anchorRegion
    local shipped = rc.cityShare
    local horizon = 0

    --- One match through the real bus.lua and storm.lua: planned, circle 1 drawn
    --- at warmup and, with `walk`, played to its last phase. The clock is set from
    --- the seed as the plan and the draw read it, so the same `i` is the same tour
    --- and the same storm whatever the share. The walk starts past wherever the
    --- scheduler has got to, since a phase job that last ran in a later match's
    --- hour would not run again until then -- and nothing a phase draws reads the
    --- clock.
    local function play(i, share, walk)
        rc.cityShare = share
        S.now = 1000000 + i * 3600017
        local m = { id = i, seq = i, state = BR.MatchState.WARMUP }
        S.matches = { m }
        BR.Bus.plan(m)
        BR.Storm.drawFirstCircle(m)
        local o = { ax = m.anchor.x, ay = m.anchor.y,
                    cx = m.stormFirst.cx, cy = m.stormFirst.cy }
        if walk then
            S.now = math.max(S.now, horizon) + 1000
            m.state = BR.MatchState.PLAYING
            BR.Storm.begin(m)
            local last = #BR.Config.Storm.phases
            local guard = 0
            while m.storm and m.storm.phase < last and guard < 64 do
                guard = guard + 1
                local rec = m.storm
                S.now = math.floor(rec.tStart + rec.tWait + rec.tShrink) + 1
                BR.Sched.step(S.now)
            end
            if m.storm and m.storm.phase == last then
                o.fx, o.fy = m.storm.cx1, m.storm.cy1
            end
            horizon = S.now
        end
        BR.Bus.clear(m)
        rc.cityShare = shipped
        return o
    end

    -- ═══ THE MATCH AT THE SHIPPED SHARE IS ITS SIDE'S FORCED MATCH, BIT FOR BIT ═══
    local N = 800
    local c1City, c1County, notItsSide, firstOff = 0, 0, 0, nil
    for i = 381001, 381000 + N do
        local city = play(i, 1.0)
        local county = play(i, 0.0)
        local real = play(i, shipped)
        local arm = (real.ay < rc.cityMaxY) and city or county
        if not (real.ax == arm.ax and real.ay == arm.ay
                and real.cx == arm.cx and real.cy == arm.cy) then
            notItsSide = notItsSide + 1
            firstOff = firstOff or i
        end
        if city.cy < OWNER_LINE then c1City = c1City + 1 end
        if county.cy < OWNER_LINE then c1County = c1County + 1 end
    end
    ok(notItsSide == 0,
        ('at the shipped share, every one of %d matches is the city- or county-forced '
            .. 'match of its own seed, anchor and circle 1 alike'):format(N),
        ('%d differ, first seed %s'):format(notItsSide, tostring(firstOff)))

    -- ═══ CIRCLE 1'S TWO ENDS, THROUGH THE REAL SERVER ═══
    --
    -- 800 seeds put one standard deviation at about 1.6 points on each, so 4.5 is
    -- nearly three of them -- and the seeds are fixed, so this passes or fails every
    -- run.
    local p1, p0 = 100 * c1City / N, 100 * c1County / N
    ok(math.abs(p1 - CAL.circle1.city) <= 4.5 and math.abs(p0 - CAL.circle1.county) <= 4.5,
        'circle 1 still opens in the city as often as the calibration says, '
            .. 'from a city anchor and from a county one',
        ('city-forced %.1f%% (calibrated %.1f), county-forced %.1f%% (calibrated %.1f)')
            :format(p1, CAL.circle1.city, p0, CAL.circle1.county))

    -- ═══ THE FINAL ZONE'S TWO ENDS, COARSELY ═══
    --
    -- 24 whole matches a side is a standard deviation of about nine points, so this
    -- guards against the final zone no longer following the anchor at all -- a walk
    -- that stops short, a zone that always ends in one place -- and is not a
    -- measurement. The lever (city-forced minus county-forced) is what the knob
    -- pulls on; it is 38 points calibrated.
    local M = 24
    local finCity, finCounty, unfinished = 0, 0, 0
    for j = 1, M do
        local i = 391000 + j
        local city = play(i, 1.0, true)
        local county = play(i, 0.0, true)
        if not (city.fy and county.fy) then
            unfinished = unfinished + 1
        else
            if city.fy < OWNER_LINE then finCity = finCity + 1 end
            if county.fy < OWNER_LINE then finCounty = finCounty + 1 end
        end
    end
    local q1, q0 = 100 * finCity / M, 100 * finCounty / M
    ok(unfinished == 0, ('all %d whole matches reach the final phase'):format(2 * M),
        ('%d did not'):format(unfinished))
    ok(math.abs(q1 - CAL.final.city) <= 20.0 and math.abs(q0 - CAL.final.county) <= 20.0
        and q1 - q0 >= 15.0,
        'and the final zone still follows the anchor toward its side',
        ('city-forced %.0f%% (calibrated %.1f), county-forced %.0f%% (calibrated %.1f)')
            :format(q1, CAL.final.city, q0, CAL.final.county))

    -- ═══ THE OUTCOME ═══
    --
    -- At the shipped share, through those lines, circle 1 and the final zone each
    -- land in the city within three points of half. The share that minimizes the
    -- larger miss is about 0.625, where circle 1 runs a point and a half over half
    -- and the final zone a point and a half under: the final zone follows the
    -- anchor less closely than circle 1 does, and one number cannot close both. A
    -- share of 0.5 opens matches in the city 46% of the time and ends them there
    -- 44%, and fails both.
    local function at(ends) return shipped * ends.city + (1 - shipped) * ends.county end
    local c1, fin = at(CAL.circle1), at(CAL.final)
    ok(math.abs(c1 - 50.0) <= 3.0 and math.abs(fin - 50.0) <= 3.0,
        'at the shipped share, circle 1 opens in the city and the final zone ends there '
            .. 'each about half the time',
        ('cityShare %.2f: circle 1 %.1f%%, final zone %.1f%% city'):format(shipped, c1, fin))

    -- And circle 1's from this run's own matches rather than the calibration's, with
    -- the draw integrated out so a seed's luck at it is not in the number: a standard
    -- deviation of about 1.4 points over 800 seeds.
    local own = at({ city = p1, county = p0 })
    ok(math.abs(own - 50.0) <= 4.0,
        "and circle 1's share from these 800 seeds through the real server agrees",
        ('%.1f%% city'):format(own))

    ok(S.errored() == nil, 'with every match run clean', S.errored())
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end

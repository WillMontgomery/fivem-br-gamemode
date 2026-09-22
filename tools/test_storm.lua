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

-- ---------------------------------------------------------------------------
-- The server: the real br_core/server/storm.lua behind the smallest roster,
-- match list and combat surface that can hold it up.
-- ---------------------------------------------------------------------------

--- @return table  { env, tick(), place(x, y), hurts(x, y), errored() }
local function newStormServer()
    local env = newSandbox()
    local S = { now = 1000000, roster = {}, out = {}, prints = {},
                matches = {}, bled = {}, defeated = {}, sent = {} }

    env.GetGameTimer = function() return S.now end
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        S.prints[#S.prints + 1] = table.concat(parts, ' ')
    end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetPlayerName    = function(s) return 'P' .. tostring(s) end
    env.GetHashKey       = function(s) return #tostring(s) end
    env.RegisterCommand  = function() end
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

    -- The HUD envelope is the only wire this file speaks on.
    env.TriggerEvent = function(name, key, payload)
        if name == 'br:ui:sendLocal' and key == env.BR.Nui.STORM then
            C.envelopes[#C.envelopes + 1] = payload
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
    -- The sky is a CLAIM made through client/world.lua, which this suite does
    -- not load: stubbed rather than stood up, because nothing here asserts on
    -- the weather and the resolver has its own suite.
    env.BR.World = env.BR.World or {}
    env.BR.World.want = function() end
    env.BR.Sfx = { play = function(cue) C.sfx[#C.sfx + 1] = cue end }

    loadInto(env, { 'br_core/client/storm.lua' })

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
---                          path), or go straight to PLAYING (the path that
---                          shipped before it, byte for byte -- nothing in
---                          BR.Storm.begin's seed-and-draw fallback changed)
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
    -- A nested next circle must leave the damaged set EXACTLY as it is today,
    -- and "exactly" is the word that needed a grid rather than a handful of
    -- points. The union of a circle with a circle inside it IS the outer circle,
    -- so every point on the map has to get the same verdict from the new rule
    -- that `BR.Dist(e.pos.x, e.pos.y, cx, cy) <= r + margin` gave it -- inside
    -- the inner circle, in the annulus between them, in the cushion, and far out
    -- in the sea.
    --
    -- A change that only looked right on a Venn diagram would pass every other
    -- block in this file and fail here, which is the point of putting it first.
    local S = newStormServer()
    local CX, CY, R = 0.0, 0.0, 1000.0
    -- Nested with room to spare: the target's rim sits 300m inside the current
    -- one, so the annulus between them is wide enough to be sampled.
    S.record(2, CX, CY, R, 300.0, 0.0, 400.0, 600000, 60000, 2.0)
    local MARGIN = 10.0   -- a HOLDING phase pays the base cushion and no travel

    -- THE OLD RULE, SPELLED OUT RATHER THAN CALLED. `BR.Dist(...) <= r + margin`
    -- meant SAFE, so the point was billed exactly when that was false.
    local function billedByTheCircleRule(x, y)
        return (math.sqrt((x - CX) * (x - CX) + (y - CY) * (y - CY))
                > R + MARGIN)
    end

    local checked, wrong, firstWrong = 0, 0, nil
    for x = -1250, 1250, 125 do
        for y = -1250, 1250, 125 do
            checked = checked + 1
            if S.hurts(x + 0.0, y + 0.0)
               ~= billedByTheCircleRule(x + 0.0, y + 0.0) then
                wrong = wrong + 1
                firstWrong = firstWrong or ('(%d, %d)'):format(x, y)
            end
        end
    end
    ok(S.errored() == nil, 'the damage tick runs clean across the sweep',
        S.errored())
    ok(checked == 441, 'the sweep covers the grid it claims to', checked)
    ok(wrong == 0,
        'a nested next circle leaves the damaged set exactly as the circle rule '
            .. 'left it, at every point of a 441-point sweep',
        firstWrong and ('first disagreement at ' .. firstWrong) or nil)

    -- AND THE THREE POINTS BY NAME, so a failure above says something even if
    -- the grid arithmetic is what broke.
    ok(S.hurts(0.0, 0.0) == false, 'the middle of both circles is safe')
    ok(S.hurts(800.0, 0.0) == false,
        'the annulus between the two rims is safe -- it is inside the current '
            .. 'circle, which the union contains')
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
    -- r 500 each, centres 900 apart: a proper overlap with a narrow lens.
    S.record(2, 0.0, 0.0, 500.0, 900.0, 0.0, 500.0, 600000, 60000, 2.0)

    ok(S.hurts(1300.0, 0.0) == false,
        'a player who got to the new destination early is SAFE there, where the '
            .. 'circle rule billed them 800m outside')
    ok(S.hurts(0.0, 0.0) == false, 'and the current circle is still safe')
    ok(S.hurts(450.0, 0.0) == false,
        'and the lens where the two overlap is safe from both directions')

    -- OUTSIDE BOTH IS STILL OUTSIDE. The union adds ground, it does not stop
    -- being a boundary: a point off the side of the pair, inside neither disc,
    -- is billed exactly as it always was.
    ok(S.hurts(0.0, 700.0) == true,
        'off the side of the pair, inside neither circle, still hurts')
    ok(S.hurts(1400.0, 900.0) == true, 'and so does past the far one')

    -- THE WHOLE PLANE, AGAINST THE GEOMETRY. The predicate is "inside one of the
    -- two discs, or within the cushion of one of them", which is the signed
    -- distance to the union written out by hand -- an independent spelling of
    -- the rule rather than a call to the function under test.
    local MARGIN = 10.0
    local checked, wrong, firstWrong = 0, 0, nil
    for x = -800, 2200, 150 do
        for y = -1000, 1000, 125 do
            local d1 = math.sqrt(x * x + y * y) - 500.0
            local d2 = math.sqrt((x - 900.0) * (x - 900.0) + y * y) - 500.0
            local expect = math.min(d1, d2) > MARGIN
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
    local S = newStormServer()
    S.record(2, 0.0, 0.0, 400.0, 1200.0, 0.0, 300.0, 600000, 60000, 2.0)

    ok(S.hurts(1505.0, 0.0) == false,
        'five metres outside the FAR island is inside the cushion')
    ok(S.hurts(1525.0, 0.0) == true,
        'and twenty-five metres outside it is not -- the cushion is ten metres, '
            .. 'not a licence')
    ok(S.hurts(-405.0, 0.0) == false,
        'the same five metres outside the CURRENT circle is still safe, exactly '
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
    T.record(2, 0.0, 0.0, 2000.0, 0.0, 0.0, 1000.0, 1000.0, 10000.0, 2.0)
    T.at(6000); ok(T.hurts(1550.0, 0.0) == false,
        'fifty metres outside a wall doing 100 m/s is inside the moving cushion')
    T.at(6000); ok(T.hurts(1650.0, 0.0) == true,
        'a hundred and fifty metres outside it is not')
    T.at(6000); ok(T.hurts(1570.0, 0.0) == false,
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
    C.record(2, 0.0, 0.0, 500.0, 900.0, 0.0, 500.0, 600000, 60000, 4.0)

    local function edgeAt(x, y)
        C.pedAt = pt(x, y)
        C.tick(2)
        local e = C.last()
        return e and e.edgeDistance
    end

    ok(near(edgeAt(0.0, 0.0), -500.0, 0.5),
        'the middle of the current circle reads 500m inside',
        edgeAt(0.0, 0.0))
    ok(near(edgeAt(900.0, 0.0), -500.0, 0.5),
        'and the middle of the NEXT circle reads 500m inside too, where the '
            .. 'circle rule read 400m OUTSIDE', edgeAt(900.0, 0.0))
    ok(near(edgeAt(450.0, 0.0), -50.0, 0.5),
        'the lens between them reads inside from the nearer rim',
        edgeAt(450.0, 0.0))
    ok(near(edgeAt(0.0, 700.0), 200.0, 0.5),
        'and off the side of the pair, inside neither, it reads positive',
        edgeAt(0.0, 700.0))
    ok(C.errored() == nil, 'the client storm callbacks run clean', C.errored())

    -- THE SIGN IS THE PART THE GRADE AND THE SKY READ, so it is asserted as a
    -- sign rather than only as a magnitude, on a sweep that crosses both discs
    -- and the gap. A nested-only implementation gets the left half of this right
    -- and the right half backwards.
    local wrongSign, firstWrong = 0, nil
    for x = -800, 1800, 100 do
        local d1 = math.abs(x) - 500.0
        local d2 = math.abs(x - 900.0) - 500.0
        local expectInside = math.min(d1, d2) < 0.0
        local got = edgeAt(x + 0.0, 0.0)
        if (got ~= nil and got < 0.0) ~= expectInside then
            wrongSign = wrongSign + 1
            firstWrong = firstWrong or tostring(x)
        end
    end
    ok(wrongSign == 0,
        'and the sign is negative inside EITHER circle and positive outside '
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
    C.pedAt = pt(1590.0, 0.0)
    C.frame()
    local moved = C.last() and C.last().edgeDistance
    ok(near(held, 200.0, 0.5),
        'the tick band measures 200m from the NEXT circle, not 1100m from the '
            .. 'current one', tostring(held))
    ok(near(moved, 190.0, 0.5),
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

    -- ═══ AND IT BARELY EVER CHANGES ITS MIND, WHICH IS THE COST OF DECIDING
    --     PER FRAME ═══
    --
    -- A renderer chosen from the shape can in principle swap under the player
    -- mid-phase, and a wall that changes texture while somebody is looking at it
    -- is exactly the class of thing that gets reported as a render bug. Sampled
    -- across a whole phase: a NESTED phase never swaps -- the target is inside the
    -- current circle from the first frame to the last -- and a BREAKOUT swaps once,
    -- at the very end of the sweep, where the shrinking circle finally swallows the
    -- target and both renderers are describing the same ring anyway.
    local function discsAcross(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs)
        local E = newStormClient()
        local SS = E.env.BR.StormShape
        local ei = E.env.BR.Config.Storm.render.edgeInset
        local rec = E.record(phase, cx0, cy0, r0, cx1, cy1, r1, waitMs, shrinkMs, 2.0)
        local flips, prev, total = 0, nil, waitMs + shrinkMs
        for k = 0, 400 do
            local sx, sy, sr = E.env.BR.StormAt(rec, rec.tStart + total * (k / 400))
            local n = #SS.inset(
                SS.union2(sx, sy, sr, rec.cx1, rec.cy1, rec.r1), ei).discs
            if prev ~= nil and n ~= prev then flips = flips + 1 end
            prev = n
        end
        return flips, prev
    end

    local nFlips, nEnd = discsAcross(2, 0, 0, 2600, 400, 0, 1600, 120000, 120000)
    ok(nFlips == 0 and nEnd == 1,
        'a nested phase is one cylinder from its first frame to its last -- the '
            .. 'renderer never swaps under the player',
        ('%d swaps, ends on %d disc(s)'):format(nFlips, nEnd))

    local bFlips, bEnd = discsAcross(4, 0, 0, 950, 1350, 0, 520, 75000, 187500)
    ok(bFlips == 1 and bEnd == 1,
        'and a breakout swaps exactly once, at the end of the sweep where the '
            .. 'union collapses and both renderers draw the same ring',
        ('%d swaps, ends on %d disc(s)'):format(bFlips, bEnd))

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
    C.record(2, 0.0, 0.0, 200.0, 360.0, 0.0, 200.0, 600000, 60000, 4.0)
    C.env.BR.Storm.wallStyle = 'columns'
    C.pedAt = pt(0.0, 0.0)
    C.frame()

    local SS = C.env.BR.StormShape
    local inset = C.env.BR.Config.Storm.render.edgeInset
    local want = SS.inset(SS.union2(0.0, 0.0, 200.0, 360.0, 0.0, 200.0), inset)

    ok(C.errored() == nil, 'the column renderer runs clean on a union',
        C.errored())
    ok(#C.markers > 40, 'and draws a wall', #C.markers)

    -- EVERY MARKER IS ON THE UNION'S BOUNDARY, AND THAT ONE TEST CARRIES TWO
    -- CLAIMS. A boundary point of a union sits on one circle and outside or on
    -- the other, so the signed distance to the union is zero there. A marker on
    -- an INTERIOR arc -- the half of each circle the other one swallowed -- would
    -- be strictly inside the other disc and come out NEGATIVE. So this rules out
    -- both a wall in the wrong place and a wall drawn through the middle of the
    -- safe zone.
    local worst, worstAt = 0.0, nil
    for _, m in ipairs(C.markers) do
        local d = math.abs(SS.distance(want, m.x, m.y))
        if d > worst then worst, worstAt = d, ('%.1f, %.1f'):format(m.x, m.y) end
    end
    ok(worst < 1e-6,
        'every column stands on the boundary of the INSET union -- none in the '
            .. 'lens, none off the shape',
        ('worst %.6f m at %s'):format(worst, tostring(worstAt)))

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
    D.record(2, 0.0, 0.0, 350.0, 100.0, 0.0, 150.0, 600000, 60000, 4.0)
    D.env.BR.Storm.wallStyle = 'columns'
    D.pedAt = pt(0.0, 0.0)
    D.frame()
    local off = 0.0
    for _, m in ipairs(D.markers) do
        off = math.max(off, math.abs(
            math.sqrt(m.x * m.x + m.y * m.y) - (350.0 - inset)))
    end
    ok(#D.markers > 40 and off < 1e-6,
        'and a nested next circle draws the current circle exactly, edgeInset '
            .. 'inside the logical edge as it always did',
        ('%d markers, worst %.6f m off %.1f'):format(#D.markers, off,
            350.0 - inset))
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
    C.record(4, 0.0, 0.0, R0, SEP, 0.0, R1, 600000, 60000, 2.2)
    C.env.BR.Storm.wallStyle = 'columns'

    local shape = SS.inset(SS.union2(0.0, 0.0, R0, SEP, 0.0, R1), rr.edgeInset)
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
    local function onFarIsland(m)
        return math.sqrt((m.x - SEP) ^ 2 + m.y ^ 2)
             < math.sqrt(m.x * m.x + m.y * m.y)
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
    D.record(2, 0.0, 0.0, 1600.0, 400.0, 0.0, 950.0, 600000, 60000, 1.25)
    D.env.BR.Storm.wallStyle = 'columns'
    -- Far enough OUTSIDE that the window widens past the ceiling rather than
    -- resting on the rr.segments floor: visArc is twice the distance out, so 600m
    -- outside the inset rim is where `want` first reaches maxDraw.
    D.pedAt = pt(2200.0, 0.0)
    D.frame()
    local nested = SS.inset(SS.union2(0.0, 0.0, 1600.0, 400.0, 0.0, 950.0),
        rr.edgeInset)
    local nslots = math.max(rr.segments,
        math.floor(SS.perimeter(nested) / rr.slotArc + 0.5))
    local nds = SS.perimeter(nested) / nslots
    local worstRing = 0.0
    for _, m in ipairs(D.markers) do
        worstRing = math.max(worstRing, math.abs(
            math.sqrt(m.x * m.x + m.y * m.y) - (1600.0 - rr.edgeInset)))
    end
    ok(nslots > rr.maxDraw and #D.markers == rr.maxDraw,
        'a nested phase-2 circle is windowed at exactly maxDraw, as it always was',
        ('%d slots, %d drawn'):format(nslots, #D.markers))
    ok(worstRing < 1e-6,
        'and every one of its columns is on the inset circle',
        ('worst %.6f m off %.1f'):format(worstRing, 1600.0 - rr.edgeInset))
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

    -- THE FADE IS READ FROM THE REAL CONFIG, NOT ASSUMED. The shipping path is the
    -- banded one, so every assertion below is against banded geometry -- and the
    -- band count is what a quad's poly cost is a multiple of, so the budget and
    -- count assertions all carry it rather than hard-coding two triangles a quad.
    -- Reading it here means raising `fade.bands` retunes this suite instead of
    -- turning it red.
    local fd = sp.fade or {}
    local nBands = math.max(1, math.floor(fd.bands or 3))
    local quadPolys = 2 * nBands

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

    local monotone, lowest = true, byBand[1]
    for bi = 2, nBands do
        if byBand[bi] > byBand[bi - 1] then monotone = false end
    end
    ok(monotone and byBand[nBands] < lowest,
        'and it falls as the wall rises, bottom band strongest -- which is the fade '
            .. 'the height depends on',
        table.concat(byBand, ' > '))

    -- THE RAMP'S OWN ARITHMETIC, against the config rather than against a literal:
    -- the bottom band samples the ramp at its own centre, so at half the phase-1
    -- fade its alpha is alpha * 0.5 * the ramp there.
    local function rampAt(t)
        local a0 = (fd.baseAlpha or 1.0)
        local a1 = (fd.topAlpha or 0.0)
        return a0 + (a1 - a0) * t
    end
    local wantBottom = rr.alpha * 0.5 * rampAt(0.5 / nBands)
    ok(byBand[1] ~= nil and math.abs(byBand[1] - wantBottom) <= 2.0,
        'and the whole ramp is scaled by the phase-1 fade-in clock, as the map ring '
            .. 'is: half strength halfway through the hold\'s last seconds',
        ('bottom band %d against %.1f'):format(byBand[1] or -1, wantBottom))

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
    D.record(4, 0.0, 0.0, R0, SEP, 0.0, R1, 600000, 60000, 2.2)
    D.pedAt = pt(300.0, 0.0, 30.0)
    D.frame()
    local dq = quadsOf(D)

    local function island(p)
        return (math.sqrt((p.x - SEP) ^ 2 + p.y ^ 2)
            < math.sqrt(p.x * p.x + p.y * p.y)) and 2 or 1
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
    V.record(3, 0.0, 0.0, 400.0, 500.0, 0.0, 400.0, 600000, 60000, 1.7)
    V.pedAt = pt(250.0, 0.0, 30.0)
    V.frame()
    local venn = SS.inset(SS.union2(0.0, 0.0, 400.0, 500.0, 0.0, 400.0),
        rr.edgeInset)
    local offShape, offAt = 0.0, nil
    for _, qd in ipairs(quadsOf(V)) do
        for _, p in ipairs({ qd.a, qd.b }) do
            local d = math.abs(SS.distance(venn, p.x, p.y))
            if d > offShape then offShape, offAt = d, ('%.1f,%.1f'):format(p.x, p.y) end
        end
    end
    ok(V.errored() == nil and #V.polys > 0, 'the strip runs clean on a Venn union',
        V.errored())
    ok(offShape < 1e-6,
        'and every corner of it stands on the boundary of the INSET union: none in '
            .. 'the lens, none off the shape',
        ('worst %.9f m at %s'):format(offShape, tostring(offAt)))
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
    local function excursionOn(phase, r0, r1, sep, samples)
        local E = newStormClient()
        E.record(phase, 0.0, 0.0, r0, sep, 0.0, r1, 600000, 60000, 2.0)
        E.pedAt = pt(r0 * 0.5, 0.0, 30.0)
        E.frame()
        local zone = SS.union2(0.0, 0.0, r0, sep, 0.0, r1)
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
            E.record(2, 0.0, 0.0, ph.radius, 0.0, 0.0, ph.radius * 0.5,
                600000, 60000, 2.0)
            E.pedAt = pt(0.0, 0.0, 30.0)
            E.frame()
            local r = ph.radius - rr.edgeInset
            for _, qd in ipairs(quadsOf(E)) do
                local mx, my = (qd.a.x + qd.b.x) * 0.5, (qd.a.y + qd.b.y) * 0.5
                local sag = r - math.sqrt(mx * mx + my * my)
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
    local SS = newStormClient().env.BR.StormShape

    local z = SS.union2(0.0, 0.0, 40.0, 55.0, 0.0, 0.0)
    ok(#(z.discs or {}) == 1 and #SS.components(z) == 1,
        'a zero-radius target is not a disc and not a component: the zone is the '
            .. 'wall circle alone',
        ('%d discs, %d components'):format(#(z.discs or {}), #SS.components(z)))
    ok(near(SS.distance(z, 55.0, 0.0), 15.0, 1e-9),
        'and the point itself reads 15m OUTSIDE that circle, which is where it is',
        SS.distance(z, 55.0, 0.0))

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
    E.record(8, 0.0, 0.0, 40.0, 55.0, 0.0, 0.0, 600000, 60000, 6.7)
    E.pedAt = pt(55.0, 0.0)
    E.tick(2)
    local e = E.last() and E.last().edgeDistance
    ok(near(e, 15.0, 0.5),
        'and the HUD reads 15m OUTSIDE there, agreeing with the ledger rather '
            .. 'than sheltering them in a one-metre disc',
        tostring(e))

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
    -- BR.Storm.begin's seed-and-draw is still there, untouched, as the fallback for
    -- the routes that never had a warmup -- so the code that shipped before #327 is
    -- still executable, and `walkMatch(anchor, false)` IS it. Both runs hold the
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
    local C = newStormClient()
    local env = C.env
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
        C.frame()
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

    -- PLAYING IS THE REAL WALL'S, AND THE PREVIEW MUST NOT BE BESIDE IT.
    ok(#wallClient(MS.PLAYING, false).polys == 0,
        'PLAYING draws no preview wall -- the record draws its own')

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
    local worstR, nq = 0.0, 0
    for _, qd in ipairs(quadsOf(C)) do
        for _, v in ipairs({ qd.a, qd.b }) do
            nq = nq + 1
            local d = math.sqrt((v.x - 400.0) ^ 2 + v.y ^ 2)
            local off = math.abs(d - (2600.0 - (rr.edgeInset or 0.0)))
            if off > worstR then worstR = off end
        end
    end
    ok(nq > 0 and worstR < 1e-6,
        'centred on circle 1, at its radius less the edgeInset every wall in this '
            .. 'file pays',
        ('%d corners, worst %.9f m off'):format(nq, worstR))

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
    local pfd = psp.fade or {}
    local pBandsN = math.max(1, math.floor(pfd.bands or 3))
    local pAlpha = rr.alpha * (rr.previewAlpha or 0.5)
    local pa0 = pAlpha * (pfd.baseAlpha or 1.0)
    local pa1 = pAlpha * (pfd.topAlpha or 0.0)
    local wantP = math.floor(pa0 + (pa1 - pa0) * (0.5 / pBandsN) + 0.5)
    local pBands = quadsOf(C)[1] and quadsOf(C)[1].bands
    ok(pBands and #pBands == pBandsN and pBands[1].alpha == wantP
        and pBands[1].alpha < rr.alpha,
        'and fainter than a wall that is actually doing something -- previewAlpha '
            .. 'scales the whole ramp, band for band',
        ('bottom band %s against %d, live wall full strength %d'):format(
            pBands and tostring(pBands[1].alpha), wantP, rr.alpha))
    ok(C.errored() == nil, 'the preview wall runs clean', C.errored())

    -- AND IT SAYS NOTHING TO THE INTERFACE. The HUD storm card is driven off the
    -- record; a preview that pushed an envelope would put a phase counter and a
    -- "storm closing" clock on screen for a storm that does not exist.
    ok(C.last() == nil, 'and no HUD envelope is pushed for a preview')
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

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end

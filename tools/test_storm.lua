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
                prints = {}, cmds = {}, sfx = {}, pedAt = pt(0.0, 0.0),
                handlers = {} }

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
    -- ═══ THE RENDERER IS CHOSEN BY THE SHAPE, NOT BY A GLOBAL DEFAULT ═══
    --
    -- Both global defaults were wrong for half the match. 'solid' is one
    -- DrawMarker type 1 -- a cylinder, and therefore a circle by construction --
    -- so left as the default after #328 it paints a curtain straight through a
    -- player standing safely in the next circle. 'columns' draws any shape but is
    -- capped at maxDraw 80, so on the phases that NEST (60 to 90 percent of them)
    -- it drew 15 percent of the ring at phase 1, 24 at phase 2, 40 at phase 3 and
    -- 64 at phase 4: a curtain stopping in mid-air with no wall behind it, for
    -- roughly 15 minutes of a 22 minute match. The owner has reacted to exactly
    -- that once already, when a 300m curtain vanishing past 300m "read as a render
    -- bug".
    --
    -- union2 routes the nested case through StormShape.circle, so the NUMBER OF
    -- DISCS in the shape exactly identifies "this union is a single circle". One
    -- disc draws solid, two draw columns, decided per frame.
    local C = newStormClient()
    ok(C.env.BR.Storm.wallStyle == nil,
        'there is no global default renderer: nil means ask the shape',
        tostring(C.env.BR.Storm.wallStyle))

    -- A NESTED PHASE GETS THE CYLINDER IT HAD BEFORE 2026-09-21, and gets it at
    -- the inset radius, which is the one number that made this a regression
    -- rather than a preference.
    local inset = C.env.BR.Config.Storm.render.edgeInset
    C.record(2, 0.0, 0.0, 350.0, 100.0, 0.0, 150.0, 600000, 60000, 4.0)
    C.pedAt = pt(0.0, 0.0)
    C.frame()
    ok(#C.markers == 1,
        'a nested phase is ONE cylinder -- the whole ring, not 64 percent of it',
        #C.markers)
    local m = C.markers[1]
    ok(m ~= nil and near(m.x, 0.0, 1e-9) and near(m.y, 0.0, 1e-9)
        and near(m.sx, (350.0 - inset) * 2.0, 1e-9),
        'centred on the circle and edgeInset inside the logical edge, exactly as '
            .. 'it was on 2026-08-03',
        m and ('%.3f, %.3f, scale %.3f'):format(m.x, m.y, m.sx))

    -- AND A UNION GETS THE WALK, because no cylinder can draw two islands.
    C.record(2, 0.0, 0.0, 200.0, 360.0, 0.0, 200.0, 600000, 60000, 4.0)
    C.frame()
    ok(#C.markers > 40,
        'while a union that no cylinder can describe gets the column walk',
        #C.markers)

    -- /brwallstyle STILL OVERRIDES IT, AND CYCLES BACK TO AUTOMATIC. The A/B is
    -- how the column geometry gets judged on real hardware and it is the one
    -- command that puts a bad night back on known ground without a deploy -- and
    -- with only two states there would be no way back to the shape's own choice
    -- once a session had typed it.
    ok(C.cmds.brwallstyle ~= nil, '/brwallstyle is still registered')
    C.cmds.brwallstyle()
    ok(C.env.BR.Storm.wallStyle == 'solid', 'and forces the single cylinder',
        tostring(C.env.BR.Storm.wallStyle))
    C.cmds.brwallstyle()
    ok(C.env.BR.Storm.wallStyle == 'columns', 'then forces the boundary walk',
        tostring(C.env.BR.Storm.wallStyle))
    C.cmds.brwallstyle()
    ok(C.env.BR.Storm.wallStyle == nil, 'then hands the choice back to the shape',
        tostring(C.env.BR.Storm.wallStyle))

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
    local C = newStormClient()
    C.record(2, 0.0, 0.0, 200.0, 360.0, 0.0, 200.0, 600000, 60000, 4.0)
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

    ok(#wallClient(MS.BUS, false).markers > 0,
        'the island is gone and the bus is flying, so there is a wall')
    ok(#wallClient(MS.BUS, true).markers == 0,
        'the island is still the world, so there is not -- even though the match '
            .. 'state says BUS')
    ok(#wallClient(MS.WARMUP, true).markers == 0,
        'and standing on the pad, with the island still the world, there is nothing')

    -- THE GATE IS THE WORLD AND NOT THE FLIGHT, and this is the assertion that
    -- says which. "From when the San Andreas map is loaded" is the owner's
    -- condition, so a warmup in which the mainland is somehow already the world
    -- gets the wall -- the wall follows the ground it is standing on, not the state
    -- machine. The game cannot currently reach that: ipl.lua's wantIsland only
    -- releases the island at BUS or PLAYING. Pinned anyway, because the tempting
    -- "simplification" is to replace the whole announcement with a BUS test, and
    -- that is the thing #327 specifically moved away from.
    ok(#wallClient(MS.WARMUP, false).markers > 0,
        'and a warmup that somehow already has Los Santos loaded gets the wall -- '
            .. 'the condition is the map, not the phase of the match')

    -- THE FALLBACK, AND IT ONLY ANSWERS WHEN NOBODY ELSE DOES. If br_environment
    -- never speaks -- it is not running, or has not reached its first
    -- announcement -- the match state answers instead, because a preview is not
    -- worth a hard dependency between two resources.
    ok(#wallClient(MS.BUS, nil).markers > 0,
        'with br_environment silent the BUS state alone raises the wall')
    ok(#wallClient(MS.WARMUP, nil).markers == 0,
        'and silence during warmup still draws nothing')

    -- PLAYING IS THE REAL WALL'S, AND THE PREVIEW MUST NOT BE BESIDE IT.
    ok(#wallClient(MS.PLAYING, false).markers == 0,
        'PLAYING draws no preview wall -- the record draws its own')

    -- ═══ IT IS THE SHIPPING RENDERER, HANDED A CIRCLE AND A LOWER ALPHA ═══
    --
    -- One disc means one cylinder, which is the wall the owner chose for a circle
    -- on 2026-08-03 and the only one that holds up at bus altitude. The assertions
    -- are the numbers that prove it went through drawWall rather than through a
    -- second renderer written beside it: the edgeInset the column path once failed
    -- to pay, the fixed base below sea level, and the alpha.
    local C = wallClient(MS.BUS, false)
    local rr = C.env.BR.Config.Storm.render
    ok(#C.markers == 1, 'a circle draws ONE marker, not a colonnade', #C.markers)
    local m = C.markers[1]
    ok(m and near(m.x, 400.0, 0.001) and near(m.y, 0.0, 0.001),
        'centred on circle 1')
    ok(m and near(m.sx, (2600.0 - (rr.edgeInset or 0.0)) * 2.0, 0.001),
        'at circle 1\'s diameter less the edgeInset every wall in this file pays',
        m and tostring(m.sx))
    ok(m and near(m.z, -100.0, 0.001),
        'glued to the world below sea level, not hung off the camera')
    ok(m and m.a == math.floor(rr.alpha * (rr.previewAlpha or 0.5)),
        'and fainter than a wall that is actually doing something',
        m and tostring(m.a))
    ok(C.errored() == nil, 'the preview wall runs clean', C.errored())

    -- AND IT SAYS NOTHING TO THE INTERFACE. The HUD storm card is driven off the
    -- record; a preview that pushed an envelope would put a phase counter and a
    -- "storm closing" clock on screen for a storm that does not exist.
    ok(C.last() == nil, 'and no HUD envelope is pushed for a preview')
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end

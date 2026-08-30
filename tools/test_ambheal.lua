-- Unit tests for healing in the back of an ambulance (owner, 2026-08-28).
--
-- ═══ WHY THIS IS ITS OWN SUITE ═══
--
-- Four of the owner's rules are effectively untestable in the game and expensive
-- to get wrong, and they are the four this file exists for:
--
--   THE DOORS. "Healing should be done with the rear doors open only." Producing
--   the failure in a match means finding an ambulance whose rear doors are shut,
--   which is every ambulance in Los Santos, and then proving that nothing
--   happened -- which looks identical to the prompt simply not being implemented.
--
--   THE ARBITRATION. "only one heal per ambulance at a time." Two players have
--   to be in one match, at one van, pressing within a few frames of each other.
--   That is a scheduled playtest to observe once, and the interesting outcome
--   (both got in) is the one that only happens under a race.
--
--   THE PARTIAL. "Interrupting keeps what you healed so far." The wrong
--   implementation -- one lump at the end -- is INDISTINGUISHABLE from the right
--   one on any heal that runs to completion, which is most of them. It shows up
--   only on an interrupt, and only as a number the player has no way to verify.
--
--   THE DEATH. "if someone shoots me to death while in the ambulance healing, I
--   should still take damage and die completely." Staging it means a second
--   player shooting a stationary target through an open door on a fifteen-second
--   clock, and a bad outcome is a stuck ped, which is the kind of thing that
--   ends a playtest round rather than producing a note.
--
-- ═══ WHAT IS NOT HERE, AND WHERE IT IS ═══
--
-- THE MORTALITY PROOF IS IN tools/test_client.lua, deliberately, and this is the
-- most important sentence in this file. A healing player is killable because
-- client/natives.lua's `wantInvincible` latch is derived from the player state
-- and the match state and NOTHING ELSE -- there is no term in it for a vehicle,
-- an attach or a subsystem. That is a fact about natives.lua, so it is asserted
-- against the real natives.lua, in the suite that already drives it frame by
-- frame ('AN ALIVE PLAYER IN A PLAYING MATCH IS MORTAL'). The same block also
-- refuses SetPlayerInvincible, SetEntityInvincible and SetEntityProofs anywhere
-- in client/ambheal.lua.
--
-- What IS here is the half of that requirement this feature owns: that a dying
-- player's claim is released, that no more health is issued to them, and that
-- nothing in the heal ever writes a player state -- because a state write is the
-- one thing that could reach the latch from over here.

local fakeTime = 0
function GetGameTimer() return fakeTime end

local RES = 'resources/[fivem-royale]/'
local ROOT = RES .. 'br_lib/'
local function loadAt(root, f)
    local chunk, err = loadfile(root .. f)
    if not chunk then
        print('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local function load(f) loadAt(ROOT, f) end
--- A br_core module, by its path under resources/[fivem-royale]/.
local function loadCore(f) loadAt(RES, f) end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',        -- BR.Clamp and BR.Dist, which the solver is built on
    'shared/protocol.lua',   -- BR.Net, for the handlers driven below
    'config/match.lua',      -- BR.Config.Combat.healthAudit: the excuse windows
    'config/overrides.lua',
    'config/storm.lua',
    'config/map.lua',
    'config/loot.lua',
    'config/fuel.lua',
    'config/rescue.lua',     -- the stretcher, the models and the camera numbers
    'config/ambheal.lua',
    'shared/health_solve.lua',
    'shared/ambheal_solve.lua',
}) do load(f) end

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

local A = BR.Config.AmbHeal

-- ---------------------------------------------------------------------------
describe('config')
do
    -- THE STRETCHER IS NOT A COPY. If somebody ever pastes the six numbers into
    -- config/ambheal.lua, the two features start drifting the first time the
    -- owner re-surveys with /brattach -- and the symptom is a body in the wrong
    -- place in one of them, which nobody would connect to the other.
    local S = BR.Config.AmbHeal.stretcher()
    local R = BR.Config.Rescue.stretcher
    ok(S == R,
        'the stretcher IS BR.Config.Rescue.stretcher -- the same table, not a '
            .. 'copy of its numbers')
    ok(S.pose ~= nil and S.pose.dict == R.pose.dict,
        'including the pose, which is the seventh number the other six were '
            .. 'measured against')

    ok(BR.Config.AmbHeal.models() == BR.Config.Rescue.models,
        'and "what counts as an ambulance" is one list, shared with the rescue')
    ok(BR.Config.AmbHeal.label() == BR.Config.Rescue.blip.label,
        'and the plate\'s noun is the word already on the map for that vehicle',
        BR.Config.AmbHeal.label())

    -- THE OWNER'S FIFTEEN SECONDS, AND HIS FULL HEAL.
    ok(A.durationMs == 15000, 'fifteen seconds, the owner\'s number', A.durationMs)
    ok(A.healTo == 100, 'to full', A.healTo)

    -- ═══ NO INVINCIBILITY KNOB, AND THAT IS AN ASSERTION RATHER THAN AN
    --     OBSERVATION ═══
    --
    -- config/rescue.lua has a whole section arguing about what may kill the
    -- passenger. This config must not grow one: the answer here is "everything,
    -- exactly as normal", and any key that admits otherwise is the beginning of
    -- the requirement being lost.
    for _, k in ipairs({ 'proofs', 'invincible', 'godmode', 'tyresBulletproof' }) do
        ok(A[k] == nil,
            ('config/ambheal.lua has no `%s` -- a healing player is mortal and '
                .. 'there is no knob that says otherwise'):format(k))
    end
end

-- ---------------------------------------------------------------------------
describe('solver.ramp')
do
    local P, T = BR.AmbHealSolve.progress, BR.AmbHealSolve.target

    ok(P(1000, 1000, 15000) == 0.0, 'a heal starts at zero')
    ok(P(1000, 8500, 15000) == 0.5, 'and is half done half way through',
        P(1000, 8500, 15000))
    ok(P(1000, 16000, 15000) == 1.0, 'and finishes at one')

    -- CLAMPED AT BOTH ENDS. A clock that went backwards (a server restart
    -- mid-heal) and a tick that arrived late are both real, and neither may
    -- produce a target outside the range -- the value feeds a health write.
    ok(P(1000, 0, 15000) == 0.0, 'a clock that went backwards does not heal you '
        .. 'in reverse')
    ok(P(1000, 99999, 15000) == 1.0, 'and a late tick does not overheal')
    ok(P(0, 0, 0) == 1.0, 'a zero duration is DONE rather than a divide by zero '
        .. '-- an uncaught throw in a BR.Sched callback costs the whole job')

    -- ═══ THE TARGET IS ANCHORED ON hp0. THIS IS THE SHIELD BUG ═══
    --
    -- server/inventory.lua carries the write-up: measuring each message from the
    -- player's CURRENT reading double-counts the ramp the earlier messages
    -- already applied ("one shield took me to ~95% from 0%", 2026-08-08). Every
    -- message in one heal comes from the same origin, so a dropped one is
    -- harmless and the last one cannot compound.
    ok(T(40, 100, 0.0) == 40, 'a heal starts you where you were', T(40, 100, 0.0))
    ok(T(40, 100, 0.5) == 70, 'and walks to the middle of what is missing',
        T(40, 100, 0.5))
    ok(T(40, 100, 1.0) == 100, 'and lands on full', T(40, 100, 1.0))

    -- THE SAME ANSWER WHATEVER HAS HAPPENED SINCE. Driven as the tick really
    -- drives it -- a whole ramp of calls -- with the ORIGIN never moving.
    local last = nil
    for i = 0, 10 do
        local v = T(40, 100, i / 10)
        ok(last == nil or v >= last, ('the ramp never goes backwards (%d%%)'):format(i * 10), v)
        last = v
    end
    ok(last == 100, 'and ends exactly on the cap rather than over it', last)

    -- A FULL-HEALTH PLAYER GETS NOTHING RATHER THAN A NEGATIVE.
    ok(T(100, 100, 0.5) == 100, 'a heal on a full player is a no-op')
    ok(T(120, 100, 1.0) == 120,
        'and a player somehow above the cap is not dragged DOWN to it -- this '
            .. 'issues health and must never issue damage', T(120, 100, 1.0))
end

-- ---------------------------------------------------------------------------
describe('solver.geometry')
do
    local at = BR.AmbHealSolve.atRearDoors

    -- ═══ THE SIGN, WHICH IS THE ONE THING THAT GETS GOT WRONG ═══
    --
    -- A GTA heading's FORWARD vector is (-sin h, cos h). A van on heading 0
    -- faces +y, so its BACK is at -y. client/rescue.lua's delivery carries the
    -- same warning, and getting it backwards puts the player at the bonnet --
    -- which passes a distance test perfectly happily and is both wrong and the
    -- one place a rolling ambulance can hit them.
    local behind = select(1, at(0, 0, 0.0, 0, -3.0, 3.5, -0.35))
    local front  = select(1, at(0, 0, 0.0, 0,  3.0, 3.5, -0.35))
    ok(behind == true, 'standing at -y of a van facing +y is BEHIND it')
    ok(front == false,
        'and standing at +y is NOT -- if this passes, the whole feature is at '
            .. 'the bonnet and the exit drops you under the wheels')

    -- THE SAME PAIR ON A ROTATED VAN, so the test is about the arithmetic
    -- rather than about heading zero.
    ok(select(1, at(0, 0, 90.0, 3.0, 0, 3.5, -0.35)) == true,
        'a van on heading 90 faces -x, so its back is at +x')
    ok(select(1, at(0, 0, 90.0, -3.0, 0, 3.5, -0.35)) == false,
        'and not at -x')

    -- DISTANCE STILL BOUNDS IT. Directly astern but out of reach is out of
    -- reach; the arc is not a licence to heal from across the road.
    ok(select(1, at(0, 0, 0.0, 0, -12.0, 3.5, -0.35)) == false,
        'the rear arc does not extend to the far side of the street')

    -- AND THE ARC IS WHAT MAKES THE DISTANCE HONEST. The driver's window is
    -- inside 3.5m of a van's ORIGIN, so a sphere test alone would offer the
    -- prompt there.
    local side = select(1, at(0, 0, 0.0, 2.0, 0.6, 3.5, -0.35))
    ok(side == false,
        'and standing at the driver\'s window is refused even though it is '
            .. 'inside the radius -- the owner asked for the BACK')

    -- THE DEGENERATE CASE. Standing exactly on the origin has no direction, and
    -- normalising a zero vector is a nan that compares false against
    -- everything -- which would read as "not at the back" for the one position
    -- that is unambiguously inside the van.
    local onIt, d, dot = at(5.0, 5.0, 33.0, 5.0, 5.0, 3.5, -0.35)
    ok(onIt == true and d == 0.0 and dot == -1.0,
        'standing exactly on the vehicle origin is in reach rather than a nan',
        ('%s %s %s'):format(tostring(onIt), tostring(d), tostring(dot)))

    -- ═══ THE DROP POINT AND THE REACH TEST ARE ONE PIECE OF ARITHMETIC ═══
    --
    -- "we force them out the back of the ambulance where they were before". The
    -- place you may stand and the place you are put down have to be the same
    -- place, or the exit teleports you somewhere you could not have got in from.
    local bx, by = BR.AmbHealSolve.dropPoint(0, 0, 0.0, A.reachM)
    ok(select(1, at(0, 0, 0.0, bx, by, A.reachM + 0.01, A.behindDot)) == true,
        'the point the player is PUT DOWN on is a point they could have healed '
            .. 'FROM -- one forward vector, two readers',
        ('drop (%.2f, %.2f)'):format(bx, by))

    for _, h in ipairs({ 0.0, 45.0, 90.0, 180.0, 270.0, 359.0 }) do
        local px, py = BR.AmbHealSolve.dropPoint(10.0, -20.0, h, 3.5)
        ok(select(1, at(10.0, -20.0, h, px, py, 3.6, -0.9)) == true,
            ('...at heading %.0f too, well inside the arc'):format(h))
    end
end

-- ---------------------------------------------------------------------------
describe('solver.doors')
do
    local open = BR.AmbHealSolve.doorsOpen

    ok(open({ 1.0, 1.0 }, 0.35) == true, 'both doors wide open is open')
    ok(open({ 0.4, 0.4 }, 0.35) == true, 'and just past the threshold counts')

    -- ═══ ALL OF THEM, NOT ANY ═══
    --
    -- "the rear doors" is plural. Half-open is the state a van is left in by
    -- somebody who bumped one door, and it is the case an `any` implementation
    -- passes and the owner's sentence does not.
    ok(open({ 1.0, 0.0 }, 0.35) == false, 'ONE DOOR OPEN IS NOT "the rear doors"')
    ok(open({ 0.0, 1.0 }, 0.35) == false, '...in either order')
    ok(open({ 0.0, 0.0 }, 0.35) == false, 'and shut is shut -- THE DOORS-SHUT REFUSAL')

    -- A THRESHOLD RATHER THAN `> 0`. A door being nudged by physics or part way
    -- through its animation reads a hair off zero, and a heal that could start
    -- through a door that is technically ajar is not the rule.
    ok(open({ 0.02, 0.02 }, 0.35) == false,
        'a door that is merely ajar is not open')

    -- ═══ AN UNREADABLE DOOR IS SHUT, AND THIS IS THE CASE THAT WAS WRONG ═══
    --
    -- THE BUG THIS SUITE FOUND, written down because it is invisible and
    -- permissive. The first draft of doorsOpen walked `1..#ratios` and treated a
    -- nil as shut -- which is correct reasoning about a value that never
    -- arrives, because IN LUA A NIL IS NOT AN ELEMENT, IT IS THE END OF THE
    -- ARRAY. `#{ 1.0, nil }` is 1. So a door the native could not read did not
    -- read as shut; it disappeared, the loop saw a one-door van, and the rule
    -- the owner wrote in the plural quietly became singular.
    --
    -- Closed at both ends: the caller says how many doors it MEANT to read and a
    -- short array is refused, and client/ambheal.lua writes `false` rather than
    -- nil so the array cannot go short in the first place.
    ok(open({ 1.0 }, 0.35, 2) == false,
        'A DOOR THAT VANISHED FROM THE ARRAY IS SHUT -- a one-element array is '
            .. 'not an answer about two doors')
    ok(open({ 1.0, false }, 0.35, 2) == false,
        'and the dense spelling of the same thing, which is what the client '
            .. 'actually sends')
    ok(open({ 1.0, 1.0 }, 0.35, 3) == false,
        'and asking about three doors and being handed two is a refusal')
    ok(open({}, 0.35) == false, 'no doors at all is not "the doors are open"')
    ok(open(nil, 0.35) == false, 'nor is nil')
    ok(open({ 0 / 0, 1.0 }, 0.35, 2) == false,
        'and a nan door is shut too -- every comparison against a nan is false, '
            .. 'so a naive test would read it as open')
end

-- ---------------------------------------------------------------------------
describe('audit')
do
    -- ═══ THE OWNER'S CHEAT DETECTOR MUST NOT CRY WOLF ON THE OWNER'S FEATURE ═══
    --
    -- server/roster.lua samples every player's ped four times a second and asks
    -- BR.HealthUnexplainedGain whether the reading is higher than the ledger for
    -- a reason. A heal to full is up to 100 unexplained points and
    -- BR.HealthShouldReport's default bar is exactly 100 -- so without the
    -- `healUntil` stamp, the first player to use this feature is the first name
    -- in the anticheat log.
    --
    -- config/match.lua's healthAudit block states the rule this is defending: "a
    -- detector that fires on honest play is worse than no detector, because it
    -- gets switched off, and the day it gets switched off is the day it was
    -- needed."
    local cfg = BR.Config.Combat.healthAudit
    local ctx = { now = 10000, state = BR.PlayerState.ALIVE }

    -- THE CONTROL FIRST, so the assertion below is not passing for free: the
    -- same rise with no stamp IS counted.
    local gain, why = BR.HealthUnexplainedGain(40, 90, ctx, cfg)
    ok(why == BR.HealthExcuse.COUNTED and gain == 50,
        'a 50-point rise with nothing to explain it is counted -- the detector '
            .. 'still works',
        ('%s %s'):format(tostring(gain), tostring(why)))

    -- ...AND THE STAMP server/ambheal.lua WRITES ON EVERY GRANT EXCUSES IT.
    ctx.healUntil = 10000 + (cfg.healSettleMs or 2000)
    gain, why = BR.HealthUnexplainedGain(40, 90, ctx, cfg)
    ok(why == BR.HealthExcuse.HEALING and gain == 0.0,
        'THE SAME RISE INSIDE `healUntil` IS EXCUSED AS HEALING -- which is the '
            .. 'stamp the heal writes every 250ms, so the whole ramp is covered '
            .. 'rather than only its last step',
        ('%s %s'):format(tostring(gain), tostring(why)))

    -- AND THE WINDOW CLOSES. A stamp that excused for ever would be a hole in
    -- the detector wearing this feature's name.
    ctx.now = ctx.healUntil + 1
    gain, why = BR.HealthUnexplainedGain(40, 90, ctx, cfg)
    ok(why == BR.HealthExcuse.COUNTED,
        'and stops excusing once the settle window lapses',
        tostring(why))
end

-- ---------------------------------------------------------------------------
describe('server')
do
    -- The real br_core/server/ambheal.lua, against stub natives. The properties
    -- under test -- who gets the van, what a stop leaves behind, what a death
    -- releases -- are a scheduler and two players away from pure, and every one
    -- of them takes a staged playtest to see once.

    local sent = {}       -- every TriggerClientEvent
    local roster = {}
    local matches = {}
    local jobs = {}
    local handlers = {}

    -- The world: a table of vehicles the stub natives answer from. Two
    -- ambulances and a bin lorry, so "is it an ambulance" has something to
    -- refuse and the arbitration has a second van to prove it is per-vehicle.
    local world = {
        [101] = { model = 1, x = 0.0,   y = 0.0,   heading = 0.0 },
        [102] = { model = 1, x = 500.0, y = 0.0,   heading = 0.0 },
        [103] = { model = 2, x = 0.0,   y = 100.0, heading = 0.0 },  -- not an ambulance
    }
    local netOf   = { [101] = 9101, [102] = 9102, [103] = 9103 }
    local entOf   = { [9101] = 101, [9102] = 102, [9103] = 103 }
    local gone    = {}

    _G.NetworkGetEntityFromNetworkId = function(n) return entOf[n] end
    _G.NetworkGetNetworkIdFromEntity = function(e) return netOf[e] end
    _G.DoesEntityExist = function(e)
        return world[e] ~= nil and not gone[e]
    end
    _G.GetEntityModel   = function(e) return (world[e] or {}).model end
    _G.GetEntityCoords  = function(e)
        local v = world[e] or {}
        return { x = v.x or 0.0, y = v.y or 0.0, z = 0.0 }
    end
    _G.GetEntityHeading = function(e) return (world[e] or {}).heading or 0.0 end

    -- MODEL 1 IS AN AMBULANCE AND NOTHING ELSE IS. Stubbed rather than borrowed
    -- from the real BR.Rescue, because what is under test here is that
    -- server/ambheal.lua ASKS -- see the refusal case below.
    local rescueBusy = {}
    local noted = {}
    BR.Rescue = {
        isAmbulance  = function(m) return m == 1 end,
        vehicleBusy  = function(v) return rescueBusy[v] == true end,
        noteVehicle  = function(src, entry, veh)
            noted[#noted + 1] = { src = src, veh = veh }
        end,
    }

    BR.Roster = {
        get = function(src) return roster[src] end,
        -- A TRIPWIRE, NOT A STUB WITH A JOB. Nothing in this feature may write a
        -- player state: the state is what client/natives.lua's invincibility
        -- latch is derived from, so a write here is the one way this file could
        -- reach across and make a healing player immortal.
        update = function(src, patch)
            for k in pairs(patch) do
                error(('server/ambheal.lua wrote roster field %q for %d')
                    :format(tostring(k), src))
            end
        end,
        each = function() end,
    }
    BR.Server = {
        matches = matches,
        matchOf = function(src)
            local e = roster[src]
            return e and e.matchId and matches[e.matchId] or nil
        end,
        notify = function() end,
    }
    BR.Sched = { every = function(_, name, fn) jobs[name] = fn end }
    BR.Broadcast = { toMatch = function() end }

    _G.RegisterNetEvent   = function() end
    _G.RegisterCommand    = function() end
    _G.AddEventHandler    = function(name, fn) handlers[name] = fn end
    _G.TriggerClientEvent = function(evt, src, d)
        sent[#sent + 1] = { evt = evt, src = src, d = d }
    end

    loadCore('br_core/server/ambheal.lua')

    local tick = jobs['ambheal.tick']
    ok(tick ~= nil, 'the heal tick registered itself on the scheduler')

    --- Put a hurt, living player at the back of a vehicle.
    local function standing(src, veh, hp)
        local w = world[veh]
        matches[1] = { id = 1, state = BR.MatchState.PLAYING }
        roster[src] = {
            src = src, matchId = 1,
            state = BR.PlayerState.ALIVE,
            hp = hp or 40.0,
            -- 3m directly behind a van facing +y.
            pos = { x = w.x, y = w.y - 3.0, z = 0.0 },
        }
        return roster[src]
    end

    local function start(src, netId)
        _G.source = src
        handlers[BR.Net.AMBHEAL_START]({ n = netId })
    end
    local function stop(src)
        _G.source = src
        handlers[BR.Net.AMBHEAL_STOP]()
    end
    local function effects(src)
        local out = {}
        for _, m in ipairs(sent) do
            if m.evt == BR.Net.INV_EFFECT and m.src == src then out[#out + 1] = m.d end
        end
        return out
    end
    local function lastSet(src)
        local found = nil
        for _, m in ipairs(sent) do
            if m.evt == BR.Net.AMBHEAL_SET and m.src == src then found = m.d end
        end
        return found
    end

    -- ═══════════════════════════════════════════════════════════════════════
    -- ONE HEAL PER AMBULANCE AT A TIME
    -- ═══════════════════════════════════════════════════════════════════════
    fakeTime = 100000
    standing(1, 101, 40.0)
    standing(2, 101, 30.0)
    sent = {}

    start(1, 9101)
    ok(BR.AmbHeal.active(1) == true, 'the first player to ask gets the ambulance')
    ok(lastSet(1) ~= nil and lastSet(1).n == 9101,
        'and is told which one, so the client attaches to the van the server '
            .. 'granted rather than the one it happened to be looking at')

    sent = {}
    start(2, 9101)
    ok(BR.AmbHeal.active(2) == false,
        'THE SECOND PLAYER AT THE SAME AMBULANCE IS REFUSED -- the owner\'s '
            .. '"only one heal per ambulance at a time"')
    ok(#sent == 0,
        'and is told nothing at all: no grant, and no refusal message either, '
            .. 'because the prompt is the only surface this feature has',
        #sent)
    ok(BR.AmbHeal.active(1) == true,
        'and the first player\'s heal is untouched by the attempt -- a refusal '
            .. 'must not be a way to knock somebody off a stretcher')

    -- IT IS PER VEHICLE, NOT A GLOBAL LOCK. The obvious wrong implementation --
    -- one flag for "somebody is healing" -- passes every assertion above.
    roster[2].pos = { x = 500.0, y = -3.0, z = 0.0 }
    start(2, 9102)
    ok(BR.AmbHeal.active(2) == true,
        'but the SECOND AMBULANCE is free -- the claim is per van, not a global '
            .. 'lock on the feature')
    stop(2)

    -- ═══════════════════════════════════════════════════════════════════════
    -- WHAT ELSE IS REFUSED
    -- ═══════════════════════════════════════════════════════════════════════
    local function refused(src, netId, note)
        local before = BR.AmbHeal.active(src)
        start(src, netId)
        ok(BR.AmbHeal.active(src) == before, note)
        if BR.AmbHeal.active(src) and not before then BR.AmbHeal.finish(src, false, 'test') end
    end

    standing(3, 103, 40.0)
    refused(3, 9103, 'a bin lorry is not an ambulance, however close you stand')

    standing(3, 102, 40.0)
    roster[3].pos = { x = 500.0, y = 3.0, z = 0.0 }   -- at the bonnet
    refused(3, 9102, 'standing at the FRONT of an ambulance is refused')

    standing(3, 102, 100.0)
    refused(3, 9102, 'a player already on full health is refused -- there is '
        .. 'nothing to gain and it would hold a van somebody else could use')

    standing(3, 102, 40.0)
    roster[3].state = BR.PlayerState.DBNO
    refused(3, 9102, 'a DOWNED player is refused -- their health is a bleed '
        .. 'countdown, and healing one would be a free revive that the CPR kit '
        .. 'charges an ultra-rare item for')

    standing(3, 102, 40.0)
    rescueBusy[102] = true
    refused(3, 9102, 'AND AN AMBULANCE A RESCUE IS USING IS REFUSED -- the '
        .. 'stretcher is the same offset and somebody is already lying on it')
    rescueBusy[102] = false

    standing(3, 102, 40.0)
    matches[1].state = BR.MatchState.ENDED
    refused(3, 9102, 'and nobody heals in a match that is over')
    matches[1].state = BR.MatchState.PLAYING

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE BLIP GAP THE OWNER ASKED US TO CHECK
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- "add that ambulance to our list of ambulance blips if it wasn't already
    -- (such as ambient ones -- should already be covered but just checking)".
    --
    -- IT WAS NOT COVERED. server/vehicles.lua discovers ambient ambulances off
    -- `drivenVehicle`, which is GetPedInVehicleSeat(veh, -1) -- THE DRIVING SEAT
    -- -- and a player who walks up to a parked van and heals in the back never
    -- sits in any seat at all. So healing is a second way to learn an ambulance
    -- exists, and it registers through the same front door.
    ok(#noted >= 1 and noted[1].veh == 101,
        'starting a heal registers the ambulance for the blip -- the driving '
            .. 'seat is the only thing server/vehicles.lua watches, and nobody '
            .. 'sits in one to heal in the back',
        ('%d registration(s)'):format(#noted))

    -- ═══════════════════════════════════════════════════════════════════════
    -- INTERRUPTING KEEPS WHAT YOU HEALED SO FAR
    -- ═══════════════════════════════════════════════════════════════════════
    for s in pairs({ [1] = true, [2] = true, [3] = true }) do BR.AmbHeal.finish(s, false, 'reset') end
    fakeTime = 200000
    standing(4, 101, 40.0)
    sent, noted = {}, {}
    start(4, 9101)

    -- A THIRD OF THE WAY IN.
    for _ = 1, 20 do
        fakeTime = fakeTime + 250
        tick()
    end
    local fx = effects(4)
    ok(#fx > 0, 'health is issued DURING the heal, not in one lump at the end -- '
        .. 'which is the only way an interrupt can keep anything', #fx)

    local partial = fx[#fx].health
    ok(partial > 40.0 and partial < 100.0,
        'and part way through, the target is part way up', partial)
    ok(fx[1].health >= 40.0 and fx[1].health < partial,
        'climbing from where the player started rather than jumping',
        ('%s -> %s'):format(tostring(fx[1].health), tostring(partial)))
    ok(fx[#fx].healthCap == 100,
        'with the cap on every message, so the client can clamp its own write')

    -- THE HEALTH THE SERVER ISSUED IS THE PLAYER'S NOW. The roster sampler
    -- catches the ped up a beat later; this is what that beat is worth.
    roster[4].hp = partial

    sent = {}
    stop(4)
    ok(BR.AmbHeal.active(4) == false, 'the interact key stops the heal')
    ok(lastSet(4) ~= nil and lastSet(4).done == false,
        'and the client is told, so the camera and the attach come down',
        lastSet(4) and tostring(lastSet(4).done))

    -- ═══ NOTHING IS TAKEN BACK ═══
    --
    -- The failure this catches is a teardown that "tidies up" by re-issuing the
    -- starting health. Every target was measured from hp0 and applied upward
    -- only, so what was earned is simply kept -- and the check is that the stop
    -- issued no further INV_EFFECT at all.
    sent = {}
    for _ = 1, 20 do
        fakeTime = fakeTime + 250
        tick()
    end
    ok(#effects(4) == 0,
        'AND NOTHING IS ISSUED AFTER THE STOP -- the partial heal stands, and '
            .. 'the ramp does not carry on in the background',
        #effects(4))
    ok(roster[4].hp == partial,
        'so the player keeps exactly what they healed', roster[4].hp)

    -- AND THE VAN IS FREE AGAIN. A claim that leaked would make the first
    -- interrupted heal of a match the last heal at that ambulance.
    standing(5, 101, 20.0)
    start(5, 9101)
    ok(BR.AmbHeal.active(5) == true,
        'and the ambulance is free for the next player -- an interrupted heal '
            .. 'does not leak its claim for the rest of the match')

    -- ═══════════════════════════════════════════════════════════════════════
    -- A FULL HEAL ENDS ITSELF
    -- ═══════════════════════════════════════════════════════════════════════
    sent = {}
    for _ = 1, 80 do
        fakeTime = fakeTime + 250
        tick()
    end
    ok(BR.AmbHeal.active(5) == false, 'fifteen seconds later the heal is over')
    ok(lastSet(5) ~= nil and lastSet(5).done == true,
        'and the client is told it COMPLETED rather than was interrupted')
    local fx5 = effects(5)
    ok(#fx5 > 0 and fx5[#fx5].health == 100,
        'having been walked all the way to full', fx5[#fx5] and fx5[#fx5].health)

    -- ═══════════════════════════════════════════════════════════════════════
    -- DYING ON THE STRETCHER IS AN ORDINARY DEATH
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- The mortality itself is client/natives.lua's and is asserted in
    -- tools/test_client.lua -- see this file's header. What is asserted HERE is
    -- everything this feature owes a player who has just been shot dead in the
    -- back of a van: the claim goes, the health stops, and nothing about their
    -- state was ever this file's to write.
    fakeTime = 400000
    standing(6, 101, 60.0)
    sent = {}
    start(6, 9101)
    for _ = 1, 10 do fakeTime = fakeTime + 250; tick() end
    ok(BR.AmbHeal.active(6) == true, 'fixture: a heal is running')
    ok(#effects(6) > 0, 'fixture: and issuing health')

    -- SHOT DEAD. This is exactly what server/combat.lua's elimination leaves
    -- behind: the roster entry moves to DEAD and everything else has to notice.
    roster[6].state = BR.PlayerState.OUT
    sent = {}
    fakeTime = fakeTime + 250
    tick()

    ok(BR.AmbHeal.active(6) == false,
        'A PLAYER WHO DIES ON THE STRETCHER STOPS HEALING -- the claim is '
            .. 'released on the very next tick')
    ok(lastSet(6) ~= nil and lastSet(6).done == false,
        'and their client is told, so the attach, the camera and the control '
            .. 'block all come down rather than outliving the ped')
    ok(#effects(6) == 0,
        'and NOT ONE MORE POINT OF HEALTH IS ISSUED -- a corpse being healed to '
            .. 'full is how a death gets un-decided',
        #effects(6))

    -- THE VAN IS FREE. A player killed mid-heal must not lock the ambulance
    -- their killer is standing next to.
    standing(7, 101, 50.0)
    start(7, 9101)
    ok(BR.AmbHeal.active(7) == true,
        'and the ambulance is immediately usable again -- including by whoever '
            .. 'just did the shooting')
    BR.AmbHeal.finish(7, false, 'test')

    -- ═══ AND NO STATE WAS EVER WRITTEN ═══
    --
    -- BR.Roster.update is a tripwire in this block: it throws on any field. If
    -- the suite got this far, server/ambheal.lua never touched a roster field,
    -- which is what keeps client/natives.lua's invincibility latch the only
    -- thing deciding whether a healing player can be hurt.
    ok(true,
        'and server/ambheal.lua never wrote a single roster field -- the '
            .. 'tripwire on BR.Roster.update would have thrown')

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE OTHER WAYS A CLAIM MUST NOT LEAK
    -- ═══════════════════════════════════════════════════════════════════════
    standing(8, 101, 40.0)
    start(8, 9101)
    gone[101] = true
    fakeTime = fakeTime + 250
    tick()
    ok(BR.AmbHeal.active(8) == false,
        'an ambulance that stops existing ends the heal in it')
    gone[101] = false

    standing(9, 101, 40.0)
    start(9, 9101)
    roster[9].pos = { x = 0.0, y = -40.0, z = 0.0 }
    fakeTime = fakeTime + 250
    tick()
    ok(BR.AmbHeal.active(9) == false,
        'AND WALKING AWAY ENDS IT ON THE SERVER TOO -- the client watches as '
            .. 'well, but a client that simply does not run that watch would '
            .. 'otherwise heal to full while running away')

    standing(10, 101, 40.0)
    start(10, 9101)
    _G.source = 10
    handlers['playerDropped']()
    ok(BR.AmbHeal.active(10) == false and BR.AmbHeal.count() == 0,
        'and a player who disconnects mid-heal does not take the ambulance with '
            .. 'them for the rest of the match',
        BR.AmbHeal.count())
end

-- ---------------------------------------------------------------------------
describe('wire')
do
    -- THREE EVENTS AND NO MORE, and the two that run client->server carry
    -- almost nothing. protocol.lua's rescue block makes the same point about
    -- the same kind of feature: the asymmetry IS the security model.
    ok(BR.Net.AMBHEAL_START ~= nil and BR.Net.AMBHEAL_STOP ~= nil
           and BR.Net.AMBHEAL_SET ~= nil,
        'the three ambulance-heal events exist')

    -- ═══ THE HEALTH IS NOT ON THEM ═══
    --
    -- It goes out on INV_EFFECT, the med kit's own channel, which is what buys
    -- the client-side cap and the audit's HEALING excuse for free. A dedicated
    -- health event would have needed its own copy of both.
    local fh = io.open('resources/[fivem-royale]/br_core/server/ambheal.lua')
    local src = fh and fh:read('a') or ''
    if fh then fh:close() end
    ok(src:find('BR.Net.INV_EFFECT', 1, true) ~= nil,
        'and the health itself rides INV_EFFECT rather than a fourth event')
    ok(src:find('healUntil', 1, true) ~= nil,
        'stamped with healUntil on the way out, or the owner\'s own feature is '
            .. 'the loudest thing in his cheat log')
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end

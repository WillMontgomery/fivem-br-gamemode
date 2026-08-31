-- The 23 station ambulances, and the blips a squad sees while one of them is
-- down (#219 step 3).
--
-- ═══ THE OWNER'S TWO SENTENCES, AND EVERY CLAUSE IS A RULE ═══
--
--   "The 23 surveyed points should be persistent ambulances. Whenever a
--    squadmate is down or out, the blips for all the ambulances should be shown
--    to the whole squad."
--
--   "I've verified those spawn locations do not conflict with any in-game
--    vehicle spawn positions. Those ambulances should be spawned at the
--    beginning of the match when the bus doors open."
--
-- ALL of them, to the WHOLE squad. Not the nearest one, not the one the downed
-- player is beside: the squad is choosing where to drive, and a map showing one
-- option is not a choice.
--
-- ═══ "DOWN OR OUT" BECAME "OUT" ON 2026-08-31, AND SO DID THE CODE ═══
--
--   "while a squadmate is DBNO bleeding out we have ambulance blips for the
--    squad, but we can't do anything with the ambulances. We should not see
--    blips until they've bled out."
--
-- The two halves of the old word are not the same offer. A DBNO mate is revived
-- AT THE BODY -- client/dbno.lua's plate, a hold, free, and they keep their
-- inventory -- and no revive key exists until they are eliminated, so a map of
-- ambulances during the bleed-out points at something nobody can act on. The
-- trigger in server/ambulances.lua's `publish` is BR.PlayerState.OUT alone, and
-- that state is the one BR.ReviveKey.onEliminated mints a key on. THERE IS NO
-- KNOB FOR THIS and there should not be: it is the sentence, not a preference.
--
-- ═══ AND THE 23 ARE NOT THE WHOLE MAP ═══
--
--   "let's not auto-show ambulance blips just because they got in an ambulance -
--    BUT do add the position to the table so when blips are shown we can include
--    any that other players have found along the way (engine-spawned ones)."
--
-- Ambient ambulances are discovered by server/rescue.lua (the only hook that can
-- see client-created population is a player driving one) and REMEMBERED there.
-- server/ambulances.lua mirrors that ledger and publishes the finds beside the
-- 23, through the identical gate. Nothing in this file configures them: they
-- have no count to plan, no model to choose and no point to survey -- the only
-- setting they share with the stations is `blip.movedM` below, which is the
-- right answer for both because both are ambulances on a minimap.
--
-- ═══ THE POINTS ARE NOT IN THIS FILE, AND MUST NEVER BE COPIED INTO IT ═══
--
-- They live in BR.Config.Map.AmbulanceSpawns, surveyed in game with /brcoords on
-- 2026-08-23, and `Points()` below reads them through BR.Config.Rescue.Points()
-- at CALL time. That is the same route #191's rescue takes to the same rows, and
-- routing both features through one reader is what makes it impossible for the
-- station ambulance and the rescue that spawns beside it to disagree about where
-- a station is. config/rescue.lua's own `points` table is empty for exactly this
-- reason and says so at length; this file is the third reader and keeps the rule.
--
-- WITH NO POINTS THE FEATURE IS INERT RATHER THAN BROKEN, which is the same
-- property config/rescue.lua and config/shop.lua ship with: nothing is created,
-- nothing is blipped, and one console line says the table was empty.
--
-- ═══ THE MODEL IS THE RESCUE'S MODEL, AND THAT IS A SHARED DECISION ═══
--
-- config/rescue.lua: "a second, longer list for recognition is how a rescue
-- ambulance ends up not counting as an ambulance". A station ambulance must be
-- an ambulance to server/ambheal.lua ("any ambulance at all" heals in the back,
-- owner 2026-08-28) and to the revive key, both of which ask
-- BR.Rescue.isAmbulance -- which resolves BR.Config.Rescue.models. So this file
-- names no model of its own and reads that one.

BR.Config = BR.Config or {}

BR.Config.Ambulances = {
    -- The whole feature, off in one line. With this false nothing is created,
    -- nothing is deleted and no blip is published -- and the rescue's spawn
    -- displacement below becomes a no-op, because there is nothing parked to
    -- displace around.
    enabled = true,

    -- ------------------------------------------------------------------
    -- CREATION
    -- ------------------------------------------------------------------
    --
    -- HOW OFTEN THE PASS RUNS. It does four things on this cadence -- create the
    -- next few, notice one that has stopped existing, refresh the blip
    -- coordinates, and run a teardown -- and 1s is the rate the slowest of them
    -- needs. It is the same number BR.Config.Rescue.tickMs carries for the same
    -- reason: a vehicle blip that updates once a second reads as smooth on a
    -- minimap, and anything faster is broadcast for no visible gain.
    tickMs = 1000,

    -- ═══ HOW MANY ARE BUILT PER PASS, AND WHY THIS IS NOT 23 ═══
    --
    -- Twenty-three CreateVehicleServerSetter calls in one frame is twenty-three
    -- sync trees built and twenty-three entities registered inside one
    -- scheduler job, and BR.Sched measures every job's peak (/brperf). Six per
    -- pass spreads it over four passes -- about four seconds, inside a bus
    -- flight that runs minutes -- and no client can see the difference: the
    -- stations are scattered across the whole map and every player is in the
    -- plane, so at OneSync's 424m relevancy radius almost none of these are
    -- cloned to anybody at the moment they are made.
    --
    -- THE SAME NUMBER PACES THE TEARDOWN, and there it is load-bearing rather
    -- than tidy -- see `deleteAttempts`.
    perTick = 6,

    -- ------------------------------------------------------------------
    -- TEARDOWN
    -- ------------------------------------------------------------------
    --
    -- ═══ HOW MANY TIMES A DELETE IS RE-ISSUED BEFORE IT IS REPORTED ═══
    --
    -- citizenfx/fivem#2256 ("Vehicles Persisting After Server-Side Deletion",
    -- open since 2023-10-29, labelled onesync) is the reason this is a number
    -- and not a single call. Its reproduction is a server-side delete loop over
    -- SEVERAL vehicles IN A NON-DEFAULT ROUTING BUCKET -- which is exactly this
    -- feature, twenty-three at a time, in bucket matchBucketBase + matchId --
    -- and the reported symptom is that DoesEntityExist answers false on the
    -- server while clients go on rendering the vehicle. The thread carries no
    -- workaround.
    --
    -- SO THE PASS RE-ASKS. A handle that still exists after a delete is deleted
    -- again on the next pass, up to this many times, and what survives is
    -- printed with its point id rather than dropped silently. That fixes the
    -- half of #2256 the server can see. The half it cannot see is answered by
    -- the routing bucket instead, and that argument is in server/ambulances.lua
    -- above `teardown` -- match ids strictly increment and buckets are never
    -- reused, so a ghost is confined to a bucket no live player is ever in
    -- again.
    deleteAttempts = 5,

    -- ------------------------------------------------------------------
    -- THE COLLISION WITH THE CPR RESCUE
    -- ------------------------------------------------------------------
    --
    -- ═══ WITHOUT THESE TWO NUMBERS EVERY RESCUE SPAWNS INSIDE A PARKED
    --     AMBULANCE ═══
    --
    -- server/rescue.lua creates its ambulance at the surveyed pickup point,
    -- EXACTLY -- client/rescue.lua's `freeSpaceNear` used to step it aside and
    -- cannot any more ("the vehicle is created on the server, which has no
    -- IsPositionOccupied to ask"), so the ring-walk now only sites the medic.
    -- config/rescue.lua still describes that mitigation as live. It is not, and
    -- with a station ambulance parked on all 23 points the case it covered stops
    -- being rare and becomes every rescue.
    --
    -- REUSING THE PARKED ONE IS REFUSED, AND NOT BY THIS FILE. config/rescue.lua
    -- argues it out at length -- the ride is scripted (doors locked, siren on,
    -- tint off, maximum upgrades, an NPC at the wheel) and "EVERY ONE OF THOSE
    -- IS A PROPERTY OF A VEHICLE WE MADE". That decision stands; what is built
    -- here is the small thing it says is actually needed.
    --
    -- THE SERVER CAN ANSWER THIS ONE EXACTLY, WHICH THE CLIENT NEVER COULD. It
    -- does not need IsPositionOccupied, because it is not asking "is anything
    -- there" -- it is asking "is one of MINE there", and it made all 23 and
    -- reads their coordinates every pass.

    -- How near a station ambulance has to be to the rescue's spawn point before
    -- the spawn is moved. An ambulance is about 6.6m long and 2.5m wide, so
    -- anything within 6m of the point is standing on it.
    occupiedM = 6.0,

    -- ...and how far BEHIND the parked one the rescue's ambulance is put
    -- instead, along the surveyed heading.
    --
    -- BEHIND, NOT BESIDE, AND THE DIRECTION IS THE DECISION. The heading in
    -- BR.Config.Map.AmbulanceSpawns is the way the owner was facing when he
    -- walked the point, which is the way a vehicle put there should face -- so
    -- the ground behind it is the ground the parked one drove in over, and the
    -- ground beside it is as likely to be a kerb, a fence or a wall. Two
    -- ambulances nose to tail also read as an ambulance station rather than as
    -- an accident.
    --
    -- 8m against a 6.6m vehicle leaves about 1.4m of daylight between the two
    -- hulls, and the rescue's ambulance pulls away forwards past the parked one.
    standAsideM = 8.0,

    -- ------------------------------------------------------------------
    -- THE BLIPS
    -- ------------------------------------------------------------------
    --
    -- ═══ NO SPRITE, NO COLOUR AND NO LABEL HERE, ON PURPOSE ═══
    --
    -- They are drawn by the handler client/rescue.lua already has for
    -- BR.Net.RESCUE_BLIP, which reads BR.Config.Rescue.blip -- sprite 153 (the
    -- game's own ambulance icon), colour 1, scale 0.9, label 'Ambulance'. That
    -- handler was written to take an OPAQUE key so the server could add a
    -- category without the client changing ("both are just strings here"), and
    -- this is the category it was left room for. A second sprite for the same
    -- vehicle in the same match would be a map that says two different things
    -- about one word.
    --
    -- ═══ AND THE AUDIENCE IS NOT BR.Config.Rescue.blip.audience ═══
    --
    -- That knob is 'match' and config/rescue.lua names #219 as the issue that
    -- owns the real answer for THESE: "ambulance blips are shown while a
    -- squadmate is down and the audience question is that issue's to settle."
    -- It is settled by the owner's own sentence -- the whole squad, and nobody
    -- else -- so it is a rule here rather than a field, and the rescue's moving
    -- blip keeps its own separate one.
    --
    -- ═══ AND `enabled` NOW GOVERNS THE FOUND ONES TOO ═══
    --
    -- server/rescue.lua's ambient ambulances used to reach the map through
    -- BR.Config.Rescue.blip and its 'match' audience. They reach it through
    -- `publish` in server/ambulances.lua now, so this switch turns off EVERY
    -- parked-ambulance blip in the game and the rescue's own moving one is the
    -- only thing left on that event. That is the honest meaning of the field --
    -- one line that stops this feature -- and it is worth writing down because
    -- the old path is what somebody would go looking for.
    blip = {
        enabled = true,

        -- How far an ambulance has to move before its blip is re-sent -- one of
        -- the 23 or one somebody found; `refresh` and `refreshFound` read the
        -- same number, because a minimap has no idea which kind it is drawing.
        --
        -- THEY ARE PARKED, SO ALMOST NOTHING IS SENT AFTER THE FIRST PASS -- and
        -- one somebody DRIVES AWAY keeps its blip under it, which is the owner's
        -- 2026-08-23 rule for the rescue's own ("if someone takes it, we need to
        -- update it's location on the map") holding for the stations without a
        -- second mechanism. A metre is below what is visible on a minimap and
        -- above the jitter of a settling vehicle.
        movedM = 1.0,
    },
}

--- The 23 surveyed points, through the rescue's reader.
---
--- ONE READER FOR ONE TABLE. Asking BR.Config.Map.AmbulanceSpawns directly here
--- would work today and would be a second path to the same rows -- and the first
--- symptom of the two disagreeing would be a rescue spawning on top of a station
--- ambulance that this file thinks is somewhere else.
---
--- @return table[]  possibly empty; callers must handle that
function BR.Config.Ambulances.Points()
    local R = BR.Config.Rescue
    if not R or not R.Points then return {} end
    return R.Points()
end

--- What model a station ambulance is.
--- @return string
function BR.Config.Ambulances.Model()
    local R = BR.Config.Rescue
    return (R and R.model) or 'ambulance'
end

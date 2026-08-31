-- Match configuration.
--
-- Player counts live here rather than being hardcoded so raising the cap later is
-- a one-line change. Note the hard ceiling below: OneSync is free up to 48 slots,
-- and setting sv_maxclients above that without a Cfx.re Element Club tier makes
-- the server fail its heartbeat check and drop off the public list entirely.

BR = BR or {}

BR.Config = BR.Config or {}

BR.Config.Match = {
    -- Slots. 48 is the free OneSync ceiling; the code paths are written to scale
    -- past it, but do not raise this without the matching Element Club tier.
    maxPlayers      = 48,
    -- 1 so a lone dev client can walk the whole flow. The win condition knows
    -- a dev match that STARTED with one squad has nothing to win (see
    -- winConditionMet) -- otherwise PLAYING would end three seconds in.
    minToStart      = 1,
    minToStartProd  = 16,

    -- Lobby / warmup timings, in seconds.
    warmupSeconds   = 45,
    warmupShortened = 15,     -- once the lobby is full, cut the wait
    endedSeconds    = 20,     -- summary screen duration before returning to lobby
    cleanupSeconds  = 5,

    -- THE COVER HANDSHAKE'S DEADLINES, and every one of them exists to be
    -- WRONG SAFELY rather than to be right (#124).
    --
    -- A screen transition is: cover the screen, change the world, uncover.
    -- The cover lives in CEF and the change lives in Lua, so the only honest
    -- way to order them is for the page to say "I am black now"
    -- (BR.NuiCb.COVERED). These are the caps on waiting for it -- a page that
    -- never answers has crashed, and a player left staring at black because
    -- of it is a far worse bug than the visible cut the cover was hiding.
    --
    -- coverWaitMs   the curtain's own fade is 600ms; four times that is
    --               "something is wrong", not "the machine is slow".
    -- verdictWaitMs the verdict backdrop starts 1.4s after the summary lands
    --               and takes 2s to reach solid black -- so ~3.9s from the
    --               ENDED transition. Six seconds is that plus room.
    -- coverSweepMs  the SERVER's own deadline for sweeping a player home
    --               without ever hearing from them. Longer than the client's
    --               own wait (which is what normally triggers the report) and
    --               comfortably inside endedSeconds, so CLEANUP is never the
    --               thing that has to rescue it.
    coverWaitMs     = 2500,
    verdictWaitMs   = 6000,
    coverSweepMs    = 8000,

    -- Default mode when a player queues without choosing.
    defaultMode     = 'solo',

    -- Squads
    autofill        = true,   -- fill partial squads with solo queuers

    -- FOUR IS THE GAME; TWO IS HOW YOU TEST IT.
    --
    -- With three dev clients and a maximum of four, every client lands in the
    -- SAME squad -- which makes cross-squad damage impossible to produce in
    -- game, and cross-squad damage is the half of #115's fix that nothing in a
    -- playtest can otherwise reach. Set this to 2 and three clients become two
    -- squads (2 + 1), which puts the enemy case on the screen.
    maxSquadSize    = 4,

    -- THE ENGINE'S OWN FRIENDLY-FIRE GATE (#115), and the one-line way back.
    --
    -- true  each squad gets a GTA team (SET_PLAYER_TEAM) and a player with a
    --       live squadmate closes the engine's friendly-fire gate, so the
    --       shooter's engine never computes a hit on a teammate and the false
    --       corpse cannot be created. Solos keep team 0 and an OPEN gate, so
    --       solo play behaves exactly as it did before this existed.
    -- false no team is ever set and the gate is always open -- byte-for-byte
    --       the pre-#115 behaviour from e1f9f98.
    --
    -- The load-bearing inference is that GTA's damage path refuses a hit when
    -- shooter and victim share a team and the gate is closed. Everything in
    -- the record supports it (see the note above BR.Native.teamFor in
    -- br_core/client/natives.lua) and no source states it in words, so this
    -- switch exists to make a wrong guess cost one line rather than a round.
    -- If squad matches suddenly have no combat at all, set this false.
    engineTeams     = true,

    -- A squad match needs somebody to fight. One squad means the win condition
    -- is already satisfied at the starting gun, which reads as "the match ended
    -- the instant it began". Dev mode drops to 1 so a two-client test can force
    -- a match through; set autofill = false to test as two one-player squads.
    minSquads       = 2,
    minSquadsDev    = 1,

    -- How long the queue waits for an incomplete party before starting the
    -- match without its stragglers (who can still late-join during warmup).
    -- Zero patience started matches on the first Ready; infinite patience
    -- hands one AFK partymate the whole lobby.
    partyGraceSeconds = 45,

    -- THE LOBBY IS A CHARACTER SHOT NOW, not a landscape.
    --
    -- It used to be an empty vista with the player invisible in it: a menu
    -- with a view. Standing YOUR ped in frame is what makes the locker and
    -- the ped picker possible at all, and it is what every battle royale does
    -- with this screen -- the thing you are about to play as, looking back at
    -- you (user, 2026-08-08).
    --
    -- Everyone stands on this exact spot, in the SAME routing bucket, and
    -- each client hides every OTHER lobby ped locally (client/squadmates.lua)
    -- -- so nobody's character walks through your shot while the bucket stays
    -- shared. A per-player bucket would have done the same job and cost the
    -- one thing the shared bucket buys: players in the lobby can still be
    -- reached by anything that addresses the lobby as a place.
    lobbyPos        = { x = 5039.27, y = -5721.95, z = 17.08, heading = 208.31 },

    -- THE LOBBY CAMERA. Locked, because a lobby camera the player can swing
    -- is a lobby camera pointed at the sky within ten seconds.
    --
    -- `dist` is the user's six feet, in metres, measured along the ped's OWN
    -- forward vector -- so the camera is always looking the ped in the face
    -- whatever heading the spawn is authored at.
    --
    -- `offset` is the part that is a design decision rather than a
    -- measurement: it slides the AIM point sideways so the ped lands in the
    -- right third of the screen instead of dead centre, because the left
    -- third is the menu (see screens/Lobby.tsx, which reserves exactly that
    -- gap). Aiming off-centre rather than moving the camera keeps the ped
    -- face-on; moving the camera would put them in three-quarter profile.
    --
    -- `fov` is a normal-ish lens. Anything wider at six feet gives the ped a
    -- caricature nose; anything narrower crops them at the chest, which the
    -- locker cannot use.
    -- The heights came down a foot after the first playtest (user,
    -- 2026-08-09): mid-torso put the lens above the character's centre of
    -- mass and the shot read as looking DOWN at them, which is the least
    -- flattering angle a character select can have. The aim drops slightly
    -- less than the camera, so the lens now tilts a touch UP -- the standard
    -- hero framing, and it puts more of the outfit in shot for the locker.
    lobbyCam        = {
        dist   = 1.83,   -- 6 ft in front of the ped
        height = 0.65,   -- camera height above the ped's root
        aim    = 0.68,   -- what it looks at; above `height` => tilted up
        offset = 0.58,   -- aim shifted left => ped sits right of centre
        fov    = 50.0,
    },

    -- Warmup pad: the Cayo Perico airstrip apron. The island is enabled by
    -- br_environment whenever a match is not PLAYING -- if players spawn into
    -- ocean here, that resource is not running (it must be ensured in
    -- server.cfg) or its island switch failed; check the F8 console for
    -- '[br_environment]'.
    --
    -- M3: the Battle Bus departs from this airstrip; its runway runs
    -- (4517.7, -4558.3) -> (4372.2, -4413.2), heading ~315.
    warmupPos       = { x = 4449.0, y = -4482.0, z = 4.3, heading = 315.0 },
    -- Tighter than the old LSIA pad: the airstrip apron is generous but the
    -- island tip is not, and a wide scatter puts players in the surf.
    --
    -- STILL THE ANCHOR FOR THE WARMUP LOOT LAYOUT (shared/loot_gen.lua and
    -- server/loot.lua both site the communal layout around it), which is why
    -- these two survive `warmupSpawns` below taking over the PLAYER arrival.
    warmupRadius    = 60.0,

    -- WHERE A PLAYER ACTUALLY LANDS WHEN THEY READY UP. Surveyed in game by
    -- the owner on 2026-08-29, and picked from at random, one per arrival.
    --
    -- THEY REPLACE THE RANDOM SCATTER, and the reason is not tidiness. The
    -- scatter drew a point in a 30m disc around `warmupPos` and dropped the
    -- player on whatever ground was under it; these are five places a person
    -- stood. The first four are a cluster (a group arriving together still
    -- arrives together); the fifth is off on its own, which is what stops
    -- five simultaneous readies looking like a formation.
    --
    -- THE TELEPORT ONTO ONE OF THESE IS THE ORDERING THE WHOLE FIX TURNS ON.
    -- See BR.LobbyPed in br_core/client/lobbyped.lua: the ped is moved HERE
    -- first and only becomes a networked, visible-to-everyone ped afterwards,
    -- so it is never a stranger appearing on the lobby mark.
    warmupSpawns    = {
        { x = 4498.92, y = -4456.00, z = 4.37, heading = 193.3 },
        { x = 4500.47, y = -4455.57, z = 4.37, heading = 167.1 },
        { x = 4497.39, y = -4457.80, z = 4.37, heading = 227.2 },
        { x = 4508.75, y = -4456.06, z = 4.35, heading = 149.0 },
        { x = 4461.69, y = -4475.51, z = 4.27, heading = 261.1 },
    },

    -- ====================================================================
    -- THE LOBBY ENTRANCE: THE WALK IN, AND THE CAMERA THAT MEETS IT.
    -- ====================================================================
    --
    -- EVERY DURATION HERE IS A KNOB ON PURPOSE. The owner offered to tune the
    -- timing himself ("He has offered to help tune this"), so nothing about
    -- when this sequence does what is written in the client -- the client
    -- reads these and /brlobbywalk replays the whole thing without a restart.
    --
    -- THE PED'S PATH is four legs: `pedStart`, three surveyed corners, and then
    -- `lobbyPos` above -- which the client appends rather than this file
    -- repeating, because the lobby mark has one definition and the locker, the
    -- camera and the loading gate all read it.
    --
    -- THE CAMERA'S PATH is three authored nodes and then the ordinary lobby
    -- frame, computed from `lobbyPos` and `lobbyCam` exactly as it always was.
    lobbyEntrance   = {
        -- ═══ ONE SURVEYED PATH, AND IT IS NOT A DRAW ANY MORE ═══
        --
        -- Re-surveyed by the owner on 2026-08-30, REPLACING the four random
        -- cases that preceded it. There is one way in again, so there is no
        -- choosing: `pedStart` is where the ped is placed under the cover and
        -- `pedPath` is the corners it walks through.
        --
        -- THE MACHINERY WENT WITH THEM rather than being left as a table of
        -- one, which would have been a draw that always drew the same card and
        -- read, to the next person, as a feature still in use.
        --
        -- `pedStart.heading` IS USED -- it is where the ped is placed, before it
        -- has a leg to face along. THE HEADINGS ON THE CORNERS ARE NOT, and are
        -- kept only because they are the survey. They are where the surveyor
        -- was standing and looking; handing them to TaskGoStraightToCoord as
        -- "the way to face on arrival" is what used to make the ped turn most of
        -- a right angle the wrong way at every corner and then turn back. A
        -- corner's facing is a consequence of where the path goes NEXT, and the
        -- client computes it -- see headingFor in br_core/client/lobbyped.lua,
        -- and the assertion in tools/test_lobbyseq.lua that would catch anyone
        -- wiring these back in.
        --
        -- THE FINAL LEG IS `lobbyPos`, appended by the client. Do not repeat it.
        --
        -- FOUR LEGS: 7.0m, 13.0m, 5.8m, 5.0m -- 30.8m in all, against 41m for
        -- the longest of the old cases. At the 18s target that is 1.71 m/s
        -- average, comfortably inside the blend clamp, so nothing is pinned at
        -- the ceiling the way case 2 used to be.
        pedStart = { x = 5040.08, y = -5699.77, z = 19.88, heading = 118.5 },
        pedPath  = {
            { x = 5034.35, y = -5703.75, z = 19.88, heading = 139.2 },
            { x = 5041.32, y = -5714.51, z = 17.68, heading = 212.0 },
            { x = 5036.56, y = -5717.71, z = 17.08, heading = 120.4 },
        },

        -- THE WALKING STYLE, AND IT IS A STOCK GTA MOVEMENT CLIPSET.
        --
        -- The owner named these from a separate emote resource's menu
        -- ("grooving male" / "grooving female") and said he intends to remove
        -- that resource. They are not its content: that menu's labels sit in
        -- front of the game's own clipsets, and these two strings are what its
        -- own table maps them to (client/AnimationList.lua, RP.Walks.Grooving
        -- and .Grooving2). Nothing in this project references, requires or
        -- checks for it -- SetPedMovementClipset takes the clipset directly.
        --
        -- THE TRAILING @ IS PART OF THE NAME. `anim@move_m@grooving` without
        -- it is a different string and RequestAnimSet answers nothing for it,
        -- which presents as a ped that walks normally rather than as an error.
        walkClipsetMale   = 'anim@move_m@grooving@',
        walkClipsetFemale = 'anim@move_f@grooving@',

        -- How long to wait for the clipset to stream before walking anyway.
        -- A missed style costs a plain walk; a wait with no ceiling costs the
        -- whole entrance.
        clipsetWaitMs = 3000,

        -- How long to wait for the ped MODEL before starting. The owner called
        -- this one out explicitly ("Wait for the model to load before
        -- proceeding"), and it is sized off client/locker.lua's own 5s request
        -- deadline plus the tick that starts it.
        modelWaitMs = 8000,

        -- ═══ EVERY WALK TAKES THE SAME TIME, AND THE SPEEDS ARE DERIVED ═══
        --
        -- Owner, 2026-08-29: "Each walk should take the exact same amount of
        -- time, and be faster at the first steps when necessary, before
        -- slowing down to a normal pace for the last walk." Target confirmed
        -- at eighteen seconds, for every case.
        --
        -- SO THERE IS NO AUTHORED LIST OF SPEEDS ANY MORE, and there cannot be
        -- one. The four cases are 41.2m, 58.7m, 28.6m and 34.0m long; a single
        -- list of blend ratios could not put all four on the same clock. The
        -- client measures the case it drew and solves for the ramp that does --
        -- see `blendPlan` in br_core/client/lobbyped.lua.
        --
        -- THE LAST LEG IS ALWAYS 1.0, which is the owner's "normal pace for the
        -- last walk", and the legs before it ramp DOWN to it in equal steps
        -- from whatever the first leg needs. Nothing jumps.
        --
        -- `walkMps` IS THE ONE NUMBER THAT CANNOT BE COMPUTED: how many metres
        -- per second this ped actually covers at blend 1.0, wearing the
        -- grooving clipset, on this ground. 1.4 is GTA's nominal walk.
        --
        -- IF THE MEASURED WALK IS NOT 18 SECONDS, THIS IS THE KNOB. /brlobbywalk
        -- prints what the last walk really took: a measured 20s against a
        -- target of 18 means this number is about ten percent low.
        walkTargetMs = 18000,
        walkMps      = 1.4,

        -- THE FLOOR AND THE CEILING ON A DERIVED BLEND RATIO. TaskGoStraight-
        -- ToCoord's move blend ratio: 1.0 is a walk, 2.0 a run, 3.0 a sprint.
        -- 3.0 is therefore as fast as a person moves, and a ratio above it is
        -- not a walk arriving anywhere. A case that cannot make the target
        -- inside this ceiling simply takes longer, and /brlobbywalk says by how
        -- much rather than the ped sprinting at an impossible ratio.
        walkBlendMin = 1.0,
        walkBlendMax = 3.0,

        -- ═══ THREE DISTANCES, AND THEY ARE NOT THE SAME QUESTION ═══
        --
        -- `cornerRadius` -- HOW EARLY THE NEXT LEG IS HANDED OVER at a corner,
        -- in metres. Each leg is a go-to-coord task and a go-to-coord task
        -- ENDS AT REST: the ped slows over the last couple of metres so it
        -- stops ON the coordinate. Handing over at 0.9m meant the ped had
        -- already finished stopping before it was told to keep going -- owner,
        -- 2026-08-29: "it seems the ped walks to the point, stops, turns, then
        -- walks to the next point." Bigger rounds the corners more and cuts
        -- them wider; smaller is closer to the surveyed line and closer to
        -- stopping at it. It is clamped in the client to a fraction of the leg
        -- being walked, so a short leg cannot be swallowed by its own corner.
        --
        -- `markRadius` -- HOW CLOSE COUNTS AS ARRIVED at the lobby mark, and
        -- it is small for a reason. The mark is the end of the walk and the
        -- ped is placed exactly on it (the lobby is a camera shot), so
        -- whatever is left when the walk stops is a TELEPORT the player
        -- watches -- owner, 2026-08-29: "the ped is getting close to the final
        -- coords, but then being teleported there." That is what this is: the
        -- length of that teleport. Under a boot's width and nobody can see it.
        --
        -- `arriveRadius` -- the plain "close enough" the two above are
        -- measured against: the floor under cornerRadius, and the window in
        -- which a ped that has stopped improving is taken to have arrived.
        cornerRadius = 2.0,
        markRadius   = 0.15,
        arriveRadius = 0.9,

        -- How long one leg may take before the sequence gives up on it and
        -- moves to the next. The FLOOR under the grace below, not the plan: it
        -- covers the window before the camera has landed, when there is nothing
        -- else watching a ped stuck on geometry.
        legTimeoutMs = 15000,

        -- ═══ AND THE FAILSAFE IS ANCHORED TO THE CAMERA NOW ═══
        --
        -- Owner, 2026-08-29: "I see you implemented a failsafe in case the ped
        -- doesn't get to the destination in time. It seem's that's firing
        -- correctly, but takes too long. Can you make it so if the ped doesn't
        -- get to the destination within 5 seconds of the camera parking we fire
        -- that function and bring them to the position ourselves?"
        --
        -- ...AND IT IS MEASURED FROM WHEN THE WALK IS DUE, NOT FROM THE PARKING.
        --
        -- Those were the same moment when he asked for it -- flight and walk
        -- both eighteen seconds -- and stopped being the same moment one
        -- message later, when the camera went thirty percent faster and started
        -- parking four seconds early. Five seconds from the PARKING would now
        -- leave under a second of slack, and case 2 (which honestly needs 19.6s)
        -- would trip it on every single return: one lobby entrance in four
        -- teleporting the ped, presenting as the arrival bug coming back.
        --
        -- So the client waits until the walk is genuinely overdue -- the drawn
        -- case's own planned duration, plus anything the walk was deliberately
        -- paused for -- and then gives it this long. The camera parking stays
        -- in as a floor. See `graceExpired` in br_core/client/lobbyped.lua.
        --
        -- IT SHOULD NEVER FIRE, AND THAT IS THE POINT. IF IT FIRES ROUTINELY,
        -- `walkMps` is wrong: the walk is taking longer than the plan thinks,
        -- and that is the number to change rather than this one.
        --
        -- THE FLIP DOES NOT COUNT AGAINST IT. A winning return stops at the
        -- second-to-last point for the length of the animation, which is a
        -- deliberate pause and not a ped that failed to arrive. Teleporting a
        -- winner out of their own victory animation would be the worst possible
        -- way to spend this.
        arriveGraceMs = 5000,

        -- THE CAMERA NODES -- CONTROL POINTS FOR A CURVE, NOT STOPS ON A ROUTE.
        --
        -- The flight is a Catmull-Rom spline THROUGH these three and then the
        -- ordinary lobby frame, resampled into `camSteps` short moves. So the
        -- camera passes through each of them without a corner: owner,
        -- 2026-08-29, "when the camera gets to a position and changes direction
        -- that's also too sudden ... we need more steps in this process which
        -- will smooth out the corners into curves."
        --
        -- `heading` IS NO LONGER READ ON A FLIGHT NODE, and that is the fix for
        -- the other half of the same report ("the camera facing direction
        -- changes too suddenly"). A per-node heading is a per-node ROTATION and
        -- a chain of them is a chain of turns. Every step of the flight now
        -- looks at ONE moving aim point -- the lobby mark, sliding onto the
        -- locker's exact aim over the last of the path -- so the whole descent
        -- is a single continuous rotation with nothing to snap between. The
        -- headings are kept because they are the survey and because the three
        -- of them are within 18 degrees of "look at the lobby" anyway.
        --
        -- `pitch` and `fov` per node are likewise unused by the flight now; the
        -- pitch is whatever looking at the aim point requires.
        camPath = {
            { x = 5550.24, y = -5555.91, z = 175.34, heading = 132.4 },
            { x = 5189.63, y = -5747.61, z =  66.61, heading =  99.5 },
            { x = 5072.10, y = -5738.05, z =  31.77, heading =  64.8 },
        },

        -- ═══ THE WHOLE FLIGHT, AND IT DECELERATES ═══
        --
        -- How long the camera takes to get from the first node above to the
        -- lobby frame, start to finish, INCLUDING the landing.
        --
        -- ═══ IT NO LONGER MATCHES `walkTargetMs`, AND THAT IS DELIBERATE ═══
        --
        -- It was 18000, matched to the walk, off "The camera flight and the
        -- walk should finish together". Then: "Also the lobby camera moves too
        -- slow. Let's do 30% faster" (owner, 2026-08-29).
        --
        -- 18000 / 1.3 = 13846, which is SPEED thirty percent higher. The other
        -- reading -- duration times 0.7, or 12600 -- is a bigger change than
        -- the words ask for, so this is the conservative one; it is one number
        -- to change if he meant the other.
        --
        -- SO THE CAMERA NOW PARKS ABOUT FOUR SECONDS BEFORE THE PED ARRIVES.
        -- They still START together (both wait on the same reveal); they no
        -- longer finish together, because he asked for the first thing more
        -- recently than the second. /brlobbywalk prints the measured gap, and
        -- `arriveGraceMs` below is measured from when the WALK is due rather
        -- than from the parking precisely so this number can move again without
        -- quietly turning the failsafe into a teleport.
        camFlightMs = 13846,

        -- ═══ TWO SETTINGS FOR SMOOTHNESS, AND THEY ARE NOT THE SAME THING ═══
        --
        -- Owner, 2026-08-29: "the camera movements in the lobby should be 2x
        -- smoother please. And round the corners once more. I mean like 2x the
        -- resolution of points."
        --
        -- `camSteps` IS THE RESOLUTION -- how many moves the flight is cut into.
        -- Each one is a linear interpolation between two static cameras with NO
        -- ease at either end, so the camera never stops: the next move picks it
        -- up at the speed the last one left it. Doubling it halves both the time
        -- and the distance per move, which halves how far the shot turns in any
        -- one of them. That is his "2x the resolution of points", and it was 24.
        --
        -- IT DOES NOT ROUND ANYTHING. More samples along the same curve is
        -- smoother MOTION over identical GEOMETRY -- the path still turns
        -- exactly as tightly as the spline says. `camRounding` below is the
        -- other half of the sentence.
        --
        -- THE COST IS TWO CAMERAS BUILT AND ONE DESTROYED PER STEP. At 48 over
        -- a 13.8s flight that is one move every 288ms, which is far longer than
        -- a frame -- there is no per-step work that does not scale, and the
        -- retiring camera is destroyed on every move rather than deferred (see
        -- dropRetiring in lobbycam.lua), so twice the steps is twice the
        -- allocations and the same number of LIVE cameras: two.
        camSteps = 96,

        -- THE SHORTEST A SINGLE MOVE MAY BE, IN MILLISECONDS.
        --
        -- NOT A KNOB, A FLOOR. The step spacing puts boundaries where the shot
        -- moves fastest, and on a path whose sharpest bend is its final approach
        -- that clusters very short steps at the landing -- 11ms on the current
        -- survey. A move shorter than a frame has no frame to interpolate
        -- across, so the engine resolves it as a cut, and several in a row is a
        -- stutter arriving exactly where the smoothing was aimed.
        --
        -- 17ms is one frame at 60fps. Raising it past about a tenth of
        -- camFlightMs / camSteps stops being a floor and starts being the
        -- schedule; the client ignores it entirely if there is no room for it.
        camStepMinMs = 17,

        -- ═══ AND THIS IS HOW WIDE IT SWINGS THROUGH EACH CORNER ═══
        --
        -- "And round the corners once more." -- the owner, 2026-08-29, about the
        -- path he had then.
        --
        -- The flight is a spline through the authored nodes, and this scales the
        -- TANGENT it carries through each one: bigger tangents mean the camera
        -- commits to a turn earlier and leaves it later, spreading the direction
        -- change over a longer arc instead of pivoting near the node. 0.5 is a
        -- plain Catmull-Rom, which is what the flight was before this was a knob.
        --
        -- ═══ IT WAS 0.75, AND THE NEW SURVEY TURNED IT UPSIDE DOWN ═══
        --
        -- ON THE OLD PATH IT HELPED, because that path had a 69-degree corner at
        -- its last node and rounding is what a 69-degree corner needs. The path
        -- surveyed on 2026-08-30 does not: it turns 32.6 degrees at node 2 and
        -- 19.7 at node 3. There is far less corner to soften, and the cost of
        -- reaching for it did not go down with it. Measured on THIS path:
        --
        --   rounding   sharpest bend    worst per-step turn
        --     0.30       8.40 deg/m
        --     0.50       7.23 deg/m           1.53 deg   <-- recommended
        --     0.60       7.16 deg/m
        --     0.75      13.13 deg/m           2.36 deg   <-- shipped
        --     1.00      42.59 deg/m           3.91 deg
        --
        -- WHY THE CLIFF MOVED DOWN, in one number: a node's tangent is scaled
        -- from the chord between its NEIGHBOURS, and the last two control
        -- segments here are 123m and 37.8m. So the tangent steering that final
        -- 37.8m stretch spans 159m of chord -- 2.1 times the segment at 0.50,
        -- 3.2 at 0.75, 4.2 at 1.00. A tangent several times longer than the
        -- segment it steers is a curve that swings wide and has to come back,
        -- and the bend it puts in on the way back is sharper than the corner it
        -- was sent to soften.
        --
        -- SO 0.75 IS NOW PAST THE CLIFF RATHER THAN BELOW IT. IT IS LEFT AT 0.75
        -- ANYWAY, deliberately: it is his knob, he has not asked for it to move,
        -- and 2.36 degrees per step is still better than the 3.32 he accepted
        -- last round -- so this is a free improvement available rather than a
        -- regression to fix. 0.50 is the recommendation whenever he wants it;
        -- it is one character.
        --
        -- THE EARLIER ADVICE THAT THIS COULD SAFELY GO TO 1.0 IS WITHDRAWN. On
        -- this path 1.0 is six times the bend of 0.5 and nearly three times the
        -- per-step turn. Raising it is a decision to make against a fresh
        -- measurement, never from the last one.
        --
        -- IT MOVES THE PATH, NOT THE PACE. The flight still takes camFlightMs
        -- whatever this is -- a rounder corner is a slightly longer path flown
        -- in the same time, so the effect on speed is a percent or two.
        camRounding = 0.75,

        -- ═══ HOW THE SPEED IS SHARED OUT ACROSS THOSE STEPS ═══
        --
        -- Owner, 2026-08-29: "The speed is too slow at the beginning and too
        -- fast at the end. Over the course of the final move the camera should
        -- slow down exponentially."
        --
        -- Every step lasts the same number of milliseconds; what changes is how
        -- much of the path it covers. The distance covered by time `s` (0..1)
        -- is (1 - e^-ks) / (1 - e^-k), so the SPEED is proportional to e^-ks --
        -- exponential decay, from the first frame to the last. One curve
        -- answers both halves of the report: it is fastest at the start and it
        -- is still decelerating, exponentially, through the final move.
        --
        -- 0 would be the old flat pace. 2.0 opens at about 2.3x the average and
        -- lands at about 0.3x it. Higher is a more violent swoop; lower is
        -- flatter. THIS IS A LOOK, NOT A MEASUREMENT -- tune it by eye.
        camDecay = 2.0,

        -- STREAMING LEADS THE REVEAL. SetFocusPosAndVel is pointed at the
        -- flight's DESTINATION -- the lobby frame it lands on -- this long
        -- before the screen fades in (owner, 2026-08-29: "1 second before
        -- fading in"). It moves where the engine STREAMS and nothing else; it
        -- has no bearing on which entities exist for this client.
        --
        -- IT USED TO POINT AT THE FIRST CAMERA NODE, which was the same owner's
        -- instruction on 2026-08-29 and which he revised on 2026-08-31 after
        -- watching the finished flight: "the textures are consistently not
        -- loading fully when the lobby cam arrives at the destination". The
        -- reasoning for the reversal lives on BR.LobbyPed.focusAhead in
        -- br_core/client/lobbyped.lua.
        --
        -- SO THIS NUMBER IS NO LONGER THE WHOLE LEAD, and raising it buys much
        -- less than it used to. The destination now streams for this PLUS the
        -- entire camFlightMs beneath it -- about fifteen seconds -- because the
        -- focus is not moved again until the entrance ends.
        focusLeadMs = 1000,

        -- How long the loading screen will hold for this sequence to get its
        -- ped onto the start mark before revealing anyway. Bounded like every
        -- other wait on that path: a boot that never shows the lobby is worse
        -- than a boot that skips a walk.
        armWaitMs = 4000,

        -- ═══ THE WALK DOES NOT START UNTIL THERE IS SOMEBODY WATCHING ═══
        --
        -- Owner, 2026-08-29: "when coming back from the warmup or another
        -- match, the ped doesn't do the full walk again."
        --
        -- IT DID THE FULL WALK. Most of it happened behind the cover the trip
        -- home was still holding -- see the long note in
        -- br_core/client/lobbyped.lua. Both the walk and the camera flight now
        -- wait for the screen to be uncovered before they start, and this is
        -- the ceiling on that wait: a cover that never lifts must cost a walk
        -- that starts anyway, never an entrance that never happens.
        --
        -- Sized off the longest legitimate cover on any road home: the leaving
        -- curtain's own 15s watchdog is the outer bound, and this sits inside
        -- it so a stuck curtain still gets a walk.
        revealWaitMs = 10000,

        -- ====================================================================
        -- THE EMOTES.
        -- ====================================================================
        --
        -- STOCK GTA ANIMATION DICTIONARIES AND CLIPS, sourced the same way the
        -- walk clipsets above were: the owner named them from a separate emote
        -- resource's MENU, and these are the game's own animations that its
        -- table maps those labels to. Nothing in this project requires,
        -- references or checks for that resource.
        --
        -- Provenance, per entry, is the file/line comment beside it --
        -- client/AnimationList.lua, blob 6868fc5, 23,862 lines.
        --
        -- `flags` IS TaskPlayAnim's animation flag field and it is the only
        -- part of this that is not a name:
        --     0  full body, plays once, the ped does nothing else
        --    48  = 16 (upper body only) + 32 (secondary / allow movement):
        --         plays OVER a walk without taking the legs
        emotes = {
            -- (a) A WINNING RETURN, at the second-to-last walk point, facing
            -- the camera. The walk PAUSES for it, so a win is longer than a
            -- loss by roughly `ms`.
            --
            -- FULL BODY, because it is a backflip. Its source entry carries no
            -- options at all -- no loop, and notably no "moving" flag -- so
            -- there is no version of this that plays over a walk.
            -- AnimationList.lua:7966  ["flip"]
            win = {
                dict  = 'anim@arena@celeb@flat@solo@no_props@',
                clip  = 'flip_a_player_a',
                flags = 0,
                ms    = 3200,   -- the cap; the clip's own end is watched for
                turnMs = 500,   -- turning to face the camera before it starts
            },

            -- (b) PARKED IN THE LOBBY, ONCE. "once the ped is parked, if they
            -- are not in the locker screen, play the 'stretch 3' emote after 30
            -- seconds, and make sure it only plays once per lobby view."
            --
            -- FULL BODY: its source entry is a LOOPING idle with no moving
            -- flag, so it holds the ped -- which is fine, the ped is parked.
            -- `ms` is what stops it looping forever.
            -- AnimationList.lua:8243  ["stretch3"]
            idle = {
                dict    = 'mini@triathlon',
                clip    = 'idle_d',
                flags   = 0,
                ms      = 4500,
                afterMs = 30000,
            },

            -- (c) READY UP. "play 'thumbs up 3' for 600ms then clearpedtasks.
            -- Make sure clearpedtasks runs before fade to black if they are
            -- accepted to warmup."
            -- AnimationList.lua:7625  ["thumbsup3"]
            ready = {
                dict  = 'anim@mp_player_intincarthumbs_uplow@ds@',
                clip  = 'enter',
                flags = 48,
                ms    = 600,

                -- ═══ AND HOW MUCH LONGER IT MAY RUN IF THERE IS ROOM ═══
                --
                -- Owner, 2026-08-29: "When pressing ready up, the thumbs up
                -- emote doesn't have enough time to complete before we fade to
                -- black. Add 500ms there please."
                --
                -- SO THE GESTURE'S WINDOW IS ms + holdMs, 1100ms, AND THE
                -- SCREEN GOING BLACK IS WHAT ENDS IT EARLY. Both of his
                -- constraints are live at once -- the animation must finish AND
                -- ClearPedTasks must run before the screen is dark -- and they
                -- are only compatible because the client can ask the page when
                -- the screen is ACTUALLY dark rather than guess. See the
                -- `br:ui:covered` listener in br_core/client/lobbyped.lua.
                --
                -- WHAT IT ACTUALLY GETS TODAY IS ABOUT 600ms OF THAT 1100.
                -- br_ui's curtain goes up on the same edge the server names the
                -- player a participant, and takes its own 600ms to reach
                -- opaque; the gesture is cut when it does. That is four times
                -- what it had before this number existed and a little more than
                -- the 600ms he originally asked for -- but it is not 1100.
                --
                -- GOING PAST THAT NEEDS THE CURTAIN TO WAIT, which is
                -- client/state.lua's enterMatchBehindCurtain, and that curtain
                -- exists (#124) to hide the cut this would then uncover. It is
                -- a real trade and it is the owner's to make; raising this
                -- number alone will not do it.
                holdMs = 500,
            },

            -- (d) THE CAMERA REACHING ITS SECOND-TO-LAST NODE. The ped is
            -- still WALKING when that happens, so this is the one emote that
            -- has to play over a walk -- flags 48. Its source entry is marked
            -- as a moving emote, which is what says the game has an upper-body
            -- version of it.
            -- AnimationList.lua:7723  ["wave"]
            wave = {
                dict  = 'friends@frj@ig_1',
                clip  = 'wave_a',
                flags = 48,
                ms    = 2500,
            },

            -- (e) MY SQUAD HAS READIED AND IS WAITING ON ME. "play any
            -- variation of 'wait*' emotes except 'wait 9'".
            --
            -- THIRTEEN EXIST AND wait9 IS OMITTED HERE rather than filtered in
            -- the client, so the exclusion is visible in the one place somebody
            -- would come looking to add one back.
            --
            -- wait12 IS ALSO OMITTED, and that is a judgement rather than an
            -- instruction: upstream pairs dictionary `rcmjosh1` with the clip
            -- `keeper_base`, which belongs to a different dictionary in the
            -- entry above it. It looks like a copy-paste and would present as
            -- an emote that silently does nothing. Add it back if it works.
            --
            -- All of these loop, and all of them are marked as moving emotes;
            -- the ped is parked while they play, so flags 0 is fine and `ms`
            -- is what ends the loop.
            -- AnimationList.lua:6341-6457  ["wait".."wait13"]
            waiting = {
                ms    = 4000,
                flags = 0,
                clips = {
                    { dict = 'random@shop_tattoo',                                    clip = '_idle_a' },          -- 6341 wait
                    { dict = 'missbigscore2aig_3',                                    clip = 'wait_for_van_c' },   -- 6350 wait2
                    { dict = 'amb@world_human_hang_out_street@female_hold_arm@idle_a', clip = 'idle_a' },          -- 6359 wait3
                    { dict = 'amb@world_human_hang_out_street@Female_arm_side@idle_a', clip = 'idle_a' },          -- 6368 wait4
                    { dict = 'missclothing',                                          clip = 'idle_storeclerk' },  -- 6377 wait5
                    { dict = 'timetable@amanda@ig_2',                                 clip = 'ig_2_base_amanda' }, -- 6386 wait6
                    { dict = 'rcmnigel1cnmt_1c',                                      clip = 'base' },             -- 6395 wait7
                    { dict = 'rcmjosh1',                                              clip = 'idle' },             -- 6404 wait8
                    { dict = 'timetable@amanda@ig_3',                                 clip = 'ig_3_base_tracy' },  -- 6422 wait10
                    { dict = 'misshair_shop@hair_dressers',                           clip = 'keeper_base' },      -- 6431 wait11
                    { dict = 'rcmnigel1a',                                            clip = 'base' },             -- 6449 wait13
                },
            },

            -- How long to wait for one animation dictionary to stream before
            -- giving up on that emote. BOUNDED, like every other stream wait
            -- here: a dictionary that will not arrive costs one gesture, never
            -- a walk that stops halfway.
            dictWaitMs = 2000,
        },
    },

    -- Routing buckets. Lobby and warmup are fixed SHARED buckets; matches
    -- allocate upward from matchBase. The warmup pad is communal (user call,
    -- 2026-08-04): everyone waiting for any flight stands there together and
    -- watches departures -- riders only hop to their match's own bucket a
    -- few seconds after wheels-up (bus.lua schedules it), jumpers the moment
    -- they leave the plane.
    lobbyBucket     = 1,
    warmupBucket    = 2,
    matchBucketBase = 100,

    -- VOICE. FiveM ships its own Mumble server and client, so there is no
    -- third-party voice resource here and none is wanted.
    --
    -- WHAT THE ENGINE DOES NOT DO FOR US: proximity voice is computed from
    -- player POSITIONS, and two matches occupy the same coordinates. Routing
    -- buckets stop players seeing each other; they are not documented to stop
    -- players HEARING each other, and betting a whole match's comms on an
    -- undocumented side effect is how you find out in front of 48 people.
    --
    -- So every match gets its own Mumble channel explicitly. ONE channel per
    -- player -- the match's proximity room -- and squadmates are reached by
    -- NAME instead of by room. See BR.Config.Match.voice.range below and
    -- br_core/client/voice.lua for why the squad room was removed (#157).
    --
    -- Channel numbers are opaque integers to the client. They are derived
    -- from matchId, which is NEVER public (roster.lua PUBLIC_FIELDS), so the
    -- server hands each player their number over VOICE_SET.
    voice = {
        enabled          = true,

        -- ==================================================================
        -- HOW FAR A VOICE CARRIES. TWO NUMBERS, BECAUSE THERE ARE TWO JOBS.
        --
        -- #157, first report: "even when set to nearby (while in squads or
        -- solos), the channel is global." Everybody heard everybody at any
        -- range, because nothing ever told Mumble a distance.
        --
        -- #157, second report, after a distance WAS supplied: "regardless of
        -- distance, 'nearby' doesn't output audio." Silent at every range,
        -- including nose to nose, while the talking indicator kept naming
        -- people. That is the engine's own behaviour and not a bug in these
        -- numbers: MUMBLE_SET_AUDIO_INPUT_DISTANCE / _OUTPUT_DISTANCE switch
        -- MumbleAudioOutput onto a listener-to-speaker position comparison,
        -- and a speaker whose position it does not have is silenced outright
        -- rather than treated as near. So those natives are no longer called.
        --
        -- BOTH NUMBERS ARE ENFORCED BY THE CLIENT NOW, one player at a time,
        -- with MUMBLE_SET_VOLUME_OVERRIDE_BY_SERVER_ID -- 0.0 for somebody out
        -- of range, 1.0 for a squadmate on the radio, and no override at all
        -- for somebody inside `nearby`, which leaves the engine to mix them
        -- positionally as it always has. See br_core/client/voice.lua.
        --
        -- THE CUTOFF IS BINARY, NOT A CURVE: in range at full volume, out of
        -- range at nothing, no fade. `setr voice_useNativeAudio true` in
        -- server.cfg changes how the edge sounds; see server.cfg.example, and
        -- do it after the range has been checked rather than with it.
        --
        -- WHY THERE ARE STILL TWO NUMBERS, AND WHY ONLY ONE OF THEM IS LIVE.
        --
        -- THE MODES ARE EXCLUSIVE. 'nearby' is proximity and only proximity;
        -- 'squad' is the pma-voice radio and only the radio. Not one on top of
        -- the other -- see BR.VoiceRouting in br_lib/shared/enums.lua, which is
        -- where a mode is defined, and the block at the top of
        -- br_core/client/voice.lua for the rounds that were lost to layering
        -- them.
        --
        -- SO `nearby` BELOW IS THE ONLY NUMBER THAT DOES ANYTHING. `squad` is
        -- vestigial: a radio channel does not attenuate, so squad voice has no
        -- range to configure and the client never reads this value. It is still
        -- SENT (server/voice.lua's VOICE_SET payload) and still asserted on by
        -- tools/test_roster.lua, which is the only reason it is still here --
        -- see the marked follow-up beside `squadRange` in that file.
        range = {
            -- Ordinary speech, in metres. Deliberately short: being heard is
            -- a positional tell, and a wide radius turns every rooftop into a
            -- public address system.
            nearby = 25.0,

            -- Squadmates, in metres. THE DEFAULT IS PAST THE MAP DIAGONAL
            -- (8 km x 11.5 km, so ~14 km corner to corner), which means squad
            -- comms never cut out anywhere a player can stand. That is the
            -- point of squad comms and 25 m would not be squad comms.
            --
            -- It is a real cutoff, not a synonym for infinity, so it is worth
            -- knowing what the alternatives buy:
            --   16000  never cuts out. The default.
            --    3500  the opening storm circle (Config.Storm.radius0) --
            --          squad comms cover the play area and no further, so a
            --          squadmate who has not left the bus zone stays reachable
            --          but one who has run to the far coast does not.
            --     100  a "shout" band: squads keep contact through a fight
            --          without a map-wide radio. Harsher, and legitimate.
            squad  = 16000.0,
        },

        -- Channel id bases. Kept far apart and far from 0, which is the
        -- default channel every client starts in.
        lobbyChannel     = 1000,
        warmupChannel    = 1001,
        matchBase        = 2000,   -- + matchId

        -- WHETHER THERE IS A SQUAD RADIO AT ALL.
        --
        -- `false` means no squad is ever assigned a channel and no squadmate
        -- list is ever sent, so the 'squad' setting has nothing to route and
        -- becomes indistinguishable from 'off' for the player who picks it.
        -- That is the honest reading now that the modes are exclusive: it used
        -- to mean "squads are proximity-only", and there is no such thing any
        -- more -- proximity-only IS 'nearby', and it is one click away in the
        -- settings screen.
        --
        -- Turning this off is therefore a decision to ship a mode that does
        -- nothing, and it should come with removing the option from the
        -- settings screen (ui-src/src/screens/Settings.tsx, VOICE_MODES).
        squadIsGlobal    = true,
    },

    -- HEALTH UNITS -- read this before touching any health number anywhere.
    --
    -- There are two scales in play and mixing them is the most likely source of
    -- a subtle balance bug in this project:
    --
    --   ENGINE health  100..200, where 100 means dead for a player ped. This is
    --                  what GetEntityHealth and SetEntityHealth speak.
    --   DISPLAY health 0..100, what the player sees and what every gameplay
    --                  number in config uses (consumables, DBNO revive HP).
    --
    -- Everything in config/*.lua is DISPLAY units. Convert at the engine
    -- boundary with BR.ToEngineHp / BR.ToDisplayHp -- never inline the arithmetic.
    --
    -- THE FLOOR IS 100, the convention after all. A 2026-08-02 note here
    -- claimed an in-game verification of floor 0 -- that verification misread
    -- a corpse: GetEntityHealth returns 0 AFTER death, so a dead body "proves"
    -- 0 while the living range never actually dips below 100. The live
    -- measurement that settled it (2026-08-04): a player died with the health
    -- bar at exactly 50%, which under a 0..200 display mapping is precisely
    -- the engine-100 death threshold announcing itself.
    maxHealth       = 200,    -- engine units
    healthFloor     = 100,    -- engine units; at or below this a player ped is dead
    maxArmour       = 100,    -- armour is already 0..100 natively, no conversion

    -- DBNO. Squads by default; solos only while carrying a CPR kit (#191), which
    -- is the one thing that can pick a lone player up. The numbers below apply
    -- to both -- a solo on the floor bleeds on the same clock, and it is the
    -- clock the ambulance is racing.
    --
    -- TWO MINUTES ON THE FIRST KNOCK, up from 45 seconds (owner, playtest:
    -- "The DBNO bleed out timer seems awfully short. We should probably double
    -- it at least. It should be 2 minutes minimum").
    --
    -- THE OTHER TWO MOVED WITH IT, AND THAT IS THE POINT. The escalation is a
    -- SHAPE, not three independent numbers: knock N is meant to be a fixed
    -- FRACTION of the first, so a squad cannot farm revives out of one long
    -- fight. Raising only the base would have flattened it -- at -8s a step the
    -- second knock would have dropped 18% of a 45s bleed and 7% of a 120s one,
    -- which is the same table describing a different rule. Scaled by the same
    -- 120/45, the curve is identical in proportion and only the units changed:
    --
    --   knock  1      2      3      4      5      6
    --   was    45s    37s    29s    21s    15s    15s   (floor)
    --   now    120s   99s    78s    57s    40s    40s   (floor)
    --
    -- dbnoBleedPerDamage below moved for the same reason -- see its note.
    dbnoBleedBase   = 120,    -- seconds on the first knock
    dbnoBleedStep   = -21,    -- each subsequent knock in the same match is shorter
    dbnoBleedMin    = 40,
    -- SECONDS OF HELD INTERACT. 2.8, down 65% from the 8.0 that shipped
    -- (owner, 2026-08-17: "the revive button hold from last round took too
    -- long - let's cut it by like 65%").
    --
    -- THIS IS THE ONLY NUMBER, and that is worth stating because a hold
    -- duration is the classic thing to end up hardcoded twice -- once for the
    -- rule and once for the picture that draws it. Everything reads this key:
    -- server/combat.lua measures the hold against it and reports progress as a
    -- fraction of it, client/dbno.lua sends it to the prompt as `holdMs`, and
    -- br_ui/dui/prompt.html sets the ring's animation-duration from that
    -- message and from nothing else. Change it here and the ring closes with
    -- the revive, on its own.
    dbnoReviveTime  = 2.8,
    dbnoReviveDist  = 1.5,
    dbnoReviveHp    = 30,     -- displayed HP after a successful revive

    -- WHAT SHOOTING A DOWNED PLAYER DOES (owner's call, 2026-08-09): it takes
    -- time off the bleed rather than health off a second health bar. There is
    -- no knocked-HP pool, because the bleed timer already IS the downed
    -- player's health -- denominated in seconds, visible to them as a
    -- countdown, and visible to everyone else as a body still crawling.
    --
    -- THE NUMBER IS A GUESS AND IS WRITTEN DOWN AS ONE, like the molotov's 42.
    -- The guess is not the seconds, it is the ROUND COUNT: four rifle rounds
    -- finish a fresh knock, a shotgun blast (~90 damage) takes about a third of
    -- it. That is the property this key exists to hold, and it is why the number
    -- had to move when dbnoBleedBase went from 45s to 120s -- at 0.35 the same
    -- four rounds would have taken 42 seconds off a two-minute clock, so
    -- finishing somebody would have needed eleven of them and shooting a downed
    -- player would have stopped being a thing anybody does.
    --
    -- 0.93: 30 damage -> 27.9s, four rounds -> 111.6s of a 120s knock, a shotgun
    -- blast -> 84s. Still a guess, still never played. Tune it before defending
    -- it -- but tune it against the round count, not against the seconds.
    dbnoBleedPerDamage = 0.93,

    -- The display health the LEDGER holds a downed player at. It has to be
    -- greater than zero for two separate reasons and both are load-bearing:
    -- BR.Damage.applyHit only sends the shooter their `netId`/`hp` correction
    -- while the victim's hp is above zero (that correction is what stops a
    -- downed player reading as a permanent corpse on the shooter's screen),
    -- and the roster's own health sampling would otherwise see a zero and hand
    -- the server-observed death check a body to eliminate.
    dbnoHp          = 5,

    -- Slack on the SERVER's revive distance check, in metres. Positions are
    -- sampled at 250ms, so the server's idea of where two players are standing
    -- is always slightly behind the client's -- the same skew the loot claim
    -- check allows for, for the same reason.
    dbnoReviveSlack = 1.0,

    -- How long the server keeps a revive alive without hearing from the client
    -- holding it. The client re-asserts every 250ms; three misses drops it.
    -- This exists because a single lost REVIVE_STOP once handed out a completed
    -- eight-second hold for a brief tap -- progress has to require continuous
    -- evidence rather than trusting one message to arrive.
    dbnoReviveBeatMs = 750,

    -- The crawl. Metres per second and degrees per second: none of the downed
    -- animations this build has is a locomotion clipset, so client/dbno.lua
    -- drives the ped by hand and these are real units rather than a multiplier
    -- on a walk that is not happening.
    dbnoCrawlSpeed  = 0.55,
    dbnoTurnRate    = 90.0,

    -- How high above the body the revive prompt floats. Low, because the body
    -- is lying down -- at the standing 0.9 it hovered well clear of the player
    -- it belonged to (owner, in game).
    dbnoPromptLift  = 0.35,

    -- Server-side sampling and broadcast rates. These are the knobs to turn if
    -- the server tick starts running long at full player count.
    --
    -- posSampleHz SAID 2 AND THE SAMPLER RAN AT 4, for as long as both have
    -- existed: roster.lua hardcoded `BR.Sched.every(250, ...)` and nothing read
    -- this value at all. So the knob documented here was not a knob, and the
    -- number it advertised was the one that had been TRIED AND REJECTED.
    --
    -- 4 Hz IS THE RATE, AND IT IS NOT NEGOTIABLE DOWNWARD (owner, confirmed).
    -- Squad beacons are drawn straight from this sampling, and at 2 Hz a
    -- teammate's dot visibly hopped rather than moved; it also halves the
    -- staleness the loot claim check has to tolerate. Anyone reaching for this
    -- to save server tick should read that sentence first -- 2 has already been
    -- shipped, played and reverted, so lowering it is a repeat rather than an
    -- experiment.
    --
    -- The value is now READ (br_core/server/roster.lua derives the scheduler
    -- interval from it) and tools/test_roster.lua fails if the two ever
    -- disagree again, which is what makes this line worth trusting.
    posSampleHz     = 4,
    deltaFlushHz    = 4,
    digestHz        = 2,

    -- Kill attribution: how long after taking damage a player still counts as
    -- having been killed by the attacker, so storm or fall damage finishing a
    -- wounded player still credits the shooter.
    assistWindowMs  = 10000,
}

-- Ambient world life inside matches, as fractions of GTA's defaults. The
-- routing-bucket population flag is the on/off switch (roster.applyBucket);
-- these throttle the amount, per-frame in gamerules. Parked cars run full
-- -- they are scenery and, eventually, loot context.
BR.Config.Ambient = {
    peds         = 0.3,
    scenarioPeds = 0.3,
    -- Raised from 0.19 (user, 2026-08-05: more vehicles, on and off road).
    -- A battle royale needs rotation: a circle two kilometres away with no
    -- car in sight is a walk, not a decision. Still well under vanilla, which
    -- fills the freeway bumper to bumper.
    vehicles     = 0.45,
    -- Parked cars are where OFF-ROAD vehicles actually come from -- GTA's
    -- density natives cannot filter by class, and the roaming traffic model
    -- is overwhelmingly city cars on city roads. Full density means every
    -- farm, quarry and trailhead has its own truck standing in it.
    parked       = 1.0,
    -- Ambient drivers drive BADLY: zero ability, maximum aggression --
    -- the apocalypse does not produce calm commuters.
    erratic      = true,

    -- HOW BADLY. The first pass used style 786468 at 30 m/s and still read as
    -- calm, and the reason is in the flags: 786468 is
    -- avoid-vehicles + avoid-objects + shortest-path + stay-on-road, so a
    -- "rushed" driver still politely drove round everything in its way.
    --
    -- 262656 is shortest-path (262144) + allow-wrong-way (512) and NOTHING
    -- else. What is missing is the point: no stopping at lights, no avoiding
    -- vehicles, no avoiding peds, no avoiding objects. They take the quickest
    -- line to wherever they are going and drive through whatever is on it.
    --
    -- Paired with ability 0.0 (worst possible driver) and aggression 1.0,
    -- which together decide how much they oversteer and how willingly they
    -- ram. Deliberately NOT panic: peds fleeing gunfire is a different system
    -- and not what is wanted here (user, 2026-08-07) -- these are commuters
    -- who drive like maniacs, not civilians running for their lives.
    erraticStyle      = 262656,
    erraticSpeed      = 45.0,    -- m/s cruise target (was 30)
    erraticAbility    = 0.0,     -- 0 = worst driver in Los Santos
    erraticAggression = 1.0,
    erraticRange      = 250.0,
    -- Re-tasked this often rather than once ever: the engine replaces a ped's
    -- task on collisions and arrivals, and a driver that reverts stays calm
    -- for the rest of its life.
    erraticRetaskMs   = 8000,
}

-- Sprint stamina, Fortnite-shaped: a meter that drains while sprinting and
-- recharges after a beat off the key. OUR meter is the only limiter -- GTA's
-- own stamina stat is kept topped up (running it dry drains HEALTH, which
-- has no place here). Client-side and cosmetic-plus-controls only; nothing
-- about it crosses the wire.
BR.Config.Stamina = {
    max          = 100.0,
    -- 12.5 was ~8 seconds of sprint, which a second playtester called too
    -- short (2026-08-07). 6.5 gives about 15 -- long enough to cross a street
    -- and break line of sight, which is what the meter is for, without making
    -- it free.
    -- 100 / 7.8: cut 35% off the twelve-second version (user, 2026-08-07).
    -- The meter is for breaking line of sight, not for crossing a district.
    drainPerSec  = 12.82,
    regenPerSec  = 25.0,   -- ~4 seconds to refill
    regenDelayMs = 900,    -- breath caught before the refill starts
    minToSprint  = 15.0,   -- an emptied meter must climb back here to sprint
}

--- Resolve the minimum players to start, honouring dev mode.
--- @param devMode boolean
--- @return integer
function BR.Config.Match.MinPlayers(devMode)
    if devMode then
        return BR.Config.Match.minToStart
    end
    return BR.Config.Match.minToStartProd
end

--- Resolve the minimum number of squads a squad match needs, honouring dev mode.
--- @param devMode boolean
--- @return integer
function BR.Config.Match.MinSquads(devMode)
    if devMode then
        return BR.Config.Match.minSquadsDev
    end
    return BR.Config.Match.minSquads
end

-- Health conversion. The only two places that know about the engine's offset.

--- Display health (0..100) -> engine health.
--- @param display number
--- @return integer
function BR.ToEngineHp(display)
    local M = BR.Config.Match
    local span = M.maxHealth - M.healthFloor
    local v = M.healthFloor + BR.Clamp(display, 0.0, 100.0) * (span / 100.0)
    return math.floor(v + 0.5)
end

--- A display-unit DELTA (damage or heal amount) -> engine units. Deltas scale
--- by the span only -- no floor offset, that is for absolute values.
--- @param display number
--- @return number  engine delta, NOT rounded (callers decide how to carry fractions)
function BR.ToEngineHpDelta(display)
    local M = BR.Config.Match
    return display * (M.maxHealth - M.healthFloor) / 100.0
end

--- Engine health -> display health (0..100).
--- @param engine number
--- @return number
function BR.ToDisplayHp(engine)
    local M = BR.Config.Match
    local span = M.maxHealth - M.healthFloor
    if span <= 0 then return 0.0 end
    return BR.Clamp((engine - M.healthFloor) * (100.0 / span), 0.0, 100.0)
end

--- Is this engine health value a dead player ped?
--- @param engine number
--- @return boolean
function BR.IsDeadHp(engine)
    return engine <= BR.Config.Match.healthFloor
end

--- M6 combat validation.
---
--- THE SEQUENCING THAT GOT US HERE, kept because it is the reusable part.
--- FiveM's weaponDamageEvent payload is not documented anywhere authoritative,
--- so nothing was enforced until real payloads had been recorded with
--- /brdamagelog and the field names were facts rather than guesses. Then the
--- validator ran in log-only mode for a full playtest, on the rule that every
--- refusal printed during honest play is a FALSE POSITIVE. That log came back
--- empty (2026-08-07), which is what unlocked both flags below.
---
--- Guessing the field names and shipping enforcement on top of them is exactly
--- the pattern that cost this project six rounds on the ammo counter.
--- WHAT A MATCH REMEMBERS ABOUT A PLAYER, so an incident can carry evidence
--- rather than only an accusation.
---
--- Held in memory and discarded when the match leaves the registry. Nothing is
--- written to a database unless an incident is filed (owner call, 2026-08-14),
--- so a clean match -- nearly all of them -- costs one table and no DynamoDB
--- traffic.
---
--- Bounded because 100 players times an unbounded chat log is a memory leak with
--- a nice name. The caps are the last N, not the first N: the recent lines are
--- the ones that explain an incident, the early ones are the bus ride.
BR.Config.Evidence = {
    chatMax = 50,
    killMax = 30,
    -- Weapons the gamemode never issued, taken out of a hand. Smaller than the
    -- other two because a strip row is a timestamp and a hash: the tenth in a
    -- row says what the second already said, and it is the PATTERN that is
    -- evidence. See BR.EvidenceBuf.DEFAULTS, which this mirrors.
    stripMax = 20,
    -- Chat lines the server accepted and delivered to nobody -- a link, or a
    -- script this gamemode does not take. Sized like `stripMax` and for the same
    -- reason, and kept in a list of its own so that a player who keeps talking
    -- after a refused line cannot push it out of `chatMax` above. See
    -- BR.EvidenceBuf.DEFAULTS, which this mirrors.
    refusedMax = 20,
}

BR.Config.Combat = {
    -- Both ON as of 2026-08-07: a full playtest produced no "shot refused"
    -- lines, which is the false-positive gate this was waiting for.
    -- `/brdamage off` backs BOTH out live, without a redeploy -- flipping the
    -- takeover changes every gunfight at once and the failure mode is the kind
    -- you want to leave in one command rather than one deploy.
    enforce       = true,
    applyOwnDamage = true,
    logHits       = false,

    -- THE SERVER COUNTS THE ROUNDS NOW. Every shot arrives as a validated
    -- server event, so it can simply be counted -- which retires the M5
    -- placeholder where the client reported its own magazine and the server
    -- believed any decrease. With this on, INV_AMMO is refused outright and
    -- the reload is the server's too.
    --
    -- Backed out by `/brdamage off` along with the rest of the takeover: if
    -- the server stops applying damage it also stops seeing shots, and a gun
    -- whose magazine nothing decrements is better than one nothing refills.
    serverAmmo    = true,

    -- WHAT A REFUSAL DOES, beyond being cancelled.
    --
    -- A stream of refusals is a real signal rather than noise: the validator
    -- ran in log-only mode for a full playtest on the rule that every refusal
    -- during honest play is a FALSE POSITIVE, and that log came back empty. So
    -- somebody generating a dozen in half a minute is doing something the
    -- server did not issue them the means to do.
    --
    -- TIGHTENED TO 8 IN 10s (user call, 2026-08-08), from 12 in 30s.
    --
    -- The looser window was chosen when nothing had been measured. Since then
    -- a full playtest has produced no false positives at all, and separating
    -- rules refusals from means refusals took the ordinary-play noise out
    -- entirely -- so the countable stream is now only things with no honest
    -- explanation, and eight of those inside ten seconds is a decision rather
    -- than a bad minute.
    --
    -- THERE IS NO `refusalAction` ANY MORE (owner call, 2026-08-14). It read
    -- "log" | "notify" | "kick" and decided what the SERVER would do to the
    -- player on its own. Crossing the threshold now files an incident with the
    -- match's evidence attached and stops there; Ringmaster reads the case and
    -- decides, because it is the side that holds the ban list, the audit log
    -- and a human. A convar that still named an enforcement action would be
    -- describing a decision this file no longer makes.
    --
    -- PER MATCH, NOT PER WINDOW, AND GRADED (owner call, 2026-08-14).
    --
    -- `refusalLimit = 8` inside a rolling ten seconds is gone. The owner's verdict
    -- on it was blunt and correct: "we don't want a system that virtually never
    -- creates incidents". Eight of anything inside ten seconds describes somebody
    -- spraying with a trainer and misses somebody careful, and since the countable
    -- stream has no honest explanation at all there was never a reason to demand
    -- eight of it.
    --
    -- So the count is per MATCH -- it no longer lapses after ten seconds -- and the
    -- bar depends on how bad the reason is:
    --
    --   high    1   the server never issued the means. One is enough.
    --   normal  2   a number the weapon does not have. Real, but position
    --               sampling and a bad tick can manufacture one, so not one.
    --
    -- Which reason sits in which tier lives in BR.ShotTier (combat_solve.lua),
    -- beside the refusal enum it keys on, because keying it here would mean
    -- reading BR.ShotRefusal before combat_solve.lua has defined it -- this file
    -- loads first. `NO_WEAPON` carries a per-reason override there and the
    -- reasoning is with it.
    --
    -- SELF IS NO LONGER COUNTED AT ALL. It used to count toward the eight without
    -- earning severity, so that mixing self-harm with real refusals could not keep
    -- somebody under the bar. At a bar of one or two that argument inverts: one
    -- self-hit plus one marginal out-of-range shot would open a case, and a player
    -- could manufacture one against themselves. It is still refused and still
    -- logged; it simply no longer contributes.
    refusalBar = { high = 1, normal = 2 },

    -- KEPT, BUT NO LONGER A THRESHOLD INPUT. The summary line on an incident reads
    -- "N shots refused in Ms", and this is the M. Nothing decides anything on it.
    refusalWindowMs = 10000,

    -- HURTING YOURSELF IS ALLOWED; DOING IT REPEATEDLY IS NOT.
    --
    -- You can stand in your own grenade, and refusing that outright made
    -- explosives free to spam at your own feet. But a player taking damage
    -- from themselves three times in five seconds is exercising a path rather
    -- than playing, so the third one is refused and counted.
    selfLimit    = 2,
    selfWindowMs = 5000,

    -- ONE SWING, ONE HIT. A melee attack is an animation with several contact
    -- points and the engine may raise more than one event for it -- which is
    -- how a punch came to apply our damage twice. Duplicates inside this
    -- fraction of the weapon's own swing cycle are cancelled without being
    -- applied. Melee only: a rifle at 85ms is genuinely several hits.
    meleeDedupe  = 0.5,

    -- `damageType` IS NOT A DISCRIMINATOR, AND THIS IS THE EVIDENCE.
    --
    -- The plan was to gate the takeover on damageType. Measured with
    -- /brdamagelog:
    --
    --   bullet     WEAPON_CARBINERIFLE  damageType 3   (2026-08-06)
    --   melee      WEAPON_UNARMED       damageType 3   (2026-08-08)
    --   explosion  WEAPON_GRENADE       damageType 3   (2026-08-08)
    --   melee      WEAPON_UNARMED       damageType 1   (2026-08-08, later)
    --
    -- Three different things share 3, and one of them ALSO reports 1. The
    -- field says nothing reliable about what happened -- and gating on it meant
    -- a punch fell through to the engine, which applied GTA's own melee damage
    -- ON TOP of ours and killed a full-health player in two hits.
    --
    -- The gate is gone. `weaponType` decides, against three tables:
    -- WeaponByHash (ours -> validate and apply), Environmental (the world's ->
    -- always the engine's, so a car fire or a fall is never a refusal), and
    -- neither (a weapon nobody was issued -> the only thing worth refusing).
    -- Chasing damageType with a longer list of numbers would have left every
    -- gap in that list as a damage path handed silently back to the client.
    --
    -- Kept as a record of what was measured. Nothing reads it.
    damageTypesSeen = { 1, 3 },

    -- FIRE IS THE ENGINE'S, AND WE CANNOT HAVE IT.
    --
    -- Measured 2026-08-08: /brdamagelog armed for 15 payloads, a molotov
    -- thrown at a player, the player DIED, and not one payload printed.
    -- Burning damage does not raise weaponDamageEvent at all -- it is applied
    -- on the victim's own machine through a path the server never sees.
    --
    -- Which means our molotov `damage` number can never apply, and worse: a
    -- molotov kill was credited to NOBODY, because attribution reads the
    -- ledger and nothing ever wrote to it.
    --
    -- So explosions are attributed from a different event entirely.
    -- `explosionEvent` DOES fire server-side, carries the thrower and the
    -- position, and fires for grenades, sticky bombs and molotovs alike. We
    -- cannot take the damage over; we can absolutely say whose it was.
    --
    -- Types are GTA's own explosion enum. Only the three this gamemode issues
    -- are claimed: a petrol pump going up is not somebody's kill.
    explosionTypes = {
        [0]  = 'grenade',
        [2]  = 'sticky',
        [3]  = 'molotov',
    },
    -- How long a fire keeps crediting the person who lit it. Molotov flames
    -- burn for a good while and a player who runs through them ten seconds
    -- later was still killed by whoever threw it. Attribution only lands on
    -- players who are ACTUALLY LOSING HEALTH inside the radius, so a generous
    -- window costs nothing.
    fireLifeMs     = 20000,
    fireRadius     = 6.0,
    -- Blast attribution is instant and short: the bang either caught you or
    -- it did not.
    blastAttributeMs = 1200,

    --[[
        ROADKILL, AND IT IS THE SAME ARGUMENT AS THE FIRE LEDGER ABOVE.

        The owner, 2026-08-21 (#194): "Roadkill should be attributed to the
        driver." The engine agrees that somebody was run over -- it kills the
        ped with WEAPON_RUN_OVER_BY_CAR -- and says nothing the server can use
        about who was driving. GET_PED_SOURCE_OF_DEATH names the vehicle, and it
        is read on the victim's own machine, so a mode that took its word for it
        would let any client hand any player a free elimination.

        So it is resolved the way fires are: from state this server already
        holds. A player lost health, they were on foot, and a vehicle a PLAYER
        was driving was on top of them and moving. Every term in that sentence
        is a server-side read (br_core/server/vehicles.lua).

        `roadkillRadiusM` IS NOT A CAR'S LENGTH, and that is the whole reason it
        is 8 rather than 5. Positions are sampled at posSampleHz -- 4 Hz -- so at
        25 m/s the car has travelled 6.25 m since the sample the check runs
        against, and the ped it hit is behind it by roughly that. A radius that
        described the collision would miss the sample that proves it.

        `roadkillMinSpeedMs` IS WHAT STOPS A PARKED CAR OWNING A STORM DEATH.
        6 m/s is ~21 km/h: below it a car does not kill anybody, and above it a
        car that happens to be passing is the only false positive left. It is
        deliberately a SPEED and not a velocity toward the victim -- the server
        samples position, and two samples give a displacement whichever way the
        car was pointing.
    ]]
    roadkillRadiusM    = 8.0,
    roadkillMinSpeedMs = 6.0,
    -- How recently the server must have attributed a roadkill for the kill feed
    -- to call a death one. The same shape and the same number as the storm's own
    -- override in server/combat.lua, for the same reason: the finishing blow of
    -- a vehicular death reads to the engine as generic damage.
    roadkillCauseMs    = 3000,

    -- HOW LONG A THROWN EXPLOSIVE STAYS YOURS.
    --
    -- A grenade goes off a second or more after it leaves the hand, and
    -- throwing the last one empties the slot -- so the validator cannot ask
    -- "are you holding a grenade" when the blast lands. It asks whether the
    -- server watched you spend one recently instead.
    --
    -- This is not the security boundary; the inventory is. Nobody reaches this
    -- check without the server having issued them the explosive and seen the
    -- count fall. The window only stops that credit lasting the whole match.
    --
    -- Generous because the alternative is refusing honest kills: 30s covers a
    -- grenade cook, a bounce, and a sticky bomb stuck to a car that the thrower
    -- waits to detonate. A sticky left longer than this is refused, which is
    -- the one known limitation and is bounded by how rare stickies are.
    explosiveGraceMs = 30000,

    -- Slack, and it is load-bearing. Roster positions are sampled at 2Hz, so
    -- at the instant of a shot both players can be half a second stale --
    -- about 4.5m each at a sprint. Refusing an honest shot is a broken game;
    -- accepting a marginal one is a rounding error no aimbot can exploit.
    rangeSlack    = 1.35,   -- multiplier on the weapon's authored maxRange
    rangeSlackM   = 12.0,   -- ...plus this, for the sampling lag itself
    intervalSlack = 0.6,    -- a shot may arrive this fraction early

    headshotMult  = 2.0,

    -- How many payloads /brdamagelog captures before it stops on its own. It
    -- prints every key it sees, so this is the tool that replaces guessing.
    logSamples    = 15,

    --[[
        IS ANYBODY REFUSING TO TAKE DAMAGE. (The health audit.)

        server/roster.lua samples every ped's health four times a second and
        writes it into the same `entry.hp` that BR.Damage.applyHit subtracts
        from. The ped's health belongs to the OWNING CLIENT, so that write hands
        back the one number the whole damage model depends on: a client that
        pins its ped at full has its ledger restored 250ms after every hit, and
        the server-observed death check in server/combat.lua reads the same
        client-owned value, so the backstop misses it too.

        THIS BLOCK CHANGES NOTHING ABOUT WHAT HAPPENS TO ANY PLAYER. It counts.
        The fix is a gameplay change with a real blast radius -- the legitimate
        upward paths are med kits, shields, revives and respawns, and a ledger
        that refuses the engine outright would also refuse falls, fire and
        drowning -- so it goes behind a playtest, and this goes in first. It is
        the same order the damage validator shipped in (see `enforce` above and
        docs/security.md): measure, prove the log is empty during honest play,
        then act.

        THE NUMBERS ARE CHOSEN TO NEVER FIRE ON HONEST PLAY, in that direction
        deliberately. Every ambiguous sample is excused, because the exploit is
        not one sample -- it is the same lie four times a second for a whole
        match -- so a detector that misses its first two seconds still catches
        it, while one that fires on a bad ping gets switched off.
    ]]
    healthAudit = {
        -- OFF IS NOT A DEFAULT ANYONE HAS TO REMEMBER: this is a counter and a
        -- console line, it touches no gameplay path, and the whole point is to
        -- learn what honest play looks like. It is here so a playtest that
        -- turns up noise can be quietened without a redeploy.
        enabled = true,

        -- Rounding, not evidence. Our display value and the engine's come
        -- through different float pipelines and both get floored.
        toleranceHp     = 2.0,
        toleranceArmour = 2.0,

        -- HOW LONG AFTER THE SERVER HURT SOMEBODY THE PED MAY STILL READ HIGH.
        --
        -- This is the main false-positive control and it is the reason the bar
        -- is not tighter. The server subtracts from the ledger and TELLS the
        -- client to hurt its own ped; between those two moments the ped is
        -- legitimately higher, by exactly the damage in flight. That gap is one
        -- sample interval (250ms) plus the round trip, and a player on a bad
        -- connection is not a cheat -- so 1500ms covers a 1.2s round trip,
        -- which is worse than anybody actually plays on.
        hurtGraceMs = 1500,

        -- HOW LONG A CONSUMABLE OR A REVIVE IS ALLOWED TO KEEP CLIMBING.
        --
        -- A med kit's INV_EFFECT carries a TARGET and the client walks its own
        -- ped up to it, so the sampler reads the rise on the way past -- that is
        -- the one honest upward path the ledger does not already own. The window
        -- starts when the server issues the effect, so it covers the animation
        -- and the round trip after it.
        healSettleMs = 2000,

        -- A revive or a respawn is the LEDGER leading and the ped following, so
        -- the sample normally reads LOW rather than high. This covers the
        -- crossover: a client that applies HEALTH_SYNC early, or a resurrection
        -- that restores GTA's default health before our number lands.
        settleMs = 2000,

        -- WHAT EARNS AN OPERATOR LINE. Cumulative unexplained recovery within
        -- one match, in display points.
        --
        -- 100 IS A WHOLE HEALTH BAR AND IT IS MEANT TO READ THAT WAY: "this
        -- player has been handed back a full bar the server never issued".
        -- Honest play sits at zero -- every legitimate rise is excused by name
        -- -- so the bar is not separating signal from noise, it is waiting long
        -- enough to be certain. A working exploit crosses it inside a single
        -- fight; nothing else crosses it at all.
        reportHp     = 100.0,
        reportArmour = 100.0,
    },
}

--[[
    PLAYER REPORTS.

    The second source of incidents, after the anticheat. The anticheat sees what
    it can measure; a player sees teaming, griefing and abuse, none of which
    leave a trace in a damage ledger.

    THE CATEGORIES ARE DELIBERATELY SHORT, and "name" is not one of them (owner,
    2026-08-12): we do not control names, so a category we cannot act on would
    only teach players that reporting does nothing. Every option here is
    something an admin can actually do something about.

    THIS EXACT LIST IS THE OWNER'S, given verbatim in #143 (2026-08-16) and in
    this order. It is shorter than the one it replaces by one entry and the
    swap is not cosmetic:

      * `teaming` and `griefing` are GONE and `power_gaming` stands where both
        of them stood. The pair were two names for the same complaint -- an
        admin opening either had to read the case to find out which had been
        meant -- and the split bought nothing, because the action on both is
        the same conversation with the same player.
      * `power_gaming` is the term the server's own community already uses for
        it, so the word on the report is the word an admin will use in the
        reply.

    THE IDS ARE WHAT REACHES THE DATABASE, not the labels, and they are what a
    console query filters on. Renaming one silently orphans every row filed
    under the old spelling -- rows already written keep `teaming`, and nothing
    here rewrites them, which is correct: a record of what somebody actually
    reported must not be edited by a config change.

    A DEFAULT IS PRE-SELECTED, because a report filed with no category is still
    worth having and a required field is how you get "asdf". `cheating` is the
    default because it is both the most common and the one most worth a human
    looking at.

    RATE LIMITS ARE NOT OPTIONAL. This feature is, by construction, a way for
    any player to make the server write to DynamoDB on demand. The limits are
    per match and enforced server-side.

    THE PANEL NO LONGER ADVERTISES THEM (owner, #142: "We don't need to tell a
    player how many people they can report, or how many reports are left").
    They are enforced exactly as hard as they were; the difference is that a
    player discovers a limit by being told the reason it refused, rather than
    by reading a running total they never asked for.

    REPORT SPAM IS ITSELF A SIGNAL and is kept rather than discarded -- the
    console's "reports they filed against others" section exists precisely so
    somebody who reports everybody is visible. A refused-for-rate report is
    still counted, because the attempt is the signal.

    THERE IS NO `maxNote`, AND NO NOTE. It was deleted with #142 ("We don't
    need a custom text field for reports. Just the dropdown"), and it turns out
    it had never done anything: br_ddb has written `note: null` unconditionally
    since 2026-08-14 ("NO FREE-TEXT NOTE, EVER, FROM THE GAME") -- so a cap on
    a string that reached a page, a callback, a net event, an incident payload
    and then a hard null was three layers of plumbing around a value the
    database was already throwing away.
]]
BR.Config.Report = {
    categories = {
        { id = 'cheating',     label = 'Cheating',     default = true },
        { id = 'abusive_chat', label = 'Abusive chat' },
        { id = 'exploiting',   label = 'Exploiting' },
        { id = 'power_gaming', label = 'Power gaming' },
        -- LAST, whatever else moves. "Something else" is the option a player
        -- picks after failing to find theirs, so it has to be the one they
        -- arrive at rather than the one they meet on the way.
        { id = 'other',        label = 'Something else' },
    },

    --- Players nameable in one submission.
    maxTargets = 5,

    --- Submissions per player per match.
    ---
    --- NOT THE SAME LIMIT AS "one report per target per match" (#143), and both
    --- are live. This one bounds how many times a player can make the server
    --- write to a database; the other bounds how many times one accusation can
    --- be made to count twice. Neither implies the other: three submissions of
    --- five distinct targets is fifteen reports and is fine, and two
    --- submissions naming the same person is one report and is refused.
    maxPerMatch = 3,
}

--- The category to pre-select, resolved from the table above rather than
--- repeated as a string that could drift out of the list.
--- @return string
function BR.Config.defaultReportCategory()
    for _, c in ipairs(BR.Config.Report.categories) do
        if c.default then return c.id end
    end
    return BR.Config.Report.categories[1].id
end

--- Is this a category the server will accept?
--- @param id string
--- @return boolean
function BR.Config.isReportCategory(id)
    for _, c in ipairs(BR.Config.Report.categories) do
        if c.id == id then return true end
    end
    return false
end

--- weaponDamageEvent's `hitComponent`, decoded.
---
--- CONFIRMED IN GAME, 2026-08-07. The community mapping was suspect until a
--- deliberate headshot came back as component 20 -- exactly where the table
--- says HEAD is -- alongside a one-shot kill. Earlier samples at 0, 14 and 17
--- (pelvis, left wrist, right elbow) are consistent with spraying at a moving
--- target, so the table is taken as correct.
---
--- This is what makes damage-by-bone possible: the payload tells us WHERE the
--- round landed, so a leg hit and a headshot need not be worth the same thing.
BR.Config.HitComponent = {
    PELVIS       = 0,
    LEFT_HIP     = 1,  LEFT_LEG      = 2,  LEFT_FOOT    = 3,
    RIGHT_HIP    = 4,  RIGHT_LEG     = 5,  RIGHT_FOOT   = 6,
    LOWER_TORSO  = 7,  UPPER_TORSO   = 8,  CHEST        = 9,
    UNDER_NECK   = 10,
    LEFT_SHOULDER = 11, LEFT_UPPER_ARM = 12, LEFT_ELBOW = 13, LEFT_WRIST = 14,
    RIGHT_SHOULDER = 15, RIGHT_UPPER_ARM = 16, RIGHT_ELBOW = 17, RIGHT_WRIST = 18,
    NECK         = 19,
    HEAD         = 20,
}

--- Is this hit component a headshot?
--- @param c integer|nil
--- @return boolean
function BR.Config.IsHeadshot(c)
    local H = BR.Config.HitComponent
    return c == H.HEAD or c == H.NECK or c == H.UNDER_NECK
end

--- Damage multiplier by body part.
---
--- THIS IS A BALANCE DECISION, AND IT IS A DEPARTURE FROM GTA. The captured
--- headshot is the evidence: a Mini SMG whose base damage we call 23 reported
--- `weaponDamage 234` and killed outright. GTA's own headshot multiplier is
--- effectively lethal for any weapon -- one round anywhere near the head ends
--- a fight regardless of what the gun is.
---
--- A battle royale generally does not want that. Fortnite headshots are a
--- large multiplier, not an instant kill, because a mode built on looting has
--- to let a player who found armour and a good gun survive one unlucky round.
--- So headshots hurt a great deal and still leave a fight to win.
---
--- Sniper rifles get there anyway through raw damage: a Heavy Sniper at 216
--- base times 2.0 is far past any health pool, which is the right place for a
--- one-shot to live.
---
--- Keyed by hitComponent; anything unlisted is 1.0.
--- TWO HEADSHOTS TO KILL (user call, 2026-08-07), and 2.5 is the arithmetic
--- of that rather than a taste. Health is 100 display units, so "two shots"
--- means a headshot must land in (50, 100]:
---
---     Mini SMG   23 x 2.5 =  58   -> 2 headshots
---     Pistol     26 x 2.5 =  65   -> 2
---     Carbine    32 x 2.5 =  80   -> 2
---     Revolver   97 x 2.5 = 243   -> 1, and a hand cannon should
---     Heavy Sniper 216 x 2.5      -> 1, which is where one-shots belong
---
--- So the rule holds for every automatic weapon and sidearm, and the two
--- weapons that break it are the two that are supposed to.
BR.Config.BodyMult = {
    [BR.Config.HitComponent.HEAD]        = 2.3,
    [BR.Config.HitComponent.NECK]        = 1.8,
    [BR.Config.HitComponent.UNDER_NECK]  = 1.8,

    -- Centre mass is the honest target: full damage, and the biggest area on
    -- the model. Everything below it is a consolation prize.
    [BR.Config.HitComponent.CHEST]       = 1.0,
    [BR.Config.HitComponent.UPPER_TORSO] = 1.0,
    [BR.Config.HitComponent.LOWER_TORSO] = 0.95,
    [BR.Config.HitComponent.PELVIS]      = 0.95,

    -- LIMBS HURT LESS, and noticeably so (user call, 2026-08-07). Spraying at
    -- a running target and clipping an arm should not trade evenly with
    -- someone who put their rounds in the chest.
    [BR.Config.HitComponent.LEFT_SHOULDER]   = 0.75,
    [BR.Config.HitComponent.RIGHT_SHOULDER]  = 0.75,
    [BR.Config.HitComponent.LEFT_UPPER_ARM]  = 0.65,
    [BR.Config.HitComponent.RIGHT_UPPER_ARM] = 0.65,
    [BR.Config.HitComponent.LEFT_ELBOW]      = 0.55,
    [BR.Config.HitComponent.RIGHT_ELBOW]     = 0.55,
    [BR.Config.HitComponent.LEFT_WRIST]      = 0.50,
    [BR.Config.HitComponent.RIGHT_WRIST]     = 0.50,

    [BR.Config.HitComponent.LEFT_HIP]    = 0.80,
    [BR.Config.HitComponent.RIGHT_HIP]   = 0.80,
    [BR.Config.HitComponent.LEFT_LEG]    = 0.65,
    [BR.Config.HitComponent.RIGHT_LEG]   = 0.65,
    [BR.Config.HitComponent.LEFT_FOOT]   = 0.50,
    [BR.Config.HitComponent.RIGHT_FOOT]  = 0.50,
}

--- A HEADSHOT IS A CLOSE-RANGE PAYOFF (user call, 2026-08-07).
---
--- Landing one across a car park should reward aim; landing one across the
--- map should not simply delete somebody. So the head multiplier is at full
--- strength inside `full` metres and decays to `far` by `fade`, which makes
--- close-quarters aim the thing it rewards rather than range.
---
--- Snipers are untouched by this in the way that matters: a Heavy Sniper hits
--- for 216 to the CHEST, so it remains a one-shot at any distance through raw
--- damage. What this removes is the SMG headshot from 200 metres.
BR.Config.HeadshotRange = {
    full = 30.0,    -- full multiplier at or inside this
    fade = 120.0,   -- decayed to `far` at or beyond this
    far  = 1.25,    -- what a very long headshot is worth
}

--- The multiplier for a hit component. Unknown parts are worth full damage --
--- an unrecognised bone should never silently zero a hit.
--- @param c integer|nil
--- @param dist number|nil  metres; only the head group cares
--- @return number
function BR.Config.BodyMultFor(c, dist)
    if c == nil then return 1.0 end
    local mult = BR.Config.BodyMult[c] or 1.0

    if dist and BR.Config.IsHeadshot(c) then
        local r = BR.Config.HeadshotRange
        local span = (r.fade or 120.0) - (r.full or 30.0)
        if span > 0.0 then
            local t = BR.Clamp((dist - (r.full or 30.0)) / span, 0.0, 1.0)
            -- Never BELOW the far value, and never above the close one: a
            -- head hit is always at least as good as a chest hit.
            mult = BR.Lerp(mult, math.max(r.far or 1.25, 1.0), t)
        end
    end

    return mult
end

--- Descent classification, shared by the BUS ceiling and the stuck-lander net.
---
--- 0.7 m/s sits between the two things that must be told apart: a parachute
--- descends around 2 m/s and clears it comfortably, while a hung client at a
--- frozen altitude reads 0. Freefall is ~50 m/s and was never in doubt -- it
--- was the CANOPY the old per-tick test could not see.
BR.Config.Match.descendRate  = 0.7      -- m/s; below this is not descending
BR.Config.Match.stuckLanderMs = 5000    -- held at one altitude this long -> ALIVE

--- Spectating (#192).
BR.Config.Spectate = {
    -- WHAT A DEAD PLAYER MAY SEE ONCE THEIR WHOLE SQUAD IS OUT.
    --
    -- False is the conservative answer and #192 argues for it directly: "free
    -- spectate of living players is the mode where a stream-sniping or ghosting
    -- accusation becomes possible, and refusing it costs little". True widens
    -- the set to every living player in that match -- never before the squad is
    -- gone, which is not this value's business: shared/spectate_solve.lua cannot
    -- reach the widening branch while a squadmate is standing, whatever this
    -- says.
    --
    -- SOLOS READ THIS ON THE FIRST PASS, because a solo player's squad is empty
    -- from the start. So this is also the answer to "may a dead solo player
    -- watch the rest of the match", and it is the same answer.
    freeAfterSquadOut = false,

    -- How often the server pushes the target's position to a spectator.
    --
    -- 250ms, MATCHING roster.lua's own position sampling and party.lua's squad
    -- beacons. Pushing faster than the server samples would re-send identical
    -- coordinates; the camera interpolates between samples, so the cadence is
    -- not the frame rate of the shot.
    feedMs = 250,

    -- The shot. Same three numbers the bus camera takes (BR.Config.Bus), for
    -- the same orbit: how far behind, how high above the subject's feet the
    -- camera looks, and the field of view.
    camDistance = 4.5,
    camHeight   = 1.0,
    fov         = 55.0,

    -- HOW LONG YOUR OWN DEATH IS ON SCREEN BEFORE THE CAMERA MOVES ON.
    --
    -- "Upon dying, the verdict text ONLY should be shown for ~10 seconds then
    -- the text can immediately disappear as we snap into spectating" -- the
    -- owner. Before this, a death cut straight to somebody else's shoulder
    -- within a second: the SLOW loop in client/spectate.lua asked for a target
    -- as soon as the state read DEAD, so the moment a player most wants to
    -- register -- what just happened to them, and who did it -- was the one
    -- moment the game skipped.
    --
    -- IT IS THE TEXT ONLY, NOT THE VERDICT SCREEN. The match-end screen is a
    -- black backdrop, a placement and a Volts line, and it is unchanged: this is
    -- the same WORD that screen slams, over the world, with nothing behind it.
    -- Two moments, two surfaces, one word table (ui-src/src/hud/verdictWord.ts).
    --
    -- ~10 SECONDS IS THE OWNER'S NUMBER and the tilde is theirs too. It is here
    -- rather than in the client so it can be shortened without a rebuild if it
    -- turns out to be a long time to sit still.
    deathVerdictMs = 10000,
}

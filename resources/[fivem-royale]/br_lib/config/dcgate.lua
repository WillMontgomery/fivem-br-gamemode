-- The data center's main gate (#420), Season 2: the numbers.
--
-- The campus's front gate (#415) has three lanes. Each lane is a crash arm
-- outside an outer bi-fold gate, a trap, and an inner bi-fold gate, with a red
-- reader at the curb outside the outer gate and inside the inner one. A player
-- at a reader presses interact, and that whole lane opens. The whole contract
-- is docs/dcgate.md.
--
-- ═══ THE OWNER'S DECISIONS (2026-10-19) ═══
--
--   * Standing at a lane's reader shows the prompt "Press E to open the gate"
--     (his words; the E is the player's own interact key, drawn as a key).
--     Pressing it opens that whole lane: both bi-fold gates fold open and its
--     crash arm rises.
--   * The lane stays open 20 seconds, then folds shut -- but waits while any
--     player or vehicle is still in the lane.
--   * The server decides, per match; clients animate.
--   * The fold: the lead leaf turns 0-90 degrees about its post hinge, and the
--     follower rides on the lead's free edge and counter-rotates (the gate
--     kit's kit_gate_doors.json).
--   * The gamemode registers, locks and opens the main gate's 24 leaves and 3
--     arms; br_datacenter stops locking them in the same publish.
--   * Season 2 only (the `dcgate` row in config/seasons.lua); the readers work
--     in a match only.
--
-- THE PARTS THEMSELVES are br_lib/config/dcgate_parts.lua, a file of their own
-- because it is generated (tools/dcgate_parts.py). This file is the numbers;
-- nothing here reads that one at load.

BR = BR or {}
BR.Config = BR.Config or {}
BR.Config.DcGate = BR.Config.DcGate or {}

local G = BR.Config.DcGate

-- ── the lane ──

-- How long a lane stays open before it folds shut. Owner, 2026-10-19.
G.openMs = 20000

-- How long a fold takes, each way: the leads 0 to foldDeg, the arm 0 to
-- armRaiseDeg, together. A reversal mid-fold (a press, or somebody stepping
-- into a closing lane) runs back from where the leaves are.
G.foldMs = 4000

-- The lead's fold at fully open. The kit: "theta 0-90, hard stop at 90" (past
-- it the two halves of a gate meet).
G.foldDeg = 90.0

-- The crash arm's raise at fully open. The kit: "85-90 deg is fully raised
-- (test the exact stop)"; its pose previews stand it at 85.
G.armRaiseDeg = 85.0

-- ── the reader ──

-- A player stands at a reader within this, measured flat (2D), and within
-- readerZM of its height. The reader leans over the lane at the driver's
-- window (the kit: 1.08 m from the body of a centered car), so a driver at the
-- pedestal and a player on foot beside it are both in reach.
G.readerM = 3.0
G.readerZM = 2.5

-- ── the server's door (DCGATE_USE) ──

G.use = {
    -- No sooner than this after the player's last press, and at most this many
    -- a match.
    minIntervalMs = 1000,
    perMatch = 120,
    -- The server's own position sample, no older than this, and the reach it
    -- allows past the client's: the 4 Hz sample of a car rolling up to the
    -- pedestal trails the client by a few meters.
    sampleMaxAgeMs = 1000,
    reachSlackM = 3.0,
}

-- ── the lane's box: who a closing gate waits for ──
--
-- The box itself is generated (dcgate_parts.lua: from the arm's beam to the
-- inner gate's fold, post to post, at grade). A player standing or downed in
-- the match whose sample is within pedMarginM of it, or any vehicle in the
-- match's routing bucket whose center is within vehicleMarginM -- a car's
-- half-length, so a bumper under a leaf counts -- holds the lane open. Both
-- from belowM under the grade to aboveM over it.
G.lane = {
    pedMarginM = 0.5,
    vehicleMarginM = 2.5,
    belowM = 1.0,
    aboveM = 4.5,
    -- The server's pass over open and closing lanes. Nothing runs while every
    -- lane in every match is shut, and the vehicle pool is read only for a lane
    -- that is due to close or closing.
    checkMs = 500,
    -- A player's sample older than this is not counted.
    sampleMaxAgeMs = 3000,
}

-- ── the client ──

G.client = {
    -- Within this of the gate's middle (dcgate_parts.lua's center, past its
    -- radius) the SLOW pass keeps the doors locked and posed as their physics
    -- streams in. Farther, nothing but the distance is asked.
    nearM = 200.0,
    -- Within this past the gate's radius, the TICK callback that shows the
    -- prompt is registered.
    promptM = 15.0,
    -- The finds: the followers (and, with the 'rotate' drive, the leads and the
    -- arm) are found by model at their placed origins, this close, at most this
    -- many a SLOW pass.
    findRadiusM = 0.6,
    findsPerPass = 9,

    -- ═══ HOW A LEAD AND AN ARM ARE MOVED (docs/dcgate.md, the engine questions) ═══
    --
    --   'ratio'   the door system's own open ratio, held locked
    --             (DoorSystemSetOpenRatio, then DoorSystemSetDoorState 1): the
    --             engine's way of holding a door ajar
    --   'rotate'  the handle frozen and turned by SetEntityRotation, the door
    --             unlocked while it is moved
    --
    -- `brgate drive <lead|arm> <ratio|rotate>` switches one on this client, for
    -- the dev box to settle which the engine honors.
    drive = { lead = 'ratio', arm = 'ratio' },
    -- With 'ratio': the angle an open ratio of 1.0 turns the part, and the sign
    -- that turns it the kit's way. Unverified in game.
    ratioDeg = { lead = 90.0, arm = 90.0 },
    ratioSign = { lead = 1, arm = 1 },
}

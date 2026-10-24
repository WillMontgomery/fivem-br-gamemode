-- The data center's main gate (#420), Season 2: the numbers.
--
-- The campus's front gate (#415) has three lanes. Each lane is a crash arm
-- outside an outer bi-fold gate, a trap, and an inner bi-fold gate, with a red
-- reader at the curb outside the outer gate and inside the inner one. Each lane
-- is a sally port: a press at a reader opens the gate nearest it, and the
-- other opens only once that one has shut behind whoever came into the trap.
-- The whole contract is docs/dcgate.md.
--
-- ═══ THE OWNER'S DECISIONS (2026-10-19) ═══
--
--   * Standing at a lane's reader shows the prompt "Press E to open the gate"
--     (his words; the E is the player's own interact key, drawn as a key).
--   * The server decides, per match; clients animate.
--   * The fold: the lead leaf turns 0-90 degrees about its post hinge, and the
--     follower rides on the lead's free edge and counter-rotates (the gate
--     kit's kit_gate_doors.json).
--   * The gamemode registers, locks and opens the main gate's 24 leaves and 3
--     arms; br_datacenter stops locking them in the same publish.
--   * Season 2 only (the `dcgate` row in config/seasons.lua); the readers work
--     in a match only. No reader in the trap.
--
-- ═══ THE OWNER'S DECISIONS (2026-10-24): A SALLY PORT, NOT A TIMER ═══
--
--   * A press at the outside reader opens only the outer gate and raises the
--     arm; a press at the inside reader opens only the inner gate.
--   * The first gate closes about 2 s after its swing area and approach are
--     clear once someone is in the trap; a first gate nobody has come into the
--     trap through within 10 s closes, and the cycle ends.
--   * The first gate fully shut with someone in the trap, the second opens;
--     it closes about 2 s after the trap and its swing area are clear.
--   * No gate ever closes on a player or a vehicle in its swing area. A press
--     while the lane's cycle runs is not taken; a player in the trap with no
--     cycle running gets nothing.
--   * The arm is turned by hand ('rotate') and stays frozen in every pose.
--
-- THE PARTS THEMSELVES are br_lib/config/dcgate_parts.lua, a file of their own
-- because it is generated (tools/dcgate_parts.py). This file is the numbers;
-- nothing here reads that one at load.

BR = BR or {}
BR.Config = BR.Config or {}
BR.Config.DcGate = BR.Config.DcGate or {}

local G = BR.Config.DcGate

-- ── the fold ──

-- How long a gate's fold takes, each way: its leads 0 to foldDeg (and the
-- outer gate's arm 0 to armRaiseDeg), together. A reversal mid-fold (somebody
-- stepping into a closing gate's swing) runs back from where the leaves are.
G.foldMs = 4000

-- The lead's fold at fully open. The kit: "theta 0-90, hard stop at 90" (past
-- it the two halves of a gate meet).
G.foldDeg = 90.0

-- The crash arm's raise at fully open. The kit: "85-90 deg is fully raised
-- (test the exact stop)"; its pose previews stand it at 85.
G.armRaiseDeg = 85.0

-- ── the sally port (owner, 2026-10-24) ──
--
-- The sequence is br_lib/shared/dcgate_solve.lua's (S.advance); these are its
-- times. Every spell is counted from no earlier than the gate standing fully
-- open (foldMs after it started).
G.cycle = {
    -- A gate closes this long after what it waits on is clear: the first gate
    -- its swing and approach (with someone in the trap), the second the trap
    -- and its swing. "About 2 s."
    closeDelayMs = 2000,
    -- A first gate nobody has come into the trap through this long after it
    -- opened closes (its swing clear), and the cycle ends.
    abandonMs = 10000,
}

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
    -- a match. Half the client's own client.askMs, so network jitter never
    -- drops a retry the client sent a second after its last.
    minIntervalMs = 500,
    perMatch = 120,
    -- The server's own position sample, no older than this, and the reach it
    -- allows past the client's: the 4 Hz sample of a car rolling up to the
    -- pedestal trails the client by a few meters.
    sampleMaxAgeMs = 1000,
    reachSlackM = 3.0,
}

-- ── the zones: who is where ──
--
-- The zones are derived from the generated parts (dcgate_solve.lua's
-- S.laneZones): the trap between the two gate lines, each gate's swing (its
-- leaves' fold, and the outer gate's arm) and its way (the swing and the
-- approach out to its reader), every one post to post at grade. These are the
-- sizes they are grown by. A player standing or downed in the match whose
-- sample is within pedMarginM of a zone, or any vehicle in the match's routing
-- bucket whose center is within vehicleMarginM of its ends -- a car's
-- half-length, so a bumper under a leaf counts -- and vehicleSideM of its
-- sides -- a car's half-width: the leaves fold inside the posts, so a car
-- beside the lane (on the island between two) is in none -- is in it. Both
-- from belowM under the grade to aboveM over it.
G.lane = {
    pedMarginM = 0.5,
    vehicleMarginM = 2.5,
    vehicleSideM = 1.0,
    belowM = 1.0,
    aboveM = 4.5,
    -- The server's pass over the lanes whose cycle runs. Nothing runs, and the
    -- vehicle pool is not read, while every lane in every match is idle.
    checkMs = 500,
    -- A player's sample older than this is not counted.
    sampleMaxAgeMs = 3000,
}

-- ── the client ──

G.client = {
    -- Within this of the gate's middle (dcgate_parts.lua's center, past its
    -- radius) the SLOW pass keeps the doors locked and posed as their physics
    -- streams in, and a gate that changes folds. Farther, nothing but the
    -- distance is asked. The leaves' lodDist (the gate kit's REPORT: 300 m),
    -- so no client sees a leaf it is not keeping posed.
    nearM = 300.0,
    -- Within this past the gate's radius, the TICK callback that shows the
    -- prompt is registered.
    promptM = 15.0,
    -- A press asks the server no sooner than this after this client's last
    -- ask (longer than the server's use.minIntervalMs).
    askMs = 1000,
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
    --   'rotate'  the handle frozen from the moment it is found and turned by
    --             SetEntityRotation, and frozen in every pose, shut included: a
    --             door entity turned by hand loses its hinge, so unfrozen a hit
    --             knocks it loose. The door is locked shut while the part is
    --             shut and let go while it is turned. It goes back to the door
    --             system only when br_core stops or `brgate drive` switches it
    --             to 'ratio'.
    --
    -- The arm is 'rotate' (owner, 2026-10-24: a 'ratio' arm hit before its
    -- lane opened stayed down; turned by hand it rises every time). The leads
    -- stay 'ratio'. `brgate drive <lead|arm> <ratio|rotate>` switches one on
    -- this client.
    drive = { lead = 'ratio', arm = 'rotate' },
    -- With 'ratio': the angle an open ratio of 1.0 turns the part, and the sign
    -- that turns it the kit's way. In game (2026-10-24) a lead held at 1.0
    -- stands 81 degrees open, not 90: 1.0 is the most the door system can be
    -- asked, so 81 is the door's own limit, not this number (docs/dcgate.md).
    ratioDeg = { lead = 90.0, arm = 90.0 },
    ratioSign = { lead = 1, arm = 1 },
}

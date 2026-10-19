-- Flick cameras (#419), Season 2: the numbers.
--
-- Pole cameras along the roads and at the junctions, a few hundred of them,
-- that feed the terminal's Scan: with Flick on, Scan shows an opponent only
-- while a working camera sees them. Players knock them out, and Scan goes blind
-- there for the rest of the match. The whole contract is docs/flick.md.
--
-- ═══ THE OWNER'S DECISIONS (2026-10-18) ═══
--
--   * Named Flick; about 300 cameras inside the play area, never blocking a
--     driveway or a lane; the prop is a pole with a camera and a solar panel.
--   * Knocked out by gunfire or knocked over by a vehicle: ONE hit on the
--     camera or on its solar panel takes it down. Down for the rest of the
--     match; the server decides; every client shows it broken; all of it
--     resets each match.
--   * Explosions and AI traffic take a camera down too, and pay nobody.
--   * Scan sees an opponent within 75 m of a working camera on foot, and
--     within 150 m in any seat of a vehicle (the cameras read plates).
--   * The coverage is drawn on the big map only, for the Scan squad only.
--     Nobody sees the cameras on any map otherwise.
--   * 2 Volts to the player who takes one down, 30 at most a match.
--   * Season 2 and later (the `flick` row in config/seasons.lua).
--
-- THE CAMERAS THEMSELVES are br_lib/config/flick_cameras.lua, a file of their
-- own because it is generated (tools/flick_cameras.py). This file is the
-- numbers; nothing here reads that one at load.

BR = BR or {}
BR.Config = BR.Config or {}
BR.Config.Flick = BR.Config.Flick or {}

local F = BR.Config.Flick

-- ── what Scan sees ──

-- An opponent within this of a live camera, measured flat on the map (2D), so
-- what Scan sends is exactly what the coverage circles show. Owner, 2026-10-18.
F.rangeM = 75.0
-- An opponent in any seat of a vehicle, within this of a live camera: the
-- cameras read plates. Owner, 2026-10-18.
F.vehicleRangeM = 150.0

-- ── the reward ──

-- Volts to the player credited with taking a camera down, and the most one
-- account is credited in a match. Owner, 2026-10-18. Paid at the match's end in
-- its one atomic ADD, the airdrop pile's path (docs/flick.md, "The reward").
F.voltsEach = 2
F.voltsMatchMax = 30

-- ── the copy ──

-- THE TAKEDOWN TOAST, the owner's words VERBATIM (2026-10-18): to the player
-- credited with a camera, and only when Volts were actually credited -- never
-- at the cap, and never for a down that pays nothing. It reads
--
--     SA Sovereign Citizens Community: Thank you for your service. +2 Volts
--
-- with "+2 Volts" in the Volts color. A toast has no title field, so the
-- sender leads the line before a colon, as the HUD's notices name what speaks
-- ("Scan: ...") and the chat its sender. The figure and the currency word are
-- not copy: BR.ShopSolve.priceLine and BR.Config.Market.currency, through
-- BR.FlickSolve.toast. tools/test_flick.lua holds both lines word for word.
F.copy = {
    sender = 'SA Sovereign Citizens Community',
    thanks = 'Thank you for your service.',
}

-- ── the registry's shape ──

-- The grid's cell, in meters: the widest range, so "any live camera within r"
-- walks the 3x3 cells around a point.
F.gridM = 150.0
-- No two cameras closer than this (tools/check_boundary.lua), so a camera's
-- model hide (art.hideRadiusM) can never catch a neighbor.
F.minSpacingM = 10.0

-- ── the server's door (FLICK_REPORT) ──

F.report = {
    -- One report a player per this, and this many a match at most.
    minIntervalMs = 300,
    perMatch = 60,
    -- The reporter's own position is the server's 4 Hz sample, no older than
    -- this.
    sampleMaxAgeMs = 1000,
    -- A camera already down is still credited to a `me` report this soon
    -- after it went down, when nobody was credited yet: a bystander's report
    -- landing first costs the shooter nothing.
    creditWindowMs = 3000,
    -- How far from the camera the reporter may stand, 3D, by the server's own
    -- sample: a `me` report by its cause, and every `other` report.
    --   vehicle  a quarter second of sample at speed plus the trip, and a
    --            rider thrown off a bike
    --   weapon   a scope draws the camera farther than the eye
    --   other    a bystander who saw it fall
    reach = { weapon = 400.0, vehicle = 25.0, other = 400.0 },
    -- EXPLOSIONS PAY NOBODY (owner, 2026-10-18). An explosion the server heard
    -- (explosionEvent) within blastM of a camera, up to blastWindowMs before
    -- its report, makes that down nobody's: it goes down, and no Volts.
    blastM = 15.0,
    blastWindowMs = 3000,
}

-- ── who is told ──

-- A camera that goes down is sent to the players whose view is this close:
-- past the farthest any camera draws, so one arriving from across the map is
-- hidden before it could be seen standing.
F.showM = 500.0
-- And the pass that sends the downs to whoever comes near since.
F.sendPassMs = 1000

-- ── the client ──

F.client = {
    -- The cameras near this player that its watch reads, once a second.
    nearM = 120.0,
    -- GetClosestObjectOfType's sphere at a row, the most it is asked a pass,
    -- and how long a row it found nothing at waits before it is asked again.
    findRadiusM = 2.0,
    findsPerPass = 4,
    findRetryMs = 5000,
    -- The down rule (BR.FlickSolve.downed): tilted past this, or moved more
    -- than this from its row. Harmless extras: the ymap's handle stays at the
    -- base when a car snaps the pole, and a break is the signal (PROP.md 6).
    tiltDownDeg = 30.0,
    movedDownM = 0.75,
    -- Health lost that counts as down, once the prop is measured; nil is off.
    healthLossDown = nil,
    -- A down camera's stand-in wreck: drawn only this close to the view, and
    -- at most this many at once.
    wreckM = 300.0,
    wreckMax = 24,
    -- Model hides made a frame (the Season 1 hides, and the downs), and
    -- coverage circles made or taken down a frame.
    hidesPerFrame = 25,
    coverageBatch = 100,
}

-- ── the art ──

F.art = {
    -- The standing camera the ymap places, its LOD inside the model
    -- (PROP.md 8): hiding it hides every distance.
    model = 'blitz_flick_cam',
    -- The stand-in a client draws over a down camera, by the cause the server
    -- recorded: the pole still standing with the camera hanging (gunfire),
    -- and the base with a torn stub (a vehicle). Either absent: hide only.
    wreck = { weapon = 'blitz_flick_cam_shot', vehicle = 'blitz_flick_cam_down' },
    -- Frozen where it is made, by cause. The shot wreck is a fragment with the
    -- standing pole's break, so a car can still knock it over; if a script-made
    -- fragment does not stand on its own on the dev box, freeze it here.
    wreckFrozen = { weapon = false, vehicle = true },
    -- The model hide's sphere at a row: reaches the base and anything still
    -- standing, and never a neighbor (minSpacingM).
    hideRadiusM = 1.5,
    -- The Scan squad's coverage on the big map: one circle per live camera.
    -- PLACEHOLDERS for the owner: never the storm's purple, Scan's red or the
    -- bounty's blue. "the circles should be barely visible" (owner,
    -- 2026-10-18): alpha 25 is the faint start, and `brflicktune` prints this
    -- line with the look he picks on the keys.
    coverage = { colour = 5, alpha = 25 },
}

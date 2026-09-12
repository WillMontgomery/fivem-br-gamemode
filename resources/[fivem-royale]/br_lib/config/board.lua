-- The stat board (#247): where it stands, how big it is, and the one URL it
-- points at.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A DUI is a whole Chromium instance rendering a page into a game texture. This
-- one runs on EACH PLAYER'S OWN MACHINE, fetches a page Ringmaster serves, and
-- br_core/client/board.lua paints it onto a quad standing on a prop in the
-- warmup area.
--
-- ═══ THERE IS ONE BOARD, AND "THE STAT BOARD" AND "THE SCOREBOARD" ARE IT ═══
--
-- Owner, 2026-09-11, settling a question this file used to leave open: the
-- warmup stat board and the scoreboard are THE SAME BOARD. One physical display,
-- showing a page that alternates between a viewer's own stats and the shared
-- leaderboard.
--
-- SO THERE IS ONE OF EVERYTHING BELOW and there is meant to be: one `prop`, one
-- `width`/`height`, one URL. The alternation is the PAGE'S, and it happens
-- inside the document Ringmaster serves -- client/board.lua has no mode, no
-- timer and no message about it, which is why nothing here configures one. If a
-- second `prop` block ever appears in this file, that is the bug.
--
-- ═══ THE GAME SERVER IS NOT IN THAT SENTENCE, AND THAT IS THE WHOLE DESIGN ═══
--
-- The house rule is that the game server must never depend on Ringmaster. It
-- does not here: the fetch is the player's client talking to a public HTTPS
-- host, the game box neither makes the request nor learns whether it worked, and
-- every value below is a client-side drawing decision. If Ringmaster is down,
-- one browser on one player's machine fails to load a page and the board shows
-- static. Nothing on the game box changes state, retries, blocks or times out.
--
-- ═══ THE URL IS THE OWNER'S, VERBATIM ═══
--
-- Owner, 2026-09-09: "We go option 3 for transport, and build a page which
-- requires no auth and provides info when given a user's license key: so if
-- their license is b6f5a1273092df7eb6a8c2a981418f275f2ae3fb, the URL would be
-- like https://ringmaster.blitz-royale.com/scoreboard?id=b6f5a127..."
--
-- A survey of both systems before this was built confirmed a license is not a
-- bearer credential anywhere: nothing anywhere accepts a license PRESENTED by a
-- caller as proof of anything. It is a key the way a row id is a key. See the
-- header of Ringmaster's src/app/scoreboard/route.ts, which states plainly what
-- the route hands to anybody who guesses forty hex characters.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Board = {
    -- OFF IS REPRESENTABLE, the same reason config/warmupcrates.lua carries one:
    -- "turn it off and see whether the symptom goes away" should not require
    -- deleting a line from a manifest. It is also what an operator running
    -- without a Ringmaster deployment would set.
    enabled = true,

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE URL
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- SPLIT SO THE HOST IS A VALUE AND NOT A LITERAL BURIED IN A FUNCTION. A
    -- staging box, a rename, or a locally-hosted console are all one edit here
    -- rather than a hunt through client Lua. NO TRAILING SLASH; `path` carries
    -- its own leading one, and BR.BoardUrl below joins them without inventing
    -- or removing a separator.
    host = 'https://ringmaster.blitz-royale.com',

    -- The route Ringmaster mounts the board on. A contract between the two
    -- repositories rather than an operator knob, and it is here beside `host`
    -- because half a URL in config and half in code is the arrangement that
    -- guarantees somebody edits only one of them.
    path = '/scoreboard',

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE TEXTURE
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- ⚠ THESE TWO NUMBERS MUST MATCH THE PAGE. Ringmaster's src/lib/scoreboard.ts
    -- pins BOARD_WIDTH/BOARD_HEIGHT at 1280x720 and writes the document at fixed
    -- pixels with `overflow: hidden` and no media query, because a DUI has no
    -- scrollbar, no wheel and no way to reach anything below the fold. A texture
    -- of a different size does not rescale the page; it crops it or leaves a
    -- band of background.
    --
    -- ═══ WHY 720p AND NOT THE 1080p THE OWNER GUESSED AT ═══
    --
    -- Owner, 2026-09-09: "Resolution, not sure. I'm thinking 1920x1080 and 30hz,
    -- but I wasn't aware that a DUI had a refresh rate?"
    --
    -- NOT ONE THIS SIDE CAN SET. CreateDui(url, w, h) takes pixels and nothing
    -- else; there is no frame-rate argument and no native that adds one.
    --
    -- ⚠ THE REST OF THIS PARAGRAPH USED TO SAY THE PAGE HAS NO MOTION AND THAT
    -- A STILL DUI IS FREE. BOTH WERE WRONG, and they were wrong in opposite
    -- directions, so the answer below is unchanged and the reasoning is not.
    --
    --   THE PAGE MOVES NOW. Ringmaster's `ee66ad2` gave the board a bounded
    --   view transition (TRANSITION_MS, 620ms) and a motion setting, and
    --   `657242e` added a background that drifts continuously. So "deliberately
    --   built with no transition, no keyframe and no easing anywhere in it" is
    --   retired: that describes only `SCOREBOARD_MOTION=off`, and the default is
    --   `full`. The knob is server-side in Ringmaster (`full`, `transitions`,
    --   `off`) and is read per request, so it is an operator decision over
    --   there rather than anything this file can express.
    --
    --   AND A STILL DUI IS NOT FREE. FiveM's NUIRenderCallbacks.cpp calls
    --   UpdateFrame() on every registered NUI window unconditionally on OnRender;
    --   the dirty-flag gate exists only in the software fallback branch. So the
    --   game's renderer does the same full-surface blit every game frame whether
    --   or not the page painted, and animation's marginal cost THERE is zero.
    --   What continuous motion actually costs is frame production inside CEF,
    --   in process, on every machine at the pad. Ringmaster's
    --   `src/lib/scoreboardPage.ts` carries the whole argument under THE MOTION,
    --   read out of the FiveM and CEF sources rather than inferred; it is not
    --   re-derived here and this note should not drift from it.
    --
    -- WHAT THE PIXELS COST, AND THE CORRECTION MAKES THIS ARGUMENT STRONGER
    -- RATHER THAN WEAKER. A runtime texture from a DUI handle is live RGBA, so
    -- the bill is width x height x 4 bytes and nothing amortizes it: 1920x1080 is
    -- 8.3 MB, 1280x720 is 3.7 MB. That is 4.6 MB per client given back on a
    -- machine already holding a battle royale map, and it is paid whether or not
    -- anybody is looking at the prop. These two numbers are ALSO the unit of the
    -- per-frame blit above, so they are spent every game frame and not only once.
    --
    -- WHAT 1080p WOULD BUY: nothing legible. The texture is sampled at whatever
    -- screen area the quad occupies, and a board a player stands a few meters
    -- from occupies a few hundred pixels of their actual display. Doubling the
    -- source resolution of text that is already being downsampled buys sharpness
    -- nobody can resolve. "Can I read it from over there" is answered by type
    -- size in the page, not by texture size here.
    width  = 1280,
    height = 720,

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE PROP
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- ⚠ THIS PROP ALREADY EXISTS IN THE WORLD. WE DO NOT PUT IT THERE.
    --
    -- Owner, 2026-09-11: "The prop is prop_huge_display_02, already in a ymap and
    -- streamed and verified working in-game."
    --
    -- THAT ONE SENTENCE CHANGED THE CODE, not just these values. The previous
    -- draft called CREATE_OBJECT_NO_OFFSET at these coordinates, which against a
    -- prop that is already standing there would put a SECOND display inside the
    -- first -- two coincident meshes z-fighting, on a board nobody could then
    -- align because there would be two of them. br_core/client/board.lua now
    -- FINDS the existing entity with GET_CLOSEST_OBJECT_OF_TYPE and never creates
    -- or deletes one. Read its `findProp` before changing anything here.
    --
    -- SO THE THREE COORDINATES ARE NO LONGER "WHERE WE PUT SOMETHING". THEY ARE
    -- "WHERE WE LOOK", and that is a weaker requirement: they have to be close
    -- enough to the prop's own origin to fall inside `radiusM`, not exact.
    prop = {
        -- Owner, 2026-09-11, verbatim. `prop_huge_display_01` is its sibling and
        -- is the first thing to try if this one turns out to be the wrong half of
        -- the pair: /brboard prop prop_huge_display_01 auditions it with no
        -- config edit and no restart.
        model   = 'prop_huge_display_02',

        -- Owner, 2026-09-11: "Position is here: 4539.29443, -4498.826,
        -- 7.20210361". Surveyed numbers, used literally: this project does not
        -- round, lower or ground-probe the owner's coordinates.
        x       =  4539.29443,
        y       = -4498.826,
        z       =  7.20210361,

        -- HOW FAR FROM THOSE THREE WE ARE WILLING TO LOOK, in meters.
        --
        -- GET_CLOSEST_OBJECT_OF_TYPE answers with the NEAREST match, so this is
        -- not "which one" -- there is one -- it is slack for the difference
        -- between the coordinate somebody read off a map editor and the origin
        -- the engine actually gives the entity. Wide enough to absorb that,
        -- narrow enough that it can never reach a different instance of the same
        -- model somewhere else on the island.
        radiusM = 8.0,

        -- ═══════════════════════════════════════════════════════════════════
        -- WHICH WAY IT FACES, DEGREES -- AND HOW FOUR NUMBERS BECAME THIS ONE
        -- ═══════════════════════════════════════════════════════════════════
        --
        -- Owner, 2026-09-11: "Rotation is: 0, 0, -0.9238796, -0.3826834"
        --
        -- THAT IS A QUATERNION AND THIS FIELD IS A HEADING. Four components, one
        -- number, and pasting any one of the four in would have been silently
        -- wrong. The conversion, with the working, so the next person can check
        -- it rather than trust it:
        --
        -- COMPONENT ORDER ASSUMED: (x, y, z, w) = (0, 0, -0.9238796, -0.3826834).
        -- That is the order the engine and the ymap both use -- GTA hands back
        -- the w LAST -- and it is not taken on faith, because the numbers
        -- themselves settle it two ways:
        --
        --   |q| = sqrt(0 + 0 + 0.9238796^2 + 0.3826834^2) = 1.0000000. A unit
        --   quaternion, so all four components are present and none is a scale.
        --
        --   x = y = 0, so the axis IS the world's up and the rotation is a PURE
        --   YAW: pitch 0.000000, roll 0.000000. A display standing upright on
        --   flat ground is exactly that. Read instead as (w, x, y, z) the same
        --   four numbers come out as yaw 180 with a ROLL OF 135 DEGREES -- a
        --   screen lying over on its corner, which is not what he placed. The
        --   component order is not a guess; the wrong one is absurd.
        --
        -- THE ARITHMETIC. With x = y = 0 the general formula collapses to
        -- heading = 2 * atan2(z, w):
        --
        --   2 * atan2(-0.9238796, -0.3826834)
        --   both arguments negative -> third quadrant -> atan2 in (-180, -90)
        --   reference angle = atan(0.9238796 / 0.3826834) = atan(2.4142136)
        --                   = 67.500003 degrees
        --   atan2           = -(180 - 67.5) = -112.500000
        --   heading         = -225.000000, which normalizes to 135.000000
        --
        --   Cross-checked against the full three-axis formula, which does not
        --   assume x = y = 0:
        --     yaw = atan2(2(wz + xy), 1 - 2(y^2 + z^2))
        --         = atan2(0.7071068, -0.7071068) = 135.000010
        --
        -- AND IT IS A CLEAN ANSWER, WHICH IS THE TELL. 0.9238796 is cos(22.5) and
        -- 0.3826834 is sin(22.5), so this was always going to land on a multiple
        -- of 22.5 degrees. A ragged result would have meant the component order
        -- was wrong. 135 is exact.
        --
        -- NO SIGN FLIP ON THE WAY INTO THE ENGINE. GTA's heading 0 faces +Y and
        -- GET_ENTITY_FORWARD_VECTOR(h) is (-sin h, cos h, 0) -- which IS the
        -- counter-clockwise rotation about +Z applied to +Y. So the mathematical
        -- yaw and the engine's heading are the same number in the same sense, and
        -- tools/test_board.lua's prop fixture is built on that identity.
        --
        -- ═══ WHY 135 AND NOT -135, AND WHY IT COSTS NOTHING IF I AM WRONG ═══
        --
        -- ymaps frequently store the INVERSE of an entity's rotation, and the
        -- conjugate of this quaternion -- (0, 0, +0.9238796, -0.3826834) -- comes
        -- out at -135 (225). Both are defensible from the four numbers alone.
        --
        -- 135 IS THE DIRECT READING, AND THE DIRECT READING IS THE ONE TO WRITE
        -- DOWN, because nothing is riding on it: the prop is FOUND, not placed,
        -- so its real orientation comes from the ymap through the entity, and
        -- BR.Dui.drawBoard builds its quad from that entity's own matrix. This
        -- field steers no geometry. It is the claim, recorded, so it can be
        -- checked -- and /brboard prints it beside the heading the found entity
        -- actually has, with the difference, so one command in the lobby settles
        -- it. If that line reads `heading 225.00 (config 135.0, off by 90.0)`,
        -- the ymap did invert it and this number becomes 225. The board looks
        -- identical either way.
        heading = 225.0,
    },

    -- ═══════════════════════════════════════════════════════════════════════
    -- WHERE THE PAGE SITS ON THAT PROP
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- All five are METERS AND DEGREES IN THE PROP'S OWN LEVELED FRAME, and all
    -- five are live under /brboard.
    --
    -- ═══ THREE OF THEM ARE nil, AND nil HERE MEANS "MEASURE THE PROP" ═══
    --
    -- ⚠ NOT AN OVERSIGHT AND NOT A HALF-FINISHED EDIT. It is a documented value
    -- that client/board.lua's `fitted()` resolves off GET_MODEL_DIMENSIONS.
    --
    -- The previous draft shipped forwardM 0.06, upM 1.20 and widthM 2.40. Those
    -- were invented with no prop to measure against and they said so. They are
    -- now known to be wrong, not merely untested: `prop_huge_display_02` is a
    -- STAGE DISPLAY -- it is the screen the base game drives through the
    -- "Big_Disp" render target in fameorshame_eps.c -- and a 2.4 m board on it
    -- would be a postage stamp somewhere in the middle of a wall.
    --
    -- AND I COULD NOT ESTABLISH ITS REAL SIZE. No dimensions for this model are
    -- published anywhere I could find, and this project does not ship a plausible
    -- number in place of a measured one. But a table of dimensions was never the
    -- only way to get them -- exactly the argument config/fuel.lua's pump lookup
    -- already won. THE ENGINE KNOWS. GET_MODEL_DIMENSIONS hands back the model's
    -- own bounding box, the prop is standing in front of the player by the time
    -- anything here is read, and a measurement beats an estimate every time:
    --
    --   forwardM  the front face of the box, plus 2 cm of clearance
    --   upM       the vertical centre of the box
    --   widthM    the full width of the box
    --
    -- ⚠ AND THEY REMAIN UNTESTED IN-GAME. Nobody has stood in front of this and
    -- looked at it. A measurement is not a playtest: the box includes whatever
    -- housing, frame or rigging the model carries, so the board will start a
    -- little WIDER than the lit screen area and will want nudging down, and
    -- which side of the model is the screen is the modeller's choice, not
    -- something a bounding box records. If it comes up behind the prop, that is
    -- `yaw 180` and not a bug.
    --
    -- PIN ANY OF THEM BY WRITING A NUMBER HERE, which is what pasting /brboard's
    -- block back does. An explicit number always wins over the measurement.
    --
    -- `forwardM` is out along the prop's facing: how far the quad stands off the
    -- front of the screen. Far enough to beat z-fighting with the model's own
    -- surface, near enough that it reads as printed on the prop rather than
    -- floating in front of it. If the board reads as floating, this is the first
    -- number to shrink, and the second thing to consider is AddReplaceTexture
    -- (see client/board.lua's header).
    forwardM = 0.12,
    -- ...along the face, positive to the READER'S RIGHT. The reader stands in
    -- front of the board looking back at it, so this moves the board the way it
    -- looks like it should move from where anybody is standing.
    --
    -- NOT MEASURED, AND 0.0 IS NOT nil. A bounding box has no opinion about
    -- where along a screen its picture belongs, and centred is the answer
    -- anyway: 0.0 is a real instruction meaning "in the middle of the prop".
    sideM    = -0.21,
    -- ...and straight up the WORLD from the prop's origin. Up the world rather
    -- than up the entity, for the reason BR.Dui's drawPlane states: a height
    -- pushed through a rolled entity's matrix swings out sideways.
    upM      = 0.02,

    -- HOW WIDE THE BOARD IS, IN METERS. The height follows the texture's own
    -- aspect (720/1280), so this is one number and not two, and the picture can
    -- never be stretched -- which also means a board fitted to a screen that is
    -- not 16:9 will fit across and leave a band above or below.
    widthM   = 9.43,

    -- AND HOW FAR IT IS TURNED OFF THE PROP'S OWN FACING, degrees, positive
    -- counter-clockwise seen from above.
    --
    -- IT EXISTS BECAUSE A PROP'S FORWARD IS THE MODELLER'S CHOICE AND NOT OURS.
    -- Plenty of GTA props face along their local -Y, or are authored square to a
    -- wall they were meant to hang on. Without this, aligning the board would
    -- mean rotating the prop away from the direction the owner wants the prop
    -- itself to face. 0.0 means "the same way the prop faces".
    yawDeg   = 180.0,

    -- ═══════════════════════════════════════════════════════════════════════
    -- WHEN IT DRAWS
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- How far away the quad is still drawn, in meters. The DUI itself exists for
    -- the whole of warmup (the issue is explicit about that), so this gates two
    -- DrawSpritePoly calls per frame and nothing else. Wide enough that the
    -- board is up before a player is close enough to read it, short enough that
    -- somebody at the far end of the pad is not paying for a quad a few pixels
    -- across.
    drawM = 80.0,

    -- ═══════════════════════════════════════════════════════════════════════
    -- WHAT IS SHOWN INSTEAD WHEN THERE IS NO PAGE
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- Owner, 2026-09-09: "If ringmaster is down, that's fine. We just show static
    -- on the screen instead."
    --
    -- STATIC IS A TEXTURE, NOT AN ABSENCE. A blank quad and a switched-off board
    -- look the same as a bug; a screen full of noise reads as a screen that is on
    -- and has nothing to show. This is a local page in br_ui, so it loads with no
    -- network at all -- which it has to, because the whole reason it is being
    -- shown is that the network did not answer.
    --
    -- IT IS THE SAME BROWSER. client/board.lua swaps between this and the board
    -- with SetDuiUrl and never destroys or recreates the DUI to change what is on
    -- it, which the issue names as a rule.
    staticUrl = 'nui://br_ui/dui/static.html',
}

--- The board's URL for one player, or nil if there is no sensible one.
---
--- ═══ PURE, SO THE ONE STRING THIS FEATURE BUILDS IS TESTABLE ═══
---
--- Everything else about the board needs a game to look at. This does not, and
--- it is the piece a typo hurts most: a wrong URL is a browser sitting on an
--- error page with nothing anywhere saying why.
---
--- ═══ THE LICENSE IS CHECKED FOR SHAPE, AND THAT IS NOT ABOUT TRUST ═══
---
--- The value arrives from our own server, off the FiveM connection, so nobody is
--- forging it. The check is about what a stray value would DO: this string is
--- handed to CreateDui, and a license carrying a '#', a '&' or a space would
--- build a URL that silently addresses something else. FiveM formats a `license`
--- identifier as hex, so hex is what is accepted, and anything else answers nil
--- and draws no board rather than fetching an unknown address.
---
--- NO LENGTH PIN. Forty characters is what this build produces and pinning it
--- would make a future FiveM change present as "the board stopped working" with
--- nothing saying why. The character set is the part that matters.
---
--- @param license string|nil  BARE, with no `license:` prefix. BR.Identity.licenseOf
---                            already strips it; BR.Identity.qualified puts it back
---                            for the paths that store it, and this is not one.
--- @param cfg table|nil       defaults to BR.Config.Board
--- @return string|nil
function BR.BoardUrl(license, cfg)
    cfg = cfg or BR.Config.Board
    if type(cfg) ~= 'table' then return nil end

    if type(license) ~= 'string' then return nil end
    if license == '' then return nil end
    if license:match('^%x+$') == nil then return nil end

    local host = cfg.host
    local path = cfg.path
    if type(host) ~= 'string' or host == '' then return nil end
    if type(path) ~= 'string' or path == '' then return nil end

    -- `id` IS THE ROUTE'S OWN PARAMETER NAME and is written here rather than in
    -- config because it is not a knob: Ringmaster's handler reads
    -- `searchParams.get('id')` and answers 400 to anything else. The owner's
    -- message spells this URL out in full and this line is that spelling.
    return host .. path .. '?id=' .. license
end

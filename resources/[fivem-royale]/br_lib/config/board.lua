-- The warmup-area stat board (#247): where it stands, how big it is, and the
-- one URL it points at.
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
    -- IT DOES NOT HAVE ONE. CreateDui(url, w, h) takes pixels and nothing else.
    -- There is no frame rate to set, because repaint is driven by the PAGE
    -- CHANGING: a still document costs approximately nothing after its first
    -- paint, and anything that animates continuously repaints this texture
    -- forever, on every machine in the lobby at once. That is a page-side
    -- property, and Ringmaster's renderer is deliberately built with no
    -- transition, no keyframe and no easing anywhere in it.
    --
    -- WHAT THE PIXELS COST. A runtime texture from a DUI handle is live RGBA, so
    -- the bill is width x height x 4 bytes and nothing amortizes it: 1920x1080 is
    -- 8.3 MB, 1280x720 is 3.7 MB. That is 4.6 MB per client given back on a
    -- machine already holding a battle royale map, and it is paid whether or not
    -- anybody is looking at the prop.
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
    -- ⚠ NOTHING SHIPS HERE, AND THE EMPTINESS IS THE POINT.
    --
    -- Owner, 2026-09-09: "I already have a prop in mind for this. Not sure how to
    -- put the DUI on it though. Need your help on that. I can help align it if
    -- you give me the tools."
    --
    -- He has not said which prop. This project does not guess a model name and
    -- does not go shopping for a "good" one -- config/warmupcrates.lua carries
    -- the same rule about his surveyed coordinates. So `model` is nil, and a nil
    -- model means br_core/client/board.lua spawns nothing, creates no browser and
    -- draws nothing at all. The feature is inert until he fills these four in.
    --
    -- THE TOOL THAT FILLS THEM IN IS /brboard. `prop <model>` auditions a model
    -- live, `here` drops it at the player's own feet and heading, and the command
    -- prints every line below in the shape it takes in this file, ready to paste.
    -- Nobody has to guess twice.
    prop = {
        -- The model name, e.g. 'prop_tv_flat_01'. nil = no board.
        model   = nil,
        -- Where it stands. Surveyed numbers, used literally: this project does
        -- not round, lower or ground-probe the owner's coordinates.
        x       = nil,
        y       = nil,
        z       = nil,
        -- Which way it faces, degrees. The quad stands out along this heading,
        -- so a board reading backwards is a heading 180 out.
        heading = 0.0,
    },

    -- ═══════════════════════════════════════════════════════════════════════
    -- WHERE THE PAGE SITS ON THAT PROP
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- All five are METERS AND DEGREES IN THE PROP'S OWN LEVELED FRAME, and all
    -- five are live under /brboard. They are starting points chosen to be
    -- visible rather than measured against anything -- there is no prop to
    -- measure against yet -- and they are expected to come back from the first
    -- alignment pass changed.
    --
    -- `forwardM` is out along the prop's facing, which is how far the quad
    -- stands off the front of the screen. Small and positive: far enough to beat
    -- z-fighting with the model's own surface, near enough that it reads as
    -- printed on the prop rather than floating in front of it. If the board
    -- reads as floating, this is the first number to shrink, and the second
    -- thing to consider is AddReplaceTexture (see client/board.lua's header).
    forwardM = 0.06,
    -- ...along the face, positive to the READER'S RIGHT. The reader stands in
    -- front of the board looking back at it, so this moves the board the way it
    -- looks like it should move from where anybody is standing.
    sideM    = 0.0,
    -- ...and straight up the WORLD from the prop's origin. Up the world rather
    -- than up the entity, for the reason BR.Dui's drawPlane states: a height
    -- pushed through a rolled entity's matrix swings out sideways.
    upM      = 1.20,

    -- HOW WIDE THE BOARD IS, IN METERS. The height follows the texture's own
    -- aspect (720/1280), so this is one number and not two, and the picture can
    -- never be stretched.
    widthM   = 2.40,

    -- AND HOW FAR IT IS TURNED OFF THE PROP'S OWN FACING, degrees, positive
    -- counter-clockwise seen from above.
    --
    -- IT EXISTS BECAUSE A PROP'S FORWARD IS THE MODELLER'S CHOICE AND NOT OURS.
    -- Plenty of GTA props face along their local -Y, or are authored square to a
    -- wall they were meant to hang on. Without this, aligning the board would
    -- mean rotating the prop away from the direction the owner wants the prop
    -- itself to face. 0.0 means "the same way the prop faces".
    yawDeg   = 0.0,

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

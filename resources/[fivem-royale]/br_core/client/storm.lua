-- The storm, client half: rendering and readouts. NOTHING in this file is
-- authoritative -- the wall, the blips, the vignette and the countdown are all
-- solved locally from the record the server published (BR.State.storm, via
-- STORM_SYNC or the snapshot) against the synced clock. Damage arrives in
-- state.lua, deliberately not here: every callback in this file can be
-- disabled (/brloop disable storm.wall etc.) and the player must keep taking
-- exactly the same damage -- that is the M4 authority drill.

BR = BR or {}

local cfg = BR.Config.Storm

-- ---------------------------------------------------------------- helpers ---

--- The record, gated on the one state where a storm can exist. BUS and
--- earlier have no record; ENDED keeps whatever is left but must not render
--- it under the verdict slam. And gated on MY OWN state too: a LOBBY
--- bystander shares the match.state but not the match -- they were getting
--- "storm closing" toasts at the vista menu, storm blips on their pause
--- map, and (with the distance gate gone) a purple wall on the horizon.
local function activeRecord()
    local ms = BR.State.match.state
    -- ENDED COUNTS, and that is the whole fix for the storm snapping off early.
    --
    -- The match flips to ENDED at the START of the verdict sequence, and the
    -- fade to black takes a couple of seconds after that. Tearing the storm
    -- down on the transition therefore killed the colour grade, the rain and
    -- the vignette a beat BEFORE the screen faded -- so the last thing a
    -- player saw was the weather being switched off, which reads as a bug
    -- rather than as the match ending (user, 2026-08-06).
    --
    -- CLEANUP is where it really goes away, and by then the screen is black.
    -- Damage is the server's and stopped at ENDED regardless; this is only
    -- what the client draws.
    if ms ~= BR.MatchState.PLAYING and ms ~= BR.MatchState.ENDED then
        return nil
    end
    if BR.State.me.state == BR.PlayerState.LOBBY then return nil end
    return BR.State.storm
end

--- Circle 1 before the storm exists, gated on the two states it belongs to.
---
--- ═══ THE MIRROR IMAGE OF activeRecord, AND THE GATE IS THE TEARDOWN ═══
---
--- WARMUP and BUS, and nothing else. The preview is a preview: it must not be on
--- screen during PLAYING beside the real wall it was standing in for, and it must
--- not survive a match ending. Both of those are this one test rather than a
--- lifecycle to get right -- the state has already moved on by the time anything
--- could draw a stale circle, exactly as activeRecord relies on for the record.
--- client/state.lua ALSO drops the field when STORM_SYNC arrives, which is belt to
--- this brace: either alone is enough.
---
--- ═══ AND THIS IS THE **PUBLISHED FIELD'S** GATE, WHICH IS NOT THE WALL'S ANY MORE
---     (#340) ═══
---
--- Two callers read this and only one still reads it alone. The map RING stops here,
--- because storm.state's own `nextBlip` draws the same circle in the same purple from
--- the record the instant one exists, so extending the ring would be two purple rings
--- on one circle. The WALL goes through previewWallCircle, which starts with this
--- function and then covers the PLAYING stretch off the record -- because the real
--- wall is suppressed for most of the phase-1 hold and the owner was looking at an
--- empty horizon. THE CONSTRAINT IN THE PARAGRAPH ABOVE IS UNCHANGED AND IS WHY THE
--- WALL'S EXTENSION IS A HANDOFF: it ends as the real wall fades in, on the real
--- wall's own clock, so the two are never both on screen at strength.
---
--- AND GATED ON MY OWN STATE, for the reason activeRecord is: a LOBBY bystander
--- shares the match state without being in the match, and they were the ones
--- getting storm blips on their pause map at the vista menu.
--- @return table|nil  { cx, cy, r }
local function previewCircle()
    local pv = BR.State.stormPreview
    if not pv then return nil end
    local ms = BR.State.match.state
    if ms ~= BR.MatchState.WARMUP and ms ~= BR.MatchState.BUS then return nil end
    if BR.State.me.state == BR.PlayerState.LOBBY then return nil end
    return pv
end

--- Solve the record right now, in one place, so every consumer in this file
--- agrees on the circle down to the millisecond.
local function solveNow(rec)
    return BR.StormAt(rec, BR.Clock.now())
end

--- WHOSE POSITION EVERY "WHERE AM I RELATIVE TO IT" ANSWER HERE IS MEASURED FROM.
---
--- "Storms are not synced between screens when spectating" -- the owner,
--- two-player playtest, 2026-08-23 (#225). NOTHING ABOUT THE STORM HAD
--- DESYNCED. The record goes to every src in the match with no state filter, a
--- dead spectator is stored the same bytes as everybody else, and BR.StormAt is
--- pure over (record, synced clock) -- so both machines were solving the
--- identical circle, in the same place, to the millisecond. What differed was
--- the BODY they measured it from: a spectator's ped is a corpse where they
--- fell, which client/spectate.lua deliberately never moves and must not.
---
--- THE SYMPTOM IS EXACTLY THAT SPLIT, and it is why the report reads as a sync
--- bug. The purple curtain and the two map rings are drawn at absolute world
--- coordinates, so they landed in the right place on both screens. The
--- distance, the bearing, the "Safe Zone -- this way" arrow, the sky and the
--- colour grade are all derived from viewer position, so none of them did --
--- and that is most of what a player actually reads.
---
--- client/gamerules.lua's mad-driver anchor is the same fix for the same class
--- of caller, and this mirrors its shape down to the fallback: a session whose
--- eased point has not landed yet (the first frames) measures from the ped
--- rather than throwing. With no session running this is byte-for-byte what it
--- always was -- same native, same value -- which is the point.
---
--- ═══ AN ADMIN SPECTATOR KEEPS THEIR OWN STORM, AND THAT IS THE STAKE TEST ═══
---
--- The console's Spectate button requires only that the admin be in game
--- (server/spectate.lua's adminStart), so an admin may be ALIVE and mid-fight
--- in their own match while watching somebody else. Their body is still out
--- there and server/storm.lua is still billing it for standing outside the
--- wall, so moving their readout onto the shot would let them bleed to death
--- behind a HUD saying they are safe -- this bug pointed the other way.
---
--- SO THE QUESTION IS "HAS THIS BODY A STAKE LEFT", NOT "IS THIS AN ADMIN". A
--- dead admin follows the shot for the same reason a dead player does, a living
--- one keeps their own, and nothing in this file has to learn what an admin is
--- or reach into the session for it.
--- @return vector3 point, string source  'spectate' when it follows the shot
local function viewpoint()
    local S = BR.Spectate
    if S and S.active and S.watchPoint and S.active() then
        local me = BR.State.me.state
        if me ~= BR.PlayerState.ALIVE and me ~= BR.PlayerState.DBNO then
            local p = S.watchPoint()
            if p then return p, 'spectate' end
        end
    end
    return GetEntityCoords(PlayerPedId()), 'ped'
end

-- ------------------------------------------------------------------- wall ---

--- Draw the boundary of `shape` as ONE CONTINUOUS SURFACE, at `alphaScale` of
--- full strength. `shape` is already inset; drawWall owns that.
---
--- ═══ A WALL IS A SURFACE, NOT A ROW OF TUBES (#336) ═══
---
---   "what you just drew is not a wall - it's a bunch of circles which are the
---    wrong height and you're still using 3dmarkers..... I thought you were
---    going to research ways to not do that."   -- the owner, 2026-09-22, #336
---
--- THE STRIPING WAS NEVER A TUNING FAILURE, and that is why this is a third
--- renderer rather than a fourth value of `overlap`. A DrawMarker type 1 is a
--- translucent CYLINDER. Seen from outside, a translucent cylinder is brightest
--- at its silhouette edges, where the line of sight passes through the most
--- surface, and dimmest through the middle -- so every column contributes two
--- bright vertical lines, and eighty of them in a row are a picket fence.
--- config/storm.lua already recorded the other half of it beside `overlap`:
--- widen the columns until they meet and the doubled alpha where they cross bands
--- the wall dark instead. There is no value between the two, because two
--- overlapping translucent tubes are not one surface. Tuning them is the thing
--- that has already failed twice.
---
--- So each consecutive PAIR of walk points is one quad -- two DRAW_POLY
--- triangles -- from a fixed bottom z to a config top z. Uniform alpha, no
--- seams, and a height this file chooses rather than one a cylinder's scale
--- happens to produce.
---
--- ═══ ONE WINDING PER QUAD, AND THE TEST IS PER QUAD RATHER THAN PER FRAME ═══
---
--- DRAW_POLY is SINGLE SIDED. Its own doc: "Only one side of the drawn triangle
--- is visible", the visible face being the one the cross product points toward.
--- PolyZone emits FOUR polys per edge to cover both windings and copying that is
--- exactly wrong here -- two coincident translucent surfaces double the alpha,
--- which is the banding this whole change exists to escape. So a quad is emitted
--- ONCE, wound so that its visible face is the side the viewer is standing on.
---
--- The obvious spelling of that is one signed distance per frame: outside the
--- zone wind everything outward, inside wind everything inward. IT IS WRONG IN
--- TWO PLACES, both of which the shipping shapes reach.
---
---   * THE FAR SIDE OF THE RING. A viewer outside the zone is outside the near
---     wall and, looking across the circle, on the INSIDE of the far one. One
---     winding for the whole frame makes the far rim face away and vanish, so a
---     circle reads as a half arc with nothing behind it -- the mid-air stop that
---     #328 already paid for once.
---   * THE SECOND ISLAND. A viewer standing inside the next circle of a broken-out
---     phase is INSIDE the zone, so the per-frame rule winds the current circle
---     inward too -- and the rim nearest them, the one they are about to walk
---     into, is the rim that disappears. Invisible from one side and a missing
---     wall from the other, which is the failure mode the issue names.
---
--- So each quad asks the question for itself, with one dot product against its
--- own plane: the quad is vertical and its normal is horizontal, so the viewer's
--- z never enters and a spectator in a helicopter gets the same faces as a ped.
--- RIGHT OF TRAVEL IS OUTWARD, by storm_shape.lua's interior-on-the-left
--- convention -- the same convention seg's `nx, ny` and arc's `out` carry -- so
--- the outward normal of a quad is just its own tangent turned ninety degrees.
---
--- ═══ CALL ORDER, WHICH TURNS OUT NOT TO BE A DECISION ═══
---
--- "Intersecting triangles are not supported: They overlap in the order they were
--- called", so the far side of the ring composites through the near side in CALL
--- ORDER rather than by depth. The reason nothing here sorts is that EVERY QUAD IS
--- EMITTED WITH THE SAME `colour` AND THE SAME ALPHA: src-over compositing of two
--- identical values is symmetric in the two draws, so no ordering of wall quads
--- against other wall quads can change a pixel. Sorting a hundred quads per frame
--- would buy exactly nothing.
---
--- THAT IS A CLAIM ABOUT THE BLEND AND ONLY A PLAYTEST CAN SETTLE IT. It holds for
--- ordinary src-over alpha and it does not hold if DRAW_POLY blends additively or
--- writes depth, and no primary source says which. If it turns out to be additive
--- the symptom is specific and recognisable -- a bright band across the middle of
--- the zone where the near and far walls overlap on screen -- and the answer is to
--- drop the quads whose face is the inward one from outside the zone, not to sort.
---
--- WHAT ORDER CANNOT FIX, AND WHAT MAKES IT ACCEPTABLE ANYWAY, is the number of
--- layers a sight line crosses. Across the middle of the ring that is two, near
--- wall then far wall, and the alpha doubles there -- which is precisely what the
--- shipping 'solid' cylinder already does, because a sight line across a cylinder
--- crosses its side surface twice as well. The strip is no denser than the wall
--- the owner chose on 2026-08-03. PolyZone's both-windings idiom would have made
--- it four.
---
--- ═══ THE SHARED EDGE IS THE SAME NUMBERS, NOT TWO AGREEING ANSWERS ═══
---
--- Quad i ends where quad i+1 begins, and the walk REUSES the stored point rather
--- than asking the shape for it twice. The last quad of a loop closes onto the
--- stored FIRST point for the same reason.
---
--- AND THIS IS NOT ABOUT A VISIBLE SEAM, said plainly because the tempting version
--- of this paragraph claims a hairline and it would be a lie. Measured: rebuilding
--- a component's closing point instead of reusing it lands somewhere else on 11
--- percent of whole-metre radii between 20 and 2600, and the worst disagreement
--- anywhere is 3.5e-12 metres. Computing a Venn crossing from arc 1's far end and
--- from arc 2's near start -- two different centres, which is the worst case this
--- file has -- disagrees by 4.9e-13. Picometres are not an artifact.
---
--- WHAT IT BUYS IS THAT THE INVARIANT IS STRUCTURAL. "Neighbours share an edge" is
--- either true by construction or true by two expressions continuing to match, and
--- the second is a thing a later rewrite can quietly stop doing -- a walk
--- reorganised to emit per PIECE rather than per component is the obvious one, and
--- it is where the two-centre case above lives. Reuse costs nothing, so the
--- invariant is spelled the way it is meant and tools/test_storm.lua asserts it
--- with `==` rather than a tolerance.
-- ═══ THE FADE, AND WHY IT IS A LADDER THIS FILE CLIMBS AT RUNTIME (#336) ═══
--
--   "are you able to make the wall fade bottom to top like the 3dmarker? if so,
--    just make it the same height as the marker was."      -- the owner, 2026-09-22
--
-- The fade is what pays for the height. The columns stood 950 metres tall -- base
-- -100, scaleZ render.height * 3 + 50 -- and topped out at world z 850 over a city
-- whose ground is around 30, which is half of "the wrong height". A wall whose top
-- FADES TO NOTHING can be that tall without towering, because the part that
-- towered is not drawn. So the height follows the fade and not the other way
-- round, and neither is a number this file decides alone: both are in
-- config/storm.lua's `strip` table.
--
-- ═══ DRAW_POLY CANNOT DO IT, AND THE TEXTURE IT NEEDS IS ONE WE MAKE ═══
--
-- DRAW_POLY takes one colour and one alpha for a whole triangle, so a gradient
-- inside a quad is not expressible in it at any triangle count. Stacking flat quads
-- is the only thing it can do, and three of them read as THREE VISIBLE STEPS --
-- which is the owner's playtest verdict on the first attempt and the defect this
-- version exists to fix.
--
-- ═══ WHAT THE FIRST ATTEMPT GOT WRONG, WRITTEN OUT SO IT IS NOT RE-DERIVED ═══
--
-- It concluded that a smooth fade was impossible in this estate, on two facts that
-- are both TRUE: there is no stock flat-white texture in the game, and this estate
-- ships no streamed assets. The error was believing those two closed the question.
--
-- A TEXTURE DOES NOT HAVE TO BE STREAMED. FiveM builds one in memory --
-- CREATE_RUNTIME_TXD, CREATE_RUNTIME_TEXTURE, SET_RUNTIME_TEXTURE_PIXEL,
-- COMMIT_RUNTIME_TEXTURE -- with no .ytd, no stream folder, no manifest entry and no
-- RequestStreamedTextureDict anywhere near it. The no-streamed-assets rule is not
-- bent by this; it is not touched by it.
--
-- AND THE PROOF WAS ALREADY IN THIS REPO. br_core/client/dui.lua:144 creates a
-- runtime TXD, :145 builds a runtime texture from a CEF surface, and :410 and :1131
-- hand that dict/texture pair straight to DrawSpritePoly as world-space quads. It
-- has been in production since #236. `grep -c RequestStreamedTextureDict dui.lua`
-- is 0. client/natives.lua already probes both CreateRuntimeTxd (:2845) and
-- DrawSpritePoly (:3038) at boot.
--
-- ═══ SO THE RAMP IS BAKED, NOT INTERPOLATED, AND THE UNPROVEN NATIVE IS GONE ═══
--
-- `_DRAW_SPRITE_POLY_2` -- the per-vertex-alpha native the first attempt was built
-- around, with no working call site anywhere in public code -- is not used here any
-- more and nothing in this file mentions it. Baking the ramp into the texture's own
-- 256 alpha levels means the ordinary single-colour DRAW_SPRITE_POLY is enough, so
-- the wall now draws through a native this codebase has been shipping for months.
--
-- THAT IS ALSO CHEAPER AND MORE EXPRESSIVE AT THE SAME TIME. 2 polys per quad rather
-- than 6, because the gradient is not approximated by stacking; and the ramp can
-- have a KINK in it, which per-vertex alpha could not express at any cost -- see
-- rampAlpha below, which holds the wall at full strength until ground level and only
-- then begins to thin.
--
-- ═══ THE ONE THING THIS DESIGN GUESSES: PREMULTIPLIED OR STRAIGHT ═══
--
-- The texture is written as PREMULTIPLIED GREY, r = g = b = a. The only proven
-- DrawSpritePoly path in this tree is dui.lua's, whose source is a CEF surface, and
-- CEF surfaces are premultiplied -- so that is the blend this native is known to
-- work with HERE, and matching it is the closest thing to evidence available without
-- a frame buffer.
--
-- WHITE-WITH-ALPHA WOULD BE THE BACKWARDS GUESS: under a premultiplied blend
-- (255, 255, 255, a) contributes full colour at every height regardless of a, which
-- is an opaque white haze over the top of the wall -- a visibly broken fade, not a
-- subtle one. Premultiplied grey under a STRAIGHT blend is the benign error in the
-- other direction: the colour is scaled by the ramp as well as the alpha, so the
-- fade comes out roughly squared -- steeper than authored, thinner at the top, still
-- a smooth bottom-to-top fade.
--
-- HOW A READER TELLS WHICH ONE THEY ARE LOOKING AT, since only eyes can: under a
-- premultiplied blend the purple keeps its hue all the way up and simply gets more
-- see-through. Under a straight blend the purple also gets DARKER as it rises, so
-- the top of the wall reads as a dim smudge shading toward black before it
-- disappears. If it is the second and the top is too thin, raise fade.topAlpha.
--
-- ═══ AND WHAT NO TEST HERE CAN SEE ═══
--
-- Code can establish that the natives exist, that the texture was created and read
-- back at the size asked for, and that the draw calls carry the geometry, UVs and
-- alphas intended. It cannot establish that a pixel appeared, nor which blend the
-- pipeline used. Those are playtest-only, so the symptom of each is written down
-- above and the console line below names which path is running.
local fade = { path = nil, rung = nil, said = false }

--- Is the textured-poly native in this build's native table?
---
--- A FiveM client exposes natives as globals, so an unimplemented one is `nil`
--- rather than a function that fails -- which makes this answerable without drawing
--- anything. This is the native dui.lua has shipped since #236, so a build without
--- it has bigger problems than the wall; it is checked anyway, because the cost of
--- being wrong is a pcall'd frame callback and no curtain at all.
--- @return boolean
local function spritePolyExists()
    return type(_G.DrawSpritePoly) == 'function'
end

-- ═══ THE RUNTIME RAMP: BUILT ONCE, READ BACK BEFORE IT IS TRUSTED ═══
--
-- Latched for the session in the same shape as `fade`: a texture handle plus the two
-- names the draw call needs. `tex` is the handle the read-back gate asks about, and
-- `txd`/`name` are what DrawSpritePoly is actually passed.
--
-- AND THE v RANGE, WHICH IS A PROPERTY OF THE TEXTURE AND NOT OF THE QUAD (#341).
-- `v0`/`v1` are the half-texel inset the draw maps the wall's bottom and top to; they
-- are computed from the height the texture was ACTUALLY built at, so the quad cannot
-- inset by a row count the texture does not have. buildRamp's tail argues them.
local ramp = { tex = nil, txd = nil, name = nil, v0 = nil, v1 = nil }

--- The fade's alpha multiplier at height `z`, with the ramp pinned to GROUND LEVEL.
---
--- ═══ THE GEOMETRY'S BOTTOM IS NOT THE RAMP'S BOTTOM, AND THAT WAS A BUG ═══
---
--- The strip stands on baseZ (-150) so that no gap can open under the curtain on a
--- slope -- the underground skirt is load-bearing and stays. But a ramp measured
--- from baseZ spends its first 15 percent below the lowest ground this config admits
--- (2.0, from the map's own POI table), which is resolution spent where nobody can
--- look and, worse, a wall that is not full strength at a player's FEET.
---
--- MEASURED, on the 3-band fallback before this function existed: the bottom band's
--- centre sampled the ramp at t 0.1667 and drew at alpha 92 where render.alpha says
--- 110. The curtain was 16 percent fainter at eye level than the config asked for,
--- on every shape, in every phase, and nothing said so.
---
--- So alpha is FLAT at baseAlpha from baseZ up to rampBaseZ, and ramps to topAlpha
--- between rampBaseZ and topZ. BOTH PATHS USE THIS ONE FUNCTION -- the gradient
--- bakes it into the texture's rows, the bands sample it at their own centres -- so
--- the fallback is an approximation of the same curve rather than a different one,
--- and the fix lands on both.
--- @param fc table    cfg.render.strip.fade
--- @param zb number   the geometry's bottom
--- @param zt number   the geometry's top
--- @param z number    the height to evaluate at
--- @return number     0..1 multiplier on render.alpha
local function rampAlpha(fc, zb, zt, z)
    local a0 = fc.baseAlpha or 1.0
    local a1 = fc.topAlpha or 0.0
    -- CLAMPED INTO THE GEOMETRY, because a rampBaseZ under the wall's own bottom
    -- would put the flat section outside the span entirely and a rampBaseZ at or
    -- above the top would divide by zero or by a negative -- a nan alpha, which is
    -- an invisible wall with nothing in the console.
    local z0 = fc.rampBaseZ or 0.0
    if z0 < zb then z0 = zb end
    if z0 >= zt then return a0 end
    if z <= z0 then return a0 end
    if z >= zt then return a1 end
    return a0 + (a1 - a0) * ((z - z0) / (zt - z0))
end

--- Bake the ramp into a runtime texture, once per resource start.
---
--- ═══ WHY THE PIXELS ARE GREY AND NOT WHITE: r = g = b = a ═══
---
--- Premultiplied, matching the one proven DrawSpritePoly source in this tree (a CEF
--- surface, which is premultiplied). The long note above has the reasoning and what
--- each blend looks like if the guess is wrong.
---
--- ═══ ROW 0 IS THE BOTTOM OF THE WALL, WHICH IS NOT OBVIOUS ═══
---
--- v = 0 is the FIRST row of a texture, not the last -- the ordinary D3D convention,
--- and this tree already depends on it: dui.lua's drawQuad documents `a` as "the
--- texture's top-left corner" and gives it UV (0, 0), and the warmup board and the
--- crate labels render right side up in production off exactly that. The draw below
--- gives the wall's BOTTOM v = 0, so the wall's bottom samples row 0 and row 0 must
--- hold baseAlpha. The texture is therefore stored bottom-of-wall first, which looks
--- upside down if you picture it as a picture of the wall.
---
--- IF THIS IS WRONG THE FAILURE IS UNMISTAKABLE rather than subtle: the wall would
--- be transparent at the ground and solid at 850 m, a purple ceiling with no base.
---
--- ═══ AND THE CURVE GOES IN THE TEXTURE, NOT IN THE UVs ═══
---
--- v maps linearly to world z, so the ramp's kink at ground level has to be carried
--- by the ROWS. That is the whole reason a baked texture beats a per-vertex alpha:
--- the flat-then-falling curve is just what the rows say, at no cost.
--- @param fc table   cfg.render.strip.fade
--- @param zb number  the geometry's bottom
--- @param zt number  the geometry's top
--- @return boolean ok, string|nil why
local function buildRamp(fc, zb, zt)
    if ramp.tex then return true end

    -- NAMED ONE AT A TIME so the rung can say WHICH native is missing. A build with
    -- DrawSpritePoly but no runtime-texture natives is not a build anybody has, and
    -- the console line is free.
    local need = {
        { 'CreateRuntimeTxd',        _G.CreateRuntimeTxd },
        { 'CreateRuntimeTexture',    _G.CreateRuntimeTexture },
        { 'SetRuntimeTexturePixel',  _G.SetRuntimeTexturePixel },
        { 'CommitRuntimeTexture',    _G.CommitRuntimeTexture },
    }
    for i = 1, #need do
        if type(need[i][2]) ~= 'function' then
            return false, ('%s is not in this build'):format(need[i][1])
        end
    end

    local w = math.max(1, math.floor(fc.rampW or 8))
    local h = math.max(2, math.floor(fc.rampH or 256))

    --- One creation attempt under a name suffix.
    ---
    --- ═══ THE SUFFIX GOES ON THE DICTIONARY TOO, AND THAT IS THE POINT ═══
    ---
    --- CREATE_RUNTIME_TEXTURE returns nothing if the name is already taken, which is
    --- the documented restart hazard: a br_core restart in the same client session
    --- loses our Lua handle while the engine keeps the texture. But FiveM's own
    --- RuntimeAssetNatives.cpp refuses one level HIGHER than that -- CREATE_RUNTIME_TXD
    --- only builds its backing dictionary when the streaming slot has no handle yet,
    --- so the second call for a name that already exists yields a TXD object with no
    --- dictionary and EVERY CreateTexture on it returns nothing, whatever the texture
    --- is called. Suffixing only the texture name would therefore retry into the same
    --- wall. Both names move together.
    local function attempt(suffix)
        local txdName = (fc.txd or 'br_storm_ramp') .. suffix
        local texName = (fc.texture or 'ramp') .. suffix
        local txd = CreateRuntimeTxd(txdName)
        if not BR.NativeTruthy(txd) then return nil end
        local tex = CreateRuntimeTexture(txd, texName, w, h)
        if not BR.NativeTruthy(tex) then return nil end
        return tex, txdName, texName
    end

    -- ═══ THE NAME IS PROBED FROM A COUNTER, BECAUSE ONE RETRY WAS NOT ENOUGH ═══
    --
    -- Every br_core restart in the same client session loses our Lua handle while the
    -- engine keeps the slot, so each start has to find a name nobody has taken yet.
    -- This used to be one retry -- the plain name, then `_b`, then bands -- and that
    -- put the THIRD restart of a session on the banded wall. The owner restarts
    -- br_core repeatedly inside a twenty-minute round, so the third one would have
    -- shown him three steps again and read as the fade regressing. The console rung
    -- said so, but only to somebody watching the console at that moment.
    --
    -- SO IT COUNTS UP INSTEAD: the plain name first (a fresh client gets the clean
    -- one), then `_2`, `_3`, and so on. Nothing persists across a restart, so each
    -- start re-probes from the beginning and lands on the first free slot.
    --
    -- ═══ AND EVERY SUCCESSFUL CREATION LEAKS ITS PREDECESSOR. SAID OUT LOUD ═══
    --
    -- RUNTIME TEXTURES CANNOT BE DESTROYED. There is no counterpart to
    -- CREATE_RUNTIME_TEXTURE, so the texture a previous br_core start made stays
    -- resident for the life of the client with nothing pointing at it. That is
    -- precisely why the name is taken and precisely why this counter exists -- the
    -- leak is the mechanism, not a side effect of it.
    --
    -- WHAT IT COSTS IS 8 KiB A RESTART: 8 x 256 pixels at 4 bytes is 8192 bytes
    -- exactly. That is what makes a counter affordable where a one-shot retry was
    -- protecting nothing worth protecting. A FAILED attempt is cheaper still -- it
    -- leaks only an empty TXD wrapper, because the refusal happens before any texture
    -- is allocated -- so re-probing a dozen taken names costs nothing measurable.
    --
    -- ═══ BOUNDED, SO A BROKEN CLIENT STILL REACHES THE FALLBACK ═══
    --
    -- The loop must not be "keep trying until one works": a client whose
    -- runtime-texture support is genuinely broken refuses EVERY name, and an unbounded
    -- probe would spin instead of banding. `nameTries` is the bound and it is a config
    -- value so the number is visible. At 32 the arithmetic is 256 KiB of leaked
    -- texture before the fallback, which is far more restarts than a playtest does and
    -- still well clear of the client's own runtime-texture ceiling.
    local tries = math.max(1, math.floor(fc.nameTries or 32))
    local tex, txdName, texName
    local used = 0
    for i = 1, tries do
        used = i
        tex, txdName, texName = attempt(i == 1 and '' or ('_' .. i))
        if tex then break end
    end
    if not tex then
        return false, ('CreateRuntimeTexture returned nothing under %d names')
            :format(tries)
    end
    ramp.tries = used

    -- ═══ THE GATE IS A READ-BACK, NOT A HANDLE ═══
    --
    -- HasStreamedTextureDictLoaded -- what this file used to ask -- is the wrong
    -- question for a slot with no backing .ytd and would answer no forever. A truthy
    -- handle is necessary and not sufficient: it says the call returned something,
    -- not that a surface exists behind it. GET_RUNTIME_TEXTURE_WIDTH agreeing with
    -- the width we asked for is the cheapest statement available that the texture is
    -- really there. (Read out of citizenfx/fivem ext/native-decls/
    -- GetRuntimeTextureWidth.md: `int GET_RUNTIME_TEXTURE_WIDTH(long tex)`, "Gets the
    -- width of the specified runtime texture.")
    -- AND IF THE READ-BACK ITSELF IS MISSING the gate degrades to the handle alone,
    -- which is weaker -- so it is RECORDED rather than quietly accepted. The console
    -- line says which gate ran, because "the wall is there" and "the wall is probably
    -- there" are different claims and only one of them was checked.
    if type(_G.GetRuntimeTextureWidth) == 'function' then
        local got = GetRuntimeTextureWidth(tex)
        if got ~= w then
            return false, ('the ramp texture read back %s px wide, not %d')
                :format(tostring(got), w)
        end
        ramp.verified = true
    else
        ramp.verified = false
    end

    -- ROWS ARE THE RAMP. Every column is identical -- the width exists only so the
    -- u axis is not degenerate -- so this is h distinct values written w times.
    for y = 0, h - 1 do
        local t = y / (h - 1)
        local v = math.floor(rampAlpha(fc, zb, zt, zb + (zt - zb) * t) * 255.0 + 0.5)
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        for x = 0, w - 1 do
            SetRuntimeTexturePixel(tex, x, y, v, v, v, v)
        end
    end
    -- NOTHING IS ON THE GPU UNTIL THIS LINE. SET_RUNTIME_TEXTURE_PIXEL writes a CPU
    -- backing buffer and the decl says so outright: the change "requires
    -- finalization through COMMIT_RUNTIME_TEXTURE to take effect".
    CommitRuntimeTexture(tex)

    -- ═══ THE HALF-TEXEL INSET, AND WHY IT LIVES HERE RATHER THAN IN THE DRAW (#341)
    --     ═══
    --
    --   "Wall is correct hue, smooth but there is a very tiny line at the top of it.
    --    the gradient looks great though."          -- the owner, 2026-09-22, #341
    --
    -- THE QUAD USED TO MAP ITS TOP EDGE TO v = EXACTLY 1.0, which is the boundary of
    -- the texture rather than the centre of its last row. A bilinear sample at v = 1.0
    -- lands halfway between row h-1 and the row AFTER it -- and if the sampler's
    -- address mode is REPEAT rather than CLAMP_TO_EDGE, the row after row 255 is row
    -- 0, the fully opaque bottom of the ramp. MEASURED THROUGH THIS BAKE at the
    -- shipping 8x256: row 255 holds alpha 0 and row 254 holds 1, so the ramp itself
    -- reaches nothing at the top -- but a wrapping sampler reads 127 at v = 1.0 and
    -- falls back to 0 by v = 255.5/256, which over a span of 1000 m is a 1.95 m band
    -- at the very top of the wall rising to HALF the base opacity. A very tiny line at
    -- the top of it.
    --
    -- SO v RUNS CENTRE-TO-CENTRE: 0.5/h to (h-0.5)/h. Those two coordinates are the
    -- exact centres of row 0 and row h-1, so the bottom samples baseAlpha and the top
    -- samples topAlpha with no filtering across a wrap boundary under EITHER address
    -- mode. That is what makes this the right fix without knowing which mode the
    -- native's sampler uses -- a fact no Lua in this estate can read, and the one
    -- thing about #341 only a playtest can confirm.
    --
    -- ═══ WHAT THE GAME'S OWN CALL SITE SAYS, AND WHY IT IS NOT A COUNTER-EXAMPLE ═══
    --
    -- DRAW_SPRITE_POLY exists for Deadline's trailing lights, and the decompiled
    -- fm_mission_controller emits it with v 0f and 1f against "Deadline_Trail_01" -- the
    -- full range, boundary included, exactly what this wall used to do. That is worth
    -- writing down because it looks at first like proof the sampler clamps.
    --
    -- IT IS NOT, AND THE DIFFERENCE IS WHAT THE TEXTURE HOLDS AT ITS EDGES. A trail
    -- glow is transparent along BOTH of its long edges, so a wrap there blends nothing
    -- into nothing and is invisible whichever mode is in force. Our ramp is deliberately
    -- OPAQUE at one edge and clear at the other -- that asymmetry is the fade -- which
    -- is precisely the texture shape that makes a wrap show. So the game's call site is
    -- evidence that v = 1.0 is ORDINARY, not that it is safe for this texture.
    --
    -- THE BOTTOM IS INSET TOO, SYMMETRICALLY, AND IT NEVER SHOWED -- for two reasons
    -- worth writing down rather than one. Row 0 is already opaque, so wrapping onto
    -- row 255 there DARKENS the edge by half instead of brightening it; and the wall's
    -- bottom half-texel is z -150.0 to -148.05, a hundred and fifty metres
    -- underground, where the skirt exists precisely so that nobody can look at it.
    -- Either alone would have hidden it. It is inset anyway: the asymmetry would
    -- otherwise be a thing the next reader has to rediscover, and rampBaseZ is exactly
    -- the config knob that could one day raise that edge into daylight.
    --
    -- WHAT IT COSTS THE RAMP is half a row of resolution at each end -- the v-to-z
    -- mapping is compressed by 1/256 of the span, 3.9 m over 1000 -- and the endpoints
    -- still land on baseAlpha and topAlpha exactly, which is the property that matters.
    ramp.v0, ramp.v1 = 0.5 / h, (h - 0.5) / h

    ramp.tex, ramp.txd, ramp.name = tex, txdName, texName
    return true
end

--- Announce the fade path ONCE, naming the rung and what it costs.
---
--- ONCE PER RESOURCE START, NOT PER FRAME. This is the owner's only way to know
--- the wall fell back -- "give me a way to know whether it fellback", 2026-09-22 --
--- and a line per frame at 60 Hz would bury the console it is meant to inform.
--- The latch is what makes it one line; BR.Storm.fadePath is what makes it
--- available afterwards, which is what /brwallstyle reads.
local function sayFade(bands, quadPolys)
    if fade.said then return end
    fade.said = true
    BR.Storm = BR.Storm or {}
    BR.Storm.fadePath = fade.path
    BR.Storm.fadeRung = fade.rung
    if fade.path == 'gradient' then
        print(('[br_core] storm wall fade: gradient, %s, %d polys per quad')
            :format(fade.rung, quadPolys))
    else
        print(('[br_core] storm wall fade: banded, %s, %d bands, %d polys per quad')
            :format(fade.rung, bands, quadPolys))
    end
end

--- Pick a fade path, at most once per resource start.
---
--- SETTLED ON THE FIRST FRAME AND NEVER RE-ASKED. There is nothing to wait for any
--- more: the ramp is built in memory rather than requested from the streamer, so it
--- either exists by the end of this call or it never will. The old version polled
--- RequestStreamedTextureDict for 300 frames because a streamed dictionary arrives
--- late; a runtime texture does not arrive at all, it is made.
---
--- EVERY RUNG NAMES ITSELF, because "give me a way to know whether it fellback" is a
--- standing requirement and a fallback whose reason is unknown is barely better than
--- a silent one.
--- @param fc table   cfg.render.strip.fade
--- @param zb number  the geometry's bottom
--- @param zt number  the geometry's top
local function resolveFade(fc, zb, zt)
    if fade.path then return end

    if (fc.prefer or 'gradient') ~= 'gradient' then
        fade.path, fade.rung = 'bands', 'config prefers bands'
        return
    end
    if not spritePolyExists() then
        fade.path, fade.rung = 'bands', 'DrawSpritePoly is not in this build'
        return
    end

    local built, why = buildRamp(fc, zb, zt)
    if not built then
        fade.path, fade.rung = 'bands', why or 'the runtime ramp could not be built'
        return
    end

    fade.path = 'gradient'
    -- THE ATTEMPT NUMBER IS IN THE LINE, and it is the one number here that says
    -- something about the SESSION rather than about the build: attempt 1 is a fresh
    -- client, attempt 5 means br_core has started five times and four 8 KiB textures
    -- are stranded behind it. That is how a leak gets noticed before it matters.
    fade.rung = ('runtime ramp %s:%s, %dx%d, no streamed asset, %s, attempt %d of %d')
        :format(ramp.txd, ramp.name,
            math.max(1, math.floor(fc.rampW or 8)),
            math.max(2, math.floor(fc.rampH or 256)),
            ramp.verified and 'width read back'
                or 'width read-back native absent, handle trusted',
            ramp.tries or 0, math.max(1, math.floor(fc.nameTries or 32)))
end

--- @param shape table       an inset BR.StormShape
--- @param alphaScale number 0..1
local function drawStrip(shape, alphaScale)
    local rr = cfg.render
    -- EVERY NUMBER BELOW HAS AN `or` DEFAULT AND THIS IS WHY. A config without a
    -- `strip` table is the one shape of failure that would be silent: the FRAME
    -- callback is pcall'd, so indexing nil would lose the whole wall and leave one
    -- line in the console rather than a crash anybody notices.
    local sp = rr.strip or {}
    local col = rr.colour
    local SS = BR.StormShape

    local comps = SS.components(shape)
    local nComp = #comps
    if nComp == 0 then return end

    -- ═══ ROUNDNESS SETS THE STEP, AND THE BUDGET OVERRULES IT ═══
    --
    -- Sag goes as ds^2 / 8r, so the step that keeps a quad within chordM of the arc
    -- it replaces is sqrt(8 * r * chordM). That is priced PER RUN below, off the run
    -- radius StormShape.runs hands out -- see the note at the walk, which carries
    -- the two things this used to get wrong and the metres each one cost.
    local chordM = sp.chordM or 2.0

    -- ═══ THE SPAN IS READ BEFORE THE FADE, BECAUSE THE FADE IS BAKED FROM IT ═══
    --
    -- These two used to be read further down, next to the walk. The ramp texture is
    -- built from the SPAN -- the flat section runs from zb to rampBaseZ and the slope
    -- from there to zt -- so the span has to exist before the path is resolved, not
    -- after. It is latched for the session with the texture, which is correct for a
    -- config read once at boot and would be a live bug the day baseZ or topZ became
    -- something the game changes mid-match. Nothing does that today.
    --
    -- A WALL WITH NO HEIGHT IS NOT A WALL, and the reason to say so here rather than
    -- trust the config is that the fade DIVIDES by the span. A topZ at or under baseZ
    -- would make every alpha a nan, and a nan alpha is an invisible wall with nothing
    -- in the console -- the silent failure this whole file is written against. Drawing
    -- nothing at all is the honest answer to a wall of no height, and refusing BEFORE
    -- the ramp is baked also keeps a nan out of the texture, where it would be latched
    -- for the rest of the session.
    local zb, zt = sp.baseZ or -150.0, sp.topZ or 850.0
    if zt <= zb then return end

    -- ═══ WHICH FADE PATH, AND IT IS SETTLED BEFORE THE BUDGET IS DIVIDED ═══
    --
    -- Because it CHANGES WHAT A QUAD COSTS. A banded quad is `bands` stacked
    -- quads, so it is 2 * bands polys and not 2, and a budget that priced every
    -- quad at two triangles would stop being a poly ceiling the moment the fade
    -- fell back. Dividing by the real cost is what keeps maxPolys meaning polys.
    local fc = sp.fade or {}
    resolveFade(fc, zb, zt)
    -- A GRADIENT QUAD IS ONE BAND, WHICH IS THE POINT OF IT: the ramp lives inside
    -- the texture the two triangles are drawn with, instead of being approximated by
    -- stacking more of them.
    local gradient = fade.path == 'gradient'
    local gDict, gTex = ramp.txd, ramp.name
    -- THE INSET v RANGE COMES OFF THE TEXTURE, NOT OFF THE CONFIG, and it is read
    -- WITHOUT an `or` default on purpose -- unlike every other number in this
    -- function. A default of 0.0/1.0 here would be the #341 defect spelled as a
    -- fallback: silent, invisible in review, and reachable the day buildRamp grows a
    -- path that forgets to set them. `gradient` is only true after buildRamp returned
    -- true, and buildRamp sets these before it does.
    local gV0, gV1 = ramp.v0, ramp.v1
    local bands = gradient and 1 or math.max(1, math.floor(fc.bands or 3))
    local quadPolys = 2 * bands
    sayFade(bands, quadPolys)

    -- THE BUDGET IS DIVIDED BEFORE ROUNDNESS IS CONSULTED, so no shape can talk
    -- its way past it: two loops of a disjoint phase-2 breakout would each like
    -- upwards of seventy quads, and this is what stops the pair costing 380 polys
    -- on a frame. The share is a ceiling, not a target -- a loop that is round
    -- enough with fewer takes fewer.
    --
    -- THE FLOOR OF 3 IS THE ONE PLACE THE CEILING IS NOT ABSOLUTE, said here so
    -- nobody has to work it out: a triangle is the least a closed loop can be, so
    -- past 42 loops the floor wins and the total creeps over maxPolys. union2 makes
    -- one loop or two and nothing else in the game builds a shape, so that is a
    -- note for whoever adds the third constructor rather than a live hole.
    local per = math.max(3,
        math.floor(math.floor((sp.maxPolys or 1024) / quadPolys) / nComp))

    local p = viewpoint()
    local vx, vy = p.x, p.y
    local cr, cg, cb = col.r, col.g, col.b
    local alpha = rr.alpha * alphaScale

    -- ═══ THE RAMP HAS A KINK IN IT, AND ONLY ONE OF THE TWO PATHS DRAWS IT EXACTLY
    --     -- WHICH IS THE WHOLE DIFFERENCE BETWEEN THEM ═══
    --
    -- rampAlpha is the curve: flat at baseAlpha from the wall's bottom up to ground
    -- level, then falling to topAlpha at the top. The GRADIENT has it baked row by
    -- row into the texture, so what it draws is the curve. The BANDS sample it at
    -- each band's own centre and hold that value flat across the band, so what they
    -- draw is a staircase approximation of the same curve -- which is exactly why the
    -- owner saw three steps, and exactly why both paths can be compared.
    --
    -- THE BANDS SAMPLE AT THE CENTRE RATHER THAN AT THE BOTTOM EDGE, deliberately: a
    -- flat band is closest to the curve it replaces when it takes the curve's value
    -- halfway along, and sampling the bottom edge instead would leave the TOP band at
    -- a non-zero alpha and give the wall a hard cut-off line at 850 m where there is
    -- currently nothing to see. Centre sampling is not what made the base too faint;
    -- the ramp starting 150 m underground was, and rampAlpha is where that is fixed.
    local function alphaAtZ(z)
        local v = math.floor(alpha * rampAlpha(fc, zb, zt, z) + 0.5)
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        return v
    end

    --- One quad of the strip, from (ax, ay) to (bx, by), bottom z to top z.
    ---
    --- The outward winding is (A_bot, B_bot, A_top) and (B_bot, B_top, A_top):
    --- take the first triangle's edges as (B_bot - A_bot) and (A_top - A_bot) and
    --- their cross product is (t.y, -t.x, 0) times the height, which is the right
    --- of travel and therefore outward. The inward face is each of those two
    --- triangles wound in reverse, which negates the cross product and nothing
    --- else -- the geometry is the same surface either way, and only which side
    --- of it exists changes.
    ---
    --- ═══ THE BANDS STACK INSIDE ONE QUAD, SO THE WINDING TEST IS STILL ONE
    ---     DOT PRODUCT ═══
    ---
    --- Every band of a quad is the same vertical plane with the same tangent, so
    --- the face the viewer is shown is decided once for the quad and not once per
    --- band. That matters beyond tidiness: a per-band test could in principle
    --- disagree between bands of one quad and show the viewer a wall with holes in
    --- it, and there is no geometry in which that would be right.
    ---
    --- THE SHARED HORIZONTAL EDGES ARE THE SAME NUMBERS, for the same reason the
    --- vertical ones are: band i's top z is band i+1's bottom z, carried in a
    --- variable rather than recomputed from i.
    --- The gradient spelling of one quad: two triangles, ONE alpha, and the ramp in
    --- the texture.
    ---
    --- ═══ THE ARGUMENT LIST IS THE ONE dui.lua HAS BEEN SHIPPING SINCE #236 ═══
    ---
    --- 25 arguments: nine position floats, then ONE (r, g, b, a) for the whole
    --- triangle, then the dictionary and texture, then nine UVW floats. Copied off
    --- the four working call sites at dui.lua:410 and :1131 rather than off a
    --- reference, which is the point of using this native instead of the per-vertex
    --- one -- the spelling is not a guess here.
    ---
    --- THE RGB ARE PLAIN 0-255 INTS, exactly as DRAW_POLY takes them, so the colour
    --- needs no conversion and gets none.
    ---
    --- ═══ THE UVs, AND EVERY ONE OF THE THREE IS A DECISION ═══
    ---
    ---   * `w = 1.0`, not 0.0. Every proven call in dui.lua passes 1.0 per vertex.
    ---     The earlier dormant version of this function passed 0.0, which was read
    ---     off a reference saying the component is ignored -- but "ignored" is a
    ---     claim about a native nothing in this tree had ever successfully called,
    ---     and the working call sites are better evidence than the claim.
    ---   * `u = 0.5` at every vertex, so every sample lands in the middle of eight
    ---     identical columns. The u axis carries no information at all; giving it a
    ---     constant in the interior means no clamp rule, wrap rule or bilinear edge
    ---     case can reach the result.
    ---   * `v` spans the wall's BOTTOM to its top, and v = 0 is the texture's first
    ---     row -- so row 0 holds the base alpha. buildRamp's header has the convention
    ---     and where in this tree it is already relied on. It runs gV0 to gV1 -- the
    ---     CENTRES of the first and last rows -- rather than 0.0 to 1.0, and that half
    ---     texel is #341: the bright hairline the owner saw along the top edge is a
    ---     sampler reading across the wrap boundary at v = 1.0. buildRamp's tail has
    ---     the measurement and what each address mode does with it.
    local function gradientQuad(ax, ay, bx, by, out, av)
        if out then
            DrawSpritePoly(ax, ay, zb, bx, by, zb, ax, ay, zt,
                cr, cg, cb, av, gDict, gTex,
                0.5, gV0, 1.0,  0.5, gV0, 1.0,  0.5, gV1, 1.0)
            DrawSpritePoly(bx, by, zb, bx, by, zt, ax, ay, zt,
                cr, cg, cb, av, gDict, gTex,
                0.5, gV0, 1.0,  0.5, gV1, 1.0,  0.5, gV1, 1.0)
        else
            DrawSpritePoly(ax, ay, zt, bx, by, zb, ax, ay, zb,
                cr, cg, cb, av, gDict, gTex,
                0.5, gV1, 1.0,  0.5, gV0, 1.0,  0.5, gV0, 1.0)
            DrawSpritePoly(ax, ay, zt, bx, by, zt, bx, by, zb,
                cr, cg, cb, av, gDict, gTex,
                0.5, gV1, 1.0,  0.5, gV1, 1.0,  0.5, gV0, 1.0)
        end
    end

    local function quad(ax, ay, bx, by)
        local nx, ny = by - ay, -(bx - ax)
        local out = (vx - (ax + bx) * 0.5) * nx
            + (vy - (ay + by) * 0.5) * ny >= 0.0
        if gradient then
            -- THE SINGLE ALPHA IS render.alpha TIMES THE PHASE CLOCK AND NOTHING
            -- ELSE. The ramp is already in the texture, so multiplying it in here as
            -- well would square it -- a wall that fades to nothing by about 300 m.
            gradientQuad(ax, ay, bx, by, out,
                math.max(0, math.min(255, math.floor(alpha + 0.5))))
            return
        end
        local h = (zt - zb) / bands
        local z0 = zb
        for i = 1, bands do
            -- THE LAST BAND TAKES zt ITSELF rather than `zb + i * h`, so the top of
            -- the wall is exactly the config's top and not a rounding of it -- the
            -- same reason the closing quad of a loop reuses the stored first point.
            local z1 = (i == bands) and zt or (z0 + h)
            local av = alphaAtZ((z0 + z1) * 0.5)
            if out then
                DrawPoly(ax, ay, z0, bx, by, z0, ax, ay, z1, cr, cg, cb, av)
                DrawPoly(bx, by, z0, bx, by, z1, ax, ay, z1, cr, cg, cb, av)
            else
                DrawPoly(ax, ay, z1, bx, by, z0, ax, ay, z0, cr, cg, cb, av)
                DrawPoly(ax, ay, z1, bx, by, z1, bx, by, z0, cr, cg, cb, av)
            end
            z0 = z1
        end
    end

    -- ═══ ONE CLOSED STRIP PER COMPONENT, AND NEVER A QUAD BETWEEN THEM ═══
    --
    -- A disjoint union is TWO closed loops, and a strip that walked the shape's
    -- own arc length straight through the seam would bridge them with a single
    -- kilometre-long quad across the unsafe gap -- a wall where there is no
    -- boundary, and the most confident possible lie about where it is safe to
    -- stand. The component walk from #328's window fix is what prevents it, used
    -- here for the same reason one level up: pointAtComponent wraps inside ONE
    -- loop, so the closing quad of each strip lands on its own first point.
    --
    -- AND THERE IS NO WINDOW. The whole boundary is drawn on every frame, at every
    -- phase, for every shape, because roundness rather than column width sets the
    -- count -- so nothing here asks where the viewer is standing except the one
    -- dot product that picks a face. The wall that stops in mid-air, the colonnade
    -- that rides the camera and the curtain hung off a spectator's corpse are all
    -- the same bug, and this is the first renderer that cannot have it.
    for ci = 1, nComp do
        local c = comps[ci]
        -- ═══ THE WALK STEPS THE RUNS, NOT THE COMPONENT, AND A VENN WAIST IS WHY
        --     (the defect this replaced put the curtain OUTSIDE the wall) ═══
        --
        -- The step is priced off CURVATURE -- sag is ds^2 / 8r -- and that rule is
        -- blind to precisely one thing: a CORNER, where the curvature is infinite
        -- and no step satisfies the bound. A Venn union is ONE component made of
        -- two arcs meeting at two reflex crossings, `c.len` is not a multiple of
        -- the step, so stepping the component at uniform arc length
        -- put one quad astride each crossing and bridged it with a straight chord
        -- across the notch. THE NOTCH CUTS INWARD, SO THAT CHORD LANDED OUTSIDE
        -- THE SHAPE -- the curtain drawn beyond the boundary that damages.
        --
        -- MEASURED THROUGH THIS RENDERER, as signed distance from the UNINSET
        -- damaging boundary, worst case over the reachable separation range for
        -- each shipping phase pair. -6.00 m is the correct answer everywhere: the
        -- curtain sitting exactly render.edgeInset inside the logical edge.
        --
        --     2600 + 1600   stepping the component +33.11 m   stepping runs -6.00 m
        --     1600 +  950                          +23.71 m                 -6.00 m
        --      950 +  520                          +15.84 m                 -6.00 m
        --      520 +  260                           +9.35 m                 -6.00 m
        --      260 +  110                           +3.66 m                 -6.00 m
        --
        -- 57 of 235 sampled reachable Venn geometries put the curtain outside the
        -- server's ten-metre damage cushion and none of them do now, so on the
        -- owner's "barely
        -- overlapping, like a venn diagram" -- the exact geometry #328 exists for
        -- -- a wedge up to 33 metres deep at each waist was being billed dps while
        -- drawn well inside the purple curtain. That is the live "20ft inside"
        -- report edgeInset exists for, INVERTED and about five times larger.
        --
        -- CIRCLES AND DISJOINT PAIRS NEVER HAD IT, which is why nothing caught it:
        -- a circle's component is one piece, and a disjoint pair's two components
        -- are a whole circle each, so neither has an interior boundary to step
        -- over. Only one of the two Venn crossings showed, too, and the other
        -- escaped by accident -- union2 opens the component AT the left crossing,
        -- so arc length 0 already lands on it.
        --
        -- AND IT COST NOTHING. With one step and a split by length, the five cases
        -- above closed at 127, 102, 82, 60 and 45 quads before and after -- identical
        -- counts, identical budget, a wall inside the boundary. #344 then replaced
        -- that split as well; the block below is why, and what it costs is fewer
        -- quads rather than more.
        local runs = SS.runs(shape, ci)
        local nRuns = math.max(1, #runs)

        -- ═══ AND EACH RUN IS PRICED OFF ITS OWN CURVATURE, WHICH IS THE OTHER HALF
        --     OF #339's FIRST LANDMINE ═══
        --
        -- There used to be ONE step for the whole component, priced off
        -- `shape.discs`, and the budget was then split between the runs BY LENGTH.
        -- Both halves of that were wrong the moment the storm stopped being round:
        --
        --   * a shape with no disc list left the step at infinity, so every loop
        --     fell back to the minSeg floor of 24 quads and sagged tens of metres
        --     inside the boundary that damages;
        --   * and splitting by length starves exactly the runs that need the points.
        --     A blob is nine short, sharply curved corner arcs joined by nine long
        --     flat runs. A straight run needs ONE quad however long it is -- a chord
        --     of a straight line cuts nothing off it -- and by length it was taking
        --     three fifths of the budget. MEASURED: a phase-5 zone, r 260 with a 98 m
        --     corner radius, drew 4.99 m of sag against a chordM of 2.0, because each
        --     corner got one quad where the sag rule wanted two.
        --
        -- So `want` is what each run actually asks for, and it is a CEILING taken
        -- per run rather than once at the end: a run that asks for 2.4 quads and is
        -- handed 2 sags 44 percent over the bound, which is precisely the failure
        -- above spelled in rounding. Summed, that total is the component's own count
        -- -- so n is derived from roundness instead of from the perimeter, and the
        -- split below then hands each run back exactly what it asked for.
        local want, total = {}, 0
        for i = 1, nRuns do
            local rn = runs[i]
            local k = 1
            if rn and rn.r and rn.r > 0.0 then
                k = math.max(1, math.ceil(rn.len / math.sqrt(8.0 * rn.r * chordM)))
            end
            want[i] = k
            total = total + k
        end

        local n = math.max(nRuns, math.max(3,
            math.min(per, math.max(sp.minSeg or 24, total))))

        -- WHERE EACH RUN ENDS, AS A POINT INDEX, and it is CUMULATIVE rather than
        -- a share handed to each run separately. Rounding each run's own share
        -- independently does not have to sum to n -- so the budget above, which is
        -- a hard ceiling, would be decided by rounding. Rounding the running total
        -- instead and then clamping it monotone (at least one quad per run, and
        -- enough left for the runs after it) makes the total exactly n by
        -- construction.
        --
        -- WEIGHTED BY `want`, NOT BY LENGTH, which is what makes the paragraph above
        -- true: when n equals the sum of `want` every cumulative total is already an
        -- integer, so each run is handed back precisely the count it asked for. The
        -- minSeg floor spreads the surplus proportionally and the poly budget takes
        -- its share back the same way.
        local edge = { [0] = 0 }
        local cum = 0
        for i = 1, nRuns do
            cum = cum + want[i]
            local k = math.floor(n * cum / total + 0.5)
            local lo, hi = edge[i - 1] + 1, n - (nRuns - i)
            if k < lo then k = lo end
            if k > hi then k = hi end
            edge[i] = k
        end

        local fx, fy = SS.pointAtComponent(shape, c, 0.0)
        local ax, ay = fx, fy
        for i = 1, nRuns do
            local t0 = runs[i] and runs[i].t0 or 0.0
            local rlen = runs[i] and runs[i].len or c.len
            local cnt = edge[i] - edge[i - 1]
            for j = 1, cnt do
                local bx, by
                if i == nRuns and j == cnt then
                    -- THE CLOSING QUAD TAKES THE STORED FIRST POINT. `n * cds` is
                    -- not always `c.len` in doubles, and pointAtComponent's wrap
                    -- then lands a hair before or after the start rather than on
                    -- it: measured, 11 percent of whole-metre radii between 20 and
                    -- 2600, worst 3.5e-12 metres. That is picometres and invisible
                    -- -- the reason to reuse the point is that the shared edge is
                    -- then the same numbers by construction instead of two
                    -- expressions that happen to agree. See the header.
                    bx, by = fx, fy
                else
                    -- AT j == cnt THIS IS THE RUN BOUNDARY ITSELF, which is the
                    -- whole point: `t0 + rlen` is the arc length of the crossing,
                    -- and pieceAtArc answers it as the NEXT piece at t = 0. The
                    -- two pieces' reconstructions of that one point differ by
                    -- 4.9e-13 metres (see the header), so which of them answers is
                    -- not a visible decision -- but it is a deterministic one, and
                    -- the vertex is ON the corner either way rather than past it.
                    bx, by = SS.pointAtComponent(shape, c, t0 + rlen * j / cnt)
                end
                quad(ax, ay, bx, by)
                ax, ay = bx, by
            end
        end
    end
end

--- Draw a curtain on the boundary of `zone`, at `alphaScale` of full strength.
---
--- ═══ ONE WALL RENDERER, AND #327 IS WHY IT IS A FUNCTION NOW ═══
---
--- This was the body of the storm.wall callback. It became a function the day the
--- game had a SECOND thing to draw a wall on: circle 1, previewed during the bus
--- ride before any storm exists (owner, 2026-09-21 -- "show the marker (or arc now
--- as it may be) starting from when the San Andreas map is loaded"). A preview wall
--- is this renderer handed a circle and a lower alpha, and
--- writing a second one would have meant two files' worth of the things this one
--- already knows: that the curtain sits edgeInset metres inside the logical edge,
--- that a cylinder cannot draw a union, that a strip's edges are shared and not
--- recomputed, that a walk of a boundary is arc length and not angle, that a
--- window must stay on one component, and that the whole thing must be glued to
--- the world rather than to the viewer.
---
--- IT TAKES THE ZONE UNINSET AND INSETS IT ITSELF, so no caller can forget to --
--- which is the live report edgeInset exists for ("20ft inside" while the HUD
--- correctly said outside).
---
--- NOTHING HERE READS THE RECORD, THE CLOCK OR THE MATCH STATE. Every one of those
--- is the caller's business, and that is what makes the same pixels available to a
--- preview that has no record and no clock at all.
--- @param zone table        a BR.StormShape
--- @param alphaScale number 0..1
local function drawWall(zone, alphaScale)
    -- FIXED SLOTS AROUND THE CIRCLE, ALWAYS DRAWN. Both lessons below were learnt
    -- on the marker paths and are kept BECAUSE the marker paths are still the A/B
    -- baseline; the strip inherits both by construction and the second outright,
    -- since it draws the whole boundary on every frame.
    --
    -- Two lessons from the first live walls, both about the same illusion:
    -- the wall must behave like a THING IN THE WORLD, not an effect around
    -- the player.
    --
    --   * Columns stand on fixed slots of BOUNDARY, one per slotArc metres of
    --     arc length, derived from the zone alone. The old arc was centred on
    --     the player's own bearing, so every step the player took slid the
    --     whole colonnade around the circumference with them -- "really
    --     jarring" was the polite version.
    --   * No proximity gate. The old |dist - r| cut-off made a 300m-tall
    --     curtain pop out of existence past 300m, which read as a render
    --     bug (and got blamed on OneSync -- it never was; markers are pure
    --     local draw calls). The wall is always drawn; what scales is how
    --     much of the ring gets columns: enough arc to span the view from
    --     wherever the player is, the full ring once the circle is small.
    local rr = cfg.render
    local col = rr.colour

    local SS = BR.StormShape

    -- ═══ edgeInset, WHICH THE COLUMN PATH NEVER PAID ═══
    --
    -- It placed its columns at exactly r, so the logical edge -- the one that
    -- damages -- sat inside the visible curtain. That is the live report
    -- edgeInset exists for ("20ft inside" while the HUD correctly said outside),
    -- and it would have come straight back the first time anybody typed
    -- /brwallstyle. The shipping path has inset since the day the report landed;
    -- this is that same one line, spelled for a shape.
    local shape = SS.inset(zone, rr.edgeInset or 0.0)

    -- ═══ THE STRIP IS THE WALL, AND THE TWO MARKER PATHS ARE THE BASELINE ═══
    --
    -- The renderer used to be a property of the shape, because each of the two
    -- marker paths was right for a different one: 'solid' is seamless and can only
    -- draw a circle, 'columns' draws any shape and stripes. The strip has neither
    -- limit -- it walks the same boundary the columns do and it is one continuous
    -- surface while doing it -- so there is nothing left for the shape to choose
    -- between. It is the default for every shape, which is every shape it can
    -- draw.
    --
    -- BOTH MARKER PATHS STAY REACHABLE, and 'solid' is the one that matters: it is
    -- the only other seamless wall in the game and therefore the A/B baseline the
    -- strip has to be judged against on real hardware. 'columns' stays because it
    -- is the striping itself, and being able to put the fence back beside the
    -- surface in one command is how the comparison gets settled without a deploy.
    --
    -- NO CALLER MAY STATE A PREFERENCE ANY MORE, and the parameter that let one is
    -- gone rather than left unused. Exactly one ever did: the #327 preview asked for
    -- the cylinder because it is looked at from the bus, which cruises at 500 and
    -- climbs to 892 over the Chiliad massif (config/map.lua), and the strip's top
    -- was a config 400 set for a player standing on the ground -- the whole wall
    -- underneath the flight. The owner has since refused markers for the preview
    -- too ("don't use a marker for the bus preview either", 2026-09-22), and the
    -- answer was to raise the strip to the marker's own 850 and fade its top out.
    -- So /brwallstyle is now the ONLY thing in the game that can ask for a marker,
    -- which is what the A/B needed it to be all along.
    local style = BR.Storm.wallStyle
    if style ~= 'solid' and style ~= 'columns' and style ~= 'strip' then
        style = 'strip'
    end

    if style == 'strip' then
        drawStrip(shape, alphaScale)
        return
    end

    if style == 'solid' then
        -- ONE marker: the entire zone as a single giant vertical cylinder.
        -- Its side surface IS the wall -- continuous, identical from every
        -- angle and distance, no columns to count or watch slide.
        --
        -- IT DRAWS ONE DISC, AND THAT IS WHY IT IS NOT THE DEFAULT ON A UNION.
        -- A DrawMarker type 1 is a cylinder, so this path is a circle by
        -- construction: forced onto a shape with two discs it paints the first
        -- one and says nothing about the second, which on a phase that broke out
        -- means a curtain straight through a player standing safely in the next
        -- circle. Nothing reaches this path by default any more -- the strip is the
        -- wall and the #327 preview asks for the cylinder by name on a shape that
        -- is always one disc -- so the only way to see that lie is to type
        -- /brwallstyle, which is deliberate: it is exactly the known ground the
        -- A/B is measured against.
        --
        -- IT READS THE SHAPE RATHER THAN r, which is what lets the shape choose.
        -- The shape is already inset (StormShape.inset rebuilt it at r - edgeInset,
        -- floored at one metre) so this is byte-for-byte the
        -- `math.max(1.0, r - edgeInset)` it replaces on every ordinary phase --
        -- and on the admin path where `brphase 1` targets a circle bigger than
        -- the collapsed one it is in, the zone constructor returns the TARGET and
        -- this now draws the wall that actually exists instead of a one-metre stub.
        --
        -- ASKED FOR, NOT INDEXED -- #339's SECOND LANDMINE. This line was
        -- `discs[1]`, which is a nil index on any shape with no disc list: one
        -- console command on any phase of any match, from the moment the storm
        -- stopped being round. StormShape.discFor names the disc per kind, which
        -- for a blob is the circle it replaced -- exactly the cylinder this path
        -- drew before #344 and therefore exactly the A/B baseline it exists to be.
        --
        -- GLUED TO THE WORLD, NOT THE PED: a fixed base below sea level and
        -- triple height (user call, 2026-08-03), spanning ocean floor to
        -- above Chiliad. The old ground-probe fallback hung the curtain off
        -- the viewer's own z whenever the probe missed -- which at wall
        -- distances is most of the time -- so the wall rode the camera.
        local disc = SS.discFor(shape)
        DrawMarker(1,
            disc.x, disc.y, -100.0,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            disc.r * 2.0, disc.r * 2.0, rr.height * 3.0 + 50.0,
            col.r, col.g, col.b, math.floor(rr.alpha * alphaScale),
            false, false, 2, false, nil, nil, false)
        return
    end

    -- ═══ A WALK ALONG A BOUNDARY, IN METRES, NOT A LOOP AROUND A CIRCLE ═══
    --
    -- Every number below was ALREADY arc length: `slots` was the circumference
    -- over slotArc, the column width was `r * step`, and visArc and want were
    -- metres. What they were not is SPELLED that way, so every line of the walk
    -- knew the boundary was a circle. Asking br_lib/shared/storm_shape.lua the
    -- same three questions -- how long is the boundary, where is it at s metres,
    -- and where along it is the viewer -- leaves the arithmetic identical and
    -- stops it depending on the shape:
    --
    --   step = (2*pi) / slots      becomes   ds = P / slots, metres per slot
    --   w = (r * step) * overlap   collapses to   w = ds * overlap
    --
    -- and the second line is the one worth noticing: the column width stops
    -- mentioning the radius at all. A slot is a slot of BOUNDARY, whatever the
    -- boundary happens to be doing there.
    --
    -- ═══ AND THE SHAPE IS A UNION NOW, WHICH IS WHY THIS PATH SHIPS (#328) ═══
    --
    -- It used to be a circle built from the live record every frame, with a note
    -- saying nothing in the game could ask the storm for anything else. Something
    -- can: the safe zone is the current circle PLUS the one the wall is closing
    -- toward, so that a player who gets to the new destination early is safe
    -- there (owner, 2026-09-21). The walk below does not change by a character
    -- for it -- it asks how long the boundary is, where it is at s metres, and
    -- where along it the viewer is standing, and a two-arc union answers all
    -- three exactly as one arc did.
    --
    -- ON AN ORDINARY PHASE IT DRAWS THE IDENTICAL CIRCLE. The next circle is
    -- normally nested inside the current one, and union2's first case returns
    -- the containing circle itself, so every marker lands where it landed
    -- before. The wall only changes shape on a phase that broke out, which is
    -- the phase where the old wall was lying.
    local P = SS.perimeter(shape)
    local slots = math.max(rr.segments, math.floor(P / rr.slotArc + 0.5))
    local ds = P / slots

    -- ═══ A SLOT GRID PER COMPONENT, BECAUSE A WINDOW MUST STAY ON ONE ISLAND ═══
    --
    -- A disjoint union is TWO closed loops. `first` runs negative and the walk
    -- used to wrap modulo the whole perimeter, which is honest for one loop --
    -- a circle, or the Venn case where arc 1 ends exactly where arc 2 begins --
    -- and a lie for two: arc length 0 is on the current circle and arc length P1
    -- is on the next one, kilometres away.
    --
    -- MEASURED, phase-4 geometry, current r520 at the origin, next r260 at
    -- (1040, 0), viewer at (560, 0): 48 markers drawn, 24 on the near circle
    -- covering bearings 2 to 79 degrees ONLY, and 24 dumped on the far circle
    -- behind the player, with no curtain at all immediately clockwise of them.
    -- Swept round the near circle in 5 degree steps, 32 of 72 viewer bearings
    -- showed a broken colonnade at phase 4 and 17 of 72 at phase 3. The nested
    -- and Venn cases measured 0 of 72, which is why the suite was green: they are
    -- single loops, and until tools/test_storm.lua's `wall.window` block they were
    -- the only shapes anything drove through this branch at all.
    --
    -- So a component gets its own slot count and its own metres per slot, both
    -- derived from the shape's own ds. Single-component shapes -- every nested
    -- phase, every Venn -- come out at exactly `slots` and `ds`, marker for
    -- marker, which is what makes this not a change to the shipping wall.
    local comps = SS.components(shape)

    --- Slots on one component, and the metres each one covers.
    local function slotsIn(c)
        local n = math.max(1, math.floor(c.len / ds + 0.5))
        return n, c.len / n
    end

    --- `n` columns from slot `first` of component `c`.
    ---
    --- ═══ GLUED TO THE WORLD, NOT TO THE VIEWER, AS THE SHIPPING PATH IS ═══
    ---
    --- These columns used to stand on a ground probe: GetGroundZFor_3dCoord under
    --- the single point of the circle nearest the viewer, cached for a second,
    --- falling back to the viewer's own z minus fallbackZDrop when it missed. Two
    --- more reads of "where is the viewer" for a wall that must look the same on
    --- every screen -- and the probe returns garbage for unloaded cells, which at
    --- wall distances is most of the time, so the fallback is what actually ran
    --- and the wall rode the camera. 'solid' settled this on 2026-08-03 with a
    --- fixed base below sea level and triple height, ocean floor to above
    --- Chiliad. Taking those same two numbers is what lets the probe, its cache
    --- and a second viewpoint() read all go away.
    ---
    --- AND alphaScale, THE OTHER DEBT THIS PATH NEVER PAID: it passed rr.alpha
    --- raw, so the phase-1 fade-in clock did nothing here. The map ring would
    --- fade in over the hold's last ten seconds while the curtain popped into
    --- existence beside it at full strength.
    ---
    --- `first + i` still runs negative and past the count, exactly as it always
    --- could. It is wrapped MODULO THE COMPONENT'S OWN SLOT COUNT here, so an
    --- off-end slot comes round to the other side of the island it is drawing
    --- rather than jumping to the other island. StormShape.pointAtComponent wraps
    --- the metres the same way, for the same reason and one level down.
    local function columns(c, first, n)
        local cslots, cds = slotsIn(c)
        local w = cds * (rr.overlap or 1.05)
        for i = 0, n - 1 do
            local mx, my = SS.pointAtComponent(shape, c,
                ((first + i) % cslots + 0.5) * cds)
            DrawMarker(1,
                mx, my, -100.0,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                w, w, rr.height * 3.0 + 50.0,
                col.r, col.g, col.b, math.floor(rr.alpha * alphaScale),
                false, false, 2, false, nil, nil, false)
        end
    end

    -- ═══ WHEN THE WHOLE BOUNDARY FITS, DRAW IT AND NEVER ASK WHERE ANYBODY IS ═══
    --
    -- At the shipping phase radii the full-ring slot counts run roughly 545,
    -- 335, 199, 109, 54, 23, 8, so from phase 5 down the entire boundary is
    -- under maxDraw and there is nothing left to choose. Windowing there bought
    -- nothing and cost the thing #225 was filed about: a viewer-relative wall,
    -- which for a spectator means a colonnade hung off their corpse's bearing on
    -- a wall they are looking at from somewhere else entirely. The endgame is
    -- where people actually fight and where that report came from, and it is now
    -- the case with no viewer in it at all.
    --
    -- Above maxDraw a window is still the only affordable answer, and it still
    -- has to know which stretch of boundary the viewer is looking at. Reading
    -- the viewer HERE rather than at the top of the callback keeps it off the
    -- shipping path, which never wanted it, and off the endgame, which no longer
    -- does.
    if slots <= rr.maxDraw then
        -- EVERY COMPONENT, EVERY SLOT. Both islands of a disjoint pair get their
        -- full colonnade here, because nothing is being rationed.
        for i = 1, #comps do
            local n = slotsIn(comps[i])
            columns(comps[i], 0, n)
        end
        return
    end

    local p = viewpoint()
    -- visArc and want carry over verbatim. The one substitution is
    -- (dist - r), which was a circle's signed distance written out by hand.
    local off = SS.distance(shape, p.x, p.y)
    local visArc = math.max(rr.wallVisDist, math.abs(off) * 2.0)
    local want = math.floor((visArc * 2.0) / rr.slotArc + 0.5)
    local drawn = math.min(slots, math.min(rr.maxDraw, math.max(rr.segments, want)))

    -- What replaces `base = math.atan(p.y - cy, p.x - cx)`: the same question,
    -- asked of a boundary instead of of a circle -- and then asked which LOOP the
    -- answer is on, so the whole budget is spent on the edge that is about to
    -- hurt the viewer.
    --
    -- THE FAR ISLAND SIMPLY GETS NO COLUMNS WHILE THE VIEWER IS AT THE NEAR ONE,
    -- and that is honest rather than a compromise: it is kilometres away, it is
    -- not the edge anybody is about to walk into, and it gets its own full window
    -- the moment a viewer is nearest to it. What it must never do is take half the
    -- curtain off the ground the viewer is standing on.
    local s = SS.nearestArc(shape, p.x, p.y)
    local c = SS.componentAt(shape, s)
    local cslots, cds = slotsIn(c)
    drawn = math.min(drawn, cslots)
    columns(c, math.floor((s - c.s0) / cds) - math.floor(drawn / 2), drawn)
end

-- ═══ ONE FADE CLOCK, READ IN BOTH DIRECTIONS (#340) ═══
--
--   "After match goes to playing, before the first storm move, the storm border
--    cannot be seen anywhere. Doesn't seem to draw during this time. The storm circle
--    should draw the entire time from while in bus to when it moves. Make sure it
--    fades in just like before."                   -- the owner, 2026-09-22, #340
--
-- TWO GATES THAT DID NOT MEET. previewCircle stops the instant the match goes PLAYING,
-- and the real wall is deliberately suppressed for all of the phase-1 hold except its
-- last fadeInSec -- so from the bus doors closing until ten seconds before the first
-- shrink there was no curtain anywhere, which is most of the early match. Both gates
-- were right about their own half and neither knew about the other.
--
-- THE FIX IS NOT A SECOND CLOCK. The map ring and the 3D curtain already share this
-- countdown (user call, 2026-08-04), and a preview fading out on a clock of its own
-- would be a third thing to keep in step -- one that could drift out of agreement
-- with the wall the day fadeInSec moved. So this is the ONE number both walls read:
-- how much of the REAL wall is showing. The preview draws one minus it.
--
-- WHICH MAKES THE HANDOFF STRUCTURAL RATHER THAN CAREFUL, and that is the whole
-- reason it is spelled as a share. The preview is at full strength exactly while the
-- real wall is suppressed, thins as the real wall rises, and is gone at the instant
-- the real wall reaches full -- so the two can neither both be absent (the defect)
-- nor both be at full strength (the constraint previewCircle's header states: the
-- preview "must not be on screen during PLAYING beside the real wall it was standing
-- in for"). There is nothing to tune out of agreement, because there is one value.
--
-- A fadeInSec OF ZERO IS ANSWERED HERE TOO, and it used to be a nan. The old spelling
-- tested `msLeft > fadeMs` and then divided by fadeMs, so a zero divided 0 by 0 on the
-- one frame that got through and handed the draw a nan alpha -- an invisible wall with
-- nothing in the console, which is the silent failure this file is written against.
-- Zero now means "no fade window": the wall is suppressed for the whole hold and
-- arrives at full strength with the shrink, and the preview covers the whole hold.
--
-- AND msLeft == fadeMs RETURNS 0 RATHER THAN DRAWING AT 0. The old test was strict, so
-- the boundary frame drew a whole wall's worth of triangles at alpha 0. Identical on
-- screen, one frame of geometry cheaper, and it means "the real wall is showing" and
-- "the preview has started thinning" are the same instant rather than adjacent ones.
--- @param rec table     the storm record
--- @param st string     the phase state solveNow reported
--- @param msLeft number ms until that phase state changes
--- @return number       0..1 of the real wall; 1 minus this is the preview's
local function wallShare(rec, st, msLeft)
    if rec.phase ~= 1 or st ~= BR.StormPhase.HOLDING then return 1.0 end
    local fadeMs = (cfg.render.fadeInSec or 10.0) * 1000.0
    if fadeMs <= 0.0 then return 0.0 end
    if msLeft >= fadeMs then return 0.0 end
    local w = 1.0 - msLeft / fadeMs
    if w < 0.0 then return 0.0 elseif w > 1.0 then return 1.0 end
    return w
end

-- A DEV-ONLY RUNTIME BISECT FOR #350. `normal` is the shipping path; the other
-- values remove exactly one recent client-side storm path while leaving the
-- authoritative server storm, damage and phase clocks untouched. The command
-- which changes it is below the map callback, beside the state it controls.
local stormBisectMode = 'normal'

BR.Loop.register(BR.Loop.FRAME, 'storm.wall', function()
    if stormBisectMode == 'walloff' then return end

    local rec = activeRecord()
    if not rec then return end

    local cx, cy, r, stt, msLeft, _, t = solveNow(rec)
    -- A COLLAPSED ZONE HAS NO WALL TO DRAW, and the zone is two circles now, so
    -- both of them have to be gone. In the shipping case that is the same test
    -- it always was: the final phase closes on a zero-radius target, so r and
    -- rec.r1 reach the floor together and this returns exactly when it used to.
    -- The pair matters on the admin path, where `brphase 1` from a collapsed
    -- wall gives a record whose CURRENT circle is a point and whose target is
    -- 2600m -- one test on r alone would draw no wall at all for that whole
    -- sweep.
    if r <= 1.0 and rec.r1 <= 1.0 then return end

    -- NO WALL BEFORE ANYTHING HAS HAPPENED. During the free-loot hold the
    -- "circle" is the whole map, and a purple ring around the horizon
    -- announced nothing but its own existence. The curtain FADES IN across
    -- the hold's last seconds, at full strength as the shrink begins.
    --
    -- AND WHAT STANDS IN FOR IT UNTIL THEN IS #327'S PREVIEW, held on screen by the
    -- other side of this same number (#340). Suppressing the whole-map ring is still
    -- right -- it told players nothing -- but "suppressed" used to mean "nothing at
    -- all", and the owner was looking at an empty horizon for most of the early match.
    local alphaScale = wallShare(rec, stt, msLeft)
    if alphaScale <= 0.0 then return end

    -- ═══ THE SHAPE COMES FROM THE RECORD'S SEED, NOT FROM THIS FILE (#344) ═══
    --
    -- BR.StormZone is the one spelling of "what shape is the storm right now", and
    -- the server's damage tick makes the identical call off the identical record.
    -- Nothing about the shape is on the wire but the seed, so a second spelling
    -- here would be a wall drawn somewhere the server is not billing -- the "20ft
    -- inside" report with no bound on how far.
    --
    -- AND IT MORPHS HERE, EVERY FRAME, which costs nothing this callback was not
    -- already paying: the zone was rebuilt every frame before it had two shapes.
    -- `t` is the sweep fraction solveNow reported, so the curtain becomes the
    -- target's shape exactly as it arrives on the target's circle, and the next
    -- phase's hold starts from that same shape -- the snap at the end of every
    -- sweep was the two zones sharing one.
    drawWall(BR.StormZone(rec, cx, cy, r, t), alphaScale)
end)

-- Which renderer draws the wall, and /brwallstyle overrides it live.
--
-- ═══ THREE RENDERERS, AND THE STRIP IS THE WALL (#336) ═══
--
-- `nil` is automatic and automatic is 'strip': the boundary as one continuous
-- quad surface. It has neither of the limits that made the other two a choice --
-- it draws every shape the walk produces, and it does not stripe -- so there is
-- nothing left for the shape to decide.
--
--   'strip'    DRAW_POLY quad strip. The wall.
--   'solid'    ONE DrawMarker type 1. Seamless, a circle by construction, and
--              therefore the A/B BASELINE: the only other continuous wall the
--              game has ever drawn, and the one the owner picked on 2026-08-03.
--              Forced onto a union it paints the first disc and lies about the
--              second, which is known ground rather than a second bug.
--   'columns'  the same cylinder walked in slotArc slots. This is the picket
--              fence from the 2026-09-22 report, kept because being able to put
--              the fence back beside the surface in one command is how the
--              comparison actually gets settled.
--
-- FOUR STATES, SO THE CYCLE REACHES ALL THREE AND COMES BACK. With three there
-- would be no way back to automatic once a session had typed the command, and
-- with two the strip would be unreachable by name -- which matters the day
-- automatic changes again.
BR.Storm = BR.Storm or {}
BR.Storm.wallStyle = nil
RegisterCommand('brwallstyle', function()
    local s = BR.Storm.wallStyle
    if s == 'solid' then s = 'columns'
    elseif s == 'columns' then s = 'strip'
    elseif s == 'strip' then s = nil
    else s = 'solid' end
    BR.Storm.wallStyle = s
    print(('[br_core] storm wall style: %s'):format(s or 'auto (strip)'))
    -- AND THE FADE PATH BESIDE IT, because this is the command the owner reaches
    -- for when he is looking at the wall, and "did the gradient fall back" is a
    -- question about the wall. It is reported rather than cycled: the path is
    -- decided once per resource start off config and what the streamer did, and a
    -- command that re-decided it mid-session would make the console line above it a
    -- lie. `nil` means no strip has drawn yet, which on the marker styles it never
    -- will.
    print(('[br_core] storm wall fade: %s'):format(BR.Storm.fadeRung
        and ('%s (%s)'):format(BR.Storm.fadePath, BR.Storm.fadeRung)
        or 'not settled yet -- no strip has drawn this session'))
end, false)

-- ------------------------------------------------------------- map blips ---
--
-- ═══ A ZONE IS A SHAPE ON THE MAP TOO, NOT A RADIUS (#335) ═══
--
-- The three rings this file draws -- the current circle, the target circle and
-- #327's warmup preview of circle 1 -- were each one BR.Native.radiusBlip call on
-- an (x, y, r). That is the same assumption the wall carried before #326 walked a
-- boundary instead of a circumference, one level down: the MAP knew the storm was
-- round.
--
-- So each ring is now a BR.StormShape, storm_shape.lua turns it into an ordered
-- list of primitives, and this materialises them. What that buys is that the map
-- does not have to be told what kind of shape it is drawing, and the day the
-- rounded rectangle's map box is worth decomposing into six pieces -- which needs
-- somebody to measure whether overlapping blip fills really compound, two minutes
-- in game -- nothing here changes.
--
-- ═══ AND AT squareness 0 IT IS THE CALL IT REPLACED, ARGUMENT FOR ARGUMENT ═══
--
-- A circle's only primitive is `{ kind = 'radius', cx, cy, r }` and that path is
-- the same BR.Native.radiusBlip(existing, cx, cy, r, colour, alpha, name) the three
-- rings were making. config/storm.lua ships squareness at 0, so that is what runs;
-- tools/test_storm.lua's `square.off` asserts it against the record rather than
-- leaving it as a claim.
--
-- THE ONE NUMBER THAT MOVED, and it moved because MIN_RADIUS is a decision this
-- estate already made: BR.StormShape.circle floors its radius at one metre, so a
-- zone whose radius has closed BELOW a metre -- the last seconds of phase 8 -- now
-- asks for a 1m ring where it used to ask for the raw sub-metre value. Both are
-- invisible on a map where the whole city is a few hundred pixels, the wall's own
-- 'solid' path has floored its drawn radius the same way since 2026-08-03, and
-- storm_shape.lua's header argues the floor. Recorded here because "byte for byte"
-- was a claim worth measuring, and this is what the measurement found.

--- A zone circle as the SHAPE the map and the wall should draw it as.
---
--- The squareness knob is read here and nowhere else in this file, so there is one
--- answer to "what shape is the storm" per call site rather than three.
---
--- ZERO RETURNS THE CIRCLE ITSELF rather than a rounded rectangle with a corner
--- radius equal to its half-extent. The two are the same geometry -- storm_shape's
--- own tests pin that their signed distances agree to the bit -- but they are not
--- the same MAP: a circle's primitive is a radius blip and a rounded rectangle's is
--- a box, so routing zero through the general shape would have drawn today's rings
--- as squares. Zero has to be the circle for the no-op to be a no-op.
--- @param cx number
--- @param cy number
--- @param r number
--- @return table shape
local function zoneShape(cx, cy, r)
    local sq = cfg.squareness or 0.0
    if sq <= 0.0 then return BR.StormShape.circle(cx, cy, r) end
    if sq > 1.0 then sq = 1.0 end
    -- HALF-EXTENT r, CORNER RADIUS r * (1 - squareness): a circle at 0 and a square
    -- that contains it at 1. config/storm.lua argues the area that costs.
    return BR.StormShape.roundedRect(cx, cy, r, r, r * (1.0 - sq))
end

--- Remove every blip in `list`. Returns nil, so a caller can write
--- `curBlip = removeBlips(curBlip)` and not have two statements to keep in step.
--- @param list table|nil
--- @return nil
local function removeBlips(list)
    if not list then return nil end
    for i = 1, #list do RemoveBlip(list[i]) end
    return nil
end

--- Is every blip in `list` still there?
---
--- ALL OF THEM, NOT THE FIRST. A zone can be several blips and the engine recycles
--- handles, so another system removing a stale handle can delete any one of ours (a
--- live "no blip at all in squads" report). Asking about the first only would leave
--- a zone drawn with a hole in it and heal nothing, because the re-assert is gated
--- on this answer.
---
--- WRAPPED, AND IT HAS TO BE. DoesBlipExist answers 0 for "no" as readily as false,
--- and 0 IS TRUTHY IN LUA, so the bare read reports a destroyed blip as present and
--- the ring never comes back for the rest of the match.
--- tools/check_bool_natives.lua caught that exact shape here before.
--- @param list table|nil
--- @return boolean
local function blipsLive(list)
    if not list or #list == 0 then return false end
    for i = 1, #list do
        if not BR.NativeTruthy(DoesBlipExist(list[i])) then return false end
    end
    return true
end

--- Draw `shape` on the map, reusing `existing`'s handles where the counts line up.
---
--- ═══ IT DOES NOT KNOW HOW MANY PRIMITIVES IT IS DRAWING ═══
---
--- One for a circle, two for a union of two discs, one for a rounded rectangle, and
--- six for the rounded rectangle's exact decomposition if that ever becomes the
--- right picture. Every one of those is a change to what a constructor in
--- storm_shape.lua writes into `prims` and to nothing in this file, which is the
--- whole reason the descriptor list exists instead of a boolean.
---
--- ═══ THE LEGEND GETS ONE ENTRY PER ZONE ═══
---
--- The first primitive carries the name; every other one is hidden on the legend.
--- blipName's header in client/natives.lua is emphatic that every blip needs a name
--- -- an unnamed blip inherits whatever GTA calls that sprite, which is how the loot
--- markers announced themselves as a heist -- and a zone drawn as three boxes is
--- still one thing to a player, so three "Safe Zone" rows would be worse than one.
--- Hiding is the answer to that rather than an exception to the rule.
---
--- HANDLES ARE REUSED POSITIONALLY, which is what keeps the shipping single-ring
--- case to one remove-and-re-add instead of a rebuild of the list. A shape with
--- FEWER primitives than last time has its surplus handles removed at the end; one
--- with more creates the new ones from nil, which is what radiusBlip does with no
--- previous handle anyway.
--- @param existing table|nil  the handle list from the previous call
--- @param shape table         a BR.StormShape
--- @param colour integer
--- @param alpha integer
--- @param name string         legend entry, applied to the first primitive
--- @return table  the new handle list
local function mapBlips(existing, shape, colour, alpha, name)
    local prims = BR.StormShape.mapPrimitives(shape)
    -- INDEXED BY PRIMITIVE, NOT APPENDED, so slot i always means primitive i. That is
    -- what makes handle reuse positional in the first place, and appending would
    -- quietly re-pair the list with the wrong descriptors the moment one of them drew
    -- nothing.
    local out, whole = {}, true
    for i = 1, #prims do
        local pr = prims[i]
        local legend = (i == 1) and name or nil
        local h
        if pr.kind == 'radius' then
            h = BR.Native.radiusBlip(existing and existing[i], pr.cx, pr.cy, pr.r,
                colour, alpha, legend)
        elseif pr.kind == 'area' then
            h = BR.Native.areaBlip(existing and existing[i],
                pr.cx, pr.cy, pr.w, pr.h, pr.rot, colour, alpha, legend)
        end
        -- NO `else`, AND NO FALLBACK PRIMITIVE. mapPrimitives is the only thing that
        -- produces these and it spells both kinds; drawing an unrecognised descriptor
        -- as the nearer-looking of the two would put a ring on the map in the wrong
        -- place, which is a confident lie about where it is safe to stand.
        -- tools/test_storm.lua asserts that every shape the file can build emits only
        -- these two, so a third one is red before it is drawn.
        if h then
            if i > 1 then BR.Native.blipHiddenOnLegend(h, true) end
            out[i] = h
        else
            whole = false
        end
    end

    -- EVERY OLD HANDLE NO WRAPPER TOOK OVER, which is both the surplus of a shape
    -- that shrank and the slot of a descriptor that drew nothing. The two wrappers
    -- remove the handle they are HANDED, so a non-nil out[i] is the receipt for
    -- existing[i] and the rest are ours to clean up. Without this a zone that lost a
    -- primitive would leave a dead fill on the map for the remainder of the match.
    if existing then
        for i = 1, #existing do
            if not out[i] then RemoveBlip(existing[i]) end
        end
    end

    -- ═══ A ZONE IS DRAWN WHOLE OR NOT AT ALL ═══
    --
    -- Half a zone on the map is worse than none of it: it is a boundary in the wrong
    -- place rather than a missing one, and a player reads a ring as the edge. So a
    -- partial draw is torn down and reported as nothing.
    --
    -- AND NOTHING IS `nil`, NOT AN EMPTY LIST. An empty table is truthy, so handing
    -- one back would turn the callers' `or not curBlip` from a retry into a latch and
    -- the zone would have no ring for the rest of the match -- the missing-blip
    -- failure this file has already had once, rebuilt out of the fix for it.
    if not whole then
        for i = 1, #prims do
            if out[i] then RemoveBlip(out[i]) end
        end
        return nil
    end
    if #out == 0 then return nil end
    return out
end

-- ------------------------------------------------------- the filled shape ---
--
-- ═══ THE MAP STOPS BEING A CIRCLE (#350) ═══
--
--   "seems every storm is still a circle."               -- owner, 2026-09-22
--
-- The wall has been a blob since #344 and the MAP was still a radius blip at `r`.
-- That is not a cosmetic gap, it is where the whole feature is visible: at phase 1
-- the nine corners are 1815 m apart along the boundary and a player on the ground
-- sees a few hundred metres of it, so the shape only reads from above. Corner
-- spacing by radius: 2600 -> 1815 m, 950 -> 663, 260 -> 182, 110 -> 77.
--
-- ADD_AREA_OVERLAY fills an arbitrary polygon on the radar AND on the pause map --
-- #347 spiked it and the concave arrowhead drew on both with its notch intact --
-- so the two zones the map draws are filled polygons of the real boundary now, and
-- the radius blips above are what a client falls back to.
--
-- ═══ THE FALLBACK IS NOT OPTIONAL AND IT IS NOT A SECOND IMPLEMENTATION ═══
--
-- The overlay sits behind a readiness gate that can refuse: the handle comes from
-- another resource, the movie has to be resident, and the gate deliberately waits
-- out the #4167 streaming race that #348 is about. A client that never gets a
-- handle must still see a zone on its map, so mapFilled() is one switch read in
-- both directions -- exactly one of the two paths draws, and the blips are already
-- written and already tested.
--
-- ═══ WHAT IT DRAWS: THE SAME TWO ZONES, AT THE SAME TWO ALPHAS ═══
--
-- The safe zone (what the blue ring marked) and the target (what the purple ring
-- marks), under the same suppression rule -- the whole-map phase-1 hold shows the
-- target only -- and the target pushed LAST so it draws over the zone, which is the
-- ordering the two blips already had.
--
-- BOTH IN THE WALL'S OWN PURPLE, AND THAT IS THE ONE VISIBLE CHANGE. An overlay
-- takes an RGB and a blip takes a palette index; `blip.currentColour = 3` is GTA's
-- blip blue and nothing on this path can ask the engine what that is in RGB. So the
-- layering survives -- faint zone, stronger target -- in one hue rather than two.
-- config/storm.lua's `overlay` block says so and is where a blue would go back.

--- How many areas the overlay is currently showing for us.
local overlayShown = 0
local lastOverlayAt = 0
local overlayKey = nil
local overlaySaid = false
local movingUnionFallbackKey = nil
local mapBlipsDirty = false

--- WHERE the zone on the map is, as the moving circle it was last made to match.
---
--- nil while nothing is drawn. `cx, cy, r` is the solved circle the drawn zone
--- agrees with -- the one it was built at, or the one it was last placed at.
--- `fit` is there only when the zone went out as ONE blob drawn about its own
--- centre, and holds what placing it needs: the radius it was drawn at and its
--- width and height at that radius.
local overlayAt = nil

--- Publish whether a custom fill is currently on the map.
---
--- storm.map runs before storm.state on the same TICK band. Marking the edge here
--- lets the blip owner react on that same pass instead of waiting for its ordinary
--- 4 Hz / 0.5 Hz refresh cadence.
--- @param drawn integer
local function setOverlayShown(drawn)
    drawn = drawn or 0
    if (overlayShown > 0) ~= (drawn > 0) then mapBlipsDirty = true end
    overlayShown = drawn
end

--- Remove our custom map fills and hand the map back to the ordinary blips.
---
--- Used by both the lifecycle and #350's `mapoff` bisect. Keeping the three
--- latches together matters: `overlayShown` controls the blip fallback while
--- the key and placement record control whether the next tick rebuilds.
local function clearMapOverlay()
    -- ALWAYS ASK. removeAll keeps an engine-refused clip on its own books; limiting
    -- retries to overlayShown would forget that clip after this function publishes
    -- the fallback and leave the stale polygon resident for the rest of the sweep.
    if BR.MapOverlay then BR.MapOverlay.removeAll() end
    setOverlayShown(0)
    overlayKey, overlayAt = nil, nil
end

--- Hand one moving non-similar union to the ordinary map blips.
---
--- A conjoined/disjoint pair cannot be moved by translating or scaling one
--- polygon: one half moves while its target stays fixed, so its outline changes
--- shape. Rebuilding that outline was the one path left with #350's reported
--- signature -- only while moving, and about once a second. The nominal-radius
--- blips already exist as the overlay's refusal fallback and update without the
--- Scaleform polygon marshalling. They are approximate guidance for a seeded blob;
--- the exact 3D wall and server damage shape are untouched.
local function startMovingUnionFallback(key)
    if movingUnionFallbackKey ~= key then
        BR.Loop.hitchMark(
            'storm.map.fallback', 'once when a moving union hands the map to blips')
    end
    movingUnionFallbackKey = key
    clearMapOverlay()
    -- Also force the mid-join case, where there was no custom fill whose state
    -- transition could set the dirty bit.
    mapBlipsDirty = true
end

--- Is the overlay drawing the zones right now? Then the radius blips must not.
---
--- READ BY THE TWO BLIP SITES ABOVE AND WRITTEN IN EXACTLY ONE PLACE -- the count
--- setAreas came back with. A boolean of its own beside it would be a second
--- expression of one fact, which is the mistake client/mapoverlay.lua's own header
--- talks itself out of twice.
--- @return boolean
local function mapFilled()
    return overlayShown > 0
end

--- The wall's own purple, at `alpha` of 255 on the linear scale a blip uses.
---
--- BR.MapOverlay.areaAlpha is what turns that into the parameter the movie wants,
--- because the movie's alpha compounds below 100 -- its header has the arithmetic.
--- Done there rather than here so that every caller of setAreas gets it.
--- @param alpha number
--- @return table  { r, g, b, a }
local function fillColour(alpha)
    local c = cfg.render.colour or {}
    return { r = c.r or 255, g = c.g or 255, b = c.b or 255,
             a = math.floor((alpha or 255) + 0.5) }
end

--- WHAT the overlay should be showing, as numbers, and its own key.
---
--- ═══ THE PLAN IS CHEAP AND THE WALK IS NOT, WHICH IS WHY THEY ARE TWO CALLS ═══
---
--- A rebuild is every clip removed and every clip re-added with a kilobyte of
--- coordinates marshalled through a Scaleform string, so it is rate-limited. This
--- runs at the tick rate and the walk runs at the rebuild rate, which is what keeps a
--- zone that has not moved from paying for a boundary walk ten times a second all
--- match: building the contours first and then deciding not to send them would be the
--- cost without the change.
---
--- ═══ THE KEY IS WHAT THE MOVING CIRCLE CANNOT CHANGE (#350) ═══
---
--- It is built from the inputs, not from the output: the phase, the target, the seed
--- and the alpha step. It used to carry the solved circle as well, to the metre, and
--- that one field is why the map rebuilt TWICE A SECOND FOR EVERY SECOND THE STORM
--- MOVED -- measured at the real 100 ms tick, every shrink but the last one's. That
--- was the only client work with the hitch's signature: none while the storm holds,
--- all of it while it moves. So the circle is held beside the key now, in overlayAt,
--- and what a change of it costs is decided in storm.map rather than by the key --
--- usually a placement, sometimes nothing, and for a moving non-similar union the
--- ordinary map-blip fallback instead of a recurring polygon rebuild.
--- @return table|nil plan
--- @return string|nil key
local function overlayPlan()
    local ov = cfg.overlay or {}
    if ov.enabled == false then return nil end

    -- WARMUP AND THE BUS: circle 1, published the moment the match formed (#327),
    -- and it wears phase 1's shape because that is the circle phase 1 will spend.
    local pv = previewCircle()
    if pv then
        return { pv = pv },
            ('p|%.0f|%.0f|%.0f|%d'):format(pv.cx, pv.cy, pv.r,
                math.floor(pv.seed or 0))
    end

    local rec = activeRecord()
    if not rec then return nil end
    local cx, cy, r, st, msLeft = solveNow(rec)
    if r <= 1.0 and rec.r1 <= 1.0 then return nil end

    -- THE SAFE ZONE IS SUPPRESSED FOR THE WHOLE-MAP PHASE-1 HOLD and ramped in on
    -- the wall's own share, exactly as the ring above is -- wallShare, one number
    -- read by the curtain, the ring and this.
    local share = wallShare(rec, st, msLeft)
    local wholeMap = rec.phase == 1 and st == BR.StormPhase.HOLDING
    local zoneA = cfg.blip.currentAlpha
    if wholeMap then zoneA = cfg.blip.currentAlpha * share end

    -- ═══ THE SHAPE THE MAP DRAWS THE ZONE IN: THE ONE IT SET OUT IN, UNTIL THE
    --     WALL ARRIVES ═══
    --
    -- The wall morphs the current zone's shape into the target's across the sweep,
    -- and the map does not: a morph is a new shape every tick, and #350 moves and
    -- scales one fill in place, which is exact only while the shape holds still. So
    -- the map draws the zone in the shape the record started in -- a sweep fraction
    -- of 0 -- the whole way, and takes the target's shape ONCE, when the sweep is
    -- FINISHED and the wall stands on the target in exactly that shape.
    --
    -- AT FINISHED AND NOT A SECOND LATER, WHEN THE NEXT RECORD ARRIVES, because a
    -- breakout is drawn as a union of the zone and its target until the two circles
    -- coincide -- which is the instant the sweep ends -- and in the old shape that
    -- union then collapses to the old shape alone: a boundary jump on the map with
    -- the wall standing still, and a fill claiming ground the wall has just left. In
    -- the target's shape it collapses to the target, which is where the wall is. The
    -- switch is in the key, so it is the one rebuild of a sweep that has stopped --
    -- and the next record's own rebuild draws the same zone again under a new target.
    local done = (st == BR.StormPhase.FINISHED) and 1 or 0

    return {
        rec = rec, cx = cx, cy = cy, r = r,
        state = st, zoneA = zoneA, m = done,
    },
        ('r|%d|%.0f|%.0f|%.0f|%d|%d|%d'):format(
            rec.phase, rec.cx1, rec.cy1, rec.r1,
            math.floor(rec.seed or 0), math.floor(zoneA + 0.5), done)
end

--- The plan's contours, ready for BR.MapOverlay.setAreas, and whether the zone among
--- them can be PLACED from now on instead of rebuilt.
---
--- ═══ ONE BLOB IS A SIMILARITY OF EVERY LATER ONE, SO IT IS DRAWN ABOUT ITS CENTRE ═══
---
--- On every phase that did not break out the safe zone is ONE blob --
--- BR.StormShape.zone returns the containing one -- and a blob is `c + r * unit`: the
--- same unit shape, moved and scaled. The solver only moves c and changes r, so the
--- zone at any later moment of the sweep is the zone drawn now, translated and
--- uniformly scaled, EXACTLY -- not approximately -- and the containment that makes it
--- one blob holds for the whole sweep, because both circles interpolate linearly.
--- So that zone is pushed with its points relative to its own centre, and
--- BR.MapOverlay.placeArea can then move and scale it in the movie with two property
--- writes instead of a rebuild. placeArea's header has why the centre is the whole
--- trick: the movie scales a clip about its origin, and for these points that origin
--- is the zone's centre.
---
--- ASKED OF THE SHAPE, NOT RE-DERIVED. `zone.blob` is what BR.StormShape.blob records
--- about itself; a union of two, a circle below MIN_RADIUS and every other shape carry
--- none, so they go out in world coordinates while static and use map blips while
--- moving. Testing the circles here instead would be a second spelling of the
--- containment rule BR.StormShape.zone already owns.
--- @param plan table  from overlayPlan
--- @return table|nil areas
--- @return table|nil fit  { cx, cy, r, w, h } when areas[1] can be placed
local function overlayFill(plan)
    local ov = cfg.overlay or {}
    local out, fit = {}, nil
    local function push(shape, alpha)
        local cols = BR.StormShape.polyline(shape, ov.chordM, ov.maxPoints)
        for i = 1, #cols do
            -- A CONTOUR UNDER THREE POINTS IS NOT A POLYGON, and the movie would be
            -- handed a coordinate string it cannot close. Reachable only on a shape
            -- whose runs have collapsed -- the last seconds of the final sweep --
            -- where BR.MapOverlay.addArea would refuse it anyway; dropped here so
            -- that "drawn whole or not at all" is not tripped by a zone that has
            -- genuinely run out of geometry.
            if #cols[i] >= 3 then
                out[#out + 1] = { points = cols[i], colour = fillColour(alpha) }
            end
        end
    end

    if plan.pv then
        local pv = plan.pv
        push(BR.StormShape.blob(pv.cx, pv.cy, pv.r, BR.StormUnit(pv.seed, 1)),
            cfg.blip.nextAlpha)
    else
        local rec = plan.rec
        -- THE SAFE ZONE, WHICH IS THE SHAPE THE WALL IS DRAWN ON -- BR.StormZone, the
        -- one spelling of "what is safe right now", so the fill and the curtain cannot
        -- disagree about where the edge is.
        if plan.zoneA > 0.0 then
            -- ═══ AT THE PLAN'S OWN SWEEP FRACTION, AND THAT IS THE WHOLE OF #350 ═══
            --
            -- 0 until the sweep is over and 1 once it is -- overlayPlan has why. The
            -- wall morphs every frame; the map does not, because placing below is
            -- exact only while the zone is ONE shape moved and scaled, and a morphing
            -- zone is a new shape every tick -- a rebuild every tick, the work #350
            -- removed. The target fill drawn over it has been the new shape all phase.
            local zone = BR.StormZone(rec, plan.cx, plan.cy, plan.r, plan.m)
            push(zone, plan.zoneA)
            local b = zone.blob
            -- EXACTLY ONE CONTOUR, AND IT IS THE FIRST AREA. A blob is one closed loop,
            -- so this is the ordinary case; it is tested rather than assumed because
            -- `fit` promises placeArea slot 1, and slot 1 must be this contour.
            if b and #out == 1 then
                local pts = out[1].points
                local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
                for i = 1, #pts do
                    local x, y = pts[i].x - b.cx, pts[i].y - b.cy
                    pts[i] = { x = x, y = y }
                    if x < x0 then x0 = x end
                    if x > x1 then x1 = x end
                    if y < y0 then y0 = y end
                    if y > y1 then y1 = y end
                end
                -- THE EXTENTS ARE WHAT _width AND _height WILL MEAN. The movie measures
                -- the clip's bounds and sets its scale from them, so a placement asks for
                -- these times the scale -- and the blob contains its own centre, so the
                -- clip's origin is inside these bounds whatever the movie counts.
                fit = { cx = b.cx, cy = b.cy, r = b.r, w = x1 - x0, h = y1 - y0 }
            end
        end
        -- AND THE TARGET, LAST, SO IT DRAWS OVER THE ZONE.
        if rec.r1 > 1.0 then
            push(BR.StormShape.blob(rec.cx1, rec.cy1, rec.r1,
                BR.StormUnit(rec.seed, rec.phase)), cfg.blip.nextAlpha)
        end
    end

    if #out == 0 then return nil end
    return out, fit
end

BR.Loop.register(BR.Loop.TICK, 'storm.map', function()
    -- LOADED AFTER THIS FILE, SO IT IS ASKED FOR AT RUNTIME AND NEVER AT LOAD.
    -- br_core's manifest puts client/mapoverlay.lua well after client/storm.lua,
    -- which is deliberate -- it needs client/natives.lua -- so BR.MapOverlay does
    -- not exist while this file is being read. It always exists by the first tick.
    if not BR.MapOverlay then return end

    -- THE FULL MAP-OVERLAY BISECT. Remove the Scaleform polygons altogether and
    -- let the existing radius/area blips carry the map. This changes only what
    -- this client draws; the wall, HUD, damage and server storm continue normally.
    if stormBisectMode == 'mapoff' then
        clearMapOverlay()
        return
    end

    local plan, key = overlayPlan()
    if not plan then
        movingUnionFallbackKey = nil
        -- NOTHING TO SHOW, SO NOTHING IS LEFT ON THE MAP. Between matches, in the
        -- lobby, and while the overlay is switched off, this is what takes the fills
        -- down -- and it puts the blips back in charge on the same tick, because
        -- mapFilled() is one number.
        clearMapOverlay()
        return
    end

    -- KEEP THE EXISTING POLYGONS BUT SEND NO MOVEMENT, RESIZE OR REBUILD CALLS.
    -- If `mapoff` and this mode both remove the hitch, the presence of the fill
    -- is innocent and the live Scaleform update traffic is the useful boundary.
    -- A client entering this mode before its first fill is allowed one build so
    -- there is something resident to freeze.
    if stormBisectMode == 'mapfreeze' and overlayShown > 0 then return end

    -- Once a moving union has selected the blip fallback, stay there for the rest
    -- of that sweep. At FINISHED or on a new record the exact static polygon is
    -- allowed back; rebuilding it once is not the recurring moving-path hitch.
    if movingUnionFallbackKey
            and (key ~= movingUnionFallbackKey
                or plan.state ~= BR.StormPhase.SHRINKING) then
        movingUnionFallbackKey = nil
    end
    if movingUnionFallbackKey and stormBisectMode ~= 'mapfreeze' then
        clearMapOverlay()
        return
    end

    -- THE GATE IS STEPPED ONLY WHILE SOMETHING WANTS AN OVERLAY. Stepping it costs
    -- a cross-resource event at 2 Hz until the handle arrives, so a client sitting
    -- in the lobby with no zone to draw should not be paying it -- and the settle
    -- window starting at warmup rather than at join is also what keeps our own call
    -- furthest from the #4167 race.
    if not BR.MapOverlay.step() then return end

    local ov = cfg.overlay
    local hz = ov.rebuildHz or 2
    if hz <= 0 then return end

    -- ═══ THE SAME PICTURE, SO THE QUESTION IS ONLY WHAT THE CIRCLE DID (#350) ═══
    if key == overlayKey and overlayShown > 0 then
        local at = overlayAt
        -- NOTHING MOVED: every hold, and the whole preview. A handful of comparisons.
        if plan.pv or (plan.cx == at.cx and plan.cy == at.cy and plan.r == at.r) then
            return
        end

        -- ONE BLOB, DRAWN ABOUT ITS CENTRE: PLACE IT. overlayFill has why this is
        -- exact rather than close. The zone is asked for again rather than assumed
        -- still to be one blob, because the last seconds of the final sweep turn it
        -- into a circle below MIN_RADIUS -- a different shape, which is a rebuild.
        if at.fit then
            local b = BR.StormZone(plan.rec, plan.cx, plan.cy, plan.r, plan.m).blob
            if b then
                local s = b.r / at.fit.r
                local resize = stormBisectMode ~= 'mapnoresize'
                local trace = BR.Loop.hitchBegin(
                    resize and 'storm.map.place' or 'storm.map.position',
                    resize and '10 Hz position + resize while a nested storm is SHRINKING'
                        or '10 Hz position only; #350 resize bisect')
                local placed = BR.MapOverlay.placeArea(
                    1, b.cx, b.cy,
                    resize and (at.fit.w * s) or nil,
                    resize and (at.fit.h * s) or nil)
                BR.Loop.hitchEnd(trace)
                if placed then
                    at.cx, at.cy = plan.cx, plan.cy
                    -- Keep the last DRAWN radius while resize is suppressed. That
                    -- makes returning to normal catch the clip up on the next tick
                    -- instead of believing the stale size is current.
                    if resize then at.r = plan.r end
                    return
                end
            end
            -- Refused, or no longer one blob. Either way what the map shows is not
            -- the zone any more, and only a rebuild below can make it so.

        -- A CONJOINED OR DISJOINT UNION CANNOT BE PLACED. One blob moves and
        -- shrinks while the target stays fixed, so the merged outline is not a
        -- translation or a scale of its previous frame. Rebuilding it was the
        -- reported hitch: REM_OVERLAY plus every ADD_AREA_OVERLAY, 0.62--1.65
        -- times a second only while this exact border moved. Use the already
        -- supported nominal-radius blip fallback for the moving interval instead.
        else
            if plan.state == BR.StormPhase.SHRINKING
                    and stormBisectMode ~= 'mapfreeze' then
                startMovingUnionFallback(key)
                return
            end
            if stormBisectMode == 'mapnoresize' then return end
        end
    end

    -- AND NEVER FASTER THAN rebuildHz, WHATEVER ASKED. This is the ceiling that
    -- holds when everything above says yes -- a phase edge, a changed target, a
    -- phase-1 fade stepping its alpha, or a refused placement falling back.
    local now = GetGameTimer()
    if (now - lastOverlayAt) < (1000.0 / hz) then return end
    lastOverlayAt = now

    -- THE WALK HAPPENS HERE AND NOWHERE EARLIER, which is the whole reason the plan
    -- and the fill are two functions: every gate above this line is cheap, so a tick
    -- on which nothing has moved costs a handful of comparisons instead of a boundary
    -- walk per contour.
    local rebuildTrace = BR.Loop.hitchBegin(
        'storm.map.rebuild', '<=2 Hz; static picture, phase, alpha, or placement recovery')
    local areas, fit = overlayFill(plan)
    if not areas then
        -- THE PLAN WANTED SOMETHING AND THE GEOMETRY HAD NOTHING LEFT -- the final
        -- sweep's last seconds, where every contour has collapsed under three points.
        -- Treated as "no fill", so the radius blips take the map and the key does not
        -- latch on a push that never happened.
        clearMapOverlay()
        BR.Loop.hitchEnd(rebuildTrace)
        return
    end

    -- A CLIENT WHICH JOINS MID-SWEEP HAS NO `overlayAt` TO CLASSIFY. overlayFill
    -- has now answered the same question without sending anything to Scaleform:
    -- no fit means the moving picture is a non-similar union. Take the fallback
    -- before setAreas, so even that first frame pays no polygon rebuild.
    if plan.state == BR.StormPhase.SHRINKING and not fit
            and stormBisectMode ~= 'mapfreeze' then
        startMovingUnionFallback(key)
        BR.Loop.hitchEnd(rebuildTrace)
        return
    end

    local drawn, chars = BR.MapOverlay.setAreas(areas)
    -- A ZONE DRAWN ABOUT ITS CENTRE IS DRAWN AT THE WORLD'S ORIGIN until it is placed,
    -- so it is placed in the same tick -- the calls queue behind the adds -- and a
    -- refusal takes the whole push down, for the reason setAreas tears down a partial
    -- one: a zone in the wrong place is worse than none, and none is what hands the
    -- map back to the radius blips.
    if drawn > 0 and fit and not BR.MapOverlay.placeArea(1, fit.cx, fit.cy) then
        BR.MapOverlay.removeAll()
        drawn = 0
    end
    setOverlayShown(drawn)
    -- A REFUSED PUSH DOES NOT LATCH. Clearing the key means the next tick tries
    -- again rather than believing the map is already showing this geometry, and
    -- mapFilled() is false in the meantime so the blips carry the map.
    overlayKey = (drawn > 0) and key or nil
    overlayAt = nil
    if drawn > 0 then
        overlayAt = { cx = plan.cx, cy = plan.cy, r = plan.r,
                      fit = fit }
    end

    -- ONCE, AND IT NAMES THE CHARACTER COUNT. The Scaleform string-parameter cap is
    -- the one unmeasured risk on this path: there is no documented limit, the spike's
    -- coordinates were about 70 characters and a real boundary is several hundred to
    -- over a thousand. If a shape ever draws GARBLED rather than absent this is the
    -- first number to look at, and config/storm.lua's `overlay.maxPoints` is the
    -- lever. Said once per session in the same shape as the wall's fade line, because
    -- a rebuild can happen twice a second and a line per rebuild is a log nobody reads.
    if drawn > 0 and not overlaySaid then
        overlaySaid = true
        local pts = 0
        for i = 1, #areas do pts = pts + #areas[i].points end
        print(('[br_core] storm map overlay: %d area(s), %d points, %d coord chars')
            :format(drawn, pts, chars))
    end
    BR.Loop.hitchEnd(rebuildTrace)
end)

-- ---------------------------------------------------------------- #350 A/B ---
--
-- These modes deliberately make the local picture wrong for a short dev-box
-- measurement. They never alter the shared storm record or server authority:
--
--   normal       shipping path
--   mapoff       no custom Scaleform fill; ordinary map blips take over
--   mapfreeze    keep the fill resident but send no live map updates
--   mapnoresize  move a nested fill but do not resize it
--   walloff      skip the shaped 3D wall
--
-- The sequence distinguishes four materially different costs: merely having the
-- overlay resident, updating it at all, the size/re-tessellation call specifically,
-- and the per-frame shaped wall. Every change starts a new correlation window so
-- samples from two modes cannot be mixed accidentally.
local stormBisectModes = {
    normal      = 'shipping storm rendering',
    mapoff      = 'custom map fill removed; fallback blips active',
    mapfreeze   = 'map fill resident; movement, resize and rebuilds frozen',
    mapnoresize = 'nested map fill moves; resize call suppressed',
    walloff     = 'shaped 3D storm wall suppressed',
}

--- @param mode string
--- @return boolean changed
function BR.Storm.setBisectMode(mode)
    mode = type(mode) == 'string' and mode:lower() or ''
    if not stormBisectModes[mode] then return false end

    stormBisectMode = mode
    BR.Storm.bisectMode = mode
    if mode == 'mapoff' then clearMapOverlay() end
    return true
end

BR.Storm.bisectMode = stormBisectMode

RegisterCommand('brstormbisect', function(_, args)
    args = args or {}
    local mode = tostring(args[1] or 'status'):lower()
    if mode == 'status' then
        print(('[br_core] storm bisect: %s -- %s')
            :format(stormBisectMode, stormBisectModes[stormBisectMode]))
        print('  modes: normal | mapoff | mapfreeze | mapnoresize | walloff')
        return
    end
    if not BR.Storm.setBisectMode(mode) then
        print('  usage: brstormbisect <normal|mapoff|mapfreeze|mapnoresize|walloff> [hitchMs]')
        return
    end

    BR.Loop.resetStats()
    BR.Loop.hitchStart(args[2])
    local h = BR.Loop.hitchStats()
    print(('[br_core] storm bisect: %s -- %s')
        :format(mode, stormBisectModes[mode]))
    print(('  fresh hitch capture at %dms; allow 2s to settle, sample one moving phase,')
        :format(h.thresholdMs))
    print('  then /brstormhitch stop. Changing mode starts another clean window.')
end, false)

-- --------------------------------------------------------------- preview ---
--
-- ═══ CIRCLE 1, BEFORE THE STORM (#327) ═══
--
--   "just determine circle 1's location upon the first player in the match
--    completing matchmaking, and show the blip starting from then. Show the
--    marker (or arc now as it may be) starting from when the San Andreas map is
--    loaded."                                          -- owner, 2026-09-21
--
-- TWO VIEWS OF ONE FACT, ON TWO DIFFERENT CLOCKS, and the two clocks are the
-- whole reason this is two callbacks rather than one:
--
--   * THE MAP BLIP runs from the moment the circle is published -- which is the
--     moment the match forms -- through warmup and the bus. Warmup is when
--     players study the route and argue about where to drop, and this is the
--     other half of that argument. It ENDS at PLAYING, and hands off to the
--     record's own purple ring rather than stopping: see the note above
--     storm.preview for why extending it would be the worse bug.
--   * THE WALL runs from when San Andreas is actually the world. During warmup
--     the player is standing on Cayo Perico, seven kilometres offshore, and Los
--     Santos is not merely unstreamed there -- it is DISABLED, because enabling
--     the heist island hides the mainland (see br_environment/client/ipl.lua).
--     A 950m curtain drawn over Los Santos while the camera is on the island is
--     a curtain in a world that does not exist yet. It runs THROUGH PLAYING and
--     into the real wall's fade-in now (#340), which is the third stretch and
--     the one previewWallCircle exists for -- the owner had an empty horizon
--     from the bus doors closing until ten seconds before the first shrink.
--
-- IT IS THE SAME RENDERER THE REAL WALL USES, handed a circle and a lower alpha.
-- See drawWall's header for why that is a requirement and not a saving.
--
-- NOTHING HERE CAN HURT ANYBODY, and that is structural rather than careful.
-- Storm damage is the server's, applied through client/state.lua on instruction,
-- and the server does not begin the storm until PLAYING. This file draws; the
-- preview is two draw calls and a blip handle.

--- Has br_environment said the Cayo lobby island is gone, and what did it say?
---
--- nil = IT HAS NOT SPOKEN, which is a different answer from "the island is on"
--- and the difference is the fallback below.
local islandSaid = nil

--- Is the world San Andreas right now?
---
--- ═══ ANOTHER RESOURCE OWNS THIS FACT, SO IT IS ASKED AND NOT GUESSED ═══
---
--- br_environment/client/ipl.lua flips the island on the BUS transition, but NOT
--- at the instant of it: applyIsland is deferred until the rendered camera is
--- genuinely clear of the island, or until the bus's own release cue a few seconds
--- into the ascent says the overcast haze is covering the swap. Guessing the moment
--- from the match state would therefore be wrong by seconds every flight, in the
--- direction that shows a wall over a world that is still switched off.
---
--- So ipl.lua announces, and this listens. br_environment is a different Lua state
--- and client events cross resources -- the existing 'br:world:ask' /
--- 'br:world:island' pair goes the same road, and its header explains why.
---
--- ═══ THE MATCH STATE IS THE FALLBACK, AND IT ONLY ANSWERS WHEN NOBODY ELSE DOES ═══
---
--- If br_environment is not running -- or has not reached its first announcement --
--- nothing will ever tell us, and a preview is not worth a hard dependency between
--- two resources. So an unheard-from world falls back to the match state, where BUS
--- is the transition the island is torn down on.
---
--- THE FALLBACK IS NOT CONSULTED ONCE br_environment HAS SPOKEN, deliberately. A
--- resource that is announcing its swaps is the authority on them, and second-
--- guessing it from the state would put the wall back exactly where the event
--- exists to move it from. What that costs, stated plainly: a single announcement
--- lost between the two resources costs one flight its preview wall. It cannot cost
--- a match anything -- the real storm has no part of this.
---
--- ═══ AND THE FALLBACK IS BUS **OR LATER**, WHICH IT HAD TO BECOME (#340) ═══
---
--- It was BUS alone, and that was complete while the preview's own state gate was BUS
--- alone: the two agreed, so the second test could not narrow anything the first had
--- not already. The preview now extends into PLAYING while the real wall is still
--- suppressed, and a BUS-only fallback would have withheld exactly that new stretch
--- on any box where br_environment is silent -- the whole fix missing, on the one
--- deployment shape that has no way to notice. PLAYING is the safest possible entry
--- to add: ipl.lua's wantIsland is `state ~= PLAYING and state ~= BUS`, so PLAYING is
--- a state in which the mainland is the world by that resource's own rule, and the
--- players are standing on it.
--- @return boolean
local function mainlandLoaded()
    if islandSaid ~= nil then return islandSaid == false end
    local ms = BR.State.match.state
    return ms == BR.MatchState.BUS or ms == BR.MatchState.PLAYING
end

AddEventHandler('br:env:world', function(island)
    islandSaid = island and true or false
end)

-- ═══ AND IT ARRIVES RATHER THAN APPEARING (#351) ═══
--
--   "When the map loaded in (while in bus), the storm wall popped in, didn't fade
--    in."                                              -- owner, 2026-09-22
--
-- #340 gave the preview wall its whole life -- warmup, the bus, and the suppressed
-- phase-1 hold -- and its fade OUT, which is one minus the real wall's share. What
-- it never had is an entry: the instant br_environment says the mainland is the
-- world, this callback starts drawing at the full previewAlpha on its first frame,
-- five hundred metres in front of a bus.
--
-- ═══ NOT A SECOND CLOCK, WHICH IS #340'S WHOLE POINT ═══
--
-- The window is render.fadeInSec -- the SAME number the curtain fades in over and
-- the map ring fades in over -- so there is one fade length in this file and the
-- preview now reads it at both ends of its life: in over fadeInSec when the world
-- arrives, out over fadeInSec as the real wall rises. Retuning that one value
-- retunes all four. What is new here is a TIMESTAMP, not a duration, and it is the
-- one thing the existing clock cannot supply: nothing about the phase-1 countdown
-- knows when the mainland streamed in.
--
-- ═══ AND IT DOES NOT CHANGE WHEN THE WALL STARTS DRAWING ═══
--
-- The ramp is anchored on the first frame mainlandLoaded() is true, which is the
-- frame this callback would have drawn on anyway -- so the wall begins at exactly
-- the moment it began before, at nothing instead of at full.
--
-- RE-ARMED WHENEVER THE MAINLAND IS NOT THE WORLD, and that is not only for the
-- next match. br_environment puts the Cayo island back for every state that is not
-- BUS or PLAYING, so a second match in one session would otherwise inherit a
-- finished ramp and pop exactly as before -- and if the island ever came back
-- mid-flight, the wall coming back should arrive the same way it did the first time.
local worldAt = nil

--- How much of the preview's own strength has arrived. 0 before the world arrived,
--- 1 once a whole fade window has passed since it did.
---
--- ═══ FOUR LINES, AND EVERY ONE OF THEM IS THE ONLY THING THAT ANSWERS ITS CASE ═══
---
--- It had two more. A `held <= 0.0` early return and an `ms <= 0.0` early return both
--- came out because each was a SECOND answer to a case something else already
--- answered, and a second answer is a line that can be deleted with nothing going
--- red:
---
---   * A ZERO WINDOW is answered by `held >= ms`, which is true for every held time
---     once ms is zero -- so fadeInSec of 0 means full strength with no division
---     performed at all, rather than a guard in front of one.
---   * A CLOCK THAT WENT BACKWARDS returns a negative share, and the CALLER already
---     draws nothing at or below zero. Clamping here as well would be the same
---     decision made twice, in two places, either of which could later move.
---
--- THE UNARMED CASE IS THE FIRST FRAME, NOT A GUARD, and the caller reads this BEFORE
--- it stamps worldAt for exactly that reason: a nil anchor IS the pass on which the
--- mainland has just become the world. Stamped first, this branch would be
--- unreachable and could be replaced with `return 1.0` -- the pop straight back, with
--- nothing to notice.
--- @return number
local function entryShare()
    if not worldAt then return 0.0 end
    local ms = (cfg.render.fadeInSec or 10.0) * 1000.0
    local held = GetGameTimer() - worldAt
    if held >= ms then return 1.0 end
    return held / ms
end

--- The purple ring on the big map. NEVER REBUILT WHILE IT IS INTACT.
---
--- Radius blips cannot be resized in place, which is why the storm's own two are
--- rebuilt on a cadence -- their radius changes every frame of a shrink. This one
--- never moves and never resizes for as long as it exists, so it is created once
--- and left alone. Re-asserted only when the handle has stopped existing: engine
--- blip handles are recycled, so another system removing a stale handle can delete
--- ours (a live "no blip at all in squads" report), and a 10 Hz existence check
--- heals that within 100ms.
---
--- A HANDLE LIST RATHER THAN A HANDLE, because a zone is however many primitives
--- its shape has (#335). At the shipping squareness of 0 that is a list of one and
--- the ring is the same blip it always was; blipsLive is what makes the existence
--- check above ask about all of them.
local previewBlip = nil

local function clearPreviewBlip()
    previewBlip = removeBlips(previewBlip)
end

-- ═══ THE RING DOES **NOT** EXTEND INTO PLAYING, AND THE WALL DOES (#340) ═══
--
-- The 3D curtain had a gap to close and the map did not, which is worth stating
-- because the two look like one symptom and #340 reported them as one. The moment
-- STORM_SYNC lands, storm.state's own `nextBlip` draws rec.cx1/cy1/r1 -- which during
-- phase 1 IS circle 1, because server/storm.lua's enterPhase SPENDS the warmup draw
-- rather than rolling a second one -- in the same purple, at the same alpha, under the
-- same "Next Safe Zone" legend, as the same shape through the same zoneShape. So the
-- ring the preview was showing is already handed over, with no gap: storm.preview is
-- registered ahead of storm.state, so the tick that takes the preview down is the same
-- tick that puts the record's ring up.
--
-- EXTENDING THE RING WOULD THEREFORE BE THE BUG client/state.lua ALREADY GUARDS: two
-- purple radius blips on one circle, which is how a player learns not to trust either
-- (#327). Measured against that, "nothing on either map" in #340 is not what is
-- happening -- the wall was the whole defect.
BR.Loop.register(BR.Loop.TICK, 'storm.preview', function()
    local pv = previewCircle()
    -- AND IT STANDS DOWN WHEN THE OVERLAY HAS THE SHAPE (#350). The filled polygon
    -- of circle 1's real boundary is the same ring this draws, done properly, so a
    -- radius blip beside it would be a second edge in a different place. See
    -- mapFilled, which is the one switch both map paths read.
    if not pv or mapFilled() then
        clearPreviewBlip()
        return
    end
    -- EVERY PIECE OF IT, AND THE READ IS WRAPPED. DoesBlipExist answers 0 for "no"
    -- as readily as false, and 0 IS TRUTHY IN LUA, so the bare read returns early
    -- for a blip that has been destroyed and the ring never comes back for the rest
    -- of warmup. tools/check_bool_natives.lua caught this against its baseline;
    -- airdrop.lua wraps the same native the same way, and blipsLive is where both
    -- that and "a zone may be more than one blip" now live.
    if blipsLive(previewBlip) then return end

    -- PURPLE, AND THE SAME PURPLE. blip.nextColour is 27, which is what the
    -- "Next Safe Zone" ring has always used -- purple is already this game's word
    -- for "the circle you are being asked to rotate to", so this reuses it rather
    -- than introducing a second colour for the same meaning (#327 says so
    -- outright). The legend entry is that same ring's, for the same reason: this
    -- IS the next safe zone, published earlier.
    previewBlip = mapBlips(previewBlip, zoneShape(pv.cx, pv.cy, pv.r),
        cfg.blip.nextColour, cfg.blip.nextAlpha, 'Next Safe Zone')
end)

--- Circle 1 for the preview WALL, over every stretch it now spans, with its share of
--- previewAlpha.
---
--- ═══ THE SAME CIRCLE FROM TWO SOURCES, BECAUSE ONLY ONE OF THEM STILL HAS IT ═══
---
--- WARMUP and BUS read BR.State.stormPreview, which is what they always did. PLAYING
--- cannot: client/state.lua nils that field the moment STORM_SYNC arrives, and it
--- should keep doing so -- the field is the belt to the state gate's brace, and a
--- preview that outlived the record it was standing in for is the failure #327 wrote
--- both guards against.
---
--- SO PLAYING READS THE RECORD'S OWN TARGET, AND IT IS THE SAME CIRCLE RATHER THAN A
--- COPY OF IT. server/storm.lua's enterPhase spends m.stormFirst -- the circle drawn
--- at warmup and published as the preview -- as phase 1's target rather than rolling a
--- second one (#327, and tools/test_storm.lua's `first.stream` is what makes that
--- impossible to break quietly). So rec.cx1/cy1/r1 during phase 1 IS what the bus was
--- shown, to the bit, from the source that still holds it. A LATE JOINER GETS IT FOR
--- FREE by the same token: somebody who attached after the preview event went out has
--- no field to read and the record all the same.
---
--- ═══ NOT activeRecord(), AND THAT IS THE ONE PLACE THE TWO MUST DIFFER ═══
---
--- activeRecord admits ENDED on purpose: the colour grade, the rain and the vignette
--- have to outlive the transition or the last thing a player sees is the weather being
--- switched off (2026-08-06). The preview must NOT -- its own header says it must not
--- survive a match ending, and a two-player playtest reaches exactly that case, a
--- match decided inside the phase-1 hold, where the record is still phase 1 HOLDING
--- and would otherwise put a purple circle under the verdict slam. So this tests
--- PLAYING by name, and the LOBBY gate is repeated rather than inherited for the same
--- reason it exists in both functions already: a bystander at the vista menu shares
--- the match state without being in the match.
---
--- THE SHARE IS wallShare's COMPLEMENT AND IS NOT COMPUTED HERE. `w >= 1.0` is one
--- test doing two jobs -- everything that is not the phase-1 hold, and the hold's fade
--- window once it has completed -- which is why the handoff cannot be half-written.
--- ═══ AND IT CARRIES THE SEED, BECAUSE IT IS PHASE 1'S SHAPE (#344) ═══
---
--- Both sources have it -- the published preview payload and the record -- and it
--- is the same integer in both, for the same reason the circle is the same circle:
--- enterPhase spends the warmup draw rather than rolling a second one. So the bus
--- is shown the shape phase 1 will actually wear, and the handoff stays a handoff
--- instead of a circle turning into a blob as one fades into the other.
--- @return table|nil circle  { cx, cy, r, seed }
--- @return number alphaScale
local function previewWallCircle()
    local base = cfg.render.previewAlpha or 0.5

    -- WARMUP AND BUS, UNCHANGED, at the bus's own alpha -- so nothing pops at the
    -- BUS -> PLAYING boundary either: the same circle carries on at the same strength.
    local pv = previewCircle()
    if pv then return pv, base end

    if BR.State.match.state ~= BR.MatchState.PLAYING then return nil end
    if BR.State.me.state == BR.PlayerState.LOBBY then return nil end
    local rec = BR.State.storm
    -- A COLLAPSED TARGET IS NOT A CIRCLE TO STAND IN FOR, the same test storm.wall
    -- makes on rec.r1 and BR.StormShape.circle's own one-metre floor would otherwise
    -- quietly answer with a one-metre ring.
    if not rec or rec.r1 <= 1.0 then return nil end

    local _, _, _, st, msLeft = solveNow(rec)
    local w = wallShare(rec, st, msLeft)
    if w >= 1.0 then return nil end
    return { cx = rec.cx1, cy = rec.cy1, r = rec.r1, seed = rec.seed },
        base * (1.0 - w)
end

BR.Loop.register(BR.Loop.FRAME, 'storm.previewWall', function()
    -- THE WORLD GATE IS FIRST NOW, BECAUSE IT IS WHAT ARMS THE ENTRY RAMP (#351).
    -- It was second, below the storm's own gate, and the two are pure predicates in
    -- either order -- the wall draws when both pass. What the order buys is that the
    -- ramp is re-armed on EVERY path where the mainland is not the world, including
    -- the ones where there is no circle to preview: between matches previewWallCircle
    -- answers nil, and a ramp cleared only inside that branch would never clear.
    if not mainlandLoaded() then
        worldAt = nil
        return
    end

    local pv, alphaScale = previewWallCircle()
    if not pv then return end

    -- ═══ READ THE RAMP, THEN ARM IT, AND THAT ORDER IS THE POINT ═══
    --
    -- On the frame the mainland becomes the world there is no anchor yet, so the share
    -- is zero and this returns -- and the stamp below is what makes every later frame
    -- measure from THIS one. Stamping first would give the same zero (a held time of
    -- 0), and it would make entryShare's own unarmed branch unreachable: dead code
    -- that could be replaced with `return 1.0` and put the pop straight back, with
    -- nothing to notice.
    --
    -- AND NOTHING IS DRAWN AT ZERO, which is the reading wallShare's header argues for
    -- its own boundary: a whole wall's worth of triangles at alpha 0 is identical on
    -- screen and a frame of geometry dearer.
    local entry = entryShare()
    if not worldAt then worldAt = GetGameTimer() end
    if entry <= 0.0 then return end

    -- ═══ THE SAME RENDERER AND THE SAME HEIGHT AS THE LIVE WALL ═══
    --
    --   "don't use a marker for the bus preview either."   -- the owner, 2026-09-22
    --
    -- THIS ASKED FOR THE CYLINDER UNTIL THE FADE EXISTED, and the reasoning was
    -- sound rather than lazy: the strip's top was a fixed world z of 400 set for a
    -- player standing on the ground, and the bus cruises at 500 and climbs to 892
    -- to clear the Chiliad massif (config/map.lua's bus.altitude and the leg-4
    -- waypoints) -- so from the one place this wall is ever looked at, the strip was
    -- entirely BELOW the viewer and read as nothing at all. The cylinder spanned
    -- -100 to 850 and was the only wall in the file tall enough to see from a plane.
    --
    -- THE ANSWER WAS TO RAISE THE WALL, NOT TO KEEP THE MARKER. render.strip.topZ
    -- is 850 now -- the marker's own top, to the metre -- and its last metres are
    -- drawn at fade.topAlpha, which is nothing. So the flight passes THROUGH the
    -- fade rather than over a band on the ground half a kilometre below, and the
    -- preview needs no height of its own: one wall, one height, two alphas. A
    -- preview-specific top was drafted and then deleted for exactly that reason.
    --
    -- SO NO PREFERENCE IS PASSED AT ALL. Every caller now takes the strip, which is
    -- what leaves /brwallstyle as the only thing in the game that can ask for a
    -- marker -- and it can still point one at the preview, because the A/B baseline
    -- has to be reachable from both walls.
    --
    -- AND THE ALPHA IS THE CALLER'S NOW, NOT A CONSTANT READ HERE (#340). It is
    -- previewAlpha through the whole bus ride and the whole suppressed hold, and
    -- previewAlpha's own fade-out across the handoff; previewWallCircle owns the
    -- arithmetic because it owns the clock. One circle, one renderer, one height, and
    -- an alpha that only ever moves when the real wall's is moving the other way.
    --
    -- AND THE SHAPE IS PHASE 1'S, not a circle (#344). The phase index is written
    -- as a literal 1 rather than read off a record because the bus has no record at
    -- all -- the preview exists precisely for the stretch before one -- and circle 1
    -- is phase 1's target by definition. A BLOB rather than the zone union: the
    -- preview is ONE circle, which is what it has always been, and there is no
    -- second circle to extend it toward until the storm exists.
    --
    -- AND alphaScale IS MULTIPLIED BY THE ENTRY RAMP (#351), which is the only thing
    -- #351 changed: one number, at the one place the alpha is finally spent, so the
    -- handoff arithmetic previewWallCircle owns is untouched. The two ramps are
    -- independent by construction -- the entry runs once when the world arrives and
    -- has completed long before the hold's last fadeInSec, where the handoff takes
    -- over -- and their product can never exceed either.
    drawWall(BR.StormShape.blob(pv.cx, pv.cy, pv.r, BR.StormUnit(pv.seed, 1)),
        alphaScale * entry)
end)

-- ----------------------------------------------------- blips, FX, envelope ---

local curBlip, nextBlip = nil, nil
local dirBlip = nil       -- centre marker: clamps to the minimap edge = direction home
local lastBlipAt = 0
local lastBlipR = -1.0
local lastPush = 0

--- The last circle solved on the 10Hz band, so the frame job can reuse it.
---
--- The frame job does NOT re-solve. A storm circle moves and shrinks slowly
--- enough that a 100ms-old radius is wrong by centimetres; the thing that
--- moves fast is the PLAYER, and that is the only term worth recomputing.
local solved = nil

--- The last whole metre we told the interface, so a push only happens when
--- the number a player can actually read has changed.
local lastEdgeShown = nil

--- Send the storm envelope. One builder, both bands.
local function pushStorm(edge, marker, expected)
    if not solved then return end
    local trace = BR.Loop.hitchBegin(marker, expected)
    lastEdgeShown = math.floor(edge + 0.5)
    TriggerEvent('br:ui:sendLocal', BR.Nui.STORM, {
        phase        = solved.phase,
        phaseState   = solved.st,
        endsAt       = solved.endsAt,
        radius       = solved.r,
        edgeDistance = edge,
        -- Toward the CENTRE when outside -- the way to run.
        bearing      = BR.Bearing(solved.px, solved.py, solved.cx, solved.cy),
        dps          = solved.dps,
    })
    BR.Loop.hitchEnd(trace)
end

local function clearBlips()
    curBlip  = removeBlips(curBlip)
    nextBlip = removeBlips(nextBlip)
    -- THE ARROW IS NOT A ZONE and stays a bare handle: it is one sprite at one
    -- point, not a shape, so it has no primitive list to walk.
    if dirBlip then RemoveBlip(dirBlip) dirBlip = nil end
    lastBlipR = -1.0
end

-- The screen grade RAMPS on the same clock as the weather and the NUI
-- vignette (weather.blendSec): fxLevel walks toward its target each tick
-- and drives the timecycle STRENGTH, so entering the storm darkens the
-- world over five seconds instead of snapping (user call, 2026-08-04).
--- How long before the wall sets off the countdown pips.
---
---   "I want timer.final to play every single time the 'storm closing in' timer
---    gets to 5s"                                       -- owner, 2026-09-07
---
--- THE HOLDING COUNTDOWN, NOT THE SHRINKING ONE. Two numbers wear this placard:
--- while the wall is HOLDING it counts down to the wall setting off ("Storm
--- moving in"), and while it is SHRINKING it counts down to the wall stopping
--- ("Storm closing now"). "Closing in 5s" is the first of those -- five seconds
--- of warning before the map gets smaller is a thing a player can act on, and
--- five seconds before the wall parks is not.
---
--- ═══ 4000 AND NOT 5000, BY EAR ═══
---
--- Owner, 2026-09-07: "the 5 second storm timer sound effect plays 1 second to
--- early. please set that back just a bit." Judged against the placard he was
--- looking at, which is the only comparison that matters here -- the HUD clock
--- is a browser rAF loop reading `endsAt` against Date.now() plus the page's own
--- offset, while this reads GetGameTimer() plus the client's, and the two are
--- allowed to differ. Rather than chase that, the number moved to where his ear
--- put it. The cue's NAME is Rockstar's `5s` and always was a generic countdown
--- pip; it was never a claim about when we play it.
local FINAL_WARN_MS = 4000

--- The storm record we have already pipped for, identified by its START.
---
--- KEYED ON tStart RATHER THAN ON THE PHASE NUMBER, and the difference is real:
--- `brphase` and `brstormfreeze off` both RE-ENTER the same phase number from
--- wherever the wall is standing, and server/storm.lua's own move-cue latch
--- carries a note about exactly that. Every route into a phase builds a fresh
--- record with a fresh tStart, so this re-arms for all of them without needing
--- to be told. A freeze rebuilds the record once with a 24-hour hold, which is
--- silent by construction rather than by a special case.
local pippedFor = nil

--- Was this player caught in the wall last tick? nil = not established yet.
---
--- ═══ THE CUE RIDES `caught`, NOT `edge > 0`, AND THAT IS THE WHOLE DESIGN ═══
---
--- `caught` is the condition the screen grade and the sky already use: outside
--- AND the storm is actually doing damage right now. Cueing off the raw
--- distance instead would fire for every player at once the moment phase 1's
--- free-loot hold begins -- everybody is outside a circle that is not hurting
--- anybody yet -- which is a chorus of alarms about nothing. Riding the same
--- boolean means the sound, the vignette and the thunder are one event.
---
--- nil RATHER THAN false IS LOAD-BEARING. A player who spawns already outside
--- must not hear the entry cue for a boundary they never crossed, and neither
--- must one whose first tick lands mid-storm after a rejoin. The first tick
--- only ESTABLISHES the value; the second is the first that can be an edge.
local caughtWas = nil

local fxLevel, fxTarget = 0.0, 0.0
local fxApplied, postOn  = false, false
local lastFxAt = 0

local function fxSet(outside)
    fxTarget = outside and 1.0 or 0.0
end

local function fxStep()
    local now = GetGameTimer()
    local dt = (lastFxAt > 0) and math.min(now - lastFxAt, 500) or 0
    lastFxAt = now
    if fxLevel == fxTarget then return end

    local blend = (cfg.weather and cfg.weather.blendSec or 5.0) * 1000.0
    local step = dt / blend
    if fxLevel < fxTarget then fxLevel = math.min(fxTarget, fxLevel + step)
    else fxLevel = math.max(fxTarget, fxLevel - step) end

    if cfg.fx.useTimecycle then
        if fxLevel > 0.0 and not fxApplied then
            fxApplied = true
            SetTimecycleModifier(cfg.fx.timecycle)
        end
        if fxApplied then
            SetTimecycleModifierStrength(cfg.fx.timecycleTarget * fxLevel)
        end
        if fxLevel <= 0.0 and fxApplied then
            fxApplied = false
            ClearTimecycleModifier()
        end
    end
    -- The post FX loop has no strength knob; it joins once the grade is
    -- genuinely present and leaves as it goes.
    if cfg.fx.usePostFx then
        if fxLevel > 0.15 and not postOn then
            postOn = true
            AnimpostfxPlay(cfg.fx.postFx, 0, true)
        elseif fxLevel < 0.05 and postOn then
            postOn = false
            AnimpostfxStop(cfg.fx.postFx)
        end
    end
end

-- REAL WEATHER. Weather natives are LOCAL to this client -- "global
-- weather" is only a thing when a resource syncs it, and nothing on this
-- server does -- so the sky itself becomes a storm effect: full THUNDER
-- when caught outside (no gentle-rain tier -- user call, 2026-08-04),
-- clear again inside. The engine's overtime blend does the build and the
-- fade over blendSec; the NUI vignette fades on the same clock.
--
-- The ladder never touches the weather until the player is first caught
-- outside -- a match spent inside the circle keeps GTA's own sky.
--
-- ═══ IT CLAIMS THE SKY, IT NO LONGER WRITES IT (2026-08-31) ═══
--
-- Every SetWeatherType* call below became BR.World.want('storm', ...) when
-- `brweather` arrived. Two things made that necessary and neither is about the
-- console verb on its own:
--
--   THE OVERRIDE HAS TO OUTLAST A TIER CHANGE. A console sky that this file
--   overwrote the next time somebody stepped over the wall would look exactly
--   like the verb not working.
--
--   AND THE OVERRIDE HAS TO GIVE THIS ONE BACK. `brweather reset` does not
--   guess what the sky should return to -- client/world.lua still holds this
--   file's last claim and simply re-resolves. That only works if the claim was
--   recorded, which is what these calls now do.
--
-- The ladder, the hysteresis and the drying schedule are untouched: what
-- changed is where the last line of each branch sends its answer.
-- RAIN IS NOT PART OF IT. SetRainLevel is this file's own knob and stays here;
-- the sky is a claim, the rain is a setting, and only one of them has three
-- systems arguing over it.
local wxTier  = 'clear'   -- what the sky is currently doing
local wxWant  = 'clear'   -- what the ladder wants it to do
local wxSince = 0         -- when it first wanted that
local wxOwned = false     -- whether we have overridden the weather at all
local wxDryAt = nil       -- when to force the ground dry after clearing
local wxUndryAt = nil     -- when to hand rain control back to the engine
local WX_NAME = { clear = 'EXTRASUNNY', thunder = 'THUNDER' }

local function weatherWant(tier)
    local wcfg = cfg.weather
    if not (wcfg and wcfg.enabled) then return end

    local now = GetGameTimer()

    -- THE DRYING SCHEDULE. Forcing sunny stops the rain, but the ground
    -- keeps its sheen and puddles for minutes -- SetRainLevel(0.0) kills
    -- rain, rain audio AND puddle creation outright (its documented job),
    -- so once the blend back to clear finishes, the world dries. Control
    -- is handed back (-1.0) a while later so the engine's own weather can
    -- rain again some day.
    if wxDryAt and now >= wxDryAt then
        wxDryAt = nil
        -- The blend has finished, so the snap is visually a no-op -- but it
        -- HARD-RESETS the weather system's internal rain memory, which the
        -- overtime path preserves and which is what kept the ground shiny
        -- long after the sky cleared (live report, 2026-08-04).
        --
        -- FORCED, because that hard reset is the entire point of the call and
        -- the claim it re-asserts is one this file already holds. Without the
        -- flag client/world.lua would see "the winner has not changed" and skip
        -- the write, which is correct for every other claim on this page and
        -- exactly wrong for this one.
        BR.World.want('storm', WX_NAME.clear, 0.0, true)
        SetRainLevel(0.0)
        wxUndryAt = now + 45000
    end
    if wxUndryAt and now >= wxUndryAt then
        wxUndryAt = nil
        SetRainLevel(-1.0)
    end

    if tier ~= wxWant then
        wxWant, wxSince = tier, now
        return
    end
    -- Hysteresis: a player strafing the wall must not strobe the sky.
    if tier ~= wxTier and now - wxSince >= (wcfg.holdMs or 2000) then
        wxTier = tier
        if not wxOwned and tier == 'clear' then return end
        wxOwned = true
        BR.World.want('storm', WX_NAME[tier], wcfg.blendSec + 0.0)
        if tier == 'thunder' then
            -- Let the thunderstorm actually rain, whatever the dry
            -- schedule was up to.
            wxDryAt, wxUndryAt = nil, nil
            SetRainLevel(-1.0)
        else
            wxDryAt = now + wcfg.blendSec * 1000.0
        end
    end
end

-- NO "clear" envelope is ever sent from here. A nil payload arrives in the
-- UI as {} (the bridge's `data or {}`), which rendered as a ghost "PHASE
-- UNDEFINED / NaN" storm card during warmup. The UI clears its own storm
-- slice whenever the match state is not PLAYING -- it already receives every
-- state transition, so it needs no extra message to know.
local function teardown()
    clearBlips()
    mapBlipsDirty = false
    -- The frame job reads `solved` and nothing else. Leaving it set would
    -- keep it computing distances to a circle that no longer exists.
    solved, lastEdgeShown = nil, nil
    -- AND THE CUE LATCH GOES BACK TO "NOT ESTABLISHED". Left as `true`, the
    -- first tick of the NEXT match would read as a crossing back inside and
    -- play the all-clear over the bus.
    caughtWas = nil
    pippedFor = nil
    -- Between matches the grade SNAPS off -- there is nothing to fade
    -- against once the world resets around a teleport home.
    fxTarget, fxLevel = 0.0, 0.0
    if fxApplied then fxApplied = false ClearTimecycleModifier() end
    if postOn then postOn = false AnimpostfxStop(cfg.fx.postFx) end
    -- Hand the sky back between matches: this file drops its claim, and
    -- client/world.lua clears the weather only if nothing else wants it.
    -- Dropping the claim rather than clearing the sky directly is what keeps a
    -- match ending from wiping a console override or the lobby island's
    -- overcast out from under them.
    if wxOwned then
        wxOwned = false
        wxTier, wxWant = 'clear', 'clear'
        wxDryAt, wxUndryAt = nil, nil
        SetRainLevel(-1.0)
        BR.World.want('storm', nil)
    end
end

BR.Loop.register(BR.Loop.TICK, 'storm.state', function()
    local rec = activeRecord()
    if not rec then
        BR.Loop.hitchContext(nil, nil, nil)
        teardown()
        return
    end

    local now = BR.Clock.now()
    local cx, cy, r, st, msLeft, dps, t = solveNow(rec)

    -- ═══ FIVE SECONDS BEFORE THE WALL SETS OFF ═══
    --
    -- Not gated on being alive, on being inside, or on spectating, and that is
    -- deliberate: this is a fact about the MATCH, like the storm.move cue the
    -- server broadcasts to everybody in it. A player watching from a corpse is
    -- still watching a round whose map is about to shrink.
    --
    -- THE LATCH IS THE WHOLE MECHANISM. This job runs at 10 Hz, so without it
    -- the last five seconds of every hold would be fifty pips. With it the cue
    -- lands on the first tick at or below the threshold -- up to 100ms late,
    -- which nobody can hear against a five-second warning.
    if st == BR.StormPhase.HOLDING and msLeft <= FINAL_WARN_MS then
        if pippedFor ~= rec.tStart then
            pippedFor = rec.tStart
            BR.Sfx.play('timer.final')
        end
    end

    -- THE LOUDEST OF #225'S THREE READS. Everything below this line -- the HUD
    -- envelope, the direction blip, the grade and the sky -- is measured from
    -- here, so this one substitution is most of the fix.
    local p, from = viewpoint()

    -- ═══ THE SAFE ZONE IS BOTH CIRCLES, AND THIS IS THE ONE LINE THAT SAYS SO ═══
    --
    --   "take for example 2 storm circles (current and next) which are barely
    --    overlapping - like a venn diagram. We should extend the safezone to
    --    cover both circles, so if a player gets to the new destination early
    --    they are safe."                                  -- owner, 2026-09-21
    --
    -- `edge` was `dist - r`: a circle's signed distance, written out by hand.
    -- It becomes the signed distance to the UNION of the current circle and the
    -- one the wall is closing toward, and the four readouts measured off it
    -- follow at once -- the HUD's metres, the screen grade, the sky, and the
    -- pair of crossing cues. Every one of them now agrees with what
    -- server/storm.lua actually bills for, which is the property that matters:
    -- a player who reached the next circle early is told they are safe because
    -- they are, rather than being shown a red screen and a thunderstorm over
    -- ground the server is not charging them for.
    --
    -- ON AN ORDINARY PHASE IT IS THE SAME NUMBER IT ALWAYS WAS. The next circle
    -- is normally nested inside the current one and the union of a circle with
    -- a circle inside it IS the outer circle, so this reads `dist - r` on every
    -- phase that did not break out. That is what makes it shippable.
    --
    -- THE SIGN IS EXACT EVERYWHERE AND THE MAGNITUDE IS EXACT FROM OUTSIDE,
    -- which is all of what is read here. StormShape.distance understates depth
    -- strictly inside the lens where two circles overlap (its header carries
    -- the numbers), so a player deep in an overlap may be told they are 300m
    -- inside rather than 400m. `caught` reads the sign, and the metres on the
    -- HUD are a countdown to safety that only a player OUTSIDE is reading.
    --
    -- AND IT IS A SHAPE NOW (#344), through the same BR.StormZone the wall and the
    -- server's damage tick use. That is what keeps the HUD's metres, the grade, the
    -- sky and the two crossing cues describing the curtain the player can see
    -- rather than a circle nothing draws any more -- at the same sweep fraction the
    -- wall morphs by.
    local zone = BR.StormZone(rec, cx, cy, r, t)
    local edge = BR.StormShape.distance(zone, p.x, p.y)   -- positive = outside
    BR.Loop.hitchContext(rec.phase, st, edge > 0)

    -- Screen FX track being outside AND the storm actually hurting right now
    -- (dps is 0 for everyone during the phase-1 free-loot hold -- the solver
    -- decides that, so this cannot disagree with the server's damage tick),
    -- and only for a viewer the storm has something to say to.
    --
    -- ═══ GATED ON THE SESSION, NOT ON A PLAYER STATE ═══
    --
    -- The comment that used to sit here read "Spectate will re-gate this when
    -- it exists". Spectating shipped and it never did, because there was no
    -- state to gate on: BR.PlayerState.SPECTATING was READ in nine places
    -- across this client and the server and ASSIGNED IN NONE. A spectator
    -- therefore fell through this test as an eliminated player and got the full
    -- REDMIST grade and a thunderstorm driven by their corpse's position.
    --
    -- So the gate asks the thing that is actually written: `from`, which is a
    -- running spectate session and nothing else. #233 has since DELETED that
    -- state rather than giving it a writer -- spectating is possible WHILE a
    -- player is OUT, not instead of it -- so there is no state test to go back
    -- to. This is the gate, not a stopgap standing in for one.
    local me = BR.State.me.state
    local affected
    if from == 'spectate' then
        -- ═══ THE SPECTATOR'S SKY IS THE SKY OVER THE SHOT ═══
        --
        -- `edge` above is already the WATCHED player's, so this is not a red
        -- screen invented for a ghost. Both effects are WORLD RENDERING rather
        -- than viewer vitals -- REDMIST is a timecycle grade over everything
        -- drawn, and the weather natives are per-client by nature (which is
        -- the whole reason config/storm.lua considers them a legitimate storm
        -- effect at all) -- so what they paint is what a third player standing
        -- at the camera would see. Following the shot makes them CORRECT, not
        -- merely quiet.
        --
        -- AND THE REPORT NAMES BOTH DIRECTIONS: a screen "red and raining"
        -- while watching a squadmate safe inside the circle, and "watch a
        -- squadmate die in the storm and your sky stays clear" (#225).
        -- Switching a spectator's effects off wholesale would answer the first
        -- half and leave the second exactly as filed.
        --
        -- NOTHING HERE CAN HURT ANYBODY. Storm damage is the server's and is
        -- applied through state.lua, never from this file -- the header says
        -- so and the M4 authority drill proves it. A ghost given thunder has
        -- been given a picture, and a picture cannot become a hit point.
        affected = true
    else
        -- DEAD is included: a corpse in the storm is still IN the storm, and
        -- the rain and grade stopping at the moment of death read as a bug
        -- (live report, 2026-08-04 -- this becomes the DBNO view later).
        affected = me == BR.PlayerState.ALIVE
            or me == BR.PlayerState.DBNO
            or me == BR.PlayerState.OUT
    end
    local caught = edge > 0 and dps > 0 and affected
    fxSet(caught)
    fxStep()

    -- ═══ CROSSING THE WALL SAYS SO ═══
    --
    --   "When they go out of the storm circle" / "Going back into the storm
    --    circle" -- owner, 2026-09-08, naming a pair of DLC sounds for it.
    --
    -- A SPECTATOR HEARS NEITHER, which is where this parts company with the
    -- grade and the sky above. Those follow the shot deliberately -- they are
    -- world rendering, and what they paint is what somebody standing at the
    -- camera would see. A cue is not world rendering: it is this interface
    -- telling THIS player something about THEIR position, and firing it for a
    -- boundary somebody else crossed is just a confusing noise. So the latch is
    -- reset rather than updated while spectating, and the first tick back in a
    -- body establishes a fresh baseline instead of reporting an edge.
    if from == 'spectate' then
        caughtWas = nil
    else
        if caughtWas ~= nil and caught ~= caughtWas then
            BR.Sfx.play(caught and 'storm.out' or 'storm.in')
        end
        caughtWas = caught
    end

    -- The sky agrees with the vignette: thunder when caught outside,
    -- clearing on the way back in. Same condition as the screen FX so the
    -- free-loot hold stays dry everywhere.
    weatherWant(caught and 'thunder' or 'clear')

    -- NO STORM TOASTS AT ALL (user call, 2026-08-05). This used to announce
    -- the approach every thirty seconds through the phase-1 hold, because the
    -- bar was hidden for that stretch and the wait needed a voice. The bar is
    -- permanent now, from the first storm record onward, so the toasts were
    -- a second clock -- coarser than the first, occasionally disagreeing with
    -- it, and interrupting the one activity the hold exists for. The
    -- countdown IS the announcement.

    -- Blips: radius blips cannot resize in place, so refresh on a cadence --
    -- brisk while shrinking, lazy while holding, and only when the radius
    -- moved enough to see.
    local gt = GetGameTimer()
    -- ═══ THE MAP RING READS THE WALL'S OWN FADE CLOCK, NOT A COPY OF IT ═══
    --
    -- The map ring and the 3D curtain arrive together (user call, 2026-08-04), and
    -- until #350 that was TWO SPELLINGS of one fade: `msLeft <= fadeMs` and
    -- `1 - msLeft / fadeMs` written out here beside wallShare's own identical
    -- arithmetic. Two spellings of one number are two things that can stop agreeing
    -- -- and this copy did not carry wallShare's fadeInSec-of-zero answer either, so
    -- it was right about that case by accident rather than by rule. There is one
    -- share now, and the overlay in storm.map reads the same one.
    local share = wallShare(rec, st, msLeft)
    local wholeMap = rec.phase == 1 and st == BR.StormPhase.HOLDING
    local fading   = wholeMap and share > 0.0
    local hz = (st == BR.StormPhase.SHRINKING or fading)
        and cfg.blip.refreshHzShrinking or cfg.blip.refreshHzHolding
    if mapBlipsDirty or gt - lastBlipAt >= 1000 / hz then
        mapBlipsDirty = false
        lastBlipAt = gt
        -- ═══ THE BLIPS ARE THE FALLBACK NOW, AND ONE OR THE OTHER DRAWS (#350) ═══
        --
        -- When the minimap overlay is filling the real boundary, these rings have to
        -- come DOWN: a filled polygon and a filled disc of the same zone on the same
        -- map are two boundaries, and a player reads whichever one is nearer. The
        -- radius reset is what makes the ring come back whole if the overlay ever
        -- stops -- lastBlipR of -1 cannot match any radius, so the next pass redraws
        -- rather than deciding the circle has not moved.
        if mapFilled() then
            curBlip  = removeBlips(curBlip)
            nextBlip = removeBlips(nextBlip)
            lastBlipR = -1.0
        -- The CURRENT circle is not drawn while it is still the whole map
        -- (phase-1 hold): a ring around all of Los Santos on every map told
        -- players nothing... until the wall starts fading in, when its map
        -- ring fades in WITH it -- alpha ramped on the same countdown the
        -- curtain uses, so neither pops.
        elseif wholeMap then
            if fading then
                local a = math.floor(cfg.blip.currentAlpha * share + 0.5)
                curBlip = mapBlips(curBlip, zoneShape(cx, cy, r),
                    cfg.blip.currentColour, a, 'Safe Zone')
                lastBlipR = r
                nextBlip = removeBlips(nextBlip)
            elseif curBlip then
                curBlip = removeBlips(curBlip) lastBlipR = -1.0
            end
        elseif math.abs(r - lastBlipR) > 1.0 or not curBlip then
            lastBlipR = r
            curBlip = mapBlips(curBlip, zoneShape(cx, cy, r),
                cfg.blip.currentColour, cfg.blip.currentAlpha, 'Safe Zone')
            -- REBUILT TOGETHER, ALWAYS IN THIS ORDER. The target ring used to
            -- be created once and left alone -- so every current-circle
            -- rebuild landed ON TOP of it, then the next phase put it back on
            -- top, and the purple ring read as flashing on the map. Blips
            -- draw in creation order; recreating both keeps purple above.
            nextBlip = removeBlips(nextBlip)
        end
        if not nextBlip and rec.r1 > 1.0 and not mapFilled() then
            nextBlip = mapBlips(nil, zoneShape(rec.cx1, rec.cy1, rec.r1),
                cfg.blip.nextColour, cfg.blip.nextAlpha, 'Next Safe Zone')
        end

    end

    -- "RUN THIS WAY", on the minimap -- whenever outside the PURPLE
    -- TARGET circle, not just the current wall (user call, 2026-08-04:
    -- during the whole phase-1 hold "outside the current circle" is
    -- impossible -- it is the entire map -- but outside the target is
    -- exactly when guidance matters). The blip sits at the NEAREST
    -- SAFE POINT just inside the target's edge, long-range so it
    -- clamps to the minimap's border as a heading that rotates with
    -- the map. Deliberately NOT the centre: the anchor is tuning
    -- data, and parking a marker on it would hand every player the
    -- storm's destination for free.
    --
    -- EVERY TICK, not on the blip refresh cadence (user call,
    -- 2026-08-04): the arrow's rotation must track the player's own
    -- movement smoothly, and re-asserting existence at 10Hz means
    -- anything that eats the handle (a live "no blip at all in squads"
    -- report -- engine blip handles are recycled, so another system
    -- removing a stale handle can delete ours) heals within 100ms
    -- instead of a refresh period.
    --
    -- ═══ IT STILL AIMS AT THE NEXT CIRCLE, NOT AT THE UNION (#328) ═══
    --
    -- The safe zone is both circles now, so it is worth writing down why this
    -- one arrow is NOT measured against the zone the line above builds. It
    -- already aims at the half of that zone the whole rule exists to reward
    -- reaching. Asking the shape for its nearest boundary point instead would
    -- put the arrow on the CURRENT circle's edge on every ordinary nested phase
    -- -- which is nearly every phase -- and that is the opposite direction from
    -- the purple ring the player is being asked to rotate to. It would also
    -- overturn the call this block was built on (2026-08-04): outside the TARGET
    -- is exactly when guidance matters, because during the phase-1 hold
    -- "outside the current circle" is impossible.
    --
    -- THE BREAKOUT IS THE CASE TO CHECK, AND IT ALREADY READS RIGHT. A player
    -- standing safely in the current circle of a barely-overlapping or
    -- separated pair is outside the target, so they get the arrow, and it points
    -- across at the island they have to reach. That is the guidance the union
    -- rule makes worth following rather than a warning it makes redundant: the
    -- storm has stopped charging them for the trip, and the arrow still tells
    -- them where the trip goes.
    --
    -- AND NOTHING FLIPS. A nearest-point-on-the-union arrow would swap islands
    -- as a player crossed the middle of a disjoint pair, aiming first one way and
    -- then the other for a step in any direction, with the storm's own
    -- destination on neither side of the swap. One destination has no such seam.
    -- tools/test_storm.lua pins the choice so it cannot be quietly "made
    -- consistent" later.
    local tx, ty, tr = rec.cx1, rec.cy1, rec.r1
    local distT = BR.Dist(p.x, p.y, tx, ty)
    if distT > tr then
        local inv = 1.0 / math.max(distT, 1.0)
        local sx = tx + (p.x - tx) * inv * math.max(tr - 25.0, 0.0)
        local sy = ty + (p.y - ty) * inv * math.max(tr - 25.0, 0.0)
        -- AN ARROW THAT POINTS AT THE CIRCLE (user call, 2026-08-04,
        -- overturning the earlier "no rotatable arrow" finding): sprite
        -- 11 is a directional arrow per the FiveM blip reference, and
        -- SetBlipRotation aims it. The bearing is player -> target
        -- centre. 2x scale, and NO SetBlipFlashes -- the sprite blinks
        -- on its own, and stacking our flash on top of that left it
        -- invisible half the time (both user calls, 2026-08-04).
        local rot = math.floor(
            BR.GtaHeading(BR.Bearing(p.x, p.y, tx, ty)) + 0.5) % 360
        if not dirBlip or not DoesBlipExist(dirBlip) then
            dirBlip = AddBlipForCoord(sx, sy, 0.0)
            SetBlipSprite(dirBlip, 11)
            SetBlipColour(dirBlip, cfg.blip.nextColour)
            SetBlipScale(dirBlip, 2.0)
            SetBlipAsShortRange(dirBlip, false)
            -- The legend entry. Without it this arrow had no name in the
            -- pause menu at all, which is the one screen where a player who
            -- does not already know what the purple arrow means goes to find
            -- out (user, 2026-08-09).
            BR.Native.blipName(dirBlip, 'Safe Zone — this way')
        else
            SetBlipCoords(dirBlip, sx, sy, 0.0)
        end
        SetBlipRotation(dirBlip, rot)
    elseif dirBlip then
        RemoveBlip(dirBlip)
        dirBlip = nil
    end

    -- The HUD envelope. The countdown is NOT ticked here -- endsAt is a server
    -- timestamp and the UI derives the digits locally, same as the warmup
    -- timer -- so 4Hz is plenty for everything except one field.
    --
    -- THE ONE FIELD IS THE DISTANCE, and it is now pushed from the FRAME band
    -- instead (storm.edge, below). Ten times a second still stepped in
    -- ~70cm jumps at a sprint and read as laggy (user, 2026-08-09).
    local endsAt = 0
    if st == BR.StormPhase.PRE or st == BR.StormPhase.HOLDING then
        endsAt = rec.tStart + rec.tWait
    elseif st == BR.StormPhase.SHRINKING then
        endsAt = rec.tStart + rec.tWait + rec.tShrink
    end
    solved = {
        phase = rec.phase, st = st, endsAt = endsAt,
        cx = cx, cy = cy, r = r, dps = dps,
        -- THE ZONE RIDES ALONG so the frame band below can measure against it
        -- without rebuilding it. Same argument as the circle above: the shape
        -- moves and closes slowly enough that a 100ms-old one is wrong by
        -- centimetres, and the thing that moves fast is the player.
        zone = zone,
        px = p.x, py = p.y,
        -- Whether the frame job has anything to do at all. Inside the circle
        -- it costs one boolean test per frame and nothing else.
        outside = edge > 0,
    }

    -- Inside, nothing here changes fast enough to be worth the traffic.
    if gt - lastPush >= 250 then
        lastPush = gt
        pushStorm(edge, 'storm.ui.tick', '<=4 Hz while a storm record is active')
    end
end)

-- THE DISTANCE, AT FRAME RATE, AND ONLY WHEN IT CHANGES.
--
-- "How far outside am I" is the one number in this interface that a player
-- reads WHILE MOVING, and every fixed cadence is wrong for it: at 4Hz it
-- stepped ~1.8m at a sprint, at 10Hz ~0.7m, and both read as the interface
-- lagging behind the world (user, 2026-08-08 and again 2026-08-09).
--
-- Cost is bounded by what is actually spent, not by the tick rate:
--
--   * inside the circle -- which is nearly everyone, nearly always -- this
--     is one boolean test per frame and returns;
--   * outside, it is one viewpoint read, one distance, and a compare. The
--     circle itself is NOT re-solved; it comes from the 10Hz band, and a
--     100ms-old radius is wrong by centimetres.
--   * and it only SENDS when the whole metre on screen changes, so sprinting
--     straight at the wall at 7 m/s costs about seven envelopes a second --
--     fewer than the fixed 10Hz it replaces -- and standing still costs
--     none at all.
--
-- Which makes this both smoother and cheaper than what it replaces.
BR.Loop.register(BR.Loop.FRAME, 'storm.edge', function()
    if not solved or not solved.outside then return end

    -- THE SAME BODY THE TICK BAND MEASURED FROM, and it has to be asked again
    -- here rather than reused off `solved`: this callback exists precisely
    -- because the position is the one term worth recomputing per frame.
    -- Spectating loses nothing by it -- client/spectate.lua eases the watch
    -- point on the FRAME band too, so the metres still count down smoothly as
    -- the watched player runs, rather than stepping at the feed's 4 Hz.
    local p = viewpoint()
    -- THE SAME ZONE THE TICK BAND BUILT, measured against the position this
    -- frame. `- solved.r` used to stand here, which was the circle's signed
    -- distance written out by hand; the shape carries the radius now.
    local edge = BR.StormShape.distance(solved.zone, p.x, p.y)
    if math.floor(edge + 0.5) == lastEdgeShown then return end

    -- The bearing home is read from the same position, so the arrow and the
    -- number can never describe different moments.
    solved.px, solved.py = p.x, p.y
    pushStorm(edge, 'storm.ui.edge',
        'per-frame check; sends only on a whole-metre change outside')
end)

-- A new record means the "next circle" moved: force the blips to rebuild so
-- the old target ring never lingers on the map.
--
-- AND IT MEANS A NEW COUNTDOWN, WHICH IS SENT ON THE FIRST TICK THAT SOLVES IT
-- RATHER THAN ON THE NEXT 4 Hz ENVELOPE BEAT (#352). The server cuts the phase-1
-- hold to 1:30 by publishing a record with a shorter wait, and the page derives
-- its digits from the `endsAt` this file forwards -- so a throttled push would
-- leave up to a quarter of a second of the old countdown on screen at the one
-- moment somebody is watching it change.
AddEventHandler(BR.Net.STORM_SYNC, function()
    clearBlips()
    mapBlipsDirty = false
    lastBlipAt = 0
    lastPush = 0
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    teardown()
    -- NOT PART OF teardown(), and that is not an oversight. teardown runs on
    -- every tick that has no storm record -- which is all of warmup -- so a
    -- preview blip cleared there would be removed and re-added ten times a
    -- second, which is exactly the blip churn the refresh cadence exists to
    -- avoid. Its lifetime is the state gate in `storm.preview`; a resource stop
    -- is the one moment no callback will ever run again to do it.
    clearPreviewBlip()
end)

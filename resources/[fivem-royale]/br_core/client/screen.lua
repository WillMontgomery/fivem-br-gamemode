-- Screen metrics.
--
-- Players run at 1080p, 1440p, 4K, on ultrawide and on 16:10. Rather than the
-- UI guessing where the edges are, the game is asked directly.
--
-- GTA maintains its own "safe zone" -- an inset from the screen edges that the
-- player can adjust in Settings > Display, and which the engine varies with
-- aspect ratio. Every vanilla HUD element respects it. Reading it and handing it
-- to the UI means our HUD sits exactly where the player expects their interface
-- to sit, on any display, including the ultrawide cases we cannot otherwise
-- reason about.
--
-- "ASKED DIRECTLY" IS NEW, AND IT IS THE WHOLE OF #231. Until now this file
-- said that and then worked the answer out anyway, from one GetSafeZoneSize
-- scalar and a formula that is only correct on 16:9. See safeZoneRect().

local last = { w = 0, h = 0, l = -1.0, t = -1.0, r = -1.0, b = -1.0,
               radar = nil, ready = nil }

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true -- so `if v then` is TRUE for a native that said no with a zero,
--- and `not v` is FALSE for the same zero. Same helper, same reason, as
--- client/airdrop.lua; see tools/bool_native_rules.lua for the write-up.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

--- The native radar's footprint, as a fraction of screen height.
---
--- THE CANONICAL VALUES, researched rather than measured off screenshots
--- (glitchdetector/fivem-minimap-anchor, the community-standard derivation):
--- the radar's map area is EXACTLY screenHeight/4 wide and screenHeight/5.674
--- tall, anchored to the safe zone's bottom-left. Two rounds of
--- screenshot-measuring produced 0.370 then 0.291; the real number is 0.25,
--- which is why the bars kept overshooting the map's right edge.
---
--- BOTH ARE FRACTIONS OF *HEIGHT*, including the width. That is how the engine
--- scales the radar, and it is why the width has to be divided by the RENDERER's
--- aspect ratio to become a fraction of screen width -- see publish().
---
--- Nothing in Lua draws this rectangle. The dashed outline that makes a
--- mismatch visible is in the NUI, hud/Hud.tsx, and only in a DEV build
--- (`npm run dev`); /brdebug has never drawn it. To check it against the real
--- radar, run the harness -- or paste `/brprobe` output from the machine that
--- looks wrong, which is what reports the real safe zone.
local RADAR_H_FRAC = 1.0 / 5.674   -- ~0.1763
local RADAR_W_FRAC = 0.25          -- width == height/4, of HEIGHT

--- The aspect the engine lays its own interface out at. Past this it stops
--- widening its layout box and keeps it CENTRED in the viewport.
local REF_ASPECT = 16.0 / 9.0

--- ═══ THE ENGINE'S OWN SUPERWIDE OFFSET, TRANSCRIBED ═══
---
--- The first fix at #231 read the safe zone from the engine instead of
--- computing it -- right, and not enough. It then said `mapLeft = safeL`,
--- because the radar hangs off the safe zone's bottom-left corner. That is
--- true on a 16:9 monitor and it is the whole of the bug on anything wider.
---
--- THIS IS NOT A GUESS AND IT IS NOT A MODEL OF A BUG REPORT. It is RAGE's
--- arithmetic, from CHudTools::GetMinSafeZone (source/frontend/HudTools.cpp),
--- which insets the safe zone into a centred 16:9 box for script callers:
---
---     if(bScript && IsSuperWideScreen())
---     {
---         float fDifference = ASPECT_RATIO_16_9 / GetAspectRatio();
---         float fMaxBounds = width * fDifference;
---         float fResDif = width - fMaxBounds;
---         float fOffsetAbsolute = fResDif * 0.5f;
---         float fOffsetRelative = fOffsetAbsolute / width;
---         x0 += fOffsetRelative;
---         x1 -= fOffsetRelative;
---     }
---
--- with `IsSuperWideScreen()` being `GetAspectRatio() > ASPECT_RATIO_16_9`.
--- Reduced, fOffsetRelative is `(1 - (16/9) / aspect) * 0.5` -- the function
--- below, and the reason the constant is 0.5 and not something tuned.
---
--- It is Rockstar's deliberate design, not a FiveM defect: nta, on the Cfx
--- forum -- "the radar ... is supposed to be 16:9-clamped (imagine playing on
--- a 32:9 monitor and having to twist your neck to even see the HUD)
--- according to R*". citizenfx/fivem#2719 is the same behaviour reported as a
--- bug: the minimap stays "in the center(ish) of the screen as if it was
--- following a 16:9 aspect ratio".
---
--- SUPERWIDE IS OFF ON A MULTI-MONITOR SETUP -- IsSuperWideScreen returns
--- false outright when the monitor config is multihead, so a surround player's
--- radar really is at the panel edge and this returns 0 for them only if the
--- aspect we are handed is theirs. It is why the aspect comes from
--- GetAspectRatio rather than from the resolution, and why /brprobe prints
--- both.
--- @param aspect number
--- @return number
local function pillarFrac(aspect)
    if type(aspect) ~= 'number' or aspect <= REF_ASPECT then return 0.0 end
    return (1.0 - REF_ASPECT / aspect) * 0.5
end

--- Apply that offset to an edge -- IF THE ENGINE HAS NOT ALREADY APPLIED IT.
---
--- WHICH IT USUALLY HAS, AND THE CASE THAT MATTERS IS WHEN IT HAS NOT.
--- safeZoneRect() below has two paths. The gfx-align read goes through
--- CalculateHudPosition -> GetMinSafeZone with bScript set, so the offset is
--- already in the number and there is nothing to add. THE FALLBACK CANNOT
--- HAVE IT: it is built from GetSafeZoneSize, which in the same file is
--- nothing but the pause-menu slider --
---
---     int size = SAFEZONE_SLIDER_MAX - CPauseMenu::GetMenuPreference(...);
---     float fSafezone = (float)(100-size)*0.01f;
---
--- -- no width, no aspect ratio, no viewport. A rectangle derived from it is
--- 16:9 by construction and CANNOT see the clamp, on any screen, ever. That is
--- the path that puts the health bars on the panel's left edge while the map
--- sits a quarter of a screen inboard, which is the owner's screenshot.
---
--- Rather than trusting which path ran, this ASKS: at 32:9 the offset is 25%
--- of the screen and the safe-zone inset is about 3%, so which side of the
--- offset the reported edge falls on IS the answer, and the two are never
--- close enough to confuse. On 16:9 the offset is 0, every edge is already
--- `>= 0`, and this returns its argument untouched -- the ordinary monitor
--- never reaches the branch at all.
--- @param edge number   the reported inset from that side, 0..1
--- @param pillar number the engine's superwide offset on that side, 0..1
--- @return number
local function intoBox(edge, pillar)
    if edge >= pillar then return edge end
    return pillar + edge
end

--- Whether the radar is currently on screen. IsRadarHidden reflects both our
--- own DisplayRadar calls and the pause map; guarded because a wrong native
--- name is nil and this must never take the metrics loop down.
local function radarVisible()
    local ok, hidden = pcall(IsRadarHidden)
    if not ok then return true end
    return not isTrue(hidden)
end

--- The RENDERER's aspect ratio.
---
--- NOT width/height. The two agree on an ordinary 16:9 monitor and diverge
--- exactly where it matters -- ultrawide, letterboxed and multi-monitor setups,
--- where the rendered aspect is not the window's. GetAspectRatio is what the
--- engine itself lays out against, so it is what our arithmetic has to use.
--- client/dui.lua learned this first and carries the longer note.
--- @param w number|nil
--- @param h number|nil
--- @return number
local function renderAspect(w, h)
    local a = GetAspectRatio(false)
    if type(a) ~= 'number' or a <= 0.1 then
        a = (w and h and h > 0) and (w / h) or (16.0 / 9.0)
    end
    return a
end

--- The safe-zone rectangle, in SCREEN FRACTIONS measured from the top-left:
--- left edge, top edge, right edge, bottom edge.
---
--- ═══ ASKED FOR, NOT WORKED OUT ═══
---
--- This used to be `local inset = (1.0 - GetSafeZoneSize()) * 0.5`, applied to
--- both axes. That formula is a 16:9 ASSUMPTION wearing the clothes of a
--- measurement, and it is wrong on every other shape of display:
--- glitchdetector/fivem-minimap-anchor DELETED the same arithmetic from its own
--- ultrawide fix and replaced it with exactly the two calls below, and
--- citizenfx/fivem#2719 records why -- on an ultrawide the engine keeps the
--- minimap "in the center(ish) of the screen as if it was following a 16:9
--- aspect ratio", which no arithmetic over a single 0.8..1.0 scalar models.
---
--- SetScriptGfxAlign puts the drawing origin on a corner of the SAFE ZONE, and
--- GetScriptGfxPosition then reports where that origin actually landed. The
--- engine has already applied the player's slider, the aspect ratio, and
--- whatever it does on unusual displays; we only read the answer. Two corners
--- give the whole rectangle -- and it is published as a rectangle rather than
--- as one inset because left and top are NOT the same number once the display
--- stops being 16:9.
---
--- The fallback below is the old arithmetic, kept ONLY for the case where the
--- gfx natives are unavailable and clearly labelled as the thing that is wrong
--- on ultrawide -- a HUD laid out on a 16:9 guess beats no HUD at all.
--- @return number, number, number, number
local function safeZoneRect()
    local ok, l, t, r, b = pcall(function()
        -- Bottom-LEFT corner: x is the left edge, y is the bottom edge.
        SetScriptGfxAlign(string.byte('L'), string.byte('B'))
        local lx, by = GetScriptGfxPosition(0.0, 0.0)
        ResetScriptGfxAlign()
        -- Top-RIGHT corner: x is the right edge, y is the top edge.
        SetScriptGfxAlign(string.byte('R'), string.byte('T'))
        local rx, ty = GetScriptGfxPosition(0.0, 0.0)
        ResetScriptGfxAlign()
        return lx, ty, rx, by
    end)

    -- THE ALIGN STATE MUST NOT BE LEFT SET, whatever happened in there. It is
    -- per-script, so a throw between the Set and the Reset above would hand
    -- every other DrawSprite in this resource -- the descent prompt, for one --
    -- an origin it never asked for, and that failure would present nowhere near
    -- this file.
    pcall(ResetScriptGfxAlign)

    -- A rectangle or nothing. A half-answer here becomes a HUD drawn off the
    -- edge of the screen, so anything that is not four numbers making a box
    -- falls through to the approximation rather than being published.
    if ok and type(l) == 'number' and type(t) == 'number'
       and type(r) == 'number' and type(b) == 'number'
       and l >= 0.0 and t >= 0.0 and r <= 1.0 and b <= 1.0
       and r > l and b > t then
        return l, t, r, b
    end

    -- ═══ AND SAY SO, ONCE, OUT LOUD ═══
    --
    -- THIS FALLING THROUGH SILENTLY IS THE SHAPE OF THE ROUND THAT SHIPPED
    -- BROKEN. The engine read is the entire fix; if it does not happen, the
    -- HUD lays out on a 16:9 guess and looks exactly like a HUD that was never
    -- fixed, with nothing anywhere saying which of the two it is. One console
    -- line costs nothing and turns "the ultrawide fix did not work" into a
    -- question with an answer.
    --
    -- ONCE, not per poll: this runs at the SLOW rate and a per-tick warning
    -- would bury the log it is supposed to be readable in.
    if not last.warned then
        last.warned = true
        print('[br_core] screen: SetScriptGfxAlign/GetScriptGfxPosition did not '
            .. 'give a safe-zone rectangle -- falling back to the '
            .. 'GetSafeZoneSize formula, which is 16:9 by construction. On an '
            .. 'ultrawide the HUD will sit on the panel edges. Run /brprobe.')
    end

    -- The old arithmetic. It is CORRECT on 16:9 and structurally blind
    -- everywhere else: GetSafeZoneSize is the pause-menu slider and nothing
    -- else (CHudTools::GetSafeZoneSize -- no width, no aspect), so no
    -- rectangle derived from it can carry the engine's superwide offset.
    -- intoBox() in publish() puts that offset back, which is the only reason
    -- this path is survivable on a wide panel at all.
    --
    -- Both axes get the same FRACTION, which is what the engine does:
    -- GetMinSafeZone computes `offsetW = (width - width*safezoneSize) * 0.5`
    -- and divides by width, and the same for height -- so it is the same
    -- percentage of each axis, not the same physical distance on both.
    local safe = GetSafeZoneSize()
    local inset = (type(safe) == 'number') and ((1.0 - safe) * 0.5) or 0.032
    return inset, inset, 1.0 - inset, 1.0 - inset
end

local function publish()
    local w, h = GetActiveScreenResolution()
    local aspect = renderAspect(w, h)
    local l, t, r, b = safeZoneRect()

    -- ONE RECTANGLE, IN VIEWPORT PERCENTAGES, AND EVERY SURFACE READS IT.
    -- Per-edge, because on an ultrawide the horizontal inset is nothing like
    -- the vertical one and a single number cannot be both.
    local safeL = l * 100.0
    local safeT = t * 100.0
    local safeR = (1.0 - r) * 100.0
    local safeB = (1.0 - b) * 100.0

    -- ═══ AND THE HUD'S OWN FRAME, WHICH IS THE MINIMAP'S BOX, NOT THE PANEL ═══
    --
    -- "See the minimap near the center of the screen? That's where we want our
    -- bars to be. this should include our voice chat, squad panel, inventory,
    -- chat, etc" -- the owner, 2026-08-23, over a real 32:9 screenshot.
    --
    -- The minimap is the HUD's ORIGIN. GTA lays its own interface out inside a
    -- 16:9 box centred in the viewport and will not move the radar out of it,
    -- so a HUD that anchors to the viewport's edges scatters away from the map
    -- by the width of the pillar -- invisible at 16:9, where the pillar is
    -- zero and the two models are the same model.
    --
    -- HORIZONTAL ONLY. A panel wider than 16:9 has spare WIDTH; the top and
    -- bottom edges are the safe zone's and stay that way, which is why
    -- mapBottom below is still safeB and there is no vertical counterpart to
    -- this. A panel NARROWER than 16:9 is the mirrored case and we have no
    -- report of it: pillarFrac returns 0 there and nothing moves.
    local pillar = pillarFrac(aspect)
    local hudL = intoBox(safeL, pillar * 100.0)
    local hudR = intoBox(safeR, pillar * 100.0)

    -- The minimap rectangle, so the UI can anchor our health/shield bars, the
    -- chat and the notices to the real radar wherever the player's safe-zone
    -- slider put it. RADAR_W_FRAC is a fraction of screen HEIGHT, so dividing
    -- by the RENDERER's aspect converts it to a fraction of screen WIDTH --
    -- the one place the aspect ratio enters this file, and the reason it comes
    -- from GetAspectRatio rather than from w/h.
    --
    -- THE WIDTH NEEDED NO CORRECTION and did not get one: it is already a
    -- fraction of the viewport, and a narrower map on a wider panel is what
    -- the engine actually draws. Only the map's PLACE was wrong.
    local mapW = (RADAR_W_FRAC / aspect) * 100.0
    local mapH = RADAR_H_FRAC * 100.0

    TriggerEvent('br:ui:sendLocal', BR.Nui.SCREEN, {
        width   = w,
        height  = h,
        -- Percentages, because the UI positions with them. safeX/safeY are the
        -- LEFT and TOP edges under their old names, kept because the UI's
        -- "is this a metrics envelope or the scope flag?" guard reads safeX.
        safeX   = safeL,
        safeY   = safeT,
        safeL   = safeL,
        safeT   = safeT,
        safeR   = safeR,
        safeB   = safeB,
        -- THE HUD'S FRAME. The safe zone's top and bottom, and the engine's
        -- layout box left and right. Everything clustered around the minimap
        -- -- the squad panel, the counters, the kill feed, the inventory --
        -- hangs off these two rather than off safeL/safeR, so the whole
        -- interface stays with the map instead of spreading to the panel's
        -- edges. Identical to safeL/safeR on 16:9.
        hudL    = hudL,
        hudR    = hudR,
        -- The radar rect. Its BOTTOM is still the safe zone's -- the engine
        -- anchors the radar to the safe zone's bottom-left corner and the
        -- vertical axis is not what a wide panel stretches. Its LEFT is the
        -- frame's, which is the correction: the safe zone's left edge is the
        -- PANEL's on an ultrawide and the radar is not there.
        mapLeft   = hudL,
        mapBottom = safeB,
        mapW      = mapW,
        mapH      = mapH,
        radarOn   = radarVisible(),
        -- Rides here rather than in its own envelope so a br_ui restart
        -- mid-session re-learns it on the next periodic publish. Owned by
        -- loading.lua; the lobby's opaque streaming backdrop keys on it.
        worldReady = BR.State.worldReady ~= false,
    })
end

--- Republish when anything changes. Resolution can change mid-session when the
--- player alt-tabs, switches monitor, or edits display settings, the safe
--- zone changes the moment they touch the calibration slider, and the radar
--- toggles with match state -- so this is polled rather than sent once.
-- SCOPES ONLY, NOT AIMING GENERALLY.
--
-- "Hide the HUD while aiming" is too broad: aiming a pistol leaves the screen
-- alone, and blanking the interface for it costs the player their health bar
-- in a fight. What actually clashes is a SCALEFORM -- the sniper scope draws a
-- full-screen overlay, and our panels sit on top of it (user, 2026-08-07:
-- "anything that doesn't display scaleforms while aiming should still have HUD
-- on, but HUD+scaleforms = bad").
--
-- Which weapons do that is a property of the weapon, so it is answered from
-- OUR table (`scoped = true`) rather than by asking the engine about camera
-- modes -- the last time this file guessed at a camera native it suspended a
-- callback and brought GTA's weapon wheel back.
--- True while a scope scaleform is up. Read by natives.lua, which owns the
--- per-frame DisplayRadar call -- see below for why that matters.
BR.Screen = BR.Screen or {}
BR.Screen.scoped = false

local scopedNow = false

BR.Loop.register(BR.Loop.TICK, 'screen.scope', function()
    local want = false

    if IsPlayerFreeAiming(PlayerId()) then
        -- ASK THE ENGINE WHAT IS IN THE HAND, not our inventory.
        --
        -- The first version read the active INVENTORY slot, which is wrong for
        -- a reason the screenshot made obvious: it only knows about weapons WE
        -- issued. A sniper equipped any other way -- vMenu, a future starting
        -- kit, anything -- left the slot empty, so the check found no weapon,
        -- decided nothing was scoped, and the HUD drew straight over the scope
        -- (user, 2026-08-08).
        --
        -- The ped is the thing actually holding a rifle, so the ped is what to
        -- ask. Our table still decides whether that weapon HAS a scope; the
        -- engine only says which weapon it is.
        local ok, hash = GetCurrentPedWeapon(PlayerPedId(), true)
        if ok then
            local w = BR.Config.WeaponByHash[BR.NormHash(hash)]
            want = (w and w.scoped) and true or false
        end
    end

    if want == scopedNow then return end
    scopedNow = want
    BR.Screen.scoped = want

    -- The radar goes with it: a minimap over a scope is the same problem.
    -- Setting it here is not enough on its own -- natives.lua re-asserts
    -- DisplayRadar every FRAME from the player's state, so a 10Hz call here
    -- would be overwritten within milliseconds. That loop reads
    -- BR.Screen.scoped for exactly this reason.
    DisplayRadar(not want)
    TriggerEvent('br:ui:sendLocal', BR.Nui.SCREEN, { scoped = want })
end)

BR.Loop.register(BR.Loop.SLOW, 'screen.metrics', function()
    local w, h = GetActiveScreenResolution()
    -- THE RECTANGLE IS WHAT IS WATCHED, not the GetSafeZoneSize scalar it used
    -- to be derived from. The engine can move these edges for reasons that
    -- scalar does not change with -- a resolution change, a monitor swap --
    -- and the UI has to follow every one of them, not only the slider.
    local l, t, r, b = safeZoneRect()
    local radar = radarVisible()
    local ready = BR.State.worldReady ~= false

    if w ~= last.w or h ~= last.h
       or math.abs(l - last.l) > 0.0005 or math.abs(t - last.t) > 0.0005
       or math.abs(r - last.r) > 0.0005 or math.abs(b - last.b) > 0.0005
       or radar ~= last.radar or ready ~= last.ready then
        last.w, last.h = w, h
        last.l, last.t, last.r, last.b = l, t, r, b
        last.radar, last.ready = radar, ready
        publish()
    end
end)

-- THE STOCK MINIMAP HEALTH/ARMOUR BARS ARE OURS NOW. SETUP_HEALTH_ARMOUR(3)
-- on the minimap scaleform hides the built-in strip (the community-standard
-- trick every custom HUD uses); our bars render in its place, driven by the
-- same display units as the rest of the interface -- the stock bar also
-- disagreed with our numbers, because it draws the raw engine range.
-- Re-applied every pass: the game quietly restores the strip after certain
-- frontend transitions, and a once-only call came back after the pause menu.
local minimapSf = nil
BR.Loop.register(BR.Loop.SLOW, 'screen.hidebars', function()
    if not minimapSf then
        minimapSf = RequestScaleformMovie('minimap')
    end
    if minimapSf and HasScaleformMovieLoaded(minimapSf) then
        BeginScaleformMovieMethod(minimapSf, 'SETUP_HEALTH_ARMOUR')
        ScaleformMovieMethodAddParamInt(3)
        EndScaleformMovieMethod()
    end
end)

--- Re-send when the UI restarts, since it loses everything on reload.
AddEventHandler('br:ui:ready', function()
    last.w = 0   -- force the next poll to republish
    publish()
end)

--- Immediate republish on demand -- the boot choreography flips worldReady
--- and must not wait out the SLOW poll for the double fade to start.
AddEventHandler('br:screen:refresh', function()
    last.w = 0
    publish()
end)

exports('publishScreenMetrics', publish)

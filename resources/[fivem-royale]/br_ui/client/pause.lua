-- The pause menu.
--
-- IT REPLACES GTA'S, IT DOES NOT LAYER OVER IT. The engine's frontend is a
-- scaleform, not a NUI layer: nothing we draw can cover it and it cannot cover
-- us, so the two can never be on screen together. The key is therefore
-- captured before the engine sees it, and OUR menu comes up.
--
-- ESC IS THE KEY, AND THIS HEADER USED TO SAY THE OPPOSITE. It said Escape
-- could not be ours, because FiveM cannot rebind the engine's pause CONTROL --
-- which is true and turned out not to matter: DISABLE_FRONTEND_THIS_FRAME
-- stops the frontend being toggled at all, from the keyboard and from a pad
-- alike (br_core/client/natives.lua). The owner asked for Escape on 2026-08-09
-- and it moved there, with a KVP migration so it moved for existing players
-- too. F1 survives only as the ENGINE-side default, for a client with no raw
-- key layer -- see the long note by the keybind at the bottom of this file,
-- which is the whole of why the lobby could not open this menu.
--
-- The MAP is deliberately handed back to the engine. GTA's map is a scaleform
-- we cannot reproduce, and re-rendering Los Santos in CEF would cost real
-- frames -- the same reason the minimap is the engine's and not ours.

local RES = GetCurrentResourceName()

BR = BR or {}
BR.Pause = {}

--- Whether our menu is up. Tracked so the keybind toggles rather than
--- re-pushing focus onto a screen that is already showing.
local open = false

--- When the menu last changed state, so ONE PRESS CANNOT COUNT TWICE.
---
--- TWO PATHS CAN SEE ONE ESCAPE, and which of them arrives is not something
--- this code gets to know. The page has its own keydown listener (App.tsx, and
--- PauseMenu's own back-out handler) and br_core's raw key layer is reading the
--- same physical key straight off the keyboard. Either can be first.
---
--- IT LIVES UP HERE, BESIDE `open`, RATHER THAN NEXT TO THE KEYBIND, and that
--- move is the whole of the lobby half of #83. The stamp used to be written
--- only inside `br:ui:pauseToggle` -- the raw-key path -- so the guard covered
--- that path against itself and not against the page at all. Opening the menu
--- from the lobby, which HAS to come from the page (see the keybind section at
--- the bottom for why the game never sees the key there), therefore left the
--- window unstamped: a raw Escape landing a frame later read `open == true`
--- and toggled the menu straight back off, and the player saw a flicker and no
--- menu. Stamping in open() and close() means every route through this file
--- shares one window, whichever of them got there first.
local lastToggle = 0

--- Whether GTA's own frontend is up because WE put it there, showing the map.
--- Its watcher thread reads this every frame, so clearing it is how anything
--- else asks the map to close.
---
--- IT IS AN INTENT, NOT AN OBSERVATION, AND THAT DISTINCTION IS #207. Read on
--- its own it answers "we asked for a map" and nothing more; whether there is
--- still a map on screen is a question only the game can answer, and until
--- #207 nothing asked it. See mapFrontendUp() below -- everything outside this
--- file's watcher goes through that and not through this.
local frontendMap = false

--- Whether the GAME has confirmed the frontend actually came up for this raise.
--- Before that, its "not active" is the raise still being in flight and is not
--- evidence of anything.
local mapSeen = false

--- The last moment the GAME said the frontend was on screen.
---
--- ANCHORED IN THE PAST RATHER THAN AT THE FIRST DOUBT, which is not a detail.
--- A "when did we first notice it was gone" clock only starts when somebody
--- asks -- so the first thing to ask after a dismissal would always be told
--- "still up", and if that first asker is a keypress then the press is eaten
--- and we are back in #207 with a smaller window. Recording when it was last
--- SEEN makes the answer the same whoever asks and whenever, which is the whole
--- property this file was missing.
local mapLastUp = 0

--- Which raise owns the shared flags.
---
--- WHY A GENERATION AND NOT A BOOLEAN (#207). The watcher thread's teardown
--- used to write `frontendMap = false`, `br:map:frontend false` and
--- announceFrontend(false) UNCONDITIONALLY, half a second after the player
--- left the map. Anything that opened a new map inside that half second got a
--- second thread -- and then the FIRST thread's teardown landed on the SECOND
--- thread's flags, took br_core's frontend suppression back off standby
--- underneath a menu that was mid-raise, and told the page to draw again. The
--- new map died on the frame it appeared, and pressing the key again only
--- started the cycle over. Stamping each raise and refusing to let a
--- superseded one write anything is what ends that; it is the same reason
--- `lastToggle` exists twenty lines up, applied to threads instead of presses.
local mapGen = 0

--- NORMALISE EVERY BOOL A NATIVE HANDS BACK.
---
--- IS_PAUSE_MENU_ACTIVE is a BOOL native and a FiveM BOOL native may answer
--- `1` rather than `true`. In Lua `1 == true` is false and `0` is truthy, so
--- `if IsPauseMenuActive() == true` and `if not IsPauseMenuActive()` are two
--- different kinds of wrong on the same call. This project has shipped that
--- mistake four times; client/inventory.lua, client/debug.lua and
--- client/driveby.lua all keep a local `yes` for it and this is the fourth.
local function yes(v) return v == true or v == 1 end

--- Does the GAME say its frontend is on screen right now? (#207)
---
--- THE GRACE IS NOT CAUTION, IT IS PauseMenuceptionTheKick. Committing the map
--- page RESTARTS the scaleform, and a restarting menu reads as "not active"
--- for a frame or two -- so a bare `not IsPauseMenuActive()` would decide the
--- player had dismissed the map on the very frame we finished opening it.
--- IsPauseMenuRestarting covers the window the engine admits to; the 150ms
--- covers the frames on either side of it that it does not. The cost of the
--- grace is 150ms of a flag describing a map that has already gone, which
--- nothing can observe; the cost of no grace is the map closing itself.
local MAP_GONE_MS = 150

local function gameSaysMapUp()
    if not mapSeen then return true end
    if yes(IsPauseMenuActive()) or yes(IsPauseMenuRestarting()) then
        mapLastUp = GetGameTimer()
        return true
    end
    return (GetGameTimer() - mapLastUp) < MAP_GONE_MS
end

--- IS THERE A MAP TO CLOSE? THE RECONCILED ANSWER (#207).
---
--- THIS FUNCTION IS THE FIX. The owner's report was "after opening the map a
--- few times using M, I can no longer open the map ... is it maybe because I
--- didn't use M to dismiss it but instead right clicked?", and yes, precisely:
--- right-click is BACK, the frontend handles it ITSELF, and the only thing
--- watching for the map going away was a list of CONTROL IDS. The watcher's
--- own comment admits the hole -- "right mouse cannot be read raw ... which is
--- why the list is broad rather than precise" -- so a right-click the list
--- misses leaves `frontendMap` raised over a menu that is not there. The next
--- press then reads as "close", clears a flag nobody is watching, and does
--- nothing the player can see. No error, because nothing went wrong; the two
--- ideas of the world had simply stopped matching.
---
--- So the flag is DERIVED rather than asserted: our intent AND the game
--- agreeing there is something on screen. When they disagree the game wins,
--- because the game is the one drawing it.
local function mapFrontendUp()
    return frontendMap and gameSaysMapUp()
end

--- Tell the PAGE that the engine's frontend owns the screen.
---
--- CLEARING THE FOCUS STACK WAS NEVER ENOUGH, and this is the fix for the
--- half of #122 that actually matters (owner, 2026-08-16: "results in the
--- lobby UI overlaying on top of the GTA V settings screen").
---
--- The reasoning that was wrong: "our screens follow focus, so emptying the
--- stack takes them all down". The LOBBY does not follow focus. It is drawn
--- from match state on purpose -- a queue screen you cannot see is worse than
--- one you cannot yet click -- so clearFocus released the cursor and left the
--- lobby painted exactly where it was, on top of a scaleform that nothing we
--- draw can sit under.
---
--- And the attempt before this one had the PAGE raise the flag itself, just
--- before asking Lua to hand over. That loses a race it cannot see: the
--- handover pops `pause` and `settings` off the stack, which leaves `lobby`
--- on top, which makes the bridge send FOCUS{screen='lobby'} -- and the page
--- treated focus coming back as the frontend having closed, so it cleared its
--- own flag and redrew, a frame before the menu even appeared. It reproduced
--- ONLY from the lobby for exactly that reason: nowhere else is there a
--- `lobby` entry underneath to become the new top.
---
--- So the flag is LUA'S, it is set before the frontend is raised and cleared
--- only once the frontend is genuinely down, and the page mirrors it.
--- @param up boolean
local function announceFrontend(up)
    TriggerEvent('br:ui:sendLocal', BR.Nui.FRONTEND, { up = up == true })
end

--- @param tab string|nil  which tab to land on ('help', 'notices', ...)
function BR.Pause.open(tab)
    if open then return end
    open = true
    lastToggle = GetGameTimer()
    -- The tab rides the focus envelope, the same way the chat channel does --
    -- one message, and the screen knows both that it is opening and what it
    -- is opening ON. A second envelope would race the first.
    TriggerEvent('br:ui:pauseTab', tab)
    TriggerEvent('br:ui:pushFocus', 'pause')
end

function BR.Pause.close()
    -- POP UNCONDITIONALLY, and never behind an `if open`. `open` is a display
    -- flag; the focus STACK is the thing that must not leak, and popFocus is
    -- already safe to call for a screen that does not hold focus.
    --
    -- The guard that used to be here is how a match left through this menu
    -- came back to haunt the lobby (user, 2026-08-09: readied up and "was
    -- brought back to the pause menu where I could not close the UI"). See
    -- the focusChanged handler at the bottom for the full sequence.
    --
    -- The stamp is written on the way DOWN as well as on the way up, and only
    -- when the menu was actually up: the closing press and the opening press
    -- are the same key, so a raw Escape trailing the page's close by a frame
    -- would otherwise re-open the menu the player just dismissed.
    if open then lastToggle = GetGameTimer() end
    open = false
    TriggerEvent('br:ui:popFocus', 'pause')
end

-- CLOSING THE MENU FROM BEHIND THE CURTAIN (#124).
--
-- The one verb on this screen that takes the whole screen away -- "Back to
-- lobby" -- deliberately does NOT close the menu when it is pressed any more.
-- br_core raises the curtain, waits for the page to report it solid black, and
-- only then fires this: the menu comes down, the party is left, the server is
-- told, and the player sees none of it.
--
-- The owner's own FAIL criterion for the path this one was modelled on says why
-- it cannot close itself first: "you see the lobby menu vanish ... at any point
-- BEFORE or DURING the fade" is a fail. A pause menu that pops away on the click
-- and drops the player back into a live match for the length of the fade is the
-- same fault wearing the same clothes.
--
-- br_core owns WHEN because br_core is the only side that knows whether there is
-- a match to leave at all, and it fires this on every outcome -- the leave
-- proceeding, the leave being refused because the player is already in the
-- lobby, and its own fail-safe timer. Three more nets sit under that: the F1
-- keybind, Escape, and the focusChanged handler at the bottom of this file.
AddEventHandler('br:ui:pauseClose', function()
    BR.Pause.close()
end)

--- GTA's own pause menu, driven straight to its map page.
---
--- THIS IS THE COMMUNITY RECIPE (cfx forum, "one button main map"), and the
--- difference from what was here is the part I had wrong: it WAITS ON THE
--- MENU'S OWN STATE rather than guessing at a delay. Every timing-based
--- version of this is reported to bring the map up "at irregular intervals",
--- which is exactly what a fixed 200ms racing a scaleform load looks like.
---
--- Two more pieces that were missing. PAUSE_MENUCEPTION_THE_KICK after
--- GoDeeper: going deeper sets the page, the kick is what commits it -- which
--- is why GoDeeper alone appeared to do nothing. And SetFrontendActive(false)
--- to leave, because the menu is being entered sideways and its own back
--- button has nowhere sensible to go back to.
---
--- It still does not SUPPRESS the other tabs. Nothing does; they are the same
--- scaleform. This lands on the map with the tabs above it, which is what
--- GTA Online itself looks like.
--- Pause menu page ids, from the list the owner linked (pastebin qxuhwjPT).
---
--- ONLY THE MAP. Deep-linking a SETTINGS page was tried and does not work:
--- GoDeeper does not reach 1139 (voice) from the multiplayer pause menu -- the
--- menu simply stays on its own default, which is the map, so the button
--- appeared to open the map instead (user, 2026-08-09). 1148 (key bindings) is
--- the same list by the same mechanism and is assumed to fail the same way, so
--- neither is offered. The screens that wanted them say where to find them.
BR.Pause.PAGE = {
    MAP = 0,   -- the map's own fullscreen view, via GoDeeper + TheKick
}

-- ===========================================================================
-- THE MAP FRONTEND'S LIFE, ONE FRAME AT A TIME (#207)
-- ===========================================================================
--
-- WHY THIS IS A STEP FUNCTION AND NOT A THREAD BODY. #199 shipped the exit
-- watcher as a closure inside Citizen.CreateThread, and its own report said the
-- consequence out loud: the thread "cannot be exercised in a Lua harness
-- (Citizen.Wait is a no-op), so the thread is recorded and never run in the
-- tests". Everything the suite could reach was the four lines before the first
-- Wait -- and #207 is a bug in the part after it. A gate that cannot see the
-- code where the bugs are is not a gate for that code.
--
-- So the thread is now `while BR.Pause.mapStep(st) do Citizen.Wait(0) end` and
-- nothing else. There is no Wait inside the step, so tools/test_client.lua can
-- drive as many frames as it likes with the game answering whatever it likes --
-- a menu that never comes up, a menu that vanishes on its own, a second raise
-- landing on top of the first. Those are the three cases the owner hit and none
-- of them was reachable before.
--
-- The phases:
--
--   raising   we have asked for the frontend; wait for the game to put it up,
--             bounded, because a menu that never arrives must not leave a
--             thread spinning at Wait(0) for the rest of the session.
--   paging    GoDeeper + TheKick, which is what commits the map page.
--   watching  the map is up. It ends when the player asks out, when somebody
--             else lowers the flag, or -- and this is the one that was missing
--             -- when THE GAME says the frontend has gone.
--   settling  we asked the frontend to go; insist for half a second, because
--             the same press that got us here is still being handled by the
--             scaleform and can bring it straight back.

local MAP_RAISE_MS  = 5000
local MAP_SETTLE_MS = 500

-- WATCHING FOR THE WAY OUT, AND WATCHING IT EVERY WAY THERE IS.
--
-- Two rounds of this listened for controls 199/200/202 only, and both
-- times the answer in game was "it is not working any differently"
-- (user, 2026-08-09). While the frontend has the input, a control
-- pressed inside it can arrive DISABLED, on a different index, or not
-- as a control at all -- so this stops relying on any single reading:
--
--   * the frontend cancel/pause controls, enabled AND disabled;
--   * INPUT_FRONTEND_RRIGHT/ACCEPT-adjacent ids used by the map page;
--   * and Escape read RAW, straight off the keyboard, which is the one
--     reading the frontend cannot intercept.
--
-- Right mouse cannot be read raw -- the raw natives are keyboard-only
-- -- so it has to come through a control, which is why the list is
-- broad rather than precise. A false positive here costs a map that
-- closes slightly too eagerly; a false negative is a player stuck in
-- a menu, which is what we have had twice.
--
-- ...AND "SLIGHTLY TOO EAGERLY" IS NOT WHAT A FALSE POSITIVE COSTS. It
-- costs the map, mid-match, while the player is reading it -- which is
-- the owner's re-report, made more than once and never addressed:
-- "opening the pause menu, then map, within the match, then scrolling in
-- quick succession, results in the map being dismissed."
--
-- AND #207 IS THE PRICE OF THE FALSE NEGATIVE, FINALLY PAID. "Broad rather
-- than precise" was honest about the list being a guess; what nobody wrote
-- down is that a MISS here used to be permanent. Right-click is BACK, the
-- frontend acts on it itself, and if none of the ids below happened to fire on
-- that frame then the menu went away while `frontendMap` stayed up. The loop
-- had no other way to end, so it did not end. That is why the watching phase
-- below asks the GAME as well as the keyboard: the input list is now one of two
-- ways out instead of the only one, and the other one cannot be guessed wrong.
--
-- WHY THIS ROUTE AND NOT THE OTHER ONE, which is the question that was
-- never asked. The engine's frontend has TWO openers in this file and
-- they are the same scaleform:
--
--   openFrontendPlain (below) has NO watcher at all. It raises the menu
--     and then polls IsPauseMenuActive() every 100ms, letting GTA own
--     every input -- because the player has to WALK there themselves and
--     "an exit watcher would close it the moment they tried to go
--     anywhere". That is the route reachable from the lobby (Settings ->
--     Voice / Graphics / GTA key bindings), and it is the one a previous
--     round fixed by taking its watcher away.
--
--   this one keeps the watcher, because the map is entered SIDEWAYS --
--     driven straight to a page whose own Back has nowhere sensible to
--     go -- so something has to notice the player wanting out.
--
-- The in-match Map card is the only way in here (PauseMenu.tsx hides it
-- in the lobby), so the fix for the lobby could not have reached this and
-- the report is not a regression: it is the half that was never touched.
-- Nothing in the page is involved -- while the frontend is up the whole
-- NUI document is opacity 0 with pointer events off, and PauseMenu.tsx's
-- keydown listener is unmounted with the menu -- and CEF is not receiving
-- the wheel at all with the cursor released.
--
-- 195 WAS NOT A BUTTON. The comment above says these are "INPUT_FRONTEND_
-- RRIGHT/ACCEPT-adjacent ids", and 194 is indeed INPUT_FRONTEND_RRIGHT --
-- but ACCEPT is 201, and 195 is INPUT_FRONTEND_AXIS_X, an ANALOG AXIS.
-- IsControlJustPressed on an analog control fires when the axis crosses
-- its press threshold, so every pan and every scroll-driven zoom on the
-- map page was being read as somebody asking to leave. That is a
-- one-number typo doing exactly what the report describes, and it is
-- removed rather than corrected: there is no button at 195 to want.
local EXITS = { 202, 200, 199, 177, 194, 25 }

-- AND USING THE MAP IS NOT LEAVING IT. Dropping 195 removes the id we
-- can prove is wrong; this removes the CLASS. The wheel is bound to
-- several control ids at once in the frontend and which of them the map
-- page answers on is a question the game settles, not the documentation
-- -- so rather than guess again, any frame in which the player is
-- zooming, scrolling or panning suppresses the exit test outright, plus
-- a short tail for the input the scaleform is still digesting.
--
--   241/242  INPUT_CURSOR_SCROLL_UP/DOWN
--   180/181  INPUT_CELLPHONE_SCROLL_FORWARD/BACKWARD
--   207/208  INPUT_FRONTEND_LT/RT      -- the map's own zoom pair
--    14/15   INPUT_WEAPON_WHEEL_NEXT/PREV
--   195..198 the frontend axes, which is what a pan is
--
-- JUST-pressed rather than held, deliberately: a held reading would let a
-- drifting controller stick sit on the guard forever and make the map
-- unleavable by mouse, which is a worse bug than the one being fixed. An
-- edge fires once and the window expires on its own, while a wheel being
-- spun produces one edge per notch and therefore keeps refreshing it --
-- which is precisely the "in quick succession" case.
local USING = { 241, 242, 180, 181, 207, 208, 14, 15, 195, 196, 197, 198 }
local BUSY_MS = 300

--- EVERY ONE OF THESE IS A BOOL NATIVE, so every one is read through `yes`.
--- Unnormalised, a build that answers `0` for "not pressed" would make every
--- id in both lists read as pressed on every frame -- `0` is truthy in Lua --
--- and the map would shut itself on the frame it opened. The lists work today,
--- which means these natives are answering booleans today; that is a fact
--- about this build and not a property of the API.
local function pressed(c)
    return yes(IsControlJustPressed(2, c)) or yes(IsDisabledControlJustPressed(2, c))
end

--- @param st table  the live raise
local function wantsOut(st)
    -- ESCAPE FIRST AND OUTSIDE THE GUARD, so there is always one way
    -- out that nothing above can suppress. IsRawKeyDown reports the HELD
    -- state, so this fires on the frame it goes down and every frame
    -- after -- which is fine, because the first one already leaves.
    local ok, down = pcall(IsRawKeyDown, 0x1B)
    if ok and yes(down) then
        if BR.Pause.mapDebug then print('[br_ui] map: exit raw ESC') end
        return true
    end

    for _, c in ipairs(USING) do
        if pressed(c) then
            if BR.Pause.mapDebug then
                print(('[br_ui] map: using the map (control %d) -- holding the exit off'):format(c))
            end
            st.busyUntil = GetGameTimer() + BUSY_MS
            return false
        end
    end
    if GetGameTimer() < st.busyUntil then return false end

    for _, c in ipairs(EXITS) do
        if pressed(c) then
            if BR.Pause.mapDebug then
                print(('[br_ui] map: exit control %d'):format(c))
            end
            return true
        end
    end
    return false
end

--- Put every flag back, and tell the two things that mirror them.
---
--- A SUPERSEDED RAISE MUST NEVER REACH HERE, WHICH IS THE OTHER HALF OF #207.
--- An old thread's teardown running late is what turned one missed dismissal
--- into a key that stayed dead: it handed br_core's frontend suppression back
--- WHILE THE NEW RAISE WAS STILL COMING UP, so br_core closed the menu the new
--- thread had just asked for, and the new thread then sat out its full
--- five-second raise deadline. Press again inside that and the same thing
--- happens again. Nothing about it is visible from a chair: no error, no menu,
--- and a key that "stopped working".
---
--- THE GENERATION IS CHECKED IN ONE PLACE AND IT IS NOT HERE. mapStep's first
--- line retires a stale raise before any of its branches can call this, and
--- retireMap has just bumped the generation to itself -- so a guard here would
--- be a second gate on a road with no second entrance. It was written, and then
--- taken out again when mutation-testing showed it could not be reached: an
--- unreachable safety check is not safety, it is a branch nothing can prove.
--- @param st table|nil  the raise letting go, for BR.Pause.map's sake
local function releaseMap(st)
    frontendMap  = false
    mapSeen      = false
    mapLastUp    = 0
    if BR.Pause.map == st then BR.Pause.map = nil end
    -- Suppression resumes only once the frontend is genuinely down, so
    -- there is no frame in which both are trying to own it.
    TriggerEvent('br:map:frontend', false)
    -- And the page draws again. Reached no matter which way the player
    -- left the map, because every exit below comes through here.
    announceFrontend(false)
end

--- Abandon whatever raise is live, without waiting for its thread to notice.
---
--- Bumping the generation is the point: it retires any watcher still out there
--- in one assignment, so nothing it does afterwards can land on the flags. Used
--- by closeMap when the game says the map has already gone -- there is no menu
--- for that watcher to watch and no reason to let it keep a press-eating flag
--- raised while it works that out for itself.
local function retireMap()
    mapGen = mapGen + 1
    -- Abandoned outright, so the debug readout stops naming a raise nothing is
    -- stepping any more. releaseMap only clears this for the raise that owns
    -- it, and by here nobody owns it.
    BR.Pause.map = nil
    releaseMap(nil)
end

--- ONE FRAME OF THE MAP FRONTEND'S LIFE.
--- @param st table     the raise, as built by openFrontendMap
--- @return boolean     true while there is more to do
function BR.Pause.mapStep(st)
    -- A SUPERSEDED RAISE DOES NOTHING AT ALL -- not a native call, not an
    -- event, not a flag. It does not even tidy up after itself, because the
    -- raise that replaced it owns everything it would have tidied.
    if st.gen ~= mapGen then return false end

    if st.phase == 'raising' then
        -- The wait is the fix, but it cannot be unbounded: if the menu never
        -- comes up -- another resource holding the frontend, a state that
        -- refuses it -- this thread would spin at Wait(0) for the rest of the
        -- session, and a busy loop nobody can see is the worst kind.
        if yes(IsPauseMenuActive()) and not yes(IsPauseMenuRestarting()) then
            -- FROM HERE THE GAME'S ANSWER MEANS SOMETHING. Before it, "not
            -- active" is the raise still in flight; after it, "not active" is
            -- the player having left.
            mapSeen      = true
            mapLastUp    = GetGameTimer()
            st.phase     = 'paging'
            return true
        end
        if GetGameTimer() >= st.deadline then
            print('[br_ui] map: pause menu never became active; giving up')
            -- Hidden for a frontend that never arrived. Without this the player
            -- is left looking at the world with no interface and no way back.
            releaseMap(st)
            return false
        end
        return true
    end

    if st.phase == 'paging' then
        -- Consumed, not remembered. A page left set here would be reused by
        -- the NEXT open, which is how a one-off navigation becomes a
        -- permanent one.
        local page = BR.Pause.pendingPage or BR.Pause.mapPage or BR.Pause.PAGE.MAP
        BR.Pause.pendingPage = nil
        local ok, err = pcall(function()
            PauseMenuceptionGoDeeper(page)
            PauseMenuceptionTheKick()
        end)
        print(('[br_ui] frontend page %d -- %s')
            :format(page, ok and 'ok' or ('FAILED ' .. tostring(err))))
        st.phase = 'watching'
        return true
    end

    if st.phase == 'watching' then
        -- SOMEBODY ASKED US TO CLOSE -- closeMap, from the map key or the
        -- pause key. The menu is still on screen, so it has to be taken down.
        if not frontendMap then return BR.Pause.mapSettle(st) end

        -- IT WENT AWAY BY ITSELF, WHICH IS THE WHOLE OF #207. Right-click is
        -- BACK and Escape is cancel; the frontend acts on both without asking
        -- us, and the owner named both by name as dismissals that must keep
        -- working. There is nothing to deactivate here -- the menu is already
        -- gone -- so this exit does NOT go through settling. Half a second of
        -- SetFrontendActive(false) aimed at a frontend that is not up is
        -- precisely what used to shoot down the next map the player asked for.
        if not gameSaysMapUp() then
            if BR.Pause.mapDebug then
                print('[br_ui] map: the frontend went away on its own -- reconciled')
            end
            releaseMap(st)
            return false
        end

        if wantsOut(st) then return BR.Pause.mapSettle(st) end
        return true
    end

    if st.phase == 'settling' then
        -- AND IT IS RE-ASSERTED, because one call is not reliably enough:
        -- the same press that got us here is still being handled by the
        -- scaleform, which can bring the menu straight back on the next
        -- frame. Half a second of insisting costs nothing and removes the
        -- whole class of "it flickered back".
        if yes(IsPauseMenuActive()) then SetFrontendActive(false) end
        if GetGameTimer() < st.until_ then return true end
        releaseMap(st)
        return false
    end

    return false
end

--- Start taking the frontend down. Split out so both ways of asking share it.
--- @return boolean  true, because settling always has frames left to run
function BR.Pause.mapSettle(st)
    -- THE PRESS-EATING FLAG COMES DOWN NOW, NOT IN HALF A SECOND (#207).
    --
    -- It used to be cleared at the END of the settle, which meant that for
    -- 500ms after the map had visibly gone, closeMap still answered "yes there
    -- is a map" -- so the next press was swallowed whole and the player saw
    -- nothing happen. That is the single most reproducible half of the report:
    -- dismiss the map, press M again straight away, nothing. What the frontend
    -- still owes us is a deactivation, and that is what `settling` is for; it
    -- is not a reason to keep telling the rest of the file there is a map up.
    frontendMap  = false
    mapSeen      = false
    mapLastUp    = 0

    -- LEAVING IS SetFrontendActive(false) AND NOTHING ELSE.
    --
    -- The recipe kicks first, and that is what was putting GTA's pause
    -- menu on screen instead of dismissing: the kick un-deepens the menu,
    -- so it pops back UP to the tabs -- and then the deactivate lands a
    -- frame or more later, leaving the frontend visible in between (user,
    -- 2026-08-09: "right click shows the GTA V pause menu instead of
    -- dismissing back to game"). Going straight out skips the page it was
    -- surfacing.
    SetFrontendActive(false)

    st.phase  = 'settling'
    st.until_ = GetGameTimer() + MAP_SETTLE_MS
    return true
end

--- @param page integer|nil
function BR.Pause.openFrontendMap(page)
    -- RECONCILED, NOT ASSUMED. The bare `if frontendMap then return end` this
    -- replaces refused to open whenever the flag was stale -- which, after a
    -- dismissal the watcher missed, was forever.
    if mapFrontendUp() then return end
    BR.Pause.pendingPage = page
    frontendMap  = true
    mapSeen      = false
    mapLastUp    = 0
    mapGen       = mapGen + 1
    -- br_core suppresses GTA's frontend every frame now that Escape is ours.
    -- This is the one time we WANT it, so it has to know to stand down --
    -- otherwise the map opens into a menu that is being closed underneath it.
    TriggerEvent('br:map:frontend', true)
    -- AND THE PAGE STOPS DRAWING (#138). Latent rather than live until now only
    -- because PauseMenu.tsx hides the Map card in the lobby, and the lobby is
    -- the one screen that keeps painting through a cleared focus stack -- so
    -- this was #122 waiting for somebody to unhide a card. Announced here, and
    -- cleared at every exit in mapStep, for the same reason openFrontendPlain
    -- does: the scaleform can be up on the very next frame.
    announceFrontend(true)

    local st = {
        gen       = mapGen,
        phase     = 'raising',
        deadline  = GetGameTimer() + MAP_RAISE_MS,
        busyUntil = 0,
    }
    -- EXPOSED, and for two readers rather than one: `brmapmode` prints it so a
    -- playtester can say which phase a map that misbehaved was in, and
    -- tools/test_client.lua drives mapStep against it directly.
    BR.Pause.map = st

    -- RAISED HERE AND NOT IN THE THREAD. It was inside the closure, which put
    -- the one native that makes this function do anything on the far side of
    -- the harness boundary. Nothing waits on it -- the raising phase is the
    -- wait -- so there was never a reason for it to be a frame later.
    --
    -- FE_MENU_VERSION_MP_PAUSE, not SP: the multiplayer pause menu is the
    -- one the map is the point of.
    ActivateFrontendMenu(GetHashKey('FE_MENU_VERSION_MP_PAUSE'), false, -1)

    Citizen.CreateThread(function()
        while BR.Pause.mapStep(st) do Citizen.Wait(0) end
    end)
end

--- GTA's own pause menu, opened PLAINLY, for the player to navigate.
---
--- A DIFFERENT JOB FROM THE MAP, hence a different function. The map is a
--- destination: we drive straight to it, and the exit watcher above is
--- deliberately trigger-happy because there is nothing in there to click.
---
--- This one is the opposite. Voice settings and key bindings live several
--- levels into the Settings tab, and the player has to walk there themselves
--- -- so we must NOT grab their inputs. Right-click, Escape and the arrow keys
--- are how the menu is used; an exit watcher would close it the moment they
--- tried to go anywhere.
---
--- So nothing is navigated and nothing is intercepted. We open it, then wait
--- for GTA to tell us it is gone, and take our frontend suppression back at
--- that point. Deep-linking was the previous attempt and it does not work:
--- PauseMenuceptionGoDeeper reaches the map and not the Settings pages, which
--- is why the voice button used to open the map (user, 2026-08-09).
function BR.Pause.openFrontendPlain()
    -- RECONCILED AND STAMPED, for the same reasons the map route is (#207).
    -- This shares `frontendMap` with the map -- one frontend, one flag -- so it
    -- has to share the discipline too: a stale flag must not refuse the
    -- handover, and a map watcher that is still out there must not be able to
    -- write over the settings menu's flags half a second from now.
    --
    -- `mapSeen` stays false for this route on purpose. It is what says "the
    -- game has confirmed OUR map came up", and gameSaysMapUp() answers `true`
    -- while it is false -- so mapFrontendUp() reduces to `frontendMap` here,
    -- which is exactly the behaviour this route already had. The reconciliation
    -- is for the map, which is driven to a page and watched; this one hands GTA
    -- the whole screen and polls, and must not second-guess it.
    if mapFrontendUp() then return end
    mapGen      = mapGen + 1
    local gen   = mapGen
    frontendMap = true
    mapSeen     = false
    TriggerEvent('br:map:frontend', true)
    -- BEFORE the menu is raised, not after. The scaleform can be on screen on
    -- the very next frame, and a page still drawing on that frame is the
    -- overlay the player reports.
    announceFrontend(true)

    Citizen.CreateThread(function()
        ActivateFrontendMenu(GetHashKey('FE_MENU_VERSION_SP_PAUSE'), false, -1)

        local deadline = GetGameTimer() + 5000
        -- Normalised, like every other BOOL native in this file: `0` is truthy
        -- in Lua, so an unnormalised `not IsPauseMenuActive()` on a build that
        -- answers with numbers would fall straight through this wait and then
        -- decide the menu was up.
        while (not yes(IsPauseMenuActive()) or yes(IsPauseMenuRestarting()))
              and GetGameTimer() < deadline do
            Citizen.Wait(0)
        end
        if gen ~= mapGen then return end
        if not yes(IsPauseMenuActive()) then
            print('[br_ui] settings: pause menu never became active; giving up')
            frontendMap = false
            TriggerEvent('br:map:frontend', false)
            -- GIVING UP STILL HANDS THE MENU BACK. The focus stack was
            -- emptied before this thread started, so returning quietly here
            -- would leave the player in a lobby they cannot see or click --
            -- a worse outcome than the frontend simply not opening.
            --
            -- AND THE PAGE IS TOLD IT MAY DRAW AGAIN, first. We hid it for a
            -- frontend that never arrived; without this the player is left
            -- staring at the world with no interface at all and no way to get
            -- it back short of reconnecting -- strictly worse than the bug
            -- this whole path exists to fix.
            announceFrontend(false)
            TriggerEvent('br:ui:frontendClosed')
            return
        end

        -- THEIR MENU, THEIR PACE. Ten minutes is not a timeout anybody will
        -- reach adjusting a microphone; it exists so a frontend that somehow
        -- never reports closing cannot leave our suppression off forever.
        local until_ = GetGameTimer() + 600000
        while yes(IsPauseMenuActive()) and GetGameTimer() < until_ do
            Citizen.Wait(100)
        end

        -- Superseded raises write nothing (#207). Ten minutes is a long time
        -- for this thread to be holding a claim on flags somebody else is now
        -- using.
        if gen ~= mapGen then return end
        frontendMap = false
        mapSeen     = false
        TriggerEvent('br:map:frontend', false)
        -- THE PAGE DRAWS AGAIN BEFORE IT IS CLICKABLE AGAIN, in that order.
        -- The loop above only ends when the frontend is genuinely gone, by
        -- whatever route the player took out of it -- Escape, the menu's own
        -- back button, a controller -- so this is the one place that knows the
        -- screen is ours again, and it is reached no matter which of those it
        -- was.
        announceFrontend(false)
        -- AND THE PLAYER GETS THEIR MENU BACK. We emptied the focus stack to
        -- get out of the frontend's way; leaving it empty would drop them in
        -- the lobby with no cursor and nothing to click. br_core decides what
        -- to restore, because it is the one that knows where they are.
        TriggerEvent('br:ui:frontendClosed')
    end)
end

-- ===========================================================================
-- OPENING AND CLOSING THE MAP, IN ONE PLACE EACH (#199)
-- ===========================================================================
--
-- These two are lifted verbatim out of the Map card's PAUSE_ACTION branch and
-- out of the `br:ui:pauseToggle` handler, and they are lifted for one reason:
-- there is now a KEY that does the same thing, and the owner's instruction was
-- "same function as our map button in the pause menu ... find what that button
-- calls and call it".
--
-- A second copy would have been the easy version and the wrong one. `brmapmode`
-- switches between three routes at runtime and each of them leaves a DIFFERENT
-- flag behind for the closer to find; a key that opened the map by its own road
-- would be a fourth door onto the same three states, which is the shape #138
-- names ("PUBLIC BECAUSE THERE WAS A FOURTH DOOR") and the shape #122 came back
-- through. One opener, one closer, and the routes stay a question this file
-- answers on its own.

--- Open the full-screen map, by whichever route `brmapmode` currently selects.
---
--- THREE ROUTES, SWITCHABLE, BECAUSE THIS IS A QUESTION THE GAME ANSWERS AND
--- NOT ONE THE DOCUMENTATION DOES.
---
---   bigmap      SetBigmapActive -- the radar, expanded
---   frontend    the real pause menu, driven to its map page (the default)
---   fullscreen  PauseToggleFullscreenMap alone
---
--- OUR MENU COMES DOWN FIRST IN EVERY BRANCH, and unconditionally: BR.Pause
--- .close() pops focus for a screen that may not hold it, which is safe by
--- design and is what makes this callable from a keypress with no menu open.
function BR.Pause.openMap()
    if BR.Pause.mapMode == 'frontend' then
        BR.Pause.close()
        BR.Pause.openFrontendMap()
        return
    end

    if BR.Pause.mapMode == 'fullscreen' then
        -- PAUSE_TOGGLE_FULLSCREEN_MAP (0x2DE6C5E2E996F178, "toggles pause
        -- menu map rendering") on its own, on the chance it draws the map
        -- with no frontend at all. pcall because a native this obscure is
        -- exactly the kind that is missing from a build, and a missing one
        -- must not take the pause menu down with it.
        BR.Pause.close()
        local ok, err = pcall(PauseToggleFullscreenMap, true)
        print(('[br_ui] map: PauseToggleFullscreenMap(true) %s')
            :format(ok and 'ok' or ('FAILED ' .. tostring(err))))
        BR.Pause.fullscreenMap = true
        return
    end

    -- THE BIG MINIMAP, NOT GTA'S PAUSE MENU.
    --
    -- The question was whether the rest of the pause menu's scaleforms
    -- can be suppressed when we only want the map. They cannot -- the
    -- tabs are part of that scaleform and ActivateFrontendMenu's
    -- component argument only chooses which one is FOCUSED (-1 is
    -- already the map).
    --
    -- SET_BIGMAP_ACTIVE avoids the question entirely: it expands the
    -- minimap to the full-screen map GTA Online uses, drawn over live
    -- gameplay, with no frontend, no tabs and no pause. It is what every
    -- resource that wants "just the map" actually uses, and it is better
    -- than what was asked for -- the world keeps running underneath.
    --
    -- IT EXPANDS THE MINIMAP, which is the catch: br_core turns the radar
    -- off in the lobby, so calling this from here worked exactly as
    -- documented on a minimap that was not being drawn, and the button
    -- looked dead (user, 2026-08-09). br_core owns the radar, so br_core
    -- owns this -- one place decides whether the map is on screen.
    BR.Pause.close()
    TriggerEvent('br:map:big', true)
    BR.Pause.bigmap = true
    print('[br_ui] map: big map on')
end

--- Take down whatever the map put up, whichever route put it there.
--- @return boolean  true if there was a map to take down
---
--- WHATEVER THE MAP KEY TURNED ON, THE MAP KEY TURNS OFF. A player should never
--- have to know WHICH native drew the thing in front of them to get rid of it,
--- and with `brmapmode` switchable at runtime they could not find out anyway.
---
--- THE FRONTEND IS CLEARED, NOT CLOSED, and that asymmetry is deliberate: its
--- watcher thread owns the teardown and reads this flag every frame, so
--- lowering it here is how anything asks the map to close. Two callers racing
--- SetFrontendActive is how a frontend gets left up with nothing listening.
---
--- THE RETURN VALUE IS THE WHOLE INTERFACE. Both callers -- the pause key and
--- the map key -- need to know whether they consumed the press on a map or
--- should carry on to what they would otherwise have done, and neither of them
--- can read these three flags for itself.
function BR.Pause.closeMap()
    if BR.Pause.bigmap then
        TriggerEvent('br:map:big', false)
        BR.Pause.bigmap = false
        return true
    end
    if frontendMap then
        -- THE ONE LINE THE REPORT IS ABOUT (#207).
        --
        -- `frontendMap` on its own answers "we asked for a map", and a press
        -- was consumed on that answer alone. Dismiss the map the way the owner
        -- did -- right-click, which is the frontend's own BACK, or Escape,
        -- which is its own cancel -- and the menu goes away without the flag
        -- coming down with it. Every press after that read as "close": it
        -- lowered a flag nobody was watching, returned true, and the caller
        -- went home. No map, no error, nothing to see.
        --
        -- Asking the game instead turns that press back into an open, because
        -- when the game says there is no frontend on screen there is nothing
        -- here to close and this is not our press to take.
        if mapFrontendUp() then
            -- Cleared and NOT torn down here: the watcher owns the teardown
            -- and reads this flag every frame, so lowering it is how anything
            -- asks the map to close. Two callers racing SetFrontendActive is
            -- how a frontend gets left up with nothing listening.
            frontendMap = false
            return true
        end
        retireMap()
        return false
    end
    if BR.Pause.fullscreenMap then
        pcall(PauseToggleFullscreenMap, false)
        BR.Pause.fullscreenMap = false
        return true
    end
    return false
end

-- THE MAP HAS A KEY OF ITS OWN NOW (#199), and this is the whole of its far
-- end. br_core/client/keybinds.lua registers the binding (M by default,
-- rebindable, in the same table every other key is in), decides which player
-- states may open a map at all, and fires this; the routing decision above
-- stays here, where the three routes and their flags live.
--
-- ONE PRESS, EITHER DIRECTION. See closeMap's note: a key that could only open
-- would leave the player holding a full-screen map and needing to be told about
-- a different key to dismiss it -- and in the default `frontend` route that key
-- is Escape, the one this menu exists to take over.
AddEventHandler('br:ui:mapToggle', function()
    if BR.Pause.closeMap() then return end
    BR.Pause.openMap()
end)

RegisterNUICallback(BR.NuiCb.PAUSE_FOCUS, function(data, cb)
    if data and data.open then BR.Pause.open(data.tab) else BR.Pause.close() end
    cb({ ok = true })
end)

-- THE WAY TO THE SETTINGS WE CANNOT WRITE.
--
-- Microphone device, sensitivity, push-to-talk and the rest are client
-- settings; no script can read or write them. Removing the button left
-- players with no route to their own microphone at all (owner, 2026-08-09),
-- which is worse than a handover that needs one extra click.
--
-- Our screens come down first: the frontend is a scaleform, so a menu left
-- open underneath would hold the cursor with nothing able to draw over it.
--- Hand the whole screen to GTA's own menu.
---
--- EVERY SCREEN COMES DOWN, not just the one that asked.
---
--- Closing the settings page and the pause menu was not enough: in the LOBBY
--- the focus stack still has `lobby` underneath, so the lobby menu stayed up
--- and drew over GTA's frontend (owner, 2026-08-09). A scaleform cannot be
--- covered by NUI and NUI cannot be covered by it, so anything of ours left on
--- screen is simply on top of the menu the player was sent to use.
---
--- clearFocus empties the stack rather than popping one screen, which is the
--- same thing ESC-in-the-lobby did when it raised the engine's menu. br_core
--- hands focus back when the frontend closes.
---
--- AND THAT STILL WAS NOT ENOUGH, which is #122 (owner, 2026-08-16). Focus is
--- about the CURSOR. The lobby is drawn from match state, not from the focus
--- stack, so emptying the stack took the mouse away and left the lobby
--- painted over the settings screen -- the same report a second time, for a
--- reason the first fix could not have addressed. openFrontendPlain announces
--- the frontend to the page, which is what actually stops it drawing.
---
--- THE ORDER MATTERS AND IT IS THIS WAY ROUND ON PURPOSE. Every pop above
--- emits a focus envelope, and popping `pause`/`settings` in the lobby leaves
--- `lobby` on top -- so the page hears FOCUS{screen='lobby'} in the middle of
--- this function. The announcement therefore goes LAST, after the stack has
--- finished collapsing, or the page would be told to draw again immediately
--- after being told not to.
--- PUBLIC BECAUSE THERE WAS A FOURTH DOOR (#138). This was local, so
--- settings.lua's "GTA key bindings" button could not reach it and grew its own
--- handover -- `clearFocus` then `br:ui:pauseRequest`, which raises the frontend
--- from br_core and announces nothing. That is #122 reproduced exactly, on the
--- one route that was never converted, and reachable from the lobby where it is
--- the only place the fault shows.
---
--- Every route into the engine's frontend goes through this function now, so
--- there is one place that knows the order and one place to be wrong.
function BR.Pause.handOverToFrontend()
    BR.Pause.close()
    TriggerEvent('br:ui:closeSettings')
    TriggerEvent('br:ui:clearFocus')
    BR.Pause.openFrontendPlain()
end
local handOverToFrontend = BR.Pause.handOverToFrontend

RegisterNUICallback(BR.NuiCb.VOICE_SETTINGS, function(_, cb)
    handOverToFrontend()
    cb({ ok = true })
end)

-- THE SAME DOOR, LABELLED FOR THE PEOPLE WHO WANT GRAPHICS.
--
-- Mechanically identical to the voice handover, and deliberately not merged
-- with it: the only route to the engine's settings used to be a button
-- reading "Microphone & push-to-talk", buried in the Voice section, so a
-- player looking for resolution, texture quality or FOV had nothing to find
-- (owner, 2026-08-16). Two names for one mechanism costs four lines; a player
-- who cannot change their resolution costs the session.
RegisterNUICallback(BR.NuiCb.GAME_SETTINGS, function(_, cb)
    handOverToFrontend()
    cb({ ok = true })
end)

-- THE MANUAL IS A PAGE OF ITS OWN IN THE LOBBY, and a tab inside the pause
-- menu once a match is running. Same component either way; only the frame
-- around it differs.
RegisterNUICallback(BR.NuiCb.HELP_FOCUS, function(data, cb)
    if data and data.open then
        TriggerEvent('br:ui:pushFocus', 'help')
    else
        TriggerEvent('br:ui:popFocus', 'help')
    end
    cb({ ok = true })
end)

-- THE ADMIN CONSOLE IS A SCREEN, NOT A TAB BODY (#23).
--
-- The owner's call: "the one in /help is much larger and would be most
-- appropriate size-wise for Ringmaster". A board of bans, incidents and a player
-- table does not fit the pause menu's tab well, and the difference between the
-- two Help frames is not the `inline` prop -- both are non-inline -- it is the
-- CONTAINER. One sits inside this menu and inherits its width; the other sits
-- inside <Page>, which is the full-screen treatment.
--
-- So the Admin tab is a DOOR. Pressing it pushes a focus screen of its own, the
-- same way the lobby's Help button does, and the console gets the whole screen.
-- Nothing new was needed to make that work: BR.FocusResolve gives any screen not
-- named in BR.FocusKeepsInput the cursor and takes game input, which is exactly
-- what a console wants, so there is no fourth notion of who owns the keyboard.
--
-- ═══ CLOSING PUTS THE MENU BACK, AND THE ORDER IS THE WHOLE OF IT ═══
--
-- Pushing `admin` fires br:ui:focusChanged('admin'), and the handler at the
-- bottom of this file answers that by closing the pause menu -- which POPS
-- `pause` off the stack. Correct, and it means a plain popFocus('admin') on the
-- way out would empty the stack entirely: focus 'none', no cursor, no menu, and
-- the player standing in the world wondering what happened. That is the leaked-
-- focus failure this file's header calls the worst non-crash bug the UI can
-- produce.
--
-- So the menu is re-opened FIRST and `admin` popped SECOND. Push-then-pop moves
-- the top of the stack straight from 'admin' to 'pause' in one transition;
-- pop-then-push would pass through 'none' on the way, and the page would blank
-- for a frame between two screens that are both meant to be up.
RegisterNUICallback(BR.NuiCb.ADMIN_FOCUS, function(data, cb)
    if data and data.open then
        TriggerEvent('br:ui:pushFocus', 'admin')
    elseif data and data.all then
        -- ESCAPE FROM INSIDE THE CONSOLE, WHICH IS NOT THE BACK BUTTON.
        --
        -- Back steps up one screen and lands on the pause menu, because that is
        -- where the Admin tab was pressed. Escape is the other exit: the owner
        -- asked for "one button - overlay gone", and a player who wants out of
        -- a menu does not want a different menu.
        --
        -- POP FIRST, THEN CLOSE, and that order is the opposite of the branch
        -- below on purpose. That one re-opens the pause menu BEFORE popping so
        -- the page never blanks between two screens that are both meant to be
        -- up. Here nothing is meant to be up afterwards, so there is no gap to
        -- cover -- and re-opening the menu on the way out would be a frame of
        -- the very thing being dismissed.
        TriggerEvent('br:ui:popFocus', 'admin')
        BR.Pause.close()
    else
        BR.Pause.open()
        TriggerEvent('br:ui:popFocus', 'admin')
    end
    cb({ ok = true })
end)

-- "THE CONSOLE SAYS I AM SIGNED OUT." Forwarded to the server and nowhere else.
--
-- NO ARGUMENTS ARE CARRIED, and that is the point rather than an economy. The
-- server reads everything it needs from `source`; a payload naming a Discord id
-- would be a payload a modified client could use to open a session as somebody
-- else. The page has already checked that the message came from the console's
-- exact origin before calling this, but that check protects the PAGE -- this
-- hop is protected by having nothing to forge.
RegisterNUICallback(BR.NuiCb.ADMIN_MINT, function(_, cb)
    TriggerServerEvent(BR.Net.ADMIN_MINT)
    cb({ ok = true })
end)

-- THE SERVER'S ANSWER, FORWARDED TO THE PAGE UNREAD.
--
-- This handler deliberately does not look inside the payload. The console's
-- address is in there, and br_lib/config/overrides.lua's whole contract is that
-- an overridable key is read on the SERVER and nowhere else -- tools/verify.sh
-- greps every br_*/client/*.lua for the key names to make the alternative
-- impossible to introduce. Forwarding the table whole means this file never
-- learns a name it is not allowed to know, and there is exactly one reader of
-- the convar in the project.
--
-- The type guard is the only inspection: a nil payload would cross the bridge as
-- an empty envelope and leave the page unable to tell "no tab for you" from "the
-- message was malformed".
RegisterNetEvent(BR.Net.ADMIN_STATE)
AddEventHandler(BR.Net.ADMIN_STATE, function(payload)
    if type(payload) ~= 'table' then return end
    TriggerEvent('br:ui:sendLocal', BR.Nui.ADMIN, payload)
end)

-- WHERE OUR DISCORD IS, FORWARDED TO THE PAGE UNREAD. Same shape as the handler
-- above and for the same reason, which is why it is written directly beside it.
--
-- This one carries no permission -- an invite is public and every player gets
-- the envelope -- but the reason for not opening it is unchanged and is the
-- stronger of the two. The value comes from an OVERRIDABLE KEY, and
-- br_lib/config/overrides.lua's contract is that such a key is read on the
-- server and nowhere else; tools/verify.sh greps every br_*/client/*.lua for the
-- key names to keep it that way, and it filters only whole-line comments -- so
-- even naming the key in a note at the end of this line would fail the build.
-- Forwarding the table whole means this file never learns a name it is not
-- allowed to say, and br_core/server/community.lua stays the one reader.
--
-- The type guard is the only inspection, and note what it does NOT decide: an
-- empty table is a perfectly good payload here, meaning "this server publishes
-- no Discord", and it has to reach the page so a card already on screen comes
-- down. Only a nil -- which would cross the bridge as an empty envelope and
-- leave the page unable to tell that from a malformed message -- is dropped.
RegisterNetEvent(BR.Net.COMMUNITY)
AddEventHandler(BR.Net.COMMUNITY, function(payload)
    if type(payload) ~= 'table' then return end
    TriggerEvent('br:ui:sendLocal', BR.Nui.COMMUNITY, payload)
end)

--- The verbs on the front page.
---
--- EVERY ONE OF THEM IS br_core's TO PERFORM, not ours: leaving a match is a
--- server round trip, leaving a squad is a roster change, and disconnecting is
--- a native br_core already wraps. br_ui owns the page and forwards the verb,
--- which is the same split the locker and the inventory use.
RegisterNUICallback(BR.NuiCb.PAUSE_ACTION, function(data, cb)
    local action = tostring(data and data.action or '')

    if action == 'map' then
        BR.Pause.openMap()
        cb({ ok = true })
        return
    end

    if action == 'server' then
        -- The client's own `disconnect` is a restricted console command and
        -- comes back "Access denied" (user, 2026-08-09). The server drops us.
        BR.Pause.close()
        -- THE CURTAIN, NOT A SECOND EXIT PATH. Disconnecting is a server round
        -- trip and DropPlayer lands whenever it lands -- so without this the
        -- player presses Disconnect and is returned to the lobby they were
        -- trying to leave, for as long as the trip takes, with nothing saying
        -- the press registered. The interstitial that already covers leaving a
        -- match covers this for the same reason: something irreversible is
        -- under way and there is nothing to look at while it happens.
        TriggerEvent('br:ui:sendLocal', BR.Nui.LEAVING,
                     { show = true, kind = 'disconnecting' })
        TriggerServerEvent(BR.Net.LEAVE_SERVER)

        -- AND A WAY BACK, WHICH THIS RAISE HAS NEVER HAD.
        --
        -- Every other curtain in the game is raised through br_core's
        -- BR.Spawn.curtain, which records that one is wanted and runs a watchdog
        -- that lifts an abandoned one after 15 seconds. This one is raised
        -- straight at the page, from the other resource, so none of that applies
        -- to it: if the drop never arrives -- br_core stopped, the event lost,
        -- an error in the server handler -- the player is left on black with
        -- nothing anywhere that will ever take it away.
        --
        -- That was survivable while the curtain passed clicks through and they
        -- could at least blind-click their way back to the lobby. It stopped
        -- being survivable today: the curtain swallows clicks now, so a stuck
        -- one takes the whole interface with it. Ten seconds is far longer than
        -- any drop takes and this thread simply dies with the client on the
        -- normal path, so the only way it can ever fire is the failure it is for.
        Citizen.SetTimeout(10000, function()
            print('[br_ui] disconnect never landed -- lifting the curtain')
            TriggerEvent('br:ui:sendLocal', BR.Nui.LEAVING, { show = false })
        end)

        cb({ ok = true })
        return
    end

    if action == 'lobby' then
        -- THE MENU STAYS UP, AND THAT IS THE FIX (#124).
        --
        -- Everything else on this screen closes the menu on the press, because
        -- everything else leaves the player where they are. Leaving a match does
        -- not: it is a covered transition, and closing here would uncover it.
        --
        -- What that looked like, and what the owner still had after the rest of
        -- #124 landed (2026-08-16): "leaving mid-match via the pause menu still
        -- has the old jarring affect." Press the button, the menu snaps away,
        -- the HUD and the world you just quit come back for the length of the
        -- curtain's fade, and your character freezes and your car vanishes in
        -- front of you while it darkens.
        --
        -- So the press does one thing only: ask. br_core raises the curtain,
        -- waits for this page to report itself black, and closes this menu
        -- through br:ui:pauseClose once nothing can be seen. The menu the player
        -- clicked is the last thing on screen and it fades out under the
        -- curtain, which is exactly what the lobby menu does on the ready-up
        -- path the owner has already passed.
        TriggerEvent('br:ui:pauseAction', action)
        cb({ ok = true })
        return
    end

    -- 'squad' is gameplay: br_core decides what it means. It changes nothing
    -- about the round in progress, so there is nothing to cover and the menu
    -- closes on the press like the rest of them.
    BR.Pause.close()
    TriggerEvent('br:ui:pauseAction', action)
    cb({ ok = true })
end)

-- ---------------------------------------------------------------- keybind ---

-- THE KEY LIVES IN br_core, with every other key in the project.
--
-- It was registered here with an empty default and in no binding table at all,
-- which meant the pause menu had no key AND no row in the settings screen to
-- give it one -- there was literally no way to open it (user, 2026-08-09).
-- br_core/client/keybinds.lua registers it and fires this; TriggerEvent
-- crosses resources, which is the same hop br_core already uses to reach the
-- interface.
--
-- AND IT IS NOT THE ONLY ROUTE IN, WHICH IS #83.
--
-- "There is no way to leave the server from within the lobby pause menu"
-- (owner, 2026-08-16). The row was there; the MENU was not, because in the
-- lobby neither of the two key routes this file can be reached by exists:
--
--   * the engine's own binding (F1, RegisterKeyMapping) needs the game to
--     receive the key, and in the lobby NUI holds the cursor with keep-input
--     off, so the game receives nothing at all. On top of that br_core's raw
--     layer gates every RegisterKeyMapping handler off while it is running, so
--     F1 is inert on any client that HAS the raw layer;
--   * and the raw layer itself is registered on Escape for this command -- but
--     br_core's own frontend suppressor says out loud that "the raw layer
--     cannot see Escape while CEF holds the cursor" (client/natives.lua), and
--     the lobby is precisely the screen that holds it.
--
-- So the only thing that reliably receives a keypress in the lobby is the PAGE,
-- which has DOM focus by definition -- and the page already had an Escape
-- handler there. It used to open our Settings screen; it asks for this menu
-- now, through the PAUSE_FOCUS callback above, and Settings stays reachable as
-- the lobby's own button and as a tab inside this menu.
--
-- Nothing here needed a new focus owner or a second SetNuiFocus caller to make
-- that work, which is deliberate: the lesson of #122 and #124 is that the lobby
-- is drawn from MATCH STATE and not from focus, so anything phrased as "release
-- focus and our screens go away" is false there. This is a key routing change
-- and nothing more.
AddEventHandler('br:ui:pauseToggle', function()
    -- See `lastToggle` at the top of this file: the page and the raw key layer
    -- can both see the same physical Escape, in either order, and a press
    -- inside this window is treated as the one press it was.
    local now = GetGameTimer()
    if now - lastToggle < 220 then return end
    lastToggle = now

    -- THE MAP IS A STATE THE SAME KEY GETS YOU OUT OF. It is drawn over live
    -- gameplay with no cursor and no menu, so without this the only way back
    -- would be a key the player has not been told about. All three routes and
    -- their flags live in BR.Pause.closeMap, which the map key also calls --
    -- see the note above it for why there is one closer and not two.
    if BR.Pause.closeMap() then return end
    if open then BR.Pause.close() else BR.Pause.open() end
end)

-- And a console door, so it can be opened without a keyboard binding at all --
-- which is exactly what you need when the question is "does the key work".
RegisterCommand('brpause', function()
    if open then BR.Pause.close() else BR.Pause.open() end
    print(('[br_ui] pause menu %s'):format(open and 'open' or 'closed'))
end, false)

-- Which route the Map button takes. 'bigmap' draws GTA's full map over live
-- gameplay with no frontend at all; 'frontend' opens the real pause menu and
-- drives it to its map page; 'fullscreen' is PauseToggleFullscreenMap on its
-- own. Switchable so the three can be compared in game rather than argued
-- about from documentation.
--
-- FRONTEND IS THE DEFAULT, on the owner's call after seeing all three in game
-- (2026-08-09): "frontend is exactly what I want". And the thing I had wrong
-- about it is worth writing down rather than leaving in three commit messages
-- -- GoDeeper + TheKick lands on the map's OWN FULLSCREEN VIEW, the one a
-- player would otherwise have to select for themselves, so the tabs are not
-- sitting above it after all. It is not navigation-with-chrome; it is the
-- view. bigmap and fullscreen stay for comparison.
BR.Pause.mapMode = 'frontend'
BR.Pause.mapPage = nil

RegisterCommand('brmapmode', function(_, args)
    local mode = tostring(args[1] or '')
    if mode == 'debug' then
        BR.Pause.mapDebug = not BR.Pause.mapDebug
        print(('[br_ui] map debug: %s'):format(tostring(BR.Pause.mapDebug)))
        return
    end
    if mode == 'frontend' or mode == 'bigmap' or mode == 'fullscreen' then
        BR.Pause.mapMode = mode
        BR.Pause.mapPage = tonumber(args[2])
        print(('[br_ui] map mode: %s%s'):format(mode,
            BR.Pause.mapPage and (' page ' .. BR.Pause.mapPage) or ''))
        return
    end
    print('=== map mode ===')
    print(('  mode: %s'):format(tostring(BR.Pause.mapMode)))
    print(('  page: %s'):format(tostring(BR.Pause.mapPage)))
    print('  bigmap     -- SetBigmapActive: full map over live gameplay, no frontend')
    print('  frontend   -- ActivateFrontendMenu + GoDeeper + TheKick (cfx recipe)')
    print('  fullscreen -- PauseToggleFullscreenMap alone, no frontend at all')
    print(('  debug: %s   (brmapmode debug -- print which input closes it)')
        :format(tostring(BR.Pause.mapDebug == true)))
    -- WHAT THE FLAG SAYS AND WHAT THE GAME SAYS, SIDE BY SIDE (#207). The two
    -- disagreeing is the whole bug, and "the map key does nothing" is not a
    -- report anybody can act on without seeing which of them is wrong.
    print(('  raise: %s gen %d   flag %s / game %s   -> map up: %s')
        :format(BR.Pause.map and BR.Pause.map.phase or 'none',
                mapGen, tostring(frontendMap), tostring(yes(IsPauseMenuActive())),
                tostring(mapFrontendUp())))
    print('  usage: brmapmode bigmap | fullscreen | frontend [pageId]')
end, false)

-- The page can be closed from under us: a match ending, a br_core restart,
-- the focus watchdog. Watching the focus envelope keeps `open` honest instead
-- of letting it drift into a state where the keybind toggles the wrong way.
-- THE PAGE CAN BE COVERED FROM UNDER US -- a match ending, the summary
-- screen, a br_core restart, the watchdog -- and this used to answer by
-- flipping `open` to false and leaving the STACK ENTRY in place.
--
-- That is the bug. `pause` sits under whatever covered it, is never popped,
-- and resurfaces the moment that thing pops: the player leaves a match
-- through this menu, readies up, and the pause menu comes back with the
-- cursor captured and a close key that now toggles the wrong way, because
-- `open` says closed while the screen says otherwise (user, 2026-08-09).
--
-- Losing the top of the stack means we are not up any more, so let go of it.
AddEventHandler('br:ui:focusChanged', function(screen)
    if screen ~= 'pause' and open then BR.Pause.close() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    open = false
    -- A big map left active would survive this resource and there would be
    -- nothing left listening for the key that closes it.
    if BR.Pause.bigmap then
        TriggerEvent('br:map:big', false)
        BR.Pause.bigmap = false
    end
    -- Same for the frontend: a pause menu we opened and then stopped listening
    -- for would be a menu the player cannot leave by any route we told them
    -- about. The thread is going away with the resource, so close it here.
    if frontendMap then
        -- The generation moves too, so any watcher still in flight stops
        -- writing (#207). No announceFrontend here, unlike every other exit:
        -- the page is going away with this resource and the bridge that would
        -- carry the message is in it.
        mapGen       = mapGen + 1
        frontendMap  = false
        mapSeen      = false
        mapLastUp    = 0
        BR.Pause.map = nil
        SetFrontendActive(false)
        TriggerEvent('br:map:frontend', false)
    end
    if BR.Pause.fullscreenMap then
        pcall(PauseToggleFullscreenMap, false)
        BR.Pause.fullscreenMap = false
    end
end)

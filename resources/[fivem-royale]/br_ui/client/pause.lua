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
local frontendMap = false

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

--- @param page integer|nil
function BR.Pause.openFrontendMap(page)
    if frontendMap then return end
    BR.Pause.pendingPage = page
    frontendMap = true
    -- br_core suppresses GTA's frontend every frame now that Escape is ours.
    -- This is the one time we WANT it, so it has to know to stand down --
    -- otherwise the map opens into a menu that is being closed underneath it.
    TriggerEvent('br:map:frontend', true)

    Citizen.CreateThread(function()
        -- FE_MENU_VERSION_MP_PAUSE, not SP: the multiplayer pause menu is the
        -- one the map is the point of.
        ActivateFrontendMenu(GetHashKey('FE_MENU_VERSION_MP_PAUSE'), false, -1)

        -- The wait is the fix, but it cannot be unbounded: if the menu never
        -- comes up -- another resource holding the frontend, a state that
        -- refuses it -- this thread would spin at Wait(0) for the rest of the
        -- session, and a busy loop nobody can see is the worst kind.
        local deadline = GetGameTimer() + 5000
        while (not IsPauseMenuActive() or IsPauseMenuRestarting())
              and GetGameTimer() < deadline do
            Citizen.Wait(0)
        end
        if not IsPauseMenuActive() then
            print('[br_ui] map: pause menu never became active; giving up')
            frontendMap = false
            TriggerEvent('br:map:frontend', false)
            return
        end

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
        local EXITS = { 202, 200, 199, 177, 194, 195, 25 }
        local function wantsOut()
            for _, c in ipairs(EXITS) do
                if IsControlJustPressed(2, c) or IsDisabledControlJustPressed(2, c) then
                    if BR.Pause.mapDebug then
                        print(('[br_ui] map: exit control %d'):format(c))
                    end
                    return true
                end
            end
            -- Escape, raw. IsRawKeyDown reports the HELD state, so this fires
            -- on the frame it goes down and every frame after -- which is
            -- fine, because the first one already leaves.
            local ok, down = pcall(IsRawKeyDown, 0x1B)
            if ok and down then
                if BR.Pause.mapDebug then print('[br_ui] map: exit raw ESC') end
                return true
            end
            return false
        end

        while frontendMap and not wantsOut() do
            Citizen.Wait(0)
        end

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

        -- AND IT IS RE-ASSERTED, because one call is not reliably enough:
        -- the same press that got us here is still being handled by the
        -- scaleform, which can bring the menu straight back on the next
        -- frame. Half a second of insisting costs nothing and removes the
        -- whole class of "it flickered back".
        local until_ = GetGameTimer() + 500
        while GetGameTimer() < until_ do
            if IsPauseMenuActive() then SetFrontendActive(false) end
            Citizen.Wait(0)
        end

        frontendMap = false
        -- Suppression resumes only once the frontend is genuinely down, so
        -- there is no frame in which both are trying to own it.
        TriggerEvent('br:map:frontend', false)
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
    if frontendMap then return end
    frontendMap = true
    TriggerEvent('br:map:frontend', true)
    -- BEFORE the menu is raised, not after. The scaleform can be on screen on
    -- the very next frame, and a page still drawing on that frame is the
    -- overlay the player reports.
    announceFrontend(true)

    Citizen.CreateThread(function()
        ActivateFrontendMenu(GetHashKey('FE_MENU_VERSION_SP_PAUSE'), false, -1)

        local deadline = GetGameTimer() + 5000
        while (not IsPauseMenuActive() or IsPauseMenuRestarting())
              and GetGameTimer() < deadline do
            Citizen.Wait(0)
        end
        if not IsPauseMenuActive() then
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
        while IsPauseMenuActive() and GetGameTimer() < until_ do
            Citizen.Wait(100)
        end

        frontendMap = false
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
local function handOverToFrontend()
    BR.Pause.close()
    TriggerEvent('br:ui:closeSettings')
    TriggerEvent('br:ui:clearFocus')
    BR.Pause.openFrontendPlain()
end

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

--- The verbs on the front page.
---
--- EVERY ONE OF THEM IS br_core's TO PERFORM, not ours: leaving a match is a
--- server round trip, leaving a squad is a roster change, and disconnecting is
--- a native br_core already wraps. br_ui owns the page and forwards the verb,
--- which is the same split the locker and the inventory use.
RegisterNUICallback(BR.NuiCb.PAUSE_ACTION, function(data, cb)
    local action = tostring(data and data.action or '')

    if action == 'map' then
        -- THREE ROUTES, SWITCHABLE, BECAUSE THIS IS A QUESTION THE GAME
        -- ANSWERS AND NOT ONE THE DOCUMENTATION DOES.
        --
        --   bigmap      SetBigmapActive -- the radar, expanded (default)
        --   frontend    the real pause menu, driven to its map page
        --   fullscreen  PauseToggleFullscreenMap alone
        --
        -- `brmapmode` switches between them in game.
        if BR.Pause.mapMode == 'frontend' then
            BR.Pause.close()
            BR.Pause.openFrontendMap()
            cb({ ok = true })
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
            cb({ ok = true })
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

    -- THE BIG MAP IS A STATE THE SAME KEY GETS YOU OUT OF. It is drawn over
    -- live gameplay with no cursor and no menu, so without this the only way
    -- back would be a key the player has not been told about.
    if BR.Pause.bigmap then
        TriggerEvent('br:map:big', false)
        BR.Pause.bigmap = false
        return
    end
    -- Same rule for the frontend routes: whatever the map key turned on, the
    -- map key turns off. A player should never have to know WHICH native drew
    -- the thing in front of them to get rid of it.
    if frontendMap then
        -- Cleared, not closed here: the watcher thread owns the teardown, and
        -- two callers racing SetFrontendActive is how a frontend gets left up
        -- with nothing listening.
        frontendMap = false
        return
    end
    if BR.Pause.fullscreenMap then
        pcall(PauseToggleFullscreenMap, false)
        BR.Pause.fullscreenMap = false
        return
    end
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
        frontendMap = false
        SetFrontendActive(false)
        TriggerEvent('br:map:frontend', false)
    end
    if BR.Pause.fullscreenMap then
        pcall(PauseToggleFullscreenMap, false)
        BR.Pause.fullscreenMap = false
    end
end)

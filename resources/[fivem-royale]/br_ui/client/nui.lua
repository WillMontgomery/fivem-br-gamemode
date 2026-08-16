-- The NUI bridge.
--
-- This file is the ONLY place in the project that calls SetNuiFocus or
-- SendNUIMessage. Everything else asks it to.
--
-- Focus is the dangerous part. A leaked focus means the player cannot move,
-- cannot shoot, and cannot recover without reconnecting -- it is the single
-- worst non-crash bug this UI can produce. The defences, in order:
--
--   1. One owner. Only this file touches SetNuiFocus.
--   2. A focus STACK, not a boolean. Two screens opening and closing out of
--      order cannot leave focus half-held.
--   3. A watchdog. If focus is held with nothing on the stack, it is released.
--   4. Release on resource stop, so a reload never strands the player.

local RES = GetCurrentResourceName()

local seq = 0
local focusStack = {}   -- array of screen names, top of stack owns focus
local focusHeld = false
-- The last screen the PAGE was told about. Compared against the top of the
-- stack, because "is anything focused" and "which screen owns it" are
-- different questions and only the second one drives the interface.
local lastTop = 'none'
local chatChannel = BR.ChatChannel.GLOBAL  -- which channel a chat focus opens in

--- Which tab a pause focus should land on, or nil for "wherever it was".
---
--- Rides the focus envelope like the chat channel above, and for the same
--- reason: opening a menu and choosing a page inside it are one intention,
--- and two envelopes would be a race for which arrives first.
---
--- BR.Pause.open(tab) is the only sender, and nothing passes a tab today --
--- `/help` raises the manual as its own page instead. Kept because it is the
--- mechanism any "take me to X" needs, and because removing a working path to
--- add it back later is the more expensive mistake.
local pauseTab = nil

-- ---------------------------------------------------------------- sending ---

--- Send one envelope to the UI.
---
--- Lua 5.4 distinguishes integer 5 from float 5.0 and they serialise
--- differently through SendNUIMessage. Normalising here, once, is what stops the
--- UI receiving inconsistent types for the same field.
---
--- @param kind string   one of BR.Nui
--- @param data any
local function send(kind, data)
    seq = seq + 1
    SendNUIMessage({
        t = 'br',
        v = BR.NUI_ENVELOPE_VERSION,
        k = kind,
        d = BR.NuiNormalise(data or {}),
        s = seq,
    })
end

--- Public entry point for other resources (br_core) to reach the UI.
--- This is the documented cross-resource hop; it is throttled by the caller,
--- never used per frame.
RegisterNetEvent('br:ui:send')
AddEventHandler('br:ui:send', function(kind, data)
    send(kind, data)
end)

-- Same-client event, for br_core calling directly without a server round trip.
AddEventHandler('br:ui:sendLocal', function(kind, data)
    send(kind, data)
end)

exports('send', send)

-- ----------------------------------------------------------------- focus ---

--- Reconcile the engine and the page with the stack.
---
--- THE DECISION IS BR.FocusResolve, in br_lib, because it is pure and this is
--- the code path that has now been got wrong twice -- see the long note there.
--- This function's only job is to APPLY the answer and to not do redundant
--- work; it must never decide anything itself, or the thing under test stops
--- being the thing that runs.
local function applyFocus()
    local want = BR.FocusResolve(focusStack)

    -- Guarded individually rather than behind one early return. That early
    -- return -- `if want == focusHeld then return end` -- was the bug:
    -- pushing a screen onto an ALREADY-FOCUSED stack left held true before
    -- and after, so the page was never told and the screen never opened.
    if want.held ~= focusHeld then
        focusHeld = want.held
        SetNuiFocus(want.held, want.held)
    end

    -- Follows the TOP, so it is re-evaluated on every change: opening a menu
    -- over the inventory has to take game input back.
    SetNuiFocusKeepInput(want.keepInput)

    if want.screen == lastTop then return end
    lastTop = want.screen

    send(BR.Nui.FOCUS, { screen = want.screen, channel = chatChannel, tab = pauseTab })
    -- ONE SHOT. The tab is a request made at the moment of opening, not a
    -- state -- leaving it set would mean the next focus change also carried
    -- it, and the screen could not tell a fresh `/help` from an echo of the
    -- last one.
    pauseTab = nil
    -- Same fact, for Lua listeners. A screen that tracks its own open/closed
    -- flag has to learn when something ELSE took the stack -- a match ending,
    -- the watchdog, a resource restart -- or its flag drifts and its keybind
    -- starts toggling the wrong way.
    TriggerEvent('br:ui:focusChanged', want.screen)
end

--- Take focus for a screen. Idempotent per screen.
--- @param screen string
local function pushFocus(screen)
    for _, s in ipairs(focusStack) do
        if s == screen then return end
    end
    focusStack[#focusStack + 1] = screen
    applyFocus()
end

--- Release focus for a screen. Safe to call when it does not hold focus.
--- @param screen string
local function popFocus(screen)
    for i = #focusStack, 1, -1 do
        if focusStack[i] == screen then
            table.remove(focusStack, i)
        end
    end
    applyFocus()
end

local function clearFocus()
    focusStack = {}
    applyFocus()
end

exports('pushFocus', pushFocus)
exports('popFocus', popFocus)
exports('clearFocus', clearFocus)

--- Focus diagnostics.
---
--- "I have no mouse" is a symptom with no error attached to it, and the cause is
--- always one of a small number of things -- nothing pushed focus, something
--- popped it, or the push arrived before this resource was listening. Printing
--- the stack answers that in one command instead of by inference.
local FORCEABLE = {
    lobby = true, chat = true, settings = true, locker = true, inventory = true,
}

RegisterCommand('brfocus', function(_, args)
    if args[1] == 'clear' then
        clearFocus()
        print('[br_ui] focus cleared')
        return
    end
    if args[1] == 'pop' and args[2] then
        popFocus(args[2])
        print(('[br_ui] popped: %s'):format(args[2]))
        return
    end
    if args[1] and FORCEABLE[args[1]] then
        pushFocus(args[1])
        print(('[br_ui] forced focus: %s'):format(args[1]))
        return
    end

    print('=== br_ui focus ===')
    print(('  SetNuiFocus held : %s'):format(tostring(focusHeld)))
    print(('  page was told    : %s'):format(tostring(lastTop)))
    print(('  keeps input      : %s'):format(
        tostring(BR.FocusResolve(focusStack).keepInput)))
    print(('  stack depth      : %d'):format(#focusStack))
    for i, s in ipairs(focusStack) do
        print(('    %d. %s%s'):format(i, s, i == #focusStack and '   <- owns focus' or ''))
    end
    if #focusStack == 0 then
        print('    (empty -- no screen has asked for focus)')
    end
    print(('  chat channel     : %s'):format(tostring(chatChannel)))
    print('  usage: brfocus [lobby|chat|settings|locker|inventory]')
    print('         brfocus pop <screen>   |   brfocus clear')
end, false)

AddEventHandler('br:ui:pushFocus', pushFocus)
AddEventHandler('br:ui:popFocus', popFocus)
AddEventHandler('br:ui:clearFocus', clearFocus)

-- Chat is opened by a keybind in br_core, but focus belongs to this resource,
-- so br_core asks rather than calling SetNuiFocus itself. The channel rides
-- along on the focus envelope instead of needing its own message kind.
AddEventHandler('br:ui:pauseTab', function(tab)
    pauseTab = tab
end)

AddEventHandler('br:ui:openChat', function(channel)
    chatChannel = channel or BR.ChatChannel.GLOBAL
    pushFocus('chat')
end)

-- ------------------------------------------------------------- callbacks ---

--- Register a callback that ALWAYS resolves.
---
--- A RegisterNUICallback that fails to call its resolve function leaves the
--- corresponding fetch() in the UI pending forever. That presents as a control
--- that silently stops working, with nothing in any console. Wrapping every
--- callback here means no individual handler can cause it.
---
--- @param name string
--- @param fn function  receives (data); may return a table
local function callback(name, fn)
    RegisterNUICallback(name, function(data, cb)
        local ok, res = pcall(fn, data or {})
        if ok then
            cb(res or { ok = true })
        else
            print(('[br_ui] callback "%s" errored: %s'):format(name, tostring(res)))
            cb({ ok = false, error = tostring(res) })
        end
    end)
end

callback(BR.NuiCb.CLOSE, function()
    clearFocus()
    return { ok = true }
end)

callback(BR.NuiCb.CHAT_FOCUS, function(data)
    if data.open then
        pushFocus('chat')
    else
        popFocus('chat')
    end
    return { ok = true }
end)

callback(BR.NuiCb.CHAT_SEND, function(data)
    local text = tostring(data.text or ''):sub(1, BR.ChatLimits.maxLength)
    popFocus('chat')

    -- SLASH COMMANDS ARE HANDLED HERE AND NOT SENT. The chat box is the one
    -- place a player already types when they want something, and `/help` is
    -- what they will type before they think to look for a menu (user,
    -- 2026-08-09). Anything unrecognised falls through to chat rather than
    -- being swallowed -- a message starting with a slash is usually still a
    -- message, and eating it silently is worse than sending it.
    local cmd = text:match('^/(%a+)')
    if cmd and cmd:lower() == 'help' then
        -- THE PAGE, NOT THE PAUSE MENU. It used to raise the pause menu on
        -- its Help tab, so pressing Back left you looking at a pause menu you
        -- never asked for -- friction on the way out of a screen somebody
        -- opened to answer one question (user, 2026-08-09). Straight to the
        -- manual, and Back goes straight back to the game.
        pushFocus('help')
        return { ok = true }
    end

    if #text > 0 then
        TriggerServerEvent(BR.Net.CHAT_SEND, {
            channel = data.channel or BR.ChatChannel.GLOBAL,
            text    = text,
        })
    end
    return { ok = true }
end)

-- ESC in the lobby: GTA's pause menu cannot open while NUI holds focus, so
-- the page captures the key and asks. The focus drops HERE (this resource
-- owns the stack); raising the actual menu is br_core's call.
-- Menu audio. The UI names a CUE, never a sound set: br_core owns the table
-- and the throttle, so a wrong name is fixed in one place. Native rather than
-- an <audio> tag in the page because engine audio ducks against gunfire.
callback(BR.NuiCb.SFX, function(data)
    if data.cue then TriggerEvent('br:ui:sfx', tostring(data.cue)) end
    return { ok = true }
end)

-- The locker is a lobby screen and the lobby already holds the cursor -- but
-- it goes on the focus stack anyway, so the same one rule ("the screen is up
-- because Lua says it owns the cursor") governs every menu in the project.
callback(BR.NuiCb.LOCKER_FOCUS, function(data)
    if data.open then
        pushFocus('locker')
    else
        popFocus('locker')
    end
    return { ok = true }
end)

-- `BR.NuiCb.PAUSE` IS GONE, AND IT WAS A FOURTH DOOR NOBODY WALKED THROUGH
-- (#138). It popped the lobby focus and fired `br:ui:pauseRequest`, which
-- raises GTA's frontend from br_core and announces nothing to the page -- so
-- it carried #122's bug in full. The page never called it: `PAUSE` was
-- declared in bridge/types.ts and referenced from no component, verified by
-- grep across ui-src.
--
-- Deleted rather than fixed. A route with no caller cannot be tested and
-- cannot be trusted, and leaving a broken one wired up is how it becomes live
-- the first time somebody adds a button. Every real route into the frontend
-- now goes through BR.Pause.handOverToFrontend.

-- ------------------------------------------------------------- the cover ---

--- Which covers the page currently says are fully opaque.
---
--- THIS IS THE ACKNOWLEDGEMENT PATH THAT DID NOT EXIST, and its absence is the
--- whole of #124. Lua raised a curtain and moved on, so "cover the screen" and
--- "change the world underneath it" were two timers started at the same moment
--- on two different clocks -- a Citizen.Wait here, a CSS transition over there
--- in another process. The world change won, every time, and the player got
--- exactly the cut the cover was added to hide: "the lobby UI goes away and
--- cuts immediately to the in-game HUD/minimap/teleports my player, and THEN
--- the fade to black happens" (owner, 2026-08-16).
---
--- Three previous attempts moved the Wait() around. They could not work: no
--- number is correct on a machine whose frame budget you do not control.
---
--- STATE, NOT A TOGGLE -- the same rule players.lua and pause.lua follow. The
--- page sends the state it is in, so a message lost on a busy frame costs one
--- stale reading that the next one corrects, rather than leaving the two sides
--- permanently inverted.
local covered = {}

--- Is a named cover fully opaque right now?
--- @param kind string  'curtain' | 'verdict'
--- @return boolean
local function isCovered(kind)
    return covered[kind] == true
end
exports('isCovered', isCovered)

callback(BR.NuiCb.COVERED, function(data)
    local kind = tostring(data.kind or 'curtain')
    local now  = data.covered == true
    if covered[kind] == now then return { ok = true } end
    covered[kind] = now

    -- br_core owns what a covered screen MEANS -- the teleport, the roster
    -- sweep, the island swap. br_ui only owns the page that said so.
    TriggerEvent('br:ui:covered', kind, now)
    return { ok = true }
end)

-- A COVER CANNOT SURVIVE THE PAGE THAT DRAWS IT, and the resource that has to
-- act on that is br_core, not this one.
--
-- br_ui restarting takes this table with it, so there is nothing to clear
-- here -- but br_core's mirror of it does NOT restart, and a stale "the screen
-- is black" there would let a teardown run in front of a fresh, transparent
-- page. It clears its copy on br:ui:ready, which is the event that means "a new
-- document has loaded and has painted nothing yet". See client/spawn.lua.

--- Cover diagnostics.
---
--- "The transition still cuts" and "the page never acknowledged" look identical
--- from a chair. This says which: a `covered` that never turns true means the
--- report is not arriving and every sequence ran on its timeout instead, which
--- is the fallback behaving correctly and NOT the fix working.
RegisterCommand('brcover', function()
    print('=== br_ui cover ===')
    local any = false
    for kind, on in pairs(covered) do
        any = true
        print(('  %-8s %s'):format(kind, on and 'COVERED (page says black)' or 'clear'))
    end
    if not any then
        print('  (nothing has ever reported -- either no transition has happened')
        print('   yet this session, or the page is not sending br/cover at all)')
    end
end, false)

-- Gameplay callbacks are forwarded to br_core, which owns the decisions.
for _, name in ipairs({
    BR.NuiCb.QUEUE, BR.NuiCb.QUEUE_LEAVE,
    BR.NuiCb.SQUAD_INVITE, BR.NuiCb.SQUAD_RESPOND,
    -- JOINREQ/JOINRESP were declared in the protocol, handled in br_core and
    -- called by the UI -- and never registered HERE, so every "join this
    -- party" click came back HTTP 404 with nothing happening on any client.
    -- Only visible with three players, which is when a join list first has
    -- anything in it (user, 2026-08-05).
    BR.NuiCb.SQUAD_JOINREQ, BR.NuiCb.SQUAD_JOINRESP,
    BR.NuiCb.SQUAD_KICK, BR.NuiCb.SQUAD_LEAVE,
    -- MODE_SET WAS MISSING, and the failure is invisible from the Lua side:
    -- br_core handles it off `br:ui:action`, but nothing registered the
    -- ENDPOINT, so every mode click came back HTTP 404 and the click did
    -- nothing (user, 2026-08-09). It also explains an older report -- picking
    -- Solo not leaving the party -- which was diagnosed as a server-side gap
    -- when the request had never arrived at all.
    BR.NuiCb.MODE_SET,
    BR.NuiCb.INV_SWAP, BR.NuiCb.INV_DROP, BR.NuiCb.INV_USE, BR.NuiCb.INV_SELECT,
    -- The locker changes the PED, which is br_core's to own -- br_ui owns the
    -- page and the callbacks, br_core owns what they mean.
    BR.NuiCb.LOCKER_PICK, BR.NuiCb.LOCKER_SPIN,
    -- Rebinding is br_core's: it owns the binding table and the raw-key
    -- reader, and the settings screen is only the page that shows them.
    BR.NuiCb.KEYBIND_SET,
}) do
    callback(name, function(data)
        TriggerEvent('br:ui:action', name, data)
        return { ok = true }
    end)
end

--- CEF capability report.
---
--- Printed at startup because a stylesheet that is perfectly correct will still
--- render as nothing if this CEF build cannot parse its colour functions -- and
--- that failure looks identical to "the CSS did not load". Knowing the Chrome
--- version turns an afternoon of guessing into one line of output.
callback(BR.NuiCb.ENV, function(data)
    local css = data.css or {}
    print('[br_ui] ---- CEF environment ----')
    -- Printed first and deliberately prominent: this is how you tell "the fix
    -- did not work" apart from "the fix never reached the client".
    print(('[br_ui]   BUILD      %s'):format(tostring(data.build)))
    print(('[br_ui]   chrome     %s'):format(tostring(data.chromeVersion)))
    print(('[br_ui]   viewport   %sx%s @ %sx'):format(
        tostring(data.viewport and data.viewport.w),
        tostring(data.viewport and data.viewport.h),
        tostring(data.viewport and data.viewport.dpr)))

    -- Is the page actually see-through? A black screen over a healthy game is
    -- otherwise undiagnosable in-game, because every native check correctly
    -- reports the world is fine -- the page is just painted over it.
    local ov = data.overlay or {}
    if ov.transparent then
        print('[br_ui]   overlay    transparent (game visible)')
    else
        print('[br_ui]   overlay    !! NOT TRANSPARENT -- this will black out the game')
        print(('[br_ui]     colorScheme %s%s'):format(
            tostring(ov.colorScheme),
            ov.colorScheme == 'dark' and '   <- paints the canvas opaque' or ''))
        print(('[br_ui]     html bg     %s'):format(tostring(ov.htmlBg)))
        print(('[br_ui]     body bg     %s'):format(tostring(ov.bodyBg)))
    end

    local order = {
        'oklch', 'oklab', 'lch', 'colorMix', 'colorMixSrgb',
        'has', 'nesting', 'atProperty', 'containerType', 'backdropFilter',
    }
    local missing = {}
    for _, k in ipairs(order) do
        local v = css[k]
        print(('[br_ui]   %-15s %s'):format(k, v and 'yes' or 'NO'))
        if not v then missing[#missing + 1] = k end
    end

    -- Tailwind v4 and HeroUI v3 emit oklch/oklab/color-mix throughout their
    -- colour system. Without them, components render with no colour at all.
    if not css.oklch or not css.colorMix then
        print('[br_ui]   note: no modern colour functions on this build -- expected.')
        print('[br_ui]   The stack is pinned to HeroUI 2 + Tailwind 3 for exactly')
        print('[br_ui]   this reason, and check-css enforces it at build time.')
    end
    print(('[br_ui] ---- %d unsupported ----'):format(#missing))

    -- This callback is also the only reliable "the interface is alive" signal.
    --
    -- br:ui:ready is fired from onClientResourceStart, which is the LUA resource
    -- starting -- CEF has not fetched the page at that point, let alone mounted
    -- React. Envelopes sent in that window reach a page whose dispatcher has no
    -- subscribers yet and are dropped, and nothing re-sent them, because the
    -- snapshot request had already been answered. The player then waits for the
    -- next thing that happens to push state before the lobby fills in.
    --
    -- This fires from the bundle's own module load, so it cannot be early.
    TriggerEvent('br:ui:ready')
    return { ok = true }
end)

--- The error sink. Without this, a CEF exception is a blank screen and there is
--- nowhere to look for the cause.
callback(BR.NuiCb.ERROR, function(data)
    print(('[br_ui] UI error in %s: %s'):format(
        tostring(data.context), tostring(data.message)))
    if data.stack and #tostring(data.stack) > 0 then
        print('[br_ui]   ' .. tostring(data.stack))
    end
    return { ok = true }
end)

-- ------------------------------------------------------------- watchdog ---

-- Focus held with an empty stack means something released a screen without
-- telling us, or a handler threw between push and pop. Rather than leave the
-- player stuck, take it back.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if focusHeld and #focusStack == 0 then
            print('[br_ui] focus held with an empty stack -- releasing (watchdog)')
            applyFocus()
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    -- Never strand the player because the UI resource restarted.
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    SetNuiFocus(false, false)
    print('[br_ui] bridge ready')
    -- Ask br_core for a full snapshot; it may have started first.
    TriggerEvent('br:ui:ready')
end)

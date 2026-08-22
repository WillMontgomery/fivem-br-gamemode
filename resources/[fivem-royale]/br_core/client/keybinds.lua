-- Key bindings.
--
-- Everything goes through REGISTER_KEY_MAPPING (verified: ns CFX, apiset client)
-- rather than polling control IDs. That single decision buys three things:
--
--   * bindings appear in the GTA pause menu under Settings > Key Bindings,
--     grouped under this resource, so players can rebind them with no UI of ours;
--   * rebinds persist across sessions, handled by the client;
--   * we stop fighting GTA's own control scheme, which is what happens when a
--     resource hardcodes IsControlJustPressed on a key the player has remapped.
--
-- Hold-style actions use the +command / -command convention: FiveM calls
-- "+revive" on press and "-revive" on release automatically.
--
-- Registration must happen at load time, not inside a loop -- the pause menu is
-- populated when the resource starts.

BR = BR or {}
BR.Keys = {
    -- action name -> whether it is currently held (for +/- pairs)
    held = {},
    -- action name -> array of listener functions
    listeners = {},
}

--- IS A NUI SCREEN HOLDING THE KEYBOARD RIGHT NOW?
---
--- A FIELD RATHER THAN A LOCAL BECAUSE THREE SEPARATE PLACES ASK IT and two of
--- them are above where a local would be declared: the tap() and hold()
--- registrars a few lines down, the raw frame loop at the bottom, and /brkeys.
--- A forward-declared local read from a closure built at load time is exactly
--- the shape tools/check_forward_locals.lua exists to catch.
---
--- FALSE IS THE STARTING ANSWER AND IT IS THE SAFE ONE. A gate that is stuck
--- OFF costs the bug this fixes -- a keystroke that also drives the game -- and
--- corrects itself on the next focus change. A gate stuck ON costs the player
--- their entire keyboard with no way to notice or recover. Every default,
--- every reset and every unknown resolves to false for that reason.
---
--- The full note on what sets it, and why the signal is br_ui's rather than
--- something read locally, is at the `br:ui:focusChanged` handler at the bottom
--- of this file.
BR.Keys.uiOwnsKeyboard = false

--- Subscribe to a key action.
--- @param action string   e.g. 'inventory', 'revive'
--- @param fn function      receives (pressed: boolean)
function BR.Keys.on(action, fn)
    local l = BR.Keys.listeners[action]
    if not l then
        l = {}
        BR.Keys.listeners[action] = l
    end
    l[#l + 1] = fn
end

--- @param action string
--- @return boolean
function BR.Keys.isHeld(action)
    return BR.Keys.held[action] == true
end

--- Actions whose next press has been BORROWED. [action] = { fn, expires }
---
--- Declared above fire() because fire() reads it -- a local read from a closure
--- built earlier in the file is exactly what tools/check_forward_locals.lua
--- exists to catch.
local claims = {}

--- Borrow one action's key for one press, for a short while.
---
--- WHY THE KEY LAYER AND NOT THE TWO PANELS (#177). The verdict screen's
--- corroborate prompt sits on TAB, and TAB is the inventory key -- so something
--- has to decide which of them a press means. Teaching the inventory panel about
--- the report prompt (and, next time, about the thing after that) is the N²
--- shape #149 and #179 both name as the trap; this is the one component that
--- already sees every key listener, so the arbitration is one function here
--- rather than a condition in each of them.
---
--- IT IS NOT #179's ARBITER AND MUST NOT BE MISTAKEN FOR ONE. #179 is about
--- LATCHING SURFACES fighting over the screen -- which panel wins, and for how
--- long -- and its answer belongs next to the focus stack, which is the thing
--- that sees all of them. This borrows ONE press of ONE action for a bounded
--- window and opens no surface at all. When #179 lands, this stays: "a prompt
--- offered a key for ten seconds" is a different question from "two panels are
--- both up".
---
--- SINGLE-SHOT AND SELF-EXPIRING, because the failure mode of getting this wrong
--- is a key that silently stops working. The claim is dropped the instant it
--- fires and again the instant it is out of time, both of them inside the same
--- path that would honour it -- so there is no timer to leak and no way for a
--- claim to outlive the prompt that made it. A second claim replaces the first;
--- the most recent thing to ask is the thing that gets the key, which is the
--- rule a player would predict.
---
--- @param action string    e.g. 'inventory'
--- @param fn function      called once, on the next press inside the window
--- @param ms number        how long the offer stands
function BR.Keys.claim(action, fn, ms)
    if type(action) ~= 'string' or type(fn) ~= 'function' then return end
    local d = tonumber(ms) or 0
    if d <= 0 then return end
    claims[action] = { fn = fn, expires = GetGameTimer() + d }
end

-- THERE IS NO `BR.Keys.release`, AND ITS ABSENCE IS DELIBERATE. The obvious
-- companion to claim() is a way to hand the key back early, and nothing in this
-- project has a reason to call one: the claim dies on the press and on the
-- clock, and both of those are checked inside fire(). Shipping the function
-- anyway would be one more correct, untested, uncalled path in a codebase that
-- has already paid for several. Add it when something needs it.

local function fire(action, pressed)
    BR.Keys.held[action] = pressed

    -- A BORROWED PRESS NEVER REACHES THE ORDINARY LISTENERS, which is the whole
    -- point: without this, TAB would corroborate the report AND open the
    -- inventory panel over the verdict screen.
    --
    -- ONLY THE PRESS IS TAKEN. The claim is cleared before the callback runs, so
    -- the `pressed = false` half of a tap pair falls straight through -- and
    -- every listener in this project treats a release as "stop", which is a
    -- no-op for something it never started.
    local c = claims[action]
    if c then
        if GetGameTimer() >= c.expires then
            claims[action] = nil
        elseif pressed then
            claims[action] = nil
            -- pcall for the same reason the listener loop below has one: a
            -- claimant that throws must not leave the key layer half-run.
            local okc, err = pcall(c.fn)
            if not okc then
                print(('[br_core] key claim for "%s" errored: %s')
                    :format(action, tostring(err)))
            end
            return
        end
    end

    local l = BR.Keys.listeners[action]
    if not l then return end
    for i = 1, #l do
        -- A listener throwing must not stop the others, and must not leave the
        -- held state wrong -- a stuck "held" flag would mean a revive that never
        -- stops or a chat box that never closes.
        local ok, err = pcall(l[i], pressed)
        if not ok then
            print(('[br_core] key listener for "%s" errored: %s'):format(action, tostring(err)))
        end
    end
end

-- THE BINDING TABLE, BUILT BY THE REGISTRARS THEMSELVES.
--
-- It exists so the settings screen can list what is bindable without anybody
-- hand-typing it a second time. The first attempt at a rebinder did hand-type
-- it, in another resource, and got two entries wrong -- the marker command is
-- `brping` not `brmarker`, and INTERACT is a hold action whose real commands
-- are `+brinteract` / `-brinteract`. Binds were being written against
-- commands that do not exist, which is a large part of why none of them
-- appeared to do anything (user, 2026-08-09).
--
-- One list, produced by the code that registers them. It cannot drift.
BR.Keys.bindings = {}

--- Which action a group is filed under on the settings screen.
local group = 'Combat'

--- Register a tap action: fires once on press.
--- @param action string      internal name
--- @param command string     console command / binding id
--- @param description string shown in the pause menu
--- @param key string         default key, e.g. 'TAB'
--- @param raw integer|nil    raw-layer default, when it must DIFFER from the
---                           engine's. Only the pause menu needs this: its key
---                           is Escape, and Escape is not something
---                           RegisterKeyMapping can be given.
local function tap(action, command, description, key, raw)
    RegisterCommand(command, function()
        -- The RAW LAYER WINS WHEN IT IS RUNNING. The command stays registered
        -- so GTA's own list still shows it, but firing from both paths would
        -- double-tap every action for a player whose chosen key happens to
        -- match the engine's stored one.
        if BR.Keys.rawActive then return end
        -- AND NOT WHILE A NUI SCREEN OWNS THE KEYBOARD.
        --
        -- Believed to be unreachable, and gated anyway. FiveM's own contract is
        -- that a focused page with keep-input off means the GAME receives
        -- nothing, so the engine should never deliver this command in the first
        -- place -- App.tsx says so in as many words about the lobby's Escape,
        -- and ui-src/src/screens/PlayerList.tsx repeats it. But "the engine
        -- will not deliver it" is an assumption about a runtime, and this file
        -- is the one that has already paid seven rounds for assumptions about
        -- what the input layer does (#129). One comparison is cheaper than
        -- finding out.
        if BR.Keys.uiOwnsKeyboard then return end
        fire(action, true)
        fire(action, false)
    end, false)
    RegisterKeyMapping(command, description, 'keyboard', key)
    BR.Keys.bindings[#BR.Keys.bindings + 1] = {
        action = action, command = command, label = description,
        default = key, hold = false, group = group, raw = raw,
    }
end

--- Register a hold action: fires true on press, false on release.
---
--- THE GATE HERE IS `rawHolds`, NOT `rawActive`, AND THE DIFFERENCE IS THE
--- WHOLE OF #129's SECOND ROUND.
---
--- `rawActive` means "the raw layer is reading the keyboard". `rawHolds` means
--- "and the native it resolved can answer the question a HOLD asks" -- is this
--- key down RIGHT NOW, on this frame. Only IsRawKeyDown answers that;
--- IsRawKeyPressed, the fallback for a build that predates it, is a
--- single-frame EDGE (see the long note at the reader below). On a client that
--- fell back, the raw layer can see a press and can never see a hold.
---
--- That used to be survivable and is not any more. The old crate open was a
--- start stamp and a subtraction -- it never needed the key to be down for any
--- of the interval -- so a client on the fallback opened crates anyway, and the
--- startup line calling it "holds degrade to taps" was an accurate description
--- of a cosmetic loss. Since the hold became an ACCUMULATOR that only advances
--- on frames the key reads down (#129, loot.lua), the same client accumulates
--- exactly one frame per press and the threshold is unreachable: the crate
--- cannot be opened at all, which is a core interaction gone rather than a
--- degraded one.
---
--- So the split is per-question rather than all-or-nothing. If the raw layer
--- cannot answer a hold, it does not claim one, and these two commands -- the
--- engine's own +/- pair, which has given both edges reliably since M0 -- drive
--- it instead. Taps are untouched either way.
---
--- THE COST WAS STATED AND THEN UNDERSTATED, AND THAT IS THE THIRD ROUND.
---
--- What was written here was: "on such a client, rebinding a HOLD action from
--- our settings screen does not take effect, because the engine owns the key."
--- True, and it reads like a shrug. It is not one. A rebind that does not take
--- effect is not a preference quietly ignored -- the rebind still lands in the
--- KVP, the settings screen still draws it, and every world prompt still NAMED
--- it, so the crate said "hold R" while the only thing listening was the engine
--- on E. The owner held R at crate after crate: "Welp, now trying to open a
--- crate does nothing at all" (#129). Loose loot went with it, because the
--- claim rides the same press (#139) -- one cause, two reports, and a core
--- interaction dead on a client that had done nothing wrong except use the
--- rebinder this file exists to provide.
---
--- The split itself is still right: a layer that cannot answer what a hold asks
--- must not claim one. What was missing is that the handover has to be VISIBLE.
--- See engineDrives below -- the prompt, the settings screen and the rebinder
--- now all name the engine's key for a binding the engine is driving, and a
--- rebind that cannot take effect is refused rather than stored. The player
--- loses the ability to move one action on an old build, and is told so, which
--- is a different thing entirely from the action silently going away.
local function hold(action, command, description, key)
    RegisterCommand('+' .. command, function()
        if BR.Keys.rawHolds then return end
        -- The press is gated for the same reason the tap above is.
        if BR.Keys.uiOwnsKeyboard then return end
        fire(action, true)
    end, false)
    RegisterCommand('-' .. command, function()
        if BR.Keys.rawHolds then return end
        -- AND THE RELEASE IS NOT, DELIBERATELY, WHICH IS THE ASYMMETRY THAT
        -- MATTERS MOST IN THIS FILE.
        --
        -- On a client where the engine drives holds, this `-brinteract` is the
        -- ONLY thing that ever writes BR.Keys.held.interact back to false --
        -- the raw loop skips hold bindings entirely in that mode. Gate it and a
        -- player who is holding E when a menu opens has a key that is down
        -- forever: dbno.lua's revive re-arms from isHeld() alone (dbno.lua:1069
        -- starts one with no press edge at all), so the latch is not a stale
        -- flag, it is a revive that runs on its own. That is the scar the
        -- resync window's own note is about, and #129's history is the receipt.
        --
        -- A release delivered late, or twice, or for a hold that was already
        -- ended when the screen took the keyboard, costs nothing: every
        -- listener treats `pressed = false` as "stop", and stopping something
        -- that is already stopped is a no-op. A release never delivered costs
        -- the round.
        fire(action, false)
    end, false)
    RegisterKeyMapping('+' .. command, description, 'keyboard', key)
    BR.Keys.bindings[#BR.Keys.bindings + 1] = {
        action = action, command = command, label = description,
        default = key, hold = true, group = group,
    }
end

-- Descriptions are prefixed so they group together and read sensibly in the
-- pause menu, where they sit alongside every other resource's bindings.

group = 'Movement'
-- Drop. ONE key for the whole descent: aboard the bus it jumps, in freefall
-- it deploys the glider. Two bindings for consecutive actions on the same
-- second of gameplay was one binding too many.
tap ('deploy',      'brdeploy',    'Royale: Jump / deploy glider',       'SPACE')
-- THE SMOKE TRAIL IS OURS TO ROUTE, NOT THE ENGINE'S (#131).
--
-- GTA already has a parachute-smoke input, and binding that would have been
-- the shorter road. It was refused on the owner's explicit call (2026-08-16):
-- "I'd rather not re-use that since it means leaving our own keybinds
-- authority yet again." Everything a player can rebind in this game is rebound
-- from one screen, reading one table, and an action routed by the engine
-- instead would sit in that list as a row we cannot move -- the same split
-- authority that had every world prompt saying E long after interact moved to
-- R. One table or none.
--
-- B, and the reason is the canopy. Steering a parachute occupies WASD, Space
-- and the shift/ctrl pair, so a toggle anywhere near them is a toggle that
-- gets hit while flying; B is outside that cluster, is bound to nothing on
-- foot in base GTA, is bound to nothing else here, and is not on the settings
-- screen's reserved list, so anyone who dislikes it can move it.
tap ('trail',       'brtrail',     'Royale: Toggle smoke trail',         'B')

-- THE VEHICLE BOOST, AND LEFT SHIFT IS A RESEARCHED CHOICE RATHER THAN A HABIT.
--
--   "while holding SHIFT by default (remappable), and in the driver's seat"
--                                                  -- owner, 2026-08-22, #203
--
-- 'LSHIFT' IS THE STRING THE ENGINE TAKES. There is no 'SHIFT' in the keyboard
-- mapper table -- it is LSHIFT and RSHIFT -- and a key name RegisterKeyMapping
-- does not recognise is a binding that never appears. The raw layer wants a
-- different number for the same key; see DEFAULT_VK below, where LSHIFT maps to
-- 0x10 and the reason is written out.
--
-- WHAT SHIFT ALREADY DOES IN A VEHICLE, ESTABLISHED RATHER THAN ASSUMED. Two
-- independent control tables agree that left shift carries four GTA controls,
-- and that in a CAR none of them fires:
--
--   21   INPUT_SPRINT                     on foot only
--   61   INPUT_VEH_MOVE_UP_ONLY           aircraft / submarine ascend
--   352  INPUT_VEH_FLY_BOOST              aircraft only
--   340  INPUT_VEH_HYDRAULICS_CONTROL_UP  lowriders with hydraulics fitted
--
-- That is why it is the right default: it is the most valuable UNBOUND key in a
-- car, and the same key sprints on foot, so one habit covers both. It is also
-- the FiveM convention -- the open nitro scripts that ship a default ship this
-- one.
--
-- THE TWO REAL COLLISIONS, AND WHAT IS DONE ABOUT EACH. RegisterKeyMapping does
-- not suppress an engine control that shares its key (see the note on the
-- removed 'ping' binding below for what that cost last time), so both of these
-- are live:
--
--   AIRCRAFT   61 and 352 would climb a helicopter while we shoved it forward,
--              from one press. Excluded in BR.Config.Boost.excludeClasses, which
--              is the one place to change it.
--   HYDRAULICS 340 would hop a lowrider fitted with them. NOT excluded: it needs
--              a Benny's hydraulics mod, nothing in this gamemode fits one, and
--              a whole vehicle class cannot be taken away for a mod no car here
--              has. If a boosting Tornado starts bouncing, this is the line.
--
-- INPUT_VEH_ROCKET_BOOST (351) IS NOT IN THAT LIST and is worth saying so about,
-- because it is the control whose name suggests it should be. It is on E, not
-- shift -- it is already suppressed at petrol pumps for exactly that reason
-- (BR.Config.Fuel.hornControls) -- and it does nothing at all on a vehicle
-- without FLAG_HAS_ROCKET_BOOST in its meta, which is no vehicle in this game.
-- It is neither a help nor an obstacle here.
hold('boost',       'brboost',     'Royale: Vehicle boost',              'LSHIFT')

group = 'Combat'
-- Inventory and interaction
tap ('inventory',   'brinventory', 'Royale: Inventory',                  'TAB')
hold('interact',    'brinteract',  'Royale: Interact / pick up / revive','E')
tap ('drop',        'brdrop',      'Royale: Drop selected item',         'G')
-- R by default because RELOAD is exactly what a player reaches for when they
-- want the thing in their hands to do something, and reloading a shield potion
-- means nothing -- so the two never want the key at the same moment. Rebind it
-- in Settings > Key Bindings like everything else here.
tap ('use',         'bruse',       'Royale: Use selected item',          'R')

group = 'Slots'
-- Slots. Direct slot keys beat scroll-wheel cycling under pressure.
tap ('slot1',       'brslot1',     'Royale: Slot 1',                     '1')
tap ('slot2',       'brslot2',     'Royale: Slot 2',                     '2')
tap ('slot3',       'brslot3',     'Royale: Slot 3',                     '3')
tap ('slot4',       'brslot4',     'Royale: Slot 4',                     '4')
tap ('slot5',       'brslot5',     'Royale: Slot 5',                     '5')

group = 'Comms'
-- Comms
tap ('chatGlobal',  'brchat',      'Royale: Chat (global)',              'T')
tap ('chatSquad',   'brchatsquad', 'Royale: Chat (squad)',               'Y')

-- PUSH TO TALK, AND IT IS OURS NOW. THIS ROW IS THE WHOLE OF #157's EIGHTH
-- ROUND, so it is worth being exact about what it replaces.
--
-- LEFT ALT WAS NEVER A DECISION. Owner, verbatim: "Why is left alt used for
-- anything? That was a mistake - a default left in place." It was pma-voice's
-- `voice_defaultRadio` default -- LMENU -- inherited by this project never
-- setting it, and it reached the player as a row in the GTA pause menu called
-- "Talk over Radio" that no screen of ours could list, name or move.
--
-- SETTING voice_defaultRadio TO 'N' WOULD NOT HAVE FIXED THAT, AND THAT IS THE
-- POINT OF THIS ROW EXISTING AT ALL. It moves pma-voice's OWN binding's
-- default and nothing else: the key would still be registered by pma-voice, it
-- would still be absent from BR.Keys.bindings (so absent from our settings
-- screen and from BR.Keys.labelFor, which is what every prompt and notice
-- asks), it would still not move for a player who had already rebound it, and
-- it would still be a second key layer with its own authority -- the exact
-- split this file's #131 note refuses for the smoke trail: "I'd rather not
-- re-use that since it means leaving our own keybinds authority yet again."
--
-- So the key is registered HERE, like every other key in this game, and
-- br_core/client/voice.lua drives pma-voice's transmit path off it. The full
-- argument for that direction, and what it must not break, is in voice.lua
-- under `push to talk`.
--
-- N, because it is the key the player is already holding: 249 is GTA's own
-- INPUT_PUSH_TO_TALK and its default keyboard binding is N, so this row starts
-- life agreeing with the engine's voice key instead of fighting it. Rebindable
-- from the settings screen like everything else.
hold('ptt',         'brptt',       'Royale: Push to talk',               'N')
-- THERE IS NO 'ping' BINDING ANY MORE, AND THAT IS THE FIX RATHER THAN AN
-- OMISSION. It was `tap('ping', 'brping', 'Royale: Place a marker', 'Z')` and
-- it had NO SUBSCRIBER: nothing anywhere called BR.Keys.on('ping', ...). The
-- feature it was for still exists and is better than it was -- client/markers
-- .lua watches for a fresh MAP WAYPOINT and turns that into the squad marker,
-- so the ping is placed the way a player already knows how to place one -- and
-- when it moved there, the key was left behind.
--
-- A BOUND KEY WITH NO LISTENER IS WORSE THAN AN UNBOUND ONE. It occupies a row
-- in the GTA pause menu and in our own rebinder, it claims the key against
-- every other resource's default, and pressing it does nothing -- which is
-- indistinguishable from the action being broken. Z is also GTA's own
-- INPUT_MULTIPLAYER_INFO (20) and INPUT_HUD_SPECIAL (48), and
-- RegisterKeyMapping does not suppress an engine control that shares its key,
-- so the only thing pressing Z ever did on this server was whatever the engine
-- does with it. That is the "pressing Z makes some radio noise" report: not
-- pma-voice, which used to bind exactly two keyboard keys (F11 cycleproximity,
-- LMENU +radiotalk) and neither was this one. IT NOW BINDS NONE: pma-voice is
-- vendored at resources/[voice]/pma-voice and BR-PATCH 3a/3b removed both
-- RegisterKeyMapping calls, so this file's rows are the only keyboard bindings
-- any resource on this server registers. The +radiotalk COMMAND is untouched
-- and is still what `ptt` drives -- see voice.lua.
--
--- NOTHING ON THIS SCREEN IS BOUND-BUT-DEAD ANY MORE, AND BOTH HALVES OF THAT
--- WERE EARNED IN THE SAME WEEK.
---
--- THE SPECTATE ARROWS (#192). 'specNext' (RIGHT) and 'specPrev' (LEFT) stood
--- in this paragraph from M3 until the round that built spectating, and
--- client/spectate.lua is the subscriber they never had. Nothing about the two
--- rows below moved: same actions, same commands, same defaults -- so a player
--- who had already rebound a key they had no way to know was dead keeps the key
--- they chose. The public site was corrected on 2026-08-21 to stop claiming they
--- worked; it now says so again because they do.
---
--- 'map' (M) WAS THE LAST ONE (#199). It was registered here with no BR.Keys.on
--- anywhere in the tree. br_ui/client/pause.lua subscribes to it now and opens
--- the same map the pause menu's button opens -- one function, three callers.

group = 'Map'
-- Map and spectating.
--
-- M, AND IT WAS ALREADY REGISTERED HERE BEFORE IT DID ANYTHING (#199). The row,
-- the default and the settings-screen entry have existed since the binding
-- table did; what was missing was a BR.Keys.on for it, which is the whole of
-- what this issue asked for. Nothing below hardcodes M -- the listener fires on
-- the ACTION, so a player who moves the row moves the map with it and every
-- screen that draws a key follows through BR.Keys.push.
tap ('map',         'brmap',       'Royale: Map',                        'M')
-- CLEARING A WAYPOINT. GTA's own way to remove one is to open the pause map,
-- find the flag and click it again -- which in a battle royale means opening a
-- full-screen menu mid-fight to undo a misclick (user, 2026-08-06: "there is
-- no way to remove a user-made waypoint"). BACKSPACE by default, rebindable
-- like everything else here.
tap ('clearWaypoint', 'brclearwp', 'Royale: Clear map waypoint',          'BACK')
tap ('specNext',    'brspecnext',  'Royale: Spectate next player',       'RIGHT')
tap ('specPrev',    'brspecprev',  'Royale: Spectate previous player',   'LEFT')

group = 'Interface'
-- OUR SCREENS ARE KEYS TOO, and they live here rather than in br_ui because
-- this is the table the rebinder reads. The pause menu was registered over
-- there with an EMPTY default and was in no table at all, so nothing could
-- open it -- there was no key, and no row in the settings screen to give it
-- one (user, 2026-08-09: "how can I test the pause menu?").
--
-- ESCAPE, because we are replacing GTA's pause menu rather than sitting
-- beside it (user call, 2026-08-09). DISABLE_FRONTEND_THIS_FRAME
-- (0x6D3465A73092F0E6) is the documented way to take the engine's menu away --
-- it stops the frontend being TOGGLED, from the keyboard and from a
-- controller's Start alike, which is why this can be done at all now and could
-- not be by disabling control 199/200.
--
-- Two guards, because a pause menu you cannot open is a soft lock:
--   * the suppression follows the binding (BR.Keys.ownsEscape) -- rebind our
--     menu off Escape and GTA's comes straight back;
--   * and it needs the raw layer, so a client without it keeps the engine's
--     menu and reaches ours on F1.
-- F1 stays as the ENGINE-side default for exactly that fallback; the raw
-- layer's own default is Escape, which RegisterKeyMapping cannot be given.
--
-- Settings is deliberately unbound: it is reachable from the lobby and from
-- the pause menu, and a mispressed key that throws a full-screen opaque menu
-- over a firefight is worse than no shortcut.
tap ('pause',       'brpausemenu', 'Royale: Pause menu',                 'F1', 0x1B)
tap ('settingsMenu', 'brsettingsmenu', 'Royale: Settings',               '')

-- THE PLAYER LIST IS TAP-TO-LATCH, AND THAT IS LOAD-BEARING RATHER THAN A UX
-- PREFERENCE (#95). `tap()` takes the 5th `raw` argument carrying the VK code
-- the raw layer actually wants; `hold()` does not. A hold-to-show panel on
-- tilde would have registered in the pause menu and then silently never fired,
-- because 0xC0 is not in DEFAULT_VK and hold() has no way to be told about it.
--
-- 0xC0 (VK_OEM_3, tilde) is already in the VK display-name table, so the
-- Settings row renders correctly with no change, and it is absent from the
-- UI's RESERVED map so a player can rebind it off tilde today.
--
-- F2 is the ENGINE-side fallback purely because it is unused and already in
-- DEFAULT_VK. It only matters on a client where IsRawKeyDown is unavailable --
-- the same client the Settings screen already tells that rebinding is off.
tap ('players',     'brplayers',   'Royale: Player list / report',       'F2', 0xC0)

-- br_ui owns the pages; this owns the keys. TriggerEvent crosses resources,
-- which is the same hop br_core already uses to reach the interface.
BR.Keys.on('pause', function(pressed)
    if pressed then TriggerEvent('br:ui:pauseToggle') end
end)
BR.Keys.on('players', function(pressed)
    if pressed then TriggerEvent('br:ui:playersToggle') end
end)

BR.Keys.on('settingsMenu', function(pressed)
    if pressed then TriggerEvent('br:ui:settingsToggle') end
end)

--- WHERE THE MAP KEY IS ANSWERED, AND WHERE IT IS NOT (#199).
---
--- ONE PRESS, AND IT IS THE PAUSE MENU'S OWN MAP BUTTON. `br:ui:mapToggle`
--- reaches the same BR.Pause.openMap() the Map card's PAUSE_ACTION callback
--- calls -- one implementation of "open the map", switchable by `brmapmode`
--- like it always was, with nothing here knowing which of the three routes it
--- ends up taking. A second copy of that decision is exactly what the issue
--- asked us not to write.
---
--- IT ALSO CLOSES, and that is a decision rather than an oversight of the
--- owner's "one-key press to open". br_ui/client/pause.lua already states the
--- rule for the other key that reaches the map: "whatever the map key turned
--- on, the map key turns off. A player should never have to know WHICH native
--- drew the thing in front of them to get rid of it." A dedicated map key that
--- can only open leaves the player holding something they have to be told a
--- different key to dismiss -- and in the default `frontend` route that key is
--- Escape, which is the one this menu is replacing. Escape still closes it too;
--- nothing was taken away.
---
--- EVERY STATE BUT THE LOBBY, which is the same answer the button gives.
--- PauseMenu.tsx hides the Map card behind `!inLobby` and says why: the map
--- route raises GTA's frontend, the lobby is drawn from MATCH STATE rather than
--- from focus, and a lobby that keeps painting over a scaleform is #122
--- verbatim. That reasoning is about the route, not about the button, so a key
--- that skipped the gate would reintroduce the bug through a second door -- the
--- exact shape #138 was ("PUBLIC BECAUSE THERE WAS A FOURTH DOOR"). So: bus,
--- freefall, glide, alive, warmup, downed, dead and spectating all open the map;
--- the lobby does not.
---
--- THE GATE IS HERE AND NOT IN br_ui BECAUSE THE STATE IS HERE. br_ui declares
--- no dependency on br_core and cannot read BR.State at all -- ringmaster.lua:66
--- records what happens to code that tries ("the first version of this read nil
--- forever from over there"). The page's own `inLobby` is derived from what the
--- bridge sends it, which is this same state by a longer road.
---
--- THE GATE NAMES THE ONE STATE THAT REFUSES, RATHER THAN THE EIGHT THAT ALLOW,
--- so an unknown answer opens the map. `BR.State.me.state` is nil for the window
--- between this file loading and the first state landing, and it would be nil
--- again for any state added later -- an allowlist would refuse both, which is a
--- key that silently does nothing on exactly the clients where something else
--- has already gone wrong. The cost of the other direction is a map opened over
--- a lobby for the length of that window; the cost of an allowlist is a dead key
--- nobody can diagnose from a chair.
BR.Keys.on('map', function(pressed)
    if not pressed then return end
    local st = BR.State and BR.State.me and BR.State.me.state
    if st == BR.PlayerState.LOBBY then return end
    TriggerEvent('br:ui:mapToggle')
end)

-- THE KILL PROMPT BORROWS TAB, AND THE BORROWING HAS TO HAPPEN HERE (#177).
--
-- br_ui shows the prompt -- it owns the toast and it writes the sentence -- but
-- br_ui declares no dependency on br_core and cannot see BR.Keys at all
-- (ringmaster.lua:66 records what happens to code that tries to read across
-- resource states: "the first version of this read nil forever from over
-- there"). So the prompt asks over the event channel, which is the same hop the
-- three bridges above already use in the other direction.
--
-- THE SERVER EVENT IS SENT FROM THIS SIDE rather than handed back to br_ui to
-- send, so the press and the message it produces are one step apart instead of
-- three. REPORT_CORROBORATE carries nothing; the server resolves the asker's own
-- killer from its own records, exactly as REPORT_KILLED does.
--
-- WHY TAB IS THE RIGHT KEY EVEN THOUGH THE INVENTORY OWNS IT: the prompt is on
-- the verdict screen and the player is dead, which is the one moment the
-- inventory panel is worth nothing -- and the alternative, a key of its own, is
-- a fourth binding for one press a player makes once a round. The claim above is
-- what stops the two fighting; see #179 for the panel-level version of that
-- fight, which this does not attempt to answer.
AddEventHandler('br:report:armCorroborate', function(ms)
    BR.Keys.claim('inventory', function()
        TriggerServerEvent(BR.Net.REPORT_CORROBORATE)
    end, tonumber(ms) or 0)
end)

--- Names of every registered action, for the debug overlay.
BR.Keys.actions = {
    'deploy', 'trail', 'boost', 'inventory', 'interact', 'drop', 'use',
    'slot1', 'slot2', 'slot3', 'slot4', 'slot5',
    -- 'ping' is gone: it had no listener and the marker it was for is placed
    -- by dropping a map waypoint now (client/markers.lua). 'specNext' and
    -- 'specPrev' are still in that state and are NOT yet removed -- they are
    -- listed here so the debug overlay keeps naming them while they are.
    -- 'map' was with them and is not any more (#199): it opens the map.
    'chatGlobal', 'chatSquad', 'ptt', 'map', 'specNext', 'specPrev',
    'clearWaypoint',
}

-- ---------------------------------------------------------------------------
-- REBINDING FROM OUR OWN SETTINGS SCREEN
--
-- The first attempt drove FiveM's `bind` console command. It did not work, and
-- rather than guess a fourth time: `bind` is real and documented, but it binds
-- a CONSOLE COMMAND, and half the table above does not have the command name
-- somebody hand-typed into another resource -- interact is `+brinteract`, the
-- marker is `brping`. Even with the names right it was writing bindings whose
-- interaction with the RegisterKeyMapping entry already in the player's
-- fivem.cfg is not something the docs settle.
--
-- So this stops asking the engine to route the key and reads the key itself.
-- IS_RAW_KEY_JUST_PRESSED / _RELEASED take a Windows virtual-key code, are
-- purely local, and answer the one question we actually have: is this exact
-- key down right now. From there we call `fire()` DIRECTLY -- the same
-- function the console commands call -- so a rebound key is indistinguishable
-- from a default one to everything downstream.
--
-- IT IS ALL-OR-NOTHING, ON PURPOSE. `rawActive` gates the RegisterKeyMapping
-- handlers above: when the raw layer is running they do nothing, so an action
-- can never fire twice for one press. And the flag is only set if the native
-- actually answers, so a build without it falls back to exactly the behaviour
-- this project has always had, with nothing lost.
--
-- The GTA pause-menu entries still exist and still list the defaults. They are
-- inert while the raw layer runs; the settings screen is the live one.
-- ---------------------------------------------------------------------------

local KVP = 'br:keys'

--- command -> virtual-key code, or FALSE for "deliberately on no key".
---
--- `false` and `nil` are different answers and the difference is load-bearing.
--- nil means nobody has said anything, so the default applies; false means the
--- player cleared it, or it lost a conflict to another action -- and that has
--- to SURVIVE A RESTART. It did not: the table was rebuilt from the KVP and
--- then every missing entry was filled in from DEFAULT_VK, so a command that
--- had been unbound came back on its default key the next session -- straight
--- back onto the key that took it from it. Rebind interact to R once and both
--- interact and USE end up on R after a reload, quietly, with the settings
--- screen showing exactly that and no way to read it as a bug.
local vk = nil

--- Commands the player has an OPINION about -- rebound or cleared.
---
--- Separate from `vk` because "we own this binding" is a different question
--- from "what key is it": the world prompts need to know whether to trust our
--- answer or the engine's, and a command sitting on its default is one we have
--- no more claim to than the engine does.
local chosen = {}

-- A SECOND SLOT PER ACTION WAS BUILT AND THEN REMOVED (user, 2026-08-09).
-- Two keyboard keys for one action is a feature nobody asks for; the reason
-- games have two slots is that the second one holds a MOUSE BUTTON or a pad
-- input, and this layer cannot read either. Half a feature that looks like the
-- whole one is worse than not having it -- a player would find the empty
-- alternate slot, try to put mouse 4 in it, and learn what it cannot do.
-- Saves written while it existed still load; their alt entries are ignored.

--- The virtual-key codes for the DEFAULT keys above, so the raw layer can
--- reproduce them for a player who has never rebound anything.
---
--- Hand-mapped because there is no native that converts a RegisterKeyMapping
--- key name to a VK code -- and deliberately kept to exactly the keys this
--- project actually uses as defaults, rather than a general table that would
--- be mostly untested.
---
--- A DEFAULT MISSING FROM HERE IS A KEY THAT NEVER FIRES. The raw layer reads
--- this table and nothing else, so a tap() registered with a key name that is
--- absent gets `vk[command] = nil`, is skipped by the frame loop entirely, and
--- shows as "Unbound" on a settings screen the player never touched. Add the
--- entry in the same commit as the binding.
local DEFAULT_VK = {
    SPACE = 0x20, TAB = 0x09, E = 0x45, G = 0x47, R = 0x52, B = 0x42,
    ['1'] = 0x31, ['2'] = 0x32, ['3'] = 0x33, ['4'] = 0x34, ['5'] = 0x35,
    -- N is push-to-talk (brptt) and it is also GTA's own INPUT_PUSH_TO_TALK
    -- default, which is why it was chosen. It has to be HERE or the raw layer
    -- skips the binding entirely and the row shows "Unbound" on a settings
    -- screen the player never touched -- see the note above this table.
    T = 0x54, Y = 0x59, Z = 0x5A, M = 0x4D, N = 0x4E, BACK = 0x08,
    -- ═══ 'LSHIFT' IS THE ENGINE'S NAME AND 0x10 IS THE RAW LAYER'S, AND THEY
    --     DELIBERATELY DISAGREE ═══
    --
    -- The vehicle boost is on left shift (brboost). RegisterKeyMapping's keyboard
    -- table has no plain 'SHIFT' -- it is LSHIFT and RSHIFT -- so the ENGINE side
    -- has to be told LSHIFT specifically.
    --
    -- The RAW side wants 0x10, which is VK_SHIFT, the GENERIC one. Three separate
    -- reasons, and they all point the same way:
    --
    --   * the raw natives read GTA's own 256-slot keyboard array, indexed by
    --     virtual-key code and fed from Windows keyboard messages -- and a
    --     WM_KEYDOWN for either shift carries wParam = VK_SHIFT (0x10). The
    --     side-specific 0xA0/0xA1 are never what lands in that slot.
    --   * the settings screen's capture is a browser keydown and reads
    --     `e.keyCode`, which is 16 for either shift. A rebind onto shift from our
    --     own screen therefore produces 0x10, so the default has to be 0x10 or a
    --     player who "rebound" it to the key it was already on would change its
    --     behaviour.
    --   * 0x10 is already in VK_NAME as 'Shift', so every prompt and every
    --     settings row renders it correctly with no change. 0xA0 would fall off
    --     the end of vkName and print '#160'.
    --
    -- The cost, stated: the boost answers to EITHER shift key rather than only
    -- the left one. That is a superset of what the pause-menu row claims and is
    -- the friendlier of the two errors.
    --
    -- AND IT HAS TO BE HERE AT ALL, which is the note above this table: a default
    -- missing from DEFAULT_VK is a key the raw layer skips entirely, showing as
    -- "Unbound" on a settings screen the player never touched.
    LSHIFT = 0x10,
    LEFT = 0x25, RIGHT = 0x27, UP = 0x26, DOWN = 0x28,
    F1 = 0x70, F2 = 0x71, F3 = 0x72, F4 = 0x73, F5 = 0x74,
}

--- One stored slot, as three distinct answers.
---
--- A number is a key. `false` (or a legacy 0) is "deliberately on no key". And
--- nil is silence, which is the only one that takes a default.
--- @return integer|false|nil
local function readSlot(stored)
    if stored == false or stored == 0 then return false end
    return tonumber(stored)
end

--- The saved-shape version, bumped when a stored binding has to MOVE.
---
--- 2 is the one that matters: the pause menu was F1 and is now Escape, and a
--- default only applies to somebody who has never saved anything -- everyone
--- who has played already has F1 written down. Without a migration the change
--- would land for new players only, and the owner asking for it would not get
--- it (2026-08-09). A version means it happens once and never fights a player
--- who then picks something else.
local KVP_VERSION = 2

--- Persist.
local function save()
    local keys = {}
    for c, v in pairs(vk) do keys[c] = v end
    SetResourceKvp(KVP, json.encode({ v = KVP_VERSION, keys = keys }))
end

local function load()
    if vk then return vk end
    vk = {}
    local version = 0
    local raw = GetResourceKvpString(KVP)
    if raw and #raw > 0 then
        local ok, res = pcall(json.decode, raw)
        if ok and type(res) == 'table' then
            -- THREE SHAPES, AND ALL OF THEM STILL LOAD. Flat (the first), a
            -- primary/alt pair (the second slot, since removed), and the
            -- versioned one. Nobody loses their bindings to a refactor they
            -- did not ask for.
            version = tonumber(res.v) or 0
            local keys = (type(res.keys) == 'table' and res.keys)
                      or (type(res.primary) == 'table' and res.primary)
                      or res
            for _, b in ipairs(BR.Keys.bindings) do
                local code = readSlot(keys[b.command])
                if code ~= nil then vk[b.command], chosen[b.command] = code, true end
            end
        end
    end

    -- THE MOVE TO ESCAPE, once. A player who has already bound the pause menu
    -- somewhere deliberate gets it moved too -- there is no way to tell "I
    -- chose F1" from "F1 was the default when I first played", and the owner's
    -- instruction was to put the menu on Escape. It is one line in the
    -- settings screen to move it back.
    if version < KVP_VERSION then
        vk['brpausemenu'] = 0x1B
        chosen['brpausemenu'] = nil
        if raw and #raw > 0 then
            local keys = {}
            for c, v in pairs(vk) do keys[c] = v end
            SetResourceKvp(KVP, json.encode({ v = KVP_VERSION, keys = keys }))
        end
    end

    for _, b in ipairs(BR.Keys.bindings) do
        -- `b.raw` is a raw-layer default that DIFFERS from the one registered
        -- with the engine -- the pause menu is Escape here and F1 there,
        -- because the engine cannot be given Escape and we can.
        if vk[b.command] == nil then vk[b.command] = b.raw or DEFAULT_VK[b.default] end
    end
    return vk
end

--- IS THIS BINDING BEING READ BY THIS LAYER, OR BY THE ENGINE?
---
--- THE QUESTION #129'S THIRD ROUND TURNED ON, AND THE ONE NOTHING WAS ASKING.
---
--- Our rebinder works by reading the keyboard itself: a rebind lands in the KVP
--- below and the frame loop watches the new virtual-key code. The ENGINE's copy
--- of the binding never moves -- nothing can change a RegisterKeyMapping
--- default from script, which is the entire reason this layer exists -- so an
--- action the engine is driving is an action sitting on its ORIGINAL key,
--- whatever the player has since chosen.
---
--- That was survivable while the split was all-or-nothing: either this layer
--- read every binding (and every rebind worked) or it read none (and the
--- settings screen said as much). The per-question split introduced for #129's
--- second round broke that symmetry. On a build without IS_RAW_KEY_DOWN the
--- layer keeps every TAP on the player's own key and quietly hands the HOLDS
--- back to the engine -- so `interact`, rebound to R, was being watched for by
--- nobody: this layer skips hold bindings in that mode, and the engine is
--- listening on E. Pressing R did nothing whatsoever. The crate would not open
--- (#129: "Welp, now trying to open a crate does nothing at all") and the loose
--- item would not be claimed, because the pickup rides the same press (#139).
---
--- One rule, and it is deliberately the exact complement of the test the frame
--- loop applies -- `code and (rawHolds or not b.hold)` under `rawActive`. Two
--- separately-written versions of "who owns this key" is how the prompt came to
--- name a key nothing was listening to; derived from the loop, they cannot
--- drift.
--- @param b table  one row of BR.Keys.bindings
--- @return boolean
local function engineDrives(b)
    if not BR.Keys.rawActive then return true end
    return b.hold and not BR.Keys.rawHolds
end

--- The code the ENGINE's own default for this binding sits on, or nil.
--- @param b table
--- @return integer|nil
local function engineCode(b)
    return b.raw or DEFAULT_VK[b.default]
end

--- Push the whole table to the interface.
function BR.Keys.push()
    local out = {}
    for _, b in ipairs(BR.Keys.bindings) do
        -- `or nil` folds the "deliberately unbound" false into absent: the
        -- screen draws both as "Unbound", and the wire should not carry a
        -- boolean in a field typed as a number.
        local code = load()[b.command] or nil
        -- THE SCREEN SHOWS THE KEY THAT WORKS, not the key we wrote down.
        --
        -- A row the engine is driving is on its default and cannot be moved.
        -- Drawing the player's stored choice for it is the same lie the world
        -- prompts were telling, in the one place they would go to fix it.
        local byEngine = engineDrives(b)
        if byEngine then code = engineCode(b) end
        out[#out + 1] = {
            group   = b.group,
            command = b.command,
            label   = (b.label:gsub('^Royale:%s*', '')),
            vk      = code,
            key     = code and (BR.Keys.vkName(code) or ('#' .. code)) or '',
            default = b.default,
            -- Whether this row is on its default, so the screen can offer a
            -- way back. It is the only way back for a key the capture cannot
            -- take -- Escape cancels a capture, so Escape can never be typed
            -- into one.
            custom  = (not byEngine) and chosen[b.command] == true,
            -- Additive, and the interface is free to ignore it: this row is
            -- the engine's and rebinding it here will not take. Sent so a
            -- screen that wants to say so has the fact rather than having to
            -- infer it from `raw` plus a hold flag it is not given.
            engine  = byEngine or nil,
        }
    end
    TriggerEvent('br:ui:sendLocal', BR.Nui.KEYBINDS,
        { actions = out, raw = BR.Keys.rawActive == true })
end

--- A readable name for a virtual-key code.
---
--- Only the ones a player is plausibly going to bind. Anything else falls back
--- to its number, which is ugly and honest -- better than a wrong name.
local VK_NAME = {
    [0x08] = 'Backspace', [0x09] = 'Tab', [0x0D] = 'Enter', [0x10] = 'Shift',
    -- ESCAPE WAS MISSING, and the pause menu's own default is Escape -- so
    -- every place that names the key printed "#27" (user, 2026-08-09).
    [0x1B] = 'Esc', [0x2C] = 'PrtSc', [0x91] = 'ScrLk', [0x13] = 'Pause',
    [0x11] = 'Ctrl', [0x12] = 'Alt', [0x14] = 'Caps', [0x20] = 'Space',
    [0x21] = 'Page Up', [0x22] = 'Page Down', [0x23] = 'End', [0x24] = 'Home',
    [0x25] = 'Left', [0x26] = 'Up', [0x27] = 'Right', [0x28] = 'Down',
    [0x2D] = 'Insert', [0x2E] = 'Delete',
    [0xBA] = ';', [0xBB] = '=', [0xBC] = ',', [0xBD] = '-', [0xBE] = '.',
    [0xBF] = '/', [0xC0] = '`', [0xDB] = '[', [0xDC] = '\\', [0xDD] = ']',
    [0xDE] = "'",
}
function BR.Keys.vkName(code)
    if VK_NAME[code] then return VK_NAME[code] end
    if code >= 0x30 and code <= 0x5A then return string.char(code) end   -- 0-9 A-Z
    if code >= 0x70 and code <= 0x7B then return 'F' .. (code - 0x6F) end -- F1-F12
    if code >= 0x60 and code <= 0x69 then return 'Num ' .. (code - 0x60) end
    return nil
end

--- The readable key a command is ACTUALLY on, or nil.
---
--- THE AUTHORITY WHEN THE RAW LAYER IS RUNNING, and the reason anything else
--- has to ask: the engine still believes its own RegisterKeyMapping default,
--- because nothing can change that from script. So GetControlInstructionalButton
--- kept answering "E" after interact was rebound to R, and every DUI prompt in
--- the world went on saying E (user, 2026-08-09).
--- @param command string
--- @return string|nil
--- @return string|nil label
--- @return boolean owned  true when this answer is ours and there is no
---                        sensible fallback -- an unbound action has NO key,
---                        and naming the engine's stale default for it is a
---                        prompt that lies.
function BR.Keys.labelFor(command)
    -- THE KEY THAT WORKS, AND ONLY EVER THE KEY THAT WORKS.
    --
    -- A prompt exists to tell the player which key to press. A prompt naming a
    -- key nothing is listening to is worse than no prompt at all, because it
    -- turns "this feature is unavailable" into "this feature is broken" -- and
    -- the player has no way to tell those apart from a chair. That is exactly
    -- what #129's third round was: the crate said R, the engine was listening
    -- on E, and the owner reported that opening a crate "does nothing at all".
    --
    -- So a binding the ENGINE is driving is named by the ENGINE's key. See
    -- engineDrives: this layer's rebind never reaches an action it is not
    -- reading, so our stored code is not an answer to the question being
    -- asked, however deliberately the player chose it.
    --
    -- The previous rule was "ours whenever we have an opinion", written to
    -- close a real gap -- with the raw layer off, the settings screen drew the
    -- rebind and the world prompts drew the engine's default, and the two
    -- openly disagreed (user, 2026-08-09: "the loot and crates still show R").
    -- They agree again here, and now they agree on the truth: BR.Keys.push
    -- draws the engine's key for those same rows.
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == command and engineDrives(b) then
            local code = engineCode(b)
            if not code then return nil end
            return BR.Keys.vkName(code) or ('#' .. code), true
        end
    end

    -- Anything this layer IS reading is ours to answer for, whether or not the
    -- player has moved it. The engine keeps the last word only for a command
    -- nobody here is watching at all.
    if not (BR.Keys.rawActive or chosen[command]) then return nil end
    local code = load()[command]
    if not code then return nil, chosen[command] == true end
    return BR.Keys.vkName(code) or ('#' .. code), true
end

--- The virtual-key code a command is ACTUALLY driven on, or nil.
---
--- THE NUMERIC TWIN OF labelFor, AND IT APPLIES THE SAME RULE FOR THE SAME
--- REASON. labelFor answers "what do I print"; this answers "what physical key
--- is this", which is the question anything suppressing an ENGINE control on
--- that key has to ask. Both defer to engineDrives: a row the engine is driving
--- sits on its original default whatever the player has since chosen, because
--- nothing can move a RegisterKeyMapping binding from script.
---
--- Derived from the same two helpers rather than re-deciding, for the reason
--- written at engineDrives: two separately-written versions of "who owns this
--- key" is how the world prompts came to name a key nothing was listening to.
--- @param command string
--- @return integer|nil
function BR.Keys.boundTo(command)
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == command then
            if engineDrives(b) then return engineCode(b) end
            return load()[b.command] or nil
        end
    end
    return nil
end

--- Is our pause menu the thing Escape opens?
---
--- ASKED BEFORE THE ENGINE'S OWN MENU IS SUPPRESSED, and that is the whole
--- point of it being a question rather than a constant. DisableFrontendThisFrame
--- takes GTA's pause menu away; doing that unconditionally would mean a player
--- who rebinds our pause menu to something else has no pause menu at all and
--- no way back. So the suppression follows the binding: hold Escape and the
--- frontend is ours, give Escape up and it is the engine's again.
---
--- THE rawActive TEST STAYS IN FRONT AND IS NOT FOLDED INTO boundTo. Without
--- the raw layer the engine drives this row, boundTo would answer with the
--- engine's own Escape default (0x1B, the `raw` argument on the tap) and the
--- frontend would be suppressed on precisely the client that has no other way
--- to reach a pause menu -- see the second of the two guards at the binding.
--- @return boolean
function BR.Keys.ownsEscape()
    if not BR.Keys.rawActive then return false end
    return BR.Keys.boundTo('brpausemenu') == 0x1B
end

--- Is this a command we registered?
local function known(command)
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == command then return b end
    end
    return nil
end

--- Put a command back on its default key, both slots.
---
--- The way back for a key the CAPTURE CANNOT TAKE. Escape cancels a capture --
--- it has to, or a player who opens the row by accident is trapped in it --
--- so Escape can never be typed into one, and the pause menu's own default is
--- Escape. Without this, rebinding pause once would be one-way.
--- @param command string
function BR.Keys.reset(command)
    local b = known(command)
    if not b then return false end

    load()
    vk[command] = b.raw or DEFAULT_VK[b.default]
    chosen[command] = nil

    save()
    BR.Keys.push()
    TriggerEvent('br:keys:changed')
    return true
end

--- Bind one command to one virtual-key code, or to nothing.
--- @param command string
--- @param code integer|nil  nil or 0 unbinds
function BR.Keys.set(command, code)
    local b = known(command)
    if not b then return false end

    -- A REBIND THAT CANNOT TAKE EFFECT IS REFUSED, NOT STORED.
    --
    -- The row this layer is not reading is the row the engine is driving, and
    -- the engine's key cannot be moved from script. Accepting the rebind wrote
    -- a preference that changed nothing, drew it on the settings screen and on
    -- every world prompt, and left the action on a key the player had every
    -- reason to believe they had abandoned -- which is #129's third round and
    -- #139 in one line. Saying no is a worse feature and a far better answer:
    -- the player learns immediately, and the action keeps working.
    if engineDrives(b) then
        -- The two ways to get here read differently to a player and the message
        -- says which: no raw layer at all is "this client cannot rebind
        -- anything", which the settings screen already announces; a hold on a
        -- build without the level native is one row out of twenty-one, and
        -- without being told, that row looks broken rather than unavailable.
        local why = (not BR.Keys.rawActive)
            and 'this client cannot read the keyboard directly'
            or 'this build has no IS_RAW_KEY_DOWN, so the game engine drives '
               .. 'hold actions'
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = ('%s stays on %s -- %s.'):format(
                (b.label:gsub('^Royale:%s*', '')), b.default, why),
            tone = 'warn', ms = 8000,
        })
        BR.Keys.push()
        return false
    end

    load()
    code = tonumber(code)
    if code == 0 then code = nil end

    -- CONFLICTS RESOLVE IN FAVOUR OF THE NEW BINDING, which is what every game
    -- does: whatever held that key is left unbound, and the screen shows which
    -- one lost it. Refusing instead would send the player hunting.
    if code then
        for c, v in pairs(vk) do
            -- FALSE, NOT NIL. Nil is "no opinion", and no opinion means the
            -- default comes back on the next restart -- onto the very key
            -- that just took this one, so the two collide again and the
            -- player has no way to see why.
            if c ~= command and v == code then
                vk[c], chosen[c] = false, true
            end
        end
    end
    vk[command] = code or false
    chosen[command] = true

    save()
    BR.Keys.push()
    -- ANYTHING THAT DRAWS A KEY HAS TO REDRAW IT. The world prompts cache
    -- their payload per entry, so without this the crate you are standing in
    -- front of keeps naming the old key until you walk away and back.
    TriggerEvent('br:keys:changed')
    return true
end

-- The reader. One FRAME callback over a table of at most eighteen entries,
-- which is two native calls each in the worst case and none at all when the
-- raw layer is off.
--
-- HOLD ACTIONS GET BOTH EDGES, which is the thing the console-command route
-- could not have given us without the +/- names being exactly right: press
-- fires true, release fires false, and `interact` keeps working as a hold.
local rawDown = {}

--- Whether the raw layer is currently being LIED TO about the keyboard.
---
--- THE STROBE, AND WHY THE FIRST FIX FOR IT WAS THE WRONG SHAPE (#90).
---
--- "holding tilde makes it flicker" (owner, 2026-08-16) -- and it was still
--- flickering after the first attempt, held down and watched. The mechanism, as
--- far as the engine will admit to one: taking or releasing the NUI cursor
--- disturbs the key state the raw natives read, which citizenfx/fivem#3064
--- reports for IS_RAW_KEY_DOWN by name. A key that is still physically held
--- reads UP and then DOWN again with no human involved. The loop below reads
--- that pair as a release and a fresh press, fires the tap, and the tap toggles
--- the very focus that produced it.
---
--- THAT IS A LOOP, NOT A GLITCH, and it is the loop that makes it a strobe
--- rather than one lost keystroke: focus change -> false press -> focus change.
--- The panel opens and shuts for as long as the key is down.
---
--- THE FIRST FIX MEASURED THE WRONG QUANTITY. It required a tap's key to have
--- read UP for 200ms before it could fire again -- a duration, chosen against a
--- guess at how long the disturbance lasts, and the disturbance turned out not
--- to fit inside the guess. A bigger number is not the next move. The number
--- was never the mechanism, and a constant tuned by trial is precisely what let
--- the transition-ordering bug survive for months behind a 450ms guess (#124).
---
--- SO THIS SUPPRESSES ON A STATE WE ACTUALLY KNOW. We know exactly when the
--- reading becomes untrustworthy, because br_ui says so: `br:ui:focusChanged`
--- is emitted by the same function that calls SetNuiFocus (br_ui/client/nui.lua,
--- applyFocus). From that event until the reading settles, a rising edge is
--- ADOPTED rather than fired -- the layer takes the new state as truth and tells
--- nobody. A focus change therefore cannot manufacture the tap that causes the
--- next focus change, which cuts the loop at the only point that closes it.
---
--- AND IT ENDS WHEN THE READING SETTLES, NOT AFTER AN INTERVAL. Any frame in
--- which a bound key changed state extends the window; the first quiet frame
--- after that closes it. When nothing was held as the menu opened -- the
--- ordinary case, every key already up -- that is two frames and costs nothing
--- measurable. When something was held, it lasts exactly as long as the engine
--- keeps changing its mind, which is the quantity the 200ms was trying to guess.
---
--- HOLDS ARE DELIBERATELY NOT SUPPRESSED. A hold's edges are not idempotent:
--- swallow a release and the revive or the crate pickup runs on with nothing
--- left to stop it, which is a scar dbno.lua already carries (owner,
--- 2026-08-09: a brief tap completed an entire eight-second revive). A hold
--- wrongly cancelled costs one more press; a hold never cancelled costs the
--- round. Only taps go quiet -- and only a tap can strobe anyway, because only
--- a tap toggles.
local resyncing = false
local resyncFrames = 0

--- Which native answers "is this key held right now".
---
--- Resolved once at start rather than per frame, and it is deliberately a
--- FUNCTION rather than a flag: IsRawKeyDown is the correct one and
--- IsRawKeyPressed is the fallback for a build that predates it -- on which
--- hold actions degrade to taps, which is a known and survivable loss, unlike
--- having no keys at all.
local rawDownFn = nil

--- ...AND WHETHER THAT FUNCTION ANSWERS A LEVEL OR AN EDGE, RECORDED BY THE
--- BRANCH THAT CHOSE IT.
---
--- This used to be re-derived at the far end as `rawDownFn == IsRawKeyDown`,
--- which asks the runtime a question it does not have to answer the same way
--- twice. FiveM's natives are globals materialised by the Lua runtime, and
--- comparing a stored reference against a fresh read of the global is a test
--- that can come back false while the native is present and working perfectly.
--- If it does, `rawHolds` goes false on a machine that has the level native,
--- every hold binding is handed to the engine for no reason, and the failure
--- that follows (see holdsOnEngine below) is silent.
---
--- The branch above already KNOWS which one it picked. Writing it down there
--- costs a local and cannot be wrong.
local rawLevel = false

--- A NATIVE'S ANSWER, TURNED INTO A LUA BOOLEAN. THIS IS #129's SEVENTH ROUND
--- AND THE ONLY LINE OF MECHANISM IN IT.
---
--- Everything downstream of the sample compares it with `==`:
---
---   keybinds.lua  `rawDown[b.command] == true`   -- is this frame an EDGE
---   keybinds.lua  `BR.Keys.held[action] == true` -- is the key down (isHeld)
---
--- and a FiveM native declared BOOL does not have to hand Lua a boolean. This
--- codebase has already been bitten twice by the same runtime: natives.lua's
--- shape test compares `hit == 1 or hit == true`, and spawn.lua's screen-fade
--- reply compares `== true or == 1`. Both were written after the value arrived
--- as a number in play and matched nothing.
---
--- Store `1` here instead of `true` and BOTH of those comparisons fail forever,
--- from one cause, in opposite directions:
---
---   `was` is permanently false, so `down ~= was` is true on EVERY frame the
---   key is held -- a tap fires once per frame instead of once per press. One
---   press of the trail key registered 545 presses and toggled the smoke 545
---   times (owner, #131, 2026-08-16).
---
---   `BR.Keys.held.interact` holds `1`, so isHeld() returns false on every
---   frame -- the crate hold is alive and earns nothing. 446 frames alive,
---   0 of 1000ms earned, 0% duty (owner, #129, 2026-08-16).
---
--- Neither instrument could see it. /brprobe rawkey counted with `if ok and v`,
--- a TRUTHINESS test, so "IsRawKeyDown true on 576 frames" proved only that the
--- value was truthy and the probe then printed that the key layer was
--- exonerated. tools/test_client.lua stubbed the native as `keys[vk] == true`,
--- a strict boolean, so the suite agreed with the broken code and passed 202/202
--- with the interaction dead on the real client.
---
--- ZERO IS FALSE, AND THAT IS WHY THIS IS NOT `v and true or false`. In Lua the
--- number 0 is TRUTHY, so the one-liner normalisation would map a native that
--- answers 1/0 to "held forever" -- a worse bug than the one being fixed, and
--- indistinguishable from it in a paste. Only the values that can actually mean
--- "not down" -- nil, false, 0 -- are false here, and every other answer is
--- true. That covers all four shapes the runtime is known to produce
--- (true/false, 1/0, 1/false, 1/nil) without needing to know which one this
--- build uses.
--- @param v any
--- @return boolean
local function truth(v)
    if v == nil or v == false or v == 0 then return false end
    return true
end

BR.Loop.register(BR.Loop.FRAME, 'keybinds.raw', function()
    if not BR.Keys.rawActive then return end

    local map = load()
    -- Did the keyboard move at all this frame? Only used while resyncing, where
    -- it is the whole termination condition: the window lasts until the reading
    -- stops changing, rather than for a length of time somebody picked.
    local moved = false

    for _, b in ipairs(BR.Keys.bindings) do
        local code = map[b.command]
        -- A HOLD BINDING IS ONLY OURS IF WE CAN ANSWER WHAT A HOLD ASKS.
        -- Without IsRawKeyDown this loop can see the press and never the
        -- release, so it would fire a press and then a bogus release on the
        -- very next frame -- and it would ALSO be shadowing the engine's +/-
        -- pair, which can do the job properly. See the note on rawHolds at the
        -- hold() registrar; skipping the binding here is what hands it back.
        if code and (BR.Keys.rawHolds or not b.hold) then
            -- EDGES ARE DERIVED, NOT ASKED FOR.
            --
            -- The first cut called IS_RAW_KEY_JUST_PRESSED, which DOES NOT
            -- EXIST -- only IS_RAW_KEY_PRESSED is declared in
            -- fivem/ext/native-decls. So the probe threw, the layer refused
            -- to start, and the settings screen honestly reported that
            -- rebinding was unavailable (user, 2026-08-09: "not sure why I
            -- got 'Rebinding is unavailable'"). It was right; the native was
            -- imaginary.
            --
            -- One native and a remembered bit gives both edges, which is all
            -- the missing one would have done anyway.
            -- IS_RAW_KEY_DOWN, NOT IS_RAW_KEY_PRESSED, and the names are a
            -- trap. In FiveM's implementation (InputNatives.cpp, over GTA's
            -- own ioKeyboard arrays):
            --
            --   KeyDown(k)    = keys[active][k]                -- HELD
            --   KeyPressed(k) = keys[active][k] & changed(k)   -- JUST pressed
            --
            -- So IsRawKeyPressed is an EDGE, true for a single frame. Reading
            -- it as a held state meant every hold action released itself on
            -- the very next frame: opening a crate stopped needing a hold and
            -- became a tap (user, 2026-08-09: "why do I no longer have to
            -- HOLD the pickup button"). The edges below are derived from the
            -- state, so the state is what this has to ask for.
            -- NORMALISED AT THE SAMPLE, WHICH IS THE ONE PLACE IT CAN BE DONE
            -- ONCE. `down` is written into BR.Keys.held, into rawDown, and
            -- passed to every listener through fire() -- three consumers, two
            -- of which test it with `== true`. Converting here means none of
            -- them can ever see the native's own shape. See truth() above for
            -- what went wrong when they did.
            local down = truth(rawDownFn(code))
            local was = rawDown[b.command] == true

            -- A HELD FLAG THAT IS ONLY EVER WRITTEN ON AN EDGE IS A LATCH, AND
            -- A LATCH CAN BE LEFT ON.
            --
            -- BR.Keys.held is what every hold interaction in the game asks
            -- ("is the player still holding this?") and until now the only
            -- thing that ever wrote it was fire(), on a transition. So the
            -- answer was not the key's state, it was a memory of the last
            -- transition anybody noticed -- and one missed release edge left it
            -- saying "held" for as long as nothing else moved that key. dbno.lua
            -- has the scar: a brief tap completed an entire eight-second revive
            -- in playtest (owner, 2026-08-09), because the stop was raised and
            -- did not land, and nothing afterwards re-checked. The crate hold
            -- has the same shape and #129 is the same complaint about it.
            --
            -- HOLD ACTIONS ONLY, and deliberately. For a hold the raw native
            -- already answers the exact question every frame, so trusting the
            -- sample over the memory costs nothing and a lost edge self-corrects
            -- on the very next one. A tap has no held state worth the name, and
            -- writing one here would fight the resync window below -- which
            -- exists precisely because this key state is NOT trustworthy across
            -- a focus change. That is also the trade being made: a dropped
            -- frame of key state now cancels a hold in progress rather than
            -- being ridden out. For a hold that is the safe side to be wrong on
            -- -- you press again -- and it is the side the owner asked for.
            --
            -- AND IT IS ONLY REACHABLE WHEN THE SAMPLE IS A LEVEL. The branch
            -- above admits a hold binding only under rawHolds, so `down` here
            -- is always IsRawKeyDown's answer -- never the edge fallback's,
            -- which would write "not held" on fifty-nine frames in every sixty
            -- and make a hold arithmetically impossible (#129, second round).
            --
            -- AND IT IS FORCED FALSE WHILE A SCREEN OWNS THE KEYBOARD, which
            -- is the half of the focus gate that no edge can deliver. dbno.lua
            -- and loot.lua do not wait for a press: dbno.lua:1069 starts a
            -- revive from `BR.Keys.isHeld('interact')` on any frame the target
            -- is in range, and loot.lua:305 advances its accumulator the same
            -- way. Suppressing only the EDGES would leave a player who opened a
            -- panel mid-hold reviving a squadmate while they type. The state is
            -- what those two read, so the state is what has to go quiet.
            if b.hold then
                BR.Keys.held[b.action] = down and not BR.Keys.uiOwnsKeyboard
            end

            if down ~= was then
                moved = true
                rawDown[b.command] = down or nil

                if BR.Keys.uiOwnsKeyboard then
                    -- ADOPTED, NOT ANNOUNCED -- the same move the resync window
                    -- makes, for a longer reason. `rawDown` above has already
                    -- taken the new state, so this layer never ends up
                    -- disagreeing with the keyboard and no key can latch: when
                    -- the screen lets go, a key that is still physically down
                    -- reads as no edge at all and waits to be released and
                    -- pressed again, which is what a player would expect after
                    -- typing.
                    --
                    -- The release edge that ENDS a live hold is not lost by
                    -- being swallowed here: it was already delivered, once, at
                    -- the moment the screen took the keyboard. See endHolds()
                    -- below the loop.
                elseif b.hold then
                    -- Both edges, always, resync or not. See the note on
                    -- `resyncing`: a swallowed release leaves a revive or a
                    -- crate pickup running with nothing left to stop it.
                    fire(b.action, down)
                elseif down and not resyncing then
                    fire(b.action, true)
                    fire(b.action, false)
                end
                -- The `elseif` above is the whole of the strobe fix. A rising
                -- edge inside the resync window still updates rawDown -- the
                -- layer ADOPTS the new state, so it is not left disagreeing
                -- with the keyboard -- it simply does not announce it. A focus
                -- change cannot then produce the tap that produces the next
                -- focus change.
            end
        end
    end

    -- THE WINDOW CLOSES WHEN THE KEYBOARD GOES QUIET, and never on a clock.
    --
    -- A frame in which something changed is evidence the engine is still
    -- settling, so it extends the window. The floor of one frame is not a
    -- tuning knob: the disturbance cannot be observed on the same frame the
    -- focus change was announced, so exiting immediately would be exiting
    -- before there was anything to see.
    if resyncing then
        if resyncFrames > 0 and not moved then
            resyncing = false
        end
        resyncFrames = resyncFrames + 1
    end
end)

-- THE ONE EVENT THAT MEANS "STOP TRUSTING THE KEYBOARD".
--
-- br_ui emits this from applyFocus, in the same breath as SetNuiFocus (see
-- br_ui/client/nui.lua), and TriggerEvent crosses resources -- the same hop
-- br_core and br_ui already use in both directions. Every SetNuiFocus call in
-- the project is covered by one: the bridge only changes `held` when the top of
-- the stack changes, and the top of the stack changing is exactly what this
-- announces.
--
-- IT DOES NOT CARE WHICH SCREEN. Any focus change disturbs the reading, and a
-- layer that only distrusted the keyboard for the screens it expected to be
-- opened would be back to reasoning about a list somebody has to remember to
-- update -- which is the mistake BR.FocusKeepsInput's allowlist note is about.
--
-- ...AND THE GATE BELOW DOES CARE, WHICH IS NOT A CONTRADICTION. The resync
-- window is about whether the READING can be trusted, and every focus change
-- disturbs it equally. The gate is about whether the ANSWER should be acted on,
-- and that is a property of the screen: see setUiKeyboard.

--- End every hold that is live right now, cleanly, once.
---
--- THE RELEASE THAT NOBODY WILL EVER SEND. A player holding E to open a crate
--- who then opens a panel is a player whose next release edge is not coming:
--- with the raw layer suppressed the loop adopts it silently, and on a client
--- where the ENGINE drives holds the `-brinteract` command is the only writer
--- of that flag and the engine has stopped delivering keys at all. Either way
--- BR.Keys.held stays true, and a true `held` is not a stale boolean -- it is a
--- revive that keeps running (dbno.lua re-arms from isHeld with no press edge)
--- and a crate that keeps counting.
---
--- So the moment a screen takes the keyboard, every live hold gets its release
--- delivered here, through fire() -- the same function and the same listeners a
--- real release would reach, so nothing downstream can tell the difference.
--- Once, on the transition, and never again while the gate is closed.
---
--- THE OTHER DIRECTION IS DELIBERATELY NOT SYMMETRICAL. Nothing is re-pressed
--- when the screen lets go, even if the key is still down. A hold wrongly
--- cancelled costs one more press; a hold wrongly RESUMED, on a key the player
--- has been resting on while typing, is the eight-second revive that dbno.lua
--- already has a scar from.
local function endHolds()
    for _, b in ipairs(BR.Keys.bindings) do
        if b.hold and BR.Keys.held[b.action] == true then
            fire(b.action, false)
        end
    end
end

--- WHICH SCREENS TAKE THE KEYBOARD AWAY FROM THE GAME, AND WHY THE ANSWER IS
--- NOT WRITTEN HERE.
---
--- THE SIGNAL IS BR.FocusResolve, IN br_lib, AND IT IS THE SAME CALL br_ui
--- APPLIES. br_ui/client/nui.lua's applyFocus resolves the stack and hands the
--- answer straight to the engine -- `SetNuiFocus(want.held, want.held)` and
--- `SetNuiFocusKeepInput(want.keepInput)` -- and `keepInput` is exactly the
--- question this gate asks: is the game still reading the keyboard underneath
--- this screen. A screen in BR.FocusKeepsInput keeps it; every other screen
--- takes it, and there is one entry in that table (`inventory`).
---
--- SO THIS RESOLVES THE SCREEN NAME THE EVENT ALREADY CARRIES, RATHER THAN
--- BEING TOLD THE ANSWER. Two ways to learn it were available and this is the
--- one that cannot drift:
---
---   * Reading BR.FocusKeepsInput directly would be a second copy of
---     FocusResolve's rule, and the whole reason that function is pure and in
---     br_lib is that this decision has been got wrong twice already (see the
---     note above it).
---   * Widening `br:ui:focusChanged` to carry keepInput would work until the
---     two resources are on different versions -- restart br_core alone and
---     br_ui is still sending one argument, so the field arrives nil, `nil ~=
---     true` reads as "takes the keyboard", and the INVENTORY -- the one screen
---     that must keep it -- is the screen that breaks. Deriving it locally from
---     a table both resources load out of br_lib has no such window.
---
--- `keepInput` DEPENDS ONLY ON THE TOP OF THE STACK, which is why a
--- one-element stack is a faithful question and not a trick: FocusResolve reads
--- `stack[n]` and nothing else. 'none' is that function's own sentinel for an
--- empty stack, and it means no screen holds anything.
--- @param screen string|nil  the top of br_ui's focus stack, or 'none'
local function setUiKeyboard(screen)
    local want = false
    if screen ~= nil and screen ~= 'none' then
        want = not BR.FocusResolve({ screen }).keepInput
    end
    if want == BR.Keys.uiOwnsKeyboard then return end
    BR.Keys.uiOwnsKeyboard = want
    -- Only on the way IN. On the way out there is nothing to unwind: the loop
    -- has been keeping `rawDown` honest the whole time, so it already agrees
    -- with the keyboard.
    if want then endHolds() end
end

AddEventHandler('br:ui:focusChanged', function(screen)
    resyncing = true
    resyncFrames = 0
    setUiKeyboard(screen)
end)

-- UI actions arrive through br_ui's forwarder, the same road the locker and
-- the inventory take: br_ui owns the page and the callbacks, br_core owns
-- what they mean.
AddEventHandler('br:ui:action', function(name, data)
    if name ~= BR.NuiCb.KEYBIND_SET then return end
    local command = tostring(data and data.command or '')
    if data and data.reset then
        BR.Keys.reset(command)
        return
    end
    BR.Keys.set(command, data and data.vk)
end)

AddEventHandler('br:ui:ready', function()
    BR.Keys.push()
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    -- PROBED, NOT ASSUMED, and the fallback is the status quo. If this build
    -- has no raw-key natives the flag stays false, the RegisterKeyMapping
    -- handlers keep working exactly as they always have, and the settings
    -- screen says so rather than offering a rebinder that cannot bind.
    -- IS_RAW_KEY_PRESSED, and only that one: it is the single raw-key native
    -- actually declared (CFX, client, takes a Windows virtual-key code). The
    -- "just pressed" and "just released" variants that would have been
    -- convenient do not exist, which is what the first version probed for and
    -- correctly failed to find.
    -- IS_RAW_KEY_DOWN FIRST. It is the one that reports a HELD key; the
    -- similarly named IsRawKeyPressed is a single-frame edge, and reading it
    -- as a state is what turned every hold action into a tap.
    local ok = pcall(function() return IsRawKeyDown(0x77) end)
    if ok then
        rawDownFn, rawLevel = IsRawKeyDown, true
    else
        ok = pcall(function() return IsRawKeyPressed(0x77) end)
        if ok then rawDownFn, rawLevel = IsRawKeyPressed, false end
    end
    BR.Keys.rawActive = ok
    -- TWO FLAGS, BECAUSE THERE ARE TWO QUESTIONS. See the note on the hold()
    -- registrar: `rawActive` is "this layer is reading the keyboard",
    -- `rawHolds` is "and it can tell a held key from a pressed one". Only the
    -- level native can, and the whole of #129's second round is a hold that was
    -- being driven by a layer answering the wrong one.
    --
    -- ASKED OF `rawLevel`, NOT OF A POINTER COMPARISON. The previous version
    -- read `rawDownFn == IsRawKeyDown`, which is a question about the runtime's
    -- global table rather than about this build's capabilities -- see the note
    -- on rawLevel. A false answer there silently moves every hold action onto
    -- the engine's key, which on a client that has rebound one is an
    -- interaction that stops responding entirely (#129 third round, #139).
    BR.Keys.rawHolds = ok and rawLevel
    print(('[br_core] raw key layer %s%s'):format(
        ok and 'active' or 'UNAVAILABLE',
        (ok and not BR.Keys.rawHolds)
            and ' (no IsRawKeyDown: hold actions stay on the engine binding)'
            or ''))
    load()
    BR.Keys.push()

    -- WHO HOLDS THE KEYBOARD RIGHT NOW? ASKED, BECAUSE br_core CAN RESTART
    -- UNDER A SCREEN THAT IS ALREADY UP.
    --
    -- The gate is edge-driven -- it learns from `br:ui:focusChanged`, and that
    -- event fires when the top of br_ui's stack CHANGES. A br_core restart
    -- changes nothing over in br_ui, so no event is coming: this fresh state
    -- would sit at its safe default and let every key through underneath an
    -- open panel until the player next opened or closed something.
    --
    -- br_ui answers this by re-announcing the screen it last announced, so the
    -- gate is recoverable rather than only reachable. Nothing answering -- a
    -- br_core that started first, which is the ordinary case -- leaves the flag
    -- at false, which is where it already was.
    BR.Keys.uiOwnsKeyboard = false
    TriggerEvent('br:ui:focusAsk')
end)

RegisterCommand('brkeys', function(_, args)
    if args[1] == 'reset' then
        vk, chosen = nil, {}
        DeleteResourceKvp(KVP)
        load()
        BR.Keys.push()
        print('[br_core] keybinds reset to defaults')
        return
    end
    print('=== keybinds ===')
    -- `holds` IS THE LINE TO READ WHEN A HOLD DOES NOT COMPLETE (#129). false
    -- with the layer active means IsRawKeyDown is missing on this build and the
    -- hold actions are being driven by the engine's +/- pair instead, which is
    -- correct but means our own rebinder does not own them.
    print(('  raw layer: %s   holds: %s   escape is ours: %s'):format(
        tostring(BR.Keys.rawActive), tostring(BR.Keys.rawHolds),
        tostring(BR.Keys.ownsEscape())))
    -- THE ONE READING THAT SAYS WHETHER THE STROBE FIX IS EVEN RUNNING. If a
    -- panel is still flickering and this has never left 0 frames, the focus
    -- event is not arriving from br_ui and the window has never opened -- which
    -- is a different fault from the window opening and being too short, and the
    -- two are indistinguishable from a chair.
    print(('  resync   : %s   frames since the last focus change: %d'):format(
        resyncing and 'OPEN (taps suppressed)' or 'closed', resyncFrames))
    -- AND THE READING THAT SAYS WHETHER THE KEYBOARD IS OURS AT ALL. "My keys
    -- do nothing" and "my keys do too much" are the same paste from a chair,
    -- and this line separates them: CLOSED with no menu on screen is a gate
    -- that stuck, which is the one failure mode of this fix that is worse than
    -- the bug, and it is fixed from here with `brfocus clear`.
    print(('  ui input : %s'):format(BR.Keys.uiOwnsKeyboard
        and 'CLOSED -- a NUI screen owns the keyboard, key actions suppressed'
        or  'open   -- key actions reach the game'))
    -- WHAT THE KEY ACTUALLY IS, WHO IS LISTENING FOR IT, AND WHETHER IT IS
    -- DOWN RIGHT NOW -- the three questions a stuck interaction raises.
    --
    -- Printing the stored code alone is what made #129's third round unreadable
    -- from a paste: interact said R, the engine was on E, and this line agreed
    -- with the lie. `via engine` on a row means the stored rebind does not
    -- apply and the key printed is the engine's -- which is now also what the
    -- prompt and the settings screen say.
    --
    -- `held` came from debug.lua's DUPLICATE of this command (#137). That file
    -- registered a second `brkeys` and, loading last, silently won -- so
    -- everything above this loop was unreachable and the diagnostics added for
    -- #90 and #129 printed for nobody. Its held column was the only thing it
    -- had that this did not, so it moved here and the duplicate is gone.
    for _, b in ipairs(BR.Keys.bindings) do
        local byEngine = engineDrives(b)
        local code = byEngine and engineCode(b) or load()[b.command]
        print(('  %-9s %-28s %-10s %-11s held=%s'):format(b.group, b.label,
            code and (BR.Keys.vkName(code) or ('#' .. code)) or '(unbound)',
            byEngine and 'via engine' or '',
            tostring(BR.Keys.isHeld(b.action))))
    end
    print('  usage: brkeys [reset]')
end, false)

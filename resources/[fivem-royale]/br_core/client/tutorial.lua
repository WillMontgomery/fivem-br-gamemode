-- The guided first run (#261) -- the client side of it.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT IS HERE TODAY, AND WHAT IS NOT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ONE DEV COMMAND, AND THAT IS THE WHOLE FILE FOR NOW. `/brtutorial` starts and
-- stops the lobby walkthrough so it can be looked at, criticised and have its
-- copy rewritten before any of the machinery that will really start it exists.
--
-- Owner, 2026-09-04: "Is there a client command to force the tutorial to start
-- while in lobby?" There was not, and that was the gap -- the cards, the ring
-- and the sequencer all landed in 2294fe3 with nothing able to mount them,
-- which is this project's own orphaned-subsystem pattern and worth not
-- repeating for a whole feature.
--
-- WHAT IS STILL TO COME: the first-match checkbox that turns Ready up into
-- Start tutorial, the persisted "already offered" flag, and the Help page
-- re-run. All three will send this same NUI message and nothing on the page
-- will change when they do -- which is the point of putting the message in
-- first and the callers after.
--
-- ═══ IT IS DEV-GATED FOR FREE, AND MUST STAY THAT WAY ═══
--
-- br_lib/shared/devgate.lua wraps RegisterCommand for the whole project, so
-- this answers only on a box with `br_devMode` true. tools/verify.sh pins that
-- gate to an allowlist of exempt names and this is not one of them. A player
-- reaching the walkthrough will do it through the checkbox, not through here.
--
-- ═══ LUA OWNS WHETHER IT IS RUNNING ═══
--
-- The page mirrors this rather than holding it, in the same shape BR.Nui.FRONTEND
-- already uses: a reload, a re-focus or a screen change cannot leave the
-- walkthrough running with nothing driving it, because the answer is always
-- whatever Lua last said.

BR = BR or {}
BR.Tutorial = BR.Tutorial or {}

--- A FiveM BOOL is 1 or 0, and 0 is TRUTHY in Lua.
---
--- The file-local every client module in this tree carries, for the reason
--- tools/verify.sh's bool-natives ratchet exists: `if IsDisabledControlJustPressed(...)`
--- is true on every frame, pressed or not.
local function isTrue(v) return v == true or v == 1 end

--- The arrows, and what each one does to a card.
---
--- ═══ THE CARDS TAKE NO CURSOR, SO THE KEYS ARE READ HERE ═══
---
--- Owner, 2026-09-05: "In-game we should actually get rid of the mouse pointer
--- for these cards altogether I think and use left/right arrow keys instead."
---
--- The page cannot do this for itself. Without NUI focus CEF receives no
--- keyboard events at all, so a `keydown` listener in React would never fire --
--- which is exactly why client/spectate.lua reads its own arrows and its header
--- records that joining the focus stack "would silently kill the arrow keys that
--- ARE the feature". Same shape, same reason.
---
--- IDS VERIFIED IN-TREE, not guessed: client/revivekey.lua's ruler names
--- 172/173/174/175 as UP/DOWN/LEFT/RIGHT and blocks the same four.
---
--- DOWN IS THE CARD'S ACTION, and it is the one choice here that is mine. One
--- card offers to open the player list for a player whose keyboard cannot reach
--- their bound key; with no cursor that offer needs a key of its own. DOWN is in
--- the same cluster as the other two, and nothing else in this project claims
--- it. Enter was the other candidate and was rejected because it opens chat.
local NAV = {
    [174] = 'back',
    [175] = 'next',
    [173] = 'action',
}

--- What the cards take away from the game while they are on screen.
---
--- ═══ THE CURSOR AND THE CAMERA WERE FIGHTING OVER ONE MOUSE ═══
---
--- Owner, 2026-09-05: "the cursor isn't exclusively set to NUI -- it's still
--- moving the game camera while in the game tutorial." Both halves of that are
--- working as built and the combination is the bug: `tutorial` is in
--- BR.FocusKeepsInput so the player can walk to the crates, and keeping input
--- keeps ALL of it -- so every drag toward a Next button also swung the camera.
---
--- SO IT IS SUBTRACTIVE RATHER THAN A DIFFERENT FOCUS. Taking the keyboard away
--- instead would stop them walking, which two of these cards ask them to do.
--- Naming the four controls that conflict with a cursor leaves movement,
--- sprint, jump and the map key exactly as they were.
---
--- ATTACK AND AIM ARE IN HERE FOR THE SAME REASON AND NOT AS A SAFETY RULE.
--- The click that presses Next is the click that fires the weapon, so without
--- these a player works through the walkthrough emptying a magazine into the
--- pad. Warmup damage is off; the noise, the recoil and the empty gun are not.
--- THE LOOK AND ATTACK BLOCKS ARE GONE WITH THE CURSOR. They existed because
--- the cards held NUI focus with input kept, so a drag toward a button swung the
--- camera and a click on one fired the weapon. With no focus there is no cursor,
--- no drag and no click -- the player is simply playing the game with three keys
--- borrowed. Blocking the camera now would stop them looking at the crates they
--- are being sent to.
---
--- WHAT IS BLOCKED IS THE THREE KEYS THEMSELVES, so a press that moves a card
--- cannot also do whatever else that arrow is bound to. `specNext`/`specPrev`
--- default to RIGHT/LEFT (client/keybinds.lua) and are only live while
--- spectating, which never overlaps warmup -- but a default is not a guarantee
--- once the player has rebound anything, and this costs one native per key.
local BLOCKED = { 172, 173, 174, 175 }

--- Is the lobby walkthrough running right now?
local running = false

--- Is the lobby OFFERING it -- the checkbox beside Ready up?
---
--- ═══ TWO FLAGS, BECAUSE THEY ARE TWO MOMENTS ═══
---
--- `offer` is the one-time invitation a brand new player meets: a checkbox,
--- default on, that turns Ready up into Start tutorial. `running` is the
--- walkthrough itself. A player can be offered it and decline, and a player can
--- be running it without ever having been offered -- which is the Help page
--- re-run (#261). Collapsing them into one flag would make the re-run impossible
--- to express.
local offering = false

--- Is the IN-GAME walkthrough running?
---
--- A THIRD FLAG, AND THEY ARE THREE MOMENTS. `offering` is the invitation in
--- the lobby, `running` is the lobby walkthrough, and this is the one that runs
--- over the HUD during warmup. They are not stages of one thing -- a player can
--- take the lobby half and decline the match half, and the Help page re-run
--- reaches the lobby half having never been offered anything.
local inGame = false

--- Is the SERVER still holding this match's warmup for us?
---
--- ═══ THE CARDS AND THE CLOCK END AT DIFFERENT MOMENTS ═══
---
--- Owner, 2026-09-07: "The last part of the in-game tutorial should be showing
--- them the timer - THIS is when matchmaking should take place and the timer
--- appears for the first time on their screen."
---
--- So the last card is ABOUT the countdown, which means the countdown has to be
--- running while they read it -- a card pointing at a timer frozen a day out is
--- pointing at nothing. The hold is therefore released when they REACH that
--- card, and the walkthrough itself ends when they dismiss it.
---
--- One flag could not say that: `inGame` is what draws the cards, and dropping
--- it to start the clock would take the last card off the screen at the moment
--- it appeared.
local holding = false

--- How many of the four warmup crates this player has opened during the run.
---
--- ═══ COUNTED HERE BECAUSE THE PAGE CANNOT SEE IT AT ALL ═══
---
--- Owner, 2026-09-05: "'go and open one' should not have a 'next' button as
--- we're waiting for their action as we've directed them." So the card needs a
--- fact -- "they opened one" -- and the page has no version of it: opening a
--- crate puts nothing in the inventory, br_core/client/loot.lua sends no NUI
--- message of any kind, and the server sends no notification on the chest path.
--- The whole receipt is the crate being re-announced as its husk, which is a
--- Lua-side fact in another file.
---
--- ZEROED WHEN THE RUN STARTS, not accumulated across a session: the card asks
--- for one crate opened NOW, and a player on their second run through the Help
--- page would otherwise walk past it having opened one an hour ago.
local crates = 0

--- How many map waypoints they have dropped during the run. See the handler.
local waypoints = 0

--- Push the walkthrough's state to the page.
local function publish()
    TriggerEvent('br:ui:sendLocal', BR.Nui.TUTORIAL,
                 { run = running, offer = offering, game = inGame,
                   crates = crates, waypoints = waypoints })
end

--- Start or stop the walkthrough, and tell the page.
---
--- IDEMPOTENT, deliberately. `/brtutorial` twice in a row is a person checking
--- whether it worked, not a request to restart from the top -- and restarting
--- would throw away the step they were reading.
--- @param on boolean
--- Tell the SERVER whether this player is in the tutorial at all.
---
--- ONE FACT FOR TWO HALVES. Matchmaking, the warmup clock and party eligibility
--- care only whether the player is in ANY of it -- see BR.Roster.setTutorial --
--- so the server gets one boolean and this file owns the OR.
local function tellServer()
    -- TWO HOLDS, TWO ANSWERS. `on` is the matchmaking exemption, which only the
    -- LOBBY half can hold (BR.Roster.setTutorial's B1). `game` is the warmup
    -- hold, which only a player already on the pad can (setTutorialGame). They
    -- are granted from opposite states, so one boolean could never have carried
    -- both.
    TriggerServerEvent(BR.Net.TUTORIAL_SET,
                       { on = running or inGame, game = holding })
end

function BR.Tutorial.set(on)
    on = on == true
    if on == running then return end
    running = on

    -- ═══ TAKING THE OFFER SPENDS IT, AND LUA HAS TO BE THE ONE TO SAY SO ═══
    --
    -- The page cleared its own copy of `offer` when the player pressed Start
    -- tutorial, and Lua did not -- so the next `publish()` re-asserted
    -- `offer = true` and the toggle came back, which it did the moment the run
    -- ended and Ready up unlocked (owner, 2026-09-04: "After completing the
    -- lobby tutorial for some reason the 'new player tutorial' toggle
    -- re-appears when the 'ready up' button unlocks.").
    --
    -- THE PAGE MIRRORS THIS FLAG, IT DOES NOT OWN IT. That is the whole point of
    -- Lua holding it, and it means a page-side clear is a repaint rather than a
    -- decision -- correct until the next push, and then silently undone.
    if running then offering = false end

    publish()

    -- ═══ AND THE SERVER HAS TO HEAR IT, WHICH IS THE WHOLE POINT ═══
    --
    -- A player mid-walkthrough must not be matchmade, must be on no warmup
    -- clock and must not be in a party (owner, 2026-09-04). All three are
    -- enforced on the SERVER -- BR.Roster.setTutorial, and the refusals it
    -- feeds in server/party.lua -- because a client that decides for itself
    -- whether it may be matchmade is not a rule, it is a suggestion.
    --
    -- SO THIS LINE IS LOAD-BEARING AND ITS ABSENCE IS SILENT. Everything on the
    -- far side of it was built and tested first, and until this call existed it
    -- was a rule nothing switched on: the walkthrough would run and the player
    -- would be dealt into a match halfway through it, with no error anywhere.
    -- That is this project's orphaned-subsystem pattern and it is worth naming
    -- at the one line that closes it.
    --
    -- `on = false` IS BELIEVED ON SIGHT at the far end; `on = true` is a request
    -- the server rules on. See BR.Roster.setTutorial for what bounds it -- it is
    -- granted only from a standing start, and it costs the player their place in
    -- the queue and their party, which is what stops it being a dodge button.
    tellServer()
end

--- Start or stop the IN-GAME walkthrough.
---
--- IT SHARES THE SERVER-SIDE HOLD WITH THE LOBBY HALF, deliberately: both are
--- "this player is in the tutorial" as far as matchmaking, the warmup clock and
--- parties are concerned, and the server has one flag for that fact. So this
--- goes through BR.Tutorial.set for the net message rather than sending its own,
--- and the hold lifts when BOTH halves are done.
--- @param on boolean
function BR.Tutorial.game(on)
    on = on == true
    if on == inGame then return end
    inGame = on
    -- FROM ZERO EVERY TIME. See `crates`.
    if on then crates, waypoints = 0, 0 end
    -- THE HOLD RISES WITH THE CARDS AND CAN FALL BEFORE THEM. See `holding`.
    holding = on
    publish()

    -- ═══ NO FOCUS, AND THAT IS THE POINT ═══
    --
    -- This used to push a `tutorial` focus so the cards' Next and Last buttons
    -- could be clicked. It cost more than it bought: the focus kept game input
    -- so the buttons could be reached without freezing the player, and keeping
    -- input keeps ALL of it -- so the same mouse drove both the cursor and the
    -- camera, and the cursor made every invisible control on the faded lobby
    -- clickable underneath (owner, 2026-09-05, both faults).
    --
    -- The cards are driven by `tutorial.nav` above instead. Nothing is pushed,
    -- nothing has to be popped, and a run that ends badly cannot strand anybody
    -- holding a focus nothing will release.

    -- ═══ THE MARKERS ARE NOT THIS FILE'S BUSINESS ANY MORE ═══
    --
    -- This used to switch the four rarity cones on with the walkthrough and off
    -- with it. They are on for everybody in warmup now (owner, 2026-09-06: "the
    -- colored markers over the crates should always be shown in warmup
    -- regardless of tutorial state, even for players not in the tutorial"), so
    -- there is nothing here to turn on -- and a switch that ran on the tutorial's
    -- edges would now be a way for the walkthrough ENDING to take a permanent
    -- feature away from the player.

    -- AND THE SERVER IS TOLD, WITHOUT TOUCHING `running`.
    --
    -- This used to call BR.Tutorial.set(running or inGame), which was wrong in a
    -- way that showed instantly: `set` is what RAISES `running`, so starting the
    -- in-game half also started the LOBBY half, and both card stacks drew at
    -- once (owner, 2026-09-04: "it shows me the lobby tutorial cards AND the
    -- game tutorial cards"). Telling the server and setting a flag are two
    -- different acts and had been written as one.
    tellServer()
end

-- ═══ AND THE SUPPRESSION RUNS PER FRAME, BECAUSE IT HAS TO ═══
--
-- DisableControlAction lasts EXACTLY ONE FRAME -- the same note client/
-- inventory.lua and client/attachtune.lua carry, for the same reason. A tick
-- pass at 10Hz would leave the camera live five frames in six, which reads as
-- the fix not working rather than as it working intermittently.
--
-- NOTHING TO RESTORE ON THE WAY OUT, which is the strongest part of doing it
-- this way: the frame after `inGame` goes false, nothing is disabled. A flag
-- left set by a crash or a resource restart cannot leave a player unable to
-- aim, which is the failure a SetPlayerControl-shaped fix would risk.
-- ═══ AND IT ENDS WHEN THE PAD DOES ═══
--
-- The in-game half had no ending except its own last card. A player who did not
-- finish it carried it out of warmup: onto the bus, into the fight, into the
-- next lobby and the match after that, with the cards still drawing over the HUD
-- and the arrow keys still being eaten. Owner, 2026-09-06: "the in-game tutorial
-- shows up every time I hop in a match until I `brtutorial off`."
--
-- TICK RATHER THAN AN EVENT, because there is no client event for "my own state
-- changed" -- client/warmupcrates.lua reads BR.State.me.state the same way, on
-- the same band, for the same reason.
--
-- IT PAYS NOTHING. This is the abandon path, not the finish: BR.Tutorial.game
-- takes the flag down and the reward is claimed only by the last card being
-- dismissed. Leaving the pad early is not finishing.
BR.Loop.register(BR.Loop.TICK, 'tutorial.leave', function()
    if not inGame then return end
    if BR.State and BR.State.me and BR.State.me.state == BR.PlayerState.WARMUP then
        return
    end
    print('[br_core] tutorial: left warmup -- the in-game walkthrough is over')
    BR.Tutorial.game(false)
end)

--- Monotonic, so the page can tell one press from the same press re-sent.
local navSeq = 0

BR.Loop.register(BR.Loop.FRAME, 'tutorial.nav', function()
    if not inGame then return end

    for i = 1, #BLOCKED do
        DisableControlAction(0, BLOCKED[i], true)
    end

    -- READ DISABLED, WHICH IS THE PROJECT'S OWN IDIOM. A control disabled this
    -- frame is invisible to IsControlJustPressed and only the Disabled reader
    -- still sees it -- the same disabled-then-read pattern client/inventory.lua
    -- and client/revivekey.lua use. `isTrue`, because these natives answer 1/0
    -- and 0 is truthy in Lua.
    for id, dir in pairs(NAV) do
        if isTrue(IsDisabledControlJustPressed(0, id)) then
            navSeq = navSeq + 1
            TriggerEvent('br:ui:sendLocal', BR.Nui.TUTORIAL_NAV,
                         { dir = dir, seq = navSeq })
        end
    end
end)

--- Show or hide the offer.
--- @param on boolean
function BR.Tutorial.offer(on)
    on = on == true
    if on == offering then return end
    offering = on
    publish()
end

--- One of the four warmup crates was opened BY THIS PLAYER.
---
--- FIRED FROM client/loot.lua's husk-reskin branch, which is the only line in
--- the tree that means "the crate I claimed has actually opened": it is
--- server-confirmed, so a refused claim cannot satisfy the card, and it is
--- opener-only, so standing next to somebody else's crate does nothing.
---
--- MATCHED BY POSITION, because that is what tells one of the owner's four from
--- the thirteen hundred other crates on the map. The anchors are 6-8m apart, so
--- a couple of metres of tolerance cannot be ambiguous; the crate is built at
--- the anchor's own x/y, so in practice the distance is zero.
---
--- ONLY WHILE THE IN-GAME HALF IS RUNNING. Outside it there is no card waiting
--- on this and the count would be bookkeeping nobody reads.
AddEventHandler('br:loot:opened', function(_, x, y)
    if not inGame then return end
    if not BR.WarmupCrates or not BR.WarmupCrates.all then return end

    for _, c in ipairs(BR.WarmupCrates.all()) do
        if BR.Dist(x, y, c.x, c.y) <= 3.0 then
            crates = crates + 1
            publish()
            return
        end
    end
end)

--- Give the match its clock back, without ending the walkthrough.
---
--- Called when the player reaches the last card, which is the one about the
--- countdown. See `holding`.
function BR.Tutorial.hold(on)
    on = on == true
    if on == holding then return end
    holding = on
    tellServer()
end

--- The player dropped a map waypoint.
---
--- COUNTED HERE FOR THE SAME REASON THE CRATES ARE: the page cannot see it.
--- The gesture is consumed by client/markers.lua the tick it happens -- the
--- waypoint is read and immediately switched off, becoming a squad marker -- so
--- there is no waypoint left on the map for anything to observe afterwards.
---
--- ONLY WHILE THE IN-GAME HALF IS RUNNING, so this is not bookkeeping nobody
--- reads outside the one card that waits on it.
AddEventHandler('br:markers:placed', function()
    if not inGame then return end
    waypoints = waypoints + 1
    publish()
end)

--- They finished the whole thing -- pay them.
---
--- ═══ IT IS A SEPARATE CALL FROM STOPPING, AND THEY ARE SEPARATE FACTS ═══
---
--- `BR.Tutorial.game(false)` is what every ending does: the last card
--- dismissed, a step whose anchor vanished, `/brtutorial off`. Only ONE of
--- those earned anything, so the page says which by sending this first. Folding
--- the reward into `game(false)` would pay a learner for the walkthrough
--- breaking under them, and pay the dev command every time it is typed.
---
--- WHAT STOPS IT BEING FARMED IS THE DATABASE, NOT THIS FUNCTION. See
--- BR.Net.TUTORIAL_DONE.
function BR.Tutorial.finish()
    TriggerServerEvent(BR.Net.TUTORIAL_DONE)
end

--- @return boolean
function BR.Tutorial.running()
    return running
end

-- ---------------------------------------------------------------------------
-- The command
-- ---------------------------------------------------------------------------

--- `/brtutorial [off]` -- run the lobby walkthrough now.
---
--- NO MATCH-STATE CHECK, ON PURPOSE. The walkthrough points at lobby controls,
--- so it has nothing to say anywhere else -- but the page already knows which
--- screen it is drawing and simply renders nothing when the lobby is not up.
--- A second opinion here would be a rule in two places that could disagree, and
--- the one on the page is the one that can actually see.
RegisterCommand('brtutorial', function(_, args)
    local arg = args and args[1]
    local off = arg == 'off' or arg == 'stop'

    if off then
        BR.Tutorial.game(false)
        BR.Tutorial.set(false)
        BR.Tutorial.offer(false)
        print('[br_core] tutorial: stopped, and the offer is hidden')
        return
    end

    -- ═══ THE OFFER, NOT THE WALKTHROUGH, AND THAT IS THE OWNER'S ASK ═══
    --
    -- 2026-09-04: "When I use brtutorial I want to see the full checkbox and
    -- 'start tutorial' button." So the bare command reproduces what a brand new
    -- player actually meets -- the checkbox beside Ready up, ticked -- rather
    -- than jumping straight into the cards. Pressing the button is what starts
    -- it, exactly as it will be for a real first-timer.
    --
    -- `/brtutorial run` skips the offer, for looking at a single card without
    -- clicking through the lobby to get there.
    if arg == 'game' then
        BR.Tutorial.game(true)
        print('[br_core] tutorial: the IN-GAME walkthrough is running')
        print('  it points at the HUD, so it draws in a match or on the pad')
        print('  /brtutorial off  stops everything')
        return
    end

    if arg == 'run' then
        BR.Tutorial.set(true)
        print('[br_core] tutorial: running -- the walkthrough is on screen')
        print('  it draws only while the LOBBY is up; open it if you see nothing')
        print('  /brtutorial off  stops it')
        return
    end

    BR.Tutorial.offer(true)
    print('[br_core] tutorial: the offer is up -- look beside Ready up')
    print('  the checkbox is ticked by default, and Ready up now reads')
    print('  Start tutorial; pressing it begins the walkthrough')
    print('  /brtutorial run   starts the lobby half without the offer')
    print('  /brtutorial game  starts the in-game half, over the HUD')
    print('  /brtutorial off  hides both')
-- NO `restricted` ARGUMENT, AND THAT IS NOT AN OVERSIGHT. Passing `true` makes
-- this an ace-restricted command, and FiveM's CLIENT console refuses those in
-- production mode outright -- "Command brtutorial is disabled in production
-- mode" (owner, 2026-09-04), before our own gate is ever consulted. Every one
-- of the 27 client commands in this tree passes nothing here for the same
-- reason. THE GATE IS STILL ON: br_lib/shared/devgate.lua wraps RegisterCommand
-- for the whole project, and that is what makes this dev-only.
end)

-- ---------------------------------------------------------------------------
-- The page starting it
-- ---------------------------------------------------------------------------

--- The player pressed "Start tutorial", or the walkthrough ended.
---
--- ═══ THE CALLBACK IS NOT HERE, AND IT CANNOT BE ═══
---
--- The page is SERVED BY br_ui, so `fetchNui` posts to `cfx-nui-br_ui` and only
--- br_ui can answer it. A RegisterNUICallback in this resource registers under
--- br_core's own namespace, which nothing is asking, and the page gets a bare
--- HTTP 404 -- owner, 2026-09-04: "clicking the 'Start tutorial' button just
--- greys out the 'ready up' button and nothing else happens", with
--- `callback br/tutorial/set: Error: HTTP 404` beside it. Every other callback
--- in the project lives in br_ui/client/ for exactly this reason.
---
--- SO br_ui TAKES THE CALL AND HANDS IT OVER, on a plain client event -- the
--- same seam, in reverse, that `br:ui:sendLocal` already uses to get messages
--- from here to the page. Separate Lua states cannot share a function; they
--- share events.
AddEventHandler('br:tutorial:set', function(run)
    BR.Tutorial.set(run == true)
end)

--- The page ending the IN-GAME half. `done` is true only when the last card was
--- dismissed, which is the one ending that pays.
---
--- THE REWARD IS CLAIMED BEFORE THE FLAG DROPS, deliberately: `game(false)`
--- pops the cursor focus and unmounts the layer, and a claim sent after that is
--- a claim sent from a resource that may already have stopped caring.
--- The page reaching the last card, which is the one about the countdown.
--- Gives the match its clock back while the card is still on screen.
AddEventHandler('br:tutorial:hold', function(on)
    BR.Tutorial.hold(on == true)
end)

AddEventHandler('br:tutorial:game', function(on, done)
    if done == true and on ~= true then BR.Tutorial.finish() end
    BR.Tutorial.game(on == true)
end)

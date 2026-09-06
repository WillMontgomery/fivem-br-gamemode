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

--- Push all three flags to the page.
local function publish()
    TriggerEvent('br:ui:sendLocal', BR.Nui.TUTORIAL,
                 { run = running, offer = offering, game = inGame })
end

--- Start or stop the walkthrough, and tell the page.
---
--- IDEMPOTENT, deliberately. `/brtutorial` twice in a row is a person checking
--- whether it worked, not a request to restart from the top -- and restarting
--- would throw away the step they were reading.
--- @param on boolean
function BR.Tutorial.set(on)
    on = on == true
    if on == running then return end
    running = on
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
    TriggerServerEvent(BR.Net.TUTORIAL_SET, { on = running })
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
    publish()
    -- The server only needs to know whether the player is in ANY of it.
    BR.Tutorial.set(running or inGame)
end

--- Show or hide the offer.
--- @param on boolean
function BR.Tutorial.offer(on)
    on = on == true
    if on == offering then return end
    offering = on
    publish()
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

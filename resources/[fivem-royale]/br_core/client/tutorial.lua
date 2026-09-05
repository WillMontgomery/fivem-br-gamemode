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

--- Start or stop it, and tell the page.
---
--- IDEMPOTENT, deliberately. `/brtutorial` twice in a row is a person checking
--- whether it worked, not a request to restart from the top -- and restarting
--- would throw away the step they were reading.
--- @param on boolean
function BR.Tutorial.set(on)
    on = on == true
    if on == running then return end
    running = on
    TriggerEvent('br:ui:sendLocal', BR.Nui.TUTORIAL, { run = running })
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
    local off = args and (args[1] == 'off' or args[1] == 'stop')
    BR.Tutorial.set(not off)

    if off then
        print('[br_core] tutorial: stopped')
        return
    end

    print('[br_core] tutorial: running -- the lobby walkthrough is on screen')
    print('  it draws only while the LOBBY is up; open it if you see nothing')
    print('  /brtutorial off  stops it')
end, true)

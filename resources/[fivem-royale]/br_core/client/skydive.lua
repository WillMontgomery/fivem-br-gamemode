-- The drop: freefall -> glider -> ground.
--
-- Driven entirely by GET_PED_PARACHUTE_STATE, because the engine's own state
-- is the only honest answer to "is the chute out yet" -- inferring it from
-- velocity or height re-derives what the ped already knows.
--
-- THE CHUTE IS A WEAPON AND IT MUST BE GIVEN. TASK_PARACHUTE's second
-- parameter looks like "give parachute" and is verified UNUSED (a removed
-- legacy jetpack flag) -- task a ped without GADGET_PARACHUTE in their
-- inventory and they fall to their death with the animation of someone
-- reaching for a ripcord that is not there.

BR = BR or {}

local CHUTE = GetHashKey('GADGET_PARACHUTE')   -- 0xFBAB5776, verified

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. This is the back half of the drop and it asked five BOOL natives
--- raw, in the two places where being wrong is fatal rather than untidy:
---
---   `if HasPedGotWeapon(ped, CHUTE, false) then break end` -- the give-verify
---   loop -- breaks on the 0 that means the ped has NO chute, so the retry that
---   exists because the give "quietly fails for a player mid-teleport" would
---   never run once. That is the chuteless fall this file opens by describing.
---
---   `if IsPedFalling(ped) then return true end` in airborneNow returns airborne
---   for a ped standing still, so the landing branch never fires and the drop
---   machine never stands down.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

local dropping = false

--- Has this drop already ended on the ground?
---
--- Separate from `dropping`, and the separation is #126. `dropping` means "the
--- drop machine is armed", and it is re-armed BY THE SERVER'S OPINION -- see
--- the top of skydive.state, which turns it back on whenever the roster still
--- calls us a faller. That is right as a net for a missed handoff and wrong as
--- a record of what our own feet have done: while the landing report is
--- outstanding the machine re-armed itself ten times a second, ran the landing
--- branch again each time, and re-fired every one-shot in it -- a fresh disarm
--- thread, a fresh report thread, a fresh "Loot up before the storm comes!"
--- toast. The stack of duplicate toasts is a symptom this file has already
--- shipped once (see the airborneSeen note below); it came back the moment the
--- server was slow to agree.
---
--- This is the fact "my feet touched down during THIS drop", which the server
--- disagreeing cannot undo. Cleared out of the plane door and at the start of a
--- round, exactly like BR.State.landed, and by nothing else.
local landedThisDrop = false

--- Is this ped genuinely off the ground RIGHT NOW?
---
--- THE PED'S OWN EVIDENCE, ASKED FRESH, because the two places that need this
--- are both places where a LATCH gives the wrong answer. It is the same test
--- skydive.disarm already trusts, lifted out so the two cannot drift.
---
--- WATER IS GROUND, and that is not a detail: GetEntityHeightAboveGround
--- measures to the SEABED, so a player swimming in 30m of water reads as 30m up
--- (user, 2026-08-05). A sea landing is a bad drop, not a continuing one.
--- @param ped integer
--- @return boolean
local function airborneNow(ped)
    if isTrue(IsPedFalling(ped)) then return true end
    if isTrue(IsEntityInWater(ped)) then return false end
    return GetEntityHeightAboveGround(ped) > 5.0
end

-- ═══ WHICH STAGE OF THE LANDING IS SLOW -- #245, AND IT IS A RULER, NOT A FIX ═══
--
-- The owner, 2026-08-30: "the loop that runs to learn that a player has landed
-- on their feet -- that either doesn't run often enough or takes too long", and
-- then, with the size of it: "I land on the ground, and my inventory doesn't
-- show up for sometimes >5 seconds. This is the same loop that starts the storm
-- timer once everyone has landed."
--
-- THOSE ARE TWO DIFFERENT FAULTS WITH TWO DIFFERENT FIXES and neither he nor
-- this file can tell them apart from the outside. "Not often enough" is a
-- cadence and would be fixed by a band; "takes too long" is a predicate that
-- stays false and would be fixed by the predicate. Shortening the report's
-- 400ms retry would look like a fix for either and be a coincidence for both.
--
-- AND READING CANNOT SETTLE IT EITHER, because the four things that have to
-- happen after a ped touches down are invisible to each other:
--
--   1. the ped is physically on the ground
--   2. the landing test in skydive.state agrees, and the branch fires
--   3. the server answers the report and this client's mirror leaves FREEFALL
--   4. the interface actually shows the bar
--
-- Every one of those is seconds-capable and every one of them looks, from a
-- chair, exactly like the other three. So this measures all four and prints one
-- line per landing on the landing player's own console -- he is mid-drop and
-- cannot type a command.
--
-- HOW TO READ THE LINE. Every number is milliseconds AFTER GROUND CONTACT.
--
--   detect large                  stage 2. The client's own landing test is the
--                                 bug, and `held by` names which of its four
--                                 clauses was last to come true.
--   detect n/a, server ~5000      stage 2, in its worst form: the branch NEVER
--                                 fired, and what ended the wait was the
--                                 server's stuck-lander net (stuckLanderMs,
--                                 5000). `NEVER TRUE` names the clauses that
--                                 never came true.
--   detect small, server large    stage 3. The report or the promotion, not
--                                 this file -- and THEN the 400ms retry is
--                                 worth looking at.
--   detect small, ui large        stage 4. The consumer.
--   contact NEVER                 the physics never said we were down. That is
--                                 a reading about IsEntityInAir, not a landing.
--
-- THE CLOCK IS LEGITIMATE HERE and this is the one place in the project where
-- that needs saying. GetGameTimer is frame-stamped -- see the long TIMING block
-- in client/main.lua, where it made every per-callback cost read exactly zero.
-- It is useless WITHIN a frame and honest ACROSS frames, and every interval
-- below spans hundreds of frames. This is the same clock noteFrame has always
-- used correctly.
BR.Skydive = BR.Skydive or {}

--- The four clauses of the landing test in skydive.state, by the short names
--- the readout prints. THEY ARE SAMPLED FROM THE SAME VALUES THE PREDICATE IS
--- EVALUATED FROM, one line above it, so the ruler cannot drift from the thing
--- it measures:
---
---   seen   airborneSeen        -- this drop has been off the ground at least once
---   nopen  cs ~= OPENING       -- the canopy is not mid-deploy
---   nfall  not IsPedFalling    -- the ped is not in a falling state
---   gnd    grounded            -- on foot, in water, or the canopy-still-attached
---                                 fallback (cs OPEN, agl < 2, speed < 2)
local LAND_CLAUSES = { 'seen', 'nopen', 'nfall', 'gnd' }

--- Print even an unfinished record after this long, rather than never. A
--- landing whose server half never arrives is exactly the case worth seeing,
--- and a diagnostic that stays silent for it is the shape of the bug it is
--- looking for.
local LAND_DEADLINE_MS = 20000

--- ...and much sooner than that once the server has already answered. See the
--- printer at the bottom of this file.
local LAND_AFTER_SERVER_MS = 3000

--- One drop's stage timings. All absolute GetGameTimer stamps; the readout
--- turns them into offsets.
local landTime = {
    open = false, printed = false,
    exitAt = 0,
    contactFrom = nil, contactRun = 0,   -- the two-sample debounce, below
    contactAt = nil,                     -- 1: physics says we are down
    branchAt = nil,                      -- 2: the landing branch fired
    reportAt = nil,                      -- 2b: DROP_LANDED left this client
    serverAt = nil,                      -- 3: our mirror left FREEFALL/GLIDE/BUS
    uiAt = nil,                          -- 4: the HUD would draw the bar
    sawAir = false,                      -- the server called us airborne at least once
    csContact = nil, csLast = nil,
    aglMax = 0.0, spdMax = 0.0,
    at = {},                             -- clause -> first stamp it was true
    last = nil,                          -- the last finished line, for /brdropdbg
}

--- Turn one drop's stamps into the line. PURE -- no natives, no clock -- which
--- is what lets tools/test_client.lua feed it a landing that never happened and
--- assert the words, the way main.lua's reduceBench is pinned.
--- @param r table  a landTime record
--- @return string
function BR.Skydive.landLine(r)
    r = r or {}
    local at = r.at or {}

    -- BASED ON CONTACT, AND IT SAYS SO WHEN IT CANNOT BE. Silently rebasing on
    -- the branch would turn "the physics never agreed we were down" into a
    -- healthy-looking zero, which is the one reading that must not be faked.
    local base = r.contactAt or r.branchAt or r.serverAt
    local function off(t)
        if t == nil or base == nil then return 'n/a' end
        return tostring(t - base)
    end

    -- WHICH CLAUSE WAS LAST TO COME TRUE -- the answer, when detect is large.
    -- A clause with no stamp at all never came true in this whole drop, and
    -- naming those is strictly more useful than naming a maximum over the rest.
    local held, heldAt, never = nil, nil, {}
    for _, c in ipairs(LAND_CLAUSES) do
        local t = at[c]
        if t == nil then
            never[#never + 1] = c
        elseif heldAt == nil or t > heldAt then
            held, heldAt = c, t
        end
    end

    local verdict
    if r.via == 'seat' then
        -- NOT "NEVER TRUE", WHICH IS WHAT THIS USED TO SAY HERE. The seat
        -- branch returns above the landing test, so its four clauses were never
        -- ASKED -- and a readout that reports an unasked question as a failed
        -- one is a readout that sends somebody after the wrong clause.
        verdict = 'ended in a vehicle seat -- the landing test was not reached'
    elseif #never > 0 then
        verdict = 'NEVER TRUE: ' .. table.concat(never, ',')
    elseif r.branchAt and r.contactAt and r.branchAt <= r.contactAt then
        -- HEALTHY, AND SAID AS SUCH. With every clause true on the same tick,
        -- "held by" would pick whichever the loop happened to look at first and
        -- hand the reader a suspect for a landing that had nothing wrong with
        -- it -- which is how a diagnostic starts costing rounds instead of
        -- saving them.
        verdict = 'detected on contact'
    elseif r.branchAt == nil then
        -- Unreachable if the sampler and the predicate still read the same
        -- values in the same pass. Printed rather than assumed away: it is the
        -- one outcome that would mean the ruler had drifted off the thing it
        -- measures, and a ruler that can say so is worth the branch.
        verdict = 'all four clauses true and the branch never fired -- SAMPLER DRIFT'
    else
        verdict = 'held by ' .. tostring(held)
    end

    -- `descent` rather than `fall`: `nfall` is a column on the same line, and a
    -- reader grepping this readout for one must not land inside the other.
    return ('[br_core] landtime %s (ms after contact): detect %s report %s server %s ui %s | %s'
        .. ' | seen %s nopen %s nfall %s gnd %s foot %s airb %s | cs %s>%s aglMax %.1f spdMax %.1f descent %s')
        :format(
            r.contactAt and 'contact' or 'contact NEVER',
            off(r.branchAt), off(r.reportAt), off(r.serverAt), off(r.uiAt),
            verdict,
            off(at.seen), off(at.nopen), off(at.nfall), off(at.gnd),
            off(at.foot), off(at.airb),
            tostring(r.csContact), tostring(r.csLast),
            r.aglMax or 0.0, r.spdMax or 0.0,
            (r.contactAt and r.exitAt and r.exitAt > 0)
                and tostring(r.contactAt - r.exitAt) or 'n/a')
end

--- Say it once, and keep it for /brdropdbg -- a console that has scrolled is
--- the commonest way a one-shot readout is lost.
local function landPrint()
    local L = landTime
    if L.printed then return end
    L.printed = true
    -- CLOSED AS WELL AS SPOKEN. A spoken record is finished, and leaving it
    -- open would keep the sampler and the printer walking over a landing that
    -- has already had its line -- and would stop the re-arm net below from
    -- opening a fresh one for the next descent.
    L.open = false
    L.last = BR.Skydive.landLine(L)
    print(L.last)
end

--- Start timing a descent. Any unfinished record is spoken first: a second drop
--- must not silently eat the measurement of the one before it.
--- @param now integer
local function landOpen(now)
    local L = landTime
    if L.open and not L.printed
       and (L.contactAt or L.branchAt or L.serverAt) then
        landPrint()
    end
    L.open, L.printed = true, false
    L.exitAt = now
    L.contactFrom, L.contactRun = nil, 0
    L.contactAt, L.branchAt, L.reportAt = nil, nil, nil
    L.serverAt, L.uiAt = nil, nil
    L.sawAir = false
    L.via = nil
    L.csContact, L.csLast = nil, nil
    L.aglMax, L.spdMax = 0.0, 0.0
    L.at = {}
end

--- Sample the world one tick before skydive.state evaluates its landing test,
--- from the values that test is about to use.
---
--- GROUND CONTACT IS ASKED OF THE PHYSICS, DELIBERATELY NOT OF THE TASK. Every
--- clause of the landing predicate is a question about what the ped is DOING --
--- falling, on foot, under a canopy -- and if the answer to "is the loop slow"
--- were taken from one of those, a clause that lies would produce a contact
--- time that lies with it and the stall would measure zero. IsEntityInAir is
--- the collision underneath us, which no ped task owns. WATER IS GROUND here
--- for the same reason it is everywhere else in this file.
---
--- TWO CONSECUTIVE SAMPLES CONFIRM IT, AND THE STAMP IS THE FIRST OF THEM: one
--- tick of collision under a still-gliding ped (a rooftop clipped on the way
--- past) is not a landing, and 200ms of debounce that is then handed straight
--- back costs nothing against a five-second question. A run that breaks throws
--- away everything measured under it, or a clip on the way down would leave the
--- clause stamps of a landing that had not happened.
---
--- CLAUSE STAMPS BEGIN AT THE FIRST TOUCHING SAMPLE, NOT AT THE CONFIRMED ONE,
--- and they are re-based there rather than run from the door. Both halves of
--- that matter:
---
---   Running from the door would stamp `nfall` during the glide -- IsPedFalling
---   is false for a ped under a canopy -- and a clause that then went TRUE at
---   touchdown and stayed true would carry a stamp saying it was never a
---   problem. The question is only ever "what was false AFTER the feet were
---   down", so the record starts there.
---
---   Waiting for the CONFIRMED sample would leave them empty on a landing the
---   predicate detects on the very first touching tick -- the healthy case --
---   and the readout would announce that all four clauses were never true on
---   a drop that worked perfectly.
--- @param ped integer
--- @param cs integer      GetPedParachuteState, as the predicate has it
--- @param agl number
--- @param seen boolean    airborneSeen
--- @param grounded boolean  the predicate's own grounded verdict, fallback included
local function landSample(ped, cs, agl, seen, grounded)
    local L = landTime
    if not L.open or L.printed or L.branchAt then return end

    local now = GetGameTimer()
    L.csLast = cs

    local touching = isTrue(IsEntityInWater(ped))
                  or not isTrue(IsEntityInAir(ped))
    if seen and touching then
        L.contactFrom = L.contactFrom or now
        L.contactRun  = L.contactRun + 1
    elseif not L.contactAt then
        -- The run broke before it was confirmed. Everything measured under it
        -- described a ped that turned out to still be in the air.
        L.contactFrom, L.contactRun = nil, 0
        L.at, L.aglMax, L.spdMax = {}, 0.0, 0.0
    end
    if not L.contactFrom then return end

    if not L.contactAt and L.contactRun >= 2 then
        L.contactAt = L.contactFrom
        L.csContact = cs
    end

    -- THE TWO NUMBERS THAT TEST THE `grounded` FALLBACK, which is the one
    -- clause with thresholds in it: it needs agl < 2.0 AND speed < 2.0. A
    -- player who lands running, or who lands on something the height probe
    -- measures from the terrain below, fails it for as long as that lasts --
    -- and these are the readings that say so instead of leaving it a theory.
    if agl > L.aglMax then L.aglMax = agl end
    local spd = GetEntitySpeed(ped)
    if spd > L.spdMax then L.spdMax = spd end

    local a = L.at
    if seen and not a.seen then a.seen = now end
    if cs ~= BR.Native.ChuteState.OPENING and not a.nopen then a.nopen = now end
    if not isTrue(IsPedFalling(ped)) and not a.nfall then a.nfall = now end
    if grounded and not a.gnd then a.gnd = now end
    -- NOT CLAUSES, BUT THE TWO THE BRIEF NAMED. `foot` is the plain grounded
    -- test without the canopy fallback, so `foot` late and `gnd` early is the
    -- fallback earning its keep and the reverse is it getting in the way.
    -- `airb` is airborneNow, which gates the re-arm and the report retry rather
    -- than the landing itself -- it is here because it is the function the
    -- suspicion was pointed at, and a reading that exonerates it is worth as
    -- much as one that convicts it.
    if (isTrue(IsPedOnFoot(ped)) or isTrue(IsEntityInWater(ped)))
       and not a.foot then a.foot = now end
    if not airborneNow(ped) and not a.airb then a.airb = now end
end

--- Stage 2: the landing branch has decided. Called from both endings that count
--- as a landing -- the ordinary one and the vehicle seat.
---
--- IT COMMITS A PENDING DEBOUNCE, and that is not tidiness. The healthy landing
--- is detected on the FIRST touching tick, one line after landSample saw it and
--- one tick before the second sample would have confirmed it -- so without this
--- the best possible drop would print `contact NEVER`, which is the readout's
--- alarm for something else entirely. A branch that has fired is confirmation:
--- two independent tests agreeing on the same tick is strictly better evidence
--- than the same test twice.
---
--- AND THE SEAT ENDING GETS ITS OWN READING. The vehicle branch returns long
--- before the sampler runs, so a drop finished from a driver's seat has no
--- pending debounce at all -- and `contact NEVER` there would put the readout's
--- one alarm for "the physics never agreed we were down" on a path where it
--- means nothing of the kind. So the physics is simply asked again, here,
--- without the debounce. It is still the same ground truth and still nothing
--- the landing predicate reads; if it answers airborne, the alarm is real.
--- @param now integer
--- @param ped integer
--- @param via string|nil  'seat' for the vehicle ending; nil for the landing test
local function landBranch(now, ped, via)
    local L = landTime
    if not L.open or L.printed or L.branchAt then return end
    if not L.contactAt then
        if L.contactFrom then
            L.contactAt = L.contactFrom
            L.csContact = L.csLast
        elseif ped and (isTrue(IsEntityInWater(ped))
                        or not isTrue(IsEntityInAir(ped))) then
            L.contactAt = now
            L.csContact = L.csLast
        end
    end
    L.branchAt = now
    L.via = via or 'branch'
end

--- Tell the server we are down, and KEEP TELLING IT UNTIL IT AGREES.
---
--- THE REPORT USED TO BE FIRE-AND-FORGET, and it is the single most
--- historically unreliable message in this project -- the server-side
--- stuck-lander promotion exists precisely because it goes missing. When it
--- does, nothing retried: the player stayed FREEFALL until that net noticed
--- five seconds of stillness, and since the net needs two fresh 2Hz position
--- samples either side of those five seconds, the real wait was closer to ten.
--- A solo player landed and then stood in an empty world with no HUD and no
--- inventory for over ten seconds (user, 2026-08-08).
---
--- Every consequence of landing hangs off the ALIVE state -- the HUD, the
--- inventory bar, loot visibility, being shootable -- so one dropped packet
--- costs all of it.
---
--- The fix is the same shape as the chute REMOVAL directly below, and for the
--- same reason: a message that must arrive is re-sent until the world reflects
--- it, rather than sent once and hoped for. The server is still the only
--- authority -- it validates the state transition exactly as before and
--- ignores a duplicate -- so the worst case is a handful of tiny events.
local function reportLanded()
    -- THE FIRST SEND ONLY. The re-sends below are the retry doing its job, and
    -- stamping them would move the report time forward every 400ms until the
    -- server agreed -- which would make stage 3 read as zero for exactly the
    -- landing where it is the whole delay.
    landTime.reportAt = landTime.reportAt or GetGameTimer()
    TriggerServerEvent(BR.Net.DROP_LANDED)

    Citizen.CreateThread(function()
        for attempt = 1, 12 do
            Citizen.Wait(400)

            -- The server has agreed: our own mirror says we are on the
            -- ground. Nothing to re-send.
            local st = BR.State.me.state
            if st ~= BR.PlayerState.FREEFALL
               and st ~= BR.PlayerState.GLIDE
               and st ~= BR.PlayerState.BUS then
                if attempt > 1 then
                    print(('[br_core] landing confirmed after %d re-sends')
                        :format(attempt - 1))
                end
                return
            end

            -- Airborne again is not a lost packet. A player who was promoted
            -- and then walked off a cliff must not be re-reporting a landing.
            --
            -- THIS USED TO READ `if dropping then return end` AND IT KILLED THE
            -- RETRY IN THE ONLY CASE THE RETRY EXISTS FOR (#126).
            --
            -- `dropping` is not "I am in the air". It is re-armed at the top of
            -- skydive.state whenever the ROSTER still calls us FREEFALL or
            -- GLIDE -- which is precisely the condition this loop is here to
            -- correct. So a hundred milliseconds after touchdown the latch was
            -- true again, and on its first wake-up four hundred milliseconds
            -- later this loop looked at it and went home. Every attempt after
            -- the first was unreachable: a retry loop, written correctly,
            -- wired to nothing, and cited in the issue thread as the reason
            -- the landing report is survivable.
            --
            -- The ped is asked instead. It is the same evidence
            -- skydive.disarm uses to decide whether someone is genuinely
            -- falling, and unlike the latch it cannot be turned back on by the
            -- server's own out-of-date opinion.
            if airborneNow(PlayerPedId()) then return end

            TriggerServerEvent(BR.Net.DROP_LANDED)
        end
        print('[br_core] landing report never took -- server still thinks we '
            .. 'are airborne after 12 attempts')
    end)
end

-- THE LANDING LATCH. The landing test is "chute away, feet on something" --
-- which is also true in the instant AFTER THE JUMP, before the exit
-- velocity and parachute task have taken hold: the ped still reads as
-- on-foot, so the landing branch fired seconds into the fall. That sent a
-- false DROP_LANDED (the server marked the player ALIVE mid-air -- the
-- premature storm clock), and re-fired every re-arm: the stack of four
-- "Loot up!" toasts. Landing only counts after the drop has actually been
-- AIRBORNE at least once.
local airborneSeen = false

-- THE CANOPY IS OUT, SO THE WEAPON IS SPENT.
--
-- GTA does NOT consume GADGET_PARACHUTE when the canopy opens: the ped keeps
-- the weapon with its ammo intact, which is the engine's definition of "has a
-- parachute available". That is why a player who had already pulled was still
-- armed with a second one and why the vanilla deploy prompt came back the
-- moment they were near the ground (live report, 2026-08-05 -- the third
-- distinct reserve-chute symptom, and the first one whose cause was the
-- ENGINE'S ammo model rather than one of our own give paths).
--
-- Zeroing the ammo the instant the canopy appears leaves the open canopy
-- alone (the parachute TASK owns it, not the inventory entry) while making a
-- redeploy impossible. Removing the weapon outright here would be the obvious
-- move and is exactly what we do NOT do: pulling the weapon out from under a
-- live parachute task is how you drop someone out of their own canopy.
local chuteSpent = false

--- Has the trail key been pressed at all during THIS drop?
---
--- THE PROMPT IS AN INSTRUCTION, AND AN INSTRUCTION THAT HAS BEEN FOLLOWED IS
--- CLUTTER (owner, 2026-08-17: "after the smoke trails button has been pressed
--- once, the DUI for it should be hidden").
---
--- It pairs with the trail now defaulting OFF (cosmetics.lua): the box appears
--- under the canopy saying which key starts the smoke, the player presses it,
--- and the box has said everything it had to say. Leaving it up for the rest of
--- the glide would be a permanent caption over the middle of the screen during
--- the one phase where the player is steering at a landing spot -- and it would
--- be offering to do a thing they have just done.
---
--- PER DROP, NOT PER MATCH, and cleared in br:drop:begin with the rest of the
--- descent state. A latch that survived into the next round would silently
--- suppress the prompt for a player who never saw it -- which is the shape of
--- every bug #131 has had: an interface confidently silent about something the
--- player has not been told.
---
--- ONE PRESS IS THE WHOLE TEST. It deliberately does NOT track whether the trail
--- ended up on or off: the owner asked for the box to go after the button is
--- pressed, and a box that came back when the player toggled the smoke off again
--- would be the prompt flashing on and off with the key.
local trailKeyUsed = false

--- What the descent prompt actually managed to do THIS drop, for /brdropdbg.
---
--- WRITTEN BECAUSE THE ONE QUESTION NOBODY COULD ANSWER WAS "DID IT DRAW" (#131).
---
--- Two rounds of that issue ended in "no prompt appeared", and neither could be
--- narrowed from a chair: the decision to show the box, the message that carries
--- its words, and the sprite that puts it on screen are three separate steps, any
--- one of which failing looks identical from the cockpit -- and identical, too,
--- to a player who simply has nothing equipped, which is the CORRECT outcome. So
--- each step keeps a count and the readout prints all of them. Four numbers and
--- one label, costing three increments a frame, against a playtest per guess.
---
--- Declared up here with the rest of the per-drop state rather than beside the
--- prompt it belongs to, because br:drop:begin clears it and that handler is
--- above the prompt block: a local referenced before its own declaration reads
--- as a nil GLOBAL, which luac accepts and the game throws on (tools/verify.sh
--- has a gate for exactly this, and it was written after a whole subsystem went
--- silent behind one console line).
local promptSeen = {
    kind = nil,       -- what the last frame decided to say, if anything
    sends = 0,        -- payloads pushed to the page
    draws = 0,        -- frames the DUI sprite was actually drawn
    fallbacks = 0,    -- frames the browser was not up and text stood in
    trailFrames = 0,  -- frames the TRAIL half of the descent was on offer
    -- THE ONE READING THAT SEPARATES "THE KEY IS DEAD" FROM "THE ENGINE IGNORED
    -- US" (#131, fifth round). The owner reports a prompt that draws perfectly,
    -- names his own rebound key, and does nothing when pressed. Three things can
    -- produce that and they are indistinguishable from a chair: the action never
    -- firing, the toggle never reaching BR.Cosmetics, or the engine declining to
    -- drop the smoke mid-glide when SetPlayerCanLeaveParachuteSmokeTrail says
    -- so. The first two are now proved by tools/test_client.lua, which presses
    -- the key on both the default binding and a rebound one; this counter is how
    -- the THIRD is told apart on a live client, from a single paste rather than
    -- a before-and-after pair the reporter has to remember to take twice.
    --
    -- `toggles` counts presses that reached the listener at all. `acted` counts
    -- the ones showTrail accepted and wrote to the native. toggles 0 is a dead
    -- key; toggles > 0 with acted 0 is an armed-state problem; both above zero
    -- with the smoke still flying is the engine, and the Lua is exonerated.
    toggles = 0,      -- presses the trail listener actually received
    acted = 0,        -- of those, the ones showTrail carried out

    -- THE COUNTER THAT WOULD HAVE FOUND THIS IN ROUND ONE (#131, 2026-08-16).
    --
    -- Every number above this line measures OUR side of the trail: what we
    -- decided, what we drew, what the key did. All five were healthy in the
    -- owner's readout and the sky was still empty, because none of them measures
    -- the thing that actually makes smoke -- GTA's own INPUT_PARACHUTE_SMOKE
    -- being held. The permission natives were mistaken for the emitter, so
    -- nothing anywhere pressed it and no counter was watching the gap.
    --
    -- This counts frames we asserted that control. It is the divider the old
    -- readout was missing: emit 0 across a whole canopy phase is this file's
    -- fault, while emit in the hundreds with an empty sky is the engine's, and
    -- before today there was no reading that could tell those apart.
    emits = 0,        -- frames INPUT_PARACHUTE_SMOKE was actually held for us
}

--- Take the parachute away for good, and kill the vanilla prompt with it.
---
--- `hard` is the second attempt: RemoveWeaponFromPed has now failed to shift
--- GADGET_PARACHUTE often enough (it is a gadget, not an ordinary weapon, and
--- the parachute task can hand it straight back as it unwinds) that the
--- fallback is RemoveAllPedWeapons -- which does work, and is safe here
--- because client/inventory.lua re-grants the active slot on its next tick.
--- @param ped integer
--- @param hard boolean|nil
local function disarmChute(ped, hard)
    if hard then
        RemoveAllPedWeapons(ped, true)
        if BR.Inv and BR.Inv.reapply then BR.Inv.reapply() end
    else
        RemoveWeaponFromPed(ped, CHUTE)
    end
    -- The COUNT is ammo and outlives the weapon removal; this is the line the
    -- "reserve chute after landing" reports kept coming back to.
    SetPedAmmo(ped, CHUTE, 0)
    ClearHelp(true)
end

--- Does this ped still have a parachute in any sense the engine cares about?
--- @param ped integer
--- @return boolean
local function hasChute(ped)
    return isTrue(HasPedGotWeapon(ped, CHUTE, false))
        or GetAmmoInPedWeapon(ped, CHUTE) > 0
end

AddEventHandler('br:drop:begin', function(d)
    -- One-shot thread: the give-verify-task sequence needs real frames
    -- between steps, and the first flight ended with a player falling
    -- chuteless -- never again on an assumption. dropping is set FIRST so
    -- the SPACE listener in bus.lua stands down immediately.
    dropping = true
    airborneSeen = false
    chuteSpent = false
    -- A new drop is a new prompt. See the note beside the declaration.
    trailKeyUsed = false
    -- The prompt's counters describe THIS drop. Cumulative ones would answer
    -- "has the box ever worked", which is not the question anybody asks after a
    -- descent where it did not (#131).
    promptSeen.kind = nil
    promptSeen.sends, promptSeen.draws = 0, 0
    promptSeen.fallbacks, promptSeen.trailFrames = 0, 0
    promptSeen.toggles, promptSeen.acted = 0, 0
    promptSeen.emits = 0
    -- Out of the door is the one moment that unambiguously un-lands you. See
    -- the note where this is SET, at the bottom of the drop machine.
    BR.State.landed = false
    landedThisDrop = false
    -- THE STOPWATCH STARTS AT THE DOOR (#245). Out of the plane is the one
    -- moment the whole descent is measured from, and it is the same moment
    -- everything else per-drop is cleared.
    landOpen(GetGameTimer())

    Citizen.CreateThread(function()
        local ped = PlayerPedId()

        SetEntityVisible(ped, true, false)
        FreezeEntityPosition(ped, false)
        ClearPedTasksImmediately(ped)

        -- Carry the bus's momentum out of the door; a dead-stop exit reads
        -- as teleportation even when the coordinates are right.
        --
        -- ...UNLESS THE CALLER SAYS THERE IS NO MOMENTUM TO CARRY. The revive
        -- key's arrival puts a player 150m ABOVE AN AMBULANCE (owner,
        -- 2026-08-30) and nothing threw them out of anything, so it asks for
        -- zero -- 25 m/s of borrowed bus speed would drift them a couple of
        -- hundred metres off the van they are supposed to be landing at. The
        -- default is the bus's own number, so bus.lua passes nothing and
        -- nothing about the drop changes.
        local speed = tonumber(d.speed) or 25.0
        local rad = math.rad(d.heading or 0.0)
        SetEntityVelocity(ped, -math.sin(rad) * speed, math.cos(rad) * speed, -2.0)

        -- THE CHUTE, VERIFIED -- and NEVER DOUBLED. GiveWeaponToPed is
        -- normally instant, but the one scenario where it quietly fails is
        -- a player mid-teleport -- which is exactly when this runs. Confirm
        -- it stuck, retry across real frames, and say so out loud if the
        -- game refuses. The has-check comes FIRST: giving a second
        -- GADGET_PARACHUTE to a ped that already holds one (the TICK
        -- floor's give can race this thread) stacks as chute ammo, which
        -- the engine treats as a RESERVE parachute -- the "handed another
        -- parachute after pulling the first" report (2026-08-04).
        for attempt = 1, 10 do
            if isTrue(HasPedGotWeapon(ped, CHUTE, false)) then break end
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
            if isTrue(HasPedGotWeapon(ped, CHUTE, false)) then break end
            if attempt == 10 then
                print('[br_core] drop: GADGET_PARACHUTE refused 10 times -- deploy will not work')
            end
            Citizen.Wait(0)
        end
        -- EXACTLY ONE, ALWAYS. Chute count is ammo, and a count above one
        -- is what the engine treats as a RESERVE parachute -- there is no
        -- reserve in this gamemode, whatever race between give paths may
        -- have happened (user rule, 2026-08-04).
        SetPedAmmo(ped, CHUTE, 1)

        SetPlayerParachuteModelOverride(PlayerId(),
            GetHashKey(BR.Config.Drop.parachuteModel))

        -- THE EQUIPPED CANOPY, AND IT HAS TO BE HERE. The tint is read when the
        -- canopy opens, so this must sit after the model override and before
        -- TaskParachute below -- the same window the smoke trail already used.
        -- Set it later and the previous design stays up, which looks exactly
        -- like the item the player bought not working.
        BR.Cosmetics.applyChute()

        -- THE TRAIL, AND IT NO LONGER ASKS ANYTHING ABOUT THE SQUAD (owner,
        -- 2026-08-20: "'Squad color' trails should not be a thing"). This used
        -- to read the roster for the player's squad colour and hand it to
        -- applyTrail as the fallback for anyone who had not bought a trail --
        -- itself the reversal of an earlier version where the squad colour won
        -- outright (#131). Both are gone: a trail is a purchase or it is
        -- nothing, so there is no colour for this end to look up and the hex
        -- parser that did it has gone with the argument.
        if BR.Config.Drop.smokeTrail then
            BR.Cosmetics.applyTrail()
        end

        -- TASKED, VERIFIED, RETRIED. TaskParachute issued in the same frame
        -- as a long teleport can silently not take -- the ped is mid-warp --
        -- and a ped without the task reports chute state -1 forever, which
        -- made SPACE dead on flight 3. The state saying FREEFALL/OPENING is
        -- the only proof the task exists.
        for attempt = 1, 8 do
            TaskParachute(ped, true, false)   -- second param verified unused
            Citizen.Wait(150)
            local cs = GetPedParachuteState(ped)
            if cs ~= BR.Native.ChuteState.NONE then break end
            if attempt == 8 then
                print('[br_core] drop: TaskParachute never took after 8 attempts')
            end
        end

        -- (The glider prompt is drawn per-frame below, so it persists until
        -- the canopy is actually out.)
    end)
end)

-- --------------------------------------------------------------------------
-- The descent prompt
-- --------------------------------------------------------------------------
--
-- THE OWNER WANTS A GLYPH, AND GTA'S HELP BOX CANNOT DRAW ONE FOR OUR KEYS.
--
-- "For #131 I do want glyphs. The glyphs should respect whatever key our player
-- selected in the pause menu for smoke trails." (2026-08-16.)
--
-- That second sentence is what settles it, and it rules out the help box twice
-- over rather than once:
--
--   1. THE TOKEN DOES NOT RENDER. Help text draws a button image from an
--      `~INPUT_*~` token, resolved against the engine's own control table. A
--      RegisterKeyMapping command is a SYNTHETIC control id (joaat | 0x80000000)
--      with no entry in that table, and `~INPUT_<hash>~` "renders a hole" --
--      measured on this build with /brpromptcheck, listed in probe.lua's roll of
--      guesses that cost a playtest each, and the reason bus.lua's own prompt
--      names INPUT_PARACHUTE_DEPLOY instead.
--
--   2. AND IF IT DID, IT WOULD DRAW THE WRONG KEY. This is the half that makes
--      it hopeless rather than merely unimplemented. Our rebinds do not live in
--      the engine: keybinds.lua keeps them in a KVP and routes them from raw key
--      codes, because "the engine still believes its own RegisterKeyMapping
--      default -- nothing can change that from script" (BR.Keys.labelFor's own
--      note, written after rebinding interact to R left every world prompt still
--      saying E). A glyph drawn from the engine's table would therefore always
--      show B, whatever the player chose -- which is verbatim the FAIL condition
--      in this issue's own validation steps.
--
-- So the prompt is drawn by the one thing that can draw whatever we like: our
-- own DUI page, dui/prompt.html, which already renders a key-cap badge for every
-- crate on the ground. Its badge IS the glyph, its text is the key label read
-- from BR.Keys, and a rebind moves both.
--
-- BOTH HALVES OF THE DESCENT MOVED, NOT JUST THE TRAIL. The glider prompt could
-- have stayed in the help box -- INPUT_PARACHUTE_DEPLOY does render -- and that
-- was the tempting smaller change. It would have split one prompt across two
-- rendering systems in two corners of the screen, for a handover the owner
-- validated as "the same box, same place, same style", and left the glider
-- prompt naming the ENGINE's key while the pause menu rebinds ours. One box,
-- one place, both keys the player's own.

--- The prompt page. Its own browser, NOT the crate prompt's.
---
--- Sharing 'lootprompt' would cost one fewer CEF instance and would work almost
--- always, because a player under a canopy is not standing over a crate. Almost
--- always is the problem: two owners of one page have to agree about who is
--- showing what, forever, across files that are edited by different people for
--- different reasons -- and the failure mode is a crate label hanging in the sky
--- or a descent prompt welded to a box on the ground.
local function promptPage()
    return BR.Dui.page('descentprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- What the box is currently saying: nil, 'glider' or 'trail'.
---
--- SENT ON CHANGE, DRAWN EVERY FRAME. That split is the whole reason a DUI beats
--- a NUI overlay here (dui.lua's opening note): the page only hears from us when
--- the words change, while the sprite is a native call per frame that costs
--- nothing. Re-sending the same payload sixty times a second would put a JSON
--- encode and a browser message on the frame path for no visible difference.
local promptKind = nil

--- The two key labels, cached for the length of a binding.
---
--- CACHED BECAUSE THE PROMPT IS PER-FRAME, and invalidated because a rebind has
--- to move it. Both halves are copied from the crate prompt, which learned them
--- the expensive way: it rebuilt its payload only when the target changed, so
--- rebinding interact in front of a crate "kept saying the old key until they
--- walked away and back" (user, 2026-08-09). A prompt drawn sixty times a
--- second must not do the lookup sixty times a second, and must not remember
--- the answer past the moment it stops being true.
---
--- `checked` is separate from the label because nil is a real answer: a player
--- who has deliberately cleared this binding has NO key, and re-asking every
--- frame for an answer that will not change is what the cache is avoiding.
local keyCache, keyChecked = {}, {}

AddEventHandler('br:keys:changed', function()
    keyCache, keyChecked = {}, {}
    -- AND THE BOX IS TOLD TO FORGET WHAT IT WAS SAYING. The payload is only
    -- re-sent when `promptKind` changes, so a rebind mid-descent would move the
    -- cached label and never push it -- the exact "kept saying the old key"
    -- failure this cache was copied from, reintroduced by the thing that fixes
    -- it. Clearing the kind forces one re-send on the next frame.
    promptKind = nil
end)

--- @param command string
--- @param fallbackControl integer|nil
--- @return string|nil  nil when the action is on no key at all
local function keyName(command, fallbackControl)
    if not keyChecked[command] then
        keyChecked[command] = true
        keyCache[command] = BR.Native.keyLabelForCommand(command, fallbackControl)
    end
    return keyCache[command]
end

--- Put a phase of the descent in the box, or take the box away.
--- @param kind string|nil  'glider', 'trail' or nil
local function setPrompt(kind)
    promptSeen.kind = kind
    if kind == promptKind then return end
    promptKind = kind
    promptSeen.sends = promptSeen.sends + 1

    local page = promptPage()
    if not kind then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = (kind == 'glider') and 'Open the glider'
                                    or 'Toggle smoke trails',
        hint  = 'Press',
        -- THE PLAYER'S OWN BINDING, ASKED FOR BY COMMAND. This is the glyph:
        -- prompt.html draws whatever lands here inside the key cap.
        --
        -- The two commands differ in their fallback, and deliberately. The
        -- glider has a vanilla control behind it (144, INPUT_PARACHUTE_DEPLOY,
        -- which genuinely still deploys during the parachute task) so naming it
        -- when we cannot read our own binding names a key that works. The trail
        -- has no such control we are willing to name: the obvious candidate is
        -- GTA's own parachute-smoke input, and pointing at it would quietly
        -- reintroduce the thing the owner ruled out -- "I'd rather not re-use
        -- that since it means leaving our own keybinds authority yet again". An
        -- unnameable trail key draws no prompt at all instead.
        key   = (kind == 'glider') and keyName('brdeploy', 144)
                                    or keyName('brtrail'),
        -- No ring: the ring is for a hold, and neither of these is one.
        ring  = false,
    })
end

-- The glider prompt PERSISTS until the chute is genuinely pulled -- redrawn
-- per frame while falling with the canopy stowed, gone the frame it opens.
--
-- AND THE CANOPY HANDS THE BOX OVER RATHER THAN EMPTYING IT (#131). The owner
-- asked for "a pointer text akin to the current 'press [key] to pull
-- parachute'" and then, "after pulling the chute it should say 'press [key] to
-- toggle smoke trails'" -- one box, two jobs, in sequence. So this is an
-- if/elseif and not two independent prompts: the descent never wants both at
-- once, and two things claiming the box in one frame is a box that flickers
-- between two sentences rather than a box that changed its mind.
BR.Loop.register(BR.Loop.FRAME, 'skydive.prompt', function()
    if not dropping then
        -- THE BOX GOES AWAY WITH THE DROP, and this is the only line that does
        -- it for the endings that are not a landing. The help box used to expire
        -- on its own the moment nothing redrew it; a DUI does not -- it holds
        -- the last thing it was told until it is told otherwise. A match killed
        -- mid-air (brforce, a mass leave) clears `dropping` and reaches nothing
        -- else, and without this the prompt would still be hanging on screen in
        -- the lobby.
        setPrompt(nil)
        return
    end
    local ped = PlayerPedId()

    -- F IS NOT A RIPCORD-CUTTER. INPUT_PARACHUTE_DETACH cuts the canopy
    -- mid-glide in base GTA -- and F is also the default enter-vehicle key, so
    -- players who reached for a door mid-descent dropped out of the sky (live
    -- report, 2026-08-04). Dead for the whole drop.
    --
    -- THE INDEX WAS WRONG AND THIS FIX HAS NEVER WORKED. It disabled 153,
    -- which is INPUT_PARACHUTE_BRAKE_RIGHT (E) -- so right-brake steering was
    -- dead for every descent since 2026-08-04, and the canopy-cutter it was
    -- written to stop stayed live the whole time. Detach is 145. Verified
    -- against the FiveM control table, not from memory; the same table is what
    -- settled INPUT_PARACHUTE_SMOKE being 154 rather than a native that emits
    -- on its own. See BR.Cosmetics.emitTrailThisFrame.
    DisableControlAction(0, 145, true)

    -- AND 144 GOES TOO, ONCE WE OWN THE KEY. GTA's parachute task reads
    -- INPUT_PARACHUTE_DEPLOY natively, so after the jump moved onto our binding
    -- (bus.lua, #174) a player who rebinds gets a jump key that works and a
    -- canopy that still opens on Space. Two keys for one action, one of them
    -- invisible to the settings screen.
    --
    -- GUARDED, AND THE GUARD IS LOAD-BEARING: with no binding at all -- which
    -- BR.Keys.set produces for the LOSER of a key conflict -- 144 is the last
    -- way to open the canopy, and taking it away is a death rather than an
    -- inconvenience.
    if BR.Keys.labelFor('brdeploy') then
        DisableControlAction(0, 144, true)
    end

    local cs = GetPedParachuteState(ped)

    -- THE SMOKE ITSELF, AND IT IS A HELD KEY RATHER THAN A FLAG (#131).
    --
    -- Everything this issue has done until now set a PERMISSION and expected
    -- smoke. GTA does not work that way: the parachute trail comes out while
    -- INPUT_PARACHUTE_SMOKE is held and stops when it is released, and the two
    -- SetPlayerParachute* natives only decide whether that key is allowed to do
    -- anything and what colour it makes. Nothing in this codebase has ever held
    -- it, which is why the owner's readout could show `armed true on true` with
    -- both natives called and a completely empty sky. The argument, and the
    -- verification behind the control index, are in cosmetics.emitTrailThisFrame.
    --
    -- HERE, NOT IN THE PROMPT BRANCH BELOW, and the distinction matters: that
    -- branch also requires a nameable key, because a prompt with an empty badge
    -- is worse than no prompt. Smoke has no such requirement -- a player who
    -- deliberately cleared their `brtrail` binding still bought the trail and
    -- still gets it, they simply cannot toggle it off. Hanging the emission off
    -- the prompt's conditions would have made a cosmetic depend on whether we
    -- could draw a letter.
    --
    -- Per frame because SetControlNormal lasts exactly one frame, and cheap: one
    -- native call, only under a canopy, only when the trail is armed and on.
    if cs == BR.Native.ChuteState.OPENING or cs == BR.Native.ChuteState.OPEN then
        if BR.Cosmetics.emitTrailThisFrame() then
            promptSeen.emits = promptSeen.emits + 1
        end
    end

    local kind = nil

    -- The airborne test must NOT be `not IsPedOnFoot`: a ped in the
    -- parachute task's freefall COUNTS AS ON FOOT, so that gate killed the
    -- prompt for the entire healthy drop (live report, 2026-08-04). What
    -- it was guarding against -- the canopy detaching a beat before the
    -- TICK landing branch disarms, flashing "open the glider" at a player
    -- standing on the ground -- is covered by the freefall/falling pair
    -- below, both false for a ped with feet on anything.
    if (isTrue(IsPedInParachuteFreeFall(ped)) or isTrue(IsPedFalling(ped)))
       and (cs == BR.Native.ChuteState.ON_BACK
            or cs == BR.Native.ChuteState.FREEFALL) then
        kind = 'glider'

    elseif cs == BR.Native.ChuteState.OPENING
        or cs == BR.Native.ChuteState.OPEN then
        -- THREE THINGS HAVE TO BE TRUE, and each one is a prompt somebody would
        -- otherwise be shown for nothing.
        --
        -- ARMED: there is a trail flying. Every player has a trail EQUIPPED --
        -- the catalogue default is 'None', which paints nothing -- so the slot
        -- is not the question, and only the branches that actually paint set
        -- this flag (cosmetics.lua argues it beside trailArmed). #131 is
        -- explicit that "somebody with nothing equipped should see no prompt at
        -- all rather than a prompt for a thing they do not have", and with the
        -- free default painting nothing that is now the commonest case rather
        -- than the solo one.
        --
        -- THERE IS NO SQUAD TEST HERE, and two rules have come and gone to leave
        -- it that way. It used to require `not BR.Cosmetics.trailSquad`, because
        -- a squad colour overrode a bought trail and offering to switch that off
        -- would have been deleting three other people's position marker. #131
        -- reversed the override; the owner has since removed the squad colour
        -- from the sky altogether. Whatever is armed here was bought by the
        -- player looking at the prompt, so there is nobody else's decision left
        -- to protect.
        --
        -- THERE IS NO ON-FOOT TEST HERE ANY MORE, AND ITS REMOVAL IS #131's
        -- THIRD ROUND.
        --
        -- It read `not IsPedOnFoot(ped)`, argued as the cheap half of a grounded
        -- test: a canopy still attached after touchdown holds the ped off "on
        -- foot", so this would drop the prompt at the moment of landing. That
        -- reasoning is fine and the clause still had to go, because it is the
        -- ONE condition in this branch that has never been measured in the air
        -- on this build -- and forty lines above, in this same callback, is the
        -- live report of what happened the last time this file inferred
        -- airborne-ness from IsPedOnFoot: "a ped in the parachute task's
        -- freefall COUNTS AS ON FOOT, so that gate killed the prompt for the
        -- entire healthy drop" (2026-08-04). The glider prompt lost its on-foot
        -- gate for exactly that reason and has worked since; the trail prompt
        -- kept one, and is the half of the descent that has now failed to appear
        -- twice. That asymmetry is the only difference between the two branches
        -- that the engine gets a vote in.
        --
        -- Nothing is lost by dropping it. The phase is already bounded twice
        -- over -- `dropping`, which the TICK machine clears within 100ms of
        -- touchdown, and the chute state, which this branch is inside -- and
        -- clearTrail() on landing takes `trailArmed` down with it, which is the
        -- first test below. The worst case is a tenth of a second of prompt
        -- after a landing where the canopy stayed attached, which is the cost
        -- the removed clause was itself willing to pay.
        --
        -- ARMED, AND ON A KEY. What remains is the pair that decides whether
        -- there is anything honest to say: a trail actually flying, and a key
        -- to name. A player who has deliberately cleared this binding has
        -- nothing to be shown -- the badge would render empty and the sentence
        -- would be an instruction to press nothing. Cached, so this is a table
        -- lookup per frame rather than a lookup per frame.
        --
        -- AND ONCE IS ENOUGH (owner, 2026-08-17). `trailKeyUsed` is the third
        -- test and it is the only one that can go from true to false and never
        -- back within a drop: the box is an instruction, the player has followed
        -- it, and it stops. See the declaration at the top of this file for why
        -- it does not track the trail's on/off state.
        if BR.Cosmetics.trailArmed and not trailKeyUsed and keyName('brtrail') then
            kind = 'trail'
        end
    end

    setPrompt(kind)
    if not kind then return end
    if kind == 'trail' then promptSeen.trailFrames = promptSeen.trailFrames + 1 end

    -- A BROWSER THAT NEVER CAME UP MUST NOT MEAN SILENCE (#131, third round).
    --
    -- BR.Dui.drawScreen draws nothing while IsDuiAvailable is false, and says
    -- nothing about it -- which is right for a crate label on the far side of a
    -- field and wrong here. A DUI is a whole CEF instance and this file asks for
    -- a SECOND one; if it does not come up, or comes up late, or the sprite
    -- never reaches the screen for any of the reasons a runtime texture can
    -- fail, the descent gets no prompt at all and nothing anywhere says why.
    -- That is indistinguishable from "the player has nothing equipped", which is
    -- a correct outcome -- and telling those two apart from the cockpit is what
    -- this issue has now cost three rounds.
    --
    -- So the words fall back to the engine's own help box. The GLYPH is what is
    -- lost, and only in the case where the glyph could not have been drawn
    -- anyway: the letter here is the player's own binding read from BR.Keys, so
    -- the fallback names the key that works, and does NOT use an `~INPUT_~`
    -- token -- the token for one of our commands renders as a hole, which is the
    -- measurement that sent this prompt to a DUI in the first place.
    local D = BR.Config.Drop
    local page = promptPage()
    if BR.Dui.ready(page) then
        promptSeen.draws = promptSeen.draws + 1
        BR.Dui.drawScreen(page,
            D.promptX or 0.5, D.promptY or 0.78, D.promptScale or 0.17)
    else
        promptSeen.fallbacks = promptSeen.fallbacks + 1
        local key = (kind == 'glider') and keyName('brdeploy', 144)
                                        or keyName('brtrail')
        BR.Native.helpThisFrame(('Press %s to %s'):format(
            tostring(key),
            (kind == 'glider') and 'open the glider' or 'toggle smoke trails'))
    end
end)

-- THE TOGGLE ITSELF (#131).
--
-- The owner playtested the previous answer to this issue -- which correctly
-- established that trails were automatic and added help text saying so -- and
-- reported "I can't tell anything was even changed". The requirement moved:
-- there is to be a key, it is to be ours, and the descent is to say so. This is
-- that key.
--
-- IT ONLY EVER FLIPS A SWITCH THE DROP ALREADY THREW. showTrail does not
-- re-decide the colour, and this does not call applyTrail -- the colour is
-- chosen once at br:drop:begin, in the window between the parachute model
-- override and TaskParachute where the engine actually reads it. Re-running
-- that choice from a key press would move it outside its window, and a trail
-- set outside its window "looks exactly like the item the player bought not
-- working" -- which is the report this issue opened with.
BR.Keys.on('trail', function(pressed)
    if not pressed or not dropping then return end
    -- Counted HERE -- after the drop test, before the armed one -- so the number
    -- means "a press arrived while there was a descent to act on". Counting
    -- above the `dropping` test would tick for every press in the lobby and stop
    -- answering the question it is here to answer. See promptSeen.toggles.
    promptSeen.toggles = promptSeen.toggles + 1

    -- THE SQUAD REFUSAL THAT USED TO BE HERE IS GONE (#131, 2026-08-16). It
    -- answered a press in a squad with "your squad's colour is flying instead,
    -- so your team can find you -- it stays on", which was the honest
    -- explanation of a deliberate override. The owner removed the override:
    -- "Squad colors should not override the bought trail - the player earned
    -- that trail." With nothing overriding anything, that reply would now be a
    -- refusal with no rule behind it -- the key would decline to switch off a
    -- trail the player bought, and tell them a story about a colour that is not
    -- in the sky. The branch went with the override rather than being reworded,
    -- and there is no squad colour left anywhere to reword it back for.

    -- Nothing equipped, or the trail system switched off in config: no prompt
    -- was drawn and there is nothing to flip. Silent, because this is a market
    -- question and not a descent one -- a message here would be an
    -- advertisement fired by a key press mid-fall.
    if not BR.Cosmetics.trailArmed then return end

    -- THE BOX HAS BEEN ANSWERED. Set here rather than beside the toggle count
    -- above, and the placement is the whole of it: `trailArmed` is exactly the
    -- condition the prompt is drawn under, so a press that reaches this line is
    -- a press against a box that was on offer. A press during freefall counts
    -- too -- the player has still used the key, the trail still comes on the
    -- moment the canopy does, and re-offering it under the canopy would be the
    -- interface forgetting something it was told fifteen seconds ago.
    trailKeyUsed = true

    -- showTrail returns false when there was no trail flying to act on, which
    -- the guard above has already excluded -- so `acted` rising in step with
    -- `toggles` is the readout saying the native was called with a new value
    -- every single time. If it is and the smoke is still there, nothing left in
    -- this file can be the cause.
    if BR.Cosmetics.showTrail(not BR.Cosmetics.trailOn) then
        promptSeen.acted = promptSeen.acted + 1
    end
end)

-- Manual deploy on OUR keymapped binding too (the base game's own deploy
-- input already works natively during the task). If the engine lost the
-- parachute task (state -1 while clearly airborne), this re-tasks instead of
-- doing nothing -- a dead key during a fatal fall is the worst possible
-- failure mode, twice observed.
BR.Keys.on('deploy', function(pressed)
    if not pressed or not dropping then return end
    local ped = PlayerPedId()
    if isTrue(IsPedInAnyVehicle(ped, true)) then return end
    local cs = GetPedParachuteState(ped)
    -- ON_BACK is the state a HEALTHY drop spends its whole freefall in (the
    -- chute was given, so the engine never reports 3/falling-to-doom). The
    -- old check only forced the canopy from FREEFALL, which is why the key
    -- read as dead for every player whose drop was going fine.
    if cs == BR.Native.ChuteState.FREEFALL
       or cs == BR.Native.ChuteState.ON_BACK then
        ForcePedToOpenParachute(ped)
    elseif cs == BR.Native.ChuteState.NONE
       and not isTrue(IsPedOnFoot(ped)) and not isTrue(IsEntityInWater(ped)) then
        -- State NONE means the TASK is lost, not necessarily the weapon --
        -- re-giving one the ped still holds stacks a reserve chute.
        if not isTrue(HasPedGotWeapon(ped, CHUTE, false)) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        SetPedAmmo(ped, CHUTE, 1)   -- exactly one; never a reserve
        TaskParachute(ped, true, false)
    end
end)

-- The drop state machine, at TICK rate -- 10Hz is far finer than any of
-- these transitions and keeps GetEntityHeightAboveGround (slow) off the
-- frame path.
BR.Loop.register(BR.Loop.TICK, 'skydive.state', function()
    -- Armed by the drop handoff OR by the server calling me a faller --
    -- whichever arrives first. Gating on the handoff alone meant that if it
    -- was ever missed, the chute floor below was disarmed for exactly the
    -- player who needed it.
    if not dropping then
        local st = BR.State.me.state
        if st ~= BR.PlayerState.FREEFALL and st ~= BR.PlayerState.GLIDE then
            return
        end
        -- THE SERVER CALLING US A FALLER IS A CLAIM, NOT A MEASUREMENT, AND
        -- AFTER TOUCHDOWN IT IS AN OUT-OF-DATE ONE (#126).
        --
        -- This re-arm is a net under a missed drop handoff and it must stay.
        -- What it must NOT do is re-run the whole machine -- landing branch,
        -- disarm sweep, report, toast -- for a player standing on the ground
        -- whose landing report simply has not been answered yet. That is the
        -- normal case for the first few hundred milliseconds of every drop and
        -- the indefinite case whenever the report goes missing, which is the
        -- whole subject of #126. Re-arming there meant a landing that fired
        -- ten times a second for as long as the server disagreed.
        --
        -- So the ped gets the casting vote: genuinely in the air (walked off a
        -- cliff, force-ejected again) re-arms and clears the latch; standing on
        -- the ground does not. Nothing is lost -- the report is being re-sent
        -- by reportLanded's retry, which now actually retries.
        if landedThisDrop and not airborneNow(PlayerPedId()) then return end
        landedThisDrop = false
        dropping = true
        -- A DESCENT THIS FILE WAS NEVER HANDED still gets measured (#245). This
        -- is the missed-handoff net, and a landing that arrives through it is
        -- precisely the one nobody has a reading for. `exitAt` is the re-arm
        -- rather than the door, so `fall` is short here and means nothing --
        -- every other number on the line is measured from contact and stands.
        if not landTime.open then landOpen(GetGameTimer()) end
    end

    local ped = PlayerPedId()

    -- A DRIVER'S SEAT IS NOT A DROP. In a vehicle IsPedOnFoot is false, so
    -- the airborne test below reads "falling" -- and the chute floor then
    -- gave the ped a parachute, re-tasked it, and forced the canopy, which
    -- EJECTS from the vehicle (live report: "given a parachute, prompted to
    -- pull, immediately ejected"). If the machine was somehow still armed
    -- when the player got in, entering a vehicle IS proof of being landed:
    -- finish the drop and stand down.
    if isTrue(IsPedInAnyVehicle(ped, true)) then
        if dropping then
            dropping = false
            landedThisDrop = true
            -- THE OTHER WAY A DROP ENDS ON THE GROUND gets a line too (#245).
            -- Stamped where the branch decides, not polled after it, so stage 2
            -- carries no sampling lag of its own.
            landBranch(GetGameTimer(), ped, 'seat')
            disarmChute(ped)
            -- clearTrail() rather than the bare native: #131 routed every
            -- trail stand-down through one helper so a match killed mid-air
            -- cannot leave the state armed into the next round.
            BR.Cosmetics.clearTrail()
            -- THE SECOND WAY A DROP ENDS ON THE GROUND, AND IT WAS TELLING THE
            -- SERVER AND NOT THE INTERFACE (#126).
            --
            -- This branch already reasoned that a seat is proof of a landing --
            -- it reports one. What it did not do is set the latch the whole of
            -- #126 hangs off, so a player who ended their drop by getting into
            -- a vehicle had the server told and their own client left thinking
            -- it was still in the air: no HUD, no inventory bar, no crate
            -- prompt, until the report completed its round trip. The fix for a
            -- report that goes missing is worth nothing on the one path that
            -- never armed it. Same two lines as the ordinary landing below.
            BR.State.landed = true
            BR.PushHud(true)
            reportLanded()
            print('[br_core] drop: finished from a vehicle seat -- the machine was still armed')
        end
        return
    end

    local cs = GetPedParachuteState(ped)

    -- Spend the chute the moment the canopy appears -- see the note on
    -- chuteSpent at the top. One write, latched, so this is not fighting the
    -- engine every tick of a two-minute glide.
    if not chuteSpent
       and (cs == BR.Native.ChuteState.OPENING
            or cs == BR.Native.ChuteState.OPEN) then
        chuteSpent = true
        SetPedAmmo(ped, CHUTE, 0)
    elseif not chuteSpent then
        -- EXACTLY ONE, EVERY TICK, FOR THE WHOLE FALL.
        --
        -- Setting it once at the give was not enough: a count above one is
        -- what the engine renders as a reserve, and something puts it back
        -- (the parachute task's own setup is the suspect -- MP peds are
        -- expected to carry a spare). Rather than keep guessing which path
        -- does it, this simply refuses to let the count be anything but one
        -- while the canopy is stowed. It is one native write at 10Hz.
        if GetAmmoInPedWeapon(ped, CHUTE) > 1 then
            SetPedAmmo(ped, CHUTE, 1)
        end
    end

    -- THE FLOOR, UNCONDITIONALLY. Below the auto-deploy height with the
    -- canopy not out, this hammers EVERY tick until it is: re-give, re-task,
    -- force -- regardless of which state the chute machinery claims to be in
    -- (-1 task lost, 0 stowed, 3 freefall; ragdolls lie about all three).
    -- Earlier versions gated each recovery step on the state that step
    -- expected, and players fell past a floor made of preconditions. The
    -- descent is invincible as the last net, but the chute is the fix.
    local agl = GetEntityHeightAboveGround(ped)
    local airborne = not isTrue(IsPedOnFoot(ped)) and not isTrue(IsEntityInWater(ped))
    if airborne and agl > 3.0 then airborneSeen = true end
    -- The floor's band has a BOTTOM as well as a top: below ~3m a chute
    -- can do nothing, and firing there is pure harm -- the vehicle-entry
    -- animation reads as "airborne at ground level" for a beat (not on
    -- foot, chute state NONE once the task drops), and the floor answered
    -- it by handing the player a parachute and forcing it open ("given a
    -- chute the moment I try to enter a vehicle", live report 2026-08-04).
    if airborne
       and cs ~= BR.Native.ChuteState.OPENING
       and cs ~= BR.Native.ChuteState.OPEN
       and agl > 3.0
       and agl < BR.Config.Drop.autoDeployAGL then
        if not isTrue(HasPedGotWeapon(ped, CHUTE, false)) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        -- Ammo is re-asserted here even when the weapon was already held: the
        -- canopy-spent latch above zeroes it, and a chute that reverted to
        -- ON_BACK afterwards would have nothing to deploy. The floor is the
        -- unconditional net -- it must not be able to fire blanks.
        SetPedAmmo(ped, CHUTE, 1)   -- exactly one; never a reserve
        chuteSpent = false
        if cs ~= BR.Native.ChuteState.FREEFALL then
            TaskParachute(ped, true, false)
        end
        ForcePedToOpenParachute(ped)
        return
    end

    -- Landed: on the ground, not falling, canopy not mid-opening -- and
    -- only after the drop has actually BEEN airborne (see the latch note
    -- at the top). Water counts: a sea landing is a bad drop, not a
    -- continuing one.
    --
    -- ANY chute state except OPENING counts as landed. The old test
    -- required NONE/ON_BACK, but the engine sometimes keeps the canopy
    -- ATTACHED after touchdown (state still OPEN, with GTA's own "press F
    -- to release parachute" prompt) -- so the machine stayed armed, the
    -- glider prompt lingered, and the next F press (bound to enter-vehicle)
    -- hit the chute floor from a driver's seat: the parachute-in-a-car
    -- ejection, root-caused at last (user insight, 2026-08-04).
    --
    -- AND on-foot alone is not the whole grounded test: with the canopy
    -- still ATTACHED the parachute task holds the ped off "on foot"
    -- indefinitely -- the machine stayed armed on the ground, which kept
    -- F dead (control 153 stays disabled while dropping) and left the
    -- floor loaded for the vehicle-entry gap (live report, 2026-08-04:
    -- "press F, nothing; enter a vehicle, given a chute"). A ped standing
    -- still at ground level with the canopy out has landed, whatever the
    -- task claims.
    local grounded = isTrue(IsPedOnFoot(ped)) or isTrue(IsEntityInWater(ped))
    if not grounded and cs == BR.Native.ChuteState.OPEN
       and agl < 2.0 and GetEntitySpeed(ped) < 2.0 then
        grounded = true
    end
    -- ONE LINE ABOVE THE PREDICATE, FROM THE PREDICATE'S OWN VALUES (#245).
    -- Anywhere else and the ruler could disagree with the thing it measures --
    -- a second `grounded` computed a tick later, from a ped that had moved, is
    -- how a stall measures zero.
    landSample(ped, cs, agl, airborneSeen, grounded)

    if airborneSeen
       and cs ~= BR.Native.ChuteState.OPENING
       and not isTrue(IsPedFalling(ped))
       and grounded then
        dropping = false
        landBranch(GetGameTimer(), ped)
        -- ONCE PER DROP. Everything below this line is a one-shot -- a disarm
        -- sweep, a report, a toast -- and the re-arm at the top of this
        -- callback used to bring the machine straight back for as long as the
        -- server had not answered the report, so all of them fired again on
        -- the next tick, and the next (#126). See landedThisDrop.
        landedThisDrop = true

        if cs == BR.Native.ChuteState.OPEN then
            -- Shed the still-attached canopy along with its vanilla prompt.
            ClearPedTasks(ped)
        end

        -- REMOVAL IS VERIFIED, NOT ASSUMED. The give path has retried across
        -- real frames since flight one, on the grounds that GiveWeaponToPed
        -- can quietly fail around a teleport -- and the removal path, doing
        -- the mirror-image thing at the mirror-image moment, never did. It
        -- also has to outlive ClearPedTasks: the task teardown can hand the
        -- weapon back into the ped's hands a frame later, which no
        -- single-shot RemoveWeaponFromPed can see coming.
        disarmChute(ped)
        Citizen.CreateThread(function()
            for attempt = 1, 15 do
                Citizen.Wait(100)
                local p = PlayerPedId()
                if not hasChute(p) then break end
                -- Escalate after three polite attempts.
                disarmChute(p, attempt >= 3)
            end
        end)

        BR.Cosmetics.clearTrail()

        -- A short grace absorbs the landing-stumble edge cases (gamerules
        -- reads this alongside its warmup/bus invincibility rule).
        BR.State.dropGraceUntil = GetGameTimer() + BR.Config.Drop.landedGraceMs

        -- LANDED, SAID BY THE ONLY MACHINE THAT CAN SEE IT.
        --
        -- Everything a landed player has -- the inventory bar, the squad panel,
        -- a weapon in the hand, a crate they can open -- has until now waited
        -- for the SERVER to agree, which it does when reportLanded() below
        -- finally gets through. That message goes missing often enough to have
        -- its own retry loop and its own server-side rescue net, and while it
        -- is in flight the player stands in a POI with nothing, sometimes until
        -- the match reaches PLAYING and something else promotes them (#126).
        -- It was read as slowness and answered with speed; it is not slowness,
        -- the systems are simply off.
        --
        -- This is the local half of the answer, and it is narrow on purpose: it
        -- decides only what this client DRAWS and what it will let this player
        -- reach for. Every authoritative question -- did the claim succeed, did
        -- the bullet count, what placement was this -- is still the server's
        -- and still keyed on the state it holds. Reading our own ped is the one
        -- observation a client is always entitled to make.
        BR.State.landed = true
        BR.PushHud(true)

        reportLanded()
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Loot up before the storm comes!', tone = 'info', ms = 6000,
        })
        print('[br_core] landed')
    end
end)

-- THE BACK HALF OF THE STOPWATCH -- stages 3 and 4, and the line itself (#245).
--
-- REGISTERED AFTER skydive.state, WHICH IS THE WHOLE POINT OF ITS POSITION IN
-- THIS FILE. The registry runs a band in registration order, so on the pass
-- where the landing branch fires this callback sees the branch's effects in the
-- SAME pass -- BR.State.landed already set, the report already sent. Registered
-- before it, every landing would carry a spurious 100ms in stage 4 that came
-- from the instrument and not the game.
--
-- IT IS NOT GATED ON `dropping`, and it cannot be: the branch clears `dropping`
-- and skydive.state then returns at its own top guard, so anything waiting for
-- the server's answer has to be watching from outside the drop machine. That is
-- the same reason the disarm sweep below runs there.
BR.Loop.register(BR.Loop.TICK, 'skydive.landtime', function()
    local L = landTime
    if not L.open or L.printed then return end

    local now = GetGameTimer()
    local st = BR.State.me.state
    local airborneState = st == BR.PlayerState.FREEFALL
                       or st == BR.PlayerState.GLIDE
                       or st == BR.PlayerState.BUS
    if airborneState then L.sawAir = true end

    -- THE SERVER'S ANSWER, AND ONLY AFTER IT HAS ASKED THE QUESTION. Without
    -- `sawAir` a drop whose jump the server had not yet registered would find
    -- the mirror still saying ALIVE from the last round and stamp stage 3 at
    -- zero on the way out of the door -- a promotion that had not happened,
    -- timed as instant.
    if not L.serverAt and L.sawAir and not airborneState then
        L.serverAt = now
    end

    -- WHAT THE PLAYER ACTUALLY SEES, which is neither of the two facts above on
    -- its own. hud/Hud.tsx hides the inventory bar while the state is
    -- freefall/glide AND `landed` is false, so EITHER our own ped's verdict or
    -- the server's promotion un-hides it, whichever lands first.
    if not L.uiAt and (BR.State.landed == true or L.serverAt ~= nil) then
        L.uiAt = now
    end

    local base = L.contactAt or L.branchAt or L.serverAt
    if not base then return end

    -- A LANDING WHOSE STORY IS ALREADY OVER IS NOT WORTH ANOTHER FIFTEEN
    -- SECONDS OF SILENCE. Once the server has promoted us the only question
    -- left is whether the branch ever fires, and a branch that has not fired
    -- three seconds after the promotion IS the finding -- that is the shape the
    -- owner is reporting. Holding the record open to the full cap for it would
    -- risk the next drop opening over the top of it, which is the one way this
    -- readout could lose the landing it exists for.
    local due = base + LAND_DEADLINE_MS
    if L.serverAt and not L.branchAt then
        local sooner = L.serverAt + LAND_AFTER_SERVER_MS
        if sooner < due then due = sooner end
    end

    if (L.branchAt and L.serverAt and L.uiAt) or now >= due then
        landPrint()
    end
end)

-- THE STANDING DISARM. Everything above depends on the landing branch firing,
-- and the landing branch has now been wrong in four different ways across four
-- sessions -- attached canopies, vehicle seats, water, the state machine never
-- arming at all. This is the net under all of it: a player the SERVER calls
-- landed (ALIVE/DBNO), standing on the ground, must not be holding a
-- parachute, whatever route they took to get there.
--
-- HasPedGotWeapon first, so the ordinary case is one cheap call at 10Hz and the
-- expensive height probe only runs for a ped that actually still has a chute.
local sweeps = 0
BR.Loop.register(BR.Loop.TICK, 'skydive.disarm', function()
    if dropping then return end

    local st = BR.State.me.state
    if st ~= BR.PlayerState.ALIVE and st ~= BR.PlayerState.DBNO then return end

    local ped = PlayerPedId()
    if not hasChute(ped) then
        sweeps = 0
        return
    end

    -- WATER IS GROUND. GetEntityHeightAboveGround measures to the SEABED, so
    -- a player swimming in 30m of water reads as 30m up and the height gate
    -- skipped them entirely -- which is the worst possible place to leave
    -- someone armed with a parachute, because the engine's next expected
    -- action is a deploy they cannot perform (user, 2026-08-05).
    local inWater = isTrue(IsEntityInWater(ped))
    if not inWater then
        -- Never yank one out of the air: if this player is somehow genuinely
        -- falling, the floor above is the system that owns them.
        if isTrue(IsPedFalling(ped)) or GetEntityHeightAboveGround(ped) > 5.0 then
            sweeps = 0
            return
        end
    end

    sweeps = sweeps + 1
    disarmChute(ped, sweeps >= 3)
end)

--- Everything about the drop, in one paste.
-- RENAMED FROM `brdrop` (#137). keybinds.lua registers `brdrop` for the "drop
-- selected item" action, this file loads after it, and the later registration
-- wins -- so on a client with no raw-key layer the G key ran THIS debug dump
-- and never dropped anything. The keybind's name is the one that cannot move:
-- RegisterKeyMapping and every saved rebind in KVP refer to it by name.
RegisterCommand('brdropdbg', function()
    local ped = PlayerPedId()
    print('=== drop (client) ===')
    print(('  dropping  %s   chuteState %d   hasChute %s   chuteAmmo %d   reserve %s'):format(
        tostring(dropping), GetPedParachuteState(ped),
        tostring(HasPedGotWeapon(ped, CHUTE, false)),
        GetAmmoInPedWeapon(ped, CHUTE),
        tostring(GetPlayerHasReserveParachute(PlayerId()))))
    print(('  AGL %.0fm   onFoot %s   inWater %s   falling %s'):format(
        GetEntityHeightAboveGround(ped), tostring(IsPedOnFoot(ped)),
        tostring(IsEntityInWater(ped)), tostring(IsPedFalling(ped))))
    -- THE THREE FACTS #126 IS ABOUT, SIDE BY SIDE. `landed` is what this
    -- client draws off, `me.state` is what the server will actually let the
    -- player do, and `landedThisDrop` says whether the drop machine believes it
    -- has finished. Two of them disagreeing is the bug; which two says which
    -- half of it.
    print(('  landed %s   landedThisDrop %s   server says %s   match %s'):format(
        tostring(BR.State.landed), tostring(landedThisDrop),
        tostring(BR.State.me.state), tostring(BR.State.match.state)))

    -- THE LAST LANDING'S STAGE BREAKDOWN, REPEATED (#245). It already printed
    -- itself the moment it happened, which is the only way to catch a player
    -- who is mid-drop -- and a console that has scrolled past it is the
    -- commonest way a one-shot readout is lost. `(not yet)` here after a
    -- landing means the record never completed, which is itself the reading:
    -- see LAND_DEADLINE_MS.
    print('  ' .. (landTime.last or 'landtime: (not yet -- no drop has finished)'))
    -- THE ANSWERS THE TRAIL PROMPT IS MADE OF, in the order it asks them, so
    -- "why is there no prompt" is one command rather than a guess. `armed false`
    -- means nothing equipped paints; `key (none)` means the binding was cleared.
    -- Each is a different fix and they are indistinguishable in the air, which
    -- is exactly how #131 came back a second time.
    --
    -- TWO ANSWERS HAVE LEFT THIS LINE, EACH WITH THE RULE IT REPORTED ON.
    -- `squad true` meant "the squad override took your trail, and that is
    -- correct"; #131 removed the override. `source purchase|squad` replaced it
    -- and said which of the two paints won -- and the owner has now removed the
    -- squad paint entirely ("'Squad color' trails should not be a thing"), so
    -- there is one paint, `source` could only ever say 'purchase', and it was
    -- `armed` in a second spelling. A readout with a column that cannot vary is
    -- a column somebody reads as evidence.
    --
    -- AND `engine` IS THE ONLY ONE OF THESE THE GAME SAID RATHER THAN US. The
    -- others are our own variables agreeing with one another, which is exactly
    -- what they did through all three of the owner's prints while nothing
    -- rendered. A colour here that is not the one the equipped item names means
    -- the write never reached the engine; the right colour with an empty sky
    -- means it did, and the emit count below is the next question.
    print(('  trail: armed %s   on %s   key %s   engine rgb %s'):format(
        tostring(BR.Cosmetics.trailArmed),
        tostring(BR.Cosmetics.trailOn),
        tostring(BR.Native.keyLabelForCommand('brtrail') or '(none)'),
        BR.Cosmetics.engineTrailColour()))

    -- AND WHETHER PRESSING THAT KEY DID ANYTHING (#131, fifth round). The line
    -- above says what the trail IS; this one says what the key DID, which is the
    -- half the report "draws perfectly but does not do anything" leaves open.
    --
    --   presses 0                the key never reached this file. The binding,
    --                            not the trail -- check `brkeys` for the row and
    --                            whether it says `via engine`.
    --   presses > 0, acted 0     the presses arrived and were refused, which
    --                            here can only mean nothing was armed to act on.
    --   presses > 0, acted > 0   every press was carried out and the permission
    --                            native was told a new value each time.
    --
    -- AND THAT LAST LINE USED TO END "so the engine is at fault and no change to
    -- this file will fix it", WHICH WAS WRONG AND COST THIS ISSUE A ROUND. The
    -- owner's readout hit exactly that case -- presses 1, acted 1, permission
    -- granted, no smoke -- and the conclusion drawn from it was that GTA was
    -- declining to honour the flag mid-glide. It was not. Nothing had ever asked
    -- for smoke: the permission natives are not emitters, and the emit count is
    -- the reading that was missing.
    --
    --   emits 0 under a canopy      nothing held INPUT_PARACHUTE_SMOKE. Either
    --                               the trail is toggled off (`on false` above)
    --                               or this file's descent loop is not running
    --                               (see the loop line below).
    --   emits > 0 and an empty sky  the control was held for that many frames
    --                               with permission granted and the colour the
    --                               engine reports above. THAT is the reading
    --                               that would exonerate the Lua -- and it is
    --                               the first time this issue has been able to
    --                               produce it.
    --
    -- `used` IS WHY THE BOX IS NOT ON SCREEN, and it is printed because it is
    -- now the commonest honest reason for that. The trail defaults OFF and the
    -- prompt retires after one press, so `used true  on false` is a player who
    -- turned the smoke on and straight back off again -- correct, and otherwise
    -- indistinguishable from a prompt that failed to draw.
    print(('  trail key: presses %d   acted %d   emit frames %d   used %s'):format(
        promptSeen.toggles, promptSeen.acted, promptSeen.emits,
        tostring(trailKeyUsed)))

    -- AND WHETHER ANY OF THAT REACHED THE SCREEN, which is the half the first
    -- two rounds could not see (#131). The four counts separate the three ways
    -- a prompt disappears, and they are three different bugs:
    --
    --   saying trail, drawn 0, text 0   the callback decided to show it and
    --                                   nothing put it anywhere -- the loop line
    --                                   below says whether it is still running.
    --   saying trail, drawn 0, text >0  the browser never came up; the words are
    --                                   in GTA's help box instead of our badge.
    --   saying (none), armed false      nothing equipped paints. Not a bug: buy
    --                                   a trail, equip it, drop SOLO.
    --   trailFrames 0 after a glide     the canopy phase was never entered at
    --                                   all -- read chuteState above, not this.
    print(('  prompt: saying %s   sends %d   drawn %d   as text %d   trail frames %d   page %s'):format(
        tostring(promptSeen.kind or '(none)'),
        promptSeen.sends, promptSeen.draws, promptSeen.fallbacks,
        promptSeen.trailFrames,
        BR.Dui.ready(promptPage()) and 'up' or 'NOT UP'))

    -- A SUSPENDED CALLBACK IS SILENT, AND SILENCE IS THIS ISSUE'S WHOLE SYMPTOM.
    -- BR.Loop retires a callback after five consecutive errors and says so once,
    -- in a console nobody was reading at the time. If the descent prompt has
    -- been retired, everything above it is beside the point.
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 'skydive.prompt' then
            print(('  loop: skydive.prompt %s   calls %d   errors %d'):format(
                s.suspended and 'SUSPENDED -- re-enable with /brloop enable skydive.prompt'
                            or (s.enabled and 'running' or 'disabled'),
                s.calls, s.errors))
        end
    end
end, false)

--- The last match state this handler acted on. See the edge note below.
local lastMatchState = nil

-- A match ending mid-air (brforce, mass leave) must not leave the latch set.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        dropping = false
        -- THE THIRD ENDING, and it is the one that leaves state behind. A
        -- match killed mid-air (brforce, a mass leave) never reaches the
        -- landing branch, so nothing clears the trail flags -- and the drop
        -- machine can arm itself from the SERVER's opinion alone if the
        -- br:drop:begin handoff is ever missed, which is a path where
        -- applyTrail does not run and therefore does not reset them either.
        -- The two together are a descent prompting for a trail left over from
        -- a match that is already over.
        BR.Cosmetics.clearTrail()
    end

    -- THE LANDED LATCH BELONGS TO ONE DROP, and a new round is a new drop.
    -- Carrying it across would tell the next match's interface that a player
    -- still sitting in the plane had already touched down -- the mirror image
    -- of the bug it exists to fix, and the more embarrassing direction to be
    -- wrong in. WARMUP is where it is armed; leaving it set through the lobby
    -- costs nothing, since nothing reads it there.
    --
    -- ON THE EDGE, NOT ON EVERY MENTION, AND THAT IS THE SECOND HALF OF #126.
    --
    -- This read "the state IS bus", and the match is in BUS for the entire
    -- descent AND for the whole wait afterwards -- it does not reach PLAYING
    -- until the sky is empty. The state is also RE-BROADCAST while that wait
    -- runs: server/match.lua extends the flight in ten-second steps for anyone
    -- still under canopy and re-announces BUS each time. So every ten seconds,
    -- for as long as somebody else was still coming down, a player already
    -- standing in a POI had their own touchdown forgotten -- their HUD, their
    -- inventory bar and their crate prompts switched off again, inside the
    -- exact window this latch exists to cover. It is also the exact scenario
    -- the validation steps ask for: one player jumps immediately, the other
    -- rides to the end of the route.
    --
    -- ENTERING warmup or the bus un-lands you. Hearing again that you are on a
    -- bus you have already jumped out of does not.
    if (d.state == BR.MatchState.WARMUP or d.state == BR.MatchState.BUS)
       and d.state ~= lastMatchState then
        BR.State.landed = false
        landedThisDrop = false

        -- THE BROWSER IS WARMED HERE, LONG BEFORE ANYTHING NEEDS IT (#131).
        --
        -- A DUI is a whole CEF instance and IsDuiAvailable is false for a beat
        -- after CreateDui -- BR.Dui.drawScreen draws nothing until it is true.
        -- Creating the page lazily on the first frame of the fall would spend
        -- that beat during the freefall, which is where the glider prompt lives
        -- and is the one prompt in this file with a body count attached ("a dead
        -- key during a fatal fall is the worst possible failure mode, twice
        -- observed"). Built at warmup or at the doors instead, it has the whole
        -- pad or the whole flight to come up. BR.Dui.page memoises, so a second
        -- match reuses the first one's browser and this costs a table lookup.
        promptPage()
    end
    lastMatchState = d.state
end)

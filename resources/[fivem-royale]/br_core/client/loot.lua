-- World loot: props, glow, prompts and pickup.
--
-- EVERY OBJECT HERE IS LOCAL AND NON-NETWORKED. CreateObjectNoOffset with
-- isNetwork = false is the entire basis of the design -- a match lays out
-- ~1900 items, and 1900 networked entities would end the server before the
-- first circle closed. The consequence is that this file is presentation over
-- a server-owned registry: deleting a prop locally does not pick anything up,
-- and only LOOT_GONE removes an entry.
--
-- SUBSCRIPTION IS 3x3 CELLS (768m), PROPS ARE 90m. Those are deliberately
-- different numbers. The registry is cheap and wants to be ahead of the
-- player; objects are not, and want to exist only where they can be seen.
--
-- NOTHING IS HARDCODED TO A KEY. Pickup runs off BR.Keys ('interact'), which
-- is a RegisterKeyMapping binding the player can rebind in the pause menu, and
-- the prompt renders whatever they bound it to.

BR = BR or {}
BR.Loot = BR.Loot or {}

--- How many containers this player has opened THIS MATCH.
---
--- Drives the crate glow, which switches off once it reaches
--- BR.Config.Loot.shineOpenLimit: the shine is teaching "these boxes open",
--- and past that it is a permanent orange marker on scenery (user call,
--- 2026-08-06). Reset with the match, so every round starts by teaching it
--- again -- the next round may be somebody else's first.
BR.Loot.openedCount = 0

--- How many times the crate drag has actually scaled a velocity. Printed by
--- /brloot: it is the difference between "the drag is not running" and "the
--- drag is not strong enough", which cost a round of guessing to tell apart.
BR.Loot.dragTicks = 0

--- THE COLLISION WAIT, COUNTED, for the reason every other counter in this file
--- exists: a crate that came down inside a building is one symptom with three
--- possible causes, and from a chair they are identical.
---
--- Owner, 2026-08-23: the airdrop "falls through the top of the building as if
--- it doesn't have collisions" and the crate then "spawn[s] at ground level
--- inside a building".
---
---   waits 0            the wait never ran -- containers are not reaching it
---   waits n, loaded 0  the collision never arrives, and every crate is
---                      released on the budget exactly as it was before
---   reseated 0         collision arrives, but the ground never changes with it,
---                      so the roof was never the probe's answer either
---
--- Three different bugs, one picture, and this line is what chooses between them
--- without another match. Read by /brloot.
BR.Loot.settle = {
    waits    = 0,    -- containers held frozen while collision streamed
    loaded   = 0,    -- ...that got it inside the budget
    timedOut = 0,    -- ...that did not, and were released anyway
    reseated = 0,    -- ...whose ground moved once the collision was really there
    lastMs   = 0,    -- how long the last wait took
    maxMs    = 0,    -- the worst one this session
    lastLift = 0.0,  -- metres the last re-seat moved a crate, signed
}

--- THE ARRIVAL ARC, COUNTED AT EVERY LINK IN ITS OWN CHAIN.
---
--- The arc "from the crate's mouth to where it lands" was written, shipped, and
--- never once played -- for every container, all the way back to when it was
--- written -- and nothing anywhere said so. It is four things in a row (the
--- server sends an origin, the client keeps it, a prop gets built while the
--- window is still open, the animation moves it), any one of which failing
--- produces the exact same symptom: an item that pops into existence. That is
--- the shape of failure /brloot's drag counter was added for, and it has the
--- same answer -- count each link separately, so "it never ran" and "it ran and
--- looked wrong" cannot be confused, and so neither needs a playtest to settle.
---
--- Read by /brarc and summarised by /brloot.
BR.Loot.arc = {
    born    = 0,     -- entries that arrived carrying an origin
    armed   = 0,     -- ...whose prop was built while the window was still open
    late    = 0,     -- ...whose prop was built too late to fly (the old bug)
    flights = 0,     -- arcs that drew at least one frame
    frames  = 0,     -- arrival frames drawn, all arcs
    lastBuildMs = nil,  -- announce -> prop, last arrival seen
    lastFrames  = 0,    -- frames the last arc drew
    lastPeak    = 0.0,  -- metres above its resting height the last arc reached
}

local L = BR.Config.Loot

local entries   = {}      -- [id] = entry, with prop bookkeeping attached
local byObject  = {}      -- [objectHandle] = id, so a ray hit resolves instantly
local queue     = {}      -- ids waiting for a model
local queued    = {}      -- [id] = true, so the queue cannot double up

local draining  = false
local myCell    = nil     -- last cell reported to the server
local claimedAt = {}      -- [id] = gametimer, to stop a held key spamming claims
local reported  = {}      -- [id] = true, entries already sent back as misplaced

--- Where a container's prop ACTUALLY ended up, by entry id.
---
--- Kept outside `entries` on purpose: opening a crate mutates the entry in
--- place on the server (kind 'chest' -> 'husk') and the client replaces its
--- whole entry table with the new payload, so anything stored on the entry is
--- gone by the time the husk needs it. This survives that, and it is what lets
--- the open crate appear exactly where the sealed one was rather than back at
--- the position it was generated at, upright, having visibly teleported (user,
--- 2026-08-06).
---
--- { x, y, z, rx, ry, rz } -- a full pose, because a crate that has been shunted
--- or has settled on a slope has pitch and roll worth keeping too.
local poses = {}

--- The container hold in progress.
---
--- `heldMs` IS ACCUMULATED, NOT DERIVED FROM A START STAMP, and that is the
--- whole of #129. The old shape was `{ id, from }` with the completion test
--- `now - from >= chestHoldMs`, which asks "has enough wall-clock passed since
--- the key went down" -- a question a momentary press answers just as well as a
--- hold does. Nothing in that arithmetic requires the key to have been down for
--- any of the interval; it relied entirely on some OTHER piece of code
--- noticing the release and clearing `id` in time, and there were two of those,
--- both with gates on them (see loot.interact below, and the canTake() early
--- return in loot.render).
---
--- Milliseconds are added HERE, in the render pass, only on frames where the
--- key reads down. A hold that stops being held stops accumulating and is
--- dropped; a press that is never held accumulates one frame and dies. There is
--- no interval left for a tap to sit out. Same reasoning dbno.lua reached for
--- the revive after a brief tap completed a whole eight-second one in playtest
--- (owner, 2026-08-09): progress needs continuous evidence, not an announcement.
---
--- `upAt` is when the key was first seen UP with a hold running -- see
--- HOLD_RELEASE_MS below. It is the second round of #129: the accumulator was
--- right and it was hanging off a single per-frame boolean with no tolerance
--- for that boolean being momentarily wrong, which this project has already
--- documented that it is (keybinds.lua, the resync window and the note on
--- citizenfx/fivem#3064 beside it).
--- `frames` and `counted` are the DUTY CYCLE, and they are instrumentation
--- rather than mechanism -- nothing reads them but /brloot. They exist because
--- #129 has now cost six rounds and "the ring filled up" was taken as proof the
--- clock filled up. It is not. The ring is a CSS animation started ONCE with
--- `chestHoldMs` as its duration (br_ui/dui/prompt.html), so it fills over that
--- duration whatever the accumulator is doing, and it resets when the hold ends
--- because the next prompt carries no duration. A hold whose key reads down on
--- one frame in six therefore shows a ring that fills in a second and a clock
--- that needs six -- and until now nothing anywhere could tell those apart.
--- `counted/frames` can: 100% means the clock is running at wall-clock speed.
---
--- `aliveMs` IS NOT A START STAMP AND MUST NEVER BECOME ONE. It is accumulated
--- exactly like `heldMs`, from the same `dt`, on the same frames -- the only
--- difference is that it is added unconditionally while `heldMs` is gated on
--- `counting`. The pair is the whole instrument: `aliveMs` is how long this
--- hold has EXISTED, `heldMs` is how much of that it EARNED, and the gap
--- between them is the fault (see STARVE_RATIO below). Deriving `aliveMs` from
--- `GetGameTimer() - startedAt` would reintroduce the exact quantity #129's
--- first round shipped and the accumulator was written to delete, sitting in
--- the same table one field away from the completion test. It is not worth the
--- two operations it would save.
local hold = { id = nil, heldMs = 0.0, upAt = nil,
               frames = 0, counted = 0, aliveMs = 0.0, warnedAt = nil }

--- WHAT THE LAST HOLD ACTUALLY DID, kept after it ends so it can be read.
---
--- Deliberately outlives the hold: the player has to let go of the key to type
--- in the F8 console, so a readout that only describes a LIVE hold describes
--- nothing by the time anybody looks at it. { id, best, frames, counted, why }.
local lastHold = nil

--- Holds that actually crossed chestHoldMs, and claims that actually left.
---
--- TWO SEPARATE FACTS, WHICH IS THE WHOLE POINT (#129, sixth round). "The ring
--- filled", "the hold completed" and "the claim went out" are three different
--- things and only the first has ever been visible -- from the player's chair
--- they are the same silence. Counting the second and the third is what says
--- which half of the system to look at next.
local completions = 0
local claimsSent  = 0

--- The last LOOT_CLAIM this client sent, and whether the server ever acted.
---
--- `answeredAt` is set when the authoritative consequence comes back -- the
--- crate re-announced as its husk, or the entry retired for a loose item. A
--- claim with no answer means the message left here and the server either never
--- heard it or refused it silently, which is a different bug entirely from a
--- claim that was never sent.
--- @type table|nil  { id, at, kind, answeredAt }
local lastClaim = nil

--- Forget the hold in progress -- all its fields, in one call.
---
--- TEN places abandon a hold: an entry dying, every entry going away, the
--- downed-mate suppression rising, leaving the take states, walking out of
--- reach, the key going up, completing, starting a fresh one, retuning the
--- duration with /brcratehold, and the unconditional frame check. They wrote
--- the fields out by hand and had already drifted once over whether `heldMs`
--- travelled with `id` -- and a hold whose clock outlives its own cancellation
--- is precisely the shape of bug #129 is about. Adding `upAt` would have been a
--- third field for all ten of them to forget. One call instead.
---
--- `why` is recorded, not acted on. Every one of those ten sites is a different
--- answer to "why did the crate not open", and they are indistinguishable on
--- screen -- the ring goes out for all of them.
--- @param why string|nil
local function clearHold(why)
    if hold.id then
        lastHold = {
            id      = hold.id,
            best    = hold.heldMs,
            frames  = hold.frames,
            counted = hold.counted,
            aliveMs = hold.aliveMs,
            -- Carried into the post-mortem so the readout can say "this hold
            -- was starved" about a hold that has already ended -- which is the
            -- only kind anybody ever reads, because letting go of the key is
            -- what it takes to reach the F8 console.
            starved = hold.warnedAt ~= nil,
            why     = why or 'unrecorded',
            at      = GetGameTimer(),
        }
    end
    hold.id, hold.heldMs, hold.upAt = nil, 0.0, nil
    hold.frames, hold.counted = 0, 0
    hold.aliveMs, hold.warnedAt = 0.0, nil
end

--- Send a claim, and remember that we did.
---
--- ONE DOOR OUT, so "did the client ask" is answerable for both the crate hold
--- and the loose-item press without trusting two call sites to have been
--- counted the same way.
--- @param id integer
--- @param kind string  'crate' or 'item' -- which path asked
local function sendClaim(id, kind)
    claimsSent = claimsSent + 1
    lastClaim = { id = id, at = GetGameTimer(), kind = kind }
    TriggerServerEvent(BR.Net.LOOT_CLAIM, { id = id })
end

--- The server did the thing a claim asked for. Called from the wire handlers.
--- @param id integer
local function noteClaimAnswered(id)
    if lastClaim and lastClaim.id == id and not lastClaim.answeredAt then
        lastClaim.answeredAt = GetGameTimer()
    end
end

--- HOW LONG THE KEY MUST READ UP BEFORE A HOLD IN PROGRESS IS ABANDONED.
---
--- A HOLD MUST NOT BE KILLED BY A KEY STATE THAT WAS NEVER RELEASED, which is
--- the mirror image of the tap guard in keybinds.lua (the resync window, which
--- replaced an earlier rawUpAt/TAP_REARM_MS pair) and rests on the same
--- measured fact: taking or releasing NUI
--- focus disturbs the key state the raw natives read -- citizenfx/fivem#3064
--- names IS_RAW_KEY_DOWN specifically -- so a key that is still physically held
--- reads UP for a frame or two around every focus change. A dropped frame used
--- to cost nothing here, because completion was `now - from >= chestHoldMs` and
--- did not care what the key had been doing. Since the clock became an
--- accumulator that is cancelled outright on the first frame the key reads up,
--- one bad frame throws the whole hold away and the player sees a ring that
--- refuses to fill.
---
--- THE INVARIANT THAT MAKES THIS SAFE, AND IT IS THE ONE TO CHECK BEFORE
--- CHANGING THE NUMBER: this grace extends only the LIFETIME of a hold, never
--- its PROGRESS. Milliseconds are still added exclusively on frames the key
--- reads down. A tap therefore banks one frame -- about 16ms of the 1000 it
--- needs -- and is then discarded when the grace expires, so it is still
--- structurally impossible for a press to open a crate. That distinction is
--- what dbno.lua's scar is about: a brief tap completed an entire eight-second
--- revive in playtest (owner, 2026-08-09) because progress was granted by an
--- announcement rather than by evidence.
---
--- 120ms because the gaps this has to swallow are one or two frames -- 100ms
--- even on a client running at 20fps -- and because the cost of being wrong is
--- a ring that lingers for a tenth of a second after a real release, which is
--- below what reads as lag. Deliberately short, for the same reason the tap
--- side stopped using a duration at all: a tap re-arming late costs nothing,
--- while a ring outstaying its key is visible on screen.
local HOLD_RELEASE_MS = 120

--- How many times a rising edge has landed on a hold that was already running.
---
--- NOT PART OF `hold`, AND DELIBERATELY NOT CLEARED BY clearHold(): it counts
--- for the whole session, because what it measures is how often this client's
--- key state drops a frame -- which is a property of the machine, not of any
--- one crate. /brloot prints it.
---
--- It exists because #129 has now cost four rounds, and the difference between
--- "this client never sees a dropped frame" and "it sees one every 300ms" was
--- not observable from anywhere. If a crate still refuses to open and this
--- reads 0, the dropped-frame path is not what is happening and the next person
--- should look elsewhere rather than at this file.
local holdResumes = 0

-- ---------------------------------------------------------------------------
-- A HOLD THAT CANNOT COMPLETE AND CANNOT VISIBLY FAIL (#129, seventh round)
--
-- The release grace and the resume absorb a key state that drops a frame. What
-- they do NOT distinguish is a key state that is wrong on EVERY frame -- and
-- that combination is silent by construction:
--
--   * the hold never completes, because milliseconds are earned only on frames
--     the key reads down and none of them do;
--   * the hold never dies, because every frame re-stamps the release grace, so
--     `alive` is true forever;
--   * the ring fills anyway, because it is a CSS animation started once with
--     `chestHoldMs` as its duration (br_ui/dui/prompt.html).
--
-- So the player holds the key, watches a full orange ring, and the crate does
-- not open -- for as long as they care to stand there. That is the state the
-- owner pasted: 446 frames alive, 0 of 1000ms earned, 0%, and a readout that
-- reported it as "the key was released". Nothing anywhere said "this hold is
-- not progressing", so five rounds were spent arguing about which key layer was
-- at fault while the readout sat at 0/1000ms and volunteered nothing.
--
-- The mechanism was fixed in keybinds.lua. This is the alarm that makes the
-- NEXT one of these audible on the first playtest instead of the sixth: a hold
-- that has existed for longer than it needed and earned less than half of it is
-- not slow, it is broken, and it says so.
-- ---------------------------------------------------------------------------

--- How much of its own lifetime a hold must EARN before it is called healthy.
---
--- Half, and the margin either side is wide on purpose. A healthy client earns
--- 100%; the worst tolerated real fault -- a key state that drops one frame in
--- twenty around NUI focus changes (citizenfx/fivem#3064) -- earns 95% and
--- completes 50ms late. A hold that has been alive for a full `chestHoldMs`
--- with less than half of it banked is not going to finish in any time the
--- player will wait: at 49% it needs another full second, and the reported
--- cases were at 0% and 17%. Nothing sits near the line.
local STARVE_RATIO = 0.5

--- Holds that outlived their own duration without earning half of it.
---
--- SESSION-WIDE AND NOT CLEARED BY clearHold(), for the same reason
--- holdResumes is not: what it measures is a property of this client's key
--- state, not of any one crate. /brloot prints it, and a non-zero value there
--- is the single line that says "stop looking at the loot code".
local starvedHolds = 0

--- How often the console warning may repeat while one hold stays starved.
---
--- The first one is what matters -- it lands in F8 with the numbers in it. The
--- repeat exists because a player who is holding a key and watching nothing
--- happen is not reading the console at that moment, and 2s is slow enough that
--- a stuck hold produces a readable trickle rather than a 60Hz wall.
local STARVE_WARN_MS = 2000

--- Is a hold in progress still being held, and should this frame count?
---
--- ONE ANSWER, ASKED BY BOTH FRAME CHECKS. loot.render advances the clock and
--- loot.interact is the unconditional net under it; when they asked the key
--- separately, the net cancelled on the same bad frame the grace above exists
--- to absorb, and the grace would have been decorative.
--- @param now number
--- @return boolean alive     the hold survives this frame
--- @return boolean counting  ...and this frame earns credit
local function holdKeyAlive(now)
    if BR.Keys.isHeld('interact') then
        hold.upAt = nil
        return true, true
    end
    if not hold.upAt then hold.upAt = now end
    return (now - hold.upAt) < HOLD_RELEASE_MS, false
end

--- THE ONE ENTRY THE PLAYER IS BEING OFFERED THIS FRAME, decided once in
--- loot.render and read by everything else.
---
--- ONE TARGET, ONE PROMPT, ONE CLAIM (#128). The prompt and the pickup used to
--- resolve their target INDEPENDENTLY -- the render pass called targetEntry()
--- to decide what to draw, and the keypress handler called it again to decide
--- what to take. Two calls, two answers: targetEntry mixed a 5.0m ray-cast with
--- a 3.5m proximity fallback, so with two items in front of the player the
--- answer flipped between them as the crosshair drifted a few pixels. The
--- player pressed while looking at one prompt and took the other, and both
--- items stayed live the whole time -- "we're able to accidentally pick up 2
--- loot items if we're facing both of them" (owner, 2026-08-16).
---
--- Resolving it once and remembering it makes the drawn prompt and the claimed
--- item the same object by construction rather than by two functions agreeing.
--- It is a frame stale by the time the key is read, which is the correct
--- staleness: what the player pressed on is what was on their screen.
local target = nil

local lastPrompt = { id = nil, hold = nil }

-- REBINDING A KEY HAS TO REDRAW THE PROMPT THAT NAMES IT.
--
-- The payload is only rebuilt when the target entry (or its hold time)
-- changes, which is right for the sixty frames a second nothing happens in --
-- and wrong for the one moment a player rebinds interact while standing in
-- front of a crate: the prompt kept saying the old key until they walked away
-- and back (user, 2026-08-09). Forgetting the cached id is enough; the next
-- frame rebuilds it with the new label.
AddEventHandler('br:keys:changed', function()
    lastPrompt.id, lastPrompt.hold = nil, nil
end)

-- Which crate is currently the one that shines, and when that was last
-- decided. Held across frames so the search does not have to run in every one.
local shineId = nil
local shineAt = 0

--- Props that are no longer loot, only scenery on its way out.
---
--- THE ENTRY DIES THE INSTANT THE SERVER CONFIRMS THE CLAIM. That is the whole
--- design, and it is the user's (2026-08-08): the moment an item is taken it
--- stops being targetable, stops prompting and leaves the registry -- so
--- nothing that follows can be interacted with, mistargeted, or double-claimed.
--- What is left is a prop with no function, and a prop with no function is
--- free to be animated however it likes.
---
--- Which sidesteps the trap in doing this the other way round: keeping the
--- entry alive for the length of the animation would mean a window in which
--- the player can still see a prompt for something that is already in their
--- inventory.
---
--- Swept by forgetAll() and onResourceStop like everything else that holds an
--- object handle -- an undeleted local object outlives the resource.
--- @type table<integer, table>
local retiring = {}
local retireSeq = 0

--- Until when the spawn worker may build props faster than its steady rate.
---
--- RE-AIMED AT THE TOUCHDOWN ITSELF (#126). It used to be armed on the FIRST
--- CELL SUBSCRIPTION of a life, on the stated grounds that the first
--- subscription is the landing. It is not, and has never been: a player is
--- allowed to see loot from the warmup pad, from the bus and all the way down
--- (BR.Config.LootVisibleStates), so the first subscription happens on the pad,
--- minutes before anybody drops. Its four-second budget therefore expired
--- during warmup and the drop -- the one moment it was written for -- got the
--- ordinary two-per-pass trickle. It was spending its stutter risk on the pad
--- and delivering nothing at the POI.
---
--- Kept rather than deleted, because the thing it was written for is real and
--- still unfixed: two props per pass across 50-150 streamed entries is several
--- seconds of a POI that looks empty to a player who has just landed and has
--- nothing else to do but look at it (user, 2026-08-08). Now it is armed off
--- the same touchdown latch everything else in #126 hangs on, which is the
--- moment the trickle is actually wrong.
local burstUntil = 0

--- Whether the touchdown burst has already been spent this life. Edge-detected
--- rather than level-tested: BR.State.landed stays true for the whole match, and
--- re-arming a four-second budget on every 10Hz tick would make the burst rate
--- the permanent rate.
local burstArmed = false

--- The entry whose prop currently has SetEntityDrawOutline switched on.
---
--- TRACKED SEPARATELY FROM shineId, and that is the whole fix for crates that
--- glowed orange forever (user, 2026-08-08: "unopened chests still glow after
--- they've opened a couple"). Turning the outline OFF used to live inside the
--- render loop's per-entry branch, which is guarded by `d2 <= glow2 and not
--- isHusk(e) and e.gzOk`. Every one of those guards is a way to leave a lit
--- crate lit:
---
---   * WALK AWAY fast enough and the entry falls outside glow2 on the very
---     next pass, so the branch that would clear it never runs again;
---   * OPEN IT and it becomes a husk, which the branch skips by design --
---     so the crate you just emptied keeps shining;
---   * open two and shineId goes nil for the rest of the match, which stops
---     anything NEW lighting up but never revisits what already is.
---
--- The leak accumulates: every crate ever approached and left stays orange,
--- which is exactly "they all glow and opening them does not stop it". One
--- id, cleared unconditionally, cannot accumulate.
local outlinedId = nil

--- Switch the outline off wherever it currently is.
--- @param entriesTbl table
local function clearOutline(entriesTbl)
    if not outlinedId then return end
    local e = entriesTbl[outlinedId]
    outlinedId = nil
    if e and e.obj and DoesEntityExist(e.obj) then
        SetEntityDrawOutline(e.obj, false)
    end
end

-- Crates THIS player opened. The reveal sound is for the person who did the
-- opening, not for everyone standing near it (user, 2026-08-05) -- and the
-- authoritative "it opened" signal arrives for every subscriber alike, so the
-- distinction has to be remembered locally.
local claimedByMe = {}

local PROP_MAX = 160      -- hard ceiling on live objects, whatever the density

-- The crate pair, kept streamed for the whole session: they are the
-- most-spawned models in the game and the sealed->open swap must be instant.
local CRATE_MODEL      = GetHashKey(L.chestProp)
local CRATE_OPEN_MODEL = GetHashKey(L.chestOpenProp)

Citizen.CreateThread(function()
    for _, model in ipairs({ CRATE_MODEL, CRATE_OPEN_MODEL }) do
        RequestModel(model)
        local waited = 0
        while not HasModelLoaded(model) and waited < 10000 do
            Citizen.Wait(100)
            waited = waited + 100
        end
    end
end)

--- Both gates come from br_lib, because the server reads the SAME tables.
--- When these were written out twice they drifted, and the symptom was no
--- loot anywhere with no error to grep for -- see the note on
--- BR.Config.LootVisibleStates.
local function canSee()
    return BR.Config.LootVisibleStates[BR.State.me.state] == true
end

-- SOMETHING ELSE HAS THE INTERACT KEY RIGHT NOW.
--
-- There is one interact key and, since M7, two things that want it: a crate on
-- the floor and a squadmate on the floor. They cannot both prompt, and picking
-- up a rifle instead of picking up a person is the wrong way round to be wrong.
--
-- A yield rather than a shared interaction registry, deliberately. The registry
-- is the tidier end state and is the right move the day a THIRD consumer shows
-- up; today it means restructuring the hottest frame pass in the client to
-- serve one caller, and this pass has cost two playtests already.
local suppressed = false

--- Stand down: no prompt, no hold, no claim. Raised by client/dbno.lua while a
--- downed squadmate is within reach.
--- @param on boolean
function BR.Loot.suppress(on)
    on = on == true
    if on == suppressed then return end
    suppressed = on
    -- Drop any hold in progress, and the offer with it. Walking up to a downed
    -- mate mid-crate must not leave a timer running behind the revive prompt --
    -- nor a remembered target that the next keypress would claim instead of
    -- starting the revive.
    if on then clearHold('a downed squadmate took the interact key'); target = nil end
end

--- ...AND A LANDED PLAYER MAY REACH FOR THINGS, before the server has caught up.
---
--- The take gate is shared with the server (BR.Config.LootTakeStates) and the
--- server's copy is still the security boundary -- nothing here can claim
--- anything it refuses. What this adds is the few tens of milliseconds between
--- our own ped touching down and the landing report completing its round trip,
--- during which the prompt used to be absent entirely: a player standing in
--- front of a crate with no way to know it could be opened (#126).
---
--- The honest cost, stated rather than hidden: a claim made inside that window
--- can be refused, and the player is TOLD so ("You cannot pick that up right
--- now", server/loot.lua). One clear message beats a prompt that never appears
--- -- and it beats it by a distance in the failure case, where the report goes
--- missing entirely and the old behaviour was several silent seconds of a world
--- that looked empty.
local function canTake()
    if suppressed then return false end
    -- ...AND NOT FROM THE STRETCHER OF AN AMBULANCE.
    --
    -- A player healing in the back of a van (client/ambheal.lua) is ALIVE and
    -- ATTACHED rather than seated, so every test in this function passes for
    -- them -- including the vehicle test one line below, because
    -- IsPedInAnyVehicle answers false for an attached ped. Left alone, a crate
    -- lying on the tarmac behind the ambulance would prompt at somebody lying on
    -- a stretcher, and the interact key that is supposed to be their ONLY way
    -- out (the owner, 2026-08-28) would open it instead.
    --
    -- A NIL-GUARDED READER, which is the shape four files already use for
    -- BR.Rescue.riding(). It is not BR.Loot.suppress, deliberately: that is a
    -- single boolean latch that client/dbno.lua writes every frame, so a second
    -- writer would spend the match undoing the first.
    if BR.AmbHeal and BR.AmbHeal.healing and BR.AmbHeal.healing() then
        return false
    end
    if BR.Config.LootTakeStates[BR.State.me.state] ~= true
       and BR.State.landed ~= true then
        return false
    end
    -- NOT FROM A CAR (user call, 2026-08-05). Driving through a POI hoovering
    -- up crates at 40mph is not looting, and the ray comes off the ped's
    -- forward vector, which in a vehicle is the vehicle's.
    return not IsPedInAnyVehicle(PlayerPedId(), false)
end

local function isContainer(e)
    return e.kind == 'chest' or e.kind == 'deathbox'
end

--- An already-opened crate. Scenery: no glow, no label, no prompt, and the
--- server refuses to claim it. It exists so a room you have already swept
--- reads as swept from the doorway.
local function isHusk(e)
    return e.kind == 'husk'
end

--- How far away this entry can still be interacted with, in metres.
---
--- ONE ANSWER, ASKED BY BOTH THE OFFER AND THE HOLD, because they used to
--- disagree and the disagreement was reachable: the old targetEntry let a
--- ray-cast prompt a crate out to pickupDistance + 1.5, while the hold loop
--- cancelled anything past pickupDistance. A crate prompted at four metres
--- therefore said "hold to open" and then dropped the hold on the first frame,
--- every time, with nothing on screen to explain why.
---
--- Containers keep the longer reach the ray happened to give them. That is not
--- generosity: a crate is a metre-wide box and the registry position is its
--- CENTRE, so a player standing at its face is already the better part of a
--- metre further away than the number suggests. The server allows
--- pickupDistance + 4.0 (server/loot.lua inReach), so both of these sit well
--- inside what it will accept.
--- @param e table
--- @return number
local function reachOf(e)
    local d = L.pickupDistance or 3.5
    if isContainer(e) then return d + 1.5 end
    return d
end

--- The pitch an item RESTS at, in degrees.
---
--- Only long things lie down. A rifle standing on end sinks into the terrain
--- however carefully its centre is placed; lying flat it sits on it. An ammo
--- box or a medkit is a box -- it spawns the right way up, and tipping it onto
--- its side is worse rather than better (user, 2026-08-08).
--- @param e table
--- @return number
local function restPitchOf(e)
    if e.kind == BR.ItemKind.WEAPON then return L.restPitch or 90.0 end
    return L.hoverPitch or 0.0
end

--- How big this entry's prop should be drawn, as a multiplier of its authored
--- size. nil means "as authored" and costs nothing.
---
--- READ FROM THE CONFIG, NOT FROM THE WIRE, which is the same call modelOf
--- makes about the model itself: the scale is a property of the ITEM, the
--- client already has the item id, and br_lib/config/loot.lua is shared -- so
--- putting it in wireEntry would grow every loot payload on the server to
--- re-send something both ends already know.
--- THE THREE AIRDROP SIZES ARE KEYED OFF THE ITEM ID, which is why the airdrop
--- gives its crate and its husk ids of their own ('airdrop', 'airdrophusk')
--- rather than reusing 'chest' and 'husk' like the 1300 generated ones. An id
--- is already on the wire, the client already has the config, and keying off
--- anything else would mean growing every loot payload to re-send a number both
--- ends know (owner, 2026-08-22: crate and husk 2x, Volts 5x).
---
--- Built once at load rather than branched per call: this runs at spawn for
--- every entry and, for a scaled one, ten times a second afterwards.
--- @param item string
--- @return number|nil
local function airdropScale(item)
    local A = BR.Config.Airdrop
    if not A then return nil end
    if item == 'volts'       then return A.voltsScale end
    if item == 'airdrop'     then return A.crateScale end
    if item == 'airdrophusk' then return A.huskScale end
    return nil
end

--- @param e table
--- @return number|nil
local function propScaleOf(e)
    if e.kind == BR.ItemKind.CONSUMABLE then
        local c = BR.Config.ConsumableById[e.item]
        return c and c.propScale or nil
    end
    return airdropScale(e.item)
end

--- Draw a prop at a multiple of its authored size (#166).
---
--- MOVED TO BR.Native.propScale (client/natives.lua) on 2026-08-22, WITHOUT a
--- copy left behind. The airdrop's falling crate and canopy have to be drawn at
--- the same size as the landed ones (owner: "The parachute and crate props
--- (including husk) should be 2x larger") and those are built by
--- client/airdrop.lua, not here -- so the choice was one shared function or two
--- matrix routines that agree until the day one of them is edited. Bound to a
--- local so this file's hot passes still pay one upvalue read, exactly as they
--- did when the body was here.
local applyPropScale = BR.Native.propScale

-- --------------------------------------------------------------------------
-- Models
-- --------------------------------------------------------------------------

--- The model an entry should be drawn as.
---
--- Weapons resolve through GET_WEAPONTYPE_MODEL rather than an authored prop
--- name per weapon: 35 hand-typed model names is 35 chances to ship an
--- invisible rifle, and the engine already knows the answer.
--- @param e table
--- @return integer|nil
local function modelOf(e)
    if e.kind == BR.ItemKind.WEAPON or e.kind == BR.ItemKind.THROWABLE then
        local w = BR.Config.WeaponById[e.item]
        return w and GetWeapontypeModel(w.hash) or nil
    end
    if e.prop then return GetHashKey(e.prop) end
    if e.kind == BR.ItemKind.AMMO then
        local a = BR.Config.AmmoPickups[e.item]
        return a and GetHashKey(a.prop) or nil
    end
    if e.kind == BR.ItemKind.CONSUMABLE then
        local c = BR.Config.ConsumableById[e.item]
        return c and GetHashKey(c.prop) or nil
    end
    return nil
end

--- How far below where it settled this entry's prop should rest, in metres.
---
--- ═══ "THE PROP PICKUP SHOULD BE LOWERED BY MAYBE 0.5M" (owner, 2026-08-30,
---     #240) ═══
---
--- "At rest, the vehicle pickup props are floating above the ground at
--- waist-level." PlaceObjectOnGroundProperly settles the prop at its AUTHORED
--- size and the matrix scale is applied afterwards (see the spawn pass, where
--- the ordering is load-bearing for a different reason), so a car drawn at
--- 0.375 keeps the origin height a full-size car was given and hangs there.
---
--- HE ASKED FOR A NUMBER RATHER THAN A DERIVATION and he is right to: the
--- arithmetic would need the model's own box and the pose it settled in, and
--- 0.5m by eye is a knob he can turn in one line after seeing it.
---
--- NIL FOR EVERYTHING ELSE, AND THAT IS THE ENTIRE REASON THIS IS PER-ITEM. The
--- same settle puts about 1300 rifles, bandages and ammo boxes on the ground
--- across the map. None of those is floating and none of them is scaled down far
--- enough to; a global drop would bury every one of them.
--- @param e table
--- @return number
local function propDropOf(e)
    local c = (e.kind == BR.ItemKind.CONSUMABLE)
        and BR.Config.ConsumableById[e.item] or nil
    local d = c and tonumber(c.propDrop) or nil
    if not d or d <= 0.0 then return 0.0 end
    return d
end

--- The marker an entry falls back to when its prop cannot be built (#224).
---
--- ═══ THIS EXISTS BECAUSE A VEHICLE IS NOT AN OBJECT, PROBABLY ═══
---
--- The warmup shop's item is a car, and the owner asked for its dropped token to
--- be "that vehicle but as a prop and super small, like the same size as a
--- weapon prop pickup. If that's not possible, use marker ID 34 instead."
---
--- WHETHER IT IS POSSIBLE IS NOT ESTABLISHED ANYWHERE IN THIS TREE.
--- CreateObjectNoOffset takes an OBJECT archetype and a car is a VEHICLE
--- archetype, so the likely answer is that it refuses -- but "likely" is not a
--- thing to hardcode either way, and this project has been wrong twice about
--- what a published native reference says versus what this build does.
---
--- SO IT IS NOT DECIDED HERE. The spawn pass below asks for the car as a prop
--- like any other item; if the engine will not build it, the entry is marked and
--- the render pass draws this marker in place of the rarity disc. The answer
--- arrives from the running game, once, on the console, and the owner's stated
--- fallback is what happens meanwhile.
---
--- NIL FOR EVERYTHING ELSE. A bandage whose prop failed to build is a bug and
--- should look like the missing thing it is, not like a car token.
--- @param e table
--- @return integer|nil
local function fallbackMarkerOf(e)
    if e.kind ~= BR.ItemKind.CONSUMABLE then return nil end
    local c = BR.Config.ConsumableById[e.item]
    return c and tonumber(c.fallbackMarker) or nil
end

--- How big that fallback marker is drawn, as a radius in metres.
---
--- ═══ A DIFFERENT KNOB FROM `propScale`, IN DIFFERENT UNITS ═══
---
--- `propScale` is a MULTIPLE OF THE MODEL'S OWN SIZE and only ever reaches an
--- entry whose prop the engine actually built. This is METRES and is what gets
--- drawn when it did not, so the two can never be the same number and turning
--- one does nothing to the other.
---
--- IT WAS A LITERAL 0.5 UNTIL 2026-08-29 and the value has not changed; it is
--- named now because the owner asked for a bigger dropped token and it is not
--- yet established which of the two knobs his cars are actually using -- see
--- BR.Config.Shop.tokenMarkerScale, which explains how to tell from the console.
--- @param e table
--- @return number
local function fallbackMarkerScaleOf(e)
    local c = (e.kind == BR.ItemKind.CONSUMABLE)
        and BR.Config.ConsumableById[e.item] or nil
    local k = c and tonumber(c.fallbackMarkerScale) or nil
    if not k or k <= 0.0 then return 0.5 end
    return k
end

--- Mark an entry as having no prop, and say so ONCE.
---
--- ONCE PER ENTRY, because the spawn pass revisits an entry every time it
--- streams back in and a line per pass is a console nobody can read. `noProp` is
--- the latch and the render pass reads it.
--- @param e table
--- @param why string
local function noProp(e, why)
    if e.noProp then return end
    e.noProp = true
    print(('[br_core] loot: no prop for %s (%s)%s')
        :format(tostring(e.item), why,
                fallbackMarkerOf(e)
                    and (' -- falling back to marker %d'):format(fallbackMarkerOf(e))
                    or ''))
end

--- What this entry is called, for the label and the prompt.
--- @param e table
--- @return string
local function labelOf(e)
    if e.kind == 'chest' then return 'Chest' end
    if e.kind == 'deathbox' then return 'Loot Box' end
    local name = BR.LootLabel({ kind = e.kind, item = e.item, count = e.count })
    -- 'volts' HAS ALREADY SPENT ITS COUNT ON THE NAME. Every other kind counts
    -- objects -- three bandages, thirty rounds -- so "x30" reads. A Volts pile
    -- counts currency, and BR.LootLabel has already put the number in front of
    -- it, so a suffix here would produce "100 Volts x100".
    if e.kind ~= 'volts' and (e.count or 1) > 1 then
        return ('%s x%d'):format(name, e.count)
    end
    return name
end

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. Six shipped bugs on this project, and solidGround below carries
--- the write-up of the sixth. Written out inline there rather than routed
--- through here, deliberately -- the comment on that line is the record of what
--- it cost, and it is worth more than the deduplication.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

--- Hold a solid prop still until the map's collision underneath it exists.
---
--- ═══ WHY A CRATE ENDS UP INSIDE A BUILDING ═══
---
--- Owner, 2026-08-23: "when it lands on top of a building the loot crate falls
--- through the top of the building as if it doesn't have collisions. This leads
--- to (when the chute is removed) the actual crate prop spawning at ground level
--- inside a building."
---
--- A CONTAINER IS THE ONLY PROP THIS FILE HANDS TO PHYSICS. Loose items are
--- frozen; a crate is created dynamic, unfrozen, gravity-bound and then
--- ActivatePhysics'd, because "drive into one and it moves" (user, 2026-08-05).
--- An unfrozen object with gravity falls until it hits COLLISION THAT HAS
--- STREAMED IN -- and map collision streams asynchronously and separately from
--- everything else. Create a crate a third of a metre above a roof whose
--- collision has not arrived yet and it falls straight through it, comes to rest
--- on the terrain, and stays there: the 10Hz crate pass records that sunken pose
--- into `poses`, and the husk inherits it when somebody opens the box. Nothing
--- puts it back afterwards, because by then it is simply where it is.
---
--- THE FIX IS THE ONE THE TELEPORT PATH ALREADY USES. client/debug.lua's
--- br:debug:teleport calls RequestCollisionAtCoord before it moves a player,
--- with a comment saying that skipping it "drops the player through the map into
--- the water". Same native, same failure, same answer -- a crate is just a
--- player that cannot swim.
---
--- FROZEN FIRST, BECAUSE THIS YIELDS. Everything else in the spawn worker
--- happens inside one frame, so an object created dynamic never gets a
--- simulation step before it is configured. This function waits, which means the
--- physics DOES get to step -- and a crate that fell through the roof during its
--- own collision wait would be a very funny bug to have written here.
---
--- BOUNDED, AND THE WORST CASE IS TODAY'S BEHAVIOUR. When the budget runs out
--- the caller unfreezes anyway: a crate that behaves exactly as it did before
--- this function existed beats a crate frozen in mid-air forever because a
--- streaming request never completed.
---
--- HasCollisionLoadedAroundEntity IS ABOUT THE ENTITY, WHICH IS WHY THE OBJECT
--- IS CREATED FIRST. There is no coord-taking form of that question, and polling
--- GetGroundZFor_3dCoord instead cannot answer it: terrain streams first and
--- answers `true` on its own, so the probe says yes about the street while the
--- building is still missing -- which is the exact state this guards against.
--- @param obj integer
--- @param x number
--- @param y number
--- @param z number
--- @return boolean loaded
--- @return number waited  milliseconds spent
local function awaitCollision(obj, x, y, z)
    FreezeEntityPosition(obj, true)
    RequestCollisionAtCoord(x, y, z)

    local budget = L.collisionWaitMs or 1500
    local waited = 0
    local S = BR.Loot.settle
    S.waits = S.waits + 1
    -- RECORDED ON EVERY EXIT, INCLUDING THE EARLY ONES. A receipt that is only
    -- written on the happy path is a receipt that says nothing about the case
    -- anybody would be reading it for.
    local function done(loaded)
        S.lastMs = waited
        if waited > S.maxMs then S.maxMs = waited end
        if loaded then S.loaded = S.loaded + 1
        else S.timedOut = S.timedOut + 1 end
        return loaded, waited
    end
    -- 0 IS TRUTHY IN LUA AND THIS NATIVE IS DECLARED BOOL. `if
    -- HasCollisionLoadedAroundEntity(e) then` is TRUE for a native that said no
    -- with a zero, which would make the whole wait a no-op that looks like it
    -- ran.
    while not isTrue(HasCollisionLoadedAroundEntity(obj)) do
        if waited >= budget then return done(false) end
        Citizen.Wait(50)
        waited = waited + 50
        -- The entry can be claimed, or stream out, while we wait.
        if not DoesEntityExist(obj) then return done(false) end
        RequestCollisionAtCoord(x, y, z)
    end
    return done(true)
end

--- WHERE A GROUND PROBE STARTS ITS SEARCH DOWNWARD, absolute z.
---
--- ═══ "HILLSIDE LOOT JUST SPAWNED BELOW THE MAP INSTEAD, NEVER REACHING THE
---     SURFACE OR ANYTHING" (owner, 2026-08-23) ═══
---
--- GetGroundZFor_3dCoord answers with the highest ground BELOW the point it is
--- given, so a probe started under the surface can only answer with something
--- lower or with nothing at all. Both callers below started at
--- `max(e.z + 50, 300)`, and BOTH HALVES OF THAT ARE TOO LOW ON A HILLSIDE:
---
---   * `e.z` IS NOT A MEASUREMENT. Scattered POI loot inherits its POI's centre
---     z verbatim (BR.GenerateLoot writes `s.z = poi.z` for every item in the
---     disc), and config/map.lua's own header says those coordinates "were
---     authored from map knowledge, not surveyed in-game". 121 of the 128 POIs
---     are authored low enough that `e.z + 50` never even reached the 300 floor.
---   * AND ROADSIDE FILLER HAS NO z AT ALL. The generator writes `s.z = 0.0` for
---     every filler item, so 300 was the only thing deciding for all of them.
---
--- 300 IS NOT HIGH ON THIS MAP, and config/map.lua proves it in its own words:
--- the battle bus's northern legs carry hand-written z values of 598 and 892
--- with the note that they "overfly the Chiliad massif, and the default cruise
--- altitude is inside the rock". The massif has five POIs on it -- chiliad 780,
--- chiliad_ridge 400, chiliad_n 320, chiliad_trail 250, chiliad_e 160 -- and
--- every one of them but the summit scattered its loot with a probe starting at
--- 300-450, into ground the same file says goes to 892.
---
--- So on high ground the probe was fired from inside the hill, and it could only
--- answer with something below the surface or with nothing. Where it found a
--- lower surface the item was built there, frozen, and its resting height
--- captured once -- nothing re-probes afterwards, so it stays under the map for
--- the rest of the match. Where it found nothing the item was never built at
--- all, which is the same bug wearing the other symptom.
---
--- ═══ AND 835254d's COLLISION WAIT IS NOT THE FIX FOR THIS ═══
---
--- That commit is about the crate: a container is the one prop here handed to
--- the physics simulation, and it fell through roofs whose collision had not
--- streamed. Loose loot takes a different path on purpose -- collision off,
--- FreezeEntityPosition true, never dynamic -- so gravity never touches it and
--- there is nothing for a collision wait to prevent. Its height is the probe
--- plus `restLift`, settled by PlaceObjectOnGroundProperly, and the probe is
--- what was wrong.
---
--- 1200 IS ABOVE EVERY PIECE OF GROUND ON THIS MAP, so the answer is the surface
--- everywhere. It changes nothing at street level: between 300 and 1200 there is
--- no geometry over any city block, so the highest ground below either start
--- point is the same surface. The same number, for the same reason, is
--- BR.Config.Airdrop.planeProbeFromZ.
local PROBE_FROM_Z = 1200.0

--- Is a point dry land with something solid under it?
---
--- DECLARED BEFORE groundZ ON PURPOSE. A `local function` referenced above its
--- own declaration resolves as a GLOBAL, which is nil -- and a nil call inside
--- a loop callback gets that callback suspended after five errors, which is
--- exactly how every crate on the map disappeared once already.
--- @param x number
--- @param y number
--- @param fromZ number
--- @return boolean okay
--- @return number groundZ
local function solidGround(x, y, fromZ)
    local ok, gz = GetGroundZFor_3dCoord(x, y, fromZ, false)
    -- IN LUA 0 IS TRUTHY AND A FIVEM BOOL NATIVE MAY ANSWER 1 RATHER THAN true,
    -- so `not ok` is FALSE for a native that failed with a zero. This project
    -- has shipped that bug five times and this line was the sixth waiting to
    -- happen: it has been survivable only because a failed probe also hands
    -- back z = 0, which the sea-level rule below catches. That is a guard
    -- working by accident, and the rooftop check now reads `gz` before it.
    if ok == nil or ok == false or ok == 0 then return false, 0.0 end

    -- SEA LEVEL IS ZERO, and that is the check that actually works.
    --
    -- GetWaterHeight answers for water VOLUMES the engine has streamed, so
    -- over open ocean -- far from anything, which is exactly where stray loot
    -- ends up -- it frequently returns nothing at all, and the probe below it
    -- happily returns the seabed. Loot kept appearing to float (user,
    -- 2026-08-06). A ground probe that lands at or below zero in this map is
    -- a seabed, full stop; the volume check stays for inland lakes, which sit
    -- well above zero and which the height rule cannot see.
    if gz <= 0.0 then return false, gz end

    -- Same normalisation, same reason: `okW` is a native BOOL and a zero from
    -- it must read as "no answer", not as "yes".
    local okW, wz = GetWaterHeight(x, y, gz)
    local haveW = okW ~= nil and okW ~= false and okW ~= 0
    if haveW and wz and wz > gz + 0.3 then return false, gz end
    return true, gz
end

--- Does this entry have to land somewhere a PED could be, and not merely
--- somewhere dry?
---
--- ═══ EXACTLY ONE ENTRY IN THE MATCH, AND THE NARROWNESS IS THE POINT ═══
---
--- The owner's report is about airdrops (2026-08-22: "Somehow these airdrops can
--- happen on top of buildings where peds otherwise cannot access"), and the
--- rooftop check behind this is a navmesh query whose behaviour NOTHING outside
--- a running client has confirmed. Applying it to all ~3200 generated entries
--- would put every item on the map behind an untested native: if it answers
--- wrongly at scale the symptom is a map with no loot on it, which is the worst
--- failure this file has.
---
--- So it is asked of the sealed airdrop crate and of nothing else. That still
--- covers the whole drop, because the 10-14 items scatter FROM the crate at the
--- moment it is opened -- and by then the crate has been walked to reachable
--- ground by the repair round-trip below, so the ring is built around the
--- corrected point rather than the roof.
---
--- WIDENING IT IS ONE LINE once a playtest says the check behaves: return true
--- for isContainer(e), or unconditionally.
--- @param e table
--- @return boolean
local function needsReachable(e)
    return e.item == 'airdrop'
end

--- Somewhere dry and solid near an entry that is not.
---
--- ONLY A CLIENT CAN COMPUTE THIS. The server has no map at all:
--- GetGroundZFor_3dCoord and GetWaterHeight are client natives, so generation
--- can put an item in the Pacific or inside a hillside and never find out.
--- The correction goes back over LOOT_FIX and the server bounds it to 30m --
--- it is a suggestion, not an instruction (see server/loot.lua).
---
--- Candidates walk outward on the golden angle: an even spread that never
--- retraces its own ring, and identical on every client, so two players
--- reporting the same crate suggest the same place for it.
--- @param e table
--- @return number|nil x
--- @return number|nil y
--- @return number|nil z
local function dryPointNear(e)
    local from   = math.max((e.z or 0.0) + 50.0, PROBE_FROM_Z)
    local reach  = needsReachable(e)
    for i = 1, 12 do
        local ang = i * 2.39996323   -- golden angle in radians
        local r   = 4.0 + i * 2.0    -- 6m out to 28m, inside the server's bound
        local x   = e.x + math.cos(ang) * r
        local y   = e.y + math.sin(ang) * r
        local ok, gz = solidGround(x, y, from)
        -- A CANDIDATE HAS TO CLEAR THE SAME BAR THE ORIGINAL FAILED. Offering a
        -- rooftop the airdrop crate could move to instead of the rooftop it is
        -- already on would be a repair that repairs nothing, and it would burn
        -- the server's cooldown doing it.
        if ok and reach then
            ok = BR.Native.pedReachable(x, y, gz)
        end
        if ok then return x, y, gz end
    end
    return nil
end

--- Ground height under an entry, cached. The server has no ground probe (the
--- native is client-side), so the authored z is only ever a hint -- and for
--- roadside filler it is not even that.
---
--- ═══ `gzOk` AND `reachOk` ARE TWO DIFFERENT ANSWERS AND MERGING THEM WOULD BE
---     A CATASTROPHE ═══
---
--- `gzOk` is "dry and solid", it is what it has always been, and it is the ONLY
--- one that decides whether a prop gets built. `reachOk` is the new rooftop
--- question, and all it may ever do is trigger the repair round-trip.
---
--- Folding the second into the first is the obvious implementation and it would
--- mean that a rooftop airdrop with no better point within 28m never gets a
--- prop at all -- an invisible, unopenable, unfindable crate carrying the best
--- loot in the match, in the exact scenario the owner reported. The check is
--- built on a navmesh native NOTHING outside a running client has confirmed,
--- against a curated flag set that says "no" about perfectly good rural ground
--- (see BR.Native.SAFE_COORD_FLAGS). A false "no" must therefore cost a wasted
--- 30m suggestion and nothing else.
---
--- SO THE WORST CASE OF THIS WHOLE FEATURE IS TODAY'S BEHAVIOUR: the crate sits
--- where it landed, exactly as it did before any of this was written.
--- @param e table
--- @return number
local function groundZ(e)
    local now = GetGameTimer()
    if e.gz and now - (e.gzAt or 0) < 10000 then return e.gz end
    local from = math.max((e.z or 0.0) + 50.0, PROBE_FROM_Z)
    local ok, gz = solidGround(e.x, e.y, from)

    e.reachOk = true
    if ok and needsReachable(e) then
        local reach, why = BR.Native.pedReachable(e.x, e.y, gz)
        e.reachOk, e.reachWhy = reach, why
        if not reach then
            -- NAMED IN THE LOG, because the whole class of bug this addresses
            -- is invisible from a chair: an airdrop on a roof and an airdrop
            -- that moved thirty metres look identical to a player who was not
            -- watching, and neither says anything today.
            print(('[br_core] loot: entry %s at (%.0f, %.0f, %.1f) is not ped-reachable (%s) -- suggesting somewhere else')
                :format(tostring(e.item), e.x, e.y, gz, tostring(why)))
        end
    end

    e.gzOk = ok
    e.gz   = ok and gz or (e.z or 0.0)
    e.gzAt = now
    return e.gz
end

local function despawn(e)
    -- The settled height belongs to THAT object handle and that pose. A prop
    -- rebuilt after streaming out has to be measured again.
    e.restZ, e.settled = nil, false
    -- AND THE FLIGHT DIES WITH THE BODY. `arriveAt` is what keeps the render
    -- pass animating this entry from outside the glow radius, so leaving it set
    -- on an entry with no prop buys a per-frame callback that returns on its
    -- first line for the rest of the match. A rebuild re-arms it if the entry
    -- is still young enough to be worth flying (see drain).
    e.arriveAt, e.arcSeen = nil, nil
    if e.obj then
        byObject[e.obj] = nil
        if DoesEntityExist(e.obj) then DeleteEntity(e.obj) end
    end
    e.obj = nil
end

--- Hand a prop over to the retiring list instead of deleting it.
---
--- Only for loose items with a body already in the world. A crate becomes a
--- husk rather than vanishing, and a husk is scenery that stays.
--- @param e table
--- @param toX number|nil  where it should fly to; nil means straight up
--- @param toY number|nil
--- @param toZ number|nil
local function retireProp(e, toX, toY, toZ)
    if not e.obj or not DoesEntityExist(e.obj) then return false end
    local c = GetEntityCoords(e.obj)
    retireSeq = retireSeq + 1
    retiring[retireSeq] = {
        obj = e.obj,
        fromX = c.x, fromY = c.y, fromZ = c.z,
        toX = toX or c.x, toY = toY or c.y, toZ = toZ or (c.z + 1.0),
        at = GetGameTimer(),
        -- THE SIZE TRAVELS WITH IT (#166). The retiring list is deliberately
        -- detached from the entry -- the entry dies the instant the server
        -- confirms the claim -- so anything the animation needs has to be
        -- copied here. Without this a half-size shield would snap to full
        -- size on the frame it was picked up and fly to the player at the
        -- wrong scale, which is a worse artefact than not scaling it at all.
        scale = e.propScale,
    }
    byObject[e.obj] = nil
    e.obj = nil        -- despawn() must not delete it now
    return true
end

--- Delete every retiring prop immediately. Teardown, not animation.
local function clearRetiring()
    for k, r in pairs(retiring) do
        if r.obj and DoesEntityExist(r.obj) then DeleteEntity(r.obj) end
        retiring[k] = nil
    end
end

-- ═══ BR.Loot.airdropBox() USED TO LIVE HERE, AND IT HAD ONE CALLER ═══
--
-- It answered "which world object is the airdrop's box drawn as right now --
-- the sealed crate, or the husk it becomes", and it existed solely so
-- client/flares.lua could stand a pair of flares on it (owner, 2026-08-22:
-- "there should be flares on the husk too fwiw").
--
-- The owner played that and asked for it to go (2026-08-23: "If we drop the
-- husk flares and keep the free-falling ones I'd be happy with that") -- see
-- the reversal written up at the top of client/flares.lua. With the landed pass
-- deleted this accessor had no readers at all, so it went with it rather than
-- staying as an exported function nothing calls.
--
-- AND `airdropId` WENT WITH IT, because it had exactly one reader and that was
-- the accessor. It was written on every LOOT_ADD for 'airdrop'/'airdrophusk'
-- and cleared in forget() and forgetAll(); with nothing left reading its VALUE
-- those three sites were a variable being maintained for nobody. A write-only
-- local that looks live is the same trap the flares themselves were.

local function forget(id)
    local e = entries[id]
    if not e then return end
    despawn(e)
    entries[id] = nil
    queued[id] = nil
    poses[id] = nil
    if hold.id == id then clearHold('the entry it was for went away') end
    -- An entry that no longer exists cannot be the thing the player is being
    -- offered. Left set, it is a claim waiting to be sent for an id the server
    -- has already retired.
    if target and target.id == id then target = nil end
    if outlinedId == id then outlinedId = nil end
end

local function forgetAll()
    clearOutline(entries)
    clearRetiring()
    for id in pairs(entries) do forget(id) end
    entries, queue, queued, byObject, reported = {}, {}, {}, {}, {}
    myCell, target = nil, nil
    clearHold('the whole registry was dropped')
    shineId, outlinedId = nil, nil
    burstUntil, burstArmed = 0, false
    -- Inline rather than through setPrompt(): that lives below this, and a
    -- local referenced before its declaration silently resolves as a global.
    lastPrompt.id, lastPrompt.hold = nil, nil
    claimedByMe = {}
    -- The tap rate-limiter, keyed by loot id. Left out of this wipe until now,
    -- so it was the one registry table that survived every match boundary and
    -- grew for the whole session -- one entry per distinct item ever picked
    -- up. Small, but strictly monotonic, and there is no id here worth keeping
    -- once the entries those ids name have been dropped.
    claimedAt = {}
    -- The glow teaches the interaction again next match: whoever is here then
    -- may never have opened one.
    BR.Loot.openedCount = 0
    local page = BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
    BR.Dui.send(page, { t = 'prompt', show = false })
end

-- The spawn worker. Model loading is asynchronous, so this cannot live in a
-- loop callback -- and a burst of RequestModel in one frame is exactly how a
-- landing at a dense POI turns into a stutter. Two per pass, then yield.
--
-- ...EXCEPT FOR THE FIRST FEW SECONDS AFTER LANDING, where the trickle is the
-- problem rather than the fix. Two per pass across 50-150 streamed entries is
-- several seconds of a POI that looks empty, and a player who has just landed
-- has nothing else to do but look at it (user, 2026-08-08). The stutter this
-- rate exists to avoid is also least costly right then: the drop is already a
-- loading moment, and nobody is in a firefight three seconds after touchdown.
local function perPass()
    if burstUntil > 0 and GetGameTimer() < burstUntil then
        return L.landingBurst or 8
    end
    return L.drainPerPass or 2
end

local function drain()
    if draining then return end
    draining = true

    Citizen.CreateThread(function()
        while #queue > 0 do
            for _ = 1, perPass() do
                local id = table.remove(queue, 1)
                if not id then break end
                queued[id] = nil

                local e = entries[id]
                if e and not e.obj then
                    -- REPORT BEFORE BUILDING. An entry in the sea or inside a
                    -- hillside gets a corrected position sent back rather than
                    -- a prop built where nobody can reach it; the server
                    -- re-announces it and the next pass builds it properly.
                    groundZ(e)
                    -- TWO REASONS TO SUGGEST A MOVE, ONE REASON TO WITHHOLD THE
                    -- PROP. `gzOk` false is the sea and the inside of hillsides
                    -- and it stops the build below; `reachOk` false is the
                    -- rooftop case and it does NOT -- it asks the server to move
                    -- the entry and lets the crate exist meanwhile. See
                    -- groundZ.
                    if (not e.gzOk or not e.reachOk) and not reported[id] then
                        local fx, fy, fz = dryPointNear(e)
                        if fx then
                            -- MARKED ONLY ON AN ACTUAL SEND. It used to be
                            -- marked before the search, which spends the entry's
                            -- one attempt on a search that found nothing -- and
                            -- the rooftop case is exactly where that happens,
                            -- because a client too far out for the navmesh to
                            -- have streamed rejects all twelve candidates and
                            -- then never asks again once it is close enough to
                            -- get a real answer.
                            reported[id] = true
                            TriggerServerEvent(BR.Net.LOOT_FIX,
                                { id = id, x = fx, y = fy, z = fz })
                        end
                    end

                    local model = modelOf(e)
                    -- A MODEL THIS BUILD DOES NOT HAVE IS THE OTHER HALF OF
                    -- #224's fallback, and it is checked before the stream
                    -- rather than after: an entry whose prop name is a typo, or
                    -- a car the game has never heard of, gets its marker here
                    -- rather than three seconds of waiting and then nothing.
                    --
                    -- THROUGH isTrue, unlike the line below it. IS_MODEL_VALID
                    -- is a BOOL native and 0 IS TRUTHY IN LUA, so `not
                    -- IsModelValid(m)` is FALSE for a model the engine just said
                    -- it does not have -- the marker would never appear and the
                    -- console would never say why. (The raw read on the next
                    -- line is the original and is in tools/bool_natives.baseline;
                    -- it is left alone here so this change is one behaviour and
                    -- not two.)
                    if e.gzOk and model and not isTrue(IsModelValid(model)) then
                        noProp(e, 'the model is not valid on this build')
                    end
                    if e.gzOk and model and IsModelValid(model) then
                        RequestModel(model)
                        local waited = 0
                        while not HasModelLoaded(model) and waited < 3000 do
                            Citizen.Wait(50)
                            waited = waited + 50
                        end
                        -- The entry can be claimed by someone else while its
                        -- model streams in; re-check before building it.
                        if HasModelLoaded(model) and entries[id] and not entries[id].obj then
                            local gz = groundZ(e)
                            -- Containers are dropped a hair above the ground
                            -- and left to settle, because the native that
                            -- would settle them for us is the very thing that
                            -- welds them in place (see below).
                            -- THE LAST PARAMETER IS `dynamic`, and it was
                            -- false -- which is why crates stayed welded to
                            -- the ground however much of the rest of the
                            -- physics setup said otherwise (user, 2026-08-05).
                            -- Containers spawn dynamic; loose floor items stay
                            -- static, because a rifle skittering down a hill
                            -- is not a feature.
                            local dynamic = isContainer(e) or isHusk(e)
                            -- THE HUSK INHERITS THE CRATE'S POSE. If this entry
                            -- already had a prop in the world -- which it did
                            -- whenever a sealed crate has just become an open
                            -- one -- put the replacement exactly where the old
                            -- one was, at the same attitude. Otherwise the box
                            -- you just opened jumps back to where it was
                            -- generated and stands up straight (user,
                            -- 2026-08-06).
                            local pose = poses[id]
                            -- SHARED WITH THE ANIMATION. Static props are
                            -- built here and never moved again unless they
                            -- animate, so this height IS their resting
                            -- height -- and animate() writing a different one
                            -- is what buried them.
                            local sx, sy, sz = e.x, e.y, gz + (L.restLift or 0.35)
                            if pose then sx, sy, sz = pose.x, pose.y, pose.z end

                            local obj = CreateObjectNoOffset(model,
                                sx, sy, sz, false, false, dynamic)
                            -- AND A HANDLE OF 0 IS A REFUSAL, NOT AN OBJECT.
                            -- The `else` is #224's: an entry whose model the
                            -- engine will not build as an object falls back to a
                            -- marker rather than being invisible on the ground.
                            if not obj or obj == 0 then
                                noProp(e, 'the engine refused to build it as an object')
                            end
                            if obj and obj ~= 0 then
                                -- CRATES KEEP THEIR COLLISION. You walk up to
                                -- one and it is a box in the world; the ray
                                -- that decides what you are looking at needs
                                -- something to hit. Loose floor items do NOT
                                -- -- a hundred rifles underfoot at a hot drop
                                -- is a player snagging on loot mid-fight, and
                                -- they are close enough to target by proximity.
                                local solid = isContainer(e) or isHusk(e)
                                SetEntityCollision(obj, solid, solid)

                                -- ═══ COLLISION FIRST, PHYSICS SECOND (owner,
                                --     2026-08-23) ═══
                                --
                                -- A crate is the only thing this file hands to
                                -- the physics simulation, and it is handed over
                                -- a few lines below. Do that before the map's
                                -- collision has streamed in underneath it and
                                -- gravity walks it through the roof it was
                                -- standing on and leaves it at street level --
                                -- inside the building, where nobody in the match
                                -- can ever reach it. See awaitCollision.
                                --
                                -- AND THEN RE-PROBE, WHICH IS THE OTHER HALF.
                                -- The ground height above was read before this
                                -- wait, so it is a reading of whatever HAD
                                -- streamed -- the terrain -- and a crate placed
                                -- on it starts inside the building rather than
                                -- falling into it. Once the collision is really
                                -- there the probe returns the surface the crate
                                -- is actually over, and the box is moved onto
                                -- it. Skipped when there is a POSE, because a
                                -- husk inherits exactly where its sealed crate
                                -- came to rest and re-grounding it would undo a
                                -- fix from 2026-08-06.
                                if solid then
                                    awaitCollision(obj, sx, sy, sz)
                                    if not pose then
                                        local ok2, gz2 = solidGround(sx, sy,
                                            math.max((e.z or 0.0) + 50.0, PROBE_FROM_Z))
                                        if ok2 and math.abs(gz2 - gz) > 0.05 then
                                            local S = BR.Loot.settle
                                            S.reseated = S.reseated + 1
                                            S.lastLift = gz2 - gz
                                            gz, e.gz = gz2, gz2
                                            e.gzAt = GetGameTimer()
                                            sz = gz2 + (L.restLift or 0.35)
                                            SetEntityCoordsNoOffset(obj, sx, sy,
                                                sz, false, false, false)
                                        end
                                    end
                                end

                                if pose then
                                    -- Order 2 is the same convention
                                    -- GetEntityRotation was read with, so the
                                    -- pose round-trips exactly.
                                    SetEntityRotation(obj, pose.rx, pose.ry,
                                        pose.rz, 2, true)
                                elseif e.heading then
                                    SetEntityHeading(obj, e.heading)
                                end
                                -- PLACEOBJECTONGROUNDPROPERLY IS WHAT WELDED
                                -- THEM DOWN. Measured, not guessed: /brprobe
                                -- crate spawned five variants differing by one
                                -- decision each, and the ONLY one that moved
                                -- was the one that skipped this call
                                -- (2026-08-06, after three failed fixes).
                                --
                                -- So containers are placed by ARITHMETIC --
                                -- we already have the ground height from the
                                -- probe -- and never by the native that
                                -- settles them into the terrain.
                                --
                                -- Loose floor items still use it: they are
                                -- frozen anyway, and it makes a rifle lie flat
                                -- on a slope instead of hovering.
                                if not solid then
                                    -- POSE FIRST, THEN SETTLE, THEN REMEMBER.
                                    --
                                    -- The native works off the model's
                                    -- bounding box, and a rifle lying flat has
                                    -- a very different box from one standing
                                    -- on end -- settle before posing and it
                                    -- lands at the wrong height for the pose
                                    -- it is about to take.
                                    SetEntityRotation(obj, restPitchOf(e), 0.0,
                                        e.heading or 0.0, 2, true)
                                    PlaceObjectOnGroundProperly(obj)

                                    -- WHERE IT ACTUALLY ENDED UP is the number
                                    -- the hover rises from and returns to, and
                                    -- it is not knowable any other way: it
                                    -- depends on the model and the slope.
                                    --
                                    -- Captured HERE rather than at the first
                                    -- settle because the object is frozen a
                                    -- few lines below, and this native does
                                    -- not move a frozen entity. Two earlier
                                    -- guesses -- the bare ground z, then
                                    -- ground + 0.35 -- buried it and then
                                    -- floated it (user, 2026-08-08).
                                    local c = GetEntityCoords(obj)

                                    -- ...AND THEN LOWERED, FOR THE ITEMS THAT
                                    -- ASK TO BE (#240).
                                    --
                                    -- Owner, 2026-08-30: "At rest, the vehicle
                                    -- pickup props are floating above the ground
                                    -- at waist-level... The prop pickup should
                                    -- be lowered by maybe 0.5m."
                                    --
                                    -- The native settles the model at its
                                    -- AUTHORED size and the matrix scale is
                                    -- applied further down, so a car token drawn
                                    -- at 0.375 keeps the origin height a
                                    -- full-size car was given. propDropOf is
                                    -- zero for every other item on the map and
                                    -- this is a no-op for all of them.
                                    --
                                    -- WRITTEN INTO restZ, NOT JUST INTO THE
                                    -- ENTITY. restZ is the height the hover
                                    -- animation rises from and settles back to;
                                    -- moving the object without moving that
                                    -- number would put the float back the first
                                    -- time anybody walked past.
                                    local drop = propDropOf(e)
                                    if drop > 0.0 then
                                        SetEntityCoordsNoOffset(obj, c.x, c.y,
                                            c.z - drop, false, false, false)
                                    end
                                    e.restZ = c.z - drop
                                end

                                -- CRATES ARE PHYSICAL. Drive into one and it
                                -- moves (user call, 2026-08-05). Only the
                                -- LOCAL prop moves -- the entry's authoritative
                                -- position never changes, so a crate shunted
                                -- across a car park is still looted from where
                                -- the server thinks it is, and every client
                                -- sees its own version of the shunt.
                                FreezeEntityPosition(obj, not solid)
                                if solid then
                                    SetEntityDynamic(obj, true)
                                    SetEntityHasGravity(obj, true)
                                    -- A CRATE IS NOT A SAFE. The default mass
                                    -- for this prop made it shift like a
                                    -- concrete block when a car hit it
                                    -- ("extremely heavy", 2026-08-06); a
                                    -- wooden crate should skitter.
                                    SetObjectPhysicsParams(obj,
                                        L.crateMass or 12.0,
                                        0.1,               -- damping
                                        -1.0, -1.0, -1.0,  -- inertia: engine default
                                        -1.0,              -- gravity: default
                                        0.1, 0.1, 0.1,     -- angular damping
                                        -1.0, -1.0)
                                    -- Physics can be dynamic, unfrozen and
                                    -- gravity-bound and still ASLEEP.
                                    ActivatePhysics(obj)
                                end
                                SetEntityAsMissionEntity(obj, false, true)

                                -- SIZE LAST, because everything above writes
                                -- the matrix (#166). SetEntityRotation,
                                -- SetEntityHeading and
                                -- PlaceObjectOnGroundProperly all rebuild the
                                -- axis vectors at unit length, so a scale
                                -- applied before any of them is a scale that
                                -- was silently thrown away. Cached on the
                                -- entry so the hover does not re-read the
                                -- config sixty times a second.
                                e.propScale = propScaleOf(e)
                                applyPropScale(obj, e.propScale)

                                -- ═══ AND THE ENTRY HAS TO STILL BE THE ENTRY
                                --     ═══
                                --
                                -- The collision wait above is the first thing in
                                -- this block that YIELDS after an object exists,
                                -- and up to a second and a half of frames is
                                -- plenty for the entry to be claimed, replaced by
                                -- its husk, or streamed out. Handing the prop to
                                -- a table that is no longer in `entries` is a box
                                -- in the world that nothing owns and nothing will
                                -- ever delete -- so it is checked, and the
                                -- orphan is destroyed rather than adopted.
                                if entries[id] == e and not e.obj then
                                    e.obj = obj
                                    byObject[obj] = id
                                elseif DoesEntityExist(obj) then
                                    DeleteEntity(obj)
                                    obj = nil
                                end

                                -- THE ARRIVAL CLOCK STARTS HERE, AND THAT IS
                                -- THE FIX (owner, 2026-08-23: "the loot doesn't
                                -- animate out of the crate like it should").
                                --
                                -- It used to start when the LOOT_ADD message
                                -- was handled, and animate() cannot move a prop
                                -- that does not exist -- its first line returns
                                -- on `not e.obj`. Between those two moments sit
                                -- the 1Hz spawn pass and a model stream, so the
                                -- 520ms window had ALWAYS closed before there
                                -- was anything to animate. The branch was not
                                -- broken; it was unreachable.
                                --
                                -- Everything above has just placed this object
                                -- at its RESTING height and measured restZ off
                                -- it, which is why the arm is here rather than
                                -- earlier: the arc has to know where it is
                                -- landing before it can leave. animate() picks
                                -- it up on the next frame.
                                local age = GetGameTimer() - (e.bornAt or 0)
                                e.arriveAt = nil
                                if e.fx and e.fy and e.bornAt then
                                    BR.Loot.arc.lastBuildMs = age
                                    if age < (L.arriveGraceMs or 3000) then
                                        e.arriveAt = GetGameTimer()
                                        BR.Loot.arc.armed = BR.Loot.arc.armed + 1
                                    else
                                        BR.Loot.arc.late = BR.Loot.arc.late + 1
                                    end
                                end
                            end
                        end
                        -- The two crate models stay resident. They are the
                        -- most-spawned models in the game by a wide margin,
                        -- and the sealed->open swap has to be instant --
                        -- re-streaming the open crate at the moment it is
                        -- looted is exactly the delay that was visible.
                        if model ~= CRATE_MODEL and model ~= CRATE_OPEN_MODEL then
                            SetModelAsNoLongerNeeded(model)
                        end
                    end
                end
            end
            Citizen.Wait(0)
        end
        draining = false
    end)
end

-- --------------------------------------------------------------------------
-- The wire
-- --------------------------------------------------------------------------

local function addEntries(list)
    -- Read once, and only if something in this batch was actually born just
    -- now. The common caller is a cell subscription of 50-150 entries that were
    -- always there, and none of them needs to know where anybody is standing.
    local px, py = nil, nil

    for _, d in ipairs(list or {}) do
        if d.id then
            local have = entries[d.id]
            if have then
                -- A RE-SEND IS A CHANGE, not a duplicate. Two things arrive
                -- this way: the repair round-trip re-announcing a corrected
                -- position, and a sealed crate becoming its opened husk. Both
                -- keep the id; both need the prop rebuilt.
                local moved = math.abs((have.x or 0) - (d.x or 0)) > 0.01
                    or math.abs((have.y or 0) - (d.y or 0)) > 0.01
                local reskinned = have.kind ~= d.kind or have.prop ~= d.prop

                if moved or reskinned then
                    -- THE SERVER ANSWERED, and this is the only place a client
                    -- can see that it did. A crate re-announced as its husk IS
                    -- the confirmation that a claim landed -- there is no reply
                    -- message and never was -- so the claim receipt is closed
                    -- here (#129, sixth round: "the claim went out" and "the
                    -- server acted on it" were the same silence from a chair).
                    if reskinned and d.kind == 'husk' then
                        noteClaimAnswered(d.id)
                    end
                    -- THE REVEAL, on the authoritative moment -- and only for
                    -- the player who opened it. This fires when the crate
                    -- ACTUALLY opened, so it cannot play for a claim the
                    -- server refused; the claimedByMe check is what stops it
                    -- firing for everyone standing nearby (user, 2026-08-05).
                    if reskinned and d.kind == 'husk' and L.openSound
                       and claimedByMe[d.id] then
                        claimedByMe[d.id] = nil
                        PlaySoundFrontend(-1, L.openSound.name,
                            L.openSound.set, true)
                    end
                    despawn(have)
                    have.x, have.y, have.z = d.x, d.y, d.z
                    have.kind, have.item, have.prop = d.kind, d.item, d.prop
                    have.rarity = d.rarity or have.rarity
                    if moved then
                        have.gz, have.gzAt, have.gzOk = nil, 0, nil
                    end
                    queued[d.id] = nil
                    -- Rebuilt on the NEXT prop pass at the latest, but a
                    -- crate the player is standing over has to change NOW --
                    -- so it jumps the queue.
                    if reskinned then
                        queued[d.id] = true
                        table.insert(queue, 1, d.id)
                        drain()
                    end
                end
            else
                entries[d.id] = {
                    id = d.id, kind = d.kind, item = d.item,
                    rarity = d.rarity or BR.Rarity.COMMON, count = d.count or 1,
                    x = d.x, y = d.y, z = d.z, prop = d.prop,
                    heading = d.heading,
                    -- Where it came from, if it came from anywhere: a crate
                    -- bursting open or a player's hand. Absent on the
                    -- generated layout, which was always just there.
                    fx = d.fx, fy = d.fy, fl = d.fl,
                    bornAt = d.fx and GetGameTimer() or nil,
                    lift = 0.0,
                }

                -- BORN JUST NOW MEANS BUILT JUST NOW, and this is the other
                -- half of why the arc never played.
                --
                -- Nothing here used to ask for a prop at all: the ONLY thing
                -- that queues a new entry is the loot.props pass, which is
                -- registered on the SLOW band -- once per SECOND. An item that
                -- has this instant burst out of a crate two metres away
                -- therefore waited up to a full second for a body, and the
                -- arrival window is half that. This is the same queue-jump a
                -- crate becoming its husk already gets, for the same reason:
                -- something the player is watching cannot wait for the trickle.
                --
                -- Gated on the prop radius because drain() does NOT check
                -- distance -- it builds whatever it is handed -- and a crate
                -- opened at the far edge of the 768m subscription would
                -- otherwise build props nobody can see, for the next pass to
                -- tear straight back down.
                if d.fx then
                    if not px then
                        local p = GetEntityCoords(PlayerPedId())
                        px, py = p.x, p.y
                    end
                    local near = L.propDistance
                    if BR.Dist2(px, py, d.x or 0.0, d.y or 0.0) <= near * near then
                        BR.Loot.arc.born = BR.Loot.arc.born + 1
                        queued[d.id] = true
                        table.insert(queue, 1, d.id)
                        drain()
                    end
                end
            end
        end
    end
end

RegisterNetEvent(BR.Net.LOOT_ADD)
AddEventHandler(BR.Net.LOOT_ADD, function(list)
    addEntries(list)
end)

-- The Volts cue. See protocol.lua: Volts are collected without a slot, so the
-- inventory's own pickup sound never fires for them and this is the whole of
-- the fix -- the same cue, from BR.Config.Loot.pickupSound, not a second one.
RegisterNetEvent(BR.Net.LOOT_PICKUP_CUE)
AddEventHandler(BR.Net.LOOT_PICKUP_CUE, function()
    local L = BR.Config.Loot
    if L and L.pickupSound then
        PlaySoundFrontend(-1, L.pickupSound.name, L.pickupSound.set, true)
    end
end)

RegisterNetEvent(BR.Net.LOOT_GONE)
AddEventHandler(BR.Net.LOOT_GONE, function(ids)
    for _, id in ipairs(ids or {}) do
        local e = entries[id]
        -- A loose item's claim is answered by its RETIREMENT, the way a crate's
        -- is answered by its husk. Same receipt, different shape.
        noteClaimAnswered(id)
        -- SOMETHING I TOOK FLIES TO ME. Somebody else's pickup just goes --
        -- LOOT_GONE does not say who claimed it, and inventing a direction
        -- would be a lie about where a player is standing.
        if e and claimedByMe[id] and not isContainer(e) and not isHusk(e) then
            local ped = PlayerPedId()
            local p = GetEntityCoords(ped)
            retireProp(e, p.x, p.y, p.z + (L.waistHeight or 0.75))
        end
        forget(id)
    end
end)

-- A br_ui restart does not touch this, but a RECONNECT does: the snapshot
-- carries whatever cells this player was already subscribed to.
RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    if payload and payload.loot then addEntries(payload.loot) end
end)

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if not d then return end
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        forgetAll()
    end
end)

-- An un-deleted local object outlives the resource that made it, so this is
-- not optional -- a restart mid-match would leave the props behind forever
-- with nothing left that knows they exist.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    forgetAll()
end)

-- --------------------------------------------------------------------------
-- Loops
-- --------------------------------------------------------------------------

-- Cell subscription.
--
-- MOVED FROM 1Hz TO 10Hz, AND THE REASON GIVEN FOR IT WAS WRONG.
--
-- A 256m cell takes 25 seconds to cross on foot, so 1Hz was ample for the
-- steady state and the band's comment has said "loot cells" since M0. The
-- reasoning written here was that the moment that matters is the FIRST
-- subscription, "because a player is only allowed to see loot once they are
-- ALIVE". That is not the rule and never was: BR.Config.LootVisibleStates
-- admits WARMUP, BUS, FREEFALL and GLIDE, so a player sees loot from the pad,
-- from the plane and the whole way down, and the first subscription of a round
-- happens on the warmup pad. The landing crosses no boundary at all if the
-- player drops inside the cell they are already subscribed to.
--
-- The rate is kept anyway, on its honest merit rather than the old one: this is
-- the cheapest of the three loot loops -- a state check, a coordinate read and
-- a string compare, with an early-out on every tick that has not moved cell --
-- and at 10Hz a boundary crossed mid-sprint is answered before the props are
-- wanted. loot.props, which is a full walk of every streamed entry, stays SLOW.
BR.Loop.register(BR.Loop.TICK, 'loot.cells', function()
    if not canSee() then
        if myCell then forgetAll() end
        return
    end

    -- THE BURST IS ARMED BY THE TOUCHDOWN, NOT BY THE FIRST SUBSCRIPTION
    -- (#126). Above the cell early-out on purpose: landing inside the cell you
    -- were already subscribed to is the common case at a POI you glided
    -- straight into, and that case must still get the budget. See burstUntil.
    local landed = BR.State.landed == true
    if landed and not burstArmed then
        burstArmed = true
        burstUntil = GetGameTimer() + (L.landingBurstMs or 4000)
    elseif not landed then
        burstArmed = false
    end

    local p = GetEntityCoords(PlayerPedId())
    local cx, cy = BR.LootCellOf(p.x, p.y)
    local key = BR.LootCellKey(cx, cy)
    if key == myCell then return end

    myCell = key
    TriggerServerEvent(BR.Net.LOOT_CELL, { cx = cx, cy = cy })
end)

-- Prop lifecycle. Entries are cheap; objects are not, so they exist in a much
-- smaller radius than the subscription and are torn down with hysteresis --
-- without it a player standing exactly on the boundary rebuilds the same model
-- every second.
BR.Loop.register(BR.Loop.SLOW, 'loot.props', function()
    if not canSee() then return end

    local p = GetEntityCoords(PlayerPedId())
    local near = L.propDistance
    local far  = L.propDistance + (L.propHysteresis or 15.0)
    local live = 0

    local now = GetGameTimer()

    for id, e in pairs(entries) do
        local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
        if e.obj then
            live = live + 1
            if d2 > far * far or not DoesEntityExist(e.obj) then
                despawn(e)
            elseif isContainer(e) then
                -- A PUSHED CRATE TAKES ITS ENTRY WITH IT.
                --
                -- The prop is physical now, but the REGISTRY position is what
                -- the prompt, the reach test and the server's claim check all
                -- use -- so a crate shunted by a car became unopenable, sitting
                -- in plain sight (user, 2026-08-06). It could hardly be more
                -- confusing: the thing you can see is not the thing the game
                -- thinks is there.
                --
                -- The client follows the object locally and tells the server,
                -- which bounds how far it will accept. Rate-limited, because
                -- a crate rolling down a hill would otherwise send one of
                -- these per second for as long as it rolls.
                local c = GetEntityCoords(e.obj)
                if BR.Dist2(c.x, c.y, e.x, e.y) > 1.0
                   and now - (e.movedAt or 0) > 2000 then
                    e.movedAt = now
                    e.x, e.y, e.z = c.x, c.y, c.z
                    e.gz, e.gzAt = c.z, now
                    TriggerServerEvent(BR.Net.LOOT_FIX,
                        { id = id, x = c.x, y = c.y, z = c.z })
                end
            end
        elseif d2 <= near * near and not queued[id] and live + #queue < PROP_MAX then
            queued[id] = true
            queue[#queue + 1] = id
        end
    end

    if #queue > 0 then drain() end
end)

--- The entry a player is closest to, within a distance. Debug only -- /brloot
--- uses it to name whatever is nearby, with no eligibility rules at all.
--- @param px number
--- @param py number
--- @param maxDist number
--- @return table|nil
local function nearestEntry(px, py, maxDist)
    local best, bestD2 = nil, maxDist * maxDist
    for _, e in pairs(entries) do
        if not isHusk(e) then
            local d2 = BR.Dist2(px, py, e.x, e.y)
            if d2 < bestD2 then best, bestD2 = e, d2 end
        end
    end
    return best
end

--- Is the player actually LOOKING at this thing?
---
--- Walking down a corridor of loot used to flicker a prompt for whichever item
--- happened to be nearest, including ones behind you (user, 2026-08-08).
---
--- Ped forward rather than camera forward: the prompt is about what the
--- CHARACTER can reach, and in third person the camera can be looking
--- somewhere the ped is not.
--- @param ped integer
--- @param px number
--- @param py number
--- @param e table
--- @return boolean
local function facing(ped, px, py, e)
    local dx, dy = e.x - px, e.y - py
    local len = math.sqrt(dx * dx + dy * dy)
    -- Standing on top of it: there is no direction to disagree with.
    if len < 0.35 then return true end

    local f = GetEntityForwardVector(ped)
    return ((dx / len) * f.x + (dy / len) * f.y) >= (L.promptFacingDot or 0.55)
end

--- The single entry the player is being offered, or nil.
---
--- EXACTLY ONE, AND IT IS THE NEAREST ONE ELIGIBLE (#128). The old version was
--- two rules stacked, and the seam between them is where the bug lived:
---
---   * a ray-cast that RETURNED EARLY, so whatever it hit won outright however
---     far away it was, and
---   * a proximity fallback that took the nearest entry and then threw it away
---     if the player was not facing it -- which is not the same thing as
---     "the nearest entry the player IS facing". An item at 1m behind the
---     shoulder suppressed the prompt for the one at 2m dead ahead.
---
--- With two items in front of the player the two rules answered differently,
--- and both answers were live: the ray-cast one was drawn, the proximity one
--- was what a keypress a frame later could just as easily claim. Facing two
--- items and taking the one you were not looking at is the fault the owner
--- reported, and it is a gameplay fault -- you lose the item you wanted and a
--- slot to one you did not.
---
--- Now there is one rule. Every candidate is judged on its own merits, and the
--- nearest survivor wins. A single pass, single-valued, and it cannot disagree
--- with itself.
---
--- The ray still earns its place, but it decides ELIGIBILITY rather than the
--- winner: a crate the player is looking straight at is reachable out to
--- reachOf() even if some loose item is technically nearer, which is the
--- "which crate am I standing in front of" behaviour the ray was added for.
---
--- COST, SINCE THIS RUNS EVERY FRAME AND THE SHINE SCAN WAS MOVED OFF THE
--- FRAME BAND FOR EXACTLY THIS REASON: it is one walk of the streamed entries,
--- which is what the old proximity fallback already did on every frame the ray
--- did not happen to hit something -- i.e. nearly all of them. What is gone is
--- the ray's early return, which only ever fired while the player was looking
--- directly at a prop. Unlike the shine, this cannot be sampled at 10Hz: it
--- decides what a keypress claims, and a keypress lands on a frame.
--- @param ped integer
--- @param px number
--- @param py number
--- @return table|nil
local function targetEntry(ped, px, py)
    -- One ray per pass, not one per candidate. It answers a single question:
    -- which entry, if any, is the player looking straight at.
    local rayId = nil
    local hit, _, entity = BR.Native.aim((L.pickupDistance or 3.5) + 1.5, 16)
    if hit and entity and entity ~= 0 then rayId = byObject[entity] end

    local best, bestD2 = nil, nil
    for id, e in pairs(entries) do
        -- A husk is an already-opened crate: scenery, and the server refuses
        -- to claim it.
        if not isHusk(e) then
            local reach = reachOf(e)
            local d2 = BR.Dist2(px, py, e.x, e.y)
            if d2 <= reach * reach then
                -- A container is exempt from the facing cone: a crate is a
                -- metre-wide box you are standing at, and making players line
                -- up with one to open it is friction for nothing. So is
                -- anything the ray hit -- the ray IS a facing test, and a
                -- stricter one.
                if isContainer(e) or id == rayId
                   or facing(ped, px, py, e) then
                    if not bestD2 or d2 < bestD2 then best, bestD2 = e, d2 end
                end
            end
        end
    end

    return best
end

--- The prompt page. One browser for the whole system, created on first use.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Tell the prompt page WHAT to show. Position is not its business -- that is
--- drawn natively, per frame, in the render loop.
---
--- Sent on CHANGE ONLY. The old NUI version had to push screen coordinates
--- across the resource bridge as the camera moved, which had to be throttled,
--- which is exactly why the text visibly trailed the crate. Nothing here moves
--- with the player at all.
--- @param e table|nil
--- @param holdMs number|nil  non-nil starts the ring animation
local function setPrompt(e, holdMs)
    local page = promptPage()
    local id   = e and e.id or nil

    if not e then
        if lastPrompt.id == nil then return end
        lastPrompt.id, lastPrompt.hold = nil, nil
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    -- A re-send would restart the ring animation from zero, so a hold that is
    -- already running is left strictly alone.
    if id == lastPrompt.id and holdMs == lastPrompt.hold then return end
    lastPrompt.id, lastPrompt.hold = id, holdMs

    local container = isContainer(e)
    -- A CRATE'S TEXT IS THE SHINE'S ORANGE, not a rarity colour -- the two are
    -- the same signal and must not disagree. Loose items keep their rarity.
    local info = BR.RarityInfo[e.rarity] or BR.RarityInfo[BR.Rarity.COMMON]
    local colour = container and (L.shineHex or '#FF961E') or info.hex

    BR.Dui.send(page, {
        t      = 'prompt',
        show   = true,
        label  = labelOf(e),
        hint   = container and 'Hold to open' or 'Press to pick up',
        -- THE PLAYER'S OWN BINDING, asked for by COMMAND rather than by
        -- control. This used to read control 51 -- GTA's context key -- which
        -- is not the thing `brinteract` is bound to, so rebinding interact in
        -- the pause menu left every prompt still saying E. The vanilla control
        -- remains the fallback, because it also still works (see the two-inputs
        -- note further down) and a prompt with no key at all is worse than one
        -- naming the second of two working keys.
        key    = BR.Native.keyLabelForCommand('brinteract',
                                              L.promptControl or 51),
        colour = colour,
        ring   = container,
        holdMs = holdMs,
    })
end

--- Smoothstep, so eases start and end at rest rather than jerking into motion.
--- @param t number 0..1
--- @return number
local function ease(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

--- Move a value toward `to` by at most `step`.
---
--- The parameter is not called `target`: that is now a file-local holding the
--- entry the player is being offered, and shadowing it inside a maths helper is
--- how a later edit here reads as touching the offer.
local function approach(v, to, step)
    if v < to then return math.min(to, v + step) end
    return math.max(to, v - step)
end

--- Animate one loose item's prop for this frame.
---
--- LOOSE ITEMS ONLY. Crates and husks are physics objects with collision that
--- the drag loop owns; hovering one would fight that loop and also lie -- a
--- crate is furniture, and furniture does not float.
---
--- Three things stack, in order:
---
---   ARRIVAL  an item born from a crate or a drop flies an arc from where it
---            came from to where it lands. Runs once, from the moment its PROP
---            was built -- see the arming block in drain(). It used to run off
---            the entry's birth stamp, which is when the MESSAGE arrived, and
---            that is why it never ran at all: there is no prop to move for the
---            first second of an entry's life, and the whole window is 520ms.
---   HOVER    inside prompt range it rises to about waist height. Eased both
---            ways: a snap reads as a bug, a rise reads as "take me".
---   BOB+SPIN a slow turn and a shallow breath, scaled by how lifted it is --
---            so an item resting on the ground is perfectly still.
--- @param e table
--- @param d2 number  squared distance to the player
--- @param dt number  ms since the last frame
--- @param now number
local function animate(e, d2, dt, now)
    if not e.obj or not DoesEntityExist(e.obj) then return end
    if isContainer(e) or isHusk(e) then return end

    local gz = groundZ(e)

    -- WHERE "ON THE GROUND" ACTUALLY IS -- ASKED, NOT CALCULATED.
    --
    -- Two wrong answers first. `gz` buried everything, because the spawn drops
    -- props at `gz + 0.35`. Then `gz + 0.35` left them floating, because the
    -- spawn ALSO calls PlaceObjectOnGroundProperly straight afterwards, which
    -- settles them onto the surface -- so the number the animation was
    -- restoring had never been where they actually sat (user, 2026-08-08).
    --
    -- Neither number was ever knowable from here: it depends on the model's
    -- bounding box and the slope under it. So the native that already knows
    -- is asked, once per settle, and its answer is remembered as `restZ`.
    local rest = e.restZ or (gz + (L.restLift or 0.35))

    -- PITCH IS THE OTHER HALF OF THE CLIPPING, BUT ONLY FOR LONG THINGS.
    --
    -- A rifle standing on end sinks into the terrain however carefully its
    -- centre is placed; lying flat it sits on it. An ammo box or a medkit is
    -- a box -- it spawns the right way up and tipping it onto its side is
    -- worse, not better (user, 2026-08-08). So only weapons lie down.
    local rp = restPitchOf(e)
    local pitch = rp + ((L.hoverPitch or 0.0) - rp) * ease(e.lift or 0.0)

    -- ARRIVAL. A parabola, not a straight line: the extra height is what
    -- makes it read as thrown rather than slid.
    --
    -- DRIVEN OFF `arriveAt`, WHICH IS STAMPED WHEN THE PROP IS BUILT, not off
    -- the moment the message arrived. See the arming block in drain(): the prop
    -- is what flies, and for the whole life of this animation the prop did not
    -- exist until long after the window had shut.
    local arriveMs = L.arriveMs or 520
    if e.arriveAt and (now - e.arriveAt) < arriveMs and e.fx and e.fy then
        local t = (now - e.arriveAt) / arriveMs
        local k = ease(t)
        -- THE ORIGIN'S HEIGHT IS A LIFT ABOVE OUR OWN GROUND, never a z off
        -- the wire. The server's z is a first-pass hint with no ground probe
        -- behind it, and when it sat below the real terrain the contents of a
        -- crate rose UP OUT OF THE FLOOR (user, 2026-08-08).
        local sz = gz + (e.fl or (L.crateMouthHeight or 0.6))
        local x = e.fx + (e.x - e.fx) * k
        local y = e.fy + (e.y - e.fy) * k
        local z = sz + (rest - sz) * k
            + math.sin(t * math.pi) * (L.arriveArc or 0.55)
        SetEntityCoordsNoOffset(e.obj, x, y, z, false, false, false)
        -- Tumbling through the air, and it keeps the phase for the hover.
        e.spin = ((e.spin or 0.0) + (L.spinDegPerSec or 55.0) * 3.0
                  * (dt / 1000.0)) % 360.0
        SetEntityRotation(e.obj, L.hoverPitch or 0.0, 0.0, e.spin, 2, true)
        applyPropScale(e.obj, e.propScale)
        e.lift = 0.0
        e.settled = false

        -- PROOF, AND THE ONLY PROOF THERE IS FROM A CHAIR. See BR.Loot.arc: an
        -- arc that never runs and an arc that runs badly look identical from
        -- the outside, and this frame counter is what tells them apart without
        -- a playtest. /brarc reads it.
        local a = BR.Loot.arc
        if not e.arcSeen then
            e.arcSeen = true
            a.flights, a.lastFrames, a.lastPeak = a.flights + 1, 0, 0.0
        end
        a.frames, a.lastFrames = a.frames + 1, a.lastFrames + 1
        if z - rest > a.lastPeak then a.lastPeak = z - rest end
        return
    end

    -- THE FLIGHT IS OVER. Cleared rather than left to expire on its own clock,
    -- because `arriveAt` is also what tells the render pass to keep animating
    -- this entry from outside the glow radius -- an arc that never clears is a
    -- prop that keeps paying for a frame callback for the rest of the match.
    -- The hover below then settles it back onto `rest`, which is the height
    -- the spawn measured, so the flight leaves the ground placement exactly as
    -- it found it.
    if e.arriveAt then e.arriveAt, e.arcSeen = nil, nil end

    -- HOVER, toward 1 when the player is close enough to be offered it.
    local pr = L.promptDistance or 2.5
    local want = (d2 <= pr * pr) and 1.0 or 0.0
    local ms = (want > (e.lift or 0.0)) and (L.hoverRiseMs or 320)
                                        or (L.hoverFallMs or 420)
    e.lift = approach(e.lift or 0.0, want, dt / math.max(ms, 1))

    local k = ease(e.lift)
    if k <= 0.001 then
        -- Fully at rest. Done once on the way down rather than every frame
        -- forever: a hundred items on the floor should cost nothing.
        if e.settled then return end
        e.settled = true

        -- Back to exactly where the spawn settled it -- see the note there
        -- for why that height is captured once and never recomputed. The prop
        -- is frozen by now, so PlaceObjectOnGroundProperly would do nothing.
        SetEntityRotation(e.obj, rp, 0.0, e.spin or (e.heading or 0.0), 2, true)
        SetEntityCoordsNoOffset(e.obj, e.x, e.y, rest, false, false, false)
        -- AND THE SIZE, which the rotation write above has just reset to 1.
        -- This is the branch that matters most for #166: it is the resting
        -- state, so it is what a player SEES from across the room, and it is
        -- the one an early return could most easily have skipped.
        applyPropScale(e.obj, e.propScale)
        return
    end
    e.settled = false

    local bob = math.sin(now / math.max(L.bobPeriodMs or 1900, 1) * math.pi * 2.0)
                * (L.bobAmplitude or 0.06) * k
    SetEntityCoordsNoOffset(e.obj, e.x, e.y,
        rest + k * (L.hoverHeight or 0.55) + bob, false, false, false)

    e.spin = ((e.spin or 0.0) + (L.spinDegPerSec or 55.0) * k * (dt / 1000.0))
             % 360.0
    SetEntityRotation(e.obj, pitch, 0.0, e.spin, 2, true)
    applyPropScale(e.obj, e.propScale)
end

--- Fly every retiring prop to its destination, then delete it.
---
--- These are not loot any more -- see the note on `retiring`. Nothing here can
--- be targeted, prompted or claimed; it is scenery being cleared away.
--- @param now number
local function stepRetiring(now)
    local ms = L.takeMs or 400
    for k, r in pairs(retiring) do
        local t = (now - r.at) / ms
        if t >= 1.0 or not r.obj or not DoesEntityExist(r.obj) then
            if r.obj and DoesEntityExist(r.obj) then DeleteEntity(r.obj) end
            retiring[k] = nil
        else
            local p = ease(t)
            SetEntityCoordsNoOffset(r.obj,
                r.fromX + (r.toX - r.fromX) * p,
                r.fromY + (r.toY - r.fromY) * p,
                -- Lifts clear of the ground first, then travels -- otherwise
                -- it ploughs through the floor on the way to a waist.
                r.fromZ + (r.toZ - r.fromZ) * p + math.sin(t * math.pi) * 0.25,
                false, false, false)
            SetEntityHeading(r.obj, (t * 540.0) % 360.0)
            -- ...and put the size back, because SetEntityHeading is a matrix
            -- write and resets the axis vectors to unit length (#166).
            applyPropScale(r.obj, r.scale)
            -- Shrinking as it flies would be nicer than spinning, and #166 has
            -- since found the lever for it -- there is no SetEntityScale, but
            -- the transform matrix carries the size (see applyPropScale). It
            -- is deliberately NOT done here: a taper on the take animation is
            -- a separate presentational change nobody has asked for, and this
            -- pass is where a per-frame matrix write would be paid for by
            -- every item anyone ever picks up. The spin plus the arc still
            -- sells it.
        end
    end
end

-- Glow, labels, the prompt and the container hold, all off one pass over the
-- entries in range. Disable with /brloop disable loot.render, the same drill
-- the storm renderer answers to.
--
-- THAT TOGGLE NOW TAKES PICKUP WITH IT, and it is worth knowing before you
-- reach for it to bisect a hitch. This pass is where the frame's one target is
-- resolved (#128), so with it off nothing is being offered and the interact key
-- has nothing to act on. That is the price of there being exactly one resolver:
-- the alternative is a second one in the keypress handler, which is the pair
-- that disagreed with each other in the first place.
--- Crate physics: drag, and remembering where each crate actually is.
---
--- SEPARATE FROM loot.props, AND TEN TIMES FASTER, and that separation is the
--- whole fix. The drag used to live inside loot.props -- which is registered
--- on the SLOW band, once per SECOND. A crate hit by a car therefore skated at
--- full speed for a whole second before anything touched it, then again, and
--- again: the damping was real, ran exactly as written, and was completely
--- invisible ("I'm thinking the weight or drag or whatever just isn't working
--- at all", user 2026-08-06). It was working; it was being asked once a
--- second. At 10Hz the same coefficient is applied ten times as often, which
--- is the order of magnitude that was missing.
---
--- This does no scanning: it walks only the entries that already HAVE a prop,
--- which is at most PROP_MAX and usually a handful.
BR.Loop.register(BR.Loop.TICK, 'loot.crates', function()
    for id, e in pairs(entries) do
        -- HUSKS TOO. An opened crate is the same physical box with a different
        -- lid: it already got the mass (both go through the `solid` branch at
        -- spawn) but it was excluded HERE, so an empty crate kept sliding like
        -- ice long after the sealed ones stopped (user, 2026-08-06). Mass and
        -- drag have to travel together or the pair is half a system.
        if e.obj and (isContainer(e) or isHusk(e)) and DoesEntityExist(e.obj) then
            -- DRAG, because prop physics has no friction worth the name and
            -- SetObjectPhysicsParams' damping only bites in the air. The
            -- horizontal velocity is scaled down and zeroed once it is slower
            -- than walking pace. Z IS LEFT ALONE: a crate knocked off a roof
            -- should still fall like one.
            local v = GetEntityVelocity(e.obj)
            local vx, vy, vz = v.x, v.y, v.z
            local speed2 = vx * vx + vy * vy
            if speed2 > 0.0001 then
                local minV = L.crateDragMin or 0.35
                if speed2 < minV * minV then
                    SetEntityVelocity(e.obj, 0.0, 0.0, vz)
                else
                    local k = L.crateDrag or 0.23
                    SetEntityVelocity(e.obj, vx * k, vy * k, vz)
                end
                -- Provable rather than inferred: /brloot prints this, so
                -- "the drag is not running" and "the drag is not enough" can
                -- be told apart without another round of guessing.
                -- SPLIT BY KIND, because "the weight only works on empty
                -- crates" (user, 2026-08-07) is a claim these two counters
                -- settle in one line: if sealed is 0 and husk is not, the
                -- loop is skipping sealed crates; if both move, the drag is
                -- running on both and the difference is somewhere else.
                BR.Loot.dragTicks = (BR.Loot.dragTicks or 0) + 1
                if isHusk(e) then
                    BR.Loot.dragHusk = (BR.Loot.dragHusk or 0) + 1
                else
                    BR.Loot.dragSealed = (BR.Loot.dragSealed or 0) + 1
                end
            end

            -- AND THE SIZE, for the one entry in the match that has one.
            --
            -- A CONTAINER IS A PHYSICS OBJECT AND PHYSICS OWNS THE MATRIX. The
            -- hover pass re-asserts the scale after every rotation write it
            -- makes, but it skips containers by design ("a crate is furniture,
            -- and furniture does not float") -- so an airdrop crate scaled once
            -- at spawn is a crate whose size the next simulation step is free
            -- to throw away. This is the containers' equivalent of that line,
            -- and it runs at 10Hz rather than 60 because a box that is the
            -- wrong size for a sixtieth of a second is a box nobody saw.
            --
            -- COSTS NOTHING WHEN THERE IS NOTHING TO DO: BR.Native.propScale
            -- returns immediately on a nil or 1.0, which is every one of the
            -- ~1300 generated crates.
            applyPropScale(e.obj, e.propScale)

            -- Remember where it ACTUALLY is. This is the only record of the
            -- pose that survives the entry being replaced when the crate
            -- becomes a husk.
            local c = GetEntityCoords(e.obj)
            local r = GetEntityRotation(e.obj, 2)
            local pose = poses[id]
            if pose then
                pose.x, pose.y, pose.z = c.x, c.y, c.z
                pose.rx, pose.ry, pose.rz = r.x, r.y, r.z
            else
                poses[id] = { x = c.x, y = c.y, z = c.z,
                              rx = r.x, ry = r.y, rz = r.z }
            end
        end
    end
end)

BR.Loop.register(BR.Loop.FRAME, 'loot.render', function(dt)
    local frameNow = GetGameTimer()

    -- BEFORE THE EARLY-OUT, and deliberately. A retiring prop is no longer an
    -- entry, so claiming the last item in scope would otherwise leave it
    -- frozen in mid-air forever -- `next(entries)` is false and nothing runs.
    if next(retiring) then stepRetiring(frameNow) end

    if not canSee() or not next(entries) then
        -- NOTHING TO OFFER MEANS NOTHING IS OFFERED. Both of these used to
        -- return with `hold` and the target left exactly as they were, so a
        -- hold begun on the last crate in scope stayed armed with its clock
        -- notionally running, and the target stayed claimable. Neither can
        -- survive the entries going away.
        clearHold(canSee() and 'no loot is streamed in'
                           or 'loot is not visible in this state')
        target = nil
        return
    end

    dt = (dt and dt > 0) and math.min(dt, 100) or 16

    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local glow2  = L.glowDistance * L.glowDistance

    -- ONE CRATE GLOWS: the nearest, and only inside the shine radius.
    --
    -- Every crate in the room lighting up at once was a wall of orange rather
    -- than a signal (user, 2026-08-06). One at a time reads as "this is the
    -- one you are walking towards", which is the only thing the glow is for.
    -- AND ONLY UNTIL THE FIRST ONE IS OPENED. The glow is teaching "these
    -- boxes open"; after that it is a permanent orange marker on furniture.
    -- WHICH crate shines is recomputed at 10Hz, not 60Hz.
    --
    -- This is a full walk of every streamed entry, and it was running once per
    -- FRAME purely to answer a question whose answer changes at walking pace.
    -- At a dense POI that is several hundred distance checks per frame for a
    -- glow that fades over metres -- and it is a prime suspect for the frame
    -- hitching that appeared as the POI count grew (user, 2026-08-06). The
    -- FADE below still runs every frame, so nothing looks any less smooth.
    local shineMax = L.shineDistance or 18.0
    local now = GetGameTimer()
    if now - shineAt >= (L.shineScanMs or 100) then
        shineAt = now
        shineId = nil
        local best = shineMax * shineMax
        if BR.Loot.openedCount < (L.shineOpenLimit or 2) then
            for id, e in pairs(entries) do
                if isContainer(e) and e.gzOk then
                    local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
                    if d2 < best then shineId, best = id, d2 end
                end
            end
        end
    end

    -- ...but the DISTANCE to it is measured fresh every frame, so the fade is
    -- smooth even though the choice of crate is not re-decided.
    local shineD2 = shineMax * shineMax
    if shineId then
        local se = entries[shineId]
        if se then
            shineD2 = BR.Dist2(p.x, p.y, se.x, se.y)
        else
            shineId = nil
        end
    end

    -- FADED BY DISTANCE, not switched at a boundary: full strength stood over
    -- the crate, nothing at all at the rim. The old version was the same
    -- brightness everywhere inside the radius and then simply vanished.
    -- SQUARED, because linear was imperceptible (user, 2026-08-06: "doesn't
    -- really fade, I can't tell the difference"). Halfway to the rim a linear
    -- curve is still at 50% -- which just reads as "on". Squared puts the same
    -- point at 25% and spends most of the radius visibly dying.
    local shineFade = 1.0
    if shineId then
        local t = math.sqrt(shineD2) / shineMax
        if t > 1.0 then t = 1.0 end
        shineFade = (1.0 - t) * (1.0 - t)
    end

    -- A slow, shallow breath. The old pulse swung 0.72..1.0 in under a second,
    -- which read as flashing; this is a fade you notice without being nagged
    -- by it.
    local pulse = 0.55 + 0.20 * math.sin(GetGameTimer() / 900.0)
    local SHINE = L.shineColour or { 255, 150, 30 }

    -- PUT OUT WHATEVER IS LIT AND SHOULD NOT BE, unconditionally and before
    -- anything else. This runs whether or not the crate is still in range,
    -- still a crate, or still anything at all -- which is precisely what the
    -- old in-loop version could not do, and why crates stayed orange for the
    -- rest of the match once you walked away from them or opened them.
    if outlinedId and outlinedId ~= shineId then clearOutline(entries) end

    for id, e in pairs(entries) do
        local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
        -- A husk is scenery. Glowing it would send players across open ground
        -- for a crate somebody already emptied, which is the exact opposite of
        -- what the open-crate model is for.
        --
        -- gzOk gates the DRAWING too, not just the prop: an entry rejected for
        -- standing in the sea still had its rarity disc painted on the waves
        -- (user, 2026-08-06).
        -- AN ARC OUTRANGES THE DRAWING, and it has to. The glow radius is the
        -- right gate for the hover -- nothing 30m away is being offered to
        -- anybody -- but a prop already in the air has to be flown all the way
        -- down whatever happens next. Gated on the same radius, it would be
        -- stranded mid-flight by a player who drove out of range during the
        -- half-second the landing takes, and a frozen object hanging over a
        -- road is forever: nothing else ever moves it.
        if e.arriveAt and d2 > glow2 and not isHusk(e) and e.gzOk then
            animate(e, d2, dt, frameNow)
        end

        if d2 <= glow2 and not isHusk(e) and e.gzOk then
            animate(e, d2, dt, frameNow)
            local gz = groundZ(e)
            local info = BR.RarityInfo[e.rarity] or BR.RarityInfo[BR.Rarity.COMMON]
            local c = info.rgb

            -- NO DISC UNDER A CRATE (user, 2026-08-07: "are you drawing a blue
            -- marker under every unopened crate? We don't need that").
            --
            -- The disc exists to say "something is here" for a loose item,
            -- which is a small prop easily lost in scenery. A crate is a
            -- metre-wide box with an orange outline and a label on the lid --
            -- it announces itself. The disc under it was a third signal for a
            -- thing that already had two, in the RARITY colour, which also
            -- quietly leaked what was inside before it was opened.
            -- THE DISC YIELDS TO THE ITEM ITSELF.
            --
            -- Its whole job is "something is here", answered from across a
            -- room for a small prop lost in scenery. Once the item has risen
            -- to meet you and is turning in the air, that question is already
            -- answered far better than a disc can -- and a marker left burning
            -- under a floating object reads as two things, not one (user call,
            -- 2026-08-08).
            --
            -- Tied to the SAME eased lift the hover uses, so it dies exactly
            -- as the item rises and fades back in over exactly as long as the
            -- item takes to settle. Two curves would drift; one cannot.
            if not isContainer(e) then
                -- ═══ AND THE ONE ENTRY THAT IS *NOTHING BUT* A MARKER (#224)
                --     ═══
                --
                -- A dropped warmup car whose prop the engine would not build has
                -- no object to hover, so the disc is not a hint beside the item
                -- -- it IS the item, and it has to be the marker the owner named
                -- rather than the small flat disc. Drawn at full alpha and at
                -- the entry's own height, because there is nothing to yield to:
                -- the eased fade above exists so the disc dies as the prop rises
                -- to meet you, and here nothing rises.
                --
                -- WHAT MARKER 34 ACTUALLY LOOKS LIKE IS NOT VERIFIED. It is the
                -- number the owner asked for, passed through; two published
                -- versions of this enum have disagreed with the game's own
                -- parser on this project before, so nothing here claims to know
                -- what it draws.
                local mk = e.noProp and fallbackMarkerOf(e) or nil
                if mk then
                    local ms = fallbackMarkerScaleOf(e)
                    DrawMarker(mk, e.x, e.y, gz + 0.05,
                        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        ms, ms, ms,
                        c[1], c[2], c[3], 200,
                        -- Bobbing and camera-facing, which is what makes a
                        -- SYMBOL marker readable where a flat disc is drawn on
                        -- the ground and wants neither.
                        true, true, 2, false, nil, nil, false)
                else
                    local a = math.floor(120 * (1.0 - ease(e.lift or 0.0)))
                    if a > 0 then
                        -- A flat disc rather than a sphere: it reads as
                        -- "something is here" without swallowing the item
                        -- itself.
                        DrawMarker(1, e.x, e.y, gz - 0.05,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            0.45, 0.45, 0.12,
                            c[1], c[2], c[3], a,
                            false, false, 2, false, nil, nil, false)
                    end
                end
            end

            -- CRATES SHINE ORANGE. Always orange, never the rarity colour: the
            -- glow says "a crate is here", and what is inside is not knowable
            -- until it is opened, so colouring it by contents was both a lie
            -- and a second meaning for a channel that already has one (user
            -- call, 2026-08-06).
            --
            -- An OUTLINE carries it, not the light: the world is pinned to
            -- noon, where a light is very nearly invisible -- which is why the
            -- previous version read as no glow at all. The light stays at low
            -- intensity for interiors and storm gloom.
            if isContainer(e) then
                local mine = (id == shineId)
                -- Only the SWITCHING ON lives here now. Switching off is done
                -- once per pass, above, against the id that is actually lit --
                -- see clearOutline and the note on outlinedId for the three
                -- ways this branch used to be skipped while a crate was still
                -- glowing.
                if mine and e.obj and DoesEntityExist(e.obj) then
                    -- The COLOUR is re-sent every frame even when the outline
                    -- is already on: alpha is what carries the distance fade,
                    -- so it has to keep moving as the player walks in. Only
                    -- the on/off flag is latched.
                    if outlinedId ~= id then
                        clearOutline(entries)
                        outlinedId = id
                        SetEntityDrawOutline(e.obj, true)
                    end
                    SetEntityDrawOutlineColor(SHINE[1], SHINE[2], SHINE[3],
                        math.floor((L.shineAlpha or 60) * pulse * shineFade))
                end
                if mine then
                    -- A hint at the crate in front of you, not a floodlight
                    -- down the street -- and it dims to nothing as you back
                    -- away rather than switching off.
                    DrawLightWithRange(e.x, e.y, gz + 0.5,
                        SHINE[1], SHINE[2], SHINE[3],
                        L.shineLightRange or 1.2,
                        (L.shineLightPower or 0.30) * pulse * shineFade)
                end
            end

            -- NO DrawText ANYWHERE IN LOOT any more (user call, 2026-08-06).
            -- The DUI prompt names whatever the player is actually facing,
            -- with real typography and the right key on it; a second, worse
            -- label floating over every item in the room was the engine text
            -- renderer competing with it. The rarity disc is what carries
            -- "something is here" at distance.
        end
    end

    if not canTake() then
        -- The offer goes with the ability to accept it. Leaving `target` set
        -- through a spell of canTake() being false -- in a car, suppressed by
        -- a downed mate, mid-respawn -- leaves a claim armed for an item the
        -- player can no longer legitimately reach.
        clearHold('the player cannot take anything right now')
        target = nil
        setPrompt(nil)
        return
    end

    -- THE HOLD. A crate is a commitment in the open -- a second standing
    -- still, visible to anyone watching the building. The ring is a CSS
    -- animation inside the DUI page, started once from its duration, so it
    -- runs at the browser's own frame rate rather than being stepped from
    -- here.
    local shown = nil
    if hold.id then
        local e = entries[hold.id]
        local reach = e and reachOf(e) or 0.0
        -- THREE WAYS A HOLD ENDS, AND LETTING GO IS THE FIRST OF THEM (#129).
        --
        -- The key check is what makes this a hold rather than a timer with a
        -- keypress in front of it. It is asked HERE, in the same pass that
        -- advances the clock, so there is no arrangement of gates or loop
        -- ordering under which the clock runs and the key is not checked --
        -- which is exactly what the old split between this pass and
        -- loot.interact allowed.
        --
        -- ...BUT LETTING GO IS A KEY THAT HAS BEEN UP FOR A REAL INTERVAL,
        -- NOT A KEY THAT READ UP ONCE, and that distinction is the whole of the
        -- second round of #129: "even after holding I cannot successfully open
        -- any crates" (owner, 2026-08-16). See HOLD_RELEASE_MS -- the grace
        -- extends how long the hold LIVES and adds nothing to what it has
        -- EARNED, because `counting` and not `alive` is what gates the
        -- accumulator two lines down.
        local alive, counting = holdKeyAlive(frameNow)
        if not e
           or BR.Dist2(p.x, p.y, e.x, e.y) > reach * reach
           or not alive then
            -- WHICH OF THE THREE, RECORDED. They look identical on screen --
            -- the ring goes out -- and they point at completely different
            -- files. Worked out here rather than in clearHold so the test can
            -- read the same string the player pastes.
            local why
            if not e then
                why = 'the crate stopped existing'
            elseif BR.Dist2(p.x, p.y, e.x, e.y) > reach * reach then
                why = 'the player walked out of reach'
            else
                why = 'the key was released'
            end
            clearHold(why)
        else
            shown = e
            setPrompt(e, L.chestHoldMs or 1000)

            -- THE DUTY CYCLE, MEASURED WHERE IT IS SPENT. `frames` is every
            -- frame this hold survived; `counted` is the subset that earned
            -- milliseconds. They are equal on a healthy client and that is the
            -- single number #129 has never had: a ring that fills in a second
            -- over a clock that earned a fifth of one is the reported symptom
            -- exactly, and it is invisible without this.
            hold.frames = hold.frames + 1

            -- ...AND THE SAME MEASUREMENT IN MILLISECONDS, which is what the
            -- alarm below compares against `chestHoldMs`. Frames cannot be
            -- compared against a duration: at 20fps a starved hold would take
            -- three times as long to be noticed as at 60.
            hold.aliveMs = hold.aliveMs + dt

            -- Only frames on which the key was down get counted, and `dt` is
            -- already clamped to 100ms above so a stalled frame cannot hand
            -- the player a tenth of a second of credit it did not earn.
            if counting then
                hold.counted = hold.counted + 1
                hold.heldMs = hold.heldMs + dt
            end

            -- THE ALARM. Checked BEFORE the completion test so it can never
            -- fire on a hold that is about to succeed, and it costs two
            -- comparisons on a healthy frame.
            --
            -- IT DOES NOT CANCEL THE HOLD, DELIBERATELY. Ending it here would
            -- be a NINTH way for a hold to die, on a rule about progress rather
            -- than about the player -- and on a client that produces a rising
            -- edge every frame (which is exactly the fault this is here to
            -- catch) the cancel and the restart would fight at 60Hz. The hold
            -- is left exactly as it was and the SILENCE is what gets fixed:
            -- the console says so, /brloot flags the live hold, the session
            -- counter climbs, and the post-mortem carries `starved` into
            -- `lastHold`. A hold that cannot complete can now be seen failing
            -- from four places instead of none.
            local need = L.chestHoldMs or 1000
            if hold.aliveMs >= need and hold.heldMs < need * STARVE_RATIO then
                if not hold.warnedAt then starvedHolds = starvedHolds + 1 end
                if not hold.warnedAt
                   or (frameNow - hold.warnedAt) >= STARVE_WARN_MS then
                    hold.warnedAt = frameNow
                    print(('[br_core] STARVED HOLD on crate #%s: alive %.0fms, '
                        .. 'earned %.0f of %dms on %d of %d frame(s) (%.0f%%). '
                        .. 'The interact key is not reading as HELD on most '
                        .. 'frames -- the ring will fill anyway and the crate '
                        .. 'will not open. Run /brkeys (check `held=`) and '
                        .. '/brprobe rawkey.')
                        :format(tostring(hold.id), hold.aliveMs, hold.heldMs,
                                need, hold.counted, hold.frames,
                                100.0 * hold.counted / math.max(hold.frames, 1)))
                end
            end

            if hold.heldMs >= (L.chestHoldMs or 1000) then
                local id = hold.id
                completions = completions + 1
                clearHold('it completed')
                -- THE GLOW HAS DONE ITS JOB. Counted on the hold completing
                -- rather than on the server's reply: the player has
                -- demonstrably learned the interaction by this point, and a
                -- refused claim (someone beat them to it) taught them just as
                -- well.
                BR.Loot.openedCount = BR.Loot.openedCount + 1
                sendClaim(id, 'crate')
                claimedByMe[id] = GetGameTimer()
                setPrompt(nil)
                shown = nil
            end
        end
    end

    -- THE FRAME'S ONE ANSWER, and everything downstream reads it rather than
    -- asking again. A hold in progress IS the offer -- re-resolving mid-hold
    -- would let the prompt wander onto a nearer item while the ring for the
    -- crate kept filling.
    if hold.id then
        target = shown
    else
        target = targetEntry(ped, p.x, p.y)
        if not shown then
            shown = target
            setPrompt(shown, nil)
        end
    end

    -- DRAWN NATIVELY, EVERY FRAME. This is the half that used to lag: the
    -- prompt is a sprite at a world position, so it is welded to the crate
    -- however fast the camera moves, and nothing crosses the bridge to keep
    -- it there.
    if shown then
        local gz = groundZ(shown)
        -- A CRATE WEARS ITS LABEL; everything else floats one.
        --
        -- On a container the prompt is drawn flat on the lid at a fixed
        -- heading, so it reads as printed on the box and does not swing round
        -- as the player circles it (user, 2026-08-06). Loose items keep the
        -- screen-facing sprite: there is no surface to print on, and a label
        -- lying flat on the ground over a pistol would be unreadable.
        -- ANCHORED TO THE PROP, not to the entry. The registry position is
        -- where the crate was GENERATED; the prop is where it actually is
        -- after settling, or after a car hit it. Passing the entity also hands
        -- the label the crate's full orientation for free.
        if isContainer(shown) and shown.obj and L.crateLabelFlat ~= false
           and DoesEntityExist(shown.obj) then
            BR.Dui.drawOnEntity(promptPage(), shown.obj,
                L.crateLabelSize or 0.55, L.crateLabelLift or 0.02)
        else
            -- No `dist`: a fixed size, not one that inflates on approach.
            --
            -- MEASURED FROM THE ITEM, not from the ground. The prop rises
            -- half a metre when the player is close enough to be offered it,
            -- and the first version added that lift to a FIXED world height --
            -- so the label climbed twice as far as the thing it labels. A
            -- constant gap above the item is what reads as attached.
            -- `shown.lift` is the same eased 0..1 the animation uses, so the
            -- two cannot drift apart.
            local lift = ease(shown.lift or 0.0) * (L.hoverHeight or 0.55)
            BR.Dui.drawWorld(promptPage(), shown.x, shown.y,
                gz + lift + (L.promptLift or 0.75), L.promptScale or 2.0)
        end
    end
end)

-- --------------------------------------------------------------------------
-- Input
-- --------------------------------------------------------------------------

--- Begin an interaction with the item the player is being offered.
---
--- THE OFFER IS READ, NOT RECOMPUTED (#128). This used to call targetEntry()
--- again, on the frame of the keypress, which made it a second opinion about
--- what the player meant -- and a second opinion is exactly what nobody wants
--- from a pickup. With two items in reach the render pass had drawn a prompt
--- for one and this could claim the other, so the item that left the ground was
--- decided by where the crosshair happened to be a sixtieth of a second after
--- the player committed.
---
--- `target` is the entry the prompt on screen is FOR. Acting on it is the whole
--- guarantee: you get what you were shown, or you get nothing.
local function interactPressed()
    if not canTake() then return end

    -- Resolved back through `entries` by id rather than used directly. Opening
    -- a crate REPLACES its entry table with the husk's, so a target held from
    -- last frame can be a table nobody owns any more -- still reading as a
    -- sealed chest, and good for a hold the server would then refuse.
    local e = target and entries[target.id]
    if not e then return end

    if isContainer(e) then
        -- A RISING EDGE THAT ARRIVES WITH THIS HOLD STILL RUNNING IS A RESUME,
        -- NOT A RESTART, AND THAT IS THE WHOLE OF #129's FOURTH ROUND.
        --
        -- The second round established that a hold must survive a frame of key
        -- state that reads UP without the player having let go
        -- (citizenfx/fivem#3064; see HOLD_RELEASE_MS). It bought that with the
        -- release grace, which keeps the hold ALIVE across the bad frame -- and
        -- then this handler threw the progress away on the very next one:
        --
        --   frame 19  isHeld=true   holdMs=304
        --   frame 20  isHeld=false  holdMs=304   <- grace holds the hold open
        --   frame 21  isHeld=true   holdMs=16    <- the re-press restarts it
        --
        -- The bad frame fires a release edge and the frame after it fires a
        -- press edge, because the raw layer derives both from the same sample.
        -- So the grace kept the hold and this call reset its clock, which makes
        -- the grace decorative for the exact case it was written for. Any
        -- source of that pair -- once every 640ms is enough against a 1000ms
        -- hold -- makes a crate structurally impossible to open while leaving
        -- every press-to-pick-up working perfectly, because a press needs ONE
        -- good frame and a hold needs a thousand milliseconds of consecutive
        -- ones. That asymmetry is the reported symptom exactly: loose loot
        -- works (#139), the crate does not (#129).
        --
        -- IT CANNOT RESURRECT A HOLD THE PLAYER ACTUALLY ENDED. `hold.id` is
        -- only still ours because holdKeyAlive has not yet expired the grace --
        -- loot.interact asks it every frame, unconditionally -- so reaching
        -- here with the same id means the key has been up for less than
        -- HOLD_RELEASE_MS. A real release clears the hold, and the press after
        -- it lands on the branch below and starts from zero.
        --
        -- AND IT IS NOT A ROUTE BACK TO PRESS-TO-OPEN. Milliseconds are still
        -- earned only on frames the key reads DOWN (see `counting` in
        -- loot.render), so this hands out no progress whatsoever -- it only
        -- stops progress already earned from being deleted.
        if hold.id == e.id then
            -- Back down, so the grace window starts again from here rather
            -- than from the frame the bad sample arrived on.
            hold.upAt = nil
            holdResumes = holdResumes + 1
            return
        end

        -- The clock starts at zero and is advanced by loot.render, on frames
        -- where the key is still down. Nothing here is a deadline.
        --
        -- clearHold() first so a fresh press cannot inherit the release grace
        -- of the one before it: a hold begun 20ms after the last one was let go
        -- would otherwise start life already counting down towards its own
        -- cancellation.
        clearHold('a fresh hold started on another crate')
        hold.id = e.id
        return
    end

    -- A tap picks up. The rate limit lives on the server; this only stops a
    -- key repeat from spending the player's whole allowance on one item.
    local now = GetGameTimer()
    if now - (claimedAt[e.id] or 0) < 500 then return end
    claimedAt[e.id] = now
    sendClaim(e.id, 'item')
end

BR.Keys.on('interact', function(pressed)
    if not pressed then
        -- LETTING GO STARTS THE CLOCK ON THE RELEASE; IT NO LONGER KILLS THE
        -- HOLD OUTRIGHT ON THE EDGE.
        --
        -- This handler used to clear the hold here and now, on the grounds that
        -- the ring should die on the same frame the key came up rather than on
        -- the next render pass. The problem is that this edge is not proof of a
        -- release: it is fired by the same raw key state that reads UP for a
        -- frame or two around every NUI focus change (citizenfx/fivem#3064 --
        -- see keybinds.lua, where the tap side of this already has a guard).
        -- So the most eager cancel in the file was also the one most easily
        -- fooled, and with the clock now being ACCUMULATED rather than
        -- subtracted, being fooled once costs the whole hold rather than
        -- nothing (#129, owner 2026-08-16: "even after holding I cannot
        -- successfully open any crates").
        --
        -- Stamping instead hands the decision to holdKeyAlive, which the two
        -- frame checks already share, so all three agree by construction. The
        -- cost is that a genuine release takes up to HOLD_RELEASE_MS to put the
        -- ring out instead of one frame -- a tenth of a second, and no progress
        -- accrues in it.
        if hold.id and not hold.upAt then hold.upAt = GetGameTimer() end
        return
    end
    interactPressed()
end)

-- ONE INPUT, AND THE PLAYER'S OWN.
--
-- This used to ALSO poll GTA's context control (51) directly, as a workaround
-- for a label problem: a custom binding's `~INPUT_<hash>~` token renders as a
-- blank hole on this build, and a prompt showing a key that does nothing is
-- worse than no prompt -- so vanilla E was wired up alongside the binding to
-- make the sign honest.
--
-- That workaround is now the bug. With the label read correctly from the
-- keymapping, rebinding interact to R left BOTH R and E working, and E was a
-- ghost key mentioned nowhere (user, 2026-08-08). It also quietly broke this
-- project's oldest standing rule -- no code polls a raw control id -- since
-- nothing a player does in the pause menu could ever turn control 51 off.
--
-- The keymapping is the only input now. BR.Keys owns it, the pause menu
-- configures it, and the prompt names it.
--
-- A THIRD PLACE THE KEY STATE IS CHECKED, AND IT IS UNCONDITIONAL.
--
-- loot.render owns the hold and cancels it on the same pass that advances it,
-- so this is not load-bearing for the ordinary case. It exists for the case
-- loot.render cannot cover: that pass is disableable (/brloop disable
-- loot.render) and returns early whenever the player cannot see or take loot,
-- and a hold left armed across such a spell is a crate that opens the moment
-- the spell ends.
--
-- THE canTake() GATE THAT USED TO BE ON THIS LOOP IS GONE, and it was a hole
-- rather than an optimisation. It made the cancel stop running under exactly
-- the conditions that also stopped loot.render running -- get into a car
-- mid-hold, or have dbno raise the suppression, and NEITHER check ran while
-- the state persisted. Cancelling a hold is never the wrong thing to do.
--
-- IT ASKS THROUGH holdKeyAlive RATHER THAN READING THE KEY ITSELF, which is
-- what makes it a net rather than a competitor. Asked separately, this pass
-- cancelled on the very frame of dropped key state that loot.render's release
-- grace exists to absorb -- so the grace would have been decorative and the
-- hold would still have been unreachable (#129, second round). One answer,
-- three callers, and it can no longer be true in one place and false in
-- another.
BR.Loop.register(BR.Loop.FRAME, 'loot.interact', function()
    if hold.id and not holdKeyAlive(GetGameTimer()) then
        clearHold('the key stayed up past the grace (net check)')
    end
end)

-- --------------------------------------------------------------------------
-- Debug
-- --------------------------------------------------------------------------

-- --------------------------------------------------------------------------
-- Dev: loot blips
-- --------------------------------------------------------------------------

-- OFF BY DEFAULT AND NEVER ON IN A REAL MATCH. A blip per item is a wallhack
-- with a nice interface; this exists so a developer can find the crate they
-- are trying to debug. /brlootblips toggles it.
local blipsOn = false
local blips   = {}   -- [id] = handle

-- THE MERCY BLIPS.
--
-- A player who lands somewhere empty and spends a minute finding nothing has no
-- way to tell "there is no loot here" from "this mode is broken" -- and the
-- second conclusion is the one they act on. So after a minute empty-handed the
-- crates near them go on the map, with a notice saying so (user, 2026-08-05).
--
-- ONCE PER MATCH, AND THAT IS THE WHOLE LIFECYCLE. This mode has no second
-- life: the only way back onto your feet is a revive, so there is no per-life
-- anything to reason about, and four fields say all of it.
--
--   * `done` is the latch, and it must exist. The expiry works fine; what did
--     not was the very NEXT pass, where `on` is false, control falls into the
--     arming test `now - landedAt >= afterMs` -- still true, and true forever --
--     and re-arms. They re-armed a second later, every second, indefinitely
--     (user, 2026-08-07: "courtesy loot blips don't remove after 1 minute" --
--     they were removed, and immediately put back). Nothing but a new match
--     reopens it, which is the one reset below.
--   * `landedAt` is the grace clock, and it counts an UNBROKEN minute ON YOUR
--     FEET. Every pass spent off them restarts it. That is what stops the map
--     lighting up and the toast firing on the frame a revived player gets their
--     weapon back -- the middle of the fight they just lost (owner, 2026-08-18):
--     the clock used to keep running through the bleed and the pickup, so they
--     stood up into a window that had expired while they were unconscious.
--     Restarting it is not a latch reset and costs them nothing but the wait
--     they would have had anyway; they still get the help if the map really is
--     empty. The old answer was to close the window outright on a knock, which
--     denied the help for the rest of the match to exactly the player who had
--     the best reason to doubt the mode.
--   * `armedAt` is when the window opened, and `on` is presentation -- whether
--     the blips are drawn right now. Player state decides `on` and nothing else.
local mercy = { landedAt = 0, armedAt = 0, on = false, done = false }

-- THE ONE RESET: a new match.
--
-- The same edge this file already forgets its entries on, because it is the
-- same fact -- that match is over, drop what we knew about it. It is also the
-- match transition a client is guaranteed to see: client/state.lua replays
-- WAITING locally off both the digest and the snapshot precisely so that every
-- subsystem's teardown still runs when the scoped broadcast cannot reach it.
-- The start-of-match edge carries no such guarantee -- a player attached to a
-- match ALREADY in warmup never hears the transition into it.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if not d then return end
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        mercy.landedAt, mercy.armedAt = 0, 0
        mercy.on, mercy.done = false, false
    end
end)

local function clearBlips()
    for id, b in pairs(blips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
        blips[id] = nil
    end
end

-- The mercy timer. Separate from the drawing below so the dev toggle and the
-- automatic help share one blip implementation.
BR.Loop.register(BR.Loop.SLOW, 'loot.mercy', function()
    local cfg = L.mercyBlips
    if not cfg or not cfg.enabled then return end
    if mercy.done then return end

    local afoot = BR.State.me.state == BR.PlayerState.ALIVE
    local now   = GetGameTimer()

    -- "HAS THIS PLAYER FOUND ANYTHING" INCLUDES OPENING A CRATE, which puts
    -- nothing in the inventory -- it SCATTERS the contents on the ground. Read
    -- as BR.Inv.lastGainAt alone, a player who burst a crate open and then got
    -- into a fight still counted as empty-handed and had the map lit up for them
    -- anyway (user, 2026-08-08). openedCount is the honest signal and the glow
    -- already maintains it.
    local gained = (BR.Inv and BR.Inv.lastGainAt or 0) > 0
                or (BR.Loot.openedCount or 0) > 0

    if mercy.armedAt == 0 then
        -- The window has not opened. It counts an unbroken minute on their feet,
        -- so time spent off them is not spent towards it: see the header.
        if not afoot then
            mercy.landedAt = 0
            return
        end
        if mercy.landedAt == 0 then mercy.landedAt = now end
        -- Only for someone who has actually found nothing. Picking anything up
        -- before the timer means they know how this works.
        if gained or now - mercy.landedAt < (cfg.afterMs or 60000) then return end
        mercy.armedAt = now

        -- THE NOTICE SAYS HOW LONG IT LASTS (user call, 2026-08-06). Help that
        -- vanishes without warning reads as a bug; help with a stated duration
        -- reads as a grace period, and the player knows to use it now. Derived
        -- from the config so retuning minShownMs cannot leave the text lying.
        local mins = (cfg.minShownMs or 60000) / 60000.0
        local howLong
        if mins >= 2.0 then
            howLong = ('%d minutes'):format(math.floor(mins + 0.5))
        elseif mins >= 1.0 then
            howLong = '1 minute'
        else
            howLong = ('%d seconds'):format(
                math.floor((cfg.minShownMs or 60000) / 1000 + 0.5))
        end
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = ('No loot nearby? Crates are marked on your map for %s.')
                :format(howLong),
            tone = 'info', ms = 8000,
        })
    end

    -- Open. Drawing follows the player -- downed, dead, spectating, no blips --
    -- and the clock underneath carries on regardless.
    mercy.on = afoot

    -- EITHER, not both (user correction, 2026-08-05): they go away as soon as
    -- something has been found, or after the timeout, whichever comes first.
    -- Help that outstays the problem is just a wallhack left switched on.
    if gained or now - mercy.armedAt >= (cfg.minShownMs or 60000) then
        mercy.on, mercy.done = false, true   -- and never again this match
    end
end)

BR.Loop.register(BR.Loop.SLOW, 'loot.devblips', function()
    if not blipsOn and not mercy.on then
        if next(blips) then clearBlips() end
        return
    end

    for id, e in pairs(entries) do
        -- An opened crate loses its blip outright rather than turning white:
        -- a map full of "already looted" markers is noise you have to read
        -- past to find the ones that matter (user, 2026-08-05).
        if isHusk(e) then
            if blips[id] then
                if DoesBlipExist(blips[id]) then RemoveBlip(blips[id]) end
                blips[id] = nil
            end
        elseif not blips[id] or not DoesBlipExist(blips[id]) then
            local b = AddBlipForCoord(e.x, e.y, e.gz or e.z or 0.0)
            -- 457 is the briefcase (user call, 2026-08-07): a courtesy blip is
            -- saying "there is loot over there", and a briefcase reads as loot
            -- at a glance where the generic 68 did not.
            SetBlipSprite(b, isContainer(e) and 457 or 1)
            SetBlipScale(b, isContainer(e) and 0.7 or 0.45)
            SetBlipColour(b, 5)
            SetBlipAsShortRange(b, true)
            -- NAMED, or GTA names it for us -- and it names a sprite by
            -- whatever mission it was drawn for, so the pause-menu legend
            -- read as something from a heist (user, 2026-08-09). Funny once.
            BR.Native.blipName(b, isContainer(e) and 'Supply Crate' or 'Loot')
            blips[id] = b
        end
    end
    for id, b in pairs(blips) do
        if not entries[id] then
            if DoesBlipExist(b) then RemoveBlip(b) end
            blips[id] = nil
        end
    end
end)

-- POI blips, so "where are the points of interest" is answerable without
-- reading the config. Dev only, and off by default -- it is the whole map.
local poiBlips = {}

RegisterCommand('brpois', function()
    if next(poiBlips) then
        for _, b in ipairs(poiBlips) do
            if DoesBlipExist(b) then RemoveBlip(b) end
        end
        poiBlips = {}
        print('[br_core] POI blips off')
        return
    end

    -- Colour by tier, so the density question ("why is there so much loot
    -- here") is answerable at a glance: 3 = hot drop, 1 = rural filler.
    local byTier = { [1] = 2, [2] = 5, [3] = 1 }   -- green, yellow, red
    for _, poi in ipairs(BR.Config.Map.POIs) do
        local b = AddBlipForCoord(poi.x, poi.y, poi.z)
        SetBlipSprite(b, 1)
        SetBlipColour(b, byTier[poi.tier] or 0)
        SetBlipScale(b, 0.9)
        SetBlipAsShortRange(b, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(
            ('[T%d] %s'):format(poi.tier, poi.name))
        EndTextCommandSetBlipName(b)
        poiBlips[#poiBlips + 1] = b

        -- The radius too: the crate budget is spread across THIS disc, so the
        -- circle is the answer to "why is it all in one corner".
        local r = AddBlipForRadius(poi.x, poi.y, poi.z, poi.radius)
        SetBlipColour(r, byTier[poi.tier] or 0)
        SetBlipAlpha(r, 60)
        poiBlips[#poiBlips + 1] = r
    end

    print(('[br_core] POI blips ON -- %d points of interest')
        :format(#BR.Config.Map.POIs))
    print('  red = tier 3 (hot drop), yellow = tier 2, green = tier 1 (rural)')
    print('  the shaded circle is the radius the crate budget spreads across')
end, false)

RegisterCommand('brlootblips', function()
    blipsOn = not blipsOn
    if not blipsOn then clearBlips() end
    print(('[br_core] loot blips %s (%d entries in scope)')
        :format(blipsOn and 'ON' or 'off', (function()
            local n = 0
            for _ in pairs(entries) do n = n + 1 end
            return n
        end)()))
end, false)

--- Spawn a crate two metres in front of the ped. Dev mode only (the server
--- refuses otherwise) -- this is the one you want when debugging, because you
--- can see the thing land.
RegisterCommand('brcrate', function(_, args)
    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local f   = GetEntityForwardVector(ped)
    TriggerServerEvent(BR.Net.LOOT_DEV, {
        item = args[1],
        x = p.x + f.x * 2.0,
        y = p.y + f.y * 2.0,
        z = p.z,
    })
    print(('[br_core] asked the server for %s'):format(args[1] or 'a crate'))
end, false)

--- Everything this client knows about the loot around it.
RegisterCommand('brloot', function()
    local p = GetEntityCoords(PlayerPedId())
    local cx, cy = BR.LootCellOf(p.x, p.y)
    local n, objs = 0, 0
    for _, e in pairs(entries) do
        n = n + 1
        if e.obj then objs = objs + 1 end
    end
    print('=== loot (client) ===')
    print(('  cell %d,%d   entries %d   props %d   queued %d')
        :format(cx, cy, n, objs, #queue))
    local near = nearestEntry(p.x, p.y, 50.0)
    if near then
        print(('  nearest: #%d %s (%s) at %.1fm')
            :format(near.id, labelOf(near), near.kind,
                    BR.Dist(p.x, p.y, near.x, near.y)))
    else
        print('  nothing within 50m')
    end

    -- PROOF THE DRAG IS RUNNING. This counter increments on every tick that
    -- actually scaled a crate's velocity, so "the drag is not running" and
    -- "the drag is not strong enough" are two different readings rather than
    -- one guess. It was 0 for as long as the drag sat on the 1Hz band and
    -- nobody could tell (user, 2026-08-06).
    print(('  crate drag: %d applications (sealed %d, husk %d), k=%.2f, floor %.2f m/s')
        :format(BR.Loot.dragTicks or 0, BR.Loot.dragSealed or 0,
                BR.Loot.dragHusk or 0, L.crateDrag or 0.0, L.crateDragMin or 0.0))
    -- And how many of each are physical right now, so "no sealed crate was
    -- ever dragged" can be told from "no sealed crate was ever pushed".
    local nSealed, nHusk = 0, 0
    for _, e in pairs(entries) do
        if e.obj then
            if isHusk(e) then nHusk = nHusk + 1
            elseif isContainer(e) then nSealed = nSealed + 1 end
        end
    end
    print(('  crate props live: %d sealed, %d husk'):format(nSealed, nHusk))

    -- PROOF THE COLLISION WAIT IS RUNNING, and which of its three failures is
    -- the one in front of you (owner, 2026-08-23: a crate "spawning at ground
    -- level inside a building"). See BR.Loot.settle.
    local s = BR.Loot.settle
    print(('  collision wait: %d held (%d loaded, %d timed out), last %dms, '
           .. 'worst %dms, budget %dms')
        :format(s.waits, s.loaded, s.timedOut, s.lastMs, s.maxMs,
                L.collisionWaitMs or 0))
    print(('    re-seated after the stream: %d (last moved %+.1fm)')
        :format(s.reseated, s.lastLift))

    -- PROOF THE ARC IS RUNNING, for exactly the reason the drag line above
    -- exists. `born 12, flew 0` is the shape the missing arc had for as long as
    -- it has existed, with nothing anywhere to say so; /brarc is the full
    -- readout and the live test.
    local arc = BR.Loot.arc
    print(('  arrival arc: %d born, %d armed, %d too late, %d flew  (/brarc)')
        :format(arc.born, arc.armed, arc.late, arc.flights))
    print(('  crate mass: %.0f kg  (glow off after %d opened; %d opened)')
        :format(L.crateMass or 0.0, L.shineOpenLimit or 0, BR.Loot.openedCount or 0))

    -- WHAT IS BEING OFFERED, AND WHAT ELSE IS IN REACH (#128).
    --
    -- The whole claim of the fix is "exactly one thing is pickable, and it is
    -- the nearest eligible one". That is not visible from a screenshot -- one
    -- prompt on screen looks the same whether the second item is live or not --
    -- so it is printed. Stand facing two items and read the list: every line is
    -- something the old code could have claimed, and exactly one carries the
    -- arrow.
    local ped = PlayerPedId()
    if target then
        print(('  offering:  #%d %s (%s) at %.2fm')
            :format(target.id, labelOf(target), target.kind,
                    BR.Dist(p.x, p.y, target.x, target.y)))
    else
        print('  offering:  nothing')
    end
    local cands = 0
    for _, e in pairs(entries) do
        if not isHusk(e) then
            local reach = reachOf(e)
            local d = BR.Dist(p.x, p.y, e.x, e.y)
            if d <= reach then
                local look = isContainer(e) or facing(ped, p.x, p.y, e)
                cands = cands + 1
                print(('    %s #%-5d %-18s %5.2fm  reach %.1fm  %s')
                    :format((target and target.id == e.id) and '->' or '  ',
                            e.id, labelOf(e), d, reach,
                            look and 'faced' or 'not faced'))
            end
        end
    end
    if cands == 0 then print('    (nothing within reach)') end

    -- THE HOLD, LIVE. `heldMs` only advances on frames the key reads down, so
    -- watching it climb and then reset on release is the whole of #129.
    --
    -- THE `STARVED` MARKER IS THE LINE THAT WOULD HAVE ENDED THIS IN ONE PASTE.
    -- `0/1000ms` on its own is ambiguous -- it is what a hold that has not
    -- started yet prints too, and the owner's paste of exactly that was read as
    -- "the hold has not begun" for six rounds. The marker says the hold IS
    -- running, HAS outlived its own duration, and has earned nothing.
    print(('  hold:      %s  %.0f/%dms   key down: %s%s')
        :format(hold.id and ('#' .. hold.id) or '-',
                hold.heldMs or 0.0, L.chestHoldMs or 1000,
                tostring(BR.Keys.isHeld('interact')),
                hold.warnedAt
                    and ('   *** STARVED: %.0fms alive, %d of %d frame(s) '
                         .. 'earning ***'):format(hold.aliveMs, hold.counted,
                                                  hold.frames)
                    or ''))

    -- ...AND WHICH MECHANISM IS ANSWERING "key down", WHICH IS THE LINE THAT
    -- WOULD HAVE SETTLED THE SECOND ROUND OF #129 IN ONE PASTE.
    --
    -- There are three, they behave differently, and the readout above cannot
    -- tell them apart: the raw layer's per-frame LEVEL sample (the good one),
    -- the raw layer's single-frame EDGE fallback on a build without
    -- IS_RAW_KEY_DOWN (on which the accumulator can never reach its threshold,
    -- because the key reads down on one frame in sixty), and the engine's own
    -- +brinteract / -brinteract pair. The first report said only "I cannot open
    -- crates", which is the same sentence for all three -- so this prints the
    -- source, and the key it is actually watching, next to the counter.
    local via
    if not BR.Keys.rawActive then
        via = 'engine +/- binding (raw layer off)'
    elseif BR.Keys.rawHolds then
        via = 'raw layer, level sample (IsRawKeyDown)'
    else
        via = 'engine +/- binding (raw layer has no IsRawKeyDown)'
    end
    local label = BR.Keys.labelFor('brinteract')
    print(('  hold key:  %s   via %s'):format(label or '(engine default)', via))
    print(('  release grace %dms -- the hold survives a dropped frame of key '
        .. 'state, and earns nothing during it'):format(HOLD_RELEASE_MS))
    -- THE COUNT THAT SAYS WHETHER THE FOURTH ROUND'S FIX IS DOING ANYTHING
    -- HERE. A rising edge arriving on a hold that is already running is the
    -- key state having dropped a frame the player never let go of. Each one
    -- used to reset the clock to zero, so on a client that produces them
    -- faster than chestHoldMs the crate could never be opened at all.
    --
    --   0 and the crate opens   nothing to see; this client is clean.
    --   >0 and the crate opens  they happen and are being absorbed.
    --   0 and it does NOT open  this is not the fault -- look somewhere else.
    print(('  key dropped a frame mid-hold %d time(s) this session '
        .. '(each one used to restart the clock)'):format(holdResumes))
    -- THE COUNTER THAT SAYS "STOP LOOKING AT THE LOOT CODE" (#129, seventh
    -- round). A starved hold is one that outlived `chestHoldMs` without
    -- earning half of it: alive, ring filling, clock going nowhere. That state
    -- was completely silent for six rounds -- it printed `0/1000ms`, which is
    -- also what a hold that has not begun prints -- and it is the state the
    -- owner was actually in.
    --
    --   0                        no hold has ever failed this way here.
    --   >0 and crates open       a hold was interrupted; not the key layer.
    --   >0 and crates NEVER open the interact key is not reading as HELD.
    --                            /brkeys `held=`, then /brprobe rawkey.
    print(('  starved    %d hold(s) outlived %dms without earning half of it')
        :format(starvedHolds, L.chestHoldMs or 1000))

    -- ====================================================================
    -- THE THREE FACTS THE RING CANNOT TELL YOU (#129, sixth round).
    --
    -- Five rounds were spent arguing about the key layer because the only
    -- thing anybody could see was an orange ring, and the ring is a CSS
    -- animation started ONCE with `chestHoldMs` as its duration -- it fills
    -- over that duration whether or not the clock underneath it is moving,
    -- and it resets on release because the next prompt carries no duration.
    -- So "the ring filled" is compatible with every one of:
    --
    --   the clock was starved and never finished       -> `last hold` below
    --   the clock finished and no claim went out       -> `completed` vs `claims`
    --   the claim went out and the server ignored it   -> `last claim` below
    --   the server acted and the world did not show it -> `last claim` answered
    --
    -- Each line below separates one of those from the next. Read them in
    -- order; the first one that reads wrong is the half to look in.
    -- ====================================================================
    print('  --- what the hold actually did ---')

    if lastHold then
        local pct = (lastHold.frames > 0)
            and (100.0 * lastHold.counted / lastHold.frames) or 0.0
        print(('  last hold  #%s reached %.0f of %dms')
            :format(tostring(lastHold.id), lastHold.best, L.chestHoldMs or 1000))
        -- THE DUTY CYCLE. 100% means the clock ran at wall-clock speed and
        -- the ring told the truth. Anything well below it means the ring
        -- finished while the clock was still a fraction of the way there --
        -- which looks exactly like a crate that refuses to open.
        print(('             %d frame(s) alive, %d earned time  (%.0f%%)')
            :format(lastHold.frames, lastHold.counted, pct))
        print(('             it ended because %s'):format(lastHold.why))
        -- AND WHETHER IT WAS EVER GOING TO END ANY OTHER WAY. "it ended
        -- because the key was released" is a true and completely misleading
        -- sentence about a hold that had already been alive for four seconds
        -- earning nothing -- it points at the release path, which is where
        -- five rounds went. This line says the release was not the problem.
        if lastHold.starved then
            print(('             AND IT WAS STARVED: alive %.0fms, earned %.0f. '
                .. 'It was never going to complete.')
                :format(lastHold.aliveMs or 0.0, lastHold.best))
        end
    else
        print('  last hold  (none started yet this session)')
    end

    print(('  completed  %d hold(s) crossed %dms this session')
        :format(completions, L.chestHoldMs or 1000))
    print(('  claims     %d sent this session (crates and loose items)')
        :format(claimsSent))

    if lastClaim then
        local ago = (GetGameTimer() - lastClaim.at) / 1000.0
        if lastClaim.answeredAt then
            print(('  last claim #%s (%s) sent %.1fs ago -- SERVER ACTED %.1fs later')
                :format(tostring(lastClaim.id), lastClaim.kind, ago,
                        (lastClaim.answeredAt - lastClaim.at) / 1000.0))
        else
            -- THE LINE THAT SPLITS THE CLIENT FROM THE SERVER. A claim with
            -- no answer left this machine and produced nothing: the server
            -- either never received it or refused it without saying so.
            print(('  last claim #%s (%s) sent %.1fs ago -- NO ANSWER FROM THE SERVER')
                :format(tostring(lastClaim.id), lastClaim.kind, ago))
        end
    else
        print('  last claim (nothing has ever been claimed this session)')
    end
end, false)

--- Change the crate hold duration live, the same way /brlabel and /brshine
--- change their numbers.
---
--- It exists because #129 arrived with a number attached that the config does
--- not have: the owner described "opening after 3 seconds" and
--- BR.Config.Loot.chestHoldMs is 1000. That gap is not worth another round
--- trip -- stand at a crate, try a value, and paste the one that feels right
--- into br_lib/config/loot.lua. Client-local and not persisted, so a restart
--- puts the configured value back.
RegisterCommand('brcratehold', function(_, args)
    local ms = tonumber(args[1])
    if ms then
        -- Floored rather than rejected: a hold of zero is a tap, which is the
        -- exact behaviour #129 exists to remove, and shipping a debug command
        -- that can reintroduce it is asking for it back.
        L.chestHoldMs = math.max(100, math.floor(ms))
        -- Any hold in flight was measured against the old number.
        clearHold('the hold duration was retuned')
        lastPrompt.id, lastPrompt.hold = nil, nil
    end
    print(('[br_core] crate hold = %dms   (usage: brcratehold <ms>)')
        :format(L.chestHoldMs or 1000))
end, false)

--- Tune the CRATE SHINE without a deploy -- the same ruler as /brlabel, for
--- the orange glow.
---
---   /brshine                  show the current numbers
---   /brshine <name> <value>   set one of them, live
---
--- It exists for the same reason /brlabel does. The glow has been called "too
--- bright" once and "not what it was" once (user, 2026-08-06 and 2026-08-09),
--- and both times the conversation was about a number nobody could see. Stand
--- next to a crate, move it until it looks right, and paste the printed line
--- into br_lib/config/loot.lua. Client-local and not persisted.
local SHINE_TUNABLE = {
    alpha    = 'shineAlpha',       -- outline alpha at the crate, 0-255
    range    = 'shineLightRange',  -- metres of cast light
    power    = 'shineLightPower',  -- light intensity at the crate
    distance = 'shineDistance',    -- metres at which a crate starts to glow
    limit    = 'shineOpenLimit',   -- crates you may open before it stops
}

RegisterCommand('brshine', function(_, args)
    local name = tostring(args[1] or '')
    local value = tonumber(args[2])
    local field = SHINE_TUNABLE[name]

    if field and value then
        L[field] = value
        print(('[br_core] %s = %s'):format(field, tostring(value)))
    elseif name ~= '' and not field then
        print(('[br_core] no such shine value: %s'):format(name))
    end

    print('=== crate shine ===')
    print(('  colour   %d %d %d  (%s)'):format(
        (L.shineColour or {})[1] or 255, (L.shineColour or {})[2] or 150,
        (L.shineColour or {})[3] or 30, tostring(L.shineHex)))
    for k, f in pairs(SHINE_TUNABLE) do
        print(('  %-8s %s'):format(k, tostring(L[f])))
    end
    print('  paste into br_lib/config/loot.lua:')
    print(('    shineAlpha      = %s,'):format(tostring(L.shineAlpha)))
    print(('    shineLightRange = %s,'):format(tostring(L.shineLightRange)))
    print(('    shineLightPower = %s,'):format(tostring(L.shineLightPower)))
    print('  usage: brshine alpha|range|power|distance|limit <value>')
end, false)

--- Tune the crate label WITHOUT a deploy.
---
---   /brlabel                  show the current numbers
---   /brlabel <lift>           metres relative to the lid (negative = down)
---   /brlabel <lift> <size>    ...and the label width in metres
---
--- This exists because the lift has now been guessed twice from outside the
--- game -- 0.02 floated it, -0.10 sank it into the box -- and each guess cost
--- a deploy and a playtest round to evaluate (user, 2026-08-06). Stand at a
--- crate, nudge it until it sits on the plywood, and paste the printed line
--- into br_lib/config/loot.lua. Client-local and not persisted: it is a ruler,
--- not a setting.
RegisterCommand('brlabel', function(_, args)
    local lift = tonumber(args[1])
    local size = tonumber(args[2])
    if lift then L.crateLabelLift = lift end
    if size then L.crateLabelSize = size end

    print(('[br_core] crate label: lift %.3f  size %.2f  fit %.2f')
        :format(L.crateLabelLift or 0.0, L.crateLabelSize or 0.0,
                L.crateLabelFit or 0.45))
    if lift or size then
        print(('  paste into br_lib/config/loot.lua:'))
        print(('    crateLabelLift  = %.3f,'):format(L.crateLabelLift or 0.0))
        print(('    crateLabelSize  = %.2f,'):format(L.crateLabelSize or 0.0))
    else
        print('  usage: brlabel <lift> [size]   (lift is metres, negative = down)')
    end
end, false)

--- Resize a consumable's ground prop WITHOUT a deploy -- the ruler /brlabel is,
--- pointed at #166.
---
---   /brpropscale                     what every consumable is drawn at
---   /brpropscale <itemId> <k>        set one, live, and rebuild its props
---
--- It exists because the number in br_lib/config/loot.lua is a guess and there
--- is no way to evaluate it except by standing next to one. The owner asked for
--- "50% the size"; whether 0.5 reads as a smaller shield or as a dropped pill
--- is a question about a rendered model, and this project has already paid for
--- guessing at those twice (the crate label lift, 0.02 then -0.10).
---
--- IT ALSO ANSWERS "DID ANYTHING HAPPEN AT ALL", which is the first thing to
--- check: GTA V has no entity-scale native and applyPropScale drives the
--- transform matrix instead, so if the props do not change size at any value
--- the matrix route does not work on this build and the answer is a smaller
--- MODEL rather than a smaller number.
---
--- Client-local and not persisted: a restart puts the configured value back.
--- THE AIRDROP'S THREE SIZES ANSWER TO THE SAME RULER, and they had to, because
--- they are the reason the question "does the matrix scale render at all" is
--- suddenly worth five numbers rather than one. Their scales live on
--- BR.Config.Airdrop rather than on a consumable row, so the setter has to know
--- which table an id belongs to -- this is that lookup, and the field name is
--- carried so the line printed for pasting names the right key.
local AIRDROP_SCALES = {
    volts       = { key = 'voltsScale', prop = 'voltsProp', label = 'Volts pile' },
    airdrop     = { key = 'crateScale', prop = 'crateProp', label = 'Airdrop crate' },
    airdrophusk = { key = 'huskScale',  prop = 'huskProp',  label = 'Airdrop husk' },
}

RegisterCommand('brpropscale', function(_, args)
    local id = args[1] and tostring(args[1]) or nil
    local k  = tonumber(args[2])

    if id and k then
        -- Floored well above zero: a scale of 0 is an invisible item, which is
        -- indistinguishable from loot that failed to spawn -- the exact
        -- confusion this file has burned rounds on.
        k = math.max(0.05, k)

        local drop = AIRDROP_SCALES[id]
        local c    = BR.Config.ConsumableById[id]
        local where, field
        if drop and BR.Config.Airdrop then
            BR.Config.Airdrop[drop.key] = k
            where, field = 'br_lib/config/airdrop.lua', drop.key
        elseif c then
            c.propScale = k
            where, field = 'br_lib/config/loot.lua', 'propScale'
        else
            print(('[br_core] no such scalable item: %s'):format(id))
            return
        end

        -- REBUILT, NOT RETUNED IN PLACE. The scale is cached on the entry at
        -- spawn, and loot.props re-queues anything in range that has no prop --
        -- so dropping the object is the whole of the refresh.
        local n = 0
        for _, e in pairs(entries) do
            if e.item == id and e.obj then despawn(e) n = n + 1 end
        end
        print(('[br_core] %s scale = %.2f  (%d prop(s) rebuilding)')
            :format(id, k, n))
        print(('  paste into %s:'):format(where))
        print(('    %s = %.2f,'):format(field, k))
        return
    end

    print('=== prop scale ===')
    for _, c in ipairs(BR.Config.Consumables) do
        print(('  %-12s %-16s %s  x%.2f')
            :format(c.id, c.label, tostring(c.prop), c.propScale or 1.0))
    end
    local A = BR.Config.Airdrop
    if A then
        for _, id in ipairs({ 'volts', 'airdrop', 'airdrophusk' }) do
            local d = AIRDROP_SCALES[id]
            print(('  %-12s %-16s %s  x%.2f')
                :format(id, d.label, tostring(A[d.prop]), A[d.key] or 1.0))
        end
        -- The canopy is not a loot entry and has no id to rebuild, so it is
        -- reported rather than offered: it is built by client/airdrop.lua and
        -- only exists while something is falling.
        print(('  %-12s %-16s (falling only)  x%.2f')
            :format('chute', 'Cargo canopy', A.chuteScale or 1.0))
    end
    print('  usage: brpropscale <itemId> <scale>   (1.0 = as authored)')
end, false)

--- Which prompt glyph actually renders.
---
--- PLAN.md records that ~INPUT_<hash>~ for a RegisterKeyMapping binding drew
--- as a HOLE on this build, which is why the bus prompt fell back to a vanilla
--- token. This prints both so one in-game look settles which to ship -- and
--- either way the KEY is the player's own binding; only the picture changes.
RegisterCommand('brpromptcheck', function()
    local custom = BR.Native.inputForCommand('brinteract')

    -- WHAT THE DUI WILL ACTUALLY PRINT. The token test below is about the
    -- native HELP TEXT glyph; this is the separate question of whether we can
    -- read back the letter a player has rebound `brinteract` to. If the
    -- "bound" line disagrees with what you set in Settings > Key Bindings,
    -- the prompt is lying and keyLabelForCommand needs another approach.
    -- WHICH FORM ANSWERED IS THE WHOLE DIAGNOSTIC. The first version printed
    -- the label and the vanilla fallback side by side, and for `brinteract`
    -- both said E -- one because the lookup missed, the other because E is
    -- the vanilla context key. Two columns agreeing by coincidence hid the
    -- bug for a round, so the SOURCE is printed now.
    print('=== prompt key label (what the DUI shows) ===')
    for _, cmd in ipairs({ 'brinteract', 'brdrop', 'brinventory', 'bruse' }) do
        local label, via = BR.Native.keyLabelForCommand(cmd, L.promptControl or 51)
        print(('  %-12s %-6s  via %s'):format(
            cmd, tostring(label or '(none)'), tostring(via or 'nothing')))
    end
    print('  "via +brXXX" or "via brXXX" = the player\'s own binding.')
    print('  "via vanilla" = we could not read it and fell back to control 51.')

    print('=== prompt tokens ===')
    print(('  custom  %s'):format(custom))
    print('  vanilla ~INPUT_CONTEXT~')
    print('  showing the custom token for 6s, then the vanilla one')
    Citizen.CreateThread(function()
        BR.Native.help(('CUSTOM: press %s to pick up'):format(custom))
        Citizen.Wait(6000)
        BR.Native.help('VANILLA: press ~INPUT_CONTEXT~ to pick up')
    end)
end, false)

--- DOES THE ARRIVAL ARC ACTUALLY RUN?
---
--- Owner, 2026-08-23: "The loot doesn't animate out of the crate like it
--- should. This is a more common issue than just airdrops."
---
--- It did not, anywhere, ever -- and the reason that went unnoticed for so long
--- is that there was no way to ask. An item that pops into existence and an item
--- whose arc ran for two frames at a quarter of a metre look identical from a
--- chair, and both look identical to an origin the server never sent. So this
--- drops one item with a KNOWN origin and reports, link by link, how far down
--- the chain it got:
---
---   origin   the entry arrived carrying fx/fy/fl at all
---   prop     a body was built for it, and how long that took
---   armed    ...while the arrival window was still open. THIS is the link that
---            was broken: the prop always arrived after it had shut.
---   flew     the arrival branch in animate() actually drew frames, and how far
---            off its resting height it got
---
--- The counters above the test are the same links tallied for REAL containers
--- opened in play since this resource started, so "the test drop arcs" and "a
--- crate bursting arcs" stay two readings rather than one hopeful inference.
---
--- The test entry is client-local with a NEGATIVE id -- every server id is
--- positive and the server has never heard of this one -- and it removes itself
--- once the verdict is printed.
local arcTestId = 0

RegisterCommand('brarc', function()
    local a = BR.Loot.arc
    print('=== arrival arc ===')
    print(('  window %dms, grace %dms, height %.2fm')
        :format(L.arriveMs or 520, L.arriveGraceMs or 3000, L.arriveArc or 0.55))
    print(('  in play: %d born with an origin, %d armed, %d too late, %d flew')
        :format(a.born, a.armed, a.late, a.flights))
    if a.lastBuildMs then
        print(('  last arrival: prop built %dms after the announce, %d frame(s), peak %.2fm')
            :format(a.lastBuildMs, a.lastFrames, a.lastPeak))
    end

    if not canSee() then
        print('  the test needs loot to be visible: stand on the warmup pad or in a match')
        return
    end

    -- WHERE A CRATE WOULD BE, AND WHERE ITS CONTENTS LAND. Two metres ahead and
    -- a couple to the side, which is roughly the geometry scatter() produces for
    -- a real chest. A test that dropped the item onto its own origin would prove
    -- nothing: a zero-length arc looks exactly like no arc.
    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local f   = GetEntityForwardVector(ped)
    local ox, oy = p.x + f.x * 2.0, p.y + f.y * 2.0
    local tx, ty = ox + f.y * 1.6, oy - f.x * 1.6

    local item = BR.Config.Consumables[1]
    if not item then
        print('  no consumable in the config to drop')
        return
    end

    arcTestId = arcTestId - 1
    local id = arcTestId
    local before = { armed = a.armed, late = a.late, flights = a.flights }

    -- THROUGH THE REAL EVENT, not by calling the handler directly. The handler
    -- is what is under test; the registration in front of it is one more link
    -- that can be wrong, and including it costs nothing.
    TriggerEvent(BR.Net.LOOT_ADD, { {
        id = id, kind = BR.ItemKind.CONSUMABLE, item = item.id,
        rarity = BR.Rarity.COMMON, count = 1,
        x = tx, y = ty, z = p.z,
        fx = ox, fy = oy, fl = L.crateMouthHeight or 0.6,
    } })

    print(('  test: one %s, origin %.1fm from where it lands')
        :format(item.id, BR.Dist(ox, oy, tx, ty)))

    Citizen.CreateThread(function()
        -- Long enough for the spawn worker to stream a model in (it waits up to
        -- 3s) plus the whole flight, so a "no prop" below means no prop rather
        -- than not yet.
        Citizen.Wait(3500 + (L.arriveMs or 520))

        local e = entries[id]
        local origin = e ~= nil and e.fx ~= nil
        local built  = e ~= nil and e.obj ~= nil and e.obj ~= 0
        local armed  = a.armed > before.armed
        local flew   = a.flights > before.flights

        print('=== arrival arc: verdict ===')
        print(('  origin   %s'):format(origin and 'yes'
            or 'NO -- the entry arrived with no fx/fy on it'))
        print(('  prop     %s'):format(built
            and ('yes, %dms after the announce'):format(a.lastBuildMs or -1)
            or  'NO -- nothing was built for the arc to move'))
        print(('  armed    %s'):format(armed and 'yes'
            or 'NO -- the prop arrived after the window had shut'))
        print(('  flew     %s'):format(flew
            and ('yes, %d frame(s), peak %.2fm above rest')
                :format(a.lastFrames, a.lastPeak)
            or  'NO -- animate() never took the arrival branch'))
        print(('  %s'):format((origin and built and armed and flew)
            and 'PASS: loot arcs out of the crate.'
            or  'FAIL: it pops into existence. The first NO above is where it stops.'))

        forget(id)
    end)
end, false)

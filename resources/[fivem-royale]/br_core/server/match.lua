-- The match state machine -- PER INSTANCE.
--
--   (queue clears the gate) ──► WARMUP ──(timer)──► BUS ──(route done)──► PLAYING
--                                                                            │
--                    (destroyed) ◄──(timer)── CLEANUP ◄──(timer)── ENDED ◄───┘
--
-- PARALLEL MATCHES (user call, 2026-08-04). There is no global "the match":
-- BR.Server.matches holds any number of concurrent instances, each with its
-- own routing bucket, storm, bus route and win condition. WAITING is not an
-- instance state -- it is what a lobby player sees when they belong to no
-- match. The lifecycle:
--
--   * While an instance is in OPEN WARMUP (not full), ready-ups late-join it
--     directly -- the queue stays empty, so no second match can form. This
--     IS the formation gate the user specified: a new match starts with the
--     first players who ready up after every existing match is BUS-or-later
--     (or a full warmup).
--   * Once the queue clears the start conditions, BR.Match.create() mints an
--     instance straight into WARMUP. Its players enter its own routing
--     bucket right there -- the warmup pad is already the match's private
--     world, which is what makes the instance handoff seamless: there is no
--     later mid-flight bucket hop to hide.
--   * ENDED sweeps its players home to the lobby (they keep matchId --
--     and with it the match's event traffic -- through the summary);
--     CLEANUP wipes per-player match state; then the instance is destroyed.
--
-- One authority, one AUDIENCE-SCOPED broadcast per transition. Clients never
-- infer the state -- they are told, and only ever about their own match.

BR = BR or {}
BR.Match = {}

local M = BR.Config.Match

--- Seconds each state lasts. nil means "until something else ends it" --
--- BUS until the route ends, PLAYING until one team is left.
local DURATION = {
    [BR.MatchState.WARMUP]  = M.warmupSeconds,
    [BR.MatchState.BUS]     = nil,   -- set from the bus route
    [BR.MatchState.PLAYING] = nil,
    [BR.MatchState.ENDED]   = M.endedSeconds,
    [BR.MatchState.CLEANUP] = M.cleanupSeconds,
}

--- How long a frozen warmup is held for: a day.
---
--- LONG ENOUGH THAT NO SESSION OUTLIVES IT, AND STILL A REAL NUMBER. The same
--- choice, for the same reason, as the storm freeze's hold (server/storm.lua):
--- clients derive their countdown by subtracting endsAt, and an infinity poisons
--- every one of those subtractions. A day is not a duration anybody will sit
--- through; it is a number that behaves.
---
--- Declared here rather than beside the command that uses it because
--- BR.Match.transition reads it, and a local called above its declaration is
--- what tools/check_forward_locals.lua exists to refuse.
local WARMUP_HOLD_MS = 24 * 60 * 60 * 1000

--- Mint a new match instance and start its warmup.
---
--- The participants are ATTACHED FIRST, then flipped to WARMUP: the state
--- change is what applies the routing bucket, and the bucket needs the
--- matchId to already be there.
---
--- @param mode string
--- @param participants integer[]
--- @return table the instance
function BR.Match.create(mode, participants)
    BR.Server.matchId = BR.Server.matchId + 1
    local m = {
        id        = BR.Server.matchId,
        bucket    = M.matchBucketBase + BR.Server.matchId,
        state     = BR.MatchState.WAITING,   -- transition() below moves it out
        mode      = mode or BR.Mode.SOLO.key,
        endsAt    = 0,
        shortened = false,
        -- WHEN THE LOBBY OPENED, WHICH IS NOT WHEN THE MATCH BEGAN. `startedAt`
        -- is stamped on entering PLAYING and stays nil until then, so anything
        -- that happens on the warmup pad -- a weapon this gamemode never issued
        -- being taken out of a hand, for instance -- has no match timestamp of
        -- any kind to be filed against. This is that timestamp, and it is
        -- deliberately a SECOND field rather than an early `startedAt`: the two
        -- mean different things and `BR.Match.wasPlayed` asks the second one.
        --
        -- Read by server/incident.lua, which puts it on a case as
        -- `matchCreatedAt` so a warmup case says which match it belongs to and
        -- when that match was formed.
        createdAt = GetGameTimer(),
    }
    BR.Server.matches[m.id] = m

    for _, src in ipairs(participants or {}) do
        if BR.Roster.get(src) then
            BR.Roster.setMatch(src, m.id)
        end
    end

    print(('[br_core] match %d formed -- %s, %d player(s), bucket %d')
        :format(m.id, m.mode, #(participants or {}), m.bucket))

    BR.Match.transition(m, BR.MatchState.WARMUP)
    return m
end

--- Did this match ever actually go live?
---
--- `startedAt` is stamped once, on entering PLAYING, and nothing clears it. It
--- is therefore the honest answer to "was this a match", and it is asked in the
--- two places that have to decide whether a departure is worth recording.
---
--- NOTHING BEFORE PLAYING IS WORTH RECORDING, and that is a statement about the
--- data rather than a policy. Warmup is invincible and the flight is
--- untouchable, so every number a results row is built from -- kills, downs,
--- revives, damage, placement, diedAt -- is still at its initial value, and
--- `survivedMs`/`presentMs` are both measured from `startedAt` and would come
--- out zero. Publishing that is not "recording a short match", it is filing a
--- row of zeroes for every participant: #132's exact fingerprint. A match that
--- dissolved on the pad did not happen, and the state machine has always said so
--- (matchTick: "nothing happened, nothing to show").
--- @param m table|nil
--- @return boolean
function BR.Match.wasPlayed(m)
    return m ~= nil and m.startedAt ~= nil
end

--- Publish the results of a match that is being DISSOLVED rather than finished
--- (#161).
---
--- THE OWNER'S CALL, 2026-08-16: "we should record everything."
---
--- A match everybody walks out of never enters ENDED, so `publishResults` -- which
--- hangs off that transition -- was never asked to run, and two players who
--- played most of a match got no aggregate, no XP, no Volts and no history row.
--- That silently reversed a decision the project had already made twice: #100
--- seals a departing player's record precisely so it survives their exit, and #81
--- confirmed a leaver's row does move on a match that ends normally. Leaving did
--- not forfeit your record -- except when you happened to be the last one out,
--- which is an accident of which code path runs rather than anybody's decision.
---
--- CALLED FROM destroy, WHICH IS THE POINT. destroy is documented as the only way
--- a match leaves the registry, so every abandonment reaches here -- the
--- memberless dissolve, the everyone-left dissolve, the underpopulated warmup,
--- and `brforce waiting` -- including the ones nobody has written yet. And it is
--- called as the FIRST thing destroy does, ahead of the roster sweep below, which
--- detaches every remaining player's matchId and would leave publishResults
--- walking a match nobody belongs to.
---
--- THERE IS NO ONCE-PER-MATCH GUARD HERE, DELIBERATELY. `m.publishedAt` inside
--- publishResults is that guard and it is the only one: a match that ended
--- normally has already stamped it, so the CLEANUP -> destroy that follows every
--- finished match no-ops without this function needing to know why. #132 is what
--- a second publish costs -- br_stats writes an atomic ADD to DynamoDB and there
--- is no compensating write -- and two guards that can disagree is how you get a
--- third one.
---
--- NO PLACEMENTS ARE AWARDED EITHER, and that is the other deliberate half. See
--- the note on awardPlacements.
--- @param m table
function BR.Match.publishAbandoned(m)
    if not BR.Match.wasPlayed(m) then return end

    -- AND NOT AFTER THE NUMBERS HAVE BEEN DESTROYED. resetPlayers runs at
    -- CLEANUP and zeroes kills, downs, revives and damage, clears placement and
    -- nils diedAt; `BR.Roster.clearDeparted` drops the sealed entries in the same
    -- breath. Publishing after that records a match in which nobody did anything
    -- -- #132's fingerprint, filed permanently.
    --
    -- The normal path never gets here with this clear (ENDED published long
    -- before CLEANUP wiped anything), so this is not a second once-guard: it is
    -- the one reachable ordering hazard, `brforce cleanup` straight from PLAYING,
    -- where the wipe would happen with nothing yet published.
    if m.wipedAt then
        print(('[br_core] match %d: dissolved after CLEANUP wiped it -- '
            .. 'nothing left to record'):format(m.id))
        return
    end

    print(('[br_core] match %d: abandoned -- recording it anyway (#161)'):format(m.id))
    BR.Match.publishResults(m)
end

--- Tear an instance down completely. The only way a match leaves the
--- registry. Any player still attached (a crash mid-teardown, a straggler)
--- is swept home first.
--- @param m table
function BR.Match.destroy(m)
    -- FIRST, AND THAT IS LOAD-BEARING (#161). A match nobody is left in never
    -- reaches ENDED, so this is the only chance its results ever get to be
    -- published -- and the roster sweep immediately below detaches every
    -- remaining player's matchId, which is the key publishResults builds its rows
    -- from. One line later there is nothing to publish.
    BR.Match.publishAbandoned(m)

    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src, e)
            if e.state ~= BR.PlayerState.LOBBY
               and e.state ~= BR.PlayerState.LEFT then
                BR.Roster.setState(src, BR.PlayerState.LOBBY)
            end
            BR.Roster.setMatch(src, nil)
            -- The SQUAD channel spent the whole match showing the in-match
            -- squad; back in the lobby it must show the PARTY again (which
            -- deliberately survives matches). A client whose party display
            -- went stale here filtered its owner out of every invite list
            -- with nothing on screen explaining why (live report,
            -- 2026-08-04: "can't see each other in the menu" until a solo
            -- queue dissolved the party).
            -- AND ANY INVITE THEY SENT DIES WITH THE MATCH (owner's call,
            -- 2026-08-09). An invite raised mid-match is answered from the
            -- pause menu, and the moment the match ends both players are
            -- somewhere else with a lobby in front of them -- a card still
            -- offering to join a party from two screens ago is answering a
            -- question nobody is still asking. The TTL sweep would get there
            -- eventually; the match ending is the honest moment.
            BR.Party.withdrawInvitesFrom(src, 'the match ended')
            BR.Party.resync(src)
        end)
    -- AND THE SEALED ENTRIES GO WITH IT. CLEANUP normally owns this half of the
    -- wipe, but a dissolved match never reaches CLEANUP -- so every player who
    -- disconnected from, or walked out of, an abandoned match left an entry in
    -- `departed` that nothing would ever collect, one per departure for the
    -- server's uptime. Safe here because publishAbandoned above is the last
    -- reader they will ever have.
    BR.Roster.clearDeparted(m.id)

    BR.Server.matches[m.id] = nil
    print(('[br_core] match %d destroyed'):format(m.id))

    -- THE ONE RELIABLE END-OF-MATCH SIGNAL, for anything holding match-scoped
    -- state. `br:match:results` is not it: that fires from the summary path and
    -- returns early on `#rows == 0`, so a match that ends empty announces
    -- nothing and would leak whatever was keyed to it. This line runs on the
    -- only path out of the registry, which is what makes it safe to free on.
    --
    -- `startedAt` RIDES THE EVENT BECAUSE THE REGISTRY IS ALREADY GONE. The line
    -- above this comment block cleared `BR.Server.matches[m.id]`, so by the time
    -- any handler runs there is no instance left to look the value up on -- and
    -- the incident close (server/incident.lua, via `br:evidence:closing`) needs
    -- it: a case filed during warmup has no start on its row and this is the
    -- moment the real one becomes both known and final. nil for a match that
    -- dissolved without ever going live, which is a fact the close preserves
    -- rather than papers over.
    TriggerEvent('br:match:destroyed', { matchId = m.id, startedAt = m.startedAt })

    -- Re-seed everyone (the old CLEANUP->WAITING snapshot, kept): the
    -- destroyed match's players just changed view, and any client that
    -- missed a delta converges here rather than at its next digest.
    BR.Broadcast.snapshot()
end

--- Move an instance to a new state.
---
--- The only way a match state ever changes. Everything else calls this, so
--- there is one place to log from and one place that broadcasts -- to the
--- match's audience, never to the world.
---
--- @param m table
--- @param state string
--- @param durationSec number|nil  overrides the table above
function BR.Match.transition(m, state, durationSec)
    local from = m.state
    if from == state then return end

    local secs = durationSec or DURATION[state]
    m.state  = state
    m.endsAt = secs and (GetGameTimer() + secs * 1000) or 0
    m.shortened = false

    -- A WARMUP THAT OPENS UNDER A FREEZE IS BORN HELD (brwarmupfreeze, at the
    -- bottom of this file). The same inheritance BR.Storm.begin already applies
    -- to a match that starts while brstormfreeze is on: a debug hold that only
    -- caught the matches running when it was typed would silently stop applying
    -- to the very next round, which is the round the tester is usually waiting
    -- for.
    --
    -- HERE RATHER THAN IN onEnter, because the broadcast below carries endsAt.
    -- A warmup that announced 45 seconds and then quietly extended would leave
    -- every HUD counting down to a departure that is not coming, which is the
    -- exact failure shortenWarmupIfFull rebroadcasts to avoid.
    local heldByFreeze = false
    if state == BR.MatchState.WARMUP and BR.Match.warmupFrozen() then
        m.endsAt = GetGameTimer() + WARMUP_HOLD_MS
        heldByFreeze = true
    end

    -- AND THE LINE BELOW SAYS SO. It used to print `(45s)` for a warmup being
    -- held for a day, because it reports `secs` -- the value from the DURATION
    -- table -- rather than the deadline the two lines above just overwrote.
    --
    -- THAT WAS THE WHOLE OF #202's SECOND HALF. The owner froze a warmup, the
    -- lobby emptied and rebuilt, and every new match logged a confident
    -- `WAITING -> WARMUP (45s)` while sitting on the pad forever. The one line
    -- in the whole feature that printed anything about a held warmup was
    -- printing the opposite, so the console actively argued the freeze was off.
    -- A stuck server with no indication of why is bad; a stuck server whose log
    -- denies it is worse.
    print(('[br_core] match %d: %s -> %s%s'):format(
        m.id, from, state,
        heldByFreeze
            and ' (HELD by brwarmupfreeze -- `brwarmupfreeze off` releases it)'
            or (secs and (' (%ds)'):format(secs) or '')))

    -- Broadcast BEFORE onEnter -- the ordering is a CONTRACT. At ENDED the
    -- client must hear the match ended BEFORE the roster sweep flips its
    -- own state to LOBBY: processing the flip first reads as a voluntary
    -- leave (roundParticipant drops) and the verdict screen never shows --
    -- the "died and went straight to the lobby card" regression
    -- (2026-08-04, caused by briefly reversing this order). BUS is the one
    -- exception: the flight computes the real endsAt inside onEnter, so
    -- onEnter(BUS) sends the single 'bus' event itself -- broadcasting
    -- here too was the doubled "state bus" client log.
    if state ~= BR.MatchState.BUS then
        BR.Broadcast.state(m, state, m.endsAt, { from = from })
    end
    BR.Match.onEnter(m, state, from)
end

--- Side effects of entering a state. Kept separate from transition() so the
--- transition itself stays trivially readable.
--- @param m table
--- @param state string
--- @param from string
function BR.Match.onEnter(m, state, from)
    if state == BR.MatchState.WARMUP then
        -- Membership was attached by create() (or brforce's fallback); only
        -- the members enter warmup. The queue gated the start; it also
        -- defined who is in -- never the whole roster, which would conscript
        -- players who did not ready up.
        BR.Roster.each(
            function(e) return e.matchId == m.id end,
            function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)

        -- Squads are formed once, here, from the parties that exist at the
        -- moment the match starts. Forming them earlier would go stale as
        -- people join and leave parties in the lobby.
        BR.Party.formSquads(m)

        -- ...and squads are what voice channels are cut from, so the push
        -- happens IMMEDIATELY after rather than waiting for the 1Hz sweep.
        -- A second in the wrong room at the start of warmup is a second of
        -- somebody's plan going to the wrong people.
        if BR.Voice then BR.Voice.pushMatch(m) end

        -- The flight is drawn NOW, not at departure: warmup is when players
        -- study the route on the map and pick their drop.
        BR.Bus.plan(m)

        -- The world is stocked NOW too, for the same reason in reverse:
        -- players land during BUS, not at PLAYING, so loot generated at the
        -- state flip would appear under the feet of whoever got down first.
        BR.Loot.begin(m)

    elseif state == BR.MatchState.BUS then
        m.descent = nil     -- fresh per flight: the descent-grace bookkeeping
        m.landCheck = nil   -- and the stuck-lander bookkeeping runs here too
        -- One "waiting on the others" notice per player per flight.
        BR.Roster.each(
            function(e) return e.matchId == m.id end,
            function(_, e) e.landNotice = nil end)

        -- The flight decides how long BUS lasts, so the deadline is set HERE
        -- -- transition() broadcasts it right after onEnter returns, as the
        -- one and only 'bus' state event. The geometry was planned at
        -- WARMUP; departure only stamps the clock onto it. `brforce bus`
        -- from nothing skips warmup, so plan on demand if nothing is drawn.
        if not BR.Bus.active(m) then BR.Bus.plan(m) end
        local dur = BR.Bus.depart(m)
        m.endsAt = GetGameTimer() + math.floor(dur * 1000)
        -- The single 'bus' state event, with the flight's real deadline --
        -- see the ordering note in transition(), which skips its own
        -- broadcast for BUS.
        BR.Broadcast.state(m, state, m.endsAt, { from = from, reason = 'busRoute' })

        BR.Roster.each(
            function(e) return e.matchId == m.id
                and e.state == BR.PlayerState.WARMUP end,
            function(src) BR.Roster.setState(src, BR.PlayerState.BUS) end)

        -- THE PAD'S LOOT DOES NOT FLY. Everything found during warmup is
        -- wiped at wheels-up: the island exists to be practised on, and
        -- arriving early must not be a head start over a late joiner who
        -- boards with nothing (user call, 2026-08-05 -- Fortnite's pre-game
        -- island rule).
        BR.Inv.clearFor(m)

        -- ...AND THE CARS BOUGHT IN THE SHOWROOM ARE HANDED OUT IMMEDIATELY
        -- AFTER THAT WIPE, WHICH IS THE WHOLE OF THE ORDERING (#224).
        --
        -- "It will be available in your inventory once the match starts" is what
        -- the purchase toast promised, and this is that moment. One line earlier
        -- and BR.Inv.clearFor would delete the thing the player paid for; the
        -- wipe is also what guarantees there is room for it, since every bag is
        -- empty on the line above.
        if BR.Shop and BR.Shop.deliver then BR.Shop.deliver(m) end

        -- The starting team count is taken HERE, before anyone can possibly
        -- be dead (warmup is invincible; the doors are still shut). Counting
        -- it at PLAYING was the bug where a player who died during the bus
        -- ride made a two-player match register as "started with one squad"
        -- -- engaging the dev-mode never-auto-end hold and hanging the match.
        m.startSquads = BR.Server.squadsAlive(m)

    elseif state == BR.MatchState.PLAYING then
        -- Anyone somehow still aboard goes out the door first -- brforce can
        -- reach PLAYING mid-flight, and a player left in the BUS state would
        -- be invisible and frozen with the match running around them.
        BR.Bus.ejectAll(m)

        -- WARMUP only. Players who rode the bus are FREEFALL or GLIDE right
        -- now, and they become ALIVE when they LAND (DROP_LANDED in bus.lua),
        -- not when the state machine happens to tick over -- snapping a
        -- mid-air player to ALIVE would say they can fight before they can
        -- steer. The WARMUP case keeps `brforce playing` working: forcing
        -- past the bus entirely still promotes the people standing on the
        -- pad. LOBBY bystanders are never touched.
        BR.Roster.each(
            function(e) return e.matchId == m.id
                and e.state == BR.PlayerState.WARMUP end,
            function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

        -- AND THE PEOPLE WHO DIED WAITING FOR THIS MOMENT GET UP (#144).
        --
        -- "If a player dies before game state changes to playing, we should
        -- notify them they will be revived automatically when the match starts,
        -- and then do so." This is the "then do so" half; the notice went out
        -- when they died. Their death was never written down -- no placement, no
        -- diedAt, no kill credited, no results row -- so there is nothing here to
        -- undo, which is the whole design (server/combat.lua's holdForStart).
        --
        -- SCOPED TO THIS MATCH by matchId, like every other sweep in this file.
        -- A held flag belongs to one instance, and matches advance independently.
        BR.Roster.each(
            function(e) return e.matchId == m.id and e.revivePending end,
            function(src, e) BR.Combat.reviveHeld(src, e) end)

        -- Nothing can win in the first moments of a match. Without this, any
        -- path that reaches PLAYING with states still settling ends instantly,
        -- and the log reads as though a match was played and won in one tick.
        m.startedAt = GetGameTimer()

        m.landCheck = nil   -- fresh stuck-lander bookkeeping per match

        -- The flight is over, so nobody is waiting for it. The `bus.landing`
        -- notice is STICKY, and a sticky notice is only as good as the code
        -- that withdraws it -- landingNotices runs during BUS only, so it
        -- cannot be the caller for the moment BUS ends. (Named by key, not by
        -- its sentence: the wording is the owner's and has changed twice.)
        BR.Bus.clearLandingNotices(m)

        -- Normally counted at BUS entry (before anyone can be dead); this
        -- fallback covers `brforce playing` straight from warmup, where the
        -- bus never ran. Never overwrite a count the bus already took.
        m.startSquads = m.startSquads or BR.Server.squadsAlive(m)

        -- The storm clock starts NOW -- the last landing, not the bus timer
        -- -- and the first circle goes on every map immediately so rotation
        -- decisions start with the looting (user call, 2026-08-02).
        BR.Storm.begin(m)

        -- The airdrop schedule is drawn HERE, after the storm, and that order
        -- is a requirement rather than a preference: siting asks BR.StormAt
        -- where the circle will be when the crate arrives, so there has to be
        -- a record to ask. Nothing is committed yet -- this only decides
        -- whether this match gets one and when it becomes due.
        if BR.Airdrop then BR.Airdrop.begin(m) end

    elseif state == BR.MatchState.ENDED then
        -- ONCE PER MATCH, AND THE SECOND TIME IS WORSE THAN A DUPLICATE.
        --
        -- transition() only no-ops on `from == state`, so ENDED can be entered
        -- again from anywhere -- `brforce ended` after CLEANUP is the reachable
        -- path today. By then resetPlayers has zeroed kills, downs, revives and
        -- damage, cleared placement, and nil'd diedAt, while matchId is left
        -- intact ON PURPOSE (the summary screen still needs this match's
        -- traffic). So the rows published the second time are not duplicates of
        -- the first -- they are a fabrication: placement nil, kills 0, damage 0,
        -- and survivedMs equal to the WHOLE MATCH for every participant.
        --
        -- Those rows are not cosmetic. br_stats' `br:match:results` handler
        -- writes an atomic ADD to DynamoDB, so a second pass adds a second
        -- `matches`, a second `deaths`, more xp and more Volts -- and there is
        -- no compensating write to undo it. A 2026-08-16 playtest produced
        -- exactly this fingerprint: a winner paid the bare completion payout
        -- with an XP gain equal to survival time alone.
        --
        -- Guarded here AND inside publishResults. Here because awardPlacements
        -- must not re-run either; there because publishResults is the one with
        -- side effects outside this resource, and a future caller should not
        -- have to know about this.
        if m.publishedAt then
            print(('[br_core] match %d: results already published, not republishing')
                :format(m.id))
        else
            BR.Match.awardPlacements(m)
            BR.Match.publishResults(m)
        end

        -- Everyone goes HOME at ENDED, not at cleanup. Placements are
        -- already awarded (the line above; the CLEANUP wipe keeps them until
        -- then), and flipping the roster to LOBBY is what drives the whole
        -- trip client-side: the fade, the teleport to the vista, the
        -- invisibility, the shared lobby bucket. They KEEP their matchId --
        -- the summary screen still needs this match's ENDED/CLEANUP traffic.
        --
        -- ...BUT NOT ON THIS FRAME, AND THAT IS #124's SECOND HALF.
        --
        -- The flip is not a bookkeeping change, it is a TEARDOWN: LOBBY is
        -- what freezes the ped (client/natives.lua), what moves the player
        -- into the shared lobby routing bucket -- so the car they were driving
        -- stops existing for them -- and what stops the storm drawing
        -- (client/storm.lua). Doing it here meant doing all three while the
        -- verdict slam was still playing over a live world. The owner, on
        -- 2026-08-16: "the player should still be able to move during that
        -- point (but can't), any vehicle they were driving despawns for some
        -- reason, and if they were in the storm, the storm effects stop
        -- rendering, THEN it fades to black."
        --
        -- The match is over; the world has not gone anywhere yet. So the sweep
        -- waits until each player's own screen is genuinely black and they say
        -- so (BR.Net.MATCH_COVERED), and the world is dismantled underneath
        -- that -- which is the entire purpose of a cover.
        --
        -- PER PLAYER, not per match: 48 clients go black at 48 slightly
        -- different moments and there is no reason to make the quick ones wait
        -- for the slow ones.
        --
        -- AND ON A DEADLINE. A client that has crashed, or whose page never
        -- reports, must still go home -- see sweepHome in the tick. That is
        -- the second of three nets; CLEANUP's resetPlayers is the third.
        m.sweepAt = GetGameTimer() + (M.coverSweepMs or 8000)

    elseif state == BR.MatchState.CLEANUP then
        BR.Bus.clear(m)
        BR.Loot.clear(m)
        if BR.Airdrop then BR.Airdrop.clear(m) end
        -- A DEBUG FREEZE DOES NOT OUTLIVE ITS MATCH. brstormfreeze holds ONE
        -- match still while something else is tested in it; carrying it into
        -- the next round means that round silently has no storm, and a battle
        -- royale with no storm never ends.
        if BR.Storm.thawOnMatchEnd then BR.Storm.thawOnMatchEnd() end
        BR.Match.resetPlayers(m)
    end
end

--- Send a finished match's players home to the lobby.
---
--- The teardown half of ENDED, split out of onEnter so it can happen at the
--- right moment rather than the earliest one. Setting LOBBY freezes the ped,
--- moves the routing bucket and stops the storm drawing on that client -- all
--- of which must happen behind a black screen, never in front of the verdict
--- slam (#124, and the note at the ENDED branch of onEnter).
---
--- Two callers, and they are the two halves of one fail-safe:
---   * the player's own client, saying its screen is covered
---   * the tick, when the deadline passes and nobody said anything
---
--- Idempotent, because both can fire for the same player: setState returns
--- immediately when the state already matches.
---
--- @param m table
--- @param only integer|nil  one player, or every remaining participant
function BR.Match.sweepHome(m, only)
    BR.Roster.each(
        function(e) return e.matchId == m.id
            and e.state ~= BR.PlayerState.LOBBY
            and e.state ~= BR.PlayerState.LEFT end,
        function(src)
            if only and src ~= only then return end
            BR.Roster.setState(src, BR.PlayerState.LOBBY)
        end)
end

--- A client reporting that its own screen has finished going black.
---
--- THE SERVER CANNOT SEE A SCREEN, and this is the only channel that can tell
--- it. Accepted only from a player whose own match is actually ENDED: outside
--- that window there is no teardown pending and the message means nothing, so
--- it is dropped rather than trusted -- a client cannot use this to send itself
--- home early, mid-fight.
RegisterNetEvent(BR.Net.MATCH_COVERED)
AddEventHandler(BR.Net.MATCH_COVERED, function()
    local src = source
    local m = BR.Server.matchOf(src)
    if not m or m.state ~= BR.MatchState.ENDED then return end
    BR.Match.sweepHome(m, src)
end)

--- Assign final placements.
---
--- Placement is by squad, not by player: a four-stack that wipes together all
--- share a placement, which is what players expect and what the summary screen
--- needs to show.
---
--- CALLED AT ENDED ONLY, AND NEVER FOR AN ABANDONED MATCH (#161).
---
--- AN ABANDONED MATCH AWARDS NO PLACEMENT OF ITS OWN. This function ranks the
--- players who are STILL STANDING when a match finishes, and a match is dissolved
--- precisely because nobody is: there is no last squad, so there is nothing here
--- to rank. Every row an abandoned match publishes therefore carries only the
--- placement its player earned on the way out --
---
---   * walked out alive -> `BR.Combat.eliminate(src, 'left', nil)` gave them one,
---     because "leaving while alive IS an elimination" (BR.Match.leaveMatch);
---   * died first       -> their real placement, from the same function;
---   * disconnected     -> none at all, which br_stats reads as 0. That is the
---     shape #100 already produces on a match that ends normally, so an abandoned
---     match is not a new answer to an old question.
---
--- AND THAT IS WHAT STOPS LEAVING BECOMING WINNING. Run here, this loop would
--- hand `placement = 1` -- first place -- to whoever simply had not left yet,
--- which is reachable today by an admin dissolving a live match with
--- `brforce waiting`. The last player out is not the last player standing, and
--- the difference between those two sentences is the entire hazard.
---
--- The last player to walk out DOES still take placement 1 from eliminate(),
--- because at that instant nobody had outlasted them and that is what placement
--- means. It is not a win: eliminate stamps `diedAt`, and #133 settled that
--- `won = placement == 1 and not died` -- one rule, read by the aggregate, the
--- payout and the history row alike. A leaver keeps the ordering and loses the
--- victory, exactly like the last squad taken by the storm.
--- @param m table
function BR.Match.awardPlacements(m)
    local living = {}
    BR.Roster.each(
        function(e)
            -- isInMatch, not just ALIVE/DBNO: since landing became what makes
            -- a player alive, a winner can be mid-glide when the last enemy
            -- dies -- still falling is still standing.
            --
            -- AND A HELD DEATH IS STILL STANDING TOO (#144). `revivePending` is
            -- a player who left the bus, went down, and whose match has not
            -- reached PLAYING: they have no diedAt, no placement and no results
            -- row saying otherwise, and the only way this function ever sees one
            -- is an admin ending a match during the flight -- there is no
            -- gameplay path, because the pre-match tick refuses to end a match
            -- that is holding somebody. Left out, they would be the one
            -- participant of a force-ended match to finish with no placement, which
            -- br_stats reads as a non-winning finish and banks as a death: the
            -- exact outcome this whole change exists to prevent, arriving
            -- through the one door nobody was watching.
            return e.matchId == m.id
                and (BR.Server.isInMatch(e.state) or e.revivePending == true)
        end,
        function(src, e) living[#living + 1] = { src = src, e = e } end)

    for _, p in ipairs(living) do
        p.e.placement = 1
        BR.Broadcast.delta({ op = 'update', src = p.src, e = { placement = 1 } })
    end

    -- Console only. The chat is for PLAYERS TALKING (user rule, 2026-08-03):
    -- the victory is announced by the end screen, which every participant is
    -- already looking at.
    if #living > 0 then
        local names = {}
        for _, p in ipairs(living) do names[#names + 1] = p.e.name end
        print(('[br_core] match %d won by %s'):format(m.id,
            table.concat(names, ', ')))
    else
        print(('[br_core] match %d ended with no survivors'):format(m.id))
    end
end

--- Announce what everyone did this match, once, at ENDED.
---
--- THIS DID NOT EXIST, AND THAT IS WHY NO STATS WERE EVER RECORDED.
--- br_stats has carried an `applyMatch` since it was written and nothing has
--- ever called it: br_core emitted no match-end event at all, so the profile
--- table has been empty this whole time and nobody noticed, because an empty
--- stats table looks exactly like a new server.
---
--- EVERY PARTICIPANT, NOT JUST THE SURVIVORS. awardPlacements walks the living,
--- because placement is the only thing the dead do not need. Statistics are the
--- opposite: the player who dropped hot and died first has kills and damage
--- worth recording, and a match that ends with NO survivors -- the storm taking
--- the last squad -- would otherwise record nothing at all for anybody.
--- (That was open bug #55.)
---
--- FIRE AND FORGET. This is a TriggerEvent, not a call: br_core does not know
--- whether anything is listening and must not care. A stats consumer that is
--- absent, broken or slow cannot affect the match ending.
--- @param m table
function BR.Match.publishResults(m)
    -- AT MOST ONCE, whoever calls. The consumer's DynamoDB write is an atomic
    -- ADD with no compensating write, so a second publish is unrecoverable
    -- without a manual repair -- see the long note at the ENDED branch. Stamped
    -- before the rows are built rather than after they are sent, so a throw
    -- part-way through cannot leave the flag clear and invite a retry.
    if m.publishedAt then return end
    m.publishedAt = GetGameTimer()

    local rows = {}
    local endedAt = GetGameTimer()
    local startedAt = m.startedAt or endedAt

    --- One participant's row.
    ---
    --- THE TWO DURATIONS ARE DIFFERENT NUMBERS AND BOTH ARE NEEDED. `survivedMs`
    --- stops when they died; `presentMs` stops when they disconnected. A player
    --- who is killed at four minutes and spectates to the twenty-minute finish
    --- survived four and was present for twenty, and paying XP on the second is
    --- what made an early death worth the same as a win (#99).
    ---
    --- Both are clamped at zero: a player eliminated during WARMUP or the bus
    --- has a timestamp older than startedAt, which is set at PLAYING.
    --- @param src integer
    --- @param e table
    --- @param left boolean  sealed on disconnect rather than read live
    local function row(src, e, left)
        local diedAt = e.diedAt or e.leftAt or endedAt
        local goneAt = e.leftAt or endedAt
        return {
            src       = src,
            name      = e.name,
            -- Normally filled by whoever consumes this -- br_core does not
            -- resolve identifiers. A SEALED entry is the exception and carries
            -- its own, captured at disconnect while the source was still
            -- resolvable; by now it is not.
            license   = e.license,
            kills     = e.kills or 0,
            downs     = e.downs or 0,
            revives   = e.revives or 0,
            damage    = e.damage or 0.0,
            -- What they took off the ground rather than earned by playing
            -- (#88's airdrop Volts). Carried on the row for the same reason
            -- `died` is: this is the only journey it makes, and the formula that
            -- reads it should not have to re-derive it from anything.
            voltsPickedUp = e.voltsPickedUp or 0,
            placement = e.placement,
            -- PLACEMENT 1 IS NOT THE SAME QUESTION AS "DID THEY WIN".
            --
            -- The last squad standing can still be killed by the storm, and
            -- eliminate() correctly records them as placement 1 -- nobody
            -- outlasted them. But they died, and a match that ends with no
            -- survivors has no winner. The client has always known this
            -- (`placement == 1 and not diedThisMatch`, client/state.lua) and
            -- shows them a death; the stats path never got the same rule and
            -- banked a win, zero deaths, the win payout and the win XP bonus.
            --
            -- Sent as a fact about the player rather than left to be inferred,
            -- because the two halves inferring it separately is exactly how
            -- they came to disagree.
            died      = e.diedAt ~= nil,
            squadId   = e.squadId,
            survivedMs = math.max(0, diedAt - startedAt),
            presentMs  = math.max(0, goneAt - startedAt),
            -- There is nobody to show a verdict screen to.
            left      = left,
        }
    end

    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src, e) rows[#rows + 1] = row(src, e, false) end)

    -- THE PLAYERS WHO LEFT COUNT TOO. They are out of the roster -- correctly,
    -- nothing should treat them as present -- but they played this match, and
    -- walking only the roster is what silently voided the record of everyone
    -- who closed the game after being eliminated (#100).
    for _, e in ipairs(BR.Roster.departedIn(m.id)) do
        rows[#rows + 1] = row(e.src, e, true)
    end

    if #rows == 0 then return end

    TriggerEvent('br:match:results', {
        matchId   = m.id,
        mode      = m.mode,
        startedAt = startedAt,
        endedAt   = endedAt,
        -- How many were in it, for placement-relative scoring: finishing 3rd of
        -- 8 and 3rd of 96 are not the same achievement. Counts the departed --
        -- they were in the match, and a field of 48 that ends with 40 still
        -- connected was never a field of 40.
        total     = #rows,
        players   = rows,
    })
end

--- Wipe ONE player's per-match state.
---
--- Split out of resetPlayers so that LEAVING a match clears the same slate that
--- the match ending clears (#161). It did not, and the consequence was silent:
--- BR.Match.leaveMatch detaches matchId, so CLEANUP's sweep -- which filters on
--- matchId -- never reached anybody who had walked out, and their kills, damage,
--- placement and diedAt followed them into their NEXT match and were banked
--- again there. Two matches, one set of kills, counted twice.
---
--- One function, both callers, so "what a match leaves behind" is defined once.
--- @param src integer
--- @param e table
function BR.Match.resetPlayer(src, e)
    e.kills, e.downs, e.revives, e.damage = 0, 0, 0, 0.0
    -- Per-match like the four above, and for the reason #161 spells out: a
    -- counter left standing follows the player into their NEXT match and is
    -- banked a second time there. One airdrop, paid twice.
    e.voltsPickedUp = 0
    e.lastDamageBy, e.lastDamageAt = nil, 0
    e.stormHp, e.lastStormAt = nil, nil
    e.hp, e.armour = 100.0, 0.0

    -- THE HEALTH AUDIT'S TALLY IS PER MATCH, for the reason #161 spells out
    -- one paragraph up and for one more of its own: the bar it is measured
    -- against ("a whole bar the server never issued") only means anything
    -- inside one round. Carried over, a player who collected forty points of
    -- honest jitter across three matches would eventually be reported for
    -- having played a lot.
    --
    -- The two WINDOWS go with it. Both are deadlines on the old match's clock,
    -- and a stale one would excuse the first two seconds of the next match --
    -- which is exactly the window a returning cheat would land in.
    e.healthAudit, e.armourAudit = nil, nil
    e.healUntil, e.healthSettleUntil = nil, nil

    -- Per-match, like the counters above. A stale diedAt would date a
    -- player's next match to their last one's clock and pay them
    -- survival XP for a match they had not started.
    e.diedAt, e.leftAt = nil, nil

    -- THE KNOCK COUNT IS PER MATCH, which is the only thing that makes
    -- the shortening bleed fair: a player who was picked up three times
    -- last round starts the next one on a full 45 seconds.
    e.dbnoUntil, e.dbnoCount = nil, 0
    e.downedBy, e.reviverSrc, e.reviveFrom = nil, nil, nil
    e.reviveBeat, e.reviveTickAt = nil, nil

    -- WHO KILLED THEM LAST ROUND IS NOT WHO KILLED THEM THIS ROUND. Cleared
    -- here with the rest of the per-match record, and it has to be cleared
    -- somewhere: server/spectate.lua points a dead solo's camera at it, so a
    -- value carried into the next match would open a session on a player this
    -- one has never fought -- and a licence, unlike downedBy, does not go stale
    -- on its own. `downedBy` two lines up is the same field for the same reason.
    e.killedByLicense = nil

    -- A HELD DEATH BELONGS TO THE MATCH IT HAPPENED IN (#144). Normally
    -- the flag is cleared by the revive at PLAYING, but a match that
    -- never reaches PLAYING -- brforce ended, everyone else leaving --
    -- leaves it set. Carried into the next round it would make its owner
    -- count toward heldForStart in a match where nothing is holding
    -- them, which is how the pre-match tick decides whether to go live
    -- or dissolve. Same reasoning as diedAt above: per match, cleared
    -- per match.
    e.revivePending = nil

    -- Explicitly cleared, so clients drop them too. squadId is
    -- per-match; partyId deliberately survives.
    BR.Roster.clearFields(src, { 'placement', 'squadId', 'colour' })
    if e.state ~= BR.PlayerState.LOBBY
       and e.state ~= BR.PlayerState.LEFT then
        BR.Roster.setState(src, BR.PlayerState.LOBBY)
    end
end

--- Clear per-player match state for one instance's players, at CLEANUP.
--- @param m table
function BR.Match.resetPlayers(m)
    m.storm = nil
    m.startSquads = nil
    BR.Inv.clearFor(m)

    -- THE MOMENT THIS MATCH'S NUMBERS STOP EXISTING, stamped so the dissolve
    -- path can refuse to publish from the wreckage (#161, and see
    -- publishAbandoned). Everything below this line is destructive, and
    -- everything that reads a results row has to happen before it.
    m.wipedAt = GetGameTimer()

    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        BR.Match.resetPlayer)

    -- The other half of the same wipe: the sealed entries of everyone who left
    -- this match. Their results published at ENDED, so nothing needs them now,
    -- and holding them would leak an entry per disconnect for the server's
    -- uptime.
    BR.Roster.clearDeparted(m.id)
end

--- Cut a match's warmup short once it is full.
---
--- Warmup exists to give stragglers time to arrive. Once nobody else can join
--- THIS match, it is dead time -- and a full warmup staring at a 45 second
--- timer with every slot taken is the most obvious possible way to waste a
--- player's patience. (It also reopens the formation gate sooner: a full
--- warmup no longer blocks the next match from forming.)
---
--- Rebroadcasts rather than mutating quietly: clients derive their countdown
--- from endsAt, so an endsAt that changed without being announced would leave
--- every HUD counting down to the wrong moment.
--- @param m table
function BR.Match.shortenWarmupIfFull(m)
    if m.shortened then return end

    -- A FROZEN WARMUP IS NOT CUT SHORT. brwarmupfreeze exists to hold the pad
    -- open, and a full lobby is the one thing that would otherwise thaw it by
    -- the back door -- silently, and down to ten seconds. Returning WITHOUT
    -- setting `shortened` is deliberate: the cut is refused for now rather than
    -- spent, so a lobby that fills during the hold is still cut short the moment
    -- somebody thaws it.
    if BR.Match.warmupFrozen() then return end

    if BR.Server.countIn(m) < M.maxPlayers then return end

    local cap = GetGameTimer() + M.warmupShortened * 1000
    if cap >= m.endsAt then
        m.shortened = true    -- already sooner than the cap; nothing to do
        return
    end

    m.endsAt = cap
    m.shortened = true
    print(('[br_core] match %d full -- warmup cut to %ds'):format(m.id, M.warmupShortened))
    BR.Broadcast.state(m, m.state, m.endsAt, { reason = 'lobbyFull' })
end

--- Why the next match OF A MODE cannot form yet, or nil if it can.
---
--- THE GATE AND THE EXPLANATION ARE THE SAME FUNCTION, deliberately.
---
--- The formation tick decides whether to start; the lobby broadcast tells
--- players what it is waiting for. Written separately those two drift, and the
--- failure is nasty: the interface confidently explains a condition that is
--- not the one actually holding the match, so the player does the thing it
--- asked for and nothing happens. One function, two callers, no disagreement.
---
--- Note there is no "a warmup is open" reason here: while one of this mode
--- is open, ready-ups late-join it instead of queueing, so the queue this
--- function reads only ever holds players waiting for a NEW match.
---
--- @param mode string|nil  the mode whose queue is being judged; defaults to
---        the dominant mode (the lobby status display's approximation)
--- @return table|nil  { reason = 'players'|'squads'|'party', have, need }
function BR.Match.startBlocker(mode)
    -- MAINTENANCE OUTRANKS EVERY OTHER REASON, because it is the only one that
    -- is not about the queue being too small -- and because a match started
    -- during a drain is guaranteed to be interrupted by the restart the drain
    -- exists to make painless. Checked first so a full queue cannot start one.
    if BR.Lobby.blocked and BR.Lobby.blocked() then
        return { reason = 'maintenance', have = #BR.Lobby.ids(mode or BR.Lobby.dominantMode()), need = 0 }
    end

    mode = mode or BR.Lobby.dominantMode()
    local queued = #BR.Lobby.ids(mode)
    local need   = BR.Lobby.needed()
    if queued < need then
        return { reason = 'players', have = queued, need = need }
    end

    -- Enough PLAYERS is not the same as enough TEAMS. Four players who all
    -- queued as one party form a single squad, and a single squad has already
    -- met the win condition before the match starts.
    if mode ~= BR.Mode.SOLO.key then
        local squads    = BR.Party.prospectiveSquads(BR.Lobby.ids(mode), mode)
        local minSquads = BR.Config.Match.MinSquads(BR.Server.devMode)
        if squads < minSquads then
            return { reason = 'squads', have = squads, need = minSquads }
        end

        -- PARTIES ENTER TOGETHER -- with a patience limit. One member
        -- readying up must not launch the match while the rest of their
        -- party is still picking a mode (the first two-client squad test
        -- started the instant the first Ready landed) -- but one AFK
        -- partymate must not brick the queue for everyone either. So the
        -- hold lasts partyGraceSeconds; after that the match forms without
        -- the stragglers, and the warmup door they can still walk through
        -- is the late-join path that already exists. The party panel marks
        -- who the room is waiting on (check / ellipsis) the whole time.
        local queuedSet = {}
        for _, src in ipairs(BR.Lobby.ids(mode)) do queuedSet[src] = true end
        local incomplete = nil
        for src in pairs(queuedSet) do
            local party = BR.Party.of(src)
            if party then
                local ready = 0
                for _, mem in ipairs(party.members) do
                    if queuedSet[mem] then ready = ready + 1 end
                end
                if ready < #party.members then
                    incomplete = { reason = 'party', have = ready, need = #party.members }
                    break
                end
            end
        end
        if incomplete then
            BR.Server.partyHoldSince = BR.Server.partyHoldSince or GetGameTimer()
            if GetGameTimer() - BR.Server.partyHoldSince
               < (BR.Config.Match.partyGraceSeconds * 1000) then
                return incomplete
            end
            -- Patience spent: start without them.
        else
            BR.Server.partyHoldSince = nil
        end
    end

    return nil
end

--- Say out loud why a full queue is not starting.
---
--- The tick runs at 4Hz, so this is throttled and only speaks when the answer
--- changes. Without it the lobby sits at "enough players" forever with no
--- indication of what it is waiting for, which is indistinguishable from the
--- queue being broken -- a failure mode this project has already shipped once.
--- @param blocker table
local lastWarn = { key = '', at = 0 }

function BR.Match.announceBlocker(blocker)
    -- An empty queue explains itself. Announcing it anyway printed
    -- "holding: 0 queued, need 1" every 15 seconds into an empty server's
    -- console, forever. Speak only when somebody is actually waiting.
    if blocker.have == 0 then return end

    local now = GetGameTimer()
    local key = ('%s:%d/%d'):format(blocker.reason, blocker.have, blocker.need)
    if key == lastWarn.key and (now - lastWarn.at) < 15000 then return end
    lastWarn.key, lastWarn.at = key, now

    -- Console only; the lobby screen already tells the waiting players what
    -- the queue is short of, phrased from this same blocker.
    if blocker.reason == 'maintenance' then
        print('[br_core] holding: a server update is pending -- no new matches')
    elseif blocker.reason == 'squads' then
        print(('[br_core] holding: %d squad(s), need %d -- waiting for another team')
            :format(blocker.have, blocker.need))
    elseif blocker.reason == 'party' then
        print(('[br_core] holding: a party has %d/%d readied up')
            :format(blocker.have, blocker.need))
    else
        print(('[br_core] holding: %d queued, need %d')
            :format(blocker.have, blocker.need))
    end
end

--- How long after PLAYING begins before a win can be declared.
--- Purely a guard against states that have not settled; a real match cannot be
--- decided this fast anyway.
local WIN_GRACE_MS = 3000

--- Is there anyone left to fight over, in THIS match?
--- @param m table
--- @return boolean
local function winConditionMet(m)
    -- Only meaningful once the match is live; two players in a lobby are not a
    -- finished match.
    if m.state ~= BR.MatchState.PLAYING then return false end
    if m.startedAt and (GetGameTimer() - m.startedAt) < WIN_GRACE_MS then
        return false
    end

    -- An empty match has not "been won" -- it has nobody in it. The
    -- abandoned-match sweep in the tick is what ends those.
    if BR.Server.countIn(m) == 0 then return false end

    -- DEV ONLY: a match that STARTED with exactly one squad has nothing to
    -- win, so as long as that squad is still standing it never auto-ends --
    -- a lone developer can sit in PLAYING and poke at the world.
    -- brforce/brskip/brleave are the ways out, and everyone dying still ends
    -- it. Production cannot reach this: the minSquads gate refuses to start
    -- a one-squad match at all. (== 1, not <= 1: a zero here means states
    -- had not settled when the count was taken, which is the grace period's
    -- problem, not this rule's.)
    if BR.Server.devMode and m.startSquads == 1
       and BR.Server.squadsAlive(m) >= 1 then
        return false
    end

    return BR.Server.squadsAlive(m) <= 1
end

--- How many of this match's players died before it started and are waiting to
--- be picked back up (#144).
---
--- THEY ARE NOT ALIVE AND THEY ARE NOT FINISHED, AND EVERY HEADCOUNT BELOW
--- ASSUMED THOSE WERE THE ONLY TWO OPTIONS. `BR.Server.aliveCount` counts states
--- that are in the fight, and DEAD is not one -- correctly, since these players
--- are lying on the ground. But the two decisions the pre-match tick makes off
--- that count both come out backwards for them:
---
---   * "everyone is down -- ending" would end the match this player is about to
---     be revived INTO, and end it before PLAYING, so the revive never runs and
---     the death they were promised would be undone gets published instead.
---   * "last player down -- going live" would refuse to go live, because it
---     insists somebody is alive first -- so a solo player who dies during the
---     flight would hold their own match in BUS forever, waiting for a state
---     that is the only thing that can revive them.
---
--- One count, asked in both places, rather than teaching aliveCount a fourth
--- meaning: aliveCount answers "can fight", and these players cannot.
--- @param m table
--- @return integer
local function heldForStart(m)
    return BR.Server.countIn(m, function(p) return p.revivePending == true end)
end

--- One instance's share of the tick.
--- @param m table
local function matchTick(m, now)
    -- A MATCH NOBODY BELONGS TO CANNOT END ITSELF: the win condition
    -- refuses empty matches by design, so an instance whose last member
    -- left (everyone brleaving mid-PLAYING) sat leaked forever with its
    -- storm still ticking (repro'd 2026-08-04). Memberless means dissolve,
    -- whatever the state.
    if BR.Server.countIn(m) == 0
       and m.state ~= BR.MatchState.ENDED
       and m.state ~= BR.MatchState.CLEANUP then
        print(('[br_core] match %d: memberless -- dissolving'):format(m.id))
        BR.Match.destroy(m)
        return
    end

    if m.state == BR.MatchState.WARMUP then
        BR.Match.shortenWarmupIfFull(m)
    end

    -- NOBODY IS LEFT BEHIND IN A FINISHED MATCH.
    --
    -- ENDED now waits for each client to report that its screen has gone black
    -- before taking that player's world away (#124). This is the net under
    -- that: a client that crashed, whose CEF died, or whose report was simply
    -- lost has no way to ask, and must go home anyway. The deadline is set at
    -- the transition and is comfortably shorter than endedSeconds, so a player
    -- swept by this still gets the rest of the summary window -- CLEANUP's
    -- resetPlayers is the backstop behind THIS, not the plan.
    if m.state == BR.MatchState.ENDED and m.sweepAt and now >= m.sweepAt then
        m.sweepAt = nil
        BR.Match.sweepHome(m)
    end

    -- Whoever is already on the ground learns the match is waiting on the
    -- rest. Polled rather than hooked to the landing report, which has a long
    -- history of not arriving -- see BR.Bus.landingNotices.
    if m.state == BR.MatchState.BUS then
        BR.Bus.landingNotices(m)
    end

    -- AN ABANDONED MATCH DIES -- but DYING IS NOT LEAVING. Everyone
    -- brleaving during warmup or the flight leaves nothing to run (nothing
    -- happened, nothing to show): the instance is destroyed on the spot.
    -- If anyone actually DIED, this was a match, however short, and it takes
    -- the REAL exit: ENDED runs placements, the verdict, the roster sweep
    -- and the trip home.
    if (m.state == BR.MatchState.WARMUP or m.state == BR.MatchState.BUS)
       and BR.Server.aliveCount(m) == 0
       and heldForStart(m) == 0 then
        local anyDead = BR.Server.countIn(m, function(p)
            return p.state == BR.PlayerState.OUT
        end) > 0
        if anyDead then
            print(('[br_core] match %d: everyone is down -- ending'):format(m.id))
            BR.Match.transition(m, BR.MatchState.ENDED)
        else
            print(('[br_core] match %d: everyone left -- dissolving'):format(m.id))
            BR.Match.destroy(m)
        end
        return
    end

    if m.state == BR.MatchState.BUS then
        -- The drop ends when the LAST player is down -- not when the route
        -- timer says so. Everyone jumped early and landed? The match goes
        -- live now instead of waiting out an empty flight. The endsAt timer
        -- below stays as the CEILING: a client that crashes mid-fall never
        -- reports a landing, and one ghost must not hold 47 players in the
        -- pre-match state forever.
        local airborne = BR.Server.countIn(m, function(p)
            return p.state == BR.PlayerState.BUS
                or p.state == BR.PlayerState.FREEFALL
                or p.state == BR.PlayerState.GLIDE
        end)
        -- A HELD PLAYER COUNTS AS A REASON TO GO LIVE (#144). They are on the
        -- ground, they are not airborne, and PLAYING is the only event that
        -- gives them their match back -- see heldForStart above. Without this
        -- the last surviving condition for a solo drop that ended badly is a
        -- state transition that will not happen.
        if airborne == 0
           and (BR.Server.aliveCount(m) > 0 or heldForStart(m) > 0) then
            print(('[br_core] match %d: last player down -- going live'):format(m.id))
            BR.Match.transition(m, BR.MatchState.PLAYING)
            return
        end

        -- THE CEILING YIELDS TO A LIVE DESCENDER. A real glider off a 500m
        -- exit outlasts the route timer, and forcing PLAYING under them
        -- started the storm clock before the last player had landed.
        --
        -- Altitude is tracked EVERY tick, so that at the moment the ceiling
        -- hits, "is anyone genuinely falling" is already answered -- deciding
        -- it only at expiry would either grant every ghost one free
        -- extension (first sample has no baseline) or grant a real glider
        -- none (no second sample before the transition). A frozen altitude
        -- stops paying within one round, so a hung client cannot hold the
        -- room; the extensions cap at two minutes regardless.
        m.descent = m.descent or { extended = 0, z = {}, falling = {} }
        BR.Roster.each(
            function(e)
                return e.matchId == m.id
                   and (e.state == BR.PlayerState.BUS
                     or e.state == BR.PlayerState.FREEFALL
                     or e.state == BR.PlayerState.GLIDE)
            end,
            function(src, e)
                if e.pos and (now - (e.posAt or 0)) < 3000 then
                    -- A RATE, not a per-tick delta. A canopy descends about
                    -- 2 m/s, which is half a metre per 250ms tick -- under
                    -- the old 1.0m test it read as NOT descending, so the
                    -- ceiling refused to wait for the one thing it exists to
                    -- wait for. Judged per second, freefall and canopy both
                    -- clear the bar and a hung client still does not.
                    local prev = m.descent.z[src]
                    local verdict = BR.ClassifyDescent(
                        prev and prev.z, prev and prev.at,
                        e.pos.z, e.posAt or now,
                        BR.Config.Match.descendRate)
                    if verdict then
                        m.descent.falling[src] = (verdict == 'falling') or nil
                    end
                    -- Only record a sample when it is genuinely new: the tick
                    -- is 4Hz and positions arrive at 2Hz, so half of all ticks
                    -- would otherwise overwrite the baseline with the same
                    -- reading and make every rate zero.
                    if not prev or prev.at ~= (e.posAt or now) then
                        m.descent.z[src] = { z = e.pos.z, at = e.posAt or now }
                    end
                else
                    m.descent.falling[src] = nil
                end
            end)

        if m.endsAt > 0 and now >= m.endsAt and airborne > 0
           and m.descent.extended < 120000 then
            local descending = false
            for _, v in pairs(m.descent.falling) do
                if v then descending = true break end
            end
            if descending then
                m.descent.extended = m.descent.extended + 10000
                m.endsAt = m.endsAt + 10000
                BR.Broadcast.state(m, m.state, m.endsAt, { reason = 'descent' })
                print(('[br_core] match %d: someone is still descending -- holding BUS 10s more')
                    :format(m.id))
            end
        end
    end

    -- STUCK LANDERS BECOME ALIVE. A player whose landing report was lost
    -- (or refused) stays FREEFALL/GLIDE forever -- and those states are
    -- invincible on their own client, so they walk the match untouchable
    -- ("players seem invincible", live report). Standing at a constant
    -- altitude for five seconds is not falling by any definition: promote
    -- them server-side, which drops their invincibility and re-arms every
    -- system keyed on ALIVE.
    --
    -- This MUST run during BUS as well as PLAYING, and the first version
    -- (PLAYING only) was circular: a stuck lander still counts as airborne,
    -- airborne > 0 is exactly what holds the match in BUS -- so the net that
    -- would fix them was waiting on the state THEY were blocking, and the
    -- player walked Los Santos untouchable until the route timer ran out
    -- ("invincible until the flight is over", live repro). No false
    -- positives from the ride itself: riders are in the BUS state, which
    -- this filter never touches, and a jumper awaiting exit coords hits the
    -- self-place fallback (and a changing z) within a second.
    if m.state == BR.MatchState.PLAYING or m.state == BR.MatchState.BUS then
        m.landCheck = m.landCheck or { z = {}, still = {} }
        BR.Roster.each(
            function(e)
                return e.matchId == m.id
                   and (e.state == BR.PlayerState.FREEFALL
                     or e.state == BR.PlayerState.GLIDE)
            end,
            function(src, e)
                if e.pos and (now - (e.posAt or 0)) < 3000 then
                    -- THE SAME RATE TEST, and this is the half that actually
                    -- hurt players. Under the old per-tick delta a parachutist
                    -- looked stationary, so this net PROMOTED THEM TO ALIVE
                    -- WHILE THEY WERE STILL IN THE AIR -- which sent them the
                    -- "match starts once everyone has landed" toast before
                    -- they had landed, dropped the airborne count to zero, and
                    -- took the match live under a player still on canopy
                    -- (user, 2026-08-06). It was meant to catch a client whose
                    -- landing report was lost, and it caught ordinary flying.
                    --
                    -- Stillness is now counted in WALL TIME, so the threshold
                    -- means five seconds whatever the tick rate happens to be.
                    local prev = m.landCheck.z[src]
                    local verdict = BR.ClassifyDescent(
                        prev and prev.z, prev and prev.at,
                        e.pos.z, e.posAt or now,
                        BR.Config.Match.descendRate)

                    if verdict == 'still' then
                        local since = m.landCheck.still[src] or (e.posAt or now)
                        m.landCheck.still[src] = since
                        local heldMs = (e.posAt or now) - since
                        if heldMs >= (BR.Config.Match.stuckLanderMs or 5000) then
                            print(('[br_core] %s (%d) has held one altitude %.1fs -- promoting to ALIVE')
                                :format(e.name, src, heldMs / 1000.0))
                            BR.Roster.setState(src, BR.PlayerState.ALIVE)
                            m.landCheck.still[src] = nil
                        end
                    elseif verdict == 'falling' then
                        m.landCheck.still[src] = nil
                    end

                    if not prev or prev.at ~= (e.posAt or now) then
                        m.landCheck.z[src] = { z = e.pos.z, at = e.posAt or now }
                    end
                end
            end)
    end

    if winConditionMet(m) then
        BR.Match.transition(m, BR.MatchState.ENDED)
        return
    end

    -- A timed state whose time is up moves to whatever comes next.
    if m.endsAt > 0 and now >= m.endsAt then
        if m.state == BR.MatchState.WARMUP then
            -- Participants still standing on the pad: a lobby idler who
            -- never readied up must not pad the number that decides whether
            -- this match is worth flying.
            if BR.Server.aliveCount(m) < M.MinPlayers(BR.Server.devMode) then
                print(('[br_core] match %d: not enough players, dissolving'):format(m.id))
                BR.Match.destroy(m)
            else
                -- No duration passed: onEnter(BUS) plans the route and sets
                -- the deadline from it.
                BR.Match.transition(m, BR.MatchState.BUS)
            end
        elseif m.state == BR.MatchState.BUS then
            BR.Match.transition(m, BR.MatchState.PLAYING)
        elseif m.state == BR.MatchState.ENDED then
            BR.Match.transition(m, BR.MatchState.CLEANUP)
        elseif m.state == BR.MatchState.CLEANUP then
            BR.Match.destroy(m)
        end
    end
end

--- The tick: every instance advances, then the queue may form a new one.
--- Deliberately dumb per instance -- check whether the current state should
--- end, and if so move on. All the interesting logic lives in onEnter.
local function tick()
    local now = GetGameTimer()

    -- A DEBUG HOLD DOES NOT OUTLIVE THE SESSION IT WAS SET FOR (#202). Asked
    -- FIRST, before the dissolves below empty the registry, so the order of the
    -- two is never load-bearing: the freeze is judged on who is connected, which
    -- neither of them changes.
    BR.Match.thawOnEmptyServer()

    BR.Server.eachMatch(function(m) matchTick(m, now) end)

    -- FORMATION, PER MODE. Matches are homogeneous (user call, 2026-08-04),
    -- so each mode's queue forms its own match, and a solo warmup being open
    -- never blocks a squad match from forming beside it -- both warmups
    -- share the communal pad; the flights are separate. A mode's queue only
    -- ever accumulates while no warmup of that mode is open (ready-ups
    -- late-join an open one instead of queueing), which is the formation
    -- gate: the next match of a mode forms from the first players to ready
    -- up after every match of that mode is BUS-or-later or a full warmup.
    for _, modeDef in pairs(BR.Mode) do
        local mode = modeDef.key
        if not BR.Server.formingMatch(mode) then
            local parts = BR.Lobby.ids(mode)
            if #parts > 0 then
                -- Every reason to hold is checked BEFORE the queue is
                -- consumed. The queue is spent on the way into WARMUP, so
                -- refusing later would leave the players out of the queue
                -- with no match to be in.
                local blocker = BR.Match.startBlocker(mode)
                if blocker then
                    BR.Match.announceBlocker(blocker)
                else
                    BR.Lobby.consume(parts)
                    BR.Match.create(mode, parts)
                end
            end
        end
    end
end

BR.Sched.every(250, 'match.tick', tick)

--- Leave the current match, on the player's own initiative.
---
--- The match must not notice beyond the elimination: leaving while alive IS an
--- elimination -- placement recorded, squadmates play on, the alive count drops
--- through the same path a death would use. Anything gentler would create a
--- second, parallel way to exit a match, and every later system (placements,
--- stats, spectate) would have to know about both.
---
--- The party deliberately survives. Leaving the MATCH and leaving the PARTY
--- are different intents with different buttons.
--- @param src integer
function BR.Match.leaveMatch(src)
    local entry = BR.Roster.get(src)
    if not entry then return end

    -- ═══ WALKING OUT FORFEITS THE WARMUP SHOP'S PURCHASE ═══
    --
    -- Owner, 2026-08-30: "if you buy a car, then leave the match, you forfeit
    -- your purchase. It should not be persistent or carry over to another round
    -- ever."
    --
    -- THIS LINE USED TO MEAN THE OPPOSITE. It released the purchase's binding so
    -- the car became OWED and the next wheels-up its buyer attended handed it
    -- over -- which is how somebody landed after the bus holding a car from the
    -- previous warmup and a car from this one (#238). Nothing is owed now:
    -- BR.Shop.release destroys the record, the Volts stay spent, and the console
    -- carries a line naming the car and its price.
    --
    -- ═══ AND THIS CALL SITE IS THE WHOLE OF THE RULE ═══
    --
    -- "Forfeit on leaving" must never become "forfeit while still in the match",
    -- which is the complaint that started all of this. Nothing in server/shop.lua
    -- reads a position, a distance or a timer -- so leaving THROUGH THIS
    -- FUNCTION is the only path to a forfeit, and a second caller appearing
    -- anywhere would silently change the rule. tools/test_shop.lua asserts that
    -- there is exactly one.
    --
    -- BEFORE THE BRANCHES BELOW, so it covers every way out of a match and not
    -- only the warmup one. Guarded because br_core is allowed to run without the
    -- shop having resolved a catalogue.
    if BR.Shop and BR.Shop.release then BR.Shop.release(src) end

    if entry.state == BR.PlayerState.LOBBY then
        -- Already home. If they still carry a matchId (the ENDED summary),
        -- leaving just detaches them from the last of its traffic -- no
        -- second trip for a player already standing in the lobby.
        BR.Roster.setMatch(src, nil)
        return
    end

    if entry.state == BR.PlayerState.WARMUP then
        -- The match has not started; there is no placement to record. They
        -- simply step out, and the warmup-end headcount treats them exactly
        -- like someone who never readied up.
        BR.Roster.clearFields(src, { 'squadId', 'colour' })
    elseif BR.Server.isInMatch(entry.state)
        or entry.state == BR.PlayerState.DBNO then
        BR.Combat.eliminate(src, 'left', nil)
    end
    -- OUT players fall through: already out of the fight, they only need the
    -- trip back to the lobby. A spectator is one of them.

    -- ...AND A HELD DEATH IS CANCELLED BY WALKING OUT (#144). Someone who died
    -- before the match started and then decided not to wait for the revive is
    -- leaving; the flag must not follow them to the lobby, where it would hold
    -- their old match open in the pre-match tick and, if that match were still
    -- forming, revive a player who is no longer in it. Leaving is the one exit
    -- the hold does not survive -- which is also why 'left' is excluded from the
    -- hold in the first place (server/combat.lua).
    entry.revivePending = nil

    -- ...AND THEIR RECORD IS SEALED BEFORE THEY ARE DETACHED (#161).
    --
    -- THE ORDER OF THE NEXT THREE STEPS IS THE WHOLE FIX, so they are together:
    -- seal, wipe, detach. Getting them in any other order loses the match or
    -- doubles it.
    --
    -- publishResults finds its rows by matchId, and the line below clears this
    -- player's -- so from that moment their kills, damage, placement and diedAt
    -- are unreachable by the match they earned them in. That was true of EVERY
    -- match, not just abandoned ones: a player who used Leave Match got no row
    -- even from a match that ran to a winner, and did not count toward the field
    -- size either. #100 fixed exactly this for disconnects and this door was
    -- never checked -- which is what made #161 look like a problem only about
    -- matches that empty out.
    --
    -- ONLY IF THIS MATCH ACTUALLY WROTE SOMETHING DOWN ABOUT THEM, and `diedAt`
    -- is the field that answers it. It is the one every results row turns on --
    -- `died`, and the end of the survival clock -- and the branches above are
    -- exactly the ones that set it: a player who was alive or downed has just
    -- been through eliminate('left'), and a player who was already OUT went
    -- through it earlier. So the two cases it excludes are the
    -- two that must be excluded, and neither needs its own clause:
    --
    --   * WARMUP -- they stepped off the pad. "The match has not started; there
    --     is no placement to record", as the branch above already says. Sealing
    --     would bank `matches +1` and a death for changing their mind.
    --   * A HELD DEATH (#144) -- holdForStart deliberately writes NO diedAt, no
    --     placement and no kill, because that death was going to be undone. It
    --     stays unwritten when its owner walks out instead of waiting for the
    --     revive; "a death that will be reversed must never be WRITTEN" does not
    --     stop being true because the player got bored.
    --
    -- Whether the MATCH was worth recording is a different question, asked once,
    -- later, by publishAbandoned -- so a bus-phase leaver is sealed here and then
    -- correctly discarded if the match never goes live at all.
    if entry.diedAt ~= nil then
        BR.Roster.sealLeaver(src)
    end

    -- THE WIPE HAPPENS EITHER WAY, and it has to. CLEANUP's sweep filters on
    -- matchId, so it will never reach this player again -- and without this their
    -- kills, damage, placement and diedAt ride into the next match and are banked
    -- a second time there. Unconditional because the stale state is just as real
    -- for somebody who walked out during the bus, where eliminate('left') has
    -- already written a placement and a diedAt that no longer belong to anything.
    BR.Match.resetPlayer(src, entry)

    BR.Roster.setState(src, BR.PlayerState.LOBBY)
    -- Leaving really leaves: unlike the ENDED sweep (which keeps matchId for
    -- the summary), a voluntary exit detaches immediately -- no more of this
    -- match's traffic, free to queue for the next one.
    BR.Roster.setMatch(src, nil)
    TriggerClientEvent(BR.Net.TO_LOBBY, src)
    BR.Server.notify(src, 'You left the match.', 'info')

    -- AND THEIR PARTY DISPLAY IS RE-ASSERTED, the same way it is when a match
    -- is destroyed. The SQUAD channel spends the whole match carrying the
    -- in-match squad, so a party change during one -- including leaving it on
    -- the way out through the pause menu -- may never have reached this
    -- client. Walking back into the lobby with a party the server does not
    -- have is how "neither player can leave the party" starts (user,
    -- 2026-08-09): the button asks to leave something already gone.
    --
    -- The match-destroy path does this per player; a voluntary exit skips
    -- that path entirely, which is exactly why it needs its own call.
    BR.Party.resync(src)

    print(('[br_core] %s (%d) left the match'):format(entry.name, src))
end

RegisterNetEvent(BR.Net.MATCH_LEAVE)
AddEventHandler(BR.Net.MATCH_LEAVE, function()
    BR.Match.leaveMatch(source)
end)

-- --------------------------------------------------------------------------
-- Admin
-- --------------------------------------------------------------------------

--- The instance admin commands operate on: the newest one, or -- for brforce
--- from nothing -- a fresh instance formed from whoever is queued (falling
--- back to nobody, which is the honest outcome of forcing a match no one
--- asked for).
--- @return table
local function debugTarget()
    local m = BR.Server.latestMatch()
    if m then return m end
    local mode  = BR.Lobby.dominantMode()
    local parts = BR.Lobby.ids()
    BR.Lobby.clear()
    return BR.Match.create(mode, parts)
end

RegisterCommand('brforce', function(_, args)
    local target = args[1]
    if not target then
        local m = BR.Server.latestMatch()
        print(('  usage: brforce <state>   current: %s')
            :format(m and m.state or BR.MatchState.WAITING))
        print('  states: waiting warmup bus playing ended cleanup')
        return
    end

    if target == BR.MatchState.WAITING then
        -- WAITING is no longer an instance state: forcing it dissolves the
        -- newest match outright, which is what the command was for.
        local m = BR.Server.latestMatch()
        if m then
            print(('[br_core] admin dissolved match %d (was %s)'):format(m.id, m.state))
            BR.Match.destroy(m)
        else
            print('  no match to dissolve')
        end
        return
    end

    for _, v in pairs(BR.MatchState) do
        if v == target then
            local m = debugTarget()
            print(('[br_core] admin forced match %d: %s -> %s'):format(m.id, m.state, v))
            BR.Match.transition(m, v)
            return
        end
    end
    print(('  unknown state: %s'):format(target))
end, true)

RegisterCommand('brskip', function()
    -- Ends the newest match's current timed state immediately.
    local m = BR.Server.latestMatch()
    if not m then
        print('  no match running')
        return
    end
    if m.endsAt > 0 then
        m.endsAt = GetGameTimer()
        print(('[br_core] admin skipped to the end of match %d\'s %s'):format(m.id, m.state))
    else
        print(('  %s has no timer to skip'):format(m.state))
    end
end, true)

--- HOLD THE MATCH IN WARMUP. Dev mode only.
---
---   brwarmupfreeze          hold every open warmup on the pad: the departure
---                           timer stops, the bus does not come
---   brwarmupfreeze off      thaw -- re-enter warmup from now, so the pad runs
---                           its ordinary countdown and departs normally
---
--- The hold also lifts on its own once the server is empty (#202). It survives
--- matches; it does not survive the session. `brstate` says when it is on.
---
--- MODELLED ON brstormfreeze (server/storm.lua) DELIBERATELY, down to the
--- restriction, the wording of the report and the `off` argument. They are the
--- same kind of control -- a debug hold on a clock that would otherwise decide
--- the session -- and giving the second one a different idiom would mean
--- learning the same command twice.
---
--- ═══ WHAT IT IS FOR ═══
---
--- Owner, 2026-08-20: "can you make me a server command that will stop the match
--- in the warmup phase?"
---
--- AND THE CASE THAT MAKES IT MORE THAN A CONVENIENCE: an incident filed during
--- WARMUP gets no match context. Warmup is invincible, the flight has not left,
--- and a case opened on the pad never enters the match timeline's pending map,
--- so it never receives the match-end close that gives every other case its
--- surroundings (server/incident.lua). That is an open design question rather
--- than a decided one -- but it could only be looked at when a warmup happened
--- to run long enough to strip a weapon in, which is to say by luck. Holding the
--- pad open turns "reproduce it if the timing is kind" into "type this, then
--- take as long as you need".
---
--- ═══ IMPLEMENTED AS A DEADLINE, AND BROADCAST LIKE ANY OTHER ═══
---
--- The state machine advances a warmup when `endsAt` passes (matchTick), so the
--- hold is a deadline a day out rather than a flag the tick has to learn about.
--- Nothing else in the file needs to know: `brskip` still ends it, `brforce bus`
--- still departs, and a match that dissolves for being underpopulated still
--- dissolves -- all of those are already written against endsAt or against the
--- state, not against a clock this command owns.
---
--- Every change of endsAt is rebroadcast, for the reason shortenWarmupIfFull
--- gives: clients derive their countdown from it, so an endsAt that moved in
--- silence leaves every HUD counting to the wrong moment.
---
--- ═══ IT DOES NOT LIFT AT MATCH END, AND IT DOES LIFT ON AN EMPTY SERVER ═══
---
--- brstormfreeze drops at the end of the match it was holding, because carrying
--- a storm freeze into the next round leaves that round with no storm and a
--- battle royale with no storm never ends -- an invisible failure.
---
--- THE SAME RULE HERE WOULD BE UNREACHABLE AND WRONG. Unreachable, because a
--- warmup that is being held never reaches the end of a match to hang the
--- release on; the only paths that do get there are the dissolves -- everybody
--- steps off the pad, or the warmup was underpopulated -- so the hook would fire
--- exactly when a tester walked away for a moment and would disarm a switch they
--- set thirty seconds ago. And wrong, because the failure it would be protecting
--- against is not invisible: a held warmup is a departure timer that has stopped
--- on the screen of everybody standing on the pad.
---
--- THAT REASONING SURVIVES #202 INTACT. What it does NOT cover, and what the
--- owner hit on 2026-08-22, is the case where there is no tester to disarm a
--- switch out from under:
---
---   "I ran brwarmupfreeze but after all players left and went back in, the
---    warmup is still frozen."
---
--- Every word of that is the code above doing what it says. `warmupFrozen` is a
--- process-lifetime flag; BR.Match.transition re-applies it to every warmup that
--- ever opens again, so the freeze was not stuck, it was PERMANENT -- one
--- console line held every future lobby on this server until somebody typed
--- `off` or restarted the resource. Nothing was broken; the scope was wrong.
---
--- SO THE RELEASE IS HUNG ON THE SERVER EMPTYING, NOT ON A MATCH ENDING. See
--- BR.Match.thawOnEmptyServer below. The two are different events and only one
--- of them is a lie about what the tester wanted: a match dissolving means the
--- people testing stepped into the lobby, and a server with nobody connected
--- means the session the hold was set for is over. An empty server rebuilding a
--- lobby from scratch should not inherit a debug switch from the last one.
---
--- IT IS STILL RELEASABLE BY HAND, AND ALWAYS WAS -- `brwarmupfreeze off`, the
--- same word the storm takes. That was never the missing piece. The missing
--- pieces were that the hold outlived its session and that NOTHING SAID SO: see
--- the log line in BR.Match.transition, which used to print `(45s)` over a
--- warmup being held for a day, and the `brstate` readout in server/debug.lua.
local warmupFrozen = false

--- Is warmup currently held by brwarmupfreeze?
--- Read by BR.Match.transition, so a match opening AFTER the freeze inherits it,
--- by shortenWarmupIfFull, so a full lobby cannot cut the hold short, and by
--- `brstate` (server/debug.lua), so a held server says why it is held.
--- @return boolean
function BR.Match.warmupFrozen() return warmupFrozen end

--- Drop the hold once nobody is connected.
---
--- POLLED FROM THE TICK RATHER THAN HOOKED TO `playerDropped`, and the reason is
--- ordering rather than taste. Half this resource registers a drop handler and
--- roster.lua's is the one that takes the entry out of the roster -- so a
--- handler here would be asking "is the server empty" either side of the answer
--- changing, depending on registration order in the manifest. The tick asks 4Hz
--- later, when the roster has settled and there is exactly one answer.
---
--- CHEAP ON THE ORDINARY PATH: the flag is false, so this is one comparison per
--- tick and never reaches the count.
---
--- WHY THE COUNT AND NOT THE MATCH REGISTRY. An empty registry is not an empty
--- server -- it is the ordinary state of a lobby between rounds, which is
--- precisely the moment a tester is standing there waiting for the next held
--- warmup. `BR.Server.count()` is zero only when the roster is empty, and
--- BR.Roster.remove clears the entry rather than marking it LEFT, so it reaches
--- zero on the last disconnect.
function BR.Match.thawOnEmptyServer()
    if not warmupFrozen then return end
    if BR.Server.count() > 0 then return end
    warmupFrozen = false
    print('[br_core] warmup freeze lifted -- the server is empty, so the next '
        .. 'lobby is not born held')
end

RegisterCommand('brwarmupfreeze', function(_, args)
    if not BR.Server.devMode then
        print('  brwarmupfreeze is dev-mode only (br_devMode true)')
        return
    end

    local thaw = (args[1] == 'off' or args[1] == 'thaw')
    local now = GetGameTimer()
    local touched = 0

    BR.Server.eachMatch(function(m)
        if m.state ~= BR.MatchState.WARMUP then return end

        if thaw then
            -- RE-ENTER WARMUP FROM NOW, which is this command's version of the
            -- storm thaw resuming the phase from wherever the wall is. The pad
            -- gets a whole ordinary warmup rather than whatever was left of one
            -- an hour ago, and `shortened` is re-armed so a full lobby is cut
            -- short again by the rule that was suppressed during the hold.
            m.endsAt = now + M.warmupSeconds * 1000
            m.shortened = false
        else
            m.endsAt = now + WARMUP_HOLD_MS
        end
        BR.Broadcast.state(m, m.state, m.endsAt,
            { reason = thaw and 'warmupThaw' or 'warmupFreeze' })
        touched = touched + 1
    end)

    warmupFrozen = not thaw
    print(('[br_core] warmup %s (%d match%s)'):format(
        thaw and 'THAWED -- the pad counts down and the bus comes'
             or 'FROZEN -- the pad stays open, no departure',
        touched, touched == 1 and '' or 'es'))
    if not thaw and touched == 0 then
        print('  (no warmup open yet -- the next one will start frozen)')
    end
end, true)

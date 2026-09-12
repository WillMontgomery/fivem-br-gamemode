-- The authoritative roster.
--
-- THIS IS THE SOURCE OF TRUTH FOR WHO IS IN THE MATCH.
--
-- Everything the gamemode needs to know about players -- who is alive, who is on
-- which squad, who killed whom, what placement they finished -- lives here and
-- nowhere else. Clients hold a read-only mirror that is only ever updated by
-- explicit broadcasts from this file.
--
-- WHY IT IS BUILT THIS WAY
--
-- Under OneSync, a client can only see players currently in its scope. Two
-- players 3km apart do not exist to each other. Any client-side attempt to count
-- players, list squadmates, or work out who is still alive therefore produces an
-- answer that is correct when everyone is huddled at the drop and wrong for the
-- rest of the match -- and the symptoms (alive count drifting, kill feed missing
-- entries) look like logic bugs rather than architecture bugs.
--
-- The server has no such limitation: playerJoining, playerDropped and
-- GetPlayers() are global. So the rule is absolute, and mechanically enforced by
-- the scope gate in tools/verify.sh: roster facts flow server -> client, never
-- the reverse, and never sideways between clients.

BR = BR or {}
BR.Roster = {}

local roster = BR.Server.roster   -- [src] = entry

--- Fields replicated to clients. Deliberately a subset: licenses, positions and
--- damage bookkeeping are server business. Broadcasting live positions to every
--- client would hand a wallhack to anyone reading the event stream.
---
--- Declared before first use and kept local -- as a global it would leak into
--- every other server script in this resource's Lua state.
local PUBLIC_FIELDS = {
    name = true, squadId = true, state = true,
    hp = true, armour = true, kills = true, placement = true, colour = true,
}

--- Fields pushed to the Ringmaster admin console. A SECOND allowlist, wider
--- than PUBLIC_FIELDS on purpose and NEVER a replacement for it: this
--- projection travels server-to-server over the VPC peering link, to a box
--- that already holds the ban list -- so it may carry exactly the things
--- PUBLIC_FIELDS exists to withhold from clients (license, position, matchId).
---
--- It lives HERE, directly under PUBLIC_FIELDS and beside newEntry, so that
--- adding a roster field forces a decision about BOTH audiences while the
--- shape is on screen. A projection defined off in br_ringmaster would drift
--- silently, and its failure mode is a privacy leak rather than a crash.
--- test_roster.lua asserts both lists against newEntry's actual keys.
local RINGMASTER_FIELDS = {
    src = true, name = true, license = true,
    matchId = true, squadId = true, state = true,
    hp = true, armour = true,
    kills = true, downs = true, revives = true, damage = true,
    placement = true,
    pos = true, posAt = true, bucket = true,
}

--- Fields carried per player. Written here so the shape is documented in one
--- place rather than accreting keys across a dozen files.
--- @param src integer
--- @return table
local function newEntry(src)
    return {
        src        = src,
        name       = GetPlayerName(src) or 'Unknown',
        license    = nil,          -- filled by br_stats if it is running
        matchId    = nil,          -- match instance membership; NEVER public
        squadId    = nil,
        state      = BR.PlayerState.LOBBY,

        hp         = 100.0,        -- DISPLAY units (0..100), see config/match.lua
        armour     = 0.0,

        kills      = 0,
        downs      = 0,
        revives    = 0,
        damage     = 0.0,
        placement  = nil,

        -- CURRENCY PICKED UP OFF THE GROUND THIS MATCH (#88). Airdrops carry a
        -- Volts pile; claiming one adds to this and writes nothing.
        --
        -- IT IS NOT A BALANCE AND MUST NEVER BE READ AS ONE. It is an INPUT to
        -- the payout formula, published once in the match results and added to
        -- `deltas.balance` inside br_stats' single atomic write -- which is what
        -- keeps config/market.lua's "exactly one writer that can increase a
        -- balance" literally true. Cleared with the rest of the per-match
        -- counters at CLEANUP.
        --
        -- IN NEITHER ALLOWLIST, and deliberately. A client has no use for it --
        -- the toast at pickup is the whole of what a player is told -- and the
        -- console cannot act on it.
        voltsPickedUp = 0,

        -- CURRENCY SPENT THIS MATCH (#293). The other direction of the same
        -- ledger, and the reason it exists is that nothing recorded it: a
        -- purchase is a conditional debit against the row, so after it settles
        -- the only trace anywhere is a smaller balance.
        --
        -- MOVED IN EXACTLY ONE PLACE -- the SUCCESS arm of BR.Market.charge --
        -- so all three spend paths (the warmup showroom, the gun shop and the
        -- revive key) are counted by construction and a refused purchase adds
        -- nothing. Do not confuse it with `entry.spent` in server/market.lua,
        -- which is an in-flight RESERVATION released the moment DynamoDB
        -- answers either way and is therefore a total of nothing.
        --
        -- A WARMUP SPEND BELONGS TO THE MATCH THE PLAYER THEN PLAYS, which is
        -- automatic rather than arranged: the showroom refuses anyone without a
        -- matchId, so the counter is already attached to that match, and
        -- BR.Match.resetPlayer -- the only thing that zeroes it -- does not run
        -- until that match cleans up.
        --
        -- LIKE voltsPickedUp IT IS IN NEITHER ALLOWLIST, published once in the
        -- match results and cleared with the rest at CLEANUP.
        voltsSpent = 0,

        pos        = nil,          -- sampled server-side, not reported by the client
        posAt      = 0,

        lastDamageBy = nil,
        lastDamageAt = 0,

        -- DBNO bookkeeping (M7). All server-side, none of it PUBLIC: the
        -- client is TOLD its own downed state on BR.Net.DBNO_SET, and everyone
        -- else learns about it only from the `state` field, which is.
        --
        -- `dbnoUntil` HAS ONE SQUAD-ONLY EXIT and it is worth naming here,
        -- because the next person to want it will reach for PUBLIC_FIELDS
        -- first: server/party.lua copies it onto the squad beacon as
        -- `bleedEndsAt`, to the downed player's own squad and to nobody else.
        -- It must NOT join PUBLIC_FIELDS -- that list goes to every client in
        -- the match, so putting a bleed-out deadline on it would hand each
        -- downed player's exact remaining seconds to the people who shot them.
        --   dbnoUntil   when the bleed runs out (server ms)
        --   dbnoCount   knocks this match; each one bleeds faster
        --   downedBy    who gets the kill if nobody touches them again --
        --               deliberately outlives assistWindowMs, unlike lastHitBy
        --   reviverSrc  who is holding on them right now
        --   reviveFrom  when that hold started
        dbnoUntil  = nil,
        dbnoCount  = 0,
        downedBy   = nil,
        reviverSrc = nil,
        reviveFrom = nil,

        -- WHEN THIS MATCH ENDED FOR THEM, on the same GetGameTimer() clock as
        -- m.startedAt. Both are nil for a player who is still in it.
        --   diedAt  set by BR.Combat.eliminate; survival time stops here
        --   leftAt  set by BR.Roster.remove; presence stops here
        -- A player who dies and stays to spectate has diedAt and no leftAt,
        -- which is exactly the difference the two numbers exist to carry.
        --
        -- DELIBERATELY IN NEITHER ALLOWLIST. These are published once, in the
        -- match results, and read by nothing live -- so a client has no use for
        -- them and the console would only be showing a number it cannot act on.
        -- Cleared at CLEANUP with the rest of the per-match state.
        diedAt     = nil,
        leftAt     = nil,

        -- THEIR PED IS DEAD AND THEIR MATCH IS NOT OVER (#144). Set when a
        -- player is killed before their match reaches PLAYING, cleared by the
        -- revive on that transition. It is the reason `state == DEAD` and
        -- `diedAt == nil` can be true at the same time, which every other part
        -- of this codebase would otherwise read as a contradiction: DEAD is what
        -- their own client draws, diedAt is what the results row is built from,
        -- and for the length of the hold only the first of those has happened.
        --
        -- ALSO IN NEITHER ALLOWLIST, and for a stronger reason than diedAt: this
        -- is a promise the server has made to one player, not a fact about them
        -- that anyone else can act on.
        revivePending = nil,

        -- THE GUIDED FIRST RUN HAS THEM, AND MATCHMAKING MAY NOT (#261).
        --
        -- Written by BR.Roster.setTutorial and by nothing else; cleared by the
        -- same verb, and by BR.Match.create for anybody a match takes anyway.
        -- While it stands, this player is refused at the one door into a match
        -- (BR.Party.mayEnter, which BR.Lobby.admissible splits on) and at every
        -- door into a party -- so no warmup clock can start against somebody
        -- who is still reading card three.
        --
        -- IN NEITHER ALLOWLIST, for revivePending's reason rather than diedAt's:
        -- this is a promise the server has made to ONE player about what will
        -- not happen to them. No other client can act on it -- the greying of
        -- the party controls happens on that player's own page, driven by their
        -- own Lua -- and the console cannot end somebody's tutorial, so it would
        -- be a column over there that nothing can be done with.
        tutorial   = nil,

        joinedAt   = GetGameTimer(),
        bucket     = 0,
    }
end

--- Players who disconnected mid-match, kept until that match publishes.
---
--- NOT KEYED BY src, AND THAT IS THE WHOLE POINT. Server ids are recycled
--- within the minute, so a sealed entry left in `roster[src]` would be
--- overwritten by -- or worse, silently merged with -- whoever connects into
--- that slot next, which inside one match is a routine occurrence rather than
--- an edge case. An array has no key to collide on.
---
--- This is the evidence buffer's move (#94), for the same reason: a disconnect
--- SEALS a player's record rather than freeing it.
local departed = {}

--- Add a player, or return the existing entry if they are already known.
--- @param src integer
--- @return table
--- Put a player in the routing bucket their state AND MATCH call for.
---
--- THE INSTANCE MODEL (user-specified, 2026-08-03; parallel matches + the
--- communal warmup, 2026-08-04): the lobby is one shared bucket, the WARMUP
--- PAD is another -- every forming match's players (and every rider until
--- their flight is genuinely airborne) share it, so the airstrip is a place
--- where you watch other lobbies' planes take off. From the moment a rider's
--- flight climbs out (m.airborne, set by the bus a few seconds after
--- wheels-up) -- or the moment they jump -- they live in their match's OWN
--- bucket, `m.bucket`, so two concurrent matches never see each other and a
--- fresh match never inherits anything.
---
--- THE BUCKET IS READ OFF THE MATCH, NOT RE-DERIVED FROM THE ID (#291). It used
--- to read `matchBucketBase + entry.matchId`, which was the same arithmetic
--- BR.Match.create ran and therefore the same answer -- right up until ids
--- became a random 20-bit draw and the bucket moved to `seq`. Two independent
--- derivations of one number agree until the day one of them changes, and the
--- symptom here would have been players in the same match placed in different
--- worlds. There is one bucket per match and one place it is computed.
---
--- A LOBBY-state player rides the lobby bucket even while they still carry
--- a matchId (the ENDED summary trip home) -- the bucket is about where
--- their PED is, the matchId about which match's traffic they hear.
--- Guarded, because the unit tests run this file without the Cfx runtime.
--- @param src integer
--- @param entry table
local function applyBucket(src, entry)
    if not SetPlayerRoutingBucket then return end
    local M = BR.Config.Match
    local m = entry.matchId and BR.Server.matches[entry.matchId]
    local bucket
    if entry.state == BR.PlayerState.LOBBY or not m then
        bucket = M.lobbyBucket
    elseif entry.state == BR.PlayerState.WARMUP
        or (entry.state == BR.PlayerState.BUS and not m.airborne) then
        bucket = M.warmupBucket
    else
        bucket = m.bucket
    end
    if SetRoutingBucketPopulationEnabled then
        -- MATCH buckets get ambient life (user call, 2026-08-04: parked
        -- cars, some traffic, pedestrians -- the AMOUNT is throttled
        -- client-side by the density multipliers in gamerules). The lobby
        -- and warmup buckets stay sterile: the island is a stage.
        SetRoutingBucketPopulationEnabled(bucket,
            bucket >= M.matchBucketBase)
    end
    SetPlayerRoutingBucket(tostring(src), bucket)
end

--- Re-derive a player's bucket from their current entry -- the lever the
--- bus pulls when a flight goes airborne and its riders leave the communal
--- warmup bucket without any state change.
--- @param src integer
function BR.Roster.rebucket(src)
    local entry = roster[src]
    if entry then applyBucket(src, entry) end
end

--- Attach a player to a match instance (or detach with nil). The bucket
--- follows immediately. matchId is server business -- it never travels in a
--- delta; scoped events are how a client knows which match it is in.
--- @param src integer
--- @param matchId integer|nil
function BR.Roster.setMatch(src, matchId)
    local entry = roster[src]
    if not entry or entry.matchId == matchId then return end
    entry.matchId = matchId
    applyBucket(src, entry)
end

--- A player's chosen display name, or nothing.
---
--- Proposed by the client (stored in ITS kvp) and accepted HERE, because a
--- name is the one preference other people can see -- so it is the one
--- preference the server has to have an opinion about.
---
--- LOBBY ONLY. Renaming yourself mid-match rewrites the kill feed everyone
--- else is reading, and there is no legitimate reason to want that.
--- @param src integer
--- @param proposed string|nil  empty or nil restores the platform name
--- @return boolean
function BR.Roster.setName(src, proposed)
    local entry = roster[src]
    if not entry then return false end
    if entry.state ~= BR.PlayerState.LOBBY then return false end

    -- THE SHARED RULE, and the server is the one that counts. The client runs
    -- the same BR.ValidateName so a player learns instantly, but that copy is
    -- a courtesy -- a modified client that skips it is refused here.
    local ok, reason, clean = BR.ValidateName(proposed)
    if not ok then
        BR.Server.notify(src, reason or 'That name is not available.', 'warn')
        return false
    end

    entry.gamertag = (#clean > 0) and clean or nil
    local name = entry.gamertag or GetPlayerName(src) or entry.name
    if name == entry.name then return true end

    entry.name = name
    BR.Broadcast.delta({ op = 'update', src = src, e = { name = name } })
    return true
end

RegisterNetEvent(BR.Net.SETTINGS_NAME)
AddEventHandler(BR.Net.SETTINGS_NAME, function(data)
    BR.Roster.setName(source, data and data.name)
end)

--- Is this player inside the guided first run right now (#261)?
---
--- ONE QUESTION ASKED IN SIX PLACES, and it is a function rather than six
--- `entry.tutorial` reads so that the day the answer needs a second term there
--- is one place to put it. The callers are BR.Party.mayEnter -- the single door
--- into a match -- the four party verbs that could otherwise put somebody in a
--- squad they may not be in, and BR.Match.startBlocker, which has to keep the
--- lobby's explanation of its own wait honest.
--- @param src integer
--- @return boolean
function BR.Roster.inTutorial(src)
    local entry = roster[src]
    return (entry ~= nil and entry.tutorial) == true
end

--- Start or end the tutorial HOLD -- the server's half of #261.
---
--- ═══════════════════════════════════════════════════════════════════════════
--- WHAT THE FLAG DOES
--- ═══════════════════════════════════════════════════════════════════════════
---
--- Owner, 2026-09-05: "if they're in the tutorial, they're not actively on any
--- warmup timer at all until the tutorial is complete. This means matchmaking
--- is not allowed to touch them and they cannot join a party while the tutorial
--- toggle is on because their party will get into the match while they're still
--- in warmup doing the tutorial."
---
--- Three rules, and this flag is the input to all three:
---
---   * BR.Party.mayEnter refuses them. That is the ONE predicate
---     BR.Lobby.admissible splits its queue on, and both doors into a match are
---     built on that split -- the formation tick consumes `ready`, the late-join
---     sweep admits `ready` -- so a player refused there is refused at both,
---     without a second rule anywhere for the two to disagree by.
---   * No warmup clock can therefore start against them, because they never
---     reach BR.PlayerState.WARMUP to be given one. The countdown is a property
---     of a match instance, not of a player, so being kept out of every instance
---     IS being kept off every clock -- there is no separate timer to suppress.
---   * The party verbs in server/party.lua refuse them, so nobody else's
---     readiness can carry them in through a squad either.
---
--- The greyed party controls are the UI's courtesy; this is the rule. A client
--- that never drew the grey is refused here just the same.
---
--- ═══════════════════════════════════════════════════════════════════════════
--- A CLIENT THAT CAN SAY "DO NOT MATCHMAKE ME" CAN SAY IT FOREVER
--- ═══════════════════════════════════════════════════════════════════════════
---
--- That is true, no amount of validation fixes it -- the server cannot see a
--- page -- and what it actually BUYS is the question that decided the shape of
--- this function.
---
--- IT BUYS NOTHING THAT ABSTENTION DOES NOT ALREADY BUY. A player who simply
--- never presses Ready is already invisible to the formation tick, already on no
--- clock, already in no squad, for as long as they like, with a stock client and
--- no message to send. This exemption hands out no capability the lobby does not
--- already give away free to anyone willing to keep their hands off one button.
--- There is nothing on the far side of the exploit to reach.
---
--- ═══ SO THERE IS NO TIME CAP, AND THE ABSENCE IS THE DECISION ═══
---
--- A cap was the obvious answer and it is the wrong one, twice:
---
---   1. IT IS THE THING THE OWNER RULED OUT, WEARING ANOTHER NAME. "Not
---      actively on any warmup timer at all until the tutorial is complete" is
---      a sentence about a clock. A cap is a clock -- one that expires on
---      somebody still mid-walkthrough and drops them into the exact match this
---      feature exists to keep them out of. It would fail as the feature at
---      precisely the moment it fired.
---   2. IT BINDS ONLY THE HONEST READER. A slow first-timer meets the cap. A
---      modified client meets it too and sends one more message. The cap costs
---      the cheat a keystroke and costs the player the feature.
---
--- WHAT DOES BIND IS THE SHAPE OF THE GRANT, and it is three things:
---
---   B1. IT IS ONLY GRANTED FROM A STANDING START -- LOBBY, attached to no
---       match. So it can never be an escape hatch: it cannot dodge a warmup, a
---       flight, a fight or a results publish, and dodging is the only version
---       of this that takes something away from somebody else.
---   B2. IT IS NOT FREE. Raising it drops the player out of the queue and out of
---       their party, below. A flag held WHILE queued would make BR.Lobby.count
---       lie to every lobby screen in the room; a flag held while partied would
---       hold that party at the door indefinitely, which is exactly the hostage
---       BR.Party.mayEnter's own release conditions were written to avoid.
---   B3. IT IS PER-CONNECTION AND WRITTEN NOWHERE. It lives on the roster entry,
---       dies with it on disconnect, and never reaches KVP or DynamoDB -- so it
---       cannot accumulate across sessions, cannot be replayed into a later one,
---       and a player who abuses it into uselessness fixes it by reconnecting.
---
--- ═══ AND THE CONDITION THAT REVERSES ALL OF THAT ═══
---
--- "Buys nothing" is an argument about today's lobby, not a law. The moment
--- anything ACCRUES to a player for standing in it -- an idle reward, a pass
--- tick, a queue-position bonus, a placeholder that pays for being connected --
--- the exemption starts buying something and a cap stops being optional.
--- Whoever adds the first of those should read this paragraph as addressed to
--- them, because nothing else in the tree will mention it.
---
--- @param src integer
--- @param on boolean  true asks for the hold; false gives it up
--- @return boolean  whether the hold stands after this call
function BR.Roster.setTutorial(src, on)
    local entry = roster[src]
    if not entry then return false end

    on = on == true

    -- GIVING IT UP IS BELIEVED ON SIGHT, AND ONLY THIS DIRECTION IS. Ending the
    -- hold hands the player back to matchmaking, which is the thing the hold was
    -- protecting them from -- there is nobody to stop from doing that, and a
    -- refusal here is how a player gets stranded outside the queue with no
    -- control anywhere that puts them back in. Unconditional, so it also clears
    -- a flag left on an entry by any path that ever stops agreeing with this
    -- one.
    if not on then
        entry.tutorial = nil
        return false
    end

    if entry.tutorial then return true end

    -- B1: A STANDING START, AND BOTH HALVES ARE LOAD-BEARING. Neither implies
    -- the other: a player on the ENDED summary trip home is in LOBBY with a
    -- matchId still attached (applyBucket says so in as many words), and
    -- granting the hold to them would pull a player out of a match that has not
    -- finished publishing their results.
    if entry.state ~= BR.PlayerState.LOBBY or entry.matchId ~= nil then
        print(('[br_core] %s (%d) asked for the tutorial hold from %s -- refused')
            :format(entry.name, src, tostring(entry.state)))
        return false
    end

    entry.tutorial = true

    -- B2: AND IT COSTS THEM THE QUEUE AND THE PARTY.
    --
    -- AFTER the flag is set, not before, so neither verb below can run against a
    -- grant that has not happened yet -- BR.Party.leave broadcasts, and a
    -- broadcast is somewhere a client can answer from.
    --
    -- THE PARTY IS LEFT OUT LOUD. `quiet` exists for switching parties, where
    -- there is a second event on the way that explains the first; there is no
    -- second event here. The mates have to hear it or their own hold at the door
    -- (BR.Party.mayEnter) simply lifts one tick later with nothing anywhere
    -- saying why. Both sentences are already-shipped wording for exactly the
    -- thing that happened -- this player did leave the party.
    --
    -- Nil-guarded on the MODULE rather than the answer: this file loads ahead of
    -- both (br_core/fxmanifest.lua), and a build without either is one where
    -- there is no queue to leave and no party to be in. Same shape as the
    -- cleanup calls in BR.Roster.remove.
    if BR.Lobby and BR.Lobby.leave then BR.Lobby.leave(src) end
    if BR.Party and BR.Party.leave then BR.Party.leave(src) end

    print(('[br_core] %s (%d) is in the tutorial -- held out of matchmaking '
        .. 'and out of parties until they finish'):format(entry.name, src))
    return true
end

--- Is this player taking the IN-GAME half, on the pad, right now?
---
--- ═══ A SECOND FLAG, BECAUSE B1 CANNOT BE WIDENED ═══
---
--- BR.Roster.setTutorial's hold is granted only from a standing start -- LOBBY,
--- no match -- and that restriction is what stops it being a dodge button for a
--- fight or a results publish. The in-game walkthrough runs INSIDE a match, on
--- the warmup pad, so it can never hold that flag and asking it to was the gap
--- the owner hit: the warmup clock ran under every card.
---
--- SO THIS ONE IS THE OPPOSITE SHAPE. It is granted ONLY from WARMUP with a
--- match attached, and it buys nothing except time on the pad: no matchmaking
--- exemption, no party exemption, no state change. What it does is hold the
--- warmup of the match the player is already in -- see BR.Match.tutorialHold.
---
--- ⚠ AND IT COSTS THE ROOM, WHICH IS THE OWNER'S CALL RATHER THAN A FREE WIN.
--- 2026-09-07: "freeze the room for the warmup timer". A warmup is match-wide --
--- there is no per-player countdown to hold -- so one learner reading cards
--- holds everybody else on the pad with them. That is the trade, it is
--- deliberate, and it is why the flag dies the moment the walkthrough does.
---
--- PER-CONNECTION AND WRITTEN NOWHERE, like its sibling: it lives on the roster
--- entry, dies with it, and never reaches KVP or DynamoDB.
--- @param src integer
--- @param on boolean
--- @return boolean  whether the hold stands after this call
function BR.Roster.setTutorialGame(src, on)
    local entry = roster[src]
    if not entry then return false end

    on = on == true

    -- GIVING IT UP IS BELIEVED ON SIGHT, and only this direction is. Ending it
    -- hands the room its clock back, which nobody needs stopping from doing.
    if not on then
        entry.tutorialGame = nil
        return false
    end

    if entry.tutorialGame then return true end

    -- THE MIRROR OF B1. Only from the pad, and only inside a match: anywhere
    -- else there is no warmup to hold and the flag would be a way to stop a
    -- clock that is not running.
    if entry.state ~= BR.PlayerState.WARMUP or entry.matchId == nil then
        print(('[br_core] %s (%d) asked for the warmup hold from %s -- refused')
            :format(entry.name, src, tostring(entry.state)))
        return false
    end

    -- ═══ B2: AND ONLY ONCE PER ACCOUNT, WHICH IS A FACT THIS SIDE ALREADY HAD ═══
    --
    -- Owner, 2026-09-08: a player finished the in-game half in solos, was paid,
    -- queued for squads and "were given deferred matchmaking and shown the
    -- in-game tutorial a second time."
    --
    -- The state test above passed both times, because it is a STATE test: a
    -- player who finished in match 1 is in WARMUP with a matchId in match 2
    -- exactly as a first-timer is. Nothing here asked the only question that
    -- separates them, and the server was the side that could answer it -- the
    -- profile row has said 'done' since the moment they were paid, and
    -- BR.Market.tutorialOf was written to hand it over and had NO CALLERS
    -- ANYWHERE IN THE TREE. This project's orphaned-subsystem pattern, sitting
    -- on the one line that would have refused the second hold.
    --
    -- A CLIENT-ONLY FIX WOULD NOT HAVE BEEN ONE. The page re-arming is what
    -- asked for this hold, and that is fixed on the page too -- but the hold is
    -- the server's to grant, it freezes the WHOLE pad's clock for a day
    -- (WARMUP_HOLD_MS), and a grant that rests on the asker being well behaved
    -- is not a rule. Both sides re-armed; both sides are fixed.
    --
    -- '' IS THE PERMISSIVE ANSWER AND THAT IS DELIBERATE, twice over. The row is
    -- read once per connect inside the inventory fetch, so a read that failed --
    -- or one that has not landed yet -- leaves the account at '' and the hold is
    -- GRANTED. market.lua chose that direction for the offer itself ("costs a
    -- player one toggle they can untick"); the same trade here costs a warmup
    -- its clock rather than costing a genuine first-timer their walkthrough.
    -- BR.Market is nil-guarded for the same reason it is reached through a
    -- global: server/market.lua loads AFTER this file (fxmanifest 542 vs 639),
    -- so this may only ever be a call-time read.
    --
    -- AND /brtutorial HAS TO OUTRANK THE ROW, or this refusal lands on the
    -- owner's own testing path. Owner, 2026-09-08: "i should be able to again
    -- since I'm using `brtutorial`." BR.Tutorial.offerable already grants that
    -- locally; the server's half of it is the DEV BOX, read off the same convar
    -- pair devgate.lua reads. Carrying an exemption on the WIRE was the
    -- alternative and it lost badly: a client-asserted `dev` flag is a
    -- 24-hour freeze of a stranger's warmup for anyone who sends it.
    if not (BR.Dev and BR.Dev.on and BR.Dev.on()) then
        local done = BR.Market and BR.Market.tutorialOf
            and BR.Market.tutorialOf(BR.Roster.licenseOf(src)) or ''
        if done ~= '' then
            print(('[br_core] %s (%d) asked for the warmup hold, but this '
                .. 'account already answered the tutorial (%s) -- refused')
                :format(entry.name, src, done))
            return false
        end
    end

    entry.tutorialGame = true
    print(('[br_core] %s (%d) is taking the in-game tutorial -- match %s holds '
        .. 'its warmup until they are done')
        :format(entry.name, src,
                tostring(entry.matchId and BR.MatchTag(entry.matchId))))
    return true
end

--- Is anybody in this match still reading tutorial cards?
--- @param matchId integer
--- @return integer  how many
function BR.Roster.tutorialGameIn(matchId)
    local n = 0
    BR.Roster.each(function(e)
        return e.tutorialGame == true and e.matchId == matchId
    end, function() n = n + 1 end)
    return n
end

RegisterNetEvent(BR.Net.TUTORIAL_SET)
AddEventHandler(BR.Net.TUTORIAL_SET, function(data)
    data = type(data) == 'table' and data or {}
    BR.Roster.setTutorial(source, data.on)
    -- TWO FLAGS ON ONE MESSAGE, and they are two different holds -- see
    -- BR.Roster.setTutorialGame. `game` is absent from every sender that
    -- predates the in-game half, which reads as false and is correct for them.
    BR.Roster.setTutorialGame(source, data.game)
end)

-- LEAVING THE SERVER IS THE SERVER'S TO DO. The client's own `disconnect`
-- console command is restricted and refuses with "Access denied", so the
-- pause menu asks instead. DropPlayer is the supported route and it means the
-- server sees the departure rather than inferring it from a socket closing.
RegisterNetEvent(BR.Net.LEAVE_SERVER)
AddEventHandler(BR.Net.LEAVE_SERVER, function()
    local src = source
    local entry = BR.Roster.get(src)
    print(('[br_core] %s (%d) left the server from the pause menu')
        :format(entry and entry.name or '?', src))
    DropPlayer(src, 'You left from the pause menu.')
end)

function BR.Roster.add(src)
    local existing = roster[src]
    if existing then
        -- The CHOSEN name wins over the platform one. reconcile() calls this
        -- for every connected player on a cadence, so without the gamertag
        -- here a rename would survive for a few seconds and then silently
        -- revert to the Steam name.
        existing.name = existing.gamertag or GetPlayerName(src) or existing.name
        return existing
    end

    local entry = newEntry(src)
    roster[src] = entry

    -- New joiners start in the LOBBY state, so they get its shared bucket
    -- too -- add() writes the state directly rather than through setState.
    applyBucket(src, entry)

    BR.Broadcast.delta({ op = 'add', src = src, e = BR.Roster.public(entry) })
    print(('[br_core] + %s (%d) joined -- %d connected'):format(entry.name, src, BR.Server.count()))
    return entry
end

--- Remove a player.
---
--- A disconnect mid-match is NOT the same as an elimination: the player is gone,
--- but their squad may still be alive and their placement still matters. So the
--- entry is marked LEFT and removed, and the caller (match.lua) decides what that
--- means for the win condition.
---
--- AND IT IS NOT THE SAME AS NEVER HAVING PLAYED. Removing the entry outright
--- is what made a quit forfeit the entire match record -- publishResults walks
--- the roster, so a departed player produced no row, so br_stats wrote nothing:
--- no XP, no Volts, no match, not even the kills they got before they left
--- (#100). In a battle royale the most common thing a player does after being
--- eliminated is close the game, so that was most of them.
--- @param src integer
--- @return table|nil the removed entry
function BR.Roster.remove(src)
    local entry = roster[src]
    if not entry then return nil end

    entry.state = BR.PlayerState.LEFT

    -- SEAL, don't discard, if they were in a match. The entry leaves the roster
    -- either way -- nothing downstream should count a disconnected player as
    -- present, and the alive count, the squad panel and the win condition all
    -- read the roster -- but it survives in `departed` until the match it
    -- belongs to publishes its results.
    if entry.matchId then
        entry.leftAt = GetGameTimer()

        -- THE LICENSE HAS TO BE RESOLVED NOW. br_stats resolves it at match end
        -- through BR.Identity.ofPlayer(src), and that answers for CONNECTED
        -- players -- by the time the results publish, this source is gone and
        -- the lookup returns nothing. A row written under a guessed key is
        -- worse than one not written, so the key is captured while it is still
        -- knowable and travels with the sealed entry.
        if entry.license == nil and BR.Identity then
            entry.license = BR.Identity.qualified('license', BR.Identity.licenseOf(src))
        end

        departed[#departed + 1] = entry
    end

    roster[src] = nil

    -- Per-player combat bookkeeping goes with them. Server ids are recycled,
    -- so a stale rate-of-fire timestamp or refusal count would be inherited by
    -- whoever connects into that slot next -- and the first thing they would
    -- notice is their opening shot refused as "too fast".
    if BR.Damage then
        if BR.Damage.forget then BR.Damage.forget(src) end
        if BR.Damage.forgetRefusals then BR.Damage.forgetRefusals(src) end
    end
    if BR.Loot and BR.Loot.clearNpcDrops then BR.Loot.clearNpcDrops(src) end
    -- Same recycled-id argument again, with a second reason on top: whoever
    -- this player was in the middle of picking up would otherwise keep a
    -- reviver that no longer exists, and their progress ring would sit at
    -- whatever percentage the disconnect froze it at until the bleed ran out.
    if BR.Combat and BR.Combat.forget then BR.Combat.forget(src) end
    -- Same recycled-id argument, and a worse outcome: the cached voice
    -- channels are what suppress a re-push, so whoever connects into this
    -- slot next would be told nothing and stay in the previous holder's room.
    if BR.Voice and BR.Voice.forget then BR.Voice.forget(src) end

    BR.Broadcast.delta({ op = 'remove', src = src })
    print(('[br_core] - %s (%d) left -- %d connected'):format(entry.name, src, BR.Server.count()))
    return entry
end

--- Seal a COPY of a player's match record, for somebody leaving the MATCH but
--- not the SERVER (#161).
---
--- THE SAME MOVE AS remove(), FOR THE OTHER WAY OUT. A disconnect seals because
--- the entry is about to be deleted; a voluntary leave has to seal because the
--- entry is about to be DETACHED -- `BR.Match.leaveMatch` clears matchId so the
--- player stops hearing this match's traffic, and publishResults finds its rows
--- by matchId. Either way the record has to survive the exit, and until this
--- existed only one of the two ways out was covered: a player who pressed Leave
--- Match forfeited their whole record even from a match that ended normally,
--- which is #100's bug arriving through the door nobody checked.
---
--- A COPY, NOT THE ENTRY ITSELF, and that is the difference from remove(). This
--- player is still connected and still playing -- they will queue again, take
--- damage again, and every one of those writes would land on a sealed record if
--- it were the same table. The entry stays live; the match takes a photograph.
---
--- The license is resolved HERE for the reason #100 gives: they may well close
--- the game before the match they just left finishes dissolving, and by then
--- `licenseOf` answers for nobody.
--- @param src integer
--- @return table|nil the sealed copy
function BR.Roster.sealLeaver(src)
    local entry = roster[src]
    if not entry or not entry.matchId then return nil end

    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    copy.state  = BR.PlayerState.LEFT
    copy.leftAt = GetGameTimer()
    copy.license = BR.Roster.licenseOf(src)

    departed[#departed + 1] = copy
    return copy
end

--- @param src integer
--- @return table|nil
function BR.Roster.get(src)
    return roster[src]
end

--- Mutate an entry and broadcast only what changed.
---
--- Sending the whole entry on every small change would be simpler and much more
--- expensive: at 48 players a state change would push every field to every
--- client. Deltas keep the fanout proportional to what actually happened.
---
--- @param src integer
--- @param changes table  field -> value
--- @return table|nil
function BR.Roster.update(src, changes)
    local entry = roster[src]
    if not entry then return nil end

    local changed = nil
    for k, v in pairs(changes) do
        if entry[k] ~= v then
            entry[k] = v
            -- Only fields the client mirror actually needs are worth sending.
            if PUBLIC_FIELDS[k] then
                changed = changed or {}
                changed[k] = v
            end
        end
    end

    if changed then
        BR.Broadcast.delta({ op = 'update', src = src, e = changed })
    end
    return entry
end

--- Clear fields, and tell clients they were cleared.
---
--- A separate verb from update() because nil cannot travel in a delta: setting
--- `e.squadId = nil` removes the key from the table, so it serialises as though
--- nothing changed and the client keeps the old value forever.
---
--- That is exactly what happened switching a squad match to solo -- the server
--- correctly emptied squadId and every client carried on displaying the squad
--- from the previous match.
---
--- @param src integer
--- @param fields table  array of field names
function BR.Roster.clearFields(src, fields)
    local entry = roster[src]
    if not entry then return end

    local cleared = {}
    for _, k in ipairs(fields) do
        if entry[k] ~= nil then
            entry[k] = nil
            if PUBLIC_FIELDS[k] then cleared[#cleared + 1] = k end
        end
    end

    if #cleared > 0 then
        BR.Broadcast.delta({ op = 'update', src = src, clear = cleared })
    end
end

--- Set a player's state, with the transition logged.
--- State changes are the single most useful thing in a match log when working
--- out why someone did or did not win.
---
--- ═══ `cause` RIDES THE EDGE, AND IT IS NOT A ROSTER FIELD (2026-09-11) ═══
---
--- Owner: "the death sound should not play if the player is dying by method of
--- leaving the match." Leaving IS an elimination here on purpose
--- (BR.Match.leaveMatch -> BR.Combat.eliminate(src, 'left', nil)), so the client
--- sees one identical edge into OUT for "you were killed" and for "you quit" --
--- and it had nothing to tell them apart with. The cause DOES cross the wire
--- already, on KILL_FEED, but that is a different message with no ordering
--- against this one (see the note over BR.NoteDeath in client/state.lua), and an
--- answer that usually arrives in time is wrong exactly when somebody is
--- disconnecting badly.
---
--- SO IT TRAVELS BESIDE `e` RATHER THAN INSIDE IT. `e` is the roster mirror and
--- every key in it is a fact that persists about the player; this is a fact
--- about the TRANSITION, true for one message and meaningless afterwards. Inside
--- `e` it would be a field the client had to remember to clear, and a stale
--- 'left' on the entry would silence a real death in the next round.
---
--- OPTIONAL, AND ABSENT MEANS UNKNOWN. Every other caller passes nothing and
--- gets exactly the message it got before.
--- @param src integer
--- @param state string
--- @param cause string|nil  why this transition happened, for the one consumer
---        that needs it ON the edge rather than in a message that may follow
function BR.Roster.setState(src, state, cause)
    local entry = roster[src]
    if not entry or entry.state == state then return end

    local from = entry.state
    entry.state = state

    -- The bucket rides the state, from the single choke point every state
    -- change already passes through.
    applyBucket(src, entry)

    BR.Broadcast.delta({ op = 'update', src = src, e = { state = state },
                         cause = cause })

    if BR.Server.devMode then
        print(('[br_core]   %s (%d): %s -> %s'):format(entry.name, src, from, state))
    end
end

--- The client-visible view of an entry.
--- @param entry table
--- @return table
function BR.Roster.public(entry)
    local out = {}
    for k in pairs(PUBLIC_FIELDS) do
        out[k] = entry[k]
    end
    return out
end

--- A player's qualified license, resolving and caching it on first ask.
---
--- `newEntry` declares `license = nil` as "filled by br_stats if it is running",
--- and for a long time nothing wrote it -- so whether a player had a license
--- attached depended on whether the ringmaster projection had run for them yet.
--- That was survivable while the only reader was a snapshot. It stopped being
--- survivable when moderation records started being keyed on it: an incident
--- with no license is a case about nobody, and server ids are recycled within
--- the minute.
---
--- SO IT LIVES HERE, once, rather than being re-derived at each call site. It
--- was already being done in two places by the time this was extracted.
--- Cached on the entry, so a roster full of players costs one identifier scan
--- each rather than one per read.
---
--- A licenseless connection stays nil, and nil is what every caller passes on.
--- Inventing a key here would be a ban against the wrong human later.
--- @param src integer
--- @return string|nil
function BR.Roster.licenseOf(src)
    local entry = roster[src]
    if not entry then return nil end
    if entry.license == nil and BR.Identity then
        entry.license = BR.Identity.qualified('license', BR.Identity.licenseOf(src))
    end
    return entry.license
end

--- One player, projected for the admin console. See RINGMASTER_FIELDS.
---
--- `connectedAt` is the wire name for `joinedAt` -- a GetGameTimer() reading,
--- deliberately not a duration, so the console can count it up continuously
--- against the envelope's clock pair instead of receiving a number that is
--- stale on arrival.
--- @param entry table
--- @return table
function BR.Roster.ringmaster(entry)
    BR.Roster.licenseOf(entry.src)

    local out = {}
    for k in pairs(RINGMASTER_FIELDS) do
        out[k] = entry[k]
    end
    out.connectedAt = entry.joinedAt
    return out
end

--- Every player, projected for the admin console.
--- @return table array
function BR.Roster.ringmasterAll()
    local out = {}
    for _, e in pairs(roster) do
        out[#out + 1] = BR.Roster.ringmaster(e)
    end
    return out
end

--- The whole roster, client-visible, for a snapshot.
--- @return table  [src] = public entry
function BR.Roster.publicAll()
    local out = {}
    for src, entry in pairs(roster) do
        out[src] = BR.Roster.public(entry)
    end
    return out
end

--- Iterate players matching a predicate. Convenience so callers do not each
--- write the same pairs() loop with a state check.
--- @param pred function|nil
--- @param fn function  receives (src, entry)
function BR.Roster.each(pred, fn)
    for src, entry in pairs(roster) do
        if not pred or pred(entry) then fn(src, entry) end
    end
end

--- Sealed entries for one match: the players who disconnected before it ended.
---
--- TWO CALLERS, AND THE RULE THEY BOTH OBEY. This said "only the results
--- publisher should call this", and the second one (#172) is the in-game player
--- list: a player who ragequits after cheating is exactly the person still
--- worth reporting, so `BR.Players.listFor` merges these rows in and marks them
--- gone. That is the same permission the publisher has, not a new one -- both
--- are RENDERING a finished record, neither is treating its subject as present.
---
--- WHAT IS STILL FORBIDDEN, and it is the part worth keeping loud: nothing may
--- put a sealed entry back into `roster`, and nothing that counts players may
--- read this. The alive count, the squad panel, the win condition and the
--- console snapshot must all go on seeing a departed player as gone, because
--- they are.
--- @param matchId integer
--- @return table array of entries
function BR.Roster.departedIn(matchId)
    local out = {}
    for _, entry in ipairs(departed) do
        if entry.matchId == matchId then out[#out + 1] = entry end
    end
    return out
end

--- Drop one match's sealed entries. Called at CLEANUP, beside the wipe that
--- resets the same per-match counters on everybody still connected -- so the
--- two halves of "this match is over" stay in one place.
--- @param matchId integer
function BR.Roster.clearDeparted(matchId)
    local kept = {}
    for _, entry in ipairs(departed) do
        if entry.matchId ~= matchId then kept[#kept + 1] = entry end
    end
    departed = kept
end

--- The stamps the server -- and only the server -- has written about this
--- player's health, in the shape both health_solve.lua entry points read.
---
--- ONE BUILDER FOR THE DETECTOR AND THE RULE, which is the property worth
--- having: `auditHealth` decides whether to COUNT a disagreement and
--- `commitSample` decides whether to BELIEVE it, and two hand-built context
--- tables would eventually let a sample be excused by one and refused by the
--- other. Every field is server-written; nothing a client sent reaches here.
---   lastHitAt    every server-applied damage path writes it
---   healUntil    server/inventory.lua and server/ambheal.lua, on ISSUING an
---                INV_EFFECT -- paired with the ceiling the caller adds below
---   settleUntil  a revive, a respawn or a match reset the server wrote
---   rescue       #191, the ambulance ride; server/rescue.lua writes it
--- @param entry table
--- @param now number
--- @return table
local function healthCtx(entry, now)
    return {
        now         = now,
        state       = entry.state,
        rescue      = entry.rescue,
        lastHitAt   = entry.lastHitAt,
        healUntil   = entry.healUntil,
        settleUntil = entry.healthSettleUntil,
    }
end

--- Does this player's ped agree with the ledger the server keeps for them?
---
--- CALLED FROM THE SAMPLER, ONE LINE BEFORE THE LEDGER IS DECIDED, and that
--- position is the whole design: the sampler is the only place both numbers
--- exist at once. The arithmetic and every excuse live in
--- br_lib/shared/health_solve.lua so they are testable without a server; this
--- function is the plumbing that finds the stamps and keeps the tally.
---
--- IT IS A DETECTOR AND IT IS ALLOWED TO DO NOTHING ELSE. It writes two fields
--- on the entry (`healthAudit`, and the report stamp inside it) and prints at
--- most one line per player per match. It must never refuse a sample, adjust a
--- number or change a state -- the moment it does, a false positive stops being
--- a noisy log line and starts being a player who cannot be healed. Refusing is
--- `commitSample`'s job, one call later and under its own flag.
---
--- IT GOT SHARPER WHEN THE LEDGER STOPPED BEING OVERWRITTEN, without a line
--- changing here. The 2026-09-08 audit's second complaint about this detector
--- was that a working exploit scored ZERO: the first sample after the grace
--- window counted, the ledger was then overwritten to match the client, and
--- every later sample had no discrepancy left to measure. Now the ledger holds,
--- so a divergent client keeps scoring on every pass and crosses `reportHp`
--- within a second instead of never.
---
--- NO INCIDENT IS FILED, DELIBERATELY (docs/security.md, and the `refusalBar`
--- note in config/match.lua). Only means-class refusals open an ANTICHEAT case,
--- and a brand-new detector filing cases before anybody has seen its
--- false-positive rate is how a good detector gets discredited. This prints for
--- an operator; promoting it is a decision to make with a playtest in hand.
--- @param src integer
--- @param entry table
--- @param hp number      display hp sampled from the ped THIS pass
--- @param armour number  armour sampled from the ped THIS pass
--- @param now number
local function auditHealth(src, entry, hp, armour, now)
    local cfg = (BR.Config.Combat or {}).healthAudit
    -- `enabled` is compared rather than tested for truthiness for the reason
    -- the whole codebase does it: a convar override can leave a string here,
    -- and `if cfg.enabled then` is true for the string "false".
    if cfg == nil or cfg.enabled == false then return end
    if BR.HealthUnexplainedGain == nil then return end

    -- THE STAMPS ARE ALL SERVER-WRITTEN, and that is the property that makes
    -- this an anticheat rather than a second thing to lie to. See healthCtx.
    local ctx = healthCtx(entry, now)

    local gain, excuse = BR.HealthUnexplainedGain(entry.hp, hp, ctx, cfg)
    entry.healthAudit = BR.HealthTally(entry.healthAudit, gain, excuse)

    -- ARMOUR IS THE SAME WEAKNESS AND IT IS NOT A SMALLER ONE. `entry.armour`
    -- is what BR.Damage.applyHit soaks a hit with before health is touched, and
    -- it is sampled off GetPedArmour on the same line -- so a client pinning its
    -- armour at 100 regenerates the soak four times a second. Tallied separately
    -- because the honest upward path is a different item (a shield potion) with
    -- a different cap, and because a single number would hide which of the two
    -- somebody was actually doing.
    local aGain, aExcuse = BR.HealthUnexplainedGain(entry.armour, armour, ctx, {
        toleranceHp  = cfg.toleranceArmour,
        hurtGraceMs  = cfg.hurtGraceMs,
    })
    entry.armourAudit = BR.HealthTally(entry.armourAudit, aGain, aExcuse)

    if BR.HealthShouldReport(entry.healthAudit, cfg)
       or BR.HealthShouldReport(entry.armourAudit, { reportHp = cfg.reportArmour }) then
        -- Stamped on BOTH, so crossing the second bar later cannot produce a
        -- duplicate line about a player already reported.
        entry.healthAudit.reportedAt = now
        entry.armourAudit.reportedAt = now
        print(('^3[br_core] HEALTH AUDIT: %s (%d) recovered %.0f hp and %.0f armour '
            .. 'this match that the server never issued (peak %.0f in one sample, '
            .. '%d samples) -- see /brhealth^7')
            :format(entry.name, src,
                entry.healthAudit.hp or 0.0, entry.armourAudit.hp or 0.0,
                entry.healthAudit.peak or 0.0, entry.healthAudit.samples or 0))
    end
end

--- Tell one client what its health actually is, because its ped disagrees.
---
--- REFUSING THE RISE FIXES THE SERVER AND LEAVES THE PLAYER WRONG. The ledger is
--- what kills them, what their squad's panel shows, what a shooter's hitmarker
--- is computed against and what the results row is built from -- so a client
--- whose ped has drifted above it is walking around inside a different game.
--- Correcting them is not a punishment and it is not optional: it is the second
--- half of "the server decides", and the audit's fix note names it
--- ("resynchronize divergent clients").
---
--- HEALTH_SYNC IS THE EXISTING VERB and no new one was invented. It is what a
--- revive, a knock and #144's held death already send, in display units, applied
--- absolutely by client/dbno.lua -- "the server says what the number IS and we
--- apply it". A correction is the same sentence said to a client that had
--- stopped listening.
---
--- ONLY ON `REFUSED`, WHICH IS THE WHOLE SAFETY STORY. Every honest way for a
--- ped to read high -- damage still in flight, a heal the server issued, an
--- ambulance rescue, a revive still settling -- comes back from
--- BR.HealthCommit as HOLD or FROZEN, and neither of those reaches this
--- function. A high-ping player is never yanked; a modified one is corrected
--- once a second.
---
--- THROTTLED, because the sampler runs at 4Hz and four corrections a second is
--- a fight with the engine rather than a correction. `resyncMs` of zero or less
--- turns the correction off and leaves the refusal standing, which is the
--- setting for a playtest that wants the ledger enforced silently.
--- @param src integer
--- @param entry table
--- @param cfg table
--- @param now number
local function resyncHealth(src, entry, cfg, now)
    -- Guarded for the unit suites, which load this file without the Cfx
    -- runtime -- the same guard applyBucket carries and for the same reason.
    if not TriggerClientEvent then return end

    local every = tonumber(cfg.resyncMs) or 1000
    if every <= 0 then return end
    if entry.healthResyncAt and (now - entry.healthResyncAt) < every then return end

    entry.healthResyncAt = now
    -- COUNTED PER MATCH, and printed by /brhealth beside the tally. An operator
    -- reading "counted 240 hp" wants to know whether the server has been
    -- shouting the real number back at that player for four minutes, and this is
    -- the only place that fact exists.
    entry.healthResyncs = (entry.healthResyncs or 0) + 1

    TriggerClientEvent(BR.Net.HEALTH_SYNC, src, {
        hp     = math.floor((entry.hp or 0.0) + 0.5),
        armour = math.floor((entry.armour or 0.0) + 0.5),
    })
end

--- Decide what the ledger holds after this sample, and write it.
---
--- ═══ THIS IS WHY THE SAMPLER IS ASYMMETRIC. READ THIS BEFORE CHANGING IT ═══
---
--- This function used to be one line -- `BR.Roster.update(src, { hp = hp,
--- armour = armour })` -- and that line was the highest-impact finding of the
--- 2026-09-08 security audit. `entry.hp` is what BR.Damage.applyHit subtracts
--- from and `hp` is a number the OWNING CLIENT chose, so the assignment handed
--- the authority on "how much health does this player have" back to the player:
--- the server took 25 off, told the client to apply it, a modified client
--- ignored the instruction, and 250ms later this line copied the untouched 100
--- back over the server's 75. Reproduced end to end, with no forged identity and
--- no administrator rights.
---
--- THE FIX THAT LOSES, AND IT IS THE ONE EVERYBODY REACHES FOR FIRST: stop
--- reading the ped. It cannot be done. The sampler exists BECAUSE the engine
--- owns damage the server never took over -- falls, fire, drowning, cars, the
--- world -- and the server models none of them. A ledger that refused the engine
--- outright would mean a player could step off a skyscraper and the server would
--- never find out. So the read stays and the WRITE became conditional.
---
--- THE SECOND FIX THAT LOSES: keep the excuse windows as they were and simply
--- stop counting inside them. That is what shipped in the detector, and the
--- audit's point was precisely that a grace period which COMMITS an unverified
--- increase is not a grace period -- it is the exploit with a comment on it.
---
--- WHAT IT IS NOW: the ledger is authoritative and monotonic downward, except
--- where the SERVER itself authorized a rise. Every clause lives in
--- br_lib/shared/health_solve.lua's BR.HealthCommit, next to the detector that
--- shares its stamps, so it is testable without a server; this function is the
--- plumbing that carries the ceilings in and the correction out.
---
--- THE LEGITIMATE UPWARD PATHS, ALL OF THEM, AND HOW EACH IS AUTHORIZED. Every
--- one was found by grepping for writes to `entry.hp` and `entry.armour`:
---
---   * A RESPAWN, A MATCH RESET AND THE WARMUP PAD write the ledger directly
---     (BR.Match.resetPlayer, BR.Combat.reviveWarmup). The pad is not ALIVE, so
---     the rule does not apply there at all -- and where it does, the write is
---     the server's own and the ped follows it.
---   * A CPR REVIVE and #144's HELD REVIVE (BR.Combat.revive, reviveHeld) write
---     the ledger and stamp `healthSettleUntil` first.
---   * THE AMBULANCE REVIVE (server/revivekey.lua) does the same, on its own
---     code path, which is why both are named here rather than "a revive".
---   * A KNOCK writes the DBNO floor -- and a downed player is skipped by the
---     caller anyway, because their health is a bleed countdown.
---   * MED KITS, BANDAGES AND ARMOUR PLATES (server/inventory.lua) and THE
---     AMBULANCE HEAL (server/ambheal.lua) are the only paths that do NOT write
---     the ledger: they send the client a TARGET and let it walk its own ped up.
---     Those two echo the target onto the entry as `grantHpTo` / `grantArmourTo`
---     beside the `healUntil` they already stamped, and this is where it is
---     spent. The window says a heal is happening; the ceiling says how much.
---
--- ARMOUR IS A SECOND CALL, NOT A SECOND RULE. It has its own ceiling and its
--- own tolerance -- the honest upward path is a different item with a different
--- cap -- but the shape is identical, and `entry.armour` matters just as much:
--- it is what applyHit soaks a hit with BEFORE health is touched, so a client
--- pinning its armour at 100 regenerates the soak four times a second.
---
--- FAIL-OPEN IF THE SOLVER IS MISSING, deliberately. br_lib is a separate
--- resource; if it has not loaded, the old behaviour is the one that keeps a
--- match playable, and `auditHealth` above makes the same call for the same
--- reason. The manifest gate in tools/verify.sh is what stops that being a
--- silent live configuration.
--- @param src integer
--- @param entry table
--- @param hp number      display hp sampled from the ped THIS pass
--- @param armour number  armour sampled from the ped THIS pass
--- @param now number
local function commitSample(src, entry, hp, armour, now)
    local cfg = (BR.Config.Combat or {}).healthAudit or {}

    local nextHp, nextArmour = hp, armour

    -- A BOOLEAN RATHER THAN THE VERDICT STRINGS THEMSELVES, and it is not
    -- tidiness: `BR.HealthVerdict` lives in the same file as BR.HealthCommit, so
    -- on the fail-open path where that file has not loaded, testing a verdict
    -- out here would index a nil table and take the whole sampler down for every
    -- player -- turning a graceful degradation into an outage.
    local refused = false

    if BR.HealthCommit ~= nil then
        local ctx = healthCtx(entry, now)
        local hpWhy, armourWhy

        ctx.grantTo = entry.grantHpTo
        nextHp, hpWhy = BR.HealthCommit(entry.hp, hp, ctx, cfg)

        -- THE ARMOUR CONFIG IS BUILT RATHER THAN PASSED WHOLE, so that
        -- `toleranceArmour` reaches the solver as the tolerance it is. Reusing
        -- `cfg` would silently measure armour against the HEALTH tolerance,
        -- which is the same trap the detector's armour call sidesteps three
        -- functions up -- and `enforce` has to be carried across explicitly or
        -- the kill switch would turn off health and leave armour enforced.
        ctx.grantTo = entry.grantArmourTo
        nextArmour, armourWhy = BR.HealthCommit(entry.armour, armour, ctx, {
            enforce      = cfg.enforce,
            toleranceHp  = cfg.toleranceArmour,
            hurtGraceMs  = cfg.hurtGraceMs,
        })

        refused = hpWhy == BR.HealthVerdict.REFUSED
               or armourWhy == BR.HealthVerdict.REFUSED
    end

    if nextHp ~= entry.hp or nextArmour ~= entry.armour then
        BR.Roster.update(src, { hp = nextHp, armour = nextArmour })
    end

    if refused then resyncHealth(src, entry, cfg, now) end
end

--- Server-side position sampling.
---
--- Read from the server rather than reported by the client, deliberately. The
--- storm, the spectator camera and the anti-cheat all depend on positions, and a
--- client-reported position is exactly the thing a cheater would lie about. The
--- server can read every player's coordinates regardless of scope, so there is no
--- reason to ask.
local function samplePositions()
    local now = GetGameTimer()
    for src, entry in pairs(roster) do
        -- GET_PLAYER_PED is declared as `Entity GET_PLAYER_PED(char* playerSrc)`
        -- -- playerSrc is documented as a STRING. Passing the numeric roster key
        -- returned 0 for every player, so positions silently never sampled and
        -- brwhy reported "not sampled yet" indefinitely.
        local ped = GetPlayerPed(tostring(src))
        entry.ped = ped

        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            entry.pos   = { x = c.x, y = c.y, z = c.z }
            entry.posAt = now

            -- Health is read the same way, for the same reason. This is what
            -- makes the reconciliation in the combat pipeline possible later.
            entry.engineHp = GetEntityHealth(ped)
            entry.engineArmour = GetPedArmour(ped)

            -- ...and converted into the DISPLAY value the rest of the system
            -- uses. Sampling the engine value without doing this left entry.hp
            -- pinned at its initial 100 forever: brwhy reported full health for
            -- a player lying dead at the bottom of a cliff, and every squad
            -- panel would have shown the same.
            --
            -- Rounded to an integer so a stationary player does not generate a
            -- delta every half second from float noise -- Roster.update only
            -- broadcasts fields that actually changed.
            local hp = math.floor(BR.ToDisplayHp(entry.engineHp) + 0.5)
            local armour = math.floor((entry.engineArmour or 0) + 0.5)

            -- ...AND BEFORE THE LEDGER IS DECIDED, ASK WHETHER IT AGREED.
            --
            -- THE DISAGREEMENT IS ONLY VISIBLE HERE, between the read and the
            -- write, which is why the call sits in the sampler rather than in a
            -- sweep of its own: on any pass where the two numbers end up equal
            -- there is nothing left to measure afterwards.
            --
            -- IT COUNTS AND DOES NOT ACT. Nothing in it changes `hp`, `armour`
            -- or anybody's state; the ledger rule is the NEXT call, under its
            -- own flag, so a noisy detector and a wrong refusal stay two
            -- separate incidents with two separate switches.
            auditHealth(src, entry, hp, armour, now)

            -- A DOWNED PLAYER'S HEALTH IS THE LEDGER'S, NOT THE PED'S.
            --
            -- Their ped is parked at the DBNO floor and their real "health" is
            -- a countdown living on this entry, so sampling would achieve one
            -- of two wrong things: agree with the floor and churn nothing, or
            -- -- on a client that was slow to apply the knock, or is simply
            -- ignoring it -- drag the entry back to full and show the squad
            -- panel a downed teammate on 100hp.
            --
            -- KEPT AS ITS OWN GUARD even though BR.HealthCommit would refuse
            -- the rise anyway: that refusal would also RESYNCHRONISE a downed
            -- player's ped four times a second, against a floor client/dbno.lua
            -- is already holding for its own reasons. DBNO simply is not the
            -- ledger's business.
            --
            -- Written as a condition rather than an early return ON PURPOSE:
            -- this is the body of a loop over the WHOLE roster, and a `return`
            -- here would stop sampling everybody who sorted after the first
            -- downed player -- positions included.
            if entry.state ~= BR.PlayerState.DBNO then
                commitSample(src, entry, hp, armour, now)
            end
        end
    end
end

--- Reconcile the roster against reality.
---
--- playerJoining and playerDropped are reliable, but a resource restart mid-session
--- leaves us with an empty roster and a server full of players, and a missed
--- event would otherwise persist for the whole match. Cheap enough to just check.
local function reconcile()
    local seen = {}

    for _, idStr in ipairs(GetPlayers()) do
        local src = tonumber(idStr)
        if src then
            seen[src] = true
            if not roster[src] then
                print(('[br_core] reconcile: adding missing player %d'):format(src))
                BR.Roster.add(src)
            end
        end
    end

    for src in pairs(roster) do
        if not seen[src] then
            print(('[br_core] reconcile: removing stale player %d'):format(src))
            BR.Roster.remove(src)
        end
    end
end

-- Connection events. These are SERVER-side and global -- unaffected by entity
-- scoping, which is the entire reason the roster is built from them.
AddEventHandler('playerJoining', function()
    BR.Roster.add(source)
end)

AddEventHandler('playerDropped', function(reason)
    local entry = roster[source]
    if entry and BR.Server.devMode then
        print(('[br_core]   drop reason: %s'):format(tostring(reason)))
    end
    BR.Roster.remove(source)
end)

--- The rate used when the configured one is unusable.
---
--- A LAST RESORT, NOT A SECOND COPY OF THE SETTING. It is only ever reached
--- when `posSampleHz` is nil, zero or negative -- i.e. when somebody has
--- already made a mistake -- and its job is to keep the server sampling rather
--- than to express a policy. It is kept equal to the shipped config value so a
--- broken config degrades to the behaviour everyone has played, and
--- tools/test_roster.lua asserts that equality rather than leaving two numbers
--- free to drift, which is the bug this whole change is about.
local FALLBACK_POS_SAMPLE_HZ = 4

--- How often positions are sampled, in milliseconds, FROM THE CONFIG.
---
--- THIS USED TO BE THE LITERAL 250 AND THE CONFIG USED TO SAY 2 Hz. Both
--- statements were in the repository at once, describing the same thing,
--- disagreeing by a factor of two, with nothing able to notice -- because
--- `BR.Config.Match.posSampleHz` had no readers at all. The hardcoded number
--- was the correct one and the documented one was the value that had been tried
--- and reverted, which is the worst way round for that pair to be.
---
--- 4 Hz IS THE RATE AND THE REASON IT IS NOT 2 IS KEPT HERE DELIBERATELY: squad
--- beacons are drawn straight from this sampling, and at 2 Hz a teammate's dot
--- visibly HOPPED rather than moved. It also halves the staleness the loot claim
--- check has to allow for. 2 Hz is a repeat of a rejected experiment, not a
--- saving -- and the number now lives in the config where somebody looking to
--- turn it down will meet that sentence before they do.
---
--- GUARDED, BECAUSE THE ALTERNATIVE IS DIVIDING BY IT BLINDLY. `1000 / 0` is
--- `inf` in Lua and `math.floor(inf)` raises -- so a typo'd config would not
--- misbehave, it would take the resource down at load, and the traceback would
--- point here rather than at the line someone edited. nil and negatives are the
--- same class of answer. A bad value falls back to the shipped rate and says so
--- loudly; it does not silently pick something.
---
--- Exposed rather than local so the guard itself is testable with values no
--- shipped config would ever hold.
--- @param hz number|nil  defaults to BR.Config.Match.posSampleHz
--- @return integer milliseconds
function BR.Roster.sampleIntervalMs(hz)
    if hz == nil then hz = BR.Config.Match.posSampleHz end
    hz = tonumber(hz)

    if not hz or hz <= 0 then
        print(('^3[br_core] roster: posSampleHz is %s, which is not a rate -- '
            .. 'sampling at %d Hz instead^7')
            :format(tostring(hz), FALLBACK_POS_SAMPLE_HZ))
        hz = FALLBACK_POS_SAMPLE_HZ
    end

    -- The same shape server/broadcast.lua uses for deltaFlushHz and digestHz,
    -- so all three rates are derived one way. `math.max(1, ...)` because a
    -- config above 1000 Hz would floor to zero and give the scheduler a job
    -- with no interval.
    return math.max(1, math.floor(1000 / hz))
end

BR.Sched.every(BR.Roster.sampleIntervalMs(), 'roster.positions', samplePositions)
BR.Sched.every(5000, 'roster.reconcile', reconcile)

--- What the health audit has seen. Read-only, and the excuse breakdown is the
--- point of it.
---
--- THE `excused` COLUMNS ARE THE FALSE-POSITIVE AUDIT and they are why this verb
--- exists rather than leaving the counters to the console line. The first
--- question anybody sensible asks of a new detector is "what if it is wrong",
--- and the only honest answer is a list of what it threw away: a playtest that
--- ends with `counted 0` and a healthy spread of `hurt` and `healing` is the
--- detector working. A playtest that ends with `counted` above zero on an honest
--- player is a bug HERE, not a cheat, and the numbers beside it say which window
--- was too short.
RegisterCommand('brhealth', function()
    local cfg = (BR.Config.Combat or {}).healthAudit or {}
    print('=== health audit ===')
    print(('  enabled %s   tolerance %s hp / %s armour   hurt grace %sms')
        :format(tostring(cfg.enabled), tostring(cfg.toleranceHp),
            tostring(cfg.toleranceArmour), tostring(cfg.hurtGraceMs)))
    print(('  heal settle %sms   revive settle %sms   report at %s hp / %s armour')
        :format(tostring(cfg.healSettleMs), tostring(cfg.settleMs),
            tostring(cfg.reportHp), tostring(cfg.reportArmour)))
    -- THE LEDGER RULE'S OWN LINE, and it goes first among the per-player rows
    -- for the reason the whole verb exists: "counted 240 hp" means something
    -- different depending on whether the ledger was being surrendered back to
    -- the client the whole time. An operator reading this report must be able to
    -- see which of the two builds they are looking at without reading the config.
    print(('  ledger enforced %s   resync every %sms')
        :format(tostring(cfg.enforce ~= false), tostring(cfg.resyncMs)))

    local any = false
    for src, entry in pairs(roster) do
        local h = entry.healthAudit
        local a = entry.armourAudit
        if h or a then
            any = true
            local parts = {}
            for excuse, n in pairs((h or {}).excused or {}) do
                parts[#parts + 1] = ('%s %d'):format(excuse, n)
            end
            table.sort(parts)
            print(('  %s (%d): counted %.0f hp / %.0f armour  peak %.0f  samples %d  resyncs %d%s')
                :format(entry.name, src,
                    (h or {}).hp or 0.0, (a or {}).hp or 0.0,
                    (h or {}).peak or 0.0, (h or {}).samples or 0,
                    entry.healthResyncs or 0,
                    (h or {}).reportedAt and '  [REPORTED]' or ''))
            if #parts > 0 then
                print(('      excused: %s'):format(table.concat(parts, '  ')))
            end
        end
    end
    if not any then
        print('  nothing sampled yet')
    end
end, true)

-- Players already connected when the resource starts (a restart mid-session).
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    Citizen.SetTimeout(1000, reconcile)
end)

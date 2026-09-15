-- Spectate sessions: who is watching whom, and whether they are allowed to.
--
-- THE SERVER OWNS THE TARGET AND THE CLIENT OWNS THE CAMERA. Everything about
-- who may be looked at is decided here and in br_lib/shared/spectate_solve.lua;
-- the client is told one target at a time and never sees a candidate list. That
-- is the same rule chat's `squad` channel follows and for the same reason -- a
-- client-side filter is not a privacy boundary.
--
-- IT IS ALSO THE ONLY SIDE THAT CAN SEE A TARGET AT ALL. Under OneSync a player
-- across the map is out of the spectator's scope, so the client cannot read
-- their position even if it were allowed to. roster.lua already samples every
-- player's coordinates server-side (for the storm, the anticheat and this), so
-- the feed below is a projection of a sample that was already being taken.
--
-- ═══ TWO CALLERS, TWO POLICIES, ONE SESSION TABLE ═══
--
--   player  a dead player watching their own squad, widening only once the
--           squad is gone. spectate_solve.playerTargets.
--   admin   the console pointing a moderator at one named person.
--           spectate_solve.adminTargets, and an audit row for every session.
--
-- ═══ THE RECYCLED SERVER ID ═══
--
-- FiveM recycles server ids within the minute, and a camera still pointed at a
-- departed player is the same class of bug as a report filed against a recycled
-- id -- which this project has already been bitten by (br_ringmaster's
-- findByLicense carries the other half of that scar). So a session remembers the
-- target's LICENSE as well as their id, and the feed re-checks the pair on every
-- push. A disconnect handler is the fast path; the license check is what makes
-- the fast path optional rather than load-bearing.

BR = BR or {}
BR.Spectate = {}

--- [watcherSrc] = session
---
--- ONE SESSION PER WATCHER, and the table is keyed that way so it cannot be two.
--- A second start replaces the first, which is the answer a player would predict
--- and the one that cannot leak a camera.
---
---   target        integer   server id being watched
---   targetLicense string|nil  who that id was when the session opened
---   name          string    for the audit row and the client's own display
---   kind          'player' | 'admin'
---   startedAt     integer   GetGameTimer()
---   commandId     string|nil  admin only: the console's audit join key
---   adminLicense  string|nil  admin only
local sessions = {}

--- [targetSrc] = { [watcherSrc] = true }
---
--- THE REVERSE INDEX EXISTS FOR ONE EVENT: playerDropped. Without it, a
--- disconnect would walk every session on the server to find the ones pointed at
--- the leaver -- cheap at 48 and the wrong shape at the 2048 this project is
--- heading for. Kept in step with `sessions` by exactly two functions, below.
local watchers = {}

local function unwatch(src, target)
    local w = watchers[target]
    if not w then return end
    w[src] = nil
    if next(w) == nil then watchers[target] = nil end
end

local function watch(src, target)
    local w = watchers[target]
    if not w then
        w = {}
        watchers[target] = w
    end
    w[src] = true
end

-- ------------------------------------------------------------- microphone ---

--- A SPECTATOR MAY LISTEN AND MAY NOT TALK. Unconditional, both kinds.
---
--- "whoever is the spectator should NEVER be able to talk, only listen" -- the
--- owner. It is not a config key and not a policy that varies by `kind`: a dead
--- player narrating their squad's fight and an admin whose voice arrives out of
--- nowhere beside a suspect are the same defect, and the second is worse.
---
--- IT IS CALLED FROM EXACTLY TWO PLACES BECAUSE THERE ARE EXACTLY TWO EDGES --
--- `sessions[src]` gaining an entry and losing one. Both creation sites
--- (`resolve` for a player, `adminStart` for an admin) funnel through the same
--- call, and `BR.Spectate.stop` is the only teardown; anything that adds a
--- third edge without coming here is a spectator with an open microphone.
---
--- THE MUTE ITSELF IS SERVER-SIDE -- see BR.Voice.setSpectatorMuted, which
--- argues why the client's own gag is not enough on its own and why muted is
--- deliberately not deafened.
--- @param src integer
--- @param on boolean
local function micFor(src, on)
    if BR.Voice and BR.Voice.setSpectatorMuted then
        BR.Voice.setSpectatorMuted(src, on)
    end
end

-- ------------------------------------------------------------------ audit ---

--- Tell the console that an admin session started, moved or ended.
---
--- THE GAME EMITS THE FACT; THE CONSOLE WRITES THE ROW. This is a plain
--- server-side TriggerEvent into br_ringmaster, which is the direction this
--- project's cross-resource traffic already runs (server/ringmaster.lua's
--- snapshot, server/incident.lua's refusals). br_core does not know what an
--- outbox is and must not: br_ringmaster owns the wire, and br_core would be
--- depending on the console if it reached for one.
---
--- PLAYER SESSIONS ARE NOT AUDITED, deliberately. An admin watching somebody who
--- does not know they are being watched is the class of action the audit log
--- exists for -- the same as a kick or a ban. A player watching their own
--- squadmate is gameplay, and filing a row for every death in every match would
--- bury the rows that matter under the ones that do not.
--- @param s table    the session
--- @param phase string 'start' | 'stop'
--- @param reason string|nil
local function audit(s, phase, reason)
    if s.kind ~= 'admin' then return end
    TriggerEvent('br:ringmaster:spectate', {
        commandId     = s.commandId,
        adminLicense  = s.adminLicense,
        targetLicense = s.targetLicense,
        targetName    = s.name,
        phase         = phase,
        reason        = reason,
        -- MILLISECONDS WATCHED, not two timestamps for the console to subtract.
        -- Every clock in this game is GetGameTimer(), which is meaningless the
        -- moment it leaves the box (br_ringmaster/server/main.lua's clockPair
        -- note); a duration survives the trip and a raw reading does not.
        durationMs    = (phase == 'stop') and (GetGameTimer() - s.startedAt) or nil,
    })
end

-- ------------------------------------------------------------------- wire ---

--- A cheap fingerprint of an inventory payload, for the feed's dedupe.
---
--- WHY NOT JUST SEND IT EVERY TICK. The feed runs at 250 ms per SESSION, and
--- late in a match most of the lobby is dead and watching somebody -- so "send
--- it anyway" is the whole roster's inventory crossing the wire four times a
--- second for the rest of the round. client/state.lua's HUD push makes the same
--- argument in the same words ("600 pointless messages a minute").
---
--- IT COVERS WHAT THE BAR DRAWS AND NOTHING ELSE: the five slots' item, count
--- and clip, the ammo pools, and which slot is in hand. `using` is deliberately
--- excluded -- its `endsAt` is a timestamp that changes on every tick of a
--- bandage, which would defeat the dedupe entirely and resend the whole payload
--- 4 Hz for the duration of every heal.
--- @param p table|nil  a BR.Inv.publicFor result
--- @return string
local function invSig(p)
    if not p then return '' end
    local out = {}
    for i = 1, #p.slots do
        local s = p.slots[i]
        out[#out + 1] = s
            and ('%s:%s:%s'):format(tostring(s.id), tostring(s.count),
                                    tostring(s.clip))
            or '-'
    end
    -- Ammo pools are a map, so they are read through a sorted key list; pairs()
    -- order is not stable in Lua and an unstable signature is a dedupe that
    -- resends at random.
    local keys = {}
    for k in pairs(p.ammo or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = ('%s=%s'):format(k, tostring(p.ammo[k]))
    end
    out[#out + 1] = 'a' .. tostring(p.active)
    return table.concat(out, '|')
end

local function push(src, s)
    local e = BR.Roster.get(s.target)
    local pos = e and e.pos

    -- ═══ THE TARGET'S INVENTORY RIDES THIS FEED, AND ONLY THIS FEED ═══
    --
    -- "the health/shield/inventory don't show properly. They should be fully
    -- populated" -- the owner. Health and shield need nothing new: `hp` and
    -- `armour` are already in roster.lua's PUBLIC_FIELDS, so every client
    -- already holds them for every player in the match and the spectator's HUD
    -- reads its own mirror. A second copy on this wire would be two
    -- representations of one fact, which is this project's signature bug.
    --
    -- AN INVENTORY IS NOT PUBLIC AND MUST NOT BECOME SO. It is not in
    -- PUBLIC_FIELDS and it is not broadcast anywhere; knowing what somebody is
    -- holding is exactly the thing a wallhack wants. So it travels on THIS
    -- event, to ONE recipient, chosen by the same server-side policy that
    -- decided they may look at this player at all (spectate_solve). A spectator
    -- learns nothing about anybody they are not already watching, and the
    -- moment the session ends the pushes stop.
    --
    -- IT IS NOT SENT AT ALL FOR A TARGET WHOSE POSITION WE WOULD NOT SEND
    -- EITHER -- the license re-check in the feed runs before this is reached,
    -- so a recycled server id stops the session rather than handing the new
    -- occupant's loadout to a stranger.
    local inv = BR.Inv and BR.Inv.publicFor and BR.Inv.publicFor(s.target) or nil
    local sig = invSig(inv)
    local sendInv = (sig ~= s.invSig)
    s.invSig = sig

    TriggerClientEvent(BR.Net.SPECTATE_SET, src, {
        targetSrc = s.target,
        name      = s.name,
        admin     = s.kind == 'admin',
        -- ABSENT RATHER THAN ZEROED when the target has not been sampled yet.
        -- (0,0,0) is a real place in the ocean and the camera would go there;
        -- a missing position leaves the camera where it was for one push, which
        -- is what a sample gap actually looks like.
        x = pos and pos.x, y = pos and pos.y, z = pos and pos.z,
        -- ABSENT WHEN UNCHANGED, and absent is NOT "empty" -- the client holds
        -- the last one it was given rather than clearing on a quiet tick. An
        -- inventory that blinked out every time nothing happened would be the
        -- reported bug with extra steps.
        inv = sendInv and inv or nil,
    })
end

--- End a session. Safe to call for a player who has none.
--- @param src integer
--- @param reason string  'stopped' | 'left' | 'target-left' | 'no-targets' | ...
--- @param final boolean|nil  ALSO tell the client not to ask again for the rest
---        of this match -- see BR.Spectate.onEliminated and the `final` note over
---        BR.Net.SPECTATE_SET. Absent on every ordinary stop, which is every
---        caller that existed before it: a session that ends because a target
---        left or a watcher was revived says nothing about the MATCH.
--- @return boolean  was anything running?
function BR.Spectate.stop(src, reason, final)
    local s = sessions[src]
    if not s then return false end

    sessions[src] = nil
    unwatch(src, s.target)
    -- THE MICROPHONE COMES BACK BEFORE ANYTHING ELSE CAN FAIL. Ordered ahead of
    -- the audit and the client push on purpose: those two reach other resources
    -- and a raise in either would otherwise leave a player who has stopped
    -- spectating unable to speak for the rest of the round, with nothing on
    -- their screen to explain it.
    micFor(src, false)
    audit(s, 'stop', reason)

    -- TOLD EVEN IF THEY ARE GONE. TriggerClientEvent to a departed source is a
    -- no-op, and the alternative -- checking first -- is a second place that can
    -- disagree with the roster about who is here.
    TriggerClientEvent(BR.Net.SPECTATE_SET, src,
                       { stop = true, reason = reason, final = final == true or nil })
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE ELIMINATION THAT DECIDES THE MATCH CLOSES THE CAMERA
--
-- "whenever the 2nd to last player (or squad) dies - they should not go
-- immediately to spectate and just show the verdict and fade to black like
-- normal." -- the owner, 2026-09-11.
--
-- ═══ WHY THE SERVER SAYS SO AND THE CLIENT DOES NOT WORK IT OUT ═══
--
-- The obvious client-side rule is "do not open a session if the match has
-- ENDED", and it is a race it can lose. The victim's OUT edge and the match's
-- transition to ENDED are two messages with no ordering between them, sent from
-- two different places -- BR.Roster.setState here, BR.Match.transition on the
-- 250ms match tick -- and client/spectate.lua's ask fires on a TIMER after the
-- death verdict rather than on either of them. A client that had not yet seen
-- ENDED would ask, be given a camera, and have it taken away a fraction of a
-- second later: the flicker the owner is asking to remove, with an extra step.
--
-- SO THE FACT TRAVELS WITH THE ELIMINATION. This runs inside
-- BR.Combat.eliminate, in the same synchronous call that writes the death, which
-- is BEFORE any client can have reacted to it -- and it does two things that
-- close the race from both ends:
--
--   * IT LATCHES ON THE MATCH INSTANCE, so `resolve` below refuses every ask
--     that arrives afterwards however late and however often. That is the half
--     that cannot be lost: no camera is ever created, so there is nothing to
--     flicker, even if the message the next paragraph sends never arrives.
--   * IT TELLS THE CLIENTS, so they do not even ask. That is the half that
--     keeps the request off the wire and out of client/spectate.lua's retry
--     budget.
--
-- ═══ THE PREDICATE, AND WHY IT IS TWO COUNTS RATHER THAN ONE ═══
--
-- "Did this death leave one squad standing" is not "one squad is standing": a
-- dev match that STARTED with one squad has one squad standing from the first
-- tick of PLAYING, and winConditionMet (server/match.lua) carves it out
-- explicitly so a lone developer can sit in the world and poke at it. A
-- predicate of `squadsAlive <= 1` would seal that match on the first death and
-- take spectating away from exactly the person who has to test it.
--
-- So the question asked is the EDGE: the field was two or more squads before
-- this elimination and is one or fewer after it. That reads as the owner's own
-- sentence -- the second-to-last squad just went out -- and it keeps the dev
-- match out WITHOUT a second copy of winConditionMet's carve-out to drift from.
--
-- `squadsBefore` IS COMBAT'S `placement`, WHICH IS ALREADY THAT COUNT.
-- BR.Combat.eliminate reads BR.Server.squadsAlive(m) before it writes anything
-- and calls it the victim's placement; a second walk of the roster here would be
-- the same number arrived at twice and the second one could disagree.
--
-- AND THE "AFTER" COUNT IS BR.Server.squadsAlive, WHICH IS THE WIN CONDITION'S
-- OWN. Deliberately not standingSquadsBesides, one file over: that one EXCLUDES
-- DBNO, because it answers "is there anybody left to fight over this knock",
-- and isInMatch counts DBNO because a downed player is coming back. Using the
-- narrower count here would seal a match that is not over -- three squads, one
-- of them entirely downed in an ambulance -- and the losing side would lose
-- their camera while the round was still being played.
--
-- ═══ WHO IS TOLD: EVERY PLAYER IN THE MATCH WHO IS NOT IN THE FIGHT ═══
--
-- Not "the squad that just lost". The owner's sentence is about a group -- in
-- squads the second-to-last SQUAD dies, and its other members are already OUT
-- and may already be watching -- and once the match is decided the set "players
-- who could still open a camera in it" and the set "players it should be closed
-- for" are the same set: everybody who is not isInMatch. So there is no squad
-- bookkeeping here at all, and the group case falls out of the match-wide answer
-- rather than out of a rule about squads that could be got wrong.
--
--   * a member of that squad ALREADY WATCHING a mate gets this as the stop that
--     ends their session -- the one teardown, so the microphone comes back and
--     the audit row is closed with a duration. They are not left in a camera
--     with nothing to watch.
--   * a member who is OUT with nothing running gets the latch alone.
--   * a member who is DBNO when it lands is isInMatch and is not told, and that
--     is consistent rather than lucky. squadsAlive COUNTS DBNO, so a squad with
--     somebody on the floor is a squad that is still standing -- which means the
--     death that decided the match cannot have come from it. The only downed
--     player who can exist at this moment is on the winning side, which is the
--     ambulance ride, whose whole feature is that being down is survivable; and
--     their bleed clock stops with the match rather than finishing them
--     (server/combat.lua's combat.dbno gate). A LOSING squad's downed member
--     reaches this function later, on their own bleed-out, as the deciding
--     elimination itself -- and is sealed on that edge like any other victim.
--   * the winners are not told either, for the same test. A living player has no
--     camera to close and no ask to suppress.
--
-- AND IT IS NOT GATED ON THE MATCH BEING IN PLAYING, which is the obvious extra
-- condition and would buy nothing. The one way to reach this before PLAYING is a
-- LEAVER -- 'left' is the single cause that skips holdForStart -- and every
-- player who is OUT before a match starts is #144's HELD death, which mayWatch
-- refuses a camera to anyway. So the pre-match case seals a match nobody could
-- have been watching, and that match's one remaining squad is ended by
-- winConditionMet within the grace period of PLAYING regardless.
--
-- AN ADMIN'S SESSION IS NOT TOUCHED, which is the one policy this must not
-- reach. A moderator watching somebody in this match is almost always ALIVE and
-- filtered out by the test above; the `kind` check covers the remaining case, an
-- admin who died in the round and then opened a console session. The match
-- ending is not a reason to end a moderation session, and adminStart is not
-- gated by the seal either -- the latch governs what a PLAYER may ask for.
-- ═══════════════════════════════════════════════════════════════════════════

--- A player has just been eliminated. Was that the one that ended the match?
---
--- @param m table            the match they were in
--- @param squadsBefore integer  BR.Server.squadsAlive(m) as it read BEFORE this
---        elimination was written to the roster -- combat.lua's `placement`.
--- @return boolean  did this seal the match?
function BR.Spectate.onEliminated(m, squadsBefore)
    if not m or m.spectateSealed then return false end

    -- THE EDGE, IN THE ORDER THAT COSTS LEAST. The `before` value is already in
    -- hand, so the roster walk below only happens for the deaths that could
    -- possibly be the last one.
    if (squadsBefore or 0) < 2 then return false end
    if BR.Server.squadsAlive(m) > 1 then return false end

    m.spectateSealed = true

    local told = 0
    BR.Roster.each(
        function(e)
            return e.matchId == m.id and not BR.Server.isInMatch(e.state)
        end,
        function(src)
            local s = sessions[src]
            if s and s.kind == 'admin' then return end
            -- A RUNNING SESSION COMES DOWN THROUGH THE ONE TEARDOWN, which is
            -- what gives the microphone back and closes the audit row; a player
            -- with nothing running still needs the latch, and `stop` returns
            -- false for exactly them.
            if not BR.Spectate.stop(src, 'match-over', true) then
                TriggerClientEvent(BR.Net.SPECTATE_SET, src,
                                   { stop = true, reason = 'match-over',
                                     final = true })
            end
            told = told + 1
        end)

    print(('[br_core] spectate: match %s is decided -- camera closed for %d '
        .. 'player(s)'):format(BR.MatchTag(m.id), told))
    return true
end

-- --------------------------------------------------------------- policies ---

--- The candidate rows for a PLAYER spectator, and the policy that produced them.
---
--- The squad rule is not applied here -- it is applied in spectate_solve, where
--- it is the structure of the function and can be tested without a server. This
--- only projects the roster into the view that function takes.
local function playerView(src, entry)
    -- WHO KILLED ME, TURNED BACK INTO A SERVER ID -- and only in solos, because
    -- that is the only place the solver looks at it.
    --
    -- SERVER-SIDE ATTRIBUTION, END TO END. `killedByLicense` is written by
    -- BR.Combat.eliminate from the killer the validated damage ledger produced;
    -- no client is asked and none is believed. GetPedSourceOfDeath was
    -- considered for exactly this shape of question and rejected (#194,
    -- server/vehicles.lua), and server/combat.lua notes that M6 cancels the
    -- engine's damage anyway, so the client honestly has nothing to report.
    --
    -- THE LOOKUP IS THE POINT OF STORING A LICENSE. The id is resolved HERE,
    -- from the roster as it stands this instant, so a recycled server id cannot
    -- be inherited: the license either still names somebody in this match or it
    -- names nobody and the killer is simply gone. Done in the walk that is
    -- already happening rather than in a second pass over the same table.
    local wantLicense = nil
    if entry.squadId == nil then wantLicense = entry.killedByLicense end
    local killerSrc = nil

    local players = {}
    BR.Roster.each(
        function(e) return e.matchId == entry.matchId end,
        function(psrc, e)
            if wantLicense ~= nil and killerSrc == nil
               and BR.Roster.licenseOf(psrc) == wantLicense then
                killerSrc = psrc
            end
            players[#players + 1] = {
                src     = psrc,
                squadId = e.squadId,
                name    = e.name,
                -- ONE DEFINITION OF "STILL IN THE FIGHT", and it is
                -- BR.Server.isInMatch -- the same answer the alive count, the
                -- win condition and the HUD read. A second definition here
                -- would drift, and the way it would drift is a dead squadmate
                -- staying on the wheel.
                living  = BR.Server.isInMatch(e.state),
            }
        end)

    return {
        mySrc     = src,
        squadId   = entry.squadId,
        free      = BR.Config.Spectate.freeAfterSquadOut == true,
        killerSrc = killerSrc,
        players   = players,
    }
end

--- The candidate rows for an ADMIN: every connected player, filtered by the
--- solver down to the one they named.
local function adminView(want)
    local players = {}
    BR.Roster.each(nil, function(psrc, e)
        players[#players + 1] = { src = psrc, name = e.name }
    end)
    return { want = want, players = players }
end

--- MAY THIS PLAYER BE WATCHING ANYBODY AT ALL?
---
--- ONE PREDICATE, ASKED ON BOTH EDGES -- opening a session, and every push of
--- the feed for the rest of it. "May I start" and "may I still be here" were
--- never two questions, and the shipped code only ever asked the first: the
--- arrow handler refused a player who was still in the fight, and `resolve` --
--- which the feed calls four times a second -- had no opinion about the WATCHER
--- at all. It re-resolved the TARGET faithfully and would have gone on doing it
--- forever.
---
--- ═══ WHAT THAT MISSING EDGE COST (owner, 2026-08-23) ═══
---
---   "dying before the match results in spectating, then getting stuck in
---    spectate. Spectating before the match starts should not be possible."
---
--- BOTH HALVES ARE THIS FUNCTION'S ABSENCE, and they are one bug seen from two
--- ends. A death before the match starts is #144's HELD death: server/combat.lua
--- puts the roster through DEAD -- holdForStart is explicit that it must, or the
--- server-observed health check finishes them for real -- and sets
--- `revivePending`, and server/match.lua picks them back up on the transition
--- into PLAYING. DEAD is not `isInMatch`, so client/spectate.lua's `spectate.open`
--- loop asked for a camera and this file handed one over. Then the revive landed,
--- the roster said ALIVE, and nothing was listening: the player was alive in a
--- live match with client/spectate.lua's control suppression re-asserted every
--- frame -- unable to move, shoot or leave the shot -- because the session that
--- suppression is keyed on had no reason to end.
---
--- ═══ `revivePending` IS THE SECOND TERM AND IT HAS TO BE ═══
---
--- A held player's state is a TRUE DEAD and must stay one, so the state string
--- cannot tell them apart from somebody genuinely out of the round. The flag is
--- the only fact that can, and reading it HERE rather than widening
--- BR.Server.isInMatch is the same call server/match.lua already makes for the
--- headcount (`isInMatch(e.state) or e.revivePending == true`): isInMatch is the
--- win condition, and a held player is not standing -- they are coming back.
--- It is bounded in three places (the revive, walking out, CLEANUP), so no
--- player can be locked out of spectating by a flag nothing clears.
---
--- NOT GATED ON A SPECTATING PLAYER STATE, because there is none. There was a
--- `BR.PlayerState.SPECTATING` that was assigned nowhere in this project, and
--- #233 deleted it -- spectating is possible while a player is OUT rather than
--- instead of it. client/state.lua and client/storm.lua took the same turning.
--- The session is the fact that gets written, and the session is what this file
--- already holds.
--- @param entry table|nil
--- @return boolean
local function mayWatch(entry)
    if not entry then return false end
    if BR.Server.isInMatch(entry.state) then return false end
    -- `~= true` RATHER THAN A TRUTH TEST, for the reason spectate_solve.lua
    -- gives about killerSrc one file over: in Lua `0` is TRUTHY, so a truth
    -- test reads correctly against a nil/true field today and lies the moment
    -- the flag becomes a count or a timestamp. Every other reader of
    -- `revivePending` spells it out the same way (server/match.lua, twice).
    return entry.revivePending ~= true
end

--- Resolve a PLAYER session's next target and apply it.
---
--- THE ONE PLACE A PLAYER'S TARGET IS EVER SET. Opening a session, the arrow
--- keys and the feed's re-resolve all come through here, so the squad rule runs
--- on every path and there is no second route that skips it.
---
--- ADMIN SESSIONS DO NOT COME THROUGH HERE AT ALL, and that is why there is no
--- `if kind == 'admin'` branch to be found in it. An admin session names one
--- person, is opened by adminStart, is never cycled, and ends rather than moves
--- -- so a shared function with a privilege flag would be a flag with exactly
--- one caller on each side and a policy that could be reached with the wrong
--- one.
---
--- @param src integer
--- @param dir number  +1 / -1 / 0
--- @return boolean running
local function resolve(src, dir)
    local s = sessions[src]
    local entry = BR.Roster.get(src)
    if not entry then
        if s then BR.Spectate.stop(src, 'gone') end
        return false
    end
    -- STILL ENTITLED TO BE HERE? Asked before the target is, because who the
    -- watcher may look at stops mattering the moment they are back in the round
    -- themselves. This is the line the feed runs into 250 ms after #144's revive
    -- puts a held player back on their feet, and it is what makes a session end
    -- BY ITSELF rather than waiting for a stop nobody was going to send.
    if not mayWatch(entry) then
        if s then BR.Spectate.stop(src, 'in-the-fight') end
        return false
    end
    if not entry.matchId then
        if s then BR.Spectate.stop(src, 'no-match') end
        return false
    end

    -- ...AND IS THAT MATCH STILL BEING PLAYED FOR?
    --
    -- THE AUTHORITATIVE HALF OF THE OWNER'S 2026-09-11 RULE, and it is here
    -- rather than only on the client because a refusal the client cannot see
    -- round is the only kind that closes the race. BR.Spectate.onEliminated
    -- latches this inside the same synchronous call that writes the deciding
    -- death, so every ask that arrives afterwards -- the automatic one, the
    -- arrow keys, all three of the client's retries, a client that never got the
    -- seal message at all -- is answered with no camera rather than with a camera
    -- that is taken away a moment later.
    --
    -- ASKED IN `resolve` AND NOT IN mayWatch, because it is not a fact about the
    -- WATCHER. mayWatch answers "is this player entitled to be looking at
    -- anybody", and a dead player in a finished match still is; what has changed
    -- is that there is no longer a round to look at. Same reason the matchId test
    -- above sits here.
    local m = BR.Server.matches and BR.Server.matches[entry.matchId]
    if m and m.spectateSealed then
        if s then BR.Spectate.stop(src, 'match-over', true) end
        return false
    end

    local list = BR.SpectateSolve.playerTargets(playerView(src, entry))
    local pick = BR.SpectateSolve.step(list, s and s.target, dir)
    if not pick then
        if s then BR.Spectate.stop(src, 'no-targets') end
        return false
    end

    if s then
        if pick.src ~= s.target then
            unwatch(src, s.target)
            s.target = pick.src
            s.targetLicense = BR.Roster.licenseOf(pick.src)
            s.name = pick.name
            watch(src, pick.src)
            -- A NEW PERSON IS A NEW INVENTORY, WHATEVER IT LOOKS LIKE. The
            -- signature is derived from CONTENTS, so two squadmates who both
            -- hold nothing but an AK would produce the same one -- and the push
            -- below would then send no inventory at all for the player just
            -- stepped onto, leaving the bar showing the previous one. Clearing
            -- it makes the first push after a cycle unconditional.
            s.invSig = nil
        end
    else
        s = {
            target        = pick.src,
            targetLicense = BR.Roster.licenseOf(pick.src),
            name          = pick.name,
            kind          = 'player',
            startedAt     = GetGameTimer(),
        }
        sessions[src] = s
        watch(src, pick.src)
        micFor(src, true)
    end

    push(src, s)
    return true
end

-- ---------------------------------------------------------------- players ---

RegisterNetEvent(BR.Net.SPECTATE_CYCLE)
AddEventHandler(BR.Net.SPECTATE_CYCLE, function(d)
    local src = source
    local dir = tonumber(type(d) == 'table' and d.dir or 0) or 0

    -- AN ADMIN SESSION DOES NOT CYCLE, AND THE ARROWS MUST NOT SILENTLY MOVE
    -- IT. The console named one person; the keys belong to the player policy.
    -- Refusing here rather than in the client is the same rule as everywhere
    -- else in this file -- the client is not where a permission is decided.
    local s = sessions[src]
    if s and s.kind == 'admin' then return end

    -- ONLY THE OUT-OF-THE-FIGHT MAY WATCH, AND A HELD DEATH IS NOT OUT OF IT.
    -- The same predicate `resolve` asks on every push, so the answer cannot come
    -- apart between the two edges -- which is exactly how a session used to open
    -- for a player the arrows would have refused a moment later.
    --
    -- KEPT HERE AS WELL AS IN `resolve`, even though resolve would now refuse
    -- this on its own: this is the cheap refusal, and without it every arrow
    -- press from every living player walks the whole roster before being told no.
    local entry = BR.Roster.get(src)
    if not mayWatch(entry) then return end

    resolve(src, dir)
end)

RegisterNetEvent(BR.Net.SPECTATE_STOP)
AddEventHandler(BR.Net.SPECTATE_STOP, function()
    BR.Spectate.stop(source, 'stopped')
end)

-- ------------------------------------------------------------------ admin ---

--- Start an admin session. Called by br_ringmaster's brspectate, never by a
--- client.
---
--- IT RE-CHECKS NOTHING ABOUT AUTHORISATION, and that is the same decision
--- br_ringmaster/server/kick.lua records: authorisation happened in the console
--- against the acting admin's scopes, and the admin's identity travels only as
--- an AUDIT field. Anything able to put bytes on that channel already has
--- console authority.
---
--- @param opts table  { admin, target, adminLicense, targetLicense, commandId }
--- @return boolean ok, string detail
function BR.Spectate.adminStart(opts)
    opts = opts or {}
    local src, target = tonumber(opts.admin), tonumber(opts.target)
    if not src or not target then return false, 'bad ids' end

    local list = BR.SpectateSolve.adminTargets(adminView(target))
    local pick = list[1]
    if not pick then return false, 'target not connected' end

    -- WATCHING YOURSELF IS NOT A MODERATION TOOL. Cheap to refuse and confusing
    -- to allow -- the camera would orbit the admin's own ped while their ped
    -- stops answering the controls the camera has taken.
    if src == target then return false, 'cannot spectate yourself' end

    -- A SECOND START REPLACES THE FIRST, and the first one's audit row is
    -- CLOSED rather than abandoned. An admin who clicks Spectate on a second
    -- player has ended the first session as surely as if they had pressed the
    -- pause-menu exit, and the log should say so with a duration.
    BR.Spectate.stop(src, 'retargeted')

    local s = {
        target        = target,
        targetLicense = BR.Roster.licenseOf(target),
        name          = pick.name,
        kind          = 'admin',
        startedAt     = GetGameTimer(),
        commandId     = opts.commandId,
        adminLicense  = opts.adminLicense,
    }
    sessions[src] = s
    watch(src, target)
    micFor(src, true)
    audit(s, 'start')
    push(src, s)

    print(('[br_core] spectate: admin %d -> %s (%d)')
        :format(src, tostring(s.name), target))
    return true, s.name
end

--- br_ringmaster asking, on the console's behalf. The reply rides back on the
--- same event idiom rather than a return value: the two resources are separate
--- Lua states and a direct call across them is the mistake server/ringmaster.lua
--- already records ("the first version of this read nil forever from over
--- there").
AddEventHandler('br:core:spectate', function(opts)
    local ok, detail = BR.Spectate.adminStart(opts)
    TriggerEvent('br:core:spectateResult', {
        commandId = opts and opts.commandId,
        ok        = ok,
        detail    = detail,
    })
end)

-- ------------------------------------------------------------- the leaver ---

--- The case that gets got wrong (#192).
---
--- A camera pointed at a departed player is not merely blank -- FiveM hands that
--- id to the next person to connect, within the minute, so it becomes a camera
--- pointed at somebody the watcher was never entitled to see. This handler is
--- the fast path. The feed's license check below is the one that has to be
--- right, because this event can be missed (a resource restart mid-session) and
--- that one cannot.
AddEventHandler('playerDropped', function()
    local gone = source

    -- Their own session, if they were watching. This is also what gives the
    -- microphone back, which matters even though they are leaving: the src is
    -- handed to the next person to connect within the minute, and a mute record
    -- left standing against it would follow them.
    BR.Spectate.stop(gone, 'left')

    -- AND THE RECORD GOES EVEN IF THERE WAS NO SESSION TO STOP. `stop` returns
    -- early for a player who was not spectating, so it is not a place to hang
    -- cleanup that must happen either way.
    if BR.Voice and BR.Voice.forgetSpectatorMute then
        BR.Voice.forgetSpectatorMute(gone)
    end

    -- And everyone watching THEM.
    local w = watchers[gone]
    if not w then return end
    for src in pairs(w) do
        local s = sessions[src]
        if s and s.kind == 'admin' then
            -- "If the player being spectated leaves while being spectated, the
            -- 'stop spectating' function runs automatically" -- the owner,
            -- verbatim. An admin session names one person and there is nobody
            -- else it could reasonably move to.
            BR.Spectate.stop(src, 'target-left')
        else
            -- A player's wheel simply loses a spoke. Re-resolving keeps them
            -- watching their squad rather than dropping them out of spectate
            -- because one teammate's connection died.
            if not resolve(src, 1) then
                BR.Spectate.stop(src, 'target-left')
            end
        end
    end
end)

-- ------------------------------------------------------------------- feed ---

--- Positions out, and validity in, on one job.
---
--- THE SAME PASS DOES BOTH ON PURPOSE. A push and a validity check on separate
--- timers is two clocks that can disagree about whether a session exists, and
--- the window between them is exactly the window in which a camera is pointed
--- somewhere it should not be.
BR.Sched.every(BR.Config.Spectate.feedMs, 'spectate.feed', function()
    for src, s in pairs(sessions) do
        -- IS THIS STILL THE SAME PERSON? The id survives a disconnect; the
        -- license does not. Comparing them is what makes a recycled id a stop
        -- rather than a silent change of subject.
        --
        -- A NIL LICENSE ON BOTH SIDES IS NOT A MATCH AND MUST NOT READ AS ONE:
        -- a licenseless connection has nil forever, so `nil == nil` would let
        -- any recycled id inherit the session. The session is only kept when the
        -- stored license is a real string and still resolves to the same one.
        local now = BR.Roster.licenseOf(s.target)
        if s.targetLicense == nil or now == nil or now ~= s.targetLicense then
            BR.Spectate.stop(src, 'target-left')
        elseif s.kind == 'admin' then
            push(src, s)
        else
            -- A PLAYER'S TARGET IS RE-RESOLVED EVERY PUSH, not only when
            -- something obvious happens. The squad rule depends on who is still
            -- standing, and that changes without any event this file listens
            -- for -- a squadmate dying somewhere else is exactly the moment the
            -- set has to shrink, and the moment the last one dies is when it may
            -- widen. dir 0 holds the current target when it is still eligible,
            -- so the shot does not jump on every tick.
            resolve(src, 0)
        end
    end
end)

-- Nothing survives the resource going away: a session in this table with no
-- client counterpart is a camera nobody can turn off.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for src in pairs(sessions) do
        BR.Spectate.stop(src, 'shutdown')
    end
end)

-- ------------------------------------------------------------------ debug ---

RegisterCommand('brspectators', function(src)
    if src ~= 0 then return end
    print('=== spectate sessions ===')
    local any = false
    for watcher, s in pairs(sessions) do
        any = true
        print(('  %d -> %d (%s) %s  %.1fs  lic=%s'):format(
            watcher, s.target, tostring(s.name), s.kind,
            (GetGameTimer() - s.startedAt) / 1000, tostring(s.targetLicense)))
    end
    if not any then print('  (nobody is spectating)') end
    print(('  free after squad out: %s')
        :format(tostring(BR.Config.Spectate.freeAfterSquadOut)))
end, true)

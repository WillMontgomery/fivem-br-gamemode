-- Server bootstrap and authoritative state.
--
-- THE SCHEDULER USED TO LIVE HERE and now lives in `br_lib/shared/sched.lua`,
-- pulled in by this resource's fxmanifest ahead of this file. It moved in M9
-- (2026-08-09) because a second server-side resource -- br_ringmaster -- needs
-- one too, and the alternatives were copying it or spawning raw threads.
--
-- Nothing about how it is used changed: subsystems still call
-- `BR.Sched.every(intervalMs, name, fn)`, /brperf still reads
-- `BR.Sched.stats()`, and each resource now keeps its own independent job
-- registry, which is the property that makes a wedged moderation job invisible
-- to the gamemode's numbers.

BR = BR or {}

-- ---------------------------------------------------------------------------
-- Server state.
--
-- This is the authority. Nothing here is derived from anything a client said,
-- and nothing here depends on players being in each other's scope -- which is
-- what makes it survive OneSync big mode at 48 players spread across the map.
-- ---------------------------------------------------------------------------

BR.Server = {
    devMode  = false,
    matchId  = 0,   -- mint counter; the highest id ever issued

    -- THE MATCH REGISTRY (parallel-matches refactor, user call 2026-08-04).
    -- matches[id] = a match INSTANCE: { id, bucket, state, mode, endsAt, ... }.
    -- There is no global "the match" any more: an instance is born straight
    -- into WARMUP when a queue clears the start gate, and is destroyed after
    -- its CLEANUP -- WAITING is not a state an instance can be in, it is what
    -- a lobby client sees when it belongs to no match. At most ONE instance
    -- is ever in open WARMUP (ready-ups late-join it until it departs or
    -- fills; only then does the queue accumulate toward the next instance).
    matches = {},

    -- roster[src] = { src, name, license, matchId, squadId, state, ... }
    -- Populated from the server-side playerJoining / playerDropped events, which
    -- are global and unaffected by entity scoping.
    roster = {},

    -- THERE IS NO SQUAD REGISTRY, and there deliberately is not one.
    --
    -- There used to be a `squads` table here. Parties took squad formation over
    -- and BR.Party.formSquads stamps `squadId` straight onto each roster entry,
    -- so nothing ever wrote to it again -- while /brsquads went on reading it
    -- and reporting "(no squads)" through every squad match that has ever been
    -- played (owner, in game, 2026-08-09). A cache nobody fills is worse than
    -- no cache, because the thing reading it answers confidently.
    --
    -- The roster is the source of truth for squad membership exactly as it is
    -- for everything else. BR.Server.squadsAlive and /brsquads both derive from
    -- it, and there is no second place for the two to disagree.
}

--- Count players in the roster matching an optional predicate.
--- @param pred function|nil
--- @return integer
function BR.Server.count(pred)
    local n = 0
    for _, p in pairs(BR.Server.roster) do
        if not pred or pred(p) then n = n + 1 end
    end
    return n
end

-- ------------------------------------------------------- match instances ---

--- The match instance a player belongs to, or nil for a lobby player.
--- A DEAD player (and an ENDED-summary spectator swept home early) keeps
--- their matchId until the instance is destroyed or they leave, so match
--- traffic still reaches them.
--- @param src integer
--- @return table|nil
function BR.Server.matchOf(src)
    local e = BR.Server.roster[src]
    return e and e.matchId and BR.Server.matches[e.matchId] or nil
end

--- @param id integer
--- @return table|nil
function BR.Server.matchById(id)
    return id and BR.Server.matches[id] or nil
end

--- Iterate every live match instance, in id order (deterministic -- tests
--- and logs depend on it).
--- @param fn function  receives (m)
function BR.Server.eachMatch(fn)
    local ids = {}
    for id in pairs(BR.Server.matches) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local m = BR.Server.matches[id]
        if m then fn(m) end
    end
end

--- The newest instance, or nil. Admin commands (brforce, brphase) target
--- this: with one match running -- the dev norm -- it is simply THE match.
--- @return table|nil
function BR.Server.latestMatch()
    local best = nil
    for id, m in pairs(BR.Server.matches) do
        if not best or id > best.id then best = m end
    end
    return best
end

--- The instance a ready-up should late-join: a WARMUP match with a free
--- slot -- OF THE GIVEN MODE, when one is asked for. Matches are
--- homogeneous (user call, 2026-08-04): a solo queuer never lands in a
--- squad match, so a solo warmup and a squad warmup can be open at the
--- same time, sharing the communal warmup bucket but flying separate
--- buses into separate matches. nil means ready-ups of that mode queue
--- for a NEW match instead -- the formation gate.
--- @param mode string|nil  restrict to this mode; nil matches any
--- @return table|nil
function BR.Server.formingMatch(mode)
    for _, m in pairs(BR.Server.matches) do
        if m.state == BR.MatchState.WARMUP
           and (not mode or m.mode == mode)
           and BR.Server.countIn(m) < BR.Config.Match.maxPlayers then
            return m
        end
    end
    return nil
end

--- Count the players belonging to a match (any player state -- DEAD and
--- summary-lobby players still belong until the instance dies).
--- @param m table
--- @param pred function|nil
--- @return integer
function BR.Server.countIn(m, pred)
    local n = 0
    for _, p in pairs(BR.Server.roster) do
        if p.matchId == m.id and (not pred or pred(p)) then n = n + 1 end
    end
    return n
end

--- The server ids a match's traffic goes to. This is the scoping primitive:
--- match STATE, storm records, bus routes and kill feed reach exactly these
--- players and nobody else.
--- @param m table
--- @return integer[]
function BR.Server.audience(m)
    local out = {}
    for src, p in pairs(BR.Server.roster) do
        if p.matchId == m.id then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

--- Is this player still in the match?
---
--- "Still in" rather than "alive" is the useful question, and the two differ at
--- both ends:
---   * a DOWNED player is not alive but is very much still in it
---   * a player in WARMUP has not dropped yet but is equally still in it
---
--- Leaving WARMUP out made the HUD read "0 ALIVE" to two players standing next
--- to each other on the warmup pad, which is technically defensible and plainly
--- wrong to look at.
---
--- LOBBY is excluded on purpose: those players are not in the match at all.
--- @param state string
--- @return boolean
function BR.Server.isInMatch(state)
    return state == BR.PlayerState.ALIVE
        or state == BR.PlayerState.DBNO
        or state == BR.PlayerState.WARMUP
        or state == BR.PlayerState.BUS
        or state == BR.PlayerState.FREEFALL
        or state == BR.PlayerState.GLIDE
end

--- How many players are still in a match. Scoped to one instance when given;
--- across every instance when not (debug output, mostly).
--- @param m table|nil
--- @return integer
function BR.Server.aliveCount(m)
    return BR.Server.count(function(p)
        return BR.Server.isInMatch(p.state)
           and (not m or p.matchId == m.id)
    end)
end

--- How many squads still have at least one living member. This is the win
--- condition, not the player count -- a four-stack with three dead is one squad.
--- Squad ids are namespaced per match (party.formSquads), so even the
--- unscoped call cannot conflate two matches' squads.
--- @param m table|nil
--- @return integer
function BR.Server.squadsAlive(m)
    local seen, n = {}, 0
    for _, p in pairs(BR.Server.roster) do
        if BR.Server.isInMatch(p.state) and (not m or p.matchId == m.id) then
            -- Solo players have no squad; each counts as their own team.
            local key = p.squadId or ('solo:' .. tostring(p.src))
            if not seen[key] then
                seen[key] = true
                n = n + 1
            end
        end
    end
    return n
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    BR.Server.devMode = GetConvar('sv_devMode', 'false') == 'true'
        or GetConvar('br_devMode', 'false') == 'true'

    -- AND THE CLIENT IS TOLD, which it previously never was.
    --
    -- Every command in the project now sits behind this switch
    -- (br_lib/shared/devgate.lua; owner, 2026-08-31), and about half of them
    -- are CLIENT commands -- /brprobe, /brcoords, /brsurvey and the rest. Those
    -- had no way to read this: client/attachtune.lua's write-up says so in as
    -- many words -- "sv_devMode and br_devMode are read in
    -- br_core/server/main.lua and are NOT replicated, so a client GetConvar
    -- sees neither". Copying the server's spelling onto the client produced a
    -- command that silently never ran, which is why those files gated
    -- themselves on player state instead.
    --
    -- ONE NAME CARRIES THE ANSWER TO BOTH QUESTIONS. sv_devMode is not
    -- replicated and is not going to be; what crosses is br_devMode, holding
    -- the OR above rather than its own raw value. So a box started with only
    -- `set sv_devMode true` still has working client dev commands, and
    -- BR.Dev.on() reads the same truth on both sides of the wire.
    --
    -- IT WRITES THE NAME IT ALSO READS, and the one case where that shows: the
    -- read two lines above sees whatever this wrote last time. Across a server
    -- restart that is harmless, because the value written is the OR of the two
    -- convars the .cfg just set, so it can only agree with them. It bites once
    -- -- `set sv_devMode false` typed live, then `restart br_core`, which reads
    -- the br_devMode this left behind and stays in dev mode. `set br_devMode
    -- false` is the way out, and the boot banner below prints which it took.
    --
    -- Guarded like server/voice.lua's convar pass, and for the same reason: the
    -- unit suites run this file without the Cfx runtime, where a nil global
    -- here would raise inside onResourceStart and take the boot with it.
    if SetConvarReplicated then
        SetConvarReplicated('br_devMode', tostring(BR.Server.devMode))
    end

    BR.Sched.start()

    -- ONESYNC IS NOT OPTIONAL FOR THIS GAMEMODE.
    --
    -- Server-side entity access -- GetPlayerPed, GetEntityCoords, GetEntityHealth
    -- against another player -- only exists when OneSync is on. Without it those
    -- natives return 0 and the server is blind: no position sampling, so no storm
    -- damage, no spectator targets, and no damage validation.
    --
    -- The failure is silent. Nothing errors; the server simply believes every
    -- player is standing at nowhere with no ped, forever. Worth an explicit,
    -- noisy check at boot rather than discovering it three milestones later.
    BR.Server.onesync = GetConvar('onesync', 'off')

    print('[br_core] server started')
    print(('[br_core]   onesync      %s'):format(BR.Server.onesync))
    print(('[br_core]   devMode      %s'):format(tostring(BR.Server.devMode)))
    print(('[br_core]   maxPlayers   %d (free OneSync ceiling is 48)')
        :format(BR.Config.Match.maxPlayers))
    print(('[br_core]   minToStart   %d'):format(BR.Config.Match.MinPlayers(BR.Server.devMode)))
    print(('[br_core]   match length ~%.0f min planned')
        :format(BR.Config.Storm.TotalSeconds() / 60.0))

    -- THE TUNABLES BLOCK, and it prints EVERY setting rather than only the
    -- overridden ones.
    --
    -- Each of these values now has two places it could have been written down
    -- -- br_lib/config/match.lua and whatever .cfg the server exec'd -- and the
    -- only question anybody will ever ask about that is "which one am I
    -- running". Printing the live number beside the source it came from answers
    -- it in the console the operator is already looking at, without a round
    -- trip through the admin console. See br_lib/config/overrides.lua.
    local tune, overridden = BR.Config.Overrides.report()
    print(('[br_core]   tunables     %d of %d set by convar')
        :format(overridden, #BR.Config.Overrides.SPEC))
    for _, l in ipairs(tune) do
        print('[br_core]  ' .. l)
    end

    -- THE LATE-EXEC TRAP, made audible.
    --
    -- The overrides are read while br_lib/config/*.lua loads, so a server.cfg
    -- whose `exec "tunables.cfg"` sits BELOW `ensure br_core` sets every convar
    -- correctly and changes nothing at all: the config tables were already
    -- built, and server/match.lua's DURATION table already holds copies of two
    -- of the values. Everything downstream then looks right -- the convar is
    -- set, the admin console reports it set -- while the game plays the
    -- defaults, which is the most expensive shape a configuration bug has.
    --
    -- So: ten seconds after start, read the convars again. Anything now set
    -- that was not set at load arrived late, and late means never.
    --
    -- BUT LATENESS IS A CONCLUSION, NOT AN OBSERVATION, and this block used to
    -- assert it without checking. "The convar is set and it did not apply" has
    -- a second cause -- br_lib/config/overrides.lua never read a convar at all,
    -- because its server-state guard did not recognise the server -- and the
    -- two are indistinguishable from the symptom. Blaming the ordering for both
    -- is not a harmless guess: it names a file the operator must then re-audit,
    -- and it is the wrong file, so the round ends with server.cfg proven
    -- correct and the bug untouched. That is exactly how this shipped. So the
    -- flag is asked FIRST, and only when the convars really were read does the
    -- ordering explanation get to speak.
    if type(SetTimeout) == 'function' then
        SetTimeout(10000, function()
            if not BR.Config.Overrides.consulted then
                print('[br_core] ')
                print('[br_core] ############################################################')
                print('[br_core]   THE TUNABLE CONVARS WERE NEVER READ ON THIS SERVER.')
                print('[br_core] ')
                print('[br_core]   br_lib/config/overrides.lua applies overrides only in the')
                print('[br_core]   server Lua state, and it did not recognise this one -- so')
                print('[br_core]   every setting is on its committed default no matter what')
                print('[br_core]   any .cfg says, and `brconfig` cannot tell you otherwise.')
                print('[br_core] ')
                print('[br_core]   THIS IS OUR BUG, NOT YOUR CONFIGURATION. Do not move the')
                print('[br_core]   exec line and do not edit tunables.cfg; neither is the')
                print('[br_core]   cause. Report this banner verbatim.')
                print('[br_core] ############################################################')
                print('[br_core] ')
                return
            end

            local late = {}
            for _, spec in ipairs(BR.Config.Overrides.SPEC) do
                local raw = GetConvar(spec.convar, '')
                if raw ~= '' and not BR.Config.Overrides.appliedFor(spec.key) then
                    late[#late + 1] = ('%s = %s'):format(spec.convar, raw)
                end
            end
            if #late == 0 then return end

            print('[br_core] ')
            print('[br_core] ############################################################')
            print('[br_core]   TUNABLE CONVARS ARRIVED TOO LATE TO DO ANYTHING:')
            for _, l in ipairs(late) do print('[br_core]     ' .. l) end
            print('[br_core] ')
            print('[br_core]   They are set, and the game is running the defaults.')
            print('[br_core]   These are read once, while br_lib/config loads.')
            print('[br_core] ')
            print('[br_core]   In server.cfg, the line')
            print('[br_core]       exec "tunables.cfg"')
            print('[br_core]   must come ABOVE `ensure br_lib` and `ensure br_core`.')
            print('[br_core]   Move it up and restart the server.')
            print('[br_core] ############################################################')
            print('[br_core] ')
        end)
    end

    if BR.Server.onesync == 'off' or BR.Server.onesync == '' then
        print('[br_core] ')
        print('[br_core] ############################################################')
        print('[br_core]   ONESYNC IS OFF. The server cannot see player entities.')
        print('[br_core] ')
        print('[br_core]   GetPlayerPed returns 0 for every player, so nothing that')
        print('[br_core]   depends on where players are can work: storm damage,')
        print('[br_core]   spectating, damage validation, the scatter test.')
        print('[br_core] ')
        print('[br_core]   Add to server.cfg, BEFORE any ensure lines:')
        print('[br_core]       set onesync on')
        print('[br_core]   It also needs a valid sv_licenseKey from keymaster.')
        print('[br_core] ############################################################')
        print('[br_core] ')
    end
end)

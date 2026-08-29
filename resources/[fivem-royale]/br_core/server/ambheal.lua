-- Healing in the back of an ambulance: the claim, and the health.
--
-- ═══ WHY THIS IS SERVER-SIDE AT ALL, WHICH IS TWO SEPARATE ARGUMENTS ═══
--
-- 1. THE ARBITRATION. "only one heal per ambulance at a time" (owner,
--    2026-08-28). A client-side check races by construction: two players walk
--    up to the same van, both clients look, both see it free, both start. There
--    is no ordering between two machines and no amount of local checking
--    invents one. Worse, the vehicles this feature works on are AMBIENT -- the
--    owner's "any ambulance at all" -- so they are shared world objects that no
--    single client owns and none of them is entitled to speak for.
--
--    A claim table on the one machine both players are connected to has an
--    order for free. `claims[netId]` is written by whichever START arrives
--    first and the second is refused, and "first" is a real answer rather than
--    a coin flip.
--
-- 2. THE HEALTH. docs/security.md's rule: the client is never the authority on
--    anything that decides a match, and health decides every match. So the heal
--    is ISSUED here, on INV_EFFECT, exactly as a med kit is -- and, exactly as a
--    med kit does, it stamps `entry.healUntil` so server/roster.lua's health
--    audit reads the rise as HEALING rather than as a client lying about its own
--    ped. See the block at `grant`.
--
-- ═══ WHAT THIS FILE CANNOT CHECK, SAID ONCE AND NOT AGAIN ═══
--
-- The rear doors. GET_VEHICLE_DOOR_ANGLE_RATIO has no server handler, so the
-- door rule is enforced on the client and only there. BR.AmbHealSolve.doorsOpen
-- carries the full statement of what that costs and why it is the right half to
-- give up. It is worth being clear that it is the ONLY one: the model, the
-- distance, the rear arc, being alive, being hurt, being in a live match and
-- whether anybody else has the van are all re-derived here from this server's
-- own reads and its own clock.
--
-- ═══ AND THE PLAYER IS MORTAL THROUGHOUT ═══
--
-- Nothing here writes a state. A healing player stays ALIVE in the roster, which
-- is what keeps client/natives.lua's invincibility latch answering false and
-- what keeps server/combat.lua's ordinary damage and death paths pointed at
-- them. There is no `entry.healing` flag on the roster and there must not be
-- one: the moment a state exists, something starts checking it before deciding
-- whether somebody may be hurt.
--
-- `entry.healUntil` IS NOT THAT FLAG. It is a stamp the health AUDIT reads to
-- excuse an upward move, it is written by the med kit already, and nothing in
-- the damage pipeline consults it -- shared/health_solve.lua is a detector and
-- config/match.lua's healthAudit block spells out that it "must never refuse a
-- sample, adjust a number or change a state".

BR = BR or {}
BR.AmbHeal = {}

local A = BR.Config.AmbHeal

--- Heals in progress, keyed by the VEHICLE's network id.
---
--- ═══ THE KEY IS THE VAN, NOT THE PLAYER, BECAUSE THE RULE IS ABOUT THE VAN ═══
---
--- "One heal per ambulance at a time" is a statement about a vehicle, so the
--- table that enforces it is indexed by one. A player-keyed table would answer
--- "is this player healing" in one lookup and "is this van taken" in a walk, and
--- the walk is the question that runs on the hot path.
---
--- A NETWORK ID RATHER THAN AN ENTITY HANDLE, and server/fuel.lua's header is
--- the argument: these are vehicles this gamemode did not create, and the net id
--- is the one name for them that both sides can resolve. It is also what arrives
--- on the wire, so a claim can be checked against an incoming message without
--- resolving anything first.
---
---   [netId] = {
---     src        who is healing
---     matchId    so teardown is per match
---     veh        the resolved entity, re-checked every tick
---     startedAt  server ms
---     hp0        display hp when it began -- every target is measured from this
---     lastAt     server ms of the last grant, for the log only
---   }
local claims = {}

--- ...and the reverse index, so "is THIS player healing" is a lookup too.
---
--- TWO TABLES RATHER THAN A WALK, and they are written in exactly two places
--- (`hold` and `release`) so they cannot come apart. The alternative is a walk
--- over `claims` on every AMBHEAL_STOP and on every roster teardown, and the
--- teardown case is the one that runs for every player who ever leaves.
local healing = {}

local stat = { started = 0, refused = 0, granted = 0, finished = 0, stopped = 0 }

--- Did a native declared BOOL say yes?
---
--- The `didHit` idiom, and this project has shipped the bug it prevents seven
--- times. A FiveM native declared BOOL hands Lua a number on some builds and a
--- boolean on others, and IN LUA `0` IS TRUTHY -- so `if DoesEntityExist(e)` is
--- true for an entity that does not exist. Here that would mean healing somebody
--- inside an ambulance that has been blown up.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Which player states may heal.
---
--- ALIVE AND NOTHING ELSE, which is narrower than server/fuel.lua's pair and
--- narrower on purpose:
---
---   WARMUP is excluded because a warmup player is invincible
---   (client/natives.lua's latch) and cannot be hurt, so there is nothing to
---   heal and the whole interaction would be a fifteen-second animation for no
---   effect.
---
---   DBNO is excluded because a downed player's health is a bleed COUNTDOWN
---   rather than a bar -- server/roster.lua refuses to even sample it -- and
---   healing one would be a revive with no reviver. That is #191's job and it
---   costs an ultra-rare item; this must not become a free version of it.
local LIVE = { [BR.PlayerState.ALIVE] = true }

--- Is the feature switched on and configured?
--- @return boolean
local function enabled()
    return A ~= nil and A.enabled == true
        and (tonumber(A.durationMs) or 0) > 0
end

--- Server natives this file leans on, checked ONCE rather than guessed at.
---
--- server/fuel.lua's pattern and its reason: almost nothing about a vehicle is
--- answerable on the server, so the handful that are get checked at load and
--- consulted per call rather than assumed. A build without
--- NetworkGetEntityFromNetworkId cannot resolve the van a client named, and the
--- honest behaviour is to refuse every heal rather than to grant them blind.
local have = {
    entityFromNet = type(NetworkGetEntityFromNetworkId) == 'function',
    netIdFrom     = type(NetworkGetNetworkIdFromEntity) == 'function',
}

if not have.entityFromNet then
    print('^3[br_core] ambheal: NetworkGetEntityFromNetworkId is missing on this '
        .. 'build -- healing in an ambulance is inert^7')
end

-- ---------------------------------------------------------------------------
-- The claim
-- ---------------------------------------------------------------------------

--- Take the van, or find out who has it.
--- @param netId integer
--- @param src integer
--- @param rec table
local function hold(netId, src, rec)
    claims[netId] = rec
    healing[src]  = netId
end

--- Give it back.
---
--- SAFE ON A CLAIM THAT IS NOT THERE, and safe to call twice, because it is
--- reached from six places: the stop message, the completion, the tick's own
--- refusals, a player dropping, a match ending and the roster losing them. A
--- release that had to be called exactly once is a claim that leaks the first
--- time two of those happen together.
--- @param netId integer|nil
--- @return table|nil rec  what was released, for the caller's log
local function release(netId)
    if netId == nil then return nil end
    local rec = claims[netId]
    claims[netId] = nil
    if rec and rec.src then healing[rec.src] = nil end
    return rec
end

--- End this player's heal, whatever they were on.
--- @param src integer
--- @param done boolean   did it run to completion?
--- @param why string
local function finish(src, done, why)
    local netId = healing[src]
    if netId == nil then return end
    release(netId)

    if done then stat.finished = stat.finished + 1
    else stat.stopped = stat.stopped + 1 end

    -- THE CLIENT IS TOLD ON EVERY ENDING, including the ones it did not cause.
    -- It is holding a scripted camera, an attached ped and a per-frame control
    -- block, and every one of those is worse to leave running than the heal was
    -- to interrupt. TriggerClientEvent to a source that has gone is a no-op, so
    -- the disconnect path needs no special case.
    TriggerClientEvent(BR.Net.AMBHEAL_SET, src, { done = done == true })

    print(('[br_core] ambheal: %d stopped healing at ambulance %s -- %s')
        :format(src, tostring(netId), tostring(why)))
end

BR.AmbHeal.finish = finish

--- Is this player healing right now?
---
--- READ BY NOBODY IN THE GAMEMODE TODAY and published anyway, for the reason
--- BR.Rescue.riding() is: the client half has half a dozen files that have to
--- stand down around it, and the server half will need the same the first time
--- something asks whether a player is busy. Nil-safe at every call site.
--- @param src integer
--- @return boolean
function BR.AmbHeal.active(src)
    return healing[src] ~= nil
end

--- @return integer
function BR.AmbHeal.count()
    local n = 0
    for _ in pairs(claims) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Starting one
-- ---------------------------------------------------------------------------

--- May this player heal at that vehicle right now?
---
--- ═══ EVERY REFUSAL IS A NAMED STRING, AND THAT IS FOR /brambheal ═══
---
--- server/rescue.lua's `canCall` learned this the expensive way: six guards that
--- all fail identically from the outside cost three playtest rounds of guessing
--- which one fired. Nothing is ever SHOWN to the player -- a refusal toast would
--- be UI copy nobody asked for -- so the only way anybody finds out is the admin
--- command at the foot of this file, and it can only print a reason that exists.
---
--- @param src integer
--- @param entry table|nil
--- @param netId any
--- @return boolean ok
--- @return string|nil why
--- @return integer|nil veh
function BR.AmbHeal.canHeal(src, entry, netId)
    if not enabled() then return false, 'the feature is off' end
    if not have.entityFromNet then return false, 'no entity resolver on this build' end

    netId = tonumber(netId)
    if netId == nil then return false, 'no vehicle named' end

    if entry == nil then return false, 'no roster entry' end
    if not LIVE[entry.state] then
        return false, ('state is %s, wanted ALIVE'):format(tostring(entry.state))
    end

    local m = BR.Server.matchOf(src)
    if not m or m.state ~= BR.MatchState.PLAYING then
        return false, 'not in a playing match'
    end

    -- ALREADY HEALING SOMEWHERE. Not an error and not a refusal to log loudly --
    -- a duplicate START is what a dropped AMBHEAL_SET looks like from the
    -- client's side -- but it must not start a second claim, which would leak
    -- the first one for the rest of the match.
    if healing[src] ~= nil then return false, 'already healing' end

    -- ═══ HURT. A FULL-HEALTH PLAYER HAS NOTHING TO GAIN ═══
    --
    -- Refused rather than granted-and-instantly-completed, because the second
    -- one costs fifteen seconds of standing still, a camera and a claim on a van
    -- somebody else could have used, in exchange for nothing.
    --
    -- READ OFF THE LEDGER, which is `entry.hp` -- the same number
    -- BR.Damage.applyHit subtracts from. It follows the client's own ped one
    -- sample later (server/roster.lua's sampler), so a client that lies about
    -- being hurt gets... a heal to full, which it could have written itself. The
    -- lie is not worth telling and this check is not the security boundary; the
    -- claim is.
    local hp0 = tonumber(entry.hp) or 100.0
    local cap = tonumber(A.healTo) or 100.0
    if hp0 >= cap then return false, ('already on %d hp'):format(math.floor(hp0)) end

    -- ═══ THE VEHICLE, RESOLVED AND INTERROGATED HERE RATHER THAN TRUSTED ═══
    local okVeh, veh = pcall(NetworkGetEntityFromNetworkId, netId)
    if not okVeh or not veh or veh == 0 then return false, 'that net id resolves to nothing' end

    local okEx, exists = pcall(DoesEntityExist, veh)
    if not okEx or not didHit(exists) then return false, 'that vehicle does not exist' end

    -- IS IT AN AMBULANCE. Asked of server/rescue.lua so both features mean the
    -- same thing by the word -- see BR.Rescue.isAmbulance for the argument.
    -- Nil-guarded because this file must keep loading if the rescue half is ever
    -- pulled, and the honest answer during that window is "nothing is an
    -- ambulance", which makes the feature inert rather than wrong.
    local okModel, model = pcall(GetEntityModel, veh)
    if not okModel then return false, 'could not read the model' end
    if not (BR.Rescue and BR.Rescue.isAmbulance and BR.Rescue.isAmbulance(model)) then
        return false, 'that is not an ambulance'
    end

    -- A RESCUE IS USING IT. The stretcher is the same offset and somebody is
    -- already lying on it; see BR.Rescue.vehicleBusy for why this is a narrow
    -- window rather than a common case.
    if BR.Rescue and BR.Rescue.vehicleBusy and BR.Rescue.vehicleBusy(veh) then
        return false, 'a rescue is using that ambulance'
    end

    -- SOMEBODY ELSE HAS IT. The owner's rule, and the reason this file exists.
    local held = claims[netId]
    if held ~= nil then
        return false, ('%d is already healing there'):format(held.src or -1)
    end

    -- ═══ ARE THEY ACTUALLY STANDING AT THE BACK OF IT ═══
    --
    -- Both positions are the SERVER's: `entry.pos` is sampled here four times a
    -- second from GetEntityCoords on the player's ped (server/roster.lua's note
    -- on why it is not asked of the client applies word for word), and the
    -- vehicle's is read here on this line. Neither is anything the client sent.
    --
    -- THE SAME SOLVER THE CLIENT DREW THE PROMPT WITH, so there is no position
    -- at which the plate is up and this refuses -- client/fuel.lua's header
    -- records what that divergence looks like from the player's side.
    local okPos, c = pcall(GetEntityCoords, veh)
    if not okPos or c == nil then return false, 'could not read where it is' end
    local okHdg, hdg = pcall(GetEntityHeading, veh)
    if not okHdg then hdg = 0.0 end

    local p = entry.pos
    if p == nil then return false, 'no position sample for that player yet' end

    -- ═══ SLACK, AND WHY IT IS ON THE SERVER'S SIDE ONLY ═══
    --
    -- The server's position sample is up to one sampler interval old and the
    -- vehicle may have rolled a little, so a test run at exactly `reachM` would
    -- refuse presses the client legitimately offered. The slack is added HERE
    -- rather than widened in the shared config, so the prompt keeps the tight
    -- number and only the ruling is forgiving -- which is the direction that
    -- cannot produce a heal at a van nobody was standing behind.
    local inReach, dist, dot = BR.AmbHealSolve.atRearDoors(
        c.x, c.y, hdg, p.x, p.y,
        (tonumber(A.reachM) or 3.5) + 2.0,
        (tonumber(A.behindDot) or -0.35) + 0.25)
    if not inReach then
        return false, ('not at the rear doors (%.1fm, dot %.2f)'):format(dist, dot)
    end

    return true, nil, veh
end

RegisterNetEvent(BR.Net.AMBHEAL_START)
AddEventHandler(BR.Net.AMBHEAL_START, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local entry = BR.Roster.get(src)
    local ok, why, veh = BR.AmbHeal.canHeal(src, entry, d.n)
    if not ok then
        stat.refused = stat.refused + 1
        -- LOGGED AND NOT SENT. Nothing in this feature tells the player
        -- anything: the prompt is the only surface, and a refusal message would
        -- be a second one. The console line is for /brambheal and for whoever
        -- is reading a server log after a playtest.
        print(('[br_core] ambheal: refused %d -- %s'):format(src, tostring(why)))
        return
    end

    local netId = tonumber(d.n)
    local now   = GetGameTimer()

    hold(netId, src, {
        src       = src,
        matchId   = entry.matchId,
        veh       = veh,
        netId     = netId,
        startedAt = now,
        hp0       = tonumber(entry.hp) or 100.0,
        lastAt    = now,
    })
    stat.started = stat.started + 1

    -- ═══ THE BLIP, AND THIS IS THE GAP THE OWNER ASKED US TO CHECK ═══
    --
    -- "add that ambulance to our list of ambulance blips if it wasn't already
    -- (such as ambient ones -- should already be covered but just checking)".
    --
    -- IT WAS NOT COVERED, and the reason is one word: SEAT. server/vehicles.lua
    -- discovers ambient ambulances off `drivenVehicle(e)`, which is
    -- `GetPedInVehicleSeat(veh, -1) == ped` -- seat -1, the DRIVING seat, and
    -- nothing else. Its own comment says why it reads that seat rather than all
    -- of them ("the driving seat is the only one whose occupant chose it"), and
    -- that reasoning is sound for what it was built for.
    --
    -- A player who walks up to a parked ambient ambulance and heals in the back
    -- NEVER SITS IN ANY SEAT AT ALL -- they are attached to the stretcher, which
    -- is the same property that keeps a rescued player out of the fuel registry.
    -- So the discovery could not fire, and an ambulance that a player is
    -- demonstrably standing inside would have had no blip.
    --
    -- ONE LINE, THROUGH THE EXISTING FRONT DOOR. BR.Rescue.noteVehicle is the
    -- same function server/vehicles.lua calls, it is keyed on the entity handle,
    -- it re-checks the model itself, it ignores a vehicle it already knows, and
    -- the blip it registers OUTLIVES the heal exactly as it outlives a driver --
    -- which is server/rescue.lua's decision 2 and is the more useful of the two
    -- rules here for the same reason: the van is still sitting there.
    if BR.Rescue and BR.Rescue.noteVehicle then
        BR.Rescue.noteVehicle(src, entry, veh)
    end

    TriggerClientEvent(BR.Net.AMBHEAL_SET, src, { n = netId })

    print(('[br_core] ambheal: %d began healing at ambulance %s from %d hp')
        :format(src, tostring(netId), math.floor(tonumber(entry.hp) or 0)))
end)

RegisterNetEvent(BR.Net.AMBHEAL_STOP)
AddEventHandler(BR.Net.AMBHEAL_STOP, function()
    -- NO PAYLOAD AND NOTHING TO VALIDATE. A player may always stop their own
    -- heal, they keep whatever the server has already issued, and `finish`
    -- returns immediately if they were not healing -- so a duplicate or a stray
    -- costs one table lookup.
    finish(source, false, 'the client asked to stop')
end)

-- ---------------------------------------------------------------------------
-- Issuing the health
-- ---------------------------------------------------------------------------

--- One tick of one heal.
---
--- ═══ WHY THIS IS A COPY OF server/inventory.lua's CONSUMABLE TICK AND NOT A
---     CALL INTO IT ═══
---
--- The shape is deliberately identical -- targets from an origin, a `healUntil`
--- stamp on every issue, INV_EFFECT as the channel -- because that shape is
--- correct and was arrived at through two shipped bugs. What is NOT shared is
--- the surrounding machinery: that loop walks the roster for players with
--- `inv.using`, consumes an item on completion, cancels on damage and pushes an
--- inventory. This has no item, no slot, no consumption and does not cancel on
--- damage. Hoisting the four lines they have in common would mean a function
--- with an item parameter that is always nil.
---
--- ═══ IT DOES NOT CANCEL ON DAMAGE, WHICH IS A DECISION ═══
---
--- BR.Config.Loot.useCancelOnDamage stops a med kit when the player is hit. This
--- does not, and the owner's sentence is why: "if someone shoots me to death
--- while in the ambulance healing, I should still take damage and die
--- completely" -- he is describing being shot mid-heal as an ordinary thing that
--- ends in an ordinary death, not as an interruption. A heal that stopped on the
--- first bullet would make the answer to "what happens if I am shot in there"
--- into "nothing much", which is the opposite of what he asked for.
---
--- The targets are anchored on `hp0` and applied UPWARD ONLY by the client, so
--- being shot at 50% through a heal leaves the player with the damage AND the
--- half-heal, and the ramp keeps climbing from underneath it. That is the same
--- arithmetic as an uninterrupted heal; nothing special happens.
--- @param rec table
--- @param entry table
--- @param now number
local function grant(rec, entry, now)
    local pct = BR.AmbHealSolve.progress(rec.startedAt, now, A.durationMs)
    local target = BR.AmbHealSolve.target(rec.hp0, A.healTo or 100.0, pct)

    -- THE SERVER JUST TOLD THIS PLAYER TO GET HEALTHIER, so server/roster.lua's
    -- health audit must not read the rise as a client lying about its own ped.
    -- shared/health_solve.lua's HEALING excuse is a deadline (`healUntil`) rather
    -- than an event, and server/inventory.lua's note explains why it is stamped
    -- where the effect is ISSUED: these targets are what the client actually
    -- climbs toward, and a window anchored anywhere else would either open
    -- before there was anything to excuse or close while the ped was still on
    -- its way up.
    --
    -- WITHOUT THIS LINE the owner's own feature would be the loudest thing in
    -- his cheat log: a heal to full is up to 100 unexplained points, and
    -- BR.HealthShouldReport's default bar is exactly 100.
    entry.healUntil = now + ((BR.Config.Combat.healthAudit or {}).healSettleMs or 2000)

    TriggerClientEvent(BR.Net.INV_EFFECT, rec.src, {
        health    = target,
        healthCap = A.healTo or 100.0,
    })
    rec.lastAt = now
    stat.granted = stat.granted + 1

    return pct >= 1.0
end

BR.Sched.every(A and A.tickMs or 250, 'ambheal.tick', function()
    if not enabled() then return end

    local now = GetGameTimer()

    for netId, rec in pairs(claims) do
        local entry = BR.Roster.get(rec.src)
        local m     = rec.matchId and BR.Server.matches[rec.matchId]

        -- ═══ THE FIVE WAYS THE SERVER ENDS ONE, AND NONE OF THEM ASKS THE
        --     CLIENT ═══
        --
        -- The client has its own list (the doors shutting, its ped dying, the
        -- van disappearing off its machine) and sends AMBHEAL_STOP. These are
        -- the ones it cannot be trusted with or cannot see: a player who left
        -- the match, one who died, one whose match ended, a vehicle that has
        -- stopped existing, and one who simply walked away. Every one of them
        -- would otherwise leave a claim on a van nobody else could ever use.
        local why = nil
        if entry == nil then
            why = 'they left'
        elseif not m or m.state ~= BR.MatchState.PLAYING then
            why = 'the match is over'
        elseif not LIVE[entry.state] then
            why = ('they are %s now'):format(tostring(entry.state))
        else
            local okEx, exists = pcall(DoesEntityExist, rec.veh)
            if not okEx or not didHit(exists) then
                why = 'the ambulance is gone'
            else
                -- WALKED AWAY. The same reach test the start used, with the same
                -- slack, so a heal cannot be ended by the sampler's own jitter.
                --
                -- IT IS THE SERVER'S JOB EVEN THOUGH THE CLIENT WATCHES TOO,
                -- because the client's watch is the one a modified client
                -- simply would not run -- and a player who could start a heal
                -- and then walk off with it is a player healing to full while
                -- running away, which is a fight-deciding thing rather than a
                -- cosmetic one.
                local okPos, c = pcall(GetEntityCoords, rec.veh)
                local okHdg, hdg = pcall(GetEntityHeading, rec.veh)
                local p = entry.pos
                if okPos and c and p then
                    local inReach = BR.AmbHealSolve.atRearDoors(
                        c.x, c.y, okHdg and hdg or 0.0, p.x, p.y,
                        (tonumber(A.reachM) or 3.5) + 2.0,
                        (tonumber(A.behindDot) or -0.35) + 0.25)
                    if not inReach then why = 'they moved away from it' end
                end
            end
        end

        if why ~= nil then
            release(netId)
            stat.stopped = stat.stopped + 1
            if entry ~= nil then
                TriggerClientEvent(BR.Net.AMBHEAL_SET, rec.src, { done = false })
            end
            print(('[br_core] ambheal: %d stopped healing at ambulance %s -- %s')
                :format(rec.src, tostring(netId), why))
        elseif grant(rec, entry, now) then
            release(netId)
            stat.finished = stat.finished + 1
            TriggerClientEvent(BR.Net.AMBHEAL_SET, rec.src, { done = true })
            print(('[br_core] ambheal: %d finished healing at ambulance %s (%d -> %d hp)')
                :format(rec.src, tostring(netId),
                        math.floor(rec.hp0), math.floor(A.healTo or 100)))
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

--- A player is gone. Drop whatever they were holding.
---
--- CALLED FROM THE ROSTER RATHER THAN FROM playerDropped, so a player removed by
--- a kick, a match teardown or a reconcile is covered by the same line as one
--- who closed the game. server/rescue.lua's BR.Rescue.forget is reached the same
--- way and for the same reason.
--- @param src integer
function BR.AmbHeal.forget(src)
    local netId = healing[src]
    if netId == nil then return end
    release(netId)
    print(('[br_core] ambheal: forgot %d\'s claim on ambulance %s')
        :format(src, tostring(netId)))
end

AddEventHandler('playerDropped', function()
    BR.AmbHeal.forget(source)
end)

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

--- Why can this player not heal in the ambulance they are standing behind?
---
--- THE REFUSAL REASONS EXIST FOR THIS COMMAND AND NOWHERE ELSE, exactly as
--- /brrescue's do. Nothing in this feature ever tells a player anything.
---
--- IT NEEDS A NET ID because the server has no way to guess which vehicle
--- somebody meant -- there is no server-side "closest vehicle" native, which is
--- the same wall server/fuel.lua hit and the reason its own answers come off a
--- seat read. With no argument it prints the live claims instead, which is the
--- question that actually gets asked ("who has that van?").
RegisterCommand('brambheal', function(src, args)
    local target = tonumber(args and args[1])
    local netId  = tonumber(args and args[2])

    print(('[br_core] ambheal: %d live claim(s); started=%d granted=%d '
        .. 'finished=%d stopped=%d refused=%d')
        :format(BR.AmbHeal.count(), stat.started, stat.granted,
                stat.finished, stat.stopped, stat.refused))

    for id, rec in pairs(claims) do
        print(('    ambulance %s <- %d, %.1fs in, from %d hp')
            :format(tostring(id), rec.src,
                    (GetGameTimer() - rec.startedAt) / 1000.0,
                    math.floor(rec.hp0)))
    end

    if target == nil then return end

    local entry = BR.Roster.get(target)
    local ok, why = BR.AmbHeal.canHeal(target, entry, netId)
    print(('    canHeal(%d, net %s) = %s%s')
        :format(target, tostring(netId), tostring(ok),
                ok and '' or (' -- ' .. tostring(why))))
end, true)

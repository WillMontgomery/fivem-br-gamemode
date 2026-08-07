-- M6: server-side damage validation and kill attribution.
--
-- THE ONE THING THAT MAKES THIS POSSIBLE: FiveM raises `weaponDamageEvent` on
-- the SERVER before damage is applied network-wide, and CancelEvent() in that
-- handler stops it reaching anyone. That is a genuine authority hook, not a
-- report-after-the-fact -- which is why M6 can replace the placeholder ammo
-- model rather than merely audit it.
--
-- MEASUREMENT BEFORE ENFORCEMENT, and that is a deliberate sequencing choice.
-- The payload's field names are not documented anywhere authoritative: the
-- game-events reference lists the event and states the list is "largely
-- undocumented", and the production anticheats that use it read only the one
-- or two fields they need (`weaponType`, `hitGlobalId`). Writing a validator
-- against guessed field names and shipping it switched on is the exact shape
-- of the mistake that cost this project six playtest rounds on the ammo
-- counter. So:
--
--   1. /brdamagelog records real payloads and prints every key in them.
--   2. BR.Config.Combat.enforce goes true once those names are known.
--
-- Until step 2, this file validates, logs its verdict, and cancels NOTHING.
-- A wrong assumption is a console line rather than a match where nobody can
-- shoot anybody.

BR = BR or {}
BR.Damage = BR.Damage or {}

local cfg = BR.Config.Combat or {}

-- Last shot time per shooter, for the rate-of-fire check. Keyed by src.
local lastShot = {}

-- Recording state for /brdamagelog.
local recording = 0

-- Ped handle -> player src, rebuilt on a cadence.
--
-- Resolving this per BULLET matters: an automatic weapon raises one of these
-- events per round, and a linear scan over the roster per round is work that
-- scales with both fire rate and player count at once. The map is rebuilt
-- lazily instead, and a miss falls through to a scan -- so a ped that
-- streamed in since the last rebuild still resolves, just once.
local pedMap, pedMapAt = {}, 0

local function rebuildPedMap()
    pedMap = {}
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src)
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then pedMap[ped] = src end
        end)
    pedMapAt = GetGameTimer()
end

--- Resolve a network id to a player src, or nil if it is not a player.
---
--- This is the whole reason hitGlobalIds is worth reading: a shot into an
--- ambient ped is not our business, and one into a player is the only kind
--- this file has an opinion about.
--- @param netId integer
--- @return integer|nil
local function playerFromNetId(netId)
    if not netId then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 then return nil end

    local src = pedMap[ent]
    if src then return src end

    -- Miss: either the map is stale or the ped is an NPC. Rebuilding is cheap
    -- and bounded, but only worth doing once a second -- otherwise every shot
    -- into scenery would rebuild it.
    if GetGameTimer() - pedMapAt > 1000 then
        rebuildPedMap()
        return pedMap[ent]
    end
    return nil
end

--- Everything the validator needs about a shooter/victim pair, from the
--- SERVER's own model. Nothing here comes off the wire.
--- @param shooter integer
--- @param victim integer
--- @return table|nil
local function contextFor(shooter, victim)
    local a = BR.Roster.get(shooter)
    local b = BR.Roster.get(victim)
    if not a or not b then return nil end

    local inv  = BR.Inv and BR.Inv.of(shooter) or nil
    local held = inv and inv.slots[inv.active] or nil

    return {
        sameSrc     = shooter == victim,
        sameMatch   = a.matchId ~= nil and a.matchId == b.matchId,
        shooterLive = a.state == BR.PlayerState.ALIVE,
        victimLive  = b.state == BR.PlayerState.ALIVE
                   or b.state == BR.PlayerState.DBNO,
        sameSquad   = a.squadId ~= nil and a.squadId == b.squadId,
        heldItem    = held and held.item or nil,
        clip        = held and held.clip or nil,
        rarity      = held and held.rarity or nil,
        posA        = a.pos,
        posB        = b.pos,
    }
end

--- Record one payload, printing every key it carries.
---
--- This is the whole point of the current milestone slice: it turns "what
--- fields does weaponDamageEvent have" from a guess into a fact, once.
--- @param sender any
--- @param data table
local function record(sender, data)
    recording = recording - 1
    print(('[br_core] --- weaponDamageEvent sample (%d left) ---'):format(recording))
    print(('  sender: %s'):format(tostring(sender)))
    if type(data) ~= 'table' then
        print(('  data is %s, not a table'):format(type(data)))
        return
    end
    -- Sorted, so two samples can be diffed by eye.
    local keys = {}
    for k in pairs(data) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = data[k]
        if type(v) == 'table' then
            local parts = {}
            for i, item in ipairs(v) do parts[i] = tostring(item) end
            print(('    %-28s { %s }'):format(k, table.concat(parts, ', ')))
        else
            print(('    %-28s %s   [%s]'):format(k, tostring(v), type(v)))
        end
    end
    if recording <= 0 then
        print('[br_core] damage log finished. Paste this to fix the field names.')
    end
end

-- --------------------------------------------------------------------------
-- The handler
-- --------------------------------------------------------------------------

AddEventHandler('weaponDamageEvent', function(sender, data)
    if recording > 0 then record(sender, data) end
    if type(data) ~= 'table' then return end

    local shooter = tonumber(sender)
    if not shooter then return end

    -- hitGlobalIds is the documented-by-usage field; hitGlobalId is the
    -- singular form some builds send. Read both rather than betting on one.
    local ids = data.hitGlobalIds
    if type(ids) ~= 'table' then
        ids = data.hitGlobalId and { data.hitGlobalId } or nil
    end
    if not ids then return end

    for _, netId in ipairs(ids) do
        local victim = playerFromNetId(netId)
        if victim then
            local ctx = contextFor(shooter, victim)
            if ctx then
                local dist = 0.0
                if ctx.posA and ctx.posB then
                    dist = BR.Dist3(ctx.posA.x, ctx.posA.y, ctx.posA.z,
                                    ctx.posB.x, ctx.posB.y, ctx.posB.z)
                end

                local now = GetGameTimer()
                local since = now - (lastShot[shooter] or 0)
                lastShot[shooter] = now

                local ok, why = BR.ValidateShot(
                    { weapon = data.weaponType, dist = dist, sinceLastMs = since },
                    ctx, cfg)

                if not ok then
                    -- REFUSALS ARE LOUD WHILE ENFORCEMENT IS OFF. The whole
                    -- purpose of this phase is to find out how often the
                    -- validator would have been WRONG about an honest shot,
                    -- and a silent refusal teaches nothing. Every line printed
                    -- here during normal play is a FALSE POSITIVE -- a shot
                    -- that would have been wrongly cancelled -- so an empty
                    -- log over a full match is the signal that enforcement is
                    -- safe to switch on.
                    BR.Damage.refusals = (BR.Damage.refusals or 0) + 1
                    print(('[br_core] shot refused: %d -> %d, %s (%.0fm, %dms)')
                        :format(shooter, victim, tostring(why), dist, since))
                    if cfg.enforce then
                        CancelEvent()
                    end
                else
                    -- WHAT THE SERVER THINKS THE HIT WAS WORTH.
                    --
                    -- Recomputed from our own tables and NEVER read off the
                    -- event: `weaponDamage` in the payload is the shooter's
                    -- own number (27 and 33 in the captured samples), and
                    -- `overrideDefaultDamage` arrives TRUE -- which is to say
                    -- the client is already telling the server what the hit
                    -- should cost. That field is precisely what a damage
                    -- multiplier edits, so it is evidence of intent and never
                    -- an input.
                    local head = BR.Config.IsHeadshot(data.hitComponent)
                    local dmg  = BR.ShotDamage(data.weaponType, ctx.rarity,
                                               dist, head, cfg)
                    BR.Damage.lastHit = {
                        shooter = shooter, victim = victim,
                        ours = dmg, theirs = data.weaponDamage,
                        head = head, component = data.hitComponent,
                        willKill = data.willKill, at = now,
                    }
                    if cfg.logHits then
                        print(('[br_core] hit %d -> %d: ours %.1f, client said %s%s')
                            :format(shooter, victim, dmg,
                                    tostring(data.weaponDamage),
                                    head and '  HEADSHOT' or ''))
                    end
                end
            end
        end
    end
end)

-- --------------------------------------------------------------------------
-- Tooling
-- --------------------------------------------------------------------------

--- Capture the next few weaponDamageEvent payloads and print every field.
---
---   brdamagelog          capture BR.Config.Combat.logSamples payloads
---   brdamagelog 40       capture that many
---   brdamagelog off
---
--- Shoot another player (or be shot) while this is running. What it prints is
--- the ground truth this milestone needs before enforcement can be trusted.
RegisterCommand('brdamagelog', function(_, args)
    if args[1] == 'off' then
        recording = 0
        print('[br_core] damage log off')
        return
    end
    recording = math.tointeger(tonumber(args[1])) or cfg.logSamples or 15
    print(('[br_core] recording the next %d weaponDamageEvent payloads.')
        :format(recording))
    print('  Shoot a player. Every field of every payload will be printed.')
end, true)

--- Forget a player's rate-of-fire history. Called on disconnect and at match
--- teardown, so a reconnect cannot inherit a stale "last shot" timestamp and
--- have their first shot refused as too fast.
--- @param src integer
function BR.Damage.forget(src)
    lastShot[src] = nil
end

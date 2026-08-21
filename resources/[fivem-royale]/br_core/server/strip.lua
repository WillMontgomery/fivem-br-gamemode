-- An unissued weapon in the hand: from a client's report to a countable fact.
--
-- WHAT THE CLIENT ALREADY DOES, AND WHY THIS EXISTS. client/inventory.lua's
-- TICK loop takes any weapon out of the ped's hand that is not the active
-- inventory slot -- see the long note there. That strip is a GAMEPLAY fix and
-- not an anticheat one: the engine applies damage locally before the server sees
-- it, so a foreign weapon lets a client kill somebody on their own screen while
-- the server refuses the shot, and the victim reads as dead while being alive.
-- It was a live report on 2026-08-08 and the strip is what stops it happening at
-- all rather than correcting it a round trip later.
--
-- WHAT IT DID NOT DO WAS SAY ANYTHING. A player granting themselves a rifle in a
-- menu tripped no alarm anywhere: the weapon vanished, they granted another, and
-- the server's records ended the match empty. Owner: "when that event fires
-- (removing weapons that aren't granted) - that triggers an incident. Remember a
-- cheater is likely to do this several times recursively, so we need to log that
-- in the incident timeline rather than creating a new incident each time."
--
-- ═══ WHAT THIS CATCHES, STATED PLAINLY SO NOBODY MISTAKES IT FOR THE DEFENCE ═══
--
-- THE REPORT IS CLIENT-SIDE. It arrives because our own resource, running on the
-- offender's machine, chose to send it. A cheat that stops br_core -- or that
-- deletes this one TriggerServerEvent -- silences this entirely, and there is no
-- server-side native that can read what is in a ped's hand to check.
--
-- So this catches exactly the tier the owner described: somebody using vMenu or
-- a trainer to hand themselves a gun, with our resource still running underneath
-- them. That is a real and common tier and it is worth catching. It is not the
-- serious tier, and nothing here should be read as covering it.
--
-- THE UNFORGEABLE HALF IS ELSEWHERE AND IS UNCHANGED: server/damage.lua
-- validates every shot against the inventory the SERVER holds, inside FiveM's
-- own `weaponDamageEvent`, which fires server-side before damage is applied
-- network-wide and can be cancelled outright. That does not need the client's
-- cooperation and cannot be turned off from a client. This file is a tripwire in
-- front of it, not a replacement for it.
--
-- ═══ NOTHING HERE TOUCHES THE PLAYER ═══
--
-- Not a notice, not a hint, not a kick -- the rule server/incident.lua states and
-- this file inherits. A player who discovers they are under suspicion changes
-- behaviour, which costs the case the evidence it was going to be made of.

BR = BR or {}
BR.Strip = {}

--- Which player states may report a strip at all.
---
--- The same pair client/inventory.lua's canArm() gates the hand on, because the
--- report is about a weapon that was IN that hand. A lobby ped and a corpse hold
--- nothing this file has an opinion about.
local LIVE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
}

--- The shortest gap between two strips this server will count from one player.
---
--- THE SECOND THROTTLE, AND THE ONLY ONE THAT IS A CONTROL. client/inventory.lua
--- sends at most one a second, which is a courtesy from code the offender has
--- already decided to modify -- so the number that actually bounds this is here.
--- A client that floods the event gets one countable strip per window and the
--- rest are dropped on the floor, uncounted and unrecorded.
---
--- 900ms RATHER THAN THE CLIENT'S 1000. If the two were equal, ordinary jitter
--- on an honest client's send would land just inside the window and drop a real
--- strip roughly half the time -- the throttle would be quietly deciding what
--- gets recorded rather than bounding what an attacker can force.
local MIN_INTERVAL_MS = 900

--- Per-source counters. [src] = { matchId, count, reports, at }
---
--- BOUNDED BY WHO IS CONNECTED. Cleared on disconnect and rebuilt when the
--- player's match changes, exactly as server/damage.lua's refusal record is.
local seenBy = {}

local stat = { reports = 0, counted = 0, throttled = 0, races = 0 }

--- Counters, for brdebug-style introspection.
---
--- `races` IS THE ONE TO WATCH. It counts reports refused because the weapon
--- turned out to be in the player's own server-side inventory -- see `ourWeapon`
--- -- which is the only false positive this feature can produce. A number that
--- climbs on a healthy server means the client's own filter is not catching a
--- case it should, and every one of those would otherwise have been a case
--- opened against an innocent player.
function BR.Strip.stats()
    local tracked = 0
    for _ in pairs(seenBy) do tracked = tracked + 1 end
    return {
        tracked = tracked,
        reports = stat.reports, counted = stat.counted,
        throttled = stat.throttled, races = stat.races,
    }
end

--- Is this hash a weapon the SERVER believes this player is carrying?
---
--- THE AUTHORITATIVE HALF OF THE FALSE-POSITIVE GUARD. client/inventory.lua
--- already declines to report a weapon that is in any of its own mirror's slots,
--- which catches the common race -- the ped still holding the previous slot's
--- weapon in the window between an INV_SET and the grant landing. That check
--- runs on the client's copy of the inventory, and the client's copy is exactly
--- the thing a compromised client controls.
---
--- This one asks the inventory the server owns. If the weapon is in it, the
--- report is a disagreement between two pieces of our own code about which slot
--- is current, and filing that as evidence of a trainer would put an innocent
--- player in a moderation queue over a tenth of a second of tick ordering.
---
--- EVERY SLOT, NOT THE ACTIVE ONE. "You were holding your own shotgun a moment
--- after switching to your rifle" is the race; narrowing this to the active slot
--- would leave it wide open.
--- @param src integer
--- @param h integer|nil  a normalised hash
--- @return boolean
local function ourWeapon(src, h)
    if h == nil then return false end
    if not (BR.Inv and BR.Inv.of) then return false end
    if not (BR.Config and BR.Config.WeaponById) then return false end

    local inv = BR.Inv.of(src)
    if type(inv) ~= 'table' or type(inv.slots) ~= 'table' then return false end

    for _, s in pairs(inv.slots) do
        if type(s) == 'table' and s.item then
            local w = BR.Config.WeaponById[s.item]
            -- NORMALISED ON BOTH SIDES. The config authors hashes positive and
            -- the engine reports them signed; twenty of this gamemode's forty
            -- weapons could never satisfy a raw comparison, and every one of
            -- them would read here as a weapon we do not issue. That exact trap
            -- has cost this project four bugs.
            if w and w.hash and BR.NormHash(w.hash) == h then return true end
        end
    end
    return false
end

-- THERE IS NO ADMIN EXEMPTION, AND THE ABSENCE IS DELIBERATE.
--
-- An `exemptAdmin` lived here, testing `BR.Grants.CONSOLE` and skipping the
-- report for anyone staff. It was written on the reasoning that the owner
-- grants themselves weapons constantly while testing, so the feature would
-- ship into a queue full of cases about the person who reads the queue.
--
-- The owner overruled it on 2026-08-21, and was right to: the exemption was a
-- hole in an anticheat shaped exactly like the accounts with the most power,
-- and it silenced this path for the one group whose misuse would matter most.
-- The noise it was avoiding is a queue the owner can close; the gap it opened
-- is one nobody would have seen.
--
-- If the testing noise ever becomes the real problem, the fix is a way to mark
-- a session as testing -- something deliberate, visible and logged -- not a
-- silent check on who somebody is.

RegisterNetEvent(BR.Net.INV_STRIPPED)
AddEventHandler(BR.Net.INV_STRIPPED, function(weapon)
    local src = source
    stat.reports = stat.reports + 1

    -- MUST BE A LIVE PLAYER IN A MATCH. Outside one there is no timeline to put
    -- this on and no round for it to be about, and the evidence buffer would
    -- refuse the note anyway.
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    if not e or not LIVE[e.state] or e.matchId == nil then return end

    local now = GetGameTimer()

    -- ONE PER WINDOW. Checked BEFORE anything else costs a table walk, because
    -- a flood is exactly the shape a client can choose to send.
    local rec = seenBy[src]
    if not rec or rec.matchId ~= e.matchId then
        rec = { matchId = e.matchId, count = 0, reports = 0, at = 0 }
        seenBy[src] = rec
    end
    if rec.at ~= 0 and now - rec.at < MIN_INTERVAL_MS then
        stat.throttled = stat.throttled + 1
        return
    end

    -- A HASH OR NOTHING. `math.tointeger` answers nil for a float, a string or a
    -- table, so a client sending rubbish gets an entry with no weapon on it
    -- rather than a stored lie.
    --
    -- ZERO IS TESTED FOR EXPLICITLY, AND IN LUA THAT IS NOT PEDANTRY. `0` is
    -- TRUTHY here, so BR.NormHash(0) returns 0 rather than nil -- a hash of zero
    -- is no weapon at all, and letting it through would put `weapon: 0` on a
    -- moderation record as though it named something. This project has shipped
    -- the truthiness version of this mistake four times.
    local n = math.tointeger(tonumber(weapon))
    local h = (n ~= nil and n ~= 0) and BR.NormHash(n) or nil

    -- OUR OWN CODE DISAGREEING WITH ITSELF IS NOT EVIDENCE. See `ourWeapon`.
    if ourWeapon(src, h) then
        stat.races = stat.races + 1
        return
    end

    -- NOBODY IS EXEMPT. There was an admin exemption here and the owner
    -- removed it on 2026-08-21: "I don't want admins to be exempt from any
    -- incidents please."
    --
    -- IT WILL FILE CASES ABOUT STAFF, AND THAT IS THE POINT. An admin
    -- granting themselves a weapon through vMenu produces a case about
    -- themselves, exactly as it would for anyone else. An anticheat that
    -- looks away from the people holding the keys is not one, and the owner
    -- would rather read their own name in the queue than trust a feature
    -- with a hole in it shaped like staff.
    local license = BR.Roster.licenseOf and BR.Roster.licenseOf(src) or nil

    -- THE THROTTLE WINDOW STARTS ON A COUNTED STRIP, NOT ON EVERY MESSAGE, and
    -- the difference is worth stating because the other order looks tidier.
    -- Starting it here means a report refused as a race leaves the window
    -- closed -- so a genuine strip arriving a moment later is still recorded
    -- rather than swallowed by a refusal that cost nothing.
    --
    -- WHAT THAT LEAVES UNBOUNDED IS BOUNDED ELSEWHERE. The one path a client
    -- can repeat freely is the race check, a walk of five slots. It does not
    -- reach the evidence buffer, the incident writer or the wire. (The admin
    -- exemption used to be the second such path; it is gone.)
    rec.at = now
    rec.count = rec.count + 1
    stat.counted = stat.counted + 1

    -- EVERY COUNTED STRIP GOES ON THE RECORD, and this is the line that answers
    -- the owner's "log that in the incident timeline". The buffer is RAM and
    -- bounded, so this costs nothing until a case exists to attach it to -- and
    -- the case, if one is opened below, is built AFTER this line, so the strip
    -- that opened it is on the timeline it is created with.
    if BR.Evidence and BR.Evidence.noteStrip then
        BR.Evidence.noteStrip(src, h)
    end

    -- SILENT ON THE FIRST, THEN ON EVERY SINGLE ONE AFTER IT. The owner's rule,
    -- 2026-08-20: "'4 or 5 more times' is too many. This should fire an incident
    -- on the 2nd offense, and each subsequent should show as corroboration from
    -- system."
    --
    --   strip 1   recorded in the evidence buffer above and announced to
    --             nobody. One weapon appearing in one hand is the shape a race
    --             between our own two inventory mirrors has, and `ourWeapon`
    --             cannot catch the whole of it; a second one a second later is
    --             not that.
    --   strip 2   the announcement that opens the case. Both strips are already
    --             in the buffer, so the timeline the case is created with has
    --             the one that stayed quiet on it.
    --   strip 3+  one announcement each, every time, which server/incident.lua
    --             turns into a corroboration on the case opened at 2. The
    --             console records those as `System` -- `incidents.corroborate()`
    --             writes `byLicense: null, byName: 'System'` for every one -- so
    --             the attribution the owner asked for is the existing one and
    --             not a second spelling of it.
    --
    -- THIS DELIBERATELY GIVES UP A BOUND, AND THE COST IS WORTH NAMING because
    -- the code it replaces existed to hold it. The old rule announced at the
    -- doublings -- 1, 2, 4, 8 -- so a hundred strips cost about seven events;
    -- this one costs ninety-nine, at up to one every MIN_INTERVAL_MS, onto a
    -- 512-deep drop-oldest outbox with the player_seen stream behind it. The
    -- owner's answer is that four or five announcements for a hundred offences
    -- is not a moderation record, and a queue an offender can flood is a
    -- problem the offender pays for by being in it.
    --
    -- WHAT STILL BOUNDS IT. MIN_INTERVAL_MS above is the real ceiling on this
    -- path and is unchanged; the artifact planner caps a case at six
    -- corroboration frames and nine total; and the timeline is RAM either way,
    -- so no volume of strips adds a DynamoDB write to the two this case was
    -- always going to cost.
    if rec.count < 2 then return end
    rec.reports = rec.reports + 1

    local name = e.name or ('src ' .. src)
    print(('[br_core] ANTICHEAT: %s (%d) -- %d unissued weapon(s) taken out of the hand this match')
        :format(name, src, rec.count))

    -- HANDED OVER, NOT FILED HERE. server/incident.lua decides whether this
    -- opens a case or corroborates one that already exists -- it is the file
    -- that knows what has been filed this match, and it answers the identical
    -- question for refusals. Fire-and-forget: if nothing is listening, the
    -- strips are still in the buffer and the weapon is still out of their hand,
    -- which is the part that protects the match.
    TriggerEvent('br:core:stripped', {
        src      = src,
        name     = name,
        -- nil only for a genuinely licenseless connection, in which case
        -- BR.IncidentBuild.fromStrip declines to file rather than opening a case
        -- about whoever holds this server id next.
        license  = license,
        matchId  = e.matchId,
        -- HOW MANY STRIPS THIS PLAYER HAS DRAWN THIS MATCH, and since the rule
        -- above announces every one from the second, this now counts UP BY ONE
        -- each time: 2, 3, 4, 5. It used to arrive as 1, 2, 4, 8 -- the
        -- doublings -- and a reader that still expects a gap between
        -- consecutive values to mean "strips happened quietly in between" would
        -- be reading a field that no longer says that. A gap here now means a
        -- LOST announcement, exactly as a gap in `seq` does.
        count    = rec.count,
        -- WHICH ANNOUNCEMENT THIS IS for this player, this match: 1 opens the
        -- case, 2+ corroborate it. It rides the wire so the console can tell a
        -- dropped corroboration from a match where nothing more happened -- the
        -- event channel discards a batch after four attempts and never says so.
        --
        -- IT IS NOW `count - 1` BY CONSTRUCTION and is kept anyway. The two
        -- fields answer different questions -- "how many offences" and "how many
        -- times were you told" -- and the day this cadence changes again they
        -- part company; a receiver that had inferred one from the other would
        -- part company with it silently.
        seq      = rec.reports,
        weapon   = h,
        at       = now,
    })
end)

--- Forget a player's strip history.
---
--- SERVER IDS ARE RECYCLED WITHIN THE MINUTE, so a record left behind would be
--- inherited by whoever lands in that slot next -- and inheriting a count is
--- inheriting somebody else's case. The same reason server/damage.lua clears its
--- refusal record here.
AddEventHandler('playerDropped', function()
    local src = source
    if not src then return end
    seenBy[src] = nil
end)

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then seenBy = {} end
end)

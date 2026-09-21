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


--- Per-source counters.
---
---   the count      { matchId, count, reports, at } -- what has been counted, how
---                  many announcements it has produced, and when the throttle
---                  window opened.
---   one memo       { vehAt, vehAns } for `vehicleGun`, one seat read per window.
---
--- BOUNDED BY WHO IS CONNECTED. Cleared on disconnect and rebuilt when the
--- player's match changes, exactly as server/damage.lua's refusal record is.
local seenBy = {}

local stat = { reports = 0, counted = 0, throttled = 0, races = 0,
               vehicleGuns = 0 }

--- Counters, for brdebug-style introspection.
---
--- `races` IS THE ONE TO WATCH. It counts reports refused because the weapon
--- turned out to be in the player's own server-side inventory -- see `ourWeapon`
--- -- which is the only false positive this feature can produce. A number that
--- climbs on a healthy server means the client's own filter is not catching a
--- case it should, and every one of those would otherwise have been a case
--- opened against an innocent player.
---
--- `vehicleGuns` IS THE SECOND ONE, AND IT ARRIVED WITH #322. It counts reports
--- refused because the reporter was sitting in a vehicle this gamemode drives
--- with its gun switched off, holding a hash this gamemode issues nobody -- the
--- engine handing somebody the gun bolted to their own car. See `vehicleGun`.
---
--- `held` IS THE THIRD AND IT ARRIVED WITH #330. It counts reports folded into a
--- sitting already counted -- the same gun, the same seat, still in the hand --
--- and `vehicleGuns` is the number that says how often #329's armament report is
--- doing its job. One that stays at zero while counted strips climb is a seat the
--- engine has told this server nothing about, which is the probe failing rather
--- than a player offending.
function BR.Strip.stats()
    local tracked = 0
    for _ in pairs(seenBy) do tracked = tracked + 1 end
    return {
        tracked = tracked,
        reports = stat.reports, counted = stat.counted,
        throttled = stat.throttled, races = stat.races,
        vehicleGuns = stat.vehicleGuns,
    }
end

--- The console budget this file's one line spends from.
---
--- ═══ #330: ONE SEAT, HUNDREDS OF LINES, AND NOTHING BETWEEN THEM ═══
---
--- Every counted strip from the second onward printed a line, at up to one every
--- MIN_INTERVAL_MS, straight into the console that royale.service pipes to a file
--- on the game box with `tmux pipe-pane`. The rate ceiling bounded the WORK and
--- not the LOG, which is the finding BR.LogBudget was written for (#287) -- and
--- the cadence note below this records giving up the bound in as many words.
---
--- WHAT IS BOUNDED IS THE CONSOLE AND NOTHING ELSE, which is what keeps this
--- clear of the owner's 2026-08-20 ruling -- "each subsequent should show as
--- corroboration from system". That ruling is about the MODERATION RECORD and it
--- is untouched: every counted strip still notes evidence and still raises
--- `br:core:stripped`, so the case still receives every one of them. An operator's
--- screen and a moderation record are different artifacts with different limits.
---
--- AND THE SUMMARY IS WHY THIS IS A RATE LIMIT RATHER THAN A MUTE. A console that
--- is quiet because it is being flooded is the worse of the two bugs; "26 more
--- strip lines went unprinted" is the sentence that tells an operator which of the
--- two they are looking at. It is not optional -- see `sayStrip`.
---
--- ITS OWN INSTANCE, NOT server/damage.lua's, AND THAT IS THE OPPOSITE OF WHAT
--- THAT FILE ARGUES FOR ITS OWN THREE PRINTS. One budget there means three kinds
--- of garbage do not buy three allowances, and it holds because all three sit
--- behind one event a client can manufacture. This line sits behind a different
--- one, and a shared allowance would let a shot flood spend the last line of the
--- strip diagnostic -- blinding the operator to the OTHER attack. The key carries
--- the player, so one offender cannot spend another's allowance either.
---
--- THE SAME KNOBS AS damage.lua's, so a playtest that wants a louder console
--- turns both up from one place, and an unset key reads as the shipped bound
--- rather than as zero.
local logCfg = (BR.Config and BR.Config.Combat) or {}
local logBudget = BR.LogBudget.new({
    windowMs  = logCfg.logWindowMs,
    perKey    = logCfg.logPerKey,
    perWindow = logCfg.logPerWindow,
})

--- Print a strip line, unless too many like it have already been printed.
---
--- FORMATTED LAZILY -- the format string and its arguments rather than a finished
--- line -- for server/damage.lua's `sayRefused` reason: under the flood this
--- exists to bound most calls print nothing, and building a string to throw away
--- is the cost being removed.
--- @param key string   what makes this line the same as another one
--- @param now number
--- @param fmt string
local function sayStrip(key, now, fmt, ...)
    local printIt, summary = logBudget:admit(key, now)
    if printIt then print(fmt:format(...)) end
    -- THE SUMMARY IS NOT OPTIONAL. Without it a flood that keeps going never
    -- reports how much it held back, which is the whole feature.
    if summary then print(BR.LogBudget.line(summary, 'strip')) end
end

--- Report what the console budget held back, once a window has closed.
---
--- THE FLOOD THAT STOPS IS THE CASE THIS EXISTS FOR, and it is server/damage.lua's
--- argument for the same job, one window later: `admit` reports a closing window on
--- the next line that asks to be printed, which covers an attack still in progress
--- and nothing else. A client that floods and then goes quiet would leave the
--- number sitting in the budget until the next strip -- which may be next match or
--- never -- and an operator reading the console afterwards is exactly the person
--- who needs it.
BR.Sched.every(1000, 'strip.logbudget', function()
    local s = logBudget:sweep(GetGameTimer())
    if s then print(BR.LogBudget.line(s, 'strip')) end
end)

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

--- Is this report the engine handing somebody the gun bolted to their own car?
---
--- ═══ THE DEFECT (#322), AND IT IS THE FIRETRUCK AGAIN IN THE CARS HE RULED
---     DRIVABLE ═══
---
--- A firetruck, fifteen minutes, 149 strips and a high severity case against a
--- player who was using the hose (owner, 2026-09-15). The client half of that is
--- answered in client/inventory.lua by BR.Config.StripExemptVehicles. What #322
--- did was make the ARMED rows of the model table DRIVABLE instead of ejecting
--- the player within one 100 ms pass -- so those seats are occupied now, all
--- match, and the same failure is reachable in about sixty more models. The
--- Caracara's gun seat is one the owner hit on 2026-09-19.
---
--- The gun is held off on the CLIENT and that is best effort by construction:
--- the native may not persist between passes, may have no opinion about a turret
--- seat, and is absent on some builds. Each of those ends with the engine
--- putting the vehicle's own gun in the hand, our own TICK loop taking it out
--- ten times a second, and the second report opening a case.
---
--- ═══ TWO CONDITIONS, AND THE SECOND ONE IS WHAT KEEPS THIS NARROW ═══
---
---   1. THE HASH IS ONE THIS GAMEMODE ISSUES NOBODY. Not "not in their
---      inventory" -- `ourWeapon` above already asks that -- but in no row of
---      BR.Config.WeaponByHash at all. Every weapon a trainer is actually worth
---      granting IS in that table (this gamemode's arsenal is the loot table:
---      rifles, shotguns, snipers, the RPG, the minigun, the railgun), so a
---      conjured one is still stripped, still reported and still filed, in a
---      Technical exactly as on foot. What is excused is a hash with no row
---      anywhere, which is the shape a VEHICLE_WEAPON_* hash has.
---   2. THEY ARE SITTING IN A MODEL THE RULING DISARMS. Asked of
---      server/vehicles.lua, which owns the citizenfx/fivem#4006 workaround --
---      a bare `GetVehiclePedIsIn` would excuse everybody who had ever driven a
---      Technical, for the rest of the match.
---
--- ═══ WHAT IT COSTS, SAID OUT LOUD ═══
---
--- Somebody granting themselves a hash in no table of ours, while seated in one
--- of those models, produces no case from this path. They also produce no
--- damage: server/damage.lua refuses a weapon it never issued whatever they are
--- sitting in, and the weapon is still taken out of their hand on every tick.
--- The alternative is a case against an honest player for sitting in a car the
--- owner ruled they may drive, which the issue names as its acceptance
--- criterion.
---
--- ═══ THIS IS NOT THE ADMIN EXEMPTION WEARING A HAT, AND THE DIFFERENCE IS THE
---     WHOLE OF WHY IT IS ALLOWED TO EXIST ═══
---
--- The exemption the owner deleted below asked WHO SOMEBODY IS: staff were not
--- reported, which is a hole shaped exactly like the accounts with the most
--- power. This asks WHAT PRODUCED THE REPORT, in the same way `ourWeapon` above
--- asks it -- a weapon the server itself put in their inventory is our own two
--- mirrors disagreeing, and a gun the ENGINE bolts to a seat this gamemode told
--- the player they may sit in is the same kind of fact. It applies to the owner
--- and to a first-day player identically, and nobody can put themselves inside
--- it except by sitting in one of the vehicles the ruling names.
---
--- IT IS ASKED AFTER `ourWeapon` AND FOR THE SAME REASON THAT ONE IS CHEAP
--- FIRST: this is a seat read and that is a walk of five slots.
--- @param src integer
--- @param h integer|nil  a normalised hash
--- @param rec table     this player's record, for the one-per-window memo
--- @param now integer
--- @return boolean
local function vehicleGun(src, h, rec, now)
    if h == nil then return false end
    if not (BR.Config and BR.Config.WeaponByHash) then return false end
    -- A WEAPON WE ISSUE IS NEVER THE CAR'S. It has a row, so the report is about
    -- a gun somebody could have been given, and that is not this. One table
    -- index, and it is first because it is the answer for every hash a trainer
    -- would bother with -- so a flood of those costs a lookup and nothing else.
    if BR.Config.WeaponByHash[h] ~= nil then return false end

    if not (BR.Vehicles and BR.Vehicles.inDisarmedVehicle) then return false end

    -- ONE SEAT READ PER WINDOW, WHATEVER THE CLIENT SENDS, AND THAT BOUND IS
    -- OWED RATHER THAN OPTIONAL. A report refused here leaves the throttle
    -- window CLOSED -- deliberately, for the reason stated at `rec.at` below --
    -- so this sits on the one path a client may repeat as fast as it can send.
    -- The race check that shares that path costs a walk of five slots; a seat
    -- read is up to ten natives, which is a different order of thing to hand
    -- somebody. Memoised on the player's own record, which is already rebuilt
    -- on a match change and cleared on disconnect.
    --
    -- WHAT THE MEMO COSTS IS UNDER A SECOND OF A STALE ANSWER for a player who
    -- got out of the car, and the failure is in the direction of the honest
    -- player: an excuse that outlives the seat by half a second rather than a
    -- case filed the moment they stepped out.
    if rec.vehAt ~= nil and now - rec.vehAt < MIN_INTERVAL_MS then
        return rec.vehAns
    end

    -- THE ROSTER'S SAMPLED PED, NOT GetPlayerPed(src). server/roster.lua's own
    -- note: GET_PLAYER_PED takes a STRING, and the numeric key answered 0 for
    -- every player once already. A 0 here would read as on foot, which files the
    -- case -- safe, but safe by accident.
    --
    -- THE ENTRY GOES WITH THE PED SINCE #329. That function reads this player's
    -- own armament report -- the engine's answer about the vehicle they are
    -- sitting in, which no server-side native can ask -- and keeps it on their
    -- roster entry so a forged one reaches nobody else. Without the entry the
    -- answer is the authored model table's, exactly as it was before.
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    rec.vehAt  = now
    rec.vehAns = BR.Vehicles.inDisarmedVehicle(e and e.ped, e)
    return rec.vehAns
end

-- THE SITTING FOLD THAT WAS HERE, AND WHY IT IS NOT (#330, review 2026-09-21).
--
-- #330 asked for "a burst of identical refusals from one shooter in one seat is
-- one event", and a `heldInSeat` fold was written for it: same seat, same hash,
-- no row in WeaponByHash, inside a three second gap, counted once per sitting.
-- It worked, and it opened a hole wider than the bug.
--
-- ANY VEHICLE COUNTS AS A SEAT, AND MOST OF GTA'S ARSENAL IS IN NO ROW OF OUR
-- TABLE. So a player sat in a Sultan, granted themselves one WEAPON_APPISTOL and
-- kept it: the first report counted, every later one folded, the count stayed at
-- one, and one is below the bar of two. No ANTICHEAT line, no br:core:stripped,
-- no case, for the whole match. Before the fold that player was filed in about
-- two seconds. That is this detector's TARGET -- "a player granting themselves a
-- rifle in a menu tripped no alarm anywhere" is the reason it exists -- not its
-- false positive.
--
-- AND THE FOLD COULD NOT BE NARROWED INTO SAFETY. The narrow version is "seated
-- in a vehicle the engine says is armed", which is #329's fact, and a report
-- carrying it has already been excused by `vehicleGun` above, so a fold gated on
-- it can never fire. The next ring out is "seated in anything", which is the
-- hole. There is no ring between them.
--
-- SO THE TWO HALVES OF #330 ARE FIXED IN TWO PLACES, one each. The console
-- volume is bounded by the log budget below, which is what the report was about.
-- The turret filing a case at all is #329's: when the engine's armament report
-- arrives, `vehicleGun` excuses the seat before anything here counts. If that
-- report does not arrive the case is filed, which is the behaviour this file had
-- before either change and is a signal the probe failed rather than a silence
-- somebody has to notice.

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

    -- NOR IS THE ENGINE HANDING SOMEBODY THE GUN BOLTED TO THEIR OWN CAR (#322).
    -- Counted rather than filed, and counted separately from `races` because the
    -- two say different things: a race is our two inventory mirrors disagreeing,
    -- this is the engine putting the car's own gun in a hand. See `vehicleGun`.
    --
    -- THE WINDOW IS LEFT CLOSED, exactly as it is for a race: a refusal that
    -- costs nothing must not swallow a genuine strip arriving a moment later.
    --
    -- AND IT RETURNS ABOVE EVERYTHING THAT MAKES NOISE. `rec.count`, the
    -- evidence buffer and the ANTICHEAT line are all below this, so one sitting
    -- in a disarmed model is no console line, no count and no timeline entry
    -- however long it lasts. The owner's Caracara printed a line per report and
    -- counted to eighteen (2026-09-19) because that model was in no row of the
    -- ruling, not because of this order -- but moving the count above this line
    -- would give every disarmed model his console, so tools/test_ringmaster.lua
    -- pins the order.
    if vehicleGun(src, h, rec, now) then
        stat.vehicleGuns = stat.vehicleGuns + 1
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
    -- WHAT THAT LEAVES UNBOUNDED IS BOUNDED ELSEWHERE. The paths a client can
    -- repeat freely are the race check -- a walk of five slots -- and, since #330,
    -- the fold: a table index and a memoised seat read. Neither reaches the
    -- evidence buffer, the incident writer or the wire. (The admin exemption used
    -- to be a third such path; it is gone.)
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
    --
    -- AND SINCE #330 THE BOUND IT GAVE UP IS GIVEN UP FOR THE RECORD ONLY. The
    -- ruling above is what the CASE receives and it is untouched -- every counted
    -- strip still announces. The CONSOLE is bounded separately by `logBudget`,
    -- which prints the first few and says how many it held. What counts as an
    -- OFFENCE is deliberately not bounded here: see the block above `logBudget`
    -- for the fold that was tried and withdrawn.
    if rec.count < 2 then return end
    rec.reports = rec.reports + 1

    local name = e.name or ('src ' .. src)
    -- THROUGH THE BUDGET SINCE #330, AND THE EVENT BELOW IS NOT. See `logBudget`:
    -- the console is bounded, the moderation record is not, and the summary line
    -- keeps the count of what went unprinted so a quiet console cannot be mistaken
    -- for a quiet server. KEYED ON THE PLAYER, so the first few lines of every
    -- offender get through and one flood cannot spend somebody else's allowance.
    sayStrip(('strip:%d'):format(src), now,
        '[br_core] ANTICHEAT: %s (%d) -- %d unissued weapon(s) taken out of the hand this match',
        name, src, rec.count)

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

-- Telling a passenger which slot will actually fire (#206).
--
-- THE FEATURE THIS REPLACES DID NOT WORK, AND THAT IS WHY THIS EXISTS.
--
-- A passenger cannot fire a rifle from a car seat. The cause is game DATA and
-- not a native: a seat names a CVehicleDriveByInfo, that names
-- CVehicleDriveByAnimInfo entries, and each of those names one
-- CDrivebyWeaponGroup. A standard car seat reaches unarmed, one-handed and
-- thrown, so a long gun is taken out of the ped's hands on the way in.
--
-- We shipped br_environment/data/vehiclelayouts.meta redefining
-- DRIVEBY_DEFAULT_ONE_HANDED and DRIVEBY_DEFAULT_REAR_ONE_HANDED by name, so
-- that list would have become every firearm the gamemode issues. THE GAME
-- IGNORED THE REDEFINITION -- owner, 2026-08-22, from the seat: "carbine rifle
-- in the passenger seat does nothing but pistols work." That was the one thing
-- no desk could settle and the playtest settled it; #197 was closed as no plan
-- to fix on the strength of it. The file is gone and docs/vehicle-data.md keeps
-- the finding, with the upstream issue that says the same thing, so nobody pays
-- a playtest round for it twice.
--
-- So the restriction stays, and the only thing left worth doing is to stop it
-- being invisible. The owner's words, verbatim:
--
--   "if a player is in a passenger seat AND has a drive-by capable weapon, AND
--    the drive-by-capable weapon is not already selected, we should give them a
--    one-time notification (per session) that says 'Switch to slot [#] to fire
--    your [weapon] during drive-by shootings.'"
--
-- THREE CONDITIONS, ALL REQUIRED, AND NO FOURTH ONE ADDED. In a passenger seat;
-- holding a drive-by capable weapon somewhere in the inventory; that weapon not
-- already the active slot. A player who already has the pistol out is told
-- nothing, because there is nothing to tell them.
--
-- ═══ WHICH WEAPONS COUNT, AND WHY IT IS NOT A LIST IN THIS FILE ═══
--
-- Telling a player to switch to a weapon that then does not fire is a worse
-- experience than saying nothing, so this cannot be guessed at. There is no
-- native that answers "does this seat accept this weapon" -- the engine only
-- ever answers by stowing, or not stowing, whatever is already in the ped's
-- hands, which is a fact about ONE weapon and only while it is selected. That
-- is what /brdriveby samples and it cannot be asked about a weapon sitting in
-- slot 4.
--
-- So the claim lives as a `driveby` field on each entry in
-- br_lib/config/weapons.lua -- IN the weapon table rather than beside it, so
-- there is no second list to fall out of step with the first. It cannot go
-- silently missing: tools/check_weapons.lua fails the build for any weapon or
-- throwable whose `driveby` is not an explicit boolean, so a gun added without
-- an answer is a red build rather than a gun nobody is ever told to switch to.
--
-- AND THE CLAIM IS AUDITED IN GAME, BECAUSE A GATE CANNOT AUDIT IT. No offline
-- check can know what is inside the game's own .rpf. /brdriveby prints our claim
-- on the row above the engine's behaviour and returns the verdict
-- `stowed-unexpected` when the two disagree in the dangerous direction -- a
-- weapon we would have offered, that the engine took away. That readout is the
-- test; this file is only the consumer.
--
-- ═══ WHAT REMAINS UNVERIFIED, SAID OUT LOUD ═══
--
-- The playtest datum is exactly two weapons wide: pistols fire from a passenger
-- seat and the carbine does not. Everything else in the table is research, and
-- the safe direction is deliberately `false` -- a weapon wrongly marked false
-- costs a notification nobody was owed, and a weapon wrongly marked true costs
-- the trust of the one player who follows the advice. Anything not known is
-- false.

BR = BR or {}
BR.DriveBy = BR.DriveBy or {}

--- THE OWNER'S SENTENCE, AND NOTHING IS APPENDED TO IT.
---
--- No key hint, no second line, no "you can change this in Settings". The
--- standing instruction on this project is that UI text is never added
--- unsolicited, and when wording is given it is used verbatim. The two
--- substitutions are the slot number and the weapon's own label.
BR.DriveBy.MESSAGE = 'Switch to slot %d to fire your %s during drive-by shootings.'

--- A FiveM BOOL, read the only way this codebase is allowed to read one.
---
--- `0` IS TRUTHY IN LUA and a native declared BOOL may hand back `1`/`0` rather
--- than `true`/`false`. IsPedInAnyVehicle is one of them, and this project has
--- shipped that bug four times.
--- @param v any
--- @return boolean
local function yes(v) return v == true or v == 1 end

--- Read the engine without letting an unbound native kill the tick.
--- @return any
local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

--- Does a standard car seat accept this weapon?
---
--- OUR CLAIM, NOT THE ENGINE'S ANSWER, and the distinction is the whole of the
--- header above. Reads the `driveby` field on the weapon table; anything the
--- table does not know is `false`, which is the direction that stays quiet.
---
--- `== true` RATHER THAN A TRUTHINESS TEST, on purpose: the field is required to
--- be a boolean by tools/check_weapons.lua, and reading a missing one as "yes"
--- because some future value is truthy is the failure this whole file is
--- careful about.
--- @param hash integer|nil  a weapon hash, signed or unsigned
--- @return boolean
function BR.DriveBy.permits(hash)
    if hash == nil then return false end
    local w = BR.Config.WeaponByHash[BR.NormHash(hash)]
    if not w then return false end
    return w.driveby == true
end

--- Which slot to name, and what to call the weapon in it.
---
--- PURE, AND IT TAKES THE MIRROR AS AN ARGUMENT, for the same reason
--- BR.Voice.noticeFor and BR.Inv.driveByVerdict are: this is the half that has
--- to be right, the owner cannot easily stage every inventory in game, and a
--- wrong answer here is worse than the bug it describes.
---
--- IT ENCODES TWO OF THE OWNER'S THREE CONDITIONS. "Has a drive-by capable
--- weapon" and "that weapon is not already selected" are both about the
--- inventory and both live here; "is in a passenger seat" is about the world and
--- lives in the tick below.
---
--- THE ACTIVE SLOT BEING CAPABLE IS SILENCE, NOT A FALLBACK. If the player
--- already has a pistol out there is nothing to tell them, so this returns nil
--- rather than naming some other slot that would also work.
---
--- THE LOWEST-NUMBERED SLOT WINS when more than one would do. That is the
--- bar's own left-to-right order, it is deterministic, and "the best drive-by
--- weapon" is a judgement nobody asked for.
---
--- THROWABLES ARE NOT OFFERED, and that is a decision rather than an oversight.
--- A thrown weapon genuinely does work from a seat -- DRIVEBY_THROW is on every
--- standard seat, and `driveby` says so truthfully for the benefit of
--- /brdriveby -- but "fire your Smoke Grenade" is bad advice in a firefight and
--- reads as a bug. The sentence says *fire*; this offers guns.
--- @param mirror table|nil  BR.Inv.local_()
--- @return integer|nil slot   the slot number to name, 1-based as the keys are
--- @return string|nil  label  the weapon's own label, as the bar shows it
function BR.DriveBy.suggestion(mirror)
    if type(mirror) ~= 'table' or type(mirror.slots) ~= 'table' then
        return nil, nil
    end

    --- The firearm in a slot, if the slot holds one this seat would accept.
    local function offerable(slot)
        if type(slot) ~= 'table' then return nil end
        -- Throwables carry `driveby = true` honestly and are still not offered;
        -- see the block above.
        if slot.kind ~= BR.ItemKind.WEAPON then return nil end
        local w = BR.Config.WeaponById[slot.id]
        if not w or w.driveby ~= true then return nil end
        return w
    end

    -- ALREADY HOLDING ONE IS THE SILENT CASE. `mirror.active` may be 0 -- the
    -- melee slot -- and `slots[0]` is simply nil, which is what it should be.
    if offerable(mirror.slots[mirror.active]) then return nil, nil end

    for i = 1, #mirror.slots do
        local w = offerable(mirror.slots[i])
        if w then return i, w.label end
    end
    return nil, nil
end

--- Which seat this ped is in, by asking the vehicle rather than the ped.
---
--- There is no native that answers "which seat am I in"; the engine only answers
--- "who is in seat N". Eight is past the largest seat count in the base game,
--- and a miss reports nil -- which the caller treats as "not a seat we can name"
--- and therefore says nothing, rather than guessing at a passenger seat.
---
--- SHARED WITH /brdriveby rather than written twice: two answers to "which seat
--- am I in" in one Lua state is how the duplicate `brkeys` happened.
--- @param veh integer
--- @param ped integer
--- @return integer|nil
function BR.DriveBy.seatOf(veh, ped)
    for i = -1, 8 do
        if safe(GetPedInVehicleSeat, veh, i) == ped then return i end
    end
    return nil
end

--- HAS THIS SESSION ALREADY BEEN TOLD?
---
--- A FILE-LOCAL BOOLEAN WITH NO RESET, and its lifetime IS the feature. It lives
--- as long as this client's Lua state does, which is exactly what "session"
--- means to a player: false again when they reconnect, and never in between,
--- however many matches, deaths, respawns or vehicles they go through.
---
--- WHAT ELSE RESETS IT, SAID OUT LOUD: restarting br_core. That re-runs this
--- file and the player is told once more. It is an admin action and the cost of
--- getting it "wrong" is one toast.
---
--- SURVIVING A RESTART WOULD COST REAL MACHINERY AND BUY NOTHING -- the same
--- argument client/voice.lua's `noticed` makes in full. KVP's lifetime is the
--- MACHINE, not the session, so a stored flag would suppress this forever on
--- every future connection, which is worse than showing it twice.
---
--- THERE IS NO `noticed = false` ANYWHERE BELOW, and its absence is the whole of
--- "once per session".
local noticed = false

--- For /brdriveby, which prints whether this session has had it.
--- @return boolean
function BR.DriveBy.shown() return noticed end

-- ON THE TICK BAND (100 ms) RATHER THAN PER FRAME. Nothing here is a control
-- disable or a draw call; it is a question that becomes true when a player sits
-- down and stays true while they sit, so ten reads a second is nine more than
-- the answer can change usefully. The whole callback is one comparison once the
-- notice has been delivered, which is most of a session.
BR.Loop.register(BR.Loop.TICK, 'inv.drivebyHint', function()
    if noticed then return end

    -- THE PURE HALF FIRST, BECAUSE IT IS CHEAPER THAN A NATIVE. Five table
    -- lookups against the mirror rule out every player who has nothing to be
    -- told, before a single native is called -- which is most players for most
    -- of a match.
    local slot, label = BR.DriveBy.suggestion(BR.Inv.local_())
    if not slot then return end

    local ped = PlayerPedId()
    if not yes(safe(IsPedInAnyVehicle, ped, false)) then return end
    local veh = safe(GetVehiclePedIsIn, ped, false)
    if not veh or veh == 0 then return end

    -- NOT THE DRIVER, AND NOT A SEAT WE COULD NOT NAME. `-1` is the driver in
    -- every vehicle in the game. nil is the engine declining to place this ped
    -- in any of the seats we asked about, which is not the same as "passenger"
    -- and must not be treated as one.
    local seat = BR.DriveBy.seatOf(veh, ped)
    if seat == nil or seat == -1 then return end

    -- SPENT ON DELIVERY, and the line is above the send for the reason the name
    -- gives: this is the only guard against a second one, and a throw between
    -- here and the toast would otherwise re-arm it on the next tick and keep
    -- doing so for the rest of the session.
    noticed = true

    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
        text = BR.DriveBy.MESSAGE:format(slot, label),
        tone = 'info',
        -- Keyed so nothing can stack under it, and long enough to read a
        -- sentence once -- it is the only time this session it is offered.
        ms   = 8000,
        key  = 'driveby.hint',
    })
end)

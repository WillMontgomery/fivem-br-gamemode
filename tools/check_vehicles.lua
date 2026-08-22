-- Refused-vehicle table gate.
--
-- The same proof tools/check_weapons.lua runs over the arsenal, run over
-- br_lib/config/vehicles.lua -- and it matters MORE here, because the polarity
-- of that table is the opposite of the weapon table's and so is the symptom of a
-- typo.
--
--   A wrong hash in weapons.lua makes a gun we ship behave oddly. Somebody
--   notices, because somebody is holding it.
--
--   A wrong hash in vehicles.lua PERMITS A TANK. `RefusedVehicleByHash` is
--   keyed on the hash, the engine reports the real one, the lookup misses, and
--   `IsAllowedVehicle` answers "allowed" -- which is the answer it gives for
--   every ordinary car, so nothing looks wrong anywhere. The row is present, the
--   name beside it is spelled correctly, and the model it was written to refuse
--   sails through. There is no in-game symptom at all: the incident that should
--   have been filed simply is not, and an absent incident looks exactly like a
--   clean server.
--
-- Every hash in that file is therefore re-derived from the `name` sitting next
-- to it on every commit. Checking a hundred rows takes a millisecond.
--
-- WHAT THIS CANNOT CHECK, said plainly because the gate passing is not the same
-- as the table being right:
--
--   * that a `name` names a REAL GTA model. `joaat('hydraa')` is a perfectly
--     good hash of a vehicle that does not exist, and both this gate and the
--     runtime would agree the row is fine. It refuses nothing, forever, quietly.
--   * that the table is COMPLETE. It is a deny-list -- absence is permission --
--     so every aircraft nobody wrote down is allowed. See the header of
--     config/vehicles.lua for why the owner's rule forces that shape.
--
-- Run via tools/verify.sh, or directly:  lua tools/check_vehicles.lua

local ROOT = 'resources/[fivem-royale]/br_lib/'
for _, f in ipairs({ 'shared/enums.lua', 'shared/geo.lua', 'config/vehicles.lua' }) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        io.write('\27[31mload error\27[0m ', f, ': ', tostring(err), '\n')
        os.exit(1)
    end
    chunk()
end

local fails = 0
local function fail(fmt, ...)
    fails = fails + 1
    io.write('\27[31mFAIL\27[0m ', string.format(fmt, ...), '\n')
end

--- Jenkins one-at-a-time, as GTA computes it: over the LOWERCASED name, with
--- every step truncated to 32 bits. The same function as check_weapons.lua's,
--- copied rather than shared because a gate that imports its own subject is a
--- gate that can be disabled by editing the subject.
--- @param s string
--- @return integer
local function joaat(s)
    local h = 0
    s = s:lower()
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = (h ~ (h >> 6))  & 0xFFFFFFFF
    end
    h = (h + (h << 3))  & 0xFFFFFFFF
    h = (h ~ (h >> 11)) & 0xFFFFFFFF
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

-- Self-test, exactly as check_weapons.lua does it: if joaat itself is wrong then
-- every line below is wrong together, and a gate that fails everything teaches
-- nothing. `rhino` is the anchor -- 0x2EA68690 in every published model table
-- there is, and it is the single model this whole feature exists to keep out.
if joaat('rhino') ~= 0x2EA68690 then
    io.write('\27[31mjoaat is broken\27[0m -- rhino hashed to 0x',
        ('%08X'):format(joaat('rhino')), ', expected 0x2EA68690\n')
    os.exit(1)
end

-- ------------------------------------------------------------------- checks --

local function signed32(h)
    return (h & 0x80000000) ~= 0 and (h - 0x100000000) or h
end

local seenName, seenHash = {}, {}
local checked, topBit, signedChecked = 0, 0, 0

for _, v in ipairs(BR.Config.RefusedVehicles or {}) do
    checked = checked + 1

    if type(v.name) ~= 'string' or v.name == '' then
        fail('a refused-vehicle row has no name to hash')
        goto continue
    end

    if seenName[v.name] then
        fail('duplicate model name %q', v.name)
    end
    seenName[v.name] = true

    do
        local want = joaat(v.name)
        if v.hash ~= want then
            fail('%s: hash is 0x%08X, should be 0x%08X',
                 v.name, v.hash or 0, want)
        end
    end

    -- Two models sharing a hash is the same failure wearing a different hat:
    -- RefusedVehicleByHash keeps one and the other row refuses nothing.
    if v.hash then
        if seenHash[v.hash] then
            fail('%q and %q share hash 0x%08X', v.name, seenHash[v.hash], v.hash)
        end
        seenHash[v.hash] = v.name
    end

    -- The reason reaches a moderation record via vehicleSummaryOf, so a row
    -- with no reason -- or with a reason nobody defined -- would put an empty
    -- sentence, or the word "nil", on a case about a player.
    if v.why ~= BR.Config.VehicleRefusal.FLIES
       and v.why ~= BR.Config.VehicleRefusal.ARMED then
        fail('%s: `why` is %q, which is neither refusal reason',
             v.name, tostring(v.why))
    end

    -- THE ONE THAT WOULD ACTUALLY HAVE CAUGHT THE BUG THIS PROJECT KEEPS
    -- SHIPPING. GetEntityModel reports SIGNED hashes; the table authors them
    -- positive. Asking IsAllowedVehicle the question the way the engine will ask
    -- it proves the normalisation on both sides, rather than proving the table
    -- agrees with itself.
    if v.hash then
        signedChecked = signedChecked + 1
        if (v.hash & 0x80000000) ~= 0 then topBit = topBit + 1 end

        local allowed = BR.Config.IsAllowedVehicle(v.hash)
        if allowed then
            fail('%s reads as ALLOWED from its unsigned hash', v.name)
        end
        local allowedSigned, why = BR.Config.IsAllowedVehicle(signed32(v.hash))
        if allowedSigned then
            fail('%s reads as ALLOWED from its signed hash 0x%08X -- '
                 .. 'this is the form the engine reports', v.name, v.hash)
        elseif why ~= v.why then
            fail('%s refuses with %q from its signed hash but %q from the table',
                 v.name, tostring(why), tostring(v.why))
        end
    end

    ::continue::
end

if checked == 0 then
    fail('the refused-vehicle table is empty -- every aircraft and every armed '
         .. 'vehicle in the game would read as allowed')
end

-- THE BATTLE BUS MUST BE REFUSED, and asserting it here is not a formality.
-- BR.Config.Bus.model is a plane, so the owner's rule covers it, and the whole
-- reason that is safe is that client/bus.lua never networks it. If somebody ever
-- deletes the `titan` row to "fix" the bus, this gate says so -- and the real fix
-- was always the isNetwork flag, never the table.
--
-- config/map.lua is loaded here rather than at the top because it is the only
-- reason this gate needs it, and the dependency is worth being visible.
do
    local chunk = loadfile(ROOT .. 'config/map.lua')
    if not chunk then
        fail('config/map.lua would not load, so the bus model could not be checked')
    else
        chunk()
        local m = (BR.Config.Bus or {}).model
        if type(m) ~= 'string' or m == '' then
            fail('BR.Config.Bus.model is not a model name')
        elseif not seenName[m] then
            fail('the Battle Bus model %q is NOT in the refused table. It is an '
                 .. 'aircraft, so the owner\'s rule refuses it; it is harmless '
                 .. 'only because client/bus.lua creates it with isNetwork = '
                 .. 'false. Removing the row hides the rule, it does not change '
                 .. 'the bus.', m)
        end
    end
end

-- Nothing in the arsenal's world should read as a vehicle and vice versa; they
-- are separate hash spaces and a collision would be a coincidence, but a
-- coincidence that files an incident on a punch is worth one comparison.
do
    local chunk = loadfile(ROOT .. 'config/weapons.lua')
    if chunk then
        chunk()
        for _, v in ipairs(BR.Config.RefusedVehicles or {}) do
            if BR.Config.WeaponByHash and
               BR.Config.WeaponByHash[BR.NormHash(v.hash)] then
                fail('model %q collides with a weapon hash', v.name)
            end
        end
    end
end

-- ------------------------------------------------------------------- report --

if fails == 0 then
    io.write(('\27[32mok\27[0m   %d refused vehicle hashes match their names; %d '
        .. 'resolve from both signed and unsigned (%d have the top bit set)\n')
        :format(checked, signedChecked, topBit))
else
    io.write(('\27[31m%d refused-vehicle table problem(s)\27[0m\n'):format(fails))
end

os.exit(fails == 0 and 0 or 1)

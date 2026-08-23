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

--- Every value BR.Config.VehicleRefusal defines, as a set.
---
--- Built from the enum so a new reason needs no edit here, and so a reason that
--- is NOT in the enum -- the actual failure -- still fails.
local reasons = {}
for _, w in pairs(BR.Config.VehicleRefusal or {}) do reasons[w] = true end
if next(reasons) == nil then
    fail('BR.Config.VehicleRefusal defines no reasons at all')
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
    --
    -- CHECKED AGAINST THE ENUM RATHER THAN AGAINST A LIST SPELLED OUT HERE. It
    -- used to name FLIES and ARMED literally, and #215's third reason therefore
    -- failed three correct rows -- a gate that has to be edited every time the
    -- thing it guards grows is a gate that gets edited carelessly. What it is
    -- actually for is unchanged and still caught: a row whose `why` is nil, or
    -- misspelled, or a bare string nobody defined.
    if reasons[v.why] == nil then
        fail('%s: `why` is %q, which is not a BR.Config.VehicleRefusal value',
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

-- ----------------------------------------------------------- the class net --
--
-- #215's third signal, and it needs the same proof for a sharper reason.
--
-- BR.Config.ClassNetExempt is the ONE allow-shaped list in config/vehicles.lua,
-- so a wrong hash there fails in the direction the rest of this gate exists to
-- prevent: the exemption misses, the class net refuses a Barracks, and a player
-- is pulled out of a troop truck the owner's rule permits. There is no in-game
-- symptom that says "the hash was wrong" -- it just looks like the rule being
-- stricter than it reads.
--
-- And a model in BOTH lists is a contradiction rather than a preference. The
-- model table wins by running first, so the exemption row would be dead code
-- that reads like a permission.
local exempt = 0
for _, v in ipairs(BR.Config.ClassNetExempt or {}) do
    exempt = exempt + 1

    if type(v.name) ~= 'string' or v.name == '' then
        fail('a class-net exemption row has no name to hash')
        goto nextExempt
    end

    do
        local want = joaat(v.name)
        if v.hash ~= want then
            fail('class-net exemption %s: hash is 0x%08X, should be 0x%08X',
                 v.name, v.hash or 0, want)
        end
    end

    if seenName[v.name] then
        fail('%q is in BOTH the refused table and the class-net exemptions. '
             .. 'The model table runs first, so the exemption never fires -- it '
             .. 'reads like a permission and is dead.', v.name)
    end

    -- Asked the way the engine will ask it, both hash forms, exactly as the
    -- refused rows above are. Signed is the form GetEntityModel reports.
    if v.hash then
        if BR.Config.ClassNetExemptByHash[BR.NormHash(v.hash)] == nil then
            fail('class-net exemption %s does not resolve from its own hash',
                 v.name)
        end
        if BR.Config.ClassNetExemptByHash[BR.NormHash(signed32(v.hash))] == nil then
            fail('class-net exemption %s does not resolve from its SIGNED hash '
                 .. '0x%08X -- this is the form the engine reports', v.name,
                 v.hash)
        end
    end

    ::nextExempt::
end

-- A class net with no classes in it is the whole third signal switched off, and
-- switched off silently: every ruling would still come out of the model table
-- and every test of the model table would still pass.
do
    local classes = 0
    for k, w in pairs(BR.Config.RefusedVehicleClasses or {}) do
        classes = classes + 1
        if math.type(k) ~= 'integer' or k < 0 or k > 22 then
            fail('refused vehicle class %s is not one of GTA V\'s 0-22',
                 tostring(k))
        end
        if reasons[w] == nil then
            fail('refused vehicle class %s maps to %q, which is not a '
                 .. 'BR.Config.VehicleRefusal value', tostring(k), tostring(w))
        end
    end
    if classes == 0 then
        fail('BR.Config.RefusedVehicleClasses is empty -- the class net is off, '
             .. 'and nothing else in the tree would say so')
    end
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
        .. 'resolve from both signed and unsigned (%d have the top bit set); '
        .. '%d class-net exemptions\n')
        :format(checked, signedChecked, topBit, exempt))
else
    io.write(('\27[31m%d refused-vehicle table problem(s)\27[0m\n'):format(fails))
end

os.exit(fails == 0 and 0 or 1)

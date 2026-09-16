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
--- [model name] = the `why` on its row, for the strip-exemption check below.
--- SEPARATE FROM `seenName` rather than stored in it: a row whose `why` is nil
--- has already failed, and folding the two would make that row invisible to the
--- duplicate-name check as well.
local refusedWhy = {}
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
    refusedWhy[v.name] = v.why

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

        -- ═══ #322: WHICH ROWS ARE DRIVEN WITH THE GUN OFF, ROW BY ROW ═══
        --
        -- The owner's ruling is "only vehicles refused for being ARMED become
        -- drivable", so the disarmed set and the ARMED rows are the SAME SET and
        -- an equality is the honest way to say it. Asserted in both directions
        -- on every row, because both directions are a shipped bug:
        --
        --   an ARMED row that is not disarmed   is a car that still ejects, and
        --                                       the ruling did not land.
        --   a FLIES or TANK row that IS         is a Buzzard or a Rhino that a
        --                                       player may now drive, which is
        --                                       the outcome the ruling names and
        --                                       excludes.
        --
        -- IN BOTH HASH FORMS, exactly as everything above is, because the engine
        -- reports the signed one and a predicate that normalises only one way
        -- would put the Rhino on the wrong side of this for real.
        -- `keepRefused` IS THE ONE EXCEPTION AND IT IS READ FROM THE ROW, not
        -- from a list of names spelled out here. A gate that carried its own
        -- copy of the seven would pass while the two disagreed, which is the
        -- failure this whole file exists to make impossible.
        local wantDisarm = (v.why == BR.Config.VehicleRefusal.ARMED)
            and v.keepRefused ~= true

        -- AND THE FIELD ONLY MEANS ANYTHING ON AN ARMED ROW. On a FLIES or TANK
        -- row it is already refused and the field would be a no-op that reads
        -- like a decision -- the same objection config/vehicles.lua's own header
        -- makes about an exemption row that never fires.
        if v.keepRefused ~= nil and v.why ~= BR.Config.VehicleRefusal.ARMED then
            fail('%s carries keepRefused but is %q, not ARMED -- the field is an '
                 .. 'exception to the #322 ruling and that ruling never reaches '
                 .. 'this row, so it is dead and reads like a decision',
                 v.name, tostring(v.why))
        end
        if v.keepRefused ~= nil and v.keepRefused ~= true then
            fail('%s has keepRefused = %s -- it is true or it is absent, because '
                 .. 'a false here reads as "considered and allowed" when it is '
                 .. 'the same as not writing it', v.name, tostring(v.keepRefused))
        end
        if BR.Config.IsDisarmedVehicle(v.hash) ~= wantDisarm then
            fail('%s is %q but IsDisarmedVehicle says %s -- #322 converts the '
                 .. 'ARMED rows and only the ARMED rows', v.name,
                 tostring(v.why), tostring(BR.Config.IsDisarmedVehicle(v.hash)))
        end
        if BR.Config.IsDisarmedVehicle(signed32(v.hash)) ~= wantDisarm then
            fail('%s answers #322 differently from its SIGNED hash 0x%08X -- '
                 .. 'this is the form GetEntityModel reports', v.name, v.hash)
        end

        -- AND THE RULING END TO END, THROUGH THE FUNCTION THE THREE CALLERS
        -- ACTUALLY ASK. The predicate above could be right while
        -- VehicleRefusalFor ignored it, which is the same feature switched off.
        -- No signals: this is the model table's own verdict, which is all a
        -- creation-time caller ever has.
        local ruling = BR.Config.VehicleRefusalFor(v.hash)
        if wantDisarm then
            if ruling ~= nil then
                fail('%s is ARMED in the table but VehicleRefusalFor still '
                     .. 'refuses it with %q', v.name, tostring(ruling))
            end
        elseif ruling ~= v.why then
            fail('%s is %q in the table but VehicleRefusalFor answers %q',
                 v.name, tostring(v.why), tostring(ruling))
        end
    end

    ::continue::
end

-- ------------------------------------------------------- #322, in the whole --
--
-- THE LEAK THE ISSUE WAS OPENED ABOUT. `caracara2` carries a mounted gun on an
-- ordinary Off-road body: no type says so, class 2 is in no net, and it was
-- permitted by OMISSION -- allowed and armed -- for as long as this table has
-- existed. Named here rather than left to the loop above because the loop proves
-- the rows that ARE present are consistent and can say nothing at all about one
-- that is deleted, and deleting this row restores the leak in silence.
if not seenName['caracara2'] then
    fail('`caracara2` is not in the refused table. It carries a mounted gun in '
         .. 'an ordinary Off-road class, so no type and no class net sees it, '
         .. 'and without a row it is ALLOWED AND ARMED -- which is the leak '
         .. '#322 was opened about.')
elseif refusedWhy['caracara2'] ~= BR.Config.VehicleRefusal.ARMED then
    fail('`caracara2` is %q rather than ARMED. Under #322 that is the '
         .. 'difference between a car the gamemode drives with the gun off and '
         .. 'one it throws the player out of.',
         tostring(refusedWhy['caracara2']))
end

-- THE CLASS NET KEEPS ITS ARMED REFUSAL, AND THIS IS THE ASSERTION THE WHOLE
-- RULING TURNS ON. Class 19 maps to the SAME `why` string the model table's
-- armed rows carry -- BR.Config.VehicleRefusal.ARMED, character for character --
-- so an implementation that converted on the reason word instead of on the
-- signal would pass every row-by-row check above and would quietly make every
-- unknown piece of military hardware drivable. That is the one outcome the owner
-- ruled out by name.
--
-- A hash in NO row of the table, so only the class net can answer for it.
do
    local UNLISTED = 0x0BADF00D
    if seenHash[UNLISTED] then
        fail('the class-net probe hash 0x%08X is now a real row -- pick another',
             UNLISTED)
    end

    local why, signal = BR.Config.VehicleRefusalFor(UNLISTED, {
        classOf = function() return 19 end,
    })
    if why ~= BR.Config.VehicleRefusal.ARMED or signal ~= 'class' then
        fail('unlisted class 19 no longer refuses as ARMED by the class net -- '
             .. 'got %q from %q', tostring(why), tostring(signal))
    end
    if BR.Config.IsDisarmedVehicle(UNLISTED) then
        fail('an unlisted model reads as disarmed. #322 converts rows of the '
             .. 'model table, which is enumerated; class 19 is the catch-all '
             .. 'for military hardware nobody wrote down and converting it '
             .. 'makes an unknown tank drivable.')
    end
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

-- --------------------------------------------- the strip-exempt vehicles --
--
-- The SECOND allow-shaped list, added 2026-09-15, and the one whose wrong hash
-- is worst of the three.
--
-- A wrong hash in the refused table permits a tank. A wrong hash in the
-- class-net exemptions pulls somebody out of a troop truck. A wrong hash HERE
-- switches the unissued-weapon anticheat off inside whatever model the typo
-- happens to name -- and every symptom of that points the other way. The
-- firetruck keeps filing the cases this table was added to stop, so it reads as
-- "the fix did not work"; meanwhile some unrelated car is quietly a place where
-- a conjured rifle is never taken out of anybody's hand, and an absent incident
-- looks exactly like a clean server.
--
-- Same two forms as the rows above, because the engine reports the signed one.
local stripExempt = 0
for _, v in ipairs(BR.Config.StripExemptVehicles or {}) do
    stripExempt = stripExempt + 1

    if type(v.name) ~= 'string' or v.name == '' then
        fail('a strip-exempt row has no name to hash')
        goto nextStripExempt
    end

    do
        local want = joaat(v.name)
        if v.hash ~= want then
            fail('strip-exempt vehicle %s: hash is 0x%08X, should be 0x%08X',
                 v.name, v.hash or 0, want)
        end
    end

    -- A MODEL IN BOTH LISTS IS A CONTRADICTION AND NOT A PREFERENCE, exactly as
    -- it is for the class-net exemptions. A refused model is one nobody is left
    -- sitting in -- client/vehrefuse.lua ejects them -- so an exemption saying
    -- "the anticheat is off in here" describes a seat that does not exist.
    --
    -- ═══ EXCEPT FOR AN ARMED ROW, SINCE #322, AND THE EXCEPTION IS NARROW ON
    --     PURPOSE ═══
    --
    -- The owner's ruling made the ARMED rows DRIVABLE rather than ejected, so
    -- their seats are occupied now and the firetruck failure can happen in one:
    -- a gun position `GetCurrentPedVehicleWeapon` has no opinion about, where
    -- nothing is disabled, `isMountedWeapon` misses, and the strip files a case
    -- against somebody who only got in a car. This table is the documented
    -- answer to that, so the gate must not stand in front of it.
    --
    -- FLIES AND TANK ARE UNCHANGED AND STILL A CONTRADICTION. Those two still
    -- eject, so the original sentence is still true of them word for word -- and
    -- keeping the check for them is what stops this exception being read as
    -- "refused models may be strip-exempt now".
    if seenName[v.name]
       and refusedWhy[v.name] ~= BR.Config.VehicleRefusal.ARMED then
        fail('%q is in BOTH the refused table and the strip exemptions, and it '
             .. 'is refused for %q rather than being armed. That vehicle is '
             .. 'still ejected, so the seat this exempts is never occupied -- '
             .. 'one of the two rows is wrong.', v.name,
             tostring(refusedWhy[v.name]))
    end

    if v.hash then
        if BR.Config.StripExemptByHash[BR.NormHash(v.hash)] == nil then
            fail('strip-exempt vehicle %s does not resolve from its own hash',
                 v.name)
        end
        if BR.Config.StripExemptByHash[BR.NormHash(signed32(v.hash))] == nil then
            fail('strip-exempt vehicle %s does not resolve from its SIGNED hash '
                 .. '0x%08X -- this is the form GetEntityModel reports', v.name,
                 v.hash)
        end
    end

    ::nextStripExempt::
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
    -- THE STRIP-EXEMPT COUNT IS PRINTED, NOT ASSUMED. An empty list checks
    -- nothing and passes, which is the correct outcome for a server that wants
    -- no exemptions and a silent one for a table somebody emptied by accident.
    -- The number on this line is what tells those apart.
    io.write(('\27[32mok\27[0m   %d refused vehicle hashes match their names; %d '
        .. 'resolve from both signed and unsigned (%d have the top bit set); '
        .. '%d class-net exemptions; %d strip-exempt\n')
        :format(checked, signedChecked, topBit, exempt, stripExempt))
else
    io.write(('\27[31m%d refused-vehicle table problem(s)\27[0m\n'):format(fails))
end

os.exit(fails == 0 and 0 or 1)

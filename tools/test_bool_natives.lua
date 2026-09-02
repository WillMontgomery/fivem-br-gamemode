-- Unit tests for the BOOL-native rules.
--
--   lua tools/test_bool_natives.lua      (or via tools/verify.sh)
--
-- WHAT THIS SUITE IS GUARDING. In Lua the number 0 is TRUTHY and a FiveM native
-- declared BOOL may answer 1/0, so `if HasCollisionLoadedAroundEntity(p) then`
-- is TRUE for a native that said no and `while not HasCollisionLoadedAroundEntity(p) do`
-- is FALSE for the same no. This project has shipped that seven times.
-- tools/check_bool_natives.lua is the gate against instance eight -- but it
-- only ever reads the REAL tree against a recorded baseline, so on a clean
-- checkout it proves the tree has not got worse and cannot prove it would
-- notice if it had. A detector that has silently stopped detecting reports "ok"
-- in exactly the same green as a real pass.
--
-- So the rules live in tools/bool_native_rules.lua as pure functions over a
-- source string, and this suite feeds them sources that are DELIBERATELY WRONG
-- and asserts each one is caught.
--
-- THE OTHER HALF MATTERS MORE, and it is every case marked "not a fault". A
-- gate that flags correct code gets an exception, then a second one, then gets
-- deleted -- so each spelling of the FIX is asserted to be silent: the helper
-- wrap, the explicit comparison, the value stored in a local, the debug
-- readout, the marked line, and the project's own helpers whose names happen to
-- read like natives. check_forward_locals.lua learned that lesson the
-- expensive way on watch/unwatch (#192); these cases are what keeps it learned.

local R = dofile('tools/bool_native_rules.lua')

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        io.write('\27[31mFAIL\27[0m ', group, ' > ', name)
        if detail then io.write('\n       ', tostring(detail)) end
        io.write('\n')
    end
end

--- Was anything at all reported?
local function hits(src, declared)
    return #R.scan(src, declared)
end

--- Is this native reported in this source?
local function caught(src, native, declared)
    for _, h in ipairs(R.scan(src, declared)) do
        if h.native == native then return true end
    end
    return false
end

--- The reported lines, as a sorted list, for the position assertions.
local function at(src)
    local out = {}
    for _, h in ipairs(R.scan(src)) do out[#out + 1] = h.line end
    table.sort(out)
    return table.concat(out, ',')
end

-- ======================================================================== --
-- THE FAULT, IN BOTH DIRECTIONS
-- ======================================================================== --

describe('the two spellings that shipped seven times')
do
    -- THE `if` FORM. 0 is truthy, so a native that answered "no" reads as yes
    -- and the code proceeds -- which in the placement path is a teleport onto
    -- geometry that has not streamed.
    ok(caught('if HasCollisionLoadedAroundEntity(ped) then break end',
              'HasCollisionLoadedAroundEntity'),
       'a bare `if <native>() then` is a fault')

    -- THE `while not` FORM, which is the one that reads as careful. `not 0` is
    -- FALSE, so the loop exits on its first iteration: the wait is still there
    -- in the source and does not exist at runtime.
    ok(caught('while not HasCollisionLoadedAroundEntity(ped) do end',
              'HasCollisionLoadedAroundEntity'),
       'and so is `while not <native>() do`')

    ok(caught('until IsScreenFadedOut()', 'IsScreenFadedOut'),
       'and `until`, which is the same loop written the other way up')

    ok(caught('if a and DoesEntityExist(e) then end', 'DoesEntityExist'),
       'a native reached through `and` is still in truth position')
    ok(caught('if DoesEntityExist(e) or b then end', 'DoesEntityExist'),
       'and through `or`')
    ok(caught('elseif IsPedOnFoot(ped) then', 'IsPedOnFoot'),
       'and after `elseif`, which is not the same word as `if`')

    -- ONE LINE CAN CARRY MORE THAN ONE, and a scanner that stops at the first
    -- match reports half a fault. spawn.lua's reveal really did have two.
    ok(hits('if not IsScreenFadedIn() and not IsScreenFadingIn() then') == 2,
       'both natives on a two-native line are reported, not just the first',
       at('if not IsScreenFadedIn() and not IsScreenFadingIn() then'))
end

describe('the names that do not start with the question')
do
    -- BOTH OF THESE WERE READ RAW IN THE SEVENTH INSTANCE, and a front-anchored
    -- name rule walks past both. NetworkIsSessionStarted gates the whole boot
    -- and GetIsLoadingScreenActive decides whether a mid-session restart
    -- replays the entire boot choreography over a live world.
    ok(caught('while not NetworkIsSessionStarted() do end',
              'NetworkIsSessionStarted'),
       'NetworkIsSessionStarted is BOOL-shaped even in the middle of the name')
    ok(caught('if not GetIsLoadingScreenActive() then end',
              'GetIsLoadingScreenActive'),
       'and so is GetIsLoadingScreenActive')

    -- NOT A BOOL AT ALL -- it returns an entity handle and 0 for "none", which
    -- is the same bug in a different return type. server/vehicles.lua carries
    -- the write-up. Catching it is the right answer, not a false alarm.
    ok(caught('if GetVehiclePedIsIn(ped, false) then end', 'GetVehiclePedIsIn'),
       'a handle-returning native that answers 0 for none is the same fault')

    ok(R.boolShaped('CanPedSeePed') and R.boolShaped('DoesBlipExist')
       and R.boolShaped('HasModelLoaded') and R.boolShaped('IsEntityDead'),
       'all four question words are recognised')
    ok(not R.boolShaped('GetEntityCoords')
       and not R.boolShaped('SetEntityHeading')
       and not R.boolShaped('RequestCollisionAtCoord'),
       'and an ordinary native is not')
    ok(not R.boolShaped('Display') and not R.boolShaped('Cancel')
       and not R.boolShaped('Isolate'),
       'the question word must be a whole capitalised word, not a prefix of one')
end

-- ======================================================================== --
-- EVERY SPELLING OF THE FIX IS SILENT
-- ======================================================================== --

describe('the fix is not reported')
do
    -- THIS IS HOW THE HELPERS ARE RECOGNISED, and it is why the rule needs no
    -- list of their names: wrapping the call makes its value an ARGUMENT rather
    -- than the truth value, and that is exactly what the fix does. isTrue and
    -- yes are both live in this repo and neither is named anywhere in the rules.
    ok(hits('while not isTrue(HasCollisionLoadedAroundEntity(obj)) do end') == 0,
       'isTrue(...) -- loot.lua\'s spelling')
    ok(hits('if yes(IsPedOnFoot(ped)) then end') == 0,
       'yes(...) -- debug.lua\'s spelling')
    ok(hits('if BR.Util.truthy(IsPedOnFoot(ped)) then end') == 0,
       'and a helper nobody has written yet, reached through a table')

    ok(hits('if DoesEntityExist(e) == 1 then end') == 0,
       'an explicit == comparison')
    ok(hits('if DoesEntityExist(e) ~= false then end') == 0,
       'and an explicit ~= comparison')

    -- STORED FIRST. The same bug if the local is later tested -- and also how
    -- half the correct code in this repo is written, so reporting it would put
    -- the gate permanently in the way. Stated here so the omission is a
    -- decision on the record rather than a hole somebody finds later.
    ok(hits('local exists = DoesEntityExist(ped)') == 0,
       'a value stored in a local is out of scope, deliberately')

    -- A DEBUG READOUT WANTS THE RAW ANSWER. spawn.lua's diagnose() and
    -- skydive.lua's /brdropdbg both print what the engine actually said,
    -- because on the day it matters `0` is the most useful thing on the line.
    ok(hits('print(tostring(IsScreenFadedOut()))') == 0,
       'a native being printed is not being believed')

    ok(hits('    return HasPedGotWeapon(ped, CHUTE, false)') == 0,
       'a bare `return` is not a truth test either')

    -- THE PER-LINE ESCAPE, spelled like the scope gate's `scope-ok`.
    ok(hits('if IsScreenFadedOut() then end  -- bool-ok: reading the raw answer') == 0,
       'and a line marked bool-ok is exempt')
end

describe('the project\'s own functions are not natives')
do
    -- BR.Native.IsDeadHp, isAllowedVehicle and friends read like natives and
    -- return real Lua booleans. Reporting them would teach people to rename
    -- their functions to get past the gate, which is the worst thing a gate can
    -- teach -- the lesson check_forward_locals.lua learned on watch/unwatch.
    local src = [[
local function IsDeadHp(hp) return hp <= 0 end
if IsDeadHp(hp) then return end
]]
    ok(hits(src, R.declared(src)) == 0,
       'a local function declared in the source is skipped')

    -- ACROSS FILES TOO: the gate builds one declared-name set over everything
    -- it scans, because a helper declared in br_lib is still a helper when
    -- br_core calls it.
    local lib = 'function BR.Native.IsAllowedVehicle(v) return true end'
    local use = 'if IsAllowedVehicle(v) then end'
    local d = R.declared(lib)
    ok(hits(use, d) == 0, 'and one declared in another file is skipped as well')
    ok(hits(use) == 1,
       'which is a real exclusion -- unknown, the same call is reported')

    ok(hits('if t.IsReady() then end') == 0
       and hits('if t:IsReady() then end') == 0,
       'a method call on a table is somebody else\'s function')
end

-- ======================================================================== --
-- THE SCANNER MUST NOT READ ITS OWN SUBJECT MATTER
-- ======================================================================== --

describe('prose about the bug is not the bug')
do
    -- THIS REPO IS HALF COMMENTARY, and every file that carries a write-up of
    -- this defect quotes the wrong spelling verbatim in order to explain it --
    -- loot.lua, dbno.lua, natives.lua, and the rules file itself. A scanner
    -- that read those would report the explanation as the fault, go red on
    -- correct files, and be deleted by the end of the week. check_weapons.lua
    -- and check_key_glyphs.lua both learned this first.
    ok(hits('-- `if HasCollisionLoadedAroundEntity(e) then` is TRUE for a 0') == 0,
       'a comment quoting the wrong spelling is not a fault')
    ok(hits('local msg = "if DoesEntityExist(e) then"') == 0,
       'nor is a string containing it')
    ok(hits('foo() -- if IsPedOnFoot(ped) then') == 0,
       'nor a trailing comment after real code')

    -- AND THE RULES FILE ITSELF, which is the sharpest version of the test:
    -- it names the natives, quotes both broken spellings, and must come back
    -- clean.
    local fh = io.open('tools/bool_native_rules.lua', 'r')
    if fh then
        local self_ = fh:read('a'); fh:close()
        ok(hits(self_, R.declared(self_)) == 0,
           'and the rules file, which quotes both broken spellings, is clean')
    else
        ok(false, 'tools/bool_native_rules.lua is readable')
    end
end

describe('the line numbers are the real ones')
do
    -- The report is pasted into a commit message and grepped for; a scanner
    -- whose line numbers drift once it has blanked a string is a scanner nobody
    -- trusts twice.
    local src = table.concat({
        '-- a comment',                             -- 1
        'local s = "if IsPedOnFoot(x) then"',       -- 2
        '',                                         -- 3
        'if IsPedOnFoot(ped) then end',             -- 4
        'local q = 1',                              -- 5
        'while not DoesEntityExist(e) do end',      -- 6
    }, '\n')
    ok(at(src) == '4,6', 'only the two real faults, at their own line numbers',
       at(src))
end

-- ----------------------------------------------------------------- result ---

io.write(('\n%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')

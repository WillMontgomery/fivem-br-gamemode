-- Static gate: a FiveM BOOL native read as a Lua truth value.
--
-- THE MOST-SHIPPED DEFECT IN THIS REPOSITORY. In Lua the number 0 is TRUTHY and
-- a native declared BOOL may answer 1/0, so both obvious spellings of the test
-- are wrong and they are wrong in opposite directions -- one proceeds without
-- waiting, the other stops waiting. tools/bool_native_rules.lua carries the
-- full write-up and the rules themselves; this file is the part that reads the
-- tree and compares it with what was already known.
--
-- Seven instances. dbno.lua, natives.lua, boost_solve.lua, keybinds.lua,
-- party.lua and vehicles.lua each carry the record of one, and the seventh was
-- the entire spawn/drop path -- spawn.lua, loading.lua, bus.lua and
-- skydive.lua, forty-eight raw reads between them, every one in a wait. Six
-- recurrences say review does not catch this, so this does.
--
-- ── THE BASELINE, AND WHY IT IS A RATCHET ─────────────────────────────────
--
-- There were 104 of these left when the gate landed. A gate that fails the
-- build on all of them is a gate somebody deletes on the Monday, and one that
-- reports them as warnings is a gate nobody reads. So the debt is WRITTEN DOWN,
-- per file and per native, in tools/bool_natives.baseline -- and the number may
-- only go DOWN:
--
--   * a file/native pair not in the baseline  -> FAIL. This is instance eight.
--   * more than the baseline records          -> FAIL. The same thing, in a
--                                                file that already had some.
--   * FEWER than the baseline records         -> FAIL, and this is the ratchet.
--                                                Lower the number in the commit
--                                                that lowers the count, or the
--                                                room you just made stays open
--                                                for the next one to fill
--                                                without anything going red.
--   * a baseline line matching nothing        -> FAIL. A file was renamed or
--                                                deleted and the record rotted.
--
-- Every one of those is a one-line edit with the exact replacement printed, and
-- NONE of them is a false positive: the gate is green on the tree that
-- generated the baseline, so it can only ever go red on a CHANGE -- which is
-- the only thing it claims to detect.
--
-- Regenerate after a deliberate change:
--     lua tools/check_bool_natives.lua --write-baseline <file>...
--
-- Run standalone:  lua tools/check_bool_natives.lua <file>...

local Rules = dofile('tools/bool_native_rules.lua')

local BASELINE = 'tools/bool_natives.baseline'

local function read(path)
    local fh = io.open(path, 'r')
    if not fh then return nil end
    local src = fh:read('a')
    fh:close()
    return src
end

local function readBaseline()
    local by = {}
    local fh = io.open(BASELINE, 'r')
    if not fh then return nil end
    for line in fh:lines() do
        if line ~= '' and not line:match('^#') then
            local count, path, native = line:match('^(%d+)\t(.-)\t(.+)$')
            if count then by[path .. '\t' .. native] = tonumber(count) end
        end
    end
    fh:close()
    return by
end

local function writeBaseline(by)
    local keys = {}
    for k in pairs(by) do keys[#keys + 1] = k end
    table.sort(keys)

    local fh = assert(io.open(BASELINE, 'wb'))
    fh:write('# Bare truth tests on BOOL-shaped FiveM natives, per file and per\n')
    fh:write('# native. Written by tools/check_bool_natives.lua -- see the top of\n')
    fh:write('# that file for what a line means and why a number may only go\n')
    fh:write('# down. Regenerate with --write-baseline after a deliberate change.\n')
    fh:write('#\n')
    fh:write('# count\tfile\tnative\n')
    for _, k in ipairs(keys) do
        fh:write(('%d\t%s\n'):format(by[k], k))
    end
    fh:close()
end

-- ---------------------------------------------------------------------------

local args = { ... }
local write = false
local paths = {}
for _, a in ipairs(args) do
    if a == '--write-baseline' then write = true else paths[#paths + 1] = a end
end

if #paths == 0 then
    io.write('usage: lua tools/check_bool_natives.lua [--write-baseline] <file>...\n')
    os.exit(2)
end

-- The sources are read ONCE and the declared-name set is built across ALL of
-- them before anything is scanned: a helper declared in br_lib is still a
-- helper when br_core calls it, and a per-file pass would report every
-- cross-resource call to one.
local sources = {}
local declared = {}
for _, path in ipairs(paths) do
    local src = read(path)
    if src then
        sources[path] = src
        Rules.declared(src, declared)
    end
end

local now, lines, total = {}, {}, 0
for _, path in ipairs(paths) do
    if sources[path] then
        for _, hit in ipairs(Rules.scan(sources[path], declared)) do
            local key = path .. '\t' .. hit.native
            now[key] = (now[key] or 0) + 1
            lines[key] = lines[key] or {}
            table.insert(lines[key], hit)
            total = total + 1
        end
    end
end

if write then
    writeBaseline(now)
    local n = 0
    for _ in pairs(now) do n = n + 1 end
    io.write(('\27[32mwrote\27[0m %s -- %d bare read(s) in %d file/native pair(s)\n')
        :format(BASELINE, total, n))
    os.exit(0)
end

local base = readBaseline()
if not base then
    io.write(('\27[31mFAIL\27[0m %s is missing.\n'):format(BASELINE))
    io.write('     The gate cannot tell a new fault from an old one without it.\n')
    io.write('     Regenerate: lua tools/check_bool_natives.lua --write-baseline <file>...\n')
    os.exit(1)
end

local keys = {}
for k in pairs(now) do keys[#keys + 1] = k end
for k in pairs(base) do if not now[k] then keys[#keys + 1] = k end end
table.sort(keys)

local bad = 0
for _, key in ipairs(keys) do
    local path, native = key:match('^(.-)\t(.+)$')
    local n, was = now[key] or 0, base[key] or 0

    if n > was then
        bad = bad + 1
        if was == 0 then
            io.write(('\27[31mFAIL\27[0m %s reads %s as a truth value:\n')
                :format(path, native))
        else
            io.write(('\27[31mFAIL\27[0m %s reads %s raw %d time(s), was %d:\n')
                :format(path, native, n, was))
        end
        for _, h in ipairs(lines[key] or {}) do
            io.write(('     %d: %s\n'):format(h.line, h.text))
        end
        io.write('     0 IS TRUTHY IN LUA, and this native answers 0 for "no" --\n')
        io.write('     either as a BOOL that came back a number, or as a handle\n')
        io.write('     that came back empty. `if X() then` is TRUE for that 0 and\n')
        io.write('     `while not X() do` is FALSE for it: one proceeds when it\n')
        io.write('     should wait, the other stops waiting. Both are wrong.\n')
        io.write(('     Wrap it -- isTrue(%s(...)), see br_core/client/loot.lua --\n')
            :format(native))
        io.write('     or compare it (== 1, ~= 0, == true) at the test itself.\n')
    elseif n < was then
        bad = bad + 1
        io.write(('\27[31mFAIL\27[0m %s now reads %s raw %d time(s), the baseline says %d.\n')
            :format(path, native, n, was))
        if n == 0 then
            io.write('     Fixed, and the baseline still reserves room for it.\n')
            io.write(('     Delete this line from %s:\n'):format(BASELINE))
            io.write(('         %d\t%s\n'):format(was, key))
        else
            io.write('     Partly fixed. Lower the count in the same commit, or the\n')
            io.write('     space just made stays open for the next one to fill.\n')
            io.write(('     In %s, replace:\n'):format(BASELINE))
            io.write(('         %d\t%s\n'):format(was, key))
            io.write('     with:\n')
            io.write(('         %d\t%s\n'):format(n, key))
        end
    end
end

if bad > 0 then
    io.write(('\27[31m%d file/native pair(s) disagree with %s\27[0m\n')
        :format(bad, BASELINE))
    os.exit(1)
end

local npairs = 0
for _ in pairs(base) do npairs = npairs + 1 end
io.write(('\27[32mok\27[0m   %d known bare BOOL-native read(s) in %d pair(s), none new\n')
    :format(total, npairs))

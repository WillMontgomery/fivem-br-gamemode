-- Static gate: every cue key a call site NAMES is a key the cue table HOLDS.
--
-- ═══ THE REPORT THIS EXISTS FOR ═══
--
-- Owner, 2026-09-08:
--
--   "btw the 5s storm sound is broke somehow. when you find out how to fix
--    that, perhaps you could fix the other sounds that are broken"
--
-- The suites were green while he said it, and they were green about the exact
-- cues in question. That is the interesting part, and it is what this file is
-- for: not the two he named, but the CLASS of failure that let a broken cue sit
-- in a green tree.
--
-- ═══ WHY NO SUITE CAN SEE THIS ═══
--
-- Every test of a cue CALL SITE stubs BR.Sfx and records the string it was
-- handed. tools/test_shared.lua's storm sandbox does it in as many words --
-- `env.BR.Sfx = { play = function(cue) C.sfx[#C.sfx + 1] = cue end }` -- and
-- then asserts `played(C, 'timer.final') == 1`. That assertion is true for ANY
-- string the call site passes. It is equally true for `timer.finol`, for a key
-- somebody deleted from config/audio.lua an hour earlier, and for a browser cue
-- name typed into a native call site by somebody who did not know the two tiers
-- are different tables. The stub is right to exist -- the storm sandbox is
-- testing the storm, not the mixer -- but it means the ONE fact that decides
-- whether a player hears anything, "is this string a key in the table", is
-- asserted nowhere in the suite.
--
-- The other half is worse. BR.Sfx.play prints `unknown cue "<key>"` ONCE per key
-- per resource lifetime, so a dead call site is one line, far up an F8 scrollback
-- nobody was reading, and silence forever after.
--
-- ═══ WHAT THIS CAUGHT THE DAY IT WAS WRITTEN ═══
--
-- br_core/client/state.lua fired `hit` and `hit.crit` on every DAMAGE_FEED. Both
-- keys were deleted from config/audio.lua on 2026-09-08 ("do not wire in any
-- sound at all for hit or hit.crit -- those are wrong sound clips"), and
-- client/dbno.lua had its matching call removed the same day. This site was
-- missed, and nothing went red: two dead calls per match and two console lines
-- per session.
--
-- ═══ WHAT IT DELIBERATELY DOES NOT CHECK ═══
--
-- THE REVERSE DIRECTION IS NOT A FAILURE, AND IT IS NOT EVEN A LIST OF UNWIRED
-- CUES. A cue can be reached in at least three ways this scan cannot see: held
-- in a local (`local MOVE_CUE = 'storm.move'` in server/storm.lua), passed to a
-- helper (`sfxToOccupants(netId, matchId, 'fuel.start')`), or asked for BY THE
-- BROWSER -- ui-src/src/screens/EndScreen.tsx sends `volts.award` through the
-- SFX NUI callback, which br_ui/client/nui.lua turns into `br:ui:sfx` and
-- client/sfx.lua answers with BR.Sfx.play. All twenty-one cues are reachable
-- today; the tail of this readout is a reading aid, not a verdict. Wiring a
-- sound is the owner's decision and never a gate's, so nothing here fails on it.
--
-- A CUE KEY HELD IN A VARIABLE IS INVISIBLE HERE, and that is correct rather
-- than a gap. client/dbno.lua's MATE_CUE deliberately routes by whether the
-- table has the key -- native where there is a pair, the browser where there is
-- not -- so a phase with no pair is ABSENT ON PURPOSE and a gate that flagged it
-- would be wrong about the one case the design cares most about. Only a key
-- written as a literal AT the call site is a claim that the cue is native, so
-- only those are checked.
--
-- `squad.down` USED TO BE THE WORKED EXAMPLE OF THAT, AND IS NO LONGER. The
-- owner ruled on 2026-09-11 that the knock and the death play the same frontend
-- pair, so all three MATE_CUE phases have one now. The argument above is
-- unchanged and still the reason this scan stops at literals; what has gone is
-- the live instance of it.
--
-- Fed the file list on argv by tools/verify.sh, the way check_forward_locals,
-- check_bool_natives and check_notice_names are: Lua cannot walk a directory
-- without io.popen, which spawns cmd.exe on this box and would make a gate's
-- coverage depend on which shell ran it.

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- Lua source with its comments removed.
---
--- LOAD-BEARING HERE MORE THAN IN THE SIBLING GATES. Three files in this tree
--- quote a dead cue call IN PROSE while explaining why it is dead:
--- client/dbno.lua says "This was BR.Sfx.play('hit.crit')", client/sfx.lua's
--- header uses BR.Sfx.play('elim') as its worked example, and config/audio.lua
--- argues about both at length. A raw search would report every one of those
--- explanations as the bug it is explaining.
--- NEWLINES SURVIVE THE STRIP, WHICH IS WHY THE BLOCK ARM IS NOT A PLAIN gsub
--- TO A SPACE. This gate reports a FILE AND LINE, and that number is only worth
--- printing if it is the line somebody can open. Collapsing a twelve-line
--- `--[[ ]]` block to one space silently moves every call site under it up
--- eleven lines, which is worse than printing no number at all: it sends the
--- reader to a line that looks innocent.
local function codeOf(src)
    src = src:gsub('%-%-%[%[.-%]%]', function(block)
        return (block:gsub('[^\n]', ''))
    end)
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

local function readRaw(path)
    local fh = io.open(path, 'r')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ------------------------------------------------------------- the table ---
--
-- LOADED, NOT PARSED. config/audio.lua is a Lua file, and the truth about which
-- keys exist is what Lua says after running it rather than what a pattern finds
-- in it. The file needs no natives and nothing of BR beyond the two lines it
-- opens with, which is why this can simply run it.
local ROOT = 'resources/[fivem-royale]/'
BR = {}
local chunk, err = loadfile(ROOT .. 'br_lib/config/audio.lua')
if not chunk then
    io.write('FAIL  cannot load config/audio.lua: ', tostring(err), '\n')
    os.exit(1)
end
chunk()
local CUES = BR.Config.Audio.cues

-- ------------------------------------------------------------ the shapes ---
--
-- Three ways a cue key is named as a literal, and all three are how a real cue
-- reaches a real player today:
--
--   BR.Sfx.play('x') / playFrom     the client playing its own cue. `%b()` takes
--                                   the balanced argument list, so the
--                                   `cond and 'a' or 'b'` form -- which is what
--                                   the hit/hit.crit site was, and what
--                                   storm.lua's wall crossing still is -- gives
--                                   up BOTH keys rather than neither.
--   BR.Net.SFX_CUE ... { c = 'x' }  the SERVER addressing an audience. The
--                                   client resolves it against its own table, so
--                                   a key the server invents is silent on every
--                                   machine in the match at once.
--   cue = 'x'                       a notice choosing its own sound.
--                                   br_ui/client/nui.lua hands this to
--                                   BR.Sfx.play, so it is a cue key with extra
--                                   steps. `cue = false` is a deliberate silence
--                                   and matches nothing here, which is right.
local sites, scanned = 0, 0
local named = {}

local function note(key, where)
    named[key] = named[key] or {}
    named[key][#named[key] + 1] = where
    sites = sites + 1
end

--- Which line of `code` an offset falls on, so a failure names a place.
local function lineAt(code, pos)
    local n = 1
    for _ in code:sub(1, pos):gmatch('\n') do n = n + 1 end
    return n
end

for _, path in ipairs({ ... }) do
    local src = readRaw(path)
    if src then
        scanned = scanned + 1
        local code = codeOf(src)

        for _, pat in ipairs({ 'BR%.Sfx%.play%b()', 'BR%.Sfx%.playFrom%b()' }) do
            local at = 1
            while true do
                local a, b = code:find(pat, at)
                if not a then break end
                local where = ('%s:%d'):format(path, lineAt(code, a))
                for k in code:sub(a, b):gmatch("'([%w%._]+)'") do
                    note(k, where)
                end
                at = b + 1
            end
        end

        local n = 0
        for line in code:gmatch('([^\n]*)\n?') do
            n = n + 1
            if line:find('SFX_CUE', 1, true) then
                for k in line:gmatch("c%s*=%s*'([%w%._]+)'") do
                    note(k, ('%s:%d'):format(path, n))
                end
            end
            for k in line:gmatch("cue%s*=%s*'([%w%._]+)'") do
                note(k, ('%s:%d'):format(path, n))
            end
        end
    end
end

-- AN EMPTY RUN IS A FAILURE, NOT A PASS. A gate fed no files, or fed a tree
-- whose call sites have all been renamed out from under these patterns, reports
-- success while checking nothing -- which is the failure every gate in this
-- directory is one shell edit away from.
if scanned == 0 then
    fail('no files were scanned',
         'verify.sh feeds the list on argv; an empty one means the find changed')
end
if sites == 0 then
    fail(('no cue call sites were found in %d file(s)'):format(scanned),
         'the call sites cannot all have gone. The patterns in this gate have '
         .. 'stopped matching the code, and it is now checking nothing')
end

local keys = {}
for k in pairs(named) do keys[#keys + 1] = k end
table.sort(keys)

for _, k in ipairs(keys) do
    if not CUES[k] then
        fail(('cue "%s" is played but is not in the table'):format(k),
             ('named at %s -- BR.Sfx.play takes the unknown-cue path for it, '
              .. 'which is ONE console line per session and silence for the rest '
              .. 'of it. Either add the pair to br_lib/config/audio.lua or delete '
              .. 'the call; a key that resolves to nothing is not a quiet sound, '
              .. 'it is a dead call site.'):format(table.concat(named[k], ' ')))
    end
end

-- The reverse, as information. See the header: wiring a sound is a decision.
local unwired = {}
for cue in pairs(CUES) do
    if not named[cue] then unwired[#unwired + 1] = cue end
end
table.sort(unwired)

if failures > 0 then
    io.write(('\ncheck_cue_sites: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write(('ok   every cue key named at a call site is in the table -- %d literal\n'
    .. '     site(s) across %d file(s), %d cue(s) reachable\n')
    :format(sites, scanned, #keys))
if #unwired > 0 then
    io.write(('     (%d reached some other way -- a local, a helper, or the\n'
        .. '     browser asking through the SFX callback -- so this is a reading\n'
        .. '     aid and not a list of unwired cues: %s)\n')
        :format(#unwired, table.concat(unwired, ', ')))
end

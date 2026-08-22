-- Static gate: the death moment and the match-end verdict are two surfaces.
--
-- ═══ THE RULE ═══
--
-- "Upon dying, the verdict text ONLY should be shown for ~10 seconds then the
-- text can immediately disappear as we snap into spectating. Our typical
-- verdict screen should remain once the match is over." -- the owner.
--
-- Two moments. The death is the WORD, alone, over a world that is still
-- running. The match end is the SCREEN -- backdrop, placement, Volts -- and it
-- is unchanged.
--
-- ═══ WHAT WAS ACTUALLY THERE BEFORE, because it was not what was expected ═══
--
-- Nothing was drawn on death at all. BR.Nui.SUMMARY is sent only on
-- MatchState.ENDED and the verdict screen is gated on the match tearing down,
-- so a player who died mid-match got no word and no pause -- client/spectate.lua
-- put them behind a squadmate inside a second. The two moments were not sharing
-- a surface; there was only one, and it was the wrong one for a death.
--
-- ═══ WHAT THIS GATE IS FOR ═══
--
-- The word and the camera are ONE SEQUENCE driven by ONE deadline. The failure
-- that would not look like a failure is the two coming apart: a second timer
-- somewhere that agrees with the first only by coincidence, leaving either dead
-- air after the word or a camera that cuts away mid-sentence. So what is pinned
-- is that there is exactly one clock and that both halves read it.
--
-- Run standalone:  lua tools/check_death_verdict.lua

local ROOT = 'resources/[fivem-royale]/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

local function codeOfLua(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

local function codeOfTs(src)
    src = src:gsub('/%*.-%*/', ' ')
    src = src:gsub('//[^\n]*', '')
    return src
end

local function read(path, strip)
    local fh = io.open(path, 'r')
    if not fh then
        fail(path .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return strip and strip(s) or s
end

-- ------------------------------------------------------------- the clock ---

local state = read(ROOT .. 'br_core/client/state.lua', codeOfLua)
if state then
    -- ONE DEADLINE, OWNED HERE. Both halves read it: the word comes down when
    -- it passes, and client/spectate.lua holds its first request until then.
    if not state:find('deathVerdictUntil') then
        fail('client/state.lua has no death-verdict deadline')
    end
    if not state:find('function BR%.DeathVerdictUp') then
        fail('client/state.lua does not expose BR.DeathVerdictUp',
             'client/spectate.lua reads it behind a nil-guard, so a rename '
             .. 'here fails OPEN -- the camera snaps away instantly again and '
             .. 'nothing says so')
    end

    -- THE DURATION IS THE CONFIG VALUE, NOT A LITERAL. A hardcoded 10000 here
    -- would make BR.Config.Spectate.deathVerdictMs a decoration -- and this
    -- project's standing failure is exactly that: a value with no reader.
    if not state:find('BR%.Config%.Spectate.-deathVerdictMs') then
        fail('the death-verdict window is not read from BR.Config.Spectate',
             'a hardcoded duration makes the config key a value nobody reads')
    end

    -- IT IS PUSHED ON THE DEATH EDGE, AND THE CALL IS PINNED TO THAT EDGE.
    --
    -- `BR.NoteDeath()` appearing in the file is NOT the claim: the pattern is
    -- satisfied by the function's own `function BR.NoteDeath()` header, so
    -- deleting the only call to it left this passing while nothing ever put the
    -- word on screen. That mutation escaped this gate's first draft, and it is
    -- the same shape as every other bug in this repository -- a correct
    -- function nobody invokes.
    --
    -- So it is matched next to `diedThisMatch = true`, which is the one line
    -- that IS the death transition.
    if not state:find('diedThisMatch = true%s+BR%.NoteDeath%(%)') then
        fail('nothing starts the death verdict on the DEAD transition',
             'BR.NoteDeath() must be called on the same edge that sets '
             .. 'diedThisMatch, or the word never appears')
    end

    -- AND IT COMES DOWN WHEN THE MATCH ENDS. Dying in the closing seconds of a
    -- round is ordinary; without this the word sits over the world at the same
    -- moment the verdict SCREEN comes up behind it -- two verdicts at once,
    -- which is precisely the pair being kept distinct.
    if not state:find('MatchState%.ENDED or d%.state == BR%.MatchState%.CLEANUP') then
        fail('the death word is not cleared when the match ends',
             'a death in the last ten seconds would draw it over the verdict '
             .. 'screen')
    end
end

-- ------------------------------------------------------- the camera holds ---

local spec = read(ROOT .. 'br_core/client/spectate.lua', codeOfLua)
if spec then
    -- THE HOLD READS THE SAME CLOCK. Not its own timer, not a copy of the
    -- duration -- the predicate state.lua owns.
    if not spec:find('BR%.DeathVerdictUp and BR%.DeathVerdictUp%(%)') then
        fail('the spectate camera does not wait for the death verdict',
             'the owner asked for the word first and the camera after; without '
             .. 'this the SLOW loop opens a session within a second of dying')
    end
    if spec:find('deathVerdictMs') then
        fail('client/spectate.lua carries its own copy of the window length',
             'two clocks of the same length agree only by coincidence -- one '
             .. 'deadline, read by both halves')
    end

    -- THE WAIT DOES NOT SPEND A RETRY. `asks` is the budget for requests the
    -- server may have dropped; charging a player two of their three attempts
    -- for waiting out their own death would leave them with one.
    local openAt = spec:find("BR%.Loop%.register%(BR%.Loop%.SLOW, 'spectate%.open'")
    if openAt then
        local body = spec:sub(openAt)
        local holdAt = body:find('BR%.DeathVerdictUp')
        local bumpAt = body:find('asks = asks %+ 1')
        if holdAt and bumpAt and holdAt > bumpAt then
            fail('the death-verdict hold is checked AFTER the retry counter',
                 'waiting out your own death would burn the retry budget')
        end
    end
end

-- ------------------------------------------------------------- one word table ---

local dv = read('ui-src/src/hud/DeathVerdict.tsx', codeOfTs)
local es = read('ui-src/src/screens/EndScreen.tsx', codeOfTs)
local vw = read('ui-src/src/hud/verdictWord.ts', codeOfTs)

if vw and not vw:find('ELIMINATED', 1, true) then
    fail('hud/verdictWord.ts does not hold the word table')
end

-- BOTH SURFACES READ THE ONE TABLE. A player told BLED OUT when they die and
-- ELIMINATED when the match ends has been given two accounts of one death, and
-- a second copy of that switch is how that happens.
for name, code in pairs({ ['DeathVerdict.tsx'] = dv, ['EndScreen.tsx'] = es }) do
    if code and not code:find('verdictWord') then
        fail(name .. ' does not read the shared verdict word table')
    end
    -- The giveaway for a re-implementation: the switch arms, copied back in.
    if code and code:find("case 'bledout'", 1, true) then
        fail(name .. ' has its own copy of the verdict word table',
             'one table, two readers -- see hud/verdictWord.ts')
    end
end

if dv then
    -- THE TEXT ONLY. The verdict SCREEN's furniture must not follow it over
    -- here: no backdrop, and above all no cover report -- that one tells Lua
    -- the screen is solid black so the world can be torn down behind it, which
    -- would be a catastrophic thing to send in the middle of a live match.
    if dv:find('useCoverReport') then
        fail('the death verdict reports screen cover',
             'that signal tells Lua it may tear the world down; the match is '
             .. 'still running')
    end
    if dv:find('end%-backdrop') then
        fail('the death verdict draws the verdict screen\'s backdrop',
             'the owner asked for the TEXT only')
    end
    -- NO CLOCK OF ITS OWN.
    if dv:find('setTimeout') or dv:find('setInterval') then
        fail('the death verdict runs its own timer',
             'Lua owns the window and the same deadline releases the camera')
    end
end

if failures > 0 then
    io.write(('\ncheck_death_verdict: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   the death word and the verdict screen are two surfaces on one '
    .. 'word table,\n     and one deadline drives both the word and the '
    .. 'spectate camera\n')

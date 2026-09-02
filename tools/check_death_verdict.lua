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

    -- ═══ #204: IT IS A MATCH-SCOPED SURFACE, NOT A LIST OF TRANSITIONS ═══
    --
    -- This gate used to pin the LIST -- "cleared on ENDED or CLEANUP" -- and the
    -- list is what was wrong. It named the four transitions a round normally
    -- passes through and could not name the one it was missing, so the word
    -- walked out of every exit that was not "the match ended underneath you":
    -- the owner went down, left, and read ELIMINATED across the lobby.
    --
    -- What is pinned now is the RULE. The word registers as a surface belonging
    -- to a match in progress, and the edges that mean "the match is over for
    -- this player" reach it through that registration. tools/test_matchexit.lua
    -- drives each of those edges with the real message shapes; these four are
    -- the wiring a grep can see, and each of them is a silent failure if it is
    -- deleted -- no error, no log, just a word that stays.
    if not state:find('BR%.MatchSurface%([^\n]*clearDeathVerdict') then
        fail('the death word is not registered as a match-scoped surface',
             'without the registration it is cleared by whichever transitions '
             .. 'somebody remembered, which is how #204 happened')
    end
    if not state:find('d%.state ~= BR%.MatchState%.PLAYING') then
        fail('the match-state teardown is a list again, not "anything but a '
             .. 'live match"',
             'the list that shipped was missing WAITING -- the state a LEAVER '
             .. "'s own mirror settles into -- which was the reported bug")
    end
    if not state:find('BR%.NotifyClear%(%)%s+dismissMatchSurfaces%(%)') then
        fail('nothing dismisses match surfaces on the LOBBY edge',
             'that edge is the one transition EVERY exit from a match passes '
             .. 'through; it is where the sticky-notice broom already lives')
    end
    if not state:find('dismissMatchSurfaces%(true%)') then
        fail('br_core starting does not force a dismissal',
             'br_ui does not restart with us, so the page can be holding '
             .. 'show=true with the deadline that would retire it gone -- a '
             .. 'word that never comes down at all')
    end

    -- AND THE FORCED PATH ACTUALLY DOES SOMETHING. A `force` argument that the
    -- dismissal ignores is the same no-op wearing a different name, and the
    -- case it covers is invisible from a chair until somebody restarts br_core.
    if not state:find('deathVerdictUntil == 0 and force ~= true') then
        fail('clearDeathVerdict does not honour the forced dismissal',
             'a fresh Lua state has deathVerdictUntil = 0, so without this the '
             .. 'one call that could correct a stale page does nothing')
    end

    -- AND SO DOES STARTING TO SPECTATE, which is the edge that was missing.
    --
    -- "The verdict text still shows while spectating for some reason." -- the
    -- owner, 2026-08-22. Every other edge above is a way OUT of a match, and
    -- starting to spectate is not one -- which is exactly why the rule as
    -- written did not reach it. client/spectate.lua's own hold is not enough on
    -- its own: `ask()` admits DEAD, so the arrow keys open a session inside the
    -- window and the automatic snap is not the only way in.
    --
    -- MATCHED ON THE HANDLER, so a file that kept a comment about spectating and
    -- dropped the wiring fails. The `admin` guard is pinned with it, because
    -- without it a MODERATOR who is alive and mid-fight tears down every surface
    -- their own live match raised the moment they open a camera -- a worse bug
    -- than the one being fixed, and one nobody would connect to this change.
    local specAt = state:find('BR%.Net%.SPECTATE_SET, function')
    if not specAt then
        fail('client/state.lua does not watch for a spectate session starting',
             'the death word has no edge to come down on while the player '
             .. 'watches somebody else, which is the 2026-08-22 report')
    else
        local body = state:sub(specAt, specAt + 600)
        if not body:find('dismissMatchSurfaces%(%)') then
            fail('a spectate session starting dismisses nothing',
                 'the handler is there but the word is not taken down')
        end
        if not body:find('d%.admin == true') then
            fail('the spectate edge does not exempt an ADMIN session',
                 'an admin spectator may be ALIVE and mid-match; treating '
                 .. 'their camera as "the match is over for me" tears down '
                 .. 'surfaces underneath a living player')
        end
    end

    -- AND A REVIVE TAKES IT WITH IT. #144's held death puts the roster through
    -- DEAD for real, so the word goes up for somebody who is about to be stood
    -- back up -- and the revive lands on the transition into PLAYING, which is
    -- the one match state a match-scoped surface survives.
    local revivedAt = state:find('BR%.Net%.REVIVED, function')
    if revivedAt and not state:sub(revivedAt, revivedAt + 400)
                              :find('dismissMatchSurfaces') then
        fail('a revive does not take the death word down',
             'the player is alive and fighting with ELIMINATED across the '
             .. 'screen for the rest of the window')
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

-- ------------------------------------------- exactly one verdict on screen ---
--
-- "When one player is in the ambulance and the only other remaining player(s)
-- die, the verdict shown is 'VICTORY ROYALE' along with ALSO the cause of DBNO
-- on top of it." -- the owner, 2026-08-29.
--
-- ═══ WHY THE DISMISSAL RULE ABOVE DID NOT COVER THIS ═══
--
-- Every edge in this file's first half is a dismissal: something happens, and
-- the word comes down. That is complete for a word that is ALREADY UP when the
-- match ends -- dying in the closing seconds, which is ordinary and which the
-- DIGEST handler's `d.state ~= PLAYING` sweep handles.
--
-- It says nothing about a death that arrives AFTER the sweep has run, and one
-- did: a player riding the ambulance is DBNO, DBNO counts as in the match, so
-- they were the last team standing and won -- and then server/combat.lua's
-- bleed clock, un-suspended when server/rescue.lua dropped the ride, finished
-- them a quarter of a second into the teardown. BR.NoteDeath put the word back
-- up over the verdict screen and nothing was left to take it down.
--
-- So there are two things to pin, and they are different in kind:
--
--   THE CAUSE, in server/combat.lua -- a bleed clock belongs to a live match.
--     Driven for real in tools/test_roster.lua ('dbno.matchEndsUnderARide'),
--     which fails on both counts with the gate removed. Pinned here as well
--     because it is one predicate and deleting it is silent.
--   THE RULE, in App.tsx -- once the match is decided, the verdict screen owns
--     the screen. Nothing else the round raised may draw over it, whatever
--     order the messages arrive in. That is what makes this robust against the
--     NEXT thing that finds a way to raise a surface late.

local combat = read(ROOT .. 'br_core/server/combat.lua', codeOfLua)
if combat then
    local tickAt = combat:find("BR%.Sched%.every%(250, 'combat%.dbno'")
    if not tickAt then
        fail('server/combat.lua has no DBNO tick to gate',
             'the 250ms bleed job is where a downed player is finished')
    else
        local body = combat:sub(tickAt, tickAt + 700)
        if not body:find('BR%.MatchState%.PLAYING') then
            fail('the bleed clock is not scoped to a live match',
                 'a match that has ENDED has already awarded placements and '
                 .. 'published results; an elimination after that point can '
                 .. 'only contradict something already written down -- and it '
                 .. 'raises a second verdict over the first')
        end
        -- BUS STAYS LIVE, and this is not decoration: #144's held death runs
        -- through this tick, so a player who bleeds out before PLAYING must
        -- still reach holdForStart or they are never revived into the round.
        if not body:find('BR%.MatchState%.BUS') then
            fail('the bleed clock excludes BUS',
                 "a death before the match starts is HELD, not published -- "
                 .. 'gating BUS out means it never happens and the player is '
                 .. 'left downed until the sweep')
        end
    end
end

local app = read('ui-src/src/App.tsx', codeOfTs)
if app then
    -- ONE MOUNT, AND IT IS GATED. Matched on the gate rather than on a comment:
    -- App.tsx's prose has always SAID the two never coincide, and saying it is
    -- exactly what turned out not to be true.
    local _, mounts = app:gsub('<DeathVerdict', '')
    if mounts ~= 1 then
        fail(('App.tsx mounts the death word %d times'):format(mounts),
             'one surface, one mount -- two would need two gates to agree')
    end
    if not app:find('!tearingDown && <DeathVerdict') then
        fail('the death word is not gated on the match being decided',
             'a death that lands AFTER the ENDED sweep -- the ambulance '
             .. 'winner -- puts the word back up over the verdict screen with '
             .. 'nothing left to dismiss it')
    end

    -- ...AND THE RIDE'S OWN CLOCK IS UNDER THE SAME RULE. It is the other
    -- surface that can be up at the moment a match is decided, and it does not
    -- end by a message: client/rescue.lua's sanity sweep nils the ride at 1 Hz
    -- when the match stops being PLAYING, while the verdict screen mounts 500ms
    -- in. Without this it is a placard under VICTORY ROYALE for the second in
    -- between -- and it is a placard now (owner: "the same card as the bleed
    -- out card"), not the bare numeral it used to be.
    if not app:find('show={ridingAmbulance && !tearingDown}', 1, true) then
        fail('the ambulance clock is not gated on the match being decided',
             'the ride ends by a 1Hz client sweep, the verdict screen by a '
             .. 'message -- the placard outlives the round it belongs to')
    end
end

if failures > 0 then
    io.write(('\ncheck_death_verdict: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   the death word and the verdict screen are two surfaces on one '
    .. 'word table,\n     one deadline drives both the word and the spectate '
    .. 'camera, and nothing\n     the round raised draws once the match is '
    .. 'decided\n')

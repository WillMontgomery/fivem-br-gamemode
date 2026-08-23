-- Interface audio.
--
-- One entry point, one table, one rate limiter. Everything that wants a sound
-- calls BR.Sfx.play('elim') and nothing else knows a sound-set name -- which is
-- what stops a wrong name being pasted into six files and fixed in five.
--
-- WHY THIS IS THIN ON PURPOSE. PlaySoundFrontend does the work; the value here
-- is the table, the throttle and the audition command. There is no mixing, no
-- queueing and no state, because a cue that needs any of those has stopped
-- being a cue and should be a music track.
--
-- FAILURE IS SILENT, WHICH IS WHY /brsfx EXISTS. A wrong sound-set name does
-- not error and does not warn: PlaySoundFrontend simply plays nothing, exactly
-- the way a misspelled native returns nil. Audition names with /brsfx and fill
-- the config from what actually plays, never from a wiki.

BR = BR or {}
BR.Sfx = {}

local lastPlayed = {}   -- cue -> GetGameTimer() of the last play
local muted = false

--- Play an interface cue.
---
--- Safe to call from anywhere, including per-frame paths: unknown cues are
--- ignored and rate-limited cues are dropped rather than queued. Dropping is
--- deliberate -- a queued hitmarker arrives after the moment it describes.
---
--- @param cue string   a key in BR.Config.Audio.cues
function BR.Sfx.play(cue)
    if muted or not BR.Config.Audio.enabled then return end

    local def = BR.Config.Audio.cues[cue]
    if not def then
        -- Once per cue, not once per call: a typo inside a frame loop would
        -- otherwise bury the console it is trying to warn in.
        if lastPlayed['?' .. cue] == nil then
            lastPlayed['?' .. cue] = 1
            print(('[br_core] sfx: unknown cue "%s"'):format(tostring(cue)))
        end
        return
    end

    local gap = BR.Config.Audio.minInterval[cue]
    if gap then
        local now = GetGameTimer()
        if (now - (lastPlayed[cue] or -math.huge)) < gap then return end
        lastPlayed[cue] = now
    end

    -- -1 = no specific sound id, we never need to stop these.
    -- false = not a network sound; every cue here is for THIS client only.
    PlaySoundFrontend(-1, def.name, def.set, false)
end

--- Play a cue POSITIONED ON A WORLD ENTITY instead of in the player's head.
---
--- ═══ SAME TABLE, SAME THROTTLE, DIFFERENT NATIVE -- AND THE NATIVE IS STILL
---     LOCAL ═══
---
--- PLAY_SOUND_FROM_ENTITY IS A CLIENT NATIVE AND IT IS NOT NETWORKED. This was
--- checked rather than assumed, because the whole reason this function exists is
--- a requirement about OTHER PLAYERS hearing something:
---
---   "All occupants of a vehicle should hear these sounds."  -- owner, 2026-08-22
---
--- The native's signature is
--- `PLAY_SOUND_FROM_ENTITY(int soundId, char* audioName, Entity entity,
---  char* audioRef, BOOL isNetwork, Any p5)` and its `isNetwork` parameter is
--- UNDOCUMENTED in citizenfx/natives -- every parameter description in that file
--- is empty. What is established is that the call plays on the machine that
--- makes it and nowhere else; the community answer to "how do other players hear
--- this" is uniformly "trigger a client event to the players who should", and the
--- 3D-audio resources that exist for FiveM exist precisely because there is no
--- one-call networked version of this.
---
--- SO THE FAN-OUT IS OURS AND IT IS THE SERVER'S. br_core/server/fuel.lua works
--- out who is in the vehicle -- it already has to, for the ledger -- and sends
--- each of them BR.Net.FUEL_SFX; each client lands here and plays its own copy
--- from its own handle for the same car. `isNetwork` is passed FALSE for exactly
--- that reason: we have already addressed everyone who should hear it, and a
--- native that turned out to network after all would double the sound.
---
--- NOTHING HERE CREATES AN ENTITY. Worth saying because `sv_entityLockdown` is
--- `relaxed` on this server, so a client that tried to spawn a sound-emitter
--- prop would be refused -- this plays from a car that GTA's own traffic
--- network already created, and adds nothing to the world.
---
--- WHY NOT PlaySoundFrontend FOR THE OCCUPANTS. It would be one native shorter
--- and it would work, because an occupant is by definition a metre from the car.
--- Anchoring on the entity is still right: the engine positions and attenuates
--- it, so it ducks and pans like a thing happening to the vehicle rather than a
--- menu click, and widening the audience past the occupants later becomes a
--- change to one list on the server rather than a change of native here.
---
--- @param cue string        a key in BR.Config.Audio.cues
--- @param entity integer    the entity to play it from
function BR.Sfx.playFrom(cue, entity)
    if muted or not BR.Config.Audio.enabled then return end
    -- ZERO IS TESTED EXPLICITLY, because `0` is truthy in Lua and it is what
    -- every entity-returning native answers for "there isn't one". Playing from
    -- entity 0 is silent, which is indistinguishable from a wrong sound name.
    if not entity or entity == 0 then return end

    local def = BR.Config.Audio.cues[cue]
    if not def then
        -- Once per cue, exactly as BR.Sfx.play does and for the same reason.
        if lastPlayed['?' .. cue] == nil then
            lastPlayed['?' .. cue] = 1
            print(('[br_core] sfx: unknown cue "%s"'):format(tostring(cue)))
        end
        return
    end

    local gap = BR.Config.Audio.minInterval[cue]
    if gap then
        local now = GetGameTimer()
        if (now - (lastPlayed[cue] or -math.huge)) < gap then return end
        lastPlayed[cue] = now
    end

    -- -1 = no specific sound id, we never need to stop these.
    -- false = not a network sound; the server has already told everyone who
    --         should hear it, and each of them is playing their own copy.
    PlaySoundFromEntity(-1, def.name, entity, def.set, false, 0)
end

--- Silence every cue. Client-side only.
--- @param on boolean
function BR.Sfx.setMuted(on)
    muted = on and true or false
end

-- ------------------------------------------------------------- the UI ------
--
-- Menu cues come from React, because React is what knows a button was pressed.
-- Routed through here rather than played in the browser so there is ONE cue
-- table and one throttle, and so the UI never learns a sound-set name.
AddEventHandler('br:ui:sfx', function(cue)
    BR.Sfx.play(cue)
end)

-- ------------------------------------------------- a cue for a whole match --
--
-- The server addressing everybody at once: the storm starting to move is the
-- first of these. SAME TABLE, SAME THROTTLE, SAME NATIVE as any local cue --
-- what the message changes is WHO plays, not WHAT plays.
--
-- THE PAYLOAD IS A CUE KEY AND IS TREATED AS UNTRUSTED ANYWAY. BR.Sfx.play
-- looks it up in BR.Config.Audio.cues and ignores anything it does not
-- recognise, so the worst a malformed message can do is one console line. The
-- wire cannot name a GTA sound set: the set of sounds this handler can produce
-- is exactly this client's own cue table.
RegisterNetEvent(BR.Net.SFX_CUE)
AddEventHandler(BR.Net.SFX_CUE, function(d)
    if type(d) ~= 'table' or type(d.c) ~= 'string' then return end
    BR.Sfx.play(d.c)
end)

-- ============================================================================
-- AUDITIONING: /brsfx
-- ============================================================================
--
--   "The sound we're using for fueling still isn't it. Can you make me
--    something which plays GTA sounds with a console command so I can pick
--    which one sounds good?"                -- owner, 2026-08-22
--
-- ═══ WHY THIS GREW, AFTER TWO REJECTED PICKS ═══
--
-- /brsfx could already play a named cue and a raw set/name pair, and that was
-- never the missing half. Both rejected fuel sounds were chosen by somebody
-- READING a table -- CHALLENGE_UNLOCKED ("more like a warning"), then
-- PROPERTY_PURCHASE -- and a command that plays a name you already decided on
-- cannot help with that. What was missing is DISCOVERY: you cannot pick a
-- sound you cannot find, and you cannot judge one you cannot hear next to its
-- neighbours. So this file now answers four questions instead of one:
--
--   what is there            `sets`, `sounds` and `find`, over the catalogue
--   what does it sound like  `play`, and `audition` for a whole set in a row
--   did it play at all       the probe below -- the one that cost two rounds
--   is it any good in situ   `bind`, which re-points a cue for this session
--
-- ═══ AND WHY IT GREW `sounds` A DAY LATER ═══
--
--   "Guess I'm not sure how to use brsfx - what I expect is a way to list all
--    sets, then type a command containing a specific set name to view all sfx
--    in the set, then play a specific sfx within that set with another
--    command. It seems I have no way to list all sfx within a given set."
--                                                     -- owner, 2026-08-23
--
-- HE WAS RIGHT, AND THE GAP WAS EXACTLY WHERE HE SAID. Seven verbs and not one
-- of them would simply SHOW you a set: `find` demands a search substring, so
-- you had to already suspect what you were looking for, and `audition` PLAYS a
-- set rather than listing it -- seventeen sounds and twelve seconds before you
-- know what is in it. Both are answers to "which sound", asked by somebody who
-- already knows roughly what they want. Neither answers "what is in here".
--
-- SO THE BROWSE PATH IS THREE PLAIN STEPS AND EACH ONE NAMES THE NEXT, which is
-- what makes it findable without reading this comment or the help:
--
--   1. brsfx sets            2. brsfx sounds <SET>    3. brsfx play <SET> <NAME>
--
-- The other verbs are still here and still shortcuts for somebody who knows the
-- name they are hunting. They are listed BELOW the three steps in `usage()` for
-- the same reason the steps are numbered: the owner has said he is not great
-- with software, and a flat list of eight equals is a list you read as none.
--
-- ═══ THE PROBE, AND WHY IT IS PHRASED AS A SUSPICION ═══
--
-- A WRONG SOUND SET IS SILENT. It does not error and does not warn, exactly
-- like a misspelled native returning nil -- so "I did not like it" and "it
-- never played" arrive looking identical, and that ambiguity is what has
-- actually been costing the rounds. The engine will answer the question if it
-- is asked properly: play through a real sound id from GET_SOUND_ID rather
-- than the fire-and-forget -1, and HAS_SOUND_FINISHED then reports on that
-- specific playback.
--
-- WHAT IT CAN AND CANNOT PROVE. A pair that never started reads as finished
-- immediately, which is the signal worth having. But a genuinely SHORT cue
-- could also start and finish inside the probe window, so `[silent?]` is
-- printed with the question mark and means "the engine said this was over
-- before it could have been audible" -- strong evidence, not a verdict.
-- HAS_SOUND_FINISHED's behaviour for a sound that never began is NOT
-- documented in citizenfx/natives (every parameter description in that file is
-- empty), so this was built to report what the engine says rather than to
-- assert what it means.
--
-- AND THE ANSWER GOES THROUGH `yes()`. HAS_SOUND_FINISHED is declared BOOL and
-- a FiveM BOOL native does not have to hand Lua a boolean -- this codebase has
-- shipped that bug six times. `0` IS TRUTHY IN LUA, so a bare `if fin then`
-- would read every released sound as still playing and the probe would report
-- every pair as fine, which is the one failure that would make this whole
-- section worse than not having it.
--
--   /brsfx                                   what this does
--   /brsfx sets [substr]                  1. list the catalogue's sound sets
--   /brsfx sounds <SET> [page]            2. list every sound in ONE set
--   /brsfx play <SET> <NAME>              3. play one pair, catalogue or not
--   /brsfx HUD_AWARDS COLLECTED              step 3 without the word `play`
--   /brsfx cues                              play every configured cue in order
--   /brsfx fuel.done                         play one configured cue
--   /brsfx find <substr> [setSubstr]         search names, optionally in one set
--   /brsfx audition <SET> [substr]           play a whole set, one after another
--   /brsfx bind <cue> <SET> <NAME>           re-point a cue for THIS SESSION
--   /brsfx stop                              cut a running audition short

--- A FiveM BOOL native may answer 1 rather than true. Sixth time in this tree.
local function yes(v) return v == 1 or v == true end

local GAP_MS      = 700   -- between two sounds in a sequence
local PROBE_MS    = 140   -- how long the probe watches before giving up on it
-- ROWS PRINTED BEFORE A LIST SAYS "AND N MORE". Also the page size for
-- `sounds`, so the two lists that can run long are cut at the same place.
--
-- NO SET IN TODAY'S CATALOGUE REACHES IT -- the biggest is
-- HUD_FRONTEND_DEFAULT_SOUNDSET at 27 -- so `sounds` fits every real set on
-- page one and the paging arm is unreachable as things stand. It is written and
-- tested anyway because the catalogue is a list somebody ADDS to (the comment
-- above it says so out loud: heard a pair, put it in), and the failure mode
-- when it is one day exceeded is a console that silently drops the tail. The
-- test drives it through an injected oversized set rather than waiting for
-- that day.
local LIST_CAP    = 60

-- One audition at a time. Two threads walking two sets interleave their sounds
-- and their printing, which produces a list nobody can map back to what they
-- heard -- the exact failure this command exists to remove.
local auditioning = false
local cancelAudition = false

--- Play one pair, watch whether the engine ever started it, and clean up.
---
--- WAITS, so it must be called from inside a Citizen thread. It holds the sound
--- id for the whole gap rather than releasing it the moment the probe is done:
--- releasing only tells the engine it may RECYCLE the id, but the cheap way to
--- be sure a recycle can never clip a sound short is not to ask for one until
--- the sound has had its time.
---
--- @param set string
--- @param name string
--- @param gapMs integer|nil   total time to hold before returning (default GAP_MS)
--- @return string             'ok' | 'silent' | 'unknown'
local function playProbed(set, name, gapMs)
    gapMs = gapMs or GAP_MS

    -- No id, no probe. A build where GET_SOUND_ID does not bind still gets the
    -- sound -- it just does not get the verdict, and says 'unknown' rather than
    -- inventing one.
    local gotId, id = pcall(GetSoundId)
    if not gotId or type(id) ~= 'number' or id < 0 then
        PlaySoundFrontend(-1, name, set, false)
        Citizen.Wait(gapMs)
        return 'unknown'
    end

    PlaySoundFrontend(id, name, set, false)

    -- POLLED ACROSS FRAMES RATHER THAN READ ONCE. A sound does not necessarily
    -- register as playing on the same frame it was asked for, so a single read
    -- would call a working pair silent whenever it lost that race. Any single
    -- frame that reports NOT finished settles it in the good direction.
    --
    -- THE WINDOW IS MEASURED ON THE CLOCK, NOT COUNTED IN FRAMES. Counting
    -- `Citizen.Wait(0)` iterations and calling each one 16ms is an assumption
    -- about the frame rate, and it is wrong in exactly the situation where this
    -- matters most: on a machine dropping frames the probe would run three
    -- times as long as intended and every short cue would come back `ok`,
    -- turning the detector off precisely when the game is misbehaving.
    local started = GetGameTimer()
    -- 'unknown' IS THE HONEST DEFAULT AND IS ALSO UNREACHABLE, AND MUTATION
    -- TESTING SAYS SO OUT LOUD: a mutant that seeds this with 'ok' survives,
    -- because `repeat` always runs its body once and every path through that
    -- body assigns. It is written as the safe answer anyway -- the day this
    -- becomes a `while` with a condition that can be false on entry, the
    -- difference is between reporting "I could not tell" and asserting "it
    -- played", and only one of those is true.
    local verdict = 'unknown'
    repeat
        Citizen.Wait(0)
        local asked, fin = pcall(HasSoundFinished, id)
        if not asked then verdict = 'unknown'; break end
        if not yes(fin) then verdict = 'ok'; break end
        verdict = 'silent'
    until (GetGameTimer() - started) >= PROBE_MS

    local waited = GetGameTimer() - started
    if gapMs > waited then Citizen.Wait(gapMs - waited) end
    pcall(ReleaseSoundId, id)
    return verdict
end

--- The marker printed beside an audition row.
--- @param verdict string
--- @return string
local function mark(verdict)
    if verdict == 'silent' then return '  [silent?]' end
    if verdict == 'unknown' then return '  [unprobed]' end
    return ''
end

--- Walk a list of { set, name } rows, printing each before playing it.
---
--- PRINTED BEFORE, NOT AFTER, because the point of a sequence is to know which
--- one you are hearing WHILE you hear it. The verdict is printed after, on its
--- own indented line, so the name is on screen for the whole 700ms.
local function walk(rows, title)
    if auditioning then
        print('[br_core] sfx: an audition is already running -- /brsfx stop')
        return
    end
    auditioning, cancelAudition = true, false

    Citizen.CreateThread(function()
        print(('--- %s: %d sound%s, %dms apart ---')
            :format(title, #rows, #rows == 1 and '' or 's', GAP_MS))

        -- THE FLAG IS RELEASED WHATEVER HAPPENS, and it is why this is a pcall
        -- rather than a straight loop. A thread that throws simply dies in
        -- FiveM -- no unwinding, no finally -- so an error in the middle of a
        -- walk would leave `auditioning` true for the rest of the session and
        -- every later /brsfx would answer "an audition is already running"
        -- about one that stopped ten minutes ago. A diagnostic that breaks the
        -- thing it is measuring has happened on this project once already
        -- (/brprobe, owner 2026-08-16).
        local silent = 0
        local ran, err = pcall(function()
            for i, r in ipairs(rows) do
                if cancelAudition then
                    print(('  stopped after %d of %d'):format(i - 1, #rows))
                    return
                end
                print(('  %3d/%-3d %s / %s'):format(i, #rows, r.set, r.name))
                local verdict = playProbed(r.set, r.name)
                if verdict == 'silent' then silent = silent + 1 end
                if verdict ~= 'ok' then
                    print(('          %s'):format((mark(verdict):gsub('^%s+', ''))))
                end
            end
        end)
        auditioning = false

        if not ran then
            print(('--- audition stopped: %s ---'):format(tostring(err)))
            return
        end
        print(('--- done. %d of %d never started as far as the engine is concerned. ---')
            :format(silent, #rows))
        if silent > 0 then
            print('    A pair marked [silent?] is almost always a set that is not')
            print('    loaded on this build, not a name you disliked.')
        end
    end)
end

--- Everything the cue table holds, as walkable rows, in a stable order.
---
--- SORTED, because `pairs()` order is unspecified and this list is something a
--- person reads down twice and compares. The old version of this command
--- iterated the table directly and reshuffled between runs.
local function cueRows()
    local keys = {}
    for cue in pairs(BR.Config.Audio.cues) do keys[#keys + 1] = cue end
    table.sort(keys)
    local rows = {}
    for _, cue in ipairs(keys) do
        local def = BR.Config.Audio.cues[cue]
        rows[#rows + 1] = { set = def.set, name = def.name, cue = cue }
    end
    return rows
end

--- The reserved first words. Anything else in slot one is a cue key or a sound
--- SET, which is what keeps `/brsfx HUD_AWARDS COLLECTED` working exactly as it
--- did before this command grew subcommands. No GTA sound set is named `find`;
--- `play` exists as the unambiguous long form for the day one is.
--
-- `sounds` IS LISTED HERE AND ITS ENTRY CHANGES NOTHING TODAY, AND MUTATION
-- TESTING SAYS SO OUT LOUD: a mutant that removes it survives, because the
-- `sounds` arm below RETURNS before control ever reaches the `not VERBS[verb]`
-- guard -- which is the same reason the guard itself is unreachable, spelled
-- out where it is used. The table is kept COMPLETE rather than trimmed to what
-- is load-bearing, because the guard's whole job is to catch the verb whose
-- handler was forgotten, and a VERBS that only lists verbs with handlers is a
-- guard that can never fire.
local VERBS = {
    cues = true, sets = true, sounds = true, find = true, audition = true,
    play = true, bind = true, stop = true, help = true,
}

local function usage()
    print('--- brsfx: pick a GTA sound by ear ---')
    -- THE THREE STEPS ARE NUMBERED AND COME FIRST, and that ordering is the
    -- whole fix. The previous version listed eight verbs flat and alphabetical-
    -- ish, which reads as eight equally likely things to try; the owner tried
    -- none of them and asked how the command works. A numbered sequence at the
    -- top says "start here, then here" without anybody having to infer it.
    print('  THREE STEPS, IN THIS ORDER:')
    print('    1. brsfx sets                   list every sound set')
    print('    2. brsfx sounds <SET>           list every sound in that set')
    print('    3. brsfx play <SET> <NAME>      play one of them')
    print('  the rest, for when you know the name you are hunting:')
    print('    brsfx sets <substr>             step 1, narrowed to matching sets')
    print('    brsfx find <substr> [setSubstr] search sound NAMES across all sets')
    print('    brsfx audition <SET> [substr]   play a whole set, back to back')
    print('    brsfx cues                      play every configured cue')
    print('    brsfx <cue>                     play one configured cue')
    print('    brsfx bind <cue> <SET> <NAME>   re-point a cue for this session')
    print('    brsfx stop                      cut a running audition short')
    print(('  catalogue: %d sets, %d pairs -- GTA\'s own script calls, DLC banks removed')
        :format(#BR.Config.Audio.catalogue, #BR.Config.Audio.find()))
    print('  configured cues:')
    for _, r in ipairs(cueRows()) do
        print(('    %-14s %s / %s'):format(r.cue, r.set, r.name))
    end
    -- THE LOOT PAIR IS NOT IN THE CUE TABLE AND IS LISTED ANYWAY. config/loot.lua
    -- keeps its own two sounds and client/loot.lua and client/inventory.lua play
    -- them directly -- a second sound path that predates this file's table. It is
    -- not moved here (the pickup sound is one the owner heard and kept, and
    -- moving it would be a change nobody asked for), but leaving it INVISIBLE to
    -- the one command for choosing sounds is how it stays unauditionable. This is
    -- also where /brsound's readout went when that command was deleted.
    local L = BR.Config.Loot
    if L and L.openSound and L.pickupSound then
        print('  loot sounds (config/loot.lua, not cues -- `bind` cannot reach them):')
        print(('    %-14s %s / %s'):format('open', L.openSound.set, L.openSound.name))
        print(('    %-14s %s / %s'):format('pickup', L.pickupSound.set, L.pickupSound.name))
    end
    print('  A pair that plays nothing prints [silent?] -- that is a wrong SET,')
    print('  not a sound you disliked. Nothing here is saved; edit')
    print('  br_lib/config/audio.lua once your ear has decided.')
end

RegisterCommand('brsfx', function(_, args)
    local verb = args[1]

    if verb == nil or verb == 'help' then usage(); return end

    if verb == 'stop' then
        cancelAudition = true
        print(('[br_core] sfx: %s'):format(
            auditioning and 'stopping after the current sound' or 'nothing running'))
        return
    end

    if verb == 'cues' then
        walk(cueRows(), 'every configured cue')
        return
    end

    if verb == 'sets' then
        local found = BR.Config.Audio.sets(args[2])
        print(('--- sound sets matching "%s": %d ---')
            :format(tostring(args[2] or 'anything'), #found))
        for _, s in ipairs(found) do
            print(('  %-46s %3d name%s'):format(s.set, s.n, s.n == 1 and '' or 's'))
        end
        print('  The first three are the sets this codebase has HEARD -- a silence')
        print('  in one of those is a wrong name rather than an absent bank.')
        -- POINTS AT STEP 2, NOT AT `audition`, WHICH IS WHAT IT USED TO SAY.
        -- Sending somebody straight from a list of 84 sets into twelve seconds
        -- of unlabelled playback skipped the step they actually wanted, and is
        -- how the browse path came to have a hole in the middle of it.
        print('  Next: brsfx sounds <SET>')
        return
    end

    -- ------------------------------------------------ step 2: ONE set, listed ---
    --
    -- The verb the owner asked for. It PRINTS and plays nothing, which is the
    -- point: a list you can read down in silence is how you choose what to
    -- spend twelve seconds auditioning.
    if verb == 'sounds' then
        local typed = args[2]
        if not typed then
            print('  usage: brsfx sounds <SET>   -- every sound in one set')
            print('  Next: brsfx sets            -- for the set names')
            return
        end

        -- FORGIVING ABOUT WHAT WAS TYPED, LOUD ABOUT WHAT IT DECIDED. resolveSet
        -- takes exact, then case-blind, then a substring that matches ONE set;
        -- anything vaguer comes back as a list of candidates rather than a pick.
        local set, near = BR.Config.Audio.resolveSet(typed)
        if not set then
            if #near == 0 then
                print(('--- no sound set matches "%s" ---'):format(typed))
                print(('  %-34s all %d of them')
                    :format('brsfx sets', #BR.Config.Audio.catalogue))
                print(('  %-34s search sound NAMES instead of set names')
                    :format(('brsfx find %s'):format(typed)))
                return
            end
            print(('--- "%s" could mean %d sets ---'):format(typed, #near))
            for i, s in ipairs(near) do
                if i > LIST_CAP then
                    print(('  ...and %d more -- narrow it: brsfx sets %s')
                        :format(#near - LIST_CAP, typed))
                    break
                end
                print('  ' .. s)
            end
            print('  Next: brsfx sounds <one of those>')
            return
        end

        local names = BR.Config.Audio.namesIn(set) or {}
        local pages = math.max(1, math.ceil(#names / LIST_CAP))
        -- A PAGE THAT IS NOT A NUMBER IS PAGE ONE, and one past the end is the
        -- last page. Neither is worth an error message: the reader is trying to
        -- see a list, and refusing to show them one over an argument they can
        -- see the effect of is the sort of thing that sends people back to
        -- guessing.
        local page = math.floor(tonumber(args[3]) or 1)
        if page < 1 then page = 1 elseif page > pages then page = pages end
        local first, last = (page - 1) * LIST_CAP + 1, math.min(#names, page * LIST_CAP)

        -- SAID OUT LOUD WHENEVER THE RESOLVER MOVED, so `brsfx sounds awards`
        -- never leaves somebody thinking they typed the set name correctly --
        -- they need the catalogue's spelling for step 3.
        if set ~= typed then
            print(('--- reading "%s" as %s ---'):format(typed, set))
        end
        print(('--- %s: %d sound%s%s ---'):format(set, #names,
            #names == 1 and '' or 's',
            pages > 1 and (', page %d of %d'):format(page, pages) or ''))
        for i = first, last do print('  ' .. names[i]) end

        -- NOTHING IS WITHHELD SILENTLY. How many are missing and the exact words
        -- that fetch them, on the same line.
        if last < #names then
            print(('  ...%d more not shown -- brsfx sounds %s %d')
                :format(#names - last, set, page + 1))
        end
        if page > 1 then
            print(('  back to the top -- brsfx sounds %s 1'):format(set))
        end
        if names[first] then
            print(('  Next: brsfx play %s %s'):format(set, names[first]))
            print('        ...or any other NAME above.')
        end
        -- THE `[silent?]` TEACHING, AT THE POINT WHERE IT IS ABOUT TO BE NEEDED.
        -- Being IN the catalogue proves GTA's own scripts play the pair; it does
        -- not prove this build has the bank loaded. "I heard nothing" arriving
        -- three seconds after this list must not read as "that sound is bad" --
        -- that confusion is what cost two rounds of picking a fuel cue.
        print('  A NAME above that plays nothing prints [silent?]. That is this SET')
        print('  not being loaded on this build, not a sound you disliked.')
        return
    end

    if verb == 'find' then
        if not args[2] then
            print('  usage: brsfx find <substr> [setSubstr]')
            return
        end
        local found = BR.Config.Audio.find(args[2], args[3])
        print(('--- names matching "%s"%s: %d ---'):format(args[2],
            args[3] and (' in sets matching "' .. args[3] .. '"') or '', #found))
        for i, r in ipairs(found) do
            if i > LIST_CAP then
                print(('  ...and %d more -- narrow it with a set: brsfx find %s <setSubstr>')
                    :format(#found - LIST_CAP, args[2]))
                break
            end
            print(('  %-46s %s'):format(r.set, r.name))
        end
        if #found > 0 then
            print('  Next: brsfx play <SET> <NAME>')
        end
        return
    end

    if verb == 'audition' then
        local set = args[2]
        if not set then
            print('  usage: brsfx audition <SET> [substr]   (SET from brsfx sets)')
            return
        end
        local names = BR.Config.Audio.namesIn(set)
        if not names then
            -- NOT A REFUSAL. The catalogue is a browsing aid, not a fence, so an
            -- unlisted set is auditioned by falling through to a substring
            -- search over everything -- and if that finds nothing either, the
            -- set name is simply reported back rather than silently ignored.
            local found = BR.Config.Audio.find(nil, set)
            if #found == 0 then
                print(('  no catalogue set matches "%s" -- brsfx sets, or brsfx play %s <NAME>')
                    :format(set, set))
                return
            end
            walk(found, ('sets matching "%s"'):format(set))
            return
        end
        local rows = {}
        for _, n in ipairs(names) do
            if args[3] == nil
                or string.find(string.lower(n), string.lower(args[3]), 1, true) then
                rows[#rows + 1] = { set = set, name = n }
            end
        end
        if #rows == 0 then
            print(('  %s has no name matching "%s"'):format(set, tostring(args[3])))
            return
        end
        walk(rows, set)
        return
    end

    if verb == 'bind' then
        local cue, set, name = args[2], args[3], args[4]
        if not cue or not set or not name then
            print('  usage: brsfx bind <cue> <SET> <NAME>')
            print('  Re-points a cue for THIS SESSION ONLY, so it can be heard where it')
            print('  really fires -- at a pump, or when the wall sets off. Nothing is')
            print('  written; edit br_lib/config/audio.lua to keep it.')
            for _, r in ipairs(cueRows()) do
                print(('    %-14s %s / %s'):format(r.cue, r.set, r.name))
            end
            return
        end
        local def = BR.Config.Audio.cues[cue]
        if not def then
            print(('  no cue "%s" -- brsfx, for the list'):format(cue))
            return
        end
        local was = ('%s / %s'):format(def.set, def.name)
        BR.Config.Audio.cues[cue] = { set = set, name = name }
        print(('[br_core] sfx: %s is now %s / %s (was %s)'):format(cue, set, name, was))
        print('  This client only, until the resource restarts. To keep it, set')
        print(("    ['%s'] = { set = '%s', name = '%s' },"):format(cue, set, name))
        print('  in br_lib/config/audio.lua.')
        Citizen.CreateThread(function()
            local verdict = playProbed(set, name, 0)
            if verdict ~= 'ok' then
                print(('  %s -- the cue is bound anyway, but check the SET name.')
                    :format(mark(verdict):gsub('^%s+', '')))
            end
        end)
        return
    end

    -- ------------------------------------------------- a raw set/name pair ---
    --
    -- `brsfx play SET NAME` and the older two-argument `brsfx SET NAME` are the
    -- same path. The second spelling is kept because it is what config
    -- audio.lua's own comments tell the reader to type, and because a command
    -- that breaks its documented form to make room for subcommands has traded
    -- one discovery problem for another.
    local set, name
    if verb == 'play' then
        set, name = args[2], args[3]
        if not set or not name then
            print('  usage: brsfx play <soundSet> <soundName>')
            return
        end
    -- ═══ `not VERBS[verb]` IS UNREACHABLE TODAY, AND MUTATION TESTING SAYS SO
    --     OUT LOUD ═══
    --
    -- A mutant that deletes it SURVIVES the suite, correctly: every word in
    -- VERBS is handled by an arm above that RETURNS, so nothing in that table
    -- can still be in `verb` by the time control arrives here. The guard is
    -- belt-and-braces against one specific future edit -- a name added to VERBS
    -- whose handler is forgotten -- and the failure it prevents is the quiet
    -- kind: `brsfx newverb HUD_AWARDS` would be read as the sound set
    -- `newverb`, play nothing, and report `[silent?]` about a subcommand.
    elseif args[2] ~= nil and not VERBS[verb] then
        set, name = args[1], args[2]
    end

    if set then
        print(('--- %s / %s ---'):format(set, name))
        Citizen.CreateThread(function()
            local verdict = playProbed(set, name, 0)
            if verdict == 'ok' then
                print('  the engine started it')
            elseif verdict == 'silent' then
                print('  [silent?] the engine reported this finished before it could be')
                print('  heard. Nearly always a SET that is not loaded on this build --')
                print('  check the set name before blaming the sound.')
            else
                -- BOTH WAYS THE PROBE CAN DECLINE, IN ONE SENTENCE, because
                -- naming only one of them would be a readout that lies on the
                -- other. There is no sound id to watch, or the engine would not
                -- answer about it -- either way the sound played and nothing
                -- was learned, which is different from `[silent?]` and must not
                -- read like it.
                print('  [unprobed] it played, but the engine gave no answer about')
                print('  whether it started -- judge this one by ear alone')
            end
        end)
        return
    end

    -- ------------------------------------------------------ one cue by key ---
    local def = BR.Config.Audio.cues[verb]
    if not def then
        print(('[br_core] sfx: no cue "%s", and no second word to read as a sound name.')
            :format(tostring(verb)))
        for _, r in ipairs(cueRows()) do
            print(('    %-14s %s / %s'):format(r.cue, r.set, r.name))
        end
        print('  brsfx        for everything this can do')
        return
    end
    print(('--- %s: %s / %s ---'):format(verb, def.set, def.name))
    Citizen.CreateThread(function()
        local verdict = playProbed(def.set, def.name, 0)
        if verdict ~= 'ok' then
            print(('  %s'):format(mark(verdict):gsub('^%s+', '')))
        end
    end)
end, false)

RegisterCommand('brmute', function()
    muted = not muted
    print(('[br_core] sfx: %s'):format(muted and 'muted' or 'unmuted'))
end, false)

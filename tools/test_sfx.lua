-- Unit tests for the cue palette and the throttle (#24).
--
-- ═══ WHY THIS IS A SUITE OF ITS OWN WHEN THREE OTHERS ALREADY TOUCH AUDIO ═══
--
-- It is deliberately NOT a second copy of what is already covered, and the
-- split is by subject rather than by file:
--
--   tools/test_client.lua  drives /brsfx: the argument order, the silence
--                          probe, every shape HAS_SOUND_FINISHED can arrive
--                          in, `bind`, and the cue arriving off the wire. That
--                          is the COMMAND.
--   tools/test_fuel.lua    the three cues the pump and the wall ask for, the
--                          no-two-cues-sound-alike rule, and the catalogue
--                          membership rule. That is the TABLE'S INVARIANTS.
--   tools/test_shared.lua  the catalogue itself -- ordering, no DLC banks,
--                          and the three pure lookup helpers.
--
-- What none of them covers is the thing #24 is actually about: THE OWNER'S
-- PALETTE, and the throttle in front of it.
--
-- ═══ PART A PINS HIS PAIRS AS LITERALS, AND THAT IS THE POINT OF THE FILE ═══
--
-- The owner sat with /brsfx and wrote out roughly thirty PlaySoundFrontend
-- lines against named game events. That is the expensive half of #24 and the
-- half nobody can reconstruct -- a wrong sound is SILENT, so a pair that got
-- edited by somebody tidying up cannot be noticed by playing the game, only by
-- somebody remembering what it used to be.
--
-- So every pair is written out again HERE, by hand, from his comment. A test
-- that read the pairs back out of BR.Config.Audio.cues would agree with any
-- edit at all, which is the same as not testing them. This is the shape
-- tools/test_warmupcrates.lua uses for his surveyed crate coordinates and for
-- the same reason: these are his numbers, not ours.
--
-- ═══ AND PART A ALSO PINS WHAT IS *NOT* THERE ═══
--
-- Twelve of his picks name a DLC audio bank and are carried in
-- br_lib/config/audio.lua as COMMENTS, because two gates in this tree refuse a
-- DLC set (tools/test_shared.lua bans them from the catalogue,
-- tools/test_fuel.lua requires every cue's set to be in it). Comments are not
-- reachable from Lua, so the file is read as TEXT and his blocked pairs are
-- checked for character by character. Without this they are one tidy-up away
-- from being lost, and the research that produced them is the expensive part.
-- tools/test_fuel.lua reads client/fuel.lua as text in the same way and says
-- so: there is no other way to reach a string that is not code.
--
-- ═══ PART B IS THE THROTTLE, WHICH HAS NEVER BEEN DRIVEN ═══
--
-- The rate limiter is the one piece of this feature with arithmetic in it and
-- the one whose failure has no visual symptom -- #24: "an unthrottled
-- full-auto burst is a hundred overlapping sounds, which has no visual symptom
-- and will not be found by playing." A throttle that silently stopped limiting
-- would look, sound and test exactly like one that worked, right up until
-- somebody fired a shotgun.
--
-- WHAT THIS CANNOT TELL YOU. There is no FiveM here and no audio. Whether
-- HUD_MINI_GAME_SOUNDSET is loaded on the shipping build, whether the owner
-- still likes ScreenFlash for his own death, and whether two of these cues are
-- distinguishable a metre from a firefight are questions only a playtest
-- answers. Every pair below is asserted to be the pair he wrote down -- never
-- that it makes a sound.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_sfx.lua

local realPrint = print
local realExit  = os.exit

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            realExit(1)
        end
        chunk()
    end
end

-- ------------------------------------------------------------------ stubs ---

local gameMs = 100000
function GetGameTimer() return gameMs end

local plays = {}      -- every PlaySoundFrontend
local fromEnt = {}    -- every PlaySoundFromEntity
local logs = {}       -- everything printed by the file under test
local commands = {}   -- [name] = fn
local handlers = {}   -- [event] = fn

function PlaySoundFrontend(id, name, set, net)
    plays[#plays + 1] = { id = id, name = name, set = set, net = net }
end
function PlaySoundFromEntity(id, name, ent, set, net)
    fromEnt[#fromEnt + 1] = { id = id, name = name, ent = ent, set = set, net = net }
end
function GetSoundId() return 7 end
function ReleaseSoundId() end
function HasSoundFinished() return false end

function print(s) logs[#logs + 1] = tostring(s) end

-- NO THIRD ARGUMENT IS ACCEPTED BY THIS STUB, ON PURPOSE.
-- br_lib/shared/devgate.lua wraps RegisterCommand for the whole project, and a
-- command that passed `restricted` would be ace-gated instead -- which FiveM's
-- client console refuses outright in production mode. A two-parameter stub
-- means a third argument vanishes here rather than being asserted about, so
-- the check that it is absent is done against the SOURCE further down.
function RegisterCommand(name, fn) commands[name] = fn end
function RegisterNetEvent() end
function AddEventHandler(ev, fn) handlers[ev] = fn end

Citizen = {
    CreateThread = function(f) f() end,
    Wait = function(ms) gameMs = gameMs + math.max(tonumber(ms) or 0, 16) end,
    SetTimeout = function() end,
}

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    -- geo.lua is here for BR.NormHash, which config/weapons.lua calls at LOAD
    -- time to build its environmental-damage index. Nothing in this suite uses
    -- geometry.
    'br_lib/shared/geo.lua',
    -- The weapons table is loaded for ONE assertion -- the hitmarker floor
    -- against the fastest weapon in the game -- and that assertion is the
    -- reason the floor has a defensible number at all.
    'br_lib/config/weapons.lua',
    'br_lib/config/audio.lua',
    'br_core/client/sfx.lua',
})

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local A = BR.Config.Audio

--- Read a shipped file as text. For the commented-out half of the palette,
--- which is not reachable any other way.
local function source(rel)
    local fh = io.open(ROOT .. rel, 'r')
    if not fh then return nil end
    local s = fh:read('a'); fh:close()
    return s
end

local AUDIO_SRC = source('br_lib/config/audio.lua')
local SFX_SRC   = source('br_core/client/sfx.lua')

-- =========================================================================
-- PART A -- the owner's palette
-- =========================================================================

describe('palette: the pairs the owner wrote down')
do
    -- ═══ VERBATIM, FROM HIS COMMENT ON #24, 2026-09-05 ═══
    --
    -- His event description is kept beside each pair because it is the only
    -- record of what the cue is FOR -- the key name is our summary of his
    -- sentence, and a summary is exactly the thing that drifts.
    local HIS = {
        { cue = 'death.self',        set = 'WastedSounds',
          name = 'ScreenFlash',            was = 'Self died' },
        { cue = 'squad.out',         set = 'GTAO_FM_Events_Soundset',
          name = 'Event_Message_Purple',   was = 'Squad mate died' },
        { cue = 'timer.final',       set = 'MP_MISSION_COUNTDOWN_SOUNDSET',
          name = '5s',                     was = 'Timer down to 3s' },
        { cue = 'airdrop.inbound',   set = 'GTAO_FM_Events_Soundset',
          name = 'Checkpoint_Hit',         was = 'Airdrop coming' },
        { cue = 'volts.award',       set = 'HUD_AWARDS',
          name = 'GOLF_NEW_RECORD',        was = 'Volts award at verdict' },
        { cue = 'toast.warn',        set = 'HUD_FRONTEND_DEFAULT_SOUNDSET',
          name = 'ERROR',                  was = 'Error toast notification sound' },
        { cue = 'match.start',       set = 'HUD_MINI_GAME_SOUNDSET',
          name = 'GO',                     was = 'Match timer start' },
        { cue = 'blips.shown',       set = 'GTAO_Magnate_Boss_Modes_Soundset',
          name = 'Crates_Blipped',         was = 'Courtesy blips or ambulance blips shown' },
        { cue = 'revivekey.pickup',  set = 'In_And_Out_Attacker_Sounds',
          name = 'Friend_Pick_Up',         was = 'Picked up (not bought) revive key' },
        { cue = 'revivekey.expired', set = 'In_And_Out_Defender_Sounds',
          name = 'Dropped',                was = 'Revive key pickup expired' },
        { cue = 'squad.waypoint',    set = 'GTAO_Heists_HUD_Sounds',
          name = 'Scope_Spot_POI',         was = 'Squad mate set a waypoint' },
        { cue = 'match.final2',      set = 'MP_MISSION_COUNTDOWN_SOUNDSET',
          name = 'Oneshot_Final',          was = 'Down to 2 squads or players in match' },
    }

    for _, h in ipairs(HIS) do
        local def = A.cues[h.cue]
        ok(type(def) == 'table', ('%s exists (%s)'):format(h.cue, h.was))
        if type(def) == 'table' then
            eq(def.set, h.set, ('%s plays out of the set he named'):format(h.cue))
            eq(def.name, h.name, ('%s plays the sound he named'):format(h.cue))
        end
    end
end

describe('palette: the knock borrows the death\'s pair, because he said so')
do
    -- ═══ NOT IN THE TABLE ABOVE, AND THAT IS THE POINT ═══
    --
    -- `HIS` is his 2026-09-05 palette, one pair per event description, and a
    -- knock is not in it -- he never named a sound for a squadmate going down,
    -- which is the whole reason `squad.down` lived on the browser tier for
    -- three days. This is a SECOND ruling, on 2026-09-11:
    --
    --   "I think the died/knock sounds are the same right now, not sure.
    --    Regardless both should be the same frontend sound and NOT an NUI
    --    sound"
    --
    -- So it is asserted as a RELATIONSHIP rather than as a pair. Writing
    -- GTAO_FM_Events_Soundset/Event_Message_Purple out a second time here would
    -- pass on the day he retunes the death cue and leaves the knock behind,
    -- which is exactly the drift the two keys exist to make visible.
    local down, out = A.cues['squad.down'], A.cues['squad.out']

    ok(type(down) == 'table',
        'squad.down has a pair at all, so MATE_CUE routes the knock to '
            .. 'PlaySoundFrontend rather than to the browser')
    ok(type(down) == 'table' and type(out) == 'table'
       and down.set == out.set and down.name == out.name,
        'and it is the SAME pair the death plays -- "both should be the same '
            .. 'frontend sound"',
        type(down) == 'table' and ('%s/%s vs %s/%s'):format(
            tostring(down.set), tostring(down.name),
            tostring(out.set), tostring(out.name)) or 'squad.down is missing')

    -- ⚠ AND THE REVIVE IS NOT SWEPT UP IN IT. "The revived sound is perfect --
    -- don't touch it" (same message). One cue moved onto another's pair; a
    -- third did not.
    local up = A.cues['squad.revived']
    ok(type(up) == 'table' and up.set == 'DLC_AW_Frontend_Sounds'
       and up.name == 'Checkpoint_Finish',
        'while squad.revived is exactly where he left it -- he called it '
            .. 'perfect',
        type(up) == 'table' and ('%s/%s'):format(tostring(up.set),
                                                 tostring(up.name)) or nil)
end

describe('palette: every cue is playable at all')
do
    -- ═══ THE WHOLE TABLE, NOT A LIST ═══
    --
    -- tools/test_fuel.lua asserts this for three named cues. Naming them is
    -- what makes that version miss the next one added -- and "the next one
    -- added" is now twelve cues rather than one. A `nil` name or an empty
    -- string reaches PlaySoundFrontend and plays nothing, which is the same
    -- silence a wrong set produces and is just as hard to trace.
    local bad = nil
    local n = 0
    for cue, def in pairs(A.cues) do
        n = n + 1
        if type(def) ~= 'table'
            or type(def.set) ~= 'string' or #def.set == 0
            or type(def.name) ~= 'string' or #def.name == 0 then
            bad = tostring(cue)
        end
    end
    ok(bad == nil, 'every cue names a non-empty set AND a non-empty sound', bad)
    ok(n >= 17, 'and the palette is the size #24 landed it at, not a remnant',
       ('%d cues'):format(n))

    -- A CUE KEY IS A STRING. `/brsfx` indexes this table with a typed word and
    -- BR.Net.SFX_CUE indexes it with something off the wire; a numeric key
    -- would be reachable by neither and is a table written wrong.
    local nonString = nil
    for cue in pairs(A.cues) do
        if type(cue) ~= 'string' then nonString = tostring(cue) end
    end
    ok(nonString == nil, 'and every key is a string', nonString)
end

describe('palette: his picks survive, live or as text')
do
    -- ═══ WHY A TEST READS COMMENTS ═══
    --
    -- These pairs cost the owner an afternoon with /brsfx and they are the ONLY
    -- record of it. Most are now LIVE CUES (2026-09-08: "land the DLC cues"),
    -- and the handful he has since rejected or that have no feature behind them
    -- live in config/audio.lua as comments -- where nothing can reach them and
    -- nothing protects them. A later reader tidying a long file deletes them and
    -- no test anywhere goes red.
    --
    -- SO THE TEXT IS THE ARTEFACT AND IT IS PINNED AS ONE, whichever side of the
    -- line a pair is on: the file must still CONTAIN both strings. It asserts
    -- nothing about whether any of them plays.
    ok(AUDIO_SRC ~= nil, 'config/audio.lua is readable')
    if AUDIO_SRC then
        local BLOCKED = {
            -- Remote_Perspective_Fire was his "Damage hit sound" and is NOT
            -- pinned any more: he rejected it outright on 2026-09-08 ("those
            -- are wrong sound clips") and the hitmarker cues are gone, so the
            -- pair is no longer an artefact worth protecting.
            { 'DLC_H3_Drone_Tranq_Weapon_Sounds', 'Pilot_Perspective_Fire',  'Damage killed sound' },
            { 'DLC_AW_BB_Sounds',                 'Period_Start',            'alt timer start (airhorn)' },
            { 'DLC_IO_Warehouse_Mod_Garage_Sounds', 'Remove_Tracker',        'gas pump started' },
            { 'DLC_AW_Frontend_Sounds',           'Checkpoint_Finish',       'squad mate revived' },
            { 'DLC_Security_Investigation_The_Yacht_Sounds', 'GPS_Set',      'alt squad waypoint' },
            { 'DLC_SECURITY_TAIL_AND_DESTROY_Sounds', 'Destroy',             'fuel finished -- the THIRD pick' },
            { 'dlc_vw_koth_Sounds',               'Zone_Contested',          'circle finished moving' },
            { 'DLC_BTL_TP_Remix_Juggernaut_Player_Sounds', 'Become_Attacker', 'bounty on the map' },
            { 'DLC_Exec_TP_SoundSet',             'Losing_Team_Shard',       'self bounty activated' },
            { 'dlc_ch_heist_finale_security_alarms_sounds', 'Metal_Detector_Online',  'shop purchase complete' },
            { 'dlc_ch_heist_finale_security_alarms_sounds', 'Metal_Detector_Offline', 'shop insufficient funds' },
            { 'DLC_Lowrider_Relay_Race_Sounds',   'Out_Of_Area',             'left the circle' },
            { 'DLC_Lowrider_Relay_Race_Sounds',   'Enter_Area',              'back in the circle' },
        }
        for _, b in ipairs(BLOCKED) do
            ok(AUDIO_SRC:find(b[1], 1, true) ~= nil and AUDIO_SRC:find(b[2], 1, true) ~= nil,
               ('his pick for "%s" is still written down (%s / %s)'):format(b[3], b[1], b[2]))
        end

        -- ═══ AND NONE OF THEM IS SECRETLY LIVE ═══
        --
        -- The other half of the same claim, and the half that would actually
        -- break a build: a DLC set reaching the cue table reddens
        -- tools/test_fuel.lua rather than this file, which is a confusing
        -- place to learn it. Asserted here too, where the reason is written
        -- down.
        -- ═══ AND THE ONES HE REJECTED ARE NOT SECRETLY LIVE ═══
        --
        -- The inverse of what this used to assert. It once demanded that NO cue
        -- name a DLC set, which was the gate the owner overruled; what matters
        -- now is the narrower claim that the specific pairs he threw out have
        -- not crept back in. `hit` and `hit.crit` are the ones he named, and
        -- `fuel.start` is the cue he deleted outright.
        local revived = nil
        for _, key in ipairs({ 'hit', 'hit.crit', 'fuel.done' }) do
            if A.cues[key] ~= nil then revived = key end
        end
        ok(revived == nil,
           'the cues the owner removed have not come back -- he rejected the '
               .. 'clips, so a later reader must not re-derive them from his '
               .. 'original list', revived)

        -- HIS OWN FINDING ABOUT THE BOUNTY CUE, WHICH IS WORTH AS MUCH AS A
        -- PAIR THAT WORKS. He wrote "THIS NEEDS SCALEFORMS ^^^" under
        -- HUD_FRONTEND_MP_COLLECTABLE_SOUNDS / Friend_Pick_Up. Losing that
        -- note means the next person picks the same pair and hears nothing.
        ok(AUDIO_SRC:find('SCALEFORM', 1, true) ~= nil,
           "and his note that the bounty-captured pair needs scaleforms is kept")
    end
end

-- =========================================================================
-- PART B -- the throttle
-- =========================================================================

-- ═══ THE HITMARKER/WEAPON CROSS-FILE INVARIANT USED TO LIVE HERE ═══
--
-- It pinned A.minInterval['hit'] at or below the fastest weapon's fire
-- interval, so no legitimate round could ever be silent. Both the cues and
-- their floors are gone (2026-09-08: "do not wire in any sound at all for hit
-- or hit.crit -- those are wrong sound clips"), and a test that reads two
-- tables neither of which still has the key is not a weaker test, it is a
-- broken one. If a hitmarker ever comes back with a clip he likes, the
-- invariant comes back with it: floor <= fastest weapon interval, and floor >
-- one frame so a shotgun shell is one cue rather than nine pellets.

describe('throttle: it actually limits, and it drops rather than queues')
do
    -- ═══ DRIVEN ON toast.warn, BECAUSE `hit` NO LONGER EXISTS ═══
    --
    -- The owner removed the hitmarker cues entirely on 2026-09-08 ("do not wire
    -- in any sound at all for hit or hit.crit"), and their floors went with
    -- see config/audio.lua for why -- but a suite that drives a cue with no
    -- sound behind it is testing the unknown-cue path by accident.
    --
    -- toast.warn carries a floor for the same reason: it can be asked for more
    -- than once per event.
    local gap = A.minInterval['toast.warn']
    plays = {}

    gameMs = 500000
    BR.Sfx.play('toast.warn')
    eq(#plays, 1, 'the first call plays')

    -- INSIDE THE WINDOW, REPEATEDLY. This is the full-auto burst and the
    -- shotgun shell: many asks, one sound.
    for _ = 1, 20 do
        gameMs = gameMs + 1
        BR.Sfx.play('toast.warn')
    end
    eq(#plays, 1, 'and twenty more inside the window play nothing at all')

    -- ═══ DROPPED, NOT QUEUED, AND THIS IS THE ASSERTION THAT SAYS SO ═══
    --
    -- client/sfx.lua's own header: "a queued hitmarker arrives after the
    -- moment it describes." If the throttle were a queue rather than a gate,
    -- the twenty suppressed calls would arrive here in a rush the instant the
    -- window opened -- which is the same hundred overlapping sounds #24 is
    -- about, moved half a second later.
    gameMs = gameMs + gap
    BR.Sfx.play('toast.warn')
    eq(#plays, 2, 'and once the window is open exactly ONE more plays -- the '
                      .. 'suppressed calls were dropped, not stored')

    -- THE BOUNDARY IS EXCLUSIVE, and it is worth pinning because `<` and `<=`
    -- read identically and differ by one whole cue on a weapon whose cadence
    -- happens to equal the floor.
    plays = {}
    gameMs = 600000
    BR.Sfx.play('toast.warn')
    gameMs = gameMs + gap - 1
    BR.Sfx.play('toast.warn')
    eq(#plays, 1, 'one millisecond short of the floor is still inside it')
    gameMs = gameMs + 1
    BR.Sfx.play('toast.warn')
    eq(#plays, 2, 'and exactly the floor is outside it')
end

describe('throttle: cues without a floor are not throttled')
do
    -- THE DEFAULT IS NO LIMIT, WHICH IS THE RIGHT DEFAULT AND IS ALSO A
    -- DECISION. config/audio.lua's own note about storm.move: it is addressed
    -- by the SERVER, once per phase edge, so a throttle there could only hide
    -- a server bug that sent it twice -- and hiding that is worse than hearing
    -- it. A future refactor that gave every cue a default floor would silently
    -- take that away.
    ok(A.minInterval['storm.move'] == nil, 'storm.move deliberately has no floor')
    plays = {}
    gameMs = 700000
    for _ = 1, 5 do BR.Sfx.play('storm.move') end
    eq(#plays, 5, 'so five asks in the same millisecond are five sounds')
end

describe('storm.move: the owner\'s own line, not a name like it')
do
    -- ═══ THE REPORT, TWICE, AND THE ANSWER WAS IN #24 ALL ALONG ═══
    --
    --   "help me find out why storm.move and storm.out don't play any sound"
    --                                          -- owner, 2026-09-07
    --   "storm.move doesn't play, though it says the engine started it."
    --                                          -- owner, 2026-09-12
    --   "I've heard it play. The line I gave you in the brsfx issue is an exact
    --    line which I've heard play."           -- owner, 2026-09-12
    --
    -- His line in #24 is PlaySoundFrontend(-1, "GO", "HUD_MINI_GAME_SOUNDSET",
    -- 1). The table held GO_NON_RACE, which he never wrote. That is the entire
    -- fault: a name one word longer than the one he had heard.
    --
    -- ═══ WHY THIS IS A PIN AND NOT A PROPERTY ═══
    --
    -- Nothing offline can hear a sound, so there is no property to assert --
    -- which is how a name he never chose sat here through a green suite and two
    -- playtests, and how the first attempt at this block then pinned a SECOND
    -- name he never chose (TIMER_STOP, off a forum post). A cue name in this
    -- table is only ever as good as the ear behind it, so what is pinned is
    -- whose ear: these two strings are his, copied out of his issue.
    local move = A.cues['storm.move']

    eq(move.set, 'HUD_MINI_GAME_SOUNDSET', 'storm.move names the set he wrote')
    eq(move.name, 'GO', 'and the name he wrote, which he has heard play')

    -- ═══ THE TWO NAMES THAT ARE NOT HIS, NAMED ═══
    --
    -- Both were arrived at by reasoning about a list rather than by listening,
    -- and both shipped. If either comes back it comes back with this red.
    ok(move.name ~= 'GO_NON_RACE',
       'not GO_NON_RACE, the corruption of his line that shipped silent twice',
       tostring(move.name))
    ok(move.name ~= 'TIMER_STOP',
       'and not TIMER_STOP, which was picked off a forum post to replace it',
       tostring(move.name))

    -- ═══ IT IS match.start's SOUND, AND THAT IS RECORDED RATHER THAN ASSERTED
    --     AGAINST ═══
    --
    -- His "Match timer start" line is where match.start got GO too, so the wall
    -- setting off and the match starting are now the same noise. This block
    -- used to assert they DIFFER; that assertion was this suite preferring its
    -- own taste to his ear, and it is gone. MEDAL_UP is the alternative he
    -- offered in the same breath and is the one line to change if he wants them
    -- apart -- so what is checked is that the alternative is still reachable,
    -- not that the collision has been tidied away behind his back.
    local alt = false
    for _, n in ipairs(A.namesIn('HUD_MINI_GAME_SOUNDSET') or {}) do
        if n == 'MEDAL_UP' then alt = true end
    end
    ok(alt, 'and MEDAL_UP, his stated alternative, is still in the catalogue '
        .. 'for the day he wants the two events to sound different')

    -- ═══ AND THAT PAIR IS WHAT REACHES THE ENGINE ═══
    --
    -- The half a config pin cannot see. BR.Sfx.play hands PLAY_SOUND_FRONTEND
    -- the NAME third and the SET fourth, which is the reverse of how a cue is
    -- written down, and a swap there silences every sound in the game with no
    -- error anywhere.
    --
    -- THE FOURTH ARGUMENT IS `false` AND HIS LINE SAYS `1`, DELIBERATELY. That
    -- difference has already been settled by his own ear on this very set: the
    -- hitmarker was CHECKPOINT_NORMAL / CHECKPOINT_PERFECT out of
    -- HUD_MINI_GAME_SOUNDSET, it went out through this same `false`, and he
    -- heard both well enough to reject them on 2026-09-08. Every sound anybody
    -- has heard from this codebase left through that argument.
    plays = {}
    gameMs = 710000
    BR.Sfx.play('storm.move')
    ok(#plays == 1 and plays[1].name == 'GO'
       and plays[1].set == 'HUD_MINI_GAME_SOUNDSET',
       'and that is the pair PLAY_SOUND_FRONTEND is handed, name then set',
       plays[1] and ('name=%s set=%s'):format(tostring(plays[1].name),
                                              tostring(plays[1].set)) or 'nothing')
end

describe('throttle: each cue has its own window')
do
    -- Two cues sharing one clock would make a refusal toast mute the
    -- elimination that follows it by a frame -- and a refusal is exactly the
    -- moment another cue is most likely to arrive alongside it.
    plays = {}
    gameMs = 800000
    -- BOTH OF THESE ARE REAL CUES WITH REAL FLOORS. `ui.hover` carries a floor
    -- and no cue definition, so it would fail this by playing nothing at all --
    -- which looks identical to a shared clock and would send the next reader
    -- into client/sfx.lua for a bug that isn't there.
    BR.Sfx.play('toast.warn')
    BR.Sfx.play('squad.waypoint')
    eq(#plays, 2, 'a throttled cue does not close the window on a different one')
end

describe('delivery: every configured cue survives the trip to the native')
do
    -- ═══ LAST IN PART B, NOT FIRST IN PART A, AND THAT IS THE CLOCK'S DOING ═══
    --
    -- This belongs beside the palette by subject, and it cannot go there. The
    -- block below plays EVERY cue, which writes `lastPlayed[cue]` for each of
    -- the five that carry a floor, and it has to walk the clock forward to do it
    -- without testing the throttle by accident. Run before PART B, that leaves
    -- the throttle's cues stamped in the FUTURE relative to the `gameMs = 500000`
    -- those tests set -- so every one of them fails on its first call with
    -- `got 0, want 1`, which reads as a broken rate limiter rather than as a
    -- neighbour that moved the clock. That is precisely what happened when this
    -- was written, and the note is here so the next person to reorder this file
    -- by subject finds out from a comment rather than from six red lines.
    --
    -- ═══ THE SEAM NOTHING ELSE IN THE PROJECT CROSSES ═══
    --
    -- Owner, 2026-09-08: "the 5s storm sound is broke somehow ... perhaps you
    -- could fix the other sounds that are broken." The suites were green while
    -- he said it, AND they were green about the cues he named, which is the part
    -- worth fixing.
    --
    -- The reason is that every OTHER test of audio in this repo stubs BR.Sfx and
    -- asserts the string a call site passed. tools/test_shared.lua's storm
    -- sandbox is explicit about it -- `env.BR.Sfx = { play = function(cue)
    -- C.sfx[#C.sfx + 1] = cue end }` -- so `played(C, 'timer.final') == 1` proves
    -- storm.lua ASKED and proves nothing whatever about whether the ask arrives
    -- anywhere. Between the ask and the engine sit a mute flag, a master switch,
    -- a table lookup and a throttle, and four of those five exits are silent.
    --
    -- So this walks the whole table through the REAL BR.Sfx.play -- the one
    -- loaded from br_core/client/sfx.lua at the top of this file -- and requires
    -- the pair to come out the other side at PlaySoundFrontend. It is the only
    -- assertion in the repo that the cue table and the player agree.
    --
    -- WHAT IT STILL CANNOT TELL YOU, and the file header says this too: whether
    -- the engine makes a NOISE. A wrong set name reaches PlaySoundFrontend
    -- exactly like a right one and plays nothing, which is why /brsfx has a
    -- probe and why `brsfx cues` exists. This proves the cue is DELIVERED; only
    -- a running client can prove it is AUDIBLE.
    local undelivered, wrongPair = nil, nil
    for cue, def in pairs(A.cues) do
        plays = {}
        -- A FRESH CLOCK PER CUE, far past any floor. Several cues carry a
        -- minInterval and this loop would otherwise be testing the throttle --
        -- and would do it in `pairs` order, so which cue got dropped would
        -- change between runs.
        gameMs = gameMs + 100000
        BR.Sfx.play(cue)
        if #plays ~= 1 then
            undelivered = tostring(cue)
        elseif plays[1].name ~= def.name or plays[1].set ~= def.set then
            wrongPair = ('%s -> %s / %s'):format(tostring(cue),
                tostring(plays[1].set), tostring(plays[1].name))
        end
    end
    ok(undelivered == nil,
       'every cue in the table reaches PlaySoundFrontend when it is played',
       undelivered)
    ok(wrongPair == nil,
       'and arrives carrying the set and sound the table gave it', wrongPair)

    -- ═══ THE ARGUMENT ORDER, PINNED ═══
    --
    -- PLAY_SOUND_FRONTEND is (soundId, audioName, audioRef, isNetwork) -- the
    -- NAME first and the SET second, which is the reverse of how every table in
    -- config/audio.lua, every /brsfx verb and every sentence anybody writes
    -- about these puts them. Swapping them is a one-word edit that compiles,
    -- runs, warns about nothing and silences the entire palette at once. It is
    -- the single most expensive typo available in this file's blast radius, so
    -- it is asserted against a pair written out by hand rather than read back
    -- out of the table.
    plays = {}
    gameMs = gameMs + 100000
    BR.Sfx.play('timer.final')
    eq(#plays, 1, 'the storm pip is delivered')
    if #plays == 1 then
        eq(plays[1].name, '5s',
           'and the SOUND goes in the second slot, which is audioName')
        eq(plays[1].set, 'MP_MISSION_COUNTDOWN_SOUNDSET',
           'and the SET goes in the third, which is audioRef')
        eq(plays[1].id, -1, 'with no sound id -- these are never stopped')
        eq(plays[1].net, false,
           'and never networked: every cue here is for THIS client only')
    end
end

-- =========================================================================
-- PART C -- failing safely
-- =========================================================================

describe('unknown cues: loud, once, and never fatal')
do
    plays, logs = {}, {}
    local safe = pcall(BR.Sfx.play, 'no.such.cue')
    ok(safe, 'an unknown cue does not throw')
    eq(#plays, 0, 'and plays nothing')
    ok(#logs == 1, 'and says so on the console exactly once', ('%d line(s)'):format(#logs))
    ok(logs[1] and logs[1]:find('no.such.cue', 1, true) ~= nil,
       'naming the cue, so the typo is findable', logs[1])

    -- ═══ ONCE PER CUE, NOT ONCE PER CALL ═══
    --
    -- The reason is in client/sfx.lua and it is a real failure: a typo inside
    -- a frame loop prints sixty lines a second and buries the console it is
    -- trying to warn. A warning that destroys the log is worse than no warning
    -- -- it is the same shape as the /brprobe incident the audition command's
    -- header records.
    logs = {}
    for _ = 1, 50 do BR.Sfx.play('no.such.cue') end
    eq(#logs, 0, 'and fifty more of the same typo say nothing further')

    -- A DIFFERENT typo is a different fact and still gets its line.
    logs = {}
    BR.Sfx.play('other.typo')
    eq(#logs, 1, 'while a different unknown cue still gets its own warning')

    -- THE SHAPES THAT ARRIVE OFF THE WIRE. BR.Net.SFX_CUE hands whatever
    -- reached the client straight to this function, so a non-string must be an
    -- answer rather than an error mid-match.
    for _, junk in ipairs({ 42, true, {}, '' }) do
        plays = {}
        local fine = pcall(BR.Sfx.play, junk)
        ok(fine and #plays == 0,
           ('a %s cue key plays nothing and does not throw'):format(type(junk)))
    end
    local nilFine = pcall(BR.Sfx.play, nil)
    ok(nilFine, 'and neither does nil')
end

describe('the kill switches')
do
    plays = {}
    gameMs = 900000
    BR.Sfx.setMuted(true)
    BR.Sfx.play('storm.move')
    eq(#plays, 0, 'muted plays nothing')
    BR.Sfx.setMuted(false)
    BR.Sfx.play('storm.move')
    eq(#plays, 1, 'and unmuted plays again')

    -- ═══ TRUTHINESS IS NOT ACCEPTED ═══
    --
    -- `on and true or false`, so a caller handing this the return of a BOOL
    -- native cannot leave the mute in a third state. 0 IS TRUTHY IN LUA, which
    -- is the shape that matters: setMuted(0) must mute, because 0 is truthy,
    -- and the honest thing is for that to be a decision rather than an
    -- accident. What must NOT happen is `muted` holding a number.
    BR.Sfx.setMuted(nil)
    plays = {}
    BR.Sfx.play('storm.move')
    eq(#plays, 1, 'setMuted(nil) is unmuted')
    BR.Sfx.setMuted(false)

    -- The master switch. An operator turning audio off must not need to touch
    -- Lua logic, which is the whole reason the table is in config.
    A.enabled = false
    plays = {}
    BR.Sfx.play('storm.move')
    eq(#plays, 0, 'BR.Config.Audio.enabled = false silences the lot')
    A.enabled = true
end

describe('playFrom: the entity guard')
do
    -- ═══ ZERO IS TESTED EXPLICITLY BECAUSE ZERO IS TRUTHY ═══
    --
    -- 0 is what every entity-returning native answers for "there isn't one",
    -- and it is TRUE in Lua. Playing from entity 0 is silent -- which is
    -- indistinguishable from a wrong sound name, the exact ambiguity this
    -- whole feature exists to remove.
    fromEnt = {}
    gameMs = 950000
    BR.Sfx.playFrom('fuel.start', 0)
    eq(#fromEnt, 0, 'entity 0 plays nothing rather than playing into the void')
    BR.Sfx.playFrom('fuel.start', nil)
    eq(#fromEnt, 0, 'and neither does nil')

    local real = 12345
    BR.Sfx.playFrom('fuel.start', real)
    eq(#fromEnt, 1, 'a real handle plays')
    if fromEnt[1] then
        eq(fromEnt[1].ent, real, 'from that entity')
        eq(fromEnt[1].set, A.cues['fuel.start'].set, 'out of the configured set')
        eq(fromEnt[1].name, A.cues['fuel.start'].name, 'with the configured name')
        -- NOT NETWORKED. server/fuel.lua has already addressed every occupant
        -- and each is playing their own copy; a native that turned out to
        -- network after all would double the sound in the car.
        eq(fromEnt[1].net, false, 'and not as a network sound')
    end

    -- SAME TABLE, SAME REFUSAL. An unknown cue must not reach the native here
    -- either, or the two entry points drift.
    fromEnt = {}
    local safe = pcall(BR.Sfx.playFrom, 'no.such.cue', real)
    ok(safe and #fromEnt == 0, 'and an unknown cue is refused here too')
end

describe('the audition command is registered, and gated by construction')
do
    ok(commands['brsfx'] ~= nil, '/brsfx is registered')
    ok(commands['brmute'] ~= nil, '/brmute is registered')

    -- ═══ NO `restricted` ARGUMENT, AND THIS IS CHECKED IN THE SOURCE ═══
    --
    -- br_lib/shared/devgate.lua wraps RegisterCommand for the whole project,
    -- so a command is dev-gated BY CONSTRUCTION. Passing `true` as the third
    -- argument would make it ace-gated instead, and FiveM's client console
    -- refuses those outright in production mode -- the command would simply
    -- not exist for the person trying to use it, with nothing said. Every one
    -- of the client commands in this tree omits it.
    --
    -- READ FROM THE SOURCE rather than asserted through the stub, because the
    -- stub takes two parameters and a third would vanish into it silently --
    -- which is the same shape as the bug.
    ok(SFX_SRC ~= nil, 'client/sfx.lua is readable')
    if SFX_SRC then
        ok(SFX_SRC:find("RegisterCommand('brsfx', function", 1, true) ~= nil,
           '/brsfx is registered through the wrapped door')
        local restricted = SFX_SRC:find('RegisterCommand%([^)]-,%s*true%s*%)')
        ok(restricted == nil,
           'and no command in this file passes `restricted`, which would be '
               .. 'ace-gated and refused by the client console in production')
    end
end

-- ------------------------------------------------------------------ result ---

if fail == 0 then
    realPrint(('\27[32m%d passed\27[0m'):format(pass))
    realExit(0)
end
realPrint(('\27[31m%d failed\27[0m, %d passed'):format(fail, pass))
realExit(1)

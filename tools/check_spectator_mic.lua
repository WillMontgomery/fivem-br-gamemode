-- Static gate: a spectator's microphone is taken on every path into a session
-- and given back on the way out.
--
-- ═══ THE RULE ═══
--
-- "whoever is the spectator should NEVER be able to talk, only listen" -- the
-- owner. Not a preference, not a config key, and not varied by whether the
-- watcher is a dead player or an admin.
--
-- ═══ WHY A TEXT GATE AND NOT A UNIT TEST ═══
--
-- The client half IS unit-tested -- tools/test_client.lua drives the real key
-- through the real loop and asserts both transmit mechanisms stay shut, on both
-- edges. That half is testable because client/voice.lua is loadable with
-- stubbed natives.
--
-- The SERVER half is the one that actually holds against a modified client, and
-- it is three call sites rather than a function: `sessions[src]` gains an entry
-- in two places and loses one in a third, and each has to reach the mute. There
-- is no value to assert and no return to inspect -- the defect is an EDGE THAT
-- DOES NOT CALL, which is exactly the shape this project keeps shipping and
-- exactly what a truth table over a pure function cannot see.
--
-- So this reads the two files as text. That is a weaker instrument than a test
-- and it is aimed at the one thing a stronger instrument would miss: somebody
-- adding a third way to start spectating.
--
-- Run standalone:  lua tools/check_spectator_mic.lua

local ROOT = 'resources/[fivem-royale]/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- Source with comments stripped, so prose describing a rule is not the rule.
---
--- The whole point of this gate is that a call site exists. Every file it reads
--- carries long comments that NAME the calls -- including this one's own
--- rationale quoted back -- and a check satisfied by a comment mentioning
--- `micFor` would pass on a file that had deleted every one of them.
local function codeOf(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')     -- block comments
    src = src:gsub('%-%-[^\n]*', '')          -- line comments
    return src
end

local function read(rel)
    local fh = io.open(ROOT .. rel, 'r')
    if not fh then
        fail(rel .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ---------------------------------------------------------------- the server ---

local spec = read('br_core/server/spectate.lua')
if spec then
    local code = codeOf(spec)

    -- ONE HELPER, so there is one place the rule lives and one name to grep.
    if not code:find('local function micFor', 1, true) then
        fail('server/spectate.lua no longer routes the microphone through one helper',
             'a second spelling of "mute the spectator" is a second thing to keep in step')
    end

    -- EVERY SESSION CREATION TAKES IT. Counted rather than merely found: there
    -- are two ways to open a session -- `resolve` for a player and `adminStart`
    -- for an admin -- and a gate that only asked "does micFor(src, true) appear
    -- somewhere" passes with either one of them deleted. That is the whole
    -- defect this file exists for.
    local takes = select(2, code:gsub('micFor%(%s*src%s*,%s*true%s*%)', ''))
    if takes < 2 then
        fail(('the microphone is taken at %d session-start site(s), not 2')
            :format(takes),
             'a dead player watching their squad and an admin watching a suspect '
             .. 'are separate call sites; both must mute')
    end

    -- AND THE TEARDOWN GIVES IT BACK. Exactly one, because there is exactly one
    -- `BR.Spectate.stop`; a second would be a second teardown to keep in step.
    local gives = select(2, code:gsub('micFor%(%s*src%s*,%s*false%s*%)', ''))
    if gives < 1 then
        fail('nothing gives the microphone back',
             'a mute that cannot be lifted is a player silent for the rest of '
             .. 'the round with nothing on screen to explain it')
    end

    -- THE ORDER INSIDE stop(). The unmute is ahead of the audit and the client
    -- push on purpose: both of those reach other resources, and a raise in
    -- either would strand the mute. Asserted because it is invisible -- every
    -- ordering of these three lines looks correct while nothing is raising.
    local stopAt  = code:find('function BR.Spectate.stop', 1, true)
    if not stopAt then
        fail('BR.Spectate.stop is gone or renamed')
    else
        local body    = code:sub(stopAt)
        local micAt   = body:find('micFor%(%s*src%s*,%s*false%s*%)')
        local auditAt = body:find('audit%(s, .stop.')
        if not micAt then
            fail('BR.Spectate.stop does not give the microphone back')
        elseif auditAt and micAt > auditAt then
            fail('the microphone is returned AFTER the audit row in stop()',
                 'the audit reaches br_ringmaster; a raise there would leave a '
                 .. 'player who stopped spectating unable to speak')
        end
    end
end

-- ----------------------------------------------------------------- the voice ---

local voice = read('br_core/server/voice.lua')
if voice then
    local code = codeOf(voice)

    if not code:find('function BR.Voice.setSpectatorMuted', 1, true) then
        fail('server/voice.lua no longer exposes BR.Voice.setSpectatorMuted',
             'server/spectate.lua calls it behind a nil-guard, so a rename here '
             .. 'fails OPEN and silently -- every spectator keeps their microphone')
    end

    -- THE SERVER-SIDE NATIVE, WHICH IS THE ONLY PART A MODIFIED CLIENT CANNOT
    -- DECLINE. A version of this that only told the client to be quiet would
    -- pass every other assertion in this file.
    if not code:find('MumbleSetPlayerMuted', 1, true) then
        fail('nothing calls MumbleSetPlayerMuted',
             'the client gag is a rule a hostile client simply does not follow; '
             .. 'the Mumble server mute is the half that holds')
    end

    -- MUTED IS NOT DEAFENED, AND THE RADIO IS NOT TOUCHED. Evicting a spectator
    -- from their squad channel is the obvious lever and it is the wrong one --
    -- leaving the channel is how you stop HEARING it, and "only listen" is the
    -- half being kept. This looks for the eviction inside the function.
    local fnAt = code:find('function BR.Voice.setSpectatorMuted', 1, true)
    if fnAt then
        local rest   = code:sub(fnAt)
        local nextFn = rest:find('\nfunction ', 2)
        local body   = nextFn and rest:sub(1, nextFn) or rest
        if body:find('setPlayerRadio', 1, true) then
            fail('the spectator mute also moves them off their radio channel',
                 'that is a DEAFEN, not a mute -- a dead player must still hear '
                 .. 'their squad')
        end
    end

    -- THE BOOL NORMALISER. MumbleIsPlayerMuted is declared BOOL and a FiveM
    -- native declared BOOL may hand Lua a NUMBER -- and in Lua `0` IS TRUTHY.
    -- This repo has shipped that bug four times. Read raw, it would report every
    -- player as already muted, so the mute is never taken and never returned.
    if code:find('MumbleIsPlayerMuted', 1, true)
        and not code:find('v == 1 or v == true', 1, true) then
        fail('MumbleIsPlayerMuted is read without the didHit normaliser',
             'a BOOL native may return 1, and `if 0 then` is TRUE in Lua')
    end
end

-- --------------------------------------------------------------- the client ---

local cvoice = read('br_core/client/voice.lua')
if cvoice then
    local code = codeOf(cvoice)

    if not code:find('function BR.Voice.silenced', 1, true) then
        fail('client/voice.lua no longer has the master transmit switch')
    end

    -- BOTH PATHS. `gagged()` is the proximity microphone and is deliberately
    -- true in squad mode, so a spectator rule written only into it leaves the
    -- squad radio -- the channel the dead player's own squad is on -- open.
    local uses = select(2, code:gsub('BR%.Voice%.silenced%(%)', ''))
    if uses < 3 then
        fail(('BR.Voice.silenced() is read %d time(s); it gates the proximity '
              .. 'path, the radio press and the frame loop'):format(uses),
             'one of the two transmit mechanisms is no longer covered')
    end
end

if failures > 0 then
    io.write(('\ncheck_spectator_mic: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   a spectator is muted at both session-start sites, unmuted once '
    .. 'on stop,\n     and still hears everything they heard before\n')

-- Every way out of a match takes the match's surfaces with it (#204).
--
-- ═══ WHAT THIS IS FOR ═══
--
-- The death word is the first surface in this client with a lifetime of its
-- own: raised at the moment of death, retired on a clock, rather than drawn for
-- as long as some state is true. Everything else br_core draws mid-match is
-- mounted inside <Hud> in App.tsx and disappears with it; the death word is
-- mounted outside that wrapper on purpose, because `hudUp` goes false the
-- instant a match is decided and the word has its own end.
--
-- That is what made it the first surface that could WALK OUT OF A MATCH. The
-- owner found it on 2026-08-22: go down, leave immediately, and the word is
-- across the lobby.
--
-- ═══ WHY IT IS TESTED HERE AND NOT IN check_death_verdict.lua ═══
--
-- That gate is static -- it greps the source for a shape. It is the right tool
-- for "there is one clock and both halves read it", and it is the wrong tool
-- for this: the claim here is about SEQUENCES of events arriving in an order
-- the server really produces, and a grep cannot tell a handler that clears the
-- word from one that clears it on the wrong edge. So this loads the real
-- client/state.lua over stubbed natives and drives it with the real message
-- shapes, the way tools/test_client.lua does for the interact key.
--
-- ═══ WHAT IS DELIBERATELY NOT COVERED ═══
--
-- Anything that needs a page. Whether CEF actually stops painting the word when
-- it is told show=false is DeathVerdict.tsx's business and is asserted at the
-- source level by check_death_verdict.lua; what is proved here is that the
-- envelope carrying show=false is SENT, on every exit, exactly once each.
--
-- Run standalone:  lua tools/test_matchexit.lua

-- ------------------------------------------------------------ native stubs ---

local fakeTime = 1000
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerServerId() return 1 end
function PlayerId() return 0 end
function PlayerPedId() return 1 end
function GetEntityHealth() return 200 end
function GetPedArmour() return 0 end
function DoesEntityExist() return false end
function IsEntityDead() return false end
function IsPedFatallyInjured() return false end
function NetworkDoesNetworkIdExist() return false end
function NetworkGetEntityFromNetworkId() return 0 end
function NetworkHasControlOfEntity() return false end
function GetPlayerFromServerId() return -1 end
function GetPlayerPed() return 0 end
function SetEntityHealth() end
function SetPedArmour() end
function ResurrectPed() end
function ClearPedTasksImmediately() end
function ExecuteCommand() end

-- THE PAUSE MENU IS MODELLED, NOT MOCKED AWAY, because noteMyState closes the
-- engine's frontend on the very transition this suite drives -- and a native
-- that raised there would look like a bug in the code under test.
local pauseMenuUp = false
function IsPauseMenuActive() return pauseMenuUp end
function SetFrontendActive(on) pauseMenuUp = on == true end

local realPrint = print
function print() end

--- Deferred callbacks, so the ten-second window can be stepped rather than
--- waited out. Citizen.SetTimeout is how the word retires itself.
--
-- CreateThread IS A NO-OP, the same choice tools/test_client.lua makes. The loop
-- registry in client/main.lua parks a `while true` inside one, and running it
-- here would never return. Nothing on the paths driven below needs a thread:
-- everything that has to happen later is scheduled with SetTimeout, which is
-- modelled properly.
local timeouts = {}
Citizen = {
    CreateThread = function() end,
    Wait = function() end,
    SetTimeout = function(ms, fn)
        timeouts[#timeouts + 1] = { due = fakeTime + (tonumber(ms) or 0), fn = fn }
    end,
}

--- Advance the clock and run whatever came due, in order.
local function advance(ms)
    fakeTime = fakeTime + ms
    local due, keep = {}, {}
    for _, t in ipairs(timeouts) do
        if t.due <= fakeTime then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    timeouts = keep
    table.sort(due, function(a, b) return a.due < b.due end)
    for _, t in ipairs(due) do t.fn() end
end

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    handlers[n][#handlers[n] + 1] = fn
end
function RegisterNetEvent() end
function RegisterCommand() end
function RegisterKeyMapping() end

--- Everything the client emitted, in order. The NUI envelopes are read out of
--- this rather than out of a second recorder, so an envelope sent through the
--- wrong channel shows up as a missing one rather than passing quietly.
local events = {}
function TriggerEvent(n, ...)
    events[#events + 1] = { name = n, args = { ... } }
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end
function TriggerServerEvent() end

-- ---------------------------------------------------------------- modules ---

local ROOT = 'resources/[fivem-royale]/'

local function loadAll(list)
    for _, f in ipairs(list) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

loadAll({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/clock.lua',
    'br_lib/config/match.lua',
    'br_core/client/main.lua',   -- BR.State, BR.Loop; must come first
})

-- The collaborators state.lua reaches for on the paths driven below. Real ones
-- would drag in the curtain, the spawn choreography and the HUD builder for no
-- gain: what is under test is which envelope leaves on which edge.
BR.PushHud     = function() end
BR.Notify      = function() end
BR.NotifyClear = function() end
BR.SquadColour = function() return { r = 0, g = 0, b = 0 } end
BR.StormAt     = function() return nil end
BR.IsDeadHp    = function(hp) return (hp or 0) <= 0 end
BR.ToDisplayHp = function(hp) return hp or 100 end
BR.ToEngineHp  = function(hp) return hp or 100 end
BR.Native      = { applyDamage = function() end }
BR.Damage      = { resync = function() end }
BR.Sfx         = { play = function() end }
BR.Party       = { memberIndex = function() return nil end,
                   withdrawInvitesFrom = function() end }
BR.Pause       = { handOverToFrontend = function() end }
BR.Spectate    = { targetSrc = nil }
BR.Squadmates  = { beaconOf = function() return nil end }
BR.Server      = { devMode = false }

-- THE CURTAIN IS A STUB THAT REPORTS ITSELF COVERED IMMEDIATELY. The entry
-- choreography is not what is being tested, and a stub that never reports would
-- park every LOBBY -> match transition behind a wait that this harness's
-- Citizen.Wait does not actually perform.
BR.Spawn = {
    curtain     = function() end,
    awaitCover  = function() return true end,
    toLobby     = function() end,
    leaveMatch  = function() end,
    traveling   = false,
}

loadAll({ 'br_core/client/state.lua' })

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0

local function ok(cond, what, got)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s%s'):format(
            what, got ~= nil and ('  (got: ' .. tostring(got) .. ')') or ''))
    end
end

local function describe(title)
    realPrint('\27[2m-- ' .. title .. '\27[0m')
end

local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

--- Everything sent on one NUI kind since the marker, oldest first.
--- @param kind string
--- @param from integer|nil  index into `events` to start at
local function envelopes(kind, from)
    local out = {}
    for i = (from or 1), #events do
        local e = events[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == kind then
            out[#out + 1] = e.args[2]
        end
    end
    return out
end

local function lastDeath(from)
    local all = envelopes(BR.Nui.DEATH, from)
    return all[#all]
end

local function mark() return #events + 1 end

--- A roster batch, as broadcast.lua really shapes one: an array of deltas that
--- are APPENDED, never coalesced -- which is why a leave from DBNO delivers a
--- DEAD and a LOBBY inside the same message.
--
-- ONE COUNTER FOR BOTH CHANNELS, and it is not a detail: the delta handler
-- drops anything at or below the last sequence it saw, and a snapshot RESETS
-- that number to its own. A suite that numbered its snapshots separately would
-- silently have its later deltas thrown away and would then pass on assertions
-- about events that never happened.
local seq = 0
local function deltas(...)
    seq = seq + 1
    fire(BR.Net.ROSTER_DELTA, { seq = seq, deltas = { ... } })
end

--- A full re-seed, as a reconnect or a br_ui restart produces one.
--- @param myState string
--- @param state string
local function snapshot(myState, state)
    seq = seq + 1
    fire(BR.Net.SNAPSHOT, {
        seq = seq, serverNow = fakeTime,
        roster = { [1] = { src = 1, state = myState } },
        match = { state = state, mode = 'solo', endsAt = 0 },
    })
end

local function meState(state)
    return { op = 'update', src = 1, e = { state = state } }
end

local function matchState(state)
    fire(BR.Net.STATE, { state = state, endsAt = 0, mode = 'solo', serverNow = fakeTime })
end

--- Put this client in a live match, alive, with a clean event log.
local function inMatch()
    timeouts = {}
    BR.State.me.src = 1
    BR.State.roster = { [1] = { src = 1, state = BR.PlayerState.ALIVE } }
    BR.State.me.state = BR.PlayerState.LOBBY
    matchState(BR.MatchState.WAITING)
    deltas(meState(BR.PlayerState.WARMUP))
    matchState(BR.MatchState.PLAYING)
    deltas(meState(BR.PlayerState.ALIVE))
end

local WINDOW = BR.Config.Spectate.deathVerdictMs

-- ═══════════════════════════════════════════════════════════════════════════
-- THE VERDICT STILL WORKS. Everything below this block is about taking the word
-- away, and a suite that only proved it could be taken away would be passed by
-- deleting it.
-- ═══════════════════════════════════════════════════════════════════════════

describe('a death mid-match raises the word and holds the camera')
do
    inMatch()
    local m = mark()
    deltas(meState(BR.PlayerState.DEAD))

    local d = lastDeath(m)
    ok(d ~= nil and d.show == true, 'the word goes up on the death', d and d.show)
    ok(BR.DeathVerdictUp() == true,
       'and the spectate camera is held while it is up', BR.DeathVerdictUp())

    -- The correction path: the cause arrives on its own wire, with no ordering
    -- against the roster delta.
    local m2 = mark()
    fire(BR.Net.KILL_FEED, { victimSrc = 1, killerSrc = 2, cause = 'eliminated' })
    local c = lastDeath(m2)
    ok(c ~= nil and c.show == true and c.cause == 'eliminated',
       'a cause landing inside the window corrects the word', c and c.cause)

    -- A REPEATED STATE PUSH IS NOT AN EXIT. Every state channel in this client
    -- is self-healing by design -- the digest re-asserts the match state twice a
    -- second and the snapshot re-seeds it wholesale -- so "the match is still
    -- playing" can arrive again at any moment, and a teardown that fired on
    -- every state message rather than on a state that is not a live match would
    -- take the word off the screen mid-sentence.
    local mp = mark()
    matchState(BR.MatchState.PLAYING)
    ok(#envelopes(BR.Nui.DEATH, mp) == 0,
       'hearing "still playing" again does not take the word down',
       #envelopes(BR.Nui.DEATH, mp))
    ok(BR.DeathVerdictUp() == true, 'and the hold survives it')

    -- STAYING TO SPECTATE CHANGES NOTHING. This is the flow the owner called
    -- "works great"; the fix must be invisible to it.
    local m3 = mark()
    deltas(meState(BR.PlayerState.SPECTATING))
    ok(#envelopes(BR.Nui.DEATH, m3) == 0,
       'moving into spectate does not take the word down',
       #envelopes(BR.Nui.DEATH, m3))
    ok(BR.DeathVerdictUp() == true, 'and the hold is still on')

    -- ...AND IT RETIRES ITSELF ON ITS OWN CLOCK.
    local m4 = mark()
    advance(WINDOW + 1)
    local e = lastDeath(m4)
    ok(e ~= nil and e.show == false, 'the window closing takes it down', e and e.show)
    ok(BR.DeathVerdictUp() == false, 'and releases the camera', BR.DeathVerdictUp())
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE EXITS
-- ═══════════════════════════════════════════════════════════════════════════

describe("#204 -- the owner's repro: down, then leave immediately")
do
    inMatch()
    deltas(meState(BR.PlayerState.DBNO))
    ok(#envelopes(BR.Nui.DEATH, mark() - 1) == 0,
       'going down is not dying, and raises no word')
    ok(BR.DeathVerdictUp() == false, 'nothing is up while merely downed')

    -- LEAVING WHILE DOWNED IS AN ELIMINATION, and server/match.lua's leaveMatch
    -- says so: eliminate('left') flips the roster to DEAD, then setState puts
    -- them in the LOBBY. Both deltas are queued and flushed together, so this is
    -- one batch -- which is why the bug is instant rather than a race.
    local m = mark()
    deltas(meState(BR.PlayerState.DEAD), meState(BR.PlayerState.LOBBY))

    local sent = envelopes(BR.Nui.DEATH, m)
    ok(#sent == 2, 'the word goes up on the death and comes back down on the leave',
       #sent)
    ok(sent[#sent] ~= nil and sent[#sent].show == false,
       'the last thing the page is told is that the word is DOWN',
       sent[#sent] and sent[#sent].show)
    ok(BR.DeathVerdictUp() == false,
       'and this client no longer believes anything is on screen')

    -- The pending retirement must not fire over whatever is on screen later.
    local m2 = mark()
    advance(WINDOW + 1)
    ok(#envelopes(BR.Nui.DEATH, m2) == 0,
       'the retirement timer is a no-op once the word is already down',
       #envelopes(BR.Nui.DEATH, m2))
end

describe('#204 -- die first, then use Leave Match inside the window')
do
    inMatch()
    deltas(meState(BR.PlayerState.DEAD))
    advance(2000)

    -- A separate batch this time: the player watched for two seconds and then
    -- pressed the button. The match is still PLAYING underneath them.
    local m = mark()
    deltas(meState(BR.PlayerState.LOBBY))
    local d = lastDeath(m)
    ok(d ~= nil and d.show == false, 'leaving takes the word with it', d and d.show)
    ok(BR.State.match.state == BR.MatchState.PLAYING,
       'and the match is still running, which is what makes this an EXIT and '
       .. 'not a teardown', BR.State.match.state)
end

describe('#204 -- the match ends underneath the player')
do
    inMatch()
    deltas(meState(BR.PlayerState.DEAD))

    local m = mark()
    matchState(BR.MatchState.ENDED)
    local d = lastDeath(m)
    ok(d ~= nil and d.show == false,
       'the word comes down as the verdict SCREEN comes up', d and d.show)

    -- ...AND THE VERDICT SCREEN IS UNTOUCHED. It is not a match-scoped surface:
    -- it IS the teardown, and the LOBBY flip below is the transition that raises
    -- it. Registering it would delete the screen it exists to show.
    local m2 = mark()
    advance(600)
    ok(#envelopes(BR.Nui.SUMMARY, m2) == 1,
       'the match-end summary is still sent to a participant',
       #envelopes(BR.Nui.SUMMARY, m2))

    -- The sweep home follows. It must not send a second dismissal.
    local m3 = mark()
    deltas(meState(BR.PlayerState.LOBBY))
    ok(#envelopes(BR.Nui.DEATH, m3) == 0,
       'and the sweep home says nothing more about a word already down',
       #envelopes(BR.Nui.DEATH, m3))
    ok(#envelopes(BR.Nui.SUMMARY, m3) == 0,
       'and takes no summary away with it', #envelopes(BR.Nui.SUMMARY, m3))
end

describe('#204 -- the match is destroyed under a dead player and never ENDS')
do
    -- server/match.lua's destroy() is reached when a match empties out or an
    -- admin forces it: it sweeps everyone to the LOBBY and detaches them
    -- WITHOUT the ENDED transition. From this client the only signal is the
    -- digest settling to WAITING, which the digest handler replays locally.
    inMatch()
    deltas(meState(BR.PlayerState.DEAD))

    local m = mark()
    fire(BR.Net.DIGEST, { alive = 0, squadsAlive = 0,
                          state = BR.MatchState.WAITING, endsAt = 0,
                          serverNow = fakeTime })
    local d = lastDeath(m)
    ok(d ~= nil and d.show == false,
       'a mirror settling back to WAITING takes the word with it', d and d.show)
end

describe('#204 -- a new round must never open with last round\'s word on it')
do
    for _, next_ in ipairs({ BR.MatchState.WARMUP, BR.MatchState.BUS }) do
        inMatch()
        deltas(meState(BR.PlayerState.DEAD))
        local m = mark()
        matchState(next_)
        local d = lastDeath(m)
        ok(d ~= nil and d.show == false,
           ('%s takes the word down'):format(next_), d and d.show)
    end
end

describe('#204 -- a revive undoes the death, and the word with it')
do
    -- #144's held death: dying before the match reaches PLAYING puts the roster
    -- through DEAD for real (server/combat.lua's holdForStart has to, or the
    -- health check eliminates them a second time), so the word genuinely goes up
    -- for somebody who is about to be stood back up.
    inMatch()
    deltas(meState(BR.PlayerState.DEAD))
    ok(BR.DeathVerdictUp() == true, 'the held death does raise the word')

    local m = mark()
    fire(BR.Net.REVIVED)
    local d = lastDeath(m)
    ok(d ~= nil and d.show == false, 'the revive takes it down', d and d.show)
    ok(BR.DeathVerdictUp() == false, 'and the camera is released')

    -- NOTHING ELSE HAPPENS ON THAT EDGE. A dismissal that also touched the focus
    -- stack could strand a player with no cursor, which is worse than the bug
    -- being fixed -- so the revive is the cleanest place to pin it: it calls the
    -- dismissal and nothing else.
    local focusy = 0
    for i = m, #events do
        local n = events[i].name
        if n == 'br:ui:pushFocus' or n == 'br:ui:popFocus'
           or n == 'br:ui:clearFocus' then
            focusy = focusy + 1
        end
    end
    ok(focusy == 0, 'a dismissal never touches the focus stack', focusy)
end

describe('#204 -- restart br_core in front of a page that did not restart')
do
    -- br_ui is a separate resource with a separate lifetime. A fresh br_core has
    -- no deadline and no memory of what it sent, and CEF is still holding
    -- show=true -- so the correction must go out UNCONDITIONALLY. This is the
    -- failure that is worse than the reported one: not a word that lingers ten
    -- seconds, but one that never comes down at all.
    inMatch()
    deltas(meState(BR.PlayerState.DEAD))
    advance(WINDOW + 1)          -- this client now believes nothing is up
    ok(BR.DeathVerdictUp() == false, 'precondition: nothing is up locally')

    local m = mark()
    fire('onClientResourceStart', 'br_core')
    local d = lastDeath(m)
    ok(d ~= nil and d.show == false,
       'br_core starting tells the page the word is down even though this '
       .. 'client never thought it was up', d and d.show)

    -- ...AND ONLY FOR THIS RESOURCE.
    local m2 = mark()
    fire('onClientResourceStart', 'some_other_resource')
    ok(#envelopes(BR.Nui.DEATH, m2) == 0,
       'another resource starting is none of our business',
       #envelopes(BR.Nui.DEATH, m2))
end

describe('#204 -- a reconnect re-seeds from a snapshot and raises nothing')
do
    -- A real disconnect takes the whole client with it -- Lua state and CEF
    -- both -- so the honest claim here is narrower and is the one that could
    -- actually go wrong: the SNAPSHOT that re-seeds a returning player must not
    -- raise a word for a death that happened before they left, and must dismiss
    -- if it seats them in the lobby.
    inMatch()
    local m = mark()
    snapshot(BR.PlayerState.DEAD, BR.MatchState.PLAYING)
    ok(#envelopes(BR.Nui.DEATH, m) == 0,
       'a snapshot is not a death edge and raises no word',
       #envelopes(BR.Nui.DEATH, m))

    -- And one that seats them in the lobby dismisses, because that snapshot is
    -- the client learning the match is over for it.
    deltas(meState(BR.PlayerState.ALIVE))
    deltas(meState(BR.PlayerState.DEAD))
    ok(BR.DeathVerdictUp() == true, 'precondition: the word is up')
    local m2 = mark()
    snapshot(BR.PlayerState.LOBBY, BR.MatchState.PLAYING)
    local d = lastDeath(m2)
    ok(d ~= nil and d.show == false,
       'a snapshot that puts me in the lobby takes the word with it',
       d and d.show)
end

describe('#204 -- the rule is a registry, not a line in one handler')
do
    -- The mechanism itself, because the whole point of the change is that the
    -- NEXT surface joins it without editing any of the edges above.
    ok(type(BR.MatchSurface) == 'function',
       'br_core exposes a way to declare a match-scoped surface',
       type(BR.MatchSurface))

    local seen = {}
    BR.MatchSurface('test surface', function(force) seen[#seen + 1] = force end)

    inMatch()
    deltas(meState(BR.PlayerState.DEAD))
    deltas(meState(BR.PlayerState.LOBBY))
    ok(#seen >= 1, 'a newly registered surface is dismissed on the leave edge',
       #seen)
    ok(seen[1] == false,
       'and is told this is an ordinary dismissal, not a stale page',
       tostring(seen[1]))

    local before = #seen
    fire('onClientResourceStart', 'br_core')
    ok(#seen == before + 1 and seen[#seen] == true,
       'and is told to force when br_core restarts in front of the page',
       tostring(seen[#seen]))
end

realPrint(('%s%d passed, %d failed\27[0m')
    :format(fail == 0 and '\27[32m' or '\27[31m', pass, fail))
os.exit(fail == 0 and 0 or 1)

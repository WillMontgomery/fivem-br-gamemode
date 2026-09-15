-- The guided first run's ACCOUNT-LEVEL fact, and the second run it must refuse.
--
-- ═══ WHAT THIS IS FOR ═══
--
-- Owner, 2026-09-08: "we just had a player where the tutorial ran, they
-- completed it in-game all the way through, got the volts, then left warmup
-- (they were in solos if that matters), then they joined squads (and got matched
-- with me immediately, which is proper), then were given deferred matchmaking
-- and shown the in-game tutorial a second time. the payout properly caught
-- they'd already done the tutorial once, but regardless, not the affect we
-- want."
--
-- The payout caught it because the payment lock is a DynamoDB conditional write
-- asked at the moment of paying. Nothing asked the OTHER record. There are two
-- independent completion facts on the same profile item -- `reportRewards`
-- (paid) and the `tutorial` string (offered) -- and the second is read exactly
-- once per connection, to send one TUTORIAL_OFFER, and was never re-pushed
-- after it changed. So finishing wrote 'done' and changed nothing anybody asked.
--
-- ═══ WHY THIS IS ITS OWN SUITE ═══
--
-- br_core/client/tutorial.lua is loaded by NO existing suite -- the client half
-- of this feature has never had a harness -- and it is the tenth-odd suite here
-- to stand up a single client file for that reason (see test_lobbyseq.lua,
-- test_matchexit.lua, test_landtime.lua). The server half of the same fix is
-- asserted in test_roster.lua, beside the hold it belongs to.
--
-- ═══ WHAT IS ASSERTED ═══
--
-- That `offerable` -- the account's standing, the one flag a completion moves --
-- goes false on FINISH and not on an abandoned run. Both terminal answers must
-- lower it and only the terminal ones may: an abandoned run is deliberately not
-- a decline and not a completion (owner, 2026-09-07: "leaving the game tutorial
-- early results in the toggle still being available in the lobby - great, keep
-- it"), and the page's re-arm is gated on this flag, so a fixture that let an
-- abandonment lower it would be asserting the fix had gone too far.
--
-- AND, SINCE 2026-09-12, WHEN A MATCH ITSELF ANSWERS THE OFFER. The owner: "if a
-- new player rejects the offer for first-time tutorial, the offer still shows up
-- after their first match. Even for subsequent sessions." Rejecting it sent
-- nothing -- the only gesture wired to TUTORIAL_DECLINE is unticking the SECOND
-- toggle, which is not drawn until the lobby half reaches its last card, and the
-- first toggle beside Ready up is page-local state. So the row stayed at '' and
-- '' is the state that gets offered. What is pinned is the new tick: the bus
-- spends an offer nobody took, the pad does not, and a player who STARTED either
-- half keeps theirs however the run ended.
--
-- ═══ WHAT IS DELIBERATELY NOT COVERED ═══
--
-- Whether the PAGE re-arms. That is Lobby.tsx's `queue()` and it is TypeScript;
-- no Lua suite can reach it. What is proved here is that the fact the page now
-- reads is TRUE for a first-timer, TRUE after an abandoned run, and FALSE after
-- a completion -- which is the whole of what that gate consumes.
--
-- Run standalone:  lua tools/test_tutorial.lua

-- ------------------------------------------------------------ native stubs ---

local realPrint = print
local logged = {}
function print(s) logged[#logged + 1] = tostring(s) end

local fakeTime = 1000
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function GetConvar(_, d) return d end
function PlayerPedId() return 1 end

-- The camera natives. The walkthrough borrows a camera for the scripted look at
-- the shop; none of these blocks drive that, but `BR.Tutorial.game(false)` calls
-- camTo(nil) on every ending, so DoesCamExist has to answer something.
function CreateCamWithParams() return 1 end
function DoesCamExist() return false end
function DestroyCam() end
function SetCamActive() end
function SetCamActiveWithInterp() end
function RenderScriptCams() end
function GetGameplayCamCoord() return { x = 0.0, y = 0.0, z = 0.0 } end
function GetGameplayCamRot() return { x = 0.0, y = 0.0, z = 0.0 } end
function FreezeEntityPosition() end
function DisableControlAction() end
function IsDisabledControlJustPressed() return false end
function SetTimeout() end

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
function RegisterNetEvent() end
function TriggerEvent(n, ...)
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end

--- EVERY MESSAGE THAT LEFT FOR THE SERVER, in order.
---
--- The completion is a net message and nothing else -- BR.Tutorial.finish's
--- whole job on the wire is one TUTORIAL_DONE -- so a suite that did not record
--- these could not tell "finished" from "stopped".
local sent = {}
function TriggerServerEvent(n, d) sent[#sent + 1] = { name = n, data = d } end

local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }
function CreateThread() end
function Wait() end

-- ------------------------------------------------------------------ modules ---

local ROOT = 'resources/[fivem-royale]/'

BR = BR or {}

--- The loop registry, kept BY NAME so one of them can be stepped.
---
--- tutorial.lua registers three loops at load -- the leave tick, the arrow-key
--- frame pass, and the one that spends an untaken offer when the bus goes. Only
--- the last is driven here, by `pump` below and only where a block says so, so
--- the other two still cannot be depended on by accident.
local loops = {}
BR.Loop = {
    TICK = 'tick', FRAME = 'frame',
    register = function(_, name, fn) loops[name] = fn end,
}

--- Step one registered loop once.
---
--- A MISSING LOOP IS REPORTED AND NOT FATAL, so a suite written against a loop
--- that does not exist yet fails at its assertions -- where the reason is -- and
--- not at its first pump.
local function pump(name)
    local fn = loops[name]
    if not fn then
        realPrint('\27[31mno loop registered\27[0m ' .. tostring(name))
        return
    end
    fn()
end

--- MY OWN PLAYER STATE, which is the only way a client file can learn that a
--- match has actually started for it.
---
--- tutorial.lua already reads this on its leave tick -- "there is no client
--- event for 'my own state changed'" -- and the new tick reads the same field.
BR.State = { me = { state = nil } }

for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/geo.lua',     -- BR.Dist, for the crate-proximity handler
    'br_core/client/tutorial.lua',
}) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

-- ------------------------------------------------------------ the fixture ---

--- THE LAST ENVELOPE THE PAGE WOULD HAVE RECEIVED.
---
--- `publish()` is the only way any tutorial fact reaches the page, so reading
--- the newest envelope is reading exactly what the page would believe. Asserting
--- on the file's locals directly is not possible and would be worse if it were:
--- the page's gate consumes the WIRE value, and a fact that changed without
--- being published is a fact the page never learns.
local last = nil
AddEventHandler('br:ui:sendLocal', function(kind, d)
    if kind == BR.Nui.TUTORIAL then last = d end
end)

--- Put the client back to a freshly connected state.
---
--- THERE IS NO RESET IN tutorial.lua AND THERE SHOULD NOT BE -- the file's flags
--- die with the client session, which is correct. So this drives the real
--- entrances instead: stop both halves, then re-answer TUTORIAL_OFFER, which is
--- the one message that sets the account's standing on connect.
local function connect(offer)
    BR.Tutorial.game(false)
    BR.Tutorial.set(false)
    -- IN THE LOBBY, which is where a connection lands. The spend tick reads this
    -- and a block that left it in a match would arm the next block's first pump.
    BR.State.me.state = BR.PlayerState.LOBBY
    sent = {}
    last = nil
    TriggerEvent(BR.Net.TUTORIAL_OFFER, { offer = offer ~= false })
end

--- Did a message of this name leave for the server?
local function sentOne(name)
    for _, m in ipairs(sent) do if m.name == name then return m end end
end

--- The newest published value of one field.
local function published(field)
    return last and last[field]
end

-- ---------------------------------------------------------------------------
-- The offer arrives, and it is the account's standing
-- ---------------------------------------------------------------------------

describe('tutorial.offer')
do
    connect(true)
    ok(published('offerable') == true,
       'A BRAND NEW ACCOUNT IS OFFERABLE -- the row read back \'\' and the '
       .. 'server said yes')

    connect(false)
    ok(published('offerable') == false,
       'and an account whose row already says declined or done is not')
end

-- ---------------------------------------------------------------------------
-- THE OWNER'S REPORT, 2026-09-12
--
-- "if a new player rejects the offer for first-time tutorial, the offer still
-- shows up after their first match. Even for subsequent sessions."
--
-- ═══ THESE TWO BLOCKS ARE FIRST, AND THE ORDER IS LOAD-BEARING ═══
--
-- `took` inside tutorial.lua is a ONE-WAY SESSION LATCH with no reset, which is
-- correct for a client whose flags die with the session and is exactly what
-- `connect()` cannot undo. So the block that needs it FALSE has to run before
-- anything in this suite starts a walkthrough. Anything added above here that
-- calls `br:tutorial:set` or `br:tutorial:game` will silently turn the first
-- block below into a copy of the second.
-- ---------------------------------------------------------------------------

describe('tutorial.firstMatch')
do
    -- ═══ READYING UP WITHOUT TAKING IT IS AN ANSWER ═══
    --
    -- The page's decline card says the offer "is only valid for their first
    -- match" (owner, 2026-09-07), and nothing enforced that: the ONLY gesture in
    -- the tree that sent TUTORIAL_DECLINE was unticking the SECOND toggle, which
    -- is not even drawn until the lobby half reaches its last card. A player who
    -- turned the first toggle off and pressed Ready up sent nothing at all, so
    -- the row stayed '' forever and the offer came back every match and every
    -- session.
    connect(true)

    pump('tutorial.spend')
    ok(published('offerable') == true,
       'SITTING IN THE LOBBY ANSWERS NOTHING -- the offer stands while there is '
       .. 'still a way to take it')
    ok(sentOne(BR.Net.TUTORIAL_DECLINE) == nil, 'and nothing is written')

    -- ═══ NOR DOES THE PAD, AND THAT IS THE POINT OF WAITING FOR THE BUS ═══
    --
    -- WARMUP is where the IN-GAME half runs. The page arms it on ready-up and
    -- starts it once the player is on the pad, so a tick that spent the offer on
    -- arrival would race the walkthrough it is meant to be detecting the absence
    -- of.
    BR.State.me.state = BR.PlayerState.WARMUP
    pump('tutorial.spend')
    ok(published('offerable') == true,
       'NOR DOES REACHING THE PAD -- the in-game half starts from here, so the '
       .. 'offer cannot expire on arrival',
       'offerable = ' .. tostring(published('offerable')))
    ok(sentOne(BR.Net.TUTORIAL_DECLINE) == nil, 'and still nothing is written')

    -- ═══ THE BUS IS THE MOMENT ═══
    BR.State.me.state = BR.PlayerState.BUS
    pump('tutorial.spend')

    ok(sentOne(BR.Net.TUTORIAL_DECLINE) ~= nil,
       'THE BUS SPENDS IT -- the match has started and they did not take the '
       .. 'offer, which is an answer, and the row is written so it is still an '
       .. 'answer tomorrow')
    ok(published('offerable') == false,
       'and the account-level flag falls with it, so the second toggle cannot '
       .. 'be re-armed for the rest of the session',
       'offerable = ' .. tostring(published('offerable')))
    ok(published('offer') == false,
       'and the lobby toggle goes too, which is the half of the report that '
       .. 'happens without reconnecting')

    -- ONCE, NOT EVERY TICK. `offerable` is false now, which is what closes the
    -- loop's own gate -- so this also asserts the gate is read and not just set.
    sent = {}
    BR.State.me.state = BR.PlayerState.ALIVE
    pump('tutorial.spend')
    pump('tutorial.spend')
    ok(sentOne(BR.Net.TUTORIAL_DECLINE) == nil,
       'and it is sent ONCE, not on every tick of the match they are now in')
end

describe('tutorial.firstMatch.took')
do
    -- ═══ STARTING IT IS TAKING THE OFFER, HOWEVER THE RUN ENDS ═══
    --
    -- Owner, 2026-09-07: "leaving the game tutorial early results in the toggle
    -- still being available in the lobby - great, keep it." An abandoned run is
    -- deliberately neither a decline nor a completion, and the whole risk in the
    -- fix above is that it starts reading as one: the leave tick takes `inGame`
    -- down the instant the player's state stops being WARMUP, so by the time the
    -- bus has them there is nothing left on the flags to say they ever tried.
    --
    -- `took` is what remembers. If this block fails, the player the owner asked
    -- us to protect has had their second go taken away.
    connect(true)
    TriggerEvent('br:tutorial:set', true)
    ok(published('run') == true, 'they pressed Start tutorial')
    TriggerEvent('br:tutorial:set', false)
    ok(published('run') == false, 'and abandoned it')

    sent = {}
    BR.State.me.state = BR.PlayerState.BUS
    pump('tutorial.spend')

    ok(sentOne(BR.Net.TUTORIAL_DECLINE) == nil,
       'AN ABANDONED RUN IS STILL NOT AN ANSWER -- the bus does not write one '
       .. 'for a player who took the offer and had it break under them')
    ok(published('offerable') == true,
       'so the offer survives the match, exactly as it survives the abandonment',
       'offerable = ' .. tostring(published('offerable')))
end

-- ---------------------------------------------------------------------------
-- THE OWNER'S SEQUENCE, 2026-09-08
-- ---------------------------------------------------------------------------

describe('tutorial.completedOnce')
do
    -- ── SOLOS: the in-game half runs, all the way through ────────────────
    connect(true)

    -- Armed by the page and taken. This is the real doorway -- br_ui's
    -- TUTORIAL_SET callback fans `{ game: true }` out as this event -- rather
    -- than a direct call, so the fixture exercises the same entrance the page
    -- uses and would notice the fanout being rewired.
    TriggerEvent('br:tutorial:game', true, false)
    ok(published('game') == true, 'the in-game walkthrough is running in solos')

    local held = sentOne(BR.Net.TUTORIAL_SET)
    ok(held ~= nil and held.data.game == true,
       'and the server is asked to hold the warmup while it runs')

    -- ── THEY COMPLETE IT, ALL THE WAY THROUGH ───────────────────────────
    --
    -- `done` true with `on` false is the page's completion message and the only
    -- ending that pays. See the handler in tutorial.lua.
    sent = {}
    TriggerEvent('br:tutorial:game', false, true)

    ok(sentOne(BR.Net.TUTORIAL_DONE) ~= nil,
       'completing it claims the reward -- this is the 500 Volts')
    ok(published('game') == false, 'and the cards come off the screen')

    -- ── THE FIX. THE COMPLETION REACHES THE ACCOUNT-LEVEL FLAG ──────────
    --
    -- This is the assertion the bug was missing. Before the fix
    -- BR.Tutorial.finish was two lines -- fire TUTORIAL_DONE, return -- so
    -- `offerable` stayed true, publish() kept re-asserting it, and the page's
    -- re-arm in Lobby.tsx's queue() read a stale yes on every later ready-up.
    ok(published('offerable') == false,
       'AND THE ACCOUNT HAS SPENT ITS OFFER -- the flag the page\'s re-arm '
       .. 'reads is false the moment they finish, not on the next connect',
       'offerable = ' .. tostring(published('offerable')))

    -- ── THEY LEAVE WARMUP AND QUEUE FOR SQUADS ──────────────────────────
    --
    -- Nothing in this file is touched by a match ending, which is the point:
    -- the flags are per-session and the fix has to hold across a mode change
    -- without anything clearing them. The owner's report is exactly this
    -- boundary -- solos, then squads, same connection -- and the reason it was
    -- never caught earlier is that reconnecting makes it disappear.
    ok(published('offerable') == false,
       'and it is STILL false in the next lobby, in another mode, on the same '
       .. 'connection -- which is the boundary the report crossed')

    -- AND THE SECOND RUN IS NEVER ARMED. The page is what would arm it and the
    -- page is TypeScript, so what is provable here is the input it reads. That
    -- input is now false, and Lobby.tsx's queue() requires it true.
    ok(published('run') ~= true and published('game') ~= true,
       'with neither half running, which is what the owner watched start again')
end

-- ---------------------------------------------------------------------------
-- THE NEGATIVES -- the fix must not go further than the report
-- ---------------------------------------------------------------------------

describe('tutorial.abandoned')
do
    -- ═══ AN ABANDONED RUN IS NOT A COMPLETION, AND MUST NOT BE ═══
    --
    -- Owner, 2026-09-07: "leaving the game tutorial early results in the toggle
    -- still being available in the lobby - great, keep it - but readying up at
    -- that point to go into tutorial again doesn't work."
    --
    -- That second go is the whole reason Lobby.tsx re-arms on ready-up at all.
    -- Gating that re-arm is what fixes the reported bug, so THIS is the block
    -- that catches the fix going too far: if `offerable` fell on an abandonment,
    -- the gate would close on the one player it must stay open for.
    connect(true)
    TriggerEvent('br:tutorial:game', true, false)
    ok(published('game') == true, 'the in-game walkthrough is running')

    sent = {}
    -- NO `done`. The page sends `{ game: false }` alone when a card's anchor has
    -- gone, which is a fault rather than an ending.
    TriggerEvent('br:tutorial:game', false, false)

    ok(sentOne(BR.Net.TUTORIAL_DONE) == nil,
       'abandoning it claims nothing -- a learner is not paid for the '
       .. 'walkthrough breaking under them')
    ok(published('game') == false, 'the cards come off the screen either way')
    ok(published('offerable') == true,
       'BUT THE OFFER SURVIVES -- an abandoned run is not a decline and not a '
       .. 'completion, so they are still offered another go',
       'offerable = ' .. tostring(published('offerable')))
end

describe('tutorial.decline')
do
    -- THE OTHER TERMINAL ANSWER, unchanged by this fix and asserted so it stays
    -- that way. Both terminal states lower the flag; they are kept apart only so
    -- a human reading the profile row can tell why.
    connect(true)
    sent = {}
    TriggerEvent('br:tutorial:decline')

    ok(published('offerable') == false,
       'declining spends the offer, exactly as finishing now does')
    ok(sentOne(BR.Net.TUTORIAL_DECLINE) ~= nil,
       'and the row is written on the far side so it is still gone tomorrow')
end

describe('tutorial.devCommand')
do
    -- ═══ /brtutorial STILL OUTRANKS A SPENT OFFER ═══
    --
    -- Owner, 2026-09-08: "again, the continue toggle did not appear. is this
    -- because I've already completed it once by chance? i should be able to
    -- again since I'm using `brtutorial`."
    --
    -- The fix above makes finishing lower the flag DURING the session rather
    -- than only on the next connect, which puts the dev command's local override
    -- in front of a case it previously only met after a reconnect. If this
    -- block fails, the owner cannot test the walkthrough twice in one session.
    connect(true)
    TriggerEvent('br:tutorial:game', true, false)
    TriggerEvent('br:tutorial:game', false, true)
    ok(published('offerable') == false, 'the account has finished it')

    ok(commands.brtutorial ~= nil, 'the dev command is registered')
    commands.brtutorial(nil, {})
    ok(published('offerable') == true,
       'AND /brtutorial PUTS IT BACK LOCALLY -- the row still says done and is '
       .. 'untouched; this raises the client\'s mirror so the lobby draws',
       'offerable = ' .. tostring(published('offerable')))
end

-- ------------------------------------------------------------------ report ---

if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m, %d passed'):format(fail, pass))
    os.exit(1)
end
realPrint(('\27[32mok\27[0m   %d assertions: finishing spends the account\'s '
    .. 'offer, so does a first match nobody took it into, abandoning does '
    .. 'neither, and /brtutorial still outranks all three')
    :format(pass))

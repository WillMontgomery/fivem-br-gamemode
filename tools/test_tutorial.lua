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

--- The loop registry, stubbed to a sink.
---
--- tutorial.lua registers two loops at load -- the leave tick and the arrow-key
--- frame pass -- and neither is driven here. Registering them into a table that
--- nothing steps is the honest version of that: the file loads exactly as it
--- ships, and no block below can accidentally depend on a tick it never pumped.
BR.Loop = {
    TICK = 'tick', FRAME = 'frame',
    register = function() end,
}

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
    .. 'offer, abandoning does not, and /brtutorial still outranks both')
    :format(pass))

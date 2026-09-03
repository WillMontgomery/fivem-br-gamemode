-- Unit tests for the squad's revive key (#219 step 4).
--
-- ═══ WHY THIS IS ITS OWN SUITE, AND WHAT IS DELIBERATELY NOT IN IT ═══
--
-- THE ONE RULE THIS FILE CANNOT ASSERT IS THE MOST IMPORTANT ONE. "The key is
-- minted on the same edge that spills the inventory" is a property of
-- server/combat.lua, not of server/revivekey.lua -- so it is asserted in
-- tools/test_roster.lua's `combat.revivekey`, where the real eliminate() runs
-- against the real roster, the real loot table and the real #144 hold. A
-- sandbox that called BR.ReviveKey.onEliminated by hand would be testing that
-- this file does what it is told, which is not the question.
--
-- WHAT IS HERE is everything downstream of the mint, and all of it is awkward to
-- reach from a live match: a three-minute expiry, a squadmate walking the last
-- 2.5 metres, a DynamoDB round trip that another elimination lands inside, and
-- two squadmates pressing buy in the same second. Every one of those is minutes
-- of a playtest and three lines here.
--
-- ═══ THE CASE THIS SUITE EXISTS FOR, IF YOU READ ONE ═══
--
-- THE SUBJECT MUST NOT COLLECT THEIR OWN KEY. An eliminated player's `pos` IS
-- the key's position -- they are spectating from the body it was minted at --
-- so the distance from the corpse to the key it left is zero, for ever. Get
-- this wrong and every key in the game collects itself on the tick after it is
-- minted, every squad silently holds every key for free, and a solo playtester
-- sees a feature that works perfectly. It is the one defect here that is
-- invisible from inside the game.
--
-- ⚠ TWO INDEPENDENT GUARDS STOP IT, AND EITHER ALONE IS SUFFICIENT -- the
-- collector filter admits only ALIVE, and the inner loop skips `mv.src == src`.
-- That is worth knowing before reading the assertion below, because it means
-- REMOVING EITHER ONE ON ITS OWN LEAVES THIS SUITE GREEN. Measured, not
-- assumed: both single-guard mutations were run and both stayed green; the
-- combined one goes red. So the assertion here pins the BEHAVIOUR and the
-- redundancy is the belt-and-braces, rather than the assertion pinning one
-- guard that somebody could then delete believing a test covers it.

local fakeTime = 0
function GetGameTimer() return fakeTime end

--- The module's console lines, captured rather than printed.
---
--- server/revivekey.lua narrates every mint, collection, expiry and purchase --
--- which is what a playtest log is for and is exactly wrong in a gate that runs
--- twenty-five suites. tools/test_roster.lua does the same thing for the same
--- reason; `realPrint` is what this file's own output goes through.
---
--- KEPT RATHER THAN DISCARDED, and bounded, so a failing assertion can still be
--- read against what the module said it was doing.
local realPrint = print
local PRINT_KEEP = 256
local printed = {}
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, '\t')
    if #printed > PRINT_KEEP then table.remove(printed, 1) end
end

local RES = 'resources/[fivem-royale]/'
local ROOT = RES .. 'br_lib/'
local function loadAt(root, f)
    local chunk, err = loadfile(root .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local function load(f) loadAt(ROOT, f) end
--- A br_core module, by its path under resources/[fivem-royale]/.
local function loadCore(f) loadAt(RES, f) end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',        -- BR.Dist, which both the collect and reach tests use
    'shared/protocol.lua',   -- BR.Net, for the handler driven below
    -- BR.Notice. Four of the owner's nine lines have a `%s` in them and `say`
    -- fills the holes through BR.Notice.line, so the module cannot speak at all
    -- without this.
    'shared/notice.lua',
    -- BR.Clock.words. The bled-out toast names the pickup's own duration out
    -- loud since 2026-09-02 ("mention that the key expires and after how long"),
    -- and it reads it off `expiryMs` through this rather than spelling three
    -- minutes into the sentence -- so server/revivekey.lua cannot mint a key
    -- without it.
    'shared/clock.lua',
    -- BR.ShopSolve.signHeight, which is the ONE derivation behind how high a
    -- plate hangs on a VEHICLE. (The plate over a key on the ground used to come
    -- through it too, minus the vehicle's origin; since 2026-09-02 it is
    -- anchored to its marker instead -- "It should be inside the 3dmarker" --
    -- and is executed in `plate.config` below.)
    'shared/shop_solve.lua',
    'config/match.lua',
    'config/overrides.lua',
    'config/storm.lua',
    'config/map.lua',
    'config/loot.lua',
    'config/rescue.lua',     -- the `models` list config/revivekey.lua reads
    'config/revivekey.lua',
}) do load(f) end

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

local K = BR.Config.ReviveKey

-- ---------------------------------------------------------------------------
describe('config')
do
    -- THE OWNER'S TWO NUMBERS, 2026-08-30. Both supersede #219's body, which was
    -- written a week earlier and says 150 Volts and nothing about expiry -- so
    -- these are asserted against his message rather than against the issue.
    ok(K.expiryMs == 180000, 'the pickup lives three minutes', K.expiryMs)
    ok(K.price == 25, 'and a key costs 25 Volts, not the 150 in the issue body',
        K.price)
    ok(K.buysAll == true,
        'and one purchase covers all of the squad\'s outstanding keys')

    -- ONE LIST FOR "AMBULANCE", SHARED WITH THE OTHER TWO FEATURES. If somebody
    -- ever pastes a model name into config/revivekey.lua, this feature starts
    -- disagreeing with the rescue and the heal about what a player is standing
    -- next to -- and the symptom is a purchase refused at a van two other
    -- features are happy to use.
    ok(BR.Config.ReviveKey.models() == BR.Config.Rescue.models,
        'and "what counts as an ambulance" is config/rescue.lua\'s one list, '
            .. 'not a copy of it')

    -- ═══ EVERY WORD IS IN ONE TABLE, AND THERE ARE EXACTLY NINE OF THEM ═══
    --
    -- #219 Q20 used to be unanswered and this suite used to assert the config
    -- held NO strings at all. The owner answered it on 2026-08-30 with a list of
    -- six lines and an instruction to stop waiting on him, and on 2026-08-31 he
    -- rewrote the collection half himself: he renamed the pickup plate and wrote
    -- the four sentences the mint, the collection and the revive now say. So the
    -- rule inverted rather than lapsed: the nine are pinned VERBATIM and a tenth
    -- is a failure.
    --
    -- WHY VERBATIM. These are his words. A tidy-up that turned "Buy revive keys
    -- — 25 Volts" into "Buy revive keys (25 Volts)" would be an agent editing
    -- the owner's copy -- the exact thing the standing rule forbids -- and it
    -- would not error anywhere. The four new ones are the likeliest to be
    -- "improved": `revived` joins its clauses with a HYPHEN where this project's
    -- house style is an em dash, and it is a hyphen because he typed one.
    --
    -- `%s` IS HIS `[player]`. He wrote the hole as `[player]` in prose; it is
    -- `%s` in the table because that is the hole BR.Notice.line fills. That the
    -- name ends up OUTSIDE the string is driven in `notify` below, against the
    -- real module.
    local C = K.copy
    ok(type(C) == 'table', 'the wording lives in one table')
    if type(C) == 'table' then
        local want = {
            take        = 'Collect revive key',
            buy         = 'Buy revive keys — 25 Volts',
            -- ═══ THE TENTH LINE, AND THE REWRITE THAT CAME WITH IT ═══
            --
            -- Owner, 2026-09-01: "The ambulance DUI should say 'Revive your
            -- squad' and the line under (in the smaller lighter font) should say
            -- 'PRESS AND HOLD' instead of including the player's name."
            --
            -- `reviveHold` IS PINNED IN CAPITALS AND THAT IS THE ASSERTION.
            -- dui/prompt.html sets `text-transform: uppercase` on the small
            -- line, so 'Press and hold' would look IDENTICAL on screen and no
            -- playtest could ever catch the difference -- which makes this the
            -- one line in the table whose only guard is here.
            revive      = 'Revive your squad',
            reviveHold  = 'PRESS AND HOLD',
            -- ═══ AND THE ONE HE ASKED TO SAY MORE, 2026-09-02 ═══
            --
            -- "Perhaps the 'grab their key!' toast should also mention that the
            -- key expires and after how long."
            --
            -- ⚠ `within %s` IS NOT HIS WORDING. He gave the fact and not the
            -- sentence, and this is the smallest insertion that carries it --
            -- his clause order, his two doors, his exclamation marks. It is
            -- pinned here so that when he corrects it there is exactly one
            -- other place to change.
            --
            -- THE SECOND HOLE IS A DURATION AND THE FIRST IS A NAME, which is
            -- the thing to get right if this line is ever rewritten: the toast
            -- reads them positionally (BR.Notice.line), so swapping them would
            -- bold three minutes and print a player's name as a deadline.
            bledOut     = '%s has bled out! Get their revive key within %s or '
                          .. 'purchase it at an ambulance!',
            collect     = "You've collected %s's revive key. Get to an "
                          .. "ambulance to revive them!",
            collectedBy = "%s picked up %s's revive key! Get to an ambulance "
                          .. "to revive them.",
            revived     = '%s revived %s - they are back in!',
            bought      = 'Revive keys bought',
            expired     = 'Revive key lost',
        }
        local n = 0
        for k, v in pairs(C) do
            n = n + 1
            ok(want[k] == v,
                ('copy.%s is the owner\'s line, character for character'):format(k),
                v)
        end
        ok(n == 10,
            'and there are TEN and no more -- an eleventh line is a question for '
                .. 'the owner, not a string to write', n)

        -- THE RENAME, ASSERTED AS A RENAME. Owner, 2026-08-31: the plate becomes
        -- "Collect revive key" "to be consistent with the terminology of the
        -- toast which reads 'Revive key collected'". The plate word and the
        -- toast's verb are a PAIR, and the pair is what would silently come
        -- apart -- either half can be edited alone and still read fine.
        ok(C.collect ~= nil and C.collect:find('collected', 1, true) ~= nil,
            'the toast the plate was renamed to match still says collected',
            C.collect)
        ok(C.collected == nil,
            'and the old whole-squad `Revive key collected` is gone -- he wrote '
                .. 'one sentence for the collector and another for the rest of '
                .. 'the squad, and keeping it would send two toasts for one '
                .. 'event')

        -- TWO HOLES MEANS TWO PEOPLE. Getting them the wrong way round still
        -- reads as a sentence, which is exactly why the ORDER is driven below
        -- rather than only read here.
        local _, holesBy = C.collectedBy:gsub('%%s', '')
        local _, holesRv = C.revived:gsub('%%s', '')
        ok(holesBy == 2, 'collectedBy names two people', holesBy)
        ok(holesRv == 2, 'and so does revived', holesRv)
    end

    -- ═══ AND NOTHING SPEAKS FROM ANYWHERE BUT THAT TABLE ═══
    --
    -- The point of `copy` is that he can rewrite everything this feature says by
    -- editing one screen. A loose `prompt` or `label` at the top level would be
    -- a second place to look and a second place to drift.
    for _, k in ipairs({ 'prompt', 'label', 'text', 'toast', 'notify',
                         'pickupText', 'boughtText' }) do
        ok(K[k] == nil,
            ('config/revivekey.lua has no top-level `%s` -- every string this '
                .. 'feature speaks is in `copy` and nowhere else'):format(k))
    end

    -- ═══ THE REVIVE IS AT AN AMBULANCE, SO IT HAS NO REACH OF ITS OWN ═══
    --
    -- Owner, 2026-08-30: "I should be able to walk up to an ambulance and see a
    -- DUI to press something to revive them", and "the press e to revive DUI
    -- when standing at the ped should not show once they've bled out. The only
    -- option at that point is the ambulance."
    --
    -- THE PAIR THAT USED TO MEASURE A HOLD AT THE KEY'S POINT IS GONE, and their
    -- absence is asserted rather than merely unused: a `reviveReachM` left in
    -- this table would be a second answer to "am I at the van", sitting beside
    -- `reachM`, waiting for somebody to tune the wrong one.
    ok((tonumber(K.reviveHoldMs) or 0) > 0, 'the hold has a duration', K.reviveHoldMs)
    ok(K.reviveReachM == nil and K.reviveSlackM == nil,
        'and NO reach of its own -- the hold happens at an ambulance, so it is '
            .. 'ruled with `reachM`, the radius the purchase already uses at the '
            .. 'same van',
        ('%s / %s'):format(tostring(K.reviveReachM), tostring(K.reviveSlackM)))
    ok((tonumber(K.reachM) or 0) > 0 and (tonumber(K.reachSlackM) or 0) > 0,
        'and that radius exists, with the slack every other position check in '
            .. 'this project rules with',
        ('%s + %s'):format(K.reachM, K.reachSlackM))

    -- ═══ AND THE PICKUP IS A PRESS, SO IT NEEDS SLACK TOO ═══
    --
    -- New with the prompt. While collection was a server-side proximity test
    -- there was nothing to reconcile -- the server was the only thing measuring.
    -- A press is a claim about where the player was a moment ago.
    ok((tonumber(K.collectSlackM) or 0) > 0,
        'the pickup press is ruled with slack on top of `collectM`, so a press '
            .. 'that was legitimate when it was made is not refused by a stale '
            .. 'sample', K.collectSlackM)

    -- ═══ THE ARRIVAL'S THREE NUMBERS ═══
    --
    -- "put them 150m above the ambulance" is the owner's, verbatim. The other
    -- two are ours and are flagged as such in the config; what is asserted here
    -- is that they EXIST, because the server spends fadeMs + focusMs of black
    -- before it processes anything and a nil would collapse that wait to zero.
    -- ═══ THE MARKER THAT REPLACES THE CORPSE ═══
    --
    -- Owner, 2026-08-31: "After a player has bled out, their ped should become
    -- invisible. Only the 3dmarker (type 24) and DUI should be shown at their
    -- position. I like the blip though - let's keep that."
    --
    -- 24 IS HIS NUMBER AND IS PINNED AS ONE. Every other value in this table is
    -- ours and is asserted only to exist; this one he wrote down, so a change to
    -- it should have to come through here.
    ok(type(K.marker) == 'table', 'the ground marker has a config block')
    ok(K.marker and K.marker.kind == 24,
        'and it is type 24, which is the number the owner gave',
        K.marker and tostring(K.marker.kind))

    -- IT MUST OUTRANGE THE PLATE, AND BY A LOT. The whole reason it exists is
    -- that hiding the body removed the only world-space thing that said where
    -- the key was, and the plate does not appear until `collectM` -- 2.5m. A
    -- marker drawn at the same radius would arrive exactly when it had stopped
    -- being needed.
    ok((tonumber(K.marker and K.marker.drawM) or 0) > (tonumber(K.collectM) or 0),
        'and it is drawn from much further away than the plate it leads to',
        ('%s vs %s'):format(tostring(K.marker and K.marker.drawM),
                            tostring(K.collectM)))

    -- LIFTED OFF THE GROUND. `rec.z` is the ground the body was lying on and a
    -- marker drawn exactly on it z-fights the terrain, which reads as flicker
    -- rather than as a number being wrong.
    ok((tonumber(K.marker and K.marker.lift) or 0) > 0,
        'and it stands off the ground rather than z-fighting it',
        K.marker and tostring(K.marker.lift))

    ok(K.dropM == 150.0, 'they arrive 150m up, which is his number', K.dropM)
    ok((tonumber(K.fadeMs) or 0) > 0, 'behind a fade with a duration', K.fadeMs)
    ok((tonumber(K.focusMs) or 0) > 0,
        'and a focus hold, so the ground under the van is streamed in before '
            .. 'anybody is standing over it', K.focusMs)

    for _, k in ipairs({ 'parachute', 'maxRevives', 'landingHp' }) do
        ok(K[k] == nil,
            ('config/revivekey.lua has no `%s` -- the parachute is skydive.lua\'s '
                .. 'whole drop machine and the health is dbnoReviveHp, so there '
                .. 'is nothing for it to describe'):format(k))
    end

    -- ═══ AND `reviveHp` IS FULL, WHICH IS THE ONE WORTH ASSERTING ═══
    --
    -- Owner, 2026-08-31: "when a revive is processed using the key, the player
    -- should come back with full health."
    --
    -- THIS BLOCK USED TO ASSERT THE OPPOSITE -- that there was NO `reviveHp` and
    -- that a key revive handed back BR.Config.Match.dbnoReviveHp "because it is
    -- the same act". His sentence says it is not the same act. The old
    -- assertion's fear was two numbers drifting apart; they are SUPPOSED to
    -- differ now, so the PAIR is what is pinned instead -- including the 30,
    -- which he did not touch and which a tidy-up sharing one constant would
    -- silently move to 100.
    ok(K.reviveHp == 100,
        'a key revive hands back full health, which is his number', K.reviveHp)
    ok(BR.Config.Match.dbnoReviveHp == 30,
        'and the in-person DBNO revive still hands back 30 -- he named one of '
            .. 'the two and the other did not move', BR.Config.Match.dbnoReviveHp)
    ok(K.reviveHp ~= BR.Config.Match.dbnoReviveHp,
        'so they are two different numbers on purpose, which is what makes a '
            .. 'key worth the death it costs')
end

-- ---------------------------------------------------------------------------
describe('plate.face')
do
    -- ═══ "A DUI THAT SHOWS ON THE NEAREST FACE OF THE VEHICLE" ═══
    --
    -- Owner, 2026-08-31. The client half of that is BR.Dui.drawNearFace; the
    -- RULE it draws from is BR.NearestBoxFace, which is arithmetic and is the
    -- whole of what "which face" means.
    --
    -- THE GEOMETRY *IS* EXECUTED, AND NOT HERE. This note used to say
    -- drawNearFace "cannot be executed outside the game". That was wrong:
    -- tools/test_shop.lua stands client/dui.lua on a stubbed car and reads the
    -- corners back out of DrawSpritePoly, and its section 7b drives this very
    -- function -- including the lateral the owner asked for on 2026-09-01, on
    -- two different faces. What stays here is the face RULE and the numbers this
    -- feature hands over; what the drawing does with them is proved there.
    --
    -- IT IS ASSERTED HERE RATHER THAN IN test_shared.lua because this is the
    -- feature that asked for it and this is the suite that would be read the day
    -- the plate comes up on the wrong panel.
    --
    -- THE AXES: +Y is the van's nose, +X its right flank, and the box is the
    -- model's own. These numbers are an ambulance's shape rather than its exact
    -- box -- about 2.4m across and 6m long -- because what is being pinned is
    -- the rule, and a box read off a live model would make the suite depend on
    -- an asset.
    local MINX, MAXX, MINY, MAXY = -1.2, 1.2, -3.0, 3.0

    -- Standing at the driver's door: a metre out from the LEFT flank, level with
    -- the middle of the van. This is the case in his sentence.
    local ux, uy, reach = BR.NearestBoxFace(-2.0, 0.0, MINX, MAXX, MINY, MAXY)
    ok(ux == -1.0 and uy == 0.0,
        'standing at the driver\'s door puts the plate on the driver\'s side',
        ('%s, %s'):format(ux, uy))
    ok(reach == 1.2,
        'and it stands off the PANEL -- the reach is the distance from the '
            .. 'van\'s origin out to that flank', reach)

    -- ...and walking round the back moves it to the back.
    ux, uy, reach = BR.NearestBoxFace(0.0, -4.5, MINX, MAXX, MINY, MAXY)
    ok(ux == 0.0 and uy == -1.0 and reach == 3.0,
        'walking round to the back doors moves it to the tail',
        ('%s, %s, %s'):format(ux, uy, reach))

    ux, uy = BR.NearestBoxFace(0.0, 4.0, MINX, MAXX, MINY, MAXY)
    ok(ux == 0.0 and uy == 1.0, 'standing at the bonnet puts it on the nose',
        ('%s, %s'):format(ux, uy))

    ux, uy = BR.NearestBoxFace(2.5, 1.0, MINX, MAXX, MINY, MAXY)
    ok(ux == 1.0 and uy == 0.0, 'and at the passenger wing, on that flank',
        ('%s, %s'):format(ux, uy))

    -- ═══ THE ASSERTION THE WHOLE ROUND IS ABOUT ═══
    --
    -- THE SAME PLAYER, IN THE SAME SPOT, GETS A DIFFERENT FACE ON A DIFFERENT
    -- MODEL -- which is what "use the vehicle's own dimensions so it is correct
    -- for a model this code has never seen" means, and the one property a
    -- constant tuned against the shipped ambulance would fail.
    --
    -- Two and a half metres back and two metres out: BESIDE a six-metre van
    -- (still well inside its length) and BEHIND a three-metre one.
    local lx, ly = -2.0, -2.5
    ux, uy = BR.NearestBoxFace(lx, ly, MINX, MAXX, MINY, MAXY)
    ok(ux == -1.0 and uy == 0.0,
        'beside a long van, that spot is the flank', ('%s, %s'):format(ux, uy))
    ux, uy = BR.NearestBoxFace(lx, ly, MINX, MAXX, -1.5, 1.5)
    ok(ux == 0.0 and uy == -1.0,
        'and behind a short one, the same spot is the tail -- the face is read '
            .. 'off the MODEL, not off a number tuned to the ambulance',
        ('%s, %s'):format(ux, uy))

    -- ═══ AN ORIGIN THAT IS NOT THE CENTRE OF THE BOX ═══
    --
    -- GetModelDimensions is a box, not a half-width, and plenty of models hang
    -- further one way than the other. A plate placed at half the box's width
    -- would be inside the bodywork on the long side and floating on the short
    -- one -- and it would look perfectly right on any symmetric test.
    ux, uy, reach = BR.NearestBoxFace(3.0, 0.0, -1.0, 1.4, MINY, MAXY)
    ok(ux == 1.0 and reach == 1.4,
        'a model whose origin sits off centre reaches further to its wide side',
        reach)
    ux, uy, reach = BR.NearestBoxFace(-3.0, 0.0, -1.0, 1.4, MINY, MAXY)
    ok(ux == -1.0 and reach == 1.0, 'and less far to its narrow one', reach)

    -- ═══ THE MODEL THAT HAS NOT ANSWERED ═══
    --
    -- GetModelDimensions hands back zeroes for a model that is not loaded, which
    -- happens for a frame or two as a van streams in. A plate at the origin is a
    -- plate slightly in the wrong place; nan corners are a hole in the world.
    ux, uy, reach = BR.NearestBoxFace(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    ok(ux == 0.0 and uy == 1.0 and reach == 0.0,
        'a box of zeroes answers the nose at zero reach rather than nothing',
        ('%s, %s, %s'):format(ux, uy, reach))
    ok(reach == reach, 'and no nan reaches the draw', reach)
end

-- ---------------------------------------------------------------------------
describe('plate.config')
do
    -- ═══ THE FIVE NUMBERS THE OWNER IS GOING TO MEASURE ═══
    --
    -- "If you want to make me the tools to manipulate the DUI position then
    -- fetch it I can give you the coords" (2026-08-31). /brplate prints these
    -- five in the shape of this table so the answer is one paste.
    --
    -- THE FIFTH IS `side` AND HE ASKED FOR IT: "I need to be able to move it
    -- left/right as well. in/out and up/down are great but can't do left/right
    -- right now" (2026-09-01).
    --
    -- ═══ AND SINCE 2026-09-02 IT IS FIVE PER FACE, WHICH IS WHAT HE SENT ═══
    --
    -- He walked round an ambulance with /brplate and pasted four blocks -- one
    -- for each of `left`, `nose`, `right` and `tail`, which are the four words
    -- BR.Dui.nearFace's answer is named by and the four keys the client looks a
    -- set up under.
    --
    -- WHAT IS PINNED IS THE SHAPE AND THE FACES, NOT THE VALUES. The numbers are
    -- his now, so a suite asserting them would be a suite that has to be edited
    -- every time he refines one -- and the tool exists so he can. What would
    -- actually break the plate is a number arriving as a string, a face key the
    -- client never looks up, or a face going missing so its panel silently falls
    -- back to the untuned defaults.
    local P = K.plate
    ok(type(P) == 'table', 'the plate\'s position lives in one table', type(P))
    if type(P) == 'table' then
        local faces = { 'left', 'nose', 'right', 'tail' }
        local wantFace = {}
        for _, f in ipairs(faces) do wantFace[f] = true end

        local nf = 0
        for k, set in pairs(P) do
            nf = nf + 1
            ok(wantFace[k] == true,
                ('plate.%s is one of the four faces the client resolves'):format(k))
            ok(type(set) == 'table',
                ('and plate.%s is a set of five rather than a bare number -- '
                 .. 'the flat table was one panel\'s numbers on four panels')
                    :format(k), type(set))
        end
        ok(nf == 4, 'four faces, no more', nf)

        for _, f in ipairs(faces) do
            local set = P[f]
            ok(type(set) == 'table',
                ('plate.%s is present -- a missing face draws at the untuned '
                 .. 'fallbacks, which looks like the plate having moved on its '
                 .. 'own'):format(f))
            if type(set) == 'table' then
                local want = {
                    out = true, side = true, frac = true, lift = true,
                    width = true,
                }
                local n = 0
                for k, v in pairs(set) do
                    n = n + 1
                    ok(want[k] == true,
                        ('plate.%s.%s is one of the five the client reads')
                            :format(f, k))
                    ok(type(v) == 'number',
                        ('and plate.%s.%s is a number rather than a string')
                            :format(f, k), tostring(v))
                end
                ok(n == 5, ('five in plate.%s, no more'):format(f), n)

                -- A width of zero draws nothing at all, and a negative one
                -- draws a mirrored plate: BR.Dui.drawNearFace refuses both, so
                -- this is the config saying the same thing where it can be seen.
                ok((tonumber(set.width) or 0) > 0,
                    ('plate.%s has a width'):format(f), set.width)

                -- ⚠ `out` IS NOT HELD TO BEING POSITIVE ANY MORE, AND THAT IS
                -- HIS CHANGE RATHER THAN A LOOSENING. This suite used to assert
                -- `out >= 0` -- "it stands off the panel rather than inside it"
                -- -- and all four of the numbers he measured are NEGATIVE: a
                -- quad standing proud of an ambulance's slab side read as
                -- floating beside the van, and he brought every one of them in.
                -- Asserting the old sign would now fail on his own approved
                -- numbers, which is the assertion being wrong rather than the
                -- config. `side` is signed for the same kind of reason -- the
                -- left of a panel is half the axis he asked for.
                ok(tonumber(set.out) ~= nil and tonumber(set.side) ~= nil,
                    ('plate.%s\'s out and side are both signed numbers -- '
                     .. 'negative `out` is inside the bodywork and negative '
                     .. '`side` is the left of the panel, and both are his')
                        :format(f),
                    ('out %s side %s'):format(tostring(set.out),
                                              tostring(set.side)))
            end
        end

        -- ═══ AND THE ASYMMETRY IS DELIBERATE, WHICH IS WORTH A TEST OF ITS OWN
        --     ═══
        --
        -- `left.side` is 1.620 and `right.side` is -2.220. That looks like a
        -- typo for a mirrored pair and it is not: an ambulance's model origin is
        -- not on its centreline, so the same place on the bodywork is a
        -- different distance along from either flank. The likeliest "fix"
        -- anybody makes to this table is averaging them, so the difference is
        -- pinned rather than left to a comment.
        local l = P.left and tonumber(P.left.side)
        local r = P.right and tonumber(P.right.side)
        ok(l ~= nil and r ~= nil and math.abs(math.abs(l) - math.abs(r)) > 0.1,
            'the two flanks are NOT mirror images of each other -- the model '
                .. 'origin is off centre, so tidying these into a matched pair '
                .. 'moves a plate the owner has already approved',
            ('left %s right %s'):format(tostring(l), tostring(r)))
    end

    -- ═══ "INSIDE THE 3DMARKER", WHICH IS THE FOURTH ANSWER AND A DIFFERENT
    --     KIND OF ANSWER ═══
    --
    -- Owner, 2026-09-02: "The 'pickup key' DUI is still... again.... way too
    -- high off the ground. I've stated this 3 times now. It should be inside the
    -- 3dmarker, which should also be made about 25% taller btw."
    --
    -- THE PREVIOUS THREE WERE ALL NUMBERS -- 1.1, then 0.6, then the ambulance
    -- plate's own `frac`/`lift` with the van's origin subtracted out, which was
    -- derived and still put the plate ~1.5m over a marker lying on the floor.
    -- The suite used to execute that subtraction here. What it executes now is
    -- the property that replaced it: the plate's height is a function of the
    -- MARKER'S OWN two numbers and of nothing else, so the two cannot separate.
    do
        local Mk = K.marker

        -- `markerBand` in client/revivekey.lua is `lift, height`; the plate is
        -- `lift + height * 0.5`. Written out here rather than called, because
        -- there is no client state in this harness to call it in -- the source
        -- pin in `describe('source')` is what ties this arithmetic to that file.
        local function mid(lift, tall) return lift + tall * 0.5 end

        local lift = tonumber(Mk and Mk.lift) or 0.06
        local tall = tonumber(Mk and Mk.height) or 0.4
        local z = mid(lift, tall)

        -- INSIDE THE BAND, WHICH IS THE OWNER'S WORD. The marker occupies
        -- [lift, lift + height] above the key's own z, and the plate is in it.
        ok(z > lift and z < lift + tall,
            'the plate over a loose key is INSIDE the marker\'s own vertical '
                .. 'band rather than above it, which is the whole of the '
                .. 'owner\'s fourth report',
            ('%.3f in (%.3f, %.3f)'):format(z, lift, lift + tall))

        -- IT MOVES WITH THE MARKER. A taller marker takes the plate up with it
        -- and a marker lifted off the terrain takes it up one for one -- which
        -- is the property the three previous answers each claimed and none had,
        -- because each was pinned to something the marker knows nothing about.
        ok(mid(lift, tall * 2.0) > z and mid(lift + 1.0, tall) == z + 1.0,
            'and it is a function of the marker\'s own lift and height, so '
                .. 'resizing or raising the marker moves the plate with it and '
                .. 'there is no second number to edit')

        -- AND IT IS UNDER A METRE. Not a tuning assertion -- a regression one.
        -- Every rejected answer to this report was over a metre off the ground,
        -- and 1.1, 0.6 and ~1.5 are all numbers somebody could reintroduce
        -- believing they were derived. A marker is ankle height.
        ok(z < 1.0,
            'and it is a marker height off the ground rather than the metre-plus '
                .. 'every rejected answer put it at', ('%.3f m'):format(z))
    end

    -- ═══ AND THE MARKER IS THE ONE HE ASKED FOR, 25% TALLER ═══
    --
    -- ⚠ `height` IS THE AXIS AND `size` IS NOT. DrawMarker takes (scaleX,
    -- scaleY, scaleZ) and the pass spends `size, size, height` -- so `size` is
    -- metres ACROSS on both horizontal axes and `height` is the vertical one on
    -- its own. Raising `size` for "taller" makes a wider marker, which is the
    -- mistake this pins: the two are asserted in opposite directions so an edit
    -- that moves the wrong one fails rather than passing quietly.
    ok(math.abs((tonumber(K.marker and K.marker.height) or 0) - 0.5) < 1e-9,
        'the marker is 0.5m tall -- 0.4 raised by the owner\'s 25%',
        tostring(K.marker and K.marker.height))
    ok(math.abs((tonumber(K.marker and K.marker.size) or 0) - 0.8) < 1e-9,
        '...and `size` is untouched, because scaleX/scaleY is how WIDE it is '
            .. 'and he asked for taller rather than bigger',
        tostring(K.marker and K.marker.size))
end

-- ---------------------------------------------------------------------------
describe('source')
do
    -- ═══ NO PLAYER-FACING COPY IN THE SERVER FILE EITHER ═══
    --
    -- The config assertions above stop a string being ADDED to the config; this
    -- stops one being written straight into the module. #219 Q20 is unanswered
    -- and the owner's rule is that copy he did not ask for reads as slop, so the
    -- only sentence this feature may speak is the market's own shortfall line --
    -- which BR.Market.charge speaks, inside the market, and which already
    -- existed for exactly this fact.
    --
    -- ═══ IT RUNS HERE, BEFORE THE MODULE IS LOADED, AND THAT IS DELIBERATE ═══
    --
    -- This suite's BR.Server stub has no `notify` -- so a notify call added to
    -- the module would THROW inside the buy callback three hundred lines below
    -- and take the whole suite down with a traceback instead of a named
    -- assertion. A crash is a red build, so the rule would still be enforced,
    -- but the report would say "attempt to call a nil value" rather than "there
    -- is no wording for this feature". Read before load, it fails as itself.
    local fh = io.open(RES .. 'br_core/server/revivekey.lua', 'r')
    ok(fh ~= nil, 'the server module is readable')
    local moduleSrc = fh and fh:read('a') or ''
    if fh then fh:close() end

    -- Strip comments, so the prose ABOUT notifying does not read as notifying.
    local code = moduleSrc:gsub('%-%-[^\n]*', '')

    -- ONE NOTIFY CALL SITE, AND IT TAKES ITS TEXT AS AN ARGUMENT. `say()` is the
    -- only path from this module to a player's screen. The behavioural half --
    -- that every string leaving it is a member of BR.Config.ReviveKey.copy -- is
    -- asserted in `notify` below, against the real module and a capturing stub;
    -- this half stops a SECOND call site with a literal in it, which is how
    -- invented copy ships wearing the owner's authority.
    -- `notify%(` AND NOT `notify`, because `say()` names it twice: once in the
    -- nil-guard that keeps this module loading on a build with no broadcast
    -- half, and once to call it. The open paren is what makes this count CALL
    -- SITES rather than mentions.
    local _, notifies = code:gsub('BR%.Server%.notify%(', '')
    ok(notifies == 1,
        'server/revivekey.lua reaches a player through exactly one notify call '
            .. 'site -- every word it speaks comes out of the config table',
        notifies)

    -- AND NO NAME IS EVER FORMATTED INTO ONE OF HIS LINES. Four of them have
    -- `%s` holes, and the tempting way to fill one is
    -- `(copy().collect):format(name)` at the call site -- which puts the
    -- player's name INSIDE the string and silently deletes the bold, because
    -- the page can only draw a name it was handed as its own part. `say` takes
    -- the values as varargs and BR.Notice.line does the splitting; a `:format(`
    -- on a copy line is the shape that regresses it, and it would look right.
    ok(code:find('copy%(%)%.%w+%s*%)?%s*:%s*format') == nil,
        'and no call site formats a name INTO one of his lines -- the values go '
            .. 'to BR.Notice.line as arguments, which is what keeps the name '
            .. 'bold and keeps it out of any string a parser touches')
    ok(code:find('function say%(who, line, tone, %.%.%.%)') ~= nil,
        'and that call site takes its text AND its names as arguments rather '
            .. 'than holding either')

    -- ═══ IT WRITES EXACTLY ONE PLAYER STATE, AND IT IS ALIVE ═══
    --
    -- This suite used to assert the module wrote NO state at all, because
    -- resurrection was step 5 and step 5 did not exist. It does now. What has
    -- not changed is that a state write from here reaches client/natives.lua's
    -- invincibility latch, which is derived from the player state and nothing
    -- else -- so the assertion narrows rather than lapsing: the only transition
    -- this file may author is the one back into the match.
    local _, states = code:gsub('Roster%.setState', '')
    ok(states == 1, 'it writes exactly one player state', states)
    ok(code:find('setState%(src, BR%.PlayerState%.ALIVE%)') ~= nil,
        'and that state is ALIVE -- nothing here eliminates, downs or benches '
            .. 'anybody')

    -- ═══ AND IT NEVER SENDS BR.Net.REVIVED ═══
    --
    -- That event stands a body up at `GetEntityCoords(ped)` -- exactly where it
    -- is lying, no placement at all -- which is #144's held death and the
    -- OPPOSITE of what the owner asked for here. It is asserted absent rather
    -- than merely unused because the two events do the same four native calls
    -- and differ only in where: a revert to REVIVED would resurrect everybody
    -- correctly, at their corpse, and look like the feature working.
    ok(code:find('BR%.Net%.REVIVED') == nil,
        'the module never sends BR.Net.REVIVED -- a key revive is an ARRIVAL '
            .. 'somewhere, and REVIVED is the resurrection that goes nowhere')
    ok(code:find('BR%.Net%.REVIVEKEY_PLACE') ~= nil,
        'it sends REVIVEKEY_PLACE, which carries the ambulance')

    -- ═══ THE CLIENT'S TWO PLATES, PINNED AS TEXT BECAUSE NO SUITE DRIVES THEM ═══
    --
    -- Both are things the owner reported by playing, both are one word in one
    -- table, and neither is reachable from a Lua harness -- there is no client
    -- state here to run a frame pass in. These are TEXT PINS and they are meant
    -- to be: if somebody renames the local they should come and read this note,
    -- because the two lines they are about are the two lines this round exists
    -- for.
    local ch = io.open(RES .. 'br_core/client/revivekey.lua', 'r')
    local clientSrc = ch and ch:read('a') or ''
    if ch then ch:close() end
    local clientCode = clientSrc:gsub('%-%-[^\n]*', '')

    -- "the press e to revive DUI when standing at the ped should not show once
    --  they've bled out. The only option at that point is the ambulance."
    ok(clientCode:find('if heldSrc and veh then') ~= nil,
        'the client offers a revive only when it has found an AMBULANCE -- there '
            .. 'is no arrangement of a body and a player that draws a revive '
            .. 'plate over a corpse')

    -- "I somehow picked up the dead player's key by walking up to them without
    --  seeing a DUI or pressing anything."
    ok(clientCode:find("mode = 'take', id = c%.id,\n%s*label = e and e%.name or nil, hint = C%.take, press = true") ~= nil,
        'and the take plate carries a press, so it draws a key cap and the '
            .. 'player has to mean it')

    -- ═══ A THIRD PIN, AND IT HAS NOW MOVED TWICE ═══
    --
    -- "the 'take revive key' DUI over a corpse is way too high off the ground"
    -- put a constant of this file's own under the loose key, and this suite once
    -- asserted the two plates MAY NOT share a number. On 2026-09-01 he asked for
    -- the opposite -- "it should be the same elevation as the 'press E to
    -- revive' DUI" -- and the pin moved to the subtraction that made one
    -- derivation place both.
    --
    -- ON 2026-09-02 HE REPORTED IT A FOURTH TIME AND NAMED THE ANCHOR: "It
    -- should be inside the 3dmarker." That is not a third position in an
    -- argument -- it is the end of the argument, because it is the only answer
    -- that is about the thing the plate has to agree with. So the pin is now the
    -- marker.
    --
    -- WHAT WOULD SILENTLY GO WRONG is somebody "tidying" `markerPlateHeight`
    -- into a constant -- the exact edit that has been made and rejected three
    -- times -- or re-coupling it to the van plate's numbers, which are four
    -- per-face sets about an ambulance's bodywork and have nothing to say about
    -- a key in a field. The arithmetic is executed in plate.config above; this
    -- pins that the client is what runs it, and off what.
    ok(clientCode:find('local function markerPlateHeight') ~= nil,
        'the loose key\'s height is a FUNCTION OF THE MARKER rather than a '
            .. 'number -- the three rejected answers were all numbers')

    ok(clientCode:find('local lift, tall = markerBand%(%)%s*\n%s*return lift %+ tall %* 0%.5')
           ~= nil,
        '...and it is the middle of the marker\'s own band, which is what '
            .. '"inside the 3dmarker" means')

    ok(clientCode:find('c%.z %+ markerPlateHeight%(%)') ~= nil,
        '...added to the key\'s own z, which is the same point the marker is '
            .. 'drawn at')

    -- ONE READER OF THE MARKER'S HEIGHT NUMBERS. If the marker pass kept its own
    -- `tonumber(M.height) or 0.4` the plate and the marker would have two
    -- authored defaults, and an unconfigured marker would draw with a plate
    -- floating over it -- this report, again, in the one case nobody plays.
    ok(clientCode:find('local function markerBand') ~= nil
       and select(2, clientCode:gsub('markerBand%(%)', '')) >= 3
       and select(2, clientCode:gsub('tonumber%(M%.height%)', '')) == 1,
        '...and both the marker pass and the plate read those two numbers '
            .. 'through markerBand -- `tonumber(M.height)` appears exactly once '
            .. 'in the file, so there is no second copy of the height, and no '
            .. 'second `or 0.4` for an unconfigured marker to disagree over')

    -- AND THE VAN PLATE READS A FACE. `plateNumbers` takes the word
    -- BR.Dui.nearFace's answer is named by, so the panel a player is standing at
    -- and the five numbers the plate is drawn with are one decision.
    ok(clientCode:find('local function plateNumbers%(face%)') ~= nil
       and clientCode:find('local face = faceWord%(BR%.Dui%.nearFace%(veh, p%.x, p%.y%)%)')
           ~= nil,
        'and the plate ON A VAN picks its five numbers by the face the player '
            .. 'is nearest to, resolved through the same call that draws it')

    -- ...AND THE GROUND PLATE READS NONE OF THEM. Re-coupling the two is the
    -- edit that looks like tidying and is the fourth report coming back.
    ok(clientCode:find('plateGroundHeight') == nil
       and clientCode:find('plateNumbers%(%)') == nil,
        '...while the plate over a loose key reads no part of the van\'s table, '
            .. 'so tuning one surface cannot move the other')

    -- ═══ AND THE MARKER THAT NOW STANDS WHERE THE BODY DOES NOT ═══
    --
    -- "After a player has bled out, their ped should become invisible. Only the
    -- 3dmarker (type 24) and DUI should be shown at their position."
    --
    -- TEXT PINS FOR THE SAME REASON AS THE THREE ABOVE: there is no client state
    -- in this harness to run a frame pass in. What is pinned is the set of
    -- decisions that would be silently wrong rather than broken.
    ok(clientCode:find("BR%.Loop%.register%(BR%.Loop%.FRAME, 'revivekey%.marker'")
           ~= nil,
        'the marker is drawn on the FRAME band -- a DrawMarker lasts exactly one '
            .. 'frame, so a TICK registration would draw a marker that strobes')

    ok(clientCode:find('DrawMarker%(kind,') ~= nil
       and clientCode:find('local kind%s+= math%.tointeger%(tonumber%(M%.kind%)%)')
           ~= nil,
        'and its type comes from the config rather than being a literal at the '
            .. 'call site, so "type 24" is one authored fact')

    -- THE ANCHOR. This is the whole of the file's header applied to a second
    -- surface: a marker on the ped would sit somewhere different on every
    -- screen -- the corpse is a death ragdoll and those "do not replicate
    -- reliably" -- while the server ruled the take against a fixed point. The
    -- plate and the marker must come off ONE pair of coordinates.
    ok(clientCode:find('rz %+ lift') ~= nil
       and clientCode:find('local rx, ry = tonumber%(rec%.x%), tonumber%(rec%.y%)')
           ~= nil,
        'and it is drawn at the KEY\'s recorded point, the server\'s own '
            .. 'numbers, exactly where the plate goes -- never at a ped')

    ok(clientCode:find('PlayerPedId%(%)') ~= nil
       and clientCode:find('rec%.live == true and rec%.held ~= true') ~= nil,
        'a key that is held or no longer live draws nothing, which is the same '
            .. 'pair of fields the plate is chosen on')

    -- NOT GATED ON `eligible()`, AND THAT IS DELIBERATE. That function refuses
    -- anybody in a vehicle, and a squadmate DRIVING to a body is the player who
    -- most needs to see where it is. A marker hung off `cand` would vanish the
    -- moment somebody got in a car to go and fetch their mate.
    local markerPass = clientCode:match(
        "BR%.Loop%.register%(BR%.Loop%.FRAME, 'revivekey%.marker'.-\nend%)")
    ok(markerPass ~= nil and markerPass:find('eligible()', 1, true) == nil,
        'and the marker pass does NOT consult eligible(), so it still draws for '
            .. 'the squadmate who is driving over to collect')

    -- ═══ AND THE VEHICLE LIFT IT USED TO BE COMPARED AGAINST IS GONE ═══
    --
    -- This used to assert `GROUND_LIFT < PROMPT_LIFT` -- that a plate over a
    -- body may not sit as high as a plate over an ambulance roof. The owner then
    -- objected to the ambulance plate as well (2026-08-31: "I don't like the
    -- positioning of the 'press E to revive' DUI"), and a plate over the roof is
    -- exactly what 1.1m above a vehicle's origin is. So the constant is not
    -- retuned, it is DELETED: the height of a plate on a van is read off that
    -- van's own box now, and there is nothing left for the ground plate to be
    -- lower than.
    --
    -- THE PROPERTY THAT SURVIVES IS THE ANCHOR, which is what the old assertion
    -- was really protecting: a plate has to be measured against the thing it is
    -- supposed to look attached to. Since 2026-09-02 the ground plate's thing is
    -- the marker at the same point, and the van plate's is the van -- so there
    -- is no shared number between them left to be right for one and wrong for
    -- the other, and the fallback SPAN this file used to keep for the ground
    -- plate went with the coupling.
    ok(clientCode:find('FALLBACK_SPAN_M') == nil,
        '...and the ambulance-shaped fallback the ground plate used to lean on '
            .. 'is gone with it -- a key in a field is not measured against a '
            .. 'van at all now')
    ok(clientCode:find('local GROUND_LIFT') == nil,
        '...so the authored ground lift he reported three times is gone rather '
            .. 'than retuned a fourth time')
    ok(clientCode:find('PROMPT_LIFT') == nil,
        '...and the 1.1m vehicle lift is gone rather than retuned -- the plate '
            .. 'on a van is derived from the van, so there is no constant left '
            .. 'to be right for an ambulance and wrong for the next model')

    -- ═══ BOTH AMBULANCE PLATES GO ON A FACE, AND THROUGH ONE CALL ═══
    --
    -- "What I want is a DUI that shows on the nearest face of the vehicle."
    --
    -- The revive and the purchase are one plate at one van a moment apart --
    -- `choose` returns exactly one candidate -- so drawing them two different
    -- ways would only mean the plate jumped the instant a squad bought a key.
    -- Pinned as ONE call site rather than as two, because that is the property:
    -- a second drawing path is how they come to disagree.
    ok(clientCode:find('BR%.Dui%.drawNearFace') ~= nil,
        'the plate at a van is a sign on its nearest face, not a billboard over '
            .. 'its roof')
    local _, vanDraws = clientCode:gsub('drawOnVan%(page', '')
    ok(vanDraws == 4,
        'and the revive, the hold, the purchase and the ruler\'s preview all '
            .. 'reach it through one function -- one declaration and three '
            .. 'calls', vanDraws)
    ok(clientCode:find('drawWorld%(page, c%.x') ~= nil
       and select(2, clientCode:gsub('BR%.Dui%.drawWorld', '')) == 1,
        '...while the loose key keeps the billboard it needs, because there is '
            .. 'no bodywork under a key lying on the ground')

    -- ═══ THE RING IS THE RESTING STATE, NOT THE PRESSED ONE ═══
    --
    -- "I want it by default to draw the empty circle around the E instead of a
    -- glyph that changes to the circle when pressed" (2026-08-31).
    --
    -- dui/prompt.html already draws `ring` with no `holdMs` as an empty circle
    -- round the key cap, so the whole of the change is that the resting revive
    -- plate now carries the flag. The HOLD is what adds a duration -- and
    -- `holdMs` is part of setPrompt's change key, so the two are separate
    -- messages and the fill animates from empty on the press.
    ok(clientCode:find("mode = 'revive', id = c%.id,\n%s*label = C%.revive, hint = C%.reviveHold, press = true,\n%s*ring%s*=%s*true,") ~= nil,
        'the revive plate draws its ring before anything is pressed')

    -- ═══ AND THE AMBULANCE PLATE NAMES NOBODY ═══
    --
    -- "The ambulance DUI should say 'Revive your squad' and the line under (in
    -- the smaller lighter font) should say 'PRESS AND HOLD' instead of including
    -- the player's name." (2026-09-01.)
    --
    -- THREE CALL SITES DRAW THAT PLATE -- the resting offer, the running hold and
    -- the ruler's preview -- and every one of them used to look up a roster row
    -- for the name. A single one left behind would put a name back over his line
    -- in exactly one of the three states, which is the shape of bug that gets
    -- reported as "sometimes it says my mate's name".
    --
    -- ASSERTED AS AN ABSENCE OF THE LOOKUP, not just a presence of the strings:
    -- `label = C.revive` with a dead `local e = ...` above it would pass a
    -- presence check and would be one edit away from regressing.
    local revivePasses = select(2, clientCode:gsub('label = C%.revive, hint = C%.reviveHold', ''))
              + select(2, clientCode:gsub('label  = C%.revive,\n%s*hint   = C%.reviveHold,', ''))
    ok(revivePasses == 3,
        'all three ambulance-plate call sites say his two lines -- the offer, '
            .. 'the hold and the ruler\'s preview', revivePasses)
    ok(clientCode:find('BR%.State%.roster%[holding%.target%]') == nil,
        'and the roster lookup that fed the name is gone from the hold rather '
            .. 'than left reading a row for a value nothing draws')

    -- ═══ THE LATERAL REACHES THE DRAW ═══
    --
    -- "I need to be able to move it left/right as well." (2026-09-01.)
    --
    -- The direction is BR.Dui's, because BR.NearestBoxFace is what knows which
    -- panel the plate is on -- so what this file must do is READ the number and
    -- HAND IT OVER, and the failure mode is a config key nothing passes: the
    -- owner would type `brplate side 0.3`, watch the readout change, and watch
    -- the plate stay exactly where it was.
    -- READ AND HAND-OFF IN ONE ASSERTION, INSIDE THE ONE FUNCTION, and that is
    -- the lesson of the mutant that got past the first draft of this. Pinning
    -- "somewhere in the file, a line reads `side` out of plateNumbers" is green
    -- against a drawOnVan that reads it into a `_` and declares `local side =
    -- 0.0` underneath -- because the READOUT and the COMMAND also read all five,
    -- and either of them satisfies a file-wide search. The plate would never
    -- move, the on-screen number would change as he pressed, and the paste block
    -- would be right. So the whole function body is taken and all three things
    -- are asserted of IT: it reads the lateral, it hands that same name over,
    -- and nothing in between rebinds the name.
    local vanBody = clientCode:match('local function drawOnVan%(page, veh%)(.-)\nend')
    ok(vanBody ~= nil, 'the plate at a van is drawn by one function')
    ok(vanBody ~= nil
       and vanBody:find('local out, side, frac, lift, width = plateNumbers%(face%)')
           ~= nil,
        'the draw reads the lateral out of the config -- out of THIS FACE\'S '
            .. 'set of five, since 2026-09-02')
    ok(vanBody ~= nil
       and vanBody:find('drawNearFace%(page, veh, p%.x, p%.y, out, oz, width, side%)')
           ~= nil,
        '...and passes it to the one function that knows which face it is on, '
            .. 'rather than offsetting the plate itself')
    ok(vanBody ~= nil and vanBody:find('local side') == nil,
        '...and does not rebind the name in between, which is the shape that '
            .. 'leaves every readout right and the plate stationary')

    -- ═══ THE RULER TAKES THE ARROW KEYS, AND ONLY WHILE IT IS ON ═══
    --
    -- "brplate needs reworked - it should use arrow keys to adjust the
    -- position." (2026-09-01.)
    --
    -- THE DANGEROUS HALF OF THIS CHANGE IS NOT THE NUDGING, IT IS THE CLAIM. A
    -- DisableControlAction that is not inside a level test on `tuning` takes the
    -- arrow keys away from every player on the server for the whole match, and
    -- there is NO SYMPTOM anywhere near this file -- the report comes back as
    -- "the phone doesn't open" weeks later. So what is pinned is the guard, in
    -- the pass, and that the pass is the only place in the file that disables
    -- anything.
    local keyPass = clientCode:match(
        "BR%.Loop%.register%(BR%.Loop%.FRAME, 'revivekey%.tunekeys'.-\nend%)")
    ok(keyPass ~= nil, 'the arrows are read on a frame pass of their own')
    ok(keyPass ~= nil and keyPass:find('if not tuning then') ~= nil,
        '...which returns before it disables anything unless the ruler is on, '
            .. 'so the keys are the player\'s in every ordinary session')
    ok(select(2, clientCode:gsub('DisableControlAction', '')) == 1,
        '...and that pass is the ONLY place in this file that takes a control '
            .. 'away from anybody',
        select(2, clientCode:gsub('DisableControlAction', '')))

    -- FRAME, NOT TICK, and the reason is mechanical: DisableControlAction lasts
    -- exactly one frame, so a claim renewed ten times a second is a key that is
    -- live five frames in six -- the up arrow would open the phone on the way
    -- past. Pinned because a band is a one-word edit that looks harmless.
    ok(clientCode:find("BR%.Loop%.FRAME, 'revivekey%.tunekeys'") ~= nil,
        '...on the FRAME band, because a block renewed at 10Hz is not a block')

    -- ENDING CLEANLY IS THE ABSENCE OF A TEARDOWN, NOT THE PRESENCE OF ONE.
    -- There is nothing to restore -- the block simply stops being renewed -- so
    -- an enable call in this file would be somebody adding a restore path that
    -- can be skipped by a Lua error, and would also be re-enabling controls the
    -- player may have disabled for their own reasons.
    ok(clientCode:find('EnableControlAction') == nil,
        '...and nothing re-enables anything, because a per-frame claim that '
            .. 'stops being made needs no undoing')

    -- THE BOOL READ. IsDisabledControlPressed is declared BOOL and may answer
    -- 1/0, and 0 is TRUTHY in Lua -- a bare read here would hold every arrow
    -- down permanently. tools/check_bool_natives.lua counts these tree-wide;
    -- this is the same rule said where the reader is.
    ok(clientCode:find('isTrue%(IsDisabledControlPressed%(0, id%)%)') ~= nil,
        'and the control read goes through isTrue, because a BOOL native that '
            .. 'answers 0 is TRUE in Lua')

    -- ═══ THE PASTE BLOCK STILL PASTES, AND IT PASTES ONE FACE ═══
    --
    -- The whole tool exists so he can send back numbers ("then fetch it I can
    -- give you the coords"). A number that is nudged, drawn and NOT printed is
    -- the one failure that wastes his time rather than the code's: he would
    -- position the plate, paste the block, and lose the axis he was measuring.
    --
    -- ALL FIVE, AND THE FACE THEY BELONG TO. Since 2026-09-02 the table holds a
    -- set per panel, so a block printed without its face key is a block he
    -- cannot paste anywhere -- and a whole `plate = { ... }` block would be
    -- worse than useless: pasted, it would delete the three faces he was not
    -- standing at.
    local pasteRow = clientCode:match(
        "print%(%('        %%%-5s = { out = %%%.3f, side = %%%.3f, frac = %%%.3f,'%)\n?%s*:format%(face, out, side, frac%)%)")
    ok(pasteRow ~= nil,
        'the paste block is ONE FACE\'S row, named by that face, carrying the '
            .. 'lateral he asked for')
    ok(clientCode:find(":format%(lift, width%)%)") ~= nil,
        '...and the other two numbers with it, so what he sends back is the '
            .. 'whole position')
    ok(clientCode:find("print%('    plate = {'%)") == nil,
        '...and it is NOT a whole plate table, which pasted would delete the '
            .. 'three faces he is not standing at')

    -- AND IT IS STILL GATED. br_lib/shared/devgate.lua wraps RegisterCommand for
    -- every br_core file loaded after it, so /brplate is gated by construction
    -- and its refusal is that wrapper's printed line. The one way to lose that
    -- is to reach for the raw door, which reads as a fix for "the ruler stopped
    -- working on the public box". tools/verify.sh pins the door project-wide;
    -- this says it where somebody would be tempted.
    ok(clientCode:find('BR%.Dev%.rawCommand') == nil,
        'and /brplate registers through the gated door like every other console '
            .. 'command -- the ruler is dev-only and says so when it refuses')
    ok(clientCode:find("mode = 'take', id = c%.id,[^}]*ring") == nil
       and clientCode:find("mode = 'buy', id = c%.id,[^}]*ring") == nil,
        '...and the take and the buy do not, because a ring with no duration '
            .. 'behind it promises a hold that does not exist')

    -- ═══ THE KEY POINT IS SQUAD-ONLY, WHICH IS A PROPERTY OF TWO OTHER FILES ═══
    --
    -- The client needs the coordinates the server rules against, and there are
    -- two places to put them: server/party.lua's squad beacon, which reaches
    -- only the squad, and roster.lua's PUBLIC_FIELDS, which reaches EVERY client
    -- in the match. The second would tell the people who just shot you whether
    -- your squad can get you back -- the difference between pushing a body and
    -- leaving it -- and it would look completely correct in game.
    --
    -- ASSERTED HERE BECAUSE NO SUITE LOADS party.lua, and because the failure is
    -- silent: nothing breaks, nothing errors, and the leak is only visible if
    -- somebody thinks to look.
    local ph = io.open(RES .. 'br_core/server/party.lua', 'r')
    local partySrc = ph and ph:read('a') or ''
    if ph then ph:close() end
    ok(partySrc:find('key = keyRow%(e, now%)') ~= nil,
        'the squad beacon carries the key point')

    local rh = io.open(RES .. 'br_core/server/roster.lua', 'r')
    local rosterSrc = rh and rh:read('a') or ''
    if rh then rh:close() end
    local pub = rosterSrc:match('local PUBLIC_FIELDS = {(.-)}')
    ok(pub ~= nil, 'roster.lua still has a PUBLIC_FIELDS list to check')
    ok(pub ~= nil and not pub:find('reviveKey') and not pub:find('key%s*='),
        'and the roster\'s public view carries neither the key nor its point -- '
            .. 'whether a squad can come back is exactly what the squad that '
            .. 'killed them would like to know', pub)
end

-- ---------------------------------------------------------------------------
-- The server module, with the world stubbed around it.
-- ---------------------------------------------------------------------------
local roster, matches, jobs, handlers = {}, {}, {}, {}
local charges, chargeAnswer

--- Everything the module sent a client, in order. { ev, src, d }
---
--- ORDERED AND NOT KEYED, because three of the properties under test are about
--- ORDER rather than content: REVIVEKEY_ARRIVE must leave a whole fade BEFORE
--- anything else, REVIVEKEY_PLACE must leave before the roster flips to ALIVE,
--- and the reviver's `done` must arrive at all. A table keyed on event name
--- would answer none of them.
local sent = {}

--- Every notice the module put on a player's screen. { who, text, tone }
local said = {}

do
    -- MODEL 1 IS AN AMBULANCE AND NOTHING ELSE IS. Stubbed rather than borrowed
    -- from the real BR.Rescue, because what is under test is that
    -- server/revivekey.lua ASKS -- see `buy.refuse.notambulance`.
    local world = {
        [201] = { model = 1, x = 0.0,   y = 0.0   },   -- an ambulance
        [202] = { model = 2, x = 0.0,   y = 0.0   },   -- a car at the same spot
        [203] = { model = 1, x = 900.0, y = 900.0 },   -- an ambulance far away
    }
    local entOf = { [9201] = 201, [9202] = 202, [9203] = 203 }
    local gone  = {}

    -- ═══ DECLARED BEFORE loadCore, AND THAT ORDER IS LOAD-BEARING ═══
    --
    -- server/revivekey.lua resolves `can.entityFromNet` ONCE at load, the way
    -- server/ambheal.lua does. A stub installed afterwards would leave the
    -- module believing the native is missing, every purchase would be refused
    -- with 'no net id resolver on this build', and the whole buy section would
    -- pass its refusal tests for entirely the wrong reason.
    _G.NetworkGetEntityFromNetworkId = function(n) return entOf[n] end

    -- ═══ 1 AND 0, NOT true AND false, AND THAT IS THE POINT OF THE STUB ═══
    --
    -- DoesEntityExist is declared BOOL and a FiveM native declared BOOL hands
    -- Lua a NUMBER on some builds. `0` is truthy in Lua, so `if
    -- DoesEntityExist(e)` is true for an entity that does not exist -- ten
    -- shipped instances of that in this project, and tools/check_bool_natives.lua
    -- exists because of them.
    --
    -- A STUB THAT ANSWERED `false` WOULD HIDE THE BUG IT IS HERE TO CATCH: the
    -- refusal would pass with or without the isTrue() wrapper, and the suite
    -- would go green on a build where a destroyed ambulance still sells revive
    -- keys. Answering 1/0 makes the wrapper load-bearing here rather than in a
    -- playtest.
    _G.DoesEntityExist = function(e)
        return (world[e] ~= nil and not gone[e]) and 1 or 0
    end
    _G.GetEntityModel  = function(e) return (world[e] or {}).model end
    _G.GetEntityCoords = function(e)
        local v = world[e] or {}
        return { x = v.x or 0.0, y = v.y or 0.0, z = 0.0 }
    end

    _G.vanish = function(e) gone[e] = true end
    _G.unvanish = function(e) gone[e] = nil end

    BR.Rescue = { isAmbulance = function(m) return m == 1 end }

    -- ═══ THE SPECTATE TEARDOWN, RECORDED IN THE SAME ORDERED LIST ═══
    --
    -- It goes into `sent` rather than a list of its own, because what is under
    -- test is WHEN it happens: the camera has to come down inside the black, not
    -- after it. A separate table would record the call and lose the only fact
    -- that matters about it.
    BR.Spectate = {
        stop = function(src, reason)
            sent[#sent + 1] = { ev = '<specStop>', src = src, d = reason }
            return true
        end,
    }

    BR.Roster = {
        get  = function(src) return roster[src] end,
        -- ═══ TWO WRITERS, BECAUSE THE REVIVE USES BOTH ═══
        --
        -- `update` is how a health number reaches the ledger and `setState` is
        -- how the roster learns somebody is back in the match. They are stubbed
        -- rather than mocked -- they really do write the entry -- because every
        -- assertion in `revive.brings-back` below is about what the entry LOOKS
        -- LIKE afterwards, and a mock that only recorded the call would be
        -- testing that the module said the words.
        update = function(src, patch)
            local e = roster[src]
            if not e then return end
            for k, v in pairs(patch) do e[k] = v end
        end,
        setState = function(src, state)
            local e = roster[src]
            if not e then return end
            -- ORDER IS THE THING UNDER TEST HERE, so the stub records WHEN the
            -- flip happened relative to the client events. server/combat.lua's
            -- reviveHeld is explicit that REVIVED must go first: a client left
            -- holding a corpse while the server calls it ALIVE is the state the
            -- server-observed death check exists to eliminate, and it would
            -- eliminate them.
            e.state = state
            sent[#sent + 1] = { ev = '<setState>', src = src, d = state }
        end,
        each = function(pred, fn)
            -- SORTED, because two of the tests below assert WHICH squadmate
            -- collected a key and pairs() order is not defined. A suite that
            -- passed on one Lua build and failed on the next would be worse
            -- than no suite.
            local ids = {}
            for src in pairs(roster) do ids[#ids + 1] = src end
            table.sort(ids)
            for _, src in ipairs(ids) do
                local e = roster[src]
                if not pred or pred(e) then fn(src, e) end
            end
        end,
    }
    -- ═══ notify IS PRESENT NOW, AND CAPTURED RATHER THAN SILENCED ═══
    --
    -- It used to be deliberately ABSENT, so that copy added to the module would
    -- throw and take the suite down. That guard has been replaced by two better
    -- ones: the source check above (exactly one call site, taking its text as an
    -- argument) and the `notify` block below, which asserts that every string
    -- reaching this stub is a member of BR.Config.ReviveKey.copy. A missing
    -- function could only ever prove that nothing was said; this proves that
    -- what was said is the owner's.
    -- ═══ `text` IS NOT ALWAYS A STRING ANY MORE ═══
    --
    -- Four of the owner's nine lines name a player, and BR.Notice.line hands
    -- BR.Server.notify a TABLE for those -- `{ text = <flat>, parts = {...} }`
    -- -- so the name can be drawn bold without ever having been inside a
    -- string. Captured RAW here, exactly as the real notify receives it, so the
    -- readers below can assert both halves: what the sentence says and where
    -- the names are. A stub that flattened on the way in would have made the
    -- second half untestable.
    BR.Server = {
        matches = matches,
        notify  = function(who, text, tone)
            said[#said + 1] = { who = who, text = text, tone = tone }
        end,
    }
    BR.Sched  = { every = function(_, name, fn) jobs[name] = fn end }

    -- THE MARKET, DRIVEN RATHER THAN STUBBED OUT. `charge` answers through a
    -- callback because it is a DynamoDB round trip, and the interesting cases
    -- here are all about WHAT HAPPENS DURING IT -- so the answer is deferred
    -- until a test calls `settle`, exactly as the real one defers until the row
    -- replies.
    charges = {}
    BR.Market = {
        charge = function(src, amount, reason, done)
            charges[#charges + 1] = {
                src = src, amount = amount, reason = reason, done = done,
            }
        end,
    }

    _G.RegisterNetEvent   = function() end
    _G.RegisterCommand    = function() end
    _G.AddEventHandler    = function(name, fn) handlers[name] = fn end
    _G.TriggerClientEvent = function(ev, src, d)
        sent[#sent + 1] = { ev = ev, src = src, d = d }
    end

    loadCore('br_core/server/revivekey.lua')
end

--- What a captured notice actually reads as on screen, flattened.
--- @param s table|nil  one entry of `said`
--- @return string|nil
local function flat(s)
    local t = s and s.text
    if type(t) == 'table' then return t.text end
    return t
end

--- The player names a captured notice sent as parts of their own, in order.
---
--- EMPTY FOR A NOTICE THAT NAMES NOBODY, which is the honest reading: a plain
--- string carries no parts at all and nothing on the page will be bold.
--- @param s table|nil
--- @return string[]
local function names(s)
    local out = {}
    local t = s and s.text
    if type(t) == 'table' and type(t.parts) == 'table' then
        for _, part in ipairs(t.parts) do
            if part.b ~= nil then out[#out + 1] = part.b end
        end
    end
    return out
end

--- The owner's LINE a captured notice was built from: its parts with every name
--- put back as the `%s` hole it came out of.
---
--- THIS IS THE ASSERTION THAT MATTERS FOR THE WHOLE FEATURE. It proves two
--- things at once about a sentence that reached a player: that the string is
--- character for character one of his, and that the name was never inside it.
--- A call site that did `(copy().collect):format(name)` would produce a notice
--- whose flat text looks perfect and whose form is unrecognisable here.
--- @param s table|nil
--- @return string|nil
local function formOf(s)
    local t = s and s.text
    if type(t) ~= 'table' then return t end
    local out = {}
    for _, part in ipairs(t.parts or {}) do
        out[#out + 1] = (part.b ~= nil) and '%s' or part.t
    end
    return table.concat(out)
end

--- Forget everything the module sent and said.
local function hush()
    for i = #sent, 1, -1 do sent[i] = nil end
    for i = #said, 1, -1 do said[i] = nil end
end

--- The first record of an event, or nil.
local function firstSent(ev)
    for i, s in ipairs(sent) do
        if s.ev == ev then return s, i end
    end
    return nil, nil
end

--- Answer the oldest outstanding charge.
local function settle(paid, why, left)
    local c = table.remove(charges, 1)
    if not c then return false end
    c.done(paid, why, left)
    return true
end

--- Put a player in the world.
local function put(src, opts)
    opts = opts or {}
    matches[1] = matches[1] or { id = 1, state = BR.MatchState.PLAYING }
    roster[src] = {
        src     = src,
        name    = opts.name or ('P' .. src),
        matchId = opts.matchId or 1,
        squadId = opts.squadId,
        state   = opts.state or BR.PlayerState.ALIVE,
        pos     = { x = opts.x or 0.0, y = opts.y or 0.0, z = 0.0 },
    }
    return roster[src]
end

local function wipe()
    for k in pairs(roster) do roster[k] = nil end
    for k in pairs(matches) do matches[k] = nil end
    for i = #charges, 1, -1 do charges[i] = nil end
    hush()
end

local sweep = jobs['revivekey.sweep']
local hold  = jobs['revivekey.hold']

-- ---------------------------------------------------------------------------
describe('sweep.registered')
do
    ok(sweep ~= nil, 'the sweep registered itself on the scheduler')
end

-- ---------------------------------------------------------------------------
describe('mint')
do
    wipe()
    fakeTime = 100000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    -- A SOLO GETS NOTHING. `squadId` is the gate, not the mode -- the same field
    -- server/combat.lua's tellSquad reads one screen above the call site.
    put(1, { squadId = nil, x = 10.0, y = 10.0 })
    ok(BR.ReviveKey.onEliminated(m, 1) == nil,
        'a player with no squad gets no key -- there would be nobody to own it')
    ok(roster[1].reviveKey == nil, 'and nothing is written to their entry')

    -- WITH A SQUAD, AT THE BODY.
    put(2, { squadId = 'A', x = 50.0, y = 60.0 })
    local rec = BR.ReviveKey.onEliminated(m, 2)
    ok(rec ~= nil, 'a squad player leaves a key')
    ok(rec.x == 50.0 and rec.y == 60.0, 'where they fell',
        rec and ('(%.1f, %.1f)'):format(rec.x, rec.y))
    ok(rec.held == false, 'which nobody holds yet')
    ok(rec.expiresAt == fakeTime + 180000, 'on a three-minute clock',
        rec.expiresAt - fakeTime)

    -- ═══ THE POSITION IS COPIED, NOT REFERENCED ═══
    --
    -- `entry.pos` is overwritten IN PLACE by the roster's sampler four times a
    -- second. A key that held the table rather than the numbers would follow the
    -- corpse through every physics nudge a body takes -- and a body on a slope
    -- keeps moving -- so the pickup would drift away from the blip its squad is
    -- running at.
    roster[2].pos.x, roster[2].pos.y = 999.0, 999.0
    ok(rec.x == 50.0 and rec.y == 60.0,
        'and the pickup does not follow the corpse when the sampler moves it',
        ('(%.1f, %.1f)'):format(rec.x, rec.y))

    -- IDEMPOTENT. Not reachable through eliminate() -- `canDie` refuses a player
    -- who is already OUT -- but the function is public and a second mint that
    -- overwrote the first would teleport a pickup somebody was walking to.
    roster[2].pos.x, roster[2].pos.y = 700.0, 700.0
    local again = BR.ReviveKey.onEliminated(m, 2)
    ok(again == rec, 'a second mint returns the first record rather than a new one')
    ok(rec.x == 50.0, 'and does not move the pickup', rec.x)

    -- NO MATCH, NO KEY. combat.lua guards on `m` for the death box and this
    -- inherits the same guard; asserted so the two cannot drift apart.
    put(3, { squadId = 'A', x = 1.0, y = 1.0 })
    ok(BR.ReviveKey.onEliminated(nil, 3) == nil, 'no match, no key')

    -- NO POSITION SAMPLE, NO KEY. A key with no coordinates is a pickup nobody
    -- can walk to and a blip pointing at the origin.
    put(4, { squadId = 'A' })
    roster[4].pos = nil
    ok(BR.ReviveKey.onEliminated(m, 4) == nil,
        'and a player the sampler has never seen leaves none either')
end

-- ---------------------------------------------------------------------------
describe('take.press')
do
    -- ═══ WALKING OVER A KEY DOES NOTHING AT ALL NOW ═══
    --
    -- "I somehow picked up the dead player's key by walking up to them without
    -- seeing a DUI or pressing anything" -- the owner, 2026-08-30. Collection
    -- used to be a proximity test this sweep ran on its own samples; it is a
    -- press. This is the assertion that the sweep cannot take a key BACK, which
    -- is the half a playtest would never notice: a squad that pressed nothing
    -- and holds nothing looks exactly like a squad that has not walked over
    -- anything yet.
    wipe()
    fakeTime = 200000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT

    local mate = put(2, { squadId = 'A', x = 0.5, y = 0.0 })
    sweep(); sweep()
    ok(dead.reviveKey.held == false,
        'a squadmate standing ON the body collects nothing without pressing -- '
            .. 'the sweep is a deadline check and nothing else now')

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE SUBJECT DOES NOT TAKE THEIR OWN KEY. READ THE HEADER
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- An OUT player's `pos` is the corpse they are spectating from, which is
    -- EXACTLY the position the key was minted at -- distance zero, for ever. The
    -- old sweep guarded this with its collector filter; the press guards it
    -- twice, with an explicit self test and with the ALIVE requirement. Get it
    -- wrong and a dead player pressing interact holds their own key, every squad
    -- holds every key for free, and a solo playtester sees a feature that works.
    local okSelf, whySelf = BR.ReviveKey.take(1, 1)
    ok(okSelf == false and whySelf ~= nil and whySelf:find('their own key') ~= nil,
        'the eliminated player cannot take their own key -- their body is lying '
            .. 'on it, at distance zero, for ever', whySelf)

    -- AN ENEMY PRESSING ON THE BODY IS NOT A COLLECTOR (#219 Q2 is unanswered
    -- for VISIBILITY, but ownership is settled: the key is "owned by the
    -- squad").
    put(3, { squadId = 'B', x = 0.5, y = 0.0 })
    ok(select(2, BR.ReviveKey.take(3, 1)) == 'different squads',
        'and neither can an enemy squad standing on top of it')

    -- ANOTHER MATCH IS NOT THE SAME SQUAD EITHER, even sharing a squad id --
    -- ids are match-namespaced, so this is belt and braces on a real invariant.
    put(4, { squadId = 'A', matchId = 2, x = 0.0, y = 0.0 })
    ok(select(2, BR.ReviveKey.take(4, 1)) ~= nil,
        'nor a player in another match who happens to share the squad id')

    -- OUT OF REACH IS OUT OF REACH.
    --
    -- THE REASON IS READ THROUGH A LOCAL AND NIL-GUARDED, here and below,
    -- because the interesting failure is the press SUCCEEDING -- and
    -- `select(2, ...):find(...)` on a success indexes nil and takes the whole
    -- suite down with a traceback instead of naming the rule that broke.
    mate.pos.x = 8.0
    local whyFar = select(2, BR.ReviveKey.take(2, 1))
    ok(whyFar ~= nil and whyFar:find('from the key') ~= nil,
        'a squadmate across the road presses on nothing, and the reason carries '
            .. 'the number', whyFar)

    -- A DOWNED SQUADMATE IS NOT FETCHING ANYTHING. They crawl at 0.55 m/s and
    -- are bleeding out; if they are on the body it is because they were shot
    -- there.
    mate.pos.x = 1.0
    mate.state = BR.PlayerState.DBNO
    local whyDown = select(2, BR.ReviveKey.take(2, 1))
    ok(whyDown ~= nil and whyDown:find('may take a key') ~= nil,
        'and a DBNO squadmate lying next to it cannot take it either', whyDown)

    -- ON THEIR FEET, ON THE BODY, PRESSING. This is the whole feature.
    mate.state = BR.PlayerState.ALIVE
    hush()
    ok(BR.ReviveKey.take(2, 1) == true,
        'a living squadmate who presses at the body takes the key')
    ok(dead.reviveKey.held == true, 'and the squad holds it')
    ok(dead.reviveKey.via == 'fetched', 'recorded as fetched', dead.reviveKey.via)
    ok(BR.ReviveKey.heldFor(1) == true,
        'which is what the revive asks through BR.ReviveKey.heldFor')
    -- TWO SENTENCES NOW, NOT ONE: his line for the collector and his line for
    -- everybody else. `flat` is this suite's flattener -- see the notify stub.
    ok(#said == 2, 'and two things are said, one per audience', #said)
    ok(said[1] and flat(said[1]) == K.copy.collect:format('P1'),
        'the presser is told the collector\'s line, in the owner\'s words',
        said[1] and flat(said[1]))
    ok(said[1] and said[1].who == 2,
        'and it goes to the presser alone, not to the squad',
        said[1] and tostring(said[1].who))

    -- AND NOT TWICE. A key already held is not takeable again -- a second press
    -- must not re-announce a thing the squad already has.
    hush()
    ok(select(2, BR.ReviveKey.take(2, 1)) == 'that key is already held',
        'a second press on a key the squad already holds is refused')
    ok(#said == 0, 'and says nothing', #said)

    -- THE BOUNDARY, BOTH SIDES OF IT. `collectM` is 2.5, `collectSlackM` is 1,
    -- so the SERVER rules at 3.5 -- and the divergence runs the forgiving way:
    -- the client draws the plate at the tight number, so there is no position at
    -- which the plate is up and the press is refused on distance.
    wipe()
    matches[1] = m
    local d2 = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    BR.ReviveKey.onEliminated(m, 1)
    d2.state = BR.PlayerState.OUT
    local m2 = put(2, { squadId = 'A', x = 3.6, y = 0.0 })
    ok(select(1, BR.ReviveKey.take(2, 1)) == false, 'at 3.6m the press misses')
    m2.pos.x = 3.4
    ok(select(1, BR.ReviveKey.take(2, 1)) == true,
        'and at 3.4m -- inside collectM plus its slack -- it lands')

    -- AND AN EXPIRED PICKUP IS NOT TAKEABLE, however close you stand. The three
    -- minutes are what makes 25 Volts mean anything.
    wipe()
    matches[1] = m
    local d3 = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    local r3 = BR.ReviveKey.onEliminated(m, 1)
    d3.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })
    fakeTime = r3.expiresAt + 1
    local whyOld = select(2, BR.ReviveKey.take(2, 1))
    ok(whyOld ~= nil and whyOld:find('expired') ~= nil,
        'a pickup whose three minutes ran out cannot be pressed up off the '
            .. 'ground -- only bought', whyOld)
end

-- ---------------------------------------------------------------------------
describe('sweep.expiry')
do
    wipe()
    fakeTime = 300000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    local rec = BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT

    fakeTime = fakeTime + 179000
    sweep()
    ok(rec.lapsed ~= true, 'at 2:59 the pickup is still there')

    fakeTime = fakeTime + 2000
    sweep()
    ok(rec.lapsed == true, 'at 3:01 it is gone')

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE PICKUP EXPIRES. THE KEY DOES NOT. THESE ARE TWO CLOCKS
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- "The pickup expires on a timer, let's say 3 minutes. They can STILL
    --  purchase the revive keys at an ambulance for 25 volts" -- one sentence,
    -- and reading it as one clock would delete the purchase path. A squad that
    -- misses the trip has lost the free option, not the player.
    ok(dead.reviveKey ~= nil,
        'and the RECORD survives -- "they can still purchase" is the other half '
            .. 'of the sentence that set the timer')
    ok(BR.ReviveKey.outstanding('A', 1) == 1,
        'so an expired pickup is still an outstanding key to buy',
        BR.ReviveKey.outstanding('A', 1))

    -- AND A LATE ARRIVAL CANNOT PRESS IT UP. The pickup is gone; only Volts
    -- reach it now.
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })
    sweep()
    ok(select(1, BR.ReviveKey.take(2, 1)) == false and dead.reviveKey.held == false,
        'a squadmate who arrives after the timer presses on nothing')

    -- THE LOG FIRES ONCE, NOT EVERY SECOND FOR THE REST OF THE MATCH.
    local before = rec.lapsed
    sweep(); sweep()
    ok(before == true and rec.lapsed == true,
        'and the expiry is latched rather than re-announced on every tick')

    -- ═══ THE BOUNDARY, AND THAT THE PRESS AND THE EXPIRY ARE COMPLEMENTS ═══
    --
    -- `pickupLive` is `now < expiresAt` and the expiry is `now >= expiresAt`, and
    -- BOTH the press and the sweep read it. So a mate pressing on the millisecond
    -- the timer runs out gets the key, and a millisecond later gets nothing --
    -- there is no window in which both are true and none in which neither is.
    -- Worth asserting rather than reasoning about: a key lost to that race would
    -- be unreproducible in a playtest and would read as the reach being flaky.
    wipe()
    fakeTime = 800000
    local m2 = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m2
    local d = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    local r = BR.ReviveKey.onEliminated(m2, 1)
    d.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    fakeTime = r.expiresAt - 1
    sweep()
    ok(BR.ReviveKey.take(2, 1) == true and r.lapsed ~= true,
        'one millisecond before the deadline the press lands, and the key does '
            .. 'not also expire')

    wipe()
    matches[1] = m2
    local d2 = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    local r2 = BR.ReviveKey.onEliminated(m2, 1)
    d2.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    fakeTime = r2.expiresAt
    sweep()
    ok(select(1, BR.ReviveKey.take(2, 1)) == false
       and d2.reviveKey.held == false and r2.lapsed == true,
        'and exactly on it the pickup expires instead -- the two outcomes are '
            .. 'complements, so neither can be lost to the other')
end

-- ---------------------------------------------------------------------------
describe('buy.refuse')
do
    wipe()
    fakeTime = 400000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 500.0, y = 500.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT

    -- The buyer, standing on the ambulance at the origin.
    local buyer = put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    local function why(src, netId)
        local _, w = BR.ReviveKey.canBuy(src, roster[src], netId)
        return w
    end

    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'the ordinary case: alive, in a squad, at an ambulance, with a key out')

    -- NOT AN AMBULANCE. Asked of BR.Rescue.isAmbulance so all three ambulance
    -- features mean one thing by the word.
    ok(why(2, 9202) == 'that is not an ambulance',
        'a car parked in the same spot is not an ambulance', why(2, 9202))

    -- TOO FAR. reachM 6 + reachSlackM 2 = 8 on the server's ruling.
    ok(why(2, 9203) ~= nil, 'an ambulance across the map is not "at an ambulance"',
        why(2, 9203))
    buyer.pos.x = 7.0
    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'and the server\'s ruling is forgiving by reachSlackM, so a press that '
            .. 'was legitimate when it was made is not refused by a stale sample')
    buyer.pos.x = 9.0
    ok(why(2, 9201) ~= nil, 'but not forgiving without limit', why(2, 9201))
    buyer.pos.x = 0.0

    -- A VEHICLE THAT HAS BEEN BLOWN UP. `0` IS TRUTHY IN LUA and DoesEntityExist
    -- is a BOOL native, so a bare truth test here would sell a key at a wreck.
    vanish(201)
    ok(why(2, 9201) == 'that vehicle does not exist',
        'an ambulance that has been destroyed is refused -- DoesEntityExist is '
            .. 'a BOOL native and 0 is truthy', why(2, 9201))
    unvanish(201)

    -- A NET ID THAT MEANS NOTHING.
    ok(why(2, 4242) == 'that net id resolves to nothing',
        'and a net id nobody recognises buys nothing', why(2, 4242))

    -- THE BUYER HAS TO BE UP AND IN THE MATCH.
    buyer.state = BR.PlayerState.OUT
    ok(why(2, 9201) ~= nil,
        'an eliminated player cannot buy their own way back', why(2, 9201))
    buyer.state = BR.PlayerState.DBNO
    ok(why(2, 9201) ~= nil, 'and neither can a downed one (#219 Q17 unanswered)',
        why(2, 9201))
    buyer.state = BR.PlayerState.ALIVE

    -- THE MATCH HAS TO BE LIVE.
    m.state = BR.MatchState.ENDED
    ok(why(2, 9201) == 'not in a playing match', 'and not after the match ends')
    m.state = BR.MatchState.PLAYING

    -- NOTHING TO BUY. 25 Volts is not refundable (config/shop.lua), so a squad
    -- with every key already held must not be charged for a no-op.
    dead.reviveKey.held = true
    ok(why(2, 9201) == 'that squad has no outstanding keys',
        'a squad with nothing outstanding is refused rather than charged',
        why(2, 9201))
    dead.reviveKey.held = false

    -- A SOLO HAS NO SQUAD TO BUY FOR.
    buyer.squadId = nil
    ok(why(2, 9201) == 'no squad', 'and a player with no squad buys nothing')
    buyer.squadId = 'A'

    -- AND NOTHING WAS CHARGED THROUGH ANY OF THAT.
    ok(#charges == 0,
        'no refusal reached the market -- the goods must not exist before the '
            .. 'debit, and neither may the debit before the goods are possible',
        #charges)
end

-- ---------------------------------------------------------------------------
describe('buy.grant')
do
    wipe()
    fakeTime = 500000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local d1 = put(1, { squadId = 'A', x = 500.0, y = 500.0 })
    local d2 = put(3, { squadId = 'A', x = 600.0, y = 600.0 })
    local other = put(4, { squadId = 'B', x = 700.0, y = 700.0 })
    BR.ReviveKey.onEliminated(m, 1)
    BR.ReviveKey.onEliminated(m, 3)
    BR.ReviveKey.onEliminated(m, 4)
    d1.state, d2.state, other.state =
        BR.PlayerState.OUT, BR.PlayerState.OUT, BR.PlayerState.OUT

    local buyer = put(2, { squadId = 'A', x = 0.0, y = 0.0 })
    ok(BR.ReviveKey.outstanding('A', 1) == 2, 'the squad has two mates out',
        BR.ReviveKey.outstanding('A', 1))

    local gotOk, gotN
    BR.ReviveKey.buy(2, 9201, function(o, _, n) gotOk, gotN = o, n end)

    -- ═══ THE GOODS DO NOT EXIST BEFORE THE DEBIT DOES ═══
    ok(#charges == 1, 'the purchase went to the market', #charges)
    ok(charges[1].amount == 25, 'for 25 Volts', charges[1].amount)
    ok(d1.reviveKey.held == false and d2.reviveKey.held == false,
        'and NOTHING is granted while DynamoDB is still thinking -- a key handed '
            .. 'out before the write lands is a key a refusal cannot take back')

    -- ═══ A SECOND PRESS DURING THE ROUND TRIP BUYS NOTHING ═══
    --
    -- BR.Market.charge reserves the Volts against the session cache, which
    -- protects the MONEY. It does not protect the GOODS: two different
    -- squadmates are two different sources with two different reservations, so
    -- the market would take 25 from each of them for the same set of keys.
    local buyer2 = put(5, { squadId = 'A', x = 0.0, y = 0.0 })
    local _, whyTwo = BR.ReviveKey.canBuy(5, buyer2, 9201)
    ok(whyTwo == 'a purchase is already in flight',
        'a squadmate pressing buy during the round trip is refused, so one '
            .. 'squad cannot be charged twice for one set of keys', whyTwo)

    -- ═══ A FOURTH MATE GOES OUT WHILE THE MONEY IS IN THE AIR ═══
    --
    -- The set is re-read AFTER the answer rather than captured before it, so
    -- "one purchase buys all revive keys for the squad" is true at the moment it
    -- completes. That is the reading most generous to the payer, and the owner's
    -- sentence is the generous one.
    local d3 = put(6, { squadId = 'A', x = 800.0, y = 800.0 })
    BR.ReviveKey.onEliminated(m, 6)
    d3.state = BR.PlayerState.OUT

    settle(true, nil, 975)

    ok(gotOk == true, 'the purchase completes')
    ok(gotN == 3, 'and covers all three -- including the one eliminated while '
        .. 'the charge was in flight', gotN)
    ok(d1.reviveKey.held == true and d2.reviveKey.held == true
       and d3.reviveKey.held == true, 'every one of the squad\'s keys is held')
    ok(d1.reviveKey.via == 'bought', 'recorded as bought', d1.reviveKey.via)
    ok(other.reviveKey.held == false,
        'and the OTHER squad paid for nothing and got nothing')
    ok(BR.ReviveKey.outstanding('A', 1) == 0, 'the squad has nothing outstanding')

    -- THE GUARD IS RELEASED, so the squad may buy again for a later
    -- elimination. "multiple instances of this are allowed per match".
    local d4 = put(7, { squadId = 'A', x = 900.0, y = 800.0 })
    BR.ReviveKey.onEliminated(m, 7)
    d4.state = BR.PlayerState.OUT
    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'and a later elimination can be bought for again -- "multiple instances '
            .. 'of this are allowed per match"')

    -- A BOUGHT KEY IS IDENTICAL TO A FETCHED ONE (owner, 2026-08-30, Q16). The
    -- `via` field records how it was come by and NOTHING may branch on it.
    ok(BR.ReviveKey.heldFor(1) == BR.ReviveKey.heldFor(3),
        'a bought key answers heldFor exactly as a fetched one does')
end

-- ---------------------------------------------------------------------------
describe('buy.refused-by-the-row')
do
    -- THE CACHE THOUGHT THEY COULD AFFORD IT AND THE ROW DISAGREED. Reachable
    -- whenever the cache is stale -- a console grant, or this licence connected
    -- somewhere else. Nothing may be granted.
    wipe()
    fakeTime = 600000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 500.0, y = 500.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT
    local buyer = put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    local gotOk = nil
    BR.ReviveKey.buy(2, 9201, function(o) gotOk = o end)
    settle(false, 'cannot afford it', nil)

    ok(gotOk == false, 'a refusal is reported as one')
    ok(dead.reviveKey.held == false,
        'and NOTHING is granted -- the keys are exactly where they were')

    -- AND THE IN-FLIGHT GUARD IS RELEASED ON THE REFUSAL PATH TOO. If it were
    -- not, one failed purchase would lock a squad out of buying for the rest of
    -- the match, and the symptom -- "buy does nothing" -- would look like the
    -- feature being broken rather than a leaked flag.
    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'a squad that was refused may try again -- the guard is released on '
            .. 'every path, because BR.Market.charge always calls back')
end

-- ---------------------------------------------------------------------------
-- Spending one.
-- ---------------------------------------------------------------------------

--- One mate OUT with a key their squad owns, and one live mate at an ambulance.
---
--- ═══ THE BODY IS A HUNDRED METRES FROM THE VAN, ON PURPOSE ═══
---
--- The revive is ruled at an AMBULANCE now (owner, 2026-08-30), so every case
--- below is set up with the corpse and its key nowhere near the reviver. A
--- fixture that put them in the same place would let a ruling that still
--- measured to the key's point pass every assertion here.
---
--- `dist` IS THE DISTANCE FROM THE AMBULANCE, which is entity 201 at the origin.
---
--- THE ELIMINATED PLAYER'S ENTRY IS DIRTIED ON PURPOSE -- placement, diedAt,
--- engineHp, a storm ledger -- because the interesting half of `bringBack` is
--- what it CLEARS. An entry that was clean before the revive would let every one
--- of those assertions pass against a function that does nothing.
--- @param opts table|nil { held, t, dist }
local function downed(opts)
    opts = opts or {}
    wipe()
    fakeTime = opts.t or 1000000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 100.0, y = 100.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state    = BR.PlayerState.OUT
    dead.placement = 5
    dead.diedAt    = fakeTime
    dead.engineHp  = 0.0
    dead.killedByLicense = 'license:deadbeef'
    dead.hp        = 0.0
    if opts.held ~= false then dead.reviveKey.held = true end

    local mate = put(2, { squadId = 'A', x = (opts.dist or 1.0), y = 0.0 })
    hush()
    return m, dead, mate
end

--- The ambulance every hold in this section is performed at.
local VAN = 9201

--- A press, naming the van the way the client does.
---
--- `netId` defaults to the ambulance at the origin. Pass 'none' for the press
--- that names nothing, which is a real client case: the net id is resolved per
--- beat and a vehicle that stopped being networked stops producing one.
local function press(src, target, netId)
    _G.source = src
    handlers[BR.Net.REVIVEKEY_START]({ target = target, n = netId or VAN })
end

--- Run a hold to its end, THROUGH THE ARRIVAL WAIT.
---
--- ═══ TWO TICKS, AND THE GAP BETWEEN THEM IS THE FEATURE ═══
---
--- The hold completing no longer revives anybody. It sends the promise -- go
--- black, focus on the van -- and the ledger work happens `fadeMs + focusMs`
--- later, so that the client's resurrection lands with the screen already dark
--- and the server never calls a player ALIVE while their ped is a corpse. Every
--- test that wants somebody standing up has to spend that wait, and doing it in
--- one helper is what stops a test accidentally asserting against the promise.
--- @param target integer
--- @param reviver integer
local function finish(target, reviver)
    fakeTime = fakeTime + (K.reviveHoldMs or 6000) + 1
    press(reviver, target)
    hold()
    fakeTime = fakeTime + (K.fadeMs or 400) + (K.focusMs or 1000) + 1
    hold()
end

local function release(src)
    _G.source = src
    handlers[BR.Net.REVIVEKEY_STOP]()
end

--- Why the last press was refused, according to the ring the server took down.
local function refusal()
    local s = firstSent(BR.Net.REVIVEKEY_PROGRESS)
    if not s or not s.d or not s.d.cancelled then return nil end
    return s.d.reason
end

-- ---------------------------------------------------------------------------
describe('revive.registered')
do
    ok(hold ~= nil, 'the hold stepper registered itself on the scheduler')
    ok(handlers[BR.Net.REVIVEKEY_START] ~= nil, 'the start handler is registered')
    ok(handlers[BR.Net.REVIVEKEY_STOP] ~= nil, 'the stop handler is registered')
    ok(BR.Net.REVIVEKEY_START ~= BR.Net.REVIVE_START,
        'and it is NOT the DBNO revive\'s event -- that one\'s ruling refuses '
            .. 'any target who is not down, and its stepper only ever walks '
            .. 'DBNO entries, so an OUT player would never be stepped')
end

-- ---------------------------------------------------------------------------
describe('revive.ruling')
do
    -- ═══ AN UNCLAIMED KEY IS NOT A REVIVE ═══
    --
    -- The one refusal that is the whole shape of the feature: a key lying on the
    -- ground is something to WALK TO or BUY. Only once the squad owns it is
    -- there anything to spend. Get this wrong and the 25 Volts buys nothing that
    -- proximity did not already give away.
    local _, dead = downed({ held = false })
    press(2, 1)
    ok(refusal() == 'that key is not held yet',
        'a key nobody has collected or bought cannot be spent', refusal())
    ok(dead.reviveKey.byS == nil, 'and no claim is written')

    -- THE TARGET HAS TO BE OUT. A live squadmate has no key to spend and a
    -- downed one is server/combat.lua's business, not this file's.
    downed()
    roster[1].state = BR.PlayerState.ALIVE
    hush(); press(2, 1)
    ok(refusal() ~= nil and refusal():find('not out') ~= nil,
        'a target who is not OUT is refused', refusal())

    downed()
    roster[1].state = BR.PlayerState.DBNO
    hush(); press(2, 1)
    ok(refusal() ~= nil and refusal():find('not out') ~= nil,
        'and so is one who is merely downed -- that is the DBNO revive, and it '
            .. 'costs the squad nothing', refusal())

    -- THE REVIVER HAS TO BE UP. A dead player cannot pick anybody up, and a
    -- downed one crawling at 0.55 m/s is not standing over anything.
    for _, st in ipairs({ BR.PlayerState.OUT, BR.PlayerState.DBNO }) do
        downed()
        roster[2].state = st
        hush(); press(2, 1)
        ok(refusal() ~= nil and refusal():find('the reviver is') ~= nil,
            ('a reviver who is %s is refused'):format(st), refusal())
    end

    -- SQUADS. The key is owned by a squad and spent by that squad.
    downed()
    roster[2].squadId = 'B'
    hush(); press(2, 1)
    ok(refusal() == 'different squads', 'an enemy cannot spend your key', refusal())

    -- ═══ AND THE MATCH HAS TO BE LIVE, WHICH IS THE LATE-GAME ANSWER ═══
    --
    -- server/combat.lua carries the write-up of what a clock belonging to a
    -- finished match did last time: it eliminated the winner and stamped a death
    -- over VICTORY ROYALE. A hold completing after the results are published
    -- would be the same shape in the other direction.
    for _, st in ipairs({ BR.MatchState.ENDED, BR.MatchState.CLEANUP,
                          BR.MatchState.WARMUP }) do
        local m = downed()
        m.state = st
        hush(); press(2, 1)
        ok(refusal() == 'not in a playing match',
            ('a match in %s revives nobody'):format(st), refusal())
    end

    -- ═══════════════════════════════════════════════════════════════════════
    -- AND THE WHOLE OF WHAT THIS ROUND CHANGED: IT HAPPENS AT AN AMBULANCE
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- "the press e to revive DUI when standing at the ped should not show once
    -- they've bled out. The only option at that point is the ambulance." --
    -- owner, 2026-08-30.
    --
    -- STANDING ON THE BODY IS NOW THE REFUSED CASE. `downed()` puts the corpse
    -- and its key at (100, 100) and the ambulance is at the origin, so a reviver
    -- moved onto the body is as far from the van as it is possible to be in this
    -- fixture -- which is the assertion: the old ruling would have ALLOWED this
    -- one and refused every case below it.
    local _, deadBody = downed()
    roster[2].pos.x, roster[2].pos.y = 100.0, 100.0
    hush(); press(2, 1)
    ok(refusal() ~= nil and refusal():find('not at an ambulance') ~= nil,
        'a reviver standing over the corpse itself is refused -- the body is not '
            .. 'a place the revive happens any more', refusal())
    ok(deadBody.reviveKey.byS == nil, 'and no hold is armed there')

    -- NO VAN NAMED AT ALL. The client sends the net id with every beat; a press
    -- without one is a press the server has nothing to rule against.
    downed()
    hush(); press(2, 1, 'none')
    ok(refusal() == 'no net id', 'a press that names no ambulance is refused',
        refusal())

    -- A CAR PARKED IN THE SAME SPOT IS NOT AN AMBULANCE. Asked of
    -- BR.Rescue.isAmbulance, so the rescue, the heal, the purchase and now the
    -- revive cannot come to mean different things by the word.
    downed()
    hush(); press(2, 1, 9202)
    ok(refusal() == 'that is not an ambulance',
        'and so is one at a car', refusal())

    -- AN AMBULANCE THAT HAS BEEN BLOWN UP. `0` IS TRUTHY IN LUA and
    -- DoesEntityExist is a BOOL native: a bare truth test here would run a
    -- six-second hold at a wreck and drop somebody out of the sky over it.
    downed()
    vanish(201)
    hush(); press(2, 1)
    ok(refusal() == 'that vehicle does not exist',
        'a destroyed ambulance revives nobody -- DoesEntityExist is a BOOL '
            .. 'native and 0 is truthy', refusal())
    unvanish(201)

    -- REACH, MEASURED TO THE VAN.
    downed({ dist = 50.0 })
    press(2, 1)
    ok(refusal() ~= nil and refusal():find('not at an ambulance') ~= nil,
        'a reviver across the map is refused, and the reason carries the number',
        refusal())

    -- THE SLACK IS ON THE SERVER'S SIDE, and it is the forgiving direction: the
    -- client draws the plate at `reachM` and the server rules at
    -- `reachM + reachSlackM`, so there is no position at which the plate is up
    -- and the hold is refused on geometry. THE SAME PAIR THE PURCHASE USES --
    -- which is the point of deleting the revive's own pair.
    local dist = K.reachM + (K.reachSlackM / 2)
    downed({ dist = dist })
    press(2, 1)
    ok(roster[1].reviveKey.byS == 2,
        'and one just outside the drawn circle is allowed, because the server '
            .. 'position sample is up to a quarter of a second old',
        dist)
    ok(roster[1].reviveKey.veh == VAN,
        'and the van is recorded with the claim, because the arrival is placed '
            .. 'above it', roster[1].reviveKey.veh)
end

-- ---------------------------------------------------------------------------
describe('revive.hold')
do
    -- ═══ THE HEARTBEAT MUST NOT RESTART THE CLOCK ═══
    --
    -- The client re-asserts every 250ms. If a re-assertion re-armed the hold,
    -- the progress would reset four times a second and the ring would never
    -- finish -- which is exactly the symptom "I hold the input, the ring fills
    -- up, but then nothing happens" (owner, playtest, on the DBNO path).
    local _, dead = downed()
    press(2, 1)
    local from = dead.reviveKey.from
    ok(dead.reviveKey.byS == 2, 'the first press arms the hold')
    fakeTime = fakeTime + 250
    press(2, 1)
    ok(dead.reviveKey.from == from,
        'and a re-assertion is a heartbeat, NOT a new hold -- it must not '
            .. 'restart the progress')
    ok(dead.reviveKey.beat == fakeTime, 'but it does refresh the deadline')

    -- ═══ FIRST HAND ON WINS ═══
    --
    -- server/combat.lua's rule verbatim: two mates on one body is not twice as
    -- fast, and it must not restart the clock for whoever pressed second.
    local mate2 = put(3, { squadId = 'A', x = 1.0, y = 0.0 })
    mate2.state = BR.PlayerState.ALIVE
    hush(); press(3, 1)
    ok(dead.reviveKey.byS == 2, 'a second presser does not take the key')
    ok(dead.reviveKey.from == from, 'and does not restart it')
    ok(refusal() ~= nil and refusal():find('taken') ~= nil,
        'and is told so -- their ring comes down rather than filling over a hold '
            .. 'that is not theirs', refusal())

    -- ═══ SILENCE IS A RELEASE ═══
    --
    -- The bug this closes shipped once already: "a brief tap completed a whole
    -- revive" (owner, 2026-08-09) because the STOP was raised and did not land.
    -- With no beat requirement, a lost STOP costs the whole interaction; with
    -- one, it costs a fraction of a second.
    fakeTime = fakeTime + (K.reviveBeatMs or 1000) + 250
    hush(); hold()
    ok(dead.reviveKey.byS == nil, 'a hold whose holder went quiet is dropped')
    ok(refusal() == 'went quiet', 'and the reason says so', refusal())
    ok(roster[1].state == BR.PlayerState.OUT,
        'and nobody was revived by a key nobody was holding')

    -- ...AND THE KEY IS STILL THERE. A dropped hold is not a spent key.
    ok(dead.reviveKey.held == true,
        'the key survives a hold that failed -- it is spent by a COMPLETED '
            .. 'revive and by nothing else')

    -- A RELEASE ENDS IT AT ONCE.
    downed()
    press(2, 1)
    hush(); release(2)
    ok(roster[1].reviveKey.byS == nil, 'letting go ends the hold')
    ok(refusal() == 'released', 'and says which', refusal())

    -- WALKING OFF THE VAN ENDS IT, AND THE STEPPER IS WHAT NOTICES.
    downed()
    press(2, 1)
    roster[2].pos.x = 900.0
    fakeTime = fakeTime + 250
    hush(); hold()
    ok(roster[1].reviveKey.byS == nil, 'walking away from the ambulance ends the hold')
    ok(refusal() ~= nil and refusal():find('not at an ambulance') ~= nil,
        'and the reason carries the distance, which is what tells a playtest '
            .. 'apart from a client that is re-arming', refusal())

    -- ...AND SO DOES THE AMBULANCE ITSELF GOING AWAY. New with the move to the
    -- van: a hold at a corpse could not have its ground blown up under it.
    downed()
    press(2, 1)
    vanish(201)
    fakeTime = fakeTime + 250
    hush(); hold()
    ok(roster[1].reviveKey.byS == nil,
        'an ambulance destroyed under a running hold ends it')
    ok(refusal() == 'that vehicle does not exist', 'and says so', refusal())
    unvanish(201)

    -- ═══ A MATCH THAT ENDS UNDER A RUNNING HOLD ═══
    local m = downed()
    press(2, 1)
    m.state = BR.MatchState.ENDED
    fakeTime = fakeTime + (K.reviveHoldMs or 6000) + 250
    hush(); hold()
    ok(roster[1].state == BR.PlayerState.OUT,
        'a hold that would have completed after the match ended stands nobody '
            .. 'up -- the results are published and the placements awarded')
    ok(refusal() == 'not in a playing match', 'and the ring comes down', refusal())

    -- ═══ AND ONE THAT RUNS ITS COURSE ═══
    downed()
    press(2, 1)
    fakeTime = fakeTime + math.floor((K.reviveHoldMs or 6000) / 2)
    hush(); press(2, 1); hold()
    ok(roster[1].state == BR.PlayerState.OUT, 'half way through, nobody is up')
    local prog = firstSent(BR.Net.REVIVEKEY_PROGRESS)
    ok(prog ~= nil and prog.d.done == nil and prog.d.cancelled == nil,
        'and the holder is being told a percentage rather than an ending')

    -- ═══ THE END OF THE HOLD IS A PROMISE, NOT A RESURRECTION ═══
    --
    -- "their screen should fade to black, set focus to the area where the
    -- ambulance I just used is, PROCESS THE REVIVE" -- the order is the
    -- specification, so the tick that finishes the ring must do the first two
    -- and none of the third.
    fakeTime = fakeTime + math.floor((K.reviveHoldMs or 6000) / 2) + 1
    hush(); press(2, 1); hold()
    local arrive = firstSent(BR.Net.REVIVEKEY_ARRIVE)
    ok(arrive ~= nil and arrive.src == 1,
        'the tick that finishes the hold tells the SUBJECT to go black')
    ok(arrive ~= nil and arrive.d.x == 0.0 and arrive.d.y == 0.0,
        'and where to point the streaming focus -- the van, not the body',
        arrive and ('(%.1f, %.1f)'):format(arrive.d.x, arrive.d.y))
    ok(roster[1].state == BR.PlayerState.OUT,
        'and NOTHING else -- the revive is processed after the fade, not during '
            .. 'it, or the server calls a player ALIVE whose ped is still a '
            .. 'corpse and the 1Hz death check eliminates them again')
    ok(firstSent(BR.Net.REVIVEKEY_PLACE) == nil, 'nobody is placed yet')

    -- ═══ AND THE SPECTATE CAMERA COMES DOWN INSIDE THE BLACK ═══
    --
    -- server/spectate.lua's resolve pass would end it within 250ms of the state
    -- flip, which is a quarter of a second AFTER the screen has started coming
    -- back -- so the player would watch a squadmate's shoulder for a beat before
    -- cutting to their own descent. Asserted at the PROMISE tick, which is the
    -- whole point: any later and it is visible.
    local _, iArrive = firstSent(BR.Net.REVIVEKEY_ARRIVE)
    local spec, iSpec = firstSent('<specStop>')
    ok(spec ~= nil and spec.src == 1,
        'the subject stops spectating on the tick the black is asked for')
    ok(iSpec ~= nil and iArrive ~= nil and iSpec > iArrive,
        'after the fade is asked for, so the cut happens with nothing on screen',
        ('%s vs %s'):format(iSpec, iArrive))

    -- ═══ AND LETTING GO DURING THE FADE DOES NOT TAKE IT BACK ═══
    --
    -- The six seconds are paid. Without this the subject would be left on a
    -- black screen by a reviver who released the key a frame after the ring
    -- closed -- or by one dropped heartbeat.
    hush(); release(2)
    ok(roster[1].reviveKey ~= nil and roster[1].reviveKey.arriveAt ~= nil,
        'a release after the ring closes does not cancel the arrival')
    ok(refusal() == nil, 'and the reviver is not told their hold stopped')

    fakeTime = fakeTime + (K.fadeMs or 400) + (K.focusMs or 1000) + 1
    hush(); hold()
    ok(roster[1].state == BR.PlayerState.ALIVE, 'and at the end, they are back in')
end

-- ---------------------------------------------------------------------------
describe('revive.brings-back')
do
    local _, dead, mate = downed()
    dead.hp = 0.0
    press(2, 1)
    hush(); finish(1, 2)

    ok(dead.state == BR.PlayerState.ALIVE, 'the subject is in the match again')
    ok(dead.hp == (K.reviveHp + 0.0),
        'on FULL health, which is his sentence of 2026-08-31 -- and NOT on the '
            .. '30 an in-person pick-up still hands back', dead.hp)
    ok(dead.armour == 0.0, 'with no armour -- theirs is on the ground with the '
        .. 'rest of their kit')

    -- ═══ THE KEY IS SPENT, AND SPENT MEANS GONE ═══
    --
    -- `held = false` would put it back on the market: `forSquad` filters on the
    -- record EXISTING, so nil is the only representation of "spent" that a
    -- second purchase cannot resurrect.
    ok(dead.reviveKey == nil, 'the key is nilled, not un-held')
    ok(BR.ReviveKey.outstanding('A', 1) == 0,
        'so the squad has nothing outstanding and cannot buy them back a second '
            .. 'time for the same death')

    -- ═══ EVERYTHING THE ELIMINATION WROTE IS UNWRITTEN ═══
    ok(dead.placement == nil,
        'the placement goes -- they have not finished anywhere')
    ok(dead.diedAt == nil, 'and so does the moment they stopped surviving')
    ok(dead.engineHp == nil,
        'and the last engine-health sample -- or the 1Hz server-observed death '
            .. 'check reads a stale corpse reading and eliminates them again a '
            .. 'second into the life they were just given')
    ok(dead.killedByLicense == nil,
        'and the spectate camera\'s memory of who killed them, so a LATER death '
            .. 'with no killer does not inherit this one')
    ok((dead.healthSettleUntil or 0) > fakeTime,
        'the health audit is told to expect the crossover, so a ledger that '
            .. 'leads the ped is not logged as a client inventing health',
        dead.healthSettleUntil)

    -- ═══ THE ORDER: THE PED IS TOLD BEFORE THE LEDGER IS ═══
    --
    -- protocol.lua's note: a client left holding a corpse while the server calls
    -- it ALIVE is exactly the state the server-observed death check exists to
    -- eliminate -- and it would eliminate them.
    local place, iRev = firstSent(BR.Net.REVIVEKEY_PLACE)
    local _, iState = firstSent('<setState>')
    ok(iRev ~= nil, 'the resurrection is sent to the machine that owns the ped')
    ok(iRev ~= nil and iState ~= nil and iRev < iState,
        'and it goes BEFORE the roster says ALIVE', ('%s vs %s'):format(iRev, iState))

    -- ═══ AND IT NAMES THE AMBULANCE, NOT THE BODY ═══
    --
    -- "put them 150m above the ambulance". The van is at the origin and the
    -- corpse is at (100, 100), so this assertion is the difference between the
    -- owner's answer and the one that shipped last round.
    ok(place ~= nil and place.d.x == 0.0 and place.d.y == 0.0,
        'and it carries the ambulance the hold was performed at, not the point '
            .. 'the body is lying on',
        place and ('(%.1f, %.1f)'):format(place.d.x, place.d.y))
    ok(firstSent(BR.Net.REVIVED) == nil,
        'and it is NOT BR.Net.REVIVED -- that one stands a body up exactly where '
            .. 'it fell, which is what #144 needs and the opposite of this')

    local hs = firstSent(BR.Net.HEALTH_SYNC)
    ok(hs ~= nil and hs.d.hp == K.reviveHp,
        'the client is told what the number IS, absolutely, the way every other '
            .. 'health correction in this project is')

    -- THE REVIVER IS CREDITED AND HIS RING IS CLOSED.
    ok(mate.revives == 1, 'the reviver is credited with the revive', mate.revives)
    local done = nil
    for _, s in ipairs(sent) do
        if s.ev == BR.Net.REVIVEKEY_PROGRESS and s.d.done then done = s end
    end
    ok(done ~= nil and done.src == 2, 'and their ring is told it landed')

    -- ═══ AND THE SQUAD IS TOLD, WHICH IS NEW ═══
    --
    -- This block used to assert that a completed revive said NOTHING, on the
    -- grounds that the owner had given no line for it. He gave one on
    -- 2026-08-31, so the assertion inverts rather than lapses -- and the ORDER
    -- of the two names is the half worth driving, because a reversed pair still
    -- reads as a sentence and would never be reported as a bug.
    --
    -- `mate` (src 2, "P2") performed the hold; `dead` (src 1, "P1") is the one
    -- coming back. His words: "(first is the reviver, second is the revived)".
    ok(#said == 1, 'a completed revive says one thing', #said)
    ok(said[1] and flat(said[1]) == K.copy.revived:format('P2', 'P1'),
        'and it is his line with the reviver first and the revived second',
        said[1] and flat(said[1]))
    local nm = said[1] and names(said[1]) or {}
    ok(nm[1] == 'P2' and nm[2] == 'P1' and #nm == 2,
        'both names travel as parts of their own, so the page can draw them '
            .. 'bold without anything having parsed a name',
        table.concat(nm, ' / '))
end

-- ---------------------------------------------------------------------------
describe('revive.storm')
do
    -- ═══ THE BUG THIS BLOCK EXISTS FOR, AND IT IS INVISIBLE IN A PLAYTEST ═══
    --
    -- server/storm.lua seeds its damage ledger from `e.stormHp` and only ever
    -- clamps it DOWN. Nothing clears that field on death -- only
    -- BR.Match.resetPlayer and stepping back inside the circle do. So a player
    -- the storm killed carries a stormHp at or below zero and is eliminated
    -- again on the very next storm tick they are outside the wall for,
    -- regardless of the health they were just handed.
    --
    -- MOVING THE ARRIVAL TO AN AMBULANCE MADE THIS LESS LIKELY AND NOT LESS
    -- REAL. They no longer come back on the spot the storm killed them, so the
    -- van is usually inside -- but a squad CAN drive an ambulance into the
    -- storm, and 150m up over a shrinking circle is not a promise of anything.
    --
    -- WHAT IT WOULD LOOK LIKE IN GAME: a squad spends 25 Volts and six seconds
    -- of standing in the open, their mate falls out of the sky on 30 hp, and
    -- dies again about a second later for no reason anyone can see. Being
    -- outside the wall is still a bad place to arrive -- that is the rule -- but
    -- the damage has to start from the health they were given.
    local _, dead = downed()
    dead.stormHp     = -12.0
    dead.lastStormAt = fakeTime

    press(2, 1)
    hush(); finish(1, 2)

    ok(dead.state == BR.PlayerState.ALIVE, 'the storm\'s victim is back up')
    ok(dead.stormHp == nil,
        'and the storm ledger is cleared -- a revived player must not be killed '
            .. 'again by a number recorded before they died', dead.stormHp)
    ok(dead.lastStormAt == nil,
        'and its clock with it, so the first tick after the revive measures from '
            .. 'now rather than from before the death')
end

-- ---------------------------------------------------------------------------
describe('revive.console')
do
    -- `/brkey revive` RUNS THE SAME PATH, WHICH IS server/rescue.lua's RULE FOR
    -- /brrescue: an admin verb that took a shortcut would be testing itself.
    --
    -- ═══ AND IT NEEDS AN AMBULANCE NOW, BECAUSE THE ARRIVAL IS SOMEWHERE ═══
    --
    -- The verb could once stand somebody up with no reviver and no van, because
    -- a key revive placed nobody anywhere. It places them 150m over a specific
    -- vehicle, so the console has to name one -- or finish a hold that already
    -- has.
    local _, dead = downed()
    local okNo, whyNo = BR.ReviveKey.revive(1)
    ok(okNo == false and whyNo ~= nil and whyNo:find('no ambulance') ~= nil,
        'with nobody holding and no van named there is nowhere to arrive, and '
            .. 'the console refuses rather than inventing a spot', whyNo)

    -- NAMING BOTH IS THE ONE WAY IN FROM COLD, and it runs the real ruling.
    downed()
    local okRev, whyRev = BR.ReviveKey.revive(1, 2, VAN)
    ok(okRev == true, 'a named reviver at a named ambulance revives', whyRev)
    ok(roster[1].state == BR.PlayerState.ALIVE,
        'and it goes through the same door')
    ok(roster[1].reviveKey == nil, 'spending the key exactly as a hold does')
    local place = firstSent(BR.Net.REVIVEKEY_PLACE)
    ok(place ~= nil and place.d.x == 0.0,
        'and places them over that van', place and place.d.x)

    -- FINISHING A RUNNING HOLD NEEDS NEITHER ARGUMENT: the van is on the record.
    dead = select(2, downed())
    press(2, 1)
    local okHold, whyHold = BR.ReviveKey.revive(1)
    ok(okHold == true, 'and a hold already running can be finished bare', whyHold)
    ok(dead.state == BR.PlayerState.ALIVE, 'at the van that hold was at')

    -- ...AND IT IS NOT A CHEAT CODE. The ruling in front of it is the real one.
    downed({ held = false })
    local ok2, why2 = BR.ReviveKey.revive(1, 2, VAN)
    ok(ok2 == false and why2 == 'that key is not held yet',
        'a squad that does not own the key cannot have one handed to them from '
            .. 'the console either', why2)

    local m = downed()
    m.state = BR.MatchState.ENDED
    local ok3, why3 = BR.ReviveKey.revive(1, 2, VAN)
    ok(ok3 == false and why3 == 'not in a playing match',
        'and a finished match refuses the console too', why3)

    local ok4 = BR.ReviveKey.revive(999)
    ok(ok4 == false, 'a player who is not on the roster is refused')

    -- ═══ AND A NAMED REVIVER IS RULED ON, NOT TAKEN AT FACE VALUE ═══
    --
    -- `/brkey revive <subject> <netId> <reviver>` takes both ids from a console
    -- line, and the whole point of the verb is that it runs the SAME ruling a
    -- player's six seconds run. Without these cases the named branch is never
    -- driven at all. Found by mutation last round -- deleting the reviveAllowed()
    -- call from that branch left this suite green.
    downed({ dist = 90.0 })
    local ok5, why5 = BR.ReviveKey.revive(1, 2, VAN)
    ok(ok5 == false and why5 ~= nil and why5:find('not at an ambulance') ~= nil,
        'a named reviver standing across the map is refused from the console '
            .. 'exactly as they are in game', why5)
    ok(roster[1].state == BR.PlayerState.OUT, 'and nobody stood up')

    downed()
    roster[2].state = BR.PlayerState.OUT
    local ok6, why6 = BR.ReviveKey.revive(1, 2, VAN)
    ok(ok6 == false and why6 ~= nil and why6:find('the reviver is') ~= nil,
        'and so is a dead one', why6)

    -- A NET ID WITH NOBODY TO MEASURE IS NOT A REVIVE EITHER.
    downed()
    local ok7, why7 = BR.ReviveKey.revive(1, nil, VAN)
    ok(ok7 == false and why7 == 'name a reviver with the net id',
        'and a van with no reviver names a distance with no player in it', why7)
end

-- ---------------------------------------------------------------------------
describe('notify')
do
    -- ═══ EVERY WORD THIS MODULE SPEAKS IS ONE OF THE OWNER'S NINE ═══
    --
    -- The source check above stops a SECOND notify call site being added. This
    -- is the half that matters: it drives the real module through all of its
    -- speaking paths and asserts that what came out is character for character
    -- what config/revivekey.lua says. A helpful default in an `or` would pass
    -- the source check and fail here.
    --
    -- KEYED ON THE FORM, NOT ON THE FLAT TEXT. Four of his lines have holes in
    -- them, so the sentence a player reads is never equal to the line it came
    -- from. `formOf` puts the names back as `%s` -- which only works if the
    -- names travelled OUTSIDE the string, so this table is also the check that
    -- nothing formatted a name in.
    local byText = {}
    for k, v in pairs(K.copy) do byText[v] = k end

    -- THE MINT. A squad hears that a mate is gone and that there is something
    -- to go and get, and the mate himself does not -- he is watching his own
    -- body.
    wipe()
    fakeTime = 2000000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m
    local dead = put(1, { squadId = 'A', x = 300.0, y = 300.0 })
    put(2, { squadId = 'A', x = 300.0, y = 300.5 })
    hush(); BR.ReviveKey.onEliminated(m, 1)
    ok(#said == 1, 'a mint says one thing', #said)
    -- TWO HOLES NOW: the mate, and how long the pickup lasts. The duration is
    -- computed the same way the module computes it -- off `expiryMs`, through
    -- BR.Clock.words -- rather than written out here, so this asserts that the
    -- toast SAYS THE CONFIGURED WINDOW and not that it says "3 minutes". Retune
    -- `expiryMs` and this still passes, saying the new number; hardcode three
    -- minutes into the sentence and it fails.
    ok(said[1] and flat(said[1])
           == K.copy.bledOut:format('P1', BR.Clock.words(K.expiryMs)),
        'and it is his bled-out line, naming the mate who is gone and how long '
            .. 'their key is on the ground',
        said[1] and flat(said[1]))
    ok(said[1] and flat(said[1]):find('3 minutes', 1, true) ~= nil,
        '...which on today\'s expiryMs of 180000 reads "3 minutes"',
        said[1] and flat(said[1]))
    ok(said[1] and type(said[1].who) == 'table'
       and #said[1].who == 1 and said[1].who[1] == 2,
        'told to the REST of the squad -- "you have bled out" is not news to '
            .. 'the player watching his own body',
        said[1] and said[1].who and #said[1].who)

    -- COLLECTION. TWO SENTENCES, TWO AUDIENCES.
    dead.state = BR.PlayerState.OUT
    hush(); BR.ReviveKey.take(2, 1)
    ok(#said == 2, 'taking a key says two things, one per audience', #said)
    ok(said[1] and flat(said[1]) == K.copy.collect:format('P1'),
        'the collector gets his line for the collector',
        said[1] and flat(said[1]))
    ok(said[1] and said[1].who == 2,
        'and gets it alone', said[1] and tostring(said[1].who))
    ok(said[2] and flat(said[2]) == K.copy.collectedBy:format('P2', 'P1'),
        'everybody else gets his other line, collector first and the key\'s '
            .. 'owner second', said[2] and flat(said[2]))
    -- THE REST OF THE SQUAD INCLUDES THE ONE WHO IS OUT. "The key is picked up
    -- by the player, then owned by the SQUAD" -- and the person it brings back
    -- is watching their own body, which makes them the one who most wants to
    -- know. Only the COLLECTOR is off this list, because he is reading the
    -- other sentence.
    ok(said[2] and type(said[2].who) == 'table'
       and #said[2].who == 1 and said[2].who[1] == 1,
        'told to the rest of the squad, the eliminated player included and the '
            .. 'collector excluded',
        said[2] and said[2].who and #said[2].who)

    -- AND THE NAMES ARE NOT IN THE STRING. This is the property the owner's
    -- bold rule rests on and the one that a `:format` at a call site would
    -- delete while leaving every sentence above reading correctly.
    local nm = said[2] and names(said[2]) or {}
    ok(nm[1] == 'P2' and nm[2] == 'P1' and #nm == 2,
        'both names travelled as parts of their own, in his order',
        table.concat(nm, ' / '))

    -- EXPIRY. THE PICKUP GOES; THE KEY DOES NOT.
    wipe()
    fakeTime = 3000000
    matches[1] = { id = 1, state = BR.MatchState.PLAYING }
    local dead2 = put(1, { squadId = 'A', x = 400.0, y = 400.0 })
    BR.ReviveKey.onEliminated(matches[1], 1)
    dead2.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 900.0, y = 900.0 })
    fakeTime = fakeTime + K.expiryMs + 1000
    hush(); sweep()
    ok(#said == 1 and flat(said[1]) == K.copy.expired,
        'a pickup running out says the owner\'s line for it',
        said[1] and flat(said[1]))
    hush(); sweep()
    ok(#said == 0,
        'and says it ONCE -- the record keeps being swept because it is still '
            .. 'buyable for the rest of the match', #said)

    -- PURCHASE. ONE PRESS, ONE SENTENCE, HOWEVER MANY KEYS IT COVERED.
    wipe()
    fakeTime = 4000000
    matches[1] = { id = 1, state = BR.MatchState.PLAYING }
    for _, id in ipairs({ 1, 3, 4 }) do
        local d = put(id, { squadId = 'A', x = 500.0 + id, y = 500.0 })
        BR.ReviveKey.onEliminated(matches[1], id)
        d.state = BR.PlayerState.OUT
    end
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })
    hush()
    BR.ReviveKey.buy(2, 9201)
    settle(true, nil, 500)
    ok(#said == 1 and flat(said[1]) == K.copy.bought,
        'one purchase says one thing, not one thing per key', #said)

    -- AND NOTHING ELSE EVER CAME OUT, IN ANY SHAPE.
    --
    -- Run over EVERY notice this suite has captured rather than only the
    -- purchase's -- `said` is not hushed between the sections above, so this
    -- sweeps the mint, both collection lines, the expiry and the purchase.
    local strayed = nil
    for _, entry in ipairs(said) do
        if byText[formOf(entry)] == nil then strayed = flat(entry) end
    end
    ok(strayed == nil,
        'no string left this module that is not one of the owner\'s nine, and '
            .. 'every name that left it was outside the string',
        strayed)
end

-- ---------------------------------------------------------------------------
describe('net')
do
    -- THE HANDLERS ARE REGISTERED AND THEY REFUSE RUBBISH.
    ok(handlers[BR.Net.REVIVEKEY_BUY] ~= nil,
        'the buy handler is registered')
    ok(handlers[BR.Net.REVIVEKEY_TAKE] ~= nil,
        'and so is the take handler -- the pickup is a press now, so there is '
            .. 'an event where the protocol used to say there must never be one')

    wipe()
    fakeTime = 700000
    matches[1] = { id = 1, state = BR.MatchState.PLAYING }
    _G.source = 2
    handlers[BR.Net.REVIVEKEY_BUY]('not a table')
    handlers[BR.Net.REVIVEKEY_BUY](nil)
    handlers[BR.Net.REVIVEKEY_BUY]({})
    ok(#charges == 0,
        'and a malformed or empty payload charges nobody anything', #charges)

    handlers[BR.Net.REVIVEKEY_TAKE]('not a table')
    handlers[BR.Net.REVIVEKEY_TAKE](nil)
    handlers[BR.Net.REVIVEKEY_TAKE]({})
    handlers[BR.Net.REVIVEKEY_TAKE]({ target = 'me' })
    ok(true, 'and a malformed take payload is survived rather than thrown on')
end

-- ---------------------------------------------------------------------------
describe('arrive.withdrawn')
do
    -- ═══ THE ONE WAY A PROMISED ARRIVAL CAN FAIL, AND IT MUST BE TAKEN BACK ═══
    --
    -- Between the ring closing and the ped being placed there is a second and a
    -- half of black screen on somebody else's machine, held on this server's
    -- word. A match that ends inside that window -- the elimination that made
    -- the last key is often the one that ends the match -- would otherwise leave
    -- the subject staring at black with the streaming focus parked on a van, and
    -- nothing in the game to take either back. The client has its own deadline
    -- as the second net; this is the first.
    local m, dead = downed()
    press(2, 1)
    fakeTime = fakeTime + (K.reviveHoldMs or 6000) + 1
    hush(); press(2, 1); hold()
    ok(dead.reviveKey.arriveAt ~= nil, 'the arrival is armed')

    m.state = BR.MatchState.ENDED
    fakeTime = fakeTime + (K.fadeMs or 400) + (K.focusMs or 1000) + 1
    hush(); hold()

    local off = firstSent(BR.Net.REVIVEKEY_ARRIVE)
    ok(off ~= nil and off.src == 1 and off.d.cancelled == true,
        'a match that ends under the fade withdraws the promise, to the subject')
    ok(firstSent(BR.Net.REVIVEKEY_PLACE) == nil, 'and places nobody')
    ok(dead.state == BR.PlayerState.OUT,
        'and stands nobody up into a match whose results are published')
    ok(dead.reviveKey ~= nil and dead.reviveKey.held == true,
        'and the key is NOT spent -- nothing was delivered, so nothing is paid')
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    -- THE MODULE'S LAST WORDS, ON A FAILURE ONLY. Silenced above so the gate
    -- reads cleanly across twenty-five suites; printed here because a failing
    -- assertion is exactly when what the module thought it was doing is worth
    -- having, and this is the only place it can still be recovered.
    realPrint('\27[2m-- last ' .. #printed .. ' module line(s) --\27[0m')
    for _, line in ipairs(printed) do realPrint('\27[2m' .. line .. '\27[0m') end
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end

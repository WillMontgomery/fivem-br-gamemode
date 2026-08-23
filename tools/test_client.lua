-- Unit tests for the CLIENT-SIDE interactions: the interact key, the crate
-- hold, and the pickup path from a keypress through to an inventory delta.
--
-- WHY THIS FILE EXISTS (#140).
--
-- tools/verify.sh ran 1,629 tests before this one and every single one of them
-- was server-side or pure arithmetic -- the roster, the state machine, the XP
-- curve, the ban rule, the scheduler. Nothing exercised a client interaction,
-- and every one of the last three regressions landed there: the crate open that
-- was a timer with a keypress in front of it (#129, first round), the hold that
-- started and never completed (#129, second round), and the crate that did
-- nothing at all while loose-loot pickup broke alongside it (#129 third round,
-- #139). Three failures, all invisible to the gate, all obvious in ten seconds
-- of play. That ratio is the worst possible one, because it makes the expensive
-- check -- a human booting a client -- the only check that works.
--
-- The obstacle is real: these paths call FiveM natives and there is no client
-- harness. It is also the same obstacle the server tests already solved.
-- tools/test_roster.lua stubs the natives at the top and loads the real modules
-- underneath; this does the same for client/keybinds.lua, client/loot.lua and
-- client/inventory.lua, and steps the frame band by hand through
-- BR.Loop.step().
--
-- THE KEYBOARD IS MODELLED, NOT MOCKED, AND THAT IS THE WHOLE VALUE OF THE
-- FILE. There are three separate mechanisms that can answer "is the interact
-- key down", they behave differently, and #129's second and third rounds were
-- both a hold being driven by the wrong one:
--
--   1. IS_RAW_KEY_DOWN     -- a per-frame LEVEL. The good one.
--   2. IS_RAW_KEY_PRESSED  -- a single-frame EDGE (KeyDown & changed), which
--                             reads "not held" on fifty-nine frames in sixty.
--   3. the engine's +brinteract / -brinteract pair, delivered by
--      RegisterKeyMapping on the press and the release.
--
-- So the harness below delivers a physical key press to BOTH the raw sample and
-- the engine command pair, every time, exactly as a real client does -- and
-- then lets the code under test decide which of them is allowed to act. That is
-- the arrangement that makes the third-round failure detectable at all: if both
-- paths decline, nothing fires, and the tests that follow say so instead of a
-- playtester having to.
--
-- WHAT THIS DELIBERATELY DOES NOT COVER: anything that needs the engine to be
-- honest. The prop, the DUI prompt, the ray-cast, the ring animation and the
-- server's own claim arbitration are all stubbed or absent. A pickup here is
-- proved as far as the LOOT_CLAIM leaving the client and an INV_SET coming back
-- into the mirror; whether the crate model actually swaps for its husk is not
-- something a Lua process can be asked.

-- ------------------------------------------------------------ native stubs ---

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerServerId() return 1 end
function PlayerId() return 0 end
function PlayerPedId() return 1 end

--- THE SERVER'S REPLICATED CONVARS, AS THIS CLIENT SEES THEM.
---
--- Modelled rather than stubbed away because #165 turned on one of them: two
--- pma-voice convars decide whether a rendering scripted camera turns this
--- client into a spectator of everybody in scope, and whether pma-voice draws
--- its own overlay -- and BOTH were "fixed" last round by writing a line into
--- server.cfg.example, which no deploy has ever copied to a server. An empty
--- table is therefore the DEFAULT here, because an unconfigured box is the
--- state the issue was reported from.
local convars = {}
function GetConvar(name, default)
    local v = convars[name]
    return v == nil and default or tostring(v)
end
function GetConvarInt(name, default)
    local v = tonumber(convars[name])
    return v == nil and default or math.floor(v)
end

--- THIS CLIENT'S OWN STATE BAG.
---
--- AN EMPTY ONE, AND IT IS SCAFFOLDING RATHER THAN A MODEL. It used to be
--- `{ voiceIntent = 'speech' }` under twenty lines explaining how those keys
--- tell one pma-voice version from another, because this suite carried a block
--- asserting br_core could detect a pre-v7.0.1-rc2 install. That detector is
--- gone -- the warning it existed to blame on an old pma-voice was vMenu's own
--- voice chat (#185) -- and the fixture went with it.
---
--- WHAT IS LEFT IS HERE ON PURPOSE, WHICH IS THE ONLY REASON TO KEEP A STUB
--- NOTHING CURRENTLY READS. LocalPlayer.state is a real FiveM global that any
--- client file may legitimately touch -- pma-voice's own disableProximity and
--- disableRadio live on it -- and a harness that raises on the first read of a
--- runtime global fails in a way that looks like a bug in the code under test.
--- An empty table answers "no key set", which is the honest default.
pmaBag = {}
LocalPlayer = setmetatable({}, { __index = function(_, k)
    if k == 'state' then return pmaBag end
end })

local realPrint = print
local logged = {}
function print(s) logged[#logged + 1] = tostring(s) end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
function RegisterNetEvent() end

-- Console commands, kept so the engine's +/- delivery can be driven and so the
-- debug readouts (/brloot, /brkeys) can be exercised -- they are the only
-- diagnostic a playtester has, and a readout that throws is worse than none.
local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end

-- RegisterKeyMapping is the ENGINE's half of the binding. What is recorded here
-- is what FiveM would actually deliver: the command name, which for a hold is
-- `+brinteract` and which FiveM answers with `-brinteract` on the release. A
-- bare name would give one edge and repeat while held, so the `+` is asserted
-- on rather than assumed.
local keymap = {}      -- [keyName] = command as registered
function RegisterKeyMapping(cmd, _desc, _device, key)
    keymap[key] = cmd
end

local events = {}
function TriggerEvent(n, ...)
    events[#events + 1] = { name = n, args = { ... } }
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end
local sent = {}
function TriggerServerEvent(n, ...) sent[#sent + 1] = { name = n, args = { ... } } end

local kvpStore = {}
function SetResourceKvp(k, v) kvpStore[k] = v end
function GetResourceKvpString(k) return kvpStore[k] end
function DeleteResourceKvp(k) kvpStore[k] = nil end

-- The KVP round trip has to be a real one: the rebind block below saves a
-- binding and the raw layer reads it back, and `load()` measures the stored
-- string with `#raw` before it decodes it. Handing a table straight through
-- would make that a length-of-table error rather than a test.
local kvpBlobs = {}
json = {
    encode = function(t)
        local key = 'blob:' .. tostring(#kvpBlobs + 1)
        kvpBlobs[#kvpBlobs + 1] = t
        kvpBlobs[key] = t
        return key
    end,
    decode = function(s) return kvpBlobs[s] end,
}

-- ------------------------------------------------------------- the keyboard ---

--- Physically-held keys, by Windows virtual-key code.
local keys = {}
--- Keys that went down on THIS frame. IS_RAW_KEY_PRESSED is
--- `keys[active][k] & changed(k)` in FiveM's InputNatives.cpp -- an edge, true
--- for exactly one frame -- and modelling it as a level would hide the entire
--- second round of #129.
local edge = {}
--- Keys the raw sample is LYING about this frame: physically down, reading up.
--- citizenfx/fivem#3064 reports exactly this for IS_RAW_KEY_DOWN around a NUI
--- focus change, and a hold that cannot survive it is a hold that cannot be
--- completed on a machine that ever opens a menu.
local lying = {}
--- Codes the raw natives are BLIND to for this whole simulated build, however
--- hard the key is held.
---
--- DIFFERENT FROM `lying` IN THE ONE WAY THAT MATTERS: `lying` is a dropout, one
--- frame long, cleared at the end of every frame(). This is a PROPERTY OF THE
--- BUILD and persists, because that is the shape #203's leading candidate has --
--- "IsRawKeyDown does not answer for shift on this machine, ever". A per-frame
--- dropout cannot express it, and it is the state in which GTA's own controls
--- see the key and we do not.
local rawBlind = {}

--- WHAT THE NATIVE HANDS BACK, WHICH IS NOT THE SAME QUESTION AS WHAT IT MEANS.
---
--- The stub these tests ran on for six rounds was `return keys[vk] == true` --
--- a strict Lua boolean. keybinds.lua then stored that value and compared it
--- with `== true` in two places. Stub and code agreed, the suite passed 202
--- assertions, and the interaction was dead on the owner's client: one press of
--- the trail key counted 545 presses and toggled the smoke 545 times, and a
--- crate hold ran 446 frames earning 0 of 1000ms (#129/#131, 2026-08-16).
---
--- A STUB THAT AGREES WITH THE CODE IT TESTS PROVES NOTHING. FiveM natives
--- declared BOOL do not have to hand Lua a boolean, and this codebase already
--- carries two scars from exactly that -- natives.lua compares `hit == 1 or
--- hit == true` on the shape test, spawn.lua compares `== true or == 1` on the
--- screen fade. Both were written after the value arrived as a NUMBER in play.
---
--- So the shape is a dimension of the test matrix now, alongside which natives
--- the build has. `1/0` is in the list specifically because 0 is TRUTHY in Lua:
--- it is the shape that punishes the obvious one-line normalisation
--- (`v and true or false`), which would read a released key as held forever.
local SHAPES = {
    { name = 'boolean true/false', down = true, up = false },
    { name = 'number 1 / false',   down = 1,    up = false },
    { name = 'number 1 / 0',       down = 1,    up = 0     },
    { name = 'number 1 / nil',     down = 1,    up = nil   },
}

--- Which raw natives this simulated BUILD has, and in what shape it answers.
--- Flipped per block so the same interaction is proved on every mechanism
--- rather than on the developer's.
local build = { rawDown = true, rawPressed = true, shape = SHAPES[1] }

--- IS_RAW_KEY_DOWN -- a per-frame LEVEL. True for EVERY frame of a hold.
function IsRawKeyDown(vk)
    if not build.rawDown then error('IS_RAW_KEY_DOWN: no such native', 0) end
    if lying[vk] or rawBlind[vk] then return build.shape.up end
    if keys[vk] then return build.shape.down end
    return build.shape.up
end

--- IS_RAW_KEY_PRESSED -- `keys[active][k] & changed(k)` in FiveM's
--- InputNatives.cpp. An EDGE: true for EXACTLY the first frame of a hold.
function IsRawKeyPressed(vk)
    if not build.rawPressed then error('IS_RAW_KEY_PRESSED: no such native', 0) end
    if edge[vk] then return build.shape.down end
    return build.shape.up
end

--- THE HARNESS'S OWN KEYBOARD, KEPT SO A LATER BLOCK CAN HAND IT BACK.
---
--- Blocks further down this file legitimately swap a native for a narrower stub
--- of their own -- #207's map block replaces IsRawKeyDown with an escape-key
--- model, because what it is testing is the escape key and nothing else. That is
--- fine right up until a block AFTER it needs the real keyboard, at which point
--- the failure is silent and looks like a bug in the code under test: #203's
--- boost block inherited the escape stub, every shift read came back up, and
--- three verdicts changed to ones that name the wrong file entirely.
---
--- One reference, restored by whoever needs it, is cheaper than a rule about
--- who has to tidy up.
local RAW_KEYBOARD = { down = IsRawKeyDown, pressed = IsRawKeyPressed }

-- ------------------------------------------------------------------ world ---

local pedPos = { x = 0.0, y = 0.0, z = 30.0 }
local inVehicle = false

--- OTHER PLAYERS, AND WHETHER THE GAME HAS SPAWNED ONE FOR US.
---
--- [serverId] = { x, y } for a player the client can see, or `false` for a
--- player who is on the roster but OUT OF SCOPE -- connected, known by name,
--- and with no ped on this machine.
---
--- Both cases are load-bearing. Voice decides the proximity cutoff from the
--- ped, because the server never tells a client where a stranger is standing,
--- and "no ped" therefore has to resolve to "too far to hear" rather than to an
--- error or to a default of zero -- a default of zero would put every
--- out-of-scope player at the origin and make half the map audible.
local others = {}

--- A ped handle that cannot collide with the local player's, which is 1.
local function pedOf(src) return 5000 + src end

function GetPlayerFromServerId(src)
    return others[src] and src or -1
end
function GetPlayerPed(ply)
    -- 0 is the engine's "no such ped", which is what an out-of-scope player
    -- resolves to and is the case the gate has to survive.
    return others[ply] and pedOf(ply) or 0
end
function GetEntityCoords(ped)
    if ped == nil or ped == 1 then return pedPos end
    local p = others[ped - 5000]
    if p then return { x = p.x, y = p.y, z = 30.0 } end
    return pedPos
end
function GetEntityForwardVector() return { x = 1.0, y = 0.0, z = 0.0 } end
function GetEntityRotation() return { x = 0.0, y = 0.0, z = 0.0 } end
function GetEntityVelocity() return { x = 0.0, y = 0.0, z = 0.0 } end
function GetGroundZFor_3dCoord() return true, 30.0 end
function GetWaterHeight() return false, 0.0 end
function GetHashKey() return 1 end
function GetWeapontypeModel() return 1 end
function IsModelValid() return true end
function HasModelLoaded() return true end
function CreateObjectNoOffset() return 0 end
function DoesEntityExist() return false end
function IsPedInAnyVehicle() return inVehicle end
--- WHAT THE ENGINE SAYS IS IN THE HAND, and it is a variable rather than a
--- constant because two things read it and they disagree about what a `false`
--- means. The ammo report treats "no answer" as a reason to say nothing; the
--- strip check treats it the same way, which is why the default below leaves
--- every case written before this one behaving exactly as it did.
---
--- nil means the engine declined to answer -- `ok == false`, the shape a ped
--- mid-animation or mid-stow produces -- and any number is a weapon actually
--- held.
--- `false` IS A THIRD ANSWER AND NOT A TYPO: the engine ANSWERED and named
--- NOTHING -- `ok == true`, hash nil. It is the shape that makes the difference
--- between "we could not read the hand" and "the hand is empty" testable, and
--- both of this file's weapon reads model it, because the strip check compares
--- the two against each other.
local pedWeapon = nil
function GetCurrentPedWeapon()
    if pedWeapon == nil then return false, 0 end
    if pedWeapon == false then return true, nil end
    return true, pedWeapon
end

--- THE GUN BOLTED TO THE VEHICLE, WHICH IS A DIFFERENT QUESTION FROM THE ONE
--- ABOVE AND THE WHOLE OF #216.
---
--- `GET_CURRENT_PED_VEHICLE_WEAPON` is `BOOL f(Ped, Hash*)`, so Lua gets the
--- BOOL and then the hash -- the same shape `GetCurrentPedWeapon` has, and it is
--- modelled with the same care, because the strip check reads BOTH and the bug
--- being fixed is that it only ever read one.
---
--- nil means THIS BUILD HAS NO OPINION -- `ok == false` -- which is what an
--- ordinary car, an ordinary ped on foot, and a build where the native is not
--- implemented all produce. That is the default, so every case written before
--- #216 keeps behaving exactly as it did.
---
--- `vehWeaponAnswersNumber` DRIVES THE BOOL'S SHAPE, for the reason
--- `controlsAnswerNumbers` below drives IsControlEnabled's: this is a FiveM BOOL
--- and this repo has shipped `v == true` on a build that answers `1` six times.
--- Both shapes are put through the same assertions.
--- `false` here is the same third answer `pedWeapon` above carries: the native
--- answered and named nothing.
---
--- A TABLE IS THE FOURTH: `{ notOk = h }` means the native REFUSED -- `ok ==
--- false` -- while still handing back a hash. That is the shape the whole `ok`
--- test exists for, and without it in the fixture the test that a refused answer
--- is not used cannot be written at all.
local vehWeapon = nil
local vehWeaponAnswersNumber = false
function GetCurrentPedVehicleWeapon()
    if vehWeapon == nil then return false, 0 end
    if type(vehWeapon) == 'table' then return false, vehWeapon.notOk end
    if vehWeapon == false then return (vehWeaponAnswersNumber and 1 or true), nil end
    return (vehWeaponAnswersNumber and 1 or true), vehWeapon
end
function GetAmmoInPedWeapon() return 0 end
function GetAmmoInClip() return false, 0 end
function GetPedArmour() return 0 end
function HasPedGotWeapon() return false end
function IsPauseMenuActive() return false end
function IsPedReloading() return false end
function IsPlayerFreeAiming() return false end
function IsDisabledControlJustPressed() return false end
function DoesBlipExist() return false end

-- ------------------------------------------------------------------ mumble ---
--
-- THE ENGINE'S ROUTING, MODELLED RATHER THAN COUNTED (#150).
--
-- Asserting "MumbleSetVoiceChannel was called with 2003" would have passed on
-- the build the owner reported. It WAS called, with the right number, on both
-- machines, and neither player could hear the other:
--
--   "when in solos, 'nearby' doesn't seem to work. It's just not passing any
--    audio. I had 2 players in the same match next to each other, neither
--    could hear."
--
-- So this keeps the two halves Mumble actually distinguishes, because the bug
-- lived in the gap between them:
--
--   CHANNEL  the room you are IN. Decides what you HEAR.
--   TARGET   a numbered list of destinations. Decides where your own audio
--            GOES. Being in a room does not put that room in your target, and
--            an empty target is a microphone wired to nothing.
--
-- WHAT THIS DELIBERATELY DOES NOT MODEL: what a real FiveM client does when no
-- resource ever selects a target. That is an engine default no Lua process can
-- be asked, it has changed across builds, and #150 is the receipt for relying
-- on it -- so the model treats "nothing selected" as "nothing sent" and the
-- tests below pin that the client always states its routing explicitly.
--
-- DISTANCE IS MODELLED NOW, AND IT WAS NOT, AND THAT WAS THE NEXT BUG (#157).
--
-- The note that used to sit here said distance happened "somewhere no test
-- here can see", so `hears` answered "is there a path at all" and stopped.
-- Every voice assertion passed on a build where two players a kilometre apart
-- could hold a conversation:
--
--   "even when set to nearby (while in squads or solos), the channel is
--    global. The off switch does work."
--
-- A stub that accepts any distance and never gates on it passes just as
-- happily as one that gates correctly, which is the SAME failure this file has
-- now had twice: modelling the call instead of the consequence. So the cutoff
-- is modelled as the engine applies it --
--
--   * a distance is a property of a SPEAKER (how far their voice carries) and
--     of a LISTENER (how far they can hear), never of a channel;
--   * NOTHING SET MEANS NO LIMIT, which is the whole of #157 -- it is the
--     default and it is why the map-wide conversation happened;
--   * it is BINARY on the stock convar path: inside the range, full volume;
--     outside it, nothing. No fade;
--   * a per-player volume override takes that speaker out of the calculation
--     entirely, which is the only way squad voice can outreach proximity.
--
-- -- and `hears` takes the metres between the two players, so a test has to
-- say where people are standing before it can claim they can talk.
-- A CHANNEL ID NAMES A ROOM THAT EXISTS, OR IT NAMES NOTHING.
--
-- THIS IS THE HOLE THE SUITE HAD, and it is why 77 assertions -- 31 of them
-- about voice -- passed green on a build where nobody could hear anybody
-- (#150, second report). The old stubs accepted any integer:
-- MumbleSetVoiceChannel(2003) put you in room 2003 instantly whether or not
-- room 2003 existed, and MumbleAddVoiceTargetChannel(1, 2003) faithfully
-- recorded a destination that was not there. So `hears` answered "yes, these
-- two can hear each other" about a pair of clients the engine was refusing
-- outright, and every voice assertion was checking the gamemode's arithmetic
-- against a fiction that could not be wrong.
--
-- The engine's own words, from the playtest these tests were supposed to have
-- made unnecessary:
--
--   Warning: [mumble] MUMBLE_ADD_VOICE_CHANNEL_LISTEN: Tried to call native
--   on a channel that didn't exist
--
-- WHAT THIS MODELS NOW, taken from what the engine actually does rather than
-- from what the native names suggest -- the three calls behave differently and
-- the differences are the bug:
--
--   SET_VOICE_CHANNEL          creates the room if it is missing, and joins
--                              it. Both take a round trip; neither happens in
--                              the calling frame.
--   ADD_VOICE_CHANNEL_LISTEN   refuses a missing room LOUDLY and drops it.
--   ADD_VOICE_TARGET_CHANNEL   refuses a missing room SILENTLY, drops it, and
--                              never retries.
--
-- That last one is why the first attempt at #150 looked correct and changed
-- nothing: it filled the voice target in the same frame as the join, before
-- the room existed, and the engine threw every one of those calls away without
-- a word. A stub that answers "channel joined" for a channel nobody created is
-- a stub that will keep lying, so this one refuses -- and, just as important,
-- refuses for a WHILE, because a stub that says yes instantly hides the race
-- just as thoroughly as one that never says no.
local mumble = {}
local function mumbleReset()
    mumble = {
        active   = true,
        channel  = 0,      -- room we are actually in
        want     = nil,    -- room we have asked to be in, not yet joined
        target   = 0,      -- selected voice target; 0 = none selected
        targets  = {},     -- [id] = { channel, ... }
        people   = {},     -- [id] = { serverId, ... }; targets that are PLAYERS
        listen   = {},     -- [channel] = true; rooms heard from outside
        prox     = nil,    -- last NetworkSetTalkerProximity
        -- THE TWO NUMBERS #157 WAS ABOUT. nil is not zero and not a default:
        -- it is "this game never told Mumble a range", which is the state the
        -- shipped build was in and the state in which everybody hears
        -- everybody at any distance.
        inDist   = nil,    -- how far our own voice carries
        outDist  = nil,    -- how far away we can hear from
        -- [serverId] = volume. A number here takes that speaker out of the
        -- distance calculation completely -- the native's documentation is
        -- explicit that it "will also bypass 3D audio and distance
        -- calculations" -- and -1 is the documented "stop overriding".
        volume   = {},
        -- Rooms that EXIST. 0 is the root channel every Mumble client starts
        -- in; it is the one room nobody has to create, and also the one room
        -- this gamemode must never leave anybody sitting in.
        channels = { [0] = true },
        pending  = {},     -- asked for, not yet echoed back by the server
        refused  = {},     -- calls the engine threw out, and which ones
        -- [serverId] = true while frames from that player are arriving. See
        -- MumbleIsPlayerTalking: this is the network, not the mixer.
        talking  = {},
        -- The Mumble client's own connection, which drops and returns
        -- underneath the game with no event to hang anything on. It is a
        -- field rather than a constant because the only thing that notices is
        -- the 1Hz watcher in voice.lua, and a test that cannot take the
        -- connection away cannot exercise it.
        connected = true,
        -- GTA'S OWN VOICE CHAT, WHICH IS A SEPARATE SWITCH FROM MUMBLE'S.
        --
        -- Owner, on the mode that is supposed to be silence: "When set to
        -- 'off', pressing the PTT button still shows that I'm talking." The
        -- prose he is looking at is the GAME's, not ours -- ours is the
        -- bottom-centre panel talkingNames() reads. MumbleSetActive(false) says
        -- nothing about this one, so `active` alone could never have caught it
        -- and 'off' passed green while the game announced him to the room.
        --
        -- Modelled as its own field for exactly that reason: two switches, two
        -- fields, and a test that can tell which one a fix actually threw.
        gameVoice = true,
    }
end
mumbleReset()

local function refuse(native, ch)
    mumble.refused[#mumble.refused + 1] = ('%s(%s)'):format(native, tostring(ch))
end

--- The SERVER creating a room, which is the only thing that can.
---
--- MUMBLE_CREATE_CHANNEL IS A SERVER NATIVE -- it is deliberately NOT defined
--- anywhere in this file, because defining it would let a future client-side
--- call look like it worked here and do nothing in the game. That is exactly
--- the shape of mistake #150 was: the missing call was being looked for in
--- client/voice.lua, among the other 29 Mumble natives, and it was never going
--- to be there. server/voice.lua calls this; the client cannot.
local function serverCreates(ch)
    if ch and not mumble.channels[ch] then mumble.pending[ch] = true end
end

--- MUMBLE_SET_ACTIVE, AND IT IS NOT A MICROPHONE SWITCH.
---
--- THIS STUB USED TO BE `mumble.active = v` AND THAT ONE LINE IS WHY A VOICE
--- REGRESSION SHIPPED GREEN. 58502b0 gagged a 'nearby' rider on the bus by
--- calling this native with false and un-gagged them by calling it with true,
--- and every assertion in this file agreed that was a microphone -- because
--- this function said so, and because hears() below only ever asked the SPEAKER
--- about it. The owner then reported the fourth silent 'nearby' in this
--- project's history: two players in one squad, both on 'nearby', standing
--- together, no audio.
---
--- WHAT THE NATIVE ACTUALLY DOES, and this project wrote it down ITSELF in
--- 475429f while researching a different native: MUMBLE_SET_ACTIVE sets
--- g_voiceActiveByScript, and Mumble_ShouldConnect reads VoiceChatPrefs &&
--- OneSync && g_voiceActiveByScript. So `false` is a DISCONNECT. The Mumble
--- client goes away, and it takes the joined channel and the voice target with
--- it -- the same two things `describe('a Mumble reconnect...')` below already
--- models a drop as destroying. `true` starts a reconnect and restores neither;
--- something in client/voice.lua has to re-join and re-route, and the only
--- thing that ever does is a pass through apply() with `applied` false.
---
--- SO IT IS MODELLED AS WHAT IT IS. `active` stays, because 'off' is still
--- entitled to ask for silence and the assertions about it are about the
--- microphone -- but the collateral is here now, so a fix that reaches for this
--- native anywhere except apply() has to prove it rebuilds what it broke.
--- Nothing in this file may make that cheaper. The three assertions this
--- honesty changed are in the bus block; read that block before softening this.
function MumbleSetActive(v)
    mumble.active = v and true or false
    if not mumble.active then
        mumble.connected = false
        mumble.channel   = nil          -- in no room at all, not even the root
        mumble.targets, mumble.people, mumble.target = {}, {}, 0
    else
        -- A reconnect ATTEMPT. Being connected again is not being routed again:
        -- the room and the target stay gone until voice.lua asks for them.
        mumble.connected = true
    end
end
function MumbleIsConnected() return mumble.connected end

--- NETWORK_SET_VOICE_ACTIVE -- the GAME's voice chat, not Mumble's.
---
--- Defined here because voice.lua now calls it, guarded, on the 'off' path. It
--- is a stock GTA native and this is what it is for; what nobody on this
--- project has watched is whether it suppresses the specific "currently
--- talking" prose the owner reported seeing while muted. The suite can only
--- prove the call is made and paired -- off turns it off, every other mode
--- turns it back on -- which is the honest limit and is exactly what is
--- asserted below. The rest is a playtest.
function NetworkSetVoiceActive(v) mumble.gameVoice = v and true or false end

--- IS THIS PLAYER SENDING US FRAMES? Note what this is NOT: it is not "can we
--- hear them". The engine sets it from decoded packets arriving, which happens
--- for every player in the room regardless of what the mixer then does with the
--- audio -- which is exactly why the indicator could name people the owner
--- could not hear. Modelled as a fact about the network, not about volume, so
--- that a client which filtered it by nothing would still fail the assertions.
--- @param ply integer player index; the stub's index IS the server id
function MumbleIsPlayerTalking(ply) return mumble.talking[ply] == true end
function MumbleDoesChannelExist(ch) return mumble.channels[ch] == true end

--- Which room the engine believes a player is in. -1 for "none I know of",
--- which is the state the settle band exists to wait out.
function MumbleGetVoiceChannelFromServerId(_)
    if mumble.channel == nil then return -1 end
    return mumble.channel
end

--- JOINING IS A REQUEST, NOT AN ASSIGNMENT -- and it is also how a room comes
--- into existence at all from the client's side. Neither half lands in the
--- calling frame: the Mumble client does its channel work on a timer of its
--- own and then waits for the server. mumbleSettle() is that reply arriving.
function MumbleSetVoiceChannel(ch) mumble.want = ch end
function MumbleClearVoiceChannel() mumble.channel, mumble.want = 0, nil end
function NetworkSetTalkerProximity(d) mumble.prox = d end
function MumbleSetVoiceTarget(id) mumble.target = id end
function MumbleClearVoiceTarget(id)
    mumble.targets[id] = {}
    mumble.people[id] = {}
end

--- HOW FAR A VOICE CARRIES, which nothing in this project ever set (#157).
---
--- Recorded rather than acted on immediately, because the consequence is at
--- the far end: `hears` below is where a distance actually decides something.
function MumbleSetAudioInputDistance(d) mumble.inDist = d end
function MumbleSetAudioOutputDistance(d) mumble.outDist = d end

--- A TARGET THAT NAMES A PLAYER, NOT A ROOM (#157).
---
--- The critical difference from MumbleAddVoiceTargetChannel above, and the
--- reason squad voice moved onto it: this resolves against the Mumble USER
--- list, so there is no room to be missing and nothing to refuse. It cannot
--- produce the "channel that didn't exist" warning because it never names a
--- channel. Modelled as always accepted for exactly that reason.
function MumbleAddVoiceTargetPlayerByServerId(id, serverId)
    mumble.people[id] = mumble.people[id] or {}
    table.insert(mumble.people[id], serverId)
end

--- THE ONE LEVER WITH PER-PLAYER GRANULARITY. -1 is "stop overriding" and is
--- modelled as removing the entry, not as a volume of -1: leaving it in place
--- would keep the speaker out of the distance calculation, which is the
--- opposite of what clearing it means.
function MumbleSetVolumeOverrideByServerId(serverId, volume)
    if volume == nil or volume < 0 then
        mumble.volume[serverId] = nil
    else
        mumble.volume[serverId] = volume
    end
end
function MumbleAddVoiceTargetChannel(id, ch)
    -- THE SILENT ONE, AND THE BUG. The listen below announces its refusal in
    -- the console, which is what finally identified this; the target just
    -- drops the channel, ships an empty packet, clears the pending update and
    -- never tries again -- leaving a microphone wired to nothing and no
    -- diagnostic anywhere.
    if not mumble.channels[ch] then
        return refuse('MUMBLE_ADD_VOICE_TARGET_CHANNEL', ch)
    end
    mumble.targets[id] = mumble.targets[id] or {}
    table.insert(mumble.targets[id], ch)
end
function MumbleAddVoiceChannelListen(ch)
    if not mumble.channels[ch] then
        return refuse('MUMBLE_ADD_VOICE_CHANNEL_LISTEN', ch)
    end
    mumble.listen[ch] = true
end
function MumbleRemoveVoiceChannelListen(ch) mumble.listen[ch] = nil end

--- Everything about one machine's voice routing, frozen.
--- @return table
local function mumbleSnapshot()
    local t = {}
    for _, ch in ipairs(mumble.targets[mumble.target] or {}) do
        t[#t + 1] = ch
    end
    local p = {}
    for _, sid in ipairs(mumble.people[mumble.target] or {}) do
        p[#p + 1] = sid
    end
    local l = {}
    for ch in pairs(mumble.listen) do l[ch] = true end
    local ex = {}
    for ch in pairs(mumble.channels) do ex[ch] = true end
    local vol = {}
    for sid, v in pairs(mumble.volume) do vol[sid] = v end
    return { active = mumble.active, channel = mumble.channel,
             selected = mumble.target, sends = t, people = p, listen = l,
             prox = mumble.prox, exists = ex,
             inDist = mumble.inDist, outDist = mumble.outDist, volume = vol,
             src = BR.State.me.src, gameVoice = mumble.gameVoice,
             refused = table.concat(mumble.refused, ' ') }
end

--- The range in force between two machines, in metres, or nil for "no limit".
---
--- NIL IS THE DEFAULT AND NIL IS THE BUG. Neither side having stated a
--- distance is precisely the shipped state #157 describes, and it has to come
--- out of this function as "no limit" rather than as some invented fallback --
--- otherwise the model quietly fixes the thing the test is meant to catch.
--- @return number|nil
local function cutoff(speaker, listener)
    local a, b = speaker.inDist, listener.outDist
    if a == nil or a <= 0 then a = nil end
    if b == nil or b <= 0 then b = nil end
    if a == nil then return b end
    if b == nil then return a end
    return math.min(a, b)
end

--- Can `speaker` be heard by `listener`, standing `metres` apart?
---
--- TWO QUESTIONS, AND #150 AND #157 ARE ONE EACH. Is there a path at all --
--- does the speaker's microphone reach this listener -- and if there is, does
--- the listener's mixer play it or throw it away for being too far off.
--- @param metres number|nil  how far apart they are standing; 0 if omitted
--- @return boolean
local function hears(speaker, listener, metres)
    -- MumbleSetActive IS A MICROPHONE SWITCH AND NOTHING ELSE, which is why
    -- only the SPEAKER is asked about it. A listener with MumbleSetActive(false)
    -- goes on hearing every stream in the room -- that is the engine's actual
    -- behaviour and it is the whole of the owner's "'off' does not work... it
    -- always feeds audio through regardless of distance". Adding
    -- `listener.active` here would make 'off' pass for free and would model a
    -- gate the engine does not have, so it is deliberately absent: 'off' has to
    -- be earned on the receive side, one mute at a time, or it does not pass.
    if not speaker.active then return false end

    local routed = false
    for _, ch in ipairs(speaker.sends) do
        if ch == listener.channel or listener.listen[ch] then routed = true end
    end
    -- ...or the speaker named this listener outright, which needs no room.
    for _, sid in ipairs(speaker.people) do
        if sid == listener.src then routed = true end
    end
    if not routed then return false end

    -- AN OVERRIDE REPLACES THE CUTOFF -- IN BOTH DIRECTIONS.
    --
    -- THIS LINE USED TO SAY `return true` AND THAT WAS THE HOLE. Any override
    -- at all meant audible, so the model could not express a mute at all, and
    -- the entire receive side was untestable: a client that silenced somebody
    -- and a client that did nothing produced the same answer here.
    --
    -- The engine, from voip-mumble/src/MumbleAudioOutput.cpp:
    --
    --   if (client->overrideVolume >= 0.0f)
    --       shouldHear = client->overrideVolume >= 0.005f;
    --
    -- So an override does not mean "hear them". It means "ignore distance and
    -- use this number", and 0.0 is below the floor -- inaudible, wherever they
    -- are standing. That is the whole mechanism the cutoff now runs on, and
    -- 1.0 is the squad radio riding the same native in the other direction.
    local override = listener.volume[speaker.src]
    if override ~= nil then return override >= 0.005 end

    local range = cutoff(speaker, listener)
    if range == nil then return true end   -- no range stated: the #157 bug
    return (metres or 0) <= range
end

local function noop() end
for _, n in ipairs({
    'ActivatePhysics', 'AddBlipForCoord', 'AddBlipForRadius',
    'AddTextComponentSubstringPlayerName', 'BeginTextCommandSetBlipName',
    'DeleteEntity', 'DisableControlAction', 'DrawLightWithRange', 'DrawMarker',
    'EndTextCommandSetBlipName', 'FreezeEntityPosition', 'GiveWeaponToPed',
    'PlaceObjectOnGroundProperly', 'PlaySoundFrontend', 'RemoveAllPedWeapons',
    'RemoveBlip', 'RemoveWeaponFromPed', 'RequestModel', 'SetAmmoInClip',
    'SetBlipAlpha', 'SetBlipAsShortRange', 'SetBlipColour', 'SetBlipScale',
    'SetBlipSprite', 'SetCurrentPedWeapon', 'SetEntityAsMissionEntity',
    'SetEntityCollision', 'SetEntityCoordsNoOffset', 'SetEntityDrawOutline',
    'SetEntityDrawOutlineColor', 'SetEntityDynamic', 'SetEntityHasGravity',
    'SetEntityHeading', 'SetEntityRotation', 'SetEntityVelocity',
    'SetModelAsNoLongerNeeded', 'SetObjectPhysicsParams', 'SetPedAmmo',
    'SetPedArmour', 'SetPedInfiniteAmmo', 'SetPedInfiniteAmmoClip',
    'SetPlayerMaxArmour', 'SetWeaponsNoAutoswap',
    -- The overlay's drawing half. /brdriveby shares a file with it, so the file
    -- is loaded, so its FRAME callback runs -- it early-returns while the
    -- overlay is off, and these exist so that a future test which turns the
    -- overlay ON does not fail as a native error.
    'DrawRect', 'SetTextFont', 'SetTextScale', 'SetTextColour',
    'SetTextDropshadow', 'SetTextEdge', 'SetTextDropShadow', 'SetTextOutline',
    'BeginTextCommandDisplayText', 'EndTextCommandDisplayText',
    'RequestCollisionAtCoord',
}) do _G[n] = noop end

-- ------------------------------------------------------------- drive-by ---
--
-- #197's natives, MODELLED RATHER THAN NOOPED, because every one of them is a
-- fact the diagnosis turns on.

--- SET_PLAYER_CAN_DO_DRIVE_BY, COUNTED.
---
--- A noop here could not tell "we assert this every tick" from "we asserted it
--- once, ten minutes ago, in a branch that has not run since" -- and that
--- distinction IS #197's first candidate. The counter is what makes the
--- cadence assertable at the desk.
local driveByCalls = 0
function SetPlayerCanDoDriveBy() driveByCalls = driveByCalls + 1 end

--- The seat. `inVehicle` above drives IsPedInAnyVehicle; these two carry the
--- rest of what a seat is.
local vehicle, vehicleSeat = 0, nil
function GetVehiclePedIsIn() return vehicle end
function GetPedInVehicleSeat(_veh, seat)
    -- The local ped is 1 (PlayerPedId). Anything else is an empty seat, and an
    -- empty seat is 0, which is what the engine answers.
    return seat == vehicleSeat and 1 or 0
end
function GetEntityModel() return 42 end
function GetDisplayNameFromVehicleModel() return 'BALLER' end
function IsPedDoingDriveby() return false end

--- IS_CONTROL_ENABLED, AND ITS RETURN SHAPE IS PART OF THE FIXTURE.
---
--- Declared BOOL, read six times a frame by the drive-by watch, and `0` is
--- truthy in Lua. A build that answers numbers turns every `not
--- IsControlEnabled(...)` into a permanent "enabled" -- which would make the
--- readout confidently exonerate a script that is in fact holding the trigger
--- down. That is the bug this codebase has shipped four times, so BOTH shapes
--- are driven through the same assertions below.
local disabledControls = {}
local controlsAnswerNumbers = false
function IsControlEnabled(_pad, c)
    local on = not disabledControls[c]
    if controlsAnswerNumbers then return on and 1 or 0 end
    return on
end

--- ...EXCEPT THIS ONE, WHICH IS THE THING UNDER TEST RATHER THAN SCENERY.
---
--- The strip block in client/inventory.lua does two things now -- it takes the
--- weapon out of the hand AND it reports -- and the whole point of the tests
--- below is that those two are separable. A noop here could not tell "the strip
--- did not happen" from "the report did not happen", which is the exact
--- distinction the false-positive guard turns on. Declared after the loop above
--- so it overrides the noop rather than racing it.
local stripped = {}
--- CALLS, NOT ENTRIES, AND THE TWO GENUINELY DIFFER. A hash of `nil` appends
--- nothing to a Lua sequence -- `#stripped` stays where it was -- so a strip of
--- a weapon the engine named as nil is invisible in the list and visible only
--- here. #216's nil-versus-nil case is the one that needs it.
local stripCalls = 0
function RemoveWeaponFromPed(_ped, hash)
    stripCalls = stripCalls + 1
    stripped[#stripped + 1] = hash
end

--- ...AND THIS ONE, WHICH WAS SCENERY UNTIL #200 (the radio wheel).
---
--- Every control this client suppresses goes through DisableControlAction, and
--- a noop could not tell "we take the weapon wheel away" from "we take the
--- player's radio away" -- which is the entire question the issue asks. The
--- disables also LAST ONE FRAME by contract, so the record is cleared at the top
--- of every frame rather than accumulated: a test that asked "was 141 ever
--- disabled" would pass on a build that disabled it once in the lobby, and the
--- claim being made is about the frame the player is driving on.
local disabled = {}
function DisableControlAction(_group, control) disabled[control] = true end

-- ---------------------------------------------------------------- boost ---
--
-- #203's natives, and the car is a PHYSICS MODEL rather than a counter.
--
-- ═══ WHY A MODEL AND NOT A SPY ═══
--
-- The owner's report is "boost does nothing, and the bar is at 100". Asserting
-- "ApplyForceToEntity was called with 0.22" would have PASSED on the build that
-- produced that report -- the call is made, every frame, and the car does not
-- move. A spy proves we asked; the complaint is about the answer.
--
-- So the stub integrates: an impulse scaled by mass IS a velocity change, so
-- `dv` lands on the car's speed and the next frame's reading reflects it. That
-- makes the closed loop a closed loop at the desk, and it makes the failure the
-- owner reported EXPRESSIBLE -- `forceInert` below is a car that takes every
-- call and ignores it, which is candidate 2 exactly. A suite that cannot state
-- the bug cannot prove the fix.
--
-- WHAT IS DELIBERATELY NOT MODELLED: drag, gearing, gradient, tyre grip and the
-- contact solver. The controller only ever asks for a gap and clamps it, so
-- nothing it does depends on where the resistance comes from -- and modelling a
-- guess at GTA's drag would be a fixture asserting its own author's arithmetic.

--- The car, in one number. Metres per second, forward.
local vehSpeed = 0.0
--- Does APPLY_FORCE_TO_ENTITY do anything on this simulated build?
local forceInert = false
--- Does it exist at all, and does it throw?
local forceThrows = false
--- Every call, in order, so the ARGUMENTS can be asserted separately from the
--- effect -- `bScaleByMass` being dropped is a real regression that would leave
--- the speed test passing on a Blista and failing on nothing the suite drives.
local forceCalls = {}

function ApplyForceToEntity(ent, ftype, x, y, z, ox, oy, oz, bone,
                            dirRel, upVec, forceRel, audio, warp)
    if forceThrows then error('APPLY_FORCE_TO_ENTITY: no such native', 0) end
    forceCalls[#forceCalls + 1] = {
        ent = ent, ftype = ftype, x = x, y = y, z = z,
        ox = ox, oy = oy, oz = oz, bone = bone, dirRel = dirRel,
        upVec = upVec, forceRel = forceRel, audio = audio, warp = warp,
    }
    if forceInert then return end
    -- SCALED BY MASS MEANS THE UNIT IS m/s. That is the whole argument in
    -- client/boost.lua's header for why the impulse is a velocity change, and
    -- it is the argument this line encodes: with the flag set, `y` lands on the
    -- speed unchanged. WITHOUT the flag an impulse would be divided by the
    -- vehicle's mass and a heavy car would barely move -- so a mutant that
    -- passes `false` there must not be able to pass a speed assertion.
    if forceRel ~= true then return end
    vehSpeed = vehSpeed + (tonumber(y) or 0.0)
end

--- GET_ENTITY_SPEED_VECTOR(entity, relative) -- +y is forward in the entity's
--- own frame, which is the whole reason boost.lua prefers it over the scalar.
--- Returns a vector table, which is the shape FiveM's Lua runtime produces.
local speedVectorMissing = false
--- HOW SIDEWAYS THE CAR IS, which is 0.0 for every test that is not about the
--- drift report. `x` is the lateral component in the entity's own frame, so a
--- non-zero value here IS a car in a slide -- the state the owner's second
--- report describes and the one /brboostwhy had no row for.
--- `vehLateralStep` is added to it on every read, so a slide can DECAY across a
--- measurement window. A constant would make the peak and the mean and the
--- minimum the same number, and a readout that reported any of the three would
--- look correct -- see the peak assertions in the boost block.
local vehLateral, vehLateralStep = 0.0, 0.0
function GetEntitySpeedVector(_ent, _rel)
    if speedVectorMissing then error('GET_ENTITY_SPEED_VECTOR: no such native', 0) end
    local x = vehLateral
    if vehLateralStep ~= 0.0 and vehLateral > 0.0 then
        vehLateral = math.max(0.0, vehLateral + vehLateralStep)
    end
    return { x = x, y = vehSpeed, z = 0.0 }
end

--- The scalar fallback. UNSIGNED, like the real one -- which is exactly why
--- boost.lua asks the vector first, and why a build without the vector is a
--- build where reversing reads as going forwards.
local speedScalarMissing = false
function GetEntitySpeed(_ent)
    if speedScalarMissing then error('GET_ENTITY_SPEED: no such native', 0) end
    return math.abs(vehSpeed)
end

--- GET_VEHICLE_CLASS. 0 is Compacts; 15/16 are the excluded aircraft.
local vehClass = 0
function GetVehicleClass() return vehClass end

--- The network id, and `0` for a vehicle that is not networked -- the case
--- boost.lua writes down explicitly because 0 is TRUTHY in Lua.
local vehNetId = 77
function NetworkGetNetworkIdFromEntity() return vehNetId end
function NetworkGetEntityFromNetworkId(id) return id == vehNetId and vehicle or 0 end

--- The particle asset. Loaded by default: the flames are not what any of these
--- tests are about, and an asset that never arrives would have every boost take
--- the "no flames" branch and prove nothing about the push.
local ptfxLoaded = true
function RequestNamedPtfxAsset() end
function HasNamedPtfxAssetLoaded() return ptfxLoaded end
function UseParticleFxAsset() end
function GetEntityBoneIndexByName(_ent, name)
    -- Exactly one exhaust, so the fallback-offset path is not taken. -1 is the
    -- engine's "no such bone" and is what everything else must answer.
    return name == 'exhaust' and 3 or -1
end
function GetModelDimensions() return { x = -1.0, y = -2.0, z = -0.5 }, { x = 1.0, y = 2.0, z = 1.0 } end
local ptfxHandles = 0
function StartParticleFxLoopedOnEntityBone()
    ptfxHandles = ptfxHandles + 1
    return ptfxHandles
end
function StartParticleFxLoopedOnEntity()
    ptfxHandles = ptfxHandles + 1
    return ptfxHandles
end
function StopParticleFxLooped() end
function SetParticleFxLoopedColour() end
function SetParticleFxLoopedAlpha() end
function SetParticleFxLoopedScale() end

--- IS_DISABLED_CONTROL_PRESSED, which /brboostwhy reads to ask "did the key reach
--- GTA's own mapper at all". Driven off the same `keys` table the raw natives
--- read, through a control->virtual-key map, so a test that presses shift
--- presses it for BOTH readers exactly as a real keyboard does -- which is the
--- arrangement that makes "the engine saw it and we did not" a state the suite
--- can actually reach.
--- WHICH KEY EACH CONTROL SITS ON. The four are the LSHIFT set; 350 is not one
--- of them and is not on the key, so it is silent unless a test puts it there --
--- which is what a build with a control the 2020 table does not name looks like.
local CONTROL_VK = { [21] = 0x10, [61] = 0x10, [340] = 0x10, [352] = 0x10 }
--- Which controls this simulated build reports at all. Emptying it is a build
--- where shift drives no control in a car, which is what config/boost.lua
--- claims and what /brboostwhy exists to check.
local controlsLive = { [21] = true, [61] = true, [340] = true, [352] = true }
function IsDisabledControlPressed(_pad, c)
    if not controlsLive[c] then return controlsAnswerNumbers and 0 or false end
    local on = keys[CONTROL_VK[c] or -1] == true
    if controlsAnswerNumbers then return on and 1 or 0 end
    return on
end

-- ------------------------------------------------------------- pma-voice ---
--
-- THE VOICE RESOURCE, MODELLED FROM ITS SOURCE RATHER THAN FROM ITS README.
--
-- br_core no longer calls a single Mumble native. It hands its rules to
-- pma-voice through that resource's exports, so THIS is now the surface the
-- voice tests have to model, and modelling it wrong is exactly how the previous
-- three rounds of voice shipped green. Everything below is taken from
-- pma-voice v7 source, with the file it came from named, so the next person can
-- check it in ten seconds instead of trusting this comment:
--
--   client/init/proximity.lua   addNearbyPlayers() runs every
--                               `voice_refreshRate` ms (200 default). It clears
--                               the target's CHANNELS, then walks the streamed
--                               player list calling addProximityCheck(ply) --
--                               ours, once we override it -- and adds the
--                               channel of everyone it returns true for.
--                               exports: overrideProximityCheck,
--                               resetProximityCheck, setVoiceState.
--   client/commands.lua         exports overrideProximityRange(range, noCycle),
--                               which calls MumbleSetTalkerProximity.
--   client/module/radio.lua     exports setRadioChannel(n); 0 leaves. The radio
--                               lives in the target's PLAYERS, which the
--                               proximity loop never touches -- that separation
--                               is what makes the bus rule possible and it is
--                               modelled as two separate fields below.
--   client/init/main.lua        exports getMutedPlayers, toggleMutePlayer,
--                               setVoiceProperty.
--
-- THE ONE PROPERTY WORTH STATING OUT LOUD, because every previous version of
-- this suite got the direction wrong: PROXIMITY IS DECIDED BY THE SPEAKER. What
-- a client computes is who IT will send to. Nothing a listener does can make an
-- out-of-range speaker audible, and -- this is the half that matters -- nothing
-- a listener does to its own transmit path can make itself deaf. hears() below
-- is written so that a fix which gags a microphone cannot accidentally pass a
-- test about ears.
local pma = {}
local function pmaReset()
    pma = {
        running = true,
        check   = nil,   -- the proximity check br_core installed, if any
        range   = nil,   -- overrideProximityRange, in metres
        noCycle = nil,   -- whether it also disabled the F11 cycle
        radio   = nil,   -- channel br_core asked to join; 0 = none, nil = never asked
        muted   = {},    -- [serverId] = true, pma-voice's own mutedPlayers
        sends   = {},    -- [serverId] = true; who our proximity reached last tick
        calls   = {},    -- every export call, in order, for "was it even asked"
    }
end
pmaReset()

local function pmaLog(name) pma.calls[#pma.calls + 1] = name end

--- pma-voice's export surface. Called as exports['pma-voice']:name(...), so
--- every function takes the table itself as its first argument.
local pmaAPI = {
    overrideProximityCheck = function(_, fn)
        pmaLog('overrideProximityCheck')
        pma.check = fn
    end,
    resetProximityCheck = function(_) pma.check = nil end,
    overrideProximityRange = function(_, range, noCycle)
        pmaLog('overrideProximityRange')
        pma.range, pma.noCycle = range, noCycle and true or false
    end,
    setRadioChannel = function(_, ch)
        pmaLog('setRadioChannel')
        pma.radio = ch
    end,
    getMutedPlayers = function(_)
        pmaLog('getMutedPlayers')
        local out = {}
        for src in pairs(pma.muted) do out[src] = true end
        return out
    end,
    -- A TOGGLE, not a setter -- which is what pma-voice actually exposes, and
    -- the reason br_core reads getMutedPlayers before deciding. A model with a
    -- setter here would hide a double-toggle bug completely.
    toggleMutePlayer = function(_, src)
        pmaLog('toggleMutePlayer')
        if pma.muted[src] then pma.muted[src] = nil else pma.muted[src] = true end
    end,
}

--- THE RESOURCE BEING ABSENT IS A FIRST-CLASS STATE, not an error case. br_core
--- has to boot and keep running with no voice resource installed at all, and
--- that is asserted rather than assumed.
function GetResourceState(name)
    if name == 'pma-voice' then
        return pma.running and 'started' or 'missing'
    end
    return 'started'
end

exports = setmetatable({}, {
    -- DECLARING one is a call on the table itself -- `exports('send', fn)` --
    -- which is a different metamethod from reading somebody else's. Needed
    -- because the focus block at the bottom loads the real br_ui bridge, and
    -- that file declares three exports at load time.
    __call = function(_, _name, _fn) end,
    __index = function(_, res)
        -- An export table for a resource that is not running is the shape
        -- FiveM gives you: indexing works, calling raises. br_core guards with
        -- GetResourceState first and pcalls anyway; both halves are exercised.
        if res == 'pma-voice' and pma.running then return pmaAPI end
        return setmetatable({}, { __index = function()
            return function() error('resource ' .. tostring(res) .. ' is not running', 0) end
        end })
    end,
})

-- ---------------------------------------------------------------- modules ---

local ROOT = 'resources/[fivem-royale]/'

-- LoadResourceFile IS DELIBERATELY NOT STUBBED ANY MORE (#206). It existed for
-- exactly one caller: /brdriveby reading br_environment's vehiclelayouts.meta
-- back off this client, to tell "the game ignored our data file" from "the file
-- never got here". The game ignored it, the file is gone, and a stub with no
-- caller is a fixture that can only ever mislead the next reader.

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
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    -- The catalogue, for the descent block at the bottom: what `trail_ember`
    -- resolves to is the first of the four things the smoke-trail prompt is
    -- made of, and BR.Config.MarketIndex is where that answer lives.
    'br_lib/config/market.lua',
    'br_lib/shared/storm_solve.lua', 'br_lib/shared/loot_gen.lua',
    -- THE BOOST PAIR, AND THE ORDER IS THE MANIFEST'S RATHER THAN A
    -- PREFERENCE. config/boost.lua derives `addMps` from BR.BoostSolve.MPH at
    -- LOAD time, so a swap here gives every boost a target of nil.
    'br_lib/shared/boost_solve.lua', 'br_lib/config/boost.lua',
    'br_core/client/main.lua',       -- the loop registry; must be first
})

-- The three collaborators that are pure native wrappers. Loading the real ones
-- would pull in the DUI browser and the ray-cast for no gain: what matters here
-- is which entry the pickup path resolves and what it sends, not what is drawn.
BR.State = BR.State or {}
-- `src` is set because voice.lua asks the engine which room IT thinks this
-- player is in, keyed on the server id, and that readback is the gate on the
-- whole transmit path now (#150).
BR.State.me = { src = 1, state = BR.PlayerState.ALIVE }
BR.State.landed = true
BR.State.roster = {}
--- [entity] = the last size it was drawn at. There is no SetEntityScale in GTA V
--- (#166); the real BR.Native.propScale drives the transform matrix, and what
--- matters here is only that the right entities are asked for the right size.
local propScales = {}

--- What BR.Native.pedReachable answers. The rooftop check (owner, 2026-08-22:
--- "Somehow these airdrops can happen on top of buildings where peds otherwise
--- cannot access"). Driven per-point so a test can put a roof at one coordinate
--- and clean ground at another, which is what the repair round-trip needs.
local unreachable = {}          -- ['x,y'] = why
local function markUnreachable(x, y, why)
    unreachable[('%.1f,%.1f'):format(x, y)] = why or 'roof'
end

BR.Native = {
    aim = function() return false, nil, 0 end,
    keyLabelForCommand = function() return 'E', 'brinteract' end,
    blipName = noop, help = noop,
    inputForCommand = function() return '~INPUT~' end,
    displayHealth = function() return 100 end,
    setDisplayHealth = noop,
    propScale = function(obj, k)
        if not obj or not k or k == 1.0 then return end
        propScales[obj] = k
    end,
    pedReachable = function(x, y)
        local why = unreachable[('%.1f,%.1f'):format(x, y)]
        if why then return false, why end
        return true, 'ok'
    end,
}
BR.Dui = {
    page = function() return { id = 'prompt' } end,
    send = noop, drawWorld = noop, drawOnEntity = noop,
}

loadAll({
    'br_core/client/keybinds.lua',   -- before loot.lua, as fxmanifest orders it
    'br_core/client/inventory.lua',
    -- The passenger's "switch to slot N" notice (#206). It registers a TICK
    -- callback at load, so it steps with every other one -- which is the point:
    -- its once-per-session latch has to survive the WHOLE suite, not just its
    -- own block, and a file loaded only for its own tests could not prove that.
    'br_core/client/driveby.lua',
    'br_core/client/loot.lua',
    -- The consumer half of the voice pair. Loaded here rather than left to the
    -- server suite because #150 was entirely on this side: server/voice.lua's
    -- arithmetic was right, tools/test_roster.lua proved it was right, and two
    -- players still could not hear each other.
    'br_core/client/voice.lua',
    -- THE BOOST, AND IT IS HERE FOR THE SAME REASON keybinds.lua IS (#203).
    --
    -- The owner's report is a key that appears to do nothing, and the last time
    -- this project had one of those it cost #129 six rounds and #139 alongside
    -- it, entirely because no suite could drive a keypress. This file already
    -- models the keyboard three ways; loading the boost underneath it means the
    -- chain from a physical shift to a force on a car is one assertion, on every
    -- shape and every simulated build the keyboard block enumerates.
    --
    -- AFTER keybinds.lua and BEFORE debug.lua, which is the manifest's own
    -- order: boost.lua reads BR.Keys.isHeld at load-registered call time, and
    -- debug.lua's /brboostwhy calls BR.Boost.trace().
    'br_core/client/boost.lua',
    -- THE DEBUG FILE IS LOADED FOR ONE COMMAND. /brdriveby is the only answer
    -- the owner gets to "why can a passenger not fire", it decides between
    -- causes that look identical from the seat, and it is now also the ONLY
    -- check there is on the `driveby` field -- no offline gate can know what is
    -- inside the game's own .rpf. A readout that reaches the wrong verdict costs
    -- a playtest round the same way a wrong fix does. Its FRAME sampler is
    -- registered here like any other callback, so the harness can step it.
    'br_core/client/debug.lua',
})

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

--- The engine half of a key event.
---
--- FiveM delivers the mapped command on the press and, for a `+name` binding,
--- its `-name` twin on the release -- and it does so WHETHER OR NOT our raw
--- layer is also reading the keyboard. Modelling it any other way would assume
--- away the failure this file was written for: if both the raw layer and the
--- command handler decline the same physical press, nothing drives the
--- interaction and the crate does nothing at all.
--- @param keyName string  the RegisterKeyMapping key name, e.g. 'E'
--- @param down boolean
local function engineKey(keyName, down)
    local cmd = keymap[keyName]
    if not cmd then return end
    if cmd:sub(1, 1) == '+' then
        local fn = commands[down and cmd or ('-' .. cmd:sub(2))]
        if fn then fn(nil, {}, '') end
    elseif down then
        local fn = commands[cmd]
        if fn then fn(nil, {}, '') end
    end
end

local INTERACT_VK   = 0x45   -- E
local INTERACT_KEY  = 'E'

local function pressInteract()
    if keys[INTERACT_VK] then return end
    keys[INTERACT_VK] = true
    edge[INTERACT_VK] = true
    engineKey(INTERACT_KEY, true)
end

local function releaseInteract()
    if not keys[INTERACT_VK] then return end
    keys[INTERACT_VK] = nil
    engineKey(INTERACT_KEY, false)
end

--- One frame of the FRAME band.
local function frame(ms)
    fakeTime = fakeTime + (ms or 16)
    -- A DISABLE LASTS EXACTLY ONE FRAME, which is why the suppressions live in
    -- a FRAME callback at all -- so the record starts empty on every one of
    -- them. See the DisableControlAction stub for why this is not cumulative.
    disabled = {}
    BR.Loop.step(BR.Loop.FRAME)
    -- IS_RAW_KEY_PRESSED is true for exactly one frame.
    edge = {}
    -- A dropout is a frame, not a state.
    lying = {}
end

local function frames(n, ms)
    for _ = 1, n do frame(ms) end
end

--- Put the client on a simulated BUILD and restart the resource on it.
---
--- The three `rawDown`/`rawPressed` cases are the three `via` lines /brloot
--- prints, and every one of them is a machine somebody is actually playing on.
--- @param rawDown boolean     IS_RAW_KEY_DOWN exists (the level sample)
--- @param rawPressed boolean  IS_RAW_KEY_PRESSED exists (the edge fallback)
--- @param shape table|nil     what the natives RETURN; defaults to booleans,
---                            so every block written before #129's seventh
---                            round keeps testing what it always tested
local function bootOn(rawDown, rawPressed, shape)
    releaseInteract()
    build.rawDown, build.rawPressed = rawDown, rawPressed
    build.shape = shape or SHAPES[1]
    -- One quiet frame so the raw layer's remembered edge state agrees with a
    -- keyboard on which nothing is held, before the flags change under it.
    frame(16)
    fire('onClientResourceStart', 'br_core')
    frame(16)
end

--- Everything the loot module is holding, dropped.
local function clearWorld()
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    sent = {}
    events = {}
end

local nextId = 0
local function addEntry(kind, item, x, y)
    nextId = nextId + 1
    fire(BR.Net.LOOT_ADD, { {
        id = nextId, kind = kind, item = item,
        x = x, y = y, z = 30.0, rarity = BR.Rarity.COMMON, count = 1,
    } })
    return nextId
end

--- Every LOOT_CLAIM the client has sent since the last clearWorld().
local function claims()
    local out = {}
    for _, s in ipairs(sent) do
        if s.name == BR.Net.LOOT_CLAIM then out[#out + 1] = s.args[1].id end
    end
    return out
end

--- Every line /brloot printed, as an array.
---
--- The readout IS the deliverable for #129's sixth round -- it is the only
--- thing a player can send back -- so it is asserted on rather than trusted.
--- A diagnostic nobody tests is a diagnostic that can print the wrong number
--- for six rounds without anyone noticing, which is most of this issue.
local function brloot()
    logged = {}
    commands['brloot'](nil, {}, '')
    return logged
end

--- The live hold clock, read the same way /brloot reads it.
local function holdMs()
    for _, line in ipairs(brloot()) do
        local ms = line:match('^%s*hold:%s+#?%-?%d*%s+(%d+)/%d+ms')
        if ms then return tonumber(ms) end
    end
    return nil
end

--- The first /brloot line matching `pat`, or nil.
local function lootLine(pat)
    for _, line in ipairs(brloot()) do
        if line:match(pat) then return line end
    end
    return nil
end

--- How many holds crossed chestHoldMs, as /brloot reports it.
local function completions()
    local line = lootLine('^%s*completed%s+%d+ hold')
    return line and tonumber(line:match('completed%s+(%d+)'))
end

--- How many claims /brloot says this client has sent.
local function claimsReported()
    local line = lootLine('^%s*claims%s+%d+ sent')
    return line and tonumber(line:match('claims%s+(%d+)'))
end

--- The last hold's summary: id, best ms, frames alive, frames that earned
--- time, and the reason it ended.
local function lastHold()
    local out = {}
    local lines = brloot()
    for i, line in ipairs(lines) do
        local id, best = line:match('^%s*last hold%s+#(%S+) reached (%d+) of %d+ms')
        if id then
            out.id, out.best = id, tonumber(best)
            local frames, counted, pct =
                (lines[i + 1] or ''):match('(%d+) frame%(s%) alive, (%d+) earned time%s+%((%d+)%%%)')
            out.frames, out.counted = tonumber(frames), tonumber(counted)
            out.pct = tonumber(pct)
            out.why = (lines[i + 2] or ''):match('it ended because (.+)$')
            return out
        end
    end
    return nil
end

--- The last claim line, split into { id, kind, answered }.
local function lastClaim()
    local line = lootLine('^%s*last claim')
    if not line then return nil end
    local id, kind = line:match('last claim #(%S+) %((%w+)%)')
    if not id then return { none = true } end
    return { id = id, kind = kind, answered = line:find('SERVER ACTED') ~= nil }
end

local CHEST_MS = BR.Config.Loot.chestHoldMs or 1000

-- ======================================================================== --
-- 1. THE HOLD REACHES ITS THRESHOLD, AND A TAP CANNOT
-- ======================================================================== --
--
-- The two halves of #129, stated as one pair. The first round shipped a crate
-- that opened from a momentary press because the completion test was
-- `now - from >= chestHoldMs` -- arithmetic a tap satisfies exactly as well as
-- a hold. The second and third rounds shipped a hold that could not complete at
-- all. Both directions have to be nailed down at once or fixing either one
-- reintroduces the other, which is precisely the history of this interaction.

--- THE MECHANISMS, TIMES THE SHAPES THE NATIVE CAN ANSWER IN.
---
--- The three mechanisms were here already. The shapes were not, and their
--- absence is the whole of #129's seventh round: every raw-layer block below
--- ran against a stub that returned a strict Lua boolean, which is the one
--- shape the broken code handled correctly.
local MECHS = {
    { name = 'engine +/- pair (no IsRawKeyDown)', rawDown = false, rawPressed = true },
    { name = 'engine +/- pair (no raw layer)',  rawDown = false, rawPressed = false },
}
for _, s in ipairs(SHAPES) do
    MECHS[#MECHS + 1] = {
        name = 'raw level sample (IsRawKeyDown -> ' .. s.name .. ')',
        rawDown = true, rawPressed = true, shape = s,
    }
end

for _, mech in ipairs(MECHS) do

describe('crate hold -- ' .. mech.name)
do
    bootOn(mech.rawDown, mech.rawPressed, mech.shape)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    ok(#claims() == 0, 'nothing is claimed before the key is touched')

    -- A FULL HOLD. Long enough to cross chestHoldMs with room to spare, so a
    -- test that starts failing is failing on the mechanism rather than on a
    -- frame of rounding.
    pressInteract()
    frames(math.ceil(CHEST_MS / 16) + 4)
    local got = claims()
    ok(#got == 1 and got[1] == id,
       'a sustained hold opens the crate',
       ('claims=%d first=%s -- the hold never reached %dms on this mechanism')
           :format(#got, tostring(got[1]), CHEST_MS))
    releaseInteract()
    frames(20)
end

describe('crate tap -- ' .. mech.name)
do
    bootOn(mech.rawDown, mech.rawPressed, mech.shape)
    clearWorld()
    addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    -- PRESS AND LET GO IMMEDIATELY. One frame of contact, which is what a tap
    -- physically is.
    pressInteract()
    frame(16)
    releaseInteract()

    -- ...and then wait far longer than the hold needs. The original bug was
    -- not that a tap opened the crate at once, it was that the clock kept
    -- running with nobody watching the key and the crate opened LATER.
    frames(math.ceil(CHEST_MS / 16) + 60)
    ok(#claims() == 0,
       'a tap never opens the crate, however long you wait afterwards',
       ('claims=%d -- press-to-open is back'):format(#claims()))
end

end  -- mechanisms

-- ======================================================================== --
-- 2. A DROPPED FRAME OF KEY STATE, AND A REAL RELEASE
-- ======================================================================== --
--
-- citizenfx/fivem#3064: taking or releasing the NUI cursor disturbs the state
-- IS_RAW_KEY_DOWN reads, so a key that is still physically held reads UP for a
-- frame or two around every focus change. The accumulator introduced in #129's
-- first round threw the whole hold away on the first such frame, which is the
-- "even after holding I cannot successfully open any crates" report. The grace
-- period that fixes it must extend the hold's LIFETIME without adding to its
-- PROGRESS, or it is a route back to press-to-open.

describe('hold survives a dropped frame')
do
    bootOn(true, true)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    pressInteract()
    frames(20)                     -- ~320ms banked
    local before = holdMs()
    lying[INTERACT_VK] = true      -- one frame of the engine changing its mind
    frame(16)
    local during = holdMs()
    ok(during ~= nil and before ~= nil and during >= before,
       'a single dropped frame does not reset the clock',
       ('before=%s after=%s'):format(tostring(before), tostring(during)))
    ok(during == before,
       'and the dropped frame earns no credit',
       ('before=%s after=%s'):format(tostring(before), tostring(during)))

    frames(math.ceil(CHEST_MS / 16) + 4)
    local got = claims()
    ok(#got == 1 and got[1] == id,
       'the hold still completes after riding out the dropout')
    releaseInteract()
    frames(20)
end

describe('hold ends on a sustained release')
do
    bootOn(true, true)
    clearWorld()
    addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    pressInteract()
    frames(20)
    ok((holdMs() or 0) > 0, 'the clock advances while the key is down')

    releaseInteract()
    frames(20)                     -- 320ms: well past the 120ms grace
    ok((holdMs() or -1) == 0, 'the clock is dropped once the key stays up',
       ('holdMs=%s'):format(tostring(holdMs())))

    frames(math.ceil(CHEST_MS / 16) + 60)
    ok(#claims() == 0, 'and a released hold never completes later')
end

-- A RELEASE FOLLOWED BY A FRESH PRESS MUST NOT INHERIT THE OLD CLOCK. This is
-- the same class of fault as the original: progress surviving the thing that
-- was supposed to end it.
describe('a second hold starts from zero')
do
    bootOn(true, true)
    clearWorld()
    addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    pressInteract()
    frames(math.ceil(CHEST_MS / 32))       -- roughly half
    releaseInteract()
    frames(20)
    pressInteract()
    frame(16)
    local ms = holdMs()
    ok(ms ~= nil and ms <= 32,
       'the new hold does not inherit the old progress',
       ('holdMs=%s'):format(tostring(ms)))
    releaseInteract()
    frames(20)
end

-- A DROPPED FRAME THAT HAPPENS MORE THAN ONCE, WHICH IS THE ONLY KIND THERE IS.
--
-- The block above fires exactly one dropout and then hands the hold a fresh
-- second to finish in, so it passes whether or not the dropout costs the clock
-- everything it had earned. It did cost it everything, and that is #129's
-- fourth round -- the suite proved the release GRACE worked and never asked
-- what the re-press did:
--
--   frame 19  isHeld=true   holdMs=304
--   frame 20  isHeld=false  holdMs=304   <- the grace keeps the hold alive
--   frame 21  isHeld=true   holdMs=16    <- the rising edge restarts the clock
--
-- The raw layer derives both edges from one sample, so a frame that reads UP
-- fires a release AND the frame after it fires a press. A client that does that
-- more often than once per chestHoldMs can therefore never open a crate, no
-- matter how long the key is held -- while every press-to-pick-up keeps working,
-- because a press needs one good frame and a hold needs a thousand milliseconds
-- of consecutive ones.
--
-- 320ms apart is well inside the 1000ms the hold needs, which is the whole
-- point: the test has to run the dropout at a rate the clock cannot outrun, or
-- it is the one-shot test again with extra steps.
describe('hold survives dropped frames that keep coming')
do
    bootOn(true, true)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    pressInteract()
    local best = 0
    for i = 1, 300 do
        -- One frame in twenty reads UP without the key having moved.
        if i % 20 == 0 then lying[INTERACT_VK] = true end
        frame(16)
        best = math.max(best, holdMs() or 0)
        if #claims() > 0 then break end
    end

    local got = claims()
    ok(#got == 1 and got[1] == id,
       'a hold whose key state drops a frame every 320ms still opens the crate',
       ('claims=%d best=%dms of %dms -- the clock is being restarted by the '
        .. 'press edge that follows each dropped frame')
           :format(#got, best, CHEST_MS))
    releaseInteract()
    frames(20)
end

-- ...AND THE INVARIANT THAT FIX MUST NOT BUY ITS WAY OUT OF. Absorbing the
-- re-press is only safe while the hold is still alive on the grace; a key with
-- REAL gaps in it -- let go for longer than HOLD_RELEASE_MS -- has to keep
-- failing, or #129's original complaint (a press opens a crate) walks back in
-- through the fix for its fourth round.
describe('mashing is still not holding')
do
    bootOn(true, true)
    clearWorld()
    addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    -- Thirty presses, each held for one frame and released for 208ms. That is
    -- eight seconds of contact with the key and eight times the hold's
    -- duration in elapsed time.
    for _ = 1, 30 do
        pressInteract()
        frame(16)
        releaseInteract()
        frames(13)
    end
    ok(#claims() == 0,
       'a key let go of for longer than the grace never opens the crate',
       ('claims=%d -- press-to-open is back'):format(#claims()))
end

-- ======================================================================== --
-- 2b. THE READOUT, WHICH IS THE DELIVERABLE OF #129'S SIXTH ROUND
-- ======================================================================== --
--
-- "When I press E the orange circle does animate. It fills up in the expected
--  period of time, and properly resets if I release the key. However -- after
--  holding the key for the fully satisfied time, the crate does not open."
--  (owner, 2026-08-16)
--
-- That sentence was read as proof the clock completes, and it is not proof of
-- anything of the sort. The ring is a CSS animation started ONCE with
-- `chestHoldMs` as its duration (br_ui/dui/prompt.html: `restartHold`), so it
-- fills over exactly that duration no matter what the accumulator underneath
-- it is doing, and it resets on release because the next prompt carries no
-- duration at all. A hold whose key sample reads down on one frame in six
-- produces a ring indistinguishable from a healthy one and a clock six times
-- too slow -- which is the reported symptom, word for word.
--
-- So the blocks below pin the READOUT rather than the mechanism. They are the
-- test this issue has been missing for five rounds: not "does the hold work"
-- but "if it does not, does anything say which half is wrong".

local function sessionCounts()
    return completions() or -1, claimsReported() or -1
end

describe('a starved key fills the ring and never opens the crate')
do
    bootOn(true, true)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)
    local comp0, claim0 = sessionCounts()

    pressInteract()
    -- PHYSICALLY HELD THE WHOLE TIME. The raw sample reads UP on five frames
    -- in every six -- gaps of 80ms, comfortably inside the 120ms grace -- so
    -- the hold never dies, the ring never resets, and the player sees a ring
    -- that filled almost four times over.
    for i = 1, 240 do
        if i % 6 ~= 0 then lying[INTERACT_VK] = true end
        frame(16)
    end

    local live = holdMs()
    local comp1, claim1 = sessionCounts()

    ok(#claims() == 0, 'the crate does not open')
    ok(comp1 == comp0, 'and no hold is reported as having completed',
       ('completed went %d -> %d'):format(comp0, comp1))
    ok(claim1 == claim0, 'and no claim is reported as sent',
       ('claims went %d -> %d'):format(claim0, claim1))
    ok(live ~= nil and live < CHEST_MS,
       'the clock is still short of the threshold after 3.8s of holding',
       ('holdMs=%s of %d'):format(tostring(live), CHEST_MS))

    releaseInteract()
    frames(20)

    -- ...AND THE READOUT SAYS WHY, WHICH IS THE ENTIRE POINT. Without the duty
    -- cycle this state and a healthy completed hold print the same three lines.
    local h = lastHold()
    ok(h ~= nil, 'the readout remembers the hold after the key is let go')
    ok(h and h.id == tostring(id), 'and which crate it was for',
       ('id=%s want %s'):format(h and tostring(h.id), tostring(id)))
    ok(h and h.frames and h.counted and h.counted < h.frames,
       'and that most frames earned no time',
       h and ('%d alive, %d earned'):format(h.frames or -1, h.counted or -1))
    ok(h and h.pct and h.pct < 50,
       'and reports the duty cycle, which is what separates this from a '
       .. 'clock that simply completed',
       h and ('duty=%s%%'):format(tostring(h.pct)))
end

describe('a completed hold reports the completion, the claim and no answer')
do
    bootOn(true, true)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)
    local comp0, claim0 = sessionCounts()

    pressInteract()
    frames(math.ceil(CHEST_MS / 16) + 4)

    local comp1, claim1 = sessionCounts()
    ok(comp1 == comp0 + 1, 'one hold is reported as completed',
       ('completed went %d -> %d'):format(comp0, comp1))
    ok(claim1 == claim0 + 1, 'and one claim as sent',
       ('claims went %d -> %d'):format(claim0, claim1))

    local h = lastHold()
    ok(h and h.pct == 100, 'the healthy hold reports a 100% duty cycle',
       h and ('duty=%s%%'):format(tostring(h.pct)))
    ok(h and h.why and h.why:find('completed'),
       'and says it ended by completing',
       h and tostring(h.why))

    -- NOTHING HAS COME BACK YET, and saying so is the line that separates a
    -- client that never asked from a server that never answered.
    local c = lastClaim()
    ok(c and c.id == tostring(id) and c.kind == 'crate',
       'the last claim names the crate and the path it came from',
       c and ('id=%s kind=%s'):format(tostring(c.id), tostring(c.kind)))
    ok(c and c.answered == false,
       'and reports the server as not having answered it')

    -- The husk coming back under the same id IS the server's answer; there is
    -- no reply message and there never was.
    fire(BR.Net.LOOT_ADD, { {
        id = id, kind = 'husk', item = 'husk', prop = 'open',
        x = 1.0, y = 0.0, z = 30.0, rarity = BR.Rarity.COMMON, count = 1,
    } })
    frames(2)
    local c2 = lastClaim()
    ok(c2 and c2.answered == true,
       'and flips to answered when the crate comes back as its husk')
    releaseInteract()
    frames(20)
end

describe('a loose pickup is counted as a claim too')
do
    bootOn(true, true)
    clearWorld()
    local id = addEntry(BR.ItemKind.WEAPON, 'pistol', 1.0, 0.0)
    frames(2)
    local _, claim0 = sessionCounts()

    pressInteract()
    frame(16)
    releaseInteract()
    frames(2)

    local _, claim1 = sessionCounts()
    ok(claim1 == claim0 + 1, 'the press path is counted by the same readout',
       ('claims went %d -> %d'):format(claim0, claim1))
    local c = lastClaim()
    ok(c and c.kind == 'item' and c.id == tostring(id),
       'and is reported as an item rather than a crate',
       c and ('id=%s kind=%s'):format(tostring(c.id), tostring(c.kind)))
end

-- ======================================================================== --
-- 3. THE PICKUP PATH, KEYPRESS THROUGH TO AN INVENTORY DELTA
-- ======================================================================== --
--
-- #139: "picking up random loose loot doesn't add it to my inventory", which
-- arrived in the same change as the crate going inert and shares the pickup
-- path with it. Three places it can break and they present identically from a
-- chair: the key never reaching the handler, the claim never being sent, and
-- the claim being answered without the mirror moving. The block below crosses
-- all three, on every mechanism, because "which one was it" is exactly the
-- question the issue asks and could not answer.

--- What the server would send back for a granted pickup.
local function serverGrants(item, kind, slot)
    local slots = {}
    for i = 1, (BR.Config.Loot.slots or 5) do slots[i] = false end
    slots[slot or 1] = {
        id = item, label = 'Thing', kind = kind,
        rarity = BR.Rarity.COMMON, count = 1, clip = 30, pool = 'rifle',
    }
    fire(BR.Net.INV_SET, { slots = slots, ammo = {}, active = slot or 1 })
end

local function heldIds()
    local out = {}
    for _, s in ipairs(BR.Inv.local_().slots) do
        if type(s) == 'table' then out[#out + 1] = s.id end
    end
    return out
end

for _, mech in ipairs({
    { name = 'raw level sample (IsRawKeyDown)', rawDown = true,  rawPressed = true },
    { name = 'engine +/- pair (no IsRawKeyDown)', rawDown = false, rawPressed = true },
    { name = 'engine +/- pair (no raw layer)',  rawDown = false, rawPressed = false },
}) do

describe('loose loot pickup -- ' .. mech.name)
do
    bootOn(mech.rawDown, mech.rawPressed)
    clearWorld()
    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = 1 })
    BR.Inv.lastGainAt = 0

    local id = addEntry(BR.ItemKind.WEAPON, 'pistol', 1.0, 0.0)
    frames(2)

    -- A LOOSE ITEM IS A TAP. Press, one frame, release -- the same input the
    -- crate block above proves cannot open a crate.
    pressInteract()
    frame(16)
    releaseInteract()
    frames(2)

    local got = claims()
    ok(#got == 1 and got[1] == id,
       'a press claims the item the prompt was offering',
       ('claims=%d -- the key never reached the pickup handler'):format(#got))

    -- ...and the far end. The client is a mirror: nothing here decides a
    -- pickup succeeded, so the delta only exists once INV_SET says so.
    serverGrants('pistol', BR.ItemKind.WEAPON, 1)
    local held = heldIds()
    ok(#held == 1 and held[1] == 'pistol',
       'the granted item lands in the local inventory mirror',
       ('held=%d'):format(#held))
    ok(BR.Inv.lastGainAt > 0,
       'and the arrival is recorded as a gain (the pickup cue, the mercy blips)')
end

end  -- mechanisms

describe('pickup refuses what it was not offering')
do
    bootOn(true, true)
    clearWorld()

    -- BEHIND THE PLAYER. The forward vector is +X, so an item at -X fails the
    -- facing cone and must not be claimable -- #128's "we're able to
    -- accidentally pick up 2 loot items if we're facing both of them" is the
    -- other half of this, and the guarantee is that the claim and the prompt
    -- resolve to one object.
    addEntry(BR.ItemKind.WEAPON, 'pistol', -1.0, 0.0)
    frames(2)
    pressInteract()
    frame(16)
    releaseInteract()
    frames(2)
    ok(#claims() == 0, 'an item behind the player is not claimed')
end

describe('pickup is refused from a vehicle')
do
    bootOn(true, true)
    clearWorld()
    addEntry(BR.ItemKind.WEAPON, 'pistol', 1.0, 0.0)
    frames(2)

    inVehicle = true
    frames(2)
    pressInteract()
    frame(16)
    releaseInteract()
    frames(2)
    inVehicle = false
    ok(#claims() == 0, 'driving through a POI does not hoover up loot')
end

-- ======================================================================== --
-- 4. THE BINDING ITSELF
-- ======================================================================== --
--
-- RegisterKeyMapping only delivers both edges for a `+name` command; a bare
-- name gives one edge and repeats while the key is held. Interact is a hold and
-- has to be registered as the pair -- this was wrong once already, in another
-- resource, and the symptom was bindings written against commands that do not
-- exist (keybinds.lua, 2026-08-09).

describe('the interact binding')
do
    ok(keymap[INTERACT_KEY] == '+brinteract',
       'interact is key-mapped as +brinteract, not the bare name',
       tostring(keymap[INTERACT_KEY]))
    ok(commands['+brinteract'] ~= nil and commands['-brinteract'] ~= nil,
       'both halves of the pair are registered as console commands')
end

--- EXACTLY ONE MECHANISM MAY ACT ON A PRESS.
---
--- Two of them acting is a double-fire; NEITHER acting is #129's third round,
--- where the raw layer handed hold bindings back to the engine while the
--- command handlers were still standing down for the raw layer, and the owner
--- got "trying to open a crate does nothing at all". The count is asserted
--- rather than the mechanism, because which one answers is allowed to differ
--- per build and the invariant is not.
describe('exactly one mechanism drives the interact press')
do
    for _, mech in ipairs({
        { name = 'level sample',   rawDown = true,  rawPressed = true },
        { name = 'edge fallback',  rawDown = false, rawPressed = true },
        { name = 'no raw layer',   rawDown = false, rawPressed = false },
    }) do
        bootOn(mech.rawDown, mech.rawPressed)
        local n = 0
        BR.Keys.on('interact', function(pressed) if pressed then n = n + 1 end end)
        pressInteract()
        frame(16)
        releaseInteract()
        frames(2)
        ok(n == 1, ('one press fires exactly one interact -- %s'):format(mech.name),
           ('fired %d times'):format(n))
    end
end

--- THE HELD FLAG IS THE STATE, NOT A MEMORY OF THE LAST EDGE.
---
--- dbno.lua carries the scar: a brief tap completed an entire eight-second
--- revive in playtest (owner, 2026-08-09) because the stop was raised and did
--- not land, and BR.Keys.held was a latch nothing ever re-checked. Whatever
--- mechanism is driving the key, releasing it has to be visible to
--- BR.Keys.isHeld or every hold in the game inherits that bug.
describe('BR.Keys.isHeld tracks a real release')
do
    for _, mech in ipairs({
        { name = 'level sample',   rawDown = true,  rawPressed = true },
        { name = 'edge fallback',  rawDown = false, rawPressed = true },
        { name = 'no raw layer',   rawDown = false, rawPressed = false },
    }) do
        bootOn(mech.rawDown, mech.rawPressed)
        pressInteract()
        frames(3)
        ok(BR.Keys.isHeld('interact') == true,
           ('held reads true while down -- %s'):format(mech.name))
        releaseInteract()
        frames(3)
        ok(BR.Keys.isHeld('interact') == false,
           ('held reads false after release -- %s'):format(mech.name))
    end
end

-- ======================================================================== --
-- 4b. THE SHAPE OF THE NATIVE'S ANSWER (#129 / #131, SEVENTH ROUND)
-- ======================================================================== --
--
-- One press of the smoke-trail key registered 545 presses and toggled the smoke
-- 545 times; a crate hold ran 446 frames and earned 0 of 1000ms at 0% duty.
-- Two reports, opposite in shape -- a key that fires far too often and a key
-- that never fires at all -- and ONE cause, which is why they are asserted
-- together in one block:
--
--   keybinds.lua stored the native's answer verbatim and then tested it with
--   `== true`, twice. `rawDown[cmd] == true` decides whether this frame is an
--   EDGE; `BR.Keys.held[action] == true` is BR.Keys.isHeld, which every hold in
--   the game asks. Hand those a value that is TRUTHY BUT NOT `true` and the
--   first is false on every frame -- so every frame is a rising edge, and a tap
--   repeats at 60Hz -- while the second is false on every frame, so a hold is
--   alive and earns nothing. Both symptoms, one line.
--
-- THE OLD SUITE COULD NOT SEE ANY OF IT, and that is the part worth keeping in
-- mind before trusting a green run: its stub was `return keys[vk] == true`, so
-- it handed the code the one shape the code got right, agreed with itself, and
-- reported 202 passing assertions while the interaction was dead on the owner's
-- machine. These blocks run the same interactions over every shape a FiveM BOOL
-- native is known to arrive in.

--- A TAP key, physically held. TAB is `brinventory`, registered through tap().
local TAP_VK  = 0x09
local TAP_KEY = 'TAB'

local function tapKey(down)
    if down then
        if not keys[TAP_VK] then
            keys[TAP_VK] = true
            edge[TAP_VK] = true
        end
    else
        keys[TAP_VK] = nil
    end
    engineKey(TAP_KEY, down)
end

for _, shape in ipairs(SHAPES) do

--- ONE PHYSICAL PRESS IS ONE TAP, HELD FOR AS LONG AS YOU LIKE.
---
--- The existing "exactly one mechanism drives the interact press" block holds
--- the key for a SINGLE frame, which cannot tell "once per press" from "once
--- per frame" -- there is only one frame. Sixty is what a real press is, and it
--- is the length at which #131 became visible from a chair.
describe('a tap fires once across a 60-frame hold -- ' .. shape.name)
do
    bootOn(true, true, shape)
    local n = 0
    BR.Keys.on('inventory', function(pressed) if pressed then n = n + 1 end end)

    tapKey(true)
    frames(60)
    local held = n
    tapKey(false)
    frames(10)

    ok(held == 1,
       'one press of a tap key fires exactly once, however long it is held',
       ('fired %d time(s) across 60 frames -- a tap is repeating per frame, '
        .. 'which is #131: one press of the trail key toggled the smoke 545 '
        .. 'times'):format(held))
    ok(n == held,
       'and the release adds nothing',
       ('fired %d before release, %d after'):format(held, n))
end

--- A HOLD EARNS EVERY FRAME OF ITS LIFE, AND THEN COMPLETES.
---
--- Asserted on the ACCUMULATOR and the duty cycle rather than only on the
--- claim, because "the crate opened" is satisfied by a clock running at any
--- speed given enough frames, and the fault being pinned here is a clock that
--- runs at zero.
describe('a hold accumulates the full duration -- ' .. shape.name)
do
    bootOn(true, true, shape)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    pressInteract()
    frames(1)
    ok(BR.Keys.isHeld('interact') == true,
       'isHeld reads true on the first frame of the hold',
       ('isHeld=%s -- BR.Keys.held is holding a value that is not the boolean '
        .. 'true, so every hold in the game is dead')
           :format(tostring(BR.Keys.isHeld('interact'))))

    -- 39 more frames: 40 x 16ms = 640ms, deliberately short of the 1000ms
    -- threshold so the accumulator can be read mid-flight.
    frames(39)
    local ms = holdMs() or -1
    ok(ms == 40 * 16,
       'the clock has earned every millisecond of a 40-frame hold',
       ('holdMs=%d, want %d -- the hold is alive and not counting')
           :format(ms, 40 * 16))
    ok(BR.Keys.isHeld('interact') == true,
       'and the key still reads held 40 frames in')

    frames(math.ceil(CHEST_MS / 16))
    local got = claims()
    ok(#got == 1 and got[1] == id,
       'and the hold crosses the threshold and opens the crate',
       ('claims=%d'):format(#got))

    local h = lastHold()
    ok(h and h.why == 'it completed', 'the readout says it completed',
       h and h.why)
    ok(h and h.pct == 100, 'at a 100% duty cycle',
       h and ('%d of %d frames earned time'):format(h.counted or -1, h.frames or -1))

    releaseInteract()
    frames(20)
end

end  -- shapes

--- AND THE HOLD SIDE OF THE SAME LINE, ASSERTED ON THE KEY LAYER ALONE.
---
--- The block above proves it through the crate. This proves it about
--- BR.Keys.held itself, which dbno.lua's revive and every future hold read
--- through the same isHeld() -- so a regression here is not a loot bug.
describe('isHeld is a boolean whatever the native returns')
do
    for _, shape in ipairs(SHAPES) do
        bootOn(true, true, shape)
        pressInteract()
        frames(30)
        local downOk = true
        for _ = 1, 30 do
            frame(16)
            if BR.Keys.isHeld('interact') ~= true then downOk = false end
        end
        ok(downOk,
           ('isHeld stays true for every frame of a 60-frame hold -- %s')
               :format(shape.name))
        releaseInteract()
        frames(20)
        ok(BR.Keys.isHeld('interact') == false,
           ('and goes false on the release -- %s'):format(shape.name))
    end
end

-- ======================================================================== --
-- 4c. AN UNPRODUCTIVE HOLD FAILS LOUDLY
-- ======================================================================== --
--
-- The fix above stops this happening. The alarm exists because it happened for
-- six rounds and NOTHING SAID SO: the hold stayed alive (every frame re-stamped
-- the release grace), the ring filled (it is a CSS animation on a fixed
-- duration), and /brloot printed `0/1000ms` -- which is also exactly what a
-- hold that has not started prints. The owner pasted that line and it was read
-- as "no hold is running".
--
-- Driven here through `lying`, which is a key state that reads UP while the key
-- is physically DOWN -- the same shape citizenfx/fivem#3064 describes, and the
-- same shape the value bug produced. What is asserted is not the mechanism but
-- the NOISE: a counter, a warning, a live marker and a post-mortem.

--- The session-wide starved-hold counter, read the way a player reads it.
local function starvedCount()
    local line = lootLine('^%s*starved%s+%d+ hold')
    return line and tonumber(line:match('starved%s+(%d+)'))
end

describe('a hold that earns nothing says so')
do
    bootOn(true, true)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    local before = starvedCount()
    ok(before ~= nil, '/brloot reports a starved-hold counter at all',
       'no `starved` line in the readout')

    -- PHYSICALLY HELD THROUGHOUT, AND THE SAMPLE READS UP ON FIVE FRAMES IN
    -- SIX. Gaps of 80ms, comfortably inside the 120ms grace, so the hold never
    -- dies -- which is the whole trap. The ring fills, the clock crawls at a
    -- sixth of wall-clock speed, and nothing ends. 2.4 seconds of that is more
    -- than twice what the hold needs and it is still nowhere near done.
    --
    -- The first frame is honest so the press lands and the hold starts; a
    -- rising edge is what creates a hold, and a sample that lies from the very
    -- first frame produces no hold to starve.
    pressInteract()
    frame(16)
    -- /brloot must not be called inside this loop: it resets `logged`, which is
    -- where the console warning has to be caught.
    logged = {}
    for i = 1, 150 do
        if i % 6 ~= 0 then lying[INTERACT_VK] = true end
        frame(16)
    end

    local warned = 0
    for _, l in ipairs(logged) do
        if l:find('STARVED HOLD', 1, true) then warned = warned + 1 end
    end
    ok(warned > 0, 'a warning naming the numbers reached the console',
       'the hold ran 2.4s earning a sixth of wall clock and said nothing')
    ok(warned <= 3, 'and it does not repeat at frame rate',
       ('printed %d times across 150 frames'):format(warned))

    ok(#claims() == 0, 'the crate does not open')
    ok(starvedCount() == (before or 0) + 1,
       'and the starved counter has gone up exactly once for this hold',
       ('starved %s -> %s'):format(tostring(before), tostring(starvedCount())))

    local live = lootLine('^%s*hold:')
    ok(live and live:find('STARVED', 1, true) ~= nil,
       'the live hold line is flagged rather than reading as an ordinary hold',
       tostring(live))

    releaseInteract()
    frames(20)

    local h = lastHold()
    ok(h ~= nil and h.best < CHEST_MS,
       'the post-mortem records a hold that never reached the threshold',
       h and tostring(h.best))
    ok(h and h.why == 'the key was released',
       'it still records the literal reason it ended', h and h.why)

    -- ...AND THE LINE THAT STOPS THAT REASON BEING BELIEVED. "it ended because
    -- the key was released" sent five rounds into the release path. It is true
    -- and it is not the fault.
    ok(lootLine('AND IT WAS STARVED') ~= nil,
       'and says the release was not why it failed',
       'the post-mortem blames the release with nothing to contradict it')
    ok(h and h.id == tostring(id), 'about the right crate',
       h and tostring(h.id))
end

--- THE ALARM MUST NOT FIRE ON A HOLD THAT IS MERELY IMPERFECT.
---
--- A false STARVED on a healthy client is worse than no alarm: it would send
--- the next person to the key layer, which is where the last six rounds went.
--- One dropped frame in twenty is the worst tolerated real fault
--- (citizenfx/fivem#3064) and it completes 50ms late.
describe('a healthy hold is never called starved')
do
    bootOn(true, true)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    local before = starvedCount()

    pressInteract()
    for i = 1, 300 do
        if i % 20 == 0 then lying[INTERACT_VK] = true end
        frame(16)
        if #claims() > 0 then break end
    end
    ok(#claims() == 1 and claims()[1] == id,
       'a hold that drops one frame in twenty still opens the crate')
    ok(starvedCount() == before,
       'and is not reported as starved',
       ('starved %s -> %s'):format(tostring(before), tostring(starvedCount())))

    releaseInteract()
    frames(20)
end

-- ======================================================================== --
-- 5. A REBOUND INTERACT KEY
-- ======================================================================== --
--
-- THE COMBINATION THAT PRODUCED "TRYING TO OPEN A CRATE DOES NOTHING AT ALL"
-- (#129, third round; #139).
--
-- Our own settings screen writes the rebind into the KVP the raw layer reads.
-- The ENGINE cannot be told about it -- nothing can change a RegisterKeyMapping
-- default from script, which is the whole reason the raw layer exists -- so the
-- engine's +brinteract / -brinteract pair stays on E forever.
--
-- So a build on which hold bindings are handed to the engine is a build on
-- which the prompt names the player's key and a different key does the work.
-- Both interactions live on that one press: the crate hold, and the loose-item
-- claim that fires on the same edge. That is exactly one report of "the crate
-- does nothing" and one of "picking up loose loot does not add it to my
-- inventory", from one cause.
--
-- The invariant asserted here is not "which mechanism" -- it is that the key
-- the player bound, and the key /brloot names, is the key that works.

--- Press whatever key the prompt currently names, however it is being driven.
---
--- This is the whole assertion, expressed as a helper: the label the DUI prompt
--- prints comes from BR.Keys.labelFor, so pressing "the key the prompt names"
--- is exactly what a player does. It is deliberately NOT parameterised on the
--- key the test rebound to -- which mechanism ends up owning a hold is allowed
--- to differ per build, and the invariant is that the sign and the door agree.
local LABEL_VK = { E = 0x45, R = 0x52 }
local function pressLabelled(down)
    local label = BR.Keys.labelFor('brinteract')
    local vk = label and LABEL_VK[label]
    if not vk then return nil end
    if down then
        if not keys[vk] then keys[vk] = true; edge[vk] = true end
    else
        keys[vk] = nil
    end
    -- The engine is bound to the DEFAULT key for ever; it delivers only when
    -- the label happens to still be that key.
    if vk == LABEL_VK[INTERACT_KEY] then engineKey(INTERACT_KEY, down) end
    return label
end

for _, mech in ipairs({
    { name = 'raw level sample (IsRawKeyDown)', rawDown = true,  rawPressed = true },
    { name = 'edge fallback (no IsRawKeyDown)', rawDown = false, rawPressed = true },
}) do

describe('rebound interact -- ' .. mech.name)
do
    bootOn(mech.rawDown, mech.rawPressed)
    BR.Keys.set('brinteract', 0x52)          -- the player picks R
    frames(2)
    clearWorld()
    local id = addEntry('chest', nil, 1.0, 0.0)
    frames(2)

    local label = BR.Keys.labelFor('brinteract')
    ok(label == 'R' or label == 'E',
       'the prompt names a key at all', tostring(label))

    -- HOLD THE KEY THE PROMPT NAMES.
    pressLabelled(true)
    frames(math.ceil(CHEST_MS / 16) + 4)
    local got = claims()
    ok(#got == 1 and got[1] == id,
       ('holding the key the prompt names (%s) opens the crate'):format(tostring(label)),
       ('claims=%d -- the prompt names a key nothing is listening to')
           :format(#got))
    pressLabelled(false)
    frames(20)

    -- AND THE LOOSE-ITEM CLAIM, WHICH RIDES THE SAME PRESS.
    clearWorld()
    local lid = addEntry(BR.ItemKind.WEAPON, 'pistol', 1.0, 0.0)
    frames(2)
    pressLabelled(true)
    frame(16)
    pressLabelled(false)
    frames(2)
    local lgot = claims()
    ok(#lgot == 1 and lgot[1] == lid,
       ('and the same key (%s) picks up a loose item'):format(tostring(label)),
       ('claims=%d'):format(#lgot))

    BR.Keys.reset('brinteract')
    BR.Keys.reset('bruse')
    frames(2)
end

end  -- mechanisms

-- The diagnostics are the only instrument a playtester has. A readout that
-- throws costs a whole round trip, and both of these have been asked for by
-- name in an issue comment.
describe('the debug readouts run')
do
    bootOn(true, true)
    clearWorld()
    addEntry('chest', nil, 1.0, 0.0)
    frames(2)
    logged = {}
    ok(pcall(commands['brloot'], nil, {}, ''), '/brloot does not throw')
    ok(pcall(commands['brkeys'], nil, {}, ''), '/brkeys does not throw')
    ok(pcall(commands['brarc'], nil, {}, ''), '/brarc does not throw')
end

describe('an item born from a container is given a body NOW, not on the 1Hz pass')
do
    -- THE ARRIVAL ARC'S FIRST BROKEN LINK (owner, 2026-08-23: "The loot doesn't
    -- animate out of the crate like it should").
    --
    -- animate() cannot move a prop that does not exist -- its first line returns
    -- on `not e.obj` -- and the ONLY thing that ever asked for a prop was the
    -- loot.props pass, registered on the SLOW band at once per SECOND. The
    -- arrival window is 520ms. So an item bursting out of a crate two metres
    -- away waited up to twice its own animation for a body, and by the time it
    -- had one the window had shut. The branch was not broken; it was
    -- unreachable, for every container, since it was written.
    --
    -- THIS IS PROVABLE HERE PRECISELY BECAUSE THE SLOW BAND IS NEVER STEPPED IN
    -- THIS FILE. Nothing else in the harness can put an id in that queue, so a
    -- queue that grows on the LOOT_ADD alone is the queue-jump and nothing else.
    bootOn(true, true)
    clearWorld()

    local ITEM = BR.Config.Consumables[1].id

    --- What /brloot says is waiting for a model.
    local function queuedNow()
        local line = lootLine('queued%s+%d+')
        return line and tonumber(line:match('queued%s+(%d+)'))
    end

    local bornBefore = BR.Loot.arc.born

    -- The generated layout was always just there. No origin, no hurry: it can
    -- wait for the trickle like the other hundred entries in the cell.
    fire(BR.Net.LOOT_ADD, { {
        id = 9001, kind = BR.ItemKind.CONSUMABLE, item = ITEM,
        x = 2.0, y = 0.0, z = 30.0, rarity = BR.Rarity.COMMON, count = 1,
    } })
    ok(queuedNow() == 0, 'an entry with no origin waits for the 1Hz pass',
        tostring(queuedNow()))

    -- One that has this instant come out of a container cannot.
    fire(BR.Net.LOOT_ADD, { {
        id = 9002, kind = BR.ItemKind.CONSUMABLE, item = ITEM,
        x = 2.0, y = 1.5, z = 30.0, rarity = BR.Rarity.COMMON, count = 1,
        fx = 0.5, fy = 0.5, fl = 0.6,
    } })
    ok(queuedNow() == 1, 'one born with an origin jumps the queue',
        tostring(queuedNow()))
    ok(BR.Loot.arc.born == bornBefore + 1,
        'and is counted, so /brarc can say whether any of this ran',
        ('%d -> %d'):format(bornBefore, BR.Loot.arc.born))

    -- ...BUT ONLY IF IT IS CLOSE ENOUGH TO BE WORTH A BODY. drain() builds
    -- whatever it is handed and never asks how far away it is, so without this
    -- gate a container opened at the far edge of the 768m subscription would
    -- build props nobody can see, for the next pass to tear straight back down.
    fire(BR.Net.LOOT_ADD, { {
        id = 9003, kind = BR.ItemKind.CONSUMABLE, item = ITEM,
        x = 900.0, y = 0.0, z = 30.0, rarity = BR.Rarity.COMMON, count = 1,
        fx = 898.0, fy = 0.0, fl = 0.6,
    } })
    ok(queuedNow() == 1, 'a container opened beyond prop range still does not',
        tostring(queuedNow()))
end

-- ------------------------------------------------------------------- voice ---
--
-- WHAT THESE TESTS CAN AND CANNOT PROVE, FIRST, BECAUSE SIX ROUNDS OF THIS
-- ISSUE SHIPPED GREEN.
--
-- br_core no longer produces audio. pma-voice does. So nothing here can prove
-- that two players hear each other -- it never could, and pretending otherwise
-- is what let 31 green voice assertions sit on top of a total outage (#150).
--
-- WHAT IS PROVABLE IS THE PART WE STILL OWN, and it is the part that was
-- actually wrong every time: WHICH RULES WE HAND pma-voice. Every mode maps to
-- a proximity answer and a radio channel; the bus rule is a branch in a pure
-- function; the squad radio number is the server's. Those are decisions, they
-- are ours, and they are testable to the same standard as combat_solve.
--
-- THE MODEL IS pma-voice'S DOCUMENTED SURFACE, read out of its source -- see
-- the pmaAPI block near the top of this file for the file-by-file citation.
-- The one thing this suite deliberately refuses to model is anything about how
-- Mumble mixes audio, because that is precisely the class of assumption that
-- has cost this project four playtests: every previous round wrote a stub that
-- agreed with the code, and the stub and the code were wrong together.

--- Where this machine's own player is standing.
local function standAt(x, y)
    pedPos = { x = x + 0.0, y = y + 0.0, z = 30.0 }
end

--- Everybody ELSE, on the roster and in the world.
---
--- TWO SEPARATE FACTS AND THE TESTS NEED BOTH, and the reason has inverted
--- since the last round. The roster is a server broadcast and carries every
--- connected player; the ped only exists while they are in scope. That
--- combination -- known, connected, unplaceable -- used to be the case that
--- deafened a match. Under pma-voice it is the ordinary case for almost
--- everybody in a 48-player match, and it must resolve to "I do not transmit to
--- them", which costs nothing and is what proximity means.
---
--- @param list table  [serverId] = { x =, y = } for a player in scope,
---                    or `false` for on-the-roster-but-not-streamed
local function playersAt(list)
    others = {}
    BR.State.roster = { [BR.State.me.src] = { name = 'me' } }
    for src, p in pairs(list) do
        BR.State.roster[src] = { name = 'p' .. tostring(src) }
        if p then others[src] = { x = p.x + 0.0, y = p.y + 0.0 } end
    end
end

local function nobodyElse()
    others = {}
    BR.State.roster = {}
end

--- ONE pma-voice PROXIMITY TICK, which is the only thing that ever consults
--- our rules.
---
--- This is addNearbyPlayers() from client/init/proximity.lua: clear the
--- channels, then ask the proximity check about every player in the streamed
--- list and keep the ones it says yes to. Two details are load-bearing:
---
---   IT CLEARS FIRST. So a tick on which the check refuses everybody leaves an
---   EMPTY transmit set -- that is the gag, and it is why the gag needs no
---   teardown of its own.
---   IT ONLY OFFERS PLAYERS IN SCOPE. `others` is the streamed list, so a
---   player on the roster with no ped is never even asked about.
local function pmaTick()
    pma.sends = {}
    if not pma.check then return end
    -- The 100 ms position cache in voice.lua is keyed on the game timer, so a
    -- tick that does not advance it would re-use the previous tick's
    -- coordinates -- which is exactly the bug the cache could have introduced
    -- and is worth stepping past rather than around.
    fakeTime = fakeTime + 200
    for src in pairs(others) do
        if src ~= BR.State.me.src then
            local add = pma.check(src)
            if add then pma.sends[src] = true end
        end
    end
end

--- Everything about one machine's voice rules, frozen.
local function pmaSnapshot()
    local sends, muted = {}, {}
    for src in pairs(pma.sends) do sends[src] = true end
    for src in pairs(pma.muted) do muted[src] = true end
    return { src = BR.State.me.src, sends = sends, muted = muted,
             radio = pma.radio, range = pma.range, noCycle = pma.noCycle,
             running = pma.running, calls = table.concat(pma.calls, ' ') }
end

--- CAN `speaker` BE HEARD BY `listener`?
---
--- THE DIRECTIONALITY IS THE WHOLE MODEL. Proximity is a fact about the
--- SPEAKER's transmit set, full stop -- if they did not send to us, no amount
--- of listening helps, and if they did, nothing on our side is filtering it.
--- The only listener-side lever in pma-voice is the per-player mute, which is
--- the one thing 'off' is allowed to use.
---
--- Note what is deliberately NOT here: any notion of the LISTENER's own
--- proximity check. A previous round's model asked the listener about its own
--- microphone state and so let a bug that gagged a player also "prove" they
--- were deaf, which is how the bus gag passed while it was silencing a match.
local function hears(speaker, listener)
    if listener.muted[speaker.src] then return false end
    if speaker.sends[listener.src] then return true end
    -- The squad radio: a channel, ignoring distance entirely. Both ends have to
    -- actually be on it -- being ASSIGNED one is not being on one.
    if speaker.radio and speaker.radio ~= 0
        and speaker.radio == listener.radio then return true end
    return false
end

local VR = BR.Config.Match.voice.range

--- PUT THIS MACHINE ON ONE VOICE MODE, WHICHEVER KIND OF MATCH IT IS IN.
---
--- The preference is TWO stored values now -- one for solos, one for squads --
--- and which is in force is derived from BR.State.match.mode on every read
--- (BR.VoiceModeFor, br_lib/shared/enums.lua). Almost every block below is
--- about ROUTING rather than about that resolution, and each one would
--- otherwise have to know which slot its scene's match kind was going to
--- consult -- a fact none of them care about and all of them could get wrong.
---
--- So this writes BOTH slots. The mode in force is then `mode` whatever the
--- match kind is, which is exactly the invariant those blocks were written
--- against. The resolution itself is asserted on its own, deliberately, in the
--- block that is about it -- with the two slots set to DIFFERENT values, which
--- is the only way to observe which one won.
---
--- ...AND IT PUTS THE SCENE IN A SQUAD MATCH, which is not a convenience
--- either. Every one of these blocks has squadmates, a server-granted radio
--- channel and a mute sweep built from a squad list: they ARE squad matches,
--- and a squad match is the only kind in which all three modes are reachable.
--- Leaving the match kind unset would mean the SOLO slot decided every one of
--- them -- where 'squad' is coerced away by design -- so the squad-routing
--- blocks would silently be testing 'nearby' and passing for the wrong reason.
--- That failure would look exactly like the bug: a suite agreeing with itself.
--- @param mode string 'squad' | 'nearby' | 'off'
local function setVoicePref(mode)
    BR.State.match.mode = BR.Mode.SQUAD.key
    fire('br:settings:changed', {
        voiceModeSolo = mode, voiceModeSquad = mode,
    })
end

--- The same, WITHOUT the event -- for blocks that drive BR.Voice's internals
--- directly and would be disturbed by an apply() they did not ask for.
--- @param mode string|nil
local function forceVoiceMode(mode)
    BR.State.match.mode = BR.Mode.SQUAD.key
    BR.Voice.pref.solo, BR.Voice.pref.squad = mode, mode
end

--- Bring one machine up from nothing: a fresh pma-voice, a mode, and a server
--- assignment. Returns the frozen rules.
---
--- @param mode  string 'squad' | 'nearby' | 'off'
--- @param radio integer|nil  the squad radio the server assigned
--- @param mates table|nil
--- @param me    integer|nil  this machine's own server id
--- @param state string|nil   this player's match state; BUS is the bus rule
local function voiceApply(mode, radio, mates, me, state)
    BR.State.me.src = me or 1
    BR.State.me.state = state or BR.PlayerState.ALIVE
    pmaReset()
    -- A FRESH RESOURCE MEANS A FRESH VIEW OF IT. br_core diffs the radio
    -- channel it has asked for, so leaving its bookkeeping populated across the
    -- reset would have it skip the join as already-done and assert against a
    -- resource nobody ever spoke to. The real game reaches this state when
    -- pma-voice restarts, which is why the handler there clears exactly these.
    BR.Voice.state.joined = nil
    BR.Voice.state.muted = {}
    BR.Voice._warned = {}
    -- Force the preference through, even when it matches the last test's:
    -- br:settings:changed early-returns on an unchanged pair, which is correct
    -- in the game and would silently skip the setup here.
    BR.Voice.pref.solo, BR.Voice.pref.squad = nil, nil
    -- br_core starting is what installs the rules into pma-voice.
    fire('onClientResourceStart', 'br_core')
    -- AND IT IS WHAT UNDOES THE LINE AT THE TOP OF THIS FUNCTION, which is why
    -- the id is stated AGAIN, here, after the fire rather than only before it.
    --
    -- client/main.lua's own onClientResourceStart does
    --     BR.State.me.src = GetPlayerServerId(PlayerId())
    -- and this harness stubs GetPlayerServerId to a constant 1. So every
    -- machine this helper has ever built has come back believing it was player
    -- 1, and the `me` argument -- which the squad blocks pass 2, 3 and 5 to --
    -- has been INERT for the life of this suite.
    --
    -- IT WENT UNNOTICED BECAUSE NOTHING DEPENDED ON IT UNTIL NOW. Those blocks
    -- assert through the radio channel, which does not involve a server id, and
    -- their scenes are built with nobodyElse() so the transmit set is empty
    -- either way. The exclusivity block below is the first one that needs two
    -- machines with DIFFERENT ids and a populated scene -- and there it is not
    -- a cosmetic flaw: pmaTick() skips `src == BR.State.me.src`, so a second
    -- machine that thinks it is player 1 silently refuses to consider player 1
    -- and reports an empty transmit set that looks exactly like the bug under
    -- test.
    BR.State.me.src = me or 1
    setVoicePref(mode)
    fire(BR.Net.VOICE_SET, { radio = radio, mates = mates,
                             nearbyRange = VR.nearby })
    BR.Loop.step(BR.Loop.TICK)
    pmaTick()
    return pmaSnapshot()
end

--- Change the preference on a machine that already has an assignment -- the
--- settings screen, mid-match -- and let one pma-voice tick pass.
local function voiceMode(mode)
    setVoicePref(mode)
    BR.Loop.step(BR.Loop.TICK)
    pmaTick()
    return pmaSnapshot()
end

--- Move this player between match states without touching anything else. The
--- bus rule lives and dies on this being the ONLY thing that changed.
local function beState(st)
    BR.State.me.state = st
    BR.Loop.step(BR.Loop.TICK)
    pmaTick()
    return pmaSnapshot()
end

--- Who the "Currently Talking" indicator is naming right now, read out of the
--- NUI push rather than off BR.Voice.talking -- the push is what reaches the
--- screen the owner is looking at.
local function talkingNames()
    local out = {}
    for i = #events, 1, -1 do
        local e = events[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.VOICE then
            for _, n in ipairs((e.args[2] or {}).names or {}) do
                out[#out + 1] = n
            end
            return out
        end
    end
    return out
end

describe('br_core hands its rules to pma-voice, and calls no Mumble native')
do
    nobodyElse()
    standAt(0, 0)
    local a = voiceApply('nearby', nil, nil, 1)

    -- 1. THE RULES ARE INSTALLED AT ALL. Everything else in this section is
    --    downstream of this one call: if the override is not registered,
    --    pma-voice quietly uses its own 7-metre roleplay default and every
    --    assertion below would be testing a function nobody ever calls.
    ok(a.calls:find('overrideProximityCheck') ~= nil,
        'the proximity check is handed to pma-voice on start', a.calls)

    -- 2. AND SO IS OUR RANGE, with the cycle key disabled. pma-voice ships
    --    three cycleable ranges and an F11 binding; this gamemode has one
    --    range and a player who found that key could otherwise put themselves
    --    on a range the gamemode never sanctioned.
    ok(a.range == VR.nearby,
        'our configured range is the one in force, not pma-voice\'s default',
        tostring(a.range))
    ok(a.noCycle == true,
        'and the proximity cycle key is disabled', tostring(a.noCycle))

    -- 3. THE NEGATIVE THAT THE WHOLE CHANGE RESTS ON.
    --
    --    pma-voice's README asks other resources not to touch
    --    NetworkSetTalkerProximity, MumbleSetTalkerProximity,
    --    MumbleSetAudioInputDistance, MumbleSetAudioOutputDistance or
    --    NetworkSetVoiceActive, "as there have been cases where it breaks
    --    pma-voice" -- and every one of those is a native some round of this
    --    file reached for. Two of them are what made 'nearby' silent.
    --
    --    This is asserted rather than left as a comment because it is the
    --    single easiest thing for a later round to undo in good faith, while
    --    "fixing" something else.
    ok(mumble.inDist == nil and mumble.outDist == nil,
        'the engine distance natives are never called', 'someone armed a cutoff')
    ok(mumble.prox == nil,
        'and neither is the GTA talker proximity -- pma-voice owns that now',
        tostring(mumble.prox))
    ok(mumble.gameVoice == true,
        'and NETWORK_SET_VOICE_ACTIVE is left exactly as pma-voice left it',
        tostring(mumble.gameVoice))
    ok(mumble.active == true and mumble.channel == 0,
        'and MUMBLE_SET_ACTIVE is never touched -- it is a disconnect, not a mic',
        ('active=%s channel=%s'):format(tostring(mumble.active),
                                        tostring(mumble.channel)))
end

describe('nearby is proximity WITH a range -- the capability #157 gave up')
do
    -- THE REGRESSION THIS WHOLE CHANGE EXISTS TO UNDO. The shipped build had no
    -- proximity cutoff at all: "even when set to nearby (while in squads or
    -- solos), the channel is global." Somebody 800 m away was as audible as
    -- somebody standing next to you.
    standAt(0, 0)
    playersAt({ [2] = { x = 5, y = 0 },                  -- close
                [3] = { x = VR.nearby + 25, y = 0 },     -- far, but streamed
                [4] = false })                           -- on the roster, not streamed
    local me = voiceApply('nearby', nil, nil, 1)

    ok(me.sends[2] == true,
        'a player inside the range is transmitted to')
    ok(me.sends[3] == nil,
        'and one outside it is NOT -- this is the line that was missing',
        'a player past the cutoff is still being sent audio')
    ok(me.sends[4] == nil,
        'and one the game never streamed is not invented into range')

    -- THE EDGE, from both sides, because "25 m" has to mean something exact.
    playersAt({ [2] = { x = VR.nearby - 0.5, y = 0 } })
    pmaTick()
    ok(pma.sends[2] == true, 'just inside the range is inside it')
    playersAt({ [2] = { x = VR.nearby + 0.5, y = 0 } })
    pmaTick()
    ok(pma.sends[2] == nil, 'just outside it is outside it')

    -- AND IT IS RE-DECIDED AS PEOPLE WALK, which is the difference between a
    -- range and a one-off assignment. The old design stated its routing once,
    -- after the room was confirmed, and had no way to express this at all.
    playersAt({ [2] = { x = 3, y = 0 } })
    pmaTick()
    local near = pma.sends[2]
    playersAt({ [2] = { x = 400, y = 0 } })
    pmaTick()
    ok(near == true and pma.sends[2] == nil,
        'walking out of range takes the audio with it, with no event to prompt it')
end

describe('squad voice is a radio and works at ANY distance')
do
    -- THE ONE THING THAT HAS EVER WORKED AND MUST NOT REGRESS. Two squadmates,
    -- a kilometre apart, neither streamed to the other -- which is the ordinary
    -- state of a squad in a battle royale and the exact case a proximity system
    -- cannot serve.
    local RADIO = 30503

    BR.State.me.src = 1
    nobodyElse()
    standAt(0, 0)
    local a = voiceApply('squad', RADIO, { 2 }, 1)

    BR.State.me.src = 2
    nobodyElse()
    standAt(1000, 1000)
    local b = voiceApply('squad', RADIO, { 1 }, 2)

    ok(a.radio == RADIO and b.radio == RADIO,
        'both squadmates joined the radio channel the server assigned',
        ('a=%s b=%s'):format(tostring(a.radio), tostring(b.radio)))
    ok(hears(a, b) and hears(b, a),
        'and they hear each other a kilometre apart, out of scope, both ways')

    -- AND IT IS NOT PROXIMITY DOING IT, which is the assertion that stops a
    -- future round "simplifying" the radio away. Neither machine has the other
    -- in its transmit set at all.
    ok(a.sends[2] == nil and b.sends[1] == nil,
        'proximity is not what carried it -- the radio is genuinely separate')

    -- A SOLO GETS NO RADIO, and asks for none.
    nobodyElse()
    local solo = voiceApply('squad', nil, nil, 3)
    ok(solo.radio == 0,
        'a solo who prefers squad voice asks for no channel at all',
        tostring(solo.radio))
end

describe('nearby declines the squad radio, and off declines everything')
do
    local RADIO = 30503
    nobodyElse()
    standAt(0, 0)

    local sq = voiceApply('squad', RADIO, { 2 }, 1)
    ok(sq.radio == RADIO, 'squad joins the assigned channel')

    -- THE PREFERENCE CAN ONLY DECLINE. The server assigns the same channel
    -- whatever the player picked -- it does not know and must not care -- so
    -- 'nearby' has to be what leaves it.
    local nb = voiceMode('nearby')
    ok(nb.radio == 0,
        'switching to nearby LEAVES the squad radio', tostring(nb.radio))

    local off = voiceMode('off')
    ok(off.radio == 0, 'and off is not on it either', tostring(off.radio))

    -- AND BACK. A preference is not a one-way door, and the previous design's
    -- overrides outlived the setting that created them: "a player who switched
    -- from 'squad' to 'nearby' kept hearing their old squad at any range."
    local back = voiceMode('squad')
    ok(back.radio == RADIO,
        'and going back re-joins it', tostring(back.radio))
end

-- ==========================================================================
describe('THE MODES ARE EXCLUSIVE -- squad is not proximity, nearby is not squad')
do
    -- THE OWNER'S SPEC, WHICH HAS NOW BEEN RESTATED THREE TIMES:
    --
    --   "Nearby should only be nearby, different from squads and not additional
    --    to it... Squads should be set to no distance/fade/etc and only
    --    talk/listen within a given squad."
    --
    -- WHY EVERY EXISTING BLOCK ABOVE PASSED ON THE BROKEN BUILD, which is the
    -- part worth understanding before reading the assertions. The squad block
    -- puts two squadmates a kilometre apart with NOBODY ELSE IN THE SCENE, so
    -- "squad also routes proximity" costs nothing there -- there is no third
    -- player standing close enough for proximity to reach. The nearby block has
    -- no squad at all. Neither block could see the defect because neither block
    -- contained the two kinds of player AT ONCE, and that is precisely what a
    -- real match is.
    --
    -- SO THIS SCENE HAS BOTH, and it is the whole point of the block:
    --
    --   1  us
    --   2  OUR SQUADMATE, a kilometre away, not streamed to this machine
    --   3  A STRANGER, two metres away, streamed, on 'nearby' and talking
    --
    -- Under the old code, 'squad' answered yes to both of them.
    --
    -- NOTHING BELOW ASKS OUR CODE WHAT IT THINKS IT DID. Every assertion goes
    -- through hears(), which is a model of pma-voice's documented surface --
    -- a transmit set, a radio channel and a per-player mute -- and knows
    -- nothing about BR.VoiceRouting. That separation is the thing seven false
    -- passes on this issue lacked.
    local RADIO = 30503

    --- The stranger's machine: 'nearby', two metres from us, transmitting.
    --- Built ONCE and reused, because their behaviour is not what is under test
    --- -- they are the fixed fact that the modes below have to answer about.
    BR.State.me.src = 3
    standAt(2, 0)
    playersAt({ [1] = { x = 0, y = 0 }, [2] = false })
    local stranger = voiceApply('nearby', nil, nil, 3)
    ok(stranger.sends[1] == true,
        'the stranger two metres away really is transmitting to us -- so every '
            .. 'silence below is a decision and not an empty scene',
        'the scene is broken: nobody is talking, so nothing below proves '
            .. 'anything')

    --- Our squadmate's machine: 'squad', a kilometre away, out of scope.
    BR.State.me.src = 2
    standAt(1000, 1000)
    playersAt({ [1] = false, [3] = false })
    local mate = voiceApply('squad', RADIO, { 1 }, 2)

    -- ---------------------------------------------------------------- squad --
    BR.State.me.src = 1
    standAt(0, 0)
    playersAt({ [2] = false, [3] = { x = 2, y = 0 } })
    local sq = voiceApply('squad', RADIO, { 2 }, 1)

    ok(hears(sq, mate) and hears(mate, sq),
        'squad still reaches a squadmate a kilometre away, both ways',
        'squad voice at range is broken -- that is the one thing that worked')

    -- THE ASSERTION THIS WHOLE ROUND EXISTS FOR, in both directions.
    ok(not hears(sq, stranger),
        'a squad player is NOT heard by the stranger standing next to them',
        'squad is still transmitting on proximity -- this is the defect')
    ok(not hears(stranger, sq),
        'and does NOT hear that stranger either, though the stranger is '
            .. 'transmitting to them',
        'squad is still HEARING proximity -- refusing to send was never enough')

    -- AND THE MECHANISM OF EACH HALF, separately, so a failure above says which
    -- half broke rather than only that something did.
    ok(next(sq.sends) == nil,
        'squad adds nobody at all to its proximity transmit set',
        'the proximity check is still answering yes for somebody on squad')
    ok(sq.muted[3] == true,
        'and it holds a mute on the non-squadmate -- the listen half',
        'the stranger is not muted, so their audio arrives whatever we send')
    ok(sq.muted[2] == nil,
        'while the SQUADMATE is never muted, which is what makes it a squad '
            .. 'and not silence',
        'squad muted its own squadmate')

    -- --------------------------------------------------------------- nearby --
    BR.State.me.src = 1
    standAt(0, 0)
    playersAt({ [2] = false, [3] = { x = 2, y = 0 } })
    -- THE SAME SERVER ASSIGNMENT. The server does not know or care which mode
    -- the player picked -- it hands out the squad radio either way -- so the
    -- radio being declined has to be this client's doing, and handing it the
    -- channel here is what makes that a real test rather than an absent one.
    local nb = voiceApply('nearby', RADIO, { 2 }, 1)

    ok(hears(nb, stranger) and hears(stranger, nb),
        'a nearby player hears the stranger next to them, and is heard',
        'nearby is silent at two metres -- this is #150')

    ok(not hears(nb, mate) and not hears(mate, nb),
        'and does NOT reach their own squadmate across the island',
        'nearby is still routing the squad -- nearby must be nearby only')
    ok(nb.radio == 0,
        'because nearby declines the radio the server assigned it',
        tostring(nb.radio))
    ok(next(nb.muted) == nil,
        'and nearby refuses nobody -- it holds no mutes at all',
        'nearby is muting somebody, which is how a receive-side gate gets back '
            .. 'in and how nearby went silent four times')

    -- ---------------------------------------- the mode is one channel, never two
    --
    -- STATED ON THE TABLE ITSELF, and this one IS a re-encoding of the code --
    -- deliberately, and it is not doing the work above. Its job is the mode
    -- nobody has added yet: a fourth row with both columns set would sail past
    -- every behavioural assertion in this block, because none of them would
    -- ever be run against it.
    for mode, r in pairs(BR.VoiceRouting) do
        ok(not (r.proximity and r.radio),
            ('routing for %q opens one channel, not two'):format(mode),
            'a mode routes proximity AND the radio -- that is the layering the '
                .. 'owner rejected')
    end
end

describe('the voice default has one definition, and br_core reads it')
do
    -- THE SIGNATURE FAILURE OF THIS PROJECT, on the smallest possible subject.
    -- br_ui/client/settings.lua said 'nearby'; br_core/client/voice.lua said
    -- 'squad'; both were spelled out by hand; nothing compared them. Settings
    -- won in practice only because br_ui pushes on br:ui:ready, so the answer
    -- to "what does a player who never opens the settings screen get" depended
    -- on a race nobody had looked at.
    ok(BR.VoiceModeDefault == 'nearby',
        "the shipped default is 'nearby' -- the only mode that works for a solo",
        tostring(BR.VoiceModeDefault))

    -- THE FALLBACK IS THE DEFAULT, not a second opinion about it. Driven with
    -- the payloads that actually reach this handler in the wild: a mode from an
    -- older build, and no mode at all.
    nobodyElse()
    standAt(0, 0)
    voiceApply('off', nil, nil, 1)

    fire('br:settings:changed',
         { voiceModeSolo = 'globalchat', voiceModeSquad = 'globalchat' })
    ok(BR.Voice.mode() == BR.VoiceModeDefault,
        'an unknown mode falls back to the shared default, not to a literal '
            .. 'this file spelled out for itself',
        tostring(BR.Voice.mode()))

    voiceApply('off', nil, nil, 1)
    fire('br:settings:changed', {})
    ok(BR.Voice.mode() == BR.VoiceModeDefault,
        'and so does a payload with no voice mode in it at all',
        tostring(BR.Voice.mode()))

    -- ==================================================================== --
    -- TWO SAVED PREFERENCES, AND THE MATCH KIND PICKS. This is the one place
    -- the two slots are set to DIFFERENT values, which is the only way to
    -- observe which one won -- everywhere else in this file setVoicePref()
    -- writes both, deliberately, so that the routing blocks are about routing.
    --
    -- THE ROW THAT MATTERS IS THE THIRD ONE. A player who chose 'squad' and
    -- then queued a solo used to carry 'squad' into a match with no squads,
    -- which is total silence by design and identical to a fault (#157). The
    -- solo slot cannot hold 'squad' at all, so there is no longer a stored
    -- value that can produce it.
    fire('br:settings:changed',
         { voiceModeSolo = 'off', voiceModeSquad = 'nearby' })

    BR.State.match.mode = BR.Mode.SOLO.key
    ok(BR.Voice.mode() == 'off',
        'a solo match reads the SOLO preference', tostring(BR.Voice.mode()))

    BR.State.match.mode = BR.Mode.SQUAD.key
    ok(BR.Voice.mode() == 'nearby',
        'and a squad match reads the SQUAD one, from the same stored pair',
        tostring(BR.Voice.mode()))

    fire('br:settings:changed',
         { voiceModeSolo = 'squad', voiceModeSquad = 'squad' })
    BR.State.match.mode = BR.Mode.SOLO.key
    ok(BR.Voice.mode() == BR.VoiceModeDefault,
        "'squad' cannot be stored as a SOLO preference -- it is coerced to the "
            .. 'default, because a solo match has no squad radio and honouring '
            .. 'it would be silence',
        tostring(BR.Voice.mode()))
    BR.State.match.mode = BR.Mode.SQUAD.key
    ok(BR.Voice.mode() == 'squad',
        'while the squad slot keeps it', tostring(BR.Voice.mode()))

    -- THE LOBBY, AND ANY CLIENT THAT HAS NOT BEEN TOLD YET, RESOLVE TO SOLO.
    -- Not an accident of a nil compare: a player with no match around them has
    -- no squad, and the solo slot is the one that cannot be silence.
    fire('br:settings:changed',
         { voiceModeSolo = 'nearby', voiceModeSquad = 'off' })
    BR.State.match.mode = nil
    ok(BR.Voice.mode() == 'nearby',
        'an unknown match kind resolves to the solo preference',
        tostring(BR.Voice.mode()))
    BR.State.match.mode = BR.Mode.SQUAD.key

    -- AND EVERY VALID MODE SURVIVES THE COERCION UNCHANGED, which is the other
    -- way a shared coercer goes wrong: one that returned the default for
    -- everything would pass both assertions above.
    local kept = true
    for mode in pairs(BR.VoiceRouting) do
        if BR.ToVoiceMode(mode) ~= mode then kept = false end
    end
    ok(kept, 'while every real mode passes through the coercion untouched',
        'BR.ToVoiceMode is eating valid modes')

    -- THE br_ui HALF IS NOT REACHABLE FROM THIS SUITE -- it loads br_core only,
    -- and br_ui/client/settings.lua wants KVP natives this harness does not
    -- stub. Nor is the TypeScript default in ui-src/src/settings/apply.ts,
    -- which is a third spelling of the same value. Both are compared against
    -- BR.VoiceModeDefault by tools/verify.sh's `voice defaults` gate, which
    -- reads the three files as text. Named here so the next person looking for
    -- that coverage finds it rather than concluding it does not exist.
end

describe('OFF means not transmitting AND not listening')
do
    -- Owner, on the version that only did the first half: "'off' does not work
    -- -- it still leaves a player in what seems to be global... 'you are not
    -- transmitting' should also mean 'you are not listening', but alas both are
    -- false."
    standAt(0, 0)
    playersAt({ [2] = { x = 2, y = 0 }, [3] = { x = 4, y = 0 } })
    local me = voiceApply('off', 30503, { 2 }, 1)

    ok(next(me.sends) == nil,
        'off transmits to nobody, however close they are standing')
    ok(me.radio == 0, 'and holds no radio')

    -- THE HALF THAT WAS NEVER BUILT. Muting is the only listener-side lever
    -- pma-voice has, and it is used here and nowhere else in the whole file.
    ok(me.muted[2] == true and me.muted[3] == true,
        'and everybody on the roster is muted -- which is what "not listening" is')

    -- INCLUDING SQUADMATES, whose radio would otherwise outlive the setting
    -- exactly as it used to.
    local speaker = { src = 2, sends = { [1] = true }, muted = {}, radio = 30503 }
    ok(not hears(speaker, me),
        'a squadmate on the radio cannot be heard through off either')
end

describe('OFF LIFTS -- the mute cannot outlive the setting that made it')
do
    -- THE FAILURE MODE THIS IS WRITTEN AGAINST is not "off does not mute". It
    -- is "off muted and something did not unmute", which is a player who is
    -- permanently deaf and has no idea why -- the shape of #157 round two,
    -- where recovery depended on an engine behaviour nobody had ever watched.
    standAt(0, 0)
    playersAt({ [2] = { x = 2, y = 0 }, [3] = { x = 4, y = 0 } })
    local off = voiceApply('off', 30503, { 2 }, 1)
    ok(off.muted[2] and off.muted[3], 'muted, as asked')

    local back = voiceMode('nearby')
    ok(next(back.muted) == nil,
        'and ONE tick after leaving off, nobody is muted at all',
        'somebody is still muted outside off -- this is the deafness bug')

    -- AND THE UNMUTE IS NOT CONDITIONAL ON HAVING SEEN THE TRANSITION. This is
    -- the property that the bus gag lacked twice: recovery has to be driven by
    -- the CURRENT state, not by an event somebody has to catch.
    voiceMode('off')
    BR.Loop.step(BR.Loop.TICK)
    ok(next(pma.muted) ~= nil, 'muted again')
    -- Reach past the event entirely: set the preference the way a reload or a
    -- race would, with no settings event fired at all, and let the band run.
    --
    -- 'nearby' RATHER THAN 'squad', AND THE CHANGE IS DELIBERATE. This line
    -- used to read 'squad' and passed because 'squad' held no mutes at all --
    -- it was proximity plus a radio and refused nobody. 'squad' now refuses
    -- every non-squadmate, so it is the wrong mode to prove "the mutes lift":
    -- it would be asserting that a mode which is SUPPOSED to hold mutes does
    -- not. 'nearby' is the mode that refuses nobody, so it is the one that
    -- makes this a test of the unmute path rather than of the mode.
    forceVoiceMode('nearby')
    BR.Loop.step(BR.Loop.TICK)
    ok(next(pma.muted) == nil,
        'and the mutes lift on the next tick with NO event to prompt it',
        'the unmute needed an event -- that is exactly how this bug ships')

    -- AND THE SAME PROPERTY FOR THE OTHER MUTING MODE, which is new. Going
    -- off -> squad must release the squadmates and keep everybody else, on a
    -- tick, with no event -- because 'squad' reaches the same sweep 'off' does
    -- and a release that only works for one of them is a permanently deaf
    -- squad.
    playersAt({ [2] = { x = 2, y = 0 }, [3] = { x = 4, y = 0 } })
    voiceApply('off', 30503, { 2 }, 1)
    ok(next(pma.muted) ~= nil, 'muted on off, once more')
    forceVoiceMode('squad')
    BR.Loop.step(BR.Loop.TICK)
    ok(pma.muted[2] == nil,
        'and off -> squad releases the SQUADMATE with no event to prompt it',
        'the squad came back from off still muted')
    ok(pma.muted[3] == true,
        'while the non-squadmate stays muted, because that is what squad means',
        'squad released somebody outside the squad')
end

-- ==========================================================================
describe('THE BUS RULE -- nearby cannot transmit from the seat')
do
    -- THE OWNER ASKED FOR THIS BACK: "please add the bus rule back in. we never
    -- agreed to skip it."
    --
    -- IT HAS BEEN TRIED TWICE AND BOTH FAILED ON THE CLOCK, NOT THE RULE.
    -- 58502b0 gagged with MumbleSetActive, which is a Mumble DISCONNECT rather
    -- than a microphone switch, and nothing rebuilt what it tore down -- the
    -- gag lasted the whole match: "while in the same squad and both set to
    -- 'nearby' while standing nearby, players can no longer hear each other."
    -- The variant before it gated inside apply(), which never re-runs on
    -- BUS -> FREEFALL, so it never lifted either.
    local RADIO = 30503
    standAt(0, 0)
    playersAt({ [2] = { x = 2, y = 0 } })

    -- 1. ON THE BUS, ON NEARBY: SILENT. Two metres apart, which is the point --
    --    this is not a range failure, it is a rule.
    local bus = voiceApply('nearby', RADIO, { 2 }, 1, BR.PlayerState.BUS)
    ok(next(bus.sends) == nil,
        'a nearby rider transmits to nobody, standing right next to them')

    -- 2. AND IT LIFTS THE INSTANT THEY LEAVE THE SEAT.
    --
    --    THE ONE ASSERTION THIS ENTIRE ROUND EXISTS FOR. Nothing is fired here
    --    except the state changing and a tick passing: no VOICE_SET, no
    --    settings event, no re-apply, no reconnect. If the gag needs any of
    --    those to lift, this fails -- and on the code this replaces, it did.
    local freefall = beState(BR.PlayerState.FREEFALL)
    ok(freefall.sends[2] == true,
        'and the match can hear them again the moment they are out of the seat',
        'the gag did not lift on BUS -> FREEFALL -- this is the 58502b0 bug')

    -- 3. AND IT COMES BACK if they are somehow put back in a seat, because it
    --    is derived rather than remembered. A latch would pass 2 and fail this.
    local again = beState(BR.PlayerState.BUS)
    ok(next(again.sends) == nil, 'and it re-applies if they are back in the seat')

    -- 4. SQUAD ON THE BUS IS UNAFFECTED. This is the half 58502b0 destroyed:
    --    everybody rides the bus, so everybody was gagged, and the squad went
    --    with them.
    local sqBus = voiceApply('squad', RADIO, { 2 }, 1, BR.PlayerState.BUS)
    ok(sqBus.radio == RADIO,
        'a squad rider keeps the radio on the bus', tostring(sqBus.radio))
    local mate = voiceApply('squad', RADIO, { 1 }, 2, BR.PlayerState.BUS)
    ok(hears(sqBus, mate) and hears(mate, sqBus),
        'and squadmates on the bus hear each other, which is the point of a bus')

    -- 5. LISTENING IS UNAFFECTED, ON EVERY MODE. The gag is transmit-only, and
    --    that is structural: it lives in a function pma-voice consults for its
    --    own voice TARGET and nowhere else.
    standAt(0, 0)
    playersAt({ [2] = { x = 2, y = 0 } })
    local rider = voiceApply('nearby', RADIO, { 2 }, 1, BR.PlayerState.BUS)
    local other = { src = 2, sends = { [1] = true }, muted = {}, radio = 0 }
    ok(hears(other, rider),
        'a gagged rider can still HEAR the person next to them',
        'the bus gag deafened the rider -- it must only take the microphone')
    ok(next(rider.muted) == nil,
        'and the gag holds no mutes -- only off is allowed to mute')

    -- 6. AND IT IS NOT A GLOBAL MUTE MASQUERADING AS A RULE: a nearby player
    --    who is NOT on the bus is unaffected by any of this.
    local alive = voiceApply('nearby', RADIO, { 2 }, 1, BR.PlayerState.ALIVE)
    ok(alive.sends[2] == true, 'and a nearby player on the ground is untouched')
end

describe('the bus rule is derived, not remembered')
do
    -- THE STRUCTURAL PROPERTY, ASSERTED DIRECTLY. Both previous attempts failed
    -- because the gag was a stored decision that something had to come back and
    -- undo. BR.Voice.gagged() is a pure function of the mode and the state, so
    -- there is nothing to undo -- and this asserts that by driving it with
    -- nothing but its two inputs.
    forceVoiceMode('nearby')
    BR.State.me.state = BR.PlayerState.BUS
    local g1 = BR.Voice.gagged()
    BR.State.me.state = BR.PlayerState.FREEFALL
    local g2 = BR.Voice.gagged()
    BR.State.me.state = BR.PlayerState.BUS
    local g3 = BR.Voice.gagged()
    ok(g1 == true and g2 == false and g3 == true,
        'the gag follows the state with no tick, no event and no apply',
        ('%s %s %s'):format(tostring(g1), tostring(g2), tostring(g3)))

    -- SQUAD IS GAGGED EVERYWHERE NOW, AND THAT IS THE POINT RATHER THAN A
    -- REGRESSION. This assertion used to read `== false` with the comment "and
    -- squad is never gagged by the bus", and it was true because squad ALSO
    -- routed proximity -- which is the defect the owner has restated three
    -- times. gagged() answers about the PROXIMITY microphone only; squad does
    -- not have one, so the honest answer is true at every position, on the bus
    -- and off it. What must not change is that the bus does not touch the
    -- RADIO, and the block above asserts that on behaviour rather than here.
    forceVoiceMode('squad')
    BR.State.me.state = BR.PlayerState.BUS
    local sqBusGag, sqBusWhy = BR.Voice.gagged()
    BR.State.me.state = BR.PlayerState.ALIVE
    local sqGroundGag = BR.Voice.gagged()
    ok(sqBusGag == true and sqGroundGag == true,
        'squad has no proximity microphone to gag, on the bus or off it',
        ('bus=%s ground=%s'):format(tostring(sqBusGag), tostring(sqGroundGag)))
    ok(type(sqBusWhy) == 'string' and sqBusWhy:find('bus') == nil,
        'and it does not blame the bus for it -- the reason is the mode',
        tostring(sqBusWhy))

    forceVoiceMode('off')
    BR.State.me.state = BR.PlayerState.ALIVE
    ok(BR.Voice.gagged() == true, 'and off is gagged everywhere')

    -- THE READOUT READS THE SAME FUNCTION, which is why /brvoice cannot drift
    -- from the behaviour the way "prox channel 2003" did for a week.
    forceVoiceMode('nearby')
    BR.State.me.state = BR.PlayerState.BUS
    local _, why = BR.Voice.gagged()
    ok(type(why) == 'string' and why:find('bus') ~= nil,
        'and it explains itself to /brvoice in words', tostring(why))
end

describe('the pma-voice convars are checked from code, not just documented')
do
    -- THE FAILURE THIS BLOCK EXISTS FOR IS NOT A CODE PATH. It is that both of
    -- these convars were "fixed" last round by adding a line to
    -- server.cfg.example -- a file .gitignore keeps off the server and
    -- tools/deploy.sh never copies -- and both symptoms came back the same
    -- week. Nothing in this repository could have caught that, because nothing
    -- in this repository had ever read a convar.
    --
    -- WHY THESE TWO AND NOT ANY OTHER:
    --
    --   voice_disableAutomaticListenerOnCamera  pma-voice's proximity loop
    --     treats a rendering scripted camera as spectating and gives a
    --     spectator a Mumble channel listen on EVERY streamed player, at no
    --     range limit. client/bus.lua renders one. That is where #165's
    --     MUMBLE_ADD_VOICE_CHANNEL_LISTEN warning comes from -- the listens go
    --     out unchecked, one per player, and warn for every channel that is not
    --     there. It is also why it never recovered: the listens are taken over
    --     the warmup bucket's player list and dropped over the match bucket's,
    --     so the difference is held for the rest of the session.
    --
    --   voice_enableUi  the bottom-right "Custom [Range]" overlay.
    --
    -- The default here is an EMPTY convar table -- an unconfigured box, which
    -- is the state the issue was reported from.
    convars = {}

    local probs = BR.Voice.convarProblems()
    local byName = {}
    for _, p in ipairs(probs) do byName[p.name] = p end

    ok(byName['voice_disableAutomaticListenerOnCamera'] ~= nil,
        'an unset camera-listener convar is reported as wrong',
        'the bus camera silently puts every rider into pma-voice spectator '
            .. 'listening and nothing says so')
    ok(byName['voice_enableUi'] ~= nil,
        'and so is an unset voice_enableUi -- the bottom-right overlay')

    -- AND THE RADIO ANIMATION, WHICH IS THE THIRD OF THESE AND THE ONE THAT
    -- NAMES A BOUNDARY RATHER THAN A SYMPTOM.
    --
    -- pma-voice's +radiotalk poses the talker's ped with TaskPlayAnim for as
    -- long as the key is held. That is cosmetic, it is wrong for a shooter --
    -- it re-poses somebody who is aiming, and it advertises to every enemy in
    -- sight that they are on comms -- and turning it off costs no audio.
    --
    -- WHAT MUST NEVER JOIN THIS LIST is voice_enableRadios, or anything that
    -- neutralises the +radiotalk KEY. That key is the only thing that ever
    -- puts a squadmate in the Mumble voice target; suppressing it makes squad
    -- voice silent by construction, which is #157 round seven arriving by a
    -- different door. The distinction is COSTUME versus MECHANISM and this
    -- assertion is where it is written down.
    ok(byName['voice_enableRadioAnim'] ~= nil,
        'and an unset voice_enableRadioAnim -- the hold-a-radio pose',
        'squad voice re-poses the player mid-fight and nothing says so')
    ok(byName['voice_enableRadios'] == nil,
        'but voice_enableRadios is NOT one of ours -- turning the radio module '
            .. 'off would take squad voice with it')

    -- IT IS THE ENGINE'S DEFAULT THAT IS WRONG, not merely "not ours". Asserted
    -- on the numbers so a later round cannot quietly flip which value we want.
    -- Read through a default rather than indexed directly: this block has to
    -- report a MISSING check as two clean failures, not take the rest of the
    -- suite down with a nil index. The two assertions above are the ones that
    -- say it is missing; these two say it is right.
    local none = {}
    local cam = byName['voice_disableAutomaticListenerOnCamera'] or none
    local ui  = byName['voice_enableUi'] or none
    ok(cam.want == 1 and cam.have == 0,
        'and it says what it is and what it must be')
    ok(ui.want == 0 and ui.have == 1,
        'for both of them')

    -- SAID OUT LOUD AT START, once, in the client console -- the same treatment
    -- a missing pma-voice gets, and for the same reason: the previous outage
    -- was invisible for a week.
    logged = {}
    nobodyElse()
    standAt(0, 0)
    voiceApply('nearby', nil, nil, 1)
    local start = table.concat(logged, '\n')
    ok(start:find('voice_disableAutomaticListenerOnCamera') ~= nil,
        'br_core starting says the camera convar is wrong', start)
    ok(start:find('voice_enableUi') ~= nil,
        'and that the overlay convar is wrong', start)

    -- AND IN /brvoice, which is the command a playtester is told to run.
    logged = {}
    pcall(commands['brvoice'])
    local said = table.concat(logged, '\n')
    ok(said:find('convars') ~= nil
        and said:find('voice_disableAutomaticListenerOnCamera') ~= nil,
        'and /brvoice names them too', said)

    -- THE OTHER HALF, AND THE ONE THAT MAKES THIS A TEST RATHER THAN A COUNTER:
    -- a correctly configured box says NOTHING. A check that fires either way
    -- would be noise, and noise in this console is what hid #150.
    convars = {
        voice_disableAutomaticListenerOnCamera = 1,
        voice_enableUi = 0,
        voice_enableRadioAnim = 0,
    }
    ok(#BR.Voice.convarProblems() == 0,
        'a configured box reports no convar problems at all',
        tostring(#BR.Voice.convarProblems()))

    logged = {}
    voiceApply('nearby', nil, nil, 1)
    local quiet = table.concat(logged, '\n')
    ok(quiet:find('voice_enableUi') == nil
        and quiet:find('voice_disableAutomaticListenerOnCamera') == nil,
        'and br_core starting is silent about them', quiet)

    logged = {}
    pcall(commands['brvoice'])
    ok(table.concat(logged, '\n'):find('convars') == nil,
        'and so is /brvoice', table.concat(logged, '\n'))

    -- Left correct for everything after this block: the rest of the suite is
    -- about the rules, not the configuration.
    logged = {}
end

describe('#157 round seven -- silence explains itself, and names the radio key')
do
    -- WHY THIS BLOCK EXISTS, AND WHY IT IS NOT ABOUT ROUTING.
    --
    -- The playtest that opened this round said "squads don't work". Every
    -- routing fact was correct: the server minted a channel, both members of
    -- one squad got the SAME channel, the client asked pma-voice for it and
    -- pma-voice's own addChannelCheck let them on. No audio moved anyway.
    --
    -- pma-voice's RADIO HAS ITS OWN PUSH-TO-TALK. client/module/radio.lua:
    --
    --     RegisterCommand('+radiotalk', ...)          -- adds the voice targets
    --     RegisterKeyMapping('+radiotalk', 'Talk over Radio', 'keyboard',
    --                        GetConvar('voice_defaultRadio', 'LMENU'))
    --
    -- and nothing else ever puts a squadmate in the target. The ordinary voice
    -- key carries PROXIMITY, and squad mode turns proximity off -- so in squad
    -- mode the ordinary key carries nothing at all. Two players pressed the
    -- key the game had taught them and heard silence.
    --
    -- NOTHING IN THIS REPOSITORY CAN PRESS A KEY OR MOVE A FRAME OF AUDIO. What
    -- it can assert is that the player is TOLD -- which is the whole fix, and
    -- the thing whose absence made a working radio indistinguishable from a
    -- broken one for a week. Every surface reads BR.Voice.statusFor, so these
    -- assertions are about the one function all of them derive from.
    --
    -- CALLED THROUGH A SHIM so a build with no status function at all reports
    -- this block as a row of clean failures rather than aborting the suite on
    -- a nil call.
    local statusFor = BR.Voice.statusFor
        or function() return { code = 'MISSING' } end

    -- THE PURE HALF FIRST, every combination, because the interesting rows are
    -- the two that look identical from a chair and are not.
    local nearby = statusFor(BR.VoiceMode.NEARBY, nil, 0)
    ok(nearby.silent == false,
       'nearby is never silent -- it is the mode that always has somebody in it',
       tostring(nearby.code))

    local off = statusFor(BR.VoiceMode.OFF, nil, 0)
    ok(off.silent == true and off.chosen == true,
       "'off' is silent BY REQUEST, and the flag says so -- a player who just "
           .. 'chose it does not need it explained back at them',
       tostring(off.code) .. '/' .. tostring(off.chosen))

    -- AND IT DRAWS NOTHING AT ALL, WHICH IS THIS ROUND'S CHANGE.
    --
    -- This row used to send `headline = 'Voice is off'`, and a headline is a
    -- line across the bottom of the screen for as long as the state lasts
    -- (ui-src/src/hud/VoiceNotice.tsx) -- which for a preference is every match
    -- the player ever plays. Owner, 2026-08-20: "when voice is off, we shouldn't
    -- have anything print in the bottom of the screen saying 'Voice is off' -
    -- just simply say nothing at all. It's off because they turned it off - the
    -- default was Nearby."
    --
    -- NOT A SHORTER STRING, NOT AN ICON, NOTHING. The assertion is `== nil`
    -- rather than a comparison against a quieter sentence for exactly that
    -- reason: an empty string, a dash or a single word would all pass a test
    -- written the other way round and all still put something on the screen.
    ok(off.headline == nil,
       "and 'off' says nothing at all on the HUD -- it is a setting the player "
           .. 'chose, not a fault they need telling about',
       tostring(off.headline))

    -- THE SETTINGS SENTENCE SURVIVES, because that surface is a page somebody
    -- opened on purpose. The owner's instruction is about the bottom of the
    -- screen; deleting the detail with the headline would take away the one
    -- place that says how to turn voice back on.
    ok(type(off.detail) == 'string' and off.detail:find('Settings, Voice') ~= nil,
       'while the settings screen still explains it and names the way out',
       tostring(off.detail))

    -- THE ROW THIS ROUND IS FOR.
    local nosquad = statusFor(BR.VoiceMode.SQUAD, nil, 0)
    ok(nosquad.silent == true and nosquad.chosen == false,
       'squad mode with NO squad is silent and was NOT asked for -- which is '
           .. 'the pair that makes it worth interrupting somebody over',
       tostring(nosquad.code) .. '/' .. tostring(nosquad.chosen))
    ok(type(nosquad.headline) == 'string'
       and nosquad.headline:lower():find('no squad') ~= nil,
       'and it says the words "no squad" rather than describing a channel',
       tostring(nosquad.headline))
    ok(type(nosquad.detail) == 'string'
       and nosquad.detail:find('Nearby') ~= nil,
       'and it names the way OUT -- an explanation with no action is a nicer '
           .. 'way of saying nothing',
       tostring(nosquad.detail))

    -- A GRANTED RADIO IS NOT A WORKING MICROPHONE, and this is the row that
    -- says so. It must NOT be `silent`: audio flows the moment the key is
    -- held, and calling that silence would train the player to ignore the
    -- state that really is.
    local radio = statusFor(BR.VoiceMode.SQUAD, 30703, 3)
    ok(radio.silent == false,
       'a squad with a radio is not silent -- it is a key press away',
       tostring(radio.code))

    -- ...AND IT SAYS NOTHING ON THE HUD, WHICH IS THIS ROUND'S CHANGE.
    --
    -- This used to assert the OPPOSITE -- that the headline told the player to
    -- HOLD something -- and that assertion was right for exactly one round. It
    -- was the only thing telling anybody that squad voice had a key of its own
    -- (Left Alt, pma-voice's). Owner, from the playtest after it shipped:
    -- "don't give me text at the bottom of the screen saying to hold any key
    -- to talk."
    --
    -- A `headline` IS DRAWN ACROSS THE BOTTOM OF THE SCREEN FOR AS LONG AS THE
    -- STATE LASTS (ui-src/src/hud/VoiceNotice.tsx), so on this row -- the
    -- WORKING one -- it was a permanent line saying voice worked. The rule now
    -- matches what that component already claims about itself: a headline means
    -- something is WRONG. The key is named once at the start of a match
    -- instead (BR.Voice.noticeFor), and in Settings, which is where somebody
    -- goes to look.
    ok(radio.headline == nil,
       'and the WORKING row draws no HUD line at all -- a permanent "voice is '
           .. 'fine" banner is furniture, and furniture is not read',
       tostring(radio.headline))

    -- THE DETAIL SURVIVES, because it goes to the settings screen rather than
    -- over the game, and it now names OUR key rather than pma-voice's.
    ok(type(radio.detail) == 'string'
       and radio.detail:find('Settings, Controls') ~= nil,
       'the settings-screen sentence points at OUR rebinder, not at GTA\'s '
           .. 'pause menu under a pma-voice row called "Talk over Radio"',
       tostring(radio.detail))
    ok(radio.detail:find('Talk over Radio') == nil,
       'and no surface names pma-voice\'s own binding any more -- the key is '
           .. 'ours (brptt), so naming theirs would send the player to a row '
           .. 'that no longer does anything',
       tostring(radio.detail))

    -- THE KEY NAME IS OUR KEY LAYER'S, so it follows the player rather than a
    -- convar. This used to read pma-voice's voice_defaultRadio, which was only
    -- ever the DEFAULT -- FiveM exposes no way to read a rebind of a
    -- RegisterKeyMapping back, so every string built from it had to hedge and
    -- the one it named was Left Alt. BR.Keys.labelFor has no such limit for a
    -- binding this layer owns, and the sentence is derived from it rather than
    -- describing it.
    -- ...AND IT NAMES THE COMMAND RATHER THAN THE LETTER, WHICH IS #209 AND IS
    -- STRICTLY STRONGER THAN WHAT THIS USED TO ASSERT.
    --
    -- This read `radio.detail:find(key)` -- the resolved LABEL had to appear in
    -- the sentence. That was the right assertion while the sentence carried a
    -- letter, and the property it was defending is unchanged: the surface must
    -- follow the player's own binding rather than a convar. What changed is
    -- WHEN the binding is read. A substituted label is read once, at compose
    -- time; this paragraph is displayed on the settings screen, which is the
    -- screen the player rebinds the key FROM, so a label baked in here goes
    -- stale under them as they use it. The token is resolved by the page on
    -- every rebind push instead.
    local key = BR.Voice.pttKeyLabel()
    ok(type(key) == 'string',
       'the key layer still reports a push-to-talk label at all -- it is what '
           .. 'decides WHICH sentence is used',
       tostring(key))
    ok(radio.detail:find(BR.KeyToken('brptt'), 1, true) ~= nil,
       'the sentence names the push-to-talk COMMAND, so the glyph the player '
           .. 'sees is resolved when it is drawn rather than when it was '
           .. 'composed',
       tostring(radio.detail))
    -- AND THE LABEL IS NOT ALSO IN IT. The mutation that keeps the assertion
    -- above green and puts the bug back is emitting both -- a token nothing
    -- reads beside the letter that started this issue.
    ok(radio.detail:find('Hold ' .. tostring(key), 1, true) == nil,
       'and the resolved letter appears nowhere in it',
       tostring(key) .. ' / ' .. tostring(radio.detail))

    -- AND THE ROW ITSELF EXISTS, IN OUR TABLE, WITH THE OWNER'S DEFAULT.
    --
    -- THIS IS THE ASSERTION THAT SEPARATES THE FIX FROM THE NEAR-MISS. Setting
    -- `voice_defaultRadio N` would have moved the key a player presses and
    -- passed every other assertion in this block -- and it would still have
    -- been pma-voice's binding, absent from BR.Keys.bindings, absent from our
    -- settings screen, and unmoved for anybody who had already rebound it.
    -- Membership of this table is what "in our key layer" MEANS: it is what
    -- the settings screen lists, what BR.Keys.set can move, and what the raw
    -- layer reads.
    local pttRow = nil
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == 'brptt' then pttRow = b end
    end
    ok(pttRow ~= nil,
       'push-to-talk is a row in OUR key layer -- not pma-voice\'s binding '
           .. 'wearing a new default',
       'no brptt in BR.Keys.bindings')
    ok(pttRow ~= nil and pttRow.default == 'N',
       "and its default is N, which the owner asked for and which is also "
           .. "GTA's own INPUT_PUSH_TO_TALK default",
       pttRow and tostring(pttRow.default) or '-')
    ok(pttRow ~= nil and pttRow.hold == true,
       'and it is a HOLD, because push-to-talk is held',
       pttRow and tostring(pttRow.hold) or '-')

    -- A SQUAD OF ONE gets its own row: the channel exists, nobody else is on
    -- it, and "hold the key" would be advice that produces nothing.
    local alone = statusFor(BR.VoiceMode.SQUAD, 30703, 0)
    ok(alone.code ~= radio.code,
       'a radio with nobody else on it is a different state from a live one',
       tostring(alone.code))

    -- ...AND IT SAYS SO IN THE SQUAD PANEL RATHER THAN ACROSS THE SCREEN.
    --
    -- Owner, 2026-08-22: "'Squad voice: nobody else on your squad radio yet' -
    -- how about instead of showing this text, we show something in the top
    -- squad panel next to each player which shows if they are muted, not
    -- listening, or talking."
    --
    -- THE SENTENCE WAS A CAPTION FOR A PICTURE ALREADY ON THE SCREEN. "Who
    -- else is on your radio" is a list of people, and the squad panel is a
    -- list of people. Three rows have now gone quiet for three different
    -- reasons -- 'radio' because it was furniture, 'off' because it named a
    -- choice, and this one because something else already answers it -- and
    -- what is left is the rule VoiceNotice.tsx states about itself: a headline
    -- means something is WRONG.
    ok(alone.headline == nil,
       'and it no longer paints a line across the bottom of the screen about '
           .. 'it -- the squad panel is the list of who is on the radio, and a '
           .. 'sentence restating a list that is already drawn is a caption',
       tostring(alone.headline))

    -- THE FLAG THE PANEL'S MARK ACTUALLY READS, and it must stay FALSE.
    --
    -- `silent` is not "nobody is talking", it is "nothing can reach this
    -- player and nothing they say can leave" -- and a radio with one person on
    -- it carries the instant a second joins. The squad panel draws its
    -- "no voice" glyph off this field, so a `true` here would mark a working
    -- radio as dead for every player who reaches their squad first.
    ok(alone.silent == false,
       'a radio waiting for its first squadmate is not a silence -- nothing '
           .. 'is refusing anybody, and the panel mark must not say otherwise',
       tostring(alone.silent))

    -- THE SETTINGS SCREEN KEEPS ITS SENTENCE. The owner's instruction is about
    -- the bottom of the screen; `detail` is read on a page somebody opened on
    -- purpose, and it is the only surface that names the channel number and
    -- the key.
    ok(type(alone.detail) == 'string'
       and alone.detail:find('only one on it', 1, true) ~= nil,
       'while the settings screen still explains it in full, because that is a '
           .. 'page the player went looking for',
       tostring(alone.detail))

    -- AND NOTHING IS TOASTED FOR IT EITHER, which is not a separate rule but
    -- the same one: pushVoice toasts `st.headline`, so a row with no headline
    -- interrupts nobody. Asserted through the real push rather than by reading
    -- that condition, because the condition is what a later round would edit.
    do
        local before = #events
        nobodyElse()
        standAt(0, 0)
        voiceApply(BR.VoiceMode.SQUAD, 30703, {}, 1)
        local toast = nil
        for i = #events, before + 1, -1 do
            local e = events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST then
                toast = e.args[2]; break
            end
        end
        ok(toast == nil,
           'and no toast either: a verdict with no headline interrupts nobody, '
               .. 'which is what "instead of showing this text" has to mean',
           toast and tostring(toast.text) or '-')

        -- THE ENVELOPE STILL CARRIES THE ROW. The panel needs `silent` and
        -- `chosen` to decide its mark, and the settings screen needs `status`
        -- and `detail`; deleting the headline must not have taken the push
        -- with it.
        local env = nil
        for i = #events, 1, -1 do
            local e = events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.VOICE then
                env = e.args[2]; break
            end
        end
        ok(type(env) == 'table' and env.status == 'alone'
           and env.silent == false and env.headline == nil,
           'the envelope still reaches the interface with the verdict on it -- '
               .. 'silence on the HUD is not silence on the wire',
           type(env) == 'table'
               and (tostring(env.status) .. '/' .. tostring(env.silent)
                    .. '/' .. tostring(env.headline))
               or 'no voice envelope')
    end

    -- AND NOW THE SURFACES, which is the half that failed. All three derive
    -- from the function above; the point of asserting them separately is that
    -- a surface that stops asking is a surface that goes quietly stale, and
    -- this file has shipped exactly that twice.
    nobodyElse()
    standAt(0, 0)
    voiceApply(BR.VoiceMode.SQUAD, nil, nil, 1)

    -- THE HUD. The envelope the page draws from has to carry the WORDS, not
    -- just a flag -- the page is a separate build, and a boolean it has to
    -- write its own sentence for is a second place for the sentence to be
    -- wrong.
    local env = nil
    for i = #events, 1, -1 do
        local e = events[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.VOICE then
            env = e.args[2]; break
        end
    end
    ok(type(env) == 'table' and env.silent == true,
       'the HUD envelope says this player is silent',
       type(env) == 'table' and tostring(env.silent) or 'no voice envelope')
    ok(type(env) == 'table' and type(env.headline) == 'string'
       and env.headline:lower():find('no squad') ~= nil,
       'and carries the sentence rather than leaving the page to invent one',
       type(env) == 'table' and tostring(env.headline) or '-')

    -- THE TOAST, because a HUD line at the bottom of a screen during a fight
    -- is a line nobody reads. Edge-triggered: it fires when the verdict
    -- CHANGES, which is when it is news.
    local toasted = nil
    for i = #events, 1, -1 do
        local e = events[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST then
            toasted = e.args[2]; break
        end
    end
    ok(type(toasted) == 'table' and type(toasted.text) == 'string'
       and toasted.text:lower():find('no squad') ~= nil,
       'and the player is interrupted once, in words, rather than left to '
           .. 'work silence out for themselves',
       type(toasted) == 'table' and tostring(toasted.text) or 'no toast')

    -- /brvoice, WHICH IS THE COMMAND A PLAYTESTER IS ACTUALLY TOLD TO RUN.
    -- Three separate claims, each ANSWERED rather than left as two numbers to
    -- compare: granted, joined, and whether they agree.
    logged = {}
    pcall(commands['brvoice'])
    local out = table.concat(logged, '\n')
    ok(out:find('radio granted') ~= nil and out:find('radio joined') ~= nil,
       '/brvoice separates "the server gave me one" from "I am on it"', out)
    ok(out:find('verdict') ~= nil and out:upper():find('SILENT') ~= nil,
       'and leads with the verdict rather than making the reader derive it',
       out)

    -- AND WITH A REAL SQUAD, the same command has to name the key -- the fact
    -- whose absence cost the round -- and it has to name OURS. This used to
    -- look for "Talk over Radio", pma-voice's own binding label, and sent the
    -- reader to GTA's pause menu to change it. Both halves moved: the key is
    -- `brptt` in our layer, and the readout says which mechanism it reaches.
    voiceApply(BR.VoiceMode.SQUAD, 30703, { 2, 3 }, 1)
    logged = {}
    pcall(commands['brvoice'])
    local live = table.concat(logged, '\n')
    ok(live:find('talk key') ~= nil and live:find('brptt') ~= nil,
       'and names OUR push-to-talk binding when the radio is the mode', live)
    ok(live:find('+radiotalk') ~= nil,
       'and says what that key actually drives, so a silent squad can be '
           .. 'traced to a mechanism rather than guessed at', live)
    ok(live:find('Talk over Radio') == nil,
       'and never sends the reader to pma-voice\'s own binding again', live)

    -- THE OTHER MODE'S KEY IS THE SAME KEY, AND IT IS PRINTED THERE TOO.
    -- Half a readout is how "the ordinary voice key" became a phrase nobody
    -- could resolve: on nearby, the key drives GTA's INPUT_PUSH_TO_TALK
    -- instead, and a reader who sees no talk-key line at all concludes there
    -- is no key.
    voiceApply(BR.VoiceMode.NEARBY, nil, nil, 1)
    logged = {}
    pcall(commands['brvoice'])
    local prox = table.concat(logged, '\n')
    ok(prox:find('talk key') ~= nil and prox:find('249') ~= nil,
       'and on nearby the same key is named against the control it drives',
       prox)
    ok(live:find('agree') ~= nil,
       'and states outright whether granted and joined are the same channel',
       live)

    -- THE OTHER HALF, AND THE ONE THAT MAKES THIS A TEST: nearby says nothing.
    -- A status line that is always up is a status line nobody reads.
    voiceApply(BR.VoiceMode.NEARBY, nil, nil, 1)
    local quiet = nil
    for i = #events, 1, -1 do
        local e = events[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.VOICE then
            quiet = e.args[2]; break
        end
    end
    ok(type(quiet) == 'table' and quiet.headline == nil
       and quiet.silent == false,
       'nearby carries no status line at all -- there is nothing wrong with it',
       type(quiet) == 'table' and tostring(quiet.headline) or '-')

    -- AND SO DOES 'off', SINCE 2026-08-20, WHICH IS THE SAME RULE FOR THE
    -- OPPOSITE REASON. nearby says nothing because nothing is wrong; 'off' says
    -- nothing because the player did it on purpose. Owner: "when voice is off,
    -- we shouldn't have anything print in the bottom of the screen saying 'Voice
    -- is off' - just simply say nothing at all."
    --
    -- DRIVEN THROUGH voiceApply RATHER THAN statusFor, because the pure function
    -- is asserted above and this is the half that failed in the game: the
    -- ENVELOPE the page draws from, and the edge-triggered toast beside it.
    -- `silent` is still true and still travels -- the settings screen reads it
    -- -- so an assertion on the flag would pass while the line stayed on screen.
    events = {}
    voiceApply(BR.VoiceMode.OFF, nil, nil, 1)
    local silenced, offToast = nil, nil
    for i = #events, 1, -1 do
        local e = events[i]
        if e.name == 'br:ui:sendLocal' then
            if e.args[1] == BR.Nui.VOICE and silenced == nil then
                silenced = e.args[2]
            elseif e.args[1] == BR.Nui.TOAST and offToast == nil then
                offToast = e.args[2]
            end
        end
    end
    ok(type(silenced) == 'table' and silenced.status == 'silenced',
       "turning voice off really does reach the 'silenced' row",
       type(silenced) == 'table' and tostring(silenced.status) or 'no envelope')
    ok(type(silenced) == 'table' and silenced.headline == nil,
       'and the HUD envelope carries no line for it, so nothing is drawn at the '
           .. 'bottom of the screen for as long as the preference lasts',
       type(silenced) == 'table' and tostring(silenced.headline) or '-')
    ok(type(silenced) == 'table' and silenced.silent == true
       and silenced.chosen == true,
       'while the flags still travel -- the settings screen draws this row and '
           .. 'needs to know the silence was asked for',
       type(silenced) == 'table'
           and (tostring(silenced.silent) .. '/' .. tostring(silenced.chosen))
           or '-')
    ok(offToast == nil,
       'and nothing is toasted at the moment they turn it off either',
       offToast and tostring(offToast.text) or 'nothing')

    logged = {}
end

describe('#157 round eight -- push to talk is OUR key, and it drives both modes')
do
    -- WHAT THIS BLOCK CAN AND CANNOT PROVE, STATED FIRST, because this file
    -- has a rule about that and voice is the subject it has cost the most.
    --
    -- IT CANNOT PROVE A MICROPHONE OPENS. Nothing in this repository can run
    -- pma-voice, execute a Mumble native or move a frame of audio, and six
    -- rounds of this issue were lost to reasoning that could not be checked.
    --
    -- WHAT IT PROVES IS THE ROUTING OF THE PRESS: which mechanism our key
    -- reaches, in which mode, and that the release always reaches the one that
    -- can latch. Those are decisions this codebase makes, and every one of
    -- them used to be made by pma-voice on a key we did not own.
    --
    -- THE TWO MECHANISMS ARE DELIBERATELY DIFFERENT AND BOTH ARE ASSERTED:
    --   squad  -> ExecuteCommand('+radiotalk'), which is what puts a squadmate
    --             in the Mumble voice target. Nothing else does.
    --   nearby -> SetControlNormal on control 249, GTA's INPUT_PUSH_TO_TALK,
    --             held every frame. There is no radio on nearby, so the radio
    --             command would do nothing at all.
    local ran, ptt249, groups = {}, 0, {}
    local realExec, realControl = ExecuteCommand, SetControlNormal
    function ExecuteCommand(c) ran[#ran + 1] = tostring(c) end
    -- COUNTED ON GROUP 0 ONLY, and the other two are recorded rather than
    -- counted. pma-voice forces this control over control groups 0, 1 and 2
    -- and we do the same, so a naive count is three times the number of
    -- frames -- which is a fine way to write an assertion that looks like it
    -- passes for the wrong reason.
    function SetControlNormal(group, control, amount)
        if control ~= 249 or amount ~= 1.0 then return end
        groups[group] = true
        if group == 0 then ptt249 = ptt249 + 1 end
    end

    --- The key, through the same path a real press takes: the registered
    --- command, into fire(), into every listener. Not a direct call to the
    --- handler -- that would be a test of a function rather than of a binding.
    local function ptt(down)
        BR.Keys.rawHolds = false
        BR.Keys.uiOwnsKeyboard = false
        local fn = commands[(down and '+' or '-') .. 'brptt']
        if fn then fn() end
    end

    local function heldFrames(n)
        ptt249 = 0
        for _ = 1, n do BR.Loop.step(BR.Loop.FRAME) end
        return ptt249
    end

    ok(commands['+brptt'] ~= nil and commands['-brptt'] ~= nil,
       'the push-to-talk command pair exists, which is what makes it a hold '
           .. 'binding rather than a tap',
       'no +brptt / -brptt')

    -- SQUAD. The press keys the radio up; the release clears it.
    nobodyElse()
    standAt(0, 0)
    voiceApply(BR.VoiceMode.SQUAD, 30703, { 2 }, 1)
    ran = {}
    ptt(true)
    ok(table.concat(ran, ' '):find('+radiotalk', 1, true) ~= nil,
       'a press in SQUAD mode drives pma-voice\'s radio push-to-talk -- the '
           .. 'one thing that ever puts a squadmate in the voice target',
       table.concat(ran, ' '))
    ptt(false)
    ok(table.concat(ran, ' '):find('-radiotalk', 1, true) ~= nil,
       'and the release clears it', table.concat(ran, ' '))

    -- NEARBY. No radio exists, so the radio command must NOT be sent -- and
    -- the key has to open the microphone some other way or 'nearby' has no
    -- push-to-talk at all.
    voiceApply(BR.VoiceMode.NEARBY, nil, nil, 1)
    ran = {}
    ptt(true)
    ok(table.concat(ran, ' '):find('+radiotalk', 1, true) == nil,
       'a press in NEARBY mode does NOT key a radio up -- there is no radio '
           .. 'in this mode and asking for one is how a mode learns about a '
           .. 'channel it must not have',
       table.concat(ran, ' '))
    ok(heldFrames(3) == 3,
       'it holds GTA\'s INPUT_PUSH_TO_TALK instead, on EVERY frame the key is '
           .. 'down -- a control forced once is a control released next frame',
       tostring(ptt249))
    ok(groups[0] and groups[1] and groups[2],
       'over all three control groups, exactly as pma-voice does it -- one '
           .. 'group alone does not reliably open the microphone',
       table.concat({ tostring(groups[0]), tostring(groups[1]),
                      tostring(groups[2]) }, '/'))

    -- THE BUS RULE REACHES THE KEY, AND IT REACHES IT MID-HOLD. This is the
    -- property the whole file is built on: the gag is re-derived per frame, so
    -- a player who boards while holding the key is gagged on the next frame
    -- rather than at the next press.
    BR.State.me.state = BR.PlayerState.BUS
    ok(heldFrames(3) == 0,
       'and boarding the bus stops it MID-HOLD -- the gag is re-asked every '
           .. 'frame, never latched at the press',
       tostring(ptt249))
    BR.State.me.state = BR.PlayerState.ALIVE
    ok(heldFrames(2) == 2,
       'and jumping brings it straight back, with no press in between',
       tostring(ptt249))
    ptt(false)

    -- THE OTHER DIRECTION OF THE SAME PROPERTY, AND IT IS THE ONE A PRESS-TIME
    -- GATE WOULD HAVE BROKEN. A player who is ALREADY on the bus when they
    -- take hold of the key, and who then jumps without letting go, has to
    -- start transmitting -- so the press must record "the key is down" rather
    -- than "the key is allowed", and the gag must live only in the frame loop.
    voiceApply(BR.VoiceMode.NEARBY, nil, nil, 1, BR.PlayerState.BUS)
    ptt(true)
    ok(heldFrames(2) == 0, 'a press taken ON the bus transmits nothing',
       tostring(ptt249))
    BR.State.me.state = BR.PlayerState.FREEFALL
    ok(heldFrames(2) == 2,
       'and jumping while still holding it starts transmitting -- a press '
           .. 'refused at the edge would need the player to let go first, '
           .. 'which nobody would think to do',
       tostring(ptt249))
    ptt(false)
    BR.State.me.state = BR.PlayerState.ALIVE

    -- OFF. Neither mechanism. Note this is belt rather than the enforcement:
    -- even with a microphone wide open, an 'off' player's voice target is
    -- empty and the mute sweep has refused everybody.
    voiceApply(BR.VoiceMode.OFF, nil, nil, 1)
    ran = {}
    ptt(true)
    ok(table.concat(ran, ' '):find('+radiotalk', 1, true) == nil
       and heldFrames(3) == 0,
       "'off' means the key does nothing at all -- neither mechanism",
       table.concat(ran, ' ') .. ' / ' .. tostring(ptt249))

    -- THE RELEASE IS UNCONDITIONAL, AND THIS IS THE ASSERTION THAT MATTERS
    -- MOST. keybinds.lua makes the same argument at its own `-brinteract`: a
    -- mode change, a squad dissolving or a match ending between the press and
    -- the release must not be able to leave `radioPressed` true inside
    -- pma-voice, because nothing else would ever clear it -- an open
    -- microphone to the squad that the player cannot turn off.
    voiceApply(BR.VoiceMode.SQUAD, 30703, { 2 }, 1)
    ptt(true)
    voiceMode(BR.VoiceMode.OFF)          -- the settings screen, mid-hold
    ran = {}
    ptt(false)
    ok(table.concat(ran, ' '):find('-radiotalk', 1, true) ~= nil,
       'a release delivered after the mode changed still clears the radio -- '
           .. 'a release never sent is a microphone latched open',
       table.concat(ran, ' '))

    -- =====================================================================
    -- A SPECTATOR LISTENS AND DOES NOT TALK. Both mechanisms, both edges.
    --
    -- "whoever is the spectator should NEVER be able to talk, only listen" --
    -- the owner, and `NEVER` is what makes this block worth its length. The
    -- rule has to hold on BOTH transmit paths, and the two are reached by
    -- different code: squad goes out over +radiotalk and nearby goes out over
    -- control 249. A gag written into BR.Voice.gagged() alone closes the
    -- second and leaves the first wide open -- which is the worse half, since
    -- the squad radio is exactly who a dead player's squadmates are.
    --
    -- BR.Spectate IS STUBBED because client/spectate.lua is not in loadAll's
    -- list -- it is a camera, and standing one up here would mean stubbing
    -- RenderScriptCams and the shape tests for no assertion's benefit. The
    -- stub is a hazard of its own and the last assertion in this block is
    -- what covers it: BR.Voice.silenced() reaches ACROSS files, so a rename
    -- of the real function would leave the nil-guard answering "not
    -- spectating" forever and every test here would still pass.
    local realSpectate = BR.Spectate
    local spectating = false
    BR.Spectate = { active = function() return spectating end }

    -- SQUAD, WHICH IS THE PATH THAT MATTERS. The press must not key the radio.
    voiceApply(BR.VoiceMode.SQUAD, 30703, { 2 }, 1)
    spectating = true
    ran = {}
    ptt(true)
    ok(table.concat(ran, ' '):find('+radiotalk', 1, true) == nil,
       'a press while spectating does NOT key the squad radio up -- the one '
           .. 'path that reaches the dead player\'s own squad',
       table.concat(ran, ' '))
    ptt(false)

    -- NEARBY, THE OTHER MECHANISM, ASSERTED SEPARATELY rather than assumed
    -- from the one above. They are different code and have failed apart.
    voiceApply(BR.VoiceMode.NEARBY, nil, nil, 1)
    ptt(true)
    ok(heldFrames(3) == 0,
       'and it does not open the proximity microphone either -- both '
           .. 'mechanisms, not whichever one the mode happens to use',
       tostring(ptt249))
    ptt(false)

    -- THE EDGE THAT ACTUALLY HAPPENS: dying mid-sentence. The press was taken
    -- while alive and entitled, the radio IS open, and then the session
    -- starts. A rule checked only at the press would leave that microphone
    -- open for the rest of the round.
    voiceApply(BR.VoiceMode.SQUAD, 30703, { 2 }, 1)
    spectating = false
    ptt(true)
    ran = {}
    spectating = true
    BR.Loop.step(BR.Loop.FRAME)
    ok(table.concat(ran, ' '):find('-radiotalk', 1, true) ~= nil,
       'a radio already keyed up when the session STARTS is closed mid-hold -- '
           .. 'dying with the key down is the ordinary way into spectating, '
           .. 'and a press-time gate would never see it',
       table.concat(ran, ' '))

    -- ONCE, NOT EVERY FRAME. The close is an edge; spending an ExecuteCommand
    -- per frame for as long as a dead player holds a key is a real cost at 48
    -- players, and it is the obvious way to write this wrong.
    ran = {}
    BR.Loop.step(BR.Loop.FRAME)
    BR.Loop.step(BR.Loop.FRAME)
    ok(#ran == 0, 'and it is closed ONCE, not re-closed every frame',
       table.concat(ran, ' '))
    ptt(false)

    -- AND IT LIFTS. A gag that cannot be given back is how a player who
    -- stopped spectating spends the next round silent with nothing on screen
    -- to explain it. Re-derived, never latched -- the same property the bus
    -- rule is built on.
    spectating = false
    voiceApply(BR.VoiceMode.NEARBY, nil, nil, 1)
    ptt(true)
    ok(heldFrames(2) == 2,
       'and stopping the session brings the microphone straight back, with no '
           .. 'press in between',
       tostring(ptt249))
    ptt(false)

    -- THE MASTER SWITCH IS ALSO THE PROXIMITY GAG, so /brvoice cannot report a
    -- microphone the checks are refusing.
    spectating = true
    local sg, sw = BR.Voice.gagged()
    ok(sg == true and type(sw) == 'string' and sw:find('spectat') ~= nil,
       'gagged() answers for it too, in words, so the readout cannot drift '
           .. 'from the behaviour',
       tostring(sw))
    spectating = false

    -- THE CROSS-FILE CALL, ASSERTED ON THE REAL SOURCE.
    --
    -- BR.Voice.silenced() reads BR.Spectate.active() out of another file
    -- behind a nil-guard, and the guard is not optional -- voice.lua loads
    -- with or without a camera. But it means a RENAME on the other side fails
    -- open and silently: silenced() would answer false forever, a spectator
    -- would talk, and every assertion above would still pass against the stub.
    -- So the name is pinned against the file that owns it.
    local specFh = io.open(ROOT .. 'br_core/client/spectate.lua', 'r')
    local specSrc = specFh and specFh:read('a') or nil
    if specFh then specFh:close() end
    ok(type(specSrc) == 'string'
       and specSrc:find('function BR.Spectate.active', 1, true) ~= nil,
       'and client/spectate.lua really defines BR.Spectate.active -- the stub '
           .. 'above would otherwise be the only thing that does',
       'BR.Spectate.active is not defined where voice.lua reaches for it')

    BR.Spectate = realSpectate

    -- AND THE KEY IS LEFT UP, so nothing after this block inherits a hold.
    ok(heldFrames(2) == 0, 'and the key layer is left with nothing held',
       tostring(ptt249))

    ExecuteCommand, SetControlNormal = realExec, realControl
end

describe('voice is OFF while spectating, and the preference comes back by itself')
do
    -- THE OWNER, 2026-08-21: "On voice -- let's set voice to OFF while in
    -- spectate, and return it to their preferred setting once spectate is
    -- over."
    --
    -- ═══ WHAT THIS IS NOT, AND WHY THE BLOCK ABOVE DOES NOT COVER IT ═══
    --
    -- It is not the spectator mute. That shipped already and it is the
    -- TRANSMIT half only -- MumbleSetPlayerMuted on the server, and
    -- BR.Voice.silenced() over both push-to-talk mechanisms on the client. Its
    -- own comments are explicit about where it stops: "MUTED IS NOT DEAFENED",
    -- the radio channel and the mute sweep are left alone. So a spectator on
    -- 'nearby' went on hearing every stranger standing near whoever they were
    -- watching, and a spectator on 'squad' went on sitting on the squad radio.
    --
    -- 'off' IN THIS PROJECT HAS ALWAYS MEANT BOTH HALVES, and that is the
    -- owner's own ruling, made against a build that only did the first:
    --
    --   "'you are not transmitting' should also mean 'you are not listening',
    --    but alas both are false."
    --
    -- So the assertions below lean hardest on the RECEIVE half -- who is
    -- audible, who is muted, and which radio channel this client is on. Those
    -- are the facts that moved. The whole suite above this block passes either
    -- way, which is the point of writing them down.
    --
    -- ═══ EVERY RESTORE HERE IS DRIVEN BY THE CLOCK AND NOTHING ELSE ═══
    --
    -- The "and it comes back" cases end a session and then step the TICK BAND
    -- ONLY. No settings event, no VOICE_SET, no state broadcast -- nothing a
    -- real client is merely usually given. That is the property under test:
    -- the restore is arithmetic over a mode that is re-derived on every call,
    -- not an action an exit path has to remember. There are five ways out of a
    -- session -- the pause-menu stop, the match ending, the player leaving,
    -- disconnecting, and br_core restarting -- and a design where each one
    -- calls something is a design where one of them eventually does not.
    -- A player left voiceless for the rest of a round is a worse bug than the
    -- one being fixed, and this repo has shipped that exact shape before.

    local realSpectate = BR.Spectate
    local spectating = false
    BR.Spectate = { active = function() return spectating end }

    --- One 10 Hz band tick and one pma-voice proximity tick, frozen. THE ONLY
    --- THING ANY RESTORE BELOW IS ALLOWED TO BE GIVEN.
    local function settle()
        BR.Loop.step(BR.Loop.TICK)
        pmaTick()
        return pmaSnapshot()
    end

    -- A SQUAD MATCH, BECAUSE IT IS THE ONLY KIND WHERE ALL THREE MODES ARE
    -- REACHABLE and the only one with a radio channel to be evicted from and
    -- put back on. Player 2 is a squadmate, player 3 is a stranger on the
    -- roster -- so 'squad' has somebody to refuse and somebody to keep, and
    -- "everyone is muted" is distinguishable from "the usual one is muted".
    voiceApply(BR.VoiceMode.SQUAD, 30703, { 2 }, 1)
    playersAt({ [2] = { x = 1, y = 0 }, [3] = { x = 2, y = 0 } })
    -- AND THE SQUADMATE IS MID-SENTENCE, which is what makes the "and nobody
    -- is talking while spectating" assertion below mean anything. Left silent
    -- it would pass on a client that had simply never named anybody.
    mumble.talking[2] = true
    local alive = settle()

    ok(#talkingNames() == 1 and talkingNames()[1] == 'p2',
       'before any session: a squadmate speaking on the radio IS named, so the '
           .. 'panel has a talking mark to lose',
       table.concat(talkingNames(), ', '))

    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD and alive.radio == 30703,
       'before any session: the player is on their squad preference and on the '
           .. 'channel the server granted',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(alive.radio))
    ok(alive.muted[3] == true and alive.muted[2] == nil,
       'and squad refuses the stranger while keeping the squadmate -- the '
           .. 'state the session has to be visible against',
       'muted 2=' .. tostring(alive.muted[2]) .. ' 3=' .. tostring(alive.muted[3]))

    -- ==================================================================== --
    -- THE SESSION STARTS.

    spectating = true
    local spec = settle()

    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       "the mode in force goes to 'off' for the length of the session -- the "
           .. 'setting, which is what the owner asked to be set',
       tostring(BR.Voice.mode()))

    local r = BR.Voice.routing()
    ok(r.proximity == false and r.radio == false,
       'and it is the real mode, both columns of the routing table, rather '
           .. 'than a fourth mode invented for spectators',
       tostring(r.proximity) .. '/' .. tostring(r.radio))

    -- THE HALF THAT IS ACTUALLY NEW. The suite above would pass with the
    -- receive side untouched, because the microphone was already taken.
    local audible = BR.Voice.audibleFor(BR.Voice.mode(), BR.State.roster,
                                        BR.Voice.state.mates, 1)
    ok(next(audible) == nil,
       'a spectator is audible-to nobody: the receive half moves too, which is '
           .. 'the whole difference between this and the microphone rule that '
           .. 'shipped before it',
       'audible set is not empty')

    ok(spec.muted[2] == true and spec.muted[3] == true,
       'so the sweep holds a mute on the squadmate as well as the stranger -- '
           .. 'squad radio included, which is the one channel the old rule '
           .. 'deliberately left open',
       'muted 2=' .. tostring(spec.muted[2]) .. ' 3=' .. tostring(spec.muted[3]))

    ok(spec.radio == 0,
       'and this client leaves the squad radio channel, because that is what '
           .. "'off' does -- not because anything told it to spectate",
       tostring(spec.radio))

    -- THE TRANSMIT HALF IS UNCHANGED AND IS STILL ITS OWN RULE. Two
    -- independent reasons a spectator cannot talk is the property the owner's
    -- `NEVER` asked for; a mutant that deleted silenced() on the grounds that
    -- the mode now covers it would be strictly weaker and would open a
    -- microphone for the 100ms the band takes to notice.
    ok(BR.Voice.silenced() == true,
       'the master transmit switch still answers for itself, independently of '
           .. 'the mode -- it is read at the keypress and every frame, where '
           .. 'the mode is read on a 10 Hz band',
       tostring(BR.Voice.silenced()))

    -- NO UI TEXT. The owner did not ask to be told about this and must not be.
    local st = BR.Voice.status()
    ok(st.headline == nil,
       'and nothing is painted over the game to announce it -- no headline, so '
           .. 'no toast and no notice',
       tostring(st.headline))

    -- ═══ WHAT A SPECTATOR'S SQUAD PANEL DRAWS, WHICH IS NOW A QUESTION ═══
    --
    -- Since 2026-08-22 the squad panel marks each row with the state of that
    -- player's voice link (ui-src/src/hud/VoiceMark.tsx). A spectator is on
    -- 'off' for the length of the session, so this is the one envelope that
    -- decides what a dead player watching their squad sees -- and the two
    -- flags below are the whole of the input.
    --
    -- CHOSEN, NOT A FAULT. The panel paints an unasked-for silence in
    -- --color-danger and an asked-for one in the dim text colour, which is the
    -- same rule VoiceNotice has always used for its headline. A spectator's
    -- silence is not a malfunction and must not be drawn as one -- and 'off'
    -- is how the rule is expressed here rather than a fourth mode invented for
    -- spectators, so `chosen` comes out true without anything knowing why.
    ok(st.silent == true and st.chosen == true,
       'a spectator\'s own row is marked as having no voice at all, and marked '
           .. 'as a CHOSEN silence rather than a fault -- the same distinction '
           .. 'the headline rule has always made',
       tostring(st.silent) .. '/' .. tostring(st.chosen))

    -- AND THE MATES' ROWS CARRY NOTHING, because there is nothing to carry: a
    -- spectator is audible-to nobody, so the talking list this panel reads is
    -- empty by construction rather than by a rule about spectating. THE
    -- INDICATOR IS DRIVEN FROM THE SAME SET THE MUTE SWEEP USES -- asserted
    -- through the push rather than off BR.Voice.talking, because the push is
    -- what reaches the panel.
    ok(#talkingNames() == 0,
       'and the squadmate who was mid-sentence a tick ago is no longer named: '
           .. 'the panel says nobody is talking, which is what a spectator can '
           .. 'hear. Nothing about spectating is taught to the indicator -- the '
           .. 'audible set went empty and it fell out',
       table.concat(talkingNames(), ', '))

    -- THE PREFERENCE IS NOT TOUCHED. This single assertion is what makes the
    -- disconnect case, the crash case and the resource-restart case safe: a
    -- session that ends by this client simply ceasing to exist leaves nothing
    -- behind to be put back, because nothing was ever taken.
    ok(BR.Voice.pref.squad == BR.VoiceMode.SQUAD,
       'while the SAVED preference is not written at all -- there is no stored '
           .. 'mode to be stranded by a disconnect, a crash or a restart',
       tostring(BR.Voice.pref.squad))

    -- ==================================================================== --
    -- AND THE SESSION ENDS, WITH NOTHING BUT A TICK.

    spectating = false
    local back = settle()

    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD,
       'stopping restores the PREFERENCE, not the default -- and nothing was '
           .. "fired to make it happen; 'squad' is not BR.VoiceModeDefault, so "
           .. 'a restore that fell back could not pass this',
       tostring(BR.Voice.mode()))
    ok(back.radio == 30703,
       'the squad radio channel is rejoined on the same tick, with no event of '
           .. 'any kind in between -- this is the assertion that a forgotten '
           .. 'exit path fails',
       tostring(back.radio))
    ok(back.muted[2] == nil and back.muted[3] == true,
       'and the ears come back exactly as they were: the squadmate released, '
           .. 'the stranger still refused',
       'muted 2=' .. tostring(back.muted[2]) .. ' 3=' .. tostring(back.muted[3]))
    ok(BR.Voice.silenced() == false,
       'and the microphone is given back with it',
       tostring(BR.Voice.silenced()))

    -- ==================================================================== --
    -- THE MATCH ENDS UNDERNEATH THE SPECTATOR.
    --
    -- THIS IS THE CASE THAT SEPARATES THE TWO POSSIBLE DESIGNS, and it is the
    -- reason the implementation is an overlay rather than a saved value. A
    -- dead player spectates their squad; the match ends while they are
    -- watching; the session stops in the lobby. An implementation that
    -- SNAPSHOT the mode at session start and put it back would put back
    -- 'squad' -- the squad-match answer -- for a player who is now in no match
    -- at all. Re-deriving gets the lobby's answer, which is the SOLO slot.
    --
    -- The two slots are set to DIFFERENT values here on purpose; it is the
    -- only way to see which one won.
    fire('br:settings:changed',
         { voiceModeSolo = BR.VoiceMode.OFF, voiceModeSquad = BR.VoiceMode.SQUAD })
    BR.State.match.mode = BR.Mode.SQUAD.key
    settle()
    spectating = true
    settle()
    -- the match ends: no match kind any more, and the session stops
    BR.State.match.mode = nil
    spectating = false
    settle()
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'a session that outlives its match comes back to the preference for the '
           .. 'match the player is in NOW -- the solo slot, not a snapshot of '
           .. 'the squad answer taken when the camera went up',
       tostring(BR.Voice.mode()))

    -- ==================================================================== --
    -- THE PREFERENCE IS CHANGED DURING THE SESSION.
    --
    -- The settings screen is reachable from the pause menu and the pause menu
    -- opens over the spectate camera. "Their preferred setting" is whatever
    -- they last chose, so the value that comes back is the NEW one -- and
    -- 'squad' is neither BR.VoiceModeDefault nor the value in force before the
    -- session, so nothing but the real preference can satisfy this.
    BR.State.match.mode = BR.Mode.SQUAD.key
    fire('br:settings:changed',
         { voiceModeSolo = BR.VoiceMode.NEARBY, voiceModeSquad = BR.VoiceMode.NEARBY })
    settle()
    spectating = true
    local mid = settle()
    ok(BR.Voice.mode() == BR.VoiceMode.OFF and mid.radio == 0,
       'a session over a nearby preference is off and off the radio too',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(mid.radio))

    voiceMode(BR.VoiceMode.SQUAD)   -- the settings screen, mid-session
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'changing the preference mid-session does not lift the session -- the '
           .. 'camera is still up, so voice is still off',
       tostring(BR.Voice.mode()))

    spectating = false
    local changed = settle()
    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD and changed.radio == 30703,
       'and what comes back is the setting they chose WHILE watching, not the '
           .. 'one they had when the camera went up',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(changed.radio))

    -- ==================================================================== --
    -- TWICE IN A ROW.
    --
    -- Two sessions in one round is the ordinary case, not an edge: a dead
    -- player steps between squadmates, and every step the SERVER treats as a
    -- re-resolve. A latch that is taken on the first start and released on the
    -- first stop is right once and wrong forever after.
    spectating = true;  settle()
    spectating = false; local one = settle()
    spectating = true;  settle()
    spectating = false; local two = settle()
    ok(one.radio == 30703 and two.radio == 30703
       and BR.Voice.mode() == BR.VoiceMode.SQUAD,
       'two sessions back to back both restore -- nothing is spent on the '
           .. 'first one',
       tostring(one.radio) .. ' then ' .. tostring(two.radio))

    -- ==================================================================== --
    -- pma-voice RESTARTS UNDER THE SESSION.
    --
    -- An admin restarting the voice resource mid-match is a real thing that
    -- happens, and br_core's handler for it drops everything it believes about
    -- the engine (`joined`, `muted`). The session is still running, so the
    -- answer must still be off -- and stopping must still put the channel back
    -- on a resource that has never heard of it.
    spectating = true
    settle()
    fire('onClientResourceStart', 'pma-voice')
    local restarted = settle()
    ok(restarted.radio == 0,
       'a voice resource that restarts under a spectator comes back off the '
           .. 'radio, because the mode is re-derived rather than replayed',
       tostring(restarted.radio))
    spectating = false
    local afterRestart = settle()
    ok(afterRestart.radio == 30703,
       'and the channel is put back afterwards all the same',
       tostring(afterRestart.radio))

    -- ==================================================================== --
    -- THE CROSS-FILE CALL, PINNED ON THE REAL SOURCE.
    --
    -- BR.Voice.mode() reads BR.Spectate.active() behind a nil-guard -- it has
    -- to, because client/voice.lua loads with or without the camera. That
    -- guard means a RENAME on the other side fails OPEN AND IN SILENCE: mode()
    -- would answer with the preference forever, a spectator would hear the
    -- whole match, and every assertion in this block would still pass against
    -- the stub above. So the name is checked against the file that owns it.
    -- (The mute block above pins the same name for the same reason; it is
    -- repeated here because these are two independent readers and either could
    -- be the one left behind.)
    local sFh = io.open(ROOT .. 'br_core/client/spectate.lua', 'r')
    local sSrc = sFh and sFh:read('a') or nil
    if sFh then sFh:close() end
    ok(type(sSrc) == 'string'
       and sSrc:find('function BR.Spectate.active', 1, true) ~= nil,
       'and BR.Spectate.active really is the name client/spectate.lua defines '
           .. '-- the nil-guard in mode() would hide a rename completely',
       'BR.Spectate.active is not defined where voice.lua reaches for it')

    BR.Spectate = realSpectate
    spectating = false
    -- AND THE SQUADMATE STOPS TALKING, so the microphone this block opened does
    -- not follow the suite into every block after it.
    mumble.talking[2] = nil
    nobodyElse()
end

describe('there is zero voice in the lobby, in both directions, and it all comes back')
do
    -- THE OWNER, 2026-08-22: "the lobby should not allow talking or listening.
    -- period. zero voice in lobby."
    --
    -- ═══ `period` IS DOING WORK IN THAT SENTENCE ═══
    --
    -- BOTH HALVES. Not muted-but-hearing, which is what the spectator rule was
    -- before the owner widened it with "'you are not transmitting' should also
    -- mean 'you are not listening', but alas both are false." And not a
    -- proximity gag like the bus rule, which is deliberately narrow -- a squad
    -- on the bus KEEPS its radio -- and would have left the lobby's radio wide
    -- open. So the assertions below lean on the receive half and on the radio
    -- channel, exactly as the spectate block above does, because those are the
    -- facts a half-done version gets wrong.
    --
    -- ═══ AND EVERY RESTORE IS DRIVEN BY THE CLOCK AND NOTHING ELSE ═══
    --
    -- Same discipline as the block above, and it matters MORE here: the lobby
    -- is reachable from more directions than any other state in this game --
    -- connecting, a match ending, a match destroyed underneath you, brforce,
    -- a party dissolving, dying and being returned. Every "and it comes back"
    -- case below moves the state and steps the TICK BAND ONLY. No settings
    -- event, no VOICE_SET, no STATE broadcast. A player left permanently
    -- voiceless by a visit to the lobby is a far worse bug than the one being
    -- fixed, and a saved-mode-and-restore-it design is how this repository
    -- would get there.

    local function settle()
        BR.Loop.step(BR.Loop.TICK)
        pmaTick()
        return pmaSnapshot()
    end

    -- A SQUAD MATCH WITH A REAL CHANNEL AND A REAL STRANGER, for the same
    -- reasons the spectate block gives: it is the only kind where all three
    -- modes are reachable, the only one with a radio to be evicted from, and
    -- the only one where "everybody is muted" is distinguishable from "the
    -- usual one is muted".
    voiceApply(BR.VoiceMode.SQUAD, 41207, { 2 }, 1)
    playersAt({ [2] = { x = 1, y = 0 }, [3] = { x = 2, y = 0 } })
    mumble.talking[2] = true
    local alive = settle()

    -- THE SAVED PAIR AS IT STANDS BEFORE ANY OF THIS, captured rather than
    -- restated. The two slots do NOT both read 'squad' even though voiceApply
    -- asked for it -- BR.ToSoloVoiceMode coerces 'squad' out of the solo slot on
    -- the way in, because a squad radio in a solo match is silence with extra
    -- steps. Writing the expected values by hand here would encode that
    -- coercion a second time and go stale the day it changes; what this block
    -- is actually about is that the pair does not MOVE.
    local prefBefore = { solo = BR.Voice.pref.solo, squad = BR.Voice.pref.squad }

    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD and alive.radio == 41207,
       'in a match: the player is on their squad preference and on the channel '
           .. 'the server granted',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(alive.radio))
    ok(alive.muted[2] == nil and alive.muted[3] == true,
       'and squad keeps the squadmate while refusing the stranger -- the state '
           .. 'the lobby has to be visible against',
       'muted 2=' .. tostring(alive.muted[2]) .. ' 3=' .. tostring(alive.muted[3]))
    ok(#talkingNames() == 1,
       'and the squadmate mid-sentence IS named, so there is a talking mark to '
           .. 'lose', table.concat(talkingNames(), ', '))

    -- ==================================================================== --
    -- INTO THE LOBBY.

    local lob = beState(BR.PlayerState.LOBBY)

    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       "the mode in force goes to 'off' the moment the player is in the lobby",
       tostring(BR.Voice.mode()))

    local r = BR.Voice.routing()
    ok(r.proximity == false and r.radio == false,
       'and it is the REAL mode, both columns of the routing table, rather than '
           .. 'a fourth mode invented for the lobby -- which is what makes the '
           .. 'receive half free',
       tostring(r.proximity) .. '/' .. tostring(r.radio))

    -- LISTENING. The half a transmit-only fix would leave broken, and the half
    -- the owner's "period" is about.
    local audible = BR.Voice.audibleFor(BR.Voice.mode(), BR.State.roster,
                                        BR.Voice.state.mates, 1)
    ok(next(audible) == nil,
       'a player in the lobby is audible-to nobody: the LISTEN half moves too',
       'audible set is not empty')
    ok(lob.muted[2] == true and lob.muted[3] == true,
       'so the sweep holds a mute on the squadmate as well as the stranger -- '
           .. 'the squad radio included, which a bus-shaped gag would have left '
           .. 'open',
       'muted 2=' .. tostring(lob.muted[2]) .. ' 3=' .. tostring(lob.muted[3]))
    ok(lob.radio == 0,
       'and this client leaves the squad radio channel entirely',
       tostring(lob.radio))
    ok(#talkingNames() == 0,
       'and the squadmate who was mid-sentence a tick ago is no longer named -- '
           .. 'nothing about the lobby was taught to the indicator, the audible '
           .. 'set went empty and it fell out',
       table.concat(talkingNames(), ', '))

    -- TALKING. Two independent reasons, which is what "period" asked for: the
    -- mode covers it on the 10 Hz band, and silenced() covers it at the
    -- keypress and on every FRAME. A match ending while a player holds
    -- push-to-talk is the ordinary way in, and 100ms of open microphone is a
    -- word.
    local sil, why = BR.Voice.silenced()
    ok(sil == true,
       'the master transmit switch answers for itself, independently of the '
           .. 'mode -- it is read at the keypress and every frame, where the '
           .. 'mode is read on a 10 Hz band',
       tostring(sil))
    ok(type(why) == 'string' and why:find('lobby', 1, true) ~= nil,
       'and it gives the LOBBY as the reason rather than "the player chose '
           .. "'off'\" -- /brvoice reports the cause, not the mechanism",
       tostring(why))

    -- NO UI TEXT. The owner did not ask to be told about this and must not be.
    local st = BR.Voice.status()
    ok(st.headline == nil,
       'and nothing is painted over the game to announce it -- no headline, so '
           .. 'no toast and no notice',
       tostring(st.headline))
    ok(st.silent == true and st.chosen == true,
       'the row is marked silent AND chosen, so the squad panel draws it in the '
           .. 'dim colour rather than as a fault -- the same distinction a '
           .. "spectator's row gets",
       tostring(st.silent) .. '/' .. tostring(st.chosen))

    -- THE PREFERENCE IS NOT TOUCHED. This one assertion is what makes the
    -- disconnect, the crash and the resource-restart cases safe: a lobby visit
    -- that ends by this client ceasing to exist leaves nothing behind to put
    -- back, because nothing was taken.
    ok(BR.Voice.pref.solo == prefBefore.solo
       and BR.Voice.pref.squad == prefBefore.squad
       and BR.Voice.pref.squad == BR.VoiceMode.SQUAD,
       'while the SAVED pair is byte-for-byte what it was before the lobby -- '
           .. 'there is no stored mode to be stranded by a disconnect, a crash '
           .. 'or a restart, because nothing was taken',
       tostring(BR.Voice.pref.solo) .. '/' .. tostring(BR.Voice.pref.squad)
           .. ' was ' .. tostring(prefBefore.solo) .. '/'
           .. tostring(prefBefore.squad))

    -- ==================================================================== --
    -- RESTORE 1: THE MATCH STARTS. The ordinary path, and nothing but a tick.

    local back = beState(BR.PlayerState.WARMUP)
    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD,
       'leaving the lobby restores the PREFERENCE, not the default -- and '
           .. "nothing was fired to make it happen. 'squad' is not "
           .. 'BR.VoiceModeDefault, so a restore that fell back could not pass '
           .. 'this', tostring(BR.Voice.mode()))
    ok(back.radio == 41207,
       'the squad radio channel is rejoined on the same tick, with no event of '
           .. 'any kind in between -- this is the assertion a forgotten exit '
           .. 'path fails', tostring(back.radio))
    ok(back.muted[2] == nil and back.muted[3] == true,
       'and the ears come back exactly as they were: the squadmate released, '
           .. 'the stranger still refused',
       'muted 2=' .. tostring(back.muted[2]) .. ' 3=' .. tostring(back.muted[3]))
    ok(BR.Voice.silenced() == false,
       'and the microphone is given back with it',
       tostring(BR.Voice.silenced()))

    -- ==================================================================== --
    -- WARMUP IS NOT THE LOBBY, AND THAT IS A DECISION RATHER THAN A GAP.
    --
    -- The state above is WARMUP and voice is fully back, which pins it. Warmup
    -- is INSIDE a match: squads are formed, the radio channel exists, and
    -- players are shooting each other on the pad. The owner's word was "the
    -- lobby", and lobbycam.lua, locker.lua and spawn.lua all draw the line at
    -- exactly BR.PlayerState.LOBBY. A rule that swallowed warmup would silence
    -- the one moment in a round when a squad is actually planning.
    ok(BR.Voice.routing().radio == true,
       'a player on the warmup pad has their squad radio -- the rule is the '
           .. 'lobby, not "anything before the bus"',
       tostring(BR.Voice.mode()))

    -- ==================================================================== --
    -- RESTORE 2: TWICE IN A ROW.
    --
    -- Not an edge. A player who plays two rounds passes through the lobby twice,
    -- and a latch taken on the first entry and released on the first exit is
    -- right once and wrong forever after.
    beState(BR.PlayerState.LOBBY)
    local one = beState(BR.PlayerState.ALIVE)
    beState(BR.PlayerState.LOBBY)
    local two = beState(BR.PlayerState.ALIVE)
    ok(one.radio == 41207 and two.radio == 41207
       and BR.Voice.mode() == BR.VoiceMode.SQUAD,
       'two lobby visits back to back both restore -- nothing is spent on the '
           .. 'first one',
       tostring(one.radio) .. ' then ' .. tostring(two.radio))

    -- ==================================================================== --
    -- RESTORE 3: pma-voice RESTARTS WHILE THE PLAYER IS IN THE LOBBY.
    --
    -- An admin restarting the voice resource between rounds is a real thing
    -- that happens, and br_core's handler drops everything it believes about the
    -- engine (`joined`, `muted`). The answer must still be off while in the
    -- lobby -- and leaving must still put the channel back on a resource that
    -- has never heard of it.
    beState(BR.PlayerState.LOBBY)
    fire('onClientResourceStart', 'pma-voice')
    local restarted = settle()
    ok(restarted.radio == 0,
       'a voice resource that restarts under a lobby player comes back off the '
           .. 'radio, because the mode is re-derived rather than replayed',
       tostring(restarted.radio))
    local afterRestart = beState(BR.PlayerState.ALIVE)
    ok(afterRestart.radio == 41207,
       'and the channel is put back afterwards all the same',
       tostring(afterRestart.radio))

    -- ==================================================================== --
    -- RESTORE 4: br_core ITSELF RESTARTS UNDER THE LOBBY.
    --
    -- The other half of the same admin action, and the one a saved-value design
    -- loses outright: a stored "what they were on before the lobby" lives in Lua
    -- state, and a resource reload is exactly what throws Lua state away. There
    -- is nothing to lose here because nothing is stored -- the preferences are
    -- pushed back by br_ui and the mode is arithmetic over them.
    beState(BR.PlayerState.LOBBY)
    fire('onClientResourceStart', 'br_core')
    BR.State.me.src = 1     -- main.lua's own handler re-reads it; see voiceApply
    settle()
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'br_core restarting under a lobby player leaves them off, because the '
           .. 'lobby is read from the state mirror rather than remembered',
       tostring(BR.Voice.mode()))
    fire('br:settings:changed',
         { voiceModeSolo = BR.VoiceMode.NEARBY, voiceModeSquad = BR.VoiceMode.SQUAD })
    fire(BR.Net.VOICE_SET, { radio = 41207, mates = { 2 },
                             nearbyRange = VR.nearby })
    local afterCore = beState(BR.PlayerState.ALIVE)
    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD and afterCore.radio == 41207,
       'and the preference the settings screen pushes back is what they leave '
           .. 'the lobby on',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(afterCore.radio))

    -- ==================================================================== --
    -- RESTORE 5: THE PREFERENCE IS CHANGED WHILE IN THE LOBBY.
    --
    -- The settings screen is reachable from the lobby menu, which makes this the
    -- ordinary case rather than an edge. What comes back is what they last
    -- chose -- and it must not be overridden by a snapshot taken on the way in.
    beState(BR.PlayerState.LOBBY)
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'in the lobby again, off again', tostring(BR.Voice.mode()))
    voiceMode(BR.VoiceMode.NEARBY)      -- the settings screen, mid-lobby
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'changing the preference in the lobby does not lift the rule -- they are '
           .. 'still in the lobby, so there is still no voice',
       tostring(BR.Voice.mode()))
    local changed = beState(BR.PlayerState.ALIVE)
    ok(BR.Voice.mode() == BR.VoiceMode.NEARBY and changed.radio == 0,
       'and what comes back is the setting they chose WHILE in the lobby, not '
           .. 'the one they had when they entered it',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(changed.radio))

    -- ==================================================================== --
    -- RESTORE 6: THE MATCH KIND CHANGES WHILE THEY SIT IN THE LOBBY.
    --
    -- THE CASE THAT SEPARATES THE TWO POSSIBLE DESIGNS, and the reason this is
    -- an overlay rather than a saved value. A player finishes a SQUAD match,
    -- lands in the lobby, and queues a SOLO. An implementation that snapshotted
    -- the mode on the way in would put back the squad answer for a match that
    -- has no squads -- which is total silence by design and indistinguishable
    -- from a fault (#157's second half). Re-deriving reads the slot for the
    -- match they are in NOW.
    --
    -- The two slots are set to DIFFERENT values on purpose; it is the only way
    -- to see which one won.
    fire('br:settings:changed',
         { voiceModeSolo = BR.VoiceMode.OFF, voiceModeSquad = BR.VoiceMode.SQUAD })
    BR.State.match.mode = BR.Mode.SQUAD.key
    settle()
    beState(BR.PlayerState.LOBBY)
    BR.State.match.mode = BR.Mode.SOLO.key   -- they queued a solo from the lobby
    beState(BR.PlayerState.WARMUP)
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'a lobby visit that changes match kind comes back to the preference for '
           .. 'the match they are in NOW -- the solo slot, not a snapshot of the '
           .. 'squad answer taken on the way in',
       tostring(BR.Voice.mode()))
    BR.State.match.mode = BR.Mode.SQUAD.key
    beState(BR.PlayerState.LOBBY)
    beState(BR.PlayerState.WARMUP)
    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD,
       'and back the other way, with no settings change in between',
       tostring(BR.Voice.mode()))

    -- ==================================================================== --
    -- A LOBBY PLAYER WHILE A MATCH IS RUNNING HEARS NOTHING, AND THAT IS THE
    -- ANSWER RATHER THAN AN ACCIDENT.
    --
    -- The rule is written against THIS PLAYER's state, not the MATCH's, so a
    -- match in full flight underneath somebody sitting in the lobby changes
    -- nothing about them. That is what the owner asked for and it is also the
    -- only safe answer: the lobby is where a player who just died and a player
    -- waiting for the next round both sit, and a lobby that could listen to a
    -- live match is a channel for exactly the intel a spectator was muted to
    -- stop carrying.
    fire('br:settings:changed',
         { voiceModeSolo = BR.VoiceMode.NEARBY, voiceModeSquad = BR.VoiceMode.NEARBY })
    BR.State.match.mode = BR.Mode.SQUAD.key
    local during = beState(BR.PlayerState.LOBBY)
    fire(BR.Net.STATE, { state = BR.MatchState.PLAYING, mode = BR.Mode.SQUAD.key })
    during = settle()
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'a live match running around a lobby player does not give them voice -- '
           .. 'the rule is their state, not the match state',
       tostring(BR.Voice.mode()))
    ok(during.sends[2] == nil and during.sends[3] == nil,
       'they transmit to nobody, though a nearby preference and two players one '
           .. 'metre away would otherwise reach both',
       'sends 2=' .. tostring(during.sends[2]) .. ' 3=' .. tostring(during.sends[3]))
    ok(during.muted[2] == true and during.muted[3] == true,
       'and they hear nobody either',
       'muted 2=' .. tostring(during.muted[2]) .. ' 3=' .. tostring(during.muted[3]))

    -- AN ADMIN IN THE LOBBY IS NOT DIFFERENT, and there is nothing to assert
    -- against because there is nothing to assert: no config key, no permission
    -- read, no branch. Same shape as BR.Voice.silenced()'s "not varied by
    -- whether the session is a dead player's or an admin's". This is a TEXT
    -- check, and it is the only instrument that can see the absence of a branch.
    do
        local vFh = io.open(ROOT .. 'br_core/client/voice.lua', 'r')
        local vSrc = vFh and vFh:read('a') or ''
        if vFh then vFh:close() end
        local code = vSrc:gsub('%-%-%[%[.-%]%]', ' '):gsub('%-%-[^\n]*', '')
        local lobAt = code:find('local function inLobby', 1, true)
        local body = lobAt and code:sub(lobAt, lobAt + 400) or ''
        ok(body:find('BR.PlayerState.LOBBY', 1, true) ~= nil,
           'the lobby test really reads BR.PlayerState.LOBBY, the same name '
               .. 'lobbycam.lua and locker.lua use',
           'inLobby does not compare against BR.PlayerState.LOBBY')
        ok(not code:find('Admin', 1, true) and not code:find('isAdmin', 1, true),
           'and nothing in client/voice.lua consults an admin flag -- the rule '
               .. 'is unconditional, with no exemption to keep in step',
           'client/voice.lua has grown an admin branch')
    end

    -- ==================================================================== --
    -- A CLIENT THAT CANNOT SAY WHERE IT IS, IS NOT IN THE LOBBY.
    --
    -- FOUND BY MUTATION: flipping inLobby() to `me == nil or ...` -- so a
    -- missing state mirror counts AS the lobby -- passed every assertion above,
    -- because BR.State.me is populated at load by client/main.lua and nothing
    -- here had ever taken it away.
    --
    -- THE DIRECTION IS onBus()'s, DELIBERATELY. That function has answered this
    -- exact question with `me ~= nil and ...` since it was written, the two sit
    -- three lines apart, and two neighbouring reads of the same mirror
    -- disagreeing about what nil means is a bug waiting for whoever edits one of
    -- them. It is also the honest answer: nothing has PUT this player in the
    -- lobby, so nothing should silence them for it -- and the state arrives
    -- within one roster push, at which point the rule applies for real.
    do
        local realMe = BR.State.me
        BR.State.me = nil
        ok(BR.Voice.mode() ~= BR.VoiceMode.OFF,
           'a client with no state mirror at all is not treated as being in the '
               .. 'lobby -- the same answer onBus() gives to the same question, '
               .. 'three lines away', tostring(BR.Voice.mode()))
        ok(BR.Voice.silenced() == false,
           'and its microphone is not taken on the strength of a nil',
           tostring(BR.Voice.silenced()))
        BR.State.me = realMe
    end

    -- ==================================================================== --
    -- SPECTATING AND THE LOBBY OVERLAP, AND NEITHER RESCUES THE OTHER.
    --
    -- The real sequence: a dead player spectates their squad, the match ends
    -- under them, and the session stops IN THE LOBBY. The spectate block above
    -- asserts the session ending restores the preference; that must not happen
    -- here, because they are now in the lobby. Two overlays over one derivation,
    -- and the second has to hold when the first lifts.
    local realSpectate2 = BR.Spectate
    local spectating2 = false
    BR.Spectate = { active = function() return spectating2 end }
    fire('br:settings:changed',
         { voiceModeSolo = BR.VoiceMode.NEARBY, voiceModeSquad = BR.VoiceMode.SQUAD })
    BR.State.match.mode = BR.Mode.SQUAD.key
    beState(BR.PlayerState.SPECTATING)
    spectating2 = true
    settle()
    ok(BR.Voice.mode() == BR.VoiceMode.OFF, 'watching: off', tostring(BR.Voice.mode()))
    -- the match ends: the camera comes down and they land in the lobby
    spectating2 = false
    local landed = beState(BR.PlayerState.LOBBY)
    ok(BR.Voice.mode() == BR.VoiceMode.OFF and landed.radio == 0,
       'a spectate session that ends IN THE LOBBY does not give voice back -- '
           .. 'the camera lifting is not the lobby lifting',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(landed.radio))
    local next2 = beState(BR.PlayerState.WARMUP)
    ok(BR.Voice.mode() == BR.VoiceMode.SQUAD and next2.radio == 41207,
       'and the next match gives it back, once both overlays are gone',
       tostring(BR.Voice.mode()) .. ' / radio ' .. tostring(next2.radio))
    BR.Spectate = realSpectate2

    BR.State.me.state = BR.PlayerState.ALIVE
    mumble.talking[2] = nil
    nobodyElse()
    settle()
end

describe('the inventory bar draws the player being watched')
do
    -- THE BUG, IN THE OWNER'S WORDS: "the health/shield/inventory don't show
    -- properly. They should be fully populated." They were populated -- with
    -- the DEAD VIEWER's inventory, which is empty, because dying clears it.
    -- The camera changed subject and the bar did not.
    --
    -- WHAT IS ASSERTED HERE is the client half: that the bar is fed from the
    -- spectate feed while a session is running and from the player's own mirror
    -- when it is not. The SERVER half -- that the target's inventory is only
    -- ever sent to somebody the server already let watch them -- is not a value
    -- this suite can see, and is gated by tools/check_spectator_hud.lua.

    --- The payload of the last `inv` envelope pushed to the interface.
    local function lastInv()
        for i = #events, 1, -1 do
            local e = events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.INV then
                return e.args[2]
            end
        end
        return nil
    end

    -- A LOADOUT NOBODY IN THIS SUITE COULD PRODUCE BY ACCIDENT, so an assertion
    -- that passes cannot be passing on the local mirror that happens to agree.
    local WATCHED = {
        slots = {
            { id = 'wpn_spectated_rifle', label = 'Watched Rifle',
              kind = 'weapon', rarity = 'legendary', count = 1, clip = 7,
              pool = 'rifle' },
            false, false, false, false,
        },
        ammo   = { rifle = 61 },
        active = 1,
        using  = nil,
    }

    fire('br:spectate:inv', WATCHED)
    local got = lastInv()
    ok(type(got) == 'table' and got.slots and got.slots[1]
       and got.slots[1].id == 'wpn_spectated_rifle',
       'the bar is fed the WATCHED player\'s slots, not the viewer\'s own',
       tostring(got and got.slots and got.slots[1]
           and got.slots[1].id or 'nothing'))
    ok(type(got) == 'table' and got.ammo and got.ammo.rifle == 61
       and got.active == 1,
       'and their ammo pools and the slot in their hand travel with it',
       tostring(got and got.ammo and got.ammo.rifle))

    -- A QUIET TICK MUST NOT BLANK THE BAR. The server dedupes the inventory out
    -- of most feed pushes, so "no inventory in this message" is the ORDINARY
    -- case and means unchanged. A client that treated it as empty would blink
    -- the bar four times a second, which is the reported bug wearing a hat.
    local before = lastInv()
    TriggerEvent('br:ui:sendLocal', BR.Nui.INV, before)  -- a push with no change
    ok(lastInv() ~= nil and lastInv().slots[1] ~= nil
       and lastInv().slots[1].id == 'wpn_spectated_rifle',
       'a feed tick carrying no inventory leaves the last one standing',
       'the bar blanked on an unchanged tick')

    -- AND IT HANDS BACK. A session ending sends an explicit nil, and the bar
    -- has to return to the viewer's own mirror -- otherwise a player who
    -- stopped spectating spends the rest of the round looking at somebody
    -- else's rifle.
    fire('br:spectate:inv', nil)
    local mine = lastInv()
    ok(type(mine) == 'table'
       and not (mine.slots and mine.slots[1] and mine.slots[1].id
                == 'wpn_spectated_rifle'),
       'and the session ending puts the viewer\'s own inventory back',
       tostring(mine and mine.slots and mine.slots[1]
           and mine.slots[1].id or 'empty'))

    -- THE PICTURE IS READ-ONLY. Nothing in this file may act on a spectated
    -- inventory: the slot keys, the drop and the use all read the local mirror,
    -- and the substitution happens only on the way to the interface. Asserted
    -- on the source because the defect would be a call site that reads the
    -- wrong variable, which no payload can show.
    local invFh  = io.open(ROOT .. 'br_core/client/inventory.lua', 'r')
    local invSrc = invFh and invFh:read('a') or ''
    if invFh then invFh:close() end
    -- THREE, AND THE NUMBER IS THE ASSERTION: the declaration, the ONE read on
    -- the way to the interface, and the ONE write from the feed. A fourth is
    -- either a second draw path or -- the case this exists for -- an ACTION
    -- reading it, which would be a keypress asking the server to drop another
    -- player's weapon. Somebody who genuinely needs a fourth updates this
    -- number and has to say why, which is the same discipline verify.sh applies
    -- to the console's verb set.
    local reads = select(2, invSrc:gsub('spectated', ''))
    ok(reads == 3,
       'the spectated inventory is declared once, drawn from once and written '
           .. 'once -- it is a picture, and nothing in this file may act on it',
       ('`spectated` appears %d time(s), expected 3'):format(reads))
end

describe('a spectator\'s click does not reach their own ped')
do
    -- "I had a gun in hand and accidentally shot it while in spectate. My
    -- preference would be we disable all ped actions while in spectate" -- the
    -- owner, 2026-08-22.
    --
    -- ═══ WHY THE ANSWER IS NOT ENTIRELY IN client/spectate.lua ═══
    --
    -- That file holds down every control a ped acts through, which stops the
    -- ENGINE reacting to them. THIS file is not the engine. The two readers
    -- below are `IsDisabledControlJustPressed`, which is documented -- in this
    -- very file, twice -- to see a control somebody has suppressed; that is the
    -- whole reason the disabled variants exist and it is how the spectate keys
    -- themselves keep working. So a suppressed left mouse button went on
    -- drinking a shield potion, and a suppressed scroll wheel went on swapping
    -- the weapon in the ped's hand. A longer list in the other file cannot
    -- reach either of them.
    --
    -- ═══ AND WHY ONLY AN ADMIN EVER HIT IT ═══
    --
    -- canArm() is false for DEAD and SPECTATING, so a dead player watching
    -- their squad returns before both readers and always did. An ADMIN
    -- spectator is ALIVE -- the console's button asks only that they be in game
    -- -- holding their own loadout, and fell straight through. Which is exactly
    -- the asymmetry the whole spectate feature keeps having to be reminded of.
    local realSpectate = BR.Spectate
    local spectating = false
    BR.Spectate = { active = function() return spectating end }

    local realPressed = IsDisabledControlJustPressed
    local pressing = nil
    function IsDisabledControlJustPressed(_pad, c) return c == pressing end

    -- An ALIVE admin holding a consumable: the reported position.
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    fire(BR.Net.INV_SET, {
        slots = { { id = 'shield_small', kind = BR.ItemKind.CONSUMABLE,
                    count = 1 } },
        ammo = {}, active = 1,
    })

    local function asked(name)
        local n = 0
        for _, s in ipairs(sent) do if s.name == name then n = n + 1 end end
        return n
    end

    -- 1. THE BASELINE. Not spectating, the click uses the potion. If this ever
    --    stops being true the two assertions after it prove nothing at all --
    --    a gate that blocks something already impossible is a gate that passes
    --    for the wrong reason.
    sent = {}
    pressing = 24                                    -- INPUT_ATTACK
    BR.Loop.step(BR.Loop.FRAME)
    ok(asked(BR.Net.INV_USE) == 1,
       'an alive player clicking with a consumable in hand uses it',
       ('%d INV_USE'):format(asked(BR.Net.INV_USE)))

    -- 2. THE SAME CLICK, SPECTATING.
    spectating = true
    sent = {}
    BR.Loop.step(BR.Loop.FRAME)
    ok(asked(BR.Net.INV_USE) == 0,
       'and the same click while spectating does nothing -- the mouse belongs '
           .. 'to the camera',
       ('%d INV_USE'):format(asked(BR.Net.INV_USE)))

    -- 3. THE WHEEL, WHICH IS THE OTHER READER AND A SEPARATE PATH. Swapping the
    --    weapon in your own ped's hand while watching somebody else's fight is
    --    the same class of accident as firing it.
    sent = {}
    pressing = 15                                    -- WHEEL_UP
    BR.Loop.step(BR.Loop.FRAME)
    ok(asked(BR.Net.INV_SELECT) == 0,
       'and the scroll wheel does not swap the weapon in the spectator\'s hand',
       ('%d INV_SELECT'):format(asked(BR.Net.INV_SELECT)))

    -- 4. GTA'S WEAPON WHEEL IS STILL SUPPRESSED. The gate sits BELOW the
    --    suppression loop for this reason: #134's own note names DEAD/
    --    SPECTATING as a phase the engine's wheel must not appear in, so a gate
    --    written one block higher would trade one bug for that one.
    local disabled = {}
    local realDisable = DisableControlAction
    function DisableControlAction(_pad, c) disabled[c] = true end
    BR.Loop.step(BR.Loop.FRAME)
    DisableControlAction = realDisable
    ok(disabled[37] == true,
       'and GTA\'s weapon wheel is still held down while spectating (#134)',
       'control 37 was not disabled')

    -- 5. IT HANDS BACK. The same property the rest of this feature is built on:
    --    stop spectating and the click works again, with nothing to reset.
    spectating = false
    sent = {}
    pressing = 24
    BR.Loop.step(BR.Loop.FRAME)
    ok(asked(BR.Net.INV_USE) == 1,
       'and the click comes straight back when the session ends',
       ('%d INV_USE'):format(asked(BR.Net.INV_USE)))

    pressing = nil
    IsDisabledControlJustPressed = realPressed
    BR.Spectate = realSpectate
end

describe('the inventory panel holds the PASSENGER trigger, not just the driver\'s')
do
    -- ═══ THE COMMENT NAMED THE CONTROL WE MEANT, BESIDE A DIFFERENT ID ═══
    --
    -- The panel-open block read:
    --
    --     DisableControlAction(0, 68, true)   -- VEH_ATTACK
    --     DisableControlAction(0, 69, true)   -- VEH_PASSENGER_ATTACK
    --
    -- Checked against the FiveM controls table on 2026-08-22: 68 is VEH_AIM,
    -- 69 is VEH_ATTACK, 91 is VEH_PASSENGER_AIM and 92 is
    -- VEH_PASSENGER_ATTACK -- and 92 appeared NOWHERE in inventory.lua. So the
    -- block took the driver's trigger and both aims and left the passenger's
    -- trigger live: a player riding shotgun could fire with the panel open,
    -- which is the one accident this block exists to prevent.
    --
    -- The wrong comment is why it survived review, and it is why this is a
    -- test rather than a corrected comment: a comment cannot fail a build.
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, count = 1 } },
        ammo = {}, active = 1,
    })

    --- Every control the FRAME loop disables in one step.
    local function heldControls()
        local seen = {}
        local real = DisableControlAction
        function DisableControlAction(_pad, c) seen[c] = true end
        BR.Loop.step(BR.Loop.FRAME)
        DisableControlAction = real
        return seen
    end

    local function togglePanel()
        for _, fn in ipairs(BR.Keys.listeners['inventory'] or {}) do fn(true) end
    end

    -- 1. THE BASELINE, WHICH IS THE HALF THAT MAKES THE REST MEAN ANYTHING.
    --    With the panel shut the trigger must be FREE -- a gate that blocks
    --    something already blocked passes for the wrong reason.
    local shut = heldControls()
    ok(shut[92] ~= true,
        'with the panel shut, the passenger trigger is the player\'s',
        'control 92 was disabled with no panel open')

    -- 2. THE PANEL IS OPEN, AND ALL FIVE IN-VEHICLE CONTROLS ARE HELD.
    togglePanel()
    local open = heldControls()
    ok(open[92] == true,
        'the panel holds VEH_PASSENGER_ATTACK (92) -- the reported gap',
        'control 92 was NOT disabled with the panel open')
    ok(open[91] == true,
        'and VEH_PASSENGER_AIM (91) with it',
        'control 91 was NOT disabled with the panel open')
    ok(open[68] == true and open[69] == true and open[70] == true,
        'and the driver\'s aim and both triggers, as it always did',
        ('68=%s 69=%s 70=%s'):format(tostring(open[68]), tostring(open[69]),
                                     tostring(open[70])))

    -- 3. IT HANDS BACK. DisableControlAction lasts one frame, so closing the
    --    panel restores by arithmetic rather than by remembering to.
    --
    --    CLOSED THROUGH THE UI ACTION, NOT A SECOND KEYPRESS. The key handler
    --    swallows a toggle within 250ms of the last one -- the debounce that
    --    fixed the panel blinking while TAB was held (user, 2026-08-09) --
    --    so a test that pressed twice in the same tick would leave the panel
    --    OPEN and then assert against a state it never reached. It did,
    --    before this comment existed.
    fire('br:ui:action', BR.NuiCb.CLOSE)
    local shutAgain = heldControls()
    ok(shutAgain[92] ~= true,
        'and closing the panel gives the trigger straight back',
        'control 92 was still disabled after the panel closed')
end

describe('the start-of-match voice notice says the mode and the real key')
do
    -- THE SENTENCE IS THE OWNER'S, VERBATIM:
    --
    --   "Voice chat is set to [mode]. Hold [button] to speak. You can change
    --    your voice preference and keybinds in Settings."
    --
    -- IT REPLACES A PERMANENT HUD LINE. The thing removed this round was a
    -- string across the bottom of the screen for the whole match telling the
    -- player to hold a key. This is the same information said once, when it is
    -- news, at the start of a match -- and then gone.
    local noticeFor = BR.Voice.noticeFor
        or function() return nil end

    -- ═══ THE KEY IS A TOKEN NOW, AND THAT IS #209 ═══
    --
    -- This block used to assert 'Hold N to speak.' -- the LABEL, substituted
    -- here. Owner, 2026-08-22, looking at this exact sentence on screen: "we
    -- should make our own glyphs for keys. For example, this message looks too
    -- bland and hard coded". The complaint was not the wording, which is
    -- unchanged below to the character; it was that the N was a letter of
    -- prose. So the sentence now carries BR.KeyToken('brptt') and the page
    -- draws a plate for it.
    --
    -- THE WORDING ASSERTIONS ARE THE POINT AND THEY DID NOT MOVE. Everything
    -- around the hole is still checked verbatim, so a change that "fixed" the
    -- glyph by rewriting the owner's sentence still fails here.
    local nb = noticeFor(BR.VoiceMode.NEARBY, 'N')
    ok(type(nb) == 'string' and nb:find('set to nearby', 1, true) ~= nil,
       'it names the mode in force', tostring(nb))
    ok(type(nb) == 'string'
       and nb:find('Hold {key:brptt} to speak.', 1, true) ~= nil,
       'and the key, in the owner\'s words, with the key itself left as a hole '
           .. 'for the interface to draw',
       tostring(nb))
    -- AND THE LABEL IS NOWHERE IN IT. Passing 'N' must not put an N in the
    -- string: the whole value of the token is that the sentence cannot go
    -- stale, and a version that substituted the label AND emitted a token
    -- would satisfy the assertion above while keeping the bug.
    ok(type(nb) == 'string' and nb:find('Hold N', 1, true) == nil,
       'the resolved label is not substituted into the sentence at all',
       tostring(nb))
    ok(type(nb) == 'string'
       and nb:find('voice preference and keybinds in Settings', 1, true) ~= nil,
       'and where to change both', tostring(nb))

    -- A DIFFERENT LABEL PRODUCES THE SAME STRING, which is the token's whole
    -- claim stated as a test: what reaches the interface no longer depends on
    -- what key was bound at the moment it was composed, only on WHETHER one
    -- was. The page resolves the rest, live, on every rebind push.
    local sq = noticeFor(BR.VoiceMode.SQUAD, 'V')
    ok(type(sq) == 'string' and sq:find('set to squad', 1, true) ~= nil
       and sq:find('Hold {key:brptt}', 1, true) ~= nil,
       'the mode is read rather than assumed, and the key is named by command',
       tostring(sq))
    ok(sq == noticeFor(BR.VoiceMode.SQUAD, 'Page Down'),
       'and rebinding does not change the sentence -- only the glyph it holds',
       tostring(sq))

    -- OFF SAYS NOTHING. Explicit owner instruction, and it is the same rule
    -- the toast already applies: a state the player chose is not news.
    ok(noticeFor(BR.VoiceMode.OFF, 'N') == nil,
       "no notice at all when voice is off",
       tostring(noticeFor(BR.VoiceMode.OFF, 'N')))

    -- AND NO KEY MEANS NO KEY. An action cleared, or lost to a conflict with
    -- another binding, is on nothing -- and naming one anyway is the exact lie
    -- #129's third round was, where a prompt said R and the engine was
    -- listening on E.
    local unbound = noticeFor(BR.VoiceMode.NEARBY, nil)
    ok(type(unbound) == 'string' and unbound:find('not bound', 1, true) ~= nil
       and unbound:find('Hold', 1, true) == nil,
       'an unbound push-to-talk says so rather than inventing a key',
       tostring(unbound))

    -- ==================================================================== --
    -- THE SURFACE, AS ONE SESSION FROM START TO FINISH.
    --
    -- ONE SEQUENCE RATHER THAN SIX INDEPENDENT SCENARIOS, AND THAT IS FORCED
    -- BY THE THING UNDER TEST. "Once per session" is a latch with no reset --
    -- deliberately, that is the whole feature -- so there is no way to give
    -- each assertion a fresh session short of reloading the file, and a
    -- test-only reset would be a second mechanism that could disagree with the
    -- real one. Read top to bottom: this is one player, connecting once, and
    -- every later assertion depends on what the earlier ones did or did not
    -- spend.
    --
    -- IT STARTS ON 'off' ON PURPOSE. That ordering is the only way to prove
    -- the load-bearing half of the rule: a suppressed notice must not spend
    -- the session's one delivery. Run the same assertions the other way round
    -- and every one of them passes with the latch spent on the opportunity,
    -- which is the bug.
    nobodyElse()
    standAt(0, 0)

    local function lastToastText()
        for i = #events, 1, -1 do
            local e = events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST then
                return type(e.args[2]) == 'table' and e.args[2].text or nil
            end
        end
        return nil
    end

    --- One match start, and whatever it said. `mode` is the MATCH kind.
    local function warmup()
        events = {}
        fire(BR.Net.STATE, { state = BR.MatchState.WARMUP,
                             mode = BR.Mode.SQUAD.key })
        local t = lastToastText()
        if type(t) == 'string' and t:find('Voice chat is set to', 1, true) then
            return t
        end
        return nil
    end

    --- The round ends. Nothing about this may re-arm the notice; it is fired
    --- between matches precisely because the previous version reset on it.
    local function matchOver()
        fire(BR.Net.STATE, { state = BR.MatchState.ENDED,
                             mode = BR.Mode.SQUAD.key })
    end

    -- 1. A SESSION THAT BEGINS MUTED SAYS NOTHING, TWICE OVER.
    voiceApply(BR.VoiceMode.OFF, nil, nil, 1)
    ok(warmup() == nil,
       "a player who has voice off is not told about it -- the owner's "
           .. 'explicit instruction', 'a notice fired on off')
    matchOver()
    ok(warmup() == nil, 'and is still not told in their second match',
       'a notice fired on off')

    -- 2. ...AND HAS SPENT NOTHING. THIS IS THE ASSERTION THE WHOLE ORDERING
    -- EXISTS FOR. The latch is spent on DELIVERY, never on the opportunity, so
    -- switching voice on for the first time still earns the sentence -- and
    -- the sentence names the push-to-talk key, which is the one fact the
    -- removed HUD line used to carry.
    matchOver()
    voiceMode(BR.VoiceMode.NEARBY)

    -- ═══ AND THE BROADCAST ARRIVES WHILE THIS CLIENT IS STILL IN THE LOBBY,
    --     WHICH IS THE REAL ORDERING AND NOT AN EDGE ═══
    --
    -- server/match.lua's BR.Match.onEnter sends Broadcast.state(WARMUP) from
    -- transition() BEFORE it runs the Roster.setState loop that moves anybody
    -- out of LOBBY. Those are two different messages on two different paths, so
    -- at the instant this handler runs the mirrored state is still `lobby`.
    --
    -- SINCE 2026-08-22 THAT IS A MODE OF 'off' (BR.Voice.mode overlays the
    -- lobby), and noticeFor() returns nil on 'off'. A handler that read mode()
    -- here would therefore decline to say anything -- every match, in every
    -- session, forever, because the latch is spent on DELIVERY and so would
    -- never be spent at all. The player would simply never be told the
    -- push-to-talk key, which is the one fact the removed HUD line carried.
    --
    -- The fix is that the notice reads BR.Voice.chosenMode() -- the SETTING,
    -- which is what the sentence is about -- and this is the assertion that
    -- says so. Nothing else in the suite would have caught it: voiceApply()
    -- leaves this client ALIVE, so every other warmup() in this block runs from
    -- a state the real game is never in at that moment.
    BR.State.me.state = BR.PlayerState.LOBBY
    ok(BR.Voice.mode() == BR.VoiceMode.OFF,
       'a client that has not yet been moved out of the lobby really is on '
           .. "'off' when the WARMUP broadcast lands -- the precondition, "
           .. 'stated so this test cannot pass by the state being wrong',
       tostring(BR.Voice.mode()))

    local shown = warmup()
    ok(type(shown) == 'string',
       'and turning voice ON later still earns the notice -- being suppressed '
           .. 'is not the same as having been shown, and the lobby the player '
           .. 'has not left yet does not suppress it',
       tostring(shown))
    ok(type(shown) == 'string' and shown:find('set to nearby', 1, true) ~= nil,
       'and it names the mode they CHOSE rather than the lobby they are '
           .. 'standing in', tostring(shown))
    BR.State.me.state = BR.PlayerState.ALIVE

    -- 3. ONCE PER BROADCAST IS NOT ENOUGH. The digest re-fires STATE on any
    -- change, so the same warmup can arrive more than once.
    ok(warmup() == nil,
       'a second WARMUP broadcast inside the same match says it again to '
           .. 'nobody', 'the notice repeated within one match')

    -- 4. AND ONCE PER SESSION, NOT ONCE PER MATCH. THIS IS THIS ROUND'S
    -- CHANGE, and the assertion here previously said the opposite -- "while
    -- the next match gets its own" -- which was right until the owner played
    -- four rounds with it. Verbatim: "let's make the 'your voice chat is set
    -- to ...' notification only happen once per session. Not per match."
    matchOver()
    ok(warmup() == nil,
       'and the NEXT match does not get its own -- once per session is the '
           .. 'whole change, and nothing re-arms the latch',
       'the notice fired again in a later match')
    matchOver()
    ok(warmup() == nil, 'nor the one after that',
       'the notice fired again in a later match')

    -- 5. A PREFERENCE CHANGE DOES NOT RE-ARM IT EITHER, and that is a decision
    -- rather than a consequence. A player who changes their voice mode is
    -- standing on the settings screen, which is already rendering the same
    -- information (`voiceDetail`, off BR.Voice.statusFor). Re-announcing it
    -- next match would tell them what they just did -- and would quietly
    -- restore per-match behaviour for anybody who opens Settings between
    -- rounds, which is the behaviour being removed.
    matchOver()
    voiceMode(BR.VoiceMode.SQUAD)
    ok(warmup() == nil,
       'changing the voice mode mid-session does not re-announce it -- the '
           .. 'screen they changed it on was already saying it',
       'a preference change re-armed the notice')
    matchOver()
    voiceMode(BR.VoiceMode.OFF)
    voiceMode(BR.VoiceMode.NEARBY)
    ok(warmup() == nil, 'and neither does turning it off and back on',
       'a preference change re-armed the notice')

    -- THE MATCH KIND CHANGING RE-DERIVES THE MODE, which is the whole reason
    -- there are two saved preferences. A player whose solo preference is Off
    -- and whose squad preference is Nearby must not carry one into the other.
    fire('br:settings:changed',
         { voiceModeSolo = 'off', voiceModeSquad = 'nearby' })
    BR.State.match.mode = BR.Mode.SOLO.key
    ok(BR.Voice.routing().proximity == false,
       'a solo match reads the solo slot', tostring(BR.Voice.mode()))
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP,
                         mode = BR.Mode.SQUAD.key })
    BR.State.match.mode = BR.Mode.SQUAD.key
    ok(BR.Voice.routing().proximity == true,
       'and the same client in a squad match reads the squad slot, with no '
           .. 'settings change in between',
       tostring(BR.Voice.mode()))
end

describe('voice never crosses a match')
do
    -- The property the whole system exists for. It is a different mechanism
    -- now -- routing buckets rather than Mumble rooms -- so it is asserted at
    -- the level that mechanism actually operates on: a player in another
    -- match is not streamed, so they are never a candidate to transmit to.
    standAt(0, 0)
    -- Same coordinates, which is the whole difficulty: two matches stand on top
    -- of each other. Player 9 is in the other match and therefore has no ped.
    playersAt({ [2] = { x = 1, y = 0 }, [9] = false })
    local a = voiceApply('nearby', nil, nil, 1)
    ok(a.sends[2] == true, 'somebody in my match, one metre away, hears me')
    ok(a.sends[9] == nil,
        'and somebody in ANOTHER match on the same spot does not',
        'a different match is being transmitted to')

    -- AND THE SQUAD RADIO IS A SECOND, INDEPENDENT WALL, which is worth having
    -- because it does not depend on scope at all: two squads handed different
    -- channels cannot reach each other however close they stand.
    --
    -- THE ARITHMETIC THAT PRODUCES THOSE NUMBERS IS THE SERVER'S and it is NOT
    -- swept here -- BR.Voice.radioChannel lives in br_core/server/voice.lua and
    -- this suite loads only the client half. What is checked here is that the
    -- client honours a difference it is handed. See the note at the end of this
    -- section for what the server suite still owes.
    nobodyElse()
    standAt(0, 0)
    local s1 = voiceApply('squad', 30703, { 2 }, 1)
    local s2 = voiceApply('squad', 30803, { 4 }, 3)
    ok(not hears(s1, s2) and not hears(s2, s1),
        'two squads on different radios cannot hear each other at any range')

    local s3 = voiceApply('squad', 30703, { 1 }, 2)
    ok(hears(s1, s3) and hears(s3, s1),
        'and two players on the SAME radio can -- so the wall is the number, '
            .. 'not an accident of the model')

    local noSquad = voiceApply('squad', nil, nil, 5)
    ok(noSquad.radio == 0 and not hears(noSquad, s1) and not hears(s1, noSquad),
        'and a player with no squad radio reaches nobody by radio at all')
end

describe('br_core survives pma-voice being absent, and says so')
do
    -- THE HARD CONSTRAINT: a missing voice resource must not stop the gamemode.
    -- It is now a TOTAL voice outage rather than a degraded one, so the second
    -- half matters as much as the first -- the last outage was invisible for a
    -- week.
    pmaReset()
    pma.running = false
    nobodyElse()
    standAt(0, 0)

    local okRun = pcall(function()
        fire('onClientResourceStart', 'br_core')
        setVoicePref('squad')
        fire(BR.Net.VOICE_SET, { radio = 30503, mates = { 2 },
                                 nearbyRange = VR.nearby })
        BR.Loop.step(BR.Loop.TICK)
    end)
    ok(okRun, 'the whole voice path runs with no voice resource installed',
        'br_core raised when pma-voice was missing')
    ok(pma.check == nil, 'and nothing was installed into a resource that is gone')

    local said = table.concat(logged, '\n')
    ok(said:find('pma%-voice') ~= nil and said:upper():find('NOT RUNNING') ~= nil,
        'and it says so, loudly, once', said)

    -- AND IT RECOVERS WHEN THE RESOURCE TURNS UP, which is not hypothetical: an
    -- admin restarting pma-voice mid-match drops every rule br_core gave it,
    -- because the override lives in that resource's Lua state.
    pma.running = true
    fire('onClientResourceStart', 'pma-voice')
    ok(pma.check ~= nil,
        'and the rules are re-installed when pma-voice starts later',
        'br_core never noticed pma-voice appear -- proximity is on its default')
    ok(pma.range == VR.nearby,
        'including the range', tostring(pma.range))
end

describe('the talking indicator names people we can actually hear')
do
    -- THE INDICATOR WAS LYING, AND THE LIE IS WHAT DIAGNOSED #157: "regardless
    -- of distance, 'nearby' doesn't output audio, though it does show who's
    -- talking, even when they should be out of range."
    --
    -- Under pma-voice that specific lie is gone by construction -- frames only
    -- arrive if the speaker targeted us -- but the indicator has a NEW way to
    -- be wrong, and it is the one this block is really about: it must be
    -- match-wide, not scope-wide.
    standAt(0, 0)
    playersAt({ [2] = { x = 2, y = 0 }, [7] = false })

    -- ON 'nearby', THE PERSON STANDING NEXT TO YOU IS NAMED. This used to be
    -- asserted on 'squad' and passed, because squad was proximity plus a radio.
    -- It is asserted on the mode that actually routes proximity now.
    voiceApply('nearby', nil, nil, 1)
    mumble.talking = { [2] = true }
    BR.Loop.step(BR.Loop.TICK)
    local names = talkingNames()
    ok(#names == 1 and names[1] == 'p2',
        'somebody talking nearby is named', table.concat(names, ','))

    -- AND ON 'squad' THE SAME PERSON IS NOT, because squad does not hear them.
    -- THIS IS THE INDICATOR HALF OF THE EXCLUSIVITY RULE and it is the one that
    -- would have caught the old behaviour from the screen rather than from the
    -- code: the panel is built from the same set the mutes are, so a stranger
    -- named here is a stranger being heard.
    voiceApply('squad', 30503, { 7 }, 1)
    mumble.talking = { [2] = true }
    BR.Loop.step(BR.Loop.TICK)
    names = talkingNames()
    ok(#names == 0,
        'and on squad that same nearby stranger is NOT named -- squad does not '
            .. 'hear proximity',
        table.concat(names, ','))

    -- THE ASSERTION THE SCOPE GATE IS ABOUT. Player 7 is a squadmate on the
    -- radio, across the island, with no ped and no player index on this
    -- machine -- so nothing local can see them talk. They are audible. If the
    -- indicator were driven off the streamed player list they would be audible
    -- and invisible, which is the exact complaint the panel exists to answer.
    fire('pma-voice:setTalkingOnRadio', 7, true)
    BR.Loop.step(BR.Loop.TICK)
    names = talkingNames()
    local sawFar = false
    for _, n in ipairs(names) do if n == 'p7' then sawFar = true end end
    ok(sawFar,
        'and so is an out-of-scope squadmate talking on the radio',
        'the indicator can only see people standing next to you: ' ..
            table.concat(names, ','))

    -- AND THEY STOP BEING NAMED when they stop.
    fire('pma-voice:setTalkingOnRadio', 7, false)
    mumble.talking = {}
    BR.Loop.step(BR.Loop.TICK)
    ok(#talkingNames() == 0, 'and silence empties the panel',
        table.concat(talkingNames(), ','))

    -- ON 'off' THE PANEL IS EMPTY, and that is correct rather than a display
    -- fault: it is read from the same set the audio decision is made from, so a
    -- blank panel while muted is the truth.
    playersAt({ [2] = { x = 2, y = 0 } })
    voiceApply('off', nil, nil, 1)
    mumble.talking = { [2] = true }
    BR.Loop.step(BR.Loop.TICK)
    ok(#talkingNames() == 0,
        'off names nobody, because off hears nobody',
        table.concat(talkingNames(), ','))
end

describe('the voice readout runs, and leads with the thing that matters')
do
    -- #150 WAS A WEEK OF A READOUT THAT LOOKED RIGHT. The old one opened with a
    -- proximity channel number that was correct, current, and had nothing to do
    -- with whether audio was leaving the machine. The first line is now the
    -- only question worth asking first.
    logged = {}
    nobodyElse()
    standAt(0, 0)
    voiceApply('nearby', 30503, { 2 }, 1, BR.PlayerState.BUS)
    local okCmd = pcall(commands['brvoice'])
    local said = table.concat(logged, '\n')
    ok(okCmd, 'the client readout runs', said)
    ok(said:find('voice engine') ~= nil and said:find('pma%-voice') ~= nil,
        'and leads with whether the voice engine is even running', said)

    -- AND IT REPORTS THE GAG, which the previous version could not: a total
    -- outage was invisible because the readout named a room instead of a
    -- transmit path.
    ok(said:find('prox mic') ~= nil and said:upper():find('NO %-%-') ~= nil,
        'and says out loud that this player is not transmitting', said)

    -- AND IT NAMES WHAT THE MODE ROUTES, as two independent flags. The readout
    -- is where the old "squad = proximity plus radio" belief was invisible:
    -- there was one 'transmitting' line and no way to see that two channels
    -- were open at once. This line cannot describe a mode the routing table
    -- does not implement, because it is printed FROM the routing table.
    ok(said:find('routes') ~= nil and said:find('NEVER BOTH') ~= nil,
        'and prints proximity and radio as two flags that are never both on',
        said)
    ok(said:lower():find('bus') ~= nil,
        'and why -- the bus, in words a playtester can act on', said)

    -- AND IT POINTS AT THE RIGHT MACHINE. This is the single biggest change in
    -- how voice is diagnosed and it is the thing most likely to waste a
    -- playtest if it is not said: proximity is enforced by the speaker.
    ok(said:upper():find('SPEAKER') ~= nil,
        'and tells the reader that proximity is the speaker\'s decision', said)

    logged = {}
end

-- ----------------------------------------------------------- the descent ---
--
-- #131, ON ITS THIRD ATTEMPT, AND THE REASON THIS SECTION EXISTS.
--
-- Twice now the smoke-trail prompt has been reported as simply absent -- "no
-- hint text or DUI that shows anything other than how to pull the chute" -- and
-- twice the answer has been reasoned out by reading the file rather than
-- measured. The four things that decide whether the box is drawn are a chute
-- state, a cosmetics flag, a ped pose and a key label, and NONE of them was
-- reachable from any gate: the prompt lives in a FRAME callback in
-- client/skydive.lua and nothing in verify.sh had ever stepped it.
--
-- So this block steps it. It loads the real cosmetics and drop modules, plays a
-- descent through them a frame at a time, and asserts on the payload that
-- reaches the DUI page -- which is the actual subject of the issue. What it
-- cannot do is prove a browser drew the texture; that is the one part still
-- left to a human, and it is called out as such in the validation steps.

describe('the descent prompt hands the box from the glider to the trail')
do
    -- THREADS ARE RECORDED RATHER THAN DROPPED. `br:drop:begin` does its real
    -- work -- the chute, the canopy tint, the trail colour -- inside a
    -- Citizen.CreateThread, so the no-op stub above would have skipped the one
    -- call that arms the prompt and this whole block would have been asserting
    -- on a state nothing ever set. cosmetics.lua also opens a `while true`
    -- weapon-tint thread at load, which is why they are run by index rather
    -- than all at once.
    local threads = {}
    Citizen.CreateThread = function(fn) threads[#threads + 1] = fn end

    -- The ped, as the drop machine asks about it.
    local ped = {
        state = -1,      -- GetPedParachuteState
        freefall = false, falling = false,
        onFoot = true, inWater = false,
        agl = 0.0, speed = 0.0,
        hasChute = false, ammo = 0,
    }
    function GetPedParachuteState() return ped.state end
    function IsPedInParachuteFreeFall() return ped.freefall end
    function IsPedFalling() return ped.falling end
    function IsPedOnFoot() return ped.onFoot end
    function IsEntityInWater() return ped.inWater end
    function GetEntityHeightAboveGround() return ped.agl end
    function GetEntitySpeed() return ped.speed end
    function GetPlayerHasReserveParachute() return false end
    function HasPedGotWeapon() return ped.hasChute end
    function GetAmmoInPedWeapon() return ped.ammo end
    function GetSelectedPedWeapon() return 0 end
    function GetControlInstructionalButton() return '' end

    -- What the trail natives were actually told, because "armed" is a claim and
    -- the colour is the thing the player paid for.
    -- `allowed` IS PERMISSION, `held` IS EMISSION, AND ONLY ONE OF THEM MAKES
    -- SMOKE. SET_PLAYER_CAN_LEAVE_PARACHUTE_SMOKE_TRAIL grants the right to use
    -- INPUT_PARACHUTE_SMOKE (control 154, default X); it does not press it, and
    -- nothing in this codebase ever did. So `allowed == true` -- the only thing
    -- this block used to assert -- was true through every round of #131 while
    -- the sky stayed empty, and the suite agreed with the owner's readout that
    -- the feature worked. `held` is the fact that was missing.
    local smoke = { allowed = nil, rgb = nil, held = nil }
    function SetPlayerCanLeaveParachuteSmokeTrail(_, on) smoke.allowed = on end
    function SetPlayerParachuteSmokeTrailColor(_, r, g, b) smoke.rgb = { r, g, b } end
    function SetControlNormal(_, control, amount)
        smoke.held = (control == 154 and amount == 1.0)
    end
    function GetPlayerParachuteSmokeTrailColor() return 0, 0, 0 end

    for _, n in ipairs({
        'ClearHelp', 'ClearPedTasks', 'ClearPedTasksImmediately',
        'ForcePedToOpenParachute', 'SetEntityVisible',
        'SetPlayerParachuteModelOverride', 'SetPlayerParachuteTintIndex',
        'SetPlayerParachutePackTintIndex', 'SetPedWeaponTintIndex',
        'TaskParachute',
    }) do _G[n] = noop end

    -- THE PAGE, AS THE PROMPT USES IT. Every message and every draw is kept:
    -- the issue is not "did a function run", it is "what did the box say", and
    -- the last payload sent is the only honest answer to that.
    local dui = { sends = {}, draws = 0 }
    BR.Dui = {
        page       = function(name) return { name = name } end,
        send       = function(_, msg) dui.sends[#dui.sends + 1] = msg end,
        drawScreen = function() dui.draws = dui.draws + 1 end,
        drawWorld  = noop, drawOnEntity = noop,
        ready      = function() return true end,
    }
    local function lastSend()
        return dui.sends[#dui.sends]
    end

    BR.PushHud = BR.PushHud or noop
    BR.State.me.src = 1
    BR.State.match = { state = BR.MatchState.BUS }
    BR.State.roster = {}

    -- THE REAL KEY LOOKUP, not the loot suite's stub. `keyLabelForCommand` is
    -- one of the four candidate faults the issue names -- `key (none)` means the
    -- prompt has no key to print and correctly draws nothing -- so answering it
    -- with a constant 'E' would test the harness instead of the game. The stub
    -- is kept for everything else, which is loaded and running above.
    local stubNative = BR.Native
    BR.Native = nil
    loadAll({ 'br_core/client/natives.lua' })
    local realNative = BR.Native
    BR.Native = stubNative
    BR.Native.ChuteState = realNative.ChuteState
    BR.Native.keyLabelForCommand = realNative.keyLabelForCommand

    -- The help box the prompt falls back into when the browser is not up.
    local helpText = nil
    BR.Native.helpThisFrame = function(t) helpText = t end

    loadAll({
        'br_core/client/cosmetics.lua',
        'br_core/client/skydive.lua',   -- after cosmetics, as fxmanifest orders it
    })
    local loadThreads = #threads        -- cosmetics' weapon-tint loop; never run

    local CS = BR.Native.ChuteState

    --- Everything br:drop:begin does, including the thread it does it in.
    local function jump()
        local before = #threads
        fire('br:drop:begin', { heading = 0.0 })
        for i = before + 1, #threads do threads[i]() end
    end

    --- Put the player in the plane door with `id` equipped and no squad.
    local function equip(id, squadColour)
        BR.State.roster[1] = { squadId = squadColour and 'sq1' or nil,
                               colour = squadColour }
        fire(BR.Net.MARKET_STATE, { equipped = { trail = id } })
        ped.hasChute, ped.ammo = true, 1
        ped.state, ped.freefall, ped.falling = CS.ON_BACK, true, true
        ped.onFoot, ped.agl = true, 400.0
    end

    bootOn(true, true)   -- the raw key layer, on the build everyone plays

    ok(BR.Keys.labelFor('brtrail') == 'B',
        'the trail action is on a key the prompt can name',
        tostring(BR.Keys.labelFor('brtrail')))
    ok(BR.Native.keyLabelForCommand('brtrail') == 'B',
        'and the prompt asks for it by command and gets the same answer',
        tostring(BR.Native.keyLabelForCommand('brtrail')))

    equip('trail_ember')
    jump()

    ok(BR.Cosmetics.trailArmed == true,
        'a bought trail arms on the way out of the door',
        ('armed %s'):format(tostring(BR.Cosmetics.trailArmed)))
    -- ARMED IS NOT ON, AND THAT IS THE OWNER'S RULE (2026-08-17): "Smoke trails
    -- should always default to off, which requires the player to press the
    -- button, which will then dismiss our DUI".
    --
    -- So the purchase is what gets PAINTED -- the colour and the entitlement are
    -- resolved on the way out of the door -- while the engine permission stays
    -- FALSE until a press. That matters beyond our own flag: leaving permission
    -- granted lets the player's vanilla X emit smoke behind a prompt that says
    -- the trail is off.
    --
    -- THE COLOUR IS THE ASSERTION NOW, WHERE `trailSource == 'purchase'` USED TO
    -- BE. That field existed to tell a purchase from a squad colour and went
    -- with the squad colour (owner, 2026-08-20); what is left of the claim is
    -- that the EQUIPPED item's rgb reached the native, which is the stronger
    -- half and the one the engine can disagree with.
    local ember = BR.Config.MarketIndex['trail_ember'].apply.trailRgb
    ok(smoke.rgb ~= nil and smoke.rgb[1] == ember[1] and smoke.rgb[2] == ember[2]
       and smoke.rgb[3] == ember[3] and smoke.allowed == false,
        "and it is the bought item's colour that is painted -- but armed is not "
        .. 'ON, so the engine is not yet permitted to emit',
        ('rgb %s allowed %s'):format(
            smoke.rgb and table.concat(smoke.rgb, ',') or 'nil',
            tostring(smoke.allowed)))

    -- Freefall: chute stowed, ped in the parachute task.
    dui.sends, dui.draws = {}, 0
    frame(16)
    local g = lastSend()
    ok(g and g.show == true and g.label == 'Open the glider',
        'the freefall box offers the glider',
        g and tostring(g.label) or 'nothing was sent')
    ok(g and g.key == 'SPACE' or (g and g.key ~= nil),
        'with a key in the cap', g and tostring(g.key) or 'nil')
    ok(dui.draws > 0, 'and it is actually drawn')

    -- The canopy opens. The ped is under it, off its feet, still descending.
    dui.sends, dui.draws = {}, 0
    ped.state, ped.freefall = CS.OPEN, false
    ped.onFoot, ped.agl = false, 300.0
    frame(16)
    local t = lastSend()
    ok(t and t.show == true and t.label == 'Toggle smoke trails',
        'THE CANOPY HANDS THE BOX TO THE TRAIL -- #131',
        t and ('label %s show %s'):format(tostring(t.label), tostring(t.show))
           or 'nothing was sent to the page at all')
    ok(t and t.key == 'B',
        'naming the key the player is actually bound to',
        t and tostring(t.key) or 'nil')
    ok(dui.draws > 0, 'and the page is drawn under the canopy too',
        ('draws %d'):format(dui.draws))

    -- THE ENGINE CALLING A PARACHUTING PED "ON FOOT" MUST NOT TAKE THE PROMPT
    -- (#131, third round). IS_PED_ON_FOOT is true for a ped inside the parachute
    -- task's freefall on this build -- measured, live, 2026-08-04 -- and the
    -- gate built on it killed the GLIDER prompt for a whole healthy drop back
    -- then. The trail branch still had one until this round. Whatever the native
    -- answers under a canopy, the box is not allowed to depend on it.
    dui.sends, dui.draws = {}, 0
    ped.onFoot = true
    frame(16)
    local stubborn = lastSend()
    ok((stubborn == nil or stubborn.show ~= false) and dui.draws > 0,
        'a ped the engine calls on-foot under an open canopy still gets the box',
        ('draws %d last %s'):format(dui.draws,
            stubborn and tostring(stubborn.show) or 'nothing re-sent'))
    ped.onFoot = false

    -- THE BROWSER NOT COMING UP IS NOT ALLOWED TO MEAN SILENCE. A DUI is a whole
    -- CEF instance; if the second one never arrives the descent used to draw
    -- nothing and say nothing, which is exactly what this issue has been
    -- reported as twice and is indistinguishable from having nothing equipped.
    helpText = nil
    BR.Dui.ready = function() return false end
    frame(16)
    ok(helpText ~= nil and helpText:find('smoke trails', 1, true) ~= nil,
        'a page that is not up falls back to words rather than nothing',
        tostring(helpText))
    ok(helpText ~= nil and helpText:find('B', 1, true) ~= nil,
        'and the words still name the key the player is bound to',
        tostring(helpText))
    BR.Dui.ready = function() return true end

    -- THE REBIND REACHES THE AIR. The FAIL condition the owner was given twice
    -- is a cap that still says B after the key has been moved.
    BR.Keys.set('brtrail', 0x4A)   -- J
    dui.sends, dui.draws = {}, 0
    frame(16)
    local reb = lastSend()
    ok(reb and reb.key == 'J',
        'a mid-descent rebind moves the letter in the cap',
        reb and tostring(reb.key) or 'nothing was re-sent')
    BR.Keys.set('brtrail', 0x42)
    frame(16)

    -- THE KEY, PRESSED THE WAY A CLIENT PRESSES IT (#131, FIFTH ROUND).
    --
    -- Everything above proves the box says the right words and names the right
    -- key. The owner reports that half as correct and the key as inert: "the
    -- smoke trails prompt draws perfectly but does not do anything. It appeared
    -- as H, which is exactly the key I set."
    --
    -- SO THIS DRIVES THE KEYBOARD, NOT `showTrail`. The checks a few lines below
    -- call BR.Cosmetics.showTrail directly, which proves the CONSUMER and says
    -- nothing whatsoever about whether a press reaches it -- and a listener
    -- attached under a different action name than the one keybinds.lua registers
    -- would satisfy every one of them while the key did nothing at all. That is
    -- not a hypothetical shape in this project: it has thirteen confirmed
    -- instances of code that is correct and connected to nothing, and #129's
    -- third round was exactly this failure on `interact`. The press below runs
    -- the whole chain -- raw sample, fire('trail'), skydive's listener,
    -- BR.Cosmetics.showTrail, the native -- and nothing in it is stubbed except
    -- the native at the far end, which records what it was told.
    local function press(vk, engineName)
        keys[vk] = true; edge[vk] = true
        -- The engine's own command handler is invoked too, exactly as FiveM
        -- would, so a regression that let BOTH paths fire shows up as a double
        -- count rather than passing quietly.
        if engineName then engineKey(engineName, true) end
        frame(16)
        keys[vk] = nil
        if engineName then engineKey(engineName, false) end
        frame(16)
    end

    local heard = 0
    BR.Keys.on('trail', function(p) if p then heard = heard + 1 end end)

    -- TURN IT ON FIRST, because a drop now starts with the trail OFF and this
    -- whole block was written when it started on. Everything below is about
    -- what a PRESS does; it needs the trail lit to have something to toggle off.
    --
    -- Counted deliberately outside `heard`, which is reset immediately after, so
    -- the "fires exactly once" assertion still measures one press and not two.
    press(0x42, 'B')
    heard = 0

    local litUp = BR.Cosmetics.trailOn
    press(0x42, 'B')
    ok(heard == 1,
        'THE TRAIL KEY FIRES ITS ACTION, EXACTLY ONCE -- #131',
        ('the action fired %d times for one press'):format(heard))
    ok(BR.Cosmetics.trailOn == (not litUp),
        'and it reaches BR.Cosmetics.trailOn, which is what the drop paints from',
        ('on %s -> %s'):format(tostring(litUp), tostring(BR.Cosmetics.trailOn)))
    ok(smoke.allowed == false,
        'and the engine is actually told to stop leaving smoke',
        ('the native was told %s'):format(tostring(smoke.allowed)))

    -- Cleared first: the stub only records when the native is CALLED, so a
    -- stale `true` from an earlier frame would read as an emission that is no
    -- longer happening. Absence is the thing being asserted here.
    smoke.held = nil
    frame(16)
    ok(smoke.held ~= true,
        'and stops PRESSING the smoke control, which is what actually emits',
        ('held %s'):format(tostring(smoke.held)))

    press(0x42, 'B')
    ok(BR.Cosmetics.trailOn == true and smoke.allowed == true,
        'and pressing it again gives the trail back',
        ('on %s allowed %s'):format(tostring(BR.Cosmetics.trailOn),
                                    tostring(smoke.allowed)))
    ok(smoke.rgb ~= nil, 'in the colour that was bought')

    -- THE ASSERTION THAT WOULD HAVE CAUGHT #131 ON DAY ONE.
    --
    -- Permission is not emission. Every earlier assertion in this block checks
    -- `smoke.allowed`, and `allowed` was true on the owner's machine through
    -- four rounds while nothing rendered -- because the smoke trail is a HELD
    -- CONTROL (INPUT_PARACHUTE_SMOKE, 154, default X) and the codebase never
    -- pressed it. `brdropdbg` faithfully reported `on true`, the suite
    -- faithfully reported `allowed == true`, and both were describing a
    -- permission nobody was exercising.
    --
    -- So: assert the PRESS, every frame, under canopy. This fails on any build
    -- that grants the right without asserting the control -- which is every
    -- build this project shipped before 2026-08-16.
    smoke.held = nil
    frame(16)
    ok(smoke.held == true,
        'and under canopy the smoke control is actually HELD, not merely allowed',
        ('allowed %s held %s'):format(tostring(smoke.allowed),
                                      tostring(smoke.held)))

    -- ON THE OWNER'S OWN KEY, AND NOT ONLY ON THE DEFAULT.
    --
    -- He plays this on H. H is not in keybinds.lua's DEFAULT_VK table and never
    -- can be -- it is reached only through the KVP the rebinder writes -- so a
    -- toggle proved on B and never on a rebound key is a toggle that passes here
    -- and is dead on his machine. That is the exact shape of #129's third round:
    -- the prompt said R, the engine was listening on E, and the rebound key was
    -- being watched for by nobody.
    BR.Keys.set('brtrail', 0x48)   -- H
    fire('br:keys:changed')
    frame(16)
    ok(BR.Native.keyLabelForCommand('brtrail') == 'H',
        'the cap follows a rebind to H, which is what the owner reports seeing',
        tostring(BR.Native.keyLabelForCommand('brtrail')))

    heard = 0
    local onH = BR.Cosmetics.trailOn
    -- No engine name: RegisterKeyMapping registered B and nothing can move it,
    -- so H exists for the raw layer alone. That asymmetry IS the test.
    press(0x48, nil)
    ok(heard == 1,
        'AND THE REBOUND KEY FIRES IT TOO -- the owner presses H, not B (#131)',
        ('the action fired %d times for one press of H'):format(heard))
    ok(BR.Cosmetics.trailOn == (not onH) and smoke.allowed == (not onH),
        'and H reaches the engine flag by exactly the road B does',
        ('on %s -> %s allowed %s'):format(tostring(onH),
            tostring(BR.Cosmetics.trailOn), tostring(smoke.allowed)))

    -- And the key it was moved OFF is dead, or a rebind that looks like it
    -- worked has quietly left the action on two keys.
    heard = 0
    press(0x42, 'B')
    ok(heard == 0,
        'while the key it was rebound away from no longer fires it',
        ('B fired the action %d times after the move to H'):format(heard))

    BR.Keys.set('brtrail', 0x42)
    fire('br:keys:changed')
    frame(16)

    -- AND THE READOUT COUNTED ALL OF IT. This is the number the owner will be
    -- asked to paste, so it has to be true: three presses landed on the listener
    -- (B, B, H -- the fourth, on the key H was rebound away from, correctly did
    -- not) and showTrail carried out every one. A readout that under-reports is
    -- worse than none, because it would send the next round of this issue after
    -- the binding when the binding is fine.
    logged = {}
    pcall(commands['brdropdbg'], nil, {}, '')
    local dbg = table.concat(logged, '\n')
    -- FOUR, NOT THREE: a drop now starts with the trail OFF, so this block
    -- opens with one extra press to light it before testing what a press does.
    -- The count is of presses that REACHED THE TOGGLE, which is the fact worth
    -- pinning -- a readout that under-reports would send the next round of this
    -- issue after the binding when the binding is fine.
    ok(dbg:find('trail key: presses 4', 1, true) ~= nil,
        'the readout counts the presses that actually reached the toggle',
        dbg:match('trail key:[^\n]*') or 'no trail key line')
    ok(dbg:find('acted 4', 1, true) ~= nil,
        'and how many of them the toggle carried out',
        dbg:match('trail key:[^\n]*') or 'no trail key line')

    -- The key does what the box says it does.
    local wasOn = BR.Cosmetics.trailOn
    fire('br:keys:changed')
    BR.Cosmetics.showTrail(not wasOn)
    ok(BR.Cosmetics.trailOn == (not wasOn) and smoke.allowed == (not wasOn),
        'and the toggle withdraws the smoke rather than re-deciding its colour')
    BR.Cosmetics.showTrail(true)
    ok(smoke.rgb ~= nil, 'coming back in the colour that was bought')

    -- Landed: the box goes away and stays away.
    dui.sends = {}
    ped.state, ped.onFoot, ped.agl, ped.falling = CS.NONE, true, 0.0, false
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    frame(16)
    local gone = lastSend()
    ok(gone and gone.show == false, 'and the match ending takes the box down',
        gone and tostring(gone.show) or 'nothing was sent')
end

describe('nobody is offered a key for a trail they do not have')
do
    -- The owner's own rule for this issue: "somebody with nothing equipped
    -- should see no prompt at all rather than a prompt for a thing they do not
    -- have". Which makes an ABSENT prompt correct in one case and the bug in
    -- another, and those two are indistinguishable from a chair -- the whole
    -- reason /brdropdbg prints the readings it does.
    local threads = {}
    Citizen.CreateThread = function(fn) threads[#threads + 1] = fn end

    local sends = {}
    BR.Dui.send = function(_, msg) sends[#sends + 1] = msg end

    local function drop(id, squadColour)
        BR.State.roster[1] = { squadId = squadColour and 'sq1' or nil,
                               colour = squadColour }
        fire(BR.Net.MARKET_STATE, { equipped = { trail = id } })
        local before = #threads
        fire('br:drop:begin', { heading = 0.0 })
        for i = before + 1, #threads do threads[i]() end
    end

    -- THE FREE DEFAULT PAINTS NOTHING, and `trail_none` is what it is called
    -- since the owner removed the squad colour from the catalogue. A slot test
    -- would have offered a prompt anyway, which is the bug this describe() is
    -- named after.
    ok(BR.Config.MarketIndex['trail_squad'] == nil,
        'the Squad Colour item is gone from the catalogue',
        'trail_squad still resolves')
    ok(BR.Config.defaultItem('trail') ~= nil
       and BR.Config.defaultItem('trail').id == 'trail_none',
        'and the trail slot still has a default to un-equip back to',
        tostring(BR.Config.defaultItem('trail') and BR.Config.defaultItem('trail').id))

    drop('trail_none', nil)
    ok(BR.Cosmetics.trailArmed == false,
        'the default item paints nothing on a solo drop',
        ('armed %s'):format(tostring(BR.Cosmetics.trailArmed)))

    sends = {}
    GetPedParachuteState = function() return BR.Native.ChuteState.OPEN end
    IsPedOnFoot = function() return false end
    frame(16)
    local last = sends[#sends]
    ok(last == nil or last.show == false,
        'and no trail prompt is offered under the canopy',
        last and tostring(last.label) or 'nothing sent')

    -- AND IT PAINTS NOTHING IN A SQUAD EITHER, WHICH IS THE INSTRUCTION (owner,
    -- 2026-08-20: "'Squad color' trails should not be a thing"). This case used
    -- to assert the opposite -- the same item painting the squad's colour -- so
    -- it is the one line that proves the fallback went with the item rather than
    -- surviving it unnamed, which would have left every unspent player flying a
    -- squad colour with nothing in the storefront to turn it off.
    drop('trail_none', '#3B9BFF')
    ok(BR.Cosmetics.trailArmed == false,
        'and nothing paints in a squad either -- there is no squad colour left',
        ('armed %s'):format(tostring(BR.Cosmetics.trailArmed)))

    -- THE BOX IS ONLY TOLD WHEN THE PROMPT CHANGES, so "nothing was sent" would
    -- otherwise mean "nothing changed since the case above" rather than "nothing
    -- is offered" -- and that is the difference this whole describe() is about.
    -- br:keys:changed clears the cached kind, which is the codebase's own way of
    -- forcing one re-send, so the next frame states the answer from scratch.
    fire('br:keys:changed')
    sends = {}
    frame(16)
    local squadded = sends[#sends]
    ok(squadded == nil or squadded.show == false,
        'so a squadded player who has bought nothing is offered no key either',
        squadded and tostring(squadded.label) or 'nothing sent')

    -- A BOUGHT TRAIL STILL FLIES IN A SQUAD, which is what #131 asked for and
    -- is now the only thing that flies at all.
    drop('trail_ember', '#3B9BFF')
    ok(BR.Cosmetics.trailArmed == true,
        'and a bought trail flies in a squad -- the player earned that trail',
        ('armed %s'):format(tostring(BR.Cosmetics.trailArmed)))

    -- A CLEARED BINDING DRAWS NOTHING, because the cap would be empty and the
    -- sentence would be an instruction to press nothing.
    BR.Keys.set('brtrail', false)
    fire('br:keys:changed')
    sends = {}
    frame(16)
    local none = sends[#sends]
    ok(none == nil or none.show == false,
        'a cleared trail binding draws no box rather than an empty cap',
        none and tostring(none.key) or 'nothing sent')
    BR.Keys.reset('brtrail')
    fire('br:keys:changed')
end

describe('the drop readout answers the four questions it was written for')
do
    -- /brdropdbg is what the owner is asked to paste when the prompt does not
    -- appear, and it is the ONLY instrument for this issue. A readout that
    -- throws, or that has been renamed out from under the instructions, is
    -- worse than none -- see #137, where `brdrop` was two commands and the
    -- loser never ran.
    ok(commands['brdrop'] == nil or commands['brdropdbg'] ~= nil,
        'the debug dump is not sitting on the drop-item keybind (#137)')
    logged = {}
    ok(pcall(commands['brdropdbg'], nil, {}, ''), '/brdropdbg does not throw')
    local said = table.concat(logged, '\n')
    ok(said:find('trail: armed', 1, true) ~= nil,
        'and prints the trail line the issue asks for', said)
    -- 'source' IS NOT IN THIS LIST ANY MORE. It said which of the purchase and
    -- the squad colour was painted, and the squad colour is gone (owner,
    -- 2026-08-20), so it could only ever have printed 'purchase' -- `armed` in a
    -- second spelling, in a readout whose whole job is that each column answers
    -- something different.
    for _, word in ipairs({ 'armed', 'on ', 'key ' }) do
        ok(said:find(word, 1, true) ~= nil,
            ('the readout carries "%s"'):format(word), said)
    end
    -- AND THE HALF THAT WAS MISSING: whether the decision reached the screen.
    -- "armed true, key B" and no box on screen was an unanswerable report.
    ok(said:find('prompt: saying', 1, true) ~= nil,
        'and says whether the box was drawn, as text, or not at all', said)
    ok(said:find('loop: skydive.prompt', 1, true) ~= nil,
        'and whether the callback that draws it is still running', said)
    -- AND WHAT THE KEY DID, which is what the fifth round of this issue turns on
    -- (#131). "The prompt draws perfectly but does not do anything" is a report
    -- the previous readout could not answer from a single paste: it said what
    -- the trail WAS and never whether a press had reached the code at all.
    ok(said:find('trail key: presses', 1, true) ~= nil,
        'and how many presses reached the toggle, and how many were carried out',
        said)
    ok(said:find('acted', 1, true) ~= nil,
        'so a dead key and an engine that ignores the flag are told apart', said)
end

-- ------------------------------------------------------------- the bus ---
--
-- #174, AND IT IS THE DESCENT PROMPT'S PROBLEM ONE PHASE EARLIER.
--
-- The owner asked for "our key layer and a DUI" on the jump prompt. What was
-- there was GTA's help box naming `~INPUT_PARACHUTE_DEPLOY~`, plus a
-- frame-polled `IsControlJustPressed(0, 144)` sitting in PARALLEL with the
-- BR.Keys listener that was already there -- so the jump was on two readers at
-- once, only one of which a player could move.
--
-- THAT SHAPE IS WHY THIS BLOCK DRIVES A KEYBOARD RATHER THAN CALLING tryJump.
-- Every failure this subsystem can have is a failure of ROUTING: the box naming
-- one key while another is listened for (#129's third round, #131), one press
-- producing two server events, a rebind that adds a key instead of moving it.
-- None of those are visible to a test that calls the handler directly, and all
-- of them are visible to a test that presses a key and counts what left the
-- client. So the press below runs the whole chain -- raw sample, fire('deploy'),
-- bus.lua's listener, tryJump, TriggerServerEvent -- with nothing stubbed except
-- the natives at the far end.
--
-- WHAT IT CANNOT DO is prove a browser drew the texture. Whether the plate is
-- legible over a Titan's wing at 500m is a playtest fact and is called out as
-- one in the issue.

describe('the bus jump prompt is ours, and so is the key -- #174')
do
    local threads = {}
    Citizen.CreateThread = function(fn) threads[#threads + 1] = fn end
    Citizen.SetTimeout   = function() end

    for _, n in ipairs({
        'StartGpsCustomRoute', 'AddPointToGpsCustomRoute',
        'SetGpsCustomRouteRender', 'ClearGpsCustomRoute', 'SetVehicleEngineOn',
        'SetPedIntoVehicle', 'SetBlockingOfNonTemporaryEvents',
        'AttachEntityToEntity', 'DetachEntity', 'SetCamActive',
        'RenderScriptCams', 'DestroyCam', 'SetCamCoord', 'PointCamAtCoord',
        'ControlLandingGear', 'SetEntityInvincible', 'SetEntityVisible',
    }) do _G[n] = noop end
    function CreateVehicle() return 258 end
    function CreatePed() return 259 end
    function CreateCamWithParams() return 7 end
    function GetFrameTime() return 0.016 end
    function GetControlNormal() return 0.0 end

    --- GTA'S OWN CONTROLS, MODELLED RATHER THAN LEFT NIL -- AND THIS IS THE
    --- LINE THE REVERT PROOF FOR THIS BLOCK STANDS ON.
    ---
    --- `IsControlJustPressed` is stubbed nowhere else in this file, because
    --- until #174 the only caller in br_core/client was the very poll this
    --- issue removed. Leave it nil and reverting the fix does not reinstate the
    --- bug -- it makes the callback RAISE, and BR.Loop.step pcalls every
    --- callback and suspends one that throws three times running. The old
    --- prompt would then draw nothing and the old poll would jump nothing, and
    --- a suite measuring the fix would come back green against the broken code
    --- for reasons that have nothing to do with the fix. Measured: without this
    --- stub the reverted file fails 14 assertions; with it, 17, and the three
    --- extra are the ones that actually name the fault.
    ---
    --- Control 144 IS_PARACHUTE_DEPLOY sits on Space and NOTHING can move it --
    --- not our rebinder, not anything from script, which is the whole reason a
    --- rebind could never be reconciled with a second reader. So a physical
    --- Space is a 144 edge whatever `deploy` has since been bound to.
    local engineControl = {}
    function IsControlJustPressed(_, control) return engineControl[control] == true end

    -- THE PAGE, AS THE PROMPT USES IT, AND KEYED BY WHICH PAGE. skydive.lua's
    -- box is loaded and running in this same process from the block above, and
    -- it writes to `descentprompt`. Recording every send regardless of page
    -- would let one file's payload be read as the other's -- which is precisely
    -- the confusion bus.lua refuses to risk by not sharing a browser.
    -- ...AND A BROWSER THAT TAKES TIME TO START, WHICH IS #174's SECOND ROUND
    -- AND THE ONE THING THIS STUB PREVIOUSLY ASSUMED AWAY.
    --
    -- `ready` returned `dui.up`, true from the very first frame -- so the suite
    -- measured a CEF instance that was up the instant it was asked for, which is
    -- the one thing a CEF instance never is. dui.lua's own note: a message sent
    -- to a browser that has not finished starting "is simply lost", and
    -- IsDuiAvailable is false until it answers. The suite therefore passed
    -- 386/386 against a prompt that, on a real client, showed the player nothing
    -- but the help-box fallback for the whole of the window they had.
    --
    -- MODELLED AS A DELAY FROM CREATION, because creation time is the only
    -- variable the caller gets a vote in: ask at warmup and the beat is spent in
    -- the lobby, ask at the doors and it is spent inside the jump window. 900ms
    -- is deliberately a fraction of the window and still longer than the gap
    -- between the doors opening and a playtester pressing the key.
    local CEF_MS = 900
    local dui = { sends = {}, draws = 0, up = true, at = nil, createdAt = nil }
    BR.Dui = {
        page = function(name)
            if name == 'busprompt' and not dui.createdAt then
                dui.createdAt = GetGameTimer()
            end
            return { name = name }
        end,
        send = function(page, msg)
            if page and page.name == 'busprompt' then
                dui.sends[#dui.sends + 1] = msg
            end
        end,
        drawScreen = function(page, x, y, s)
            if page and page.name == 'busprompt' then
                dui.draws = dui.draws + 1
                dui.at = { x = x, y = y, scale = s }
            end
        end,
        drawWorld = noop, drawOnEntity = noop,
        -- Only this file's page is modelled. skydive.lua is loaded and running
        -- in this same process and warms its own browser on the same edge; its
        -- readiness is that block's business, not this one's.
        ready = function(page)
            if not page or page.name ~= 'busprompt' then return true end
            if not dui.up then return false end   -- the forced-down case, #11
            return dui.createdAt ~= nil
               and (GetGameTimer() - dui.createdAt) >= CEF_MS
        end,
    }
    local function said() return dui.sends[#dui.sends] end

    -- The engine's help box, in both its forms: the per-frame fallback and the
    -- one-shot with the beep.
    local helpFrame, helpFrames, beeps = nil, 0, {}
    BR.Native.helpThisFrame = function(t) helpFrame = t; helpFrames = helpFrames + 1 end
    BR.Native.help = function(t) beeps[#beeps + 1] = t end

    loadAll({ 'br_core/client/bus.lua' })

    bootOn(true, true)   -- the raw key layer, on the build everyone plays

    --- A press, delivered to BOTH readers exactly as a real client delivers it.
    ---
    --- The engine's own command handler is invoked alongside the raw sample --
    --- so a regression that lets both paths act shows up as a DOUBLE COUNT
    --- rather than passing quietly. That is not hypothetical here: it is what
    --- the removed control-144 poll did on every jump.
    local function press(vk, engineName)
        keys[vk] = true; edge[vk] = true
        if engineName then engineKey(engineName, true) end
        -- ...and the third reader, the engine control, which is on Space and
        -- stays on Space. See the IsControlJustPressed note above.
        engineControl[144] = (vk == 0x20) or nil
        frame(16)
        engineControl[144] = nil
        keys[vk] = nil
        if engineName then engineKey(engineName, false) end
        frame(16)
    end

    local function jumps()
        local n = 0
        for _, s in ipairs(sent) do
            if s.name == BR.Net.BUS_JUMP then n = n + 1 end
        end
        return n
    end

    --- Put this client in the plane door, doors shut, with a live route.
    local function board()
        local t = GetGameTimer()
        local pts = {}
        for i = 0, 8 do
            pts[#pts + 1] = { x = i * 400.0, y = 0.0, z = 500.0,
                              t = t + i * 500 }
        end
        fire(BR.Net.BUS_ROUTE, {
            points = pts, timed = true, heading = 0.0,
            sx = 0.0, sy = 0.0, alt = 500.0, legs = { 'a', 'b' },
            tStart = t, rotateAt = t,
            jumpFrom = t + 300, doorsClose = t + 2000, tEnd = t + 4000,
        })
        BR.State.match = { state = BR.MatchState.BUS }
        BR.State.me.state = BR.PlayerState.BUS
        local before = #threads
        BR.Loop.step(BR.Loop.TICK)
        for i = before + 1, #threads do threads[i]() end
    end

    -- 0. THE BROWSER IS ASKED FOR AT WARMUP, NOT AT THE DOORS -- #174, REOPENED
    --    BY PLAYTEST: "why are we still using natives to draw the jump text".
    --
    --    It was our box all along; what the owner saw was this file's OWN help-
    --    box fallback, because the browser was created on the first frame of the
    --    jump window and IsDuiAvailable is false for a beat after CreateDui. The
    --    beat therefore landed inside the only seconds the prompt exists for --
    --    and the owner's own observation is the proof: the descent prompt right
    --    after the jump rendered perfectly, because skydive.lua warms the very
    --    same document on the WARMUP/BUS edge and it had the whole flight to
    --    come up. Same page, same size, different creation time.
    --
    --    Asserted on the STATE broadcast rather than on a frame count, because
    --    "early enough" is not a number this suite can own -- what it can own is
    --    that the ask happens on the same edge the working prompt uses.
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    ok(dui.createdAt ~= nil,
        'the jump prompt\'s browser is asked for at WARMUP, not at the doors',
        'nothing asked BR.Dui.page for `busprompt` on the warmup state -- so the '
            .. 'browser starts inside the jump window')

    -- The lobby, measured in the only unit that matters to a browser: time to
    -- start. Shorter than a real warmup by two orders of magnitude and still
    -- twice the modelled startup.
    frames(120, 16)

    -- Counted from BEFORE the doors, so a fallback frame at the START of the
    -- window is caught. The existing help-box assertion below resets this
    -- counter after the window has already been open for 24 frames, which is
    -- exactly the blind spot the reopened issue lived in.
    helpFrame, helpFrames = nil, 0

    board()
    sent = {}

    -- 1. THE DOORS ARE SHUT AND THERE IS NO BOX. The prompt is bounded by
    --    `jumpFrom`, and a DUI holds whatever it was last told -- so "nothing
    --    sent, nothing drawn" is the only honest state before the window.
    dui.sends, dui.draws = {}, 0
    frame(16)
    ok(#dui.sends == 0 and dui.draws == 0,
        'nothing is drawn before the doors open',
        ('%d sends, %d draws'):format(#dui.sends, dui.draws))

    -- 2. THE WINDOW OPENS: OUR BOX, OUR KEY.
    frames(24, 16)
    local open = said()
    ok(open and open.show == true and open.label == 'Jump from the plane',
        'the doors-open box is a DUI payload, not a help string',
        open and tostring(open.label) or 'nothing was sent to the page at all')
    ok(dui.draws > 0, 'and it is actually drawn', ('draws %d'):format(dui.draws))
    -- THE ASSERTION THE SHIPPED CODE CANNOT PASS, and the one the owner is
    -- reporting. Not "a DUI eventually appeared" -- "the player never saw the
    -- engine draw this prompt", counted from the frame the doors opened.
    ok(helpFrames == 0,
        'and the box covers the window from its FIRST frame -- the player never '
            .. 'sees the native fallback while the browser starts (#174)',
        ('the engine help box drew this prompt on %d frames of the window; '
            .. 'last was %s'):format(helpFrames, tostring(helpFrame)))
    ok(open and open.key == 'Space',
        'naming the key `deploy` is actually bound to, read from BR.Keys',
        open and tostring(open.key) or 'nil')

    -- 3. AND THE HELP BOX IS NOT ALSO RUNNING. This is the assertion the old
    --    code cannot pass: it called helpThisFrame EVERY frame of the window,
    --    with `~INPUT_PARACHUTE_DEPLOY~` in it. A DUI that draws while the
    --    scaleform also draws is two prompts, and the second one is the liar.
    helpFrame, helpFrames = nil, 0
    frames(3, 16)
    ok(helpFrames == 0,
        'and GTA\'s help box is not drawing the prompt alongside it',
        ('the scaleform was asked %d times: %s'):format(helpFrames,
            tostring(helpFrame)))

    -- 4. NO ENGINE GLYPH TOKEN ANYWHERE. `~INPUT_PARACHUTE_DEPLOY~` renders
    --    control 144's key, which after this change is a key nothing aboard the
    --    plane is listening for. Asserted as a string search because that is
    --    how it would come back -- somebody restoring "just the wording".
    local anyToken = false
    for _, m in ipairs(dui.sends) do
        for _, v in pairs(m) do
            if type(v) == 'string' and v:find('~INPUT', 1, true) then
                anyToken = true
            end
        end
    end
    ok(not anyToken,
        'and no payload carries an ~INPUT_~ token -- the engine draws none of this')

    -- 5. THE BOX SITS WHERE THE DESCENT BOX SITS. The two are one box to a
    --    player: press here, fall out, and the same plate offers the glider.
    local D = BR.Config.Drop
    ok(dui.at and dui.at.x == D.promptX and dui.at.y == D.promptY
        and dui.at.scale == D.promptScale,
        'in the same place and at the same scale as the descent prompt',
        dui.at and ('%s,%s @%s'):format(tostring(dui.at.x), tostring(dui.at.y),
            tostring(dui.at.scale)) or 'never drawn')

    -- 6. ONE PRESS, ONE BUS_JUMP.
    --
    --    THE NUMBER THAT BITES. With the control-144 poll in place both readers
    --    saw the same physical Space in the same frame and `riding` was still
    --    true between them, so every jump sent TWO BUS_JUMP events. Counting
    --    what left the client is the only way to see that at all -- both paths
    --    call the same tryJump, so any test that asserts "the jump happened"
    --    passes on the broken code.
    sent = {}
    press(0x20, 'SPACE')
    ok(jumps() == 1,
        'ONE PRESS SENDS EXACTLY ONE BUS_JUMP -- not one per reader (#174)',
        ('%d BUS_JUMP events left the client for one press of Space'):format(jumps()))

    -- 7. THE REBIND MOVES THE LABEL **AND** THE LISTENER, TOGETHER.
    --
    --    Twice now this project has shipped a prompt naming a key nothing was
    --    listening for -- #131 drew a key the code did not read, and #129's
    --    third round drew R while the engine listened on E. Both halves are
    --    asserted from one rebind, in one place, so they cannot pass apart.
    BR.Keys.set('brdeploy', 0x4A)   -- J
    frame(16)
    local moved = said()
    ok(moved and moved.key == 'J',
        'a rebind moves the letter in the cap',
        moved and tostring(moved.key) or 'nothing was re-sent after the rebind')

    sent = {}
    press(0x4A, nil)   -- no engine name: RegisterKeyMapping registered SPACE
                       -- and nothing can move it, so J is the raw layer's alone
    ok(jumps() == 1,
        'AND THE KEY IN THE CAP IS THE KEY THAT JUMPS',
        ('J sent %d BUS_JUMP events'):format(jumps()))

    -- 8. AND THE KEY IT WAS MOVED OFF IS DEAD. A rebind that ADDS a key rather
    --    than moving it is what the control-144 poll made every rebind do:
    --    Space kept jumping forever, whatever the settings screen said.
    sent = {}
    press(0x20, 'SPACE')
    ok(jumps() == 0,
        'while the key it was rebound AWAY from no longer jumps at all',
        ('Space still sent %d BUS_JUMP events after the move to J'):format(jumps()))

    BR.Keys.reset('brdeploy')
    frame(16)
    ok(said() and said().key == 'Space', 'and a reset puts the cap back',
        said() and tostring(said().key) or 'nothing re-sent')

    -- 9. A SCREEN THAT OWNS THE KEYBOARD OWNS THIS KEY TOO (62491d6). The jump
    --    is a `tap()` like every other action, so it inherits the NUI focus
    --    gate -- asserted rather than assumed, because "inherits it" is exactly
    --    the kind of claim this file exists to stop taking on trust.
    sent = {}
    fire('br:ui:focusChanged', 'players')
    press(0x20, 'SPACE')
    ok(jumps() == 0,
        'typing under a NUI screen does not throw the player out of the plane',
        ('%d BUS_JUMP events were sent while a screen held the keyboard'):format(jumps()))

    fire('br:ui:focusChanged', 'none')
    frames(3, 16)   -- the resync window closes on the first quiet frame
    sent = {}
    press(0x20, 'SPACE')
    ok(jumps() == 1,
        'and the key comes straight back when the screen lets go',
        ('%d BUS_JUMP events after focus was released'):format(jumps()))

    -- 10. THE DOORS CLOSING IS A SECOND STATE AND IT SURVIVED THE MOVE. The
    --     help box had two strings; so does the page, and the beep still beeps.
    dui.sends, beeps = {}, {}
    frames(110, 16)          -- past doorsClose: the box is a FRAME callback...
    BR.Loop.step(BR.Loop.TICK)   -- ...and the beep is a TICK one. Both bands
                                 -- have to be stepped or the "it still beeps"
                                 -- assertion below is testing the harness.
    local closing = said()
    ok(closing and closing.show == true and closing.label == 'Doors closing!',
        'the box hardens into the last call',
        closing and tostring(closing.label) or 'nothing was re-sent')
    ok(closing and closing.key == 'Space',
        'still naming the player\'s own key', closing and tostring(closing.key))
    ok(#beeps == 1,
        'and the one-shot beep still fires, exactly once',
        ('%d beeps'):format(#beeps))

    -- 11. A BROWSER THAT NEVER CAME UP MUST NOT MEAN SILENCE, and here that
    --     costs the whole match rather than a cosmetic: a player who cannot see
    --     the prompt does not jump. The words fall back; the glyph is what is
    --     lost, and the letter is STILL the player's own binding.
    dui.up = false
    helpFrame = nil
    frame(16)
    ok(helpFrame ~= nil and helpFrame:find('Space', 1, true) ~= nil,
        'a page that is not up falls back to words naming the bound key',
        tostring(helpFrame))
    ok(helpFrame ~= nil and helpFrame:find('~INPUT', 1, true) == nil,
        'and never to an ~INPUT_~ token, which renders as a hole for our commands',
        tostring(helpFrame))
    dui.up = true

    -- 12. AN UNBOUND JUMP SAYS SO. `BR.Keys.set` clears the LOSER of a key
    --     conflict, so a player can lose the jump binding without ever having
    --     touched that row -- and the trail prompt's answer (draw nothing) would
    --     read as the prompt being broken for the one action you cannot skip.
    BR.Keys.set('brdeploy', nil)
    frame(16)
    local unbound = said()
    ok(unbound and unbound.show == true and unbound.label == 'Jump is unbound'
        and unbound.key == nil,
        'a cleared jump binding says so rather than drawing an empty cap',
        unbound and ('label %s key %s'):format(tostring(unbound.label),
            tostring(unbound.key)) or 'nothing sent')
    BR.Keys.reset('brdeploy')
    frame(16)

    -- 13. /brbus IS THE ONLY INSTRUMENT THIS SUBSYSTEM HAS, and it used to
    --     RAISE: it formatted `#crumbs`, a local that exists nowhere in the
    --     file, so the command a playtester is asked to paste died on its own
    --     third line. It now answers the two questions that are actually asked
    --     -- was there a box, and what key did it name.
    logged = {}
    ok(pcall(commands['brbus'], nil, {}, ''), '/brbus does not throw',
        table.concat(logged, '\n'))
    local dump = table.concat(logged, '\n')
    ok(dump:find('prompt', 1, true) ~= nil and dump:find('key ', 1, true) ~= nil,
        'and reports whether the box is showing and which key it names', dump)
    ok(dump:find('Space', 1, true) ~= nil,
        'reading the same BR.Keys answer the box prints, so it cannot agree '
            .. 'with a lie the box is telling', dump)
    -- AND THE ONE LINE THAT SEPARATES "LATE" FROM "NEVER". `sends`/`draws`/
    -- `fallbacks` are lifetime totals -- a `draws` earned two matches ago reads
    -- exactly like a browser that came up on this flight -- so they cannot tell
    -- a browser that started slowly from a third CEF instance that is never
    -- granted at all. Those two faults have opposite fixes, and this is the line
    -- a playtester pastes to choose between them.
    ok(dump:find('browser ', 1, true) ~= nil,
        'and says whether the browser came up, and how long it took', dump)
    ok(dump:find('browser ready ', 1, true) ~= nil
        and dump:find('NEVER READY', 1, true) == nil,
        'reporting a warmed browser as ready rather than as never having come up',
        dump)
    logged = {}

    -- 14. THE RIDE ENDING TAKES THE BOX DOWN. A DUI holds its last content
    --     forever; the help box expired on its own. Without the explicit
    --     take-down a match torn down mid-flight leaves "Jump from the plane"
    --     hanging over the lobby.
    dui.sends = {}
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.Loop.step(BR.Loop.TICK)
    frame(16)
    local gone = said()
    ok(gone and gone.show == false, 'and leaving the plane takes the box away',
        gone and tostring(gone.show) or 'nothing was sent')

    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    BR.Loop.step(BR.Loop.TICK)
    sent = {}
end

describe('an inventory starts and returns to fists, not to slot 1 -- #155')
do
    -- Owner, 2026-08-16: "The default inventory slot should be fists, not slot
    -- 1." Slot 0 is the fist slot (BR.Config.Loot.meleeSlot) -- selectable,
    -- never fillable -- and landing with a weapon nobody drew takes the player's
    -- first action for them.
    --
    -- THE MIRROR'S HALF ONLY. The server owns the active slot and its default
    -- now lives in exactly one function, newInv(); tools/test_roster.lua asserts
    -- that end, including the pickup rule that has to keep working around it.
    -- What is proved here is the two client-side values #155 names: the one the
    -- mirror holds before any INV_SET arrives -- a fresh join, and every
    -- `restart br_core`, where the server keeps the real inventory and this file
    -- is rebuilt from nothing -- and the one it goes back to at teardown.
    local MELEE = BR.Config.Loot.meleeSlot or 0

    fire(BR.Net.INV_SET, {
        slots = {}, ammo = {}, active = 1,
    })
    ok(BR.Inv.local_().active == 1,
        'a slot the server chose is still mirrored faithfully',
        ('active %s'):format(tostring(BR.Inv.local_().active)))

    -- Teardown: WAITING, ENDED and CLEANUP all reach clearLocal(), which is the
    -- death and match-reset path.
    fire(BR.Net.STATE, { state = BR.MatchState.ENDED })
    ok(BR.Inv.local_().active == MELEE,
        'A MATCH TEARDOWN PUTS THE HAND BACK TO FISTS, NOT TO SLOT 1 -- #155',
        ('active %s'):format(tostring(BR.Inv.local_().active)))

    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = 1 })
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    ok(BR.Inv.local_().active == MELEE,
        'and so does a match dropping back to WAITING',
        ('active %s'):format(tostring(BR.Inv.local_().active)))

    -- AN INV_SET THAT NAMES NO SLOT IS AN EMPTY HAND. The mirror reads
    -- `d.active or MELEE_SLOT`, and this is the assertion that keeps the `or`
    -- honest in both directions: absent must mean fists...
    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = 1 })
    fire(BR.Net.INV_SET, { slots = {}, ammo = {} })
    ok(BR.Inv.local_().active == MELEE,
        'an inventory that names no active slot is fists, not slot 1',
        ('active %s'):format(tostring(BR.Inv.local_().active)))

    -- ...and an explicit 0 must survive the wire as a real answer rather than
    -- being read as absence. In Lua `0 or x` is 0, so this passes today; it is
    -- pinned because the same line in TypeScript needs `??` and not `||`, and
    -- the two ends have to agree about what the fist slot is.
    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = 1 })
    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = MELEE })
    ok(BR.Inv.local_().active == MELEE,
        'and an explicit slot 0 is carried as a choice, not lost as an absence',
        ('active %s'):format(tostring(BR.Inv.local_().active)))
end

describe('an unissued weapon in the hand is stripped AND reported')
do
    -- THE STRIP IS OLD AND UNCHANGED; THE REPORT IS THE NEW HALF. Both are
    -- asserted separately in every case here, because the guard that stops this
    -- accusing innocent players works by withholding one and not the other --
    -- and a suite that could only see "the tick did something" would pass with
    -- that guard deleted.
    --
    -- WHY THE STRIP EXISTS AT ALL, since it reads like anticheat and is not:
    -- the engine applies damage locally before the server sees it, so a foreign
    -- weapon lets a client kill somebody on their own screen while the server
    -- refuses the shot. The victim reads as dead and is alive. That was a live
    -- report on 2026-08-08 and taking the weapon out of the hand is what stops
    -- it happening rather than correcting it a round trip later.

    local CONJURED  = 0x11111111            -- in no table this gamemode has
    local CARBINE   = 0x83BF0278            -- WEAPON_CARBINERIFLE, issued
    local PISTOL    = 0x1B06D571            -- WEAPON_PISTOL, issued
    local UNARMED   = BR.Config.Gadgets.UNARMED
    local PARACHUTE = BR.Config.Gadgets.PARACHUTE

    local function reports()
        local out = {}
        for _, s in ipairs(sent) do
            if s.name == BR.Net.INV_STRIPPED then out[#out + 1] = s.args[1] end
        end
        return out
    end

    --- How many times ONE weapon was taken out of the hand.
    ---
    --- COUNTED BY HASH RATHER THAN BY CALL, because this suite has
    --- client/skydive.lua loaded and its own TICK callback removes the parachute
    --- through the same native. A bare call count would be measuring another
    --- file's behaviour and would have made these cases read as passing for the
    --- wrong reason.
    local function strips(hash)
        local n = 0
        for _, h in ipairs(stripped) do if h == hash then n = n + 1 end end
        return n
    end

    local function reset()
        sent, stripped = {}, {}
    end

    --- One TICK with a given weapon in the ped's hand.
    local function tickHolding(hash)
        pedWeapon = hash
        BR.Loop.step(BR.Loop.TICK)
    end

    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true

    -- A carbine in slot 1, selected. This is an ordinary armed player.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })

    -- 1. THE WEAPON THE SERVER ISSUED, IN THE HAND. Nothing happens, which is
    --    the case that has to stay silent -- it is every tick of every match.
    reset()
    tickHolding(CARBINE)
    ok(strips(CARBINE) == 0, 'the active slot\'s own weapon is not stripped',
        strips(CARBINE))
    ok(#reports() == 0, 'and nothing is reported')

    -- 2. FISTS AND THE PARACHUTE. The chute is granted by skydive.lua and
    --    removing it at 400 metres is a death, not a HUD bug.
    reset()
    tickHolding(UNARMED)
    ok(strips(UNARMED) == 0 and #reports() == 0,
        'fists are never stripped or reported')
    reset()
    tickHolding(PARACHUTE)
    ok(strips(PARACHUTE) == 0 and #reports() == 0,
        'and neither is the parachute')

    -- 3. THE CASE THIS EXISTS FOR. A weapon the gamemode has never heard of.
    reset()
    fakeTime = fakeTime + 5000
    tickHolding(CONJURED)
    ok(strips(CONJURED) == 1, 'a conjured weapon comes out of the hand',
        strips(CONJURED))
    ok(#reports() == 1, 'AND it is reported, which it never used to be',
        #reports())
    ok(reports()[1] == CONJURED, 'with the hash that was actually held',
        tostring(reports()[1]))

    -- 4. THE THROTTLE. A cheat re-granting on every tick would otherwise put ten
    --    net events a second on the wire, per offender, for as long as they kept
    --    going. The STRIP still happens every tick -- that is the gameplay fix
    --    and it must not be rate-limited.
    reset()
    tickHolding(CONJURED)
    tickHolding(CONJURED)
    tickHolding(CONJURED)
    ok(strips(CONJURED) == 3,
        'the strip itself is not throttled -- it runs every tick',
        strips(CONJURED))
    ok(#reports() == 0, 'but the report is', #reports())

    reset()
    fakeTime = fakeTime + 1000
    tickHolding(CONJURED)
    ok(#reports() == 1, 'and comes back once the window has passed', #reports())

    -- 5. THE FALSE POSITIVE THIS FEATURE COULD ACTUALLY PRODUCE, and the only
    --    one. The strip compares against the ACTIVE slot, so a weapon from
    --    another slot of the player's OWN inventory -- held for the tick between
    --    a slot change and the grant landing -- is stripped too.
    --
    --    Stripping it is harmless: applyActive puts the right weapon back on the
    --    same tick. Opening a case about it would put an innocent player in a
    --    moderation queue over a tenth of a second of tick ordering, so the
    --    report is withheld and the strip is not.
    fire(BR.Net.INV_SET, {
        slots = {
            { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 },
            { id = 'pistol',       kind = BR.ItemKind.WEAPON, clip = 12 },
        },
        ammo = {}, active = 1,
    })
    reset()
    fakeTime = fakeTime + 5000
    tickHolding(PISTOL)
    ok(strips(PISTOL) == 1,
        'a weapon from another of your own slots is still stripped',
        strips(PISTOL))
    ok(#reports() == 0,
        'but it is NOT reported -- our own code racing itself is not evidence',
        #reports())

    -- ...AND THE GUARD IS NOT SIMPLY "NEVER REPORT". The same player, the same
    -- inventory, a weapon they do not own: reported.
    reset()
    fakeTime = fakeTime + 5000
    tickHolding(CONJURED)
    ok(strips(CONJURED) == 1 and #reports() == 1,
        'while a weapon that is in none of their slots still is')

    -- 6. NOT WHILE THE HAND IS NOT OURS TO FILL. canArm() gates the whole tick
    --    body, so a corpse or a lobby ped holding something reports nothing --
    --    and, more to the point, is not stripped either, because
    --    RemoveAllPedWeapons would take a parachute with it.
    BR.State.me.state = BR.PlayerState.DEAD
    BR.State.landed = false
    reset()
    fakeTime = fakeTime + 5000
    tickHolding(CONJURED)
    ok(strips(CONJURED) == 0 and #reports() == 0,
        'a player who is not alive is neither stripped nor reported')

    -- Leave the world as this block found it.
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    pedWeapon = nil
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    BR.Loop.step(BR.Loop.TICK)
    reset()
end

describe('a vehicle\'s own mounted gun is not a conjured weapon -- #216')
do
    -- ═══ THE OWNER'S REPORT, 2026-08-22 ═══
    --
    --   "can you confirm that vehicle-related incidents will not fire as a
    --    weapons-related incident? Because that's exactly what happened here. I
    --    caused this myself and confirmed no weapons were ever involved."
    --
    -- They had stolen an armed helicopter. The engine makes a seated ped's
    -- CURRENT WEAPON the vehicle's mounted gun, `GetCurrentPedWeapon` reports
    -- that hash, and the strip check above found it was not fists, not the
    -- parachute and in no slot -- so it stripped it and filed a WEAPON case
    -- against somebody who had never held a weapon. Once a tick, because the
    -- engine hands it straight back.
    --
    -- ═══ WHAT THIS BLOCK IS ACTUALLY GUARDING, WHICH IS THE FIX AND NOT THE BUG
    --
    -- The bug is one assertion and it would pass against the one-line wrong fix
    -- ("in a vehicle? skip the check"). So the assertions below are weighted the
    -- other way: MOST of them are about the hole that fix would open, and the
    -- suite is deliberately harder to satisfy than the report was.
    --
    -- WHY AN ORDINARY CAR NEEDS NO CASE HERE, and it is worth stating because
    -- its absence looks like a gap: an ordinary car's seated ped reports
    -- UNARMED, which was always allowed. If it reported anything else, every car
    -- ride in every match since 2026-08-08 would have filed a weapon case, and
    -- none has. The armed vehicle is the whole of the difference.

    local CONJURED = 0x11111111            -- in no table this gamemode has
    local CARBINE  = 0x83BF0278            -- WEAPON_CARBINERIFLE, issued
    -- VEHICLE_WEAPON_PLAYER_BUZZARD. A real mounted-gun hash, and the point of
    -- using a real one is that it is in none of this gamemode's tables either --
    -- so it is indistinguishable from CONJURED to every check except the new one.
    local MOUNTED  = 0xE2822A29
    -- A SECOND MOUNTED GUN, so "the vehicle's own" can be told apart from "any
    -- mounted-looking hash". VEHICLE_WEAPON_PLAYER_LAZER.
    local OTHER_MOUNTED = 0x8B3428B8

    local function reports()
        local out = {}
        for _, s in ipairs(sent) do
            if s.name == BR.Net.INV_STRIPPED then out[#out + 1] = s.args[1] end
        end
        return out
    end

    local function strips(hash)
        local n = 0
        for _, h in ipairs(stripped) do if h == hash then n = n + 1 end end
        return n
    end

    --- One TICK with `held` in the hand, seated in a vehicle whose mounted gun
    --- is `mounted` (nil for a vehicle with no guns, or none the native knows).
    local function tickSeated(held, mounted)
        inVehicle, vehicle = true, 77
        vehWeapon = mounted
        pedWeapon = held
        sent, stripped = {}, {}
        fakeTime = fakeTime + 5000
        BR.Loop.step(BR.Loop.TICK)
    end

    --- The same, on foot.
    local function tickOnFoot(held, mounted)
        inVehicle, vehicle = false, 0
        vehWeapon = mounted
        pedWeapon = held
        sent, stripped = {}, {}
        fakeTime = fakeTime + 5000
        BR.Loop.step(BR.Loop.TICK)
    end

    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true

    -- A carbine in slot 1, selected: an ordinary armed player who then steals a
    -- Buzzard. This is the owner's situation exactly.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })

    -- 1. THE BUG. The vehicle's own gun, in the seat of that vehicle.
    tickSeated(MOUNTED, MOUNTED)
    ok(strips(MOUNTED) == 0,
        'the vehicle\'s own mounted gun is not taken out of the hand',
        strips(MOUNTED))
    ok(#reports() == 0,
        'and NO weapon case is filed -- the act was stealing a vehicle',
        #reports())

    -- 2. THE HOLE THE ONE-LINE FIX WOULD OPEN, AND THE REASON THIS BLOCK EXISTS.
    --    Same seat, same armed vehicle, a rifle this gamemode issues nobody.
    --    "Skip the check in a vehicle" passes case 1 and fails this.
    tickSeated(CONJURED, MOUNTED)
    ok(strips(CONJURED) == 1,
        'a CONJURED weapon in that same seat still comes out of the hand',
        strips(CONJURED))
    ok(#reports() == 1 and reports()[1] == CONJURED,
        'and is still reported, with the hash that was actually held',
        tostring(reports()[1]))

    -- 3. AND THE EXCUSE IS THE VEHICLE'S OWN GUN, NOT ANY MOUNTED-LOOKING HASH.
    --    A Lazer's cannon held in a Buzzard is not the Buzzard's minigun. Both
    --    hashes are absent from every table this gamemode has, so nothing but
    --    the equality can tell them apart.
    tickSeated(OTHER_MOUNTED, MOUNTED)
    ok(strips(OTHER_MOUNTED) == 1 and #reports() == 1,
        'a DIFFERENT vehicle\'s mounted gun is stripped and reported')

    -- 4. A VEHICLE THE NATIVE HAS NO OPINION ABOUT is not a blanket excuse.
    --    An unarmed car -- `ok == false` -- leaves the check exactly as it was.
    tickSeated(CONJURED, nil)
    ok(strips(CONJURED) == 1 and #reports() == 1,
        'a seat with no mounted gun excuses nothing')

    -- 5. ON FOOT, EVEN IF THE NATIVE ANSWERS ANYWAY. A stale or over-eager
    --    read must not reach across a ped standing in a field.
    tickOnFoot(MOUNTED, MOUNTED)
    ok(strips(MOUNTED) == 1 and #reports() == 1,
        'the same hash on foot is stripped and reported')

    -- 6. THE BOOL, IN BOTH SHAPES. `0` IS TRUTHY IN LUA and a FiveM BOOL may be
    --    `1` rather than `true`; this repo has shipped the wrong reading SIX
    --    times, and a `== true` here would have silently un-fixed the bug on
    --    every build that answers numbers.
    vehWeaponAnswersNumber = true
    tickSeated(MOUNTED, MOUNTED)
    ok(strips(MOUNTED) == 0 and #reports() == 0,
        'a build whose BOOL answers 1 rather than true is read the same way')
    vehWeaponAnswersNumber = false

    -- 7. A VEHICLE THAT ANSWERS `0` HAS NO MOUNTED GUN, and `0` must not match
    --    a hand that reads `0` either. This is the "0 is truthy in Lua" trap in
    --    its exact local form: `BR.NormHash(0)` is `0` and not nil, so a bare
    --    `m == h` would have called "this vehicle has no gun" a match for "this
    --    hand holds nothing" and excused it. Delete the `m ~= 0` guard and this
    --    is the assertion that fails.
    --
    --    (The REPORT is not asserted here: the client does send hash 0 on this
    --    path and server/strip.lua refuses it explicitly -- `n ~= 0` -- so
    --    nothing reaches a record either way. The strip is the behaviour this
    --    file decides.)
    tickSeated(0, 0)
    ok(strips(0) == 1,
        'a vehicle answering "no mounted gun" excuses nothing, hash 0 included',
        strips(0))

    -- 8. THE NATIVE SIMPLY NOT BEING ON THIS BUILD. Absent is no opinion, and
    --    no opinion is not an excuse. Restored immediately after.
    local realNative = GetCurrentPedVehicleWeapon
    GetCurrentPedVehicleWeapon = nil
    tickSeated(CONJURED, MOUNTED)
    ok(strips(CONJURED) == 1 and #reports() == 1,
        'a build without the native keeps the old behaviour rather than a hole')
    GetCurrentPedVehicleWeapon = realNative

    -- 8b. A NATIVE THAT THROWS. Same answer as one that is missing, and it is
    --     asserted separately because the two reach it down different branches.
    GetCurrentPedVehicleWeapon = function() error('no such vehicle') end
    tickSeated(CONJURED, MOUNTED)
    ok(strips(CONJURED) == 1 and #reports() == 1,
        'a native that raises is no opinion either, not an exemption')
    GetCurrentPedVehicleWeapon = realNative

    -- 8c. ═══ THE ANSWER THE ENGINE REFUSED TO GIVE IS NOT AN ANSWER ═══
    --
    --     The native says `ok == false` AND hands back a hash anyway -- a stale
    --     out-param, or a build that fills it before deciding. If the BOOL were
    --     ignored and only the hash compared, that stale value becomes an
    --     exemption for whatever it happens to name, and here it names the
    --     conjured rifle in the player's hand.
    --
    --     THIS IS THE ONLY ASSERTION THAT THE `ok` TEST HAS ANY EFFECT AT ALL.
    --     Mutation testing named it: with the BOOL dropped the suite still
    --     passed, because every other case here has the hash disagreeing too.
    tickSeated(CONJURED, { notOk = CONJURED })
    ok(strips(CONJURED) == 1 and #reports() == 1,
        'a hash the native declined to vouch for excuses nothing')

    -- 8d. AN ENGINE THAT ANSWERS AND NAMES NOTHING, on both sides at once: the
    --     hand reads nil and the vehicle reads nil. `nil == nil` is TRUE in Lua,
    --     so without the `m ~= nil` test the two nothings would have matched and
    --     excused each other. Same family as the `0` trap in case 7 and the
    --     sixth time this repo has paid for a member of it.
    --
    --     COUNTED IN CALLS RATHER THAN IN ENTRIES, because the hash being
    --     stripped IS nil and `t[#t + 1] = nil` appends nothing at all. A list
    --     length would have read 0 for a strip that happened, which is the
    --     assertion passing for the exactly wrong reason.
    inVehicle, vehicle = true, 77
    vehWeapon = false
    pedWeapon = false
    sent, stripped, stripCalls = {}, {}, 0
    fakeTime = fakeTime + 5000
    BR.Loop.step(BR.Loop.TICK)
    ok(stripCalls == 1,
        'a nil hand and a nil mounted gun do not match each other',
        stripCalls)

    -- 9. AND THE ISSUED WEAPON IS STILL THE ISSUED WEAPON IN A SEAT. The one
    --    case that is every tick of every match with a passenger in it.
    tickSeated(CARBINE, MOUNTED)
    ok(strips(CARBINE) == 0 and #reports() == 0,
        'the active slot\'s own weapon is untouched in a seat')

    -- Leave the world as this block found it.
    inVehicle, vehicle = false, 0
    vehWeapon, pedWeapon = nil, nil
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    BR.Loop.step(BR.Loop.TICK)
    sent, stripped = {}, {}
end

-- ------------------------------------------------ the downed presentation ---
--
-- FOUR THINGS THE OWNER WATCHED GO WRONG ON THE FLOOR (2026-08-17), and the
-- first coverage client/dbno.lua has ever had. Before this block it was loaded
-- by NO suite at all -- neither was client/squadmates.lua -- so the crawl, the
-- knock sequence, the revive prompt's position and the overhead names had
-- exactly the same amount of automated evidence behind them as a file that was
-- never written.
--
--   1. the labels over a downed or dead player draw at standing height
--   2. a downed player cannot stop crawling
--   3. the ped stands fully upright before snapping into the crawl
--   4. the downed camera hovers at standing height
--
-- WHAT THIS BLOCK CAN AND CANNOT SETTLE, said once here rather than hedged at
-- every assertion. It can settle ORDER, ANCHORING and CONSEQUENCE: which
-- native ran before which, what world point a label was pinned to, and whether
-- the ped had moved after sixty frames of nobody touching the keyboard. It
-- cannot settle whether any of it LOOKS right -- a camera height, an animation
-- transition and a label's clearance are judgements a person makes with their
-- eyes, and a Lua process asserting that a shot reads as "on the floor" would
-- be asserting its own opinion.
--
-- The model below is written to be able to FAIL. In particular the crawl clip
-- is modelled as a locomotion clip that MOVES THE PED BY ITSELF, because that
-- is the only mechanism that explains "there's no way to stop crawling" -- and
-- a stub that quietly held the ped still would have made the fix untestable in
-- exactly the way #129 and #131 were untestable for six rounds.

describe('the downed presentation')
do
    -- A REAL VECTOR, because dbno.lua measures reach with `#(a - b)` and a
    -- plain table cannot be subtracted. FiveM's vector3 does both, so the model
    -- does both -- otherwise nearestDowned() throws and every revive assertion
    -- below would be testing a suspended callback.
    local V = {}
    V.__index = V
    V.__sub = function(a, b)
        return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, V)
    end
    V.__len = function(a)
        return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    end
    local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end

    -- WHERE A HEAD IS, WHICH IS THE WHOLE OF FAULT 1. A ped's origin is at its
    -- feet in both postures; the HEAD moves, and by more than a metre. Anything
    -- anchored to the origin therefore cannot tell the two apart, which is
    -- precisely what the owner was looking at.
    local HEAD_STANDING = 1.65
    local HEAD_PRONE    = 0.30

    -- [pedHandle] = a body in the world.
    local bodies = {
        [1]    = { x = 0.0, y = 0.0, z = 30.0, h = 0.0, dead = false,
                   prone = false },
        [5002] = { x = 1.0, y = 0.0, z = 30.0, h = 0.0, dead = false,
                   prone = true },
    }
    local MATE = 5002

    local world = {
        ragdoll = false, air = false,
        -- The clip's own mover. See the header: a locomotion clip translates
        -- the ped whether or not anybody asked it to.
        mover   = 0.0,
        rayHit  = false,
        -- WHAT THE SHAPE TEST ANSWERS WITH. `true` rather than `1` by default,
        -- because that is the shape this project has already been bitten by
        -- twice and the one the old `hit == 1` comparison silently declined.
        hitShape = true,
    }
    local input = { lr = 0.0, ud = 0.0 }
    local look  = { [1] = 0.0, [2] = 0.0 }
    -- Forward-declared: the teleport stub below has to be able to cancel the
    -- clip, because that is what the engine does with it.
    local anim

    -- Everything the client did, in order. The ORDER is the deliverable for
    -- fault 3: a wait between the resurrection and the pose is a frame of a
    -- player standing up in front of everybody.
    local log = {}
    local function note(what, extra) log[#log + 1] = { what = what, extra = extra } end
    local function firstAt(what)
        for i, e in ipairs(log) do if e.what == what then return i end end
        return nil
    end
    local function countOf(what)
        local n = 0
        for _, e in ipairs(log) do if e.what == what then n = n + 1 end end
        return n
    end
    --- Did anything YIELD between two calls? The question fault 3 turns on.
    local function waitedBetween(a, b)
        local i, j = firstAt(a), firstAt(b)
        if not i or not j then return nil end
        for k = i + 1, j - 1 do
            if log[k].what == 'wait' then return true end
        end
        return false
    end

    -- ---------------------------------------------------------- the world ---

    function PlayerPedId() return 1 end
    function DoesEntityExist(ped) return bodies[ped] ~= nil end
    function GetEntityCoords(ped)
        local b = bodies[ped] or bodies[1]
        return vec(b.x, b.y, b.z)
    end
    function GetEntityHeading(ped) return (bodies[ped] or bodies[1]).h end
    function SetEntityHeading(ped, h) (bodies[ped] or bodies[1]).h = h end
    --- SET_ENTITY_COORDS_NO_OFFSET(entity, x, y, z, keepTasks, keepIK, doWarp).
    ---
    --- THE LAST THREE ARE NOT AXES, and modelling them as though they were is
    --- how the shipped call went unnoticed: it passed `false, false, false`,
    --- which reads as an innocent xAxis/yAxis/zAxis triple and actually means
    --- "clear this ped's tasks". The ped's task IS the crawl animation, and the
    --- crawl teleports the ped every frame -- so the clip was being destroyed
    --- and rebuilt sixty times a second and never played past its first frame.
    ---
    --- Modelled as the native documents it, which is what makes the assertion
    --- about a stable clip able to fail.
    function SetEntityCoordsNoOffset(ped, x, y, z, keepTasks)
        local b = bodies[ped] or bodies[1]
        b.x, b.y, b.z = x, y, z
        if not keepTasks then anim.playing = false end
        note('move')
    end
    function IsEntityDead(ped) return (bodies[ped] or bodies[1]).dead end
    function IsPedFatallyInjured() return false end
    function IsPedRagdoll() return world.ragdoll end
    function IsEntityInAir() return world.air end
    function GetEntityHealth() return 200 end
    function SetEntityHealth(_, hp) note('health', hp) end
    function GetFrameTime() return 0.016 end
    function GetDisabledControlNormal(_, control)
        if control == 30 then return input.lr end
        if control == 31 then return input.ud end
        return 0.0
    end
    function GetControlNormal(_, control) return look[control] or 0.0 end
    function GetActivePlayers() return {} end

    --- THE HEAD BONE, WHICH IS THE ONE THING ON A PED THAT KNOWS THE POSTURE.
    function GetPedBoneCoords(ped, _bone, _ox, _oy, _oz)
        local b = bodies[ped] or bodies[1]
        return vec(b.x, b.y, b.z + (b.prone and HEAD_PRONE or HEAD_STANDING))
    end

    local rays = {}
    function StartShapeTestRay(_, _, _, x2, y2, z2)
        rays[#rays + 1] = { x = x2, y = y2, z = z2 }
        return #rays
    end
    function GetShapeTestResult(h)
        local r = rays[h] or { x = 0.0, y = 0.0, z = 0.0 }
        if world.rayHit then
            return 2, world.hitShape, vec(r.x, r.y, r.z)
        end
        return 2, world.hitShape == true and false or 0, vec(0.0, 0.0, 0.0)
    end

    -- ------------------------------------------------------------- the ped ---

    -- STREAMING, MODELLED AS A COST RATHER THAN AS A FLAG. Only the dictionary
    -- the owner chose in game exists on this build, and it is not loaded until
    -- something asks for it -- which is the whole of fault 3's first half: WHEN
    -- the asking happens relative to standing the corpse back up.
    anim = {
        exists  = { ['move_injured_ground'] = true },
        loaded  = false,
        playing = false,
        speed   = nil,
        last    = nil,
    }
    function DoesAnimDictExist(d) return anim.exists[d] == true end
    function HasAnimDictLoaded(d) return anim.exists[d] == true and anim.loaded end
    function RequestAnimDict(d)
        note('anim:request', d)
        if anim.exists[d] then anim.loaded = true end
    end
    function TaskPlayAnim(_, dict, name, blendIn, _bo, _dur, flag, _rate,
                          lockX, lockY, lockZ)
        note('anim:play')
        anim.playing = true
        -- A fresh task runs at the engine's rate whatever it was last told.
        anim.speed = 1.0
        anim.last = { dict = dict, name = name, blendIn = blendIn, flag = flag,
                      lockX = lockX, lockY = lockY, lockZ = lockZ }
    end
    function IsEntityPlayingAnim() return anim.playing end
    function SetEntityAnimSpeed(_, _, _, s)
        anim.speed = s
        note('anim:speed', s)
    end
    function ClearPedTasks() anim.playing = false note('cleartasks') end
    function ClearPedTasksImmediately() anim.playing = false note('cleartasks!') end
    function SetPedCanRagdoll() end
    function ResetPedMovementClipset() end
    function SetPedMoveRateOverride() end
    function SetEntityLocallyInvisible() end

    -- WHO THIS CLIENT HAS MARKED UNABLE TO BE DAMAGED, and what group it put
    -- them in. Recorded rather than swallowed: #115 turns entirely on whether
    -- a SQUADMATE's local clone carries the mark and an ENEMY's does not, and
    -- a no-op stub can only ever agree with whatever the code happens to do.
    --
    -- nil is a THIRD answer here and it is load-bearing -- "never touched" is
    -- not "touched with false", and the enemy assertion below is the one that
    -- needs to tell them apart. (`0` is truthy in Lua and these natives take
    -- booleans, so the values are stored raw and compared with == rather than
    -- being coerced through `and true or false`.)
    local shielded, grouped = {}, {}
    function SetEntityCanBeDamaged(ped, toggle) shielded[ped] = toggle end
    function SetPedRelationshipGroupHash(ped, g) grouped[ped] = g end

    -- TWO DISTINGUISHABLE GROUPS. The file-wide stub answers every GetHashKey
    -- with 1, which would make BR_ALLY and PLAYER the same number and the
    -- release assertion below unable to fail. squadmates.lua captures
    -- PLAYER_GROUP at LOAD time, so this has to be in place before loadAll.
    local PLAYER_HASH = 9001
    function GetHashKey(s) return s == 'PLAYER' and PLAYER_HASH or 1 end

    -- The resurrection, and the reading that matters at the moment it happens.
    local resurrect = { count = 0, dictLoadedFirst = nil, posed = nil }
    function NetworkResurrectLocalPlayer()
        note('resurrect')
        resurrect.count = resurrect.count + 1
        resurrect.dictLoadedFirst = anim.loaded
        bodies[1].dead = false
    end

    -- ---------------------------------------------------------- the labels ---

    local tagsMade = 0
    function CreateFakeMpGamerTag(_, text)
        tagsMade = tagsMade + 1
        note('gamertag', text)
        return 900 + tagsMade
    end
    function RemoveMpGamerTag() end
    function SetMpGamerTagVisibility() end
    function IsSphereVisible() return true end

    local drawn, origin, pending = {}, nil, nil
    function SetDrawOrigin(x, y, z) origin = { x = x, y = y, z = z } end
    function ClearDrawOrigin() origin = nil end
    function SetTextFont() end
    function SetTextScale() end
    function SetTextColour() end
    function SetTextCentre() end
    function SetTextDropshadow() end
    function SetTextEdge() end
    function SetTextDropShadow() end
    function SetTextOutline() end
    function BeginTextCommandDisplayText() end
    function AddTextComponentSubstringPlayerName(s) pending = s end
    function EndTextCommandDisplayText()
        if origin then
            drawn[#drawn + 1] = { text = pending, x = origin.x, y = origin.y,
                                  z = origin.z }
        end
    end
    --- The last name this client drew for itself, or nil.
    local function lastName()
        return drawn[#drawn]
    end

    -- ---------------------------------------------------------- the camera ---

    local cams = {}
    local shot = { rendering = false, coord = nil, aim = nil, built = 0 }
    function CreateCamWithParams()
        shot.built = shot.built + 1
        local h = 700 + shot.built
        cams[h] = true
        return h
    end
    function DoesCamExist(h) return cams[h] == true end
    function DestroyCam(h) cams[h] = nil note('cam:destroy') end
    function SetCamActive() end
    function RenderScriptCams(on)
        shot.rendering = on and true or false
        note('cam:render', shot.rendering)
    end
    function SetCamCoord(_, x, y, z) shot.coord = { x = x, y = y, z = z } end
    function PointCamAtCoord(_, x, y, z) shot.aim = { x = x, y = y, z = z } end

    -- ------------------------------------------------------ the neighbours ---

    local threads = {}
    Citizen.CreateThread = function(fn) threads[#threads + 1] = fn end
    Citizen.Wait = function(ms) note('wait', ms) end
    local function runThreads()
        local i = 1
        while i <= #threads do
            threads[i]()
            i = i + 1
        end
        threads = {}
    end

    local dui = { draws = {}, sends = {} }
    BR.Dui = {
        page       = function(n) return { name = n } end,
        send       = function(_, m) dui.sends[#dui.sends + 1] = m end,
        drawWorld  = function(_, x, y, z) dui.draws[#dui.draws + 1] =
                         { x = x, y = y, z = z } end,
        drawScreen = noop, drawOnEntity = noop,
        ready      = function() return true end,
    }
    BR.Sfx = BR.Sfx or { play = noop }
    BR.Native.knockdown = function() note('knockdown') end
    BR.Native.setDisplayHealth = function(hp) note('setHealth', hp) end
    BR.Native.keyLabelForCommand = function() return 'E' end
    BR.Native.ALLY_GROUP = 1

    -- The mate has to be a player the engine will hand us a ped for, which is
    -- what the harness's `others` table decides.
    others[2] = { x = 1.0, y = 0.0 }

    loadAll({
        'br_core/client/squadmates.lua',   -- owns the head anchor; loads first
        'br_core/client/dbno.lua',         -- as fxmanifest orders them
    })
    -- The load-time threads are NOT run: the first knock below has to be the
    -- first time anything asks for the crawl dictionary, or the ordering
    -- question fault 3 turns on cannot be asked.
    threads = {}

    local function tickBand() BR.Loop.step(BR.Loop.TICK) end

    --- One frame, with the CLIP'S OWN MOVER applied first.
    ---
    --- Deliberately applied whether or not the clip has been told to hold: the
    --- client cannot know what the engine does with a playback rate of zero, so
    --- the model assumes the worst and the fix has to hold the ped still on its
    --- own evidence.
    local function drift(n)
        for _ = 1, n do
            if world.mover ~= 0.0 then
                local h = math.rad(bodies[1].h)
                bodies[1].x = bodies[1].x - math.sin(h) * world.mover
                bodies[1].y = bodies[1].y + math.cos(h) * world.mover
            end
            frame(16)
        end
    end

    --- How many times a loop callback has thrown, and whether it is suspended.
    --- A suspended dbno.controls is a player stuck on the floor with nothing
    --- left running to move them, so it is asserted rather than assumed.
    local function loopHealth(name)
        for _, s in ipairs(BR.Loop.stats()) do
            if s.name == name then return s.errors, s.suspended end
        end
        return nil, nil
    end

    local function travelled(fromX, fromY)
        local dx, dy = bodies[1].x - fromX, bodies[1].y - fromY
        return math.sqrt(dx * dx + dy * dy)
    end

    -- ====================================================================== --
    -- 1. THE LABELS SIT ON THE BODY, NOT ON THE CAPSULE
    -- ====================================================================== --

    describe('the labels over a body follow the body -- fault 1')

    BR.State.me = { src = 1, state = BR.PlayerState.ALIVE, squadId = 'sq1' }
    BR.State.roster = {
        [1] = { src = 1, name = 'Me',    squadId = 'sq1',
                state = BR.PlayerState.ALIVE },
        [2] = { src = 2, name = 'Bravo', squadId = 'sq1',
                state = BR.PlayerState.DBNO },
    }
    -- FOUR METRES, NOT ONE, AND THAT DISTANCE IS NOW LOAD-BEARING.
    --
    -- This block measures WHERE A NAME IS DRAWN. Within revive reach the name is
    -- deliberately not drawn at all (owner, 2026-08-17: "when going in for the
    -- revive, the playernames text is shown at the exact same position as the
    -- DUI, resulting in an overlap effect") -- the revive prompt's own label IS
    -- that player's name, so the overhead one is suppressed rather than nudged.
    --
    -- The old fixture stood the body at 1.0m, INSIDE the 1.5m reach, and then
    -- asserted both that the name is drawn there and, forty lines later, that
    -- the revive prompt is drawn there too. It pinned the overlap it was written
    -- to catch. Geometry is measured out of reach; the suppression is asserted
    -- separately below; the prompt assertions keep 1.0m.
    -- THE BODY MOVES, NOT JUST THE BEACON. Suppression is decided from the real
    -- ped distance, so a beacon that claims 4m over a ped still lying at 1m
    -- would measure nothing. The two are kept in step deliberately.
    bodies[MATE].x = 4.0
    fire(BR.Net.SQUAD_POS, { { src = 2, name = 'Bravo', i = 2, x = 4.0, y = 0.0,
                              state = BR.PlayerState.DBNO } })
    tagsMade = 0
    tickBand()
    drawn = {}
    frame(16)

    ok(BR.Squadmates.pedOf(2) == MATE,
        'the harness can see the downed mate at all',
        ('pedOf(2) = %s'):format(tostring(BR.Squadmates.pedOf(2))))

    ok(tagsMade == 0,
        'A BODY ON THE FLOOR GETS NO GAMER TAG, because a gamer tag cannot be lowered',
        ('the engine was asked for %d tag(s) over a downed mate'):format(tagsMade))

    local proneName = lastName()
    ok(proneName ~= nil and proneName.text == 'Bravo [DOWN]',
        'and gets a name this client draws itself instead',
        proneName and tostring(proneName.text) or 'nothing was drawn')
    ok(proneName ~= nil
       and math.abs(proneName.z - (30.0 + HEAD_PRONE + 0.30)) < 0.01,
        'pinned just above the head bone of a body that is lying down',
        proneName and ('drawn at z %.2f, the head is at %.2f')
            :format(proneName.z, 30.0 + HEAD_PRONE) or 'nothing was drawn')

    -- THE ASSERTION THAT CANNOT PASS ON AN ORIGIN-ANCHORED LABEL. Same ped,
    -- same coordinates, different posture: an anchor that reads the entity's
    -- position answers identically both times, which is the fault exactly as
    -- the owner described it.
    bodies[MATE].prone = false
    drawn = {}
    frame(16)
    local standName = lastName()
    ok(standName ~= nil and proneName ~= nil
       and (standName.z - proneName.z) > 1.0,
        'AND THE LABEL MOVES WHEN THE BODY DOES -- fault 1',
        (standName and proneName)
            and ('lying %.2f, standing %.2f -- a difference of %.2f')
                :format(proneName.z, standName.z, standName.z - proneName.z)
            or 'one of the two frames drew nothing')
    bodies[MATE].prone = true

    -- AND INSIDE REVIVE REACH THE NAME IS NOT DRAWN AT ALL.
    --
    -- The revive prompt is a SCREEN-SPACE sprite about 16% of screen height,
    -- centred on the same head bone the name hangs off -- the two agree to
    -- within 5cm, so the name lands inside the plate. Offsetting cannot fix
    -- that: a world lift big enough to clear the sprite at arm's length puts the
    -- name in the sky at 20m. Nothing is lost by suppressing it, because the
    -- prompt's own label IS that player's name.
    bodies[MATE].x = 1.0
    fire(BR.Net.SQUAD_POS, { { src = 2, name = 'Bravo', i = 2, x = 1.0, y = 0.0,
                              state = BR.PlayerState.DBNO } })
    tickBand()
    drawn = {}
    frame(16)
    local nearName = lastName()
    ok(nearName == nil,
        'AND A BODY WITHIN REVIVE REACH GETS NO OVERHEAD NAME, because the '
        .. 'prompt already carries it and they would sit on top of each other',
        nearName and ('a name was drawn at z %.2f'):format(nearName.z)
            or 'nothing was drawn, which is the point')

    -- The upright states keep the ENGINE's tag. The common case is not being
    -- rewritten to fix the uncommon one, and a fix that silently moved every
    -- squadmate's name onto a hand-rolled draw would be a much larger change
    -- than the one that was asked for.
    BR.State.roster[2].state = BR.PlayerState.ALIVE
    fire(BR.Net.SQUAD_POS, { { src = 2, name = 'Bravo', i = 2, x = 1.0, y = 0.0,
                              state = BR.PlayerState.ALIVE } })
    tagsMade = 0
    tickBand()
    drawn = {}
    frame(16)
    ok(tagsMade == 1,
        'a mate on their feet still wears the engine tag they always did',
        ('tags made: %d'):format(tagsMade))
    ok(#drawn == 0,
        'and nothing is drawn over them by hand',
        ('%d hand-drawn name(s)'):format(#drawn))

    -- A DEAD mate is the owner's second sentence: "the playernames thing is
    -- also true for dead players".
    BR.State.roster[2].state = BR.PlayerState.DEAD
    fire(BR.Net.SQUAD_POS, { { src = 2, name = 'Bravo', i = 2, x = 1.0, y = 0.0,
                              state = BR.PlayerState.DEAD } })
    tagsMade = 0
    tickBand()
    drawn = {}
    frame(16)
    local deadName = lastName()
    ok(tagsMade == 0 and deadName ~= nil and deadName.text == 'Bravo [DEAD]',
        'A DEAD MATE IS LABELLED THE SAME WAY, which the owner asked for by name',
        ('tags %d, drew %s'):format(tagsMade,
            deadName and tostring(deadName.text) or 'nothing'))
    ok(deadName ~= nil and deadName.z < 30.0 + HEAD_STANDING,
        'and below the height a standing head would be at',
        deadName and ('%.2f vs %.2f'):format(deadName.z, 30.0 + HEAD_STANDING)
                  or 'nothing was drawn')

    -- THE REVIVE PROMPT IS THE DUI HALF OF THE SAME SENTENCE.
    BR.State.roster[2].state = BR.PlayerState.DBNO
    fire(BR.Net.SQUAD_POS, { { src = 2, name = 'Bravo', i = 2, x = 1.0, y = 0.0,
                              state = BR.PlayerState.DBNO } })
    tickBand()
    dui.draws = {}
    frame(16)
    local pronePrompt = dui.draws[#dui.draws]
    ok(pronePrompt ~= nil,
        'a mate within reach is offered a revive prompt at all',
        ('%d world draws'):format(#dui.draws))
    ok(pronePrompt ~= nil
       and math.abs(pronePrompt.z - (30.0 + HEAD_PRONE
                                     + (BR.Config.Match.dbnoPromptLift or 0.35)))
           < 0.01,
        'and it hangs off the head bone rather than off the ped origin',
        pronePrompt and ('drawn at %.2f'):format(pronePrompt.z) or 'nothing drawn')

    bodies[MATE].prone = false
    dui.draws = {}
    frame(16)
    local standPrompt = dui.draws[#dui.draws]
    ok(standPrompt ~= nil and pronePrompt ~= nil
       and (standPrompt.z - pronePrompt.z) > 1.0,
        'AND THE PROMPT MOVES WITH THE BODY TOO -- fault 1',
        (standPrompt and pronePrompt)
            and ('lying %.2f, standing %.2f'):format(pronePrompt.z, standPrompt.z)
            or 'one of the two frames drew nothing')
    bodies[MATE].prone = true

    ok(select(1, loopHealth('squadmates.lownames')) == 0,
        'and the loop that draws them has not thrown once',
        ('errors %s'):format(tostring(select(1, loopHealth('squadmates.lownames')))))

    -- ====================================================================== --
    -- 3. A FALL PUTS NOBODY BACK ON THEIR FEET, NOT EVEN FOR A FRAME
    -- ====================================================================== --
    --
    -- Ordered before the movement block on purpose: this has to be the FIRST
    -- knock of the session, because the question is what happens the one time
    -- the crawl dictionary is not in memory yet.

    describe('a fall never shows a standing frame -- fault 3')

    BR.State.me.state = BR.PlayerState.DBNO
    bodies[1].dead = true      -- the world killed this ped on the way down
    bodies[1].prone = false    -- ...and it has not been posed yet
    log = {}
    fire(BR.Net.DBNO_SET, { downed = true, bleedEndsAt = 60000 })
    runThreads()

    ok(anim.loaded == true and resurrect.count == 1,
        'the fall is resurrected and the pose is resolved',
        ('resurrects %d, dict loaded %s')
            :format(resurrect.count, tostring(anim.loaded)))

    ok(resurrect.dictLoadedFirst == true,
        'THE CRAWL CLIP IS IN MEMORY BEFORE THE CORPSE IS STOOD BACK UP -- fault 3',
        ('at the moment of the resurrection the dictionary was %s')
            :format(resurrect.dictLoadedFirst and 'loaded' or 'NOT loaded'))

    ok(waitedBetween('resurrect', 'anim:play') == false,
        'AND NOTHING YIELDS BETWEEN THE RESURRECTION AND THE POSE -- fault 3',
        ('a yield between them is a frame of a player standing up; waited: %s')
            :format(tostring(waitedBetween('resurrect', 'anim:play'))))

    local iRes, iClear, iPose = firstAt('resurrect'), firstAt('cleartasks!'),
                                firstAt('anim:play')
    ok(iRes and iClear and iPose and iRes < iClear and iClear < iPose,
        'in the one order that works: resurrect, clear the dying task, pose',
        ('resurrect %s, clear %s, pose %s'):format(tostring(iRes),
            tostring(iClear), tostring(iPose)))

    ok(countOf('knockdown') == 0,
        'and a body that has already fallen is not ragdolled again',
        ('knockdowns on the fall path: %d'):format(countOf('knockdown')))

    ok(anim.last ~= nil and anim.last.blendIn >= 100.0,
        'the pose snaps rather than blending out of the standing idle',
        anim.last and ('blend in %.1f'):format(anim.last.blendIn) or 'no anim')

    ok(countOf('setHealth') == 1,
        'and the downed floor is re-applied over whatever the resurrection gave',
        ('health writes: %d'):format(countOf('setHealth')))

    -- A LIVE KNOCK IS THE OTHER PATH AND IT KEEPS ITS KNOCKDOWN. The ragdoll
    -- instant is the feel of being shot down; only the fall path skips it.
    fire(BR.Net.DBNO_SET, { downed = false })
    runThreads()
    log = {}
    bodies[1].dead = false
    fire(BR.Net.DBNO_SET, { downed = true, bleedEndsAt = 60000 })
    runThreads()
    ok(countOf('resurrect') == 0 and countOf('knockdown') == 1,
        'a player shot down is knocked down, not resurrected',
        ('resurrects %d, knockdowns %d')
            :format(countOf('resurrect'), countOf('knockdown')))

    -- ====================================================================== --
    -- 2. LETTING GO MEANS STOPPING
    -- ====================================================================== --

    describe('a downed player can stop crawling -- fault 2')

    bodies[1].prone = true
    world.ragdoll, world.air = false, false
    input.lr, input.ud = 0.0, 0.0
    frame(16)   -- the pose is on, the hold is taken

    ok(anim.last ~= nil and anim.last.lockX == true and anim.last.lockY == true,
        'the crawl clip is tasked with its mover locked, not left to drive the ped',
        anim.last and ('lockX %s lockY %s lockZ %s'):format(
            tostring(anim.last.lockX), tostring(anim.last.lockY),
            tostring(anim.last.lockZ)) or 'no anim was tasked')

    -- THE CONSEQUENCE, NOT THE CALL. The clip is modelled as one that moves the
    -- ped by itself -- see the header -- so this fails on any build where the
    -- client does not actively hold them still.
    world.mover = 0.009        -- about the crawl's own speed, per frame
    bodies[1].x, bodies[1].y = 0.0, 0.0
    frame(16)                  -- the frame that takes the hold
    local sx, sy = bodies[1].x, bodies[1].y
    drift(60)
    ok(travelled(sx, sy) <= 0.05,
        'A DOWNED PLAYER WHO PRESSES NOTHING STAYS PUT -- fault 2',
        ('they travelled %.3fm in 60 frames of pressing nothing')
            :format(travelled(sx, sy)))

    ok(anim.speed == 0.0,
        'and the crawl clip is held still rather than hauling them along forever',
        ('clip rate %s'):format(tostring(anim.speed)))

    -- AND THE CRAWL ITSELF STILL WORKS, which is the half a "fix" could
    -- trivially break: a downed player pinned in place is a worse bug than one
    -- who cannot stop.
    input.ud = -1.0
    sx, sy = bodies[1].x, bodies[1].y
    log = {}
    drift(60)
    ok(travelled(sx, sy) > 0.3,
        'and one who presses forward still crawls',
        ('they travelled %.3fm in 60 frames of holding forward')
            :format(travelled(sx, sy)))

    -- THE CLIP SURVIVES THE STEP THAT MOVES THEM.
    --
    -- Every crawling frame teleports the ped, and SET_ENTITY_COORDS_NO_OFFSET's
    -- fifth argument decides whether that teleport takes the ped's tasks with
    -- it -- which is to say, whether it destroys the crawl animation. It was
    -- being passed `false`, so the clip was torn down and rebuilt on every
    -- frame of movement and never got past its opening pose.
    ok(countOf('anim:play') <= 2,
        'AND THE CRAWL CLIP IS NOT TORN DOWN AND REBUILT ON EVERY STEP',
        ('the clip was re-tasked %d times in 60 frames of crawling')
            :format(countOf('anim:play')))
    ok(anim.speed == 1.0,
        'with the clip running again the moment they ask to move',
        ('clip rate %s'):format(tostring(anim.speed)))

    -- Steering survives too.
    input.lr, input.ud = 1.0, 0.0
    local h0 = bodies[1].h
    drift(10)
    ok(math.abs(bodies[1].h - h0) > 1.0,
        'and can still turn on the spot without travelling',
        ('heading %.1f -> %.1f'):format(h0, bodies[1].h))
    input.lr = 0.0

    -- A WALL, ON THE BUILD WHOSE SHAPE TEST ANSWERS `true`. The old comparison
    -- was `hit == 1` alone, which reads a boolean answer as a miss -- the same
    -- shape bug natives.lua already carries the fix for on this very native.
    world.rayHit, world.hitShape = true, true
    world.mover = 0.0
    input.ud = -1.0
    sx, sy = bodies[1].x, bodies[1].y
    drift(30)
    ok(travelled(sx, sy) <= 0.02,
        'a wall stops the crawl even when the shape test answers `true`',
        ('they travelled %.3fm into it'):format(travelled(sx, sy)))
    world.rayHit = false
    input.ud = 0.0

    ok(select(1, loopHealth('dbno.controls')) == 0
       and select(2, loopHealth('dbno.controls')) ~= true,
        'and the loop that does all of this has never thrown or been suspended',
        ('errors %s suspended %s'):format(
            tostring(select(1, loopHealth('dbno.controls'))),
            tostring(select(2, loopHealth('dbno.controls')))))

    -- ====================================================================== --
    -- 4. THE VIEW IS FROM THE FLOOR
    -- ====================================================================== --

    describe('the downed camera is on the floor -- fault 4')

    frame(16)
    ok(shot.rendering == true and shot.coord ~= nil,
        'A DOWNED PLAYER GETS A CAMERA OF THEIR OWN -- fault 4',
        ('rendering %s, positioned %s'):format(tostring(shot.rendering),
            shot.coord and 'yes' or 'no'))

    ok(shot.coord ~= nil and shot.coord.z < 30.0 + HEAD_STANDING,
        'and it sits below the standing head it used to hover over',
        shot.coord and ('camera at %.2f, a standing head at %.2f')
            :format(shot.coord.z, 30.0 + HEAD_STANDING) or 'no camera')

    ok(shot.coord ~= nil and shot.coord.z >= 30.0 + 0.3,
        'without dropping through the floor it is meant to be lying on',
        shot.coord and ('%.2f above a floor at 30.00'):format(shot.coord.z - 30.0)
                    or 'no camera')

    ok(shot.aim ~= nil and math.abs(shot.aim.z - (30.0 + HEAD_PRONE)) < 0.2,
        'pointed at the body rather than at where the body would be standing',
        shot.aim and ('aimed at %.2f'):format(shot.aim.z) or 'no aim')

    -- DERIVED FROM THE POSTURE, not from a constant that happens to be small.
    --
    -- Written nil-safe on purpose: a build with no downed camera at all has to
    -- come out of here as a FAILED ASSERTION and not as a crashed suite, or the
    -- revert that proves this block bites cannot be run.
    local proneCam = shot.coord and shot.coord.z
    bodies[1].prone = false
    frame(16)
    local standCam = shot.coord and shot.coord.z
    ok(proneCam and standCam and (standCam - proneCam) > 1.0,
        'and the height is the posture -- a standing ped would put it back up',
        (proneCam and standCam)
            and ('lying %.2f, standing %.2f'):format(proneCam, standCam)
            or 'there was no camera to measure')
    bodies[1].prone = true
    frame(16)

    -- AND IT IS HANDED BACK. A scripted camera nobody destroys is the whole
    -- game rendered from a dead handle.
    fire(BR.Net.DBNO_SET, { downed = false })
    runThreads()
    frame(16)
    ok(shot.rendering == false and next(cams) == nil,
        'standing back up gives the game its own camera back',
        ('rendering %s, cameras alive %s'):format(tostring(shot.rendering),
            next(cams) and 'yes' or 'no'))

    -- A match ending mid-bleed is the other way out, and the one that leaves no
    -- DBNO_SET behind to do the tidying.
    bodies[1].dead = false
    fire(BR.Net.DBNO_SET, { downed = true, bleedEndsAt = 60000 })
    runThreads()
    frame(16)
    local upMidMatch = shot.rendering
    fire(BR.Net.STATE, { state = BR.MatchState.ENDED })
    ok(upMidMatch == true and shot.rendering == false and next(cams) == nil,
        'and so does the match ending while they are still on the floor',
        ('up %s, then rendering %s'):format(tostring(upMidMatch),
                                            tostring(shot.rendering)))

    -- ====================================================================== --
    -- THE READOUT, which is the only instrument for any of this
    -- ====================================================================== --

    describe('/brdbno answers the four questions it was extended for')

    logged = {}
    ok(pcall(commands['brdbno'], nil, {}, ''), '/brdbno does not throw')
    local said = table.concat(logged, '\n')
    for _, word in ipairs({ 'pose', 'clip', 'held at', 'head', 'camera' }) do
        ok(said:find(word, 1, true) ~= nil,
            ('the readout carries "%s"'):format(word), said)
    end

    -- ====================================================================== --
    -- NOTHING IN THIS FILE MAY WRITE DAMAGE STATE ONTO A CLONE IT DOES NOT OWN
    -- ====================================================================== --
    --
    -- #115, the false corpse: the shooter's engine kills a teammate's clone
    -- locally, the server refuses the damage with CancelEvent(), and
    -- CancelEvent() sends no negative acknowledgement -- so there is no
    -- message with which to correct the corpse.
    --
    -- THIS BLOCK USED TO ASSERT THE OPPOSITE OF WHAT IT ASSERTS NOW, and the
    -- reversal is the point. Round eight put SetEntityCanBeDamaged(matePed,
    -- false) on the mate's clone and these assertions pinned it. The playtest
    -- on 2026-08-19 disproved it -- "their ped fell over, then popped back up",
    -- i.e. the damage landed and the repair net caught it, and the next shot
    -- killed outright. A player's ped is owned by their own machine, control
    -- can never be taken, and script writes to it are not honoured here.
    --
    -- So the shield is gone, prevention moved to the engine team gate in
    -- client/natives.lua (asserted in its own suite, further down), and what
    -- is left here has to hold the LINE: this file may put a mate in the ally
    -- group, and may not pretend to control their damage.
    --
    --   REVERT-DETECTING   -- fail if the disproven mark comes back (1), or if
    --                         the ally group stops being applied (2) or
    --                         released (4)
    --   OVERREACH-DETECTING -- fail if this file starts touching players who
    --                         are not squadmates at all (3)

    describe('this client stops writing to a squadmate clone it does not own -- #115')

    -- A THIRD PLAYER WHO IS NOT IN THE SQUAD. The server never names them in
    -- a SQUAD_POS push -- that push is squad-only by construction
    -- (server/party.lua groups on squadId and skips any squad of one, pinned
    -- in test_roster.lua) -- so this client learns of them only as another
    -- body in the world, which is exactly what an enemy is.
    local ENEMY = 5003
    others[3] = { x = 2.0, y = 0.0 }
    bodies[ENEMY] = { x = 2.0, y = 0.0, z = 30.0, h = 0.0, dead = false,
                      prone = false }

    BR.State.me = { src = 1, state = BR.PlayerState.ALIVE, squadId = 'sq1' }
    BR.State.roster = {
        [1] = { src = 1, name = 'Me',     squadId = 'sq1',
                state = BR.PlayerState.ALIVE },
        [2] = { src = 2, name = 'Bravo',  squadId = 'sq1',
                state = BR.PlayerState.ALIVE },
        [3] = { src = 3, name = 'Victor', squadId = 'sq9',
                state = BR.PlayerState.ALIVE },
    }

    shielded[MATE], shielded[ENEMY] = nil, nil
    fire(BR.Net.SQUAD_POS, { { src = 2, name = 'Bravo', i = 2, x = 1.0, y = 0.0,
                              state = BR.PlayerState.ALIVE } })
    tickBand()

    -- 1. REVERT-DETECTING, and the whole reason this suite was rewritten. nil
    --    is a THIRD answer to "was the clone marked" and it is the only
    --    passing one: `false` here means somebody put the disproven native
    --    back, and `true` means they put back its release as well.
    ok(shielded[MATE] == nil,
        'A SQUADMATE CLONE IS NEVER MARKED UNDAMAGEABLE -- disproven, #115',
        ('SetEntityCanBeDamaged on the mate: %s'):format(tostring(shielded[MATE])))

    -- 2. REVERT-DETECTING. The group is not what stops a bullet and must not be
    --    described as though it is, but the AI and melee paths do read it.
    ok(grouped[MATE] == BR.Native.ALLY_GROUP,
        'and IS still put in the ally group the AI and melee paths read',
        ('group: %s'):format(tostring(grouped[MATE])))

    -- 3. OVERREACH-DETECTING. Whatever this file does, it does to squadmates
    --    the server named and to nobody else -- an enemy is never touched at
    --    all, not even into a group.
    ok(shielded[ENEMY] == nil and grouped[ENEMY] == nil,
        'AND AN ENEMY IS NEVER TOUCHED BY THIS FILE AT ALL -- #115',
        ('shield %s, group %s')
            :format(tostring(shielded[ENEMY]), tostring(grouped[ENEMY])))

    -- 4. REVERT-DETECTING, on the release path. The empty push is a squad that
    --    dissolved; an ex-mate must be handed back to the default group rather
    --    than left carrying this client's private idea of an ally. Ticked
    --    twice: once is a loop that ran, twice is a loop that kept its answer.
    shielded[MATE], shielded[ENEMY] = nil, nil
    fire(BR.Net.SQUAD_POS, {})
    tickBand()
    tickBand()
    ok(grouped[MATE] == PLAYER_HASH,
        'AND AN EX-SQUADMATE IS HANDED BACK to the default relationship group',
        ('group on the ex-mate: %s'):format(tostring(grouped[MATE])))

    ok(shielded[MATE] == nil and shielded[ENEMY] == nil,
        'and no damage state was written to anybody, before or after',
        ('mate %s, enemy %s')
            :format(tostring(shielded[MATE]), tostring(shielded[ENEMY])))

    ok(select(1, loopHealth('squadmates.tags')) == 0,
        'and the loop that does all of this has not thrown once',
        ('errors %s'):format(tostring(select(1, loopHealth('squadmates.tags')))))

    others[3] = nil
end

-- ======================================================================== --
-- 9. TYPING INTO A NUI SCREEN MUST NOT ALSO DRIVE THE GAME
-- ======================================================================== --
--
-- THE REPORT. A search field was added to the in-game player list, and typing a
-- name into it played the game underneath: E interacted, R used the held item,
-- G dropped it, 1-5 swapped slots, and T pushed chat focus -- which replaces
-- the top of the focus stack and therefore CLOSES THE PANEL BEING TYPED INTO.
--
-- IT IS NOT A BUG IN THE SEARCH FIELD. The chat composer has had it identically
-- for as long as the raw key layer has existed. A text field is simply the
-- first place in that panel where letters get typed.
--
-- ONLY THE RAW LAYER LEAKS, AND THAT IS WHY IT WAS NEVER SEEN. The engine's
-- RegisterKeyMapping route needs the GAME to receive the key, and a focused
-- page with keep-input off means it receives nothing -- ui-src/src/App.tsx and
-- screens/PlayerList.tsx both record that finding, and it is why every screen
-- in this interface answers its own Escape from the DOM. br_core's raw layer
-- reads the keyboard directly, which is its entire purpose, so a focus change
-- is invisible to it. The `resyncing` window covers the two frames of the
-- TRANSITION and nothing after it.
--
-- THE BRIDGE BELOW IS THE REAL ONE. br_ui/client/nui.lua is loaded and driven
-- rather than modelled, because the fault is a disagreement BETWEEN two
-- resources -- br_ui has always known which screen owns the keyboard, and
-- br_core was not asking. A model of the bridge written next to the fix would
-- be a model that agrees with the fix, which is the failure #129's seventh
-- round is a monument to.

describe('the focus gate')
do
    -- THE REAL br_ui BRIDGE.
    --
    -- `RES` is captured out of GetCurrentResourceName at LOAD time, so the name
    -- is swapped for exactly that call and put straight back: br_core's own
    -- onClientResourceStart handlers call it at HANDLER time and have to keep
    -- seeing 'br_core', or bootOn() would silently stop rebooting the key
    -- layer and every assertion below would be measuring a stale build.
    local nui = { held = false, cursor = false, keepInput = false, sent = 0 }
    function SendNUIMessage() nui.sent = nui.sent + 1 end
    function SetNuiFocus(held, cursor) nui.held, nui.cursor = held, cursor end
    function SetNuiFocusKeepInput(keep) nui.keepInput = keep end
    function RegisterNUICallback() end

    -- The bridge opens a `while true` watchdog at load. It is RECORDED and
    -- never run: Citizen.Wait is a no-op in this harness, so running it would
    -- hang the suite. What the watchdog does when it fires is call applyFocus
    -- on an empty stack, which is the same call `brfocus clear` makes and which
    -- is exercised through clearFocus below.
    local uiThreads = {}
    Citizen.CreateThread = function(fn) uiThreads[#uiThreads + 1] = fn end

    local coreName = GetCurrentResourceName
    GetCurrentResourceName = function() return 'br_ui' end
    loadAll({ 'br_ui/client/nui.lua' })
    GetCurrentResourceName = coreName

    -- chat.lua is what makes T dangerous rather than merely noisy: it asks
    -- br_ui to open the chat composer, which pushes a NEW screen over whatever
    -- was on top. That is the reported symptom -- the panel closing itself --
    -- and it is only reproducible with this file in the room.
    loadAll({ 'br_core/client/chat.lua' })

    ok(#uiThreads == 1, 'the bridge loaded (its focus watchdog is registered)',
       ('%d thread(s)'):format(#uiThreads))

    -- ---------------------------------------------------------- the keyboard ---

    --- Every key this block types, delivered to BOTH mechanisms exactly as
    --- pressInteract() does -- the raw sample and the engine's command.
    ---
    --- The engine's half of the two "ways out" sits on a function key: the raw
    --- layer's default for the pause menu is Escape, which RegisterKeyMapping
    --- cannot be given, and the player list's is tilde, which is not in
    --- DEFAULT_VK. Both carry a `raw` override in keybinds.lua and this table
    --- states both halves so neither is assumed.
    local TYPED = {
        interact   = { vk = 0x45, key = 'E'   },
        use        = { vk = 0x52, key = 'R'   },
        drop       = { vk = 0x47, key = 'G'   },
        chatGlobal = { vk = 0x54, key = 'T'   },
        chatSquad  = { vk = 0x59, key = 'Y'   },
        slot1      = { vk = 0x31, key = '1'   },
        slot2      = { vk = 0x32, key = '2'   },
        inventory  = { vk = 0x09, key = 'TAB' },
        trail      = { vk = 0x42, key = 'B'   },
        pause      = { vk = 0x1B, key = 'F1'  },
        players    = { vk = 0xC0, key = 'F2'  },
    }

    local function keyDown(action, down)
        local k = TYPED[action]
        if down then
            if not keys[k.vk] then keys[k.vk] = true; edge[k.vk] = true end
        else
            keys[k.vk] = nil
        end
        engineKey(k.key, down)
    end

    --- LET THE RESYNC WINDOW CLOSE.
    ---
    --- NOT A SLEEP, AND THE DISTINCTION IS THE WHOLE OF #90. `resyncing`
    --- suppresses TAPS from the moment a focus change is announced until the
    --- first frame on which no bound key changed state -- so it is ended by
    --- QUIET, not by a clock, and a test that never goes quiet never leaves it.
    --- The first draft of this block pressed and released on consecutive
    --- frames, which is a keyboard moving on every single frame; the window
    --- stayed open for the whole run and every tap read as suppressed no matter
    --- what the gate did. That is a test that passes for the wrong reason,
    --- which is the only kind this file exists to stop.
    ---
    --- Three frames is quiet. A human types at five to ten characters a second,
    --- which is a bound key moving about once every eight frames.
    local function settle() frames(3) end

    --- Type one character, at a speed a person can actually type.
    local function typeKey(action)
        keyDown(action, true)
        frame(16)
        settle()
        keyDown(action, false)
        frame(16)
        settle()
    end

    --- How many presses reached each action, counted at the key layer itself.
    ---
    --- MEASURED HERE AND NOT AT THE FAR END ON PURPOSE. Four of the registered
    --- actions have no subscriber at all in this tree -- `map`, `ping`,
    --- `specNext`, `specPrev` -- so asserting "the map did not open" would pass
    --- on a totally unguarded key layer. What the gate promises is that the
    --- ACTION does not fire; what any given action then does is somebody
    --- else's file and somebody else's test.
    local fired = {}
    for action in pairs(TYPED) do
        fired[action] = 0
        BR.Keys.on(action, function(pressed)
            if pressed then fired[action] = fired[action] + 1 end
        end)
    end
    local function resetCount()
        for a in pairs(fired) do fired[a] = 0 end
    end
    local function counted()
        local n, names = 0, {}
        for a, v in pairs(fired) do
            n = n + v
            if v > 0 then names[#names + 1] = ('%s x%d'):format(a, v) end
        end
        table.sort(names)
        return n, table.concat(names, ', ')
    end

    --- What the bridge says is on top of the focus stack, read the way a human
    --- reads it -- out of /brfocus, which is the diagnostic that exists for
    --- exactly this question.
    local function topScreen()
        logged = {}
        commands['brfocus'](nil, {}, '')
        for _, line in ipairs(logged) do
            local s = line:match('^%s*page was told%s*:%s*(%S+)')
            if s then return s end
        end
        return nil
    end

    --- Put a screen up through the ordinary road: br_core asks br_ui, br_ui
    --- resolves the stack and announces it. Nothing here shortcuts to the key
    --- layer.
    local function openScreen(s) fire('br:ui:pushFocus', s) end
    local function closeScreen(s) fire('br:ui:popFocus', s) end

    --- A player's name, as the nine bound keys its letters happen to be.
    local NAME = { 'chatGlobal', 'interact', 'use', 'drop', 'chatSquad',
                   'slot1', 'slot2', 'trail', 'inventory' }

    local function typeAName()
        resetCount()
        for _, a in ipairs(NAME) do typeKey(a) end
    end

    --- The same name, with anything a key OPENED closed again between letters.
    ---
    --- THE UNGATED BASELINE NEEDS THIS AND THE GATED CASE DOES NOT, and that
    --- asymmetry is the bug written out in one function. With nothing focused,
    --- the first letter is T -- it reaches chat.lua, chat.lua asks br_ui for
    --- the composer, and from that moment the remaining eight letters are
    --- suppressed for entirely the right reason. Clearing between letters is
    --- what makes "all nine reach the game" a measurable statement rather than
    --- a measurement of the first one.
    local function typeANameLoose()
        resetCount()
        for _, a in ipairs(NAME) do
            typeKey(a)
            fire('br:ui:clearFocus')
            settle()
        end
    end

    -- ==================================================================== --

    -- ==================================================================== --
    -- Raising a screen that is already on the stack                          --
    -- ==================================================================== --

    describe('a buried screen can be raised again')
    do
        fire('br:ui:clearFocus')
        settle()
        ok(topScreen() == 'none', 'the stack starts empty', topScreen())

        -- THE SEQUENCE THE OWNER HIT, 2026-08-20. They had the admin console
        -- open in the pause menu when the match ended. br_core pushes 'lobby'
        -- on that transition (client/state.lua), which lands ON TOP of a stack
        -- that still has 'admin' in it -- nothing pops the console, because
        -- nothing knows it is there.
        openScreen('pause')
        openScreen('admin')
        settle()
        ok(topScreen() == 'admin', 'the console holds focus while it is open', topScreen())

        openScreen('lobby')
        settle()
        ok(topScreen() == 'lobby', 'the match ending puts the lobby over it', topScreen())

        -- AND NOW THE TAB IS PRESSED AGAIN. This is the whole bug: 'admin' is
        -- still in the stack, so a push that merely checks membership decides
        -- there is nothing to do and returns WITHOUT announcing anything. The
        -- console could not be opened again for the rest of the session, with
        -- no error anywhere -- the owner reported exactly that.
        openScreen('admin')
        settle()
        ok(topScreen() == 'admin',
           'pressing the tab again raises it rather than doing nothing',
           topScreen())

        -- THE SAME MECHANISM, AND THEREFORE THE SAME BUG, FOR /help.
        -- pause.lua pushes 'help' through this identical path, so it was never
        -- an admin-console problem -- it was a focus-stack problem that the
        -- admin console happened to reach first.
        fire('br:ui:clearFocus')
        settle()
        openScreen('pause')
        openScreen('help')
        openScreen('lobby')
        settle()
        ok(topScreen() == 'lobby', 'help buried the same way', topScreen())
        openScreen('help')
        settle()
        ok(topScreen() == 'help', 'and help can be raised again too', topScreen())

        -- ALREADY ON TOP IS STILL A NO-OP, and that half must not regress.
        -- spawn.lua and state.lua both push a screen they believe is already up
        -- purely to assert it; re-announcing an unchanged top would send the
        -- page a FOCUS it did not need on every state tick.
        fire('br:ui:clearFocus')
        settle()
        openScreen('lobby')
        settle()
        local before = topScreen()
        openScreen('lobby')
        settle()
        ok(topScreen() == before and before == 'lobby',
           'asserting the screen already on top changes nothing', topScreen())

        -- POPPING STILL REMOVES IT ONCE AND FOR ALL. A raise that re-seated by
        -- appending without removing would leave two entries, and the first pop
        -- would look like it had failed.
        fire('br:ui:clearFocus')
        settle()
        openScreen('pause')
        openScreen('admin')
        openScreen('lobby')
        openScreen('admin')
        settle()
        closeScreen('admin')
        settle()
        ok(topScreen() ~= 'admin',
           'one pop is enough after a raise, not two', topScreen())

        fire('br:ui:clearFocus')
        clearWorld()
        settle()
    end

    -- ALL THREE MECHANISMS, BECAUSE THE GATE IS IN THREE PLACES AND ONLY ONE OF
    -- THEM IS THE LEAK.
    --
    -- The raw frame loop is where the bug lives. The engine's own command
    -- handlers are believed to be unreachable under a focused page -- FiveM's
    -- contract is that keep-input off means the game receives nothing -- but
    -- this harness delivers the engine's command on every physical press
    -- REGARDLESS, deliberately, and has since #129 (see engineKey). So running
    -- the block on a build with no raw layer is running it against the
    -- pessimistic model: the one where the engine does deliver. If that is ever
    -- true on a real client, the gate holds there too, and if it is not, this
    -- costs three assertions.
    for _, mech in ipairs({
        { name = 'raw level sample', rawDown = true,  rawPressed = true  },
        { name = 'edge fallback',    rawDown = false, rawPressed = true  },
        { name = 'no raw layer',     rawDown = false, rawPressed = false },
    }) do

    describe('typing into a focused screen fires nothing -- ' .. mech.name)
    do
        bootOn(mech.rawDown, mech.rawPressed)
        fire('br:ui:clearFocus')
        clearWorld()
        settle()
        ok(topScreen() == 'none', 'the stack starts empty', topScreen())

        -- The leak, first, on a screen that is NOT up. Same keys, same frames.
        -- Without this the block cannot tell "the gate works" from "the
        -- keyboard helper is broken", which is the shape of test that passes
        -- for six rounds while the interaction is dead.
        typeANameLoose()
        local loose, looseWhich = counted()
        ok(loose == 9, 'with nothing focused, all nine keys reach the game',
           ('%d of 9 fired (%s) -- the harness is not delivering keys at all')
               :format(loose, looseWhich))

        openScreen('players')
        settle()
        ok(topScreen() == 'players', 'the player list holds focus', topScreen())
        ok(nui.keepInput == false,
           'and the engine was told the game does NOT keep input',
           tostring(nui.keepInput))

        typeAName()
        local n, which = counted()
        ok(n == 0, 'typing a name into it fires no key action at all',
           ('%d press(es) got through: %s'):format(n, which))

        -- THE REPORTED SYMPTOM, END TO END. T reaches chat.lua, chat.lua asks
        -- br_ui to open the composer, and the composer goes on TOP -- so the
        -- panel being typed into is the thing that closes.
        ok(topScreen() == 'players',
           'and the panel the player is typing into is still the one on screen',
           ('the top is now %s -- a letter in a name closed the panel')
               :format(tostring(topScreen())))

        closeScreen('players')
        settle()
        ok(topScreen() == 'none', 'the panel closes', topScreen())

        typeANameLoose()
        local back, backWhich = counted()
        ok(back == 9, 'and the keyboard comes straight back',
           ('%d of 9 fired (%s) -- the gate stuck shut, which is worse than '
            .. 'the leak'):format(back, backWhich))
    end

    end  -- mechanisms

    describe('a screen that keeps input is untouched')
    do
        -- THE ALLOWLIST IS READ, NOT RESTATED. `inventory` is the single entry
        -- in BR.FocusKeepsInput and this asserts the real table rather than the
        -- name: add a second screen there tomorrow and this test starts
        -- describing that too.
        local keepers = {}
        for s in pairs(BR.FocusKeepsInput) do keepers[#keepers + 1] = s end
        table.sort(keepers)
        ok(#keepers == 1 and keepers[1] == 'inventory',
           'exactly one screen keeps game input, and it is the inventory',
           table.concat(keepers, ', '))

        bootOn(true, true)
        fire('br:ui:clearFocus')
        settle()
        for _, screen in ipairs(keepers) do
            openScreen(screen)
            settle()
            ok(nui.keepInput == true,
               ('%s was given keep-input by the bridge'):format(screen),
               tostring(nui.keepInput))

            -- Keys that do not themselves move the focus stack, so what is
            -- being measured stays the key layer. TAB would toggle the very
            -- panel under test and T would push the chat composer over it.
            resetCount()
            typeKey('use')
            typeKey('drop')
            typeKey('slot1')
            local n, which = counted()
            ok(n == 3,
               ('every key still reaches the game under %s'):format(screen),
               ('%d of 3 fired (%s) -- the gate is suppressing a screen that '
                .. 'deliberately keeps input'):format(n, which))
            closeScreen(screen)
            settle()
        end
    end

    describe('the way out is never suppressed')
    do
        -- ESCAPE AND THE PANEL'S OWN KEY ARE THE PAGE'S, ON EVERY SCREEN THAT
        -- TAKES THE KEYBOARD, AND THAT IS NOT A CONSEQUENCE OF THIS CHANGE --
        -- it is the arrangement the interface already shipped, because the raw
        -- layer was never a reliable way out of a focused screen. Every focus
        -- screen answers Escape from a capture-phase window listener of its
        -- own: PlayerList.tsx (which also answers the rebindable close key, and
        -- deliberately does NOT when the caret is in the search field),
        -- PauseMenu.tsx, Settings.tsx, Locker.tsx, Market.tsx, Help.tsx,
        -- Chat.tsx, and App.tsx for the lobby.
        --
        -- WHAT LUA OWES THEM IS THAT THE ROUTE STILL WORKS, which is this: the
        -- page asks for the pop, the pop reaches the bridge, and the keyboard
        -- comes back. Asserted through the callback the page actually calls.
        bootOn(true, true)
        fire('br:ui:clearFocus')
        settle()
        openScreen('players')
        settle()
        resetCount()
        typeKey('players')
        typeKey('pause')
        local n = counted()
        ok(n == 0,
           'the open/close key and Escape do not fire in Lua under a screen',
           ('%d fired -- and PlayerList.tsx already answers both in the DOM, '
            .. 'so this would be the second handler for one press'):format(n))

        -- The page's own dismiss, which is the road #142 put every close on.
        closeScreen('players')
        settle()
        resetCount()
        typeKey('pause')
        ok(fired.pause == 1, 'and Escape works again the moment the page lets go',
           ('pause fired %d time(s)'):format(fired.pause))
    end

    describe('the gate lifts on every route out')
    do
        -- FOUR ROADS OUT OF A FOCUSED SCREEN, and the fourth had no event at
        -- all until this change. A gate that sticks costs the player their
        -- whole keyboard with no menu left to close, which is strictly worse
        -- than the leak it was added to fix.
        local function stuck()
            settle()
            resetCount()
            typeKey('use')
            return fired.use == 0
        end

        bootOn(true, true)
        fire('br:ui:clearFocus')

        -- 1. The panel's own dismiss, a successful report, and the bus taking
        --    the panel away all end in the same popFocus.
        openScreen('players')
        ok(stuck(), 'suppressed while the panel is up')
        closeScreen('players')
        ok(not stuck(), 'lifts on the panel popping its own focus')

        -- 2. clearFocus -- `brfocus clear`, and the same applyFocus call the
        --    bridge's watchdog makes when it finds focus held over an empty
        --    stack.
        openScreen('players')
        ok(stuck(), 'suppressed again')
        fire('br:ui:clearFocus')
        ok(not stuck(), 'lifts on the focus stack being cleared outright')

        -- 3. A SCREEN REPLACING ANOTHER, which is the case that is not a route
        --    out at all and must not be read as one.
        openScreen('players')
        openScreen('inventory')
        ok(not stuck(), 'a keep-input screen opening OVER one lifts it')
        closeScreen('inventory')
        ok(stuck(), 'and closing it puts the panel underneath back in charge')
        fire('br:ui:clearFocus')

        -- 4. THE RESOURCE STOPPING. The route that emitted nothing: br_ui
        --    released the engine's focus directly and told no one, because
        --    until now its only listeners were screens inside br_ui that were
        --    going away with it. `ensure br_ui` mid-match would have taken the
        --    player's keyboard permanently -- and taken with it the screen
        --    whose close key was the only way back.
        openScreen('players')
        ok(stuck(), 'suppressed under the panel')
        fire('onResourceStop', 'br_ui')
        ok(not stuck(), 'lifts when br_ui stops out from under the player',
           'the keyboard is gone and there is no screen left to close')
    end

    describe('the gate recovers after br_core restarts under a screen')
    do
        -- THE OTHER DIRECTION, AND THE ONE AN EDGE-DRIVEN GATE CANNOT SEE.
        -- Restarting br_core changes nothing in br_ui, so no focus event is
        -- coming; a fresh key layer would sit at its safe default and let every
        -- keystroke through underneath a panel that is still on screen.
        bootOn(true, true)
        fire('br:ui:clearFocus')
        openScreen('players')

        -- The restart. bootOn() fires onClientResourceStart for br_core, which
        -- is where the ask lives.
        bootOn(true, true)
        settle()
        ok(topScreen() == 'players',
           'br_ui still has the panel up, because nothing over there restarted',
           tostring(topScreen()))

        resetCount()
        typeKey('use')
        ok(fired.use == 0,
           'the restarted key layer asked who holds the keyboard and was told',
           ('use fired %d time(s) -- br_core came back deaf to a panel that is '
            .. 'still on screen'):format(fired.use))
        fire('br:ui:clearFocus')
    end

    describe('a hold that is live when a screen opens ends cleanly')
    do
        -- THE LATCH THIS PROJECT HAS ALREADY SHIPPED ONCE. A suppressed key
        -- that stays "down" is not a stale boolean: dbno.lua re-arms a revive
        -- from BR.Keys.isHeld() with no press edge at all, and loot.lua's crate
        -- accumulator advances on any frame the flag reads true. So a hold that
        -- is not ENDED when the keyboard is taken away is a revive that runs
        -- while the player types.
        for _, mech in ipairs({
            { name = 'raw level sample', rawDown = true,  rawPressed = true  },
            { name = 'engine +/- pair',  rawDown = false, rawPressed = true  },
            { name = 'no raw layer',     rawDown = false, rawPressed = false },
        }) do
            -- THE WORLD THIS CRATE NEEDS, STATED RATHER THAN INHERITED. The
            -- blocks above this one leave the player downed, dead, in a
            -- vehicle or with loot suppressed by a squadmate on the floor --
            -- all legitimate ends to their own subjects, and all of them make
            -- loot.render offer nothing. Inheriting any of them would give a
            -- crate that never opens for a reason with nothing to do with the
            -- key layer, which is a false red rather than a false green but is
            -- still a test measuring the wrong thing.
            BR.State.me.state = BR.PlayerState.ALIVE
            BR.State.landed = true
            BR.Loot.suppress(false)
            inVehicle = false

            bootOn(mech.rawDown, mech.rawPressed)
            fire('br:ui:clearFocus')
            clearWorld()
            local id = addEntry('chest', nil, 1.0, 0.0)
            frames(2)

            local releases = 0
            BR.Keys.on('interact', function(pressed)
                if not pressed then releases = releases + 1 end
            end)

            pressInteract()
            frames(10)
            ok(BR.Keys.isHeld('interact') == true,
               ('the hold is live before the screen opens -- %s'):format(mech.name))

            local before = releases
            openScreen('players')
            frames(2)
            ok(releases == before + 1,
               ('the screen taking the keyboard delivers exactly one release -- %s')
                   :format(mech.name),
               ('%d release(s)'):format(releases - before))
            ok(BR.Keys.isHeld('interact') == false,
               ('and the key stops reading as held -- %s'):format(mech.name),
               'a latched hold is a revive that runs while the player types')

            -- ...AND IT STAYS ENDED. The finger is still on the key: a state
            -- that is only cleared once, on the edge, comes straight back on
            -- the next frame's sample.
            frames(60)
            ok(BR.Keys.isHeld('interact') == false,
               ('it stays ended for as long as the key is held -- %s')
                   :format(mech.name))
            ok(#claims() == 0,
               ('and the crate never opens while the panel is up -- %s')
                   :format(mech.name),
               ('claims=%d'):format(#claims()))

            -- THE KEY IS STILL DOWN WHEN THE SCREEN LETS GO. Nothing may be
            -- re-pressed on its behalf: a hold wrongly resumed on a key the
            -- player has been resting on is the eight-second revive dbno.lua
            -- carries a scar from.
            closeScreen('players')
            frames(math.ceil(CHEST_MS / 16) + 10)
            ok(#claims() == 0,
               ('a key still held when the screen closes does not resume -- %s')
                   :format(mech.name),
               ('claims=%d'):format(#claims()))

            -- And a real press afterwards works, so the layer is not left deaf.
            releaseInteract()
            frames(4)
            pressInteract()
            frames(math.ceil(CHEST_MS / 16) + 10)
            ok(#claims() == 1 and claims()[1] == id,
               ('releasing and pressing again opens the crate -- %s')
                   :format(mech.name),
               ('claims=%d -- the key layer is deaf after a focus change')
                   :format(#claims()))
            releaseInteract()
            frames(20)
        end
    end

    describe('the gate survives every shape the native answers in')
    do
        -- #129'S SEVENTH ROUND, APPLIED TO THIS GATE. The suppression reads the
        -- same `down` sample every other decision in the loop reads, so a shape
        -- that breaks truth() breaks this too -- and 1/0 is the one that
        -- punishes the obvious normalisation, because 0 is truthy in Lua.
        for _, shape in ipairs(SHAPES) do
            bootOn(true, true, shape)
            fire('br:ui:clearFocus')

            openScreen('players')
            settle()
            resetCount()
            typeKey('use')
            typeKey('drop')
            local n, which = counted()
            ok(n == 0, ('nothing fires under a screen -- %s'):format(shape.name),
               ('%d fired: %s'):format(n, which))

            closeScreen('players')
            settle()
            resetCount()
            typeKey('use')
            typeKey('drop')
            local back = counted()
            ok(back == 2, ('and both come back after it -- %s'):format(shape.name),
               ('%d of 2 fired'):format(back))
        end
    end

    describe('/brkeys says whether the gate is closed')
    do
        -- "MY KEYS DO NOTHING" AND "MY KEYS DO TOO MUCH" ARE THE SAME PASTE
        -- from a chair. This line is the only thing that separates them, and a
        -- gate reported CLOSED with no menu on screen is the one failure of
        -- this change that is worse than the bug.
        bootOn(true, true)
        fire('br:ui:clearFocus')
        logged = {}
        commands['brkeys'](nil, {}, '')
        local free = table.concat(logged, '\n')
        ok(free:find('ui input', 1, true) and free:find('open', 1, true),
           'it reports the keyboard as free with nothing focused', free)

        openScreen('players')
        logged = {}
        commands['brkeys'](nil, {}, '')
        local shut = table.concat(logged, '\n')
        ok(shut:find('CLOSED', 1, true) ~= nil,
           'and as closed under a screen that owns it', shut)
        closeScreen('players')
    end
end

describe('a browser is not up until the engine says so -- client/dui.lua')
do
    -- THE FILE EVERY PROMPT IN THIS PROJECT ASKS THE SAME QUESTION OF, AND THE
    -- ONE THIS SUITE HAD NEVER LOADED.
    --
    -- Every block above stubs BR.Dui wholesale, so `BR.Dui.ready` -- the single
    -- gate between "our box, naming our key" and "the engine's help box" on the
    -- bus, on the descent and over every crate -- has been decided by the
    -- harness rather than measured. That is how #174's DUI shipped with 386
    -- green assertions and no prompt on the owner's screen.
    --
    -- LOADED LAST, because loading it replaces the stub the blocks above need.
    local avail = nil          -- what IsDuiAvailable hands back, VERBATIM
    local sends = 0
    function CreateDui() return 7 end
    function CreateRuntimeTxd(n) return n end
    function CreateRuntimeTextureFromDuiHandle() end
    function GetDuiHandle() return 'h' end
    function IsDuiAvailable() return avail end
    function SendDuiMessage() sends = sends + 1 end
    function DestroyDui() end

    loadAll({ 'br_core/client/dui.lua' })

    --- A page nobody else owns, rebuilt per case: BR.Dui.page memoises on the
    --- name and `ready` latches, so a case that reused one would be reading the
    --- previous case's answer.
    local n = 0
    local function fresh()
        n = n + 1
        return BR.Dui.page('probe' .. n, 'nui://br_ui/dui/prompt.html', 8, 8)
    end

    -- 1. A NATIVE'S ANSWER IS NOT A LUA BOOLEAN (3b42f0e). A FiveM native
    --    declared BOOL may return `true`, `1`, `false`, `nil` -- or `0`, and in
    --    Lua the number 0 is TRUTHY. Stored verbatim it latches a page that is
    --    NOT up as ready forever: the scale push is fired at a browser that
    --    cannot receive it, every draw puts a blank texture on screen, and the
    --    CALLER'S FALLBACK NEVER RUNS -- so nothing anywhere says the browser is
    --    missing. That is strictly worse than the bug this round is about,
    --    because the bus at least said something.
    --    ASSERTED THE WAY CALLERS ASK IT -- `if BR.Dui.ready(page) then` -- and
    --    not as `== false`. Nothing stores this answer, so its truthiness is the
    --    whole contract, and a shape assertion would have inflated the revert
    --    proof with two cases (`nil`, `1`) that are already correct at every
    --    call site. Exactly one of these five is a real behavioural fault, and
    --    it is `0`.
    for _, shape in ipairs({
        { v = false, name = 'false' },
        { v = nil,   name = 'nil' },
        { v = 0,     name = '0 -- a number, and truthy in Lua' },
    }) do
        local page = fresh()
        avail = shape.v
        local answer = BR.Dui.ready(page)
        ok(not answer,
            ('a browser answering %s is not ready'):format(shape.name),
            ('BR.Dui.ready answered %s, so the caller draws a blank plate and '
                .. 'skips its fallback'):format(tostring(answer)))
    end

    -- 2. AND UP IS UP, in both shapes a true answer arrives in.
    for _, shape in ipairs({
        { v = true, name = 'true' },
        { v = 1,    name = '1 -- a number' },
    }) do
        local page = fresh()
        avail = shape.v
        local answer = BR.Dui.ready(page)
        ok(answer and true or false,
            ('a browser answering %s is ready'):format(shape.name),
            tostring(answer))
    end

    -- 3. THE EDGE IS WHERE THE SCALE LANDS, and it is the reason `ready` is
    --    where that push lives at all: a message sent to a CEF instance that has
    --    not finished starting is dropped without a word, so pushing from
    --    BR.Dui.page would work on a warm reload and silently not on a cold one.
    local page = fresh()
    avail = false
    sends = 0
    BR.Dui.ready(page); BR.Dui.ready(page); BR.Dui.ready(page)
    ok(sends == 0, 'nothing is sent to a browser that has not answered yet',
        ('%d messages were sent into the void'):format(sends))

    avail = true
    ok(BR.Dui.ready(page), 'and the poll notices when it comes up')
    ok(sends == 1, 'the scale is pushed exactly once, on the not-ready->ready edge',
        ('%d pushes'):format(sends))
    BR.Dui.ready(page); BR.Dui.ready(page)
    ok(sends == 1, 'and not again on every frame after it',
        ('%d pushes after three more polls'):format(sends))

    -- 4. ONCE UP, STAYS UP. `ready` latches deliberately -- the natives are not
    --    asked again -- and a prompt that flickered back to its help-box
    --    fallback because one frame's answer came back odd would read as the
    --    box fighting itself.
    avail = false
    ok(BR.Dui.ready(page),
        'a browser that has come up is not un-readied by a later false',
        tostring(BR.Dui.ready(page)))
end

-- ======================================================================== --
-- 12. THE LOBBY REVEAL WAITS FOR THE CHARACTER STANDING IN THE SHOT
-- ======================================================================== --
--
-- THE REPORT (owner, 2026-08-18): "on the lobby screen - can we wait to fade
-- the screen in until after our target ped has fully spawned in?"
--
-- The lobby is a portrait. client/loading.lua waited for the session, for the
-- interface and for collision under the vista, and then took the loading screen
-- down and flipped worldReady -- which is what fades the lobby in -- WITHOUT
-- ever asking whether the person the shot is composed around had arrived.
-- client/locker.lua applies the stored character exactly once per session, on
-- its own asynchronous RequestModel, so the two simply raced.
--
-- WHY THIS IS TESTED WITH A REAL SCHEDULER AND NOT WITH A NO-OP Citizen.
--
-- The harness's default `Citizen.Wait = function() end` would make every wait in
-- loading.lua vanish, and a suite that erases the waits cannot say anything at
-- all about a change that ADDS one -- the reverted file and the fixed file would
-- both "pass" by running straight through. So this block installs coroutines:
-- Citizen.Wait yields the number of milliseconds it wants and `pump` advances a
-- fake clock and resumes the threads that are due. That is close enough to
-- FiveM's scheduler for the only question being asked, which is WHAT HAD TO BE
-- TRUE before the loading screen came down.
--
-- WHAT IS MEASURED IS THE CONSEQUENCE, NOT THE CALL. Nothing here asserts that
-- some readiness helper was invoked; every assertion is about
-- ShutdownLoadingScreen having happened or not happened, and about
-- BR.State.worldReady, because those two ARE the reveal. A test that checked the
-- helper ran would pass just as happily on a helper whose answer was ignored --
-- the failure this file has already had twice (see the pma-voice and the raw-key
-- notes above).
do
    describe('the lobby reveal waits for the ped')

    -- ---------------------------------------------------------- the world ---

    local prev = {
        Citizen                     = Citizen,
        DoesEntityExist             = DoesEntityExist,
        GetEntityCoords             = GetEntityCoords,
        GetHashKey                  = GetHashKey,
        GetEntityModel              = GetEntityModel,
    }

    -- The character roster, which the rest of this suite has no use for and
    -- therefore never loaded. BR.PedById is how the gate turns the stored
    -- locker id into the model it is waiting to see on the player.
    do
        local chunk, err = loadfile(ROOT .. 'br_lib/config/peds.lua')
        if not chunk then
            realPrint('\27[31mload error\27[0m peds.lua: ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end

    --- A hash that is a function of the NAME. The suite's own GetHashKey stub
    --- returns 1 for everything, which would make every model equal to every
    --- other model and the whole gate a tautology.
    local function hashOf(s)
        local h = 0
        for i = 1, #tostring(s) do h = (h * 31 + tostring(s):byte(i)) % 2147483647 end
        return h
    end

    local world = {}

    GetHashKey       = function(s) return hashOf(s) end
    DoesEntityExist  = function() return world.pedExists end
    GetEntityModel   = function()
        if world.modelThrows then error('GET_ENTITY_MODEL: no such entity', 0) end
        return world.pedModel
    end
    GetEntityCoords  = function() return world.pos end

    -- Recorded rather than stubbed away: these three ARE the reveal.
    local shut = { nui = 0, screen = 0, fadeIn = 0 }
    function ShutdownLoadingScreenNui() shut.nui = shut.nui + 1 end
    function ShutdownLoadingScreen()    shut.screen = shut.screen + 1 end
    function DoScreenFadeIn()           shut.fadeIn = shut.fadeIn + 1 end
    function IsScreenFadedOut()         return world.fadedOut end
    -- SETTABLE, because the answer decides whether this file does ANYTHING.
    -- `BR.State.worldReady = not isTrue(GetIsLoadingScreenActive())` is the
    -- first line of loading.lua and the only thing separating a fresh join from
    -- a mid-session br_core restart.
    function GetIsLoadingScreenActive()
        if world.loadscreen == nil then return true end
        return world.loadscreen
    end
    function NetworkIsSessionStarted()  return world.session end
    function HasCollisionLoadedAroundEntity() return world.collision end
    function SendLoadingScreenMessage() return true end

    -- ------------------------------------------------------- the scheduler ---

    local threads = {}
    Citizen = {
        CreateThread = function(fn)
            threads[#threads + 1] = { co = coroutine.create(fn), wake = fakeTime }
        end,
        Wait = function(ms) coroutine.yield(tonumber(ms) or 0) end,
        SetTimeout = function() end,
    }

    --- Advance the fake clock and let every thread that is due run.
    local function pump(ms)
        local target = fakeTime + ms
        while fakeTime < target do
            fakeTime = fakeTime + 50
            for _, t in ipairs(threads) do
                if coroutine.status(t.co) == 'suspended' and fakeTime >= t.wake then
                    local ran, waited = coroutine.resume(t.co)
                    if not ran then
                        realPrint('\27[31mthread error\27[0m ' .. tostring(waited))
                    end
                    t.wake = fakeTime + (tonumber(waited) or 0)
                end
            end
        end
    end

    --- A fresh join, with the world in whatever shape the caller asked for.
    ---
    --- Every scenario reloads client/loading.lua rather than sharing one boot:
    --- the file's thread runs ONCE and latches worldReady, so a second scenario
    --- against the same chunk would be measuring nothing.
    local function join(setup)
        threads = {}
        shut.nui, shut.screen, shut.fadeIn = 0, 0, 0
        logged = {}

        -- The finished state, which each scenario then breaks in exactly one
        -- place. Stating it positively means a scenario cannot pass because it
        -- happened to inherit a broken world from the one before it.
        world = {
            session   = true,
            collision = true,
            fadedOut  = false,
            pedExists = true,
            pos       = { x = BR.Config.Match.lobbyPos.x,
                          y = BR.Config.Match.lobbyPos.y, z = 17.0 },
            pedModel  = hashOf(BR.Config.Peds[1].model),
            modelThrows = false,
        }
        BR.Locker = { chosen = function() return BR.Config.Peds[1].id end }
        BR.Spawn  = { traveling = false }
        BR.State.worldReady = nil
        if setup then setup() end

        local chunk = assert(loadfile(ROOT .. 'br_core/client/loading.lua'))
        chunk()

        -- The interface's own handshake, which the first gate in the file waits
        -- on. Called one handler at a time so an unrelated module throwing
        -- cannot swallow loading.lua's, which registers last.
        for _, fn in ipairs(handlers['br:ui:ready'] or {}) do pcall(fn) end
    end

    local function said(word)
        return table.concat(logged, '\n'):find(word, 1, true) ~= nil
    end

    -- ====================================================================== --
    -- The race itself
    -- ====================================================================== --

    describe('the reveal holds while the chosen character is not on the player')
    do
        -- A FRESH JOIN HANDS YOU SOMEBODY ELSE'S PED. That is the whole
        -- mechanism: GTA gives every player a default model, locker.lua swaps it
        -- for the stored choice, and the reveal used to happen whenever it
        -- happened to happen.
        join(function() world.pedModel = hashOf('mp_m_freemode_01') end)

        pump(4000)
        ok(shut.screen == 0 and BR.State.worldReady ~= true,
           'the loading screen stays up while the default ped is still standing there',
           ('shutdowns=%d worldReady=%s after 4s'):format(
               shut.screen, tostring(BR.State.worldReady)))

        world.pedModel = hashOf(BR.Config.Peds[1].model)
        pump(1500)
        ok(shut.screen == 1 and shut.nui == 1,
           'and comes down once the character is actually on the player',
           ('shutdowns=%d nui=%d'):format(shut.screen, shut.nui))
        ok(BR.State.worldReady == true,
           'and only then does worldReady flip, which is what fades the lobby in',
           tostring(BR.State.worldReady))
        ok(said('lobby ped ready'),
           'and the console says so, so a playtest can tell waiting from luck',
           table.concat(logged, '\n'))
    end

    describe('the reveal holds while the ped is not on the lobby mark')
    do
        -- THE CAMERA IS AIMED AT COORDINATES, NOT AT THE ENTITY
        -- (client/lobbycam.lua). A correct character standing somewhere else is
        -- the "empty scene" half of the report: a menu over a hillside.
        join(function() world.pos = { x = 0.0, y = 0.0, z = 30.0 } end)

        pump(4000)
        ok(shut.screen == 0,
           'a character four kilometres from the mark is not a lobby shot',
           ('shutdowns=%d'):format(shut.screen))

        world.pos = { x = BR.Config.Match.lobbyPos.x,
                      y = BR.Config.Match.lobbyPos.y, z = 17.0 }
        pump(1500)
        ok(shut.screen == 1, 'and the reveal follows the ped onto the mark',
           ('shutdowns=%d'):format(shut.screen))
    end

    describe('the reveal does not lift a loading screen into a trip\'s own black')
    do
        -- BR.State.me.state DEFAULTS to LOBBY and the ped starts wherever GTA
        -- put it, so spawn.lua's lobby watchdog fires during the BOOT and a join
        -- routinely has a BR.Spawn.toLobby running under the loadscreen. That
        -- trip is faded OUT from its teleport until its collision wait ends --
        -- and it puts the ped on the mark BEFORE that. A gate that only asked
        -- about the ped would therefore release the last cover the player has
        -- straight into somebody else's black screen.
        join(function() BR.Spawn.traveling = true end)

        pump(4000)
        ok(shut.screen == 0,
           'a ped already on the mark is not enough while a trip still owns the screen',
           ('shutdowns=%d'):format(shut.screen))

        BR.Spawn.traveling = false
        pump(1500)
        ok(shut.screen == 1, 'and the screen is released once the trip lets go',
           ('shutdowns=%d'):format(shut.screen))
    end

    describe('the collision wait it was added behind still runs')
    do
        -- The new gate sits AFTER the world gate, and adding it must not have
        -- moved the reveal in front of the thing that was already correct.
        join(function() world.collision = false end)

        pump(20000)
        ok(shut.screen == 0,
           'a perfect ped on unstreamed ground is still not a lobby to reveal',
           ('shutdowns=%d'):format(shut.screen))

        world.collision = true
        pump(2000)
        ok(shut.screen == 1, 'and the reveal follows the ground in',
           ('shutdowns=%d'):format(shut.screen))
    end

    -- ====================================================================== --
    -- The ceiling, which is the half that matters more than the wait
    -- ====================================================================== --

    describe('a character that never arrives costs a pop, never a black screen')
    do
        -- TWO ROSTER MODELS ALREADY WERE NOT ON THE BUILD (locker.lua). A model
        -- name with a typo in it never streams, locker.apply gives up after five
        -- seconds and keeps the ped you had -- so this gate's condition can be
        -- one that is NEVER satisfied, and an unbounded wait would park that
        -- player on the gag reel for the rest of the session with nothing in any
        -- log. The governing rule of both this file and spawn.lua is that a
        -- visible cut always beats an unrecoverable screen.
        join(function() world.pedModel = hashOf('a_m_y_typo_99') end)

        pump(60000)
        ok(shut.screen == 1 and BR.State.worldReady == true,
           'the reveal gives up and happens anyway',
           ('shutdowns=%d worldReady=%s'):format(
               shut.screen, tostring(BR.State.worldReady)))
        ok(said('never settled') and said('not on the player'),
           'and the console names which half never came',
           table.concat(logged, '\n'))
    end

    describe('the wait cannot outlive a predicate that throws')
    do
        -- This runs in a bare Citizen thread with no handler above it, one step
        -- before the only code that takes the loading screen down. A readiness
        -- check that raises would stop that thread dead and leave the player on
        -- the loading screen forever -- a worse failure than the one being
        -- fixed, introduced by the fix.
        join(function() world.modelThrows = true end)

        pump(3000)
        ok(shut.screen == 1 and BR.State.worldReady == true,
           'an error in the check reveals the lobby instead of holding it',
           ('shutdowns=%d worldReady=%s'):format(
               shut.screen, tostring(BR.State.worldReady)))
        ok(said('errored'), 'and says so', table.concat(logged, '\n'))
    end

    describe('every half of the gate fails OPEN')
    do
        -- A br_core that loaded without the locker, or without the match config,
        -- must boot to a working lobby. A gate that holds on a module it cannot
        -- find is the orphaned-subsystem failure wearing a loading screen.
        join(function()
            BR.Locker = nil
            world.pos = { x = 0.0, y = 0.0, z = 30.0 }
            local keep = BR.Config.Match.lobbyPos
            BR.Config.Match.lobbyPos = nil
            -- Restored the moment the chunk has read it; the gate reads it every
            -- poll, so this really does exercise the absent case.
            BR.Spawn = nil
            world.restore = function() BR.Config.Match.lobbyPos = keep end
        end)

        pump(3000)
        ok(shut.screen == 1 and BR.State.worldReady == true,
           'no locker, no config and no spawn module still reaches the lobby',
           ('shutdowns=%d worldReady=%s'):format(
               shut.screen, tostring(BR.State.worldReady)))
        world.restore()
    end

    -- ====================================================================== --
    -- The scar: a native declared BOOL that answers with a NUMBER
    -- ====================================================================== --

    describe('DoesEntityExist is read in both shapes, and 0 is not "yes"')
    do
        -- 0 IS TRUTHY IN LUA. `if not DoesEntityExist(ped) then` reads a build
        -- that answers 0/1 as "the ped is there" on every single frame, which
        -- turns this gate into a no-op on exactly the machines it is meant to
        -- help. spawn.lua's /brblack footer already carries `== true or == 1`
        -- for this reason, and keybinds.lua carries the same scar from the raw
        -- key sample -- this is the third place it can bite.
        for _, shape in ipairs({
            { name = 'boolean false', absent = false },
            { name = 'number 0',      absent = 0 },
            { name = 'nil',           absent = nil },
        }) do
            join(function() world.pedExists = shape.absent end)

            pump(4000)
            ok(shut.screen == 0,
               ('a ped reported absent as %s is not revealed'):format(shape.name),
               ('shutdowns=%d'):format(shut.screen))

            world.pedExists = (shape.absent == 0) and 1 or true
            pump(1500)
            ok(shut.screen == 1,
               ('and it reveals when the same native says present -- %s')
                   :format(shape.name),
               ('shutdowns=%d'):format(shut.screen))
        end
    end

    describe('every wait in this file survives a native that answers 1/0')
    do
        -- THE SEVENTH INSTANCE, AND WHY IT IS TESTED HERE RATHER THAN ARGUED.
        -- The DoesEntityExist cases above cover the `if not X()` direction. The
        -- three below are the OTHER direction and the one that is easy to miss
        -- reading a diff: these are WAITS, and a wait that stops waiting still
        -- looks exactly like a wait. Every assertion is that the loading screen
        -- is STILL UP -- which is the only observable difference between a file
        -- that waited and a file that ran straight through.

        -- 1. THE GROUND. `if HasCollisionLoadedAroundEntity(p) then break end`
        --    breaks on a 0, so the gag reel that exists to cover the stream-in
        --    would be dropped 250ms into a cold load, over an island that is
        --    not there. The false/true pair of this is asserted further up; the
        --    number pair is the one that shipped.
        join(function() world.collision = 0 end)
        pump(20000)
        ok(shut.screen == 0,
           'collision answering 0 is not collision, however truthy 0 is in Lua',
           ('shutdowns=%d after 20s'):format(shut.screen))

        world.collision = 1
        pump(2000)
        ok(shut.screen == 1, 'and 1 from the same native releases it',
           ('shutdowns=%d'):format(shut.screen))

        -- 2. THE SESSION. The first gate holds the screen for up to 30s waiting
        --    for the interface AND a started session; `not NetworkIsSessionStarted()`
        --    is FALSE for a 0, so on such a build it never ran one iteration.
        join(function() world.session = 0 end)
        pump(4000)
        ok(shut.screen == 0,
           'a session reported 0 does not satisfy the wait for a session',
           ('shutdowns=%d'):format(shut.screen))

        world.session = 1
        pump(2000)
        ok(shut.screen == 1, 'and 1 does',
           ('shutdowns=%d'):format(shut.screen))

        -- 3. THE RESTART, which is the inverted one and the reason a helper is
        --    better than a habit. `not GetIsLoadingScreenActive()` is FALSE for
        --    the 0 that MEANS the loadscreen is already gone -- so a br_core
        --    restart mid-session read worldReady = false and replayed the whole
        --    boot choreography, gag reel and all, over a live world. That is the
        --    one case the line exists to prevent, defeated by the line itself.
        join(function() world.loadscreen = 0 end)
        pump(4000)
        ok(BR.State.worldReady == true and shut.screen == 0,
           'a mid-session restart with no loadscreen up replays nothing',
           ('worldReady=%s shutdowns=%d'):format(
               tostring(BR.State.worldReady), shut.screen))

        join(function() world.loadscreen = 1 end)
        pump(4000)
        ok(shut.screen == 1,
           'and a fresh join reported as 1 still gets the whole sequence',
           ('shutdowns=%d'):format(shut.screen))
    end

    -- ------------------------------------------------------------ teardown ---

    Citizen         = prev.Citizen
    DoesEntityExist = prev.DoesEntityExist
    GetEntityCoords = prev.GetEntityCoords
    GetHashKey      = prev.GetHashKey
    GetEntityModel  = prev.GetEntityModel
end

-- ------------------------------------------------------------------ report ---

-- ======================================================================== --
-- COURTESY BLIPS ARE ONCE PER MATCH (#164, item 4)
-- ======================================================================== --
--
-- Owner, 2026-08-18: "It runs exactly once per match, at most. That's it.
-- There's no logic to say we restart the courtesy blips, ever."
--
-- Two rounds of fixes here were built on a once-per-LIFE latch, and a battle
-- royale has no second life -- the only way back onto your feet is a revive. So
-- the per-life reset was the between-MATCHES reset in disguise, and the DBNO
-- special case existed only to defend against it. Both are gone: the latch is
-- cleared by the match teardown transition and by nothing else.
--
-- THE EXHAUSTIVE CASES LIVE IN tools/test_shared.lua ('loot.mercy'), which
-- sandboxes client/loot.lua on its own and can count real blip handles. This
-- block is the integration half -- the same band inside the FULL client, with
-- every other module loaded around it -- and it is deliberately short. Two
-- suites with two models of the same latch is how this file ended up with two.

describe('courtesy blips are once per match')

local function mercyToasts()
    local n = 0
    for _, e in ipairs(events) do
        if e.name == 'br:ui:sendLocal'
            and type(e.args[2]) == 'table'
            and type(e.args[2].text) == 'string'
            and e.args[2].text:find('Crates are marked', 1, true) then
            n = n + 1
        end
    end
    return n
end

--- Sit ALIVE and empty-handed until the grace expires, then read the toast.
local function waitOutGrace()
    fakeTime = fakeTime + 61000
    BR.Loop.step(BR.Loop.SLOW)
end

BR.State.me = BR.State.me or {}
BR.Inv = BR.Inv or {}
BR.Inv.lastGainAt = 0
BR.Loot.openedCount = 0

-- 1. THE BLIPS ARM ONCE for somebody who has found nothing.
events = {}
BR.State.me.state = BR.PlayerState.ALIVE
BR.Loop.step(BR.Loop.SLOW)
waitOutGrace()
ok(mercyToasts() == 1,
    'an empty-handed player is offered the courtesy blips once',
    ('toasts: %d'):format(mercyToasts()))

-- 2. AND NOT AGAIN. The expiry was never the broken half; the pass AFTER it
--    was, where the arming test `now - landedAt >= afterMs` is still true.
events = {}
waitOutGrace()
waitOutGrace()
ok(mercyToasts() == 0,
    'and never again -- the latch holds past the expiry',
    ('toasts: %d'):format(mercyToasts()))

-- 3. NO PLAYER STATE REOPENS THE WINDOW. A knock, a bleed-out, a trip through
--    the lobby: player state moves the blips on and off the map and touches
--    nothing else. There is no second life for it to reset for.
events = {}
BR.State.me.state = BR.PlayerState.DBNO
BR.Loop.step(BR.Loop.SLOW)
BR.Loop.step(BR.Loop.SLOW)
BR.State.me.state = BR.PlayerState.ALIVE
waitOutGrace()
waitOutGrace()
ok(mercyToasts() == 0,
    'A REVIVED PLAYER IS NOT OFFERED THEM AGAIN -- a knock is not a new match',
    ('toasts after a knock and revive: %d'):format(mercyToasts()))

events = {}
BR.State.me.state = BR.PlayerState.DEAD
BR.Loop.step(BR.Loop.SLOW)
BR.State.me.state = BR.PlayerState.LOBBY
BR.Loop.step(BR.Loop.SLOW)
BR.State.me.state = BR.PlayerState.ALIVE
BR.Loop.step(BR.Loop.SLOW)
waitOutGrace()
ok(mercyToasts() == 0,
    'and nor is a death -- that is what "once per MATCH" costs the old '
    .. 'per-life control, and it is the point',
    ('toasts after a death and respawn: %d'):format(mercyToasts()))

-- 4. THE MATCH TEARDOWN DOES, and it is the only thing that does. Fired here
--    the way the wire fires it, so a handler that stops listening fails this.
events = {}
TriggerEvent(BR.Net.STATE, { state = BR.MatchState.WAITING })
BR.State.me.state = BR.PlayerState.ALIVE
BR.Loop.step(BR.Loop.SLOW)
waitOutGrace()
ok(mercyToasts() == 1,
    'A NEW MATCH RE-ARMS THEM -- once per match, not once per session',
    ('toasts after a new match: %d'):format(mercyToasts()))

-- ---------------------------------------------------------------------------
-- THE TWO REPORT PROMPTS, AND THE KEY BEHIND ONE OF THEM (#177, #180)
--
-- WHY THIS IS A CLIENT TEST AND NOT A SERVER ONE. The server sends an OCCASION
-- and never a sentence -- `{ kind = 'exists' }` and `{ kind = 'killer', name }`
-- -- so tools/test_roster.lua can prove who gets a prompt and can never prove
-- what it says. Both of #180's failures were in the sentence, and #177's second
-- and third are a key name and what pressing it does. None of that is reachable
-- from the server suite.
--
-- AND THE KEY IS THE PART THAT COULD ONLY BE FOUND HERE. TAB is the inventory
-- key (#179). The prompt tells the player to press TAB, so a press has to reach
-- ONE of the two things listening for it and not both -- and nothing in either
-- file, read on its own, says which.
-- ---------------------------------------------------------------------------

describe('the report prompts say what they were told to say -- #177, #180')
do
    loadAll({ 'br_ui/client/players.lua' })

    bootOn(true, true)
    fire('br:ui:clearFocus')
    frames(3)

    -- THE PLAYER IS DEAD AND STILL LANDED, which is not a contrivance: the kill
    -- prompt arrives when you die, `BR.State.landed` stays true for the whole
    -- match (client/loot.lua says so in as many words), and canArm() in
    -- client/inventory.lua admits a landed player. So the inventory panel really
    -- does open over a corpse, and the control below asserts it -- which is what
    -- makes the "did not open" assertion afterwards worth anything.
    BR.State.me.state = BR.PlayerState.DEAD
    BR.State.landed = true

    --- The most recent toast with a given key.
    local function toast(k)
        for i = #events, 1, -1 do
            local e = events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST
               and type(e.args[2]) == 'table' and e.args[2].key == k then
                return e.args[2]
            end
        end
        return nil
    end

    local function openedInventory()
        for _, e in ipairs(events) do
            if e.name == 'br:ui:pushFocus' and e.args[1] == 'inventory' then
                return true
            end
        end
        return false
    end

    --- How many presses reached the inventory ACTION.
    ---
    --- MEASURED AT THE KEY LAYER, NOT AT THE PANEL, for the reason the focus
    --- block gives about the same question: what the panel DOES with a press is
    --- its own business and its own state. `panelOpen` is a latch with no
    --- `focusChanged` reconciler (that asymmetry IS #179), so a press can
    --- legitimately produce a popFocus rather than a push -- and an assertion
    --- written against pushFocus alone would then read "the key was swallowed"
    --- when the key had arrived perfectly. This counts arrival.
    local invPresses = 0
    BR.Keys.on('inventory', function(pressed)
        if pressed then invPresses = invPresses + 1 end
    end)

    --- Put the inventory panel away, whichever state earlier blocks left it in.
    local function shutPanel()
        fire('br:ui:action', BR.NuiCb.CLOSE)
        fire('br:ui:clearFocus')
        frames(3)
        events, sent = {}, {}
        invPresses = 0
    end

    local function corroborations()
        local n = 0
        for _, s in ipairs(sent) do
            if s.name == BR.Net.REPORT_CORROBORATE then n = n + 1 end
        end
        return n
    end

    --- One TAB, through both mechanisms, then long enough for the inventory
    --- panel's own 250ms double-fire guard to let go of it.
    local function tapTab()
        keys[0x09] = true
        edge[0x09] = true
        engineKey('TAB', true)
        frame(16)
        keys[0x09] = nil
        engineKey('TAB', false)
        frame(16)
        frames(20)
    end

    -- ------------------------------------------------------- #180, verbatim ---
    --
    -- ONE LITERAL, COPIED WHOLE OUT OF THE ISSUE, and deliberately not built by
    -- concatenation the way the source builds it. A test that assembled the
    -- sentence the same way the code does would agree with the code about where
    -- the spaces go, which is exactly the class of miss this compares against --
    -- the punctuation here is unusual on purpose (the full stop lives INSIDE the
    -- closing parenthesis) and is the owner's, not a typo to be tidied.
    local WANT = 'See something suspicious? You can report players by pressing tilde (above TAB on your keyboard.) As a bonus, all accurate reports are rewarded with Volts.'

    events = {}
    fire(BR.Net.REPORT_HINT, { kind = 'exists' })
    local t = toast('report.exists')
    ok(t ~= nil, 'the courtesy notice is raised as a toast')
    ok(t ~= nil and t.text == WANT,
        'and its text is byte-for-byte what #180 specifies',
        t and ('got: ' .. tostring(t.text)) or 'no toast')

    -- IT NAMES TILDE WHATEVER THE PLAYER HAS BOUND, which is #180 overriding
    -- #168 on the owner's call -- the sentence teaches WHERE the key is, which a
    -- resolved label cannot do. Rebinding the panel and re-pushing the keybind
    -- table must not move this sentence.
    events = {}
    fire('br:ui:sendLocal', BR.Nui.KEYBINDS, {
        actions = { { command = 'brplayers', key = 'F7', vk = 0x76 } },
    })
    fire(BR.Net.REPORT_HINT, { kind = 'exists' })
    ok((toast('report.exists') or {}).text == WANT,
        'and it does not follow a rebind of the player-list key')

    -- ------------------------------------------ #177 part 2: it says TAB ---
    events = {}
    fire(BR.Net.REPORT_HINT, { kind = 'killer', name = 'Karl' })
    local nudge = toast('report.nudge')
    ok(nudge ~= nil, 'the kill prompt is raised')
    ok(nudge ~= nil and nudge.text == 'Suspect cheating? Press TAB to report Karl.',
        'and it names TAB, not the player-list key',
        nudge and ('got: ' .. tostring(nudge.text)) or 'no toast')

    -- THAT PROMPT ARMED THE KEY, so let it time out before the key assertions
    -- below start from a known state. Leaving it live is how the first draft of
    -- this block had its own control corroborating a case.
    frame(11000)

    -- ------------------------- #177 part 3: the key IS the action ---
    --
    -- THE CONFLICT IS REAL, AND THIS IS WHERE IT IS WRITTEN DOWN. With no prompt
    -- up, TAB over a corpse opens the inventory panel -- `canArm()` admits a
    -- landed player whatever their state, so the comment in inventory.lua about
    -- never opening "over a corpse" is describing an intention. That is not
    -- fixed here (it is #179's ground), but it is the reason a corroborate
    -- action on TAB needs an arbiter at all, and it is asserted rather than
    -- assumed: without it, the next assertion could pass on a key nothing was
    -- listening for.
    shutPanel()
    tapTab()
    ok(invPresses == 1 and openedInventory(),
        'TAB over a corpse reaches the inventory and opens its panel',
        ('%d press(es), opened %s'):format(invPresses, tostring(openedInventory())))
    ok(corroborations() == 0, 'and corroborates nothing, because nothing was offered')

    -- NOW THE PROMPT, AND THE SAME PRESS.
    shutPanel()
    fire(BR.Net.REPORT_HINT, { kind = 'killer', name = 'Karl' })
    events, sent, invPresses = {}, {}, 0
    tapTab()
    ok(corroborations() == 1,
        'pressing TAB while the prompt is up submits the corroboration',
        ('%d sent'):format(corroborations()))
    ok(invPresses == 0 and not openedInventory(),
        'and the inventory never sees the press -- one key, one meaning',
        ('%d press(es), opened %s'):format(invPresses, tostring(openedInventory())))

    -- ONE PRESS, NOT A MODE. The next press goes back to the inventory even
    -- though the ten seconds have not elapsed. A claim that latched would be a
    -- key the player has lost for the rest of the prompt.
    shutPanel()
    tapTab()
    ok(corroborations() == 0 and invPresses == 1,
        'the press after that is the inventory again -- the offer was for one press',
        ('%d corroborations, %d inventory press(es)')
            :format(corroborations(), invPresses))

    -- AND IT EXPIRES WITH THE SENTENCE. A prompt nobody answered must hand the
    -- key back on its own: an unanswered offer that held TAB for the rest of the
    -- round would be a lost inventory in the next fight, with nothing on screen
    -- explaining it.
    shutPanel()
    fire(BR.Net.REPORT_HINT, { kind = 'killer', name = 'Karl' })
    frame(11000)      -- longer than the sentence is on screen
    events, sent, invPresses = {}, {}, 0
    tapTab()
    ok(corroborations() == 0 and invPresses == 1,
        'an unanswered prompt hands TAB back once its sentence has gone',
        ('%d corroborations, %d inventory press(es)')
            :format(corroborations(), invPresses))
    shutPanel()
end

-- ======================================================================== --
-- 12. THE ENGINE'S OWN FRIENDLY-FIRE GATE  (#115, round nine)
-- ======================================================================== --
--
-- WHY THIS SUITE CARRIES MORE WEIGHT THAN USUAL, stated at the top because it
-- changes what the assertions have to be:
--
--   THE OWNER CANNOT PLAYTEST THE HALF THAT MATTERS. Three clients against
--   BR.Config.Match.maxSquadSize = 4 puts all three in ONE squad, so
--   cross-squad damage -- the thing the entire game rests on and the thing
--   this change could break -- cannot be produced in game at all. (Set
--   maxSquadSize = 2 and it can: three clients become 2 + 1.) Everything
--   below the first divider exists because of that sentence.
--
--   AND EIGHT ROUNDS OF #115 WERE PINNED BY STUBS THAT AGREED WITH THE CODE.
--   So the rule the engine is believed to follow is written out HERE, once,
--   from the external record -- and every damage question is asked through it
--   rather than through natives.lua's own arithmetic. If teamFor's idea of a
--   team is wrong, `engineBlocks` gives the wrong answer and these fail; if
--   the two merely agree with each other, they still have to agree with a rule
--   nobody in this file is free to change quietly.
--
-- THE MECHANISM, so a reader knows what is being asserted. A player's ped is
-- owned by their own machine and script writes to their clone are not honoured
-- -- which is why the relationship group (2026-08-05, three times) and
-- SetEntityCanBeDamaged (2026-08-19, playtest) both failed. What DOES replicate
-- is what a client authors about ITSELF: CPlayerGameStateDataNode carries
-- `playerTeam` (six bits) and `isFriendlyFireAllowed` (one bit) alongside
-- isInvincible and the damage proofs (citizenfx/fivem, SyncTrees_Five.h). And
-- the friendly-fire setting is read inside the damage path, not the AI one --
-- GTA V has a ped config flag literally named
-- CPED_CONFIG_FLAG_IgnoreNetSessionFriendlyFireCheckForAllowDamage (442).
--
-- WHAT IS INFERRED: that the check is "same team AND the gate closed => refuse".
-- No source states it in words. Only a playtest closes that, and the shape of
-- the fix below is chosen so that a wrong inference costs solo play NOTHING.

do
    describe('the engine team gate -- #115')

    -- ----------------------------------------------------------- the engine ---

    local team = { writes = {}, last = nil }
    local gate = { writes = {}, last = nil, kind = nil }
    local invincible = nil

    function SetPlayerTeam(_, t)
        team.writes[#team.writes + 1] = t
        team.last = t
    end

    -- RECORDED WITH ITS TYPE, not coerced. These are BOOL natives and this
    -- codebase has shipped the 1-versus-true confusion four times; a stub that
    -- normalised the value would be the fifth, and would hide a gate handed a
    -- number the engine reads as "on" whichever way it was meant.
    function NetworkSetFriendlyFireOption(v)
        gate.writes[#gate.writes + 1] = v
        gate.last, gate.kind = v, type(v)
    end

    function SetPlayerInvincible(_, v) invincible = v end

    local function noop2() end
    SetCanAttackFriendly = noop2
    SetPedRelationshipGroupHash = noop2
    SetMaxWantedLevel = noop2
    SetPlayerWantedLevel = noop2
    SetPlayerWantedLevelNow = noop2
    SetCreateRandomCops = noop2
    SetCreateRandomCopsNotOnScenarios = noop2
    SetCreateRandomCopsOnScenarios = noop2
    SetEntityVisible = noop2
    FreezeEntityPosition = noop2
    DisplayRadar = noop2
    DisableFrontendThisFrame = noop2
    SetFrontendActive = noop2
    ThefeedHideThisFrame = noop2
    HideHudComponentThisFrame = noop2
    BusyspinnerIsOn = function() return false end
    BusyspinnerOff = noop2
    SetVehicleDensityMultiplierThisFrame = noop2
    SetPedDensityMultiplierThisFrame = noop2
    SetScenarioPedDensityMultiplierThisFrame = noop2
    SetRandomVehicleDensityMultiplierThisFrame = noop2
    SetParkedVehicleDensityMultiplierThisFrame = noop2
    NetworkOverrideClockTime = noop2
    PauseDeathArrestRestart = noop2
    SetFadeOutAfterDeath = noop2
    IgnoreNextRestart = noop2

    -- THE REAL natives.lua, replacing the stub table for the rest of the file.
    -- This is the last suite, so nothing downstream is measuring the stub.
    loadAll({ 'br_core/client/natives.lua' })
    local N = BR.Native

    ok(type(N.teamFor) == 'function' and type(N.SOLO_TEAM) == 'number',
        'natives.lua exposes the team decision as something testable at all',
        ('teamFor %s, SOLO_TEAM %s')
            :format(type(N.teamFor), tostring(N.SOLO_TEAM)))

    -- ==================================================================== --
    -- COULD A PED BE STANDING HERE? (#88, the rooftop report)
    -- ==================================================================== --
    --
    -- Owner, 2026-08-22: "Somehow these airdrops can happen on top of buildings
    -- where peds otherwise cannot access."
    --
    -- GetGroundZFor_3dCoord answers HEIGHT, not REACHABILITY, and no native
    -- answers reachability directly. The nearest thing is the pathfinding
    -- NAVMESH, which is the graph peds actually walk -- GET_SAFE_COORD_FOR_PED
    -- is documented entirely in terms of navmesh polygons.
    --
    -- ═══ AND THE SNAP DISTANCE IS THE SIGNAL, NOT THE BOOLEAN ═══
    --
    -- The native searches a VOLUME around the point (its own USE_FLOOD_FILL
    -- flag is documented as the alternative to "scanning all polygons within
    -- the search volume"), so standing on an un-navmeshed roof it happily finds
    -- the street thirty metres below and answers TRUE. Reading the boolean
    -- alone would pass every rooftop in Los Santos. These are the cases that
    -- say so.
    do
        describe('natives.pedReachable')

        local safe = { ok = 1, x = 0.0, y = 0.0, z = 0.0 }
        local navmesh = 1
        local asked = nil
        GetSafeCoordForPed = function(x, y, z, onlyOnPavement, flags)
            asked = { x = x, y = y, z = z,
                      onlyOnPavement = onlyOnPavement, flags = flags }
            return safe.ok, { x = safe.x, y = safe.y, z = safe.z }
        end
        IsNavmeshLoadedInArea = function() return navmesh end

        local function at(x, y, z)
            safe.x, safe.y, safe.z = x, y, z
            return N.pedReachable(0.0, 0.0, 0.0)
        end

        ok(at(0.0, 0.0, 0.0), 'a point the navmesh returns unchanged is reachable')

        -- THE ROOF. The navmesh has nothing up here, so the search volume finds
        -- the street below and hands back a coord tens of metres down. The
        -- boolean said yes; the distance says no.
        local r, why = at(0.0, 0.0, -34.0)
        ok(not r, 'a coord snapped 34m downward is a roof, whatever the BOOL said',
            tostring(why))
        ok(type(why) == 'string' and why ~= '',
            'and it says which way it was snapped, for the log')

        -- Sideways, too: a point inside a wall snaps to the corridor outside it.
        ok(not at(40.0, 0.0, 0.0), 'a coord snapped 40m sideways is not here')
        -- ...but not so tight that ordinary navmesh jitter rejects good ground.
        ok(at(0.0, 0.0, 1.0), 'a metre of vertical slack is still reachable')
        ok(at(2.0, 0.0, 0.0), 'and two metres of horizontal')

        -- A FLAT NO FROM THE NATIVE IS A NO.
        safe.ok = 0
        ok(not at(0.0, 0.0, 0.0), 'no safe coord at all is not reachable')
        safe.ok = 1

        -- ═══ 0 IS TRUTHY IN LUA AND A FIVEM BOOL MAY ANSWER 1 ═══
        --
        -- Five shipped bugs on this project. Both natives here are declared
        -- BOOL, and both are read through the normaliser.
        safe.ok = false
        ok(not at(0.0, 0.0, 0.0), 'and neither is a plain false')
        safe.ok = true
        ok(at(0.0, 0.0, 0.0), 'a plain true is a yes')
        safe.ok = 1
        ok(at(0.0, 0.0, 0.0), 'and so is a 1')

        -- ═══ FAIL OPEN WHEN THE GRAPH IS NOT THERE ═══
        --
        -- The navmesh streams like everything else and the drop is announced
        -- while the whole match is kilometres away. "I cannot see" must never
        -- read as "no" -- that would refuse every point on the map to every
        -- distant client and take the loot system with it.
        navmesh = 0
        safe.x, safe.y, safe.z = 0.0, 0.0, -500.0   -- a nonsense answer
        local nr, nwhy = N.pedReachable(0.0, 0.0, 0.0)
        ok(nr, 'an unloaded navmesh answers YES, not no')
        ok(nwhy == 'navmesh not loaded', 'and says so rather than pretending',
            tostring(nwhy))
        navmesh = 1

        -- THE FOURTH ARGUMENT IS false, AND THAT IS NOT AN ACCIDENT. The one
        -- forum thread in which a rooftop complaint was actually RESOLVED
        -- turned on it: the reporter's first attempt passed `true`
        -- (onlyOnPavement) and got (0,0,0) every time.
        safe.x, safe.y, safe.z = 0.0, 0.0, 0.0
        N.pedReachable(1.0, 2.0, 3.0)
        ok(asked and asked.onlyOnPavement == false,
            'onlyOnPavement is false -- true is what made the published fix fail')
        ok(asked and asked.flags == N.SAFE_COORD_FLAGS,
            'and the flags are the named constant, not a literal',
            tostring(asked and asked.flags))
        ok(asked and asked.x == 1.0 and asked.y == 2.0 and asked.z == 3.0,
            'and it is asked about the point it was given')

        -- A MISSING NATIVE IS TODAY'S BEHAVIOUR, not an empty map.
        local keep = GetSafeCoordForPed
        GetSafeCoordForPed = nil
        ok(N.pedReachable(0.0, 0.0, 0.0),
            'a build without the native answers yes rather than erroring')
        GetSafeCoordForPed = keep

        GetSafeCoordForPed, IsNavmeshLoadedInArea = nil, nil
    end

    -- A STAND-IN, SO A MISSING IMPLEMENTATION FAILS RATHER THAN ABORTS. Revert
    -- the production change and every assertion below should report; a suite
    -- that dies on the first nil call reports ONE number, and the revert table
    -- in the issue needs the real one.
    -- The stand-in answers with NUMBERS a real implementation can never
    -- produce, rather than nil: nil propagates into a comparison and takes the
    -- suite down with it, which is the abort this block exists to avoid.
    if type(N.teamFor) ~= 'function' then N.teamFor = function() return -999, false end end
    if type(N.SOLO_TEAM) ~= 'number' then N.SOLO_TEAM = -998 end
    if type(N.forgetTeam) ~= 'function' then N.forgetTeam = function() end end

    -- ------------------------------------------------------------ the world ---

    --- A roster mirror in the shape client/state.lua maintains: keyed by server
    --- id, entries carrying the PUBLIC fields only. `src` is NOT one of them
    --- (see PUBLIC_FIELDS in server/roster.lua), which is exactly why teamFor
    --- has to identify "me" by the KEY and not by a field on the entry -- an
    --- earlier draft that read e.src counted itself as its own squadmate and
    --- closed the gate on a solo.
    --- @param rows table  array of { src, squadId or false, state or nil }
    local function world(rows)
        local r = {}
        for _, row in ipairs(rows) do
            r[row[1]] = { name = 'P' .. row[1],
                          state = row[3] or BR.PlayerState.ALIVE }
            if row[2] then r[row[1]].squadId = row[2] end
        end
        return r
    end

    local function seat(src, r)
        local e = r[src] or {}
        return N.teamFor({ src = src, squadId = e.squadId }, r)
    end

    --- CAN A DAMAGE B, under the engine rule this change bets on.
    ---
    --- Written from the external record, not from natives.lua: same team AND a
    --- closed gate => the engine refuses to compute the hit. The gate term is
    --- `sa or sb` rather than one side's, because nothing found says WHOSE
    --- setting is read -- `isFriendlyFireAllowed` replicates per player, so it
    --- could be the shooter's or the victim's. Taking "either" is the
    --- conservative model: a fix that is correct under it is correct under
    --- both readings, and a fix that needs a particular one fails here.
    local function engineBlocks(a, b, r)
        local ta, sa = seat(a, r)
        local tb, sb = seat(b, r)
        return (ta == tb) and (sa or sb)
    end

    local function pairDetail(a, b, r)
        local ta, sa = seat(a, r)
        local tb, sb = seat(b, r)
        return ('%d: team %s gate %s   |   %d: team %s gate %s')
            :format(a, tostring(ta), sa and 'CLOSED' or 'open',
                    b, tostring(tb), sb and 'CLOSED' or 'open')
    end

    -- ==================================================================== --
    -- 1. CROSS-SQUAD PvP -- THE CASE THE OWNER CANNOT PUT ON A SCREEN
    -- ==================================================================== --

    local twoSquads = world({
        { 1, 'm7sq1' }, { 2, 'm7sq1' },
        { 3, 'm7sq2' }, { 4, 'm7sq2' },
    })

    ok(engineBlocks(1, 2, twoSquads) == true,
        'A SQUADMATE CANNOT BE SHOT: same team, gate closed -- #115',
        pairDetail(1, 2, twoSquads))

    ok(engineBlocks(1, 3, twoSquads) == false,
        'AND THE OTHER SQUAD CAN BE, which is the whole game and cannot be playtested',
        pairDetail(1, 3, twoSquads))

    ok(engineBlocks(3, 4, twoSquads) == true,
        'the rule is not about being squad 1 -- squad 2 protects its own too',
        pairDetail(3, 4, twoSquads))

    ok(engineBlocks(2, 4, twoSquads) == false,
        'and every cross-squad pair, not just the one through the squad leader',
        pairDetail(2, 4, twoSquads))

    -- OVERREACH-DETECTING, and the exact failure mode a global flag flip has:
    -- two squads that shared a team would pass every same-squad assertion above
    -- and silently end PvP.
    ok(select(1, seat(1, twoSquads)) ~= select(1, seat(3, twoSquads)),
        'TWO SQUADS ARE NEVER ON THE SAME TEAM',
        pairDetail(1, 3, twoSquads))

    -- ==================================================================== --
    -- 2. SOLOS -- TWO INDEPENDENT GUARANTEES, BECAUSE ONE IS A SINGLE POINT
    -- ==================================================================== --
    --
    -- A solo must be able to damage every player in the game. That is held up
    -- twice over on purpose: a solo shares a team with no SQUAD, and a solo
    -- also leaves the gate OPEN. Either one alone would do it; both means the
    -- default game mode survives even if the team inference is wrong.

    local mixed = world({
        { 1, false }, { 2, false },
        { 3, 'm7sq1' }, { 4, 'm7sq1' },
    })

    ok(engineBlocks(1, 2, mixed) == false,
        'TWO SOLOS CAN ALWAYS FIGHT -- they share team 0 and both gates are open',
        pairDetail(1, 2, mixed))

    ok(engineBlocks(1, 3, mixed) == false and engineBlocks(3, 1, mixed) == false,
        'A SOLO AND A SQUAD MEMBER CAN FIGHT, in both directions',
        pairDetail(1, 3, mixed))

    ok(select(1, seat(1, mixed)) == N.SOLO_TEAM
       and select(2, seat(1, mixed)) == false,
        'a solo is on the reserved solo team with the gate OPEN',
        pairDetail(1, 2, mixed))

    ok(select(1, seat(3, mixed)) ~= N.SOLO_TEAM,
        'AND NO SQUAD IS EVER GIVEN THE SOLO TEAM',
        ('squad team %s, solo team %s')
            :format(tostring(select(1, seat(3, mixed))), tostring(N.SOLO_TEAM)))

    ok(engineBlocks(3, 4, mixed) == true,
        'while the squad in the same match is still protected',
        pairDetail(3, 4, mixed))

    -- ==================================================================== --
    -- 3. A SQUAD OF ONE HAS NOBODY TO PROTECT, SO IT PROTECTS NOBODY
    -- ==================================================================== --

    local lone = world({
        { 1, 'm7sq1' },                    -- squad id, no squadmates
        { 2, false },
        { 3, 'm7sq2' }, { 4, 'm7sq2' },
    })

    ok(select(2, seat(1, lone)) == false,
        'A SQUAD OF ONE LEAVES THE GATE OPEN -- nothing to protect',
        pairDetail(1, 2, lone))

    ok(engineBlocks(1, 2, lone) == false and engineBlocks(1, 3, lone) == false,
        'so a lone squad member can be shot by a solo and by another squad',
        pairDetail(1, 3, lone))

    ok(select(1, seat(1, lone)) ~= N.SOLO_TEAM
       and select(1, seat(1, lone)) ~= select(1, seat(3, lone)),
        'and still holds a team of its own, shared with nobody',
        pairDetail(1, 3, lone))

    -- ==================================================================== --
    -- 4. THE SQUAD CHANGES UNDER THE PLAYER, MID-MATCH
    -- ==================================================================== --

    local dwindling = world({
        { 1, 'm7sq1' }, { 2, 'm7sq1' },
        { 3, 'm7sq2' },
    })
    ok(select(2, seat(1, dwindling)) == true,
        'with a live squadmate the gate is closed',
        pairDetail(1, 2, dwindling))

    -- A MATE WHO DIED IS STILL A MATE. Their entry stays in the roster with
    -- state DEAD until the match ends, and the gate stays shut over them: a
    -- corpse does not need shooting, and a gate that opened and closed as
    -- teammates died would be a gate that is wrong for a frame every time.
    dwindling[2].state = BR.PlayerState.DEAD
    ok(select(2, seat(1, dwindling)) == true,
        'a DEAD squadmate does not reopen the gate -- no flapping mid-fight',
        pairDetail(1, 2, dwindling))

    -- ...but a mate who LEFT the server is gone from the roster entirely.
    dwindling[2] = nil
    ok(select(2, seat(1, dwindling)) == false
       and engineBlocks(1, 3, dwindling) == false,
        'AND A SQUAD THAT EMPTIED OPENS THE GATE AGAIN',
        pairDetail(1, 3, dwindling))

    -- End of match: server/roster.lua clears squadId, which is a `clear` list
    -- on the delta rather than a value -- the client mirror deletes the key.
    dwindling[1].squadId = nil
    ok(select(1, seat(1, dwindling)) == N.SOLO_TEAM
       and select(2, seat(1, dwindling)) == false,
        'and a cleared squadId returns the player to the solo team, gate open',
        pairDetail(1, 3, dwindling))

    -- ==================================================================== --
    -- 5. THE WIRE IS SIX BITS WIDE
    -- ==================================================================== --
    --
    -- CPlayerGameStateDataNode reads playerTeam as a 6-bit field, so 0..63 is
    -- what replicates and a wider number would be truncated INTO SOMEBODY
    -- ELSE'S TEAM -- two strangers unable to hurt each other, silently.

    local widest, sawSolo = 0, false
    for i = 1, 70 do
        local r = world({ { 1, ('m2sq%d'):format(i) }, { 2, ('m2sq%d'):format(i) } })
        local t = seat(1, r)
        if t > widest then widest = t end
        if t == N.SOLO_TEAM then sawSolo = true end
    end
    ok(widest <= 63 and not sawSolo,
        'every squad index lands in 1..63 and never on the solo team',
        ('widest %d, hit the solo team: %s'):format(widest, tostring(sawSolo)))

    -- THE GUARD THAT WILL FIRE ON SOMEBODY ELSE'S CHANGE. Distinct teams are
    -- only needed up to the number of squads, and the worst case is every
    -- player solo-squadded. Raise maxPlayers past 63 and two squads start
    -- sharing a team; this is the line that says so.
    ok(BR.Config.Match.maxPlayers <= 63,
        'and the slot ceiling still fits inside the six-bit team field',
        ('maxPlayers %s'):format(tostring(BR.Config.Match.maxPlayers)))

    -- ==================================================================== --
    -- 6. EVERY UNKNOWN FAILS OPEN
    -- ==================================================================== --
    --
    -- The direction of the failure is the point. A wrong guess that gives two
    -- players the same team is a peace treaty nobody can see; a wrong guess
    -- that gives nobody a team is the game exactly as it shipped in e1f9f98.

    for _, bad in ipairs({ 'sq1', 'm7squad1', '', 'm7sqX', 42, true }) do
        local t, s = N.teamFor({ src = 1, squadId = bad }, {})
        ok(t == N.SOLO_TEAM and s == false,
            ('an unrecognised squad id (%s) leaves the player unteamed and armed')
                :format(tostring(bad)),
            ('team %s, gate %s'):format(tostring(t), tostring(s)))
    end

    do
        local t, s = N.teamFor(nil, nil)
        ok(t == N.SOLO_TEAM and s == false,
            'and so does having no state at all -- a cold client can still shoot',
            ('team %s, gate %s'):format(tostring(t), tostring(s)))
    end

    do
        -- A roster the client has not received yet. The team is still known
        -- from my own squad id; the gate cannot be, so it stays open.
        local t, s = N.teamFor({ src = 1, squadId = 'm7sq3' }, {})
        ok(t == 3 and s == false,
            'an empty roster mirror gives a team but never closes the gate',
            ('team %s, gate %s'):format(tostring(t), tostring(s)))
    end

    -- ==================================================================== --
    -- 7. WHAT applyGameRules ACTUALLY HANDS THE ENGINE
    -- ==================================================================== --

    local function rules(src, r, state)
        BR.State.me = { src = src, squadId = r[src] and r[src].squadId,
                        state = state or BR.PlayerState.ALIVE }
        BR.State.roster = r
        BR.State.match = { state = BR.MatchState.PLAYING }
        N.applyGameRules()
    end

    local function reset()
        team.writes, team.last = {}, nil
        gate.writes, gate.last, gate.kind = {}, nil, nil
        N.forgetTeam()
    end

    reset()
    rules(1, twoSquads)
    ok(team.last == select(1, seat(1, twoSquads)) and team.last ~= nil,
        'IN A SQUAD, THE FRAME LOOP WRITES THE SQUAD TEAM',
        ('SetPlayerTeam(%s), expected %s')
            :format(tostring(team.last), tostring(select(1, seat(1, twoSquads)))))

    ok(gate.last == false and gate.kind == 'boolean',
        'and CLOSES the gate, with a real boolean and not a 1',
        ('NetworkSetFriendlyFireOption(%s) :: %s')
            :format(tostring(gate.last), tostring(gate.kind)))

    -- THE ASSERTION THAT FAILS ON A GLOBAL FLIP, and the reason round seven's
    -- recommendation was refused twice. A solo lobby with the gate closed is a
    -- pacifist lobby, and solo is the DEFAULT MODE.
    reset()
    rules(1, mixed)
    ok(gate.last == true and gate.kind == 'boolean',
        'A SOLO LEAVES THE GATE OPEN -- PvP IS NOT SWITCHED OFF FOR THEM',
        ('NetworkSetFriendlyFireOption(%s) :: %s')
            :format(tostring(gate.last), tostring(gate.kind)))

    ok(team.last == N.SOLO_TEAM,
        'and is put on the reserved solo team rather than left wherever it was',
        ('SetPlayerTeam(%s)'):format(tostring(team.last)))

    -- The memo: the team is a synced node, so it is written on change and on a
    -- slow refresh, not sixty times a second.
    reset()
    rules(1, twoSquads)
    rules(1, twoSquads)
    rules(1, twoSquads)
    ok(#team.writes == 1,
        'the team is written once, not once a frame -- it dirties a sync node',
        ('%d write(s)'):format(#team.writes))

    fakeTime = fakeTime + 5000
    rules(1, twoSquads)
    ok(#team.writes == 2,
        'and is re-asserted on a slow refresh, because a memo is only a belief',
        ('%d write(s)'):format(#team.writes))

    reset()
    rules(1, twoSquads)
    rules(3, twoSquads)
    ok(#team.writes == 2 and team.last == select(1, seat(3, twoSquads)),
        'a change of squad is written immediately, not at the refresh',
        ('%d write(s), last %s'):format(#team.writes, tostring(team.last)))

    -- WARMUP PEACE IS A SEPARATE LEVER AND STAYS ONE. It is invincibility on
    -- the player's OWN ped -- owner-authored, which is why it has always
    -- worked -- and nothing about teams may be load-bearing for it.
    reset()
    rules(1, twoSquads, BR.PlayerState.WARMUP)
    ok(invincible == true,
        'WARMUP IS STILL GLOBAL PEACE, on its own invincibility lever',
        ('SetPlayerInvincible(%s)'):format(tostring(invincible)))

    reset()
    rules(1, mixed, BR.PlayerState.WARMUP)
    ok(invincible == true and gate.last == true,
        'including for a solo, whose gate is open the whole time',
        ('invincible %s, gate %s')
            :format(tostring(invincible), tostring(gate.last)))

    -- ==================================================================== --
    -- 8. THE ONE-LINE WAY BACK
    -- ==================================================================== --
    --
    -- The load-bearing inference cannot be settled from a desk, so the config
    -- switch is the difference between a wrong guess costing one line and a
    -- wrong guess costing a round. Pinned, because a kill switch nothing tests
    -- is a kill switch that has stopped working by the time it is needed.

    local was = BR.Config.Match.engineTeams
    BR.Config.Match.engineTeams = false
    reset()
    rules(1, twoSquads)
    ok(#team.writes == 0,
        'engineTeams = false NEVER TOUCHES SET_PLAYER_TEAM',
        ('%d write(s)'):format(#team.writes))
    ok(gate.last == true and gate.kind == 'boolean',
        'and holds the gate open exactly as e1f9f98 left it',
        ('NetworkSetFriendlyFireOption(%s)'):format(tostring(gate.last)))
    BR.Config.Match.engineTeams = was

    reset()
    rules(1, twoSquads)
    ok(gate.last == false and #team.writes == 1,
        'and turning it back on restores the gate on the next frame',
        ('gate %s, %d team write(s)')
            :format(tostring(gate.last), #team.writes))
end

-- ---------------------------------------------------------------------------
-- 'None' IS NOT A PRODUCT (owner, 2026-08-20)
--
-- "'None' smoke trail should not exist - and btw this means the default (new
-- player, new profile) should be no smoke trails at all."
--
-- THE HALF THAT IS EASY TO GET WRONG IS THE HALF THAT IS NOT A DELETION. The
-- item has to stay in BR.Config.MarketIndex -- it is what
-- BR.Config.defaultItem('trail') answers, what server/market.lua fills an empty
-- slot with, and what an un-equip resolves to -- while not being offered a tile
-- in the grid. So this pins both directions at once: gone from the shelf,
-- present in the catalogue.
-- ---------------------------------------------------------------------------

describe("'None' is not a tile in the Market, and is still the trail default")
do
    loadAll({ 'br_ui/client/market.lua' })

    --- The most recent grid pushed to the page.
    local function grid()
        for i = #events, 1, -1 do
            local e = events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.MARKET then
                return e.args[2]
            end
        end
        return nil
    end

    --- Every id of one kind on that grid, sorted so a failure prints readably.
    local function idsOf(g, kind)
        local out = {}
        for _, it in ipairs(g and g.items or {}) do
            if it.kind == kind then out[#out + 1] = it.id end
        end
        table.sort(out)
        return out
    end

    local function has(list, id)
        for _, v in ipairs(list) do if v == id then return true end end
        return false
    end

    -- A NEW PROFILE, WHICH IS THE CASE THE OWNER NAMED: nothing bought, and the
    -- server has filled the empty trail slot with the catalogue default, which
    -- is exactly what server/market.lua does on a first connect.
    fire(BR.Net.MARKET_STATE, {
        balance = 0, owned = {}, equipped = { trail = 'trail_none' },
    })

    local g = grid()
    ok(g ~= nil, 'the page is sent a grid')

    local trails = idsOf(g, BR.Config.ItemKind.TRAIL)
    ok(not has(trails, 'trail_none'),
        "a new profile is shown no 'None' tile in the smoke trail row",
        table.concat(trails, ','))
    ok(#trails == 6, 'while every trail that actually paints is still on the shelf',
        table.concat(trails, ','))

    -- THE OTHER TWO DEFAULTS ARE UNTOUCHED, and that is why the flag is per-item
    -- rather than a rule about defaults. Rainbow is the loud canopy every player
    -- already flies and Standard is a real weapon finish; both are looks somebody
    -- might choose on their merits, and hiding them would leave the canopy and
    -- finish slots with no way back from a purchase.
    ok(has(idsOf(g, BR.Config.ItemKind.CHUTE), 'chute_rainbow'),
        'the free canopy is still a tile',
        table.concat(idsOf(g, BR.Config.ItemKind.CHUTE), ','))
    ok(has(idsOf(g, BR.Config.ItemKind.WEAPON), 'wtint_normal'),
        'and so is the free weapon finish',
        table.concat(idsOf(g, BR.Config.ItemKind.WEAPON), ','))

    -- BUYING A TRAIL DOES NOT BRING IT BACK, which is the assertion that
    -- separates "hidden" from "hidden until you need it". It is stated rather
    -- than assumed because it is the behaviour with a cost: this tile was the
    -- storefront's ONLY un-equip control, so with it gone a player who buys
    -- Ember has nothing in the Market that takes it off again.
    fire(BR.Net.MARKET_STATE, {
        balance = 0, owned = { 'trail_ember' }, equipped = { trail = 'trail_ember' },
    })
    ok(not has(idsOf(grid(), BR.Config.ItemKind.TRAIL), 'trail_none'),
        'and buying Ember does not bring the tile back',
        table.concat(idsOf(grid(), BR.Config.ItemKind.TRAIL), ','))

    -- ═══ AND THE ITEM IS STILL THERE, WHICH IS THE HALF THAT IS NOT A DELETE ═══
    --
    -- Deleting the row makes defaultItem('trail') answer nil, and the trail slot
    -- then has no value to fall back to at all. br_lib/config/market.lua has the
    -- long-form record of that argument; these three lines are the mechanical
    -- version of it.
    ok(BR.Config.MarketIndex['trail_none'] ~= nil,
        'the item is still in the catalogue index')
    ok(BR.Config.defaultItem('trail') ~= nil
       and BR.Config.defaultItem('trail').id == 'trail_none',
        'and is still what the trail slot defaults to',
        tostring(BR.Config.defaultItem('trail') and BR.Config.defaultItem('trail').id))

    -- HIDING A TILE CANNOT OPEN A PURCHASE HOLE. The server resolves ids against
    -- the config rather than against whatever the client rendered, and refuses
    -- every default outright -- so an id nobody can see is not an id nobody
    -- checks.
    local item, why = BR.Config.buyable('trail_none')
    ok(item == nil and why == 'already owned by everyone',
        'and it is still refused as a purchase, tile or no tile',
        tostring(why))
end

-- ------------------------------------------------------------- drive-by ---
--
-- #197 -- A PASSENGER CANNOT FIRE FROM A SEAT.
--
-- WHAT THESE TESTS CAN AND CANNOT PROVE, FIRST, because the honest answer to
-- #197 is not a code change and pretending otherwise is how this ships green
-- and broken.
--
-- The cause is the ENGINE's own per-seat weapon rule: a seat carries a list of
-- weapon groups in its CVehicleDriveByInfo, a standard car seat lists unarmed,
-- one-handed and thrown, and a rifle is therefore taken out of the ped's hands
-- on the way into the seat. No Lua process can be asked to confirm that, and no
-- native lifts it. This file cannot prove the diagnosis.
--
-- WHAT IT CAN PROVE IS EVERYTHING WE OWN, which is exactly the half that had to
-- be ruled out before the platform could be blamed:
--
--   1. that we assert the drive-by permission on a CADENCE. It used to be set
--      only inside applyActive's arm branch, which returns early when the
--      weapon has not changed -- so the last assertion could be minutes and a
--      respawn behind the moment the player sat down. That is #197's candidate
--      1 and it is now closed by construction.
--   2. that the READOUT reaches the right verdict from a given world. Four
--      causes look identical from a passenger seat; the owner gets one command
--      and it has to name the right one, including on a build where BOOL
--      natives answer numbers.
--   3. that a diagnostic does not blame a guard that no longer exists.

describe('#197 -- the drive-by permission is asserted on a cadence, not once')
do
    bootOn(true, true)
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    inVehicle, vehicle, vehicleSeat = false, 0, nil
    disabledControls, controlsAnswerNumbers = {}, false

    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)      -- the grant lands here

    -- THE REGRESSION, STATED AS AN ASSERTION. Nothing changes from here on: no
    -- INV_SET, no slot switch, no respawn. applyActive returns on its second
    -- line for every one of these ticks -- which is precisely the state a player
    -- is in while they walk to a car, get in, and sit down.
    driveByCalls = 0
    BR.Loop.step(BR.Loop.TICK)
    BR.Loop.step(BR.Loop.TICK)
    BR.Loop.step(BR.Loop.TICK)
    ok(driveByCalls == 3,
        'the permission is re-asserted every tick with NOTHING changing',
        ('called %d times over 3 quiet ticks'):format(driveByCalls))

    -- AND ABOVE THE canArm() GATE, which is the other half of the same
    -- argument. canArm() answers "may this file put a weapon in this ped's
    -- hand" -- false for the lobby, the bus and the whole descent -- and whether
    -- a player may fire from a seat is not that question. A permission that is
    -- already true before anybody sits down cannot be late.
    BR.State.me.state = BR.PlayerState.BUS
    BR.State.landed = false
    driveByCalls = 0
    BR.Loop.step(BR.Loop.TICK)
    BR.Loop.step(BR.Loop.TICK)
    ok(driveByCalls == 2,
        'and it is still asserted in a state this file refuses to arm',
        ('called %d times in BUS'):format(driveByCalls))

    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true

    -- THE FISTS CASE, which the old placement could never reach at all: the
    -- unarmed branch of applyActive has no SetPlayerCanDoDriveBy in it and never
    -- did, so a player who spawned, drew nothing and got into a car was relying
    -- entirely on the engine's default.
    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = BR.Config.Loot.meleeSlot or 0 })
    BR.Loop.step(BR.Loop.TICK)
    driveByCalls = 0
    BR.Loop.step(BR.Loop.TICK)
    ok(driveByCalls == 1,
        'and with fists up, where the arm branch never ran',
        ('called %d times'):format(driveByCalls))
end

describe('#197 -- the verdict names the cause, and the causes are separable')
do
    local CARBINE = BR.NormHash(BR.Config.WeaponById['carbinerifle'].hash)
    local UNARMED = BR.NormHash(BR.Config.Gadgets.UNARMED)

    --- "Explicitly absent", because `{ engineHash = nil }` is an EMPTY TABLE in
    --- Lua and pairs() cannot carry a nil. Half the cases below are about a
    --- field being missing -- the engine naming no weapon at all is the shape a
    --- stow produces -- so the absence has to survive being passed around.
    local NONE = {}

    --- A world, as the readout sees it. Defaults are "an armed passenger with
    --- nothing wrong", so each case below states only what it is about.
    local function world(over)
        local f = {
            state = BR.PlayerState.ALIVE, canArm = true, panelOpen = false,
            slotIndex = 1, item = 'carbinerifle',
            wantHash = CARBINE, appliedHash = CARBINE, engineHash = CARBINE,
            driveByAt = 0, driveByCount = 900,
            inVehicle = true, blocked = nil,
        }
        for k, v in pairs(over or {}) do
            if v == NONE then f[k] = nil else f[k] = v end
        end
        return f
    end
    local function verdict(over)
        local code = BR.Inv.driveByVerdict(world(over))
        return code
    end

    -- THE ANSWER TO #197, and the shape it arrives in: our two hashes agree
    -- with each other and the ENGINE is holding nothing. The weapon is in the
    -- inventory and not in the hands.
    ok(verdict({ engineHash = UNARMED }) == 'stowed',
        'the engine holding fists over our rifle is named a STOW',
        verdict({ engineHash = UNARMED }))
    ok(verdict({ engineHash = NONE }) == 'stowed',
        'and so is the engine declining to name a weapon at all',
        verdict({ engineHash = NONE }))

    -- OURS BEFORE THEIRS. Both of the causes we can actually fix are checked
    -- before the platform is blamed, or the readout would exonerate our own bug
    -- in the exact case where it matters -- a stow and an open panel look the
    -- same from the seat.
    ok(verdict({ engineHash = UNARMED, panelOpen = true }) == 'panel',
        'an open panel is OUR bug and outranks the stow',
        verdict({ engineHash = UNARMED, panelOpen = true }))
    ok(verdict({ engineHash = UNARMED, blocked = 'VEH_PASSENGER_ATTACK' }) == 'control',
        'and so does a control something disabled',
        verdict({ engineHash = UNARMED, blocked = 'VEH_PASSENGER_ATTACK' }))

    -- CANDIDATE 1, which is what this round actually changed. If the tick that
    -- asserts the permission is dead, that is the answer and it is not the
    -- engine's fault.
    ok(verdict({ engineHash = UNARMED, driveByCount = 0 }) == 'never-asked',
        'a permission we never asserted outranks the stow too',
        verdict({ engineHash = UNARMED, driveByCount = 0 }))

    -- NOT EVERY QUESTION IS THIS QUESTION.
    ok(verdict({ inVehicle = false }) == 'onfoot',
        'on foot, there is nothing here to explain')
    ok(verdict({ canArm = false }) == 'state',
        'and a state this client will not arm is named as such')
    ok(verdict({ wantHash = NONE, item = NONE }) == 'unarmed',
        'an empty hand is not a drive-by problem')
    ok(verdict({ appliedHash = NONE }) == 'ungranted',
        'nor is a grant that has not landed yet')

    -- EVERYTHING RULED OUT IS ITS OWN ANSWER, and it has to be, because that is
    -- the readout that says "#197 is not what you think it is" -- the one case
    -- where a confident wrong verdict costs the most.
    ok(verdict({}) == 'unexplained',
        'a passenger holding what we granted, with every control live, is UNEXPLAINED')

    -- SIGNED HASHES, ON BOTH SIDES. The engine hands weapon hashes back SIGNED
    -- and the config authors them positive; twenty of the forty weapons in this
    -- game have the top bit set, and a raw comparison has already produced
    -- unlimited ammo once. Here it would produce a permanent, confident,
    -- completely wrong "THE ENGINE HAS STOWED THE WEAPON" for half the loot
    -- table -- on foot as well as in a seat.
    local signed = CARBINE - 0x100000000
    ok(verdict({ engineHash = signed }) == 'unexplained',
        'the same weapon, signed one side and unsigned the other, is not a stow',
        verdict({ engineHash = signed }))

    -- BOOLS THAT ARE NUMBERS, which is the bug this codebase has shipped four
    -- times. `0` is truthy in Lua, so an `if f.inVehicle then` would read a
    -- build's honest "no, you are not in a vehicle" as yes.
    ok(verdict({ inVehicle = 1, engineHash = UNARMED }) == 'stowed',
        'inVehicle = 1 is in a vehicle',
        verdict({ inVehicle = 1, engineHash = UNARMED }))
    ok(verdict({ inVehicle = 0, engineHash = UNARMED }) == 'onfoot',
        'and inVehicle = 0 is NOT, however truthy Lua finds it',
        verdict({ inVehicle = 0, engineHash = UNARMED }))
    ok(verdict({ panelOpen = 1, engineHash = UNARMED }) == 'panel',
        'panelOpen = 1 is an open panel',
        verdict({ panelOpen = 1, engineHash = UNARMED }))
    ok(verdict({ panelOpen = 0, engineHash = UNARMED }) == 'stowed',
        'and panelOpen = 0 is a closed one',
        verdict({ panelOpen = 0, engineHash = UNARMED }))

    -- A verdict with no world at all must still answer rather than throw: this
    -- is a diagnostic, and a diagnostic that raises has told you nothing.
    ok(select(1, BR.Inv.driveByVerdict(nil)) == 'onfoot',
        'and an empty world answers instead of throwing')
    ok(type(select(2, BR.Inv.driveByVerdict(nil))) == 'string',
        'with a sentence, always')
end

describe('#206 -- the readout accuses OUR table when the engine contradicts it')
do
    local CARBINE = BR.NormHash(BR.Config.WeaponById['carbinerifle'].hash)
    local UNARMED = BR.NormHash(BR.Config.Gadgets.UNARMED)

    --- A stowed weapon in a passenger seat -- the reported case -- with only OUR
    --- CLAIM about the seat varying. Everything else is "nothing wrong", so each
    --- assertion below is about exactly one thing.
    local function stow(permitted)
        return BR.Inv.driveByVerdict({
            state = BR.PlayerState.ALIVE, canArm = true, panelOpen = false,
            slotIndex = 1, item = 'carbinerifle',
            wantHash = CARBINE, appliedHash = CARBINE, engineHash = UNARMED,
            driveByAt = 0, driveByCount = 900,
            inVehicle = true, blocked = nil,
            permitted = permitted,
        })
    end

    -- THE EXPECTED STOW IS NOT AN ALARM. A rifle taken out of your hands in a
    -- car seat is GTA working as designed, and it is what every player will see
    -- for most of the loot table -- so it is `stowed`, plainly, whether we said
    -- the seat refuses it or nobody asked.
    ok(stow(nil) == 'stowed',
        'a stow with no claim either way is the plain GTA seat rule', stow(nil))
    ok(stow(false) == 'stowed',
        'and so is a stow we predicted', stow(false))

    -- THE ONE THAT MATTERS. We claimed this seat accepts the weapon; the engine
    -- took it away. That is the exact table entry that would have told a player
    -- to switch to a slot that does not fire, and it is the only thing in this
    -- project that can catch it -- no offline gate can read the game's .rpf.
    ok(stow(true) == 'stowed-unexpected',
        'a stow of a weapon WE said the seat accepts accuses our own table',
        stow(true))
    ok(stow(true) ~= stow(false),
        'and it is a different answer from an ordinary stow, or nobody would look')

    -- ...AND THE SENTENCE HAS TO NAME THE FIELD AND THE FILE, because the fix is
    -- a one-word edit and a verdict that does not say where is a riddle.
    local _, wrongTable = BR.Inv.driveByVerdict({
        inVehicle = true, canArm = true, wantHash = CARBINE,
        appliedHash = CARBINE, engineHash = UNARMED, driveByCount = 9,
        permitted = true,
    })
    ok(wrongTable:find('weapons.lua', 1, true) ~= nil
       and wrongTable:find('driveby', 1, true) ~= nil,
        'the accusing sentence names the file and the field to change', wrongTable)

    -- THE POSITIVE READING. This is what a pistol in a passenger seat looks
    -- like, and "nothing here explains it" would read as a failure on a readout
    -- that has just shown the seat saying yes.
    local function held(permitted)
        return BR.Inv.driveByVerdict({
            state = BR.PlayerState.ALIVE, canArm = true, panelOpen = false,
            slotIndex = 1, item = 'pistol',
            wantHash = CARBINE, appliedHash = CARBINE, engineHash = CARBINE,
            driveByAt = 0, driveByCount = 900,
            inVehicle = true, blocked = nil,
            permitted = permitted,
        })
    end
    ok(held(true) == 'armed',
        'a weapon the engine lets you keep in a seat, that we said it would, is ARMED',
        held(true))

    -- ONLY `== true` IS A CLAIM, and this is where writing `if f.permitted then`
    -- would be indistinguishable -- so it is pinned from the other side instead:
    -- neither `nil` nor `false` may be read as the claim that earns `armed`.
    ok(held(nil) == 'unexplained',
        'with no claim to credit, a held weapon is still UNEXPLAINED', held(nil))
    ok(held(false) == 'unexplained',
        'and a claim that the seat REFUSES it is not a reason to say ARMED',
        held(false))

    -- ORDER. Every cause we can fix ourselves still outranks both of these, or
    -- the readout blames a weapon table for an open panel.
    local function stowWith(permitted, over)
        local f = {
            state = BR.PlayerState.ALIVE, canArm = true, panelOpen = false,
            slotIndex = 1, item = 'carbinerifle',
            wantHash = CARBINE, appliedHash = CARBINE, engineHash = UNARMED,
            driveByAt = 0, driveByCount = 900,
            inVehicle = true, blocked = nil, permitted = permitted,
        }
        for k, v in pairs(over) do f[k] = v end
        return BR.Inv.driveByVerdict(f)
    end
    ok(stowWith(true, { panelOpen = true }) == 'panel',
        'an open panel still outranks an accusation against our table')
    ok(stowWith(true, { blocked = 'VEH_PASSENGER_ATTACK' }) == 'control',
        'and so does a control held down every frame')
    ok(stowWith(true, { driveByCount = 0 }) == 'never-asked',
        'and so does a permission we never asserted')

    -- THE PLAIN STOW STILL EXPLAINS ITSELF, and it now has to carry the tested
    -- result rather than promising an override that no longer exists: the data
    -- file was shipped, the game ignored it, and the file is gone.
    local _, plain = BR.Inv.driveByVerdict({
        inVehicle = true, canArm = true, wantHash = CARBINE,
        appliedHash = CARBINE, engineHash = UNARMED, driveByCount = 9,
        permitted = false,
    })
    ok(plain:find('IGNORED BY THE GAME', 1, true) ~= nil,
        'the ordinary stow says the data-file route was tried and refused', plain)
    ok(plain:find('br_environment', 1, true) == nil,
        'and it no longer sends anybody to a resource that ships no such file',
        plain)
end

describe('#197 -- /brdriveby measures it end to end')
do
    local CARBINE = BR.NormHash(BR.Config.WeaponById['carbinerifle'].hash)

    --- Arm the watch and let it run to its verdict.
    --- @return string  everything the command printed, as one blob
    local function run(seconds)
        logged = {}
        commands['brdriveby'](nil, { tostring(seconds or 1) }, '')
        -- frame() steps fakeTime by 16ms, which is what closes the window.
        frames(math.ceil(((seconds or 1) * 1000) / 16) + 2)
        return table.concat(logged, '\n')
    end

    bootOn(true, true)
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)

    -- THE REPORTED CASE. In a front passenger seat, holding a rifle the server
    -- issued, with the engine holding nothing.
    inVehicle, vehicle, vehicleSeat = true, 77, 0
    pedWeapon = nil
    disabledControls, controlsAnswerNumbers = {}, false
    local out = run(1)
    -- PLAIN `stowed`, AND THAT IS THE POINT OF THIS ROUND. The carbine is
    -- `driveby = false` in the weapon table, the engine stowed it, and the two
    -- agree -- so this is GTA behaving as designed rather than anything to
    -- investigate. The previous version of this assertion expected
    -- `override-ignored`, which was true right up until the playtest made the
    -- override stop existing.
    ok(out:find('VERDICT %[stowed%]') ~= nil,
        'a rifle the seat refuses, and that we agree it refuses, is a plain stow',
        out:sub(1, 400))
    -- ANCHORED TO THE ROW, NOT TO THE PAGE. The trailer explains what a seat is
    -- and therefore contains the words "front passenger" whatever seat you are
    -- actually in -- so a loose `out:find('front passenger')` passes even when
    -- the row above it says "driver". Caught by mutation: naming seat 0 the
    -- driver survived a whole test run.
    ok(out:find('seat%s+0%s+%(front passenger%)') ~= nil,
        'and the SEAT ROW names the seat, because GTA permits drive-by per seat',
        out:match('  seat[^\n]*'))
    ok(out:find('engine held the slot weapon on 0 of') ~= nil,
        'and the count of frames it was held is 0 -- not a climb-in animation')

    -- THE ENGINE NAMING FISTS is the same answer arriving in the other shape,
    -- and it is the single most load-bearing line in the readout -- it IS the
    -- stow. Printed as an unrecognised hash it would be the one row the owner
    -- skims past.
    pedWeapon = BR.Config.Gadgets.UNARMED
    out = run(1)
    ok(out:find('VERDICT %[stowed%]') ~= nil,
        'the engine naming WEAPON_UNARMED is a stow too', out:sub(1, 400))
    ok(out:find('ENGINE holds[^\n]*FISTS') ~= nil,
        'and the row says FISTS rather than an unrecognised hash',
        out:match('  ENGINE holds[^\n]*'))
    pedWeapon = nil

    -- OUR CLAIM, ON THE FACE OF THE READOUT. This row and the sample above it
    -- are the entire audit of br_lib/config/weapons.lua's `driveby` field --
    -- there is no offline check possible, because the truth is inside the
    -- game's .rpf -- so the row has to actually say which way we called it.
    ok(out:find('we say the seat%s+REFUSES it') ~= nil,
        'the readout prints our own claim about the seat, next to the engine\'s',
        out:match('  we say the seat[^\n]*'))

    -- THE HINT, PRINTED RATHER THAN WAITED FOR. It fires once a session, so
    -- without this row there is no way to see what it would have said.
    ok(out:find('drive%-by hint%s+nothing to suggest') ~= nil,
        'and with only a rifle in the bar there is nothing to suggest',
        out:match('  drive%-by hint[^\n]*'))

    -- ...AND WITH A PISTOL IN ANOTHER SLOT, THE EXACT SENTENCE. Anchored to the
    -- owner's wording: a readout that paraphrases the notice cannot be used to
    -- check the notice.
    fire(BR.Net.INV_SET, {
        slots = {
            { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 },
            { id = 'pistol',       kind = BR.ItemKind.WEAPON, clip = 12 },
        },
        ammo = {}, active = 1,
    })
    out = run(1)
    ok(out:find('Switch to slot 2 to fire your Pistol during drive%-by shootings%.') ~= nil,
        'the readout prints the notice verbatim, slot and weapon substituted',
        out:match('  drive%-by hint[^\n]*'))

    -- A WEAPON THE TABLE DOES NOT COVER AT ALL. Melee carries no `driveby`
    -- field on purpose -- no car seat reaches DRIVEBY_BIKE_MELEE -- and the
    -- absence must read as "no" rather than as a claim.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'machete', kind = BR.ItemKind.WEAPON, clip = 1 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)
    pedWeapon = BR.Config.Gadgets.UNARMED
    out = run(1)
    ok(out:find('VERDICT %[stowed%]') ~= nil,
        'a weapon with no claim at all is a plain stow, never an accusation',
        out:sub(1, 500))
    ok(out:find('we say the seat%s+REFUSES it') ~= nil,
        'and a missing field reads as REFUSES rather than as "-"',
        out:match('  we say the seat[^\n]*'))

    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)
    pedWeapon = nil

    -- The other two seats a squad car actually has. Rear seats and the driver's
    -- own seat are separate entries in the vehicle's layout with their own
    -- weapon lists, so the readout has to distinguish them or the owner cannot
    -- tell "this seat" from "this vehicle".
    vehicleSeat = -1
    ok(run(0.3):find('seat%s+%-1%s+%(driver%)') ~= nil,
        'the driver seat is named as the driver')
    vehicleSeat = 2
    ok(run(0.3):find('seat%s+2%s+%(rear seat 2%)') ~= nil,
        'and a rear seat as a rear seat')
    vehicleSeat = 0

    -- THE SAME SEAT WITH THE WEAPON ACTUALLY IN HAND is a different answer, and
    -- has to be: this is what a PISTOL looks like, and it is how the owner will
    -- tell the seat rule from a script bug in ten seconds.
    --
    -- IT IS A PISTOL AND NOT THE CARBINE, WHICH IS THE WHOLE OF THIS ROUND. The
    -- engine holding a carbine in a car seat would mean our table is wrong, and
    -- the readout says so rather than congratulating itself -- `armed` is
    -- reserved for the case where the seat and our claim AGREE.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'pistol', kind = BR.ItemKind.WEAPON, clip = 12 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)
    pedWeapon = BR.Config.WeaponById['pistol'].hash
    out = run(1)
    ok(out:find('VERDICT %[armed%]') ~= nil,
        'a pistol the engine IS holding in a seat is ARMED, not a stow',
        out:sub(1, 400))
    ok(out:find('we say the seat%s+ACCEPTS it') ~= nil,
        'and our claim on the row above agrees with it',
        out:match('  we say the seat[^\n]*'))

    -- THE OTHER DIRECTION, WHICH IS THE DANGEROUS ONE. Same seat, same held
    -- weapon, but the engine is holding a CARBINE -- a gun we say the seat
    -- refuses. Our table would be wrong, and this is the only place in the
    -- project that can notice.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)
    pedWeapon = CARBINE
    out = run(1)
    ok(out:find('we say the seat%s+REFUSES it') ~= nil
       and out:find('VERDICT %[armed%]') == nil,
        'a carbine the engine keeps is NOT called armed, because we said it would not be',
        out:match('  we say the seat[^\n]*'))

    -- A CONTROL HELD DOWN EVERY FRAME, which is #197's candidate 3. The watch
    -- has to catch it, and it has to outrank everything the engine is doing.
    disabledControls = { [69] = true }
    out = run(1)
    ok(out:find('VERDICT %[control%]') ~= nil,
        'a disabled VEH_PASSENGER_ATTACK is caught by the frame sampler',
        out:sub(1, 400))
    ok(out:find('VEH_PASSENGER_ATTACK.*DISABLED on') ~= nil,
        'and the row says so, with the frame count')

    -- ...ON A BUILD WHERE IsControlEnabled ANSWERS NUMBERS. Same world, same
    -- expected verdict. `not 0` is false in Lua, so a raw read here would report
    -- every control as enabled on every frame and hand back the wrong verdict
    -- with total confidence.
    controlsAnswerNumbers = true
    out = run(1)
    ok(out:find('VERDICT %[control%]') ~= nil,
        'and still caught when the native answers 1/0 instead of true/false',
        out:sub(1, 400))

    disabledControls, controlsAnswerNumbers = {}, false

    -- ON FOOT. The command must be runnable anywhere without lying.
    inVehicle, vehicle, vehicleSeat = false, 0, nil
    out = run(1)
    ok(out:find('VERDICT %[onfoot%]') ~= nil,
        'and on foot it says so rather than inventing a cause', out:sub(1, 400))

    -- THE READOUT ITSELF MUST NOT BE THE THING THAT BREAKS. Five throws suspend
    -- a callback in this project's loop registry, and the sampler shares its
    -- band with the weapon-wheel suppression.
    local suspended = false
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 'debug.driveby' and (s.suspended or s.errors > 0) then
            suspended = true
        end
    end
    ok(not suspended, 'and the frame sampler never threw across all of that')
end

-- --------------------------------------------- the passenger's one notice ---
--
-- #206 -- TELL A PASSENGER WHICH SLOT THEY CAN ACTUALLY FIRE.
--
-- The owner's words, and every one of the three conditions below is in them:
--
--   "if a player is in a passenger seat AND has a drive-by capable weapon, AND
--    the drive-by-capable weapon is not already selected, we should give them a
--    one-time notification (per session) that says 'Switch to slot [#] to fire
--    your [weapon] during drive-by shootings.'"
--
-- WHAT THIS SUITE CAN AND CANNOT PROVE, because the honest answer matters more
-- than a green run. It CANNOT prove that a pistol actually fires from a seat --
-- that is game data inside the .rpf and no Lua process can read it; the two
-- facts we have are a playtest (pistols yes, carbine no) and /brdriveby, which
-- audits the claim in game. What it CAN prove is everything that decides WHO is
-- told WHAT and HOW OFTEN, and a wrong answer in any of those is the failure the
-- owner named: telling a player to switch to a weapon that then does nothing.
--
-- ONE SEQUENCE FROM START TO FINISH, not six independent scenarios, and that is
-- forced by the thing under test. "Once per session" is a latch with no reset --
-- deliberately, that IS the feature -- so there is no way to give each assertion
-- a fresh session short of reloading the file, and a test-only reset would be a
-- second mechanism that could disagree with the real one. Read top to bottom.
--
-- IT STARTS WITH THE CASES THAT MUST SAY NOTHING, and that ordering is the only
-- way to prove the load-bearing half: a notice that was never due must not spend
-- the session's one delivery. Run these after the positive case and every one of
-- them passes for the wrong reason.

describe('#206 -- who gets told, and what the sentence says')
do
    --- The mirror, as BR.Inv.local_() hands it over. Written by hand rather than
    --- driven through INV_SET so each case states only what it is about.
    --- @param active integer
    local function mirror(active, ...)
        local slots = {}
        for i, id in ipairs({ ... }) do
            slots[i] = { id = id, kind = BR.ItemKind.WEAPON }
        end
        return { slots = slots, ammo = {}, active = active }
    end

    -- ═══ CONDITION 2: A WEAPON A SEAT ACCEPTS, SOMEWHERE IN THE BAR ═══
    local slot, label = BR.DriveBy.suggestion(mirror(1, 'carbinerifle', 'sniperrifle'))
    ok(slot == nil,
        'a bar with nothing a seat accepts suggests nothing',
        tostring(slot))

    slot, label = BR.DriveBy.suggestion(mirror(1, 'carbinerifle', 'pistol'))
    ok(slot == 2 and label == 'Pistol',
        'a pistol in slot 2, with a rifle selected, is slot 2 and "Pistol"',
        tostring(slot) .. ' / ' .. tostring(label))

    -- ═══ CONDITION 3: ALREADY HOLDING ONE IS SILENCE, NOT A FALLBACK ═══
    --
    -- The owner is explicit: "the drive-by-capable weapon is not already
    -- selected". A player with the pistol out has nothing to be told, and
    -- naming some OTHER slot that would also work is a notice about nothing.
    ok(BR.DriveBy.suggestion(mirror(2, 'carbinerifle', 'pistol')) == nil,
        'with the pistol already selected there is nothing to say')
    ok(BR.DriveBy.suggestion(mirror(1, 'pistol', 'microsmg')) == nil,
        'and that holds even when a SECOND acceptable weapon is in the bar')

    -- THE LOWEST SLOT WINS, which is the bar's own left-to-right order. "The
    -- best drive-by weapon" is a judgement nobody asked for.
    slot, label = BR.DriveBy.suggestion(mirror(1, 'carbinerifle', 'microsmg', 'pistol'))
    ok(slot == 2 and label == 'Micro SMG',
        'the leftmost acceptable slot is the one named', tostring(slot))

    -- THE MELEE SLOT IS 0, AND slots[0] IS nil. A player on fists must still be
    -- told, and indexing the mirror with 0 must not be the thing that stops it.
    slot = BR.DriveBy.suggestion(mirror(0, 'carbinerifle', 'pistol'))
    ok(slot == 2, 'a player on fists is told about the pistol', tostring(slot))

    -- THROWABLES ARE NOT OFFERED, and that is a decision rather than an
    -- oversight: they genuinely do work from a seat, and "fire your Smoke
    -- Grenade" is bad advice in a firefight.
    ok(BR.Config.WeaponById['grenade'].driveby == true,
        'a grenade is honestly marked as usable from a seat')
    ok(BR.DriveBy.suggestion({
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON },
                  { id = 'grenade',      kind = BR.ItemKind.THROWABLE } },
        ammo = {}, active = 1,
    }) == nil, '...and is still never the thing a passenger is told to switch to')

    -- MELEE CARRIES NO CLAIM AT ALL, and the absence must read as "no".
    ok(BR.Config.WeaponById['machete'].driveby == nil,
        'melee deliberately has no driveby field')
    ok(BR.DriveBy.suggestion(mirror(1, 'carbinerifle', 'machete')) == nil,
        'and a missing field is never mistaken for a yes')

    -- A MIRROR THAT IS NOT ONE. This runs on a tick against whatever the
    -- inventory happens to be mid-teardown; answering is mandatory, throwing is
    -- not an option.
    ok(BR.DriveBy.suggestion(nil) == nil, 'no mirror at all answers rather than throwing')
    ok(BR.DriveBy.suggestion({}) == nil, 'and neither does a mirror with no slots')

    -- ═══ THE WHOLE CLAIM, AS ONE LINE ═══
    --
    -- WHY THE EXACT SET AND NOT A SPOT CHECK. Every `true` below is a promise
    -- made to a player in a moving car, and the cost of a wrong one is the exact
    -- failure the owner named: told to switch to a slot, switched, and nothing
    -- fires. Spot-checking three of them leaves the other seven free to be
    -- "tidied" by anybody who assumes a weapon band has one answer -- and the
    -- SMG band provably does not.
    --
    -- SO CHANGING THIS LINE IS THE POINT. It is not a guard against edits; it is
    -- a demand that an edit be deliberate, and that whoever makes it has a
    -- reason better than symmetry. Nothing offline can check the values (the
    -- truth is inside the game's .rpf) -- /brdriveby from a seat is the only
    -- check there is, and the verdict `stowed-unexpected` is what it says when
    -- one of these is wrong.
    --
    -- The evidence for each is written up in docs/vehicle-data.md: GROUP_PISTOL
    -- is named as a whole group, three small SMGs are named individually, and
    -- everything else -- including the full-size SMG, the Assault SMG and the
    -- sawn-off -- is a MOTORCYCLE drive-by weapon that a car seat refuses.
    local claimed = {}
    for _, w in ipairs(BR.Config.Weapons) do
        if w.driveby == true then claimed[#claimed + 1] = w.id end
    end
    table.sort(claimed)
    ok(table.concat(claimed, ' ') ==
        'combatpistol heavypistol machinepistol microsmg minismg pistol '
        .. 'pistolmk2 revolver revolvermk2 snspistol',
        'exactly seven pistols and three small SMGs are claimed usable from a seat',
        table.concat(claimed, ' '))

    -- AND EVERY THROWABLE, because DRIVEBY_THROW is on every standard seat --
    -- honestly recorded even though a throwable is never the thing suggested.
    local thrown = 0
    for _, t in ipairs(BR.Config.Throwables) do
        if t.driveby == true then thrown = thrown + 1 end
    end
    ok(thrown == #BR.Config.Throwables,
        'and every throwable, which is a separate weapon group the seat reaches',
        ('%d of %d'):format(thrown, #BR.Config.Throwables))

    -- SIGNED HASHES, because permits() takes one straight off the engine in
    -- client/debug.lua. Twenty of the forty weapons here have the top bit set.
    local P = BR.Config.WeaponById['pistol'].hash
    ok(BR.DriveBy.permits(P) == true, 'the pistol is permitted from its positive hash')
    ok(BR.DriveBy.permits(P - 0x100000000) == true,
        'and from the SIGNED hash the engine hands back')
    ok(BR.DriveBy.permits(BR.Config.WeaponById['carbinerifle'].hash) == false,
        'the carbine is not -- which is the one thing the playtest settled')
    ok(BR.DriveBy.permits(nil) == false, 'and nothing at all is not a yes')
    ok(BR.DriveBy.permits(0x1234) == false, 'nor is a hash this gamemode never issued')
end

describe('#206 -- the notice is delivered once per session, and never twice')
do
    --- Every drive-by hint this session has produced, newest last.
    local function hints()
        local out = {}
        for _, e in ipairs(events) do
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST
               and type(e.args[2]) == 'table' and e.args[2].key == 'driveby.hint' then
                out[#out + 1] = e.args[2].text
            end
        end
        return out
    end

    bootOn(true, true)
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    inVehicle, vehicle, vehicleSeat = false, 0, nil

    -- NOTHING HAS SPENT IT YET. Asserted rather than assumed: the latch lives
    -- for the whole suite, so a future test that sits a player in a seat with a
    -- pistol in slot 2 would silently move this block's ground out from under
    -- it. This is the assertion that would fail first, and loudly.
    ok(not BR.DriveBy.shown(),
        'the session has not been told anything before this block runs')

    fire(BR.Net.INV_SET, {
        slots = {
            { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 },
            { id = 'pistol',       kind = BR.ItemKind.WEAPON, clip = 12 },
        },
        ammo = {}, active = 1,
    })

    -- ═══ CONDITION 1: IN A PASSENGER SEAT ═══

    -- ON FOOT, with exactly the inventory that would otherwise qualify.
    BR.Loop.step(BR.Loop.TICK)
    BR.Loop.step(BR.Loop.TICK)
    ok(#hints() == 0, 'a player standing on the ground is told nothing')

    -- IN A VEHICLE AND NOT IN A SEAT WE COULD NAME. The engine places nobody in
    -- seats -1..8, which is not the same fact as "front passenger" and must not
    -- be treated as one -- a wrong guess here is a notice fired at somebody
    -- climbing in through a door.
    inVehicle, vehicle, vehicleSeat = true, 77, nil
    BR.Loop.step(BR.Loop.TICK)
    ok(#hints() == 0, 'a vehicle with no seat we can name is told nothing')

    -- THE DRIVER. Seat -1 in every vehicle in the game, and the owner's
    -- condition is "a passenger seat".
    vehicleSeat = -1
    BR.Loop.step(BR.Loop.TICK)
    BR.Loop.step(BR.Loop.TICK)
    ok(#hints() == 0, 'the driver is told nothing')

    -- A PASSENGER WITH THE PISTOL ALREADY OUT. Condition 3, from the seat this
    -- time rather than through the pure function.
    vehicleSeat = 0
    fire(BR.Net.INV_SET, {
        slots = {
            { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 },
            { id = 'pistol',       kind = BR.ItemKind.WEAPON, clip = 12 },
        },
        ammo = {}, active = 2,
    })
    BR.Loop.step(BR.Loop.TICK)
    ok(#hints() == 0, 'a passenger already holding the pistol is told nothing')

    -- A PASSENGER WITH NOTHING A SEAT ACCEPTS. Condition 2.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)
    ok(#hints() == 0, 'a passenger carrying only a rifle is told nothing')

    -- A BUILD WHERE IsPedInAnyVehicle ANSWERS NUMBERS, and the honest "no" it
    -- gives is `0`. `0` IS TRUTHY IN LUA. `if IsPedInAnyVehicle(...) then` would
    -- read this as a passenger seat and fire the notice at somebody walking down
    -- the street -- and it would spend the session doing it, so they would never
    -- get it when it was true. This codebase has shipped that bug four times.
    fire(BR.Net.INV_SET, {
        slots = {
            { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 },
            { id = 'pistol',       kind = BR.ItemKind.WEAPON, clip = 12 },
        },
        ammo = {}, active = 1,
    })
    inVehicle = 0
    BR.Loop.step(BR.Loop.TICK)
    BR.Loop.step(BR.Loop.TICK)
    ok(#hints() == 0, 'inVehicle = 0 is NOT in a vehicle, however truthy Lua finds it')

    -- ...AND NONE OF THAT SPENT THE SESSION'S ONE NOTICE.
    ok(not BR.DriveBy.shown(),
        'and none of those opportunities used up the one delivery')

    -- ═══ ALL THREE CONDITIONS, AT LAST ═══
    --
    -- ON THE `1` SHAPE OF THE SAME NATIVE, which is the other half of that bug:
    -- `v == true` is just as wrong on a build that answers numbers, and it fails
    -- silently in the direction where nobody is ever told anything.
    inVehicle = 1
    BR.Loop.step(BR.Loop.TICK)

    -- THE OWNER'S SENTENCE, CHARACTER FOR CHARACTER, with the slot number and
    -- the weapon's own label substituted and NOTHING appended. No key hint, no
    -- second line -- the standing instruction on this project is that UI text is
    -- never added unsolicited, and when wording is given it is used verbatim.
    ok(#hints() == 1, 'a passenger with a pistol in slot 2 and a rifle out is told',
        tostring(#hints()))
    ok(hints()[1] == 'Switch to slot 2 to fire your Pistol during drive-by shootings.',
        'and the sentence is the owner\'s, exactly, with nothing added',
        tostring(hints()[1]))
    ok(BR.DriveBy.shown(), 'the latch is spent on DELIVERY')

    -- ═══ AND NEVER AGAIN, HOWEVER HARD THIS TRIES ═══
    --
    -- A new match, a new vehicle, a new seat, a respawn, a different weapon in a
    -- different slot. There is no `noticed = false` anywhere in that file and
    -- this is what says so.
    for _, seat in ipairs({ 0, 1, 2, 3 }) do
        vehicleSeat, vehicle = seat, 77 + seat
        fire(BR.Net.INV_SET, {
            slots = {
                { id = 'sniperrifle', kind = BR.ItemKind.WEAPON, clip = 10 },
                { id = 'microsmg',    kind = BR.ItemKind.WEAPON, clip = 16 },
            },
            ammo = {}, active = 1,
        })
        BR.Loop.step(BR.Loop.TICK)
        BR.Loop.step(BR.Loop.TICK)
    end
    BR.State.me.state = BR.PlayerState.LOBBY
    BR.Loop.step(BR.Loop.TICK)
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.Loop.step(BR.Loop.TICK)
    ok(#hints() == 1,
        'four more seats, four more vehicles, a state round trip -- still one notice',
        tostring(#hints()))

    -- THE TWO ENTRIES MOST LIKELY TO BE "TIDIED" INTO AGREEMENT, pinned. They
    -- are both SMGs and they are on opposite sides of the line: the Mini SMG
    -- fires from a car seat and the full-size SMG is a motorcycle drive-by
    -- weapon. Anybody who assumes the SMG family is one answer breaks one of
    -- these, and the failure is otherwise invisible until a player is told to
    -- switch to a gun that does nothing.
    ok(BR.DriveBy.permits(BR.Config.WeaponById['minismg'].hash) == true,
        'the mini SMG is claimed usable from a car seat')
    ok(BR.DriveBy.permits(BR.Config.WeaponById['smg'].hash) == false,
        'and the full-size SMG is not -- it is bike-only')
    ok(BR.DriveBy.permits(BR.Config.WeaponById['sawnoff'].hash) == false,
        'nor is the sawn-off, for the same reason')

    inVehicle, vehicle, vehicleSeat = false, 0, nil
end

describe('#197 -- the ammo readout does not blame a guard the loop does not have')
do
    bootOn(true, true)
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)

    -- A passenger holding the weapon the slot names. The ammo loop has no
    -- vehicle guard -- it was replaced by the GetCurrentPedWeapon check years of
    -- bugs ago -- so nothing is blocking the report, and saying "in a vehicle"
    -- here sends the reader to a branch that is not in the file.
    inVehicle = true
    pedWeapon = BR.Config.WeaponById['carbinerifle'].hash
    local s = BR.Inv.reportState()
    ok(s.blockedBy ~= 'in a vehicle',
        'a seat on its own is never given as the reason the report stopped',
        tostring(s.blockedBy))
    ok(s.inVehicle == true,
        'but the seat is still reported as a FACT, which is what it is',
        tostring(s.inVehicle))

    -- And the reason that IS true still is.
    pedWeapon = nil
    ok(BR.Inv.reportState().blockedBy == 'the ENGINE says the ped holds a different weapon',
        'a stowed weapon is named as the engine stowing it',
        tostring(BR.Inv.reportState().blockedBy))

    inVehicle = false
end

-- ======================================================================== --
-- #200. THE RADIO WHEEL IN THE DRIVER'S SEAT
-- ======================================================================== --
--
-- "while in the driver's seat, the GTA radio wheel cannot be displayed. I assume
-- it's inadvertently disabled as part of our weapon wheel hide, but not sure."
-- (owner, 2026-08-22.)
--
-- THE CONTROL NUMBERS ARE THE TEST. What opens the radio wheel is 85,
-- INPUT_VEH_RADIO_WHEEL, whose default key is Q -- and so is 141
-- (INPUT_MELEE_ATTACK_HEAVY) and so is 264 (INPUT_MELEE_ATTACK2), because GTA
-- reuses that key across contexts that cannot both apply: you do not throw
-- punches from a car seat. client/inventory.lua was disabling the on-foot half
-- of that pair on every frame of a drive.
--
-- SO THE ASSERTIONS ARE PER-FRAME AND PER-CONTROL, and both halves are pinned
-- in both contexts. A test that only proved "141 is free in a car" would pass
-- with the whole melee block deleted, which is the #134-shaped regression this
-- fix is one wrong line away from.

describe('#200 -- the radio wheel in the driver\'s seat')
do
    local RADIO_WHEEL  = 85                  -- INPUT_VEH_RADIO_WHEEL   Q
    local MELEE_ON_Q   = { 141, 264 }        -- MELEE_ATTACK_HEAVY / _2  Q
    local WEAPON_WHEEL = 37                  -- INPUT_SELECT_WEAPON     TAB
    local MELEE_SLOT   = BR.Config.Loot.meleeSlot or 0

    --- Are all of these disabled on the frame just stepped?
    local function allOff(list)
        for _, c in ipairs(list) do
            if disabled[c] ~= true then return false end
        end
        return true
    end
    local function anyOff(list)
        for _, c in ipairs(list) do
            if disabled[c] == true then return true end
        end
        return false
    end

    bootOn(true, true)
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    inVehicle = false

    -- An ordinary armed player: a carbine in slot 1, selected.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })

    -- 1. ON FOOT, ARMED. Everything the two issues care about, in one frame.
    frame(16)
    ok(disabled[WEAPON_WHEEL] == true,
       'on foot: GTA\'s weapon wheel is suppressed -- #134')
    ok(allOff(MELEE_ON_Q),
       'on foot: the melee keys are suppressed, so a rifle cannot throw a punch')
    ok(disabled[RADIO_WHEEL] ~= true,
       'and control 85 is not disabled -- this gamemode never touches it')

    -- 2. IN THE DRIVER'S SEAT. The one line that changed, and the one that
    --    must not have.
    inVehicle = true
    frame(16)
    ok(not anyOff(MELEE_ON_Q),
       'in a vehicle: the melee controls on Q are left alone, so the radio '
       .. 'wheel opens -- #200')
    ok(disabled[WEAPON_WHEEL] == true,
       'in a vehicle: the weapon wheel is STILL suppressed -- #134 does not '
       .. 'regress to buy #200')
    ok(disabled[RADIO_WHEEL] ~= true, 'and 85 is still nobody\'s business here')

    -- 3. THE BOOL SHAPES. IsPedInAnyVehicle is declared BOOL and a FiveM native
    --    declared BOOL does not have to hand Lua a boolean -- this project has
    --    shipped that mistake four times. Both directions are pinned because
    --    they fail in opposite ways and only one of them is visible.
    inVehicle = 1
    frame(16)
    ok(not anyOff(MELEE_ON_Q),
       'a native answering 1 rather than true is still IN A VEHICLE '
       .. '(1 == true is false in Lua)')

    inVehicle = 0
    frame(16)
    ok(allOff(MELEE_ON_Q),
       'and one answering 0 rather than false is still ON FOOT -- 0 is TRUTHY '
       .. 'in Lua, so the one-line normalisation would have said otherwise')

    inVehicle = nil
    frame(16)
    ok(allOff(MELEE_ON_Q),
       'a native that declines to answer resolves to ON FOOT, which is the '
       .. 'side where being wrong only costs the radio wheel')

    -- 4. WHAT THE FIX DID NOT CHANGE. Fists and a real melee weapon still
    --    swing, on foot, exactly as they did before -- the gate is the SEAT,
    --    not the slot, and these two prove it did not quietly become the slot.
    inVehicle = false
    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = MELEE_SLOT })
    frame(16)
    ok(not anyOff(MELEE_ON_Q), 'on foot with fists up, nothing is suppressed')

    fire(BR.Net.INV_SET, {
        slots = { { id = 'machete', kind = BR.ItemKind.WEAPON } },
        ammo = {}, active = 1,
    })
    frame(16)
    ok(not anyOff(MELEE_ON_Q), 'and a machete is allowed to swing')

    -- 5. AND THE SEAT IS NOT A LICENCE. An armed player who gets out is back
    --    under the suppression on the very next frame -- the block is per-frame
    --    by contract and a latch here would be the punch bug with extra steps.
    fire(BR.Net.INV_SET, {
        slots = { { id = 'carbinerifle', kind = BR.ItemKind.WEAPON, clip = 30 } },
        ammo = {}, active = 1,
    })
    inVehicle = true
    frame(16)
    ok(not anyOff(MELEE_ON_Q), 'armed and seated: free')
    inVehicle = false
    frame(16)
    ok(allOff(MELEE_ON_Q), 'armed and back on the pavement: suppressed again, '
       .. 'on the first frame')
end

-- ======================================================================== --
-- #199. THE MAP KEY
-- ======================================================================== --
--
-- "we need a new keybind - M by default. It should be a one-key press to open
-- the full screen map, same function as our 'map' button in the pause menu."
-- (owner, 2026-08-22.)
--
-- The binding row already existed and had no listener -- keybinds.lua said so in
-- as many words ("STILL DEAD AND STILL BOUND"). What is proved here is the
-- listener, the states it answers in, and that nothing hardcodes M.

describe('#199 -- the map binding')
do
    bootOn(true, true)
    -- THE KEYBOARD HAS TO BE OURS AND THE READING HAS TO HAVE SETTLED. bootOn
    -- re-announces focus, which opens the resync window -- and a rising edge
    -- inside it is ADOPTED rather than fired, deliberately (#90's strobe fix).
    -- Pressing on the next frame would measure that, not the map.
    fire('br:ui:focusChanged', 'none')
    frames(3)

    ok(keymap['M'] == 'brmap',
       'the map is registered with the engine as a bare tap on M',
       tostring(keymap['M']))

    local row
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == 'brmap' then row = b end
    end
    ok(row ~= nil, 'and it is in the table the settings screen reads')
    ok(row and row.hold == false, 'as a TAP -- one press, not a hold')
    ok(BR.Keys.boundTo('brmap') == 0x4D,
       'and the raw layer reads it on M (0x4D) by default',
       tostring(BR.Keys.boundTo('brmap')))

    --- How many times the map has been asked for since the marker.
    local function toggles(from)
        local n = 0
        for i = from + 1, #events do
            if events[i].name == 'br:ui:mapToggle' then n = n + 1 end
        end
        return n
    end

    --- One press of a key the raw layer is watching, both paths, like a client.
    local function tapKey(vk, keyName)
        keys[vk] = true
        edge[vk] = true
        engineKey(keyName, true)
        frame(16)
        keys[vk] = nil
        engineKey(keyName, false)
        frame(16)
    end

    -- ONE PRESS, ONE ASK. Two would mean the raw layer and the engine command
    -- both fired, which is the double-tap `rawActive` exists to prevent.
    BR.State.me.state = BR.PlayerState.ALIVE
    local mark = #events
    tapKey(0x4D, 'M')
    ok(toggles(mark) == 1, 'one press of M asks for the map exactly once',
       toggles(mark))

    -- EVERY STATE THE PAUSE MENU'S MAP BUTTON IS OFFERED IN, which is every
    -- state but the lobby -- PauseMenu.tsx hides the card behind `!inLobby`.
    for _, st in ipairs({
        BR.PlayerState.WARMUP, BR.PlayerState.BUS, BR.PlayerState.FREEFALL,
        BR.PlayerState.GLIDE, BR.PlayerState.ALIVE, BR.PlayerState.DBNO,
        BR.PlayerState.DEAD, BR.PlayerState.SPECTATING,
    }) do
        BR.State.me.state = st
        local m = #events
        tapKey(0x4D, 'M')
        ok(toggles(m) == 1, ('the map opens in %s'):format(st), toggles(m))
    end

    -- ...AND NOT THE LOBBY, and the reason is #122 rather than taste: the map
    -- route raises GTA's frontend, and the lobby is the one screen of ours that
    -- keeps painting through a cleared focus stack.
    BR.State.me.state = BR.PlayerState.LOBBY
    local m = #events
    tapKey(0x4D, 'M')
    ok(toggles(m) == 0, 'and not in the lobby, where the button is hidden too')

    -- NOTHING HARDCODES M. Move the row and the key moves with it -- both ways
    -- round, because a rebind that leaves the OLD key working is the same bug
    -- as one that never takes.
    BR.State.me.state = BR.PlayerState.ALIVE
    BR.Keys.set('brmap', 0x4A)          -- J
    ok(BR.Keys.boundTo('brmap') == 0x4A, 'a rebind moves the map key')

    m = #events
    tapKey(0x4D, 'M')
    ok(toggles(m) == 0, 'after the rebind, M no longer opens the map')
    m = #events
    tapKey(0x4A, 'M')                   -- the engine half is still on M
    ok(toggles(m) == 1, 'and the new key does')

    -- AND THE ENGINE SUPPRESSION FOLLOWS IT. natives.lua takes control 244
    -- (INPUT_INTERACTION_MENU, the only control whose default key is M) away
    -- only while our map binding is actually sitting on M.
    ok(BR.Keys.boundTo('brmap') ~= 0x4D,
       'with the map rebound, nothing claims M from the engine')
    BR.Keys.reset('brmap')
    ok(BR.Keys.boundTo('brmap') == 0x4D, 'and reset puts it back on M')

    -- THE REFACTOR THAT MADE boundTo EXIST MUST NOT HAVE MOVED ownsEscape.
    -- It is the gate on DisableFrontendThisFrame, and a wrong answer there is
    -- either GTA's pause menu coming back or the player having none at all.
    ok(BR.Keys.ownsEscape() == true,
       'the pause menu still owns Escape while the raw layer runs')
    BR.Keys.set('brpausemenu', 0x71)    -- F2
    ok(BR.Keys.ownsEscape() == false,
       'and gives Escape back to the engine the moment it is rebound off it')
    BR.Keys.reset('brpausemenu')
    ok(BR.Keys.ownsEscape() == true, 'and takes it back on a reset')

    -- ON A CLIENT WITH NO RAW LAYER, the ENGINE drives every row -- and boundTo
    -- has to answer with the engine's key, the one that actually works, rather
    -- than with whatever we wrote down. It is the same rule labelFor applies and
    -- it exists for the same reason: #129's third round was a prompt naming a
    -- key nothing was listening to.
    bootOn(false, false)
    ok(BR.Keys.boundTo('brmap') == 0x4D,
       'with no raw layer the map is on the ENGINE\'s M, and boundTo says so',
       tostring(BR.Keys.boundTo('brmap')))
    ok(BR.Keys.set('brmap', 0x4A) == false,
       'a rebind of an engine-driven row is refused rather than stored')
    ok(BR.Keys.boundTo('brmap') == 0x4D, 'so the key does not move')
    ok(BR.Keys.ownsEscape() == false,
       'and Escape stays the engine\'s, which is that client\'s only pause menu')

    -- AND THE TWO ANSWERS HAVE TO BE ABLE TO DIFFER, or the assertion above
    -- proves nothing -- it would pass on a boundTo that ignored the engine
    -- entirely, because a row nobody has moved sits on the same key either way.
    -- This is the real shape of #129's third round: a rebind made on a client
    -- that HAD the raw layer is still in the KVP when the profile lands on one
    -- that does not, and the engine is listening on the original key regardless.
    bootOn(true, true)
    BR.Keys.set('brmap', 0x4A)          -- J, and it really is stored this time
    ok(BR.Keys.boundTo('brmap') == 0x4A, 'with the raw layer, the rebind is the key')
    bootOn(false, false)
    ok(BR.Keys.boundTo('brmap') == 0x4D,
       'without it, the SAME stored rebind is ignored and boundTo answers with '
       .. 'the engine\'s M -- the key that actually works',
       tostring(BR.Keys.boundTo('brmap')))

    bootOn(true, true)
    fire('br:ui:focusChanged', 'none')
    frames(3)
    BR.Keys.reset('brmap')
end

-- ======================================================================== --
-- #199. THE KEY AND THE BUTTON OPEN THE SAME MAP
-- ======================================================================== --
--
-- "same function as our 'map' button in the pause menu ... find what that
-- button calls and call it."
--
-- WHY THIS LOADS br_ui. The routing decision -- bigmap, frontend or fullscreen,
-- switchable at runtime with `brmapmode` -- lives over there, and each route
-- leaves a different flag behind for the closer to find. "The key calls the same
-- function" is only worth asserting against the real three; a stub of them would
-- be a stub written to agree.
--
-- The thread openFrontendMap starts is RECORDED AND NEVER RUN, the same
-- arrangement the focus-gate block uses for br_ui's own watchdog: Citizen.Wait
-- is a no-op here, so running it would spin forever. Everything asserted below
-- happens before that thread's first Wait.

describe('#199 -- the key and the button open the same map')
do
    local nuiCb = {}
    function RegisterNUICallback(name, fn) nuiCb[name] = fn end
    local uiThreads = {}
    Citizen.CreateThread = function(fn) uiThreads[#uiThreads + 1] = fn end
    function ActivateFrontendMenu() end
    function PauseMenuceptionGoDeeper() end
    function PauseMenuceptionTheKick() end
    function SetFrontendActive() end
    function IsPauseMenuRestarting() return false end
    local fullscreenArg = nil
    function PauseToggleFullscreenMap(on) fullscreenArg = on end
    -- The bigmap route goes through the REAL br_core/client/natives.lua, which
    -- is loaded by the suite above -- br_core owns the radar, so br_core owns
    -- the expansion. These three are the only pieces of it a Lua process cannot
    -- supply: the engine call itself and the notice stack that lives in
    -- client/state.lua, which this harness does not load.
    function SetBigmapActive() end
    BR.Notify = function() end
    BR.NotifyClear = function() end

    local coreName = GetCurrentResourceName
    GetCurrentResourceName = function() return 'br_ui' end
    loadAll({ 'br_ui/client/pause.lua' })
    GetCurrentResourceName = coreName

    --- How many times the frontend route has been raised since the marker.
    local function raises(from)
        local n = 0
        for i = from + 1, #events do
            local e = events[i]
            if e.name == 'br:map:frontend' and e.args[1] == true then n = n + 1 end
        end
        return n
    end

    local function pressButton()
        nuiCb[BR.NuiCb.PAUSE_ACTION]({ action = 'map' }, function() end)
    end
    local function pressKey() fire('br:ui:mapToggle') end

    ok(BR.Pause.mapMode == 'frontend',
       'the default route is still the engine frontend, driven to its map page',
       tostring(BR.Pause.mapMode))
    ok(BR.Pause.closeMap() == false,
       'with no map up, the closer says there was nothing to close')

    -- 1. THE BUTTON. What it did before this change, unchanged.
    local m = #events
    pressButton()
    ok(raises(m) == 1, 'the pause menu button raises the frontend map')

    -- 2. THE KEY, ON THE SAME STATE. It finds the map already up and takes it
    --    down rather than opening a second one -- which is the observable proof
    --    that both went through the same flag rather than through two copies of
    --    the routing.
    m = #events
    pressKey()
    ok(raises(m) == 0, 'the map key on an open map does not raise a second one')
    ok(BR.Pause.closeMap() == false, 'because it closed the one that was up')

    -- 3. THE KEY, FROM NOTHING. Identical effect to the button.
    m = #events
    pressKey()
    ok(raises(m) == 1, 'and from a closed map the key opens exactly what the '
       .. 'button opens')
    pressKey()

    -- 4. THE OTHER TWO ROUTES. `brmapmode` is switchable in game, so the key
    --    has to work whichever one the owner is comparing -- and each leaves its
    --    own flag, which is precisely why there is one closer and not three.
    BR.Pause.mapMode = 'bigmap'
    m = #events
    pressKey()
    ok(BR.Pause.bigmap == true, 'in bigmap mode the key expands the minimap')
    pressKey()
    ok(BR.Pause.bigmap == false, 'and the same key puts it away')

    -- ...AND THE BUTTON GOES THROUGH THE SAME ROUTING, which is the assertion a
    -- second implementation written for the key would fail. Pressing the card in
    -- bigmap mode has to expand the minimap and raise no frontend at all.
    m = #events
    pressButton()
    ok(BR.Pause.bigmap == true and raises(m) == 0,
       'the button honours brmapmode too -- one opener, not two',
       ('bigmap %s, frontend raises %d'):format(tostring(BR.Pause.bigmap), raises(m)))
    pressKey()
    ok(BR.Pause.bigmap == false, 'and the key closes what the button opened')

    BR.Pause.mapMode = 'fullscreen'
    fullscreenArg = nil
    pressKey()
    ok(BR.Pause.fullscreenMap == true and fullscreenArg == true,
       'in fullscreen mode the key toggles the map on')
    pressKey()
    ok(BR.Pause.fullscreenMap == false and fullscreenArg == false,
       'and off again')

    -- 5. THE PAUSE KEY STILL CLOSES A MAP FIRST, which is the behaviour the
    --    extraction of closeMap() could most easily have dropped: it was three
    --    inline branches in that handler and is now one call.
    BR.Pause.mapMode = 'bigmap'
    pressKey()
    ok(BR.Pause.bigmap == true, 'with a big map up...')
    fakeTime = fakeTime + 1000          -- past the pause key's own 220ms guard
    fire('br:ui:pauseToggle')
    ok(BR.Pause.bigmap == false,
       '...Escape takes the map down rather than opening the pause menu')

    BR.Pause.mapMode = 'frontend'
end

-- ======================================================================== --
-- #199. AND GTA'S OWN M IS TAKEN AWAY WHILE OURS IS ON IT
-- ======================================================================== --
--
-- The issue calls M "GTA's own expanded-map key". It is not: per the FiveM
-- controls reference the only control whose default key is M is 244,
-- INPUT_INTERACTION_MENU -- GTA Online's interaction menu, which a FiveM server
-- does not run. So the suppression is insurance rather than a known fix, and the
-- thing worth pinning is not that 244 is disabled but that it FOLLOWS THE
-- BINDING: hardcoding it would be the same mistake as hardcoding the key.
--
-- This drives client/natives.lua's per-frame rules directly. It is not on
-- BR.Loop -- gamerules.lua calls it, and that file is not in this harness -- so
-- a frame() would not reach it.

describe('#199 -- GTA\'s own M, while ours is on it')
do
    BR.State.me = { src = 1, state = BR.PlayerState.ALIVE }
    BR.State.roster = {}
    BR.State.match = { state = BR.MatchState.PLAYING }
    local INTERACTION_MENU = 244

    local function rulesFrame()
        disabled = {}
        BR.Native.applyGameRules()
    end

    BR.Keys.reset('brmap')
    rulesFrame()
    ok(disabled[INTERACTION_MENU] == true,
       'with our map on M, control 244 is taken from the engine so one press '
       .. 'cannot drive two things')

    BR.Keys.set('brmap', 0x4A)          -- J
    rulesFrame()
    ok(disabled[INTERACTION_MENU] ~= true,
       'move the map off M and the engine gets 244 back -- the suppression '
       .. 'follows the binding, it is not a constant')

    BR.Keys.set('brmap', nil)           -- deliberately unbound
    rulesFrame()
    ok(disabled[INTERACTION_MENU] ~= true,
       'and an unbound map claims nothing at all')

    BR.Keys.reset('brmap')
    rulesFrame()
    ok(disabled[INTERACTION_MENU] == true, 'reset puts both back')

    -- AND IT IS NOT COLLATERAL. 20 and 48 are the two controls that DO expand
    -- the radar (INPUT_MULTIPLAYER_INFO / INPUT_HUD_SPECIAL, both on Z) and
    -- neither is ours to take.
    ok(disabled[20] ~= true and disabled[48] ~= true,
       'the controls that actually expand the radar are left alone')
end


-- ======================================================================== --
-- #207. THE MAP KEY KEEPS OPENING THE MAP, HOWEVER THE LAST ONE CLOSED
-- ======================================================================== --
--
-- THE REPORT: "after opening the map a few times using M, I can no longer open
-- the map. No errors either. Is it maybe because I didn't use M to dismiss it
-- but instead right clicked? That's the game's default 'dismiss' button which
-- should still be an option. Same with ESC." (owner, 2026-08-22.)
--
-- THE BUG WAS IN CODE NO TEST COULD REACH, AND THAT IS THE REAL FINDING. The
-- block above this one says so in as many words -- "the thread openFrontendMap
-- starts is RECORDED AND NEVER RUN ... Citizen.Wait is a no-op here, so running
-- it would spin forever. Everything asserted below happens before that thread's
-- first Wait." Everything that broke happened AFTER it. The suite proved the key
-- and the button went through one flag and stopped exactly where the exit
-- watcher began.
--
-- SO THE FIX SHIPPED WITH A SHAPE CHANGE: the watcher is BR.Pause.mapStep(st),
-- one frame per call, and the thread is `while mapStep(st) do Wait(0) end` and
-- nothing else. There is no Wait inside a step, so this block drives the
-- watcher frame by frame with the game answering whatever it likes -- a menu
-- that never comes up, a menu that vanishes on its own, a second raise landing
-- on top of the first. None of those was reachable before and the middle one is
-- the report.
--
-- WHAT THE HARNESS MODELS THAT THE OLD ONE DID NOT: IsPauseMenuActive is a
-- variable here rather than `return false`. The map's state is now DERIVED from
-- it, so a test that could not move it could not test the derivation.

describe('#207 -- the map opens again however the last one was dismissed')
do
    --- HOW THIS BUILD SHAPES A BOOL. Flipped to numbers for the last block:
    --- a FiveM BOOL native may answer 1 rather than true, `1 == true` is false
    --- and `0` is TRUTHY -- which this project has shipped four times.
    local shape = { yes = true, no = false }
    local function B(v) return v and shape.yes or shape.no end

    local menuActive, restarting, escDown = false, false, {}
    local ctrl = {}
    local deactivations = 0

    IsPauseMenuActive     = function() return B(menuActive) end
    IsPauseMenuRestarting = function() return B(restarting) end
    -- The game's own answer to SET_FRONTEND_ACTIVE(false) is that the menu
    -- goes away. Modelling that rather than counting calls is what makes the
    -- settle phase mean anything: an assertion about a counter would pass
    -- against a settle that never took the menu down.
    SetFrontendActive = function(on)
        deactivations = deactivations + 1
        if on == false then menuActive = false end
    end
    IsRawKeyDown = function(vk) return B(escDown[vk] == true) end
    IsControlJustPressed         = function(_, c) return B(ctrl[c] == true) end
    IsDisabledControlJustPressed = function(_, c) return B(ctrl[c] == true) end

    --- The raise currently being stepped. openFrontendMap publishes it.
    local live = nil

    local function raisesSince(from)
        local n = 0
        for i = from + 1, #events do
            local e = events[i]
            if e.name == 'br:map:frontend' and e.args[1] == true then n = n + 1 end
        end
        return n
    end

    local function lastFrontendEvent()
        for i = #events, 1, -1 do
            if events[i].name == 'br:map:frontend' then return events[i].args[1] end
        end
    end

    --- What the PAGE was last told about who owns the screen.
    ---
    --- WORTH ITS OWN ASSERTIONS BECAUSE THE FAILURE IS CATASTROPHIC. App.tsx
    --- puts the entire NUI document at `opacity: 0, pointerEvents: none` while
    --- this is true -- health, inventory, kill feed, everything. A map exit
    --- that forgets to lower it leaves the player looking at Los Santos with no
    --- interface at all and no key that brings it back, which is a great deal
    --- worse than the map not opening.
    local function pageHidden()
        for i = #events, 1, -1 do
            local e = events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.FRONTEND then
                return e.args[2] and e.args[2].up
            end
        end
    end

    local function pressKey()
        fakeTime = fakeTime + 300          -- past the pause key's own 220ms guard
        fire('br:ui:mapToggle')
        if BR.Pause.map then live = BR.Pause.map end
    end

    --- Step the live raise, one frame per iteration, stopping when it is done.
    --- @return boolean  whether the watcher still has work
    local function step(n)
        local more = true
        for _ = 1, (n or 1) do
            fakeTime = fakeTime + 16
            more = BR.Pause.mapStep(live)
            if not more then break end
        end
        return more
    end

    --- Back to nothing at all, by the honest road rather than by reaching in.
    ---
    --- Every flag this suite drives is a file-local in pause.lua, so a block
    --- cannot start by assigning them -- it has to leave the previous map the
    --- way a player would. Which is worth having: a reset that could not be
    --- expressed as "tell the game the menu is gone and let the code reconcile"
    --- would be evidence the reconciliation does not work.
    local function reset()
        menuActive, restarting, escDown, ctrl = false, false, {}, {}
        if live then
            fakeTime = fakeTime + 400
            for _ = 1, 400 do
                if BR.Pause.mapStep(live) == false then break end
                fakeTime = fakeTime + 16
            end
        end
        while BR.Pause.closeMap() do end
        live = nil
        deactivations = 0
    end

    --- A map that is genuinely up: key pressed, menu on screen, page committed.
    local function openMap()
        reset()
        pressKey()
        step()                 -- raising, and the game has not caught up yet
        menuActive = true
        step()                 -- raising -> paging, and the game is believed now
        step()                 -- paging  -> watching
        return live
    end

    BR.Pause.mapMode = 'frontend'

    -- ------------------------------------------------------------------- --
    -- 1. THE REPORT, REPRODUCED. The frontend dismisses ITSELF.
    -- ------------------------------------------------------------------- --
    --
    -- Right-click is the frontend's own BACK and Escape is its own cancel; both
    -- are handled inside the scaleform, and the watcher only ever INFERRED them
    -- from a list of control ids its own comment calls "broad rather than
    -- precise" because "right mouse cannot be read raw". This is that list
    -- missing: nothing our end sees, and the menu gone.
    openMap()
    ok(live.phase == 'watching',
       'the map comes up and is watched', tostring(live.phase))

    ok(pageHidden() == true, 'and our page is standing down for it')

    menuActive = false                 -- and not one control we watch fired
    ok(step(20) == false,
       'the watcher notices the GAME took the map away, with no input at all')
    ok(lastFrontendEvent() == false,
       'br_core gets its frontend suppression back')
    ok(pageHidden() == false,
       'and the page is told it may draw again -- a HUD left hidden is worse '
       .. 'than the map not opening')

    local m = #events
    pressKey()
    ok(raisesSince(m) == 1,
       'AND THE NEXT M PRESS OPENS THE MAP -- which is the whole report',
       ('raises %d'):format(raisesSince(m)))
    step(3)

    -- ------------------------------------------------------------------- --
    -- 2. THE SAME THING WITH NO WATCHER RUNNING AT ALL.
    -- ------------------------------------------------------------------- --
    --
    -- The orphaned-watcher case, which is what a real client had: the loop
    -- `while frontendMap and not wantsOut()` could not end, because the only
    -- two things that ended it were our own flag and an input list that had
    -- already missed. So the flag sat raised over a menu that was not there and
    -- closeMap answered every press with "yes, there was a map" -- lowering a
    -- flag nobody was watching and returning, with nothing on screen to show
    -- for it. No error, because nothing errored.
    openMap()
    menuActive = false
    fakeTime = fakeTime + 300          -- and the watcher never gets a frame
    ok(BR.Pause.closeMap() == false,
       'a flag left up over a menu that has gone does not consume the press')
    ok(BR.Pause.mapStep(live) == false,
       'and the orphaned watcher is retired rather than left spinning')

    m = #events
    pressKey()
    ok(raisesSince(m) == 1, 'so M opens, exactly as the player expected')
    step(3)

    -- ...AND SO DOES THE BUTTON, which is a SECOND door onto the same stale
    -- flag. The Map card calls openMap directly and does NOT go through
    -- closeMap first, so a reconciliation that lived only in closeMap would
    -- leave the button dead in exactly the state that killed the key -- the
    -- shape #138 is filed under ("PUBLIC BECAUSE THERE WAS A FOURTH DOOR").
    reset()
    pressKey()
    step()
    menuActive = true
    step(2)                            -- a map genuinely up, and then...
    menuActive = false                 -- ...gone, with nothing watching
    fakeTime = fakeTime + 300
    m = #events
    -- BR.Pause.openMap() is where the Map card's PAUSE_ACTION branch ends up;
    -- the block above already pins that the card and the key reach this one
    -- function, so driving it here is driving the button's far end.
    BR.Pause.openMap()
    ok(raisesSince(m) == 1,
       'the pause menu Map BUTTON opens over a stale flag too',
       ('raises %d'):format(raisesSince(m)))
    live = BR.Pause.map
    step(3)

    -- ------------------------------------------------------------------- --
    -- 3. RIGHT-CLICK AND ESCAPE STILL DISMISS, WHICH THE OWNER ASKED FOR BY
    --    NAME. "That's the game's default dismiss button which should still be
    --    an option. Same with ESC."
    -- ------------------------------------------------------------------- --
    for _, c in ipairs({ 202, 200, 199, 177, 194, 25 }) do
        openMap()
        ctrl = { [c] = true }
        deactivations = 0
        step()
        ok(live.phase == 'settling',
           ('exit control %d still takes the map down'):format(c),
           tostring(live.phase))
        -- ON THE SAME FRAME, not on the next one. The frontend has to come
        -- down where the player asked for it to; leaving it for the settle's
        -- re-assert loop to notice would show them one more frame of a menu
        -- they have already dismissed.
        ok(deactivations >= 1 and menuActive == false,
           ('control %d deactivates the frontend on the frame it is pressed')
               :format(c),
           ('%d calls, menu %s'):format(deactivations, tostring(menuActive)))

        -- AND THE RE-ASSERT IS REAL. "The same press that got us here is still
        -- being handled by the scaleform, which can bring the menu straight
        -- back on the next frame" -- so a menu that comes back during the
        -- settle has to be put down again rather than left up with the watcher
        -- already gone.
        ctrl = {}
        menuActive = true              -- the scaleform bounces it back
        step(3)
        ok(menuActive == false,
           ('and a menu that flickers back during the settle is put down again '
            .. '(after control %d)'):format(c))
        step(60)
    end

    openMap()
    escDown = { [0x1B] = true }        -- raw Escape, which the frontend cannot eat
    step()
    ok(live.phase == 'settling', 'raw Escape still dismisses the map')
    escDown = {}
    step(60)
    ok(BR.Pause.closeMap() == false, 'and leaves nothing behind')

    -- AND M ITSELF, WHICH CLOSES BY LOWERING THE FLAG RATHER THAN BY BEING
    -- SEEN. The key never reaches the watcher's input list at all -- br_core
    -- routes it to closeMap, which drops the flag and lets the watcher find it
    -- dropped. So "the watcher acts on our flag coming down" is a separate
    -- path from "the watcher saw a button", and it is the one that has to end
    -- in a deactivated frontend: nothing else in the file will take GTA's menu
    -- off the screen.
    openMap()
    deactivations = 0
    pressKey()                         -- M on an open map is a close
    ok(BR.Pause.mapStep(live) == true and live.phase == 'settling',
       'the map key lowering the flag sends the watcher to settle',
       tostring(live.phase))
    ok(deactivations >= 1 and menuActive == false,
       'and GTA\'s menu is actually taken off the screen, not just forgotten',
       ('%d calls, menu %s'):format(deactivations, tostring(menuActive)))
    step(60)
    ok(pageHidden() == false, 'with the page handed back')

    -- ------------------------------------------------------------------- --
    -- 4. A PRESS DURING THE SETTLE IS NOT EATEN.
    -- ------------------------------------------------------------------- --
    --
    -- The half-second re-assert exists because "the same press that got us here
    -- is still being handled by the scaleform". It used to hold the map's flag
    -- up for that whole half second, so dismissing the map and pressing M
    -- straight afterwards -- the most ordinary thing a player does -- did
    -- nothing at all. What the frontend still owes us is a deactivation; that
    -- is not a reason to tell the rest of the file there is a map up.
    openMap()
    ctrl = { [202] = true }
    step()
    ctrl = {}
    ok(live.phase == 'settling', 'mid-settle...')
    ok(BR.Pause.closeMap() == false,
       '...a press is NOT consumed by a map that has already gone')

    -- ------------------------------------------------------------------- --
    -- 5. AND THE OLD RAISE DOES NOT LAND ON THE NEW ONE.
    -- ------------------------------------------------------------------- --
    --
    -- The other half of the cascade. The old teardown used to write
    -- `frontendMap = false`, `br:map:frontend false` and announceFrontend(false)
    -- UNCONDITIONALLY, half a second late -- so it handed br_core's frontend
    -- suppression back underneath a menu that was mid-raise, br_core closed the
    -- map that had just been asked for, and the new watcher then sat out its
    -- full five-second raise deadline. Press again inside that and it happens
    -- again, which is how "a few times" becomes "no longer".
    local stale = live
    m = #events
    deactivations = 0
    pressKey()
    ok(raisesSince(m) == 1, 'it opens a new one, in quick succession')
    ok(live ~= stale, 'and that really is a NEW raise, not the old one resumed')

    ok(BR.Pause.mapStep(stale) == false,
       'the superseded raise retires on its next frame')
    ok(deactivations == 0,
       'writing nothing on its way out -- no SetFrontendActive aimed at the '
       .. 'menu the new raise is bringing up', tostring(deactivations))
    ok(lastFrontendEvent() == true,
       'so br_core is still stood down for the raise that is actually live')

    menuActive = true
    step(3)
    ok(live.phase == 'watching', 'and the new map comes up unharmed',
       tostring(live.phase))
    menuActive = false
    step(20)

    -- ------------------------------------------------------------------- --
    -- 6. THE RESTART GRACE IS NOT PADDING.
    -- ------------------------------------------------------------------- --
    --
    -- PauseMenuceptionTheKick RESTARTS the scaleform to commit the map page, and
    -- a restarting menu reads as "not active". Without the grace, deriving the
    -- flag from the game would close the map on the frame it finished opening --
    -- a fix that produces a worse bug than the one it fixes.
    -- LONGER THAN THE GRACE, deliberately. A restart window shorter than
    -- MAP_GONE_MS would pass with the restart check deleted, which is a test
    -- that proves the grace and calls it the restart check.
    openMap()
    menuActive, restarting = false, true
    step(30)                           -- ~480ms of restarting, vs a 150ms grace
    ok(live.phase == 'watching', 'a RESTARTING menu is not a dismissed one',
       tostring(live.phase))

    restarting = false
    step(2)                            -- 32ms of "gone", inside the 150ms grace
    ok(live.phase == 'watching', 'and a frame or two of "gone" is still inside the grace')

    menuActive = true
    step(2)
    ok(live.phase == 'watching', 'the menu coming back clears the doubt')

    -- A MAP READ FOR A MINUTE IS STILL A MAP. The grace has to be measured
    -- from when the game was LAST seen holding the frontend, refreshed every
    -- frame -- not from one sighting at the start. Anchored at the start, a
    -- map open longer than the grace would look dismissed while the player was
    -- still reading it, and the watcher would walk away from a frontend that
    -- is very much on screen.
    menuActive = true
    step(400)                          -- ~6.4 seconds of a map being read
    ok(live.phase == 'watching',
       'a map held open far longer than the grace is not read as dismissed',
       tostring(live.phase))
    ctrl = { [202] = true }
    step()
    ok(live.phase == 'settling',
       'and it still answers an exit control when the player is done')
    ctrl = {}
    step(60)

    openMap()
    menuActive = false
    ok(step(20) == false, 'and a real absence still ends it')

    -- ------------------------------------------------------------------- --
    -- 7. A FRONTEND THAT NEVER ARRIVES GIVES UP AND LEAVES NOTHING BEHIND.
    -- ------------------------------------------------------------------- --
    reset()
    pressKey()
    fakeTime = fakeTime + 6000
    ok(step() == false, 'a menu that never comes up is given up on, not waited on')
    ok(lastFrontendEvent() == false and BR.Pause.closeMap() == false,
       'and the giving up puts every flag back, so the next press still opens')

    -- ------------------------------------------------------------------- --
    -- 8. FOR A WHOLE SESSION, WHICHEVER WAY THE LAST ONE WENT.
    -- ------------------------------------------------------------------- --
    --
    -- "M reopens it every time, however the last one was dismissed, for the
    -- whole session." The bug was cumulative -- it took "a few times" -- so the
    -- assertion has to be too. Four dismissals, three rounds, and every single
    -- press in between has to raise a map.
    local ROUTES = {
        { name = 'an exit control',   close = function() ctrl = { [202] = true } end },
        { name = 'raw Escape',        close = function() escDown = { [0x1B] = true } end },
        { name = 'the map key again', close = function() pressKey() end },
        { name = 'the frontend, on its own',
          close = function() menuActive = false end },
        { name = 'the pause key',
          close = function()
              fakeTime = fakeTime + 300
              fire('br:ui:pauseToggle')
          end },
    }

    local everyPressOpened, everyExitTidied = true, true
    local detail, tidyDetail = nil, nil
    for round = 1, 3 do
        for _, r in ipairs(ROUTES) do
            local before = #events
            openMap()
            if raisesSince(before) ~= 1 then
                everyPressOpened = false
                detail = detail or ('round %d, after %s: %d raises')
                    :format(round, r.name, raisesSince(before))
            end
            r.close()
            step(60)
            escDown, ctrl = {}, {}
            -- EVERY EXIT PUTS THE SCREEN BACK. Five dismissals, three rounds,
            -- and not one of them may leave the page hidden, br_core stood
            -- down, or GTA's menu on screen.
            if pageHidden() ~= false or lastFrontendEvent() ~= false
               or menuActive ~= false then
                everyExitTidied = false
                tidyDetail = tidyDetail or
                    ('round %d, %s: page hidden %s, br_core %s, menu %s'):format(
                        round, r.name, tostring(pageHidden()),
                        tostring(lastFrontendEvent()), tostring(menuActive))
            end
        end
    end
    ok(everyPressOpened,
       'M opens the map on every press of a three-round session, through five '
       .. 'different dismissals', detail)
    ok(everyExitTidied,
       'and every one of those exits hands back the page, the suppression and '
       .. 'the screen', tidyDetail)

    -- ------------------------------------------------------------------- --
    -- 9. AND ALL OF IT AGAIN ON A BUILD WHOSE BOOL NATIVES ANSWER NUMBERS.
    -- ------------------------------------------------------------------- --
    --
    -- In Lua `0` is truthy and `1 == true` is false, and a FiveM BOOL native may
    -- answer either shape. Unnormalised, `not IsPauseMenuActive()` on a build
    -- that says `0` is FALSE -- so the raise would decide the menu was up before
    -- it was, and `if IsControlJustPressed(...)` would read every id in both
    -- lists as pressed on every frame and shut the map on the frame it opened.
    -- This project has shipped that mistake four times; this is the block that
    -- makes the fifth fail here instead of in a playtest.
    shape = { yes = 1, no = 0 }

    openMap()
    ok(live.phase == 'watching',
       'the map still comes up when the natives answer 1 rather than true',
       tostring(live.phase))

    ctrl = {}
    step(5)
    ok(live.phase == 'watching',
       'and a 0 from IsControlJustPressed is NOT read as a press',
       tostring(live.phase))

    -- THE ONE THAT ACTUALLY BITES, and it is not the one it looks like.
    -- Unnormalised, `0` is truthy -- so the USING guard fires first, on every
    -- frame, and refreshes its own busy window forever. wantsOut then never
    -- reaches the EXITS list at all and the map becomes UNLEAVABLE by any
    -- control: the map that will not close rather than the map that closes
    -- itself. Only pressing a real exit on a numeric build shows it.
    ctrl = { [202] = true }
    step()
    ok(live.phase == 'settling',
       'and a real exit control still closes the map on a numeric build',
       tostring(live.phase))
    ctrl = {}
    step(60)

    openMap()
    menuActive = false
    ok(step(20) == false, 'a 0 from IsPauseMenuActive is read as "not active"')

    m = #events
    pressKey()
    ok(raisesSince(m) == 1, 'and M opens the map on a numeric build too')
    step(3)
    menuActive = false
    step(20)

    shape = { yes = true, no = false }
end

-- ======================================================================== --
-- #208. GTA'S OWN VEHICLE NAME DOES NOT DRAW OVER OURS
-- ======================================================================== --
--
-- "when getting in a vehicle, there's a GTA V text in the bottom right
-- describing what vehicle it is (make/model) - but that text overlaps with our
-- UI." (owner, 2026-08-22.) Bottom right is the vehicle bars and the inventory.
--
-- THE ASSERTION IS AS MUCH ABOUT WHAT SURVIVES AS ABOUT WHAT GOES. "Hide the
-- vehicle text" has a lazy answer -- one of the whole-HUD switches -- that
-- takes the reticle and the minimap with it, and a player who cannot see their
-- crosshair has a worse problem than one reading a car's name through a fuel
-- bar.

describe('#208 -- the engine\'s vehicle name is hidden, and only it')
do
    local hidden = {}
    HideHudComponentThisFrame = function(id) hidden[id] = true end

    BR.State.me = { src = 1, state = BR.PlayerState.ALIVE }
    BR.State.match = { state = BR.MatchState.PLAYING }

    hidden = {}
    BR.Native.applyGameRules()

    -- 6 is HUD_VEHICLE_NAME, from the documented component table
    -- (citizenfx/natives, HUD/HideHudComponentThisFrame.md). Looked up rather
    -- than guessed, and pinned here so the number cannot drift into a nearby
    -- one that happens to look right in a screenshot.
    ok(hidden[6] == true,
       'HUD_VEHICLE_NAME is suppressed, so the make/model card stops drawing '
       .. 'over the vehicle bars')

    -- THE ONES THAT MUST SURVIVE. 14 is HUD_RETICLE and 21/22 are the
    -- whole-HUD groups; taking any of them is the shortcut the issue rules out
    -- in as many words ("do not disable the whole HUD to remove one label").
    ok(hidden[14] ~= true, 'the reticle is untouched')
    ok(hidden[21] ~= true and hidden[22] ~= true,
       'and neither whole-HUD group is taken')

    -- AND THE FOUR THIS FILE ALREADY HID ARE STILL HIDDEN, which is the
    -- regression a careless edit to that block would produce.
    ok(hidden[3] == true and hidden[4] == true and hidden[7] == true
       and hidden[9] == true and hidden[2] == true,
       'cash, bank, area, street and the ammo counter are all still suppressed')

    -- PER FRAME, WHICH IS WHAT MAKES IT SURVIVE A RESPAWN AND A MATCH
    -- BOUNDARY. The engine re-shows the component every frame it wants to
    -- draw, so a one-shot hide at resource start would last exactly one frame.
    -- applyGameRules is on BR.Loop.FRAME with no state gate above it, so the
    -- honest way to assert "it stays hidden" is to run it in the states a
    -- player passes through and find it hidden in each.
    local held = true
    for _, st in ipairs({ BR.PlayerState.LOBBY, BR.PlayerState.WARMUP,
                          BR.PlayerState.BUS, BR.PlayerState.ALIVE,
                          BR.PlayerState.DBNO, BR.PlayerState.DEAD,
                          BR.PlayerState.SPECTATING }) do
        BR.State.me.state = st
        hidden = {}
        BR.Native.applyGameRules()
        if hidden[6] ~= true then held = false end
    end
    ok(held, 'and it is hidden in every player state, so a respawn or a new '
       .. 'match cannot bring it back')

    BR.State.me.state = BR.PlayerState.ALIVE
end

-- ═══════════════════════════════════════════════════════════════ #203 ═══
--
-- THE VEHICLE BOOST, FROM A PHYSICAL KEY TO A FORCE ON A CAR.
--
-- The owner's report is "boost does nothing, and the bar is at 100", and the
-- feature's own report named two unverified guesses as the likely causes with a
-- third from the owner. Every one of those is a different rung of one chain, and
-- NOT ONE of them was reachable by a test before this block: the boost suite
-- tests the arithmetic (tools/test_boost.lua, pure), and nothing tested the
-- chain the arithmetic sits in.
--
-- That is the exact hole #129 fell through twice. The rule this file was written
-- for applies unchanged: a suite that cannot press a key cannot tell a broken
-- interaction from a working one, and the expensive check -- a human in a car --
-- becomes the only check.
--
-- WHAT IS PROVED HERE AND WHAT IS NOT. The keyboard, the key layer, the seat
-- gate, the meter, the decision to push and the ARGUMENTS to the impulse are all
-- proved. Whether GTA's physics actually moves a car when handed that impulse is
-- not a thing a Lua process can be asked -- so it is modelled BOTH ways
-- (`forceInert`) and what is proved instead is that the readout tells the two
-- apart. That is the deliverable: the suite cannot say which cause is real, and
-- it can say that the instrument names it correctly whichever it is.
do
    describe('#203 the boost, key to car')

    -- THE KEYBOARD, TAKEN BACK. #207's block above swaps IsRawKeyDown for an
    -- escape-key stub of its own and does not put it back -- correctly, for what
    -- it tests. Inheriting it here made every shift read come back UP, which is
    -- indistinguishable from the bug this block exists to measure: three
    -- verdicts flipped to ones that name a different file. See RAW_KEYBOARD.
    IsRawKeyDown, IsRawKeyPressed = RAW_KEYBOARD.down, RAW_KEYBOARD.pressed

    local VK_SHIFT, VK_LSHIFT, VK_RSHIFT = 0x10, 0xA0, 0xA1

    --- Which virtual-key codes this simulated BUILD fills when shift goes down.
    ---
    --- THE WHOLE OF THE FIX IS THIS ONE FIXTURE. IS_RAW_KEY_DOWN reads a 256-slot
    --- array indexed by Windows virtual-key code, and no source anywhere -- the
    --- native declaration, InputNatives.cpp, the docs, the forums -- says which
    --- slot a shift press fills. keybinds.lua BET on 0x10 and wrote the bet down
    --- as three converging inferences. So the bet is a dimension of the matrix
    --- now, exactly as the raw-native shape became one after #129's seventh
    --- round: every build below is one a player could be sitting at.
    local FILLS = {
        { name = 'generic only (0x10)',        codes = { VK_SHIFT } },
        { name = 'side-specific only (0xA0)',  codes = { VK_LSHIFT } },
        { name = 'right shift only (0xA1)',    codes = { VK_RSHIFT } },
        { name = 'both generic and side',      codes = { VK_SHIFT, VK_LSHIFT } },
    }

    local function shiftDown(fill)
        for _, c in ipairs(fill.codes) do
            keys[c] = true
            edge[c] = true
        end
        engineKey('LSHIFT', true)
    end

    local function shiftUp(fill)
        for _, c in ipairs(fill.codes) do keys[c] = nil end
        engineKey('LSHIFT', false)
    end

    --- Put the player in the driver's seat of an ordinary car at `speed` m/s.
    local function drive(speed, class)
        inVehicle   = true
        vehicle     = 900
        vehicleSeat = -1          -- -1 is the driver in every vehicle in the game
        vehClass    = class or 0  -- 0 is Compacts; 15/16 are the excluded aircraft
        vehSpeed    = speed or 20.0
    end

    local function onFoot()
        inVehicle, vehicle, vehicleSeat = false, 0, nil
    end

    --- A clean slate for one scenario: no key held, meter full, engine willing.
    local function resetBoost(fill)
        if fill then shiftUp(fill) end
        for _, f in ipairs(FILLS) do shiftUp(f) end
        forceInert, forceThrows = false, false
        speedVectorMissing, speedScalarMissing = false, false
        forceCalls = {}
        vehClass, vehNetId = 0, 77
        -- SIX SECONDS ON FOOT REFILLS THE METER FROM EMPTY, on wall clock, which
        -- is the per-player rule client/boost.lua argues for. Doing it by running
        -- the real loop rather than by poking the local means a change to that
        -- rule shows up here as a failure rather than being papered over.
        onFoot()
        frames(400, 16)
    end

    local C = BR.Config.Boost

    -- ── THE CHAIN, ON EVERY BUILD THE KEYBOARD CAN BE ────────────────────────
    for _, fill in ipairs(FILLS) do
        resetBoost()
        drive(20.0)
        shiftDown(fill)
        frames(8, 16)

        ok(BR.Keys.isHeld('boost') == true,
           ('key layer sees shift when the build fills %s'):format(fill.name))
        ok(BR.Boost.active() == true,
           ('a boost starts when the build fills %s'):format(fill.name))
        ok(#forceCalls > 0,
           ('the impulse is applied when the build fills %s'):format(fill.name))

        shiftUp(fill)
        frames(2, 16)
        ok(BR.Boost.active() == false,
           ('the boost ends on release, %s'):format(fill.name))
    end

    -- ── AND THE KEY LAYER MUST NOT INVENT ONE ────────────────────────────────
    --
    -- The superset only widens the codes that mean SHIFT. A build where nothing
    -- is held must still read as nothing held, or the fix is a boost that runs
    -- forever -- which is the failure mode a truthiness bug would produce and the
    -- one this project has shipped four times.
    resetBoost()
    drive(20.0)
    frames(8, 16)
    ok(BR.Keys.isHeld('boost') == false,
       'no shift code down means no boost -- the superset widens the key, not the answer')
    ok(BR.Boost.active() == false, 'and no boost starts')

    -- ...AND IT MUST NOT LEAK ONTO ANOTHER BINDING. 0xA0 now means shift; it must
    -- not also mean the interact key, which is what a synonym table applied to
    -- every code instead of to one would do.
    resetBoost()
    keys[VK_LSHIFT] = true
    frames(4, 16)
    ok(BR.Keys.isHeld('interact') == false,
       'a shift synonym does not fire the interact binding')
    keys[VK_LSHIFT] = nil

    -- ── THE SEAT, THE CLASS AND THE METER ────────────────────────────────────
    local fill = FILLS[1]

    resetBoost()
    onFoot()
    shiftDown(fill)
    frames(8, 16)
    ok(BR.Boost.active() == false, 'holding the key on foot boosts nothing')
    shiftUp(fill)

    resetBoost()
    drive(20.0)
    vehicleSeat = 0                     -- front passenger
    shiftDown(fill)
    frames(8, 16)
    ok(BR.Boost.active() == false, 'a passenger cannot boost -- the driver seat is the spec')
    shiftUp(fill)

    resetBoost()
    drive(20.0, 15)                     -- helicopter
    shiftDown(fill)
    frames(8, 16)
    ok(BR.Boost.active() == false,
       'a helicopter cannot boost -- shift already climbs it (excludeClasses)')
    shiftUp(fill)

    -- ── THE ARGUMENTS THE IMPULSE IS GIVEN ───────────────────────────────────
    --
    -- ASSERTED SEPARATELY FROM THE EFFECT, because they fail separately. Dropping
    -- bScaleByMass leaves the call being made and the units silently becoming
    -- newton-seconds -- a Blista would leap and a Phantom would not move, and no
    -- speed assertion on one vehicle could see it.
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    frames(4, 16)
    local call = forceCalls[1]
    ok(call ~= nil, 'the impulse reaches APPLY_FORCE_TO_ENTITY')
    if call then
        ok(call.ftype == 1, 'forceType 1 -- APPLY_TYPE_IMPULSE, not a continuous force')
        ok(call.x == 0.0 and call.z == 0.0, 'nothing is pushed sideways or upwards')
        ok(call.y > 0.0, 'the push is FORWARD (+y in the entity frame)')
        ok(call.dirRel == true, 'bLocalForce -- so +y means the car\'s nose, not north')
        ok(call.forceRel == true,
           'bScaleByMass -- the flag that makes dv a velocity change in m/s')
        ok(call.audio == false,
           'bPlayAudio false -- it squeals once per call and this is called every frame')
        ok(call.ent == 900, 'and it is applied to the vehicle, not the ped')
    end
    shiftUp(fill)

    -- ── THE CAR ACTUALLY GOES FASTER, AND STOPS BEING PUSHED ON RELEASE ──────
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    -- Two seconds is the whole ramp, so this is the spec's own claim: "+30mph
    -- ... over the course of the first 2 seconds".
    frames(125, 16)
    local reached = vehSpeed
    ok(reached > 20.0 + C.addMps * 0.9,
       'two seconds of boost reaches about +30 mph over the speed at the press',
       ('reached %.2f from 20.0, wanted about %.2f'):format(reached, 20.0 + C.addMps))

    -- NOTHING IS DONE TO THE CAR ON RELEASE. The clause the owner stated in as
    -- many words and the one most likely to be "fixed" by a tidy-up.
    shiftUp(fill)
    frames(30, 16)
    ok(vehSpeed >= reached,
       'releasing the key does nothing at all to the car -- no braking, no restore',
       ('was %.2f, now %.2f'):format(reached, vehSpeed))

    -- ── THE READOUT, WHICH IS THE ACTUAL DELIVERABLE ─────────────────────────
    --
    -- IT IS ASSERTED ON RATHER THAN TRUSTED, for the reason /brloot's own helper
    -- gives: the readout is the only thing a playtester can send back, and a
    -- diagnostic nobody tests can print the wrong number for six rounds without
    -- anyone noticing. Here it is worse than that -- the readout is what decides
    -- WHICH of three files gets edited next, so a wrong verdict costs the same
    -- round a wrong fix does.

    --- Run /brboostwhy for a window and give back its verdict code.
    local function brboost(secs)
        logged = {}
        commands['brboostwhy'](nil, { tostring(secs or 1) }, '')
        frames(math.floor((secs or 1) * 1000 / 16) + 2, 16)
        local text = table.concat(logged, '\n')
        return text:match('VERDICT %[([%w%-]+)%]'), text
    end

    resetBoost()
    drive(20.0)
    shiftDown(fill)
    -- 2.5s, AND THE LENGTH IS PART OF THE TEST. The ramp is 2s, so a window
    -- shorter than that measures a boost still climbing and correctly reads
    -- INCONCLUSIVE -- which is the verdict doing its job, not a failure. The
    -- default window is 6s for the same reason: a diagnostic that reports
    -- half a boost invites the wrong fix.
    local code, text = brboost(2.5)
    ok(code == 'ok', 'a working boost reads as [ok]', code)
    ok(text:find('best gain', 1, true) ~= nil,
       'and the readout states the gain against the +30 mph the spec asks for')
    shiftUp(fill)

    -- CANDIDATE 2, THE ONE THE SUITE EXISTS TO BE ABLE TO STATE. Every call is
    -- made and the engine ignores all of them: the key is fine, the seat is fine,
    -- the meter spends, and the car does not move. This is the owner's report
    -- exactly, and the readout must name the impulse rather than the key.
    resetBoost()
    drive(20.0)
    forceInert = true
    shiftDown(fill)
    code, text = brboost(1)
    ok(code == 'force-inert',
       'an impulse the engine ignores reads as [force-inert], not as a key fault', code)
    ok(text:find('APPLY_FORCE_TO_ENTITY is doing nothing', 1, true) ~= nil,
       'and it says so in words, with the torque-multiplier trade named as the owner\'s call')
    shiftUp(fill)
    forceInert = false

    -- CANDIDATE 1. The key never arrives at all: no raw code, no engine control.
    resetBoost()
    drive(20.0)
    code = brboost(1)
    ok(code == 'key-unseen', 'a key that never arrives reads as [key-unseen]', code)

    -- ...AND THE VERSION OF CANDIDATE 1 THAT IS ACTIONABLE. The build fills only
    -- the side-specific slot. With the VK_ALSO superset in place the boost simply
    -- works, so the readout says [ok] -- which is the point: the fix removes the
    -- failure rather than diagnosing it. The verdict for the un-fixed shape is
    -- proved directly against BR.Boost.verdict below, where it can be stated
    -- without un-fixing the code.
    resetBoost()
    drive(20.0)
    shiftDown(FILLS[2])
    code = brboost(2.5)
    ok(code == 'ok',
       'a build that fills only 0xA0 boosts anyway -- that is the fix, measured', code)
    shiftUp(FILLS[2])

    -- ...AND A WINDOW SHORTER THAN THE RAMP SAYS SO RATHER THAN GUESSING. This
    -- is the same working boost measured for half its climb; a readout that
    -- called it [force-inert] would send the next round to rewrite the physics.
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    code = brboost(1)
    ok(code == 'inconclusive',
       'half a ramp is [inconclusive], not a verdict on the impulse', code)
    shiftUp(fill)

    -- AND THE SEAT, THROUGH THE REAL READOUT.
    resetBoost()
    onFoot()
    shiftDown(fill)
    code = brboost(1)
    ok(code == 'not-in-vehicle', 'holding the key on foot reads as [not-in-vehicle]', code)
    shiftUp(fill)

    resetBoost()
    drive(20.0, 16)                     -- plane
    shiftDown(fill)
    code = brboost(1)
    ok(code == 'excluded-class', 'a plane reads as [excluded-class]', code)
    shiftUp(fill)

    -- THE KEY ARRIVES AND THE KEY LAYER DROPS IT. A NUI screen holding the
    -- keyboard is the reachable version of that: IsRawKeyDown still reports the
    -- code down, and BR.Keys.held is forced false so a player typing in a panel
    -- does not boost. The readout has to name keybinds.lua rather than say the
    -- key was never seen -- those are different files.
    --
    -- THIS CASE IS WHY `rawSelf` EXISTS. Mutation testing found the field was
    -- never written, so this whole verdict was unreachable and every instance of
    -- it came out as [key-unseen].
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    fire('br:ui:focusChanged', 'players')
    code, text = brboost(1)
    ok(code == 'key-not-routed',
       'a raw code down with isHeld false is [key-not-routed], not [key-unseen]', code)
    ok(text:find('keybinds.lua', 1, true) ~= nil,
       'and the verdict names the file to edit')
    fire('br:ui:focusChanged', 'none')
    shiftUp(fill)

    -- ═══ THE SHAPE #203'S LEADING CANDIDATE ACTUALLY HAS ═══
    --
    -- The raw natives do not answer for shift AT ALL on this build, on any of the
    -- three codes, while the key is physically down and GTA's own controls on it
    -- report pressed. That is what "IsRawKeyDown may not answer for shift" means
    -- if it is true, and it is the state no readout in this project could see
    -- before now: the key reaches the GAME and not us, so the fault is the
    -- READER, and neither a different default key nor a rewrite of the physics
    -- would touch it.
    resetBoost()
    drive(20.0)
    rawBlind[VK_SHIFT], rawBlind[VK_LSHIFT], rawBlind[VK_RSHIFT] = true, true, true
    shiftDown(fill)
    code, text = brboost(1)
    ok(code == 'key-engine-only',
       'raw silent while the engine control fires is [key-engine-only]', code)
    ok(text:find('IsRawKeyDown cannot', 1, true) ~= nil,
       'and the verdict says the READER is wrong, not the key and not the physics')
    shiftUp(fill)
    rawBlind[VK_SHIFT], rawBlind[VK_LSHIFT], rawBlind[VK_RSHIFT] = nil, nil, nil

    -- REMAPPABLE, WHICH IS THE SPEC, AND THE READOUT HAS TO FOLLOW THE REBIND.
    -- "while holding SHIFT by default (REMAPPABLE)". A diagnostic that assumed
    -- shift would tell a player who moved the key that their key never arrived.
    resetBoost()
    drive(20.0)
    BR.Keys.set('brboost', 0x4B)        -- K
    keys[0x4B], edge[0x4B] = true, true
    code, text = brboost(2.5)
    ok(code == 'ok', 'the boost follows a rebind off shift', code)
    ok(text:find('watching 0x4B', 1, true) ~= nil,
       'and the readout names the key the binding is actually on')
    keys[0x4B] = nil
    BR.Keys.reset('brboost')
    frames(2, 16)

    -- THE RAW NATIVES ANSWERING 1/0 RATHER THAN true/false, WHICH IS THE BUG
    -- THIS PROJECT HAS SHIPPED FOUR TIMES AND WHICH A TRUTHINESS COUNT CANNOT
    -- SEE. `0` is TRUTHY in Lua, so a sampler written as `if v then` counts every
    -- frame of an UNTOUCHED key as pressed -- and then confidently reports that
    -- the key layer is fine. /brprobe rawkey did exactly that for six rounds.
    --
    -- Nothing is held here, so every honest reading is "up": the verdict must be
    -- [key-unseen]. Under the truthiness bug all three codes read down and it
    -- becomes [key-not-routed], which sends the next round to the wrong file.
    bootOn(true, true, SHAPES[3])       -- number 1 / number 0
    resetBoost()
    drive(20.0)
    code = brboost(1)
    ok(code == 'key-unseen',
       'on a build that answers 1/0, an untouched key still reads as unseen', code)
    bootOn(true, true, SHAPES[1])       -- back to booleans for what follows

    -- A NATIVE THAT THROWS. The pcall used to discard its result, which is the
    -- construction that can fail on every frame of every boost and say nothing.
    resetBoost()
    drive(20.0)
    forceThrows = true
    shiftDown(fill)
    code, text = brboost(1)
    ok(code == 'force-throws', 'a native that throws reads as [force-throws]', code)
    ok(text:find('no such native', 1, true) ~= nil,
       'and the readout carries the engine\'s own message, not a guess')
    shiftUp(fill)
    forceThrows = false

    -- ── THE VERDICT LADDER, DIRECTLY ─────────────────────────────────────────
    --
    -- The rungs above are the ones reachable by driving the real client. These
    -- are the rest, and they matter for the same reason: each names a DIFFERENT
    -- file to edit, and a ladder that reaches the wrong rung sends the next round
    -- to the wrong place. Pure function, so they cost nothing.
    describe('#203 the verdict ladder')

    local base = {
        enabled = true, frames = 100, heldFrames = 100, inVehFrames = 100,
        driverFrames = 100, wantFrames = 100, pushFrames = 100, forced = 100,
        addMps = C.addMps, gain = C.addMps,
    }
    local function verdict(over)
        local f = {}
        for k, v in pairs(base) do f[k] = v end
        for k, v in pairs(over or {}) do f[k] = (v ~= 'nil') and v or nil end
        return (BR.Boost.verdict(f))
    end

    ok(verdict({ enabled = false }) == 'disabled', 'boost switched off is [disabled]')
    ok(verdict({ frames = 0 }) == 'no-frames', 'a loop that never ran is [no-frames]')

    -- THE THREE KEY FAULTS, WHICH ARE THREE DIFFERENT FIXES IN THREE PLACES.
    ok(verdict({ heldFrames = 0, rawSelf = 90, rawSelfCode = 0x10 }) == 'key-not-routed',
       'raw code down and isHeld never true is keybinds.lua dropping it')
    ok(verdict({ heldFrames = 0, rawSelfCode = 0x10, rawBestCode = 0xA0,
                 rawBestFrames = 90 }) == 'key-wrong-code',
       'another code answering and ours not is the wrong virtual-key code')
    ok(verdict({ heldFrames = 0, rawSelfCode = 0x10, engineFrames = 90 }) == 'key-engine-only',
       'the engine seeing the key while no raw code does is the wrong READER')
    ok(verdict({ heldFrames = 0, rawSelfCode = 0x10 }) == 'key-unseen',
       'and nothing at all seeing it is [key-unseen]')

    -- THE key-wrong-code SENTENCE HAS TO NAME BOTH CODES, or it is a verdict the
    -- reader still has to go and investigate.
    do
        local _, s = BR.Boost.verdict({
            enabled = true, frames = 100, heldFrames = 0,
            rawSelfCode = 0x10, rawBestCode = 0xA0, rawBestFrames = 90,
        })
        ok(s:find('0x10', 1, true) and s:find('0xA0', 1, true),
           'the wrong-code verdict names the code we watch AND the one that answered')
    end

    ok(verdict({ driverFrames = 0, inVehFrames = 0 }) == 'not-in-vehicle',
       'held on foot is [not-in-vehicle]')
    ok(verdict({ driverFrames = 0 }) == 'not-driver', 'held as a passenger is [not-driver]')
    -- THE EXCLUSION IS ASKED BEFORE THE SEAT, AND THIS IS THE CASE THAT FOUND IT.
    -- `driverFrames` counts the SEAT and the class gate is applied after it, so a
    -- pilot has a non-zero seat count. A ladder that asked the seat first let a
    -- helicopter through to rung 3 and answered `no-want` -- the ladder's own
    -- word for "unreachable" -- which would have sent the next round hunting a
    -- bug that did not exist.
    ok(verdict({ driverFrames = 100, wantFrames = 0, excludedFrames = 90,
                 pushFrames = 0, forced = 0, class = 15 }) == 'excluded-class',
       'a pilot IS in the driver seat, and the class gate still names the cause')
    ok(verdict({ driverFrames = 0, wantFrames = 0, pushFrames = 0, forced = 0,
                 excludedFrames = 90, class = 15 }) == 'excluded-class',
       'and so is a passenger in one')
    -- ...BUT IT MUST NOT CLAIM A BOOST THAT WORKED. Sit in a helicopter for a
    -- moment, get into a car, boost it properly: the helicopter is not the story.
    ok(verdict({ excludedFrames = 30, class = 15 }) == 'ok',
       'an excluded vehicle earlier in the window does not overrule a boost that ran')
    ok(verdict({ wantFrames = 0, dryFrames = 90 }) == 'dry-latch',
       'a latched dry meter is [dry-latch] -- let go and press again')
    ok(verdict({ wantFrames = 0, emptyFrames = 90 }) == 'meter-empty',
       'an empty meter is [meter-empty] -- wait six seconds')
    ok(verdict({ wantFrames = 0 }) == 'no-want', 'and an unreachable combination says so')
    ok(verdict({ pushFrames = 0 }) == 'no-push', 'wanting to boost and never pushing says so')
    ok(verdict({ forced = 0, forceThrew = 90 }) == 'force-throws', 'a throwing native is named')
    ok(verdict({ forced = 0, noSpeed = 90 }) == 'no-speed-native',
       'no speed reading is [no-speed-native] and stops the ladder there')
    ok(verdict({ forced = 0, alreadyAhead = 90 }) == 'already-ahead',
       'a car already faster than the ramp is correct behaviour, not a fault')

    -- THE LAST RUNG, AND ITS MIDDLE. A threshold that called a working boost
    -- broken would cost exactly the round this whole readout exists to save.
    ok(verdict({ gain = 0.0 }) == 'force-inert', 'no gain at all is [force-inert]')
    ok(verdict({ gain = C.addMps * 0.05 }) == 'force-inert',
       'and a gain far under a tenth of what was asked still is')
    ok(verdict({ gain = C.addMps * 0.3 }) == 'inconclusive',
       'a third of the way is INCONCLUSIVE rather than a guess in either direction')
    ok(verdict({ gain = C.addMps * 0.8 }) == 'ok',
       'and most of the way, against drag and gearing, is [ok]')

    -- ORDER IS PART OF THE CONTRACT. Every rung assumes the ones above passed, so
    -- a late symptom must never be able to name itself as the cause: a boost that
    -- never started trivially "applied no force".
    ok(verdict({ heldFrames = 0, driverFrames = 0, pushFrames = 0, forced = 0,
                 gain = 0.0, rawSelfCode = 0x10 }) == 'key-unseen',
       'with everything downstream also empty, the KEY is still the verdict')

    -- AND A TABLE WITH NOTHING IN IT MUST NOT THROW. The readout calls this
    -- inside a pcall, and a verdict that errors is a readout that prints its
    -- rows and then swallows its own conclusion.
    do
        local okc, c = pcall(BR.Boost.verdict, {})
        ok(okc and c == 'disabled', 'an empty facts table is answered, not thrown on')
        local okn = pcall(BR.Boost.verdict, nil)
        ok(okn, 'and so is nil')
    end

    -- ══════════════════════════════════════════════════════════════════════ --
    -- THE REST OF WHAT THE BOOST KEY DOES
    -- ══════════════════════════════════════════════════════════════════════ --
    --
    -- "Vehicle boost does work now, but still getting drift mode at the same
    -- time. Sick affect, but not intended or acceptable really."
    --                                              -- owner, 2026-08-22
    --
    -- RegisterKeyMapping does not take a key away from the engine, and eight
    -- stock controls default to LSHIFT. client/boost.lua now holds down the two
    -- that can act on a ground vehicle while the key is held in the driver's
    -- seat.
    --
    -- ═══ THIS BLOCK IS SHAPED BY #200 RATHER THAN BY THE FIX ═══
    --
    -- A suppression is one edit away from eating a control somebody needs -- an
    -- unconditional block in client/inventory.lua took the radio wheel away for
    -- months. So the assertions come in PAIRS, and the negative half of each pair
    -- is the one that matters: every scope clause is tested by showing that
    -- OUTSIDE it nothing is suppressed, and the two ids deliberately left off the
    -- list are pinned as still free. A test that only proved "61 is held down in
    -- a car" would pass with the whole list replaced by every id on the key,
    -- which is exactly the regression #200 was.
    describe('#203 what else is on the boost key')

    -- THE IDS ARE WRITTEN OUT HERE RATHER THAN READ FROM THE CONFIG, and
    -- mutation testing is why. Every assertion below used to check
    -- BR.Config.Boost.suppressControls against itself, so deleting 340 from the
    -- config deleted it from the expectation too and the suite stayed green on a
    -- control that had silently stopped being suppressed. The list IS the
    -- decision -- which ids of the eight on this key are ours to take -- so it is
    -- pinned as a literal and the config is checked against it.
    local EXPECT     = { 61, 340 }      -- MOVE_UP_ONLY, HYDRAULICS_CONTROL_UP
    local LEFT_ALONE = { 21, 352 }      -- on the key, off the list, and why
    local SUPPRESSED = BR.Config.Boost.suppressControls

    local function allOff(list)
        for _, c in ipairs(list) do
            if disabled[c] ~= true then return false end
        end
        return true
    end
    local function anyOff(list)
        for _, c in ipairs(list) do
            if disabled[c] == true then return true end
        end
        return false
    end

    -- THE CONFIG SAYS WHAT THIS BLOCK SAYS. Checked as a SET both ways round: a
    -- missing id and an extra one are different bugs and the second is #200.
    do
        local want, got = {}, {}
        for _, c in ipairs(EXPECT) do want[c] = true end
        for _, c in ipairs(SUPPRESSED or {}) do got[c] = true end
        local same = #EXPECT == #(SUPPRESSED or {})
        for c in pairs(want) do if not got[c] then same = false end end
        for c in pairs(got) do if not want[c] then same = false end end
        ok(same, 'BR.Config.Boost.suppressControls is exactly {61, 340} -- adding '
           .. 'an id here without a reason beside it is how #200 happened',
           table.concat(SUPPRESSED or {}, ','))
    end

    -- 1. THE CASE THE OWNER IS IN. Driving a car, holding the key.
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    frames(8, 16)
    ok(allOff(EXPECT),
       'driving and holding the key: 61 and 340 are both held down')
    ok(not anyOff(LEFT_ALONE),
       'and 21 and 352 are NOT -- they are on the key and do nothing to a car, '
       .. 'which is the #200 distinction between a key and an effect')

    -- 2. THE KEY IS THE SCOPE, AND IT IS MEASURED ON THE VERY NEXT FRAME. The
    --    release frame is the whole difference: the boost loop skips everything
    --    below its idle path once the key is up AND no boost is running, so a
    --    suppression missing its `held` clause looks correct on every frame
    --    except the one where a running boost is being stopped. Waiting four
    --    frames to look is what let that mutant live.
    shiftUp(fill)
    frame(16)
    ok(not anyOff(EXPECT),
       'let go and the engine has all of it back on the VERY NEXT frame, '
       .. 'including the frame the running boost is stopped on')

    -- 3. THE SEAT IS THE SCOPE.
    resetBoost()
    onFoot()
    shiftDown(fill)
    frames(8, 16)
    ok(not anyOff(EXPECT),
       'holding the key on foot suppresses nothing -- sprint is not ours to take')
    shiftUp(fill)

    resetBoost()
    drive(20.0)
    vehicleSeat = 0                     -- front passenger
    shiftDown(fill)
    frames(8, 16)
    ok(not anyOff(EXPECT),
       'a passenger keeps their controls -- the boost is the driver\'s and so is '
       .. 'the suppression')
    shiftUp(fill)

    -- 4. AND SO IS THE CLASS, WHICH IS THE ONE THAT WOULD HURT MOST TO GET
    --    WRONG. 61 and 352 ARE the collective in a helicopter. Excluding
    --    aircraft from the boost and then suppressing their flight controls
    --    anyway would ground every pilot on the server, silently, for as long as
    --    they held a key they had every reason to hold.
    for _, class in ipairs({ 15, 16 }) do
        resetBoost()
        drive(20.0, class)
        shiftDown(fill)
        frames(8, 16)
        ok(not anyOff(EXPECT),
           ('class %d keeps every control -- an excluded aircraft is excluded '
            .. 'from the suppression too, not just from the push'):format(class))
        shiftUp(fill)
    end

    -- 5. NOT GATED ON THE BOOST RUNNING, WHICH IS THE CLAUSE A TIDY-UP WOULD
    --    ADD. Four seconds of capacity spent, key still down: the meter is empty
    --    and the dry latch is set, so `want` is false and nothing is being
    --    pushed -- and GTA does not consult our meter before pitching the car.
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    frames(340, 16)                     -- 5.4s: past the 4s capacity, still held
    ok(BR.Boost.active() == false, 'the meter has run dry, so no boost is running')
    ok(allOff(EXPECT),
       'and the controls are STILL held down -- the scope is the key and the '
       .. 'seat, not the meter')
    shiftUp(fill)

    -- 6. THE OFF SWITCH TAKES THE SUPPRESSION WITH IT. `enabled = false` is
    --    documented as "the client registers nothing", and a suppression left
    --    running under it would be this file quietly keeping a control from a
    --    server that had switched the whole feature off.
    resetBoost()
    drive(20.0)
    BR.Config.Boost.enabled = false
    shiftDown(fill)
    frames(8, 16)
    ok(not anyOff(EXPECT),
       'with the boost switched off, nothing is suppressed either')
    BR.Config.Boost.enabled = true
    shiftUp(fill)

    -- 7. THE BOOL SHAPES, AGAIN, BECAUSE THE SEAT GATE IS THE SUPPRESSION'S
    --    GATE. IsPedInAnyVehicle is declared BOOL, `0` is TRUTHY in Lua, and
    --    this project has shipped that mistake five times. Both directions,
    --    because they fail in opposite ways and only one of them is visible.
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    inVehicle = 1
    frames(8, 16)
    ok(allOff(EXPECT),
       'a native answering 1 rather than true is still IN A VEHICLE '
       .. '(1 == true is false in Lua)')

    inVehicle = 0
    frames(8, 16)
    ok(not anyOff(EXPECT),
       'and one answering 0 rather than false is still ON FOOT -- 0 is TRUTHY, '
       .. 'so the naive normalisation would suppress a pedestrian\'s sprint')
    shiftUp(fill)

    -- ══════════════════════════════════════════════════════════════════════ --
    -- THE INSTRUMENT THAT WOULD NAME A CAUSE THE DESK CANNOT
    -- ══════════════════════════════════════════════════════════════════════ --
    --
    -- Two rows were added to /brboostwhy for the second report, and both exist
    -- because the first report was read wrongly: four controls reading PRESSED
    -- was taken as four things happening to the car, when IS_DISABLED_CONTROL_
    -- PRESSED only ever answers "the key bound to this id is down".
    resetBoost()
    drive(20.0)
    shiftDown(fill)
    local code, text = brboost(2.5)
    ok(code == 'ok', 'the suppression does not break the boost it protects', code)
    ok(text:find('every OTHER control', 1, true) ~= nil,
       'the readout sweeps the whole 0..359 table and says so when it finds '
       .. 'nothing -- the four rows above it are a hardcoded 2020 list')
    shiftUp(fill)

    -- ...AND IT NAMES ONE WHEN THERE IS ONE. A control this build answers for on
    -- the same key, absent from the four, is precisely the input Rockstar could
    -- have added after the public table's last update -- the one candidate the
    -- old readout was structurally incapable of showing.
    resetBoost()
    drive(20.0)
    CONTROL_VK[350], controlsLive[350] = 0x10, true
    shiftDown(fill)
    code, text = brboost(1)
    ok(text:find('(350)', 1, true) ~= nil,
       'a fifth control on the key is named by its id, not silently dropped')
    ok(text:find('not in the 2020 table', 1, true) ~= nil,
       'and it is labelled as one the reference does not cover')
    shiftUp(fill)
    CONTROL_VK[350], controlsLive[350] = nil, nil

    -- ...AND THE SWEEP MUST NOT REPORT THE WHOLE DRIVING CONTROL SET. It runs
    -- only on frames the boost key is down; a version that ran every frame would
    -- list accelerate, steer and brake, which is true and useless and would bury
    -- the one row worth having.
    --
    -- 350 IS PUT ON A KEY THAT IS HELD DOWN AND THE BOOST KEY IS NOT PRESSED,
    -- which is the only shape that separates the two versions. Testing it with
    -- shift ALSO held proves nothing: an ungated sweep and a gated one both run
    -- on every frame of that window. 0x60 is numpad 0 -- no binding in this
    -- project watches it, so holding it drives nothing else.
    resetBoost()
    drive(20.0)
    CONTROL_VK[350], controlsLive[350] = 0x60, true
    keys[0x60] = true
    code, text = brboost(1)
    ok(text:find('(350)', 1, true) == nil,
       'a control held on a DIFFERENT key is not swept up -- the sweep runs only '
       .. 'on frames the boost key is down')
    ok(text:find('silent on all 0 frames', 1, true) ~= nil,
       'and the readout says how many frames it actually swept, so an empty '
       .. 'list cannot be read as evidence when nothing was sampled')
    keys[0x60] = nil
    CONTROL_VK[350], controlsLive[350] = nil, nil

    -- THE SIDEWAYS ROW. The owner's word is "drift", no drift INPUT exists on
    -- this build, and the remaining suspect is our own impulse -- 1.4 g handed
    -- to the rigid body without passing through the tyres. This is the number
    -- that convicts or exonerates it, and it could not be read before.
    --
    -- THE VALUE IS READ OUT OF THE ROW RATHER THAN SEARCHED FOR IN THE WHOLE
    -- REPORT, and anchored at its start. `find('6.0 m/s peak')` matches inside
    -- '-6.0 m/s peak', which is exactly the reading a dropped abs() would print.
    local function slipRow(t)
        return (t:match('sideways while boosting%s+([^\n]+)')) or ''
    end

    -- A SLIDE THAT DECAYS, so peak, mean and minimum are three different
    -- numbers and only one of them is 7.5. A readout that kept the last sample,
    -- or the smallest, passes a constant-value test and fails this one.
    resetBoost()
    drive(20.0)
    vehLateral, vehLateralStep = 7.5, -0.02
    shiftDown(fill)
    code, text = brboost(2.5)
    ok(slipRow(text):find('^7%.5 m/s peak') ~= nil,
       'the readout reports PEAK lateral speed while boosting, which is what a '
       .. 'drift IS', slipRow(text))
    shiftUp(fill)
    vehLateral, vehLateralStep = 0.0, 0.0

    -- SIDEWAYS IS SIDEWAYS WHICHEVER WAY IT SLID. The component is signed -- a
    -- car sliding left reads negative -- and a peak taken without abs() would
    -- report the least sideways frame of a left-hand drift as its worst.
    resetBoost()
    drive(20.0)
    vehLateral = -6.0
    shiftDown(fill)
    code, text = brboost(2.5)
    ok(slipRow(text):find('^6%.0 m/s peak') ~= nil,
       'a drift the other way is the same size drift -- the sign is dropped, '
       .. 'not printed', slipRow(text))
    shiftUp(fill)
    vehLateral = 0.0

    -- AND A NaN IS NOT A MEASUREMENT. `x ~= x` is the only test for it, and
    -- without it the row prints '-nan m/s peak' -- which is worse than no row,
    -- because it looks like an answer.
    resetBoost()
    drive(20.0)
    vehLateral = 0.0 / 0.0
    shiftDown(fill)
    code, text = brboost(2.5)
    ok(slipRow(text):find('^not measured') ~= nil,
       'a NaN lateral reading is discarded rather than printed as a peak',
       slipRow(text))
    shiftUp(fill)
    vehLateral = 0.0

    -- ...AND SAYS SO RATHER THAN PRINTING A ZERO WHEN IT CANNOT MEASURE. A build
    -- with no speed vector falls back to the unsigned scalar, which has no
    -- direction to decompose -- and a confident 0.0 there would exonerate the
    -- impulse on evidence that was never collected.
    resetBoost()
    drive(20.0)
    speedVectorMissing = true
    shiftDown(fill)
    code, text = brboost(2.5)
    ok(text:find('not measured', 1, true) ~= nil,
       'a build with no speed vector reports that it could not measure, not 0.0')
    shiftUp(fill)
    speedVectorMissing = false

    resetBoost()
    onFoot()
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('sfx.audition')
-- ═══════════════════════════════════════════════════════════════════════════
--
--   "Can you make me something which plays GTA sounds with a console command
--    so I can pick which one sounds good?"      -- owner, 2026-08-22
--
-- ═══ WHY THE AUDITION COMMAND IS DRIVEN HERE AND NOT LEFT TO A GREP ═══
--
-- tools/test_shared.lua proves the SEARCH returns the right rows and
-- tools/verify.sh proves the command still exists and still probes. Neither one
-- runs it. Two things can only be seen by running it, and both are the kind of
-- mistake that produces SILENCE rather than an error -- which is the exact
-- failure mode this whole feature exists to make visible:
--
--   1. THE ARGUMENT ORDER. PLAY_SOUND_FRONTEND is
--      (soundId, audioName, audioRef) -- the NAME comes before the SET, which
--      is the opposite of how everything in this codebase talks about a cue
--      ("HUD_AWARDS / PROPERTY_PURCHASE", set first). Swap them and every
--      single sound in the game goes quiet, with no error anywhere and a
--      config file that still reads perfectly.
--
--   2. WHAT THE PROBE MAKES OF EACH SHAPE THE BOOL CAN ARRIVE IN.
--      HAS_SOUND_FINISHED is declared BOOL and this project has shipped the
--      number-not-boolean bug SIX times. `0` IS TRUTHY IN LUA, so a build that
--      answers 0 for "not finished yet" would make a bare truth test report
--      every pair as silent -- the probe firing constantly on working sounds,
--      which is worse than no probe because it would be believed at first.
--      Every shape is driven: true, 1, false, 0 and nil.
do
    loadAll({ 'br_lib/config/audio.lua', 'br_core/client/sfx.lua' })

    -- ---------------------------------------------------------- the engine ---
    local plays, released = {}, {}
    local savedPlay = PlaySoundFrontend
    PlaySoundFrontend = function(id, name, set, p3)
        plays[#plays + 1] = { id = id, name = name, set = set, p3 = p3 }
    end
    GetSoundId       = function() return 7 end
    ReleaseSoundId   = function(id) released[#released + 1] = id end

    -- WHAT THE ENGINE SAYS WHEN ASKED WHETHER THE SOUND IS OVER. Driven per
    -- case; `true` is the "it never started" answer the probe exists to catch.
    local finished = true
    HasSoundFinished = function() return finished end

    -- THREADS RUN INLINE, AND `Wait` MOVES THE CLOCK. The suite's default
    -- Citizen.Wait is a no-op and GetGameTimer answers a frozen fakeTime -- and
    -- the probe measures its window with GetGameTimer, so a Wait that did not
    -- advance it would spin forever. A Wait that does not advance time is also
    -- not a faithful model of one: in the game every Wait(0) is a frame.
    local savedCitizen = Citizen
    Citizen = {
        CreateThread = function(f) f() end,
        Wait = function(ms) fakeTime = fakeTime + math.max(tonumber(ms) or 0, 16) end,
        SetTimeout = function() end,
    }

    --- Run /brsfx and hand back everything it printed.
    local function brsfx(...)
        local from = #logged + 1
        plays, released = {}, {}
        commands['brsfx'](0, { ... }, 'brsfx')
        return table.concat(logged, '\n', from, #logged)
    end

    ok(commands['brsfx'] ~= nil, '/brsfx is registered')

    -- ═══ THE ARGUMENT ORDER ═══
    local out = brsfx('play', 'HUD_AWARDS', 'COLLECTED')
    ok(#plays == 1, 'brsfx play makes exactly one sound call', ('%d'):format(#plays))
    ok(plays[1] and plays[1].name == 'COLLECTED' and plays[1].set == 'HUD_AWARDS',
       'and passes the NAME third-from-left and the SET after it, which is '
           .. 'PLAY_SOUND_FRONTEND(soundId, audioName, audioRef) and is the '
           .. 'reverse of how a cue is written down',
       plays[1] and ('name=%s set=%s'):format(tostring(plays[1].name),
                                              tostring(plays[1].set)) or 'nothing')

    -- THROUGH A REAL SOUND ID, WHICH IS THE WHOLE PROBE. Fire-and-forget -1
    -- cannot be asked whether it ever started, and a version of this command
    -- that quietly went back to -1 would still play sounds and would still look
    -- like it was working.
    ok(plays[1] and plays[1].id == 7,
       'through a real GET_SOUND_ID rather than fire-and-forget -1, so there '
           .. 'is something to ask HAS_SOUND_FINISHED about',
       plays[1] and tostring(plays[1].id) or 'nothing')
    ok(released[1] == 7, 'and the id is released afterwards rather than leaked',
       tostring(released[1]))

    -- ═══ EVERY SHAPE A BOOL NATIVE MAY ARRIVE IN ═══
    --
    -- The pair is the same every time; only the engine's answer changes. What
    -- is asserted is the VERDICT the owner reads, because that is the whole
    -- output of the feature.
    local SHAPES = {
        { v = true,  silent = true,  why = 'a strict true means finished, so it never started' },
        { v = 1,     silent = true,  why = 'and 1 is the same answer from a build that returns numbers' },
        { v = false, silent = false, why = 'a strict false means it is still playing' },
        { v = 0,     silent = false, why = '...AND SO IS 0, which is TRUTHY in Lua -- the shape that '
                                           .. 'punishes a bare `if finished then` and would report '
                                           .. 'every working sound as silent' },
        { v = nil,   silent = false, why = 'and nil is not "finished" either' },
    }
    for _, s in ipairs(SHAPES) do
        finished = s.v
        local o = brsfx('play', 'HUD_AWARDS', 'COLLECTED')
        local sawSilent = o:find('[silent?]', 1, true) ~= nil
        ok(sawSilent == s.silent, s.why,
           ('HasSoundFinished -> %s, reported %s'):format(
               tostring(s.v), sawSilent and 'silent' or 'played'))
    end
    finished = false

    -- ═══ THE HONEST THIRD ANSWER: THE PROBE DECLINING ═══
    --
    -- `[silent?]` and `[unprobed]` must not be confusable. The first is
    -- evidence about the sound; the second is an admission about the probe, on
    -- a build where there was no sound id to watch or where the native would
    -- not answer. A tool that reported "silent" when it simply could not tell
    -- would send the owner hunting a set name that was fine -- which is the
    -- same wasted round, with the blame moved.
    local savedGet = GetSoundId
    GetSoundId = function() return -1 end
    out = brsfx('play', 'HUD_AWARDS', 'COLLECTED')
    ok(out:find('[unprobed]', 1, true) ~= nil,
       'a build with no sound id to spare reports that it could not tell, not '
           .. 'that the sound was silent', out)
    ok(#plays == 1 and plays[1].id == -1,
       'and the sound is still played, fire-and-forget, rather than skipped -- '
           .. 'the ear is the primary instrument and the probe is the aid',
       plays[1] and tostring(plays[1].id) or 'nothing')
    GetSoundId = savedGet

    HasSoundFinished = function() error('this native does not exist here') end
    out = brsfx('play', 'HUD_AWARDS', 'COLLECTED')
    ok(out:find('[unprobed]', 1, true) ~= nil,
       'and a build whose HAS_SOUND_FINISHED does not bind says the same thing '
           .. 'rather than taking the whole command down', out)
    ok(#plays == 1, 'while still playing the sound')
    HasSoundFinished = function() return finished end

    -- ═══ A CUE BY KEY, WHICH IS WHAT MAKES THE CONFIG AUDITIONABLE ═══
    local done = BR.Config.Audio.cues['fuel.done']
    brsfx('fuel.done')
    ok(#plays == 1 and plays[1].name == done.name and plays[1].set == done.set,
       '/brsfx <cue> plays whatever the cue table currently says',
       plays[1] and (tostring(plays[1].set) .. '/' .. tostring(plays[1].name)) or 'nothing')

    -- AND THE OLDER TWO-WORD FORM STILL WORKS. config/audio.lua's own comments
    -- tell the reader to type `/brsfx HUD_AWARDS PROPERTY_PURCHASE`, and a
    -- command that broke its documented spelling to make room for subcommands
    -- would have traded one discovery problem for another.
    brsfx('HUD_AWARDS', 'MEDAL_BRONZE')
    ok(#plays == 1 and plays[1].set == 'HUD_AWARDS' and plays[1].name == 'MEDAL_BRONZE',
       'and the documented two-word form still plays a raw pair',
       plays[1] and (tostring(plays[1].set) .. '/' .. tostring(plays[1].name)) or 'nothing')

    -- A SUBCOMMAND IS NOT MISTAKEN FOR A SOUND SET. `sets` and `find` take a
    -- second word too, and reading `brsfx find GO` as the set `find` would be a
    -- silent sound and a search that never ran.
    brsfx('find', 'GO')
    ok(#plays == 0, 'a subcommand with an argument is not read as a set/name pair',
       ('%d play(s)'):format(#plays))

    -- ═══ SEARCH OUTPUT ═══
    out = brsfx('find', 'GO', 'MINI')
    ok(out:find('GO_NON_RACE', 1, true) ~= nil,
       'brsfx find prints the pairs it matched', out)
    ok(out:find('HUD_AWARDS', 1, true) == nil,
       'and nothing from a set the second word excluded')

    out = brsfx('sets', 'AWARDS')
    ok(out:find('HUD_AWARDS', 1, true) ~= nil, 'brsfx sets lists a matching set')

    out = brsfx('find', 'nothing_is_called_this')
    ok(out:find(': 0 ', 1, true) ~= nil, 'and an empty search says so', out)

    -- ═══ STEP 2: LISTING ONE SET WITHOUT PLAYING IT ═══
    --
    --   "It seems I have no way to list all sfx within a given set."
    --                                             -- owner, 2026-08-23
    --
    -- The verb that was missing, and the property that makes it the missing one
    -- rather than a synonym for `audition`: IT MAKES NO SOUND. `audition` was
    -- the only way to see a whole set and it costs twelve seconds of playback
    -- to do it; a list you read in silence is what lets somebody decide what is
    -- worth auditioning.
    local awardNames = BR.Config.Audio.namesIn('HUD_AWARDS')
    out = brsfx('sounds', 'HUD_AWARDS')
    ok(#plays == 0,
       'brsfx sounds plays NOTHING -- it is the silent half of browsing, and a '
           .. 'version that played would just be `audition` with a longer name',
       ('%d sound calls'):format(#plays))

    local missing = nil
    for _, n in ipairs(awardNames) do
        if out:find(n, 1, true) == nil then missing = n end
    end
    ok(missing == nil, 'and prints every name in the set, not a sample', missing)
    ok(out:find(('%d sounds'):format(#awardNames), 1, true) ~= nil,
       'with the count in the header', out:sub(1, 80))

    -- EACH STEP NAMES THE NEXT ONE. This is what makes the three-step flow
    -- findable without reading the help, which is the actual complaint: the
    -- verbs all existed, and none of them pointed anywhere.
    ok(brsfx('sets', 'AWARDS'):find('brsfx sounds', 1, true) ~= nil,
       'step 1 ends by naming step 2')
    ok(out:find('brsfx play HUD_AWARDS ', 1, true) ~= nil,
       'and step 2 ends by naming step 3, with a real NAME filled in rather '
           .. 'than a placeholder to be decoded', out:sub(-300))

    -- AND THE `[silent?]` TEACHING SURVIVES THE NEW ROUTE IN. Being listed here
    -- proves GTA's own scripts play the pair; it does not prove this build has
    -- the bank. "Listed it, played it, heard nothing" must not read as "that
    -- sound is bad" -- that exact confusion cost two rounds of fuel cue.
    ok(out:find('[silent?]', 1, true) ~= nil
       and out:find('not a sound you disliked', 1, true) ~= nil,
       'and a set listing still explains what silence will mean', out:sub(-200))

    -- ═══ FORGIVING ABOUT WHAT WAS TYPED, LOUD ABOUT WHAT IT DECIDED ═══
    out = brsfx('sounds', 'hud_awards')
    ok(out:find(awardNames[1], 1, true) ~= nil,
       'a set name in the wrong case still lists the set -- GTA\'s names SHOUT '
           .. 'and nobody types 37 characters of caps twice')
    ok(out:find('reading "hud_awards" as HUD_AWARDS', 1, true) ~= nil,
       'and the command says which set it decided on, because step 3 needs the '
           .. 'catalogue\'s spelling and would otherwise be typed wrong', out:sub(1, 120))

    out = brsfx('sounds', 'awards')
    ok(out:find('reading "awards" as HUD_AWARDS', 1, true) ~= nil
       and out:find(awardNames[1], 1, true) ~= nil,
       'a partial name that can only mean one set resolves to it, and says so',
       out:sub(1, 120))

    -- A NEAR MISS IS ANSWERED WITH THE CANDIDATES, NOT WITH A REFUSAL. `HUD`
    -- means thirteen sets; picking one would be guessing, and printing nothing
    -- would leave somebody who is two characters from the answer with no route
    -- to it.
    out = brsfx('sounds', 'HUD')
    ok(out:find('could mean', 1, true) ~= nil
       and out:find('HUD_AWARDS', 1, true) ~= nil
       and out:find('HUD_FREEMODE_SOUNDSET', 1, true) ~= nil,
       'an ambiguous set name lists the sets it could have meant', out:sub(1, 200))
    ok(#plays == 0, 'and still plays nothing')

    out = brsfx('sounds', 'nothing_is_called_this')
    ok(out:find('no sound set matches', 1, true) ~= nil
       and out:find('brsfx sets', 1, true) ~= nil,
       'a set name matching nothing at all says so and points back at step 1',
       out)

    out = brsfx('sounds')
    ok(out:find('usage: brsfx sounds', 1, true) ~= nil,
       'and the verb with no set at all prints its usage', out)

    -- ═══ PAGING, DRIVEN THROUGH AN INJECTED SET BECAUSE NO REAL ONE IS BIG
    --     ENOUGH ═══
    --
    -- The biggest set in the catalogue is 27 names, well under the 60-row cap,
    -- so every real `brsfx sounds` fits on one page and the paging arm is
    -- unreachable through the shipped data. It is tested anyway: the catalogue
    -- is a list somebody ADDS to, and the failure this guards is a console that
    -- drops the tail of a list WITHOUT SAYING SO -- which in a tool whose whole
    -- subject is "the thing you cannot see is the thing that is wrong" would be
    -- the worst possible bug to have.
    local big = {}
    for i = 1, 145 do big[i] = ('ZZ_PAGE_%03d'):format(i) end
    table.insert(BR.Config.Audio.catalogue, { set = 'ZZ_PAGING_SET', names = big })

    out = brsfx('sounds', 'ZZ_PAGING_SET')
    ok(out:find('page 1 of 3', 1, true) ~= nil,
       'a set longer than the cap is paged rather than dumped', out:sub(1, 90))
    ok(out:find('ZZ_PAGE_001', 1, true) ~= nil
       and out:find('ZZ_PAGE_060', 1, true) ~= nil
       and out:find('ZZ_PAGE_061', 1, true) == nil,
       'with exactly the first page of names on it')
    ok(out:find('85 more not shown', 1, true) ~= nil,
       'and it says HOW MANY it held back -- silent truncation in a browsing '
           .. 'tool is worse than no tool', out:sub(-220))
    ok(out:find('brsfx sounds ZZ_PAGING_SET 2', 1, true) ~= nil,
       'and the exact words that fetch them')

    out = brsfx('sounds', 'ZZ_PAGING_SET', '3')
    ok(out:find('page 3 of 3', 1, true) ~= nil
       and out:find('ZZ_PAGE_145', 1, true) ~= nil
       and out:find('more not shown', 1, true) == nil,
       'the last page holds the tail and claims nothing is missing', out:sub(1, 90))
    ok(out:find('brsfx sounds ZZ_PAGING_SET 1', 1, true) ~= nil,
       'and offers the way back to the top')

    -- A PAGE NUMBER PAST THE END, OR NOT A NUMBER AT ALL, IS CLAMPED RATHER
    -- THAN REFUSED. Somebody typing a page number is trying to see a list; an
    -- error message instead of a list is how they go back to guessing.
    ok(brsfx('sounds', 'ZZ_PAGING_SET', '99'):find('page 3 of 3', 1, true) ~= nil,
       'a page past the end clamps to the last one')
    ok(brsfx('sounds', 'ZZ_PAGING_SET', 'banana'):find('page 1 of 3', 1, true) ~= nil,
       'and a page that is not a number is page one')
    ok(brsfx('sounds', 'ZZ_PAGING_SET', '-4'):find('page 1 of 3', 1, true) ~= nil,
       'as is a negative one')

    table.remove(BR.Config.Audio.catalogue)
    ok(BR.Config.Audio.namesIn('ZZ_PAGING_SET') == nil,
       'and the injected set is gone again')

    -- ═══ AUDITIONING A WHOLE SET, IN ORDER ═══
    --
    -- The comparative case, which is the one that actually settles a choice:
    -- play, wait, play the next, printing each name.
    local names = BR.Config.Audio.namesIn('HUD_AWARDS')
    out = brsfx('audition', 'HUD_AWARDS')
    ok(#plays == #names, 'brsfx audition plays every name in the set',
       ('%d of %d'):format(#plays, #names))
    local sameOrder = true
    for i, n in ipairs(names) do
        if not plays[i] or plays[i].name ~= n then sameOrder = false end
    end
    ok(sameOrder, 'in the catalogue order, so the printed list and the sounds '
                      .. 'heard line up one for one')
    ok(out:find(names[1], 1, true) ~= nil and out:find(names[#names], 1, true) ~= nil,
       'and every name is printed as it plays, not just at the end')

    -- AND THE SILENT ONES ARE COUNTED. This is the line that turns "one of
    -- these was wrong" into "this one was wrong".
    finished = true
    out = brsfx('audition', 'HUD_AWARDS')
    ok(out:find(('%d of %d never started'):format(#names, #names), 1, true) ~= nil,
       'a set where nothing plays reports the count rather than looking like a '
           .. 'set of sounds somebody disliked', out:sub(-260))
    finished = false

    -- ═══ bind: THE THIRD FUEL SOUND IS THE OWNER'S, AND THIS IS HOW THEY TRY IT ═══
    local wasSet, wasName = done.set, done.name
    brsfx('bind', 'fuel.done', 'HUD_MINI_GAME_SOUNDSET', 'MEDAL_UP')
    ok(BR.Config.Audio.cues['fuel.done'].set == 'HUD_MINI_GAME_SOUNDSET'
       and BR.Config.Audio.cues['fuel.done'].name == 'MEDAL_UP',
       'brsfx bind re-points a cue in the live table')
    brsfx('fuel.done')
    ok(plays[1] and plays[1].name == 'MEDAL_UP',
       'and the cue really plays the new pair afterwards -- which is what lets '
           .. 'a candidate be judged at a pump instead of in a menu')

    -- IT REFUSES A KEY THAT IS NOT A CUE, rather than inventing one. A typo
    -- that silently created `fuel.donne` would leave the owner auditioning a
    -- cue nothing fires.
    brsfx('bind', 'fuel.donne', 'HUD_AWARDS', 'WIN')
    ok(BR.Config.Audio.cues['fuel.donne'] == nil,
       'and a misspelled cue key is refused rather than quietly created')

    BR.Config.Audio.cues['fuel.done'] = { set = wasSet, name = wasName }

    -- ═══ THE MATCH-WIDE CUE ARRIVING FROM THE SERVER ═══
    --
    -- The storm's. Everything about the payload is treated as untrusted even
    -- though the server is the sender, because the cost of doing so is one
    -- type check and the cost of not doing so is a client error mid-match.
    local move = BR.Config.Audio.cues['storm.move']
    plays = {}
    fire(BR.Net.SFX_CUE, { c = 'storm.move' })
    ok(#plays == 1 and plays[1].set == move.set and plays[1].name == move.name,
       'a storm.move cue off the wire plays the configured pair',
       plays[1] and (tostring(plays[1].set) .. '/' .. tostring(plays[1].name)) or 'nothing')

    for _, junk in ipairs({ { c = 'no such cue' }, { c = 42 }, { }, 'not a table', 7 }) do
        plays = {}
        local safe = pcall(fire, BR.Net.SFX_CUE, junk)
        ok(safe and #plays == 0,
           'a malformed cue message plays nothing and does not throw',
           ('%s -> %d play(s), ok=%s'):format(type(junk), #plays, tostring(safe)))
    end
    plays = {}
    local safeNil = pcall(fire, BR.Net.SFX_CUE, nil)
    ok(safeNil and #plays == 0, 'and neither does no payload at all')

    -- THE MUTE SWITCH COVERS IT TOO. A player who muted our cues must not be
    -- given a sound by the server just because it arrived over the wire.
    BR.Sfx.setMuted(true)
    plays = {}
    fire(BR.Net.SFX_CUE, { c = 'storm.move' })
    ok(#plays == 0, 'and /brmute silences the server-addressed cue as well',
       ('%d'):format(#plays))
    BR.Sfx.setMuted(false)

    PlaySoundFrontend = savedPlay
    Citizen = savedCitizen
end

-- ======================================================================== --
-- N. THE AMMO THAT CAME BACK
-- ======================================================================== --
--
-- Owner, 2026-08-23, live two-player playtest: "when picking up a railgun from
-- the airdrop it seemed to have a different amount of ammo than what the HUD
-- showed, then once depleted, switching between slots gave me more ammo."
--
-- The second sentence is a duplication exploit: cycle the wheel and the gun is
-- loaded again, for free, as many times as you like.
--
-- IT IS NOT IN THE SWITCH, WHICH IS WHY READING THE SWITCH FOUND NOTHING.
-- applyActive does RemoveAllPedWeapons -> GiveWeaponToPed(..., 0, ...) ->
-- SetPedAmmo, so it grants nothing and then writes an explicit number: it can
-- only ever hand out what it was TOLD. What it is told is the SERVER's number,
-- and with Combat.serverAmmo on the server only debits a round when a validated
-- weaponDamageEvent reaches BR.Damage.spendRound. Rounds burnt by anything else
-- were charged to nobody, and the re-grant handed them straight back.
--
-- WHY THE HARNESS MODELS THE PED'S AMMO RATHER THAN COUNTING CALLS. "SetPedAmmo
-- was called with 6" is true of the fix and of the bug; the question is what the
-- GUN ends up holding after a sequence of grants, and only a model of the ped
-- can answer that. Every native below is the real one's contract: GiveWeaponToPed
-- ADDS (which is why the file passes 0), SetPedAmmo SETS the total, and the
-- magazine is part of the total rather than beside it.
describe('a depleted weapon stays depleted across a slot switch -- 2026-08-23')
do
    local savedGive    = GiveWeaponToPed
    local savedRemove  = RemoveAllPedWeapons
    local savedSetAmmo = SetPedAmmo
    local savedSetClip = SetAmmoInClip
    local savedGetAmmo = GetAmmoInPedWeapon
    local savedGetClip = GetAmmoInClip
    local savedCurrent = SetCurrentPedWeapon

    -- The ped's own holding, by normalised hash. `total` includes the magazine,
    -- which is the whole point of the model the report loop watches.
    local gun = { total = {}, clip = {} }

    function RemoveAllPedWeapons() gun.total, gun.clip = {}, {} end
    function GiveWeaponToPed(_, hash, ammo)
        local h = BR.NormHash(hash)
        gun.total[h] = (gun.total[h] or 0) + (ammo or 0)
    end
    function SetPedAmmo(_, hash, n)
        local h = BR.NormHash(hash)
        gun.total[h] = math.max(0, n or 0)
        gun.clip[h]  = math.min(gun.clip[h] or 0, gun.total[h])
    end
    function SetAmmoInClip(_, hash, n)
        local h = BR.NormHash(hash)
        gun.clip[h] = math.min(math.max(0, n or 0), gun.total[h] or 0)
    end
    function GetAmmoInPedWeapon(_, hash) return gun.total[BR.NormHash(hash)] or 0 end
    function GetAmmoInClip(_, hash) return true, gun.clip[BR.NormHash(hash)] or 0 end
    function SetCurrentPedWeapon(_, hash) pedWeapon = hash end

    local RAILGUN = BR.Config.WeaponById['railgun']
    local PISTOL  = BR.Config.WeaponById['pistol']
    local RH, PH  = BR.NormHash(RAILGUN.hash), BR.NormHash(PISTOL.hash)

    --- Pull the trigger, the way the engine does: one round out of the magazine
    --- and out of the total, and a reload off the ped's own reserve when the
    --- magazine empties. Nothing here talks to the server, which IS the bug.
    local function pull(hash, n)
        local h = BR.NormHash(hash)
        for _ = 1, (n or 1) do
            if (gun.total[h] or 0) <= 0 then break end
            gun.total[h] = gun.total[h] - 1
            gun.clip[h]  = math.max(0, (gun.clip[h] or 0) - 1)
            if gun.clip[h] == 0 then
                local w = BR.Config.WeaponByHash[h]
                gun.clip[h] = math.min(w and w.clip or 0, gun.total[h])
            end
        end
        -- Ten ticks: enough for the report loop's own gate to open, and enough
        -- for the mirror to have seen the gun at rest afterwards.
        for _ = 1, 10 do
            fakeTime = fakeTime + 100
            BR.Loop.step(BR.Loop.TICK)
        end
    end

    --- What the server would send. `clip` and the pool are the SERVER's numbers,
    --- so leaving them where they were is exactly a server that has not noticed
    --- the shots -- which is the state an explosive weapon is always in.
    local function serverSays(active, railClip, heavy)
        fire(BR.Net.INV_SET, {
            slots = {
                { id = 'railgun', label = 'Railgun', kind = BR.ItemKind.WEAPON,
                  rarity = 5, count = 1, clip = railClip, pool = 'heavy' },
                { id = 'pistol', label = 'Pistol', kind = BR.ItemKind.WEAPON,
                  rarity = 1, count = 1, clip = PISTOL.clip, pool = 'light' },
            },
            ammo = { heavy = heavy, light = 24 },
            active = active,
        })
        BR.Loop.step(BR.Loop.TICK)
    end

    local function ammoReports()
        local out = {}
        for _, s in ipairs(sent) do
            if s.name == BR.Net.INV_AMMO then out[#out + 1] = s.args[1] end
        end
        return out
    end

    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    fire(BR.Net.STATE, { state = BR.MatchState.PLAYING })

    -- ── 1. THE PICKUP. What the HUD draws and what the gun holds are the same
    --       number, which is the first half of the report.
    --
    --       The HUD reads `clip` and the pool off the payload and prints them as
    --       "clip / reserve"; the ped is given `clip + reserve` in total. So the
    --       assertion is that the engine's total equals what the bar adds up to,
    --       and that the magazine matches the number in the big type.
    sent = {}
    serverSays(1, RAILGUN.clip, RAILGUN.clip)
    local hudClip, hudReserve = RAILGUN.clip, RAILGUN.clip
    ok(gun.total[RH] == hudClip + hudReserve,
       'a railgun off an airdrop holds exactly what the HUD adds up to',
       ('engine %s, HUD %d + %d'):format(tostring(gun.total[RH]),
                                         hudClip, hudReserve))
    ok(gun.clip[RH] == hudClip,
       'and its magazine is the number the bar prints in the big type',
       ('engine %s, HUD %d'):format(tostring(gun.clip[RH]), hudClip))

    -- ── 2. FIRE IT DRY, WITH THE SERVER NONE THE WISER.
    --
    --       No INV_SET follows, because for an explosive there is nothing to
    --       follow: a blast raises no weaponDamageEvent (server/damage.lua's own
    --       2026-08-08 capture), so spendRound never runs and the server's
    --       numbers stay exactly where they were.
    sent = {}
    pull(RAILGUN.hash, hudClip + hudReserve)
    ok(gun.total[RH] == 0, 'the gun is empty after the last round',
       tostring(gun.total[RH]))

    -- THE HALF THAT TELLS THE SERVER. Silenced by serverAmmo until 2026-08-23,
    -- which is why the drift was permanent rather than a round trip long.
    local reports = ammoReports()
    ok(#reports > 0 and reports[#reports].total == 0,
       'the client reports the rounds as gone, even with serverAmmo on',
       ('%d report(s), last total %s'):format(
           #reports, reports[#reports] and tostring(reports[#reports].total) or '-'))

    -- ── 3. THE EXPLOIT. Switch away, switch back. The server still believes the
    --       railgun is loaded, so this is the exact press the owner made.
    serverSays(2, RAILGUN.clip, RAILGUN.clip)
    ok(gun.total[RH] == nil or gun.total[RH] == 0,
       'switching away takes the railgun off the ped',
       tostring(gun.total[RH]))

    serverSays(1, RAILGUN.clip, RAILGUN.clip)
    ok((gun.total[RH] or 0) == 0,
       'A DEPLETED WEAPON COMES BACK DEPLETED -- the switch conjures nothing',
       ('engine total %s (server still says %d + %d)'):format(
           tostring(gun.total[RH]), RAILGUN.clip, RAILGUN.clip))

    -- ...AND NOT ONLY THROUGH THE SWITCH. reapplyAmmo runs on any INV_SET whose
    -- ammo went up, and the pool is SHARED -- so picking up a bandage while
    -- somebody else's sniper ammo landed used to reload the railgun too. Same
    -- deficit, same subtraction, different door.
    serverSays(1, RAILGUN.clip, RAILGUN.clip + 5)
    ok((gun.total[RH] or 0) == 5,
       'and an unrelated pickup credits only what was actually picked up',
       tostring(gun.total[RH]))

    -- ── 4. IT IS NOT RAILGUN-ONLY, AND THE REPORT UNDERSTATES IT. The railgun is
    --       where the owner found it because an explosive is charged for nothing
    --       at all; every weapon leaks for every shot the server does not see.
    sent = {}
    serverSays(2, RAILGUN.clip, 0)
    pull(PISTOL.hash, PISTOL.clip + 24)
    ok(gun.total[PH] == 0, 'a pistol emptied the same way is empty',
       tostring(gun.total[PH]))
    serverSays(1, RAILGUN.clip, 0)
    serverSays(2, RAILGUN.clip, 0)
    ok((gun.total[PH] or 0) == 0,
       'and it stays empty across the same switch -- this was never railgun-only',
       tostring(gun.total[PH]))

    -- ── 5. THE OTHER DIRECTION, WHICH IS THE ONE A CARELESS FIX BREAKS. A
    --       genuine grant must still arm the player: the deficit may only ever
    --       take away rounds the ENGINE has already spent.
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    sent = {}
    serverSays(1, RAILGUN.clip, RAILGUN.clip)
    ok(gun.total[RH] == RAILGUN.clip * 2,
       'a fresh weapon after a teardown is fully loaded',
       tostring(gun.total[RH]))

    -- Firing without the shortfall ever being measured (the state a stow or a
    -- suspended probe leaves) must not dock anything either: it is `max(0, ...)`
    -- and it is keyed on the item, so a slot that changed weapons starts clean.
    pull(RAILGUN.hash, 2)
    serverSays(1, 0, 0)             -- the server catches up: nothing left
    serverSays(1, PISTOL.clip, 12)  -- ...and a DIFFERENT gun lands in slot 1
    fire(BR.Net.INV_SET, {
        slots = {
            { id = 'pistol', label = 'Pistol', kind = BR.ItemKind.WEAPON,
              rarity = 1, count = 1, clip = PISTOL.clip, pool = 'light' },
        },
        ammo = { light = 24 }, active = 1,
    })
    BR.Loop.step(BR.Loop.TICK)
    ok(gun.total[PH] == PISTOL.clip + 24,
       'and a new weapon in a slot that was empty is not docked for it',
       tostring(gun.total[PH]))

    -- ── 6. THE READOUT. The owner cannot check any of this from a chair, and a
    --       diagnostic that throws is worse than none -- /brloot and /brkeys are
    --       pinned the same way for the same reason. Exercised on a live
    --       inventory AND on an empty one, because the empty case is the one
    --       that reaches for fields that are not there.
    ok(pcall(commands['brammo'], nil, {}, ''),
       '/brammo does not throw with a weapon in hand')
    fire(BR.Net.INV_SET, { slots = {}, ammo = {}, active = 0 })
    ok(pcall(commands['brammo'], nil, {}, ''),
       'and neither does it on an empty inventory holding fists')

    GiveWeaponToPed     = savedGive
    RemoveAllPedWeapons = savedRemove
    SetPedAmmo          = savedSetAmmo
    SetAmmoInClip       = savedSetClip
    GetAmmoInPedWeapon  = savedGetAmmo
    GetAmmoInClip       = savedGetClip
    SetCurrentPedWeapon = savedCurrent
    pedWeapon = nil
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
end

-- ======================================================================== --
-- O. THE MANUAL RELOAD KEY
-- ======================================================================== --
--
-- Owner, 2026-08-23: "we need a manual reload button, which should default to
-- R." R WAS ALREADY `use`, and keybinds.lua chose it in the first place by
-- arguing about a reload that did not exist yet -- "the two never want the key
-- at the same moment". That sentence is now load-bearing, so it is what this
-- block tests: ONE key, and which of the two things it means is decided by what
-- is in the player's hands.
--
-- THE SERVER OWNS THE ARITHMETIC AND test_roster PROVES IT. What is proved here
-- is narrower and is the half that lives on this side: which message goes out,
-- and -- for the states where nothing should happen -- that NOTHING goes out.
-- A key that asks the server on every press would be answered correctly and
-- would still be wrong, because it would eat the `use` that press was.
describe('#R -- the manual reload key')
do
    local RIFLE = BR.Config.WeaponById['carbinerifle']

    local function press()
        for _, fn in ipairs(BR.Keys.listeners['use'] or {}) do fn(true) end
    end

    local function asked(name)
        local n = 0
        for _, s in ipairs(sent) do if s.name == name then n = n + 1 end end
        return n
    end

    --- Stand the player up holding slot 1, with a shield in slot 2.
    ---
    --- THE SHIELD IS NOT SCENERY. `use` falls through to "the lowest slot that
    --- is consumable" when the active slot is not one, so without something to
    --- fall through TO, every "the reload took the press" assertion would pass
    --- against a key that did nothing whatsoever.
    local function holding(slot, pool)
        fire(BR.Net.INV_SET, {
            slots = {
                slot,
                { id = 'shield', label = 'Shield',
                  kind = BR.ItemKind.CONSUMABLE, rarity = 2, count = 1 },
            },
            ammo = { medium = pool }, active = 1,
        })
    end

    local function rifle(clip)
        return { id = 'carbinerifle', label = 'Carbine Rifle',
                 kind = BR.ItemKind.WEAPON, rarity = 3, count = 1,
                 clip = clip, pool = 'medium' }
    end

    BR.State.me.state = BR.PlayerState.ALIVE
    BR.State.landed = true
    fire(BR.Net.STATE, { state = BR.MatchState.PLAYING })

    -- ── 1. THE ORDINARY PRESS: a magazine with room in it over a live pool.
    holding(rifle(10), 100)
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 1,
       'R with a half-empty rifle in hand asks the server to reload',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))
    ok(asked(BR.Net.INV_USE) == 0,
       'and it does NOT also drink the shield in slot 2 -- one press, one thing',
       ('%d INV_USE'):format(asked(BR.Net.INV_USE)))

    -- ── 2. A FULL MAGAZINE IS NOT A RELOAD, so the press is a `use` again. This
    --       is the assertion that keeps the key from swallowing the old
    --       behaviour: the two are exclusive, not ordered.
    holding(rifle(RIFLE.clip), 100)
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 0,
       'a full magazine is not a reload',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))
    ok(asked(BR.Net.INV_USE) == 1,
       'and the press goes back to being the use key it always was',
       ('%d INV_USE'):format(asked(BR.Net.INV_USE)))

    -- ── 3. AN EMPTY POOL IS NOT A RELOAD EITHER, and this is the railgun's
    --       ordinary state -- the one every ammo bug this week was found in.
    --       Quietly: no message, no notification, nothing to answer.
    holding(rifle(0), 0)
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 0,
       'A DRY GUN OVER AN EMPTY POOL ASKS FOR NOTHING',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))

    -- ...AND SPAMMING IT IS THE SAME NOTHING. The server cannot mint a round
    -- here either (test_roster runs a hundred presses at zero pool through the
    -- real handler); this is the half that keeps the wire quiet as well.
    sent = {}
    for _ = 1, 50 do press() end
    ok(asked(BR.Net.INV_RELOAD) == 0,
       'and fifty presses at zero pool send fifty nothings',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))

    -- ── 4. FISTS. Slot 0 holds nothing at all, and `inv.slots[0]` is not even
    --       an index -- the predicate has to answer that without reaching into
    --       it.
    fire(BR.Net.INV_SET, {
        slots = { rifle(0),
                  { id = 'shield', label = 'Shield',
                    kind = BR.ItemKind.CONSUMABLE, rarity = 2, count = 1 } },
        ammo = { medium = 100 }, active = 0,
    })
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 0,
       'a reload on fists asks for nothing',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))
    ok(asked(BR.Net.INV_USE) == 1,
       'and R with empty hands still reaches the shield, as it always did',
       ('%d INV_USE'):format(asked(BR.Net.INV_USE)))

    -- ── 5. A MACHETE HAS NO MAGAZINE. It is a WEAPON by kind, which is exactly
    --       why `kind == WEAPON` is not the whole test -- `w.clip` is nil here
    --       and `w.clip or 0` would have made it a gun with a zero magazine.
    holding({ id = 'machete', label = 'Machete', kind = BR.ItemKind.WEAPON,
              rarity = 1, count = 1 }, 100)
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 0,
       'a machete cannot be reloaded',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))

    -- ── 6. A THROWABLE'S "MAGAZINE" IS ITS STACK. Nothing moves rounds into a
    --       grenade, and a reload that touched `count` would be inventing them.
    holding({ id = 'grenade', label = 'Grenade', kind = BR.ItemKind.THROWABLE,
              rarity = 3, count = 2 }, 100)
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 0,
       'and neither can a grenade',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))

    -- ── 7. IN THE AIR, WHICH IS DELIBERATE AND IS NOT ABOUT RELOADING. Arming
    --       is suspended for the whole descent because RemoveAllPedWeapons takes
    --       the parachute with it, and canArm() is the gate that says so -- so a
    --       reload at 400 metres is refused by the same line, on this side, and
    --       again at the far end where FREEFALL is not in the LIVE table.
    holding(rifle(10), 100)
    BR.State.landed = false
    BR.State.me.state = BR.PlayerState.FREEFALL
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 0 and asked(BR.Net.INV_USE) == 0,
       'a reload in freefall asks for nothing, and neither does anything else',
       ('%d INV_RELOAD, %d INV_USE'):format(asked(BR.Net.INV_RELOAD),
                                            asked(BR.Net.INV_USE)))

    BR.State.me.state = BR.PlayerState.GLIDE
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 0,
       'and under the canopy is the same answer',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))

    -- ...AND IT COMES BACK ON TOUCHDOWN, with nothing to reset. The landing
    -- latch is what canArm() reads, so this is the same press one state later.
    BR.State.landed = true
    BR.State.me.state = BR.PlayerState.ALIVE
    sent = {}
    press()
    ok(asked(BR.Net.INV_RELOAD) == 1,
       'and the first press on the ground reloads',
       ('%d INV_RELOAD'):format(asked(BR.Net.INV_RELOAD)))

    -- ── 8. THE BINDING ITSELF. One row, on R, and it is a TAP -- a held reload
    --       would repeat for as long as the key was down.
    local row
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == 'bruse' then row = b end
    end
    ok(row ~= nil, 'the key is in the table the settings screen reads')
    ok(row and row.default == 'R', 'and it defaults to R',
       tostring(row and row.default))
    ok(row and row.hold == false, 'as a TAP -- one press, one magazine',
       tostring(row and row.hold))
    ok(row and row.label:find('eload') ~= nil,
       'and the row says so, because it is the only row that can',
       tostring(row and row.label))

    -- NOTHING ELSE CLAIMED R. The whole argument for one binding is that there
    -- is only one, so a second row on the same default would silently make this
    -- block's exclusivity assertions meaningless.
    local onR = 0
    for _, b in ipairs(BR.Keys.bindings) do
        if b.default == 'R' then onR = onR + 1 end
    end
    ok(onR == 1, 'and it is the only binding defaulting to R', tostring(onR))

    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
end

realPrint(('%s%d passed, %d failed\27[0m')
    :format(fail == 0 and '\27[32m' or '\27[31m', pass, fail))
os.exit(fail == 0 and 0 or 1)

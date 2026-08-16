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

--- Which raw natives this simulated BUILD has. Flipped per block so the same
--- interaction is proved on all three mechanisms rather than on the developer's.
local build = { rawDown = true, rawPressed = true }

function IsRawKeyDown(vk)
    if not build.rawDown then error('IS_RAW_KEY_DOWN: no such native', 0) end
    if lying[vk] then return false end
    return keys[vk] == true
end

function IsRawKeyPressed(vk)
    if not build.rawPressed then error('IS_RAW_KEY_PRESSED: no such native', 0) end
    return edge[vk] == true
end

-- ------------------------------------------------------------------ world ---

local pedPos = { x = 0.0, y = 0.0, z = 30.0 }
local inVehicle = false
function GetEntityCoords() return pedPos end
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
function GetCurrentPedWeapon() return false, 0 end
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
        -- The Mumble client's own connection, which drops and returns
        -- underneath the game with no event to hang anything on. It is a
        -- field rather than a constant because the only thing that notices is
        -- the 1Hz watcher in voice.lua, and a test that cannot take the
        -- connection away cannot exercise it.
        connected = true,
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

function MumbleSetActive(v) mumble.active = v and true or false end
function MumbleIsConnected() return mumble.connected end
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
             src = BR.State.me.src,
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

    -- AN OVERRIDE BEATS THE CUTOFF. This is the whole mechanism squad voice
    -- runs on: the listener has taken this speaker out of the distance
    -- calculation, so where they are standing stops mattering.
    if listener.volume[speaker.src] ~= nil then return true end

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
    'SetPlayerCanDoDriveBy', 'SetPlayerMaxArmour', 'SetWeaponsNoAutoswap',
}) do _G[n] = noop end

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
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    -- The catalogue, for the descent block at the bottom: what `trail_ember`
    -- resolves to is the first of the four things the smoke-trail prompt is
    -- made of, and BR.Config.MarketIndex is where that answer lives.
    'br_lib/config/market.lua',
    'br_lib/shared/storm_solve.lua', 'br_lib/shared/loot_gen.lua',
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
BR.Native = {
    aim = function() return false, nil, 0 end,
    keyLabelForCommand = function() return 'E', 'brinteract' end,
    blipName = noop, help = noop,
    inputForCommand = function() return '~INPUT~' end,
    displayHealth = function() return 100 end,
    setDisplayHealth = noop,
}
BR.Dui = {
    page = function() return { id = 'prompt' } end,
    send = noop, drawWorld = noop, drawOnEntity = noop,
}

loadAll({
    'br_core/client/keybinds.lua',   -- before loot.lua, as fxmanifest orders it
    'br_core/client/inventory.lua',
    'br_core/client/loot.lua',
    -- The consumer half of the voice pair. Loaded here rather than left to the
    -- server suite because #150 was entirely on this side: server/voice.lua's
    -- arithmetic was right, tools/test_roster.lua proved it was right, and two
    -- players still could not hear each other.
    'br_core/client/voice.lua',
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
--- The three cases are the three `via` lines /brloot prints, and every one of
--- them is a machine somebody is actually playing on.
--- @param rawDown boolean     IS_RAW_KEY_DOWN exists (the level sample)
--- @param rawPressed boolean  IS_RAW_KEY_PRESSED exists (the edge fallback)
local function bootOn(rawDown, rawPressed)
    releaseInteract()
    build.rawDown, build.rawPressed = rawDown, rawPressed
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

--- The live hold clock, read the same way /brloot reads it.
local function holdMs()
    logged = {}
    commands['brloot'](nil, {}, '')
    for _, line in ipairs(logged) do
        local ms = line:match('^%s*hold:%s+#?%-?%d*%s+(%d+)/%d+ms')
        if ms then return tonumber(ms) end
    end
    return nil
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

for _, mech in ipairs({
    { name = 'raw level sample (IsRawKeyDown)', rawDown = true,  rawPressed = true },
    { name = 'engine +/- pair (no IsRawKeyDown)', rawDown = false, rawPressed = true },
    { name = 'engine +/- pair (no raw layer)',  rawDown = false, rawPressed = false },
}) do

describe('crate hold -- ' .. mech.name)
do
    bootOn(mech.rawDown, mech.rawPressed)
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
    bootOn(mech.rawDown, mech.rawPressed)
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
end

-- ------------------------------------------------------------------- voice ---
--
-- WHY VOICE IS TESTED FROM THE CLIENT SIDE AT ALL.
--
-- tools/test_roster.lua has swept the channel arithmetic since the day voice
-- shipped -- 64 matches by 16 squads, no collisions, nothing in channel 0 --
-- and every one of those assertions was passing on the build where two solo
-- players stood next to each other in silence (#150). The arithmetic was never
-- the problem. What the server computes is only half a voice system; the other
-- half is what the client does with it, and until this section nothing tested
-- that half at all.

--- Apply one server assignment to a FRESH engine, and freeze the result.
---
--- The settings event first, because that is the real order: br_ui pushes the
--- stored preference on br:ui:ready and the server pushes channels on every
--- state change. Whichever lands second re-applies.
--- @param mode string   'squad' | 'nearby' | 'off'
--- @param prox integer|nil
--- @param mates table|nil  squadmate server ids, as the server sends them
--- @param me integer|nil   this machine's own server id
--- @return table snapshot
--- The Mumble server answering, and the client noticing.
---
--- One turn is one round trip: everything asked for comes into existence, a
--- pending join completes, and the 10Hz band gets a step so voice.lua can
--- state the routing it deliberately withheld while the room was still on its
--- way. Both halves matter -- a client that states its routing once, in the
--- frame it was told the numbers, states it into a void and never finds out.
--- @param turns integer|nil  round trips to let pass; three by default
local function mumbleSettle(turns)
    for _ = 1, turns or 3 do
        for ch in pairs(mumble.pending) do mumble.channels[ch] = true end
        mumble.pending = {}
        if mumble.want then
            if mumble.channels[mumble.want] then
                mumble.channel = mumble.want
            else
                -- The implicit create: asking to join a room that does not
                -- exist is what brings it into being, one round trip later.
                mumble.pending[mumble.want] = true
            end
        end
        BR.Loop.step(BR.Loop.TICK)
    end
end

local VR = BR.Config.Match.voice.range

--- Where this machine's own player is standing. Squad range is decided from
--- the squad position push against this, so a test that wants to separate two
--- squadmates moves one of them here and pushes the other's coordinates.
local function standAt(x, y)
    pedPos = { x = x + 0.0, y = y + 0.0, z = 30.0 }
end

--- The 1Hz squad position push, which is where voice learns how far away a
--- squadmate is. Coordinates only -- membership comes from VOICE_SET, because
--- this push stops entirely while a squad is on the bus and a squad that could
--- not talk on the drop would be a worse bug than the one being fixed.
--- @param list table  { { src = n, x = n, y = n }, ... }
local function squadAt(list)
    fire(BR.Net.SQUAD_POS, list)
end

local function voiceApply(mode, prox, mates, me)
    BR.State.me.src = me or 1
    mumbleReset()
    fire('br:settings:changed', { voiceMode = mode })
    -- THE SERVER MAKES THE ROOM FIRST. This is br_core/server/voice.lua's
    -- makeChannel(), in the order it really happens. ONE room now: the squad
    -- room is gone (#157), so there is no longer a second room on a second
    -- clock for a listen to be stated against too early.
    serverCreates(prox)
    fire(BR.Net.VOICE_SET, { prox = prox, mates = mates,
                             nearbyRange = VR.nearby, squadRange = VR.squad })
    -- AND THEN A MOMENT PASSES, because it has to. See mumbleSettle.
    mumbleSettle()
    return mumbleSnapshot()
end

--- Change the preference on a machine that already has an assignment, without
--- touching the engine model -- the settings screen mid-match.
local function voiceMode(mode)
    fire('br:settings:changed', { voiceMode = mode })
    -- A PREFERENCE CHANGE COSTS A BEAT TOO. Applying one clears the room and
    -- re-joins it, and re-joining is a round trip like any other -- so the
    -- transmit path is withheld across it exactly as it is on a fresh
    -- assignment. That is a real half-second of silence when a player flips
    -- the setting mid-match, and it is the correct trade: the alternative is
    -- re-stating a target against a room the engine has not confirmed, which
    -- is the bug.
    mumbleSettle()
    return mumbleSnapshot()
end

describe('a room has to exist before anything can use it -- #150')
do
    -- THE ASSERTIONS THAT WOULD HAVE CAUGHT THIS, and did not exist.
    --
    -- Every other voice test in this file used to run against a model in which
    -- naming a room was the same as there being one, which is why they were
    -- all green while two players stood next to each other in silence. These
    -- are the three facts that separate naming a room from having one.
    local PROX = 2041

    -- 1. THE ROUTING IS WITHHELD UNTIL THE ROOM IS REAL.
    --
    --    This is the assignment arriving and the client acting on it, with no
    --    time allowed to pass -- which is exactly what the shipped build did,
    --    all of it in one frame. The engine has not joined the room yet, so
    --    the voice target must not be filled: every channel handed to
    --    MumbleAddVoiceTargetChannel here would be discarded in silence and
    --    never retried, leaving the microphone wired to nothing.
    BR.State.me.src = 1
    mumbleReset()
    fire('br:settings:changed', { voiceMode = 'squad' })
    serverCreates(PROX)
    fire(BR.Net.VOICE_SET, { prox = PROX, mates = { 2 },
                             nearbyRange = VR.nearby, squadRange = VR.squad })

    local early = mumbleSnapshot()
    ok(early.channel ~= PROX,
        'the room is not joined in the frame it was asked for',
        tostring(early.channel))
    ok(#early.sends == 0,
        'so nothing is transmitted into it yet -- and nothing is thrown away',
        ('sends=%d'):format(#early.sends))
    ok(early.refused == '',
        'and the engine is asked to resolve nothing it cannot', early.refused)

    -- 2. AND THEN IT IS STATED, WITHOUT A NEW ASSIGNMENT TO PROMPT IT. The
    --    room turns up about half a second later and something has to notice.
    --    Nothing did before this fix: the client spoke once, into a void.
    mumbleSettle()
    local settled = mumbleSnapshot()
    ok(settled.channel == PROX,
        'once the room exists the player is in it', tostring(settled.channel))
    ok(#settled.sends == 1 and settled.sends[1] == PROX,
        'and the transmit path is stated then, not before',
        ('sends=%d refused=%s'):format(#settled.sends, settled.refused))

    local other = voiceApply('squad', PROX, { 1 }, 2)
    ok(hears(settled, other) and hears(other, settled),
        'so two players in a room that exists can hear each other')

    -- 3. AND NO ROOM IS NAMED THAT NOBODY MADE -- because there is only one
    --    room left to name (#157).
    --
    --    This block used to assert the opposite: that a squad room the server
    --    forgot to create produced the exact console line the owner pasted
    --    into #150. It kept producing it, and the owner could never say when,
    --    because it was a race -- the client waited for the PROXIMITY room and
    --    then immediately named the SQUAD room, a different room on a
    --    different clock, without ever asking whether that one had arrived.
    --    Squad voice no longer uses a room, so the refusal has no way to
    --    happen and this asserts it never does.
    ok(settled.refused == '' and other.refused == '',
        'nothing is refused by the engine, in either mode',
        settled.refused .. ' ' .. other.refused)
    ok(next(settled.listen) == nil and next(other.listen) == nil,
        'and no channel listen is stated at all, which is what made the '
        .. 'warning possible')
end

describe('solo proximity voice -- #150')
do
    -- Two players, one solo match, standing together. Both get the same
    -- proximity room and no squad room, which is exactly the payload
    -- tools/test_roster.lua asserts the server sends a solo.
    local PROX = 2003

    -- 'nearby' IS THE SHIPPED DEFAULT (br_ui/client/settings.lua), so this is
    -- the configuration every player is in until they open the settings screen
    -- and change it -- and it is the mode the owner named in the report.
    local a = voiceApply('nearby', PROX, nil, 1)
    local b = voiceApply('nearby', PROX, nil, 2)

    ok(a.channel == PROX, 'a solo player is put in their match room',
        tostring(a.channel))
    ok(#a.sends > 0,
        'AND is given somewhere to send audio -- the whole of #150',
        ('sends=%d selected=%s'):format(#a.sends, tostring(a.selected)))
    ok(a.sends[1] == PROX, 'and that somewhere is the match room',
        tostring(a.sends[1]))
    ok(hears(a, b) and hears(b, a),
        'so two solos in one match, standing together, can hear each other')
    ok(a.prox == VR.nearby, 'with the talker proximity the server sent',
        tostring(a.prox))

    -- The other half of the solo case: a player whose preference is 'squad'
    -- but who has no squad. Before the fix this was silent too -- the branch
    -- that set the target needed a squad channel to exist.
    local c = voiceApply('squad', PROX, nil, 3)
    ok(#c.sends > 0 and c.sends[1] == PROX,
        'a solo who prefers squad voice still reaches the match room',
        ('sends=%d'):format(#c.sends))
    ok(hears(c, a), 'and is audible to a solo on the default preference')
    ok(#c.people == 0,
        'and opens a radio to nobody -- a solo has no squadmates to name',
        ('people=%d'):format(#c.people))
end

describe('squad voice is a radio, not a room -- #157')
do
    -- THE TRADE THIS FIX MUST NOT MAKE. Repairing proximity by capping squads
    -- at 25 m would be a worse bug than the one being fixed -- "squad voice
    -- cutting out at 25 m is not squad voice" -- so the squad case is asserted
    -- in the same breath, at a range that would fail under a naive cap.
    local PROX = 2007
    local FAR = 400.0

    standAt(0, 0)
    local a1 = voiceApply('squad', PROX, { 2 }, 1)
    squadAt({ { src = 1, x = 0, y = 0 }, { src = 2, x = FAR, y = 0 } })
    a1 = mumbleSnapshot()

    standAt(FAR, 0)
    local a2 = voiceApply('squad', PROX, { 1 }, 2)
    squadAt({ { src = 1, x = 0, y = 0 }, { src = 2, x = FAR, y = 0 } })
    a2 = mumbleSnapshot()

    -- A rival squad in the same match, standing next to the first player.
    standAt(0, 0)
    local b1 = voiceApply('squad', PROX, { 4 }, 3)

    ok(a1.channel == PROX, 'a squad player is still in the match room')
    ok(#a1.sends == 1 and a1.sends[1] == PROX,
        'and still sends into it', ('sends=%d'):format(#a1.sends))
    ok(#a1.people == 1 and a1.people[1] == 2,
        'and additionally straight to their squadmate, by server id',
        ('people=%d'):format(#a1.people))
    ok(a1.volume[2] ~= nil,
        'with that squadmate exempted from the distance cutoff -- the only '
        .. 'mechanism that can outreach proximity')
    ok(a1.volume[3] == nil and a1.volume[4] == nil,
        'and nobody else exempted')

    ok(hears(a1, a2, FAR) and hears(a2, a1, FAR),
        ('so squadmates %dm apart still hear each other'):format(FAR))
    ok(hears(a1, b1, 5.0),
        'while a rival squad standing next to them hears them as proximity')
    ok(not hears(a1, b1, FAR) and not hears(b1, a1, FAR),
        'and the same rival, walked away, does not')
    ok(#b1.people == 1 and b1.people[1] == 4,
        'each squad having a radio only to its own', ('%d'):format(#b1.people))
end

describe('voice never crosses a match')
do
    -- The property the whole voice system exists for, now checked on the side
    -- that actually talks to Mumble. Two matches, two proximity rooms.
    standAt(0, 0)
    local a = voiceApply('nearby', 2003, nil, 1)
    local b = voiceApply('nearby', 2004, nil, 2)
    ok(not hears(a, b) and not hears(b, a),
        'two different matches cannot hear each other')

    -- And the lobby is a room too -- leaving somebody in channel 0 puts them
    -- with everyone whose assignment has not landed yet.
    local lobby = voiceApply('nearby', BR.Config.Match.voice.lobbyChannel, nil, 3)
    ok(lobby.channel ~= 0 and #lobby.sends > 0,
        'and a player in the lobby is in a real room with a real target')
    ok(not hears(lobby, a) and not hears(a, lobby),
        'which the match cannot hear and cannot be heard from')
end

describe('switching preference mid-match')
do
    local PROX = 2011

    standAt(0, 0)
    voiceApply('squad', PROX, { 2 }, 1)
    local before = mumbleSnapshot()
    ok(before.volume[2] ~= nil, 'squad mode opens the radio to a squadmate')
    ok(#before.people == 1, 'and points the microphone at them')

    -- AN OVERRIDE OUTLIVES EVERYTHING ELSE, exactly as a channel listen used
    -- to: MumbleClearVoiceChannel takes us out of the room we are IN and says
    -- nothing about a standing instruction to the mixer. Before this was
    -- fixed the same shape of bug let a player who chose 'nearby' keep hearing
    -- their squad at unlimited range while the interface told them they were
    -- on proximity only.
    local after = voiceMode('nearby')
    ok(after.volume[2] == nil, 'and choosing nearby shuts it again')
    ok(#after.people == 0, 'and stops sending to them directly',
        ('people=%d'):format(#after.people))
    ok(#after.sends == 1 and after.sends[1] == PROX,
        'leaving the proximity room as the only destination',
        ('sends=%d'):format(#after.sends))

    local back = voiceMode('squad')
    ok(back.volume[2] ~= nil and #back.people == 1,
        'and choosing squad again restores both')

    local off = voiceMode('off')
    ok(not off.active, 'off stops transmitting')
    local on = voiceMode('nearby')
    ok(on.active and #on.sends > 0, 'and coming back off it re-establishes audio')
end

describe('leaving a match takes its rooms with it')
do
    local PROX = 2019

    standAt(0, 0)
    voiceApply('squad', PROX, { 2 }, 1)
    -- Back to the lobby: the server pushes the lobby room and an empty squad.
    fire(BR.Net.VOICE_SET, { prox = BR.Config.Match.voice.lobbyChannel,
                             mates = {},
                             nearbyRange = VR.nearby, squadRange = VR.squad })
    -- The lobby is a room like any other and has to be created like any other
    -- -- so there is a beat between leaving the match and arriving in it. That
    -- beat is silent rather than leaky: the voice target is cleared before the
    -- new one is built, so a player mid-transition is transmitting nowhere.
    mumbleSettle()
    local lobby = mumbleSnapshot()

    ok(lobby.volume[2] == nil,
        'the radio to the squad just left is shut')
    ok(#lobby.sends == 1 and lobby.sends[1] == BR.Config.Match.voice.lobbyChannel,
        'and nothing is still being sent into the match just left',
        table.concat(lobby.sends, ','))
    ok(#lobby.people == 0, 'nor to anybody who is still in it',
        ('people=%d'):format(#lobby.people))

    local stillIn = voiceApply('squad', PROX, { 3 }, 2)
    ok(not hears(lobby, stillIn) and not hears(stillIn, lobby),
        'so the lobby and the match are mutually inaudible')
end

describe('a Mumble reconnect re-establishes the routing')
do
    -- The Mumble client drops and comes back underneath us with no event. A
    -- channel set while it was down never took, and the 1Hz watcher is the
    -- only thing that notices -- so it has to restore the TARGET as well as
    -- the channel, or the player comes back in the right room and mute.
    local PROX = 2023
    voiceApply('nearby', PROX, nil, 1)

    -- THE DROP, MODELLED AS A DROP rather than by reaching in and clearing a
    -- flag by hand. The engine forgets everything it knew, the connection goes
    -- away, and the 1Hz watcher is the only thing in the game that can notice
    -- either of those.
    mumbleReset()
    mumble.connected = false
    BR.Loop.step(BR.Loop.SLOW)

    mumble.connected = true      -- ...and it comes back
    BR.Loop.step(BR.Loop.SLOW)

    -- NOTHING IS ASSUMED TO HAVE SURVIVED IT. A reconnected Mumble client
    -- rebuilds its channel list from the server, so the room has to be joined
    -- again and the routing has to wait for it again. A client that trusted
    -- its own memory here would come back holding the right room number with
    -- nothing behind it, for the rest of the match.
    ok(mumble.want == PROX, 'the room is joined again from scratch',
        tostring(mumble.want))
    -- And the target stays empty until it is: re-stating routing into a room
    -- the engine has not rejoined is the original bug, arriving by a new road.
    ok(#(mumble.targets[1] or {}) == 0,
        'and nothing is transmitted into it while that is pending')

    mumbleSettle()
    local healed = mumbleSnapshot()

    ok(healed.channel == PROX, 'the room is re-joined', tostring(healed.channel))
    ok(#healed.sends > 0 and healed.sends[1] == PROX,
        'and the transmit path is re-established with it',
        ('sends=%d'):format(#healed.sends))
end

describe('proximity voice has a range at all -- #157')
do
    -- THE ASSERTION WHOSE ABSENCE LET A MAP-WIDE PARTY LINE SHIP.
    --
    -- Every voice test above this one passed on the build the owner reported,
    -- because none of them had any idea where anybody was standing. The three
    -- facts here are the ones that separate "there is a path" from "they can
    -- actually hear each other".
    local PROX = 2031

    standAt(0, 0)
    local a = voiceApply('nearby', PROX, nil, 1)
    local b = voiceApply('nearby', PROX, nil, 2)

    -- 1. THE RANGE IS STATED TO THE ENGINE AT ALL. Both halves: input is how
    --    far our voice carries, output is how far we can hear from, and the
    --    engine takes the tighter of the two. Neither was ever set.
    ok(a.inDist == VR.nearby,
        'the client tells Mumble how far its own voice carries',
        tostring(a.inDist))
    ok(a.outDist == VR.nearby,
        'and how far away it can hear from', tostring(a.outDist))

    -- 2. AND IT ACTUALLY CUTS OFF. On the stock convar path the engine's
    --    proximity is a binary in/out test, so this is exactly what a player
    --    experiences: audible, then a step further, gone.
    ok(hears(a, b, VR.nearby - 5.0) and hears(b, a, VR.nearby - 5.0),
        ('two solos %.0fm apart hear each other'):format(VR.nearby - 5.0))
    ok(not hears(a, b, VR.nearby + 5.0),
        ('and %.0fm apart they do not -- this is the whole of #157')
            :format(VR.nearby + 5.0))
    ok(not hears(a, b, 1000.0),
        'nor across the map, which is what was reported')

    -- 3. AND A CLIENT THAT NEVER STATED ONE HEARS EVERYTHING. The shipped
    --    build, reproduced: same rooms, same targets, same everything except
    --    that nobody handed Mumble a distance. If this ever stops being true
    --    the model has been made too forgiving to catch the next one.
    local deaf = { active = true, channel = PROX, sends = { PROX }, people = {},
                   listen = {}, volume = {}, src = 9,
                   inDist = nil, outDist = nil }
    ok(hears(deaf, deaf, 5000.0),
        'while a client that states no range is audible 5km away -- the '
        .. 'default, and the bug')
end

describe('squad range is enforced, not assumed -- #157')
do
    -- range.squad IS A REAL CUTOFF, not a synonym for infinity. It defaults
    -- past the map diagonal so that squad comms never drop in play, but the
    -- mechanism is a range like any other and an unenforced number in config
    -- is a lie waiting to be found in a playtest.
    local PROX = 2037

    standAt(0, 0)
    voiceApply('squad', PROX, { 2 }, 1)
    squadAt({ { src = 2, x = VR.squad + 500.0, y = 0 } })
    local tooFar = mumbleSnapshot()
    ok(tooFar.volume[2] == nil,
        ('a squadmate beyond the squad range (%.0fm) is not exempted')
            :format(VR.squad))
    ok(#tooFar.people == 1,
        'though the microphone still points at them -- routing is membership, '
        .. 'audibility is range')

    squadAt({ { src = 2, x = 400.0, y = 0 } })
    local back = mumbleSnapshot()
    ok(back.volume[2] ~= nil,
        'and walking back inside it opens the radio again without a new '
        .. 'assignment from the server')

    -- NO POSITION MEANS AUDIBLE. There is no squad position push while the
    -- squad is on the bus, and a squad that could not talk on the drop would
    -- be a worse bug than the one being fixed.
    squadAt({})
    local silentPush = mumbleSnapshot()
    ok(silentPush.volume[2] ~= nil,
        'a squadmate nobody has placed yet -- on the bus, or in the first '
        .. 'second -- is audible rather than silent')
end

describe('the voice readout runs')
do
    -- /brvoice is the one instrument a playtester has for this, and #150 is
    -- being handed back to the owner with "run it and read the talking-into
    -- line" -- so it must not throw and it must actually say something.
    standAt(0, 0)
    voiceApply('nearby', 2029, nil, 1)
    logged = {}
    ok(pcall(commands['brvoice'], nil, {}, ''), '/brvoice does not throw')
    local said = table.concat(logged, '\n')
    ok(said:find('talking into', 1, true) ~= nil,
        'and reports where audio is being sent, not just which room we are in')
    ok(said:find('NOTHING', 1, true) == nil,
        'and does not report silence on a healthy assignment', said)
    -- The line the second attempt at #150 needed. "talking into" is what this
    -- client ASKED the engine for, and on the reported build the engine
    -- accepted none of it -- so the readout has to say whether the engine
    -- agrees the player is in the room those numbers came from.
    ok(said:find('in the room', 1, true) ~= nil,
        'and says whether the engine has actually joined the room')
    ok(said:find('NOT YET', 1, true) == nil,
        'which on a settled assignment it has', said)
    -- AND THE LINE #157 NEEDS. A playtester who cannot see the range in force
    -- cannot tell a broken cutoff from a working one, which is how a map-wide
    -- party line survived two rounds of diagnosis.
    ok(said:find('nearby range', 1, true) ~= nil,
        'and prints the range actually in force')
    ok(said:find('GLOBAL', 1, true) == nil,
        'and does not warn about a missing range on a build that has it', said)
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
    local smoke = { allowed = nil, rgb = nil }
    function SetPlayerCanLeaveParachuteSmokeTrail(_, on) smoke.allowed = on end
    function SetPlayerParachuteSmokeTrailColor(_, r, g, b) smoke.rgb = { r, g, b } end

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
        ('armed %s source %s'):format(tostring(BR.Cosmetics.trailArmed),
                                      tostring(BR.Cosmetics.trailSource)))
    ok(BR.Cosmetics.trailSource == 'purchase' and smoke.allowed == true,
        'and it is the purchase that is painted, solo or not')

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

    press(0x42, 'B')
    ok(BR.Cosmetics.trailOn == true and smoke.allowed == true,
        'and pressing it again gives the trail back',
        ('on %s allowed %s'):format(tostring(BR.Cosmetics.trailOn),
                                    tostring(smoke.allowed)))
    ok(smoke.rgb ~= nil, 'in the colour that was bought')

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
    ok(dbg:find('trail key: presses 3', 1, true) ~= nil,
        'the readout counts the presses that actually reached the toggle',
        dbg:match('trail key:[^\n]*') or 'no trail key line')
    ok(dbg:find('acted 3', 1, true) ~= nil,
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
    -- reason /brdropdbg prints the four readings.
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

    -- Squad Colour is the free default -- `trailRgb = nil` -- so solo it paints
    -- nothing, and a slot test would have offered a prompt anyway.
    drop('trail_squad', nil)
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

    -- Equipped Squad Colour IN a squad does paint, and that player owns the
    -- choice, so they get the key like anyone else (#131 removed the override).
    drop('trail_squad', '#3B9BFF')
    ok(BR.Cosmetics.trailArmed == true and BR.Cosmetics.trailSource == 'squad',
        'in a squad the same item paints the squad colour',
        ('armed %s source %s'):format(tostring(BR.Cosmetics.trailArmed),
                                      tostring(BR.Cosmetics.trailSource)))

    -- A BOUGHT TRAIL IN A SQUAD IS THE REVERSAL THE OWNER ASKED FOR. `source
    -- purchase` while squadded is the single line that proves it.
    drop('trail_ember', '#3B9BFF')
    ok(BR.Cosmetics.trailSource == 'purchase',
        'and a bought trail outranks it -- the player earned that trail',
        tostring(BR.Cosmetics.trailSource))

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
    for _, word in ipairs({ 'armed', 'source', 'on ', 'key ' }) do
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

-- ------------------------------------------------------------------ report ---

realPrint(('%s%d passed, %d failed\27[0m')
    :format(fail == 0 and '\27[32m' or '\27[31m', pass, fail))
os.exit(fail == 0 and 0 or 1)

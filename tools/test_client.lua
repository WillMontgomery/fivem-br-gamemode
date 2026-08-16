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
    'br_lib/shared/storm_solve.lua', 'br_lib/shared/loot_gen.lua',
    'br_core/client/main.lua',       -- the loop registry; must be first
})

-- The three collaborators that are pure native wrappers. Loading the real ones
-- would pull in the DUI browser and the ray-cast for no gain: what matters here
-- is which entry the pickup path resolves and what it sends, not what is drawn.
BR.State = BR.State or {}
BR.State.me = { state = BR.PlayerState.ALIVE }
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

-- ------------------------------------------------------------------ report ---

realPrint(('%s%d passed, %d failed\27[0m')
    :format(fail == 0 and '\27[32m' or '\27[31m', pass, fail))
os.exit(fail == 0 and 0 or 1)

-- The data center's main gate (#420), Season 2, client half: THE PROMPT AT A
-- READER, THE ASK, AND THE GATE AS THIS CLIENT SHOWS IT. It decides nothing;
-- every lane is server/dcgate.lua's.
--
--   the doors    the 24 bi-fold leaves and 3 crash arms registered with the
--                door system and locked shut -- in every season, as the
--                br_datacenter pack kept them -- and each posed as its physics
--                streams in, read back and posed again when it is off
--   the prompt   at a lane's reader, "Press E to open the gate" (the owner's
--                words, the E the player's own interact key drawn as a key),
--                while that lane's cycle is not running
--   the ask      interact at a reader: DCGATE_USE, and nothing else
--   the fold     each gate the server says is open, folded open: its leads
--                turn about their post hinges, its followers ride the leads'
--                knuckles and counter-rotate, and the outer gate's arm rises;
--                and back. Each lane's two gates fold apart (a sally port)
--   the dev tools `brgate`
--
-- ═══ THE FOLD (the gate kit's kit_gate_doors.json) ═══
--
-- A lead turns 0-90 degrees about its hinge -- its origin -- by the door
-- system's own open ratio, held locked (the 'ratio' drive), or turned by hand
-- with its handle frozen (the 'rotate' drive; client.drive picks, and `brgate
-- drive` switches it here). A follower is attached to its lead at the knuckle
-- (AttachEntityToEntity, "not DoorSystemSetOpenRatio": the door system cannot
-- fold a pair) and turned -2 times its lead's turn as it is now, so the half
-- folds flat; it is unlocked while attached, and let go, put back, frozen and
-- locked again once its lead is shut. The arm rises with the outer gate. A
-- gate's pose is one number, 0 shut to 1 open (BR.DcGateSolve), moved a whole
-- fold per foldMs; a fold turned back halfway runs back from where it is.
--
-- ═══ A PART TURNED BY HAND STAYS FROZEN (owner, 2026-10-24) ═══
--
-- A door entity this file has turned with SetEntityRotation -- a 'rotate'
-- lead or arm, a follower put back where it was placed -- loses its hinge:
-- unfrozen, a car running into it knocks it loose. So a 'rotate' part is
-- frozen the moment it is found and stays frozen in every pose, shut
-- included, and a follower let go is frozen where it is put back. Frozen, a
-- part is solid: cars stop against it and it cannot fall. Only br_core
-- stopping, or `brgate drive` switching a kind to 'ratio', unfreezes them and
-- hands them back to the door system.
--
-- ═══ IDEMPOTENT, WHEREVER THE GATE IS WHEN IT STREAMS IN ═══
--
-- What a part should show is a function of its gate's pose and nothing else.
-- A door whose physics streams in (DoorSystemGetIsPhysicsLoaded) is posed to it
-- on the SLOW pass -- a gate open since before this client came near arrives
-- open, its followers attached as they are found -- and every lead and arm at
-- rest is read back by its drive's own read (its open ratio, or its
-- rotation) and posed again when it is off; a pass that finds every part
-- where it should be calls nothing but the reads.
--
-- ═══ WHAT IT COSTS ═══
--
-- Nothing per frame, anywhere. Away from the gate the SLOW pass asks one
-- distance (none in the lobby, none without the map pack); within client.nearM
-- it reads each door's physics, and each lead and arm back, once a second;
-- within client.promptM a TICK callback reads this player's position for the
-- prompt; and a FRAME callback exists only while a gate near this client is
-- folding.

BR = BR or {}
BR.DcGate = BR.DcGate or {}

local G = BR.DcGate
local GS = BR.DcGateSolve

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua. Every BOOL read
--- in this file goes through here (tools/bool_native_rules.lua).
local isTrue = BR.NativeTruthy

local function cfg() return BR.Config.DcGate end
local function C() return BR.Config.DcGate.client or {} end
local function parts() return BR.Config.DcGate.parts or {} end

--- THE SEASON, ASKED ONCE A SECOND (client/flick.lua's reason): the handlers,
--- the prompt and the targets read this boolean, and the SLOW pass and
--- BR.Season.onChange refresh it.
local seasonOn = false
local function refreshSeason()
    seasonOn = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('dcgate') == true
end
refreshSeason()

local function on()
    return seasonOn
end

-- ═══ THE PROMPT: THE OWNER'S WORDS (2026-10-19) ═══
--
-- "Press E to open the gate". The E is the player's own interact key: a
-- BR.KeyToken hole the page draws as a key cap, re-resolved on every rebind --
-- the shape of client/skydive.lua's "Press {key} to pull your chute!" and the
-- big map's sticky notice (tools/check_key_glyphs.lua: a key is drawn as a key,
-- and the key it draws is the real one). Sticky while the player stands at a
-- reader of a lane whose cycle is not running, taken down the moment they are
-- not, and silent: it comes up every time anybody walks to a reader.
local PROMPT_KEY = 'dcgate.reader'
local PROMPT_TEXT = 'Press ' .. BR.KeyToken('brinteract') .. ' to open the gate'
G.PROMPT_TEXT = PROMPT_TEXT

--- THE SETTLE: a gate's followers are ridden on after its pose stops, until
--- no lead has turned for SETTLE_FRAMES frames running, before a shut gate's
--- followers are let go. A door the system moves this frame shows it next,
--- and the door system may ease a lead to its ratio over many frames; the
--- followers track it all the way. SETTLE_MAX_FRAMES caps a lead that never
--- comes to rest. A follower's attach yaw changing by more than SETTLE_DEG
--- between frames is its lead still turning.
local SETTLE_FRAMES = 5
local SETTLE_MAX_FRAMES = 300
local SETTLE_DEG = 0.05
--- THE SLOW PASS'S CHECK on a gate at rest: an attached follower more than
--- this off -2 times its lead's turn as the lead stands now (a lead the door
--- system moved after the settle) is ridden again.
local ASTRAY_DEG = 1.0
--- THE READ-BACK on a gate at rest: a 'ratio' lead or arm whose open ratio
--- reads more than REPOSE_RATIO off its gate's pose, or a 'rotate' one whose
--- rotation reads more than REPOSE_DEG off (or that is not frozen), is posed
--- again; one still off on the next pass has its door registered again first.
local REPOSE_RATIO = 0.02
local REPOSE_DEG = 2.0
--- A SNAPSHOT'S POSE is taken over only when this client's pose of that gate
--- is more than this off it (a late joiner, a restart): a client folding in
--- step with the server, a network trip behind, keeps its own.
local POSE_JUMP = 0.1

-- ------------------------------------------------------------ the state ---

--- The server's word for each lane of this match: [n] = { outer, inner, busy }
--- (BR.DcGateSolve.decode). Empty is every gate shut and no cycle running,
--- which is how every match starts: the server says nothing until a lane
--- moves, and the lobby empties it.
local serverGates = {}
--- The match the last word was for (nil: none), for `brgate`.
local gateMatch = nil

--- Every door: { kind = 'lead'|'follow'|'arm', row, lane, gate, name, hash,
--- model, handle?, applied?, attached?, frozen?, yaw? (a follower's last
--- attach yaw), held? (the door state a 'rotate' part was last given), off
--- (passes running it has read back off its pose) }.
local doors = {}
--- The lanes, in order: { n, row, leads ([i] = the door of row.leads[i]),
--- gates = { outer, inner } }.
local lanes = {}
--- [n] = the lane.
local laneByN = {}
--- Every gate, in order (lane 1 outer, lane 1 inner, ...): { lane, n, which,
--- pose, target, settle, settled, folded, adopted, leads, follows, arm?, all }.
local gates = {}

--- Within client.nearM of the gate this pass.
local near = false
--- The pack's models are in this build: nil not asked yet, else the answer.
local present = nil
--- SLOW passes since the pack was last looked for.
local lookedAgo = 0
--- The doors are registered.
local registered = false

--- The reader the prompt is up for (an index into parts().readers), or nil.
local atReader = nil
--- When this client last asked.
local lastAsk = nil

--- Every lane's zones (BR.DcGateSolve.zones), built once per registry table.
local zoneCache, zoneParts = nil, nil
local function zones()
    local p = parts()
    if zoneParts ~= p then zoneCache, zoneParts = GS.zones(p), p end
    return zoneCache
end

local function build()
    doors, lanes, laneByN, gates = {}, {}, {}, {}
    for _, row in ipairs(parts().lanes or {}) do
        local L = { n = row.lane, row = row, leads = {}, gates = {} }
        for _, w in ipairs(GS.GATES) do
            local Gt = { lane = L, n = row.lane, which = w, pose = 0.0, target = 0.0, settle = 0, settled = 0,
                         folded = false, adopted = false, leads = {}, follows = {}, all = {} }
            L.gates[w] = Gt
            gates[#gates + 1] = Gt
        end
        local function add(kind, r, Gt)
            local d = { kind = kind, row = r, lane = L, gate = Gt, name = GS.doorName(r.id),
                        hash = GetHashKey(GS.doorName(r.id)), model = GetHashKey(r.model), off = 0 }
            doors[#doors + 1] = d
            Gt.all[#Gt.all + 1] = d
            return d
        end
        for i, r in ipairs(row.leads or {}) do
            local Gt = L.gates[GS.gateOf(r.id) or '']
            if Gt then
                local d = add('lead', r, Gt)
                L.leads[i] = d
                Gt.leads[#Gt.leads + 1] = d
            end
        end
        for _, r in ipairs(row.follows or {}) do
            local lead = (row.leads or {})[r.lead]
            local Gt = lead and L.gates[GS.gateOf(lead.id) or '']
            if Gt then Gt.follows[#Gt.follows + 1] = add('follow', r, Gt) end
        end
        if row.arm then
            local Gt = L.gates[GS.gateOf(row.arm.id) or '']
            if Gt then Gt.arm = add('arm', row.arm, Gt) end
        end
        lanes[#lanes + 1] = L
        laneByN[L.n] = L
    end
end
build()

-- ------------------------------------------------------------ the doors ---

--- Is the map pack in this build? Its lead's model in the CD image. Asked at
--- load and, while the answer is no, every tenth SLOW pass: a pack that
--- mounts after br_core starts is picked up within ten seconds.
local function packPresent()
    if present then return true end
    if present == false then
        lookedAgo = lookedAgo + 1
        if lookedAgo < 10 then return false end
    end
    lookedAgo = 0
    local first = doors[1]
    present = first ~= nil and isTrue(IsModelInCdimage(first.model))
    return present
end

--- The pack's lock: the open ratio back to 0, forced shut this frame, then
--- held locked (its DOOR_LOCKS loop: "4 forces it shut and locked this frame
--- (a leaf left ajar), then 1 holds it, as ox_doorlock and qb-doorlock do").
local function shut(d)
    DoorSystemSetOpenRatio(d.hash, 0.0, false, true)
    DoorSystemSetDoorState(d.hash, 4, false, true)
    DoorSystemSetDoorState(d.hash, 1, false, true)
    d.held = 1
end

--- One part registered with the door system on this client, under the
--- pack's own name, and locked shut. A name already registered is taken back
--- and registered again, as the pack does.
local function register(d)
    if isTrue(IsDoorRegisteredWithSystem(d.hash)) then RemoveDoorFromSystem(d.hash) end
    AddDoorToSystem(d.hash, d.model, d.row.x, d.row.y, d.row.z, false, false, true)
    shut(d)
end

--- Every part registered and locked shut. Local (no door events are sent: the
--- server's word is DCGATE_STATE), under the pack's own names, so a pack that
--- still registers a part and this file hold one door between them, not two.
local function registerDoors()
    for _, d in ipairs(doors) do
        register(d)
        d.applied, d.attached, d.yaw, d.off = nil, false, nil, 0
    end
    registered = true
end

--- This part's handle: the cached one while it exists, else (when `find`)
--- the map object of its model at its placed origin. Nil when there is none.
--- A handle gone takes what this file did to it along: a copy that streams
--- back in is the map's, hinged and unfrozen.
local function handleOf(d, find)
    local h = d.handle
    if h and isTrue(DoesEntityExist(h)) then return h end
    d.handle, d.attached, d.frozen, d.yaw = nil, false, false, nil
    if not find then return nil end
    h = GetClosestObjectOfType(d.row.x, d.row.y, d.row.z, C().findRadiusM or 0.6, d.model,
        false, false, false)
    if not h or h == 0 then return nil end
    d.handle = h
    return h
end

--- The drive a kind of part is moved by: 'ratio' or 'rotate'.
local function driveOf(kind)
    local dr = C().drive or {}
    return dr[kind] == 'rotate' and 'rotate' or 'ratio'
end

--- How far a lead or the arm turns at its gate's pose.
local function partDeg(d)
    if d.kind == 'lead' then return GS.leadTurn(d.row.sense, d.gate.pose, cfg().foldDeg) end
    return GS.armRaise(d.gate.pose, cfg().armRaiseDeg)
end

--- The 'ratio' drive's open ratio for a lead or the arm at its gate's pose.
local function wantRatio(d)
    if d.gate.pose <= 0 then return 0.0 end
    local which = d.kind == 'lead' and 'lead' or 'arm'
    return GS.ratio(partDeg(d), (C().ratioDeg or {})[which], (C().ratioSign or {})[which])
end

--- The 'rotate' drive's rotation (x, y, z, order 2) for a lead or the arm.
local function wantRotation(d)
    if d.kind == 'lead' then return 0.0, 0.0, d.row.h + partDeg(d) end
    return GS.armRotation(d.row, partDeg(d))
end

--- Bring a lead or the arm to its gate's pose. True when it is there.
---
--- 'rotate': frozen first (and never unfrozen here), then turned; its door
--- locked shut while the part is shut and let go while it is turned.
--- 'ratio': the door system's open ratio, held locked.
local function drivePart(d, find)
    if driveOf(d.kind) == 'rotate' then
        local h = handleOf(d, find)
        if not h then return false end
        if not d.frozen then
            FreezeEntityPosition(h, true)
            d.frozen = true
        end
        local rx, ry, rz = wantRotation(d)
        SetEntityRotation(h, rx, ry, rz, 2, true)
        local want = d.gate.pose > 0 and 0 or 1
        if d.held ~= want then
            if want == 1 then
                shut(d)
            else
                DoorSystemSetDoorState(d.hash, 0, false, true)
                d.held = 0
            end
        end
        return true
    end
    if d.gate.pose <= 0 then
        shut(d)
        return true
    end
    DoorSystemSetOpenRatio(d.hash, wantRatio(d), false, true)
    DoorSystemSetDoorState(d.hash, 1, false, true)
    return true
end

--- THE READ-BACK: is this lead or arm off its gate's pose, by its drive's own
--- read? A 'ratio' part by its open ratio (DoorSystemGetOpenRatio: a part the
--- door system dropped -- an arm hit before its lane opened read 0.000 at
--- pose 1); a 'rotate' part by its rotation, or by not being frozen.
local function offPose(d)
    if driveOf(d.kind) == 'rotate' then
        local h = handleOf(d, false)
        if not h or not d.frozen then return true end
        local rot = GetEntityRotation(h, 2)
        local rx, ry, rz = wantRotation(d)
        return GS.rotationOff(rx, ry, rz, rot.x, rot.y, rot.z) > REPOSE_DEG
    end
    return math.abs((DoorSystemGetOpenRatio(d.hash) or 0.0) - wantRatio(d)) > REPOSE_RATIO
end

--- A follower on its lead's knuckle, turned -2 times the lead's turn as the
--- lead stands NOW (BR.DcGateSolve.followerYaw). Unfrozen as it is attached
--- (it was frozen where it was let go) and unlocked once attached, so the
--- door system does not hold it shut under its lead. True when attached, and
--- then whether its yaw moved since its last ride (its lead turning).
local function ride(f, find)
    local lead = f.lane.leads[f.row.lead]
    local lh = lead and handleOf(lead, find)
    local h = lh and handleOf(f, find)
    if not h then return false, false end
    if f.frozen then
        FreezeEntityPosition(h, false)
        f.frozen = false
    end
    local yaw = GS.followerYaw(GetEntityHeading(lh), lead.row.h, f.row.turn)
    AttachEntityToEntity(h, lh, 0, f.row.ox, f.row.oy, f.row.oz, 0.0, 0.0, yaw,
        false, false, true, false, 2, true)
    local moved = f.yaw == nil or math.abs(GS.wrap180(yaw - f.yaw)) > SETTLE_DEG
    f.yaw = yaw
    if not f.attached then
        f.attached = true
        DoorSystemSetDoorState(f.hash, 0, false, true)
    end
    return true, moved
end

--- Is this attached follower off -2 times its lead's turn as the lead stands
--- now, by more than ASTRAY_DEG? Reads only the lead's heading.
local function astray(f)
    if not f.attached or f.yaw == nil then return false end
    local lead = f.lane.leads[f.row.lead]
    local lh = lead and handleOf(lead, false)
    if not lh then return false end
    local want = GS.followerYaw(GetEntityHeading(lh), lead.row.h, f.row.turn)
    return math.abs(GS.wrap180(want - f.yaw)) > ASTRAY_DEG
end

--- A follower let go of its shut lead: put back at its placed origin and
--- heading as it is let go (so one let go with its lead still turned, br_core
--- stopping mid-fold, does not stay where the knuckle left it), frozen there
--- (turned by hand, it would fall to a hit), and locked shut.
local function release(f)
    local h = f.handle
    if f.attached and h and isTrue(DoesEntityExist(h)) then
        DetachEntity(h, false, true)
        SetEntityCoordsNoOffset(h, f.row.x, f.row.y, f.row.z, false, false, false)
        SetEntityRotation(h, 0.0, 0.0, f.row.h, 2, true)
        FreezeEntityPosition(h, true)
        f.frozen = true
    end
    f.attached, f.yaw = false, nil
    shut(f)
end

--- A part handed back to the door system: a follower let go, then anything
--- this file froze put at its placed rotation and unfrozen, and locked shut.
--- For br_core stopping and `brgate drive`.
local function letGo(d)
    if d.kind == 'follow' then release(d) end
    local h = d.handle
    if d.frozen and h and isTrue(DoesEntityExist(h)) then
        SetEntityRotation(h, 0.0, 0.0, d.row.h, 2, true)
        FreezeEntityPosition(h, false)
    end
    d.frozen = false
    shut(d)
end

--- The gate's leads and arm to its pose.
local function driveGate(Gt, find)
    for _, d in ipairs(Gt.leads) do drivePart(d, find) end
    if Gt.arm then drivePart(Gt.arm, find) end
end

--- Every follower of the gate ridden. True when any of them moved: a lead
--- still turning.
local function rideGate(Gt, find)
    local turning = false
    for _, f in ipairs(Gt.follows) do
        local _, moved = ride(f, find)
        turning = turning or moved
    end
    return turning
end

local function releaseGate(Gt)
    for _, f in ipairs(Gt.follows) do release(f) end
end

-- ------------------------------------------------------------- the fold ---

local animLoop = nil
local lastFrameAt = nil
local animate

local function moving(Gt)
    return Gt.pose ~= Gt.target or Gt.settle > 0
end

local function armAnim()
    if animLoop == nil then
        lastFrameAt = GetGameTimer()
        animLoop = BR.Loop.register(BR.Loop.FRAME, 'dcgate.fold', animate)
    end
end

--- THE FOLD, A FRAME AT A TIME, ONLY WHILE A GATE NEAR THIS CLIENT MOVES. A
--- gate's pose steps toward its target and its parts follow; once there, its
--- followers are ridden on until its leads have stopped turning (THE SETTLE
--- above) and a shut gate's let go. A fold that finished leaves its doors to
--- the SLOW pass (applied cleared), which reads their physics and finds them
--- where they are; the settle after one of the SLOW pass's own poses does
--- not, or the two would hand the gate back and forth for ever.
animate = function()
    local now = GetGameTimer()
    local dt = lastFrameAt and (now - lastFrameAt) or 0
    lastFrameAt = now
    local busy = false
    for _, Gt in ipairs(gates) do
        if Gt.pose ~= Gt.target then
            Gt.pose = GS.step(Gt.pose, Gt.target, dt, cfg().foldMs or 4000)
            driveGate(Gt, false)
            rideGate(Gt, false)
            if Gt.pose == Gt.target then Gt.settle, Gt.settled, Gt.folded = SETTLE_FRAMES, 0, true end
            busy = true
        elseif Gt.settle > 0 then
            Gt.settle = Gt.settle - 1
            Gt.settled = Gt.settled + 1
            if rideGate(Gt, false) and Gt.settled < SETTLE_MAX_FRAMES then Gt.settle = SETTLE_FRAMES end
            if Gt.settle == 0 then
                if Gt.pose <= 0 then releaseGate(Gt) end
                if Gt.folded then
                    Gt.folded = false
                    for _, d in ipairs(Gt.all) do d.applied = nil end
                end
            end
            busy = true
        end
    end
    if not busy then
        BR.Loop.unregister(animLoop)
        animLoop, lastFrameAt = nil, nil
    end
end

--- Every gate's target from the server's word, the season and the lobby.
--- Near the gate a gate that must move folds (its handles found first, so the
--- followers ride from the first frame); away from it the pose is simply the
--- target, and the parts are posed as they stream in. A gate whose pose a
--- snapshot just set (adopted) folds on from there.
local function retarget()
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    for _, Gt in ipairs(gates) do
        local word = serverGates[Gt.n]
        local t = (on() and not lobby and word ~= nil and word[Gt.which] == true) and 1.0 or 0.0
        if t ~= Gt.target or Gt.adopted then
            Gt.target, Gt.adopted = t, false
            if near and registered then
                if Gt.pose ~= Gt.target then
                    if Gt.settle == 0 then
                        for _, d in ipairs(Gt.all) do handleOf(d, true) end
                        rideGate(Gt, false)
                    end
                    armAnim()
                end
            else
                Gt.pose, Gt.settle, Gt.settled, Gt.folded = t, 0, 0, false
            end
        end
    end
end

--- The server's word gone: every gate shut.
local function clearMatch()
    serverGates, gateMatch = {}, nil
    retarget()
end

-- --------------------------------------------------------- the server's word ---

--- Each lane's code (BR.DcGateSolve.code) taken; anything that is not one is
--- a lane at rest.
local function take(list)
    serverGates = {}
    if type(list) ~= 'table' then return end
    for n in pairs(laneByN) do
        local w = GS.decode(list[n])
        if w then serverGates[n] = w end
    end
end

--- A snapshot's poses ([n] = { outer, inner }) taken over where this client's
--- is more than POSE_JUMP off.
local function adopt(poses)
    if type(poses) ~= 'table' then return end
    for _, Gt in ipairs(gates) do
        local p = poses[Gt.n]
        local v = type(p) == 'table' and p[Gt.which == 'outer' and 1 or 2] or nil
        if type(v) == 'number' and v >= 0.0 and v <= 1.0 and math.abs(v - Gt.pose) > POSE_JUMP then
            Gt.pose, Gt.adopted, Gt.settle, Gt.settled, Gt.folded = v, true, 0, 0, false
            for _, d in ipairs(Gt.all) do d.applied = nil end
        end
    end
end

RegisterNetEvent(BR.Net.DCGATE_STATE)
AddEventHandler(BR.Net.DCGATE_STATE, function(d)
    if type(d) ~= 'table' or d.matchId == nil or not on() then return end
    gateMatch = d.matchId
    take(d.lanes)
    retarget()
end)

-- A LATE JOINER, A RESTART: the snapshot's word replaces this one, and each
-- gate's pose in it is taken over. None in it (no match, Season 1), and every
-- gate is shut here.
RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    local v = type(payload) == 'table' and payload.dcgate or nil
    if type(v) ~= 'table' or v.matchId == nil or not on() then
        if gateMatch ~= nil or next(serverGates) ~= nil then clearMatch() end
        return
    end
    gateMatch = v.matchId
    take(v.lanes)
    adopt(v.poses)
    retarget()
end)

-- ----------------------------------------------------------- the prompt ---

local function setPrompt(idx)
    if idx == atReader then return end
    local was = atReader
    atReader = idx
    if idx ~= nil and was == nil then
        BR.Notify(PROMPT_TEXT, 'info', { key = PROMPT_KEY, sticky = true, cue = false })
    elseif idx == nil then
        BR.NotifyClear(PROMPT_KEY)
    end
end

--- The reader this player stands at, of a lane whose cycle is not running, in
--- a match under way (the bus still flying, or playing: a player who jumped
--- early is on the ground before the match goes live), standing, and not in
--- a trap (no reader in the trap: the owner's); nil otherwise.
local function readerHere()
    if not on() then return nil end
    local S = BR.State
    local ms = S and S.match and S.match.state
    if not ((ms == BR.MatchState.BUS or ms == BR.MatchState.PLAYING) and S.me
            and S.me.state == BR.PlayerState.ALIVE) then
        return nil
    end
    if BR.Keys and BR.Keys.uiScreen ~= nil then return nil end
    local p = GetEntityCoords(PlayerPedId())
    local i, r = GS.readerAt(parts().readers, p.x, p.y, p.z, cfg().readerM or 3.0, cfg().readerZM or 2.5)
    if not i then return nil end
    local w = serverGates[r.lane]
    if w and w.busy then return nil end
    if GS.inTrap(zones(), p.x, p.y, p.z, cfg().lane) then return nil end
    return i
end

local promptLoop = nil

local function armPrompt(want)
    if want and promptLoop == nil then
        promptLoop = BR.Loop.register(BR.Loop.TICK, 'dcgate.prompt', function()
            setPrompt(readerHere())
        end)
    elseif not want and promptLoop ~= nil then
        BR.Loop.unregister(promptLoop)
        promptLoop = nil
        setPrompt(nil)
    end
end

-- THE PRESS ASKS, for the reader the prompt is up for and no other; the
-- server opens the gate that reader stands beyond, or says nothing. Not while
-- one of our screens holds the keyboard, and not again within client.askMs
-- (longer than the server's use.minIntervalMs, so network jitter never drops a
-- retry).
if BR.Keys and BR.Keys.on then
    BR.Keys.on('interact', function(pressed)
        if not pressed or atReader == nil then return end
        if BR.Keys.uiScreen ~= nil then return end
        local now = GetGameTimer()
        if lastAsk ~= nil and now - lastAsk < (C().askMs or 1000) then return end
        lastAsk = now
        TriggerServerEvent(BR.Net.DCGATE_USE, { reader = atReader })
    end)
end

-- ------------------------------------------------------- the SLOW pass ---

--- Where this client's view is: the storm's viewpoint (a spectator's shot),
--- or the player.
local function viewpoint()
    if BR.Storm and BR.Storm.viewpoint then
        local p = BR.Storm.viewpoint()
        if p then return p end
    end
    return GetEntityCoords(PlayerPedId())
end

--- NEAR THE GATE, ONCE A SECOND: the registration still standing (a pack that
--- stopped took it), and every gate at rest posed again where a door's physics
--- streamed in, a follower's copy went, an attached follower is off its lead's
--- turn (astray), or a lead or arm reads back off its pose -- its leads and
--- arm driven, its followers ridden (found as needed) and settled, or let go.
--- A part read back off twice running has its door registered again first.
local function keepPosed()
    for _, L in ipairs(lanes) do
        if L.leads[1] and not isTrue(IsDoorRegisteredWithSystem(L.leads[1].hash)) then
            registerDoors()
            break
        end
    end
    for _, Gt in ipairs(gates) do
        if not moving(Gt) then
            local stale, off = false, nil
            for _, d in ipairs(Gt.all) do
                if isTrue(DoorSystemGetIsPhysicsLoaded(d.hash)) then
                    if d.applied ~= Gt.pose then
                        stale = true
                    elseif d.kind == 'follow' then
                        if d.attached and (not handleOf(d, false) or (Gt.pose > 0 and astray(d))) then stale = true end
                    elseif offPose(d) then
                        off = off or {}
                        off[#off + 1] = d
                    else
                        d.off = 0
                    end
                else
                    d.applied, d.off = nil, 0
                end
            end
            if off then
                for _, d in ipairs(off) do
                    d.off = d.off + 1
                    if d.off == 2 then register(d) end
                end
                stale = true
            end
            if stale then
                driveGate(Gt, true)
                if Gt.pose > 0 then
                    rideGate(Gt, true)
                    Gt.settle, Gt.settled = SETTLE_FRAMES, 0
                    armAnim()
                else
                    releaseGate(Gt)
                end
                for _, d in ipairs(Gt.all) do
                    local ok = true
                    if d.kind == 'follow' and Gt.pose > 0 then ok = d.attached end
                    if driveOf(d.kind) == 'rotate' and d.kind ~= 'follow' then ok = d.handle ~= nil end
                    d.applied = ok and Gt.pose or nil
                end
            end
        end
    end
end

--- Away from the gate: nothing is driven, and everything is posed again on
--- the way back.
local function leaveNear()
    for _, Gt in ipairs(gates) do
        Gt.pose, Gt.settle, Gt.settled, Gt.folded, Gt.adopted = Gt.target, 0, 0, false, false
        for _, d in ipairs(Gt.all) do d.applied = nil end
    end
    if animLoop ~= nil then
        BR.Loop.unregister(animLoop)
        animLoop, lastFrameAt = nil, nil
    end
end

BR.Loop.register(BR.Loop.SLOW, 'dcgate.watch', function()
    local was = seasonOn
    refreshSeason()
    if was and not seasonOn then clearMatch() end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby and (gateMatch ~= nil or next(serverGates) ~= nil) then clearMatch() end
    if not packPresent() then return end
    if not registered then registerDoors() end
    local nowNear, promptNear = false, false
    if not lobby then
        local p = viewpoint()
        nowNear = GS.near(parts(), p.x, p.y, C().nearM or 200.0)
        promptNear = on() and GS.near(parts(), p.x, p.y, C().promptM or 15.0)
    end
    if near and not nowNear then leaveNear() end
    near = nowNear
    if near then keepPosed() end
    armPrompt(promptNear)
end)

-- The season moved: off Season 2, every gate shut and no prompt.
if BR.Season and BR.Season.onChange then
    BR.Season.onChange(function()
        refreshSeason()
        if not on() then
            clearMatch()
            armPrompt(false)
        end
    end)
end

-- At load: the doors locked, if the pack is here (the pack locked them at its
-- own start; this takes that over).
if packPresent() then registerDoors() end

-- br_core stopping: the prompt down, and every part handed back to the door
-- system -- every follower let go, anything frozen put where it was placed and
-- unfrozen, and every part shut and locked: a gate left locked is the map's
-- resting state, and the registrations are this file's again when it starts.
AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    if atReader ~= nil then BR.NotifyClear(PROMPT_KEY) end
    atReader = nil
    if not registered then return end
    for _, Gt in ipairs(gates) do
        Gt.pose, Gt.target, Gt.settle, Gt.settled, Gt.folded = 0.0, 0.0, 0, 0, false
    end
    for _, d in ipairs(doors) do letGo(d) end
end)

-- ------------------------------------------------------------ the suites ---

--- What this client holds, for the suites and `brgate`.
--- @return table
function G.counts()
    local out = { near = near, registered = registered, present = present, reader = atReader,
                  match = gateMatch, lanes = {}, attached = 0, frozen = 0, handles = 0,
                  folding = animLoop ~= nil, prompting = promptLoop ~= nil }
    for _, L in ipairs(lanes) do
        local w = serverGates[L.n]
        local row = { busy = w ~= nil and w.busy == true }
        for _, which in ipairs(GS.GATES) do
            local Gt = L.gates[which]
            row[which] = { pose = Gt.pose, target = Gt.target, open = w ~= nil and w[which] == true }
        end
        out.lanes[L.n] = row
    end
    for _, d in ipairs(doors) do
        if d.attached then out.attached = out.attached + 1 end
        if d.frozen then out.frozen = out.frozen + 1 end
        if d.handle then out.handles = out.handles + 1 end
    end
    return out
end

-- -------------------------------------------------------------- the dev ---
--
--   brgate [list]                     the server's lanes (`brgatesv list`) and
--                                     this client's gates, poses and drives
--   brgate near                       the lane of the nearest reader: each part's
--                                     door state, physics, open ratio, handle,
--                                     frozen, turn and attachment
--   brgate open <lane|all> [in|out]   through the server (`brgatesv`)
--   brgate close <lane|all>
--   brgate drive <lead|arm> <ratio|rotate>   how this client moves them

RegisterNetEvent(BR.Net.DCGATE_DEV)
AddEventHandler(BR.Net.DCGATE_DEV, function(text)
    print('[br_core] brgate: ' .. tostring(text))
end)

local function gateWords(L)
    local w = serverGates[L.n]
    return ('%s, outer %s %.2f, inner %s %.2f'):format(w and w.busy and 'cycle running' or 'idle',
        w and w.outer and 'open' or 'shut', L.gates.outer.pose, w and w.inner and 'open' or 'shut', L.gates.inner.pose)
end

local function devList()
    local k = G.counts()
    local out = {}
    for _, L in ipairs(lanes) do
        out[#out + 1] = ('lane %d %s'):format(L.n, gateWords(L))
    end
    print(('[br_core] brgate: this client: %s; near %s, pack %s, %d handles, %d attached, %d frozen; drive lead %s, arm %s')
        :format(table.concat(out, '; '), tostring(k.near), tostring(k.present), k.handles, k.attached, k.frozen,
            driveOf('lead'), driveOf('arm')))
end

local function devNear()
    local p = GetEntityCoords(PlayerPedId())
    local best, bestD = nil, nil
    for i, r in ipairs(parts().readers or {}) do
        local d = math.sqrt((p.x - r.x) ^ 2 + (p.y - r.y) ^ 2)
        if bestD == nil or d < bestD then best, bestD = i, d end
    end
    if not best then
        print('[br_core] brgate: no readers (dcgate_parts.lua)')
        return
    end
    local r = parts().readers[best]
    local L = laneByN[r.lane]
    print(('[br_core] brgate: %s %.1f m away, lane %d %s (targets %.0f, %.0f), pack %s, registered %s')
        :format(r.id, bestD, r.lane, gateWords(L), L.gates.outer.target, L.gates.inner.target,
            tostring(present), tostring(registered)))
    for _, which in ipairs(GS.GATES) do
        for _, d in ipairs(L.gates[which].all) do
            local h = handleOf(d, true)
            local turn = ''
            if h then
                local rot = GetEntityRotation(h, 2)
                turn = (', rotation %.1f %.1f %.1f (placed heading %.1f, turned %.1f)'):format(rot.x, rot.y, rot.z,
                    d.row.h, GS.wrap180(GetEntityHeading(h) - d.row.h))
            end
            print(('  %s: state %s, physics %s, ratio %.3f, handle %s, frozen %s%s%s'):format(d.row.id,
                tostring(DoorSystemGetDoorState(d.hash)), tostring(isTrue(DoorSystemGetIsPhysicsLoaded(d.hash))),
                DoorSystemGetOpenRatio(d.hash) or 0.0, tostring(h), tostring(d.frozen == true), turn,
                d.kind == 'follow' and (', attached ' .. tostring(h ~= nil and isTrue(IsEntityAttached(h)))) or ''))
        end
    end
end

--- Switch how this client moves one kind of part: every part of that kind
--- handed back to the door system first (put where it was placed, unfrozen,
--- locked shut), then posed again the new way on the next pass.
local function devDrive(kind, mode)
    if (kind ~= 'lead' and kind ~= 'arm') or (mode ~= 'ratio' and mode ~= 'rotate') then
        print('[br_core] brgate: brgate drive <lead|arm> <ratio|rotate>')
        return
    end
    for _, d in ipairs(doors) do
        if d.kind == kind then
            letGo(d)
            d.off = 0
        end
        d.applied = nil
    end
    local c = C()
    c.drive = c.drive or {}
    c.drive[kind] = mode
    print(('[br_core] brgate: %s moved by %s on this client (until it restarts)'):format(kind, mode))
end

RegisterCommand('brgate', function(_, args)
    args = args or {}
    local verb = args[1] and args[1]:lower() or 'list'
    if verb == 'list' then
        devList()
        ExecuteCommand('brgatesv list')
    elseif verb == 'near' then
        devNear()
    elseif verb == 'open' or verb == 'close' then
        ExecuteCommand(('brgatesv %s %s%s'):format(verb, tostring(args[2] or ''),
            args[3] and (' ' .. tostring(args[3])) or ''))
    elseif verb == 'drive' then
        devDrive(args[2] and args[2]:lower() or '', args[3] and args[3]:lower() or '')
    else
        print('[br_core] brgate: brgate [list] | near | open <lane|all> [in|out] | close <lane|all> '
            .. '| drive <lead|arm> <ratio|rotate>')
    end
end)

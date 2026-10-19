-- The data center's main gate (#420), Season 2, client half: THE PROMPT AT A
-- READER, THE ASK, AND THE GATE AS THIS CLIENT SHOWS IT. It decides nothing;
-- every lane is server/dcgate.lua's.
--
--   the doors    the 24 bi-fold leaves and 3 crash arms registered with the
--                door system and locked shut -- in every season, as the
--                br_datacenter pack kept them -- and each posed as its physics
--                streams in
--   the prompt   at a lane's reader, "Press E to open the gate" (the owner's
--                words, the E the player's own interact key drawn as a key)
--   the ask      interact at a reader: DCGATE_USE, and nothing else
--   the fold     each lane the server says is open, folded open: the leads
--                turn about their post hinges, the followers ride the leads'
--                knuckles and counter-rotate, the arm rises; and back
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
-- folds flat; it is unlocked while attached and detached and locked again once
-- its lead is shut. The arm rises with the lane. A lane's pose is one number, 0
-- shut to 1 open (BR.DcGateSolve), moved a whole fold per foldMs; a fold turned
-- back halfway runs back from where it is.
--
-- ═══ IDEMPOTENT, WHEREVER THE GATE IS WHEN IT STREAMS IN ═══
--
-- What a part should show is a function of its lane's pose and nothing else.
-- A door whose physics streams in (DoorSystemGetIsPhysicsLoaded) is posed to it
-- on the SLOW pass -- a lane open since before this client came near arrives
-- open, its followers attached as they are found -- and a pass that finds every
-- part already posed calls nothing but the reads.
--
-- ═══ WHAT IT COSTS ═══
--
-- Nothing per frame, anywhere. Away from the gate the SLOW pass asks one
-- distance (none in the lobby, none without the map pack); within client.nearM
-- it reads each door's physics once a second; within client.promptM a TICK
-- callback reads this player's position for the prompt; and a FRAME callback
-- exists only while a lane near this client is folding.

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
-- reader of a shut lane, taken down the moment they are not, and silent: it
-- comes up every time anybody walks to a reader.
local PROMPT_KEY = 'dcgate.reader'
local PROMPT_TEXT = 'Press ' .. BR.KeyToken('brinteract') .. ' to open the gate'
G.PROMPT_TEXT = PROMPT_TEXT

--- Frames a lane's followers are ridden after its leads stop -- a door the
--- system moves this frame may show it next -- before a shut lane's
--- followers are let go.
local SETTLE_FRAMES = 3

-- ------------------------------------------------------------ the state ---

--- The lanes the server says are open in this match: [n] = true. Empty is
--- every lane shut, which is how every match starts: the server says nothing
--- until a lane opens, and the lobby empties it.
local serverOpen = {}
--- The match the last word was for (nil: none), for `brgate`.
local gateMatch = nil

--- Every door: { kind = 'lead'|'follow'|'arm', row, lane, name, hash, model,
--- handle?, applied?, attached?, frozen? }.
local doors = {}
--- The lanes, in order: { n, row, pose, target, settle, folded, leads, follows,
--- arm, all }.
local lanes = {}
--- [n] = the lane.
local laneByN = {}

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

local function build()
    doors, lanes, laneByN = {}, {}, {}
    for _, row in ipairs(parts().lanes or {}) do
        local L = { n = row.lane, row = row, pose = 0.0, target = 0.0, settle = 0, folded = false,
                    leads = {}, follows = {}, all = {} }
        local function add(kind, r)
            local d = { kind = kind, row = r, lane = L, name = GS.doorName(r.id),
                        hash = GetHashKey(GS.doorName(r.id)), model = GetHashKey(r.model) }
            doors[#doors + 1] = d
            L.all[#L.all + 1] = d
            return d
        end
        for _, r in ipairs(row.leads or {}) do L.leads[#L.leads + 1] = add('lead', r) end
        for _, r in ipairs(row.follows or {}) do L.follows[#L.follows + 1] = add('follow', r) end
        if row.arm then L.arm = add('arm', row.arm) end
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
end

--- Every part registered with the door system on this client and locked
--- shut. Local (no door events are sent: the server's word is DCGATE_STATE),
--- under the pack's own names, so a pack that still registers a part and this
--- file hold one door between them, not two. A name already registered is
--- taken back and registered again, as the pack does.
local function registerDoors()
    for _, d in ipairs(doors) do
        if isTrue(IsDoorRegisteredWithSystem(d.hash)) then RemoveDoorFromSystem(d.hash) end
        AddDoorToSystem(d.hash, d.model, d.row.x, d.row.y, d.row.z, false, false, true)
        shut(d)
        d.applied, d.attached, d.frozen = nil, false, false
    end
    registered = true
end

--- This part's handle: the cached one while it exists, else (when `find`)
--- the map object of its model at its placed origin. Nil when there is none.
local function handleOf(d, find)
    local h = d.handle
    if h and isTrue(DoesEntityExist(h)) then return h end
    d.handle, d.attached, d.frozen = nil, false, false
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

--- Bring a lead or an arm to its lane's pose. True when it is there.
local function drivePart(d, find)
    local L = d.lane
    local deg
    if d.kind == 'lead' then
        deg = GS.leadTurn(d.row.sense, L.pose, cfg().foldDeg)
    else
        deg = GS.armRaise(L.pose, cfg().armRaiseDeg)
    end
    if driveOf(d.kind) == 'rotate' then
        local h = handleOf(d, find)
        if not h then return false end
        if L.pose <= 0 then
            SetEntityRotation(h, 0.0, 0.0, d.row.h, 2, true)
            FreezeEntityPosition(h, false)
            d.frozen = false
            shut(d)
            return true
        end
        if not d.frozen then
            DoorSystemSetDoorState(d.hash, 0, false, true)
            FreezeEntityPosition(h, true)
            d.frozen = true
        end
        if d.kind == 'lead' then
            SetEntityRotation(h, 0.0, 0.0, d.row.h + deg, 2, true)
        else
            local rx, ry, rz = GS.armRotation(d.row, deg)
            SetEntityRotation(h, rx, ry, rz, 2, true)
        end
        return true
    end
    if L.pose <= 0 then
        shut(d)
        return true
    end
    local which = d.kind == 'lead' and 'lead' or 'arm'
    local r = GS.ratio(deg, (C().ratioDeg or {})[which], (C().ratioSign or {})[which])
    DoorSystemSetOpenRatio(d.hash, r, false, true)
    DoorSystemSetDoorState(d.hash, 1, false, true)
    return true
end

--- A follower on its lead's knuckle, turned -2 times the lead's turn as the
--- lead stands NOW (BR.DcGateSolve.followerYaw). Unlocked once attached, so
--- the door system does not hold it shut under its lead. True when attached.
local function ride(f, find)
    local lead = f.lane.leads[f.row.lead]
    local lh = lead and handleOf(lead, find)
    local h = lh and handleOf(f, find)
    if not h then return false end
    local yaw = GS.followerYaw(GetEntityHeading(lh), lead.row.h, f.row.turn)
    AttachEntityToEntity(h, lh, 0, f.row.ox, f.row.oy, f.row.oz, 0.0, 0.0, yaw,
        false, false, true, false, 2, true)
    if not f.attached then
        f.attached = true
        DoorSystemSetDoorState(f.hash, 0, false, true)
    end
    return true
end

--- A follower let go of its shut lead and locked shut in its own place.
local function release(f)
    if f.attached and f.handle and isTrue(DoesEntityExist(f.handle)) then
        DetachEntity(f.handle, false, true)
    end
    f.attached = false
    shut(f)
end

--- The lane's leads and arm to its pose.
local function driveLane(L, find)
    for _, d in ipairs(L.leads) do drivePart(d, find) end
    if L.arm then drivePart(L.arm, find) end
end

local function rideLane(L, find)
    for _, f in ipairs(L.follows) do ride(f, find) end
end

local function releaseLane(L)
    for _, f in ipairs(L.follows) do release(f) end
end

-- ------------------------------------------------------------- the fold ---

local animLoop = nil
local lastFrameAt = nil
local animate

local function moving(L)
    return L.pose ~= L.target or L.settle > 0
end

local function armAnim()
    if animLoop == nil then
        lastFrameAt = GetGameTimer()
        animLoop = BR.Loop.register(BR.Loop.FRAME, 'dcgate.fold', animate)
    end
end

--- THE FOLD, A FRAME AT A TIME, ONLY WHILE A LANE NEAR THIS CLIENT MOVES. A
--- lane's pose steps toward its target and every part follows; once there,
--- its followers are ridden SETTLE_FRAMES more (the leads' last turn) and a
--- shut lane's let go. A fold that finished leaves its doors to the SLOW pass
--- (applied cleared), which reads their physics and finds them where they are;
--- the settle after one of the SLOW pass's own poses does not, or the two
--- would hand the lane back and forth for ever.
animate = function()
    local now = GetGameTimer()
    local dt = lastFrameAt and (now - lastFrameAt) or 0
    lastFrameAt = now
    local busy = false
    for _, L in ipairs(lanes) do
        if L.pose ~= L.target then
            L.pose = GS.step(L.pose, L.target, dt, cfg().foldMs or 4000)
            driveLane(L, false)
            rideLane(L, false)
            if L.pose == L.target then L.settle, L.folded = SETTLE_FRAMES, true end
            busy = true
        elseif L.settle > 0 then
            L.settle = L.settle - 1
            rideLane(L, false)
            if L.settle == 0 then
                if L.pose <= 0 then releaseLane(L) end
                if L.folded then
                    L.folded = false
                    for _, d in ipairs(L.all) do d.applied = nil end
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

--- Every lane's target from the server's word, the season and the lobby.
--- Near the gate a lane that must move folds (its handles found first, so the
--- followers ride from the first frame); away from it the pose is simply the
--- target, and the parts are posed as they stream in.
local function retarget()
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    for _, L in ipairs(lanes) do
        local t = (on() and not lobby and serverOpen[L.n] == true) and 1.0 or 0.0
        if t ~= L.target then
            L.target = t
            if near and registered then
                if L.pose <= 0 and L.settle == 0 then
                    for _, d in ipairs(L.all) do handleOf(d, true) end
                    rideLane(L, false)
                end
                armAnim()
            else
                L.pose, L.settle, L.folded = t, 0, false
            end
        end
    end
end

--- The server's word gone: every lane shut.
local function clearMatch()
    serverOpen, gateMatch = {}, nil
    retarget()
end

-- --------------------------------------------------------- the server's word ---

local function takeOpen(list)
    serverOpen = {}
    if type(list) ~= 'table' then return end
    for n in pairs(laneByN) do
        if list[n] == true then serverOpen[n] = true end
    end
end

RegisterNetEvent(BR.Net.DCGATE_STATE)
AddEventHandler(BR.Net.DCGATE_STATE, function(d)
    if type(d) ~= 'table' or d.matchId == nil or not on() then return end
    gateMatch = d.matchId
    takeOpen(d.open)
    retarget()
end)

-- A LATE JOINER, A RESTART: the snapshot's word replaces this one. None in it
-- (no match, Season 1), and every lane is shut here.
RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    local v = type(payload) == 'table' and payload.dcgate or nil
    if type(v) ~= 'table' or v.matchId == nil or not on() then
        if gateMatch ~= nil or next(serverOpen) ~= nil then clearMatch() end
        return
    end
    gateMatch = v.matchId
    takeOpen(v.open)
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

--- The reader this player stands at, of a lane not open, in a match being
--- played, standing; nil otherwise.
local function readerHere()
    if not on() then return nil end
    local S = BR.State
    if not (S and S.match and S.match.state == BR.MatchState.PLAYING and S.me
            and S.me.state == BR.PlayerState.ALIVE) then
        return nil
    end
    if BR.Keys and BR.Keys.uiScreen ~= nil then return nil end
    local p = GetEntityCoords(PlayerPedId())
    local i, r = GS.readerAt(parts().readers, p.x, p.y, p.z, cfg().readerM or 3.0, cfg().readerZM or 2.5)
    if not i or serverOpen[r.lane] then return nil end
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
-- server opens the lane, or says nothing. Not while one of our screens holds
-- the keyboard, and not again within use.minIntervalMs.
if BR.Keys and BR.Keys.on then
    BR.Keys.on('interact', function(pressed)
        if not pressed or atReader == nil then return end
        if BR.Keys.uiScreen ~= nil then return end
        local now = GetGameTimer()
        if lastAsk ~= nil and now - lastAsk < ((cfg().use or {}).minIntervalMs or 1000) then return end
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
--- stopped took it), and every lane that is still posed again where a door's
--- physics streamed in or a follower's copy went -- its leads and arm driven,
--- its followers ridden (found as needed) or let go.
local function keepPosed()
    for _, L in ipairs(lanes) do
        if L.leads[1] and not isTrue(IsDoorRegisteredWithSystem(L.leads[1].hash)) then
            registerDoors()
            break
        end
    end
    for _, L in ipairs(lanes) do
        if not moving(L) then
            local stale = false
            for _, d in ipairs(L.all) do
                if isTrue(DoorSystemGetIsPhysicsLoaded(d.hash)) then
                    if d.applied ~= L.pose then stale = true end
                    if d.kind == 'follow' and d.attached and not handleOf(d, false) then stale = true end
                else
                    d.applied = nil
                end
            end
            if stale then
                driveLane(L, true)
                if L.pose > 0 then
                    rideLane(L, true)
                    L.settle = SETTLE_FRAMES
                    armAnim()
                else
                    releaseLane(L)
                end
                for _, d in ipairs(L.all) do
                    local ok = true
                    if d.kind == 'follow' and L.pose > 0 then ok = d.attached end
                    if driveOf(d.kind) == 'rotate' and d.kind ~= 'follow' then ok = d.handle ~= nil end
                    d.applied = ok and L.pose or nil
                end
            end
        end
    end
end

--- Away from the gate: nothing is driven, and everything is posed again on
--- the way back.
local function leaveNear()
    for _, L in ipairs(lanes) do
        L.pose, L.settle, L.folded = L.target, 0, false
        for _, d in ipairs(L.all) do d.applied = nil end
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
    if lobby and (gateMatch ~= nil or next(serverOpen) ~= nil) then clearMatch() end
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

-- The season moved: off Season 2, every lane shut and no prompt.
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

-- br_core stopping: the prompt down, every follower let go, and every part
-- shut and locked where it was placed -- a gate left locked is the map's
-- resting state, and the registrations are this file's again when it starts.
AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    if atReader ~= nil then BR.NotifyClear(PROMPT_KEY) end
    atReader = nil
    if not registered then return end
    for _, L in ipairs(lanes) do
        L.pose, L.target, L.settle, L.folded = 0.0, 0.0, 0, false
        for _, d in ipairs(L.all) do
            if d.kind == 'follow' then
                release(d)
            elseif d.frozen and d.handle and isTrue(DoesEntityExist(d.handle)) then
                SetEntityRotation(d.handle, 0.0, 0.0, d.row.h, 2, true)
                FreezeEntityPosition(d.handle, false)
                d.frozen = false
                shut(d)
            else
                shut(d)
            end
        end
    end
end)

-- ------------------------------------------------------------ the suites ---

--- What this client holds, for the suites and `brgate`.
--- @return table
function G.counts()
    local out = { near = near, registered = registered, present = present, reader = atReader,
                  match = gateMatch, lanes = {}, attached = 0, frozen = 0, handles = 0,
                  folding = animLoop ~= nil, prompting = promptLoop ~= nil }
    for _, L in ipairs(lanes) do
        out.lanes[L.n] = { pose = L.pose, target = L.target, open = serverOpen[L.n] == true }
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
--                                     this client's poses and drives
--   brgate near                       the lane of the nearest reader: each part's
--                                     door state, physics, open ratio, handle,
--                                     turn and attachment -- the tool for
--                                     docs/dcgate.md's engine questions
--   brgate open|close <lane|all>      through the server (`brgatesv`)
--   brgate drive <lead|arm> <ratio|rotate>   how this client moves them

RegisterNetEvent(BR.Net.DCGATE_DEV)
AddEventHandler(BR.Net.DCGATE_DEV, function(text)
    print('[br_core] brgate: ' .. tostring(text))
end)

local function devList()
    local k = G.counts()
    local out = {}
    for _, L in ipairs(lanes) do
        out[#out + 1] = ('lane %d %s, pose %.2f'):format(L.n, serverOpen[L.n] and 'open' or 'shut', L.pose)
    end
    print(('[br_core] brgate: this client: %s; near %s, pack %s, %d handles, %d attached; drive lead %s, arm %s')
        :format(table.concat(out, '; '), tostring(k.near), tostring(k.present), k.handles, k.attached,
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
    print(('[br_core] brgate: %s %.1f m away, lane %d %s here (pose %.2f -> %.2f), pack %s, registered %s')
        :format(r.id, bestD, r.lane, serverOpen[r.lane] and 'open' or 'shut', L.pose, L.target,
            tostring(present), tostring(registered)))
    for _, d in ipairs(L.all) do
        local h = handleOf(d, true)
        local turn = ''
        if h then
            local rot = GetEntityRotation(h, 2)
            turn = (', rotation %.1f %.1f %.1f (placed heading %.1f, turned %.1f)'):format(rot.x, rot.y, rot.z,
                d.row.h, GS.wrap180(GetEntityHeading(h) - d.row.h))
        end
        print(('  %s: state %s, physics %s, ratio %.3f, handle %s%s%s'):format(d.row.id,
            tostring(DoorSystemGetDoorState(d.hash)), tostring(isTrue(DoorSystemGetIsPhysicsLoaded(d.hash))),
            DoorSystemGetOpenRatio(d.hash) or 0.0, tostring(h), turn,
            d.kind == 'follow' and (', attached ' .. tostring(h ~= nil and isTrue(IsEntityAttached(h)))) or ''))
    end
end

--- Switch how this client moves one kind of part: every lane's parts of that
--- kind brought shut the old way first, then posed again the new way.
local function devDrive(kind, mode)
    if (kind ~= 'lead' and kind ~= 'arm') or (mode ~= 'ratio' and mode ~= 'rotate') then
        print('[br_core] brgate: brgate drive <lead|arm> <ratio|rotate>')
        return
    end
    for _, d in ipairs(doors) do
        if d.kind == kind then
            if d.frozen and d.handle and isTrue(DoesEntityExist(d.handle)) then
                SetEntityRotation(d.handle, 0.0, 0.0, d.row.h, 2, true)
                FreezeEntityPosition(d.handle, false)
            end
            d.frozen = false
            shut(d)
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
        ExecuteCommand(('brgatesv %s %s'):format(verb, tostring(args[2] or '')))
    elseif verb == 'drive' then
        devDrive(args[2] and args[2]:lower() or '', args[3] and args[3]:lower() or '')
    else
        print('[br_core] brgate: brgate [list] | near | open <lane|all> | close <lane|all> '
            .. '| drive <lead|arm> <ratio|rotate>')
    end
end)

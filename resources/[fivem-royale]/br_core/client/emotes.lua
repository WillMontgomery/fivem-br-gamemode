-- Emotes, this side of the wire: the server's dance records, this player's own
-- playback and what cancels it, and the music every record is owed at this
-- distance (#215).
--
-- Owner, 2026-10-02 (#215, "Scope v2"): one PR with the complete SOLO system.
-- "Anywhere except the lobby, on foot only." A dance plays until its time is up
-- or the player moves, aims, gets in a vehicle, goes down or dies -- "damage
-- does not cancel". Emotes are a Season 2 feature (#388): every entry point
-- below asks BR.Season.has('emotes'), the one gate (br_lib/config/seasons.lua),
-- and tools/check_emote_gate.lua fails the build when one does not.
--
-- ═══ THE CLIENT ASKS AND THE SERVER PUBLISHES ═══
--
-- Picking a dance sends EMOTE_PLAY { id } and nothing else. The server checks
-- ownership, the wheel, the state, the seat and the position, and answers with
-- an EMOTE_RECORD to everybody in earshot -- this player included. THE DANCE
-- STARTS WHEN ITS OWN RECORD ARRIVES, not on the press, so what the dancer sees
-- is what everybody near them sees. A record's end is COMPUTED (tStart +
-- durationMs) and never messaged; an early stop re-sends the same record with
-- `tEnd` on it, and that replaces the one held for the dancer.
--
-- ═══ ONE LEVEL-BASED PASS, THE USE EMOTE'S SHAPE ═══
--
-- client/inventory.lua's `inv.emote` is the pattern: a TICK pass asks "should
-- this ped be dancing right now" and makes the ped agree. Nothing starts or
-- stops on an event, so every ending -- the record's natural end, a tEnd, a
-- cancel, the gate closing, a resource stop -- reaches the clip the same way.
-- NEVER ClearPedTasks: StopAnimTask names our clip and leaves a crawl or a
-- vault alone (inventory.lua says why at stopEmote).
--
-- ═══ THE MUSIC IS THE PAGE'S; THE DISTANCE IS OURS ═══
--
-- Every client, dancing or not, sends the page { tracks } about ten times a
-- second while any dance is audible: which file, how far into it, and a 0..1
-- distance gain. A spectator listens from what they are watching, not from the
-- body they left (BR.Spectate.watchPoint). EVERY STARTER TRACK FILE IS ABSENT
-- TODAY, and that is the shipped path: the page marks a missing file once and
-- the dance plays in silence, still ending at durationMs.

BR = BR or {}
BR.Emotes = BR.Emotes or {}

--- Movement input past this is "the player is moving" (a stick at rest reads a
--- little off zero; a key reads 1.0).
local MOVE_DEAD = 0.25
--- Faster than this, in m/s, and a dance may not START. Not a cancel: some
--- clips carry root motion and the ped would cancel itself.
local SPEED_MAX = 1.0
--- How long a dictionary may take to stream before the dance goes without it.
--- Same number, same reason as inventory.lua's EMOTE_LOAD_MS.
local LOAD_MS = 2000
--- How often a clip the engine dropped is put back. Same as EMOTE_RETASK_MS.
local RETASK_MS = 1000

--- The wheel has eight segments, and that is the library's number, not a
--- config value: ScaleformUI's RadialMenu is built with exactly eight.
local SEGMENTS = 8

--- [src] = the last record the server sent for that player, plus `recvAt`.
local records = {}
--- The eight wheel slots as the server last stated them; '' is empty.
local wheel = { '', '', '', '', '', '', '', '' }
--- [id] = true for every dance this player owns, mirrored for `bremote`.
local owned = {}
--- What this file has put on the ped. `key` names the dance it belongs to
--- ('rec:<tStart>' or 'aud:<dict><clip>'), so a different dance is a stop and
--- then a start rather than a re-task.
local anim = { dict = nil, clip = nil, ped = 0, taskedAt = 0, askedAt = nil, key = nil }
--- tStart of the own record an EMOTE_STOP has already been sent for. A stop
--- goes once; until the tEnd comes back, the record is treated as over.
local stopSent = nil
--- `bremote <dict> <clip>`: a local-only clip with no record and no music.
local audition = nil
--- Whether the page was last sent a non-empty track list, so the final empty
--- one goes exactly once.
local audioLive = false
--- The gate's answer on the previous SLOW pass; nil before the first.
local lastOn = nil

-- ------------------------------------------------------------------ clock ---

--- Milliseconds into a record, never negative.
---
--- Synced, it is server time minus tStart, like every other record in the
--- game. Not synced yet, it is timed from the record's own send: `tSent` is the
--- server clock when it left, so tSent - tStart plus the time since it arrived
--- is accurate to one-way latency.
--- @param rec table
--- @return number
local function posOf(rec)
    local p
    if BR.Clock and BR.Clock.synced then
        p = BR.Clock.now() - rec.tStart
    else
        p = (rec.tSent or rec.tStart) - rec.tStart + GetGameTimer() - rec.recvAt
    end
    if p < 0 then p = 0 end
    return p
end

--- Where a record ends, in milliseconds after its start.
local function endMs(rec)
    return (rec.tEnd or (rec.tStart + rec.durationMs)) - rec.tStart
end

--- Is this record still playing?
local function live(rec)
    return posOf(rec) < endMs(rec)
end

--- This player's server id, or nil before it is known.
local function myId()
    return BR.State and BR.State.me and BR.State.me.src or nil
end

--- Why emotes are off, for a console line, given BR.Season.current(): the
--- season this client was told, or nil before the server's answer arrives
--- (#388: the season is unknown until then, and every gate is shut).
--- @param season integer|nil
--- @return string
local function offWhy(season)
    if season == nil then return "the server's season has not arrived yet" end
    return ('this box runs Season %d'):format(season)
end

-- --------------------------------------------------------------- the wire ---

-- THE WHEEL AND THE COLLECTION, MIRRORED. The server pushes MARKET_STATE on
-- every change; `emotes` is the eight slots, sent only while the gate is open.
-- br_ui keeps its own copy for the Market grid -- this one is the wheel's.
RegisterNetEvent(BR.Net.MARKET_STATE)
AddEventHandler(BR.Net.MARKET_STATE, function(state)
    if type(state) ~= 'table' then return end
    local e = type(state.emotes) == 'table' and state.emotes or {}
    for k = 1, SEGMENTS do
        wheel[k] = type(e[k]) == 'string' and e[k] or ''
    end
    owned = {}
    for _, id in ipairs(type(state.owned) == 'table' and state.owned or {}) do
        if type(id) == 'string' then owned[id] = true end
    end
end)

-- A DANCE, ANYBODY'S. Kept by src and replaced on arrival: a tEnd copy of a
-- record is the same record ending early, and a new tStart is a new dance.
RegisterNetEvent(BR.Net.EMOTE_RECORD)
AddEventHandler(BR.Net.EMOTE_RECORD, function(d)
    if not BR.Season.has('emotes') then return end
    if type(d) ~= 'table' or type(d.src) ~= 'number' then return end
    if BR.Emotes.row(d.id) == nil then return end
    for _, f in ipairs({ 'tStart', 'durationMs', 'x', 'y', 'z' }) do
        if type(d[f]) ~= 'number' then return end
    end
    if d.tSent ~= nil and type(d.tSent) ~= 'number' then return end
    if d.tEnd ~= nil and type(d.tEnd) ~= 'number' then return end
    records[d.src] = {
        src = d.src, id = d.id, tStart = d.tStart, durationMs = d.durationMs,
        x = d.x, y = d.y, z = d.z, tSent = d.tSent, tEnd = d.tEnd,
        recvAt = GetGameTimer(),
    }
end)

-- ---------------------------------------------------------------- reading ---

--- The eight wheel slots, '' for empty. A copy.
--- @return string[]
function BR.Emotes.wheel()
    local out = {}
    for k = 1, SEGMENTS do out[k] = wheel[k] end
    return out
end

--- Is the player asking to move? Read off the DISABLED value, so it still
--- answers on a frame something has disabled the control (the wheel does).
--- Movement on either axis, or jump.
--- @return boolean
function BR.Emotes.moving()
    return math.abs(tonumber(GetDisabledControlNormal(0, 30)) or 0) > MOVE_DEAD
        or math.abs(tonumber(GetDisabledControlNormal(0, 31)) or 0) > MOVE_DEAD
        or BR.NativeBool(IsDisabledControlPressed(0, 22))
end

--- Is the player using a weapon? Aiming, the aim button, firing, or melee.
--- Firing and melee are read as "aiming a weapon" -- an owner question on
--- #215, and the safe reading: a full-body dance that fires is a dance nobody
--- else can see the gun in.
--- @param ped integer
--- @return boolean
local function aiming(ped)
    return BR.NativeBool(IsPlayerFreeAiming(PlayerId()))
        or BR.NativeBool(IsDisabledControlPressed(0, 25))
        or BR.NativeBool(IsPedShooting(ped))
        or BR.NativeBool(IsPedInMeleeCombat(ped))
end

--- Why the body may not dance, from the state down: everything blocked() asks
--- after the gate and before the item and Interact. One reading for blocked()
--- and for the playback's cancels, so the two cannot disagree about what "on
--- foot" means.
--- @return string|nil
local function bodyWhy()
    local me = BR.State and BR.State.me
    if not (me and BR.Config.Emotes.states[me.state]) then return 'state' end
    local ped = PlayerPedId()
    if BR.NativeBool(IsEntityDead(ped)) or BR.NativeBool(IsPedFatallyInjured(ped)) then
        return 'dead'
    end
    -- "On foot only" (owner). BR.Inv.offFoot is the inventory's answer -- a
    -- seat, a door being opened, an attachment, a chute -- and the trying-to-
    -- enter read is asked again here so a dance never starts on the way in.
    if (BR.Inv and BR.Inv.offFoot and BR.Inv.offFoot(ped))
       or (tonumber(GetVehiclePedIsTryingToEnter(ped)) or 0) ~= 0 then
        return 'vehicle'
    end
    if BR.NativeBool(IsPedSwimming(ped)) or BR.NativeBool(IsPedSwimmingUnderWater(ped)) then
        return 'swimming'
    end
    if BR.NativeBool(IsPedFalling(ped)) or BR.NativeBool(IsPedInParachuteFreeFall(ped)) then
        return 'falling'
    end
    if BR.NativeBool(IsPedClimbing(ped)) or BR.NativeBool(IsPedVaulting(ped)) then
        return 'climbing'
    end
    return nil
end

--- Is an item channel (a heal, a shield) running?
local function channeling()
    local inv = BR.Inv and BR.Inv.local_ and BR.Inv.local_()
    return type(inv) == 'table' and inv.using ~= nil
end

--- Is Interact held? A revive, a crate or a pickup must not fight a dance.
local function interacting()
    return BR.Keys ~= nil and BR.Keys.isHeld ~= nil and BR.Keys.isHeld('interact') == true
end

--- WHY THIS PLAYER MAY NOT DANCE, OR OPEN THE WHEEL, RIGHT NOW -- or nil.
---
--- The state-level half, shared by the wheel's press and its frame pass.
--- Moving and aiming are NOT here: the wheel may be opened on the move, and
--- those two are asked at the pick (canStart).
--- @return string|nil
function BR.Emotes.blocked()
    if not BR.Season.has('emotes') then return 'gate' end
    local why = bodyWhy()
    if why then return why end
    if channeling() then return 'item' end
    if interacting() then return 'interact' end
    return nil
end

--- May a dance START now? blocked(), then the reads that refuse a start and
--- do not cancel one: ragdolling, aiming, already moving.
--- @return boolean
--- @return string|nil why
function BR.Emotes.canStart()
    if not BR.Season.has('emotes') then return false, 'gate' end
    local why = BR.Emotes.blocked()
    if why then return false, why end
    local ped = PlayerPedId()
    if BR.NativeBool(IsPedRagdoll(ped)) then return false, 'ragdoll' end
    if aiming(ped) then return false, 'aiming' end
    if (tonumber(GetEntitySpeed(ped)) or 0) > SPEED_MAX then return false, 'moving' end
    if BR.Emotes.moving() then return false, 'moving' end
    return true, nil
end

--- Ask the server to play a dance on the wheel. No toast on a refusal: every
--- case the server refuses is checked here first, and a pick that cannot play
--- simply does nothing.
--- @param id string
--- @return boolean
--- @return string|nil why
function BR.Emotes.request(id)
    if not BR.Season.has('emotes') then return false, 'gate' end
    local ok, why = BR.Emotes.canStart()
    if not ok then return false, why end
    local slotted = false
    for k = 1, SEGMENTS do
        if wheel[k] ~= '' and wheel[k] == id then slotted = true end
    end
    if not slotted then return false, 'not on the wheel' end
    TriggerServerEvent(BR.Net.EMOTE_PLAY, { id = id })
    audition = nil
    return true, nil
end

--- The own record while it is playing and not already asked to stop, or nil.
--- @return table|nil
function BR.Emotes.mine()
    local me = myId()
    local rec = me and records[me]
    if rec and live(rec) and stopSent ~= rec.tStart then return rec end
    return nil
end

--- Send the one EMOTE_STOP an own record is owed.
--- @param rec table
local function sendStop(rec)
    if stopSent == rec.tStart then return end
    stopSent = rec.tStart
    TriggerServerEvent(BR.Net.EMOTE_STOP, {})
end

--- End this player's dance, and any audition.
function BR.Emotes.stop()
    audition = nil
    local rec = BR.Emotes.mine()
    if rec then sendStop(rec) end
end

--- Every record held, by src. A shallow copy, for the suites.
--- @return table
function BR.Emotes.records()
    local out = {}
    for src, rec in pairs(records) do out[src] = rec end
    return out
end

--- WHY A DANCE THAT IS PLAYING MUST END, or nil.
---
--- blocked()'s state reasons, then the ones only a playing dance has: moving
--- and aiming (owner: "moving or aiming a weapon cancels"), and the item
--- channel and Interact -- two cancels the owner did not list and is asked
--- about on #215.
---
--- RAGDOLL IS NOT HERE, and neither is damage: "damage does not cancel". A hit
--- that knocks the clip off is put back by the playback pass once the ped is
--- up again; no health is read and no task flag is used for it.
--- @return string|nil
local function cancelWhy()
    if not BR.Season.has('emotes') then return 'gate' end
    local why = bodyWhy()
    if why then return why end
    if BR.Emotes.moving() then return 'moving' end
    if aiming(PlayerPedId()) then return 'aiming' end
    if channeling() then return 'item' end
    if interacting() then return 'interact' end
    return nil
end

-- --------------------------------------------------------------- playback ---

--- Take it off the ped and let go of the dictionary. Touches no native when
--- there is nothing to do.
local function stopAnim()
    if anim.ped ~= 0 then
        StopAnimTask(anim.ped, anim.dict, anim.clip, 8.0)
    end
    if anim.askedAt ~= nil then RemoveAnimDict(anim.dict) end
    anim.dict, anim.clip, anim.ped, anim.taskedAt = nil, nil, 0, 0
    anim.askedAt, anim.key = nil, nil
end

--- This dance plays without its clip, and the console says why, once. A
--- record is stopped (so nobody hears music for a dance nobody sees), and an
--- audition is dropped.
--- @param why string
--- @param rec table|nil
local function spend(why, rec)
    print(('[br_core] emotes: %s / %s %s -- this dance plays without it')
        :format(tostring(anim.dict), tostring(anim.clip), why))
    stopAnim()
    if rec then sendStop(rec) end
    audition = nil
end

BR.Loop.register(BR.Loop.TICK, 'emotes.play', function()
    local want, key, rec = nil, nil, nil
    if BR.Season.has('emotes') then
        rec = BR.Emotes.mine()
        if rec then
            want = BR.Emotes.row(rec.id)
            key = want and ('rec:' .. tostring(rec.tStart)) or nil
        elseif audition then
            want = audition
            key = 'aud:' .. audition.dict .. audition.clip
        end
    end

    -- A CANCEL IS SENT ONCE AND ACTED ON AT ONCE: the clip comes off on this
    -- pass, and the tEnd the server sends back only confirms it.
    if want and cancelWhy() ~= nil then
        if rec then sendStop(rec) end
        audition = nil
        want = nil
    end

    if not want then stopAnim() return end

    local ped = PlayerPedId()

    -- A DIFFERENT DANCE OR A DIFFERENT PED IS A STOP NOW AND A START NEXT PASS
    -- (inventory.lua: a StopAnimTask followed by a task in the same frame can
    -- cancel the stop).
    if anim.key ~= nil and (anim.key ~= key or (anim.ped ~= 0 and anim.ped ~= ped)) then
        stopAnim()
        return
    end
    anim.key, anim.dict, anim.clip = key, want.dict, want.clip

    local now = GetGameTimer()
    if anim.ped == ped then
        if now - anim.taskedAt < RETASK_MS then return end
        if BR.NativeBool(IsEntityPlayingAnim(ped, want.dict, want.clip, 3)) then
            anim.taskedAt = now
            return
        end
        -- Dropped. NOT WHILE RAGDOLLED: a task on a ragdoll is thrown away,
        -- and the dance resumes once the ped is up -- "damage does not cancel".
        if BR.NativeBool(IsPedRagdoll(ped)) then return end
    end

    if not BR.NativeBool(HasAnimDictLoaded(want.dict)) then
        if anim.askedAt == nil then
            if not BR.NativeBool(DoesAnimDictExist(want.dict)) then
                spend('is not a dictionary on this build', rec)
                return
            end
            RequestAnimDict(want.dict)
            anim.askedAt = now
        elseif now - anim.askedAt >= LOAD_MS then
            spend(('did not stream in %dms'):format(LOAD_MS), rec)
        end
        return
    end

    -- FULL BODY, LOOPING, UNTIL STOPPED. The flag is the row's (1, AF_LOOPING,
    -- on every starter row); the config refuses 16, 32 and 1024. 8.0 in and
    -- -8.0 out, and -1 because the end is the stop above, never the clip's.
    TaskPlayAnim(ped, want.dict, want.clip, 8.0, -8.0, -1, want.flag or 1, 0.0,
                 false, false, false)
    RemoveAnimDict(want.dict)
    anim.ped, anim.taskedAt, anim.askedAt = ped, now, nil
end)

-- ------------------------------------------------------------------ music ---

--- The empty list, sent once when the last dance goes quiet.
local function silence()
    TriggerEvent('br:ui:sendLocal', BR.Nui.EMOTE_AUDIO, { tracks = {} })
    audioLive = false
end

BR.Loop.register(BR.Loop.TICK, 'emotes.audio', function()
    if not BR.Season.has('emotes') then
        if audioLive then silence() end
        audioLive = false
        return
    end

    -- THE LISTENER IS WHERE THE PICTURE IS. A spectator's ped is a corpse
    -- where they fell (client/spectate.lua), so they hear from the watched
    -- point instead.
    local lp = (BR.Spectate and BR.Spectate.watchPoint and BR.Spectate.watchPoint())
        or GetEntityCoords(PlayerPedId())

    local srcs = {}
    for src, rec in pairs(records) do
        if live(rec) then srcs[#srcs + 1] = src else records[src] = nil end
    end
    table.sort(srcs)

    local me, radius = myId(), BR.Config.Emotes.hearRadiusM
    local tracks = {}
    for _, src in ipairs(srcs) do
        local rec = records[src]
        local row = BR.Emotes.row(rec.id)
        -- The own record asked to stop is silent AT ONCE, not when the tEnd
        -- comes back a round trip later.
        local stopped = (src == me and stopSent == rec.tStart)
        if row and type(row.track) == 'string' and not stopped then
            local dx, dy, dz = lp.x - rec.x, lp.y - rec.y, lp.z - rec.z
            local g = 1 - math.sqrt(dx * dx + dy * dy + dz * dz) / radius
            if g > 0 then
                tracks[#tracks + 1] = {
                    src = src, track = row.track, pos = posOf(rec),
                    g = math.min(g, 1.0),
                }
            end
        end
    end

    if #tracks > 0 or audioLive then
        TriggerEvent('br:ui:sendLocal', BR.Nui.EMOTE_AUDIO, { tracks = tracks })
        audioLive = #tracks > 0
    end
end)

-- ------------------------------------------------------------------- gate ---

-- THE GATE IS ASKED, NOT REMEMBERED, everywhere above. This pass is for the
-- three things that have to HAPPEN when it moves: the server is asked for the
-- market state again (which refreshes br_ui's Emotes tab and slider and this
-- file's wheel mirror), the keybind table is re-pushed so the wheel row
-- appears or goes, and a closed gate takes everything off.
--
-- BEFORE THE SEASON ARRIVES the gate reads shut (br_lib/shared/season.lua), so
-- these passes do nothing that cannot be undone. The pass that sees it land
-- on a season with emotes is a flip, and maps the wheel's key from here.
BR.Loop.register(BR.Loop.SLOW, 'emotes.gate', function()
    local on = BR.Season.has('emotes') == true
    if on and BR.Keys and BR.Keys.mapGated then BR.Keys.mapGated() end

    if (lastOn == nil and on) or (lastOn ~= nil and on ~= lastOn) then
        TriggerServerEvent(BR.Net.MARKET_STATE)
        if BR.Keys and BR.Keys.push then BR.Keys.push() end
    end

    if not on then
        records = {}
        audition = nil
        stopAnim()
    end
    lastOn = on
end)

-- THE ONE ENDING THE LOOP CANNOT COVER, because the loop is what stops: a
-- restart of br_core mid-dance would leave a looping clip on the ped and the
-- page playing music with nothing left to tell it otherwise.
AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    stopAnim()
    if audioLive then silence() end
end)

-- ------------------------------------------------------------- the probe ---

--- THE DANCES, AS /brnativecheck ROWS: one per catalogue id.
---
--- Both halves of each clip are asked of the build -- the dictionary exists,
--- and the clip is in it (GetAnimDuration's zero is "no such clip"). The row
--- also says whether the track file is in br_ui's bundle. A MISSING TRACK IS
--- STILL ok: the dance plays in silence, which is today's shipped path.
---
--- It waits, boundedly, for each dictionary, so it lives behind a console
--- command and never in a loop pass -- BR.Inv.emoteCheck's shape.
--- @return table array of { name, ok, detail }
function BR.Emotes.nativeCheck()
    if not BR.Season.has('emotes') then
        return { { name = 'dances', ok = true,
                   detail = ('emotes are off (%s)'):format(offWhy(BR.Season.current())) } }
    end
    local rows = {}
    for _, id in ipairs(BR.Config.Emotes.order) do
        local row = BR.Emotes.row(id)
        local ran, good, detail = pcall(function()
            local track
            if row.track == nil then
                track = 'no track (plays silent)'
            elseif LoadResourceFile('br_ui', 'ui/' .. row.track) ~= nil then
                track = 'track present'
            else
                track = 'track MISSING (plays silent)'
            end
            local name = row.dict .. ' / ' .. row.clip
            if not BR.NativeBool(DoesAnimDictExist(row.dict)) then
                return false, ('%s -- no such dictionary on this build, %s'):format(name, track)
            end
            RequestAnimDict(row.dict)
            local waited = 0
            while not BR.NativeBool(HasAnimDictLoaded(row.dict)) and waited < LOAD_MS do
                Citizen.Wait(50)
                waited = waited + 50
            end
            if not BR.NativeBool(HasAnimDictLoaded(row.dict)) then
                RemoveAnimDict(row.dict)
                return false, ('%s -- did not stream in %dms, %s'):format(name, LOAD_MS, track)
            end
            local len = tonumber(GetAnimDuration(row.dict, row.clip)) or 0
            RemoveAnimDict(row.dict)
            if len <= 0 then
                return false, ('%s -- the dictionary has no clip of that name, %s')
                    :format(name, track)
            end
            return true, ('%.2fs clip, plays %ds, %s'):format(len, row.durationMs // 1000, track)
        end)
        rows[#rows + 1] = {
            name   = 'dance: ' .. id,
            ok     = ran and good == true,
            detail = ran and tostring(detail) or tostring(good),
        }
    end
    return rows
end

-- ------------------------------------------------------------ the console ---

--- One line per row of the probe.
local function printRows(rows)
    for _, r in ipairs(rows) do
        print(('  %s %-28s %s'):format(r.ok and 'ok  ' or 'FAIL', r.name, r.detail or ''))
    end
end

-- THE AUDITION TOOL. Dev-only even in a season that has emotes: it plays ANY
-- dictionary and clip on a ped other players can see (an owner question on
-- #215), so it stays behind the console-command dev gate as well as asking
-- the emote gate first.
RegisterCommand('bremote', function(_, args)
    if not BR.Season.has('emotes') then
        print(('[br_core] bremote: emotes are off (%s; '
              .. 'br_lib/config/seasons.lua)'):format(offWhy(BR.Season.current())))
        return
    end
    args = type(args) == 'table' and args or {}
    local a1 = args[1]

    if a1 == nil then
        print('[br_core] bremote: usage: bremote <dict> <clip> [flag] | stop | check')
        for k = 1, SEGMENTS do
            print(('  slot %d  %s'):format(k, wheel[k] ~= '' and wheel[k] or '(empty)'))
        end
        for _, id in ipairs(BR.Config.Emotes.order) do
            local row = BR.Emotes.row(id)
            print(('  %-22s %-16s %s / %s  flag %d  %dms  %s%s'):format(id, row.name,
                row.dict, row.clip, row.flag, row.durationMs, tostring(row.track or 'no track'),
                owned[id] and '  (owned)' or ''))
        end
        return
    end

    if a1 == 'stop' then
        BR.Emotes.stop()
        print('[br_core] bremote: stopped')
        return
    end

    if a1 == 'check' then
        printRows(BR.Emotes.nativeCheck())
        return
    end

    local dict, clip = a1, args[2]
    if type(clip) ~= 'string' or clip == '' then
        print('[br_core] bremote: usage: bremote <dict> <clip> [flag]')
        return
    end
    local n = tonumber(args[3])
    local flag = (n and math.tointeger(n)) or 1
    local bad = BR.Emotes.flagProblem(flag)
    if bad then
        print(('[br_core] bremote: flag %s refused -- %s'):format(tostring(args[3]), bad))
        return
    end
    local ok, why = BR.Emotes.canStart()
    if not ok then
        print(('[br_core] bremote: cannot start -- %s'):format(tostring(why)))
        return
    end
    BR.Emotes.stop()
    audition = { dict = dict, clip = clip, flag = flag }
    print(('[br_core] bremote: auditioning %s / %s (flag %d) -- local only, no music')
        :format(dict, clip, flag))
end, false)

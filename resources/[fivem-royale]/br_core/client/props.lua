-- /brprop (#384), client half: draw the server's dev props, and move them by hand.
--
-- Owner, 2026-10-03: "I'm testing some custom props - first ever, made by
-- Claude, and I want a way to spawn them in. I would like something akin to our
-- pickups where it hovers/bobs/rotates when close, and I need a way to interact
-- with it manually like moving in every direction, and rotating."
--
-- ═══ PRESENTATION AND REQUESTS, NEVER DECISIONS ═══
--
-- br_core/server/props.lua owns every prop: it assigns the id, holds the record
-- and decides every change. This file draws its OWN local, non-networked copy
-- of each record -- CreateObjectNoOffset with isNetwork = false, exactly as
-- client/loot.lua draws loot, because `sv_entityLockdown relaxed` refuses a
-- client-created networked entity (client/airdrop.lua's note) -- and everything
-- else it does is ASK: spawn, move, delete, display, save, load. Deleting a copy
-- here deletes nothing anywhere else.
--
-- ═══ HOW IT ASKS ═══
--
-- Every request is the server's dev command `brpropsv`, run from here with
-- ExecuteCommand: this client has no command by that name, so FiveM sends the
-- line to the server, which runs it as this player behind the same dev gate
-- as every other dev command (server/props.lua's header has the sources).
-- `brprop` is what the player types, and it does first what only a client
-- can: stream the model, find the ground in front of him, pick the nearest
-- prop, run the edit keys. `list` and `where` ask nothing at all -- they read
-- the records every client is already sent, beside what THIS client managed
-- to draw, which the server cannot know.
--
-- The edit preview is the one thing that is not a command: ten updates a
-- second would trip FiveM's rate limit on a client's server commands. It is
-- the PROP_MOVE net event, and the server takes it only inside the edit
-- session `brpropsv edit begin` opened for this player and this prop -- so the
-- edit starts here when the server says the session is open, not before.
--
-- ═══ TWO LOOKS ═══
--
--   pickup  (the default) the loot pickup's own animation off the loot's own
--           numbers -- see BR.PropSolve.hover. Inside prompt range it rises,
--           bobs and spins, eased; outside it rests at exactly its record.
--           No collision, like a loose loot item.
--   static  exactly where and how it was placed, with collision.
--
-- ═══ THE EDIT MODE READS KEYS NO PLAYER ACTION IS ON ═══
--
-- Through BR.Keys.rawKeyDown (client/keybinds.lua), which binds nothing and
-- fires nothing, so it cannot shadow a player's key -- and an edit key the
-- player HAS bound one of his own actions to is switched off for the session
-- and said so, rather than doing two things at once. The GTA controls those
-- keys would otherwise drive (walking on WASD, cover on Q, ducking on Ctrl...)
-- are disabled frame by frame while editing, so they come back on their own the
-- frame editing ends.

BR = BR or {}

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua. Every BOOL read
--- in this file goes through here (tools/bool_native_rules.lua).
local isTrue = BR.NativeTruthy

local S = BR.PropSolve

--- [id] = the server's record, as last sent.
local recs = {}

--- [id] = this client's drawing of it:
---   { state = 'loading'|'built'|'failed', model, hash, since, obj,
---     display, lift, off, settled, dirty }
local copies = {}

--- A spawn waiting for its model to stream, or nil.
local pending = nil

--- The edit session, or nil.
local E = nil

--- An `edit begin` the server has not answered yet: { id, at }, or nil.
local asking = nil

--- @return table BR.Config.Props, at call time
local function cfg() return BR.Config.Props end

--- @return table BR.Config.Loot, at call time -- the pickup look's numbers
local function loot() return BR.Config.Loot or {} end

--- One line on F8. The only text this file ever prints outside the edit readout.
--- @param text string
local function say(text)
    print('[br_core] brprop: ' .. text)
end

--- Run one request on the server, as the `brpropsv` dev command.
--- @param line string  everything after the command name
local function ask(line)
    ExecuteCommand('brpropsv ' .. line)
end

-- ------------------------------------------------------------------- keys ---

-- ═══ THE EDIT KEYS, AND WHY THESE ═══
--
-- W A S D and Q / Z are the owner's own choice for a hand tool -- his words for
-- /brattach were "WASD to move around and Q/Z to move up and down". The
-- rotations cannot follow /brattach onto E and R, because those are the
-- player's interact and use keys and this tool may not shadow them; so they sit
-- on the I J K L cluster beside it, plus U and O: J/L turn, I/K tip forward and
-- back, U/O lean. None of those letters is a player binding by default, and
-- three of them (I, J, O) drive no GTA control at all.
--
-- Ctrl is the coarse modifier rather than Shift, because Shift is the vehicle
-- boost. F drops the prop to the ground ("floor"), C clears its rotation, Enter
-- confirms and X cancels -- Escape is the pause menu, and Backspace is the
-- player's clear-waypoint key.
--
-- `codes` are Windows virtual-key codes, which is what IS_RAW_KEY_DOWN indexes.
-- Ctrl asks the side-specific codes too, on the evidence client/keybinds.lua
-- records for Shift: the generic slot was never filled on the owner's build.
local KEYS = {
    { name = 'fwd',       label = 'W', codes = { 0x57 } },
    { name = 'back',      label = 'S', codes = { 0x53 } },
    { name = 'left',      label = 'A', codes = { 0x41 } },
    { name = 'right',     label = 'D', codes = { 0x44 } },
    { name = 'up',        label = 'Q', codes = { 0x51 } },
    { name = 'down',      label = 'Z', codes = { 0x5A } },
    { name = 'yawLeft',   label = 'J', codes = { 0x4A } },
    { name = 'yawRight',  label = 'L', codes = { 0x4C } },
    { name = 'pitchUp',   label = 'I', codes = { 0x49 } },
    { name = 'pitchDown', label = 'K', codes = { 0x4B } },
    { name = 'rollLeft',  label = 'U', codes = { 0x55 } },
    { name = 'rollRight', label = 'O', codes = { 0x4F } },
}
local COARSE = { name = 'coarse', label = 'Ctrl', codes = { 0x11, 0xA2, 0xA3 } }
local ONCE = {
    { name = 'ground',  label = 'F',     codes = { 0x46 } },
    { name = 'reset',   label = 'C',     codes = { 0x43 } },
    { name = 'confirm', label = 'Enter', codes = { 0x0D } },
    { name = 'cancel',  label = 'X',     codes = { 0x58 } },
}

--- The GTA controls on those keys, disabled while editing so a nudge is not
--- also a step, a duck or a reload. Taken from the docs.fivem.net controls
--- table (citizenfx/fivem-docs controls.md, 2026-10-03), key by key, every
--- index whose default PC key is one we read -- on foot, in a vehicle and in
--- the frontend alike, because the tool does not care where the player is.
--- A disable lasts one frame, so nothing has to be put back.
local BLOCKED = {
    32, 71, 77, 87, 129, 136, 150, 232,                       -- W
    34, 63, 89, 133, 147, 234, 338,                            -- A
    8, 31, 33, 72, 78, 88, 130, 139, 149, 151, 196, 219, 233,  -- S
    268, 269, 302,
    9, 30, 35, 59, 64, 90, 134, 146, 148, 195, 218, 235,       -- D
    266, 267, 278, 279, 339, 342,
    44, 52, 85, 138, 141, 152, 205, 264,                       -- Q
    20, 48,                                                     -- Z
    182, 311, 303,                                              -- L, K, U
    23, 49, 75, 145, 185, 251,                                  -- F
    26, 79, 253, 319, 324,                                      -- C
    73, 105, 120, 154, 186, 252, 323, 337, 345, 354, 357,       -- X
    18, 176, 191, 201, 215,                                     -- Enter
    36, 60, 62, 132, 210, 224, 280, 281, 326, 341, 343,         -- Ctrl
}

--- Is any of these codes down, read through the raw key layer?
--- @param codes table
--- @return boolean
local function keyDown(codes)
    if not (BR.Keys and BR.Keys.rawKeyDown) then return false end
    for i = 1, #codes do
        if BR.Keys.rawKeyDown(codes[i]) == true then return true end
    end
    return false
end

-- --------------------------------------------------------------- drawing ---

--- Hand a model back to the streamer. Called the moment nothing of ours needs
--- it held: right after the copy is built (the object keeps it resident), and
--- whenever a load is abandoned or refused.
--- @param hash integer|nil
local function release(hash)
    if hash then SetModelAsNoLongerNeeded(hash) end
end

--- Delete one copy, and let go of its model if it was still streaming.
--- @param id integer
local function dropCopy(id)
    local c = copies[id]
    if not c then return end
    if c.obj and isTrue(DoesEntityExist(c.obj)) then DeleteEntity(c.obj) end
    if c.state == 'loading' then release(c.hash) end
    copies[id] = nil
end

--- Write a position and a rotation onto an object.
local function place(obj, x, y, z, pitch, roll, yaw)
    SetEntityCoordsNoOffset(obj, x, y, z, false, false, false)
    SetEntityRotation(obj, pitch, roll, yaw, 2, true)
end

--- Collision for a static prop, none for a pickup -- a loose loot item has
--- none either -- and frozen always, so physics never moves a record.
--- @param c table @param r table
local function shape(c, r)
    FreezeEntityPosition(c.obj, true)
    local solid = r.display == S.STATIC
    SetEntityCollision(c.obj, solid, solid)
    c.display = r.display
end

--- Start drawing record `id`, or redraw it if its model changed.
--- @param id integer
local function wantCopy(id)
    local r = recs[id]
    if not r then return end
    local c = copies[id]
    if c and c.model ~= r.model then
        dropCopy(id)
        c = nil
    end
    if c then
        c.dirty, c.settled = true, false
        return
    end

    local hash = GetHashKey(r.model)
    if not isTrue(IsModelInCdimage(hash)) then
        copies[id] = { state = 'failed', model = r.model }
        say(("#%d '%s' is not in this game's CD image, so it is not drawn here. "
            .. 'Is the resource that streams it started?'):format(id, r.model))
        return
    end
    RequestModel(hash)
    copies[id] = {
        state = 'loading', model = r.model, hash = hash, since = GetGameTimer(),
        lift = 0.0, off = 0.0, dirty = true, settled = false,
    }
end

--- Take one record from the server.
--- @param r table
local function learn(r)
    if type(r) ~= 'table' or type(r.id) ~= 'number' or type(r.model) ~= 'string' then
        return
    end
    recs[r.id] = r
    -- MID-EDIT, ONLY THE DISPLAY IS TAKEN. The transform on the wire is an echo
    -- of this client's own preview, a frame or two old; the preview stays put.
    if E and E.id == r.id then E.display = r.display end
    wantCopy(r.id)
end

--- Forget one record and its copy -- and the edit, if it was this one.
--- @param id integer
local function forget(id)
    recs[id] = nil
    dropCopy(id)
    if E and E.id == id then
        E = nil
        say(('#%d was deleted while you were editing it; edit ended'):format(id))
    end
end

--- Build every copy whose model has streamed in; give up on any that never will.
--- @param now integer
local function stepBuilds(now)
    local waitMs = cfg().loadWaitMs or 5000
    for id, c in pairs(copies) do
        if c.state == 'loading' then
            local r = recs[id]
            if not r then
                dropCopy(id)
            elseif isTrue(HasModelLoaded(c.hash)) then
                local obj = CreateObjectNoOffset(c.hash, r.x, r.y, r.z, false, false, false)
                release(c.hash)
                -- A HANDLE OF 0 IS A REFUSAL, NOT AN OBJECT -- client/loot.lua's
                -- rule. A vehicle or ped archetype is in the CD image and
                -- streams fine, and is still not an object.
                if not obj or obj == 0 then
                    c.state = 'failed'
                    say(("#%d '%s' loaded, but the game refused to build it as an "
                        .. 'object (is it a vehicle or ped model?)'):format(id, r.model))
                else
                    c.obj, c.state = obj, 'built'
                    shape(c, r)
                    place(obj, r.x, r.y, r.z, r.pitch, r.roll, r.yaw)
                    c.dirty, c.settled = false, true
                end
            elseif now - c.since > waitMs then
                release(c.hash)
                c.state = 'failed'
                say(("#%d '%s' did not load within %d ms, so it is not drawn here")
                    :format(id, r.model, waitMs))
            end
        end
    end
end

--- Draw every built copy for this frame.
--- @param dt number @param now integer
local function animate(dt, now)
    local me = nil
    for id, c in pairs(copies) do
        local r = recs[id]
        if c.state == 'built' and r and c.obj then
            if c.display ~= r.display then
                shape(c, r)
                c.dirty, c.settled = true, false
            end

            if E and E.id == id then
                -- THE PREVIEW: exactly the edit's transform, never hovering --
                -- the thing being placed is the resting pose.
                local t = E.t
                place(c.obj, t.x, t.y, t.z, t.pitch, t.roll, t.yaw)
                c.lift, c.off, c.settled = 0.0, 0.0, false
            elseif r.display == S.STATIC then
                if c.dirty or not c.settled then
                    place(c.obj, r.x, r.y, r.z, r.pitch, r.roll, r.yaw)
                    c.lift, c.off = 0.0, 0.0
                    c.dirty, c.settled = false, true
                end
            else
                -- FLAT DISTANCE, as loot.lua measures its prompt range
                -- (BR.Dist2 over x and y), so a prop and a rifle at the same
                -- spot rise at the same step.
                me = me or GetEntityCoords(PlayerPedId())
                local dx, dy = r.x - me.x, r.y - me.y
                local zOff, pitch, off, k = S.hover(c, r.pitch, dx * dx + dy * dy,
                    dt, now, loot())
                if k <= 0.001 then
                    -- AT REST, EXACTLY THE RECORD, written once on the way down
                    -- rather than every frame -- loot.lua's rule: a prop on the
                    -- floor should cost nothing.
                    if c.dirty or not c.settled then
                        place(c.obj, r.x, r.y, r.z, r.pitch, r.roll, r.yaw)
                        c.dirty, c.settled = false, true
                    end
                else
                    c.dirty, c.settled = false, false
                    place(c.obj, r.x, r.y, r.z + zOff, pitch, r.roll, r.yaw + off)
                end
            end
        end
    end
end

-- ------------------------------------------------------------------ spawn ---

--- Where a new prop goes: in front of the player, on the ground, facing the
--- way he faces. Its own footprint is added to the distance so it does not
--- land on his feet, and its own bottom is put on the ground rather than its
--- origin, so a model authored with its pivot in the middle is not half-buried.
--- @param hash integer
--- @return table { x, y, z, yaw }
local function spot(hash)
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local half, minZ = 0.5, 0.0
    local okd, lo, hi = pcall(GetModelDimensions, hash)
    if okd and lo and hi then
        half = math.max(hi.x - lo.x, hi.y - lo.y) * 0.5
        minZ = lo.z
    end
    local dist = (cfg().spawnAheadM or 1.5) + half
    local h = math.rad(heading)
    local x, y = pos.x - math.sin(h) * dist, pos.y + math.cos(h) * dist
    local found, gz = GetGroundZFor_3dCoord(x, y, pos.z + 2.0, false)
    if not isTrue(found) or type(gz) ~= 'number' then
        -- No ground under the spot (water, or collision not streamed): the
        -- player's own feet, a metre under the ped's root.
        gz = pos.z - 1.0
    end
    return { x = x, y = y, z = gz - minZ, yaw = S.angle(heading) }
end

--- `/brprop spawn`: check the name here, stream the model, then ask.
---
--- THE MODEL IS CHECKED ON THIS CLIENT BECAUSE ONLY A CLIENT CAN. The server has
--- no CD image; whether a name streams is a question about the game, so the
--- refusal that names the model is printed here, before anything is asked.
--- @param model string|nil
--- @param display string|nil
local function beginSpawn(model, display)
    local P = cfg()
    local name, why = S.modelName(model, P)
    if not name then
        say(('spawn refused: %s'):format(why))
        return
    end
    local mode, why2 = S.display(display)
    if not mode then
        say(('spawn refused: %s'):format(why2))
        return
    end
    if pending then
        say(("still loading '%s'; try again in a moment"):format(pending.model))
        return
    end
    local hash = GetHashKey(name)
    if not isTrue(IsModelInCdimage(hash)) then
        say(("spawn refused: '%s' is not in the game's CD image. Is the resource that "
            .. 'streams it started, and does the name match its archetype?'):format(name))
        return
    end
    RequestModel(hash)
    pending = { model = name, hash = hash, display = mode, since = GetGameTimer() }
end

--- One frame of a pending spawn: send it once the model is in, refuse it if
--- the model never comes.
--- @param now integer
local function stepSpawn(now)
    local p = pending
    if isTrue(HasModelLoaded(p.hash)) then
        pending = nil
        local t = spot(p.hash)
        release(p.hash)
        ask(('spawn %s %s %s %s %s %s'):format(p.model, p.display,
            S.num(t.x), S.num(t.y), S.num(t.z), S.num(t.yaw)))
        say(("asked the server for '%s' (%s)"):format(p.model, p.display))
    elseif now - p.since > (cfg().loadWaitMs or 5000) then
        pending = nil
        release(p.hash)
        say(("spawn refused: '%s' did not load within %d ms")
            :format(p.model, cfg().loadWaitMs or 5000))
    end
end

-- ------------------------------------------------------------------- edit ---

--- The surveyed boundary, or nothing -- the server's own reading of it, so the
--- preview stops where the server would refuse.
--- @param x number @param y number
--- @return boolean
local function inBounds(x, y)
    local M = BR.Config.Map
    if not (M and M.InBounds and M.Boundary and BR.PointInPolygon) then return false end
    return M.InBounds(x, y) == true
end

--- Send the edit's preview to the server, on the edit stream.
--- @param id integer @param t table @param now integer
local function sendMove(id, t, now)
    TriggerServerEvent(BR.Net.PROP_MOVE, {
        id = id, x = t.x, y = t.y, z = t.z,
        pitch = t.pitch, roll = t.roll, yaw = t.yaw,
    })
    if E then E.lastSentAt, E.dirty = now, false end
end

--- @param t table
--- @return table
local function copyT(t)
    return { x = t.x, y = t.y, z = t.z, pitch = t.pitch, roll = t.roll, yaw = t.yaw }
end

--- End the edit. Confirm sends the preview with `edit confirm`; cancel asks the
--- server to put back its own copy of the record from when the edit began, for
--- everybody. Either closes the session.
---
--- THE LOCAL RECORD TAKES THE ANSWER AT ONCE, rather than waiting a round trip
--- for the echo -- otherwise the copy would jump back to the last 10 Hz update
--- for a frame or two. If the server refuses the confirm it sends this client
--- the record as it stands, and that corrects it.
--- @param confirm boolean
local function finishEdit(confirm)
    local e = E
    if not e then return end
    local t = confirm and e.t or e.orig
    if confirm then
        ask(('edit confirm %d %s %s %s %s %s %s'):format(e.id, S.num(t.x), S.num(t.y),
            S.num(t.z), S.num(t.pitch), S.num(t.roll), S.num(t.yaw)))
    else
        ask(('edit cancel %d'):format(e.id))
    end
    E = nil
    local r = recs[e.id]
    if r then
        r.x, r.y, r.z = t.x, t.y, t.z
        r.pitch, r.roll, r.yaw = t.pitch, t.roll, t.yaw
    end
    local c = copies[e.id]
    if c then c.dirty, c.settled = true, false end
    if confirm then
        say(('#%d confirmed'):format(e.id))
    else
        say(('#%d edit canceled; put back where it was'):format(e.id))
    end
end

--- F: put the prop's lowest point on the ground under it.
---
--- ASKED OF THE ENGINE, NOT CALCULATED. The lowest point of a rotated box
--- depends on the euler order the engine applies, and the engine already knows
--- it: the eight corners of the model's box are put through the object's own
--- matrix with GetOffsetFromEntityInWorldCoords, and the lowest one is lifted
--- or dropped onto the first ground below the highest. The prop's collision is
--- off for the probe so the ground found is never its own top.
local function snapToGround()
    local c = copies[E.id]
    if not (c and c.obj) then return end
    local t = E.t
    place(c.obj, t.x, t.y, t.z, t.pitch, t.roll, t.yaw)
    local okd, lo, hi = pcall(GetModelDimensions, GetEntityModel(c.obj))
    if not okd or not lo or not hi then
        say(('#%d has no model box; cannot find its bottom'):format(E.id))
        return
    end
    local low, top = math.huge, -math.huge
    for _, cx in ipairs({ lo.x, hi.x }) do
        for _, cy in ipairs({ lo.y, hi.y }) do
            for _, cz in ipairs({ lo.z, hi.z }) do
                local w = GetOffsetFromEntityInWorldCoords(c.obj, cx, cy, cz)
                if w.z < low then low = w.z end
                if w.z > top then top = w.z end
            end
        end
    end
    SetEntityCollision(c.obj, false, false)
    local found, gz = GetGroundZFor_3dCoord(t.x, t.y, top + 0.5, false)
    local solid = (recs[E.id] and recs[E.id].display) == S.STATIC
    SetEntityCollision(c.obj, solid, solid)
    if not isTrue(found) or type(gz) ~= 'number' then
        say(('no ground under #%d here'):format(E.id))
        return
    end
    local n = copyT(t)
    n.z = t.z + (gz - low)
    E.t, E.dirty = n, true
end

--- One line of the on-screen readout. client/attachtune.lua's text call.
local function text(x, y, s)
    SetTextFont(4)
    SetTextScale(0.0, 0.34)
    SetTextColour(255, 255, 255, 235)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(x, y)
end

--- The dev readout: what is being edited, where it is, the step and the keys.
--- A key the player has bound to one of his own actions is shown as off.
--- @param coarse boolean
local function readout(coarse)
    local t, P = E.t, cfg()
    local m, deg = S.stepSize(coarse, P)
    local cm, cdeg = S.stepSize(true, P)
    local fm, fdeg = S.stepSize(false, P)
    local function k(entry)
        return E.taken[entry.name] and '-' or entry.label
    end
    local lines = {
        ('#%d  %s  (%s)'):format(E.id, E.model, E.display),
        ('x %.2f   y %.2f   z %.2f'):format(t.x, t.y, t.z),
        ('pitch %.1f   roll %.1f   yaw %.1f'):format(t.pitch, t.roll, t.yaw),
        ('step %s %.2f m / %.0f deg   (%s: %.2f m / %.0f deg)'):format(
            coarse and 'coarse' or 'fine', m, deg, k(COARSE),
            coarse and fm or cm, coarse and fdeg or cdeg),
        ('%s %s %s %s move   %s %s up/down'):format(k(KEYS[1]), k(KEYS[3]),
            k(KEYS[2]), k(KEYS[4]), k(KEYS[5]), k(KEYS[6])),
        ('%s %s yaw   %s %s pitch   %s %s roll'):format(k(KEYS[7]), k(KEYS[8]),
            k(KEYS[9]), k(KEYS[10]), k(KEYS[11]), k(KEYS[12])),
        ('%s ground   %s reset rotation   %s confirm   %s cancel'):format(
            k(ONCE[1]), k(ONCE[2]), k(ONCE[3]), k(ONCE[4])),
    }
    for i = 1, #lines do text(0.015, 0.30 + (i - 1) * 0.026, lines[i]) end
end

--- One frame of the edit.
--- @param now integer
local function stepEdit(now)
    for i = 1, #BLOCKED do DisableControlAction(0, BLOCKED[i], true) end

    local P = cfg()
    local coarse = not E.taken.coarse and keyDown(COARSE.codes)
    local cam = GetGameplayCamRot(2)
    local camYaw = cam and cam.z or 0.0
    local me = GetEntityCoords(PlayerPedId())

    for _, key in ipairs(KEYS) do
        local down = not E.taken[key.name] and keyDown(key.codes)
        -- A KEY HELD WHEN THE EDIT BEGAN DOES NOTHING UNTIL IT IS LET GO --
        -- the Enter that submitted the command must not confirm it.
        if not down then E.armed[key.name] = true end
        local st = E.keys[key.name]
        if st == nil then
            st = {}
            E.keys[key.name] = st
        end
        if S.repeatFire(st, down and E.armed[key.name] == true, now, P) then
            local n = S.move(E.t, key.name, camYaw, coarse, P)
            local ok, why = S.placeOk(n, me, inBounds, P)
            if ok then
                E.t, E.dirty = n, true
            elseif not E.warnedEdge then
                E.warnedEdge = true
                say(('#%d stops here: %s'):format(E.id, why))
            end
        end
    end

    for _, key in ipairs(ONCE) do
        local down = not E.taken[key.name] and keyDown(key.codes)
        local was = E.held[key.name] == true
        E.held[key.name] = down
        if not down then
            E.armed[key.name] = true
        elseif not was and E.armed[key.name] == true then
            if key.name == 'confirm' then
                finishEdit(true)
                return
            elseif key.name == 'cancel' then
                finishEdit(false)
                return
            elseif key.name == 'ground' then
                snapToGround()
            elseif key.name == 'reset' then
                E.t, E.dirty = S.resetRotation(E.t), true
            end
        end
    end

    if E.dirty and S.sendDue(E.lastSentAt, now, P.sendHz) then
        sendMove(E.id, E.t, now)
    end
    readout(coarse)
end

--- The nearest record within `range` of the player, or nil.
--- @param range number
--- @return integer|nil
local function nearestId(range)
    local me = GetEntityCoords(PlayerPedId())
    local best, bestD = nil, nil
    for id, r in pairs(recs) do
        local dx, dy, dz = r.x - me.x, r.y - me.y, r.z - me.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d <= range and (bestD == nil or d < bestD) then best, bestD = id, d end
    end
    return best
end

--- Can prop `id` be edited on this client? The record, or nil and why.
--- @param id integer
--- @return table|nil
--- @return string|nil why
local function editable(id)
    if not (BR.Keys and BR.Keys.rawActive == true and BR.Keys.rawKeyDown) then
        return nil, 'edit needs the raw key layer, which is not running on this client (see /brkeys)'
    end
    local r = recs[id]
    if not r then return nil, ('there is no prop #%s'):format(tostring(id)) end
    local c = copies[id]
    if not c or c.state ~= 'built' then
        return nil, ('#%d is not drawn on this client, so it cannot be edited here'):format(id)
    end
    return r, nil
end

--- `/brprop edit [id]`: check what only this client can, then ask the server
--- for the session. The edit itself starts in openEdit, on its answer.
--- @param id integer|nil
local function askEdit(id)
    if E then
        say(('already editing #%d; Enter confirms, X cancels'):format(E.id))
        return
    end
    if asking and GetGameTimer() - asking.at < (cfg().loadWaitMs or 5000) then
        say(('still waiting for the server to open #%d'):format(asking.id))
        return
    end
    if not (BR.Keys and BR.Keys.rawActive == true and BR.Keys.rawKeyDown) then
        say('edit needs the raw key layer, which is not running on this client (see /brkeys)')
        return
    end
    if id == nil then
        id = nearestId(cfg().pickRangeM or 50.0)
        if id == nil then
            say(('no prop within %d m; give an id (see /brprop list)')
                :format(math.floor(cfg().pickRangeM or 50.0)))
            return
        end
    end
    local _, why = editable(id)
    if why then
        say(why)
        return
    end
    asking = { id = id, at = GetGameTimer() }
    ask(('edit begin %d'):format(id))
end

--- The server opened this player's session on `id`: start the edit.
---
--- AN ANSWER NOBODY IS WAITING FOR IS HANDED BACK. A session this client will
--- not use would hold the prop against every other editor until it idled out,
--- so it is canceled at once -- nothing was streamed, so nothing moves.
--- @param id integer
local function openEdit(id)
    local wanted = asking ~= nil and asking.id == id
    asking = nil
    local r, why = nil, nil
    if wanted and E == nil then r, why = editable(id) end
    if r == nil then
        ask(('edit cancel %d'):format(id))
        if why then say(why) end
        return
    end

    local t = { x = r.x, y = r.y, z = r.z, pitch = r.pitch, roll = r.roll, yaw = r.yaw }
    E = {
        id = id, model = r.model, display = r.display,
        t = t, orig = copyT(t),
        keys = {}, held = {}, armed = {}, taken = {},
        lastSentAt = nil, dirty = false, warnedEdge = false,
    }

    -- THE PLAYER'S OWN BINDINGS WIN. Any edit key he has put one of his actions
    -- on is off for this session, so one press never does two things.
    local all = { COARSE }
    for _, k in ipairs(KEYS) do all[#all + 1] = k end
    for _, k in ipairs(ONCE) do all[#all + 1] = k end
    for _, k in ipairs(all) do
        local action, label = nil, nil
        if BR.Keys.actionOnKey then action, label = BR.Keys.actionOnKey(k.codes[1]) end
        if action then
            E.taken[k.name] = label or action
            say(("%s is your key for '%s', so it does nothing while editing")
                :format(k.label, tostring(label or action)))
        end
    end
    say(('editing #%d %s; Enter confirms, X cancels'):format(id, r.model))
end

-- ------------------------------------------------------------------ loop ---

BR.Loop.register(BR.Loop.FRAME, 'props.frame', function(dt)
    if next(copies) == nil and pending == nil and E == nil then return end
    local now = GetGameTimer()
    if pending then stepSpawn(now) end
    stepBuilds(now)
    if E then stepEdit(now) end
    animate(dt or 0, now)
end)

-- ------------------------------------------------------------------- wire ---

RegisterNetEvent(BR.Net.PROP_SYNC)
AddEventHandler(BR.Net.PROP_SYNC, function(msg)
    if type(msg) ~= 'table' then return end
    if msg.full then
        local keep = {}
        for _, r in ipairs(msg.props or {}) do
            if type(r) == 'table' and r.id ~= nil then keep[r.id] = true end
        end
        local gone = {}
        for id in pairs(recs) do
            if not keep[id] then gone[#gone + 1] = id end
        end
        for i = 1, #gone do forget(gone[i]) end
        for _, r in ipairs(msg.props or {}) do learn(r) end
    end
    for _, r in ipairs(msg.set or {}) do learn(r) end
    for _, id in ipairs(msg.gone or {}) do forget(id) end
end)

RegisterNetEvent(BR.Net.PROP_RESULT)
AddEventHandler(BR.Net.PROP_RESULT, function(text)
    say(tostring(text))
end)

-- THE SESSION, OPENED OR CLOSED BY THE SERVER. A close carrying no reason is
-- the answer to a refused `edit begin`, whose reason already came as a result
-- line; one with a reason ends an edit in progress, and the copy goes back to
-- the record -- which the stream has been keeping current all along.
RegisterNetEvent(BR.Net.PROP_EDIT)
AddEventHandler(BR.Net.PROP_EDIT, function(msg)
    if type(msg) ~= 'table' or type(msg.id) ~= 'number' then return end
    if msg.open == true then
        openEdit(msg.id)
        return
    end
    if asking and asking.id == msg.id then asking = nil end
    if E and E.id == msg.id and msg.why ~= nil then
        E = nil
        local c = copies[msg.id]
        if c then c.dirty, c.settled = true, false end
        say(('#%d edit ended by the server: %s'):format(msg.id, tostring(msg.why)))
    end
end)

-- EVERY LOCAL COPY GOES WITH THE RESOURCE. A local object outlives the script
-- that made it, so without this a `restart br_core` would leave each prop
-- standing a second time beside the one the restarted file draws.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    local ids = {}
    for id in pairs(copies) do ids[#ids + 1] = id end
    for i = 1, #ids do dropCopy(ids[i]) end
    if pending then
        release(pending.hash)
        pending = nil
    end
    E, asking = nil, nil
end)

-- --------------------------------------------------------------- command ---

local USAGE = 'usage: brprop spawn <model> [pickup|static] | list | delete <id|all> '
    .. '| display <id> <pickup|static> | where <id> | edit [id] | save | load'

--- @param s any
--- @return integer|nil
local function idOf(s)
    local n = tonumber(s)
    if n == nil then return nil end
    return math.tointeger(n)
end

RegisterCommand('brprop', function(_, args)
    local verb = args[1] and args[1]:lower() or nil

    if verb == 'spawn' then
        beginSpawn(args[2], args[3])

    elseif verb == 'list' then
        local ids = {}
        for id in pairs(recs) do ids[#ids + 1] = id end
        table.sort(ids)
        if #ids == 0 then
            say('no props')
            return
        end
        local me = GetEntityCoords(PlayerPedId())
        for _, id in ipairs(ids) do
            local r, c = recs[id], copies[id]
            local dx, dy, dz = r.x - me.x, r.y - me.y, r.z - me.z
            local state = (c and c.state == 'built') and '' or
                ('  [' .. ((c and c.state) or 'not drawn') .. ' here]')
            print(('  #%-3d %-28s %-6s %9.2f %9.2f %8.2f  %4.0f m%s'):format(id, r.model,
                r.display, r.x, r.y, r.z, math.sqrt(dx * dx + dy * dy + dz * dz), state))
        end

    elseif verb == 'delete' then
        local which = args[2] and args[2]:lower() == 'all' and 'all' or idOf(args[2])
        if which == nil then
            say('delete needs an id or all')
            return
        end
        ask(('delete %s'):format(tostring(which)))

    elseif verb == 'display' then
        local id = idOf(args[2])
        local mode = args[3] and S.display(args[3]) or nil
        if id == nil or mode == nil then
            say('usage: brprop display <id> <pickup|static>')
            return
        end
        ask(('display %d %s'):format(id, mode))

    elseif verb == 'where' then
        local id = idOf(args[2])
        local r = id and recs[id] or nil
        if not r then
            say(('there is no prop #%s'):format(tostring(args[2])))
            return
        end
        -- MID-EDIT, THE PREVIEW: that is where the prop is on screen.
        local t = (E and E.id == id) and E.t or r
        print(S.whereLine({ model = r.model, display = r.display, x = t.x, y = t.y,
            z = t.z, pitch = t.pitch, roll = t.roll, yaw = t.yaw }))

    elseif verb == 'edit' then
        local id = nil
        if args[2] ~= nil then
            id = idOf(args[2])
            if id == nil then
                say('usage: brprop edit [id]')
                return
            end
        end
        askEdit(id)

    elseif verb == 'save' then
        ask('save')

    elseif verb == 'load' then
        ask('load')

    else
        print(USAGE)
    end
end, false)

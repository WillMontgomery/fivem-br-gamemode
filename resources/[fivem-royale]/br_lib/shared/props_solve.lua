-- Dev props (#384): the pure half. No natives, no state of its own.
--
-- THE SERVER OWNS EVERY PROP; this file is the rules it owns them by, and the
-- arithmetic a client previews with. Both sides load it, so the client refuses
-- the same bad name or bad number the server would, before it goes over the
-- wire, and the server is still the one that decides.
--
-- WHAT IS HERE, IN THE ORDER A PROP MEETS IT:
--
--   modelName / display / transform   is this request well formed at all
--   placeOk                           is it somewhere a prop may be
--   move / resetRotation              one edit-mode step, camera-relative
--   repeatFire / sendDue              when a held key steps, when to send
--   hover                             the loot pickup's look, on a prop
--   fromRow / row / whereLine         the save file and the paste line
--   num                               a number on a brpropsv command line
--
-- Every function takes its config as an argument rather than reading
-- BR.Config at load, so a test can hand it any numbers and this file can be
-- loaded in any order.

BR = BR or {}
BR.PropSolve = BR.PropSolve or {}

local S = BR.PropSolve

S.PICKUP = 'pickup'
S.STATIC = 'static'

--- A real number: not nil, not a string, not NaN, not infinite.
--- @param v any
--- @return boolean
local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end
S.finite = finite

--- An angle in degrees, folded into (-180, 180].
---
--- ONE SPELLING FOR EVERY ANGLE THE SERVER STORES, so a yaw of 370 and a yaw of
--- 10 are the same record and the `where` line never prints 2,160 degrees after
--- a long hold.
--- @param a number
--- @return number
function S.angle(a)
    local r = a % 360.0
    if r > 180.0 then r = r - 360.0 end
    return r
end

--- A model name a prop may be built from, lower-cased, or nil and why.
---
--- LETTERS, DIGITS, `_` AND `-`, because that is what an archetype name is and
--- because the string travels to every client, into a JSON file and into a
--- console line. Anything else is not a model.
--- @param s any
--- @param cfg table  BR.Config.Props
--- @return string|nil name
--- @return string|nil why
function S.modelName(s, cfg)
    if type(s) ~= 'string' or s == '' then return nil, 'no model name given' end
    local maxLen = cfg.nameMaxLen or 64
    if #s > maxLen then
        return nil, ('a model name is at most %d characters'):format(maxLen)
    end
    if not s:match('^[A-Za-z0-9_%-]+$') then
        return nil, 'a model name is letters, digits, _ and - only'
    end
    return s:lower(), nil
end

--- A display mode, or nil and why. Nil in is the default, `pickup`.
--- @param s any
--- @return string|nil
--- @return string|nil why
function S.display(s)
    if s == nil then return S.PICKUP, nil end
    if type(s) ~= 'string' then return nil, 'display is pickup or static' end
    local m = s:lower()
    if m == S.PICKUP or m == S.STATIC then return m, nil end
    return nil, 'display is pickup or static'
end

--- Position and rotation off a request, checked and normalised, or nil and why.
---
--- POSITION IS REQUIRED, ROTATION DEFAULTS TO ZERO. A missing x is a broken
--- request; a missing roll is a prop that has never been rolled.
--- @param d table
--- @param cfg table  BR.Config.Props
--- @return table|nil { x, y, z, pitch, roll, yaw }
--- @return string|nil why
function S.transform(d, cfg)
    if type(d) ~= 'table' then return nil, 'no position given' end
    local x, y, z = d.x, d.y, d.z
    if not (finite(x) and finite(y) and finite(z)) then
        return nil, 'the position is not three real numbers'
    end
    local pitch, roll, yaw = d.pitch or 0.0, d.roll or 0.0, d.yaw or 0.0
    if not (finite(pitch) and finite(roll) and finite(yaw)) then
        return nil, 'the rotation is not three real numbers'
    end
    local w = cfg.world or {}
    local xy = w.xy or 10000.0
    if math.abs(x) > xy or math.abs(y) > xy
       or z < (w.zMin or -500.0) or z > (w.zMax or 3000.0) then
        return nil, 'the position is outside the world'
    end
    return {
        x = x, y = y, z = z,
        pitch = S.angle(pitch), roll = S.angle(roll), yaw = S.angle(yaw),
    }, nil
end

--- May a prop be at `t`? Inside the playable boundary, or near whoever asked.
---
--- THE TWO HALVES ARE AN `or` ON PURPOSE. The island's outline is where props
--- belong, and the warmup pad and the lobby are outside it -- so a dev standing
--- there can still place something in front of himself, and nobody can put a
--- prop at the far end of the map from the lobby by typing numbers.
---
--- `inBounds` IS PASSED IN (BR.Config.Map.InBounds in the game), so this file
--- needs no map and a test can draw any outline it likes.
--- @param t table   { x, y, z }
--- @param near table|nil  the requester's position, or nil when unknown
--- @param inBounds function|nil  (x, y) -> boolean
--- @param cfg table  BR.Config.Props
--- @return boolean ok
--- @return string|nil why
function S.placeOk(t, near, inBounds, cfg)
    if inBounds ~= nil and inBounds(t.x, t.y) == true then return true, nil end
    local r = cfg.nearM or 150.0
    -- NO type(near) == 'table' TEST: in CfxLua GetEntityCoords answers a
    -- vector3, whose type() is 'vector3', and a table-only guard refused every
    -- real position (server/fuel.lua records the same mistake). The field reads
    -- work on a vector and on a plain table alike.
    if near ~= nil and type(near) ~= 'number' and type(near) ~= 'string'
       and type(near) ~= 'boolean'
       and finite(near.x) and finite(near.y) and finite(near.z) then
        local dx, dy, dz = t.x - near.x, t.y - near.y, t.z - near.z
        if dx * dx + dy * dy + dz * dz <= r * r then return true, nil end
    end
    return false, ('outside the playable area and more than %d m from you')
        :format(math.floor(r))
end

--- The step in force: metres and degrees.
--- @param coarse boolean
--- @param cfg table
--- @return number m, number deg
function S.stepSize(coarse, cfg)
    local s = cfg.step or {}
    local which = coarse and (s.coarse or {}) or (s.fine or {})
    return which.m or (coarse and 0.10 or 0.01), which.deg or (coarse and 15.0 or 1.0)
end

--- The edit-mode actions, in the order the readout lists them.
S.ACTIONS = {
    'fwd', 'back', 'left', 'right', 'up', 'down',
    'yawLeft', 'yawRight', 'pitchUp', 'pitchDown', 'rollLeft', 'rollRight',
}

--- One edit step. Returns a NEW transform; `t` is not touched.
---
--- ═══ FORWARD IS WHERE THE CAMERA LOOKS, FLATTENED ONTO THE GROUND ═══
---
--- `camYaw` is the gameplay camera's yaw in degrees (GetGameplayCamRot(2).z),
--- which is a GTA heading: 0 is north (+y) and it grows COUNTER-clockwise, so
--- 90 is west. Forward is therefore (-sin h, cos h) and right is (cos h, sin h)
--- -- at 0 that is north and east, at 90 west and north. W pushes the prop away
--- from the camera and D to its right whichever way the player has turned the
--- view, and neither ever changes the height: up and down are their own keys.
---
--- YAW LEFT IS +, for the same reason: a heading that grows counter-clockwise
--- turns left as it grows.
--- @param t table
--- @param action string  one of S.ACTIONS
--- @param camYaw number  degrees
--- @param coarse boolean
--- @param cfg table
--- @return table
function S.move(t, action, camYaw, coarse, cfg)
    local m, deg = S.stepSize(coarse, cfg)
    local n = {
        x = t.x, y = t.y, z = t.z,
        pitch = t.pitch or 0.0, roll = t.roll or 0.0, yaw = t.yaw or 0.0,
    }
    local h = math.rad(camYaw or 0.0)
    local fx, fy = -math.sin(h), math.cos(h)
    local rx, ry = math.cos(h), math.sin(h)

    if action == 'fwd' then
        n.x, n.y = n.x + fx * m, n.y + fy * m
    elseif action == 'back' then
        n.x, n.y = n.x - fx * m, n.y - fy * m
    elseif action == 'right' then
        n.x, n.y = n.x + rx * m, n.y + ry * m
    elseif action == 'left' then
        n.x, n.y = n.x - rx * m, n.y - ry * m
    elseif action == 'up' then
        n.z = n.z + m
    elseif action == 'down' then
        n.z = n.z - m
    elseif action == 'yawLeft' then
        n.yaw = S.angle(n.yaw + deg)
    elseif action == 'yawRight' then
        n.yaw = S.angle(n.yaw - deg)
    elseif action == 'pitchUp' then
        n.pitch = S.angle(n.pitch + deg)
    elseif action == 'pitchDown' then
        n.pitch = S.angle(n.pitch - deg)
    elseif action == 'rollRight' then
        n.roll = S.angle(n.roll + deg)
    elseif action == 'rollLeft' then
        n.roll = S.angle(n.roll - deg)
    end
    return n
end

--- The same position, with no rotation at all.
--- @param t table
--- @return table
function S.resetRotation(t)
    return { x = t.x, y = t.y, z = t.z, pitch = 0.0, roll = 0.0, yaw = 0.0 }
end

--- Does a held key step on this frame? `st` is that key's own memory.
---
--- A TAP IS EXACTLY ONE STEP: the press steps at once and arms a delay, so a
--- quick press never repeats. Held past `repeatDelayMs` it steps every
--- `repeatMs`, which is a speed in steps per second rather than per frame --
--- the same hold moves the same distance on any machine.
---
--- A FRAME HITCH DOES NOT BURST. After a long frame the next step is one
--- interval from NOW rather than every interval that was missed, so a stall
--- cannot fling a prop across the room.
--- @param st table   { at = number|nil }
--- @param down boolean
--- @param now number  ms
--- @param cfg table
--- @return boolean
function S.repeatFire(st, down, now, cfg)
    if not down then
        st.at = nil
        return false
    end
    if st.at == nil then
        st.at = now + (cfg.repeatDelayMs or 250)
        return true
    end
    if now >= st.at then
        local every = cfg.repeatMs or 50
        st.at = st.at + every
        if st.at <= now then st.at = now + every end
        return true
    end
    return false
end

--- Is the next edit update due? At most `hz` a second.
--- @param last number|nil  when the last one went, ms
--- @param now number
--- @param hz number
--- @return boolean
function S.sendDue(last, now, hz)
    if last == nil then return true end
    return (now - last) >= (1000.0 / math.max(hz or 10, 1))
end

--- Smoothstep, so a rise starts and ends at rest. client/loot.lua's own ease.
--- @param t number
--- @return number
function S.ease(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

--- Move `v` toward `to` by at most `step`. client/loot.lua's own approach.
local function approach(v, to, step)
    if v < to then return math.min(to, v + step) end
    return math.max(to, v - step)
end

--- One frame of the PICKUP look, off the loot's own numbers.
---
--- ═══ THE LOOT PICKUP'S ANIMATION, NUMBER FOR NUMBER ═══
---
--- client/loot.lua's animate() is the look the owner asked for ("something
--- akin to our pickups where it hovers/bobs/rotates when close"), and `L` IS
--- BR.Config.Loot -- promptDistance, hoverRiseMs, hoverFallMs, hoverHeight,
--- bobAmplitude, bobPeriodMs, spinDegPerSec and hoverPitch, read here at call
--- time. Inside prompt range the lift eases toward 1 over hoverRiseMs and back
--- to 0 over hoverFallMs; the height, the bob and the spin all scale with the
--- eased lift, so a prop at rest is perfectly still; and the pitch tilts by
--- hoverPitch from the prop's OWN pitch with the lift (a rifle rests flat, so
--- for loot that is the same thing; a prop placed pitched keeps its pitch).
--- The frame step is clamped to 100 ms, as loot.render clamps it, so a hitch
--- does not jump the lift and the spin in one frame.
---
--- WHY A TWIN RATHER THAN A CALL. animate() is a local in loot.lua threaded
--- through a loot entry's arrival arc, its scale and its settle-once ground
--- probe, none of which a prop has; exporting it would make every loot change a
--- prop change. The numbers are shared, which is the half that keeps the two
--- looking alike, and tools/test_props.lua pins that this reads them.
---
--- ═══ ONE DIFFERENCE, AND IT IS THE ISSUE'S ═══
---
--- A loot item comes to rest at whatever angle its spin left it. A prop's own
--- rotation IS its resting orientation, so the spin is held as an offset on its
--- yaw and unwinds as the prop settles: while falling the offset shrinks in
--- proportion to the lift, so it lands at exactly its recorded yaw -- never
--- more than half a turn back, and never a snap.
--- @param st table  { lift, off } -- this prop's own memory
--- @param restPitch number  the prop's recorded pitch
--- @param d2 number  squared distance from the player
--- @param dt number  ms since the last frame
--- @param now number  ms
--- @param L table  BR.Config.Loot
--- @return number zOff  metres above the recorded z
--- @return number pitch
--- @return number yawOff  degrees added to the recorded yaw
--- @return number k  the eased lift, 0 at rest
function S.hover(st, restPitch, d2, dt, now, L)
    dt = math.min(math.max(dt or 0.0, 0.0), 100.0)
    local pr = L.promptDistance or 2.5
    local want = (d2 <= pr * pr) and 1.0 or 0.0
    local lift = st.lift or 0.0
    local ms = (want > lift) and (L.hoverRiseMs or 320) or (L.hoverFallMs or 420)
    local before = S.ease(lift)
    st.lift = approach(lift, want, dt / math.max(ms, 1))
    local k = S.ease(st.lift)

    if want > 0.0 then
        st.off = S.angle((st.off or 0.0) + (L.spinDegPerSec or 55.0) * k * (dt / 1000.0))
    elseif before > 0.0 then
        st.off = (st.off or 0.0) * (k / before)
    else
        st.off = 0.0
    end

    local bob = math.sin(now / math.max(L.bobPeriodMs or 1900, 1) * math.pi * 2.0)
              * (L.bobAmplitude or 0.06) * k
    local rp = restPitch or 0.0
    local pitch = rp + (L.hoverPitch or 0.0) * k
    return k * (L.hoverHeight or 0.55) + bob, pitch, st.off, k
end

--- A record off one saved row, checked by the same rules a request is, or nil
--- and why. Positions are held to the WORLD box only: the file is the server's
--- own, written by `save`, and the dev loading it may be standing anywhere.
--- @param row table
--- @param cfg table
--- @return table|nil
--- @return string|nil why
function S.fromRow(row, cfg)
    if type(row) ~= 'table' then return nil, 'not a row' end
    local model, why = S.modelName(row.model, cfg)
    if not model then return nil, why end
    local display, why2 = S.display(row.display)
    if not display then return nil, why2 end
    local t, why3 = S.transform(row, cfg)
    if not t then return nil, why3 end
    t.model, t.display = model, display
    return t, nil
end

--- A record as it goes over the wire and into the save file: a copy, so the
--- receiver can never reach into the server's own table.
--- @param r table
--- @return table
function S.row(r)
    return {
        id = r.id, model = r.model, display = r.display,
        x = r.x, y = r.y, z = r.z, pitch = r.pitch, roll = r.roll, yaw = r.yaw,
    }
end

--- The ready-to-paste Lua line `/brprop where` prints.
---
--- THE SAVE FILE'S OWN FIELDS AND NOTHING ELSE. No id, because an id is this
--- session's; the line is for putting the placement into code or config, where
--- it outlives every id.
--- @param r table
--- @return string
function S.whereLine(r)
    return ("{ model = '%s', display = '%s', x = %.3f, y = %.3f, z = %.3f, "
        .. 'pitch = %.1f, roll = %.1f, yaw = %.1f },')
        :format(r.model, r.display, r.x, r.y, r.z, r.pitch, r.roll, r.yaw)
end

--- A number as it goes into a `brpropsv` command line, and back out of one.
---
--- EVERY DIGIT A DOUBLE HAS. The confirm and the spawn reach the server as
--- console text rather than as a table, and a position rounded on the way --
--- '%.2f' would do it to the centimeter -- would put the prop a little off from
--- the preview that was confirmed. '%.17g' reads back with tonumber() as the
--- same double, bit for bit.
--- @param v number
--- @return string
function S.num(v)
    return ('%.17g'):format(v)
end

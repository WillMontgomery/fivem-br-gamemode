-- Dev props (#384), server half: the one place a prop exists.
--
-- Owner, 2026-10-03: "Be sure the server spawns it since clients can't. Give me
-- tools to spawn objects by name and I'll stream them."
--
-- ═══ THE SERVER OWNS THE RECORD, AND NOBODY OWNS AN ENTITY ═══
--
-- A prop here is a RECORD -- id, model name, position, pitch/roll/yaw and a
-- display mode -- and this file is the only thing that creates, changes or
-- deletes one. Every client draws its own local, non-networked copy from the
-- record, exactly the way br_core/client/loot.lua draws loot. That is the
-- repo's rule for every object it makes, and here it is also the only shape
-- that works: `sv_entityLockdown relaxed` refuses a client-created networked
-- entity outright (see client/airdrop.lua's note), and a networked object
-- cannot be bobbed smoothly by more than one machine anyway.
--
-- So clients never decide anything about a prop. They ASK -- spawn, move,
-- delete, display, save, load -- and this file checks the asker, checks the
-- request, applies it and tells everybody.
--
-- ═══ THE DOOR IS BR.Admin.devTrusted, NOT DEV MODE ═══
--
-- Dev mode is a fact about how the process was started and every connected
-- client passes it (#232; tools/check_net_gates.lua). Every handler below asks
-- BR.Admin.devTrusted -- dev mode AND a console grant -- before it reads its
-- payload, and a refusal there goes to THIS console rather than over the wire,
-- for the leak reason server/loot.lua's LOOT_DEV note gives. Every other
-- refusal is the trusted requester's own business and is answered on their F8.
--
-- ═══ LOBBY, WARMUP, MATCH: NONE OF IT MATTERS ═══
--
-- These are dev props. They persist until somebody deletes them or br_core
-- restarts, and `/brprop save` / `load` carry them across the restart.

BR = BR or {}
BR.Props = BR.Props or {}

local S = BR.PropSolve

--- [id] = { id, model, display, x, y, z, pitch, roll, yaw }
local props = {}
local nextId = 1

--- [src] = GetGameTimer() of the last edit update taken from that player.
local lastMoveAt = {}

--- @return table BR.Config.Props, read at call time
local function cfg() return BR.Config.Props end

--- How many props exist.
--- @return integer
function BR.Props.count()
    local n = 0
    for _ in pairs(props) do n = n + 1 end
    return n
end

--- Every record, as copies, in id order.
--- @return table
function BR.Props.list()
    local out = {}
    for _, r in pairs(props) do out[#out + 1] = S.row(r) end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- One record, as a copy, or nil.
--- @param id integer
--- @return table|nil
function BR.Props.get(id)
    local r = props[id]
    return r and S.row(r) or nil
end

-- ------------------------------------------------------------------- wire ---

--- The answer to one request, on the requester's F8 and on this console.
---
--- THIS CONSOLE TOO, because a prop placed on a shared dev box is a change to
--- the world everybody on it sees, and the console is the record of who did it.
--- @param src integer
--- @param text string
local function tell(src, text)
    print(('[br_core] brprop (client %s): %s'):format(tostring(src), text))
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent(BR.Net.PROP_RESULT, src, text)
    end
end

--- The whole list, to one client or to everybody.
--- @param target integer  a server id, or -1
local function sendAll(target)
    TriggerClientEvent(BR.Net.PROP_SYNC, target, { full = true, props = BR.Props.list() })
end

--- One changed record, to everybody.
--- @param r table
local function sendSet(r)
    TriggerClientEvent(BR.Net.PROP_SYNC, -1, { set = { S.row(r) } })
end

--- Deleted ids, to everybody.
--- @param ids table
local function sendGone(ids)
    TriggerClientEvent(BR.Net.PROP_SYNC, -1, { gone = ids })
end

-- ------------------------------------------------------------------- rules ---

--- Where the requester is, as this server sampled it -- never as they said.
--- @param src integer
--- @return table|nil
local function posOf(src)
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    return e and e.pos or nil
end

--- The surveyed playable boundary, or nothing when it is not loaded.
---
--- NOT BR.Config.Map.InBounds HANDED OVER BARE: that answers TRUE for
--- everything when shared/polygon.lua is missing, which is the right default
--- for a loot layout and the wrong one for a gate. Here a missing outline means
--- only the `near the requester` half can say yes.
--- @param x number @param y number
--- @return boolean
local function inBounds(x, y)
    local M = BR.Config.Map
    if not (M and M.InBounds and M.Boundary and BR.PointInPolygon) then return false end
    return M.InBounds(x, y) == true
end

--- Ask the dev gate, and say on THIS console when it closes.
--- @param src integer
--- @param verb string
--- @return boolean
local function allowed(src, verb)
    local ok, why = false, 'no-admin-module'
    if BR.Admin and BR.Admin.devTrusted then
        ok, why = BR.Admin.devTrusted(src)
    end
    if ok ~= true then
        -- NOT PRINTED WHEN DEV MODE IS OFF: on a public server any client can
        -- send these events, and a console line each would let one fill the
        -- console. Off a dev box the answer is simply no.
        if why ~= 'dev-mode-off' then
            print(('^3[br_core] brprop %s (client %s) refused: %s^7')
                :format(verb, tostring(src), tostring(why)))
        end
        return false
    end
    return true
end

-- ----------------------------------------------------------------- verbs ---
--
-- EACH TAKES AN ALREADY-AUTHORIZED src. The net handlers at the bottom are the
-- doors and ask BR.Admin.devTrusted first; these are what they open onto, and
-- they are public so tools/test_props.lua can drive every rule directly.

--- Make a prop. Returns the record (a copy) or nil and why.
--- @param src integer
--- @param d table  { model, display, x, y, z, pitch, roll, yaw }
--- @return table|nil
--- @return string|nil why
function BR.Props.create(src, d)
    local P = cfg()
    if type(d) ~= 'table' then return nil, 'no request' end
    local model, why = S.modelName(d.model, P)
    if not model then return nil, why end
    local display, why2 = S.display(d.display)
    if not display then return nil, why2 end
    local t, why3 = S.transform(d, P)
    if not t then return nil, why3 end
    local ok, why4 = S.placeOk(t, posOf(src), inBounds, P)
    if not ok then return nil, why4 end
    if BR.Props.count() >= (P.maxProps or 64) then
        return nil, ('there are already %d props; delete one first')
            :format(P.maxProps or 64)
    end

    local r = {
        id = nextId, model = model, display = display,
        x = t.x, y = t.y, z = t.z, pitch = t.pitch, roll = t.roll, yaw = t.yaw,
    }
    nextId = nextId + 1
    props[r.id] = r
    sendSet(r)
    return S.row(r), nil
end

--- Move or turn a prop. Returns the record (a copy) or nil and why.
---
--- 'too-soon' IS NOT A REFUSAL ANYBODY IS TOLD ABOUT. It is the floor under a
--- client sending faster than sendHz, and the next update carries the same
--- intent; a line per dropped frame would bury the console.
--- @param src integer
--- @param d table  { id, x, y, z, pitch, roll, yaw, final? }
--- @param now integer|nil  ms; defaults to GetGameTimer()
--- @return table|nil
--- @return string|nil why
function BR.Props.move(src, d, now)
    local P = cfg()
    if type(d) ~= 'table' then return nil, 'no request' end
    local r = props[tonumber(d.id) or -1]
    if not r then return nil, ('there is no prop #%s'):format(tostring(d.id)) end

    now = now or GetGameTimer()
    local final = d.final == true
    local last = lastMoveAt[src]
    if not final and last ~= nil and (now - last) < (P.moveMinMs or 50) then
        return nil, 'too-soon'
    end

    local t, why = S.transform(d, P)
    if not t then return nil, why end
    local ok, why2 = S.placeOk(t, posOf(src), inBounds, P)
    if not ok then return nil, why2 end

    lastMoveAt[src] = now
    r.x, r.y, r.z = t.x, t.y, t.z
    r.pitch, r.roll, r.yaw = t.pitch, t.roll, t.yaw
    sendSet(r)
    return S.row(r), nil
end

--- Delete one prop, or every prop with 'all'. Returns how many went, or nil
--- and why.
--- @param which integer|string
--- @return integer|nil
--- @return string|nil why
function BR.Props.remove(which)
    local ids = {}
    if which == 'all' then
        for id in pairs(props) do ids[#ids + 1] = id end
        table.sort(ids)
    else
        local id = tonumber(which)
        if not id or not props[id] then
            return nil, ('there is no prop #%s'):format(tostring(which))
        end
        ids[1] = id
    end
    for i = 1, #ids do props[ids[i]] = nil end
    if #ids > 0 then sendGone(ids) end
    return #ids, nil
end

--- Change how a prop is shown. Returns the record (a copy) or nil and why.
--- @param id integer
--- @param mode string
--- @return table|nil
--- @return string|nil why
function BR.Props.setDisplay(id, mode)
    local r = props[tonumber(id) or -1]
    if not r then return nil, ('there is no prop #%s'):format(tostring(id)) end
    -- NIL IS NOT A MODE HERE. S.display reads nil as the spawn default, which
    -- is right for `spawn <model>` and wrong for `display <id>` with the mode
    -- left off -- that is a typo, not a request for a pickup.
    if mode == nil then return nil, 'display is pickup or static' end
    local display, why = S.display(mode)
    if not display then return nil, why end
    r.display = display
    sendSet(r)
    return S.row(r), nil
end

--- Write every prop to the save file. Returns how many, or nil and why.
--- @return integer|nil
--- @return string|nil why
function BR.Props.save()
    local P = cfg()
    local rows = BR.Props.list()
    local okEnc, body = pcall(json.encode, { v = 1, props = rows })
    if not okEnc or type(body) ~= 'string' then return nil, 'could not encode the props' end
    local res = GetCurrentResourceName()
    local wrote = SaveResourceFile(res, P.saveFile, body, -1)
    -- SaveResourceFile answers a BOOL, compared rather than believed: a 0 here
    -- would otherwise read as a successful save of a file that is not there.
    if wrote ~= true and wrote ~= 1 then
        return nil, ('could not write %s/%s'):format(res, P.saveFile)
    end
    return #rows, nil
end

--- Replace every prop with the save file's. Returns loaded, skipped -- or nil
--- and why, in which case nothing changed.
---
--- ALL OR NOTHING ON THE FILE, ROW BY ROW INSIDE IT. A missing or unreadable
--- file changes nothing, because deleting every prop to then load none would
--- turn a typo into data loss. A file that reads is applied, and each row is
--- held to the same rules a request is; one bad row is skipped and counted
--- rather than costing the rest. Ids are kept, so a `where` line from before the
--- restart still names the same prop -- and a duplicate or missing id gets a
--- fresh one rather than overwriting its neighbour.
--- @return integer|nil loaded
--- @return integer|string skipped, or why
function BR.Props.load()
    local P = cfg()
    local res = GetCurrentResourceName()
    local body = LoadResourceFile(res, P.saveFile)
    if type(body) ~= 'string' or body == '' then
        return nil, ('there is no %s/%s yet (run /brprop save first)'):format(res, P.saveFile)
    end
    local okDec, doc = pcall(json.decode, body)
    if not okDec or type(doc) ~= 'table' or type(doc.props) ~= 'table' then
        return nil, ('%s/%s is not a props file'):format(res, P.saveFile)
    end

    local fresh, pending, kept, skipped = {}, {}, 0, 0
    local maxProps = P.maxProps or 64
    for _, row in ipairs(doc.props) do
        local r = S.fromRow(row, P)
        if not r or kept >= maxProps then
            skipped = skipped + 1
        else
            kept = kept + 1
            local id = type(row.id) == 'number' and math.tointeger(row.id) or nil
            if id and id > 0 and fresh[id] == nil then
                r.id = id
                fresh[id] = r
            else
                pending[#pending + 1] = r
            end
        end
    end

    local top = 0
    for id in pairs(fresh) do if id > top then top = id end end
    for i = 1, #pending do
        top = top + 1
        pending[i].id = top
        fresh[top] = pending[i]
    end

    props = fresh
    nextId = top + 1
    sendAll(-1)
    return BR.Props.count(), skipped
end

-- ------------------------------------------------------------------ doors ---

-- THE LATE JOINER'S COPY, and the restarted br_core's. client/state.lua sends
-- br:ready when a client finishes loading and again on every br_ui or br_core
-- restart, so one answer here covers both -- the same hook server/world.lua,
-- server/community.lua and server/board.lua already hang their pushes on.
-- No gate: the props are drawn for every player, so every player is sent them.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = source
    sendAll(src)
end)

RegisterNetEvent(BR.Net.PROP_SPAWN)
AddEventHandler(BR.Net.PROP_SPAWN, function(d)
    local src = source
    if not allowed(src, 'spawn') then return end
    local r, why = BR.Props.create(src, d)
    if not r then
        tell(src, ('spawn refused: %s'):format(why))
        return
    end
    tell(src, ('spawned #%d %s (%s) at %.2f, %.2f, %.2f')
        :format(r.id, r.model, r.display, r.x, r.y, r.z))
end)

RegisterNetEvent(BR.Net.PROP_MOVE)
AddEventHandler(BR.Net.PROP_MOVE, function(d)
    local src = source
    if not allowed(src, 'move') then return end
    local r, why = BR.Props.move(src, d)
    if not r then
        if why == 'too-soon' then return end
        tell(src, ('move refused: %s'):format(why))
        -- THE REQUESTER GETS THE RECORD AS IT STANDS, so a client that
        -- previewed something refused is put back where the server says.
        local cur = type(d) == 'table' and BR.Props.get(tonumber(d.id) or -1) or nil
        if cur then TriggerClientEvent(BR.Net.PROP_SYNC, src, { set = { cur } }) end
        return
    end
    if type(d) == 'table' and d.final == true then
        tell(src, ('#%d placed at %.2f, %.2f, %.2f  pitch %.1f roll %.1f yaw %.1f')
            :format(r.id, r.x, r.y, r.z, r.pitch, r.roll, r.yaw))
    end
end)

RegisterNetEvent(BR.Net.PROP_DELETE)
AddEventHandler(BR.Net.PROP_DELETE, function(d)
    local src = source
    if not allowed(src, 'delete') then return end
    local which = type(d) == 'table' and d.id or nil
    local n, why = BR.Props.remove(which)
    if not n then
        tell(src, ('delete refused: %s'):format(why))
        return
    end
    if which == 'all' then
        tell(src, ('deleted every prop (%d)'):format(n))
    else
        tell(src, ('deleted #%s'):format(tostring(which)))
    end
end)

RegisterNetEvent(BR.Net.PROP_DISPLAY)
AddEventHandler(BR.Net.PROP_DISPLAY, function(d)
    local src = source
    if not allowed(src, 'display') then return end
    if type(d) ~= 'table' then return end
    local r, why = BR.Props.setDisplay(d.id, d.display)
    if not r then
        tell(src, ('display refused: %s'):format(why))
        return
    end
    tell(src, ('#%d is now shown as %s'):format(r.id, r.display))
end)

RegisterNetEvent(BR.Net.PROP_SAVE)
AddEventHandler(BR.Net.PROP_SAVE, function()
    local src = source
    if not allowed(src, 'save') then return end
    local n, why = BR.Props.save()
    if not n then
        tell(src, ('save failed: %s'):format(why))
        return
    end
    tell(src, ('saved %d prop(s) to %s/%s')
        :format(n, GetCurrentResourceName(), BR.Config.Props.saveFile))
end)

RegisterNetEvent(BR.Net.PROP_LOAD)
AddEventHandler(BR.Net.PROP_LOAD, function()
    local src = source
    if not allowed(src, 'load') then return end
    local n, skipped = BR.Props.load()
    if not n then
        tell(src, ('load failed: %s'):format(skipped))
        return
    end
    tell(src, ('loaded %d prop(s)%s'):format(n,
        skipped > 0 and (', skipped %d bad row(s)'):format(skipped) or ''))
end)

AddEventHandler('playerDropped', function()
    lastMoveAt[source] = nil
end)

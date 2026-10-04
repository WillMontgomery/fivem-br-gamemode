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
-- delete, display, save, load -- and this file checks the request, applies it
-- and tells everybody.
--
-- ═══ A STANDARD DEV COMMAND, AND ONE NET EVENT THAT IS NOT ONE ═══
--
-- Owner, 2026-10-03, after `brprop spawn` was refused `not-admin` in a
-- playtest: "please fix it in the repo, so it's a standard dev command". The
-- requests used to be net events behind BR.Admin.devTrusted, which also wants
-- a grants row carrying the `view` scope -- and nothing has written scopes
-- since Ringmaster dropped them on 2026-08-29.
--
-- Every request is now the server command `brpropsv`, so it goes through
-- br_lib/shared/devgate.lua's RegisterCommand wrap: dev mode, and nothing
-- else, exactly as every other dev command. The player never types it.
-- client/props.lua's `brprop` does the parts only a client can (the model's
-- CD image, the ground in front of him, the nearest prop, the edit keys) and
-- runs `brpropsv` with ExecuteCommand. A command the client does not have is
-- sent to the server as msgServerCommand and run there as `player.<id>`, with
-- `source` the player's server id (citizenfx/fivem,
-- ResourceNetBindings.cpp's FallbackEvent and ServerCommandPacketHandler.cpp).
-- REGISTERED UNRESTRICTED ON PURPOSE: restricted would ask that player for the
-- `command.brpropsv` ACE, which is the grant this change takes away.
--
-- The 10 Hz edit stream cannot be a command -- FiveM rate-limits a client's
-- server commands at 7 a second -- so it stays a net event, and a net event
-- may not decide anything on dev mode (#232; tools/check_net_gates.lua). It is
-- authorized by an EDIT SESSION instead: `brpropsv edit begin <id>` opens one
-- for that player and that prop, and the stream is taken from nobody else and
-- for nothing else. Confirm, cancel, a disconnect, the prop being deleted, a
-- load, an idle timeout and another `edit begin` each close it.
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

--- [src] = { id, orig = { x, y, z, pitch, roll, yaw }, at }
---
--- One per player, and the only thing the edit stream asks. `orig` is the
--- record as it stood at `edit begin`, which is what a cancel puts back; `at`
--- is when the server last heard from the session, for the idle timeout.
local sessions = {}

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

--- The prop this player's open edit session is on, or nil.
--- @param src integer
--- @return integer|nil
function BR.Props.editing(src)
    local s = sessions[src]
    return s and s.id or nil
end

-- ------------------------------------------------------------------- wire ---

--- The answer to one request, on the requester's F8 and on this console.
---
--- THIS CONSOLE TOO, because a prop placed on a shared dev box is a change to
--- the world everybody on it sees, and the console is the record of who did it.
---
--- THE F8 LINE IS AN EVENT, NOT THE PRINT. FiveM does capture what a command
--- run by a client prints and send it back as `__cfx_internal:serverPrint` --
--- but only the stock chat resource listens for that, and this server does
--- not run it.
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

-- -------------------------------------------------------------- sessions ---

--- Close one player's edit session, and tell them when the server is the one
--- closing it. Returns the session that was open, or nil.
---
--- NOT TOLD when they asked for it (confirm, cancel), when they left, or when
--- the prop was deleted -- the client ends its edit on the `gone` it is sent
--- anyway, and says so.
--- @param src integer
--- @param why string|nil  the reason to send them, or nil to send nothing
--- @return table|nil
local function closeSession(src, why)
    local s = sessions[src]
    if not s then return nil end
    sessions[src] = nil
    if why and type(src) == 'number' and src > 0 then
        TriggerClientEvent(BR.Net.PROP_EDIT, src, { id = s.id, open = false, why = why })
    end
    return s
end

--- Close every session that has been idle longer than editIdleMs.
--- @param now integer|nil  ms; defaults to GetGameTimer()
--- @return integer how many closed
function BR.Props.expireSessions(now)
    now = now or GetGameTimer()
    local idle = cfg().editIdleMs or 600000
    local stale = {}
    for src, s in pairs(sessions) do
        if now - s.at > idle then stale[#stale + 1] = src end
    end
    for i = 1, #stale do
        closeSession(stale[i], ('idle for %d s'):format(math.floor(idle / 1000)))
    end
    return #stale
end

-- ----------------------------------------------------------------- verbs ---
--
-- EACH TAKES THE REQUESTER'S src, ALREADY PAST THE DEV GATE. The command at the
-- bottom is the door; these are what it opens onto, and they are public so
-- tools/test_props.lua can drive every rule directly.

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
---
--- `final` IS FOR THE CONFIRM COMMAND. The stream never carries it through --
--- see BR.Props.stream -- so a client cannot use it to skip the floor.
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

--- Open an edit session: this player, this prop. Returns the prop's id, or
--- nil and why.
---
--- ANOTHER BEGIN FROM THE SAME PLAYER REPLACES THEIR OLD SESSION, wherever it
--- was. Their client refuses a second edit while one is open, so a begin with
--- one already here means that client lost its edit -- br_core restarted under
--- it -- and the old session is nobody's any more. The prop it was on stays
--- where the last update left it.
---
--- ANOTHER PLAYER'S SESSION ON THE SAME PROP IS A REFUSAL: two streams on one
--- record would each undo the other ten times a second.
--- @param src integer
--- @param id integer|nil
--- @param now integer|nil  ms; defaults to GetGameTimer()
--- @return integer|nil
--- @return string|nil why
function BR.Props.editBegin(src, id, now)
    now = now or GetGameTimer()
    if type(src) ~= 'number' or src <= 0 then
        return nil, 'edit needs a player; run brprop edit in game'
    end
    local r = props[tonumber(id) or -1]
    if not r then return nil, ('there is no prop #%s'):format(tostring(id)) end
    BR.Props.expireSessions(now)
    for other, s in pairs(sessions) do
        if other ~= src and s.id == r.id then
            return nil, ('client %s is editing #%d'):format(tostring(other), r.id)
        end
    end
    closeSession(src, nil)
    sessions[src] = {
        id = r.id, at = now,
        orig = { x = r.x, y = r.y, z = r.z, pitch = r.pitch, roll = r.roll, yaw = r.yaw },
    }
    return r.id, nil
end

--- One update of the edit stream. Returns the record (a copy), or nil and why.
---
--- THE SESSION IS THE WHOLE DOOR. No session, or a session on another prop, is
--- 'no-session' -- dropped without a word, here or on the wire, because any
--- client can send this event and a line each would let one fill the console.
--- Only inside a session does anything else get asked.
--- @param src integer
--- @param d table  { id, x, y, z, pitch, roll, yaw }
--- @param now integer|nil  ms; defaults to GetGameTimer()
--- @return table|nil
--- @return string|nil why
function BR.Props.stream(src, d, now)
    local s = sessions[src]
    if s == nil or type(d) ~= 'table' or tonumber(d.id) ~= s.id then
        return nil, 'no-session'
    end
    now = now or GetGameTimer()
    local r, why = BR.Props.move(src, {
        id = s.id, x = d.x, y = d.y, z = d.z, pitch = d.pitch, roll = d.roll, yaw = d.yaw,
    }, now)
    if r then s.at = now end
    return r, why
end

--- End this player's edit session. `how` is 'confirm', with the transform in
--- `d`, or 'cancel'. Returns the record as it now stands (a copy), or nil and
--- why.
---
--- THE SESSION CLOSES EITHER WAY, a refused confirm included: the client has
--- already ended its edit, so a session left open would be one nobody uses.
---
--- A CANCEL PUTS BACK THE SERVER'S OWN COPY of the record from `edit begin`,
--- unchecked -- it was a record, so it was placeable -- rather than a position
--- the client sends. That is what lets a cancel restore a prop the player has
--- since walked far away from.
--- @param src integer
--- @param id integer|nil  the id the client means; must be the session's
--- @param how string  'confirm' | 'cancel'
--- @param d table|nil  { x, y, z, pitch, roll, yaw } for a confirm
--- @param now integer|nil  ms; defaults to GetGameTimer()
--- @return table|nil
--- @return string|nil why
function BR.Props.editEnd(src, id, how, d, now)
    local s = sessions[src]
    if not s then return nil, 'you have no open edit' end
    if tonumber(id) ~= s.id then
        return nil, ('your open edit is #%d, not #%s'):format(s.id, tostring(id))
    end
    closeSession(src, nil)
    local r = props[s.id]
    if not r then return nil, ('there is no prop #%d'):format(s.id) end

    if how == 'cancel' then
        local o = s.orig
        r.x, r.y, r.z = o.x, o.y, o.z
        r.pitch, r.roll, r.yaw = o.pitch, o.roll, o.yaw
        sendSet(r)
        return S.row(r), nil
    end

    d = type(d) == 'table' and d or {}
    return BR.Props.move(src, {
        id = s.id, x = d.x, y = d.y, z = d.z, pitch = d.pitch, roll = d.roll, yaw = d.yaw,
        final = true,
    }, now)
end

--- Delete one prop, or every prop with 'all'. Returns how many went, or nil
--- and why. An edit session on a deleted prop closes with it.
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
    local gone = {}
    for i = 1, #ids do
        props[ids[i]] = nil
        gone[ids[i]] = true
    end
    local orphaned = {}
    for src, s in pairs(sessions) do
        if gone[s.id] then orphaned[#orphaned + 1] = src end
    end
    for i = 1, #orphaned do closeSession(orphaned[i], nil) end
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
---
--- EVERY EDIT SESSION CLOSES, AND ITS PLAYER IS TOLD: an id that survives the
--- load may be a different prop now, and the edit was of the old one.
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

    local editors = {}
    for src in pairs(sessions) do editors[#editors + 1] = src end
    for i = 1, #editors do closeSession(editors[i], 'the props were reloaded') end

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

-- THE EDIT STREAM. Asks the session and nothing else -- see BR.Props.stream.
-- A refusal inside a session (out of bounds, a broken number) is the editor's
-- own business: they hear why, and get the record as it stands, so a preview
-- the server refused is put back where the server says.
RegisterNetEvent(BR.Net.PROP_MOVE)
AddEventHandler(BR.Net.PROP_MOVE, function(d)
    local src = source
    local r, why = BR.Props.stream(src, d)
    if r or why == 'no-session' or why == 'too-soon' then return end
    tell(src, ('move refused: %s'):format(why))
    local cur = type(d) == 'table' and BR.Props.get(tonumber(d.id) or -1) or nil
    if cur then TriggerClientEvent(BR.Net.PROP_SYNC, src, { set = { cur } }) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastMoveAt[src] = nil
    closeSession(src, nil)
end)

-- A session nobody has touched for editIdleMs closes on its own. Guarded: the
-- scheduler is br_lib/shared/sched.lua, and a test that loads this file alone
-- calls BR.Props.expireSessions itself.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(5000, 'props.sessions', function()
        BR.Props.expireSessions(GetGameTimer())
    end)
end

-- --------------------------------------------------------------- command ---

local USAGE = 'usage: brpropsv spawn <model> <pickup|static> <x> <y> <z> [yaw] '
    .. '| delete <id|all> | display <id> <pickup|static> | save | load '
    .. '| edit begin <id> | edit confirm <id> <x> <y> <z> <pitch> <roll> <yaw> '
    .. '| edit cancel <id>  (players type brprop, which runs this)'

--- A command-line number, or the text itself when it is not one -- which
--- S.transform then refuses by name rather than reading as "missing".
--- @param s string|nil
--- @return number|string|nil
local function numArg(s)
    if s == nil then return nil end
    return tonumber(s) or s
end

--- @param s any
--- @return integer|nil
local function idOf(s)
    local n = tonumber(s)
    if n == nil then return nil end
    return math.tointeger(n)
end

--- @param args table @param from integer  index of x
--- @return table { x, y, z, pitch, roll, yaw }
local function transformArgs(args, from)
    return {
        x = numArg(args[from]), y = numArg(args[from + 1]), z = numArg(args[from + 2]),
        pitch = numArg(args[from + 3]), roll = numArg(args[from + 4]), yaw = numArg(args[from + 5]),
    }
end

--- `brpropsv edit begin|confirm|cancel <id> ...`
--- @param src integer @param args table
local function editVerb(src, args)
    local step, id = args[2] and args[2]:lower() or nil, idOf(args[3])
    if step == 'begin' then
        local opened, why = BR.Props.editBegin(src, id)
        if not opened then
            tell(src, ('edit refused: %s'):format(why))
            if type(src) == 'number' and src > 0 then
                TriggerClientEvent(BR.Net.PROP_EDIT, src, { id = id, open = false })
            end
            return
        end
        print(('[br_core] brprop (client %s): editing #%d'):format(tostring(src), opened))
        TriggerClientEvent(BR.Net.PROP_EDIT, src, { id = opened, open = true })

    elseif step == 'confirm' or step == 'cancel' then
        local d = step == 'confirm' and transformArgs(args, 4) or nil
        local r, why = BR.Props.editEnd(src, id, step, d)
        if not r then
            tell(src, ('%s refused: %s'):format(step, why))
            -- THE REQUESTER GETS THE RECORD AS IT STANDS, so a preview the
            -- server did not take is put back where the server says.
            local cur = BR.Props.get(id or -1)
            if cur and type(src) == 'number' and src > 0 then
                TriggerClientEvent(BR.Net.PROP_SYNC, src, { set = { cur } })
            end
            return
        end
        if step == 'confirm' then
            tell(src, ('#%d placed at %.2f, %.2f, %.2f  pitch %.1f roll %.1f yaw %.1f')
                :format(r.id, r.x, r.y, r.z, r.pitch, r.roll, r.yaw))
        else
            print(('[br_core] brprop (client %s): #%d edit canceled'):format(tostring(src), r.id))
        end

    else
        tell(src, USAGE)
    end
end

-- THE DOOR. Registered through devgate.lua's wrap, so with dev mode off it
-- prints which gate closed and runs nothing; with it on, it runs for whoever
-- typed it. `false` is `restricted` -- see the header.
RegisterCommand('brpropsv', function(source, args)
    local src = tonumber(source) or 0
    args = args or {}
    local verb = args[1] and args[1]:lower() or nil

    if verb == 'spawn' then
        local d = transformArgs(args, 4)
        d.model, d.display = args[2], args[3]
        d.pitch, d.roll, d.yaw = 0.0, 0.0, numArg(args[7]) or 0.0
        local r, why = BR.Props.create(src, d)
        if not r then
            tell(src, ('spawn refused: %s'):format(why))
            return
        end
        tell(src, ('spawned #%d %s (%s) at %.2f, %.2f, %.2f')
            :format(r.id, r.model, r.display, r.x, r.y, r.z))

    elseif verb == 'delete' then
        local which = args[2] and args[2]:lower() == 'all' and 'all' or idOf(args[2])
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

    elseif verb == 'display' then
        local r, why = BR.Props.setDisplay(idOf(args[2]), args[3])
        if not r then
            tell(src, ('display refused: %s'):format(why))
            return
        end
        tell(src, ('#%d is now shown as %s'):format(r.id, r.display))

    elseif verb == 'save' then
        local n, why = BR.Props.save()
        if not n then
            tell(src, ('save failed: %s'):format(why))
            return
        end
        tell(src, ('saved %d prop(s) to %s/%s')
            :format(n, GetCurrentResourceName(), BR.Config.Props.saveFile))

    elseif verb == 'load' then
        local n, skipped = BR.Props.load()
        if not n then
            tell(src, ('load failed: %s'):format(skipped))
            return
        end
        tell(src, ('loaded %d prop(s)%s'):format(n,
            skipped > 0 and (', skipped %d bad row(s)'):format(skipped) or ''))

    elseif verb == 'edit' then
        editVerb(src, args)

    else
        tell(src, USAGE)
    end
end, false)

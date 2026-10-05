-- The Yubikey and the terminals it opens (#396, Season 2), client half: what
-- this player SEES. Everything it decides is presentation; every rule is the
-- server's (server/yubikey.lua, server/terminal.lua).
--
--   the key        held / squadUsed, as YUBIKEY_STATE says. client/state.lua
--                  reads BR.Yubikey.glyph() into the HUD envelope, where br_ui
--                  draws the equipped icon. A key on the GROUND is ordinary
--                  loot and client/loot.lua draws it.
--   the terminals  the config's sites plus the dev tool's (TERMINAL_SITES):
--                  a local prop each, within STREAM_M; a blip each, only while
--                  this player holds a key and only for a terminal inside the
--                  storm; and the shared world plate within reach, whose hold
--                  asks the server to open the computer (TERMINAL_USE).
--   Storm reveal   where this match's storm ends, on both maps, from the
--                  squad's TERMINAL_REVEAL to the trip back to the lobby.
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing, unless a plate is up. The terminals are walked on the SLOW band
-- (props, blips, which ones the storm has taken) and on the TICK band (which
-- one is in reach, and the hold), and both return before calling a native on a
-- Season 1 server or with no terminal anywhere. The FRAME band only draws the
-- plate, and only while there is one. tools/perf_client.lua's budget holds it.

BR = BR or {}
BR.Yubikey = BR.Yubikey or {}

local Y = BR.Yubikey
local TS = BR.TerminalSolve

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua. Every BOOL read
--- in this file goes through here (tools/bool_native_rules.lua).
local isTrue = BR.NativeTruthy

local function cfg() return BR.Config.Terminals end
local function copy() return BR.Config.Terminals.copy end
local function art() return BR.Config.Terminals.art or {} end

--- THE SEASON, ASKED ONCE A SECOND AND NOT ON EVERY READ. A client's
--- BR.Season.has is a few table reads now -- the client holds its season and
--- re-reads br_seasonServed only when it moves (br_lib/shared/season.lua) --
--- and the TICK band and the HUD envelope (BR.Yubikey.glyph) still ask it ten
--- times a second for an answer that only moves at a match boundary, and only
--- on a dev box (`brseason`). So one boolean answers them; the SLOW pass
--- refreshes it.
local seasonOn = false
local function refreshSeason()
    seasonOn = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end
refreshSeason()

local function on()
    return seasonOn
end

--- Props exist within this many metres of the player, and are let go of past
--- STREAM_M * 1.25 -- the gap stops one standing on the line being rebuilt
--- every pass.
local STREAM_M = 150.0

--- The plate's size and height over the terminal's origin. PLATE_SCALE is the
--- other world plates' number (client/revivekey.lua's PROMPT_SCALE), so the
--- seventh consumer of the one prompt browser draws like the other six.
local PLATE_SCALE = 1.6
local PLATE_LIFT = 0.9

--- How long a model may take to stream before the terminal is drawn as
--- nothing and said so on F8.
local LOAD_WAIT_MS = 5000

-- ------------------------------------------------------------- the state ---

--- What the server told this player (YUBIKEY_STATE).
local held, squadUsed = false, false

--- The dev tools' changes (TERMINAL_SITES): placed sites, removed config ids,
--- ids forced online.
local dev = { placed = {}, removed = {}, forced = {} }

--- The merged terminal list, rebuilt when the dev changes arrive.
local list = nil

--- [id] = { state = 'loading'|'built'|'failed', hash, since, obj, online,
---          big, mini }  -- big/mini: the blip on each map
local world = {}

--- Storm reveal: { x, y, r, matchId, radius, big, mini }, or nil.
local reveal = nil

--- The terminal within reach, from the TICK band, or nil.
local near = nil

--- What the plate shows, or nil: { id, x, y, z, hint, press }.
local plate = nil

--- The plate's last message, so it is sent only on change (a re-send restarts
--- the ring from zero -- client/dbno.lua's #129 note).
local shownKey = nil

--- A hold under way: { id, at }, or nil.
local holding = nil

--- False from the moment a hold completes until interact is let go, so one
--- long press cannot ask twice.
local armed = true

--- @return boolean  this player holds a key (false on Season 1)
function Y.held()
    return on() and held
end

--- The equipped icon for the HUD envelope, or nil when there is none to draw.
--- @return string|nil
function Y.glyph()
    if Y.held() then return art().hudGlyph end
    return nil
end

--- The holder mark beside a squadmate's name, or nil.
--- @param mateHolds boolean|nil  the squad beacon's `yubikey`
--- @return string|nil
function Y.mateGlyph(mateHolds)
    if mateHolds == true and on() then return art().hudGlyph end
    return nil
end

--- Is this file's plate on screen? Read by client/dbno.lua, which owns the one
--- BR.Loot.suppress call: a terminal on a floor with loot near it must not
--- take two answers from one press, nor share the one prompt browser with a
--- crate's plate -- so even an offline plate, with nothing to hold, counts.
--- @return boolean
function Y.prompting()
    return plate ~= nil
end

--- Every terminal, config rows first (less any the dev tool removed), then the
--- dev tool's.
--- @return table[]
local function sites()
    if list then return list end
    local out, at = {}, {}
    for _, s in ipairs((TS.sites(cfg().sites))) do
        if not dev.removed[s.id] then
            out[#out + 1] = s
            at[s.id] = #out
        end
    end
    for _, s in ipairs(dev.placed) do
        if at[s.id] then out[at[s.id]] = s else out[#out + 1] = s end
    end
    list = out
    return out
end

-- -------------------------------------------------------------- the maps ---

local function removeBlip(b)
    if b and isTrue(DoesBlipExist(b)) then RemoveBlip(b) end
end

--- One sprite on each map: display 3 is the pause map, 5 the minimap --
--- client/airdrop.lua's pair, which is what a playtest proved draws on both.
--- @return integer big, integer mini
local function blipPair(x, y, z, sprite, colour, scale, name)
    local out = {}
    for i, display in ipairs({ 3, 5 }) do
        local b = AddBlipForCoord(x, y, z)
        SetBlipSprite(b, sprite)
        SetBlipColour(b, colour)
        SetBlipScale(b, scale)
        SetBlipDisplay(b, display)
        SetBlipAsShortRange(b, false)
        if name then BR.Native.blipName(b, name) end
        out[i] = b
    end
    return out[1], out[2]
end

local function dropTerminalBlips(w)
    removeBlip(w.big)
    removeBlip(w.mini)
    w.big, w.mini = nil, nil
end

local function clearReveal()
    if not reveal then return end
    removeBlip(reveal.radius)
    removeBlip(reveal.big)
    removeBlip(reveal.mini)
    reveal = nil
end

--- Draw where the storm ends: a radius blip around the point and the sprite on
--- each map.
local function drawReveal()
    if not reveal then return end
    local R = art().reveal or {}
    local name = copy().storm_reveal_blip
    local radius = math.max(tonumber(reveal.r) or 0.0, R.radiusM or 60.0)
    reveal.radius = BR.Native.radiusBlip(reveal.radius, reveal.x, reveal.y, radius,
        R.colour or 1, R.alpha or 120, name)
    removeBlip(reveal.big)
    removeBlip(reveal.mini)
    reveal.big, reveal.mini = blipPair(reveal.x, reveal.y, 0.0,
        R.sprite or 161, R.colour or 1, R.scale or 1.0, name)
end

-- ----------------------------------------------------------------- props ---

local function dropProp(id)
    local w = world[id]
    if not w then return end
    if w.obj and isTrue(DoesEntityExist(w.obj)) then DeleteEntity(w.obj) end
    if w.state == 'loading' and w.hash then SetModelAsNoLongerNeeded(w.hash) end
    dropTerminalBlips(w)
    world[id] = nil
end

local function dropAll()
    for id in pairs(world) do dropProp(id) end
    near, holding = nil, nil
end

--- Stream, build or let go of one terminal's prop for where the player stands.
--- The entry exists for every terminal, near or not -- its blip is on the
--- whole map -- and `state` says what the prop is doing: 'away' (none, out of
--- range), 'loading', 'built' or 'failed'.
local function stepProp(s, d2, now)
    local w = world[s.id]
    if not w then
        w = { state = 'away' }
        world[s.id] = w
    end
    local within = d2 <= STREAM_M * STREAM_M
    if w.state == 'away' then
        if not within then return end
        local hash = w.hash or GetHashKey(art().terminalProp or 'prop_laptop_01a')
        if not isTrue(IsModelInCdimage(hash)) then
            w.state = 'failed'
            print(("[br_core] terminals: '%s' is not in this game's CD image, so terminal %s "
                .. 'is not drawn'):format(tostring(art().terminalProp), s.id))
            return
        end
        RequestModel(hash)
        w.hash, w.state, w.since = hash, 'loading', now
        return
    end
    if d2 > (STREAM_M * 1.25) ^ 2 and w.state ~= 'failed' then
        -- Out of range: the prop goes; the entry, and its blip, stay.
        if w.obj and isTrue(DoesEntityExist(w.obj)) then DeleteEntity(w.obj) end
        if w.state == 'loading' and w.hash then SetModelAsNoLongerNeeded(w.hash) end
        w.obj, w.state = nil, 'away'
        return
    end
    if w.state == 'loading' then
        if isTrue(HasModelLoaded(w.hash)) then
            local obj = CreateObjectNoOffset(w.hash, s.x, s.y, s.z, false, false, false)
            SetModelAsNoLongerNeeded(w.hash)
            if not obj or obj == 0 then
                w.state = 'failed'
                return
            end
            SetEntityHeading(obj, s.h or 0.0)
            FreezeEntityPosition(obj, true)
            w.obj, w.state = obj, 'built'
        elseif now - w.since > LOAD_WAIT_MS then
            SetModelAsNoLongerNeeded(w.hash)
            w.state = 'failed'
            print(('[br_core] terminals: the terminal prop did not load within %d ms; %s is '
                .. 'not drawn'):format(LOAD_WAIT_MS, s.id))
        end
    end
end

--- Is the player in a live match, where terminals and their blips belong?
--- @return boolean
local function inMatch()
    local S = BR.State
    if not S or not S.match or not S.me then return false end
    local st = S.match.state
    return (st == BR.MatchState.BUS or st == BR.MatchState.PLAYING)
        and S.me.state ~= BR.PlayerState.LOBBY
end

-- THE TERMINALS, ONCE A SECOND: props near the player, which terminals the
-- storm has taken, and their blips. One zone build per pass however many
-- terminals there are.
BR.Loop.register(BR.Loop.SLOW, 'terminals.world', function()
    refreshSeason()
    if not on() then
        if next(world) ~= nil then dropAll() end
        clearReveal()
        return
    end

    -- Back in the lobby: the match's reveal and its squad's use are over.
    local S = BR.State
    if S and S.me and S.me.state == BR.PlayerState.LOBBY then
        clearReveal()
        squadUsed = false
    end

    local all = sites()
    if #all == 0 then
        if next(world) ~= nil then dropAll() end
        return
    end

    local now = GetGameTimer()
    local p = GetEntityCoords(PlayerPedId())
    local live = inMatch()
    local zone = nil
    if live and S.storm then
        zone = TS.zoneAt(S.storm, BR.Clock and BR.Clock.now() or now)
    end
    local blips = live and held

    local present = {}
    for _, s in ipairs(all) do
        present[s.id] = true
        local dx, dy = p.x - s.x, p.y - s.y
        stepProp(s, dx * dx + dy * dy, now)
        local w = world[s.id]
        if w then
            w.online = dev.forced[s.id] == true or TS.inside(zone, s.x, s.y)
            -- "Terminal blips should appear from the start only when a Yubikey
            -- is equipped", and, the owner's own spec, only for a terminal
            -- INSIDE the storm.
            if blips and w.online then
                if not (w.big and isTrue(DoesBlipExist(w.big))) then
                    dropTerminalBlips(w)
                    local a = art()
                    w.big, w.mini = blipPair(s.x, s.y, s.z, a.blipSprite or 521,
                        a.blipColour or 51, a.blipScale or 0.9, copy().terminal_label)
                end
            elseif w.big or w.mini then
                dropTerminalBlips(w)
            end
        end
    end
    -- A terminal the dev tool took away.
    for id in pairs(world) do
        if not present[id] then dropProp(id) end
    end
end)

-- -------------------------------------------------------------- the plate ---

local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Show, change or take down the plate. Sent on change only.
local function setPrompt()
    local k = plate and table.concat({ plate.id, plate.hint, tostring(plate.press),
        tostring(holding ~= nil) }, ':') or nil
    if k == shownKey then return end
    local wasUp = shownKey ~= nil
    shownKey = k
    if not plate then
        if wasUp then BR.Dui.send(promptPage(), { t = 'prompt', show = false }) end
        return
    end
    BR.Dui.send(promptPage(), {
        t      = 'prompt',
        show   = true,
        label  = copy().terminal_label,
        hint   = plate.hint,
        -- THE KEY CAP ONLY WHERE THERE IS A HOLD: an offline terminal has
        -- nothing to press, and a cap on its plate would be a lie the player
        -- acts on (client/revivekey.lua's rule).
        key    = plate.press and BR.Native.keyLabelForCommand(
                     'brinteract', BR.Config.Loot.promptControl or 51) or nil,
        ring   = holding ~= nil,
        holdMs = cfg().holdMs,
    })
end

--- What this player's plate says at this terminal.
---
---   offline     the storm has it: the offline line, nothing to hold
---   no key      the no_key line ("what they need to do to gain access"); the
---               hold still opens the computer, which lists every function
---               unavailable for the same reason
---   squad used  the squad_used line; the hold opens it the same way
---   usable      terminal_use, the key cap and the ring
local function plateFor(s)
    local w = world[s.id]
    local online = (w and w.online) or dev.forced[s.id] == true
    if not online then return { hint = copy().offline, press = false } end
    if not held then return { hint = copy().no_key, press = true } end
    if squadUsed then return { hint = copy().squad_used, press = true } end
    return { hint = copy().terminal_use, press = true }
end

-- WHICH TERMINAL IS IN REACH, AND THE HOLD, TEN TIMES A SECOND.
BR.Loop.register(BR.Loop.TICK, 'terminals.near', function()
    if not on() then
        if plate then plate = nil; setPrompt() end
        near, holding = nil, nil
        return
    end
    local all = sites()
    if #all == 0 then
        if plate then plate = nil; setPrompt() end
        near, holding = nil, nil
        return
    end

    local S = BR.State
    local open = BR.Terminal and BR.Terminal.computerOpen and BR.Terminal.computerOpen()
    local alive = S and S.me and S.me.state == BR.PlayerState.ALIVE
    near = nil
    if alive and not open then
        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        local reach = cfg().useDistanceM or 2.5
        local best = reach * reach
        for _, s in ipairs(all) do
            local dx, dy, dz = p.x - s.x, p.y - s.y, p.z - s.z
            local d2 = dx * dx + dy * dy
            if d2 <= best and math.abs(dz) <= 3.0 then
                best, near = d2, s
            end
        end
        if near and BR.NativeTruthy(IsPedInAnyVehicle(ped, false)) then near = nil end
    end

    if near then
        local f = plateFor(near)
        plate = { id = near.id, x = near.x, y = near.y, z = near.z,
                  hint = f.hint, press = f.press }
    else
        plate = nil
    end

    -- THE HOLD: a level, not an edge -- let go, walk off or lose the press and
    -- it ends; held long enough and the server is ASKED.
    if holding then
        local still = plate ~= nil and plate.press and plate.id == holding.id
            and BR.Keys.isHeld('interact')
        if not still then
            holding = nil
        elseif GetGameTimer() - holding.at >= (cfg().holdMs or 800) then
            TriggerServerEvent(BR.Net.TERMINAL_USE, { terminalId = holding.id })
            holding, armed = nil, false
        end
    end
    if not armed and not BR.Keys.isHeld('interact') then armed = true end
    setPrompt()
end)

-- THE PLATE, EVERY FRAME IT IS UP, AND NOTHING ELSE.
BR.Loop.register(BR.Loop.FRAME, 'terminals.plate', function()
    if not plate then return end
    BR.Dui.drawWorld(promptPage(), plate.x, plate.y, plate.z + PLATE_LIFT, PLATE_SCALE)
end)

-- THE PRESS ACTS ON WHAT WAS DRAWN, never on a fresh search (client/loot.lua's
-- #128). Not while a br_ui screen holds the keyboard, and not while the
-- computer is up.
BR.Keys.on('interact', function(pressed)
    if not pressed then return end
    if not plate or not plate.press or holding or not armed then return end
    if BR.Keys.uiScreen ~= nil then return end
    if BR.Terminal and BR.Terminal.computerOpen and BR.Terminal.computerOpen() then return end
    holding = { id = plate.id, at = GetGameTimer() }
    setPrompt()
end)

-- ------------------------------------------------------------- the wire ---

RegisterNetEvent(BR.Net.YUBIKEY_STATE)
AddEventHandler(BR.Net.YUBIKEY_STATE, function(d)
    if type(d) ~= 'table' then return end
    held = d.held == true
    squadUsed = d.squadUsed == true
    -- Blips follow on the next SLOW pass; a lost key takes them down now.
    if not held then
        for _, w in pairs(world) do dropTerminalBlips(w) end
    end
end)

RegisterNetEvent(BR.Net.TERMINAL_SITES)
AddEventHandler(BR.Net.TERMINAL_SITES, function(d)
    if type(d) ~= 'table' then return end
    local placed = {}
    for _, s in ipairs((TS.sites(d.placed))) do placed[#placed + 1] = s end
    local removed, forced = {}, {}
    for _, id in ipairs(type(d.removed) == 'table' and d.removed or {}) do
        if TS.validId(id) then removed[id] = true end
    end
    for _, id in ipairs(type(d.forced) == 'table' and d.forced or {}) do
        if TS.validId(id) then forced[id] = true end
    end
    dev = { placed = placed, removed = removed, forced = forced }
    list = nil
    -- A moved terminal is rebuilt where it now stands.
    for _, s in ipairs(placed) do
        if world[s.id] then dropProp(s.id) end
    end
end)

RegisterNetEvent(BR.Net.TERMINAL_REVEAL)
AddEventHandler(BR.Net.TERMINAL_REVEAL, function(d)
    if type(d) ~= 'table' or not on() then return end
    if not (TS.finite(d.x) and TS.finite(d.y)) then return end
    clearReveal()
    reveal = { x = d.x, y = d.y, r = tonumber(d.r) or 0.0, matchId = d.matchId }
    drawReveal()
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    dropAll()
    clearReveal()
end)

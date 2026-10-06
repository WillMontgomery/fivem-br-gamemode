-- The Yubikey and the terminals it opens (#396, Season 2), client half: what
-- this player SEES. Everything it decides is presentation; every rule is the
-- server's (server/yubikey.lua, server/terminal.lua).
--
--   the key        held / squadUsed, as YUBIKEY_STATE says. client/state.lua
--                  reads BR.Yubikey.glyph() into the HUD envelope, where br_ui
--                  draws the equipped icon. A key on the GROUND is ordinary
--                  loot and client/loot.lua draws it.
--   the terminals  the config's sites plus the dev tool's (TERMINAL_SITES):
--                  a blip each, only while this player holds a key and only
--                  for an online terminal -- inside the storm, the one rule
--                  the server reads
--                  (BR.TerminalSolve.offlineWhy); and the shared world plate
--                  within reach -- the owner's "Computer system" / "press to
--                  open" with the interact key (2026-10-06) -- whose PRESS
--                  asks the server to open the computer (TERMINAL_USE). A
--                  terminal outside the storm has NEITHER, for anyone (owner,
--                  2026-10-06: "no blip and no DUI - hence it's unusable"). THE
--                  LAPTOPS ARE NOT OURS: the owner's ymap places them
--                  (2026-10-06, streamed with br_stream_s2), and every site
--                  row says where one stands -- this file makes no prop, and
--                  reads nothing off one.
--   the laptops    hidden where terminals are off (Season 1): a model hide at
--                  each config row, made and taken down only when the season
--                  moves (below, "the laptops, Season 1").
--   Storm reveal   where this match's storm ends, on both maps, from the
--                  squad's TERMINAL_REVEAL to the trip back to the lobby.
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing, unless a plate is up. The terminals are walked on the SLOW band
-- (blips, which ones the storm has taken) and on the TICK band (which one is
-- in reach), and both return before calling a native on a
-- Season 1 server or with no terminal anywhere. The FRAME band only draws the
-- plate, and only while there is one. tools/perf_client.lua's budget holds it.
-- The Season 1 hides cost their natives once per season move, never per pass.

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

--- The plate's size and height over the terminal's origin. PLATE_SCALE is the
--- other world plates' number (client/revivekey.lua's PROMPT_SCALE), so the
--- seventh consumer of the one prompt browser draws like the other six.
local PLATE_SCALE = 1.6
local PLATE_LIFT = 0.9

-- ------------------------------------------------------------- the state ---

--- What the server told this player (YUBIKEY_STATE). `squadMatch` picks the
--- squad_used line or its `_solo` sibling (owner, round 2: "squad" only in a
--- squad match).
local held, squadUsed, squadMatch = false, false, false

--- The dev tools' changes (TERMINAL_SITES): placed sites, removed config ids,
--- ids forced online.
local dev = { placed = {}, removed = {}, forced = {} }

--- The merged terminal list, rebuilt when the dev changes arrive.
local list = nil

--- [id] = { online, why, big, mini } for every terminal: whether it is online,
--- why not (BR.TerminalSolve.offlineWhy's answer: 'offline' or nil),
--- and its blip on each map
local world = {}

--- Storm reveal: { x, y, r, matchId, radius, big, mini }, or nil.
local reveal = nil

--- The terminal within reach, from the TICK band, or nil.
local near = nil

--- What the plate shows, or nil: { id, x, y, z, hint, press }.
local plate = nil

--- The plate's last message, so it is sent only on change.
local shownKey = nil

--- GetGameTimer() of the last press that asked the server, or nil. A press
--- sooner than runMinIntervalMs after it asks nothing: the server drops a use
--- that soon anyway (its own anti-spam interval, server/terminal.lua), so a
--- mashed key sends one request, not ten.
local lastAsk = nil

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
--- crate's plate. A terminal outside the storm has no plate, so it never
--- counts.
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

-- ------------------------------------------------ the laptops, Season 1 ---
--
-- ═══ SEASON 1 HIDES THE OWNER'S LAPTOPS (2026-10-06) ═══
--
-- His ymap is in br_stream_s2, installed from Season 2 on, and a running
-- server cannot swap a streamed asset: after a live `brseason 1` its laptops
-- still stream, and terminals are Season 2. So on a client where they are
-- off, the laptop at every config row is hidden with a MODEL HIDE, and the
-- hide comes off when they come on -- a live `brseason` switch included. NOT
-- PER FRAME: on start, on every move of this
-- client's season (BR.Season.onChange; the SLOW pass's own refresh catches a
-- move the latch did not announce), and only a change calls a native. A
-- model hide is this client's alone ("Network players do not see changes
-- done with this"), which is what a per-client season answer wants.
--
-- THE NATIVES, from the Cfx docs (citizenfx/natives, ENTITY, read 2026-10-06):
--
--   CreateModelHideExcludingScriptObjects(x, y, z, radius, model,
--       surviveMapReload)  0x3A52AE588830BF7F. Hides every object of `model`
--       intersecting the sphere, "only ... map objects", never one a script
--       made. surviveMapReload is TRUE: false hides "only currently loaded
--       objects", and a laptop across the map is not loaded when this runs --
--       it streams in later and must stream in hidden.
--   RemoveModelHide(x, y, z, radius, model, lazy)  0xD9E3006FB3CBD765. Undoes
--       either kind; lazy is FALSE, so "all matching objects currently in
--       scope are restored immediately".
--
-- Both return nothing, so there is no BOOL to read. A ymap's entities are
-- map objects: the game's own scripts hide map props with these.
--
-- ONLY THE CONFIG ROWS, which say where the ymap's laptops stand. A terminal
-- the dev tool placed has no laptop, and a row it removed for a session keeps
-- its laptop as furniture -- and on a Season 1 box no dev change may unhide
-- one. The rows themselves change only with a restart of this resource, which
-- takes every hide down as it stops and makes them again from the new rows.

--- Every model hide this client has made: [key] = { x, y, z, r, hash }. The
--- key names the row it was made for, its id and its place.
local hides = {}

--- The season answer the hides were last made for (nil: never made).
local hidesFor = nil

local function hideKey(s)
    return ('%s@%.3f,%.3f,%.3f'):format(s.id, s.x, s.y, s.z)
end

--- Make this client's hides match its season: the laptop at every config row
--- hidden while terminals are off here, none while they are on. Only a hide
--- that has to be made or taken down calls a native.
local function syncHides()
    hidesFor = on()
    local model = art().terminalProp
    local want, order = {}, {}
    if not hidesFor and type(model) == 'string' and model ~= '' then
        for _, s in ipairs((TS.sites(cfg().sites))) do
            local k = hideKey(s)
            want[k] = s
            order[#order + 1] = k
        end
    end
    for k, h in pairs(hides) do
        if not want[k] then
            RemoveModelHide(h.x, h.y, h.z, h.r, h.hash, false)
            hides[k] = nil
        end
    end
    local hash = nil
    local r = tonumber(art().hideRadiusM) or 2.0
    for _, k in ipairs(order) do
        if not hides[k] then
            hash = hash or GetHashKey(model)
            local s = want[k]
            CreateModelHideExcludingScriptObjects(s.x, s.y, s.z, r, hash, true)
            hides[k] = { x = s.x, y = s.y, z = s.z, r = r, hash = hash }
        end
    end
end

--- Every hide taken down: this resource is stopping, and a restart makes them
--- again from its own rows.
local function dropHides()
    for k, h in pairs(hides) do
        RemoveModelHide(h.x, h.y, h.z, h.r, h.hash, false)
        hides[k] = nil
    end
    hidesFor = nil
end

-- ON START, and on every move of the season.
syncHides()
if BR.Season and BR.Season.onChange then
    BR.Season.onChange(function()
        refreshSeason()
        syncHides()
    end)
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

-- ------------------------------------------------------------- the list ---

local function dropTerminal(id)
    local w = world[id]
    if not w then return end
    dropTerminalBlips(w)
    world[id] = nil
end

local function dropAll()
    for id in pairs(world) do dropTerminal(id) end
    near = nil
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

-- THE TERMINALS, ONCE A SECOND: which ones the storm has taken, and their
-- blips. One zone build per pass however many terminals there are, and no
-- native at all for a terminal while this player holds no key.
BR.Loop.register(BR.Loop.SLOW, 'terminals.world', function()
    refreshSeason()
    -- A season move the latch did not announce: the hides follow it here. A
    -- boolean compared, and nothing more, on every pass that moved nothing.
    if hidesFor ~= on() then syncHides() end
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
    local live = inMatch()
    local zone = nil
    if live and S.storm then
        zone = TS.zoneAt(S.storm, BR.Clock and BR.Clock.now() or now)
    end
    local blips = live and held

    local present = {}
    for _, s in ipairs(all) do
        present[s.id] = true
        local w = world[s.id]
        if not w then
            w = {}
            world[s.id] = w
        end
        -- THE ONE ONLINE RULE, the server's own (BR.TerminalSolve.offlineWhy).
        w.why = TS.offlineWhy(s, zone, dev.forced[s.id] == true)
        w.online = w.why == nil
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
    -- A terminal the dev tool took away.
    for id in pairs(world) do
        if not present[id] then dropTerminal(id) end
    end
end)

-- -------------------------------------------------------------- the plate ---

local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Show, change or take down the plate. Sent on change only.
local function setPrompt()
    local k = plate and table.concat({ plate.id, plate.hint, tostring(plate.press) }, ':') or nil
    if k == shownKey then return end
    local wasUp = shownKey ~= nil
    shownKey = k
    if not plate then
        if wasUp then BR.Dui.send(promptPage(), { t = 'prompt', show = false }) end
        return
    end
    -- THE OWNER'S PLATE (2026-10-06): "Computer system" over "press to open"
    -- with the interact key on it -- the page's key-cap badge, the loose
    -- items' plate. No ring: nothing is held.
    BR.Dui.send(promptPage(), {
        t      = 'prompt',
        show   = true,
        label  = copy().terminal_label,
        hint   = plate.hint,
        -- THE KEY CAP ONLY WHERE A PRESS DOES SOMETHING (client/revivekey.lua's
        -- rule): every plate this file shows opens the computer, since a
        -- terminal outside the storm has none. The player's own key for
        -- interact, whatever they bound it to.
        key    = plate.press and BR.Native.keyLabelForCommand(
                     'brinteract', BR.Config.Loot.promptControl or 51) or nil,
    })
end

--- What this player's plate says at this terminal, or nil for NO PLATE.
---
---   offline     the storm has it: NO PLATE AT ALL, for anyone (owner,
---               2026-10-06: "A terminal outside the storm should have no
---               blip and no DUI - hence it's unusable"). Nothing is drawn,
---               nothing can be pressed, and the loot prompt keeps the floor.
---               A terminal the SLOW pass has not placed yet counts as
---               outside. The server still refuses a use there (its toast,
---               `offline`, answers a client a step behind the storm).
---   no key      the no_key line ("what they need to do to gain access"); the
---               press still opens the computer, which lists every function
---               unavailable for the same reason
---   squad used  the squad_used line; the press opens it the same way
---   usable      terminal_use ("press to open") and the key cap
local function plateFor(s)
    local w = world[s.id]
    local online = (w and w.online) or dev.forced[s.id] == true
    if not online then return nil end
    if not held then return { hint = copy().no_key, press = true } end
    if squadUsed then return { hint = TS.pick(copy(), 'squad_used', squadMatch), press = true } end
    return { hint = copy().terminal_use, press = true }
end

-- WHICH TERMINAL IS IN REACH, TEN TIMES A SECOND.
BR.Loop.register(BR.Loop.TICK, 'terminals.near', function()
    if not on() then
        if plate then plate = nil; setPrompt() end
        near = nil
        return
    end
    local all = sites()
    if #all == 0 then
        if plate then plate = nil; setPrompt() end
        near = nil
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

    local f = near and plateFor(near) or nil
    if f then
        plate = { id = near.id, x = near.x, y = near.y, z = near.z,
                  hint = f.hint, press = f.press }
    else
        plate = nil
    end
    setPrompt()
end)

-- THE PLATE, EVERY FRAME IT IS UP, AND NOTHING ELSE.
BR.Loop.register(BR.Loop.FRAME, 'terminals.plate', function()
    if not plate then return end
    BR.Dui.drawWorld(promptPage(), plate.x, plate.y, plate.z + PLATE_LIFT, PLATE_SCALE)
end)

-- THE PRESS OPENS IT (owner, 2026-10-06: "press to open"; it was an 800 ms
-- hold). The press ASKS: the server opens the computer only for a living
-- player in reach of a live terminal in a match on Season 2, and says why
-- not otherwise (server/terminal.lua's BR.Terminal.use). It acts on what was
-- drawn, never on a fresh search (client/loot.lua's #128). Not while a br_ui
-- screen holds the keyboard, not while the computer is up, and not again
-- within runMinIntervalMs of the last ask.
BR.Keys.on('interact', function(pressed)
    if not pressed then return end
    if not plate or not plate.press then return end
    if BR.Keys.uiScreen ~= nil then return end
    if BR.Terminal and BR.Terminal.computerOpen and BR.Terminal.computerOpen() then return end
    local now = GetGameTimer()
    if lastAsk ~= nil and now - lastAsk < (cfg().runMinIntervalMs or 500) then return end
    lastAsk = now
    TriggerServerEvent(BR.Net.TERMINAL_USE, { terminalId = plate.id })
end)

-- ------------------------------------------------------------- the wire ---

RegisterNetEvent(BR.Net.YUBIKEY_STATE)
AddEventHandler(BR.Net.YUBIKEY_STATE, function(d)
    if type(d) ~= 'table' then return end
    held = d.held == true
    squadUsed = d.squadUsed == true
    squadMatch = d.squadMatch == true
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
    -- A moved terminal's blip is drawn again where it now stands.
    for _, s in ipairs(placed) do
        if world[s.id] then dropTerminal(s.id) end
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
    dropHides()
end)

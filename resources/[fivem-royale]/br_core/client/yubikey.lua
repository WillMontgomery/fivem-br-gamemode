-- The Yubikey and the terminals it opens (#396, Season 2), client half: what
-- this player SEES. Everything it decides is presentation; every rule is the
-- server's (server/yubikey.lua, server/terminal.lua).
--
--   the key        held, as YUBIKEY_STATE says. client/state.lua
--                  reads BR.Yubikey.glyph() into the HUD envelope, where br_ui
--                  draws the equipped icon. A key on the GROUND is ordinary
--                  loot and client/loot.lua draws it.
--   the terminals  the config's sites plus the dev tool's (TERMINAL_SITES):
--                  a blip each, only while this player holds a key, from
--                  warmup on (round 5), and only for an online terminal --
--                  inside the storm once there is one, the one rule the
--                  server reads (BR.TerminalSolve.offlineWhy) -- drawn like a
--                  fuel station's: short-range, so the minimap shows it only
--                  nearby and the big map always; and the shared world plate
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
--                  squad's TERMINAL_REVEAL to the trip back to the lobby --
--                  Storm reveal's answer, or the spot Storm control picked
--                  (2026-10-07): the same fact, the same mark.
--   the first-pickup card  (round 5) the owner's words on br_ui's tutorial
--                  card the first time this player ever gets a key
--                  (YUBIKEY_STATE's `first`), up until they press Enter --
--                  read here as a control, the one key it takes.
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

--- The plate's size. PLATE_SCALE is the other world plates' number
--- (client/revivekey.lua's PROMPT_SCALE), so the seventh consumer of the one
--- prompt browser draws like the other six. Its height is art.plateLiftM over
--- the terminal's row, which is the laptop's own origin (round 6: at the
--- laptop, not over it).
local PLATE_SCALE = 1.6

--- How far over a terminal's row (the laptop's origin, on its desk) the plate
--- is centered, in meters.
--- @return number
local function plateLift()
    return tonumber(art().plateLiftM) or 0.15
end

-- ------------------------------------------------------------- the state ---

--- What the server told this player (YUBIKEY_STATE): whether they hold a key.
local held = false

--- The dev tools' changes (TERMINAL_SITES): placed sites, removed config ids,
--- ids forced online.
local dev = { placed = {}, removed = {}, forced = {} }

--- The merged terminal list, rebuilt when the dev changes arrive.
local list = nil

--- [id] = { online, why, blip } for every terminal: whether it is online,
--- why not (BR.TerminalSolve.offlineWhy's answer: 'offline' or nil),
--- and its one blip
local world = {}

--- The squad's mark of where the storm ends (Storm reveal's, or Storm
--- control's spot): { x, y, r, matchId, radius, big, mini }, or nil.
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
--- Storm reveal's; a terminal's blip is one short-range blip (terminalBlip).
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

--- ONE BLIP PER TERMINAL, A FUEL STATION'S KIND (owner, 2026-10-06, round 5:
--- "change the computers SetBlipDisplay to the same type as fuel stations -
--- reason being, the blips are currently pinned on the minimap and are always
--- there" -- and "we're not changing the blip type right? Just the display?").
--- So the sprite, the color and the scale are the art block's, as they were,
--- and the display is client/fuel.lua's station blip exactly: no
--- SetBlipDisplay at all (the default) and SetBlipAsShortRange(true) -- on the
--- big map always, on the minimap only when the player is near it. It was a
--- display-3 and display-5 PAIR that was not short-range, so the minimap one
--- sat pinned to the edge from anywhere on the map.
--- @param s table  the terminal
--- @return integer blip
local function terminalBlip(s)
    local a = art()
    local b = AddBlipForCoord(s.x, s.y, s.z)
    SetBlipSprite(b, a.blipSprite or 521)
    SetBlipColour(b, a.blipColour or 51)
    SetBlipScale(b, a.blipScale or 0.9)
    SetBlipAsShortRange(b, true)
    BR.Native.blipName(b, copy().terminal_label)
    return b
end

local function dropTerminalBlips(w)
    removeBlip(w.blip)
    w.blip = nil
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

--- Is the player where terminal blips belong: a match from its WARMUP on
--- (owner, 2026-10-06, round 5: "it's okay to show the computer system blips
--- while in warmup as long as the player has possession of a Yubikey"; it was
--- the bus on), through the bus and the match being played?
--- @return boolean
local function inMatch()
    local S = BR.State
    if not S or not S.match or not S.me then return false end
    local st = S.match.state
    return (st == BR.MatchState.WARMUP or st == BR.MatchState.BUS or st == BR.MatchState.PLAYING)
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

    -- Back in the lobby: the match's reveal is over.
    local S = BR.State
    if S and S.me and S.me.state == BR.PlayerState.LOBBY then
        clearReveal()
    end

    local all = sites()
    if #all == 0 then
        if next(world) ~= nil then dropAll() end
        return
    end

    local now = GetGameTimer()
    local live = inMatch()
    -- THE STORM, ONCE THERE IS ONE: from PLAYING, as the server's own m.storm.
    -- Before it (warmup and the bus) no terminal is outside anything, so every
    -- one has its blip -- and a record left over from the last match, which
    -- this client still holds until the new one arrives, decides nothing.
    local zone = nil
    if live and S.storm and S.match.state == BR.MatchState.PLAYING then
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
            if not (w.blip and isTrue(DoesBlipExist(w.blip))) then
                dropTerminalBlips(w)
                w.blip = terminalBlip(s)
            end
        elseif w.blip then
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
---   online      THE ONE PLATE: terminal_use ("press to open") and the key
---               cap, whoever walks up
---
--- ONE PLATE, WHATEVER THE PLAYER'S STATUS. Round 6 took the key out of it
--- (owner, 2026-10-07: "if I approach a computer with no Yubikey, the DUI
--- should show the same as if I do have one. The player will realize what's
--- up when they go to open the app."), and round 7 the squad's spent use
--- (owner, the same day: 'The DUI reading "you already used your terminal
--- this match" should be the same DUI text as the rest, not unique to that
--- status.'). So a key or none, the squad's use spent or not, a run in
--- flight: the same plate, and the press opens the computer all the same --
--- its app says what stands in the way (no_key, squad_used, ...). The
--- terminal's BLIP still needs a key.
local function plateFor(s)
    local w = world[s.id]
    local online = (w and w.online) or dev.forced[s.id] == true
    if not online then return nil end
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
    BR.Dui.drawWorld(promptPage(), plate.x, plate.y, plate.z + plateLift(), PLATE_SCALE)
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

-- ------------------------------------------------- the first-pickup card ---
--
-- ═══ THE FIRST-PICKUP CARD (owner, round 5, 2026-10-06) ═══
--
-- "I've still not seen the tutorial-style card which tells them how to use it
-- and requires manual dismissal using the return key." The first time a player
-- EVER gets a Yubikey -- a pickup or `bryubikey give`; the server says so with
-- YUBIKEY_STATE's `first`, once per account -- br_ui shows the owner's words
-- (copy first_pickup) on its tutorial card (BR.Nui.YUBIKEY_CARD), and it STAYS
-- until the player presses ENTER. Nothing else takes it down and no timer
-- does: not the match ending (br_ui keeps it off the lobby and the verdict and
-- shows it again in the next match), not a death, not a terminal's computer
-- (which hides it while it covers the screen).
--
-- IT MUST NOT TRAP THE PLAYER. It takes no NUI focus, so movement, aiming and
-- shooting are the game's as ever; and so CEF never sees a key, and Enter is
-- read HERE, as client/tutorial.lua reads its arrows: the controls Enter is,
-- disabled for the frame so the press does nothing else, and read disabled.
-- ONLY ENTER is taken, only while the card is up, and only while nothing else
-- holds the keyboard -- in a match (WARMUP, the bus, PLAYING; the HUD the card
-- is drawn over), with no br_ui screen, in-game menu or computer up
-- (BR.Keys.screenHoldsEscape) and GTA's own pause menu down, so a menu's own
-- Enter still selects in it.
--
-- THE KEYBOARD'S ENTER, NOT A CONTROLLER'S A. Every control Enter is, is also
-- a gamepad's A button -- and on foot A is sprint (INPUT_SPRINT 21) as well,
-- so a controller player running off from the crate they looted it from would
-- dismiss the card unread. A press counts only when IsUsingKeyboard says the
-- keyboard made it, read on the frame of the press (the #396 round 5
-- review). A controller player takes it down with the keyboard's Enter, the
-- key the card shows.
--
-- WHAT IT COSTS: nothing while it is down. While it is up, a few table reads
-- and seven natives a frame (IsPauseMenuActive, and three controls disabled
-- and read), and an eighth, IsUsingKeyboard, on a frame one of them is pressed.

--- Is the first-pickup card up? Lua owns it; br_ui mirrors it.
local card = false

--- What br_ui was last told: shown (true), hidden (false), or nothing yet.
local cardSent = nil

--- THE CONTROLS ENTER IS, and the only ones the card takes:
--- INPUT_FRONTEND_RDOWN (191) and INPUT_FRONTEND_ACCEPT (201) -- Enter and the
--- numpad's -- and INPUT_FRONTEND_ENDSCREEN_ACCEPT (215), Enter. None of them
--- moves, aims, fires, jumps or enters a vehicle; INPUT_SKIP_CUTSCENE (18)
--- and INPUT_CELLPHONE_SELECT (176) are left alone because they are the left
--- mouse button too, and a shot must never dismiss it. All three are a
--- gamepad's A too, which is why a press is also asked `keyboardMade`.
local ENTER = { 191, 201, 215 }

--- Did the keyboard make this frame's press? IsUsingKeyboard answers for the
--- last input on the pad the card reads (0), so on the frame A is pressed it
--- is false. BOOL, so through isTrue: a 0 for "a gamepad" is truthy.
--- @return boolean
local function keyboardMade()
    return isTrue(IsUsingKeyboard(0))
end

--- Is a terminal's computer up over the screen? (client/terminal.lua)
--- @return boolean
local function computerUp()
    return BR.Terminal ~= nil and BR.Terminal.computerOpen ~= nil and BR.Terminal.computerOpen() == true
end

--- Tell br_ui what it shows -- the card with the owner's words, or none --
--- on a change only (or `force`, br_ui having come up afresh). His words are
--- four lines since round 6: the card's H1 and H3, its body, and what follows
--- the Enter cap.
--- @param force boolean|nil
local function sendCard(force)
    local show = card and not computerUp()
    if not force and show == cardSent then return end
    cardSent = show
    local c = copy()
    TriggerEvent('br:ui:sendLocal', BR.Nui.YUBIKEY_CARD, {
        show = show,
        title = show and c.first_pickup_title or nil,
        subtitle = show and c.first_pickup_subtitle or nil,
        text = show and c.first_pickup or nil,
        dismiss = show and c.first_pickup_dismiss or nil,
    })
end

--- May the card take Enter this frame?
--- @return boolean
local function enterFree()
    if not inMatch() then return false end
    if BR.Keys and BR.Keys.screenHoldsEscape and BR.Keys.screenHoldsEscape() then return false end
    if isTrue(IsPauseMenuActive()) then return false end
    return true
end

--- Is the first-pickup card up? (For the dev tools and the suites.)
--- @return boolean
function Y.cardUp()
    return card
end

-- ENTER, EVERY FRAME THE CARD IS UP, AND NOTHING ELSE.
BR.Loop.register(BR.Loop.FRAME, 'yubikey.card', function()
    if not card then return end
    -- A computer opening or closing over it hides or shows it again.
    sendCard()
    if computerUp() or not enterFree() then return end
    for i = 1, #ENTER do DisableControlAction(0, ENTER[i], true) end
    local pressed = false
    for i = 1, #ENTER do
        if isTrue(IsDisabledControlJustPressed(0, ENTER[i])) then pressed = true end
    end
    if not pressed then return end
    -- A controller's A (sprint, too) is not Enter: the card stays.
    if not keyboardMade() then return end
    card = false
    sendCard()
end)

-- br_ui restarting mid-card gets it back.
AddEventHandler('br:ui:ready', function()
    if card then sendCard(true) end
end)

-- ------------------------------------------------------------- the wire ---

RegisterNetEvent(BR.Net.YUBIKEY_STATE)
AddEventHandler(BR.Net.YUBIKEY_STATE, function(d)
    if type(d) ~= 'table' then return end
    held = d.held == true
    -- Blips follow on the next SLOW pass; a lost key takes them down now.
    if not held then
        for _, w in pairs(world) do dropTerminalBlips(w) end
    end
    -- THE FIRST KEY EVER (round 5): the card goes up, until Enter.
    if d.first == true and on() then
        card = true
        sendCard()
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

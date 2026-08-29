-- Player-placed markers: the pause-map ping.
--
-- PLACEMENT RIDES THE WAYPOINT GESTURE. The pause map's only scriptable
-- input is the native waypoint, so setting one IS the placement: the
-- coordinate is read, the waypoint is immediately consumed (SetWaypointOff
-- -- these are markers, not GPS), and the server relays it to whoever
-- should see it. Setting a waypoint ON your existing marker (within 120m)
-- removes it instead -- place and remove live in the same gesture.
--
-- Each marker is a map blip in the owner's squad colour plus a tall
-- coloured beam in the world -- 3x the storm wall's height (user spec),
-- visible across a rotation. One marker per player, squad-visible in
-- squads, private in solo; the server scopes, this file only renders.

BR = BR or {}

local markers = {}   -- [owner] = { x, y, colour, blip, gz, gzAt }

-- Colours come from BR.SquadColours (br_lib/shared/enums.lua), keyed on the
-- owner's stable member index -- the SAME table the minimap beacons use, so a
-- teammate is one colour everywhere. NEVER PURPLE, in any slot including the
-- fallback: purple belongs to the storm alone (user call, 2026-08-04).
local SOLO_COLOUR = '#FBBF24'   -- amber: reads "ping", nothing like the storm

local function hexToRgb(hex)
    if type(hex) ~= 'string' then return 255, 255, 255 end
    local r, g, b = hex:match('^#(%x%x)(%x%x)(%x%x)$')
    if not r then return 255, 255, 255 end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

-- OUR OWN MARKER BLIPS, BY HANDLE.
--
-- The placement watcher finds the player's waypoint with GetFirstBlipInfoId(8)
-- -- 8 is the waypoint sprite, and that is the standard trick. The moment
-- destination markers ALSO became sprite 8, the watcher started finding THEM:
-- it read another player's marker as a freshly placed waypoint, consumed it,
-- and re-placed the reader's own marker there. Which is exactly the reported
-- symptom -- a second marker deleting the first and taking its colour (user,
-- 2026-08-05).
--
-- Keeping the sprite (it is the right icon) means the watcher has to know
-- which sprite-8 blips are ours and skip them.
local ownBlips = {}

local function removeMarker(owner)
    local m = markers[owner]
    if m then
        if m.blip and DoesBlipExist(m.blip) then RemoveBlip(m.blip) end
        if m.blip then ownBlips[m.blip] = nil end
        markers[owner] = nil
    end
end

RegisterNetEvent(BR.Net.MARKER_SYNC)
AddEventHandler(BR.Net.MARKER_SYNC, function(d)
    if type(d) ~= 'table' or not d.owner then return end
    if d.op == 'clear' then
        removeMarker(d.owner)
        return
    end

    removeMarker(d.owner)   -- a re-place moves it: old blip goes first

    -- ONE PALETTE, KEYED ON THE MEMBER INDEX. The same table the minimap
    -- beacons use, so a teammate is one colour everywhere: their dot, their
    -- destination, and the beam standing on it. Solo has no index and keeps
    -- the amber default.
    local colour = d.i and BR.SquadColour(d.i) or nil
    local hex = colour and colour.hex or SOLO_COLOUR
    local blipColour = colour and colour.blip or 5

    local blip = AddBlipForCoord(d.x, d.y, 0.0)
    -- Sprite 8, radar_waypoint: a destination, visibly not a player. Both
    -- were sprite 1 and the map could not tell them apart (user, 2026-08-05).
    SetBlipSprite(blip, 8)
    SetBlipColour(blip, blipColour)
    SetBlipScale(blip, 1.1)
    SetBlipAsShortRange(blip, false)
    -- Named, so the legend says WHOSE destination this is rather than
    -- whatever GTA calls sprite 8.
    --
    -- The owner's name comes from the roster mirror, not from the payload:
    -- MARKER_SYNC carries owner/x/y/i and nothing else, so reading d.name
    -- would have quietly fallen back to the generic label forever.
    local who = BR.State.roster[d.owner]
    BR.Native.blipName(blip,
        who and who.name and (who.name .. "'s Marker") or 'Squad Marker')
    ownBlips[blip] = true
    markers[d.owner] = { x = d.x, y = d.y, colour = hex, blip = blip }
end)

-- The placement watcher: a fresh waypoint while in a match becomes a marker.
BR.Loop.register(BR.Loop.TICK, 'markers.place', function()
    if not IsWaypointActive() then return end

    -- THE RESCUE'S WAYPOINT IS NOT A PING. This pass consumes any fresh
    -- waypoint and turns it into a squad marker -- correct for a player
    -- clicking the map, and exactly wrong for the one client/rescue.lua sets to
    -- show a downed player where the ambulance is taking them. Without this the
    -- destination waypoint would be eaten on the tick after it was set.
    if BR.Rescue and BR.Rescue.riding and BR.Rescue.riding() then return end

    -- AND A SURVEY'S WAYPOINT IS NOT A PING EITHER. /brsurvey
    -- (client/survey.lua) authors the map boundary out of this exact gesture --
    -- the owner clicks a dozen or two corners on the pause map and each one
    -- becomes a vertex -- and the two cannot both consume it. Same precedent as
    -- the ride above, same shape of guard, and for the same reason: the tool
    -- that wants the gesture says so, and this pass stands down while it does.
    if BR.Survey and BR.Survey.active and BR.Survey.active() then return end

    local st = BR.State.me.state
    if st == BR.PlayerState.LOBBY or st == BR.PlayerState.LEFT then return end

    -- Walk the sprite-8 blips past our OWN markers to the real waypoint. Ours
    -- wear the same sprite deliberately, so the first hit is very often a
    -- teammate's destination rather than the thing the player just placed.
    local blip = GetFirstBlipInfoId(8)
    while DoesBlipExist(blip) and ownBlips[blip] do
        blip = GetNextBlipInfoId(8)
    end
    if not DoesBlipExist(blip) then return end
    local c = GetBlipInfoIdCoord(blip)
    SetWaypointOff()

    local mine = markers[BR.State.me.src]
    if mine and BR.Dist(c.x, c.y, mine.x, mine.y) < 120.0 then
        TriggerServerEvent(BR.Net.MARKER_CLEAR)
    else
        TriggerServerEvent(BR.Net.MARKER_SET, { x = c.x, y = c.y })
    end
end)

-- The world beams. Always drawn -- at 6x wall height they are landmarks,
-- and there are at most four of them.
BR.Loop.register(BR.Loop.FRAME, 'markers.beam', function()
    if not next(markers) then return end

    local beamH = ((BR.Config.Storm.render and BR.Config.Storm.render.height)
        or 300.0) * 6.0
    local now = GetGameTimer()
    -- Distance from the RENDERED CAMERA, not the ped: aboard the bus the
    -- ped is nowhere near the view, and the beams must read from the
    -- flight (user call, 2026-08-04).
    local cc = GetFinalRenderedCamCoord()

    for _, m in pairs(markers) do
        -- Ground probe, cached: the beam must stand ON the terrain. A
        -- failed distant probe falls back to the last answer (or sea level).
        if not m.gz or now - (m.gzAt or 0) > 5000 then
            local ok, gz = GetGroundZFor_3dCoord(m.x, m.y, 500.0, false)
            if ok then m.gz = gz end
            m.gz = m.gz or 0.0
            m.gzAt = now
        end
        local r, g, b = hexToRgb(m.colour)
        -- A fixed-width cylinder vanishes into a subpixel sliver seen from
        -- the bus 5-10km out -- "the markers don't draw from the plane" was
        -- angular size, not culling. Past ~800m the radius grows with
        -- distance (~1% of range) so the beam keeps a readable width from
        -- anywhere on the route.
        local dist = BR.Dist(cc.x, cc.y, m.x, m.y)
        local rad = 10.0 + math.max(0.0, dist - 800.0) * 0.01
        DrawMarker(1, m.x, m.y, m.gz - 10.0,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            rad, rad, beamH,
            r, g, b, 130,
            false, false, 2, false, nil, nil, false)
    end
end)

-- CLEARING THE PLAYER'S OWN MAP WAYPOINT.
--
-- GTA's only way to remove one is to open the pause map, find the flag and
-- click it again -- which mid-match means going to a full-screen menu to undo
-- a misclick (user, 2026-08-06). SetWaypointOff is the engine's own call for
-- it and touches nothing else: squad pings are our blips, tracked separately
-- in `markers`, and are unaffected.
BR.Keys.on('clearWaypoint', function(pressed)
    if not pressed then return end

    -- BOTH KINDS OF MARK, one key.
    --
    -- There were two ways to put a mark on the map and no obvious way to take
    -- either off. GTA's own waypoint needs the pause map and a second click on
    -- the flag; OUR squad ping could only be cleared by pressing the ping key
    -- again while standing within 120m of it -- which is useless for the ping
    -- you placed on a building across the valley, and undiscoverable anyway
    -- (user, 2026-08-06). This clears whichever exists, unconditionally and
    -- from anywhere.
    if IsWaypointActive() then SetWaypointOff() end
    if markers[BR.State.me.src] then
        TriggerServerEvent(BR.Net.MARKER_CLEAR)
    end
end)

-- Between matches the world is a different place; markers do not carry over.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WAITING or d.state == BR.MatchState.CLEANUP then
        for owner in pairs(markers) do removeMarker(owner) end
    end
end)

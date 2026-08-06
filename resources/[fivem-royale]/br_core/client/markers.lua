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

local function removeMarker(owner)
    local m = markers[owner]
    if m then
        if m.blip and DoesBlipExist(m.blip) then RemoveBlip(m.blip) end
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
    markers[d.owner] = { x = d.x, y = d.y, colour = hex, blip = blip }
end)

-- The placement watcher: a fresh waypoint while in a match becomes a marker.
BR.Loop.register(BR.Loop.TICK, 'markers.place', function()
    if not IsWaypointActive() then return end

    local st = BR.State.me.state
    if st == BR.PlayerState.LOBBY or st == BR.PlayerState.LEFT then return end

    local blip = GetFirstBlipInfoId(8)   -- 8 = the waypoint sprite
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

-- Between matches the world is a different place; markers do not carry over.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WAITING or d.state == BR.MatchState.CLEANUP then
        for owner in pairs(markers) do removeMarker(owner) end
    end
end)

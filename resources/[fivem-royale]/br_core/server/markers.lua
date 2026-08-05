-- Player-placed map markers.
--
-- One marker per player. In solo only its owner ever hears about it; in
-- squads the whole squad does, tinted the owner's squad colour -- the same
-- colour their name tag and smoke trail wear. The server relays and scopes;
-- it derives nothing from the coordinates (a marker is a note, not a
-- gameplay object).

BR = BR or {}

local markers = {}   -- [src] = { x, y }

--- Everyone who should see this player's marker: themselves, plus their
--- squadmates when they have any.
local function audience(src)
    local entry = BR.Roster.get(src)
    local list = { src }
    if entry and entry.squadId then
        BR.Roster.each(
            function(e) return e.squadId == entry.squadId end,
            function(other)
                if other ~= src then list[#list + 1] = other end
            end)
    end
    return list
end

local function pushTo(list, payload)
    for _, target in ipairs(list) do
        TriggerClientEvent(BR.Net.MARKER_SYNC, target, payload)
    end
end

RegisterNetEvent(BR.Net.MARKER_SET)
AddEventHandler(BR.Net.MARKER_SET, function(d)
    local src = source
    local entry = BR.Roster.get(src)
    if not entry then return end
    if type(d) ~= 'table'
       or type(d.x) ~= 'number' or type(d.y) ~= 'number' then return end

    markers[src] = { x = d.x + 0.0, y = d.y + 0.0 }
    pushTo(audience(src), {
        op     = 'set',
        owner  = src,
        x      = d.x + 0.0,
        y      = d.y + 0.0,
        colour = entry.colour,   -- nil in solo; the client picks a default
    })
end)

RegisterNetEvent(BR.Net.MARKER_CLEAR)
AddEventHandler(BR.Net.MARKER_CLEAR, function()
    local src = source
    if not markers[src] then return end
    markers[src] = nil
    pushTo(audience(src), { op = 'clear', owner = src })
end)

-- Housekeeping: a marker whose owner is gone (left the match, disconnected)
-- must not beam forever on their squadmates' screens. The clear is broadcast
-- wide -- clearing an unknown marker is a no-op everywhere else, and the
-- owner's squad may already be unknowable by the time they vanish.
BR.Sched.every(5000, 'markers.sweep', function()
    for src in pairs(markers) do
        local entry = BR.Roster.get(src)
        if not entry or not BR.Server.isInMatch(entry.state) then
            markers[src] = nil
            TriggerClientEvent(BR.Net.MARKER_SYNC, -1, { op = 'clear', owner = src })
        end
    end
end)

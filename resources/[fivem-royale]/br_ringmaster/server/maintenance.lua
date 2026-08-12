--[[
    The game's half of a maintenance window.

    IT POLLS RATHER THAN BEING TOLD. The console could push "start draining"
    down the command channel, and that would be one fewer moving part -- but a
    pushed flag lives in memory, and a server that restarts mid-window would
    come back accepting players with nothing anywhere to notice. Reading the row
    every twenty seconds means the truth is re-derived continuously and heals
    itself after a restart on either side.

    WHAT IT DOES:
      * tells connected ADMINS when an update is waiting, so somebody schedules
        it rather than it sitting for three days
      * tells EVERYONE when a window is scheduled, in friendly terms, once
      * exposes BR.Ring.draining() for the connect gate, which is what actually
        holds the door
      * asks br_core to stop starting new matches while draining, because a
        match begun during a drain is one that will be interrupted by the very
        restart the drain exists to make painless

    ANNOUNCEMENTS ARE ONCE PER STATE, NOT PER POLL. A chat line every twenty
    seconds saying the same thing is how players learn to ignore chat, and the
    one time it matters is the time they have tuned it out.
]]

BR = BR or {}
BR.Ring = BR.Ring or {}

--- How often the window is re-read. Slower than the ban check because nothing
--- here is per-player: a twenty-second lag on "the server is draining" costs at
--- most one player joining who then gets told, while a tighter poll would spend
--- a DynamoDB read every few seconds forever.
local POLL_MS = 20000

--- Latest known window, or nil. Read by the gate.
local window = nil

--- Which announcements have already gone out, keyed by what they announced.
--- Cleared when the window goes away, so the NEXT window announces afresh.
local announced = {}

local nextReq = 0
local pending = {}

--- Is the server refusing new players right now?
---
--- DERIVED HERE, ONCE, so the gate and the announcements cannot disagree about
--- what "draining" means. `deploying` counts: the restart is imminent and
--- letting somebody in to be dropped seconds later is worse than turning them
--- away with an explanation.
--- @return boolean
function BR.Ring.draining()
    if not window then return false end
    local s = window.state
    if s == 'deploying' then return true end
    if s ~= 'scheduled' and s ~= 'draining' then return false end
    -- The clock, not the stored state: the console advances `scheduled` to
    -- `draining` on its own timer, and until that lands the row still says
    -- scheduled while the moment has passed.
    return os.time() * 1000 >= (window.drainStartsAt or 0)
end

--- The message shown to somebody turned away at the door.
--- @return string
function BR.Ring.drainMessage()
    local note = window and window.note or ''
    if note == '' then note = 'a server update' end
    return ('The server is preparing for %s.\n\n'):format(note)
        .. 'It is not accepting new players while the matches already running '
        .. 'finish up. This usually takes a few minutes -- try again shortly.'
end

--- Send a chat line to one player, or to everyone with -1.
local function tell(target, colour, text)
    TriggerClientEvent('chat:addMessage', target, {
        color = colour,
        multiline = true,
        args = { 'Server', text },
    })
end

--- Everyone currently connected who holds any admin scope.
---
--- Uses the SAME grants table the console authorises against, read through
--- br_ddb -- rather than FiveM's ace system, which is a separate notion of
--- "admin" that nobody has kept in sync. One source of truth or none.
local function tellAdmins(text)
    for _, src in ipairs(GetPlayers()) do
        local byKind = BR.Identity.ofPlayer(src)
        local license = BR.Identity.qualified('license', byKind.license)
        if license then
            local req = nextReq + 1
            nextReq = req
            pending[req] = function(scopes)
                if type(scopes) == 'table' and #scopes > 0 then
                    tell(tonumber(src), { 255, 180, 60 }, text)
                end
            end
            SetTimeout(5000, function() pending[req] = nil end)
            TriggerEvent('br:ddb:grantsFetch', req, license)
        end
    end
end

AddEventHandler('br:ddb:grantsResult', function(req, scopes)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(scopes)
end)

AddEventHandler('br:ddb:maintenanceResult', function(req, w, info)
    local cb = pending[req]
    if cb then
        pending[req] = nil
        cb(w, info or {})
    end
end)

--- One poll: read the row, announce anything new, adjust the match blocker.
local function poll()
    if GetResourceState('br_ddb') ~= 'started' then return end

    local req = nextReq + 1
    nextReq = req

    pending[req] = function(w, info)
        if info.error then
            -- FAIL OPEN, like everything else on this path. An unreadable
            -- maintenance row must not hold the door shut.
            window = nil
            return
        end

        local wasDraining = BR.Ring.draining()
        window = w

        -- A window that has ended clears the announcement memory, so the next
        -- one is announced properly rather than being swallowed as a repeat.
        local live = w and (w.state == 'scheduled' or w.state == 'draining' or w.state == 'deploying')
        if not live then
            if announced.scheduled or announced.draining then
                announced = {}
                tell(-1, { 120, 220, 140 },
                    'The server update is finished. Thanks for waiting -- back to normal.')
            end
            -- An update waiting with nobody scheduling it: nudge the admins who
            -- can do something about it. Once, not every poll.
            if w and (w.updateAvailable or 0) > 0 and not announced.update then
                announced.update = true
                tellAdmins(('A server update is ready (%d commit%s behind). '):format(
                    w.updateAvailable, w.updateAvailable == 1 and '' or 's')
                    .. 'Schedule it in Ringmaster when the timing suits.')
            end
            BR.Ring.setMatchBlock(false)
            return
        end

        announced.update = nil

        if not announced.scheduled then
            announced.scheduled = true
            tell(-1, { 120, 190, 255 },
                ('A server update has been scheduled by %s.'):format(w.createdByName)
                .. ' Nothing changes for you right now -- finish your match. '
                .. 'The update runs once everyone has left, so no game gets cut short.')
        end

        local nowDraining = BR.Ring.draining()
        if nowDraining and not announced.draining then
            announced.draining = true
            tell(-1, { 255, 200, 80 },
                'The server has stopped accepting new players while the update waits. '
                .. 'Carry on -- your match is unaffected, and the update starts once the server empties.')
        end

        -- Starting a match during a drain guarantees interrupting it, which is
        -- the exact outcome draining exists to avoid.
        BR.Ring.setMatchBlock(nowDraining)

        if wasDraining and not nowDraining then
            BR.Ring.setMatchBlock(false)
        end
    end

    SetTimeout(6000, function() pending[req] = nil end)
    TriggerEvent('br:ddb:maintenance', req)
end

--- Ask br_core to stop starting new matches.
---
--- THROUGH AN EVENT, not a direct call: br_ringmaster deliberately does not
--- depend on br_core (see the manifest), so it asks and does not care whether
--- anybody is listening. A server with no gamemode running has no matches to
--- block, and this quietly does nothing there.
local blocked = false
function BR.Ring.setMatchBlock(on)
    if on == blocked then return end
    blocked = on
    TriggerEvent('br:ringmaster:blockMatches', on)
    print(('^3[br_ringmaster] new matches %s^7'):format(on and 'BLOCKED (maintenance)' or 'allowed'))
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- First poll shortly after boot rather than immediately: br_ddb may still
    -- be starting, and a failed first read would just log noise.
    SetTimeout(5000, poll)
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(POLL_MS)
        poll()
    end
end)

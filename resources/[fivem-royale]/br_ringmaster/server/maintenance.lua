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
local POLL_IDLE_MS = 20000

--- While a window is LIVE, poll far more often.
---
--- A cancel has to reopen the door quickly: an admin who calls off maintenance
--- and watches players still bounce for another twenty seconds reasonably
--- concludes the cancel did not work. Nothing else here is urgent, so the fast
--- rate applies only while there is something to be urgent about.
local POLL_LIVE_MS = 4000

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

--- Notify one player, or everyone with -1.
---
--- THROUGH THE GAMEMODE'S OWN NOTIFY CHANNEL, not chat:addMessage. This server
--- does not ensure FiveM's  resource at all -- it has its own NUI -- so
--- every maintenance announcement was being sent into a void. The symptom was
--- perfect silence in game while the console showed the window advancing
--- correctly, which is indistinguishable from the poller not running.
local function tell(target, tone, text)
    TriggerClientEvent(BR.Net.NOTIFY, target, {
        text = text,
        tone = tone,
        ms   = 12000,
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
                    tell(tonumber(src), 'warn', text)
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
                tell(-1, 'success',
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

        local nowDraining = BR.Ring.draining()

        --[[
            ONE MESSAGE PER PLAYER, NOT TWO.

            The default window starts draining immediately, so the first poll
            that sees it satisfies both conditions at once and fired both
            announcements in the same tick -- two notifications, stacked,
            thirty-one seconds apart from nothing.

            They also said the same thing twice: "finish your match, the update
            runs once everyone leaves" and "carry on, your match is unaffected".
            So the two cases collapse into one line each, and only the one that
            is actually true right now is sent.
        ]]
        if nowDraining then
            if not announced.draining then
                announced.draining = true
                announced.scheduled = true   -- the earlier notice is moot now
                -- AN ESTIMATE, BECAUSE "SOON" IS NOT AN ANSWER. The thing a
                -- player actually wants to know is whether to wait or go and do
                -- something else, and that question needs a number. The deploy
                -- is a git pull and a resource restart -- comfortably under five
                -- minutes -- so the figure is honest rather than optimistic.
                tell(-1, 'warn',
                    'A server update is pending. No new matches can be started. '
                    .. 'Estimated downtime: under 5 minutes.')
            end
        elseif not announced.scheduled then
            announced.scheduled = true
            tell(-1, 'info',
                ('Server update scheduled by %s. It runs once everyone has left, '):format(w.createdByName)
                .. 'so no match gets cut short.')
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
        Citizen.Wait(window and POLL_LIVE_MS or POLL_IDLE_MS)
        poll()
    end
end)

-- Spectate sessions: who is watching whom, and whether they are allowed to.
--
-- THE SERVER OWNS THE TARGET AND THE CLIENT OWNS THE CAMERA. Everything about
-- who may be looked at is decided here and in br_lib/shared/spectate_solve.lua;
-- the client is told one target at a time and never sees a candidate list. That
-- is the same rule chat's `squad` channel follows and for the same reason -- a
-- client-side filter is not a privacy boundary.
--
-- IT IS ALSO THE ONLY SIDE THAT CAN SEE A TARGET AT ALL. Under OneSync a player
-- across the map is out of the spectator's scope, so the client cannot read
-- their position even if it were allowed to. roster.lua already samples every
-- player's coordinates server-side (for the storm, the anticheat and this), so
-- the feed below is a projection of a sample that was already being taken.
--
-- ═══ TWO CALLERS, TWO POLICIES, ONE SESSION TABLE ═══
--
--   player  a dead player watching their own squad, widening only once the
--           squad is gone. spectate_solve.playerTargets.
--   admin   the console pointing a moderator at one named person.
--           spectate_solve.adminTargets, and an audit row for every session.
--
-- ═══ THE RECYCLED SERVER ID ═══
--
-- FiveM recycles server ids within the minute, and a camera still pointed at a
-- departed player is the same class of bug as a report filed against a recycled
-- id -- which this project has already been bitten by (br_ringmaster's
-- findByLicense carries the other half of that scar). So a session remembers the
-- target's LICENSE as well as their id, and the feed re-checks the pair on every
-- push. A disconnect handler is the fast path; the licence check is what makes
-- the fast path optional rather than load-bearing.

BR = BR or {}
BR.Spectate = {}

--- [watcherSrc] = session
---
--- ONE SESSION PER WATCHER, and the table is keyed that way so it cannot be two.
--- A second start replaces the first, which is the answer a player would predict
--- and the one that cannot leak a camera.
---
---   target        integer   server id being watched
---   targetLicense string|nil  who that id was when the session opened
---   name          string    for the audit row and the client's own display
---   kind          'player' | 'admin'
---   startedAt     integer   GetGameTimer()
---   commandId     string|nil  admin only: the console's audit join key
---   adminLicense  string|nil  admin only
local sessions = {}

--- [targetSrc] = { [watcherSrc] = true }
---
--- THE REVERSE INDEX EXISTS FOR ONE EVENT: playerDropped. Without it, a
--- disconnect would walk every session on the server to find the ones pointed at
--- the leaver -- cheap at 48 and the wrong shape at the 2048 this project is
--- heading for. Kept in step with `sessions` by exactly two functions, below.
local watchers = {}

local function unwatch(src, target)
    local w = watchers[target]
    if not w then return end
    w[src] = nil
    if next(w) == nil then watchers[target] = nil end
end

local function watch(src, target)
    local w = watchers[target]
    if not w then
        w = {}
        watchers[target] = w
    end
    w[src] = true
end

-- ------------------------------------------------------------- microphone ---

--- A SPECTATOR MAY LISTEN AND MAY NOT TALK. Unconditional, both kinds.
---
--- "whoever is the spectator should NEVER be able to talk, only listen" -- the
--- owner. It is not a config key and not a policy that varies by `kind`: a dead
--- player narrating their squad's fight and an admin whose voice arrives out of
--- nowhere beside a suspect are the same defect, and the second is worse.
---
--- IT IS CALLED FROM EXACTLY TWO PLACES BECAUSE THERE ARE EXACTLY TWO EDGES --
--- `sessions[src]` gaining an entry and losing one. Both creation sites
--- (`resolve` for a player, `adminStart` for an admin) funnel through the same
--- call, and `BR.Spectate.stop` is the only teardown; anything that adds a
--- third edge without coming here is a spectator with an open microphone.
---
--- THE MUTE ITSELF IS SERVER-SIDE -- see BR.Voice.setSpectatorMuted, which
--- argues why the client's own gag is not enough on its own and why muted is
--- deliberately not deafened.
--- @param src integer
--- @param on boolean
local function micFor(src, on)
    if BR.Voice and BR.Voice.setSpectatorMuted then
        BR.Voice.setSpectatorMuted(src, on)
    end
end

-- ------------------------------------------------------------------ audit ---

--- Tell the console that an admin session started, moved or ended.
---
--- THE GAME EMITS THE FACT; THE CONSOLE WRITES THE ROW. This is a plain
--- server-side TriggerEvent into br_ringmaster, which is the direction this
--- project's cross-resource traffic already runs (server/ringmaster.lua's
--- snapshot, server/incident.lua's refusals). br_core does not know what an
--- outbox is and must not: br_ringmaster owns the wire, and br_core would be
--- depending on the console if it reached for one.
---
--- PLAYER SESSIONS ARE NOT AUDITED, deliberately. An admin watching somebody who
--- does not know they are being watched is the class of action the audit log
--- exists for -- the same as a kick or a ban. A player watching their own
--- squadmate is gameplay, and filing a row for every death in every match would
--- bury the rows that matter under the ones that do not.
--- @param s table    the session
--- @param phase string 'start' | 'stop'
--- @param reason string|nil
local function audit(s, phase, reason)
    if s.kind ~= 'admin' then return end
    TriggerEvent('br:ringmaster:spectate', {
        commandId     = s.commandId,
        adminLicense  = s.adminLicense,
        targetLicense = s.targetLicense,
        targetName    = s.name,
        phase         = phase,
        reason        = reason,
        -- MILLISECONDS WATCHED, not two timestamps for the console to subtract.
        -- Every clock in this game is GetGameTimer(), which is meaningless the
        -- moment it leaves the box (br_ringmaster/server/main.lua's clockPair
        -- note); a duration survives the trip and a raw reading does not.
        durationMs    = (phase == 'stop') and (GetGameTimer() - s.startedAt) or nil,
    })
end

-- ------------------------------------------------------------------- wire ---

local function push(src, s)
    local e = BR.Roster.get(s.target)
    local pos = e and e.pos
    TriggerClientEvent(BR.Net.SPECTATE_SET, src, {
        targetSrc = s.target,
        name      = s.name,
        admin     = s.kind == 'admin',
        -- ABSENT RATHER THAN ZEROED when the target has not been sampled yet.
        -- (0,0,0) is a real place in the ocean and the camera would go there;
        -- a missing position leaves the camera where it was for one push, which
        -- is what a sample gap actually looks like.
        x = pos and pos.x, y = pos and pos.y, z = pos and pos.z,
    })
end

--- End a session. Safe to call for a player who has none.
--- @param src integer
--- @param reason string  'stopped' | 'left' | 'target-left' | 'no-targets' | ...
function BR.Spectate.stop(src, reason)
    local s = sessions[src]
    if not s then return false end

    sessions[src] = nil
    unwatch(src, s.target)
    -- THE MICROPHONE COMES BACK BEFORE ANYTHING ELSE CAN FAIL. Ordered ahead of
    -- the audit and the client push on purpose: those two reach other resources
    -- and a raise in either would otherwise leave a player who has stopped
    -- spectating unable to speak for the rest of the round, with nothing on
    -- their screen to explain it.
    micFor(src, false)
    audit(s, 'stop', reason)

    -- TOLD EVEN IF THEY ARE GONE. TriggerClientEvent to a departed source is a
    -- no-op, and the alternative -- checking first -- is a second place that can
    -- disagree with the roster about who is here.
    TriggerClientEvent(BR.Net.SPECTATE_SET, src, { stop = true, reason = reason })
    return true
end

-- --------------------------------------------------------------- policies ---

--- The candidate rows for a PLAYER spectator, and the policy that produced them.
---
--- The squad rule is not applied here -- it is applied in spectate_solve, where
--- it is the structure of the function and can be tested without a server. This
--- only projects the roster into the view that function takes.
local function playerView(src, entry)
    local players = {}
    BR.Roster.each(
        function(e) return e.matchId == entry.matchId end,
        function(psrc, e)
            players[#players + 1] = {
                src     = psrc,
                squadId = e.squadId,
                name    = e.name,
                -- ONE DEFINITION OF "STILL IN THE FIGHT", and it is
                -- BR.Server.isInMatch -- the same answer the alive count, the
                -- win condition and the HUD read. A second definition here
                -- would drift, and the way it would drift is a dead squadmate
                -- staying on the wheel.
                living  = BR.Server.isInMatch(e.state),
            }
        end)

    return {
        mySrc   = src,
        squadId = entry.squadId,
        free    = BR.Config.Spectate.freeAfterSquadOut == true,
        players = players,
    }
end

--- The candidate rows for an ADMIN: every connected player, filtered by the
--- solver down to the one they named.
local function adminView(want)
    local players = {}
    BR.Roster.each(nil, function(psrc, e)
        players[#players + 1] = { src = psrc, name = e.name }
    end)
    return { want = want, players = players }
end

--- Resolve a PLAYER session's next target and apply it.
---
--- THE ONE PLACE A PLAYER'S TARGET IS EVER SET. Opening a session, the arrow
--- keys and the feed's re-resolve all come through here, so the squad rule runs
--- on every path and there is no second route that skips it.
---
--- ADMIN SESSIONS DO NOT COME THROUGH HERE AT ALL, and that is why there is no
--- `if kind == 'admin'` branch to be found in it. An admin session names one
--- person, is opened by adminStart, is never cycled, and ends rather than moves
--- -- so a shared function with a privilege flag would be a flag with exactly
--- one caller on each side and a policy that could be reached with the wrong
--- one.
---
--- @param src integer
--- @param dir number  +1 / -1 / 0
--- @return boolean running
local function resolve(src, dir)
    local s = sessions[src]
    local entry = BR.Roster.get(src)
    if not entry then
        if s then BR.Spectate.stop(src, 'gone') end
        return false
    end
    if not entry.matchId then
        if s then BR.Spectate.stop(src, 'no-match') end
        return false
    end

    local list = BR.SpectateSolve.playerTargets(playerView(src, entry))
    local pick = BR.SpectateSolve.step(list, s and s.target, dir)
    if not pick then
        if s then BR.Spectate.stop(src, 'no-targets') end
        return false
    end

    if s then
        if pick.src ~= s.target then
            unwatch(src, s.target)
            s.target = pick.src
            s.targetLicense = BR.Roster.licenseOf(pick.src)
            s.name = pick.name
            watch(src, pick.src)
        end
    else
        s = {
            target        = pick.src,
            targetLicense = BR.Roster.licenseOf(pick.src),
            name          = pick.name,
            kind          = 'player',
            startedAt     = GetGameTimer(),
        }
        sessions[src] = s
        watch(src, pick.src)
        micFor(src, true)
    end

    push(src, s)
    return true
end

-- ---------------------------------------------------------------- players ---

RegisterNetEvent(BR.Net.SPECTATE_CYCLE)
AddEventHandler(BR.Net.SPECTATE_CYCLE, function(d)
    local src = source
    local dir = tonumber(type(d) == 'table' and d.dir or 0) or 0

    -- AN ADMIN SESSION DOES NOT CYCLE, AND THE ARROWS MUST NOT SILENTLY MOVE
    -- IT. The console named one person; the keys belong to the player policy.
    -- Refusing here rather than in the client is the same rule as everywhere
    -- else in this file -- the client is not where a permission is decided.
    local s = sessions[src]
    if s and s.kind == 'admin' then return end

    -- ONLY THE OUT-OF-THE-FIGHT MAY WATCH. A living player pressing the arrow
    -- gets nothing: BR.Server.isInMatch is the same test that decides whether
    -- they count toward the alive number, so "can still play" and "may watch"
    -- are answers to one question and cannot come apart.
    local entry = BR.Roster.get(src)
    if not entry or BR.Server.isInMatch(entry.state) then return end

    resolve(src, dir)
end)

RegisterNetEvent(BR.Net.SPECTATE_STOP)
AddEventHandler(BR.Net.SPECTATE_STOP, function()
    BR.Spectate.stop(source, 'stopped')
end)

-- ------------------------------------------------------------------ admin ---

--- Start an admin session. Called by br_ringmaster's brspectate, never by a
--- client.
---
--- IT RE-CHECKS NOTHING ABOUT AUTHORISATION, and that is the same decision
--- br_ringmaster/server/kick.lua records: authorisation happened in the console
--- against the acting admin's scopes, and the admin's identity travels only as
--- an AUDIT field. Anything able to put bytes on that channel already has
--- console authority.
---
--- @param opts table  { admin, target, adminLicense, targetLicense, commandId }
--- @return boolean ok, string detail
function BR.Spectate.adminStart(opts)
    opts = opts or {}
    local src, target = tonumber(opts.admin), tonumber(opts.target)
    if not src or not target then return false, 'bad ids' end

    local list = BR.SpectateSolve.adminTargets(adminView(target))
    local pick = list[1]
    if not pick then return false, 'target not connected' end

    -- WATCHING YOURSELF IS NOT A MODERATION TOOL. Cheap to refuse and confusing
    -- to allow -- the camera would orbit the admin's own ped while their ped
    -- stops answering the controls the camera has taken.
    if src == target then return false, 'cannot spectate yourself' end

    -- A SECOND START REPLACES THE FIRST, and the first one's audit row is
    -- CLOSED rather than abandoned. An admin who clicks Spectate on a second
    -- player has ended the first session as surely as if they had pressed the
    -- pause-menu exit, and the log should say so with a duration.
    BR.Spectate.stop(src, 'retargeted')

    local s = {
        target        = target,
        targetLicense = BR.Roster.licenseOf(target),
        name          = pick.name,
        kind          = 'admin',
        startedAt     = GetGameTimer(),
        commandId     = opts.commandId,
        adminLicense  = opts.adminLicense,
    }
    sessions[src] = s
    watch(src, target)
    micFor(src, true)
    audit(s, 'start')
    push(src, s)

    print(('[br_core] spectate: admin %d -> %s (%d)')
        :format(src, tostring(s.name), target))
    return true, s.name
end

--- br_ringmaster asking, on the console's behalf. The reply rides back on the
--- same event idiom rather than a return value: the two resources are separate
--- Lua states and a direct call across them is the mistake server/ringmaster.lua
--- already records ("the first version of this read nil forever from over
--- there").
AddEventHandler('br:core:spectate', function(opts)
    local ok, detail = BR.Spectate.adminStart(opts)
    TriggerEvent('br:core:spectateResult', {
        commandId = opts and opts.commandId,
        ok        = ok,
        detail    = detail,
    })
end)

-- ------------------------------------------------------------- the leaver ---

--- The case that gets got wrong (#192).
---
--- A camera pointed at a departed player is not merely blank -- FiveM hands that
--- id to the next person to connect, within the minute, so it becomes a camera
--- pointed at somebody the watcher was never entitled to see. This handler is
--- the fast path. The feed's licence check below is the one that has to be
--- right, because this event can be missed (a resource restart mid-session) and
--- that one cannot.
AddEventHandler('playerDropped', function()
    local gone = source

    -- Their own session, if they were watching. This is also what gives the
    -- microphone back, which matters even though they are leaving: the src is
    -- handed to the next person to connect within the minute, and a mute record
    -- left standing against it would follow them.
    BR.Spectate.stop(gone, 'left')

    -- AND THE RECORD GOES EVEN IF THERE WAS NO SESSION TO STOP. `stop` returns
    -- early for a player who was not spectating, so it is not a place to hang
    -- cleanup that must happen either way.
    if BR.Voice and BR.Voice.forgetSpectatorMute then
        BR.Voice.forgetSpectatorMute(gone)
    end

    -- And everyone watching THEM.
    local w = watchers[gone]
    if not w then return end
    for src in pairs(w) do
        local s = sessions[src]
        if s and s.kind == 'admin' then
            -- "If the player being spectated leaves while being spectated, the
            -- 'stop spectating' function runs automatically" -- the owner,
            -- verbatim. An admin session names one person and there is nobody
            -- else it could reasonably move to.
            BR.Spectate.stop(src, 'target-left')
        else
            -- A player's wheel simply loses a spoke. Re-resolving keeps them
            -- watching their squad rather than dropping them out of spectate
            -- because one teammate's connection died.
            if not resolve(src, 1) then
                BR.Spectate.stop(src, 'target-left')
            end
        end
    end
end)

-- ------------------------------------------------------------------- feed ---

--- Positions out, and validity in, on one job.
---
--- THE SAME PASS DOES BOTH ON PURPOSE. A push and a validity check on separate
--- timers is two clocks that can disagree about whether a session exists, and
--- the window between them is exactly the window in which a camera is pointed
--- somewhere it should not be.
BR.Sched.every(BR.Config.Spectate.feedMs, 'spectate.feed', function()
    for src, s in pairs(sessions) do
        -- IS THIS STILL THE SAME PERSON? The id survives a disconnect; the
        -- licence does not. Comparing them is what makes a recycled id a stop
        -- rather than a silent change of subject.
        --
        -- A NIL LICENCE ON BOTH SIDES IS NOT A MATCH AND MUST NOT READ AS ONE:
        -- a licenceless connection has nil forever, so `nil == nil` would let
        -- any recycled id inherit the session. The session is only kept when the
        -- stored licence is a real string and still resolves to the same one.
        local now = BR.Roster.licenseOf(s.target)
        if s.targetLicense == nil or now == nil or now ~= s.targetLicense then
            BR.Spectate.stop(src, 'target-left')
        elseif s.kind == 'admin' then
            push(src, s)
        else
            -- A PLAYER'S TARGET IS RE-RESOLVED EVERY PUSH, not only when
            -- something obvious happens. The squad rule depends on who is still
            -- standing, and that changes without any event this file listens
            -- for -- a squadmate dying somewhere else is exactly the moment the
            -- set has to shrink, and the moment the last one dies is when it may
            -- widen. dir 0 holds the current target when it is still eligible,
            -- so the shot does not jump on every tick.
            resolve(src, 0)
        end
    end
end)

-- Nothing survives the resource going away: a session in this table with no
-- client counterpart is a camera nobody can turn off.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for src in pairs(sessions) do
        BR.Spectate.stop(src, 'shutdown')
    end
end)

-- ------------------------------------------------------------------ debug ---

RegisterCommand('brspectators', function(src)
    if src ~= 0 then return end
    print('=== spectate sessions ===')
    local any = false
    for watcher, s in pairs(sessions) do
        any = true
        print(('  %d -> %d (%s) %s  %.1fs  lic=%s'):format(
            watcher, s.target, tostring(s.name), s.kind,
            (GetGameTimer() - s.startedAt) / 1000, tostring(s.targetLicense)))
    end
    if not any then print('  (nobody is spectating)') end
    print(('  free after squad out: %s')
        :format(tostring(BR.Config.Spectate.freeAfterSquadOut)))
end, true)

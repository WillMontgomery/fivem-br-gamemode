-- Artifacts: taking the picture, and handing it to the thing that can upload it.
--
-- The bookkeeping -- how many frames, when, under what number -- lives in
-- br_lib/shared/artifact_plan.lua, which is pure and unit-tested. This file is
-- the half that cannot be tested outside the game: which events fire, which
-- resource takes the shot, which player it is taken of, and what the server
-- clock says. Same split as evidence_buf/evidence and combat_solve/damage.
--
-- ═══ NOTHING HERE TOUCHES THE PLAYER ═══
--
-- No notice, no hint, no sound, no prompt. `screenshot-basic` renders off the
-- game's own render target without drawing anything, and the subject is told
-- nothing at any point -- the same rule server/incident.lua states at length and
-- for the same reason: a player who discovers they are under suspicion changes
-- behaviour, which costs the case the evidence it was going to be made of.
--
-- ═══ THE GAME DOES NOT DEPEND ON RINGMASTER, AND STILL DOES NOT ═══
--
-- Frames go straight to S3 under the game box's own instance role, through
-- br_ddb -- the same resource, the same credential chain and the same region
-- that already reach DynamoDB. Nothing here calls the console, waits on it, or
-- notices whether it is running.
--
-- ═══ A PARTIAL SET IS THE NORMAL OUTCOME, NOT A FAULT ═══
--
-- The capture happens on the SUBJECT'S OWN CLIENT. They can disconnect, crash,
-- alt-tab, sit on a loading screen, or be running without `screenshot-basic` at
-- all. Every one of the frames fails independently, and a case with two frames
-- -- or none -- is a normal case. So:
--
--   * nothing in this file prints in an error colour. `^1` and `^3` mean "a
--     human should look at this", and a frame that did not arrive is not that.
--   * nothing here retries a frame. The moment has passed; the next scheduled
--     frame is the retry.
--   * nothing here changes the incident. The row was written before any of this
--     ran and is complete without it.
--
-- ═══ THE TIMESTAMP IS THE SERVER'S ═══
--
-- This is an anti-cheat surface. The whole premise is that the machine the
-- picture comes from may be running modified software, so its clock is not
-- evidence. Every artifact is stamped with `os.time()` on THIS box, sampled at
-- the moment the server decides to ask for the frame.
--
-- ASKED-AT RATHER THAN ARRIVED-AT, deliberately. The frame is rendered on the
-- client within a frame or two of the request and then spends an unknown amount
-- of time in transit; the request time is the one the server chose, is what the
-- +5s and +10s offsets are relative to, and cannot be stretched by a slow
-- upload. The cost, said out loud: an artifact's stamp is up to one upload
-- earlier than the instant the pixels were sampled.

BR = BR or {}
BR.Artifacts = {}

--- The capture resource. THIRD-PARTY AND NOT ASSUMED PRESENT -- see the standing
--- rule, and `available()` below.
local SHOT_RESOURCE = 'screenshot-basic'

--- What we ask the client to encode.
---
--- WEBP AT 0.92 (owner, 2026-08-20). Nine frames per incident upload from a
--- PLAYER'S connection in the middle of a match, so the format is the lever and
--- the quality is not: webp at 0.92 is materially smaller than jpg at the same
--- setting, which is how the bandwidth is paid for without giving up the
--- fidelity that makes a screenshot worth reviewing.
---
--- IT IS ONE CONSTANT AND THE EXTENSION FOLLOWS IT. br_ddb derives the key and
--- the Content-Type from this value rather than carrying its own copy, so
--- switching to 'jpg' after a playtest is this line and nothing else.
local ENCODING = 'webp'
local QUALITY  = 0.92

--- How long br_ddb gets to answer. Same convention and same reasoning as
--- server/market.lua's `ask`: a bridge that never answers must not leak a
--- pending closure per request for the life of the server.
local ASK_TIMEOUT_MS = 6000

--- How long a client gets to deliver a frame before we stop waiting for it.
---
--- LOAD-BEARING, BECAUSE `screenshot-basic` HAS NO TIMEOUT OF ITS OWN. Its
--- server half parks the callback in a table keyed by an upload token and only
--- ever fires it when a multipart POST arrives at its HTTP endpoint. A client
--- that disconnects, crashes or simply never uploads leaves that entry there
--- forever and OUR CALLBACK IS NEVER CALLED -- which is the commonest failure
--- this feature has. Without this timer every such frame would leak a closure
--- here too.
---
--- Fifteen seconds is chosen against the thing it competes with: the next timed
--- frame is five seconds away, so a client slow enough to miss this is a client
--- whose next frame is already in flight.
local SHOT_TIMEOUT_MS = 15000

local plan = BR.ArtifactPlan.new()

BR.Artifacts.plan = plan

--- Counters, for brdebug-style introspection. Every name here is neutral on
--- purpose: `lost` is not `failed`.
local stat = { asked = 0, stored = 0, lost = 0, bytes = 0, skipped = 0 }

-- ---------------------------------------------------------------------------
-- br_ddb
-- ---------------------------------------------------------------------------

local nextReq = 0
local pending = {}

AddEventHandler('br:ddb:artifactResult', function(req, ok, extra)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(ok, extra or {})
end)

--- One br_ddb request with a timeout of our own. The `ask` convention from
--- server/market.lua, copied rather than shared because the two files answer on
--- different result events.
local function ask(event, cb, ...)
    if GetResourceState('br_ddb') ~= 'started' then
        cb(false, { error = 'br_ddb not started' })
        return
    end
    local req = nextReq + 1
    nextReq = req
    pending[req] = cb
    SetTimeout(ASK_TIMEOUT_MS, function()
        if pending[req] then
            pending[req] = nil
            cb(false, { error = 'timed out' })
        end
    end)
    TriggerEvent(event, req, ...)
end

-- ---------------------------------------------------------------------------
-- The capture
-- ---------------------------------------------------------------------------

--- Can a frame be taken at all right now?
---
--- CHECKED EVERY TIME RATHER THAN ONCE AT START. A resource can be started,
--- stopped and restarted while the server runs, and the standing rule is not
--- "warn if it is missing at boot", it is "do not assume it is installed".
--- @return boolean
local function available()
    return GetResourceState(SHOT_RESOURCE) == 'started'
end

--- Did `screenshot-basic` report a failure?
---
--- THE `didHit` SCAR, ON A VALUE THAT IS DECLARED `string | boolean`. Its server
--- half calls back with `err || false` -- so success is the boolean `false` and
--- a failure is a message -- and that value crosses a JS-to-Lua resource
--- boundary before it gets here. IN LUA `0` IS TRUTHY, so a runtime that hands
--- back `0` for that `false` would make every successful capture read as a
--- failure and this feature would silently store nothing. Four shipped bugs in
--- this project came from reading a boundary value raw; this one is compared
--- against every shape that can mean "no error".
--- @param err any
--- @return boolean
local function reportedError(err)
    if err == nil or err == false or err == 0 then return false end
    return true
end

--- The server id of the player holding this license, or nil.
---
--- RESOLVED PER PLAYER FROM THE IDENTIFIERS, NOT READ OFF THE ROSTER ENTRY.
--- `entry.license` is documented as filled lazily -- by br_stats, if it is
--- running -- so a lookup against it would answer nil on a server without
--- br_stats and, worse, could answer for the wrong entry. server/incident.lua's
--- `announceReporting` resolves the same way for the same reason: there, getting
--- it wrong tells the offender they are under suspicion; here, getting it wrong
--- photographs an innocent player's screen. Both are failures this must not
--- have.
---
--- A DEPARTED ENTRY IS SKIPPED. Sealed copies keep a license and have no live
--- connection behind them, and server ids are recycled within the minute -- a
--- request addressed to a stale id is a request addressed to whoever landed in
--- that slot.
--- @param license string
--- @return integer|nil
local function srcFor(license)
    if license == nil or not BR.Roster then return nil end
    local found = nil
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src, _)
            if found ~= nil then return end
            local byKind = BR.Identity and BR.Identity.ofPlayer(src)
            local lic = byKind and BR.Identity.qualified('license', byKind.license)
            if lic ~= nil and lic == license then found = src end
        end)
    return found
end

--- Unix milliseconds, from THIS box. What an artifact is STAMPED with.
---
--- `os.time()` rather than `GetGameTimer()`, and this is the one place in
--- br_core that wants a wall clock. Every other timestamp the game produces is
--- milliseconds since server start, which is correct inside the game and
--- meaningless in a bucket that outlives the process -- br_ringmaster converts
--- them on the way out with a clock pair for exactly that reason. An artifact
--- has no envelope to ride and no converter waiting for it, so it is stamped in
--- real time at source.
--- @return number
local function stampMs()
    return os.time() * 1000
end

--- Milliseconds since the server started. What the SCHEDULE is measured in.
---
--- TWO CLOCKS, DELIBERATELY, AND THIS IS THE ONE THE RULES USE. `os.time()` has
--- one-second granularity and can be stepped by NTP, so a corroboration nine and
--- a half seconds after a filing could read as ten -- or, after a backward step,
--- as minus four. `GetGameTimer()` is monotonic and in milliseconds, which is
--- what "the first ten seconds have already elapsed" needs. The wall clock is
--- for the stamp, which has to mean something off the box; the game clock is for
--- the rule, which only has to mean something on it.
--- @return number
local function nowMs()
    return GetGameTimer()
end

--- Take one frame and upload it.
---
--- THE ORDER IS DELIBERATE: claim, then ask br_ddb where to put it, then take
--- the shot. Claiming first means the frame number is settled before anything
--- can go wrong, so two corroborations landing in the same tick cannot be handed
--- the same number and overwrite each other.
---
--- A CLAIM IS NOT RELEASED WHEN THE DISK REFUSES. br_ddb declining to hand out a
--- path means the spool is full or br_ddb is gone, and in that state no frame is
--- going to be taken anyway -- putting the number back would only spend it on
--- the next attempt to fail. The slot is bounded at nine regardless.
---
--- @param incidentId string
--- @param license string
--- @param kind string  'timed' | 'corroboration'
local function capture(incidentId, license, kind)
    -- CHEAPEST REFUSALS FIRST, AND NONE OF THEM SPEND A SLOT. A server without
    -- the capture resource, or a subject who has left, must cost this file
    -- nothing at all -- including nothing in the log, which is why `skipped` is
    -- a counter rather than a print.
    if not available() then
        stat.skipped = stat.skipped + 1
        return
    end

    local src = srcFor(license)
    if src == nil then
        stat.skipped = stat.skipped + 1
        return
    end

    -- The reason it refused is deliberately not read here. `plan:stats()` counts
    -- each kind separately for `brartifacts`, and acting on them differently
    -- would be inventing a distinction the caller does not have: every one of
    -- them means the same thing to this function, which is "no frame".
    local index = plan:claim(incidentId, kind, nowMs())
    if not index then
        -- EVERY REASON HERE IS A RULE WORKING. 'cap' is the seventh
        -- corroborator, 'covered' is a corroboration inside the ten seconds the
        -- timed frames already cover, 'unknown' is a case this process did not
        -- file. The owner's words: a seventh corroborator adds no frame and that
        -- is not a failure. Counted, never printed.
        stat.skipped = stat.skipped + 1
        return
    end

    local capturedAt = stampMs()

    ask('br:ddb:artifactBegin', function(ok, extra)
        if not ok or type(extra.path) ~= 'string' then
            stat.lost = stat.lost + 1
            print(('[br_core] artifact %s/%02d not taken: %s')
                :format(tostring(incidentId), index, tostring(extra.error)))
            return
        end

        local path, key = extra.path, extra.key
        stat.asked = stat.asked + 1

        -- ONE ANSWER PER REQUEST. The timeout below and the callback race each
        -- other whenever a client is merely slow rather than gone, and the loser
        -- must do nothing -- a second `artifactPut` would upload a file the
        -- first one has already deleted.
        local answered = false

        local function settle(taken, note)
            if answered then return end
            answered = true
            if not taken then
                stat.lost = stat.lost + 1
                -- PLAIN, NOT YELLOW. A frame that did not arrive is the normal
                -- outcome of photographing somebody else's machine, and dressing
                -- it as a warning would teach an operator to ignore the colour
                -- that means something.
                print(('[br_core] artifact %s not taken: %s'):format(tostring(key), note))
                return
            end
            ask('br:ddb:artifactPut', function(putOk, put)
                if putOk then
                    -- FLOORED BEFORE IT REACHES `%d`. A JS number crosses the
                    -- boundary as a Lua float, and string.format('%d', ...)
                    -- RAISES on a float with a fractional part -- so a byte count
                    -- that arrived a hair off integral would throw inside the
                    -- success path of a feature whose whole design is that
                    -- failures are quiet.
                    local bytes = math.floor(tonumber(put.bytes) or 0)
                    stat.stored = stat.stored + 1
                    stat.bytes = stat.bytes + bytes
                    print(('[br_core] artifact %s stored (%d bytes, %s)')
                        :format(tostring(key), bytes, kind))
                else
                    stat.lost = stat.lost + 1
                    print(('[br_core] artifact %s not stored: %s')
                        :format(tostring(key), tostring(put.error)))
                end
            end, incidentId, index, ENCODING, capturedAt)
        end

        SetTimeout(SHOT_TIMEOUT_MS, function()
            -- THE FILE MAY STILL LAND AFTER THIS. `screenshot-basic` keeps the
            -- upload token open indefinitely, so a client that comes back three
            -- minutes later still writes to `path` -- with nobody waiting. That
            -- orphan is br_ddb's to sweep, and it does, by age.
            settle(false, 'no answer from the client')
        end)

        -- pcall BECAUSE THE EXPORT IS SOMEBODY ELSE'S. `available()` was true a
        -- moment ago; a resource that stops between that check and this line
        -- raises rather than returning, and a raise here would take the event
        -- handler with it.
        local okCall, err = pcall(function()
            exports[SHOT_RESOURCE]:requestClientScreenshot(src, {
                encoding = ENCODING,
                quality  = QUALITY,
                -- The one field the client never sees: screenshot-basic strips
                -- it before it emits to them, so the subject cannot learn where
                -- on the server the frame lands.
                fileName = path,
            }, function(shotErr)
                -- The second return value is the path we just supplied; it is
                -- deliberately ignored. br_ddb derives the path it reads from
                -- the same id and index it derived this one from, so nothing
                -- filesystem-shaped ever crosses back over a boundary.
                settle(not reportedError(shotErr), tostring(shotErr))
            end)
        end)

        if not okCall then
            settle(false, tostring(err))
        end
    end, incidentId, index, ENCODING)
end

-- ---------------------------------------------------------------------------
-- What starts a capture
-- ---------------------------------------------------------------------------

-- ON THE ACKNOWLEDGEMENT, NOT ON THE FILING. `br:ringmaster:incident` carries no
-- id -- br_ddb mints it -- and a frame cannot be keyed to a case that has no
-- name yet. `br:incident:filed` is the acknowledgement br_ringmaster sends once
-- the row is DURABLE, so this also cannot photograph anybody on behalf of a case
-- that failed to write. It is the third handler on that event; the other two are
-- in server/incident.lua and server/players.lua, and none of the three knows the
-- others exist.
--
-- THE COST, STATED: "immediately" is measured from the acknowledgement rather
-- than from the report, so the first frame is one DynamoDB round trip late. The
-- alternative -- capture into a buffer at filing time and key it once the id
-- arrives -- would hold image bytes in memory for a write that may never land,
-- to save a second on a ten-second schedule.
AddEventHandler('br:incident:filed', function(ack)
    if type(ack) ~= 'table' then return end
    if type(ack.incidentId) ~= 'string' or ack.incidentId == '' then return end
    if ack.subjectLicense == nil then return end

    -- NOT EVEN OPENED WHEN THERE IS NOTHING TO CAPTURE WITH. An open case with a
    -- plan and no capture resource would refuse corroborations as 'cap' or
    -- 'covered' later, which would read as a rule firing rather than as a server
    -- that cannot take pictures.
    if not available() then return end

    if not plan:open(ack.incidentId, nowMs()) then return end

    -- THREE INDEPENDENT ATTEMPTS. Each resolves the subject again when it fires,
    -- because a player who was here at +0 may be gone at +5 -- and each claims
    -- its own number, so the second failing does not renumber the third.
    for _, offset in ipairs(BR.ArtifactPlan.timedOffsets()) do
        if offset == 0 then
            capture(ack.incidentId, ack.subjectLicense, 'timed')
        else
            SetTimeout(offset, function()
                capture(ack.incidentId, ack.subjectLicense, 'timed')
            end)
        end
    end
end)

-- ONE FRAME PER CORROBORATION, AND THIS IS THE ONLY PLACE THAT DECIDES IT.
--
-- `br:ringmaster:corroborate` is the single choke point every corroboration goes
-- through -- the anticheat's doubling in server/incident.lua, a second player's
-- report in server/players.lua, and the one-press TAB answer in the same file.
-- Listening to the event rather than being called from those three keeps this
-- file out of all of them, exactly as br_ringmaster's own listener does.
--
-- AN ADMIN'S CORROBORATION COUNTS (owner, e2298f8). There is no admin test here
-- and there must not be one: an admin earns nothing for corroborating, and their
-- corroboration is still evidence like any other.
--
-- THE TEN-SECOND RULE IS NOT APPLIED HERE. `plan:claim` owns it, along with the
-- cap, because they are the same decision -- "does this corroboration get a
-- frame" -- and splitting it across two files is how the two halves start
-- disagreeing.
AddEventHandler('br:ringmaster:corroborate', function(ev)
    if type(ev) ~= 'table' then return end
    if type(ev.incidentId) ~= 'string' or ev.incidentId == '' then return end
    if ev.license == nil then return end
    capture(ev.incidentId, ev.license, 'corroboration')
end)

-- ---------------------------------------------------------------------------
-- Introspection and lifecycle
-- ---------------------------------------------------------------------------

--- Counters, for brdebug.
function BR.Artifacts.stats()
    local s = plan:stats()
    s.asked   = stat.asked
    s.stored  = stat.stored
    s.lost    = stat.lost
    s.bytes   = stat.bytes
    s.skipped = stat.skipped
    s.enabled = available()
    return s
end

AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    plan:reset()
    -- ONE LINE, ONCE. The standing rule is that a missing third-party resource
    -- is a normal state, so this says which state we are in and then never
    -- mentions it again -- rather than a line per incident for the life of the
    -- server.
    if available() then
        print(('[br_core] artifacts: %s is running; frames will be %s at %.2f')
            :format(SHOT_RESOURCE, ENCODING, QUALITY))
    else
        print(('[br_core] artifacts: %s is not running -- incidents will carry no frames')
            :format(SHOT_RESOURCE))
    end
end)

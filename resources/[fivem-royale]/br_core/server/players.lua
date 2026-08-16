--[[
    The in-game player list, and the reports filed from it.

    THE SERVER RESOLVES THE BUCKET AND SENDS THE ANSWER. It never sends a
    matchId for the client to filter on -- `matchId` is marked NEVER PUBLIC in
    roster.lua's PUBLIC_FIELDS, and shipping it so the client can do the
    filtering would leak the exact field that projection exists to withhold.
    What goes out is a list of people, already correct.

    THIS IS AN INFORMATION CHANGE, AND THAT WAS A DELIBERATE CALL (owner,
    2026-08-12). Before this, a player knew how many were alive but not who.
    Names of the people you are fighting is a real thing to hand over, and it
    was weighed against the report flow needing somewhere to live. What is NOT
    handed over stays exactly as it was: no positions, no health, no inventory,
    no matchId.

    NO LIST IN THE LOBBY (owner). Tilde does nothing there. A lobby player has
    nobody to report and no bucket to be in.

    PLAYERS WHO LEFT STILL APPEAR, marked. Somebody who ragequits after cheating
    is precisely the person most worth reporting, and a list that drops them the
    moment they disconnect makes that impossible. The roster keeps the entry
    until the match is destroyed; this renders it rather than filtering it.
]]

BR = BR or {}
BR.Players = BR.Players or {}

--- license -> reports submitted this match, and which match that was.
---
--- KEYED ON LICENSE, NOT SOURCE. A server id is recycled within the minute, so
--- a limit keyed on one would be handed to whoever connects into that slot next
--- -- either giving somebody a fresh allowance by reconnecting, or charging a
--- stranger for reports they did not file.
local usage = {}

--- Reports counted for a license in a match, resetting when the match changes.
local function usageFor(license, matchId)
    local u = usage[license]
    if not u or u.matchId ~= matchId then
        u = { matchId = matchId, count = 0 }
        usage[license] = u
    end
    return u
end

--- Everyone in the same bucket as this player.
---
--- @param src integer
--- @return table|nil rows, integer|nil matchId
function BR.Players.listFor(src)
    local me = BR.Roster.get(src)
    if not me or not me.matchId then return nil, nil end

    local rows = {}
    BR.Roster.each(
        function(e) return e.matchId == me.matchId end,
        function(otherSrc, e)
            rows[#rows + 1] = {
                src     = otherSrc,
                name    = e.name,
                -- Already public: PUBLIC_FIELDS carries state and squadId, so
                -- this widens nothing. It is what lets the panel grey out your
                -- own squad and mark who has gone.
                state   = e.state,
                squadId = e.squadId,
                left    = e.state == BR.PlayerState.LEFT,
                you     = otherSrc == src,
            }
        end)

    -- DETERMINISTIC ORDER. `each` walks a hash, and a list that reshuffles
    -- between two-second refreshes is one where a player clicks the wrong
    -- checkbox. Sorted by name, with the departed last -- they are the least
    -- likely to be the subject and the most likely to be scrolled past.
    table.sort(rows, function(a, b)
        if a.left ~= b.left then return not a.left end
        return (a.name or '') < (b.name or '')
    end)

    return rows, me.matchId
end

--- Send one player their bucket, plus the report rules.
--- @param src integer
function BR.Players.push(src)
    local rows, matchId = BR.Players.listFor(src)
    if not rows then
        -- Explicitly empty rather than silent: the panel has to be able to tell
        -- "not in a match" from "the request went nowhere".
        TriggerClientEvent(BR.Net.PLAYERS_LIST, src, { inMatch = false, players = {} })
        return
    end

    local license = BR.Identity and BR.Identity.qualified(
        'license', (BR.Identity.ofPlayer(src) or {}).license)
    local used = license and usageFor(license, matchId).count or 0

    TriggerClientEvent(BR.Net.PLAYERS_LIST, src, {
        inMatch    = true,
        players    = rows,
        -- THE RULES TRAVEL WITH THE DATA. The panel cannot invent its own limit
        -- and must not hardcode one that drifts from the server's.
        categories = BR.Config.Report.categories,
        defaultCategory = BR.Config.defaultReportCategory(),
        maxTargets = BR.Config.Report.maxTargets,
        remaining  = math.max(0, BR.Config.Report.maxPerMatch - used),
    })
end

RegisterNetEvent(BR.Net.PLAYERS_ASK)
AddEventHandler(BR.Net.PLAYERS_ASK, function()
    BR.Players.push(source)
end)

--- Tell the reporter what happened.
local function answer(src, ok, filed, refused)
    TriggerClientEvent(BR.Net.REPORT_RESULT, src, {
        ok = ok, filed = filed or 0, refused = refused,
    })
end

--[[
    A submitted report.

    EVERYTHING THE CLIENT SENT IS TREATED AS A CLAIM. It names server ids and a
    category string; the server resolves both. A modified client can ask to
    report anybody for anything and gets exactly the same treatment as an honest
    one -- refused for the same reasons, counted against the same limit.

    THE ANSWER WAITS FOR THE WRITE. The promise made to the player is that an
    admin will review it, and that is only true once a row exists. Reporting
    success on receipt would be a lie in exactly the case that matters: the one
    where the write failed.
]]
RegisterNetEvent(BR.Net.REPORT_SUBMIT)
AddEventHandler(BR.Net.REPORT_SUBMIT, function(data)
    local src = source
    if type(data) ~= 'table' then return end

    local me = BR.Roster.get(src)
    if not me or not me.matchId then
        answer(src, false, 0, 'You can only report from inside a match.')
        return
    end

    local byKind = BR.Identity and BR.Identity.ofPlayer(src)
    local reporter = byKind and BR.Identity.qualified('license', byKind.license)
    if not reporter then
        -- Without a license the report cannot be attributed, and an
        -- unattributable accusation is worth less than none: the console's
        -- "who reports everybody" signal depends on knowing who filed it.
        answer(src, false, 0, 'Your account could not be identified.')
        return
    end

    local u = usageFor(reporter, me.matchId)
    if u.count >= BR.Config.Report.maxPerMatch then
        -- COUNTED EVEN THOUGH IT IS REFUSED. Somebody hammering the limit is
        -- itself a signal, and discarding the attempt discards the signal.
        u.count = u.count + 1
        answer(src, false, 0, ('You have used all %d reports for this match.')
            :format(BR.Config.Report.maxPerMatch))
        return
    end

    local targets = type(data.targets) == 'table' and data.targets or {}
    if #targets == 0 then
        answer(src, false, 0, 'No players were selected.')
        return
    end
    if #targets > BR.Config.Report.maxTargets then
        answer(src, false, 0, ('You can report at most %d players at once.')
            :format(BR.Config.Report.maxTargets))
        return
    end

    local note = nil
    if type(data.note) == 'string' and data.note ~= '' then
        note = data.note:sub(1, BR.Config.Report.maxNote)
    end

    local filed, seen = 0, {}

    for _, t in ipairs(targets) do
        local tsrc = tonumber(type(t) == 'table' and t.src or nil)
        local category = tostring(type(t) == 'table' and t.category or '')

        if not BR.Config.isReportCategory(category) then
            category = BR.Config.defaultReportCategory()
        end

        -- One report per target per submission, whatever the client sent.
        if tsrc and not seen[tsrc] and tsrc ~= src then
            seen[tsrc] = true

            local te = BR.Roster.get(tsrc)
            -- SAME BUCKET ONLY. A client naming a server id from another match
            -- is either broken or probing; either way the answer is the same.
            if te and te.matchId == me.matchId then
                local tby = BR.Identity and BR.Identity.ofPlayer(tsrc)
                local tlicense = tby and BR.Identity.qualified('license', tby.license)
                    or te.license

                if tlicense then
                    local payload, why = BR.IncidentBuild.fromReport({
                        license         = tlicense,
                        name            = te.name,
                        reporterLicense = reporter,
                        reporterName    = me.name,
                        category        = category,
                        note            = note,
                        matchId         = me.matchId,
                        at              = GetGameTimer(),
                    }, BR.Evidence and BR.Evidence.forLicense(tlicense) or {})

                    if payload then
                        TriggerEvent('br:ringmaster:incident', payload)
                        filed = filed + 1
                    else
                        print(('^3[br_core] report not filed for %s: %s^7')
                            :format(tostring(te.name), tostring(why)))
                    end
                end
            end
        end
    end

    if filed == 0 then
        answer(src, false, 0, 'None of those players could be reported.')
        return
    end

    u.count = u.count + 1
    answer(src, true, filed, nil)

    print(('[br_core] report: %s filed %d incident(s) in match %s (%d/%d used)')
        :format(me.name, filed, tostring(me.matchId),
                u.count, BR.Config.Report.maxPerMatch))

    -- The panel shows the remaining allowance, so it needs refreshing after a
    -- submission or it would keep offering a report that is no longer there.
    BR.Players.push(src)
end)

--- Reports do not survive the match they were filed in.
AddEventHandler('br:match:destroyed', function(ev)
    if type(ev) ~= 'table' then return end
    for license, u in pairs(usage) do
        if u.matchId == ev.matchId then usage[license] = nil end
    end
end)

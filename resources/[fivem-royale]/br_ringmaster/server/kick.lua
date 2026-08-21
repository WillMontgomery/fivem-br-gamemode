--[[
    brkick -- the console's one reach into a running match.

    THE ONLY FILE IN THIS PROJECT ALLOWED TO CALL DropPlayer, and verify.sh
    enforces that by path. The scoping is the point: "the console can kick"
    must not quietly become "any file in this resource can remove anyone",
    and keeping the capability in one small reviewable file is what stops the
    second sentence from becoming true by accident.

    HOW A KICK ARRIVES:

        Ringmaster  --ssh-->  dispatch.sh  --tmux send-keys-->  this console
                                                                     |
                                          brkick <license> "<reason>" <cmdId>
                                                                     |
                                            DropPlayer + outcome event back

    WHAT THIS FILE TRUSTS: nothing about the reason text. It arrives already
    stripped by the console (lib/actions.ts) and again by dispatch.sh, and is
    stripped a third time here. Three independent hops each assume the previous
    one was compromised, because this is the path where being wrong is worst --
    a newline in a reason is a second command on this very console.

    WHAT IT DOES NOT DO: decide whether the kick was allowed. Authorisation
    happened in the console against the acting admin's scopes. The admin's
    identity travels only as an AUDIT field echoed back in the outcome -- never
    as an authorisation input, because anything able to put bytes on this
    channel already has console authority and could grant itself an ace.
]]

BR = BR or {}
BR.Ring = BR.Ring or {}

--- Strip anything that could terminate a console line or wreck a chat frame.
--- Third of three hops; see the header.
local function clean(s)
    if type(s) ~= 'string' then return '' end
    s = s:gsub('[%c]', ' ')          -- control characters, newlines included
    s = s:gsub('%s+', ' ')
    s = s:gsub('^%s*(.-)%s*$', '%1')
    if #s > 300 then s = s:sub(1, 300) end
    return s
end

--- Find the connected player holding this license.
---
--- Server ids are recycled within the minute, so the console never sends one:
--- it sends the license and this resolves it HERE, against the current player
--- list. A stale id from a console rendered thirty seconds ago would otherwise
--- kick whoever happened to inherit that slot.
--- @param license string
--- @return number|nil src
local function findByLicense(license)
    for _, src in ipairs(GetPlayers()) do
        local byKind = BR.Identity.ofPlayer(src)
        local got = BR.Identity.qualified('license', byKind.license)
        if got == license then
            return tonumber(src)
        end
    end
    return nil
end

--- Remove the player holding this license, if they are here.
---
--- THE ONE DropPlayer CALL SITE, exposed as a function so the ban gate can
--- reach it without a second one appearing elsewhere. verify.sh pins
--- DropPlayer to this file by path, and this is what lets that stay true while
--- other files still need the capability.
--- @param license string
--- @param reason string  already cleaned by the caller
--- @return boolean kicked, string|nil name
function BR.Ring.dropByLicense(license, reason)
    local src = findByLicense(license)
    if not src then return false, nil end

    local name = GetPlayerName(src) or 'Unknown'
    DropPlayer(src, reason)
    return true, name
end

--- Report what happened, so the console can close the audit row.
---
--- THIS IS THE SECOND HALF OF THE TWO-PHASE AUDIT. The console wrote an intent
--- row before dispatching and is waiting to stamp an outcome onto it, joined by
--- this command id. A kick that never reports leaves that row `pending`, which
--- the audit page shows as "unacknowledged" -- deliberately distinguishable
--- from "failed", because "we asked and never found out" is its own fact.
local function report(commandId, ok, detail)
    if not commandId or commandId == '' then return end
    if BR.Ring.emitOutcome then
        BR.Ring.emitOutcome(commandId, ok, detail)
    end
end

RegisterCommand('brkick', function(source, args)
    -- Console only. `source` is 0 for the server console, which is the only
    -- caller this command has: dispatch.sh types it into the console through
    -- tmux. A player invoking it would arrive with their own id.
    if source ~= 0 then
        return
    end

    local license = args[1]
    local commandId = args[#args]

    -- The reason is everything between, rejoined: FiveM splits on spaces even
    -- inside quotes, so a multi-word reason arrives as several argv entries.
    local parts = {}
    for i = 2, #args - 1 do parts[#parts + 1] = args[i] end
    local reason = clean(table.concat(parts, ' '):gsub('^"(.*)"$', '%1'))
    if reason == '' then reason = 'No reason given' end

    if type(license) ~= 'string' or not license:match('^license2?:%x+$') then
        print('^1[br_ringmaster] brkick: bad license^7')
        report(commandId, false, { error = 'bad license' })
        return
    end

    -- THE APPEAL LINE GOES ON HERE, NOT INSIDE dropByLicense. That function is
    -- also how the ban gate removes somebody a late answer turned out to have
    -- banned, and the gate has already composed its own message -- appeal line
    -- and all -- by the time it calls in. Appending inside the drop would give
    -- that one path the sentence twice.
    --
    -- GUARDED, BECAUSE A KICK MUST HAPPEN WHATEVER ELSE IS WRONG. If appeal.lua
    -- ever falls out of the manifest, an admin's kick still removes the player
    -- with the reason they typed, instead of the console command erroring on a
    -- nil call and the player staying in the match.
    local message = BR.Ring.withAppeal and BR.Ring.withAppeal(reason) or reason

    local kicked, name = BR.Ring.dropByLicense(license, message)
    if not kicked then
        -- NOT AN ERROR, and the distinction matters to the person reading the
        -- audit log later. The player already left, or was never here; the ban
        -- (if this kick accompanied one) still stands and the connect gate will
        -- enforce it. Reporting this as a failure would send admins chasing a
        -- problem that does not exist.
        print(('^3[br_ringmaster] brkick: %s is not connected^7'):format(license))
        report(commandId, true, { kicked = false, reason = 'not connected' })
        return
    end

    print(('^2[br_ringmaster] kicked %s (%s): %s^7'):format(name, license, reason))
    report(commandId, true, { kicked = true, name = name })
end, true)

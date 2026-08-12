--[[
    br_ddb debug -- one command, read-only.

    `brddb` answers the only question worth asking about this resource before
    the ban gate depends on it: can this box actually reach DynamoDB? That is
    genuinely unknown until tried -- it needs an instance role resolved through
    IMDS, a VPC route, and an IAM policy, and any of the three failing produces
    the same symptom (a lookup that never answers) from inside FXServer.

    RESTRICTED, so it runs from the server console or an ace-allowed principal
    and not from any player.
]]

local RESTRICTED = true

--- Correlates a request with its answer. Monotonic; resets on restart, which
--- is harmless because nothing outlives a single command invocation.
local nextReq = 0
local pending = {}

local function newReq(handler)
    nextReq = nextReq + 1
    local id = nextReq
    pending[id] = handler

    -- Never leave a handler behind. If the JS half never answers -- the exact
    -- failure this command exists to detect -- say so rather than sitting
    -- silent, which reads as the command not having run.
    SetTimeout(6000, function()
        if pending[id] then
            pending[id] = nil
            print('^1[br_ddb] no answer within 6s -- the JS half did not respond.^7')
            print('  Check the server console for a br_ddb startup line.')
        end
    end)

    return id
end

AddEventHandler('br:ddb:selftestResult', function(req, ok, info)
    local handler = pending[req]
    if not handler then return end
    pending[req] = nil
    handler(ok, info or {})
end)

AddEventHandler('br:ddb:banResult', function(req, banned, info)
    local handler = pending[req]
    if not handler then return end
    pending[req] = nil
    handler(banned, info or {})
end)

--- Ask the ban question directly, for one license.
---
--- THIS EXISTS BECAUSE "THE BAN DID NOT WORK" HAS FOUR CAUSES and they are
--- indistinguishable from the outside: the row was never written, it was
--- written under a different license string, the game cannot read the table, or
--- the connect gate is not running. This command isolates the middle two --
--- it performs the exact lookup the gate performs, with the license spelled out
--- by hand, and prints the raw answer.
---
--- Usage:  brban license:b6f5a1273092df7eb6a8c2a981418f275f2ae3fb
RegisterCommand('brban', function(_source, args)
    local license = args[1]
    if type(license) ~= 'string' or license == '' then
        print('^3usage: brban <license>   e.g. brban license:abc123...^7')
        print('  Your own license prints from `bridents` while connected.')
        return
    end

    print(('^5[br_ddb]^7 asking about %s'):format(license))

    local req = newReq(function(banned, info)
        if info.error then
            print(('^1  lookup FAILED: %s^7'):format(tostring(info.error)))
            print('  The gate would FAIL OPEN here and let this player in.')
            return
        end

        if banned then
            print('^1  BANNED^7')
            print(('    reason  %s'):format(tostring(info.reason)))
            print(('    expires %s'):format(
                info.expiresAt and os.date('%Y-%m-%d %H:%M', math.floor(info.expiresAt / 1000))
                or 'never'))
            print('  The gate would refuse this connection.')
        else
            print('^2  not banned^7')
            print('  Either no row exists for this EXACT license string, or the')
            print('  ban is lifted/expired. Compare it character for character')
            print('  with what the console shows -- a mismatched license reads')
            print('  as "not banned" and is the most common cause of a ban that')
            print('  appears to do nothing.')
        end
    end)

    TriggerEvent('br:ddb:banCheck', req, license)
end, RESTRICTED)

RegisterCommand('brddb', function()
    print('^5[br_ddb]^7 probing DynamoDB...')

    local req = newReq(function(ok, info)
        print(('  region       %s'):format(tostring(info.region)))
        print(('  table prefix %s'):format(tostring(info.prefix)))
        print(('  round trip   %sms'):format(tostring(info.ms)))

        if ok then
            print('^2  reachable -- credentials, route and GetItem permission all work.^7')
        else
            print(('^1  FAILED: %s^7'):format(tostring(info.error)))
            print('  Usual causes, in the order worth checking:')
            print('   1. the instance role has no GetItem on ringmaster-bans')
            print('   2. no route from this box to DynamoDB (check the endpoint/NAT)')
            print('   3. wrong region -- set br_ddb_region in server.cfg')
        end
    end)

    TriggerEvent('br:ddb:selftest', req)
end, RESTRICTED)

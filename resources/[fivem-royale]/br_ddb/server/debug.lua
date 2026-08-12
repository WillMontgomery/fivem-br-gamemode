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

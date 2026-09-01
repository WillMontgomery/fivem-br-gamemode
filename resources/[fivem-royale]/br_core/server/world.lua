-- The world override: the console's clock and the console's sky.
--
-- Owner, 2026-08-31: "can you make me a brtime command on the server which will
-- set the time in-game? Recall we have the game locked at noon right now. Also I
-- want one for brweather too."
--
--   brtime <hour> [minute]     move the clock for everyone
--   brtime <hh:mm>             the same thing, spelled the way a clock is
--   brtime reset               back to the pinned 12:00
--   brweather <name>           set the sky for everyone
--   brweather                  print the fifteen names
--   brweather reset            hand the sky back to the storm and the island
--
-- ═══ WHY THIS IS A BROADCAST AND NOT A SETTING ═══
--
-- NEITHER OF THESE IS SERVER STATE. GTA's clock is overridden per client, by
-- br_core/client/natives.lua's per-frame NetworkOverrideClockTime; the weather
-- is written per client by client/storm.lua and br_environment/client/ipl.lua,
-- whose own comment says "Per-client weather, like the storm's: nothing syncs
-- it." There is nothing on this box to change. What this file owns is the
-- OVERRIDE -- one small record, held in BR.World (br_lib/shared/world.lua), sent
-- whole to everybody who needs it.
--
-- ═══ THE LATE JOINER ═══
--
-- A client that connects after the command was typed has never seen the
-- broadcast, and its own pin would put it at noon while the rest of the session
-- stood at dusk. So the override is also sent to ONE client on br:ready, which
-- is the message every client sends when it has finished loading and wants a
-- snapshot -- the same hook server/community.lua and server/admin.lua answer.
--
-- IT IS SENT EVEN WHEN IT IS EMPTY, for server/community.lua's reason: a client
-- that reconnects after a `brtime reset` must be told the override is gone, and
-- "no override" is a payload rather than a silence.
--
-- ═══ WHAT MOVING THE CLOCK ACTUALLY CHANGES ═══
--
-- GTA's ambient population is TIME-GATED, so this is not only a lighting knob.
-- server/rescue.lua's ambient-ambulance note is the specific case and it is
-- written from the other side of this decision: "The world clock is pinned to
-- high noon permanently. Several of GTA's ambulance population points are
-- time-gated to evening and night, so those spawns never fire at all." Move the
-- clock into the evening and some of them start firing -- which changes what
-- BR.Rescue's discovery ledger can find, and therefore where a squad can spend a
-- revive key. That is a gameplay difference, not a screenshot difference, and it
-- is why this verb is dev-mode only rather than merely console-only.

local RESTRICTED = true

--- Send the whole override to one client, or to everybody.
--- @param target number  a server id, or -1 for everyone
local function send(target)
    TriggerClientEvent(BR.Net.WORLD_SET, target, BR.World.payload())
end

-- The late joiner's copy. `source` is the client that just finished loading.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    send(source)
end)

--- Refuse a verb unless it came from the server console AND this box is a dev
--- box, and SAY SO on the console either way.
---
--- ═══ TWO GATES, AND RESTRICTED IS NEITHER OF THEM ═══
---
--- Registering restricted admits the server console OR any live client holding
--- the `br.admin` ACE. That is the right boundary for a readout and the wrong
--- one for the world: #202's rule for brcar is that a verb like this "must not
--- become a route for anyone without console access", and an admin holding
--- br.admin does not have console access. The narrowing is the equality below.
---
--- AND DEV MODE ON TOP OF IT (owner, 2026-08-31: "Yes I want all client and
--- server commands gated behind devmode"). Same switch brcar, brgive, brarm,
--- brtestfire and brstormfreeze already carry -- one convar meaning "this box is
--- not a real match" -- rather than a second thing to remember.
---
--- `0` IS TRUTHY IN LUA, which is why the console test is an EQUALITY rather
--- than a truthiness test. Source 0 is the console, so `if src then` admits
--- every player and `if not src then` admits nobody; both compile and both look
--- right. Same trap brcar's note spells out.
---
--- IT PRINTS RATHER THAN RETURNING QUIETLY. A refusal that says nothing is
--- indistinguishable from a verb that ran and did nothing, and the person typing
--- this on the public box needs to read WHICH of the two gates stopped them.
--- The print goes to the server console; nothing here is ever shown to a player.
--- @param verb string @param src any
--- @return boolean
local function consoleDevOnly(verb, src)
    if tonumber(src) ~= 0 then
        print(('  %s is server-console only (the br.admin ACE is not enough)')
            :format(verb))
        return false
    end
    if not BR.Server.devMode then
        print(('  %s is dev-mode only. Start the server with br_devMode true '
            .. '(or sv_devMode true) to use it.'):format(verb))
        return false
    end
    return true
end

--- What the override currently is, in one line, for every usage and confirmation.
--- @return string
local function stateLine()
    local h, m = BR.World.clockHM()
    local wx   = BR.World.weatherName()
    return ('  now: %02d:%02d (%s), sky %s')
        :format(h, m,
                BR.World.holdsTime() and 'overridden' or 'the pin',
                wx or 'left to the storm and the island')
end

local function usageTime()
    print('  usage: brtime <hour> [minute]    hour 0-23, minute 0-59')
    print('         brtime <hh:mm>')
    print('         brtime reset              back to the pinned '
        .. ('%02d:%02d'):format(BR.World.DEFAULT_HOUR, BR.World.DEFAULT_MINUTE))
    print('    Every client pins its own clock every frame; this moves the pin')
    print('    for all of them, including anyone who joins afterwards.')
    print('    Ambient population is time-gated: evening and night change which')
    print('    vehicles and peds the engine spawns, hospital ambulances among')
    print('    them (see the ambient-ambulance note in server/rescue.lua).')
    print(stateLine())
end

local function usageWeather()
    print('  usage: brweather <name>')
    print('         brweather reset           hand the sky back to the game')
    local row = {}
    for _, name in ipairs(BR.World.WEATHERS) do
        row[#row + 1] = name
        if #row == 5 then
            print('    ' .. table.concat(row, '  '))
            row = {}
        end
    end
    if #row > 0 then print('    ' .. table.concat(row, '  ')) end
    print('    While a sky is set it outranks the storm\'s thunder and the')
    print('    island\'s overcast; reset gives both of them their sky back.')
    print(stateLine())
end

RegisterCommand('brtime', function(src, args)
    if not consoleDevOnly('brtime', src) then return end

    local kind, hour, minute, err = BR.World.parseTime(args and args[1],
                                                       args and args[2])
    if kind == 'error' then
        print('  ' .. tostring(err))
        usageTime()
        return
    end
    if kind == 'usage' then
        usageTime()
        return
    end

    if kind == 'reset' then
        BR.World.clearTime()
        send(-1)
        print(('[br_core] brtime: back on the pin, %02d:%02d for everyone')
            :format(BR.World.DEFAULT_HOUR, BR.World.DEFAULT_MINUTE))
        return
    end

    BR.World.setTime(hour, minute)
    send(-1)
    print(('[br_core] brtime: %02d:%02d for everyone, and for anyone who joins')
        :format(hour, minute))
end, RESTRICTED)

RegisterCommand('brweather', function(src, args)
    if not consoleDevOnly('brweather', src) then return end

    local kind, name, err = BR.World.parseWeather(args and args[1])
    if kind == 'error' then
        print('  ' .. tostring(err))
        usageWeather()
        return
    end
    if kind == 'usage' then
        usageWeather()
        return
    end

    if kind == 'reset' then
        BR.World.clearWeather()
        send(-1)
        print('[br_core] brweather: the sky is the storm\'s and the island\'s again')
        return
    end

    BR.World.setWeather(name)
    send(-1)
    print(('[br_core] brweather: %s for everyone, and for anyone who joins')
        :format(name))
end, RESTRICTED)

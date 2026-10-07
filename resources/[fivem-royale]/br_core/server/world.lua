-- The world override: the console's clock and the console's sky.
--
-- Owner, 2026-08-31: "can you make me a brtime command on the server which will
-- set the time in-game? Recall we have the game locked at noon right now. Also I
-- want one for brweather too."
--
--   brtime <hour> [minute]     move the clock for everyone
--   brtime <hh:mm>             the same thing, spelled the way a clock is
--   brtime reset               back to the state's own clock: 12:00 in the
--                              lobby and on the warmup pad, the match's
--                              running clock from bus start (#394)
--   brweather <name>           set the sky for everyone
--   brweather                  print the fifteen names
--   brweather reset            hand the sky back to the storm and the island
--
-- And the festive match sky's cycle (#399), below: `brsky` shows and forces it.
--
-- ═══ WHY THIS IS A BROADCAST AND NOT A SETTING ═══
--
-- NEITHER OF THESE IS SERVER STATE. GTA's clock is set per client, by
-- br_core/client/natives.lua's clock writer; the weather is written per client
-- by client/storm.lua and br_environment/client/ipl.lua,
-- whose own comment says "Per-client weather, like the storm's: nothing syncs
-- it." There is nothing on this box to change. What this file owns is the
-- OVERRIDE -- one small record, held in BR.World (br_lib/shared/world.lua), sent
-- whole to everybody who needs it.
--
-- ═══ THE LATE JOINER ═══
--
-- A client that connects after the command was typed has never seen the
-- broadcast, and its own clock would stand at noon while the rest of the
-- session stood at dusk. So the override is also sent to ONE client on
-- br:ready, which is the message every client sends when it has finished
-- loading and wants a snapshot -- the same hook server/community.lua and
-- server/admin.lua answer.
--
-- IT IS SENT EVEN WHEN IT IS EMPTY, for server/community.lua's reason: a client
-- that reconnects after a `brtime reset` must be told the override is gone, and
-- "no override" is a payload rather than a silence.
--
-- ═══ WHAT MOVING THE CLOCK ACTUALLY CHANGES ═══
--
-- GTA's ambient population is TIME-GATED, so this is not only a lighting knob.
-- server/rescue.lua's ambient-ambulance note is the specific case and it is
-- written from the other side of this decision: the clock never reaches night
-- in a match (noon to about 17:00, #394), and "Several of GTA's ambulance
-- population points are time-gated to evening and night". Move the clock into
-- the evening and some of them start firing -- which changes what
-- BR.Rescue's discovery ledger can find, and therefore where a squad can spend a
-- revive key. That is a gameplay difference, not a screenshot difference, and it
-- is why this verb is dev-mode only rather than merely console-only.

local RESTRICTED = true

--- Send the whole override to one client, or to everybody.
--- @param target number  a server id, or -1 for everyone
local function send(target)
    TriggerClientEvent(BR.Net.WORLD_SET, target, BR.World.payload())
end

-- ═══ THE FESTIVE SKY TRAVELS WITH IT (#399) ═══
--
-- Owner, 2026-10-05: "yes snow is meant to reach the players" -- December and
-- January, on the festive crates' switch (`brfestive` drives both),
-- everywhere. The server decides it, ONE fact: the `snow` Season row AND the
-- festive calendar (BR.Festive.now, br_lib/shared/festive.lua). It rides the
-- payload above, so it reaches everybody when it moves and a late joiner on
-- br:ready, and a client holds it (BR.World.festive) without reading anything
-- per tick. What it does to the sky is client/world.lua's.
--
-- IT MOVES ONLY ON CHANGE: `brfestive`, a `brseason` switch, and the date
-- crossing into or out of the festive months, which a one-minute job notices.

--- The festive sky by the server's own answer.
--- @return boolean
local function festiveSkyNow()
    return BR.Season ~= nil and BR.Season.has('snow')
       and BR.Festive ~= nil and BR.Festive.now() == true
end

BR.WorldSky = BR.WorldSky or {}

-- ═══ THE FESTIVE MATCH SKY CYCLES (#399) ═══
--
--   "The match weather can cycle between snow, snowlight, xmas and blizzard
--    during the months of December and January."     -- owner, 2026-10-06
--
-- PER MATCH, ON THE MATCH RECORD, like the clock's anchor: m.sky holds the
-- weather showing, when it began and when it turns, and the match's own seeded
-- generator (BR.World.cycleNext draws from it: never the weather just shown,
-- each held 180-300 s, br_lib/config/festive.lua). Every player in one match
-- therefore stands under one sky, and two matches under two.
--
-- IT STARTS WHEN THE MATCH GOES PLAYING, which is the moment its first circle
-- goes on the map (BR.Storm.begin runs in the same transition).
-- BR.Match.transition stamps it BEFORE it broadcasts, so the PLAYING state
-- event carries the first weather and nothing else is sent for it. Until then
-- -- the lobby, warmup, the bus and the doors-open sky -- the festive sky is
-- #399's XMAS.
--
-- ONE MESSAGE PER CHANGE: a one-second job turns a PLAYING match's cycle when
-- its hold is up and sends the new weather to that match's audience, the dead
-- watching their squad included. A client that (re)loads mid-match finds it in
-- the snapshot's match view.
--
-- IT ENDS WITH THE MATCH: from ENDED nothing turns, and the state events still
-- carry the last weather, so the sky does not move under the verdict; the
-- record goes with the match. A return to WARMUP or BUS (brforce) drops it. The
-- festive sky going off stops every cycle; coming on starts one in every
-- PLAYING match.

--- Tell one match's audience the weather its cycle shows now (none: stopped).
--- @param m table
local function cycleSend(m)
    BR.Broadcast.toMatch(m, BR.Net.WORLD_CYCLE,
                         { weather = m.sky and m.sky.weather or nil })
end

--- Turn a match's cycle: the next weather -- or `force` -- held from `now`.
--- @param m table @param now number @param force string|nil
local function cycleTurn(m, now, force)
    local s = m.sky
    local w, holdMs = BR.World.cycleNext(s.rng, s.weather)
    s.weather = force or w
    s.since, s.nextAt = now, now + holdMs
    s.turns = s.turns + 1
    print(('[br_core] match %s: the festive sky is %s for %d s')
        :format(BR.MatchTag(m.id), s.weather, holdMs // 1000))
end

--- Start a match's cycle. Sends nothing: the caller knows who must hear.
---
--- SEEDED PER MATCH, from its id and the moment it started, so two matches
--- never share a sequence and `brsky` can print the seed that replays one --
--- up to the first `brsky <weather>`, which draws a turn and shows another.
--- @param m table @param now number
local function cycleBegin(m, now)
    local seed = (math.floor(tonumber(m.id) or 0) * 7919 + math.floor(now)) & 0x7FFFFFFF
    m.sky = { seed = seed, rng = BR.Rng(seed), turns = 0 }
    cycleTurn(m, now)
end

--- The festive sky moved: start a cycle in every PLAYING match, or stop them
--- all.
--- @param on boolean
local function cyclesFollow(on)
    if not (BR.Server and BR.Server.eachMatch) then return end
    local now = GetGameTimer()
    BR.Server.eachMatch(function(m)
        if on and m.sky == nil and m.state == BR.MatchState.PLAYING then
            cycleBegin(m, now)
            cycleSend(m)
        elseif not on and m.sky ~= nil then
            m.sky = nil
            cycleSend(m)
        end
    end)
end

--- Start, keep or drop a match's cycle for the state it is entering. Called by
--- BR.Match.transition beside stampClock, before the state is broadcast.
--- @param m table @param state string
function BR.WorldSky.stamp(m, state)
    if state == BR.MatchState.WARMUP or state == BR.MatchState.BUS then
        m.sky = nil
    elseif state == BR.MatchState.PLAYING and m.sky == nil and BR.World.isFestive() then
        cycleBegin(m, GetGameTimer())
    end
end

--- Read the festive sky again and tell every client if it moved.
---
--- THE ORDER OF THE TWO SENDS IS THE BLEND. Coming on, each match's first
--- weather goes out BEFORE the festive fact: a client holds it under a sky that
--- is still plain, and the festive fact then turns the clear sky straight to it
--- -- one blend, not XMAS and then the cycle. Going off, the festive fact goes
--- first and the cycles stop under a sky that is already plain.
--- @param why string|nil  what asked, for the console line
--- @return boolean on  the festive sky now
--- @return boolean moved  whether it was just sent to everybody
function BR.WorldSky.refresh(why)
    local on = festiveSkyNow()
    if on == BR.World.isFestive() then return on, false end
    BR.World.setFestive(on)
    if on then
        cyclesFollow(true)
        send(-1)
    else
        send(-1)
        cyclesFollow(false)
    end
    print(('[br_core] festive sky %s for everyone (%s)')
        :format(on and 'ON' or 'off', why or 'the server date'))
    return on, true
end

-- The cycles' clock: a PLAYING match whose hold is up turns, and its audience
-- is told. A comparison per match a second; nothing is sent between turns.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(1000, 'world.cycle', function()
        if not (BR.Server and BR.Server.eachMatch) then return end
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            local s = m.sky
            if s and m.state == BR.MatchState.PLAYING and now >= s.nextAt then
                cycleTurn(m, now)
                cycleSend(m)
            end
        end)
    end)
end

-- The date crossing into or out of December and January. Its first run is the
-- scheduler's first pass, after server/main.lua has booted the season.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(60000, 'world.festive', function() BR.WorldSky.refresh() end)
end

-- The late joiner's copy. `source` is the client that just finished loading.
-- The festive sky is read first, so a client that arrives before the job's
-- first pass is not told an answer that is about to move.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = source
    local _, moved = BR.WorldSky.refresh()
    if not moved then send(src) end
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
    local wx = BR.World.weatherName()
    local clock
    if BR.World.holdsTime() then
        clock = ('%02d:%02d, held still by brtime'):format(BR.World.clockHM())
    else
        clock = ('%02d:%02d held in the lobby and warmup, running from bus start')
            :format(BR.World.restHM())
    end
    return ('  now: %s; sky %s'):format(clock, wx or 'left to the storm and the island')
end

local function usageTime()
    print('  usage: brtime <hour> [minute]    hour 0-23, minute 0-59')
    print('         brtime <hh:mm>')
    print('         brtime reset              back to '
        .. ('%02d:%02d'):format(BR.World.restHM())
        .. ' in the lobby and warmup, or the match\'s running time')
    print('    Holds every client\'s clock still at the time given -- lobby,')
    print('    warmup and match alike -- until reset, including anyone who joins')
    print('    afterwards.')
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
        print(('[br_core] brtime: reset for everyone -- %02d:%02d in the lobby '
            .. 'and warmup, the match\'s running time from bus start')
            :format(BR.World.restHM()))
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

-- ═══ brsky: THE FESTIVE MATCH SKY'S CYCLE, SEEN AND FORCED (#399) ═══
--
--   brsky              every cycling match: the weather, how long it has held,
--                      when it turns, its turn count and seed
--   brsky <weather>    SNOW, SNOWLIGHT, XMAS or BLIZZARD, now, in every PLAYING
--                      match's cycle, with a fresh hold; its audience is told
--                      once, as for a turn
--   brsky next         turn every PLAYING match's cycle now
--
-- Dev mode (devgate.lua) plus restricted, as `brfestive` is: a testing verb
-- for a sky that otherwise takes three to five minutes to move. What it prints
-- goes to the server console.

--- One match's cycle, in one line.
--- @param m table @param now number
--- @return string
local function cycleLine(m, now)
    local s = m.sky
    local turns = s.nextAt > now
        and ('turns in %d s'):format(math.ceil((s.nextAt - now) / 1000))
        or 'turns within a second'
    if m.state ~= BR.MatchState.PLAYING then turns = 'stopped with the match' end
    return ('  match %s (%s): %s for %d s, %s; turn %d, seed %d')
        :format(BR.MatchTag(m.id), tostring(m.state), s.weather,
                math.floor((now - s.since) / 1000), turns, s.turns, s.seed)
end

RegisterCommand('brsky', function(_, args)
    local a = args and args[1]
    local want = nil
    if a ~= nil and a ~= '' then
        local word = tostring(a):upper()
        if word == 'NEXT' then
            want = 'next'
        elseif BR.World.inCycle(word) then
            want = word
        else
            print('  usage: brsky [next|' .. table.concat(BR.Config.Festive.cycle.weathers, '|') .. ']')
            return
        end
    end

    local now, any = GetGameTimer(), false
    BR.Server.eachMatch(function(m)
        local s = m.sky
        if not s then return end
        any = true
        if want and m.state == BR.MatchState.PLAYING then
            if want == 'next' then
                cycleTurn(m, now)
                cycleSend(m)
            elseif want ~= s.weather then
                cycleTurn(m, now, want)
                cycleSend(m)
            end
        end
        print(cycleLine(m, now))
    end)

    if any then return end
    if not BR.World.isFestive() then
        print('[br_core] brsky: no match sky cycles -- the festive sky is off '
            .. '(brfestive on, on Season 2 or later)')
    else
        print('[br_core] brsky: no match sky cycles yet -- a festive match\'s '
            .. 'cycle starts when it goes PLAYING')
    end
end, RESTRICTED)

-- Voice authority: WHICH SQUAD RADIO EXISTS, AND WHO MAY BE ON IT.
--
-- ==========================================================================
-- WHAT THIS FILE STOPPED DOING, AND WHY THAT IS THE POINT.
--
-- It used to hand every client a Mumble PROXIMITY CHANNEL and create the room
-- with MUMBLE_CREATE_CHANNEL. It does neither now. pma-voice owns the engine
-- (see client/voice.lua for the whole argument), and pma-voice's model is that
-- every player has their OWN channel and speakers add the channels of the
-- players near them to their voice target. There is no match room to assign,
-- and creating one behind pma-voice's back would be a room nobody joins.
--
-- WHAT IS LEFT IS THE ONE THING pma-voice CANNOT KNOW: which of these
-- forty-eight people are a squad, and therefore which radio channel each player
-- is entitled to. pma-voice has a radio -- a channel audible at any distance,
-- riding MumbleAddVoiceTargetPlayerByServerId, which resolves against the
-- Mumble user list rather than the channel list and so reaches a squadmate the
-- game has not streamed in. That is exactly what squad voice has always needed.
--
-- ==========================================================================
-- HOW A PLAYER GETS ONTO A RADIO, AND WHY IT TAKES BOTH SIDES.
--
--   1. THIS FILE decides the NUMBER, from matchId and squadId, and sends it to
--      that player and to nobody else (VOICE_SET). Neither input is public --
--      matchId is excluded from roster.lua's PUBLIC_FIELDS -- so a client
--      cannot work out another squad's channel.
--   2. THE CLIENT decides whether to ASK for it, because the mode preference is
--      the player's. 'squad' asks; 'nearby' and 'off' ask for channel 0.
--   3. THIS FILE REFUSES ANYBODY WHO ASKED FOR ONE THEY WERE NOT GIVEN, using
--      pma-voice's own `addChannelCheck` hook -- which exists for precisely
--      this and is consulted inside its setPlayerRadio before anyone is added.
--
-- STEP 3 IS NOT DECORATION. Step 1's secrecy is only worth what guessing costs,
-- and the radio channel space is small integers. The check re-derives squad
-- membership from the roster at the moment of the request, so it cannot go
-- stale and there is no second copy of the answer to keep in step.
--
-- WHAT THIS COSTS, stated plainly, as the previous version of this file did:
-- proximity voice is now enforced by the SPEAKER, on the speaker's machine. A
-- modified client can therefore transmit to anyone it can see. The failure mode
-- is nuisance rather than surveillance, muting is the answer to nuisance and
-- pma-voice has a per-player mute already. The SQUAD radio is the part that
-- would actually be worth stealing, and that is the part this file gates.
--
-- ==========================================================================
-- MATCH ISOLATION, WHICH IS NOW SOMEBODY ELSE'S MECHANISM. READ THIS.
--
-- Two parallel matches stand on the same coordinates, and the old design gave
-- each match its own Mumble room because "routing buckets stop players seeing
-- each other; they are not documented to stop them HEARING each other."
--
-- THAT SENTENCE WAS ABOUT AN ENGINE SIDE EFFECT AND IT NO LONGER APPLIES.
-- pma-voice does not hear by room. It builds its voice target from the client's
-- own STREAMED player list, so a player in another match's routing bucket is
-- never a candidate to be sent to in the first place. Isolation is not being
-- inferred from an undocumented property of Mumble; it is the resource's own
-- selection loop, and buckets are the thing it selects from.
-- Config.Match.matchBucketBase gives every match its own.
--
-- THE HONEST RESIDUE, because this is the class of claim this project keeps
-- getting burned on: nobody here has watched two matches fail to hear each
-- other under pma-voice. What has changed is that the claim now rests on a
-- documented resource behaviour we have read the source of, rather than on an
-- engine behaviour nobody could find documentation for.
--
-- The SQUAD RADIO does not depend on any of that: its channel number contains
-- matchId, so two matches cannot collide on one, and the check in step 3 above
-- is a hard server-side wall regardless of buckets.
-- ==========================================================================

BR = BR or {}
BR.Voice = BR.Voice or {}

local VOICE_RES = 'pma-voice'
local V = (BR.Config.Match or {}).voice or {}

--- Is pma-voice running?
---
--- THE NATIVE ITSELF IS GUARDED, which is not paranoia about FXServer builds --
--- it is about the harnesses. This function is on the path of BR.Voice.push,
--- and push is called from the roster, from match state changes and from a 1 Hz
--- sweep; a nil global here would raise inside all three and take the roster's
--- own bookkeeping down with it. Absent reads as "no voice resource", which is
--- the correct and safe answer for anything that cannot answer the question.
local function present()
    return GetResourceState ~= nil and GetResourceState(VOICE_RES) == 'started'
end

-- ==========================================================================
-- THE CHANNEL MATHS IS PURE AND EXPOSED, DELIBERATELY.
--
-- Everything that can go wrong here is arithmetic -- two squads landing on one
-- number, a radio surviving into the next match -- and none of it is observable
-- from outside until two people who should not hear each other do. Arithmetic
-- that cannot be seen belongs somewhere it can be tested, which is the same
-- split as storm_solve and combat_solve.

--- Which proximity channel a match (or the lobby, or warmup) is.
---
--- THIS IS NO LONGER A MUMBLE CHANNEL AND NOTHING JOINS IT. pma-voice assigns
--- every player their own channel and this number is never handed to the engine
--- by anything, on either side.
---
--- It is kept because it is still the cheapest MATCH-SCOPED IDENTIFIER in the
--- system -- two players who must not hear each other still have to differ on
--- it, and it is what /brvoice prints to show that they do -- and because
--- tools/test_roster.lua has swept it since voice shipped.
--- @param matchId integer|nil
--- @param state string|nil
--- @return integer
function BR.Voice.proxChannel(matchId, state)
    if matchId then return (V.matchBase or 2000) + matchId end
    if state == BR.PlayerState.WARMUP then return V.warmupChannel or 1001 end
    return V.lobbyChannel or 1000
end

--- Which pma-voice radio channel one squad in one match is.
---
--- ==========================================================================
--- A squadId IS A STRING, NOT A NUMBER, AND THAT COST A ROUND OF THIS FILE.
---
--- server/party.lua namespaces squad ids by match and formats them as text:
---
---     local id = ('m%dsq%d'):format(m.id, i)     -- 'm3sq1'
---
--- The first version of this function did `matchId * stride + squadId` on that,
--- which is an arithmetic operation on a non-numeric string. In Lua that does
--- not evaluate to nil or to zero -- IT RAISES. The raise came out of
--- BR.Voice.push, which is called from inside BR.Roster.each by the 1 Hz sweep
--- and by pushMatch, so a single squad match aborted the sweep for every player
--- after it and left them with no voice assignment at all.
---
--- IT WOULD NEVER HAVE BEEN CAUGHT IN SOLOS, which is the part worth
--- remembering: solos have no squadId, so radio is nil, so the arithmetic never
--- runs. Exactly the shape of #150, where solo voice was broken from the day it
--- shipped because every test queued squads. tools/test_roster.lua caught this
--- one, in the squad blocks, before it reached a playtest.
---
--- SO THE INDEX IS PARSED OUT, AND A FAILURE TO PARSE IS LOUD. A silent nil
--- here would be a squad with no radio -- proximity-only squad voice, which is
--- the exact regression this whole change exists to end, and it would look like
--- "squad chat stopped working at range" with nothing in the console.
--- ==========================================================================
--- @param matchId integer|nil
--- @param squadId string|nil  as party.lua writes it, e.g. 'm3sq1'
--- @return integer|nil  nil when this player has no squad radio at all
local warnedSquadId = false
function BR.Voice.radioChannel(matchId, squadId)
    if not matchId or not squadId then return nil end

    local mid = math.tointeger(tonumber(matchId))
    if not mid then return nil end

    -- The trailing index is the squad's number within its match. The matchId is
    -- taken from the roster entry rather than from the string, so the two
    -- halves of the number come from the same place the caller got them.
    local n = tostring(squadId):match('sq(%d+)$')
    n = n and math.tointeger(tonumber(n)) or nil
    if not n then
        if not warnedSquadId then
            warnedSquadId = true
            print(('[br_core] VOICE: cannot read a squad index out of squadId '
                .. '%q -- server/party.lua has changed its format. SQUAD VOICE '
                .. 'IS PROXIMITY-ONLY until this is fixed.')
                :format(tostring(squadId)))
        end
        return nil
    end

    -- Separate number space from the proximity ids above, and far from them.
    -- The stride is per match, so squad 3 of match 7 and squad 3 of match 8 are
    -- different rooms -- which is what stops a radio surviving into the next
    -- match on a client that never asked to leave.
    --
    -- Read through V so a later round can move these into
    -- br_lib/config/match.lua (Config.Match.voice.radioBase / .radioStride)
    -- without touching this file. They are not there today.
    return (V.radioBase or 30000) + (mid * (V.radioStride or 100)) + n
end

--- @param e table roster entry
--- @return integer
local function proxChannelFor(e)
    return BR.Voice.proxChannel(e.matchId, e.state)
end

--- Who else is on this player's squad, by server id.
---
--- Sorted so the payload is stable and the dedup below can compare two pushes
--- as strings rather than re-deriving set equality every second for every
--- player. Departed players are excluded: a squadmate who has left is not
--- somebody to keep a radio open to.
--- @param src integer  the player being pushed; never in their own list
--- @param e table
--- @return table array of server ids, possibly empty
local function squadmatesOf(src, e)
    local out = {}
    if V.squadIsGlobal == false then return out end
    if not e.matchId or not e.squadId then return out end
    BR.Roster.each(
        function(o) return o.squadId == e.squadId
            and o.matchId == e.matchId
            and o.state ~= BR.PlayerState.LEFT end,
        function(other)
            if other ~= src then out[#out + 1] = other end
        end)
    table.sort(out)
    return out
end

--- @param list table
--- @return string
local function key(list)
    return table.concat(list, ',')
end

-- ------------------------------------------------------- the server-side wall ---

--- MAY THIS PLAYER JOIN THIS RADIO CHANNEL?
---
--- Handed to pma-voice as a per-channel check. It re-derives the answer from
--- the roster every time it is asked -- there is no cached membership here to
--- go stale, which matters because the interesting moment is exactly when a
--- player's squad has just changed.
--- @param src integer
--- @param channel integer
--- @return boolean
function BR.Voice.mayJoin(src, channel)
    local e = BR.Roster.get(src)
    if not e or e.state == BR.PlayerState.LEFT then return false end
    return BR.Voice.radioChannel(e.matchId, e.squadId) == channel
end

--- Channels we have already registered a check on, so we register once each.
--- Cleared when pma-voice restarts, because it drops every check it holds when
--- the resource that gave it one goes away -- and it drops ours when br_core
--- restarts, which is why registration is lazy rather than done at start.
local checked = {}

local function guard(channel)
    if not channel or checked[channel] then return end
    if not present() then return end
    local okc, err = pcall(function()
        exports[VOICE_RES]:addChannelCheck(channel, function(src)
            return BR.Voice.mayJoin(src, channel)
        end)
    end)
    -- MARKED EITHER WAY, so a failing export cannot be retried once a second
    -- for the life of the match. A failure here is the wall coming down, so it
    -- says so in those words rather than as a stack trace.
    checked[channel] = true
    if not okc then
        print(('[br_core] VOICE: could not register the squad-radio guard on '
            .. 'channel %s (%s). That channel is now joinable by any client '
            .. 'that guesses it.'):format(tostring(channel), tostring(err)))
    end
end

AddEventHandler('onResourceStart', function(name)
    if name == VOICE_RES then
        -- pma-voice came back holding nothing of ours. Every guard has to be
        -- re-registered, and forgetting each player's cached assignment is what
        -- makes the sweep below re-push -- and therefore re-guard -- within the
        -- second.
        checked = {}
        BR.Roster.each(
            function(e) return e.state ~= BR.PlayerState.LEFT end,
            function(src) BR.Voice.forget(src) end)
    elseif name == GetCurrentResourceName() and not present() then
        print('[br_core] VOICE: ' .. VOICE_RES .. ' is not running. There is '
            .. 'no voice chat -- no proximity, no squad radio. The gamemode '
            .. 'runs without it. See server.cfg.example for the install.')
    end
end)

-- ------------------------------------------------------------------- the push ---

--- Send one player their squad radio and their squad, if either has changed.
---
--- Deduplicated on the roster entry, because every caller fires on a state
--- change and several of them fire on the SAME state change -- a squad forming
--- is also a state change is also a match join.
--- @param src integer
function BR.Voice.push(src)
    if V.enabled == false then return end

    local e = BR.Roster.get(src)
    if not e then return end

    local prox  = proxChannelFor(e)
    local radio = BR.Voice.radioChannel(e.matchId, e.squadId)
    local mates = squadmatesOf(src, e)
    local mk    = key(mates)

    if e.voiceProx == prox and e.voiceMates == mk and e.voiceRadio == radio then
        return
    end

    -- EVICT BEFORE REASSIGNING, but only when they should be on NO channel.
    --
    -- pma-voice's own setPlayerRadio removes a player from their previous
    -- channel before adding them to a new one, so a player moving from one
    -- squad to another cleans up on the way in and needs nothing here. The case
    -- that does NOT clean up is the player who should now be on nothing -- back
    -- to the lobby, squad dissolved, match over -- because nobody is going to
    -- issue a join that displaces the old one. Left alone they would keep
    -- talking to their last squad from the lobby.
    if radio == nil and e.voiceRadio ~= nil and present() then
        pcall(function() exports[VOICE_RES]:setPlayerRadio(src, 0) end)
    end

    e.voiceProx, e.voiceMates, e.voiceRadio = prox, mk, radio

    -- THE WALL BEFORE THE INVITATION. The check has to be registered before the
    -- client is told the number, or the first join races past an unguarded
    -- channel.
    guard(radio)

    local R = V.range or {}
    TriggerClientEvent(BR.Net.VOICE_SET, src, {
        radio       = radio,
        mates       = mates,
        nearbyRange = R.nearby or 25.0,

        -- ==================================================================
        -- THE TWO FIELDS BELOW ARE NOT READ BY br_core/client/voice.lua.
        --
        -- `prox` was the match's Mumble room and there is no such room now;
        -- `squadRange` was the distance at which the client stopped opening a
        -- squadmate's volume override, and the pma-voice radio has no range at
        -- all -- it is a channel, and a channel does not attenuate.
        --
        -- THEY ARE STILL SENT BECAUSE tools/test_roster.lua ASSERTS ON THEM --
        -- see its 'voice.channels -- solos' block, which checks that a solo is
        -- told the proximity room the roster says they are in and that the
        -- squad range is the longer of the two. That suite is owned elsewhere
        -- and a contract change is not something to land underneath it.
        --
        -- REMOVING THEM IS A TWO-MINUTE JOB once that block is updated, and it
        -- should be done rather than left: fields nobody reads are exactly how
        -- this project accumulates subsystems with no callers. This comment is
        -- the marker for that follow-up, deliberately named so a grep for
        -- 'squadRange' lands on it.
        -- ==================================================================
        prox        = prox,
        squadRange  = R.squad or 16000.0,
    })
end

--- Re-push everybody in a match. Used when squads are formed, which changes
--- every member's squad roster at once.
--- @param m table
function BR.Voice.pushMatch(m)
    if V.enabled == false or not m then return end
    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src) BR.Voice.push(src) end)
end

--- Forget a player's cached assignment so their next push always sends.
---
--- Called on disconnect: a reconnecting player inherits the src, and a stale
--- cache would leave them silently on whatever radio the last holder had.
--- @param src integer
function BR.Voice.forget(src)
    local e = BR.Roster.get(src)
    if e then e.voiceProx, e.voiceMates, e.voiceRadio = nil, nil, nil end
end

-- THE SAFETY NET. Every path that changes a player's match or squad is supposed
-- to push, and the ones that exist do. This catches the ones that do not exist
-- yet: a subsystem added later that moves somebody between matches without
-- knowing this file is here would otherwise leave them on their old squad's
-- radio. It sends nothing when nothing has changed.
BR.Sched.every(1000, 'voice.sweep', function()
    if V.enabled == false then return end
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src) BR.Voice.push(src) end)
end)

-- ------------------------------------------------------------------ readout ---

RegisterCommand('brvoice', function()
    local R = V.range or {}
    print('=== voice ===')

    -- FIRST LINE, FOR THE SAME REASON AS THE CLIENT'S. The previous version of
    -- this command opened with the range and the channel arithmetic and read as
    -- healthy through a total outage, because the arithmetic was fine and there
    -- was no voice resource running to act on it.
    print(('  engine       %s'):format(present()
        and (VOICE_RES .. ' -- running')
        or (VOICE_RES .. ' IS NOT RUNNING. There is no voice chat on this '
            .. 'server at all.')))
    print(('  enabled      %s   nearby %.0fm (falloff, speaker-side)   squad-global %s')
        :format(tostring(V.enabled ~= false), R.nearby or 25.0,
                tostring(V.squadIsGlobal ~= false)))

    local guards = 0
    for _ in pairs(checked) do guards = guards + 1 end
    print(('  radio guards %d channel(s) gated to their own squad'):format(guards))

    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src, e)
            -- THE MODE IS PRINTED BECAUSE #150 WAS A MODE-SHAPED BUG. A solo
            -- match and a squad match are indistinguishable in every other
            -- column: both have a matchId, and solos simply have no squadId.
            -- It is also the column that separates "no radio because solo"
            -- from "no radio because something is wrong".
            local m = BR.Server.matchById(e.matchId)
            print(('  %-20s (%d)  match %-5s %-6s squad %-10s -> radio %s, mates [%s]')
                :format(e.name, src, tostring(e.matchId or '-'),
                        m and tostring(m.mode) or '-',
                        tostring(e.squadId or '-'),
                        tostring(e.voiceRadio or 'none'),
                        e.voiceMates ~= nil and e.voiceMates ~= '' and e.voiceMates
                            or 'nobody'))
        end)

    -- WHAT THIS READOUT PROVES, AND -- MORE USEFULLY -- WHAT IT DOES NOT.
    --
    -- #150 was a week of a correct server readout over a total client-side
    -- outage. That trap is bigger now, not smaller: proximity does not appear
    -- on this side AT ALL any more. There is no assignment to print, because
    -- there is nothing for this file to assign.
    print('')
    print('  This lists the SQUAD RADIO only. Proximity voice is not assigned')
    print('  by this server -- pma-voice decides it on each client, from that')
    print('  client\'s own streamed player list, so there is nothing here that')
    print('  can confirm or deny it. Run /brvoice in a player\'s F8 console.')
    print('  A squad player showing "radio none" is a BUG; a solo showing it is')
    print('  correct. Two squads that must not hear each other differ on radio.')
end, true)

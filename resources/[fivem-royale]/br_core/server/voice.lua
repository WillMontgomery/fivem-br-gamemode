-- Voice channel authority.
--
-- FiveM ships its own Mumble server and client. What it does NOT ship is any
-- notion of "these forty-eight people are a match and those forty-eight are
-- not": proximity voice is computed from player POSITIONS, and two parallel
-- matches stand on the same coordinates. Routing buckets stop players seeing
-- each other; they are not documented to stop them HEARING each other, and a
-- whole match's comms is not something to hang on an undocumented side effect.
--
-- So channels are explicit and they are the SERVER'S. The client is told two
-- integers and applies them; it cannot work them out for itself, because both
-- are derived from matchId and matchId is never public (PUBLIC_FIELDS in
-- roster.lua). That is deliberate: the same rule that stops a client knowing
-- which match a stranger is in stops it guessing its way into their channel.
--
-- Pushed on every event that can change the answer -- joining a match, squads
-- being formed, going back to the lobby -- rather than on a timer, because a
-- player who is briefly in the wrong voice channel is a player broadcasting
-- their position to the wrong forty-seven people.

BR = BR or {}
BR.Voice = BR.Voice or {}

local V = (BR.Config.Match or {}).voice or {}

-- THE CHANNEL MATHS IS PURE AND EXPOSED, DELIBERATELY.
--
-- Everything that can go wrong here is arithmetic -- two matches landing on
-- one number, a squad room colliding with a proximity room, somebody left in
-- channel 0 -- and none of it is observable from the outside until two players
-- who should not hear each other do. Arithmetic that cannot be seen belongs
-- somewhere it can be tested, which is the same split as storm_solve and
-- combat_solve.

--- Which proximity channel a match (or the lobby, or warmup) is.
---
--- Everyone gets one, including in the lobby: channel 0 is where every Mumble
--- client starts, so leaving lobby players there puts them in a room with
--- anybody whose assignment has not landed yet.
--- @param matchId integer|nil
--- @param state string|nil
--- @return integer
function BR.Voice.proxChannel(matchId, state)
    if matchId then return (V.matchBase or 2000) + matchId end
    if state == BR.PlayerState.WARMUP then return V.warmupChannel or 1001 end
    return V.lobbyChannel or 1000
end

-- ==========================================================================
-- THERE IS NO SQUAD ROOM ANY MORE, AND THAT IS THE POINT (#157).
--
-- #150 ended with a caveat on the record: the squad room is created by this
-- side, and whether a channel created MID-MATCH is announced to clients that
-- already authenticated to the Mumble server was never confirmed. The named
-- follow-up was to stop using a room for squad voice and address squadmates
-- directly. Two things since have turned that from a fallback into the only
-- option:
--
--   1. THE WARNING NEVER WENT AWAY. The owner still sees
--        "MUMBLE_ADD_VOICE_CHANNEL_LISTEN: Tried to call native on a channel
--         that didn't exist"
--      and cannot say when. It is a race, which is why: the client withholds
--      its routing until it has joined the PROXIMITY room, and then states a
--      listen on the SQUAD room without ever asking whether that one arrived.
--      Two rooms, two clocks, one wait. Sometimes the second room is late and
--      the listen is refused -- loudly, once, with no retry.
--
--   2. A ROOM CANNOT BEAT THE DISTANCE CUTOFF ANYWAY. Now that proximity
--      actually has a range (#157), every stream a client receives is gated by
--      that range whichever room carried it -- Mumble's distance belongs to
--      the speaker and the listener, never to a channel. So the squad room
--      would have delivered squad audio faithfully to a player standing 30 m
--      away and had it thrown out by the mixer. Squad voice needs the
--      per-player volume override, which needs squadmates' server ids, and
--      once the client has those the room has nothing left to do.
--
-- So the server sends the squad's MEMBERSHIP instead of a squad channel, and
-- the client points its voice target at those players by server id. No room,
-- no creation, no round trip, and no listen -- which is the only way to say
-- that warning line cannot come back rather than that it probably will not.
--
-- WHAT THIS COSTS, stated plainly. A voice target naming players is a target a
-- modified client could point at server ids it was never given, so a cheat can
-- push its own audio at a stranger. The failure mode is nuisance, not
-- surveillance, and muting is the answer to nuisance and is per-player already.
--
-- AND THE SECOND ROUND OF #157 WIDENED THAT, so it is restated here rather than
-- left to age. The proximity cutoff is now applied by the LISTENER, in
-- br_core/client/voice.lua, because the engine's own distance cutoff silenced
-- every speaker on the owner's build. So audio from anyone in the same match
-- does reach a client whether or not they are close enough to hear it, and a
-- modified client could play it. WHAT IS UNCHANGED is the part this file owns:
-- the room. Two matches are two rooms, nothing crosses between them, and no
-- client can put itself in a room it was not given -- so the blast radius of a
-- liar is the match they are already in, and never the server.
--
-- THE PROXIMITY ROOM IS STILL MADE HERE, and still by MUMBLE_CREATE_CHANNEL,
-- which is a SERVER native (FiveM's Mumble surface is 29 client natives and 3
-- server ones). Without it that room existed only by accident, because
-- MumbleSetVoiceChannel creates what it cannot find and the first player into
-- a match brought the room into being by walking into it.
local made = {}

--- @param ch integer|nil
local function makeChannel(ch)
    -- Channel 0 is the root every client already starts in; the native ignores
    -- it, and asking would be asking for the one room nobody can create.
    if not ch or ch == 0 or made[ch] then return end
    if not MumbleCreateChannel then
        made[ch] = true   -- say it once, not once a second
        print('[br_core] VOICE: MUMBLE_CREATE_CHANNEL is missing on this '
            .. 'server build. Match rooms will exist only because the first '
            .. 'player to join one creates it by accident, which is how it '
            .. 'worked before #150 and is not something to rely on.')
        return
    end
    MumbleCreateChannel(ch)
    made[ch] = true
end

--- @param e table roster entry
--- @return integer
local function proxChannelFor(e)
    return BR.Voice.proxChannel(e.matchId, e.state)
end

--- Who else is on this player's squad, by server id.
---
--- THIS REPLACES THE SQUAD CHANNEL and it is the server's decision, exactly as
--- the channel was: a client is told who its squadmates are and can only
--- decline them. Sorted so the payload is stable and the dedup below can
--- compare two pushes as strings rather than re-deriving set equality every
--- second for every player.
---
--- Departed players are excluded the same way every other sweep here excludes
--- them -- a squadmate who has left is not somebody to keep a radio open to.
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

--- Send one player their room and their squad, if either has changed.
---
--- Deduplicated on the entry, because every caller below fires on a state
--- change and several of them fire on the SAME state change -- a squad forming
--- is also a state change is also a match join.
--- @param src integer
function BR.Voice.push(src)
    if V.enabled == false then return end

    local e = BR.Roster.get(src)
    if not e then return end

    local prox  = proxChannelFor(e)
    local mates = squadmatesOf(src, e)
    local mk    = key(mates)

    if e.voiceProx == prox and e.voiceMates == mk then return end
    e.voiceProx, e.voiceMates = prox, mk

    -- MAKE THE ROOM BEFORE TELLING ANYONE TO GO TO IT. One room now: see the
    -- block above for why the squad room is gone.
    makeChannel(prox)

    local R = V.range or {}
    TriggerClientEvent(BR.Net.VOICE_SET, src, {
        prox        = prox,
        mates       = mates,
        nearbyRange = R.nearby or 25.0,
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
--- Called on disconnect: a reconnecting player inherits the src, and a stale
--- cache would leave them silently in whatever channel the last holder had.
--- @param src integer
function BR.Voice.forget(src)
    local e = BR.Roster.get(src)
    if e then e.voiceProx, e.voiceMates = nil, nil end
end

-- THE SAFETY NET. Every path that changes a player's match or squad is
-- supposed to push, and the ones that exist do. This catches the ones that do
-- not exist yet: a subsystem added later that moves somebody between matches
-- without knowing this file is here would otherwise leave them talking to
-- their old match, which is the one failure mode worth a second-by-second
-- sweep. It sends nothing when nothing has changed.
BR.Sched.every(1000, 'voice.sweep', function()
    if V.enabled == false then return end
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src) BR.Voice.push(src) end)
end)

RegisterCommand('brvoice', function()
    local R = V.range or {}
    print('=== voice channels ===')
    print(('  enabled %s   nearby %.0fm   squad %.0fm   squad-global %s')
        :format(tostring(V.enabled ~= false),
                R.nearby or 25.0, R.squad or 16000.0,
                tostring(V.squadIsGlobal ~= false)))
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src, e)
            -- THE MODE IS PRINTED BECAUSE #150 WAS A MODE-SHAPED BUG.
            --
            -- A solo match and a squad match are indistinguishable in every
            -- other column here: both have a matchId, both have a proximity
            -- channel, and solos simply have no squadId. Reading "squad -"
            -- and inferring "so this is solos" is a step somebody has to know
            -- to take, and the first thing anybody diagnosing voice needs to
            -- establish is which of the two they are looking at.
            local m = BR.Server.matchById(e.matchId)
            print(('  %-20s (%d)  match %-5s %-6s squad %-10s -> prox %s, radio to [%s]')
                :format(e.name, src, tostring(e.matchId or '-'),
                        m and tostring(m.mode) or '-',
                        tostring(e.squadId or '-'),
                        tostring(e.voiceProx or '-'),
                        e.voiceMates ~= nil and e.voiceMates ~= '' and e.voiceMates
                            or 'nobody'))
        end)
    print('  Two players who should NOT hear each other must differ on prox.')
    -- A CORRECT ASSIGNMENT HERE PROVES ALMOST NOTHING, which is the lesson of
    -- #150: both silent players had the right prox channel on this readout the
    -- whole time. What was missing was the client's voice TARGET, which this
    -- side cannot see at all. If the numbers below look right and players
    -- still cannot hear each other, the answer is on their machines.
    print('  This is the ASSIGNMENT only. Whether audio is actually being sent')
    print('  is client-side -- run /brvoice in a player\'s F8 console and read')
    print('  the "talking into" line.')
end, true)

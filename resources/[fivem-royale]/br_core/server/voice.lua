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

--- Which squad channel a squad index inside a match is.
---
--- Keyed on the squad INDEX rather than the squadId string, because a Mumble
--- channel is a number and the id is not. The stride caps how many squads a
--- match can have distinct rooms for; exceeding it puts two squads in one
--- room, which is worse than no squad voice at all -- so it is announced
--- rather than allowed to happen quietly.
--- @param matchId integer
--- @param idx integer  0-based squad index
--- @return integer
function BR.Voice.squadChannel(matchId, idx)
    local stride = V.squadStride or 16
    if idx >= stride then
        print(('[br_core] VOICE: match %d has more squads than the channel '
            .. 'stride allows (%d) -- two squads will share a room. Raise '
            .. 'BR.Config.Match.voice.squadStride.'):format(matchId, stride))
        idx = idx % stride
    end
    return (V.squadBase or 5000) + matchId * stride + idx
end

--- @param e table roster entry
--- @return integer
local function proxChannelFor(e)
    return BR.Voice.proxChannel(e.matchId, e.state)
end

--- @param e table
--- @return integer|nil
local function squadChannelFor(e)
    if not e.matchId or not e.squadId then return nil end
    local idx = BR.Party.squadIndex and BR.Party.squadIndex(e.squadId) or nil
    if not idx then return nil end
    return BR.Voice.squadChannel(e.matchId, idx)
end

--- Send one player their channels, if they have changed.
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
    local squad = V.squadIsGlobal ~= false and squadChannelFor(e) or nil

    if e.voiceProx == prox and e.voiceSquad == squad then return end
    e.voiceProx, e.voiceSquad = prox, squad

    TriggerClientEvent(BR.Net.VOICE_SET, src, {
        prox      = prox,
        squad     = squad,
        proximity = V.talkerProximity or 25.0,
    })
end

--- Re-push everybody in a match. Used when squads are formed, which changes
--- every member's squad channel at once.
--- @param m table
function BR.Voice.pushMatch(m)
    if V.enabled == false or not m then return end
    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src) BR.Voice.push(src) end)
end

--- Forget a player's cached channels so their next push always sends.
--- Called on disconnect: a reconnecting player inherits the src, and a stale
--- cache would leave them silently in whatever channel the last holder had.
--- @param src integer
function BR.Voice.forget(src)
    local e = BR.Roster.get(src)
    if e then e.voiceProx, e.voiceSquad = nil, nil end
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
    print('=== voice channels ===')
    print(('  enabled %s   proximity %.0fm   squad-global %s')
        :format(tostring(V.enabled ~= false),
                V.talkerProximity or 25.0,
                tostring(V.squadIsGlobal ~= false)))
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src, e)
            print(('  %-20s (%d)  match %-5s squad %-10s -> prox %s, squad %s')
                :format(e.name, src, tostring(e.matchId or '-'),
                        tostring(e.squadId or '-'),
                        tostring(e.voiceProx or '-'),
                        tostring(e.voiceSquad or '-')))
        end)
    print('  Two players who should NOT hear each other must differ on prox.')
end, true)

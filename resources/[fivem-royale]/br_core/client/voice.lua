-- Voice, client half: apply the channels the server assigned.
--
-- FiveM's built-in Mumble does the hard part -- capture, codec, positional
-- mixing -- and this file does the only part it cannot: deciding WHO is in
-- the room. See server/voice.lua for why that decision cannot be made here.
--
-- NOTHING HERE IS AUTHORITATIVE and nothing here is a privacy boundary. A
-- client that ignored every line of this would put itself in the wrong Mumble
-- channel, which is a room the server never told anyone else to join -- so the
-- failure mode of a liar is silence, not eavesdropping. That is the property
-- that makes it safe to do this client-side at all.

BR = BR or {}
BR.Voice = BR.Voice or {}

local V = (BR.Config.Match or {}).voice or {}

-- What the server last told us. Kept so /brvoice can report it and so a
-- re-apply after a Mumble reconnect has something to re-apply.
BR.Voice.state = { prox = nil, squad = nil, proximity = nil, applied = false }

--- Are the natives this file needs actually present on this build?
---
--- Checked ONCE and cached, because the alternative is a pcall per call on a
--- path that runs on every match transition. A missing native here is not
--- fatal -- voice falls back to whatever the engine does by default, which is
--- proximity in channel 0 -- but it must be LOUD, because the symptom is two
--- matches quietly sharing a room and nobody noticing until somebody calls a
--- rotation and a stranger answers.
local ok = nil
local function available()
    if ok ~= nil then return ok end
    ok = (MumbleSetVoiceChannel ~= nil)
        and (MumbleClearVoiceChannel ~= nil)
        and (NetworkSetTalkerProximity ~= nil)
    if not ok then
        print('[br_core] VOICE: the Mumble natives are not available on this '
            .. 'build -- every match will share the default channel. '
            .. 'Run /brnativecheck.')
    end
    return ok
end

--- Put us in our channels.
---
--- ORDER MATTERS AND THE CLEAR IS NOT OPTIONAL. MumbleSetVoiceChannel moves us
--- into a channel; nothing moves us OUT of the previous one, so switching
--- match without clearing first leaves a player audible in the match they just
--- left. Clearing first costs a frame of silence and is the difference between
--- a voice channel and a leak.
local function apply()
    if not available() then return end

    local s = BR.Voice.state

    NetworkSetTalkerProximity(s.proximity or V.talkerProximity or 25.0)

    MumbleClearVoiceChannel()
    if MumbleClearVoiceTarget then MumbleClearVoiceTarget(1) end

    if not s.prox then
        s.applied = false
        return
    end

    -- The proximity room: everyone in our match, and nobody else, with
    -- distance deciding who actually hears us INSIDE it.
    MumbleSetVoiceChannel(s.prox)

    -- The squad room, if we are in one. Two halves, and both are needed:
    -- LISTEN so their voices reach us, and a voice TARGET so ours reaches
    -- them -- MumbleSetVoiceChannel only ever puts us in one room to talk in.
    if s.squad and MumbleAddVoiceChannelListen and MumbleSetVoiceTarget
       and MumbleAddVoiceTargetChannel then
        MumbleAddVoiceChannelListen(s.squad)
        MumbleAddVoiceTargetChannel(1, s.prox)
        MumbleAddVoiceTargetChannel(1, s.squad)
        MumbleSetVoiceTarget(1)
    end

    s.applied = true
end

RegisterNetEvent(BR.Net.VOICE_SET)
AddEventHandler(BR.Net.VOICE_SET, function(d)
    if type(d) ~= 'table' then return end
    local s = BR.Voice.state
    s.prox      = math.tointeger(tonumber(d.prox))
    s.squad     = math.tointeger(tonumber(d.squad))
    s.proximity = tonumber(d.proximity) or s.proximity
    apply()
end)

-- RE-APPLIED ON RECONNECT, not just on assignment.
--
-- The Mumble client connects asynchronously and can drop and come back
-- underneath us. A channel set while it was disconnected is a channel that
-- never took, and the player then talks in channel 0 -- the room every other
-- disconnected-and-recovered player is also in. There is no event for this,
-- so it is polled on the slow band: one boolean per second.
local wasConnected = false
BR.Loop.register(BR.Loop.SLOW, 'voice.watch', function()
    if not available() or not MumbleIsConnected then return end

    local now = MumbleIsConnected()
    if now and not wasConnected then
        -- Just (re)connected. Whatever we thought was applied was not.
        BR.Voice.state.applied = false
        apply()
    end
    wasConnected = now

    -- And a cheap self-heal for the case with no event at all: we have
    -- channels, we are connected, and somehow nothing is applied.
    if now and BR.Voice.state.prox and not BR.Voice.state.applied then
        apply()
    end
end)

RegisterCommand('brvoice', function()
    local s = BR.Voice.state
    print('=== voice (client) ===')
    print(('  natives      %s'):format(available() and 'present' or 'MISSING'))
    print(('  connected    %s'):format(
        MumbleIsConnected and tostring(MumbleIsConnected()) or 'unknown'))
    print(('  prox channel %s'):format(tostring(s.prox or 'unassigned')))
    print(('  squad channel %s'):format(tostring(s.squad or 'none (solo)')))
    print(('  proximity    %.0fm'):format(s.proximity or V.talkerProximity or 25.0))
    print(('  applied      %s'):format(tostring(s.applied)))
    if MumbleGetVoiceChannelFromServerId and BR.State.me.src then
        print(('  engine says  %s'):format(
            tostring(MumbleGetVoiceChannelFromServerId(BR.State.me.src))))
    end
    print('  Two players who should NOT hear each other must differ on prox.')
end, false)

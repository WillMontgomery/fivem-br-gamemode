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

--- The player's own preference, from the settings screen. NOT authority --
--- see apply(): it can only decline rooms the server already granted.
BR.Voice.pref = { mode = 'squad', volume = 0.80 }

--- Server ids heard speaking on the last tick. The squad panel's marker.
BR.Voice.talking = {}

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

    -- THE PLAYER'S OWN PREFERENCE, LAYERED OVER THE SERVER'S ASSIGNMENT.
    --
    -- The server decides WHICH rooms exist and who may be in them; this
    -- decides which of the ones we were given we actually use. That split is
    -- the same one everywhere else in this project, and it is what keeps a
    -- preference from being a privacy hole: choosing 'squad' cannot put us
    -- anywhere the server did not already put us.
    --
    --   off     stop transmitting entirely
    --   nearby  the proximity room only -- the squad room is not joined
    --   squad   both, which is the assignment as issued
    if BR.Voice.pref.mode == 'off' then
        if MumbleSetActive then MumbleSetActive(false) end
        s.applied = false
        return
    end
    if MumbleSetActive then MumbleSetActive(true) end

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

    -- The squad room, if we are in one AND the player wants it. Two halves,
    -- and both are needed: LISTEN so their voices reach us, and a voice
    -- TARGET so ours reaches them -- MumbleSetVoiceChannel only ever puts us
    -- in one room to talk in.
    if s.squad and BR.Voice.pref.mode ~= 'nearby'
       and MumbleAddVoiceChannelListen and MumbleSetVoiceTarget
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

-- ------------------------------------------------------- preference + UI ---

--- Push the per-player volume to everyone we know about.
---
--- THERE IS NO MASTER OUTPUT NATIVE. MumbleSetVolumeOverrideByServerId sets
--- ONE player's level, so "voice volume" is every player at once, re-applied
--- as the roster changes -- an override only exists for somebody who was
--- present when it was set.
local function applyVolume()
    if not MumbleSetVolumeOverrideByServerId then return end
    for src in pairs(BR.State.roster) do
        pcall(MumbleSetVolumeOverrideByServerId, src, BR.Voice.pref.volume)
    end
end

AddEventHandler('br:settings:changed', function(s)
    if type(s) ~= 'table' then return end
    local mode = tostring(s.voiceMode or 'squad')
    if mode ~= 'squad' and mode ~= 'nearby' and mode ~= 'off' then mode = 'squad' end
    local vol = tonumber(s.volVoice) or 0.80

    local changedMode = mode ~= BR.Voice.pref.mode
    local changedVol  = vol ~= BR.Voice.pref.volume
    BR.Voice.pref.mode, BR.Voice.pref.volume = mode, vol

    if changedMode then apply() end
    if changedVol then applyVolume() end
end)

-- WHO IS TALKING.
--
-- Voice was the one system in this game with no visual at all: somebody
-- speaks and there is nothing on screen to say who (owner, 2026-08-09).
--
-- MumbleIsPlayerTalking takes a PLAYER INDEX, not a server id, and a player
-- outside our scope has no index -- which is the correct filter anyway: if we
-- cannot see them, we are not hearing them either.
--
-- Sent on CHANGE, never on the tick. Four pushes a second of an unchanged
-- list is four re-renders a second of a panel that has not moved.
local lastKey = ''
BR.Loop.register(BR.Loop.TICK, 'voice.talking', function()
    if not MumbleIsPlayerTalking then return end

    local talking = {}
    for src in pairs(BR.State.roster) do
        local ply = GetPlayerFromServerId(src) -- scope-ok: presentation only; out of scope means inaudible anyway
        if ply and ply ~= -1 then
            local okT, isTalking = pcall(MumbleIsPlayerTalking, ply)
            if okT and isTalking then talking[#talking + 1] = src end
        end
    end
    table.sort(talking)

    local key = table.concat(talking, ',')
    if key == lastKey then return end
    lastKey = key
    BR.Voice.talking = talking
    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE, { talking = talking })
end)

-- The roster changes constantly and an override only exists for a player who
-- was there when it was set, so the volume is re-asserted on the slow band.
BR.Loop.register(BR.Loop.SLOW, 'voice.volume', applyVolume)

AddEventHandler('br:ui:ready', function()
    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE, { talking = BR.Voice.talking })
end)

RegisterCommand('brvoice', function()
    local s = BR.Voice.state
    print('=== voice (client) ===')
    print(('  mode         %s   volume %.2f'):format(
        BR.Voice.pref.mode, BR.Voice.pref.volume))
    print(('  talking      %s'):format(table.concat(BR.Voice.talking, ', ')))
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

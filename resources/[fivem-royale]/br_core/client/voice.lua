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
--
-- `talkTo` and `listening` are not from the server: they are what we last told
-- the ENGINE, recorded so /brvoice can print the transmit path rather than
-- just the assignment. #150 was invisible for a week precisely because the
-- readout said "prox channel 2003" -- which was true, correct, and had nothing
-- to do with whether any audio was leaving the machine.
BR.Voice.state = {
    prox = nil, squad = nil, proximity = nil, applied = false,
    talkTo = {},        -- channels currently in our voice target
    listening = nil,    -- channel we asked to hear without being in it
}

--- The player's own preference, from the settings screen. NOT authority --
--- see apply(): it can only decline rooms the server already granted.
BR.Voice.pref = { mode = 'squad' }

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

--- The one Mumble voice target slot this file owns.
---
--- Mumble has thirty. We need exactly one, and naming it keeps the clear, the
--- fills and the select from ever drifting onto different numbers -- a clear of
--- 1 followed by a fill of 2 would read fine and transmit nothing.
local TARGET = 1

--- Can we ROUTE, as opposed to merely join a room? Deliberately separate from
--- available() above, and the separation is the whole of the #150 fix.
---
--- available() answers "can we be in the right channel". This answers "can we
--- send audio into it", which is a different set of natives and a different
--- failure. If these are missing we must leave the engine's own routing
--- ALONE -- clearing a voice target we have no way to refill is exactly how a
--- player ends up in the correct room with nowhere to send audio, which is the
--- bug this file shipped with.
local function canRoute()
    return MumbleClearVoiceTarget ~= nil
        and MumbleAddVoiceTargetChannel ~= nil
        and MumbleSetVoiceTarget ~= nil
end

--- Put us in our channels AND point our microphone at them.
---
--- ORDER MATTERS AND THE CLEAR IS NOT OPTIONAL. MumbleSetVoiceChannel moves us
--- into a channel; nothing moves us OUT of the previous one, so switching
--- match without clearing first leaves a player audible in the match they just
--- left. Clearing first costs a frame of silence and is the difference between
--- a voice channel and a leak.
---
--- BEING IN A CHANNEL IS NOT THE SAME AS TRANSMITTING INTO IT (#150).
---
--- The owner, playtesting solos: "when in solos, 'nearby' doesn't seem to
--- work. It's just not passing any audio. I had 2 players in the same match
--- next to each other, neither could hear."
---
--- Both of those players WERE in the right channel. The server had assigned
--- it, the client had applied it, and /brvoice on either machine would have
--- printed the same correct number. What neither of them had was a voice
--- TARGET: the list of destinations Mumble actually sends a captured frame to.
--- This function cleared target 1 on every single call and then refilled it
--- inside one `if` -- the branch that required a squad channel AND the 'squad'
--- preference. Miss either and the target stayed empty, and an empty target is
--- a microphone wired to nothing.
---
--- Two populations missed it, which is why the report reads the way it does:
---
---   SOLOS, always and from the first commit. A solo player has no squadId
---   (party.lua's formSquads returns early for BR.Mode.SOLO), so the server
---   correctly sends squad = nil, so the branch could never run. Solo voice
---   has never worked, not once -- the squad tests in tools/test_roster.lua
---   queue BR.Mode.SQUAD.key exclusively and no test ever reached the client.
---
---   EVERYBODY, from the moment the settings screen shipped, because its
---   default is voiceMode = 'nearby' (br_ui/client/settings.lua) and 'nearby'
---   is the one mode the branch explicitly excluded. A squad player who never
---   opened settings was silent too.
---
--- So the target is now built unconditionally from the proximity channel --
--- the room every player has in every mode -- and the squad room is ADDED to
--- it when there is one. The old squad behaviour is a strict subset of this:
--- squads still get both rooms in the target and still hear the squad room
--- through a listen, so nothing that worked before stops working.
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

    -- STOP HEARING THE LAST SQUAD ROOM BEFORE ANYTHING ELSE.
    --
    -- MumbleClearVoiceChannel takes us out of the room we are IN; it says
    -- nothing about rooms we asked to LISTEN to from outside, and a listen
    -- survives everything below. Without this, a player who switched from
    -- 'squad' to 'nearby' kept hearing their squad at unlimited range while
    -- the interface told them they were on proximity only -- and a player who
    -- returned to the lobby kept hearing the match they had just left, which
    -- is the leak the rest of this file exists to prevent.
    if s.listening and MumbleRemoveVoiceChannelListen then
        MumbleRemoveVoiceChannelListen(s.listening)
    end
    s.listening = nil

    MumbleClearVoiceChannel()
    if canRoute() then MumbleClearVoiceTarget(TARGET) end
    s.talkTo = {}

    if not s.prox then
        s.applied = false
        return
    end

    -- The proximity room: everyone in our match, and nobody else, with
    -- distance deciding who actually hears us INSIDE it.
    MumbleSetVoiceChannel(s.prox)

    -- The squad room, if we are in one AND the player wants it. LISTEN is the
    -- half that brings their voices to us: MumbleSetVoiceChannel only ever
    -- puts us in ONE room, and that one is the proximity room.
    local wantSquad = (s.squad ~= nil) and BR.Voice.pref.mode ~= 'nearby'
    if wantSquad and MumbleAddVoiceChannelListen then
        MumbleAddVoiceChannelListen(s.squad)
        s.listening = s.squad
    end

    -- THE OTHER HALF, AND THE ONE THAT WAS MISSING: where our own audio goes.
    --
    -- The proximity room is in the target for EVERY player in every mode --
    -- that is the line whose absence made two solo players standing next to
    -- each other inaudible to one another. The squad room joins it only when
    -- there is one and the player has not asked for proximity only.
    if canRoute() then
        MumbleAddVoiceTargetChannel(TARGET, s.prox)
        s.talkTo[#s.talkTo + 1] = s.prox
        if wantSquad then
            MumbleAddVoiceTargetChannel(TARGET, s.squad)
            s.talkTo[#s.talkTo + 1] = s.squad
        end
        MumbleSetVoiceTarget(TARGET)
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

-- THERE IS NO VOICE VOLUME SLIDER, AND THERE MUST NOT BE ONE LIKE THIS.
--
-- There is no master output native. The only way to build a volume control is
-- MUMBLE_SET_VOLUME_OVERRIDE_BY_SERVER_ID across every player -- and that
-- native's own documentation says it "will also bypass 3D audio and distance
-- calculations".
--
-- So a blanket override does not adjust the volume of proximity voice; it
-- REPLACES it. Every speaker lands at one flat level whatever the distance,
-- 'nearby' stops meaning anything, and the routing this file exists to apply
-- is quietly cancelled by a slider in the settings screen. It was built,
-- caught before it shipped, and removed (2026-08-09).
--
-- The per-player form is still the right tool for a per-player job -- muting
-- or boosting ONE person, which is a feature worth having later. The output
-- level belongs to the game's own voice settings, which the settings screen
-- now sends players to.

AddEventHandler('br:settings:changed', function(s)
    if type(s) ~= 'table' then return end
    local mode = tostring(s.voiceMode or 'squad')
    if mode ~= 'squad' and mode ~= 'nearby' and mode ~= 'off' then mode = 'squad' end
    if mode == BR.Voice.pref.mode then return end
    BR.Voice.pref.mode = mode
    apply()
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

AddEventHandler('br:ui:ready', function()
    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE, { talking = BR.Voice.talking })
end)

RegisterCommand('brvoice', function()
    local s = BR.Voice.state
    print('=== voice (client) ===')
    print(('  mode         %s'):format(BR.Voice.pref.mode))
    print(('  talking      %s'):format(table.concat(BR.Voice.talking, ', ')))
    print(('  natives      %s'):format(available() and 'present' or 'MISSING'))
    print(('  connected    %s'):format(
        MumbleIsConnected and tostring(MumbleIsConnected()) or 'unknown'))
    print(('  prox channel %s'):format(tostring(s.prox or 'unassigned')))
    print(('  squad channel %s'):format(tostring(s.squad or 'none (solo)')))
    print(('  proximity    %.0fm'):format(s.proximity or V.talkerProximity or 25.0))
    print(('  applied      %s'):format(tostring(s.applied)))

    -- THE LINE #150 NEEDED AND DID NOT HAVE.
    --
    -- Every readout above can be perfect while no audio leaves the machine,
    -- because they all describe which room we are IN. This one describes where
    -- the microphone is pointed, and an empty list here means silence however
    -- right everything else looks. It must never be empty while a prox channel
    -- is assigned and the mode is not 'off'.
    print(('  talking into %s'):format(
        #s.talkTo > 0 and table.concat(s.talkTo, ', ')
            or 'NOTHING -- no audio is being sent'))
    print(('  hearing also %s'):format(tostring(s.listening or 'nothing extra')))
    print(('  can route    %s'):format(canRoute() and 'yes'
        or 'NO -- voice-target natives missing on this build'))

    if MumbleGetVoiceChannelFromServerId and BR.State.me.src then
        print(('  engine says  %s'):format(
            tostring(MumbleGetVoiceChannelFromServerId(BR.State.me.src))))
    end
    print('  Two players who should NOT hear each other must differ on prox.')
    print('  Two players who SHOULD hear each other need the same prox AND a')
    print('  non-empty "talking into" on both machines.')
end, false)

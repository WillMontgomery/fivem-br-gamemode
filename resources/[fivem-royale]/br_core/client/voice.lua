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

--- Their names, in the same order. The bottom-centre indicator prints these.
BR.Voice.names = {}

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

-- ==========================================================================
-- A CHANNEL IS NOT A NUMBER YOU MENTION. IT IS A ROOM THAT HAS TO EXIST.
--
-- This is the second half of #150, and it is the layer underneath the voice
-- target. The engine said it out loud in the owner's client console:
--
--   Warning: [mumble] MUMBLE_ADD_VOICE_CHANNEL_LISTEN: Tried to call native
--   on a channel that didn't exist
--
-- WHAT THE ENGINE ACTUALLY DOES, because the three natives this file uses do
-- three DIFFERENT things with a channel that is not there and only one of them
-- says so:
--
--   MumbleSetVoiceChannel(n)          creates it. If the room does not exist
--                                     the Mumble client sends a temporary
--                                     channel of that name and joins it when
--                                     the server echoes it back. This is why
--                                     the proximity room has always existed
--                                     eventually, and why the /brvoice readout
--                                     looked right.
--
--   MumbleAddVoiceChannelListen(n)    refuses, LOUDLY -- the line above -- and
--                                     drops the call. (The engine does re-try
--                                     unresolved listens on its own once the
--                                     room appears; nothing else here does.)
--
--   MumbleAddVoiceTargetChannel(t,n)  refuses SILENTLY, PERMANENTLY, and with
--                                     no diagnostic whatsoever. The channel
--                                     contributes nothing to the target, the
--                                     voice-target packet ships empty, and the
--                                     pending update is cleared unconditionally
--                                     -- so there is no retry and no second
--                                     chance.
--
-- THE LAST ONE IS THE BUG. Not the listen, which is merely the only one that
-- complained. The previous fix correctly filled the voice target -- and did it
-- in the same frame as MumbleSetVoiceChannel, before the room it named had
-- come back from the server. Every AddVoiceTargetChannel call was thrown away
-- in silence, the target stayed empty, and every player in every mode was a
-- microphone wired to nothing. That is precisely the reported symptom: talking
-- works (the indicator is driven by the local microphone), nobody hears you,
-- in solos and in squads, whatever the preference says.
--
-- NONE OF THIS IS CONFIGURABLE. `voice_useNativeAudio` chooses where decoded
-- audio is rendered and is read at exactly one place in the engine, nowhere
-- near channels, targets or listens. No convar is required for any of this and
-- adding one would have fixed nothing -- see the comment in server.cfg.example.
--
-- SO THE FIX IS TO WAIT. The channel is joined, and the routing that depends
-- on it is withheld until the engine confirms the join actually happened.
-- ==========================================================================

--- How long to wait for the room, on the 10Hz band.
---
--- The Mumble client does its channel work on a 500ms timer of its own and
--- then has to wait for the server, so "a moment" is somewhere around half a
--- second and is not a number this code gets to choose.
---
---   BLIND    how long to wait when the engine cannot be asked at all (older
---            artifacts have no MumbleDoesChannelExist). Comfortably past the
---            engine's own 500ms tick plus a round trip.
---   GIVE_UP  the safety valve. If the readback exists but never agrees --
---            it has been wrong before -- route anyway rather than leave a
---            player permanently silent waiting for a confirmation that is
---            never coming. Being possibly-unrouted beats being definitely
---            unrouted.
local BLIND, GIVE_UP = 8, 30
local waited = 0

--- Is the engine actually IN our proximity room yet?
---
--- @return boolean|nil true yes, false not yet, nil cannot be asked
local function joined()
    local prox = BR.Voice.state.prox
    if not prox then return false end

    -- The direct question, on builds new enough to answer it.
    if MumbleGetVoiceChannelFromServerId and BR.State.me and BR.State.me.src then
        local okc, ch = pcall(MumbleGetVoiceChannelFromServerId, BR.State.me.src)
        -- -1 means "in no channel the client knows about", which is exactly
        -- the state being waited out.
        if okc and ch ~= nil then return math.tointeger(tonumber(ch)) == prox end
    end
    if MumbleDoesChannelExist then
        local okc, exists = pcall(MumbleDoesChannelExist, prox)
        if okc then return exists and true or false end
    end
    return nil
end

--- Forward-declared: apply() below reaches it, and it reaches back into the
--- state apply() sets up. See tools/check_forward_locals.lua for why this form
--- and not a plain `local function` further down.
local route

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

    -- JOIN THE ROOM. This is also what CREATES it: if the proximity room does
    -- not exist, the Mumble client asks the server for it and joins once the
    -- server echoes it back. That echo is the thing everything below has to
    -- wait for, and it is why nothing below happens here.
    MumbleSetVoiceChannel(s.prox)

    -- AND STOP, until the engine confirms the join. Everything that comes next
    -- resolves this channel by name at the instant it is called, and the voice
    -- target throws away what it cannot resolve without a word and without a
    -- retry. Calling it now -- one line after the join, in the same frame, as
    -- this file used to -- is how the microphone ends up wired to nothing.
    waited = 0
    if joined() == true then
        route()
    else
        s.applied = false
    end
end

--- The routing that can only be stated once the room is really there: what we
--- also want to HEAR, and where our own audio GOES.
---
--- Split out of apply() because it happens LATER -- usually half a second
--- later, on the settle band below. Nothing in here clears anything, so it is
--- safe to reach a second time without punching a hole in a live conversation.
route = function()
    local s = BR.Voice.state

    -- The squad room, if we are in one AND the player wants it. LISTEN is the
    -- half that brings their voices to us: MumbleSetVoiceChannel only ever
    -- puts us in ONE room, and that one is the proximity room.
    --
    -- THIS IS THE CALL THAT PRINTS THE WARNING IN THE ISSUE, and it prints it
    -- because nothing creates the squad room: no client ever joins it, and
    -- joining is the only thing that creates a room from this side. It is
    -- created by the SERVER now (server/voice.lua) -- MumbleCreateChannel is a
    -- server native and always was, which is why no amount of reading this
    -- file ever found the missing call.
    local wantSquad = (s.squad ~= nil) and BR.Voice.pref.mode ~= 'nearby'
    if wantSquad and MumbleAddVoiceChannelListen then
        MumbleAddVoiceChannelListen(s.squad)
        s.listening = s.squad
    end

    -- WHERE OUR OWN AUDIO GOES.
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

-- THE WAIT, ON THE 10Hz BAND.
--
-- A room takes about half a second to come back from the Mumble server, so
-- this is the difference between voice working and voice not working -- not a
-- polish detail. 10Hz because a whole second of silence at the start of every
-- match and every squad change is something a player would notice, and because
-- the engine's own timer runs at 500ms so a slower poll would routinely miss
-- the first opportunity.
--
-- It costs one comparison per tick once settled, which is the price of the
-- band it is already on.
BR.Loop.register(BR.Loop.TICK, 'voice.settle', function()
    local s = BR.Voice.state
    if s.applied or not s.prox or BR.Voice.pref.mode == 'off' then return end
    if not available() then return end

    waited = waited + 1

    -- Re-stated every tick, exactly as FiveM's own reference voice resource
    -- does it. A repeat of the channel we already asked for is close to free:
    -- the engine only acts when the requested channel differs from the last
    -- one it acted on.
    MumbleSetVoiceChannel(s.prox)

    local inRoom = joined()
    if inRoom == true                          -- the engine confirms it
        or (inRoom == nil and waited >= BLIND)  -- nothing to ask; wait it out
        or waited >= GIVE_UP then               -- never confirmed; route anyway
        route()
    end
end)

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
        -- Just (re)connected. Whatever we thought was applied was not: a
        -- reconnected Mumble client rebuilds its channel list from the server,
        -- so the room has to be joined again from scratch and the settle band
        -- has to wait for it again from scratch. Nothing may be assumed to
        -- have survived the drop.
        BR.Voice.state.applied = false
        apply()
    end
    wasConnected = now

    -- A cheap self-heal for the case with no event at all: we are connected,
    -- we have a room, and somehow nothing is applied. The settle band above is
    -- what normally finishes the job; this catches the case where it never
    -- started, and re-arms it.
    if now and BR.Voice.state.prox and not BR.Voice.state.applied
        and waited >= GIVE_UP then
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

    -- NAMES TRAVEL WITH THE IDS, because the interface now has to name people
    -- the interface has no other way to name. The squad panel only ever needed
    -- the ids -- it already holds its own members' names -- but proximity
    -- voice is heard from anyone in the match, and the bottom-centre indicator
    -- has to print "Currently Talking: <names>" for strangers too.
    BR.Voice.names = {}
    for i, src in ipairs(talking) do
        local e = BR.State.roster[src]
        BR.Voice.names[i] = (e and e.name) or ('#' .. tostring(src))
    end

    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE,
        { talking = talking, names = BR.Voice.names })
end)

AddEventHandler('br:ui:ready', function()
    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE,
        { talking = BR.Voice.talking, names = BR.Voice.names })
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

    -- THE LINE THE SECOND ATTEMPT AT #150 NEEDED.
    --
    -- "talking into" above is what this client ASKED the engine for, and on
    -- the build the owner played the engine accepted none of it: the rooms
    -- those numbers named were not there yet, and MumbleAddVoiceTargetChannel
    -- discards what it cannot resolve without saying a word. There is no
    -- native that reads a voice target back, so the honest proxy is whether
    -- the engine agrees we are in the room those numbers came from. If this
    -- says "not yet" for more than a second or two, nothing above it is real.
    local inRoom = joined()
    print(('  in the room  %s'):format(
        inRoom == true and 'yes'
        or inRoom == false and 'NOT YET -- nothing above this line is live'
        or 'cannot tell (no readback native on this build)'))
    print(('  settled      %s'):format(s.applied and 'yes'
        or ('no -- %d tick(s) waited'):format(waited)))
    print('  Two players who should NOT hear each other must differ on prox.')
    print('  Two players who SHOULD hear each other need the same prox AND a')
    print('  non-empty "talking into" on both machines, with "in the room" and')
    print('  "settled" both saying yes.')
end, false)

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
local R = V.range or {}

--- Fallbacks for the two ranges, used when the server payload is missing them
--- (an older server, a hand-fired event, a test). Config is shared, so this is
--- the same number the server would have sent.
local NEARBY_M = R.nearby or 25.0
local SQUAD_M  = R.squad or 16000.0

-- What the server last told us. Kept so /brvoice can report it and so a
-- re-apply after a Mumble reconnect has something to re-apply.
--
-- `talkTo`, `radioTo` and `heard` are not from the server: they are what we
-- last told the ENGINE, recorded so /brvoice can print the transmit path
-- rather than just the assignment. #150 was invisible for a week precisely
-- because the readout said "prox channel 2003" -- which was true, correct, and
-- had nothing to do with whether any audio was leaving the machine.
BR.Voice.state = {
    prox = nil, applied = false,
    mates  = {},        -- squadmate server ids the server gave us
    nearby = NEARBY_M,  -- metres; the proximity cutoff in force
    squad  = SQUAD_M,   -- metres; how far the squad radio reaches
    talkTo = {},        -- channels currently in our voice target
    radioTo = {},       -- server ids currently in our voice target
    heard  = {},        -- [src] = true while a volume override is open for them
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

--- Can we tell Mumble HOW FAR a voice carries? The whole of #157.
---
--- Separate from available() and canRoute() for the same reason those are
--- separate from each other: it is a different set of natives and a different
--- failure. Missing these does not break routing -- everybody still ends up in
--- the right room with a working microphone -- it breaks the RANGE, and the
--- symptom is the one the owner reported: perfectly good voice that carries
--- across the entire map. That is quiet enough to survive a playtest, so it
--- says so once, loudly.
local rangeOk = nil
local function canRange()
    if rangeOk ~= nil then return rangeOk end
    rangeOk = (MumbleSetAudioInputDistance ~= nil)
        and (MumbleSetAudioOutputDistance ~= nil)
    if not rangeOk then
        print('[br_core] VOICE: MUMBLE_SET_AUDIO_INPUT_DISTANCE / '
            .. '_OUTPUT_DISTANCE are missing on this build -- proximity voice '
            .. 'has no range and every player in a match will hear every '
            .. 'other one anywhere on the map. Run /brnativecheck.')
    end
    return rangeOk
end

--- Can we address a PLAYER rather than a room?
---
--- Squad voice is two natives now and needs both: one to route our audio to a
--- squadmate without a room in the middle, and one to exempt them from the
--- distance cutoff at the far end. Neither has a room, which is the point --
--- see the block below.
local function canRadio()
    return MumbleAddVoiceTargetPlayerByServerId ~= nil
        and MumbleSetVolumeOverrideByServerId ~= nil
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
-- SO THE FIX IS TO WAIT. The channel is joined, and the routing that depends
-- on it is withheld until the engine confirms the join actually happened.
--
-- ==========================================================================
-- AND BEING IN A ROOM IS NOT THE SAME AS BEING IN RANGE (#157).
--
-- Everything above got the plumbing right and the owner reported the next
-- thing down: "even when set to nearby (while in squads or solos), the channel
-- is global. The off switch does work."
--
-- OFF WORKING IS THE CLUE. It proves the preference reaches this file and that
-- this file reaches the engine. Nothing was broken in the chain -- there was
-- simply no range in it. FiveM's Mumble decides audibility with a distance the
-- GAME has to supply:
--
--   MumbleSetAudioInputDistance(m)   how far our own voice carries.
--   MumbleSetAudioOutputDistance(m)  how far away we can hear from.
--
-- Nothing in this project ever called either one. With no distance there is
-- nothing for MumbleAudioOutput to gate on, so every stream that reaches a
-- client is played at full volume regardless of where the speaker is standing.
-- Everyone in the room hears everyone in the room, which is the report, exactly.
--
-- The line that LOOKED like it was doing this job, and never was:
--
--   NetworkSetTalkerProximity(25.0)
--
-- That is a GTA native belonging to the game's own voice chat. FiveM's Mumble
-- layer does not read it, and it has been sitting here since voice shipped
-- making the range look configured. It is still called -- it costs nothing and
-- it is the right call on the native-audio path -- but it is not the one that
-- does the work.
--
-- THE CUTOFF IS BINARY. On the stock convar path a speaker is in range at full
-- volume or out of range at silence; there is no fade. `voice_useNativeAudio`
-- swaps that for the game's attenuation curves, and it is a taste decision
-- rather than a fix -- see server.cfg.example.
--
-- ==========================================================================
-- WHICH IS WHY SQUAD VOICE IS NO LONGER A ROOM.
--
-- A distance in Mumble belongs to a SPEAKER and a LISTENER. It does not belong
-- to a channel, and there is no per-channel form of it -- so the moment
-- proximity has a 25 m cutoff, EVERY stream a client receives is cut off at
-- 25 m, including one that arrived through the squad room. A squad room can
-- deliver a squadmate's voice faithfully from the far side of the map and have
-- the mixer throw it away on arrival.
--
-- The one native with the right granularity is the per-player volume override,
-- whose own documentation is explicit that it "will also bypass 3D audio and
-- distance calculations". That is a liability for a master volume slider --
-- which is why one was built and removed, see the note further down -- and it
-- is exactly the right tool for a radio: this ONE person, at a flat level,
-- wherever they are.
--
-- So squad voice is now:
--
--   ROUTE   MumbleAddVoiceTargetPlayerByServerId(t, src) -- our audio reaches
--           each squadmate directly. No room, so nothing to create, nothing to
--           wait for, and no MumbleAddVoiceChannelListen anywhere in this file.
--   HEAR    MumbleSetVolumeOverrideByServerId(src, 1.0) -- their audio is
--           exempt from the cutoff, out to BR.Config.Match.voice.range.squad.
--
-- AND THAT IS ALSO THE FIX FOR THE WARNING THE OWNER COULD NOT PLACE. The
-- listen was refused because route() waited for the PROXIMITY room and then
-- immediately named the SQUAD room, which is a different room on a different
-- clock -- created by the server, not joined by anybody, and never checked for.
-- A late squad room meant a refused listen, once, with no retry, which is
-- exactly why it appeared sometimes and could not be pinned to an action.
-- There is no listen now, so there is no race and no warning.
--
-- WHAT A SQUADMATE SOUNDS LIKE NOW: flat and centred rather than positional,
-- like a radio, because that is what bypassing 3D audio means. Standing next
-- to a squadmate you hear the radio copy, not a directional one. That is the
-- price of hearing them at all from 2 km away, and it is the same trade every
-- radio resource in FiveM makes.
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

--- Forward-declared: apply() below reaches them, and they reach back into the
--- state apply() sets up. See tools/check_forward_locals.lua for why this form
--- and not a plain `local function` further down.
local route
local radio

--- Where each squadmate was, last time the server said. Keyed on server id.
---
--- READ STRAIGHT OFF THE SQUAD POSITION PUSH, which is 1Hz and goes only to
--- members of that squad (server/party.lua). Voice keeps its own copy rather
--- than reaching into client/squadmates.lua because that file's table is about
--- blips and overhead names -- it is cleared on staleness rules written for
--- presentation, and voice must not go quiet because a blip decided to.
---
--- A MISSING POSITION MEANS AUDIBLE, not silent. There is no push while the
--- squad is on the bus, and there is none in the first second of a match; a
--- squad that could not talk on the drop would be a worse bug than a squad
--- that carries fractionally too far. Being wrong in the generous direction
--- here costs nothing -- the squad is together on the bus anyway.
local matePos = {}

--- Distance from us to a squadmate, or nil when nobody has said where they are.
--- @param src integer
--- @return number|nil
local function mateDistance(src)
    local p = matePos[src]
    if not p then return nil end
    local me = GetEntityCoords(PlayerPedId())
    if not me then return nil end
    return BR.Dist(me.x, me.y, p.x, p.y)
end

RegisterNetEvent(BR.Net.SQUAD_POS)
AddEventHandler(BR.Net.SQUAD_POS, function(list)
    if type(list) ~= 'table' then return end
    local seen = {}
    for _, m in ipairs(list) do
        local src = math.tointeger(tonumber(m.src))
        if src then
            seen[src] = true
            matePos[src] = { x = tonumber(m.x) or 0.0, y = tonumber(m.y) or 0.0 }
        end
    end
    for src in pairs(matePos) do
        if not seen[src] then matePos[src] = nil end
    end
    -- The radio's reach is re-decided the moment we learn where anybody is,
    -- rather than waiting up to a second for the band below. The push IS the
    -- movement, so this is the earliest honest moment to act on it.
    if radio then radio() end
end)

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
--- the room every player has in every mode -- and squadmates are ADDED to it
--- by server id when there are any (#157; they used to be a second room).
---
--- AND THE RANGE IS STATED HERE, on every apply, before anything else (#157).
--- It is not a one-off at resource start because 'off' takes the microphone
--- away and coming back has to restore everything, and because a Mumble
--- reconnect drops the client's idea of it along with everything else.
local function apply()
    if not available() then return end

    local s = BR.Voice.state

    -- THE PLAYER'S OWN PREFERENCE, LAYERED OVER THE SERVER'S ASSIGNMENT.
    --
    -- The server decides WHICH room exists, who may be in it, and who counts
    -- as a squadmate; this decides which of what we were given we actually
    -- use. That split is the same one everywhere else in this project, and it
    -- is what keeps a preference from being a privacy hole: choosing 'squad'
    -- cannot put us anywhere the server did not already put us.
    --
    --   off     stop transmitting entirely
    --   nearby  the proximity room only, cut off at range.nearby
    --   squad   that, plus squadmates out to range.squad
    if BR.Voice.pref.mode == 'off' then
        if MumbleSetActive then MumbleSetActive(false) end
        -- AND SHUT THE RADIO. An override is a standing instruction to the
        -- mixer and it outlives everything else here, exactly as a channel
        -- listen used to -- so a player who chose 'off' while a squadmate was
        -- talking would keep hearing them, which is not what off means.
        radio(true)
        s.applied = false
        return
    end
    if MumbleSetActive then MumbleSetActive(true) end

    -- HOW FAR A VOICE CARRIES. The whole of #157, and two lines of it.
    --
    -- Both halves are needed and they are not the same question: input is how
    -- far OUR voice reaches, output is how far away we can hear FROM. Set one
    -- and the other side of the conversation still decides for itself.
    if canRange() then
        MumbleSetAudioInputDistance(s.nearby)
        MumbleSetAudioOutputDistance(s.nearby)
    end

    -- The GTA-side talker proximity. It is not what gates Mumble -- see the
    -- block above -- but it is the right number to hand the game's own voice
    -- path, which is what `voice_useNativeAudio` switches playback onto.
    NetworkSetTalkerProximity(s.nearby)

    -- SHUT THE RADIO BEFORE REBUILDING IT.
    --
    -- Same reasoning the channel listen needed and the same failure it had: a
    -- volume override is not undone by clearing a channel or a target. Without
    -- this, a player who switched from 'squad' to 'nearby' kept hearing their
    -- old squad at any range while the interface told them they were on
    -- proximity only, and a player who returned to the lobby kept hearing the
    -- match they had just left. route() reopens it for whoever still qualifies.
    radio(true)

    MumbleClearVoiceChannel()
    if canRoute() then MumbleClearVoiceTarget(TARGET) end
    s.talkTo, s.radioTo = {}, {}

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

    -- Does this player want the squad radio at all? Both halves are a choice:
    -- the server decides who is on the squad, the settings screen decides
    -- whether to use them.
    local wantSquad = (#s.mates > 0) and BR.Voice.pref.mode ~= 'nearby'

    -- WHERE OUR OWN AUDIO GOES.
    --
    -- The proximity room is in the target for EVERY player in every mode --
    -- that is the line whose absence made two solo players standing next to
    -- each other inaudible to one another (#150).
    --
    -- Squadmates are added BY SERVER ID rather than by room (#157). Unlike a
    -- channel, a player id resolves against the Mumble user list rather than
    -- the channel list, so there is nothing to create and nothing to wait for:
    -- the call cannot be refused for naming a room that does not exist,
    -- because it does not name a room.
    if canRoute() then
        MumbleAddVoiceTargetChannel(TARGET, s.prox)
        s.talkTo[#s.talkTo + 1] = s.prox
        if wantSquad and canRadio() then
            for _, src in ipairs(s.mates) do
                MumbleAddVoiceTargetPlayerByServerId(TARGET, src)
                s.radioTo[#s.radioTo + 1] = src
            end
        end
        MumbleSetVoiceTarget(TARGET)
    end

    -- AND WHOSE VOICE IS EXEMPT FROM THE CUTOFF. Routing gets a squadmate's
    -- audio to this machine; only the override gets it past the mixer once
    -- they are more than range.nearby away.
    radio()

    s.applied = true
end

--- Open or shut the per-player volume override for each squadmate.
---
--- THIS IS WHAT MAKES SQUAD VOICE LONGER-RANGED THAN PROXIMITY VOICE, and it
--- is the only mechanism that can be: a Mumble distance is one number per
--- speaker and per listener, so "25 m for strangers, the map for my squad"
--- cannot be said with distances. It is said one squadmate at a time.
---
--- Re-run on every squad position push, on the slow band, and out of route().
--- All three are cheap: a squad is at most four people and the calls are
--- skipped when nothing has changed, so a settled squad costs a table lookup
--- per mate per second.
---
--- @param shutAll boolean|nil  close every override regardless of range
radio = function(shutAll)
    local s = BR.Voice.state
    if not canRadio() then return end

    local want = {}
    if not shutAll and BR.Voice.pref.mode ~= 'nearby'
        and BR.Voice.pref.mode ~= 'off' then
        for _, src in ipairs(s.mates) do
            local d = mateDistance(src)
            -- nil is "nobody has said where they are" -- on the bus, or in the
            -- first second. Audible: see matePos above.
            if d == nil or d <= s.squad then want[src] = true end
        end
    end

    for src in pairs(want) do
        if not s.heard[src] then
            -- 1.0 is "as loud as they would be standing next to you", which is
            -- what a radio should sound like. The point of the call is not the
            -- level, it is that setting one at all takes this speaker out of
            -- the distance calculation entirely.
            MumbleSetVolumeOverrideByServerId(src, 1.0)
            s.heard[src] = true
        end
    end
    for src in pairs(s.heard) do
        if not want[src] then
            -- -1.0 is the documented "stop overriding", not "mute". Muting
            -- them would leave a squadmate standing next to you inaudible,
            -- which is the opposite of the intent: out of radio range they go
            -- back to being an ordinary voice in the proximity room.
            MumbleSetVolumeOverrideByServerId(src, -1.0)
            s.heard[src] = nil
        end
    end
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
    s.prox   = math.tointeger(tonumber(d.prox))
    s.nearby = tonumber(d.nearbyRange) or NEARBY_M
    s.squad  = tonumber(d.squadRange) or SQUAD_M

    -- WHO COUNTS AS A SQUADMATE IS THE SERVER'S ANSWER, and it is the whole of
    -- the payload that used to be a channel number. An empty list is a solo,
    -- a player whose squad has not formed yet, or a player in the lobby -- all
    -- of which mean the same thing here: proximity only.
    s.mates = {}
    for _, v in ipairs(type(d.mates) == 'table' and d.mates or {}) do
        local src = math.tointeger(tonumber(v))
        if src then s.mates[#s.mates + 1] = src end
    end

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

    -- THE RADIO'S REACH, RE-DECIDED ONCE A SECOND.
    --
    -- The squad position push is the usual trigger and it arrives at the same
    -- rate, but it stops entirely when the squad is on the bus or the server
    -- has nothing to say -- and a squadmate who walks out of range while the
    -- push is quiet must still fall out of the radio. One pass over at most
    -- three server ids.
    radio()
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
    print(('  squadmates   %s'):format(
        #s.mates > 0 and table.concat(s.mates, ', ') or 'none (solo)'))
    print(('  applied      %s'):format(tostring(s.applied)))

    -- THE LINES #157 NEEDED. Both of them, because a range that is not stated
    -- and a range that is stated as zero look identical from the outside and
    -- sound identical in the game: everybody hears everybody, everywhere.
    print(('  nearby range %.0fm'):format(s.nearby))
    print(('  squad range  %.0fm'):format(s.squad))
    print(('  range set    %s'):format(canRange() and 'yes'
        or 'NO -- distance natives missing; voice will be GLOBAL'))

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
    print(('  radio to     %s'):format(
        #s.radioTo > 0 and table.concat(s.radioTo, ', ')
            or 'nobody (solo, or nearby-only)'))

    -- WHO IS EXEMPT FROM THE CUTOFF. "radio to" above is where our microphone
    -- goes; this is whose voice gets past our own 25 m gate on the way in, and
    -- in a squad match the two lists should match. If "radio to" names people
    -- and this says nobody, squadmates can hear you and you cannot hear them.
    local heard = {}
    for src in pairs(s.heard) do heard[#heard + 1] = src end
    table.sort(heard)
    print(('  hearing past the cutoff  %s'):format(
        #heard > 0 and table.concat(heard, ', ') or 'nobody'))
    print(('  can route    %s'):format(canRoute() and 'yes'
        or 'NO -- voice-target natives missing on this build'))
    print(('  can radio    %s'):format(canRadio() and 'yes'
        or 'NO -- player-target natives missing; squad voice is proximity only'))

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
    print('  "settled" both saying yes -- and, if they are further apart than')
    print('  the nearby range, each other\'s ids on the "hearing past" line.')
end, false)

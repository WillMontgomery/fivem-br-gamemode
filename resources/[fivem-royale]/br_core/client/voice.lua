-- Voice, client half: apply the channels the server assigned.
--
-- FiveM's built-in Mumble does the hard part -- capture, codec, positional
-- mixing -- and this file does the only part it cannot: deciding WHO is in
-- the room. See server/voice.lua for why that decision cannot be made here.
--
-- NOTHING HERE IS AUTHORITATIVE. The server decides which room exists and who
-- is on whose squad; this file can only decline what it was given.
--
-- WHAT THAT IS AND IS NOT WORTH, stated precisely, because it changed with the
-- third round of #157 and an out-of-date claim here would be worse than none.
--
--   ACROSS MATCHES it is still a hard boundary, and that is the one that
--   matters. A client that ignored every line of this would put itself in a
--   Mumble room the server never told anyone else to join, so the failure mode
--   is silence rather than eavesdropping. Match isolation is the channel, the
--   channel is the server's, and none of it has moved.
--
--   WITHIN ONE MATCH there is no boundary at all, and as of this round there is
--   no RANGE either. Everybody in a match hears everybody in that match,
--   wherever they are standing. That is a knowingly-shipped regression in
--   feature terms and a knowingly-shipped repair in working terms -- see the
--   NOBODY IS MUTED BY DEFAULT block below for why the alternative was silence.

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
    heard  = {},        -- [src] = true while a RADIO override is open for them

    -- WHO WE CAN CURRENTLY HEAR. Since the third round of #157 that is
    -- everybody in the match unless the player chose 'off', and this table
    -- says so explicitly rather than being left empty -- the talking indicator
    -- is drawn from it, and an empty set is what stopped it rendering.
    audible = {},       -- [src] = true
    -- [src] = the volume override we currently hold open on that player.
    -- 1.0 is the squad radio, 0.0 is 'off'. Absent -- which is the normal state
    -- for almost everyone -- means we hold none and the engine mixes them.
    over   = {},
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

--- Can we decide, per player, whether we hear them?
---
--- Squad voice needs both of these and so, now, does proximity voice: one
--- routes our audio to a squadmate without a room in the middle, and the other
--- is the ONLY per-listener volume control the engine exposes. Missing these is
--- not a degraded feature any more -- it is a client with no receive-side gate
--- at all, which is a match-wide party line. See the LISTENING IS OURS block.
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
-- NOBODY IS MUTED BY DEFAULT. THERE IS NO PROXIMITY CUTOFF ANY MORE (#157).
--
-- READ THIS BEFORE ADDING ONE BACK. Two rounds have now tried to give voice a
-- range and both shipped SILENCE, which is a worse bug than the one they were
-- fixing, and the second one took squad voice down with it. Owner, after the
-- second attempt:
--
--   "Confirmed in squads that the squad chat no longer works either. No errors
--    in the console, and it looks like I'm talking, but nobody can hear me."
--   "With both players set to 'nearby' - neither can hear each other or see
--    that they're talking, despite standing directly across from each other."
--
-- WHAT THE SECOND ATTEMPT DID. It made the receive side a whitelist: every
-- player on the roster got an explicit per-player volume override, 0.0 for
-- anyone this client could not place, and the talking indicator was rewired
-- onto the same set. Then it ran that on the 10Hz band from the first tick.
--
-- AND THE FIRST TICK IS THE PROBLEM, which is a thing no amount of reading the
-- rule could show, because the rule is right and the CLOCK is wrong. At the
-- start of a match no other player's ped has streamed in yet, so the distance
-- to every one of them is nil, so every one of them is written a 0.0 mute
-- before anybody has moved. Recovery then depended entirely on -1.0 handing a
-- player back to the engine's own mixing -- an engine behaviour this project
-- has never observed, only assumed, and which the suite ASSUMED IN THE SAME
-- CHANGE by modelling -1.0 as removal. Code and test agreed with each other
-- and neither of them had asked the engine.
--
-- THE SAFETY ARGUMENT WAS ALSO FALSE, and naming that is the point of this
-- block. It read: "if this function never ran, every player would be audible --
-- loud, obvious, reported in a minute". True of a function that never runs.
-- Not true of one that runs constantly and writes silence as its default
-- answer, which is what it became. A default of MUTE cannot fail safe.
--
-- SO THE DEFAULT IS AUDIBLE, EVERYWHERE, AND THE ONLY MUTE LEFT IS THE ONE THE
-- PLAYER ASKED FOR. Three rules, and there is no fourth:
--
--   off      every player is muted, because the player chose that.
--   nearby   nobody is muted. No cutoff. Match-wide.
--   squad    nobody is muted, and squadmates additionally get a flat 1.0 so
--            they sound like a radio.
--
-- A player this client cannot place is AUDIBLE. That is the single assertion
-- worth keeping from this round; it is in tools/test_client.lua and it fails
-- on the code this replaced.
--
-- WHAT IS KNOWINGLY GIVEN UP: proximity voice has no proximity. Somebody
-- 800 m away is as audible as somebody standing next to you. That is a real
-- loss and it is not being papered over -- but a squad that can talk beats a
-- range that silences the squad, and the range can be rebuilt on the transmit
-- side (see the pma-voice block below) where a mistake costs nobody their ears.
--
-- ==========================================================================
-- WHY THE ENGINE'S OWN DISTANCE CUTOFF IS STILL NOT CALLED (#157, round one).
--
-- The round before THAT handed Mumble a range and the owner reported the
-- result:
--
--   "'off' does not work - it still leaves a player in what seems to be
--    global, and it always feeds audio through regardless of distance."
--   "curiously, regardless of distance, 'nearby' doesn't output audio, though
--    it does show who's talking, even when they should be out of range."
--
-- THREE FACTS, AND THEY ONLY FIT ONE SHAPE. Squad voice worked perfectly.
-- 'nearby' went silent at EVERY distance, including nose to nose. And the
-- talking indicator still lit up for the people who could not be heard.
--
-- The indicator is the tell. It is driven by MumbleIsPlayerTalking, which is
-- true when frames from that speaker are ARRIVING and being decoded. So the
-- audio reached the machine -- room, target and routing all correct -- and the
-- mixer played it at zero. Not a routing fault. A volume fault.
--
-- WHAT THE ENGINE ACTUALLY DOES, from voip-mumble/src/MumbleAudioOutput.cpp:
--
--   distance = min(listener's m_distance, speaker's client->distance)
--   if both are < 0.01      the speaker is ALWAYS AUDIBLE, wherever they are.
--   if overrideVolume >= 0  distance is skipped entirely and audibility is
--                           simply (overrideVolume >= 0.005).
--   if the speaker's position is zero/uninitialised, the speaker is SILENCED
--                           outright -- isAudible = false, volume 0.
--
-- Line one is the state this game shipped in for a week: no distance anywhere,
-- so everybody heard everybody. Line two is why squad voice is the one thing
-- that works. LINE THREE IS WHY 'nearby' WENT SILENT: the moment a distance is
-- stated the engine starts comparing positions, and a speaker it has no
-- position for is not distant, it is silenced. Standing on top of each other
-- did not help because the comparison never involved where anybody was.
--
-- We cannot fix that from Lua. There is no native that makes the Mumble
-- positional stream arrive, and a cutoff that silences everyone is worse than
-- no cutoff at all. So THE DISTANCE NATIVES ARE NOT CALLED ANY MORE:
--
--   MumbleSetAudioInputDistance / MumbleSetAudioOutputDistance -- gone.
--   MumbleSetTalkerProximity, which the engine routes into the same
--   SetAudioDistance, is deliberately NOT called either, for the same reason.
--
-- The engine is therefore left in the state that PROVABLY DELIVERS AUDIO -- no
-- cutoff anywhere, everybody in the room audible to everybody else. That was
-- once described here as an interim state with a Lua-side cutoff layered over
-- it. The Lua-side cutoff is gone (see the block above); this state is now the
-- whole of it, and the only per-player level left is:
--
--   MumbleSetVolumeOverrideByServerId(src,  1.0)   radio: flat, any range.
--                                                  An UPGRADE, never a gate.
--   MumbleSetVolumeOverrideByServerId(src,  0.0)   muted. ONLY on 'off'.
--   MumbleSetVolumeOverrideByServerId(src, -1.0)   no override; back to the
--                                                  engine's own mixing.
--
-- THE ONE THING THAT IS NOT KNOWN ABOUT THIS NATIVE, and it is why the rules
-- above are shaped the way they are: whether -1.0 really does restore engine
-- mixing has never been observed, in game or anywhere else. It is documented
-- and it is believed and it has never been WATCHED. Every path in this file
-- that has to release an override therefore writes 1.0 first and -1.0 second,
-- so that a -1.0 the engine ignores leaves the player AUDIBLE rather than
-- however it was left. See the release loop in listen().
--
-- NetworkSetTalkerProximity(25.0) is still called. It is a GTA native, it
-- belongs to the game's own voice path rather than to Mumble, it costs nothing,
-- and it is the right number for that path if voice_useNativeAudio is ever
-- turned on. It has never been what gates Mumble and it is not what gates it
-- now.
--
-- ==========================================================================
-- CHECKED AGAINST pma-voice (MIT, (c) 2021 Dillon Skaggs), which is the most
-- widely deployed voice resource on FiveM. Two things came out of reading
-- client/init/proximity.lua and its README, and they point opposite ways.
--
-- IT CONFIRMS THE DIAGNOSIS ABOVE, INDEPENDENTLY. pma-voice does not call
-- MumbleSetAudioInputDistance or MumbleSetAudioOutputDistance anywhere, and
-- its README asks other resources not to set them either, because "there have
-- been cases where it breaks pma-voice". A resource with years of field
-- exposure does not hand the engine a number and trust the gate -- which is why
-- this file does not either, and it is a stronger reason than our own playtest.
--
-- IT ALSO DOES IT ON THE OTHER SIDE OF THE CONVERSATION, AND THAT IS BETTER.
-- Every player there has their own channel and listens ONLY to their own. A
-- speaker walks the players near THEM and adds each one's channel to their own
-- voice target -- so you hear somebody because they decided you were close
-- enough to send to. Proximity is enforced by the speaker, and audio from out
-- of range never leaves their machine.
--
-- (Note for anyone reading pma-voice to check this: its MumbleAddVoiceChannelListen
-- calls are NOT how it does proximity. Ordinary range is target selection,
-- above; the per-player listen calls serve spectator mode and phone calls.)
--
-- AND IT IS THE ONLY REMAINING PLACE A RANGE CAN GO, now that the receive-side
-- one has been taken out. IT IS ALSO THE SAFE PLACE FOR ONE, which is the whole
-- argument: a transmit-side range that is wrong makes the speaker inaudible to
-- people they should have reached. A receive-side range that is wrong makes the
-- LISTENER deaf to everybody, including their own squad, which is what shipped.
-- The failure is one player's microphone instead of one player's ears, and it
-- cannot mute a squad, because squadmates are named in the target directly.
--
-- WHAT WOULD HAVE TO BE TRUE BEFORE TRYING IT, because two rounds have now been
-- lost to acting on an engine behaviour nobody watched:
--
--   * A VOICE TARGET HAS LIMITS NOTHING HERE CAN MEASURE. Twenty-five metres on
--     a hot drop is twenty players, and a target that overflows fails the way
--     everything in this file fails -- silently. That is the exact failure
--     class this issue has already shipped twice, and it needs an observation
--     in a real match rather than an argument in a comment.
--   * REBUILDING THE TARGET EVERY TICK IS NOT WHAT IT DOES TODAY. Today it is
--     stated once, after the room is confirmed. A range means re-stating it as
--     people walk, and clearing a target is a hole in a live conversation.
--
-- IT DOES NOT NEED PER-PLAYER CHANNELS: we have
-- MumbleAddVoiceTargetPlayerByServerId already, squad voice has been riding it
-- since #157, and pointing it at nearby players instead of at the match room
-- expresses the same idea without touching the server's channel scheme -- which
-- is worth keeping, because pma-voice serves one world and we run parallel
-- matches on the same coordinates. AFTER the playtest, not with it.
-- ==========================================================================
--
-- ==========================================================================
-- WHICH IS ALSO WHY SQUAD VOICE IS NOT A ROOM.
--
-- Audibility is a property of a SPEAKER and a LISTENER, never of a channel. A
-- room cannot carry its own range: a squad room would deliver a squadmate's
-- voice faithfully from the far side of the map and then be gated on arrival by
-- whatever rule the listener applies to everyone. That was true when the rule
-- lived in the engine, it stayed true when the rule briefly lived in this file,
-- and it is why the squad room did not come back when the rule was removed --
-- a listener-side gate never knew which room a stream came through, so a room
-- was never going to be what exempted anyone from it.
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
--   HEAR    MumbleSetVolumeOverrideByServerId(src, 1.0) -- heard at a flat
--           level out to BR.Config.Match.voice.range.squad.
--
-- THAT SECOND LINE IS NOW A COMFORT, NOT A REQUIREMENT, and the distinction is
-- what stops the next round breaking squad voice again. With no cutoff anywhere
-- a squadmate is audible whether or not the radio is open; the 1.0 only makes
-- them sound like a radio rather than like a voice on the far side of a field.
-- So range.squad may DECLINE to open the radio and must never CLOSE the ears:
-- past range.squad a squadmate falls back to being an ordinary audible player,
-- not to silence. Muting them there is the bug this round exists to remove.
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
local listen

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
--- @param me table|nil  our own coordinates, hoisted by the caller
local function mateDistance(src, me)
    local p = matePos[src]
    if not p then return nil end
    me = me or GetEntityCoords(PlayerPedId())
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
    if listen then listen() end
end)

-- THERE WAS A playerDistance() HERE AND IT IS DELIBERATELY GONE.
--
-- It measured the distance to a STRANGER off their streamed ped, and returned
-- nil when the client had no ped for them. Its docstring argued that nil was
-- exact rather than approximate -- out of scope is hundreds of metres, so
-- unplaceable really does mean too far to hear -- and that treating nil as
-- inaudible "fails the safe way, toward silence".
--
-- BOTH HALVES WERE WRONG, AND THE SECOND ONE IS THE ONE THAT COST A PLAYTEST.
-- Out of scope is not the only way to be unplaceable: so is the first tick of a
-- match, before anything has streamed, which is when this ran hardest. And
-- silence is not the safe way for a voice system. It is the failure mode that
-- gets reported a week late with "no errors in the console".
--
-- Nothing measures the distance to a stranger any more, because nothing gates
-- on it any more. If a range comes back it belongs on the transmit side (see
-- the pma-voice block), where the same nil cannot deafen the person holding it.
-- git show 6f40809 has the body if it is ever wanted back.

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
    --   off     stop transmitting, and stop listening
    --   nearby  the proximity room. No cutoff -- the whole match (#157, r3)
    --   squad   that, plus a flat radio to squadmates out to range.squad
    if BR.Voice.pref.mode == 'off' then
        -- HALF OF 'OFF' IS THE MICROPHONE. This is the half that always worked.
        if MumbleSetActive then MumbleSetActive(false) end

        -- ...EXCEPT THAT IT IS NOT THE WHOLE MICROPHONE, WHICH IS THE OTHER
        -- THING THE OWNER REPORTED: "When set to 'off', pressing the PTT button
        -- still shows that I'm talking."
        --
        -- MumbleSetActive is Mumble's switch. GTA has its OWN voice chat behind
        -- its own switch, and the "currently talking" prose the owner sees is
        -- the game's, not ours -- our indicator is the bottom-centre panel and
        -- it is driven from BR.Voice.state.audible further down. Turning one off
        -- says nothing about the other, so both are turned off here.
        --
        -- GUARDED, AND UNVERIFIED. NetworkSetVoiceActive is a stock GTA native
        -- and this is what it is for, but nobody on this project has watched it
        -- suppress that specific prose. If it turns out not to be the right
        -- switch, the cost is one no-op call and the prose stays -- it cannot
        -- take audio away, because every other mode sets it back to true one
        -- line below before anything else happens.
        if NetworkSetVoiceActive then NetworkSetVoiceActive(false) end

        -- AND THE OTHER HALF IS THE EARS, which is what the owner reported
        -- missing: "'off' does not work - it still leaves a player in what
        -- seems to be global... 'you are not transmitting' should also mean
        -- 'you are not listening', but alas both are false."
        --
        -- It was false because nothing here ever addressed listening at all.
        -- MumbleSetActive(false) is a microphone switch and nothing more: the
        -- player stayed in the room, every stream in that room kept arriving,
        -- and with no cutoff anywhere they were all played. Muting every one of
        -- them, one at a time, is what 'off' means and it is what listen() does
        -- when the mode is 'off'.
        --
        -- THIS IS THE ONLY PLACE IN THE FILE THAT WRITES A MUTE, and it stays
        -- because the player asked for it in the settings screen. Every other
        -- mute was removed this round; see the NOBODY IS MUTED BY DEFAULT block.
        --
        -- The voice target goes too. Nothing should be able to leak out of a
        -- client that has been told to be silent, and a target left loaded is
        -- one MumbleSetActive(true) from anywhere away from transmitting again.
        if canRoute() then MumbleClearVoiceTarget(TARGET) end
        s.talkTo, s.radioTo = {}, {}
        listen()

        s.applied = false
        return
    end
    if MumbleSetActive then MumbleSetActive(true) end
    -- ...and the game's own voice comes back with it, whatever 'off' did to it.
    if NetworkSetVoiceActive then NetworkSetVoiceActive(true) end

    -- THE ENGINE'S OWN DISTANCE CUTOFF IS NOT ARMED, DELIBERATELY.
    --
    -- MumbleSetAudioInputDistance / MumbleSetAudioOutputDistance used to be
    -- called here with the nearby range, and that is what made 'nearby' silent
    -- at every distance -- see the block at the top of this file. Stating any
    -- distance switches the engine onto a position comparison it has no
    -- positions for, and a speaker it cannot place is silenced rather than
    -- treated as near. Leaving both unset is the state that provably delivers
    -- audio, and as of this round it is the ONLY thing deciding audibility:
    -- listen() no longer narrows it, it only opens squad radios.
    --
    -- This is a NEGATIVE requirement, so it is asserted in tools/test_client.lua
    -- rather than left as a comment somebody re-adds in good faith.

    -- The GTA-side talker proximity. It is not what gates Mumble -- see the
    -- block above -- but it is the right number to hand the game's own voice
    -- path, which is what `voice_useNativeAudio` switches playback onto.
    NetworkSetTalkerProximity(s.nearby)

    -- RE-DECIDE WHO WE HEAR.
    --
    -- A volume override is not undone by clearing a channel or a target -- it is
    -- a standing instruction to the mixer and it outlives both. Without this, a
    -- player who switched from 'squad' to 'nearby' kept hearing their old squad
    -- at any range while the interface told them they were on proximity only,
    -- and a player who returned to the lobby kept hearing the match they had
    -- just left. listen() reconciles the whole set against the new mode and the
    -- new squad, so nothing is left open that should not be.
    listen()

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

    -- AND WHO WE HEAR. Routing gets audio TO people; this decides what is
    -- played of what arrives here, and the two are genuinely separate -- that
    -- separation being the whole of this round of #157.
    listen()

    s.applied = true
end

--- DECIDE WHO THIS PLAYER CAN HEAR, AND MAKE THE ENGINE AGREE.
---
--- THE ONE OWNER OF THE RECEIVE SIDE, AND IT NOW HAS ALMOST NOTHING TO OWN.
--- That is the fix. The version this replaces built a whitelist -- every player
--- on the roster got an explicit answer every 100 ms, and the answer for anyone
--- it could not place was 0.0. Read as a rule it was correct. Run from the
--- first tick of a match, before a single ped has streamed, it wrote silence
--- over the entire roster and depended on -1.0 to undo it. See the NOBODY IS
--- MUTED BY DEFAULT block at the top of this file.
---
--- THE RULE NOW, in full:
---
---   AUDIBLE IS THE DEFAULT AND IT IS NOT WRITTEN ANYWHERE. No override is the
---   engine's own mixing, and with no distance armed (apply()) that is audible.
---   Doing nothing is therefore the correct answer for almost every player, and
---   a tick that does nothing cannot silence anybody.
---
---   1.0   RADIO, and ONLY an upgrade. A squadmate inside range.squad, flat and
---         centred. Past range.squad the radio simply is not opened and they go
---         back to being an ordinary audible player -- NOT to 0.0.
---   0.0   MUTED, and ONLY when the player chose 'off'. There is no other
---         producer of this value in the file, and there must not be one.
---
--- THE COST, NAMED: there is no proximity cutoff. Everybody in the match hears
--- everybody in the match. Restoring a range is a transmit-side job now; the
--- pma-voice block at the top says why and what has to be true first.
---
--- Run on the 10Hz band with the indicator, on every squad position push, and
--- out of apply()/route(). Cost is one pass over the roster -- the same pass the
--- talking indicator was already making, now made once for both -- and, once
--- settled, ZERO native calls, because want[] stops changing.
listen = function()
    local s = BR.Voice.state
    local mode = BR.Voice.pref.mode

    -- WHAT WE HOLD OPEN, and WHO WE CAN HEAR. Two different questions now that
    -- they have stopped being the same one: `want` is the small set of players
    -- we are actively overriding, `audible` is everybody, because everybody is.
    local want, audible = {}, {}

    -- CAN WE MUTE AT ALL? On a build without the volume-override native the
    -- answer is no -- and 'off' therefore cannot silence anybody, whatever the
    -- settings screen says. That has to change what the INDICATOR claims, not
    -- just what the audio does: an empty "Currently Talking" panel over a match
    -- the player can plainly hear is the same class of lie this round exists to
    -- remove. So on such a build, 'off' still reports everyone as audible,
    -- because everyone is. /brvoice says so out loud on the "cutoff by" line.
    local canMute = canRadio()

    if mode ~= 'off' or not canMute then
        -- EVERYONE IS AUDIBLE. No distance is consulted and none is available
        -- to consult; this loop exists to feed the talking indicator, not to
        -- decide anything, and it writes no native calls at all.
        --
        -- The roster is the right list. It is a server broadcast, it carries
        -- every connected player rather than every player in scope, and it is
        -- the same list the interface already draws from. A player who is
        -- somehow not on it is a player in another match, and another match is
        -- another Mumble room -- a wall this does not need to duplicate.
        for src in pairs(BR.State.roster or {}) do
            if src ~= (BR.State.me and BR.State.me.src) then
                audible[src] = true
            end
        end

        -- AND SQUADMATES GET THE RADIO ON TOP OF THAT. Audible either way; the
        -- override only changes what they SOUND like, from a voice somewhere in
        -- the world to a flat centred one. A squadmate is audible even if they
        -- are not on our roster copy yet, which is why they are added here
        -- rather than being looked up in the loop above.
        if mode == 'squad' then
            local me = GetEntityCoords(PlayerPedId())
            for _, src in ipairs(s.mates) do
                local d = mateDistance(src, me)
                -- nil is "nobody has said where they are" -- on the bus, or in
                -- the first second of a match. Audible: see matePos above.
                -- Past range.squad we DECLINE the radio and stop; we do not
                -- mute, because that was the bug.
                if d == nil or d <= s.squad then want[src] = 1.0 end
                audible[src] = true
            end
        end
    else
        -- 'OFF' IS NOT A SPECIAL CASE, IT IS THE ONLY CASE THAT MUTES. Nobody is
        -- audible, so everybody on the roster is muted -- including squadmates,
        -- whose radio would otherwise outlive the setting exactly as it used to.
        for src in pairs(BR.State.roster or {}) do
            if src ~= (BR.State.me and BR.State.me.src) then want[src] = 0.0 end
        end
        for _, src in ipairs(s.mates) do want[src] = 0.0 end
    end

    -- AND THE ANSWER IS PUBLISHED BEFORE ANY NATIVE IS TOUCHED, so that a build
    -- which cannot hold overrides still feeds the indicator. This used to sit at
    -- the bottom behind an early `if not canRadio() then return end`, which
    -- meant the one build where voice is guaranteed to work -- no gate, no
    -- mutes, everybody audible -- was also the one build that showed nobody
    -- talking. Fail-open has to reach the screen too, not just the mixer.
    s.audible = audible
    if not canMute then
        s.heard, s.over = {}, {}
        return
    end

    -- RECONCILE. Only the differences are sent: a settled match makes no native
    -- calls at all on this band, which is what lets it sit at 10Hz.
    for src, level in pairs(want) do
        if s.over[src] ~= level then
            MumbleSetVolumeOverrideByServerId(src, level)
            s.over[src] = level
        end
    end
    for src in pairs(s.over) do
        if want[src] == nil then
            -- RELEASING AN OVERRIDE IS THE ONE THING HERE THAT CANNOT BE TESTED
            -- OFFLINE, SO IT IS DONE TWICE.
            --
            -- -1.0 is the documented "stop overriding", which is NOT the same as
            -- 0.0: it hands the speaker back to the engine's own mixing, which
            -- is where they sound like a person in the world again. That is
            -- what the documentation says. Nobody on this project has ever
            -- WATCHED it happen, and the previous round of #157 built its entire
            -- recovery path on it -- and wrote a test stub that modelled -1.0 as
            -- removal, so the assumption checked itself and passed.
            --
            -- So the release is 1.0 THEN -1.0. If -1.0 works, the second call
            -- wins and the speaker is positional, exactly as intended. If -1.0
            -- turns out to be ignored, clamped, or read as a volume, the first
            -- call is what stands and the speaker is AUDIBLE at full volume.
            -- Two natives on a rare transition, and neither outcome is silence.
            MumbleSetVolumeOverrideByServerId(src, 1.0)
            MumbleSetVolumeOverrideByServerId(src, -1.0)
            s.over[src] = nil
        end
    end

    -- The radio set, kept for /brvoice: whose voice we are holding open at a
    -- flat level, as opposed to whose voice the engine is mixing for us.
    s.heard = {}
    for src, level in pairs(want) do
        if level == 1.0 then s.heard[src] = true end
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

        -- AND THAT INCLUDES EVERY VOLUME OVERRIDE. listen() only sends the
        -- DIFFERENCES between what it wants and what it believes is already
        -- set, which is what lets it sit on the 10Hz band -- and a reconnected
        -- engine holds none of them while this table still claims all of them.
        -- Left alone, every mute and every squad radio would be skipped as
        -- already-done, and the player would come back to a wide-open match
        -- with a silent squad. Forgetting first is what makes the re-apply
        -- real; nothing is leaked by it, because the engine has already
        -- dropped what these entries describe.
        BR.Voice.state.over = {}
        BR.Voice.state.heard = {}
        BR.Voice.state.audible = {}

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

    -- Who we hear is re-decided on the 10Hz band with the indicator, below --
    -- players move faster than this band can follow.
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

-- WHO IS TALKING -- AND ONLY PEOPLE WE CAN ACTUALLY HEAR.
--
-- Voice was the one system in this game with no visual at all: somebody
-- speaks and there is nothing on screen to say who (owner, 2026-08-09).
--
-- THE INDICATOR WAS LYING, AND THE LIE IS WHAT DIAGNOSED #157. Owner:
-- "regardless of distance, 'nearby' doesn't output audio, though it does show
-- who's talking, even when they should be out of range."
--
-- MumbleIsPlayerTalking answers "are frames arriving from this player and being
-- decoded", which is a fact about the network, not about the mixer. Every
-- player in the match is in one Mumble room, so frames arrive from all of them
-- whether or not a single one is played -- and the indicator faithfully listed
-- people the player could not hear. Two halves of one system with nothing
-- joining them, which is precisely what the routing/listening split was.
--
-- So it is joined here: this filters the talking flag through the set listen()
-- has just decided is audible, and through nothing else. A name on screen means
-- "you are hearing this person" because it is read from the same table the
-- audio decision was made from, whatever that decision happens to be.
--
-- AND THAT COUPLING IS WHY IT WENT BLANK. Owner, after round two: "when using
-- my PTT, the fivem default prose shows up 'currently talking' but ours doesn't
-- anymore." Nothing was wrong with this callback. listen() had muted the entire
-- roster, so `audible` was empty, so there was nobody to name -- the indicator
-- was reporting the audio bug accurately and it read as a second bug. It is
-- fixed by fixing listen(), and the coupling is kept precisely because a blank
-- indicator is now a truthful alarm rather than a display fault.
--
-- ONE PASS, NOT TWO. This used to walk the roster on its own tick and listen()
-- would have walked it again -- same list, same band, same scope lookup per
-- entry. So they are one callback, and the indicator physically cannot
-- disagree with the audio.
--
-- Sent on CHANGE, never on the tick. Ten pushes a second of an unchanged list
-- is ten re-renders a second of a panel that has not moved.
local lastKey = ''
BR.Loop.register(BR.Loop.TICK, 'voice.hear', function()
    -- FIRST, AND UNCONDITIONALLY: who can we hear. This runs in every mode
    -- including 'off' -- a player who joins the roster while we are muted has
    -- to be muted too, and there is no event for that.
    listen()

    if not MumbleIsPlayerTalking then return end

    local talking = {}
    for src in pairs(BR.Voice.state.audible) do
        local ply = GetPlayerFromServerId(src) -- scope-ok: presentation only, and listen() has already ruled on audibility
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

    -- THE LINES #157 NEEDED, AND THE ONE THAT HAS NOW BEEN WRONG TWICE.
    --
    -- It first reported whether the engine's own distance cutoff had been armed
    -- -- always yes, while voice was silent, because arming it is what silenced
    -- it. It then reported that this client applied the cutoff per player --
    -- also true, also useless, because what it applied was silence. So it
    -- reports the only thing a playtester can act on: whether there is a cutoff
    -- at all. There is not, and saying so out loud is the point.
    print(('  nearby range %.0fm  (NOT ENFORCED -- see below)'):format(s.nearby))
    print(('  squad range  %.0fm'):format(s.squad))
    print('  cutoff by    NOBODY. There is no proximity cutoff (#157, round 3).')
    print('               Everyone in this match hears everyone in this match.')
    if not canRadio() then
        print('               ...and the squad radio is off too: the '
            .. 'volume-override native is missing on this build.')
    end

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

    -- WHO IS ON THE RADIO. "radio to" above is where our microphone goes; this
    -- is who we are holding open at a flat level on the way in, and in a squad
    -- match the two lists should match. It is no longer an exemption from
    -- anything -- everyone is audible -- it is only who sounds like a radio.
    local heard = {}
    for src in pairs(s.heard) do heard[#heard + 1] = src end
    table.sort(heard)
    print(('  radio open on  %s'):format(
        #heard > 0 and table.concat(heard, ', ') or 'nobody'))

    -- AND THE LINE THIS ROUND OF #157 NEEDED: everybody we can hear at all.
    --
    -- Every readout above describes where audio is SENT. This one is the only
    -- one about what arrives and is played. It is also exactly the list the
    -- "Currently Talking" indicator is drawn from -- so if this says nobody
    -- while other people are plainly in the match, that is the indicator bug
    -- and the audio bug at the same time, which is what round two shipped.
    local hear, muted = {}, 0
    for src in pairs(s.audible) do hear[#hear + 1] = src end
    table.sort(hear)
    for _, level in pairs(s.over) do
        if level == 0.0 then muted = muted + 1 end
    end
    print(('  hearing      %s'):format(
        #hear > 0 and table.concat(hear, ', ')
            or 'nobody -- correct for off, and for standing alone'))
    -- THE NUMBER THAT SHOULD BE ZERO IN EVERY MODE EXCEPT 'off'. A non-zero
    -- count here on 'nearby' or 'squad' means the receive-side whitelist has
    -- come back from somewhere and the player is going deaf again.
    print(('  muted        %d player(s)%s'):format(muted,
        BR.Voice.pref.mode == 'off' and ' -- off, so all of them'
            or ' -- MUST BE 0 outside off; anything else is #157 again'))
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
    print('  "settled" both saying yes, and each other on the "hearing" line.')
    print('  Distance is not a factor any more. If two players in one match')
    print('  cannot hear each other, it is the room or the target, never range.')
end, false)

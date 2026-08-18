-- Voice, client half: OUR RULES, EXPRESSED THROUGH pma-voice.
--
-- ==========================================================================
-- WHAT CHANGED, AND WHY THERE IS SO LITTLE LEFT HERE.
--
-- Every previous version of this file drove FiveM's raw Mumble natives itself:
-- it joined a room, filled a voice target, and decided per player whether the
-- mixer should play them. That is six rounds of #150/#157, four of which
-- shipped a SILENT 'nearby', and none of which could be tested -- nothing in
-- this repository can execute a Mumble native, so every round was reasoned
-- offline and found out in a playtest.
--
-- The owner has ended that: pma-voice (MIT, (c) Dillon Skaggs) now owns the
-- engine. It is the most widely deployed voice resource on FiveM, and the two
-- things this project kept failing at are the two things it does natively:
--
--   PROXIMITY WITH FALLOFF, enforced by the SPEAKER. pma-voice gives every
--   player their own Mumble channel and, four times a second, rebuilds its
--   voice target from the channels of the players near IT. You hear somebody
--   because they decided you were close enough to send to; audio from out of
--   range never leaves their machine. That is why it never had our bug: there
--   is no receive-side gate to get wrong, so a mistake costs one player's
--   microphone rather than one player's ears.
--
--   A RADIO AT ANY RANGE. MumbleAddVoiceTargetPlayerByServerId resolves against
--   the Mumble USER list rather than the channel list, so it reaches a player
--   the game has not streamed in. That is what squad voice has always needed
--   and it is what pma-voice's radio is built on.
--
-- SO THIS FILE NO LONGER CHANGES ANYTHING IN THE ENGINE. It calls exactly one
-- Mumble native, MumbleIsPlayerTalking, and that one is a READ -- it drives the
-- talking indicator and alters nothing. Every setter is gone.
--
-- THAT DISTINCTION IS THE RULE, not a technicality, and it is stated as a
-- boundary because the next round will be tempted to cross it: pma-voice's
-- README asks other resources not to touch NetworkSetTalkerProximity,
-- MumbleSetTalkerProximity, MumbleSetAudioInputDistance,
-- MumbleSetAudioOutputDistance or NetworkSetVoiceActive, "as there have been
-- cases where it breaks pma-voice" -- and every one of those is a native a
-- previous round of this file reached for. Two of them are what made 'nearby'
-- silent. Reading is fine. Writing is somebody else's job now, and
-- tools/test_client.lua asserts that none of them are written.
--
-- WHAT IS LEFT IS THE PART pma-voice CANNOT KNOW: our three modes, our squads,
-- and the bus.
--
-- ==========================================================================
-- THE THREE MODES, AND WHERE EACH ONE LANDS.
--
--   off      transmit to nobody, and hear nobody.
--            TRANSMIT: our proximity check (below) returns false for every
--            player, so pma-voice adds no channel to the voice target. The
--            radio is dropped by leaving the channel.
--            LISTEN: pma-voice's own per-player mute, reconciled every tick.
--            This is the ONLY thing in this file that can make a player deaf,
--            it happens only because the player asked for it in the settings
--            screen, and the loop that applies it is driven by the mode alone
--            so it lifts the instant the mode changes. See muteSweep().
--
--   nearby   proximity only, WITH FALLOFF, out to Config.Match.voice.range
--            .nearby. This is the capability the hand-rolled version gave up
--            in #157 round three and it is the reason for the whole change.
--            No radio channel.
--
--   squad    proximity, plus the squad radio -- a pma-voice radio channel the
--            SERVER assigns, audible at any distance, on the radio key.
--
-- ==========================================================================
-- THE BUS RULE, AND WHY THIS SHAPE CANNOT STICK.
--
-- Riding the drop bus on 'nearby' must not transmit. 'squad' on the bus is
-- unaffected, and listening is never affected.
--
-- IT HAS BEEN TRIED TWICE AND BOTH ATTEMPTS FAILED THE SAME WAY -- not on the
-- rule, on the CLOCK. 58502b0 gated on MumbleSetActive, which is not a
-- microphone switch at all but a Mumble DISCONNECT, and nothing rebuilt the
-- room or the target afterwards, so the gag lasted the whole match. The variant
-- before it gated inside apply(), which never re-runs on BUS -> FREEFALL, so
-- the gag never lifted either.
--
-- THE FIX IS THAT THERE IS NO LONGER ANY STATE TO GET STUCK IN. The rule now
-- lives inside the proximity check that pma-voice calls for every nearby player
-- four times a second, and it recomputes `onBus()` from BR.State.me.state on
-- every one of those calls. There is no transition handler, no cached boolean,
-- no `applied` flag and no event that can be missed -- if the player is no
-- longer in the seat, the very next call answers differently. A rule that is
-- re-derived cannot fail to lift.
--
-- AND IT CANNOT TAKE ANYTHING ELSE WITH IT, structurally rather than by
-- intention. The check only decides which OTHER players' channels go into our
-- voice target. It is not consulted for the radio, which pma-voice keeps in the
-- same target as PLAYERS rather than channels and rebuilds on a different path
-- (client/module/radio.lua), so 'squad' on the bus is untouched. And it is not
-- consulted for listening at all -- under pma-voice we hear somebody because
-- THEY targeted US, which is a decision on their machine that nothing here can
-- reach.
--
-- (There is a second, blunter lever -- LocalPlayer.state.disableProximity,
-- which pma-voice checks at the top of addNearbyPlayers(). It is deliberately
-- NOT used: it also skips that function's MumbleAddVoiceChannelListen call, and
-- "listening is unaffected" would then be a hope rather than a fact.)
--
-- ==========================================================================
-- WHAT STILL CANNOT BE VERIFIED FROM THIS REPOSITORY. Stated plainly, because
-- pretending otherwise is what produced six rounds.
--
--   * That any of this produces audio. Nothing here can execute a Mumble
--     native or run pma-voice. The suite proves our RULES -- which mode gags
--     what, that the bus gag lifts, that the squad channel is the server's --
--     against a model of pma-voice's documented surface. It cannot prove
--     pma-voice works, only that we are asking it for the right things.
--   * Whether MumbleSetTalkerProximity (which pma-voice calls on our behalf
--     via overrideProximityRange) also affects PLAYBACK attenuation, or only
--     the value pma-voice reads back for its own range maths. We no longer
--     care in the way we used to -- we do our own distance comparison -- but
--     it is not a settled question and it is not settled here.
--   * Whether `voice_enableUi 0` removes the duplicate "currently talking"
--     readout the owner has been looking at. It removes PMA-VOICE'S overlay --
--     that much is read off its source, see the note on the convar below --
--     and pma-voice's overlay is the only voice UI this server will now be
--     running. If a readout survives it, it is FiveM's own and it is not ours.
-- ==========================================================================

BR = BR or {}
BR.Voice = BR.Voice or {}

--- The resource that now owns the engine. Named once.
local VOICE_RES = 'pma-voice'

local V = (BR.Config.Match or {}).voice or {}
local R = V.range or {}

--- Fallbacks for the range, used when the server payload is missing it (an
--- older server, a hand-fired event, a test). Config is shared, so this is the
--- same number the server would have sent.
local NEARBY_M = R.nearby or 25.0

--- What the server last told us, plus what we last told pma-voice.
---
--- `radio` is the channel the SERVER assigned; `joined` is the channel we last
--- asked pma-voice for. They differ for exactly as long as it takes a mode
--- change to be applied, and /brvoice prints both, because "the server gave me
--- a channel" and "I am on it" are different claims and #150 was a week of
--- confusing the two.
BR.Voice.state = {
    radio  = nil,       -- squad radio channel the server assigned, or nil
    joined = nil,       -- what we last asked pma-voice to join; 0 = none
    mates  = {},        -- squadmate server ids, from the server
    nearby = NEARBY_M,  -- metres; the proximity range in force

    -- WHO WE CAN HEAR. Under pma-voice this is no longer a set we compute --
    -- audibility is decided by the SPEAKER, on their machine, and no native
    -- reports it. So this is the set we do not REFUSE: everybody, unless the
    -- player chose 'off'. The talking indicator is filtered through it, which
    -- keeps the old property that a blank indicator on 'off' is correct and a
    -- blank indicator anywhere else is an alarm.
    audible = {},       -- [src] = true

    -- Players we currently hold a pma-voice mute on. Only ever non-empty on
    -- 'off'. See muteSweep().
    muted  = {},        -- [src] = true
}

--- The player's own preference, from the settings screen.
---
--- NOT AUTHORITY. It can only decline what the server granted: the squad radio
--- CHANNEL NUMBER is the server's (see server/voice.lua, and the pma-voice
--- addChannelCheck it registers), and this only decides whether we ask to be
--- on it.
BR.Voice.pref = { mode = 'squad' }

--- Server ids heard speaking on the last tick, and their names. The squad panel
--- and the bottom-centre indicator read these.
BR.Voice.talking = {}
BR.Voice.names = {}

-- ---------------------------------------------------------------- presence ---

--- Is pma-voice actually running?
---
--- CHECKED EVERY TIME RATHER THAN CACHED, because it can start after us, stop
--- under us, and be restarted by an admin mid-match -- and the answer decides
--- whether an export call is a no-op or a hard error that takes the rest of the
--- callback with it.
---
--- br_core does NOT declare pma-voice in its fxmanifest. FiveM's `dependency`
--- is a hard gate: a missing one stops the resource starting, and a voice
--- resource that is not installed yet must not stop the gamemode booting. This
--- is the same shape as server/debug.lua's br_ddb check.
--- @return boolean
local function present()
    return GetResourceState(VOICE_RES) == 'started'
end

--- One export call, guarded, never fatal.
---
--- EVERY CALL INTO pma-voice GOES THROUGH HERE. An export into a resource that
--- has stopped between the check and the call raises, and this file runs inside
--- callbacks that other subsystems share -- a raise here would take the 10Hz
--- band down with it.
--- @param name string  the export
--- @return any|nil  the export's return, or nil if it could not be called
local function call(name, ...)
    if not present() then return nil end
    local okc, res = pcall(function(...)
        return exports[VOICE_RES][name](exports[VOICE_RES], ...)
    end, ...)
    if not okc then
        -- Said once per export, not once per tick: a broken export on the 10Hz
        -- band would otherwise be several thousand lines of console a minute.
        if not BR.Voice._warned then BR.Voice._warned = {} end
        if not BR.Voice._warned[name] then
            BR.Voice._warned[name] = true
            print(('[br_core] VOICE: %s:%s failed -- %s. Is pma-voice the '
                .. 'version this was written against (v7.0.0 or later)?')
                :format(VOICE_RES, name, tostring(res)))
        end
        return nil
    end
    return res
end

-- ------------------------------------------------------------- the bus rule ---

--- Is this player in the drop bus seat right now?
---
--- Read straight off the mirrored player state on every call. It is deliberately
--- not cached and deliberately not hung off a state-change event: see the block
--- at the top of this file for the two rounds that were lost to exactly that.
--- @return boolean
local function onBus()
    local me = BR.State and BR.State.me
    return me ~= nil and me.state == BR.PlayerState.BUS
end

--- Is our proximity microphone gagged, and why?
---
--- ONE FUNCTION, TWO CALLERS, AND THAT IS THE POINT. The proximity check uses
--- it to decide, and /brvoice uses it to REPORT -- so the readout cannot drift
--- from the behaviour the way "prox channel 2003" did for a week while no audio
--- was leaving the machine.
--- @return boolean gagged
--- @return string|nil reason  human-readable, for /brvoice
function BR.Voice.gagged()
    local mode = BR.Voice.pref.mode
    if mode == 'off' then
        return true, "the player chose 'off'"
    end
    -- THE BUS RULE. 'nearby' only: a squad on the bus keeps its radio, which is
    -- the whole point of having one on the way to the drop.
    if mode == 'nearby' and onBus() then
        return true, 'riding the bus on nearby -- switch to squad, or jump'
    end
    return false, nil
end

-- --------------------------------------------------------------- proximity ---

--- Straight-line distance between two coordinate triples.
---
--- Written out rather than using BR.Dist because that one is 2D, and voice is
--- one of the few systems where the vertical really matters: somebody four
--- storeys above you is not standing next to you. Tolerates a missing z so the
--- suite's flat world still measures.
local function dist3(a, b)
    local dx = (a.x or 0.0) - (b.x or 0.0)
    local dy = (a.y or 0.0) - (b.y or 0.0)
    local dz = ((a.z or 0.0) - (b.z or 0.0))
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Our own coordinates, at most one pma-voice tick old.
---
--- The check below is called ONCE PER NEARBY PLAYER PER TICK, across a resource
--- boundary, and on a hot drop that is a lot of calls. Our own position cannot
--- have changed between two of them, so it is read once per 100 ms and shared.
--- `myPosAt` is nil rather than a sentinel number until the first read. A
--- numeric sentinel would compare as "fresh enough" against a game timer that
--- is still near zero -- a resource restart inside the first tenth of a second
--- of the session -- and hand out the origin as this player's position, which
--- puts everybody either in range or out of it depending on where the map's
--- zero is.
local myPos, myPosAt = { x = 0.0, y = 0.0, z = 0.0 }, nil
local function here()
    local now = GetGameTimer()
    if myPosAt == nil or now - myPosAt >= 100 then
        myPos, myPosAt = GetEntityCoords(PlayerPedId()), now
    end
    return myPos
end

--- SHOULD OUR AUDIO GO TO THIS PLAYER?
---
--- This is pma-voice's `addProximityCheck`, replaced through its own
--- `overrideProximityCheck` export. pma-voice calls it once per player in
--- its own streamed player list every `voice_refreshRate` ms (200 by default),
--- and adds that player's Mumble channel to our voice target when it returns
--- true.
---
--- THREE FACTS ABOUT THIS FUNCTION, ALL OF THEM LOAD-BEARING.
---
---   IT IS TRANSMIT-SIDE. Returning false means our audio does not reach them.
---   It says nothing about whether we hear them -- that is decided by the same
---   function running on THEIR machine. This is the asymmetry the whole change
---   is for: the worst thing a bug here can do is mute one player's microphone,
---   where the old receive-side gate's worst case was one player's ears, and
---   that is what shipped four times.
---
---   IT IS PURE, AND IT IS RE-ASKED CONSTANTLY. Every answer is derived from
---   the mode, the bus state and the two positions, on every call. Nothing is
---   remembered between calls, so no gag can outlive its cause.
---
---   IT ONLY EVER SEES PLAYERS IN SCOPE, because pma-voice offers it this
---   client's streamed player list and nothing else. A player in another
---   match's routing bucket is therefore never a candidate at all. That is now
---   what keeps two matches standing on the same coordinates out of each
---   other's conversations -- see the note in server/voice.lua, which is where
---   that claim is argued.
---
--- @param ply integer  a CLIENT player index, not a server id
--- @return boolean shouldAdd
--- @return number|nil distance  pma-voice records this; it is not a gate
local function proximityCheck(ply)
    -- 'off', and the bus. Both mean the same thing to the engine: this player's
    -- channel does not go in our target, so no frame of ours reaches them.
    if BR.Voice.gagged() then return false, nil end

    -- scope-ok: this is the ONE place where a scope-limited read is not a bug
    -- but the definition of the question. `ply` is not ours -- pma-voice took
    -- it from its own streamed player list and is asking us about that one
    -- player. Scope is a strict SUPERSET of proximity here: a player the game
    -- has not streamed to us is hundreds of metres away, which is an order of
    -- magnitude past a 25 m range, so nobody who could have been in range is
    -- missing from the list. Nothing about the roster, the match or the squad
    -- is derived from it -- those all still come from the server broadcast --
    -- and the answer is thrown away 200 ms later.
    local ped = GetPlayerPed(ply)  -- scope-ok: proximity audibility only; see above
    -- 0 is the engine's "no such ped". An unplaceable player is one we cannot
    -- measure to, and the honest answer is not to send -- which, on the
    -- transmit side, costs them hearing us and costs us nothing. On the receive
    -- side the same nil is what deafened a whole match twice; that is precisely
    -- the trade this change was made to get.
    if not ped or ped == 0 then return false, nil end

    local d = dist3(here(), GetEntityCoords(ped))
    return d < BR.Voice.state.nearby, d
end

--- Hand our rules to pma-voice. Idempotent.
---
--- CALLED AGAIN WHENEVER EITHER RESOURCE STARTS, and that is not belt and
--- braces. pma-voice resets the proximity check to its own default when the
--- resource that supplied one restarts -- it watches for exactly that in its
--- onClientResourceStop handler -- and it loses ours entirely when pma-voice
--- itself restarts, because the override lives in its Lua state. Either event
--- silently returns the whole server to a 7-metre "Normal" default, which is
--- the kind of thing that gets reported as "voice feels wrong today".
local function install()
    if not present() then return end
    call('overrideProximityCheck', proximityCheck)
    -- OUR RANGE, AND NO F11. pma-voice ships three cycleable modes (whisper /
    -- normal / shout, 3/7/15 m) and a key to cycle them. This game has one
    -- proximity range and it comes from Config.Match.voice.range.nearby, so the
    -- override sets it and the second argument disables the cycle key -- a
    -- player who found F11 could otherwise quietly put themselves on a range
    -- the gamemode never sanctioned.
    call('overrideProximityRange', BR.Voice.state.nearby + 0.0, true)
end

AddEventHandler('onClientResourceStart', function(res)
    if res == GetCurrentResourceName() then
        if not present() then
            -- LOUD, ONCE. A missing voice resource is now a total voice outage
            -- rather than a degraded one, and the previous outage was invisible
            -- for a week. It must not stop br_core starting, and it does not.
            print('[br_core] VOICE: ' .. VOICE_RES .. ' is NOT running. There '
                .. 'is no voice chat at all -- proximity, squad and the mode '
                .. 'setting all do nothing. See server.cfg.example.')
        end
        install()
    elseif res == VOICE_RES then
        -- pma-voice came up (or came back). Everything we told it is gone.
        BR.Voice.state.joined = nil
        BR.Voice.state.muted = {}
        install()
        BR.Voice.apply()
    end
end)

-- ------------------------------------------------------------- squad radio ---

--- Ask pma-voice for the radio channel this mode implies. Diffed, because
--- setRadioChannel is a round trip to the server and back.
---
--- THE NUMBER IS NEVER OURS. `state.radio` arrives over VOICE_SET and is
--- derived from matchId and squadId, neither of which is public -- so a client
--- cannot work out another squad's channel, and server/voice.lua registers a
--- pma-voice `addChannelCheck` on it so a client that guessed one anyway is
--- refused. All this decides is whether to ask for the one we were given.
local function applyRadio()
    local s = BR.Voice.state
    local want = (BR.Voice.pref.mode == 'squad' and s.radio) and s.radio or 0
    if s.joined == want then return end
    -- Nothing is recorded as done while there is nobody to have done it, so a
    -- pma-voice that starts later is not skipped as already-joined.
    if not present() then return end
    call('setRadioChannel', want + 0)
    s.joined = want
end

--- WHO IS TALKING ON THE SQUAD RADIO.
---
--- Registered on pma-voice's OWN net event, which the server fires at every
--- member of a radio channel. This is the only way to know that an out-of-scope
--- squadmate is speaking: MumbleIsPlayerTalking needs a client player index,
--- and a squadmate two kilometres away does not have one on this machine. That
--- gap is why the indicator used to go blank for exactly the people the radio
--- exists to reach.
local radioTalking = {}
RegisterNetEvent('pma-voice:setTalkingOnRadio')
AddEventHandler('pma-voice:setTalkingOnRadio', function(src, talking)
    src = math.tointeger(tonumber(src))
    if not src then return end
    radioTalking[src] = talking and true or nil
end)

-- ------------------------------------------------------------------- 'off' ---

--- HOLD THE MUTES 'off' ASKS FOR, AND DROP THEM THE INSTANT IT DOES NOT.
---
--- 'off' has always had to mean both halves -- the owner, on the version that
--- only did the first: "'you are not transmitting' should also mean 'you are
--- not listening', but alas both are false." Not transmitting is the proximity
--- check above. Not listening can only be per-player, because under pma-voice
--- the audio is already on its way before this client has any say.
---
--- THIS IS THE ONE THING IN THIS FILE THAT CAN MAKE A PLAYER DEAF, so it is
--- built so that it cannot do so by accident:
---
---   THE MUTE BRANCH IS THE ONLY BRANCH THAT NEEDS A REASON. `mode == 'off'` is
---   re-read every tick; there is no cached "should be muted" anywhere.
---   THE UNMUTE BRANCH NEEDS NONE. Any tick on which the mode is not 'off'
---   unmutes everything we hold, whatever else is true, whatever transition was
---   or was not observed. That is the property #157 round two lacked: its
---   recovery depended on a native behaviour nobody had ever watched.
---   IT IS FREE WHEN THERE IS NOTHING TO DO. A player who has never chosen
---   'off' costs one table lookup per tick and makes no export call at all.
---
--- pma-voice owns the mute itself (client/init/main.lua, mutedPlayers), which
--- is deliberate: it also gates that resource's own radio and call volume
--- restores, so a mute we applied behind its back would be undone by the next
--- person who spoke on the radio.
local function muteSweep()
    local s = BR.Voice.state
    local wantOff = (BR.Voice.pref.mode == 'off')

    -- The common case, and it must stay cheap: not muting, nothing held.
    if not wantOff and next(s.muted) == nil then return end
    if not present() then s.muted = {} return end

    -- pma-voice's own table is the truth. Read once per tick rather than asked
    -- per player, and diffed against it -- so there is no bookkeeping of ours
    -- to drift out of step with the engine, which is the failure this whole
    -- issue keeps having.
    local held = call('getMutedPlayers') or {}

    if wantOff then
        local me = BR.State.me and BR.State.me.src
        for src in pairs(BR.State.roster or {}) do
            if src ~= me and not held[src] then
                call('toggleMutePlayer', src)
                s.muted[src] = true
            end
        end
    else
        for src in pairs(s.muted) do
            if held[src] then call('toggleMutePlayer', src) end
            s.muted[src] = nil
        end
    end
end

-- --------------------------------------------------------------- the apply ---

--- Re-state everything the mode decides. Cheap, idempotent, and safe to call
--- from anywhere -- there is nothing here to tear down and rebuild, which is
--- the difference between this and every apply() this file has had before.
function BR.Voice.apply()
    applyRadio()
    -- The proximity check needs no applying at all: it is a function pma-voice
    -- already holds and already calls, and it will read the new mode on its
    -- next tick without being told. That is the whole bus-rule fix, stated
    -- once more because it is the thing most likely to be "helpfully" replaced
    -- with an explicit re-apply by a later round.
end

RegisterNetEvent(BR.Net.VOICE_SET)
AddEventHandler(BR.Net.VOICE_SET, function(d)
    if type(d) ~= 'table' then return end
    local s = BR.Voice.state

    s.nearby = tonumber(d.nearbyRange) or NEARBY_M
    s.radio  = math.tointeger(tonumber(d.radio))

    -- WHO COUNTS AS A SQUADMATE IS THE SERVER'S ANSWER. An empty list is a
    -- solo, a squad that has not formed, or a player in the lobby -- all of
    -- which mean proximity only. It is presentation and diagnostics now: the
    -- radio's actual membership is pma-voice's, from the channel the server put
    -- everybody on, so these two can only disagree while a push is in flight.
    s.mates = {}
    for _, v in ipairs(type(d.mates) == 'table' and d.mates or {}) do
        local src = math.tointeger(tonumber(v))
        if src then s.mates[#s.mates + 1] = src end
    end

    -- The range can change between matches, so it is re-stated rather than set
    -- once at start.
    call('overrideProximityRange', s.nearby + 0.0, true)
    BR.Voice.apply()
end)

AddEventHandler('br:settings:changed', function(s)
    if type(s) ~= 'table' then return end
    local mode = tostring(s.voiceMode or 'squad')
    if mode ~= 'squad' and mode ~= 'nearby' and mode ~= 'off' then mode = 'squad' end
    if mode == BR.Voice.pref.mode then return end
    BR.Voice.pref.mode = mode
    BR.Voice.apply()
end)

-- ------------------------------------------------------ the talking indicator ---

--- WHO IS TALKING -- AND ONLY PEOPLE WE CAN ACTUALLY HEAR.
---
--- THIS READOUT IS NOW HONEST FOR FREE, which it never was before. It is driven
--- by MumbleIsPlayerTalking, which answers "are frames from this player
--- arriving and being decoded" -- a fact about the network, not the mixer. On
--- the old design every player in the match was in one room, so frames arrived
--- from all of them whether or not one was played, and the indicator faithfully
--- named people the owner could not hear:
---
---   "regardless of distance, 'nearby' doesn't output audio, though it does
---    show who's talking, even when they should be out of range."
---
--- Under pma-voice, frames only arrive if the speaker's own proximity check put
--- us in their voice target. Arrival IS audibility. The two halves that had
--- nothing joining them are now the same fact.
---
--- TWO SOURCES, because there are two ways to reach this machine:
---   PROXIMITY  MumbleIsPlayerTalking over the streamed player list.
---   RADIO      pma-voice's own setTalkingOnRadio event, which is the only
---              thing that can report a squadmate the game has not streamed.
---
--- Sent on CHANGE, never on the tick.
local lastKey = ''
BR.Loop.register(BR.Loop.TICK, 'voice.hear', function()
    local s = BR.Voice.state

    -- WHO WE DO NOT REFUSE. Everybody, unless the player chose 'off'. See the
    -- note on state.audible: under pma-voice this is not a computed set any
    -- more, and claiming otherwise is what a previous round did just before it
    -- muted the roster.
    local audible = {}
    if BR.Voice.pref.mode ~= 'off' then
        local me = BR.State.me and BR.State.me.src
        for src in pairs(BR.State.roster or {}) do
            if src ~= me then audible[src] = true end
        end
    end
    s.audible = audible

    muteSweep()

    local talking = {}
    local seen = {}

    -- DRIVEN BY THE ROSTER, NOT BY WHAT THE GAME HAPPENS TO HAVE STREAMED.
    --
    -- The set being walked is `audible`, which came off BR.State.roster a few
    -- lines up -- a server broadcast carrying every connected player, not a
    -- scope list. That ordering is the whole point and it is the rule
    -- tools/verify.sh's scope gate exists to enforce: the QUESTION is
    -- match-wide, and only the ANSWER for one player is resolved locally.
    -- Walking the streamed player list instead would silently shorten the
    -- question to "who is standing near me", which is wrong for a 48-player map.
    if MumbleIsPlayerTalking then
        for src in pairs(audible) do
            -- scope-ok: presentation only. MumbleIsPlayerTalking needs a local
            -- player index and there is no server-side equivalent -- but a
            -- player with no index is a player pma-voice could not have sent us
            -- proximity audio from either, because its target selection runs off
            -- the same streamed list on THEIR machine. So -1 here means "not
            -- audible by proximity", which is the truth, not a gap. The gap that
            -- would matter -- a squadmate on the radio from across the island,
            -- audible and out of scope -- is closed by radioTalking below, which
            -- is fed by a server broadcast precisely because this cannot see it.
            local ply = GetPlayerFromServerId(src)  -- scope-ok: proximity talking only; radio is handled below
            if ply and ply ~= -1 then
                local okT, isTalking = pcall(MumbleIsPlayerTalking, ply)
                if okT and isTalking then
                    seen[src] = true
                    talking[#talking + 1] = src
                end
            end
        end
    end

    -- THE RADIO, WHICH REACHES PEOPLE THE LOOP ABOVE CANNOT SEE -- and this is
    -- the half that makes the indicator match-wide rather than scope-wide.
    -- pma-voice's server fires setTalkingOnRadio at every member of a radio
    -- channel, so a squadmate two kilometres away is named here even though
    -- this client has no ped, no player index and no Mumble talking flag for
    -- them. Audible on the radio and invisible on the panel was the failure
    -- worth designing against; it is why this is a net event and not a poll.
    for src in pairs(radioTalking) do
        if not audible[src] then
            -- Pruned here rather than on a disconnect event, because there is
            -- no pma-voice event for "that player is gone" and a table keyed on
            -- departed server ids would grow for the life of the session.
            -- Deleting the current key mid-pairs() is defined behaviour.
            radioTalking[src] = nil
        elseif not seen[src] then
            seen[src] = true
            talking[#talking + 1] = src
        end
    end

    table.sort(talking)
    local key = table.concat(talking, ',')
    if key == lastKey then return end
    lastKey = key
    BR.Voice.talking = talking

    -- NAMES TRAVEL WITH THE IDS: proximity voice is heard from anyone in the
    -- match and the bottom-centre indicator has to print strangers too.
    BR.Voice.names = {}
    for i, src in ipairs(talking) do
        local e = (BR.State.roster or {})[src]
        BR.Voice.names[i] = (e and e.name) or ('#' .. tostring(src))
    end

    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE,
        { talking = talking, names = BR.Voice.names })
end)

AddEventHandler('br:ui:ready', function()
    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE,
        { talking = BR.Voice.talking, names = BR.Voice.names })
end)

-- ------------------------------------------------------------------ readout ---

RegisterCommand('brvoice', function()
    local s = BR.Voice.state
    local up = present()

    print('=== voice (client) ===')

    -- THE FIRST LINE IS THE ONE THAT MATTERS NOW, and it is first for that
    -- reason. The previous version of this command named a proximity room that
    -- had been torn down, and read as healthy through a total outage. There is
    -- exactly one question to ask before any other: is the thing that makes
    -- audio actually here.
    print(('  %-13s%s'):format('voice engine',
        up and (VOICE_RES .. ' -- running')
            or (VOICE_RES .. ' IS NOT RUNNING. There is no voice at all. '
                .. 'Nothing below this line does anything.')))

    print(('  %-13s%s'):format('mode', BR.Voice.pref.mode))

    -- TRANSMIT. One line, and it is the truth as the proximity check will
    -- answer it on its next call -- same function, not a description of it.
    local gag, why = BR.Voice.gagged()
    print(('  %-13s%s'):format('transmitting',
        gag and ('NO -- ' .. tostring(why)) or 'yes, to players within range'))
    print(('  %-13s%.0f m (falloff -- pma-voice, speaker-side)'):format(
        'nearby range', s.nearby))

    -- THE BUS RULE, SHOWN AS ITS TWO INPUTS rather than as its answer, because
    -- the two failures it has had were both "the rule was right and the state
    -- was stale". If `in bus seat` says yes after the player has jumped, that
    -- is the bug, and it is visible here without reading any other file.
    print(('  %-13s%s'):format('in bus seat', tostring(onBus())))

    -- RADIO. Assigned and joined are separate claims; see state.radio.
    print(('  %-13s%s'):format('squad radio',
        s.radio and tostring(s.radio) or 'none assigned (solo, or in the lobby)'))
    print(('  %-13s%s'):format('  joined',
        s.joined == nil and 'nothing asked for yet'
            or (s.joined == 0 and 'no -- correct for off and nearby'
                or tostring(s.joined))))
    print(('  %-13s%s'):format('squadmates',
        #s.mates > 0 and table.concat(s.mates, ', ') or 'none (solo)'))

    -- LISTEN.
    local hear = {}
    for src in pairs(s.audible) do hear[#hear + 1] = src end
    table.sort(hear)
    print(('  %-13s%s'):format('not refusing',
        #hear > 0 and table.concat(hear, ', ')
            or 'nobody -- correct for off, and for standing alone'))
    local nmuted = 0
    for _ in pairs(s.muted) do nmuted = nmuted + 1 end
    print(('  %-13s%d player(s)%s'):format('muted', nmuted,
        BR.Voice.pref.mode == 'off' and ' -- off, so all of them'
            or ' -- MUST BE 0 outside off'))
    print(('  %-13s%s'):format('talking',
        #BR.Voice.talking > 0 and table.concat(BR.Voice.talking, ', ')
            or 'nobody'))

    -- AND THE THING A PLAYTESTER MUST KNOW BEFORE DIAGNOSING ANYTHING, because
    -- it inverts where you look. Every previous version of this file gated on
    -- the receive side, so "I cannot hear Bob" was a question about my machine.
    -- It is now a question about BOB'S.
    print('')
    print('  Proximity is enforced by the SPEAKER: you hear somebody because')
    print('  THEY decided you were in range. So if you cannot hear Bob, run')
    print('  /brvoice on BOB\'s machine and read his "transmitting" line --')
    print('  there is nothing on yours that can be refusing him.')
    print('  Squad radio ignores range entirely and is on the radio key.')
end, false)

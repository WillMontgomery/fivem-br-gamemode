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
-- THEY ARE MUTUALLY EXCLUSIVE. NOT LAYERED. The owner has restated this more
-- than once and this file is where it kept being lost:
--
--   "Nearby should only be nearby, different from squads and not additional to
--    it. It means a player could hear anyone nearby within their bucket, and
--    likewise others will hear them nearby. Squads should be set to no
--    distance/fade/etc and only talk/listen within a given squad."
--
-- WHAT THIS FILE USED TO DO, AND IT IS WORTH NAMING BECAUSE THE COMMENT HERE
-- ADVERTISED IT AS CORRECT: 'squad' was "proximity, plus the squad radio".
-- BR.Voice.gagged() returned false on 'squad', so proximityCheck() fell
-- through to its distance comparison and every player within 25 m -- squad or
-- not, enemy or not -- was added to the voice target, with the radio layered
-- on top. A squad player heard the stranger they were fighting.
--
-- NOTHING HERE DECIDES WHAT A MODE MEANS ANY MORE. BR.VoiceRouting
-- (br_lib/shared/enums.lua) does, in two booleans per mode that are never both
-- true, and everything below is derived from those two columns. See the block
-- there for why it lives in br_lib and what stops it drifting.
--
--   off      transmit to nobody, and hear nobody.
--            TRANSMIT: our proximity check (below) returns false for every
--            player, so pma-voice adds no channel to the voice target. The
--            radio is dropped by leaving the channel.
--            LISTEN: pma-voice's own per-player mute, reconciled every tick.
--            See muteSweep().
--
--   nearby   PROXIMITY ONLY, with falloff, out to Config.Match.voice.range
--            .nearby, and scoped to this player's routing bucket because
--            pma-voice only ever offers us players the game streamed. No radio
--            channel, and NO SPECIAL CASE FOR SQUADMATES: a squadmate across
--            the island is exactly as inaudible as any other stranger, and a
--            squadmate standing next to you is exactly as audible. This is the
--            capability the hand-rolled version gave up in #157 round three.
--
--   squad    THE SQUAD RADIO ONLY -- a pma-voice radio channel the SERVER
--            assigns, audible at any distance, no falloff, no fade.
--            TRANSMIT: proximity is off entirely, so the only thing carrying
--            our audio is the radio, and the only people on it are the squad.
--            LISTEN: everybody who is not a squadmate is muted, by the same
--            per-player mute 'off' uses -- because under pma-voice audibility
--            is the SPEAKER's decision, so declining to transmit does not on
--            its own stop a nearby stranger's audio arriving. Refusing it is
--            the second half of "only talk/listen within a given squad" and
--            without it 'squad' would still hear proximity.
--
--            A PLAYER WITH NO SQUAD THEREFORE HEARS NOBODY. That is the spec
--            read honestly -- an empty squad is an empty conversation -- and
--            it is why the DEFAULT is 'nearby' rather than this. It is now
--            said on the HUD and on the settings screen as well as in
--            /brvoice: silence with no explanation is indistinguishable from
--            a broken feature, which is exactly how it was reported.
--
--            AND THE RADIO IS A SEPARATE PUSH-TO-TALK. THIS IS THE ONE THAT
--            COST #157 ITS SEVENTH ROUND, and it is not our code at all:
--
--                RegisterCommand('+radiotalk', ...)
--                RegisterKeyMapping('+radiotalk', 'Talk over Radio',
--                    'keyboard', GetConvar('voice_defaultRadio', 'LMENU'))
--                                    -- pma-voice client/module/radio.lua
--
--            pma-voice's radio adds its voice targets when +radiotalk goes
--            DOWN and calls MumbleClearVoiceTargetPlayers when it comes up.
--            Nothing else ever puts a squadmate in the target. So the game's
--            ordinary voice key carries PROXIMITY and only proximity -- and
--            in squad mode proximity is off, so the ordinary key carries
--            NOTHING. A squad that presses it hears silence in both
--            directions and reports that squad voice does not work.
--
--            WE DO NOT DRIVE THAT KEY FROM HERE. Synthesising +radiotalk off
--            a talking probe is exactly the class of untestable cleverness
--            that produced six rounds of this issue, and pma-voice's own
--            keybind is a thing the player can see and rebind. What was
--            missing was that anybody had ever TOLD them, so that is what
--            this file now does -- see BR.Voice.statusFor and radioKeyLabel.
--
-- THE MUTE IS THE ONLY THING IN THIS FILE THAT CAN MAKE A PLAYER DEAF, and it
-- is now reached by two modes rather than one, so muteSweep()'s rule matters
-- more than it did: the mute branch needs a reason, the unmute branch needs
-- none, and both are re-derived from the CURRENT mode every tick.
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
--
-- #185, AND WHY EVERY MEASUREMENT BEFORE 2026-08-18 IS WORTHLESS.
--
-- A SECOND VOICE IMPLEMENTATION WAS RUNNING THE WHOLE TIME. vMenu ships its
-- own voice chat, it is ON BY DEFAULT, and nobody on this project had ever
-- enumerated what else on the box touches voice -- the audit that proved OUR
-- resources were clean was run over br_* only, so it answered "are we doing
-- this" and never "who is doing this".
--
-- IT WAS vMenu THAT PRODUCED THE SYMPTOMS THIS FILE SPENT THREE ROUNDS ON:
-- the "currently talking" overlay we could not find a setting for, channel
-- behaviour nobody could account for, and the
--
--     MUMBLE_ADD_VOICE_CHANNEL_LISTEN: Tried to call native on a channel that
--     didn't exist
--
-- spam that #165 was opened for. With vMenu's voice turned off the console is
-- clean, and pma-voice v7.0.2-rc3's own channel-listen sites all resolve the
-- channel first (client/init/proximity.lua, addChannelListener) so none of
-- them can raise it.
--
-- WHAT WENT WITH IT. The pma-voice VERSION DETECTOR that used to live in this
-- file -- BR.Voice.generation, generationOf, legacyLines, the state-bag probe
-- on the slow band and the #165 essay in /brvoice -- existed for exactly one
-- purpose: to blame that warning on a pre-v7.0.1-rc2 pma-voice. The warning
-- was never pma-voice's, so the detector is gone. server.cfg.example still
-- pins the version, which is the right place for a version to be pinned.
--
-- WHAT DID NOT GO WITH IT, and the distinction is the point: the two convars
-- below. Neither is a workaround for vMenu. voice_disableAutomaticListener-
-- OnCamera guards against pma-voice's OWN setSpectatorMode, which is still
-- there in v7.0.1/v7.0.2 (proximity.lua: `GetRenderingCam()` feeds
-- `isSpectating`, and this gamemode renders a scripted camera in the lobby,
-- on the bus and while downed); voice_enableUi turns off pma-voice's OWN
-- bottom-right overlay, which is a real `v-if="voice.uiEnabled"` in its
-- voice-ui/src/App.vue and which we duplicate. Both are read out of the
-- running client by BR.Voice.convarProblems rather than assumed.
--
-- ONE CLAIM THIS FILE USED TO MAKE AND MUST NOT MAKE AGAIN: that the overlay
-- disappearing PROVED a replicated convar had reached the client before
-- pma-voice's scripts ran. The overlay that disappeared was vMenu's. The
-- convars may well arrive in time -- the camera one is re-read inside
-- pma-voice's own loop every 200 ms, which is a structural argument and still
-- stands -- but nothing here has EMPIRICALLY established it, and pretending
-- otherwise is how this file got to round six.
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

    -- WHO WE DO NOT REFUSE. Under pma-voice this is not "who can I hear" --
    -- audibility is decided by the SPEAKER, on their machine, and no native
    -- reports it. It is the set this client declines to mute, and it is what
    -- the mode's LISTEN half is made of: everybody on 'nearby', squadmates
    -- only on 'squad', nobody on 'off'. See BR.Voice.audibleFor.
    --
    -- The talking indicator is filtered through the same table, in the same
    -- tick, which keeps the property that a name on that line is somebody this
    -- client is genuinely accepting audio from.
    audible = {},       -- [src] = true

    -- Players we currently hold a pma-voice mute on. Non-empty on 'off' (all of
    -- them) and on 'squad' (everybody who is not a squadmate). Always empty on
    -- 'nearby', which refuses nobody. See muteSweep().
    muted  = {},        -- [src] = true
}

--- The player's own preference, from the settings screen.
---
--- NOT AUTHORITY. It can only decline what the server granted: the squad radio
--- CHANNEL NUMBER is the server's (see server/voice.lua, and the pma-voice
--- addChannelCheck it registers), and this only decides whether we ask to be
--- on it.
---
--- THE DEFAULT IS READ, NOT RESTATED. This line used to say 'squad' while
--- br_ui/client/settings.lua said 'nearby', and the only reason the player got
--- 'nearby' was that br_ui happens to push on br:ui:ready and overwrite this.
--- Restart br_core on its own, or lose that push to a race, and the two
--- disagreed with nothing to say which had won. There is one definition now
--- and it is in br_lib/shared/enums.lua.
BR.Voice.pref = { mode = BR.VoiceModeDefault }

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

--- The routing row for the mode this player has chosen. Never nil.
---
--- EVERY DECISION IN THIS FILE COMES THROUGH HERE. Nothing below compares
--- BR.Voice.pref.mode against a string literal, which is the property that
--- makes the modes stay exclusive: there is no second place to teach 'squad'
--- about proximity.
--- @return table  { proximity = boolean, radio = boolean }
function BR.Voice.routing()
    return BR.VoiceRoutingFor(BR.Voice.pref.mode)
end

--- Is our proximity microphone gagged, and why?
---
--- ONE FUNCTION, TWO CALLERS, AND THAT IS THE POINT. The proximity check uses
--- it to decide, and /brvoice uses it to REPORT -- so the readout cannot drift
--- from the behaviour the way "prox channel 2003" did for a week while no audio
--- was leaving the machine.
---
--- IT ANSWERS ABOUT THE PROXIMITY MICROPHONE AND NOTHING ELSE. 'squad' is
--- gagged here and that is not a malfunction -- squad routes through the radio,
--- which this function has no opinion about. /brvoice prints the two
--- separately for exactly that reason; do not read a `true` here as "this
--- player is silent".
--- @return boolean gagged
--- @return string|nil reason  human-readable, for /brvoice
function BR.Voice.gagged()
    local r = BR.Voice.routing()

    -- MODES THAT DO NOT ROUTE PROXIMITY AT ALL. Derived from the routing table
    -- rather than from a list of mode names, so a mode added there is handled
    -- here without anybody remembering to come back.
    if not r.proximity then
        if r.radio then
            return true, 'squad mode -- proximity is off; the squad radio '
                .. 'carries instead, at any distance'
        end
        return true, "the player chose 'off'"
    end

    -- THE BUS RULE. Proximity modes only: a squad on the bus keeps its radio,
    -- which is the whole point of having one on the way to the drop.
    if onBus() then
        return true, 'riding the bus on nearby -- switch to squad, or jump'
    end
    return false, nil
end

--- WHO WE DO NOT REFUSE -- the listen half, and the other half of exclusivity.
---
--- WHY THIS EXISTS AT ALL. Under pma-voice, audibility is decided by the
--- SPEAKER: their proximity check put us in their voice target and the frames
--- are on their way before this machine has any say. So declining to transmit
--- does NOT make a mode exclusive on its own -- a 'squad' player who only
--- refused to send would still hear every 'nearby' stranger who walked past
--- them. "Only talk/listen within a given squad" needs both halves and this is
--- the second one.
---
--- IT IS PURE, AND IT TAKES ITS INPUTS RATHER THAN READING THEM, so the suite
--- can drive it through every combination without a game and without the
--- stub agreeing with the code by construction.
---
---   proximity  everybody. NOT "everybody within 25 m" -- we deliberately do
---              not re-implement the range on the receive side. Arrival IS
---              audibility under pma-voice, and a receive-side distance gate is
---              precisely what shipped a silent 'nearby' four times (#157).
---   radio      squadmates only, from the SERVER's list. Everybody else is
---              muted, which is what makes squad mode deaf to proximity.
---   neither    nobody. 'off'.
---
--- @param mode string|nil
--- @param roster table|nil  [src] = entry; the server broadcast, match-wide
--- @param mates table|nil   array of squadmate server ids, from VOICE_SET
--- @param me integer|nil    this player's own server id, never in the result
--- @return table  [src] = true
function BR.Voice.audibleFor(mode, roster, mates, me)
    local r = BR.VoiceRoutingFor(mode)
    local out = {}
    if r.proximity then
        for src in pairs(roster or {}) do
            if src ~= me then out[src] = true end
        end
    elseif r.radio then
        -- THE SQUAD LIST IS THE SERVER'S, and it is the same list the server
        -- built the radio channel's membership from -- so "who I will listen
        -- to" and "who is actually on my radio" have one origin and cannot
        -- drift into a squadmate being muted while talking.
        for _, src in ipairs(mates or {}) do
            -- Still filtered through the roster: a mate who has disconnected
            -- is not somebody to hold an exception open for, and a src that is
            -- somehow ours must never be in here.
            if src ~= me and (roster == nil or roster[src] ~= nil) then
                out[src] = true
            end
        end
    end
    return out
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

-- ------------------------------------------------- the two convars ---
--
-- TWO pma-voice CONVARS THIS GAMEMODE CANNOT RUN WITHOUT, AND THE REASON THEY
-- ARE CHECKED FROM CODE RATHER THAN WRITTEN DOWN.
--
-- Both of them were "fixed" last round by adding a line to server.cfg.example.
-- server.cfg.example is not a config file. tools/deploy.sh rsyncs
-- resources/[fivem-royale]/ and nothing else, and .gitignore line 33 keeps the
-- real server.cfg off this repository entirely -- so a convar added to the
-- example reaches the box only when a human retypes it. That did not happen,
-- and the two symptoms in #165 are exactly what their absence looks like.
--
-- br_core/server/voice.lua now SETS both (SetConvarReplicated) when the
-- operator has not, so a fresh box is correct without anyone editing anything.
-- This half is the receipt: the client reads what actually arrived and says so,
-- because "the server set it" and "this client has it" are different claims and
-- #150 was a week of confusing exactly that kind of pair.
--
-- ==========================================================================
-- DO THEY ARRIVE? ONE HALF OF THIS IS SETTLED AND THE OTHER HALF IS NOT, AND
-- THE DIFFERENCE IS WORTH KEEPING STRAIGHT -- the version of this comment that
-- did not keep it straight cited a vMenu symptom as proof (#185).
--
--   STRUCTURALLY, FOR THE CAMERA ONE, AND THIS STILL STANDS: pma-voice re-reads
--   it INSIDE its loop body, every 200 ms (client/init/proximity.lua, the
--   `local cam = ...` line). There is no start-time read to lose a race
--   against. A convar that lands late takes effect on the next tick, and one
--   that lands early is simply already there. Start order cannot break it.
--
--   FOR voice_enableUi, NOTHING IS ESTABLISHED. It IS read once, at pma-voice's
--   own onClientResourceStart (client/init/init.lua), so a replicated value
--   that arrives after that is a value pma-voice never sees. This comment used
--   to argue that the value must have arrived in time because "the overlay is
--   gone" -- and the overlay that went was vMenu's, turned off by hand on
--   2026-08-18. That is not evidence of anything about our convar. What we
--   have instead is convarProblems(), which READS the value out of the running
--   client and prints it in /brvoice; that is a measurement rather than an
--   argument, and it is the thing to look at.
--
-- AND WITH THE CAMERA ONE IN FORCE, pma-voice's spectator listening is not
-- merely off, it is UNREACHABLE HERE. `cam` is pinned to -1, so
-- `isSpectating` collapses to NetworkIsInSpectatorMode() -- and the only
-- caller of NetworkSetInSpectatorMode in this gamemode is BR.Native.spectate,
-- behind BR.Native.use.spectatorNative, which is false (client/natives.lua).
-- The other way in is pma-voice's setListenerOverride export, which br_core
-- never calls. isListenerEnabled therefore cannot become true, setSpectatorMode
-- cannot run, and the two listen sites inside it cannot fire.
--
-- THAT IS WORTH HAVING ON ITS OWN MERITS and it is not a workaround for
-- anybody: the listens setSpectatorMode takes are unlimited-range and are
-- added over one routing bucket's player list and removed over another's, so
-- what is left behind is a hole through the match isolation server/voice.lua
-- spends forty lines arguing for. The convar closes it whether or not anything
-- was ever printing a warning about it.
-- ==========================================================================
--
--   voice_disableAutomaticListenerOnCamera 1
--     pma-voice's proximity loop (client/init/proximity.lua) computes
--         local cam = GetConvarInt("voice_disableAutomaticListenerOnCamera", 0)
--                       ~= 1 and GetRenderingCam() or -1
--         local isSpectating = NetworkIsInSpectatorMode() or cam ~= -1
--     -- ANY RENDERING SCRIPTED CAMERA puts this client into pma-voice's
--     SPECTATOR LISTENING mode, which walks the whole streamed player list
--     calling MumbleAddVoiceChannelListen on each of their channels. This
--     gamemode renders a scripted camera in the lobby (client/lobbycam.lua),
--     ON THE BUS (client/bus.lua, RenderScriptCams at the end of boarding) and
--     while downed (client/dbno.lua). So the bus silently turns every rider
--     into a spectator of everybody in scope: unlimited-range listening, and --
--     because the listens are added over the WARMUP bucket's player list and
--     removed over the MATCH bucket's one flight later -- a residue on players
--     this client can no longer see and will never remove. That residue is a
--     hole straight through the match isolation server/voice.lua argues for.
--
--   voice_enableUi 0
--     pma-voice's own bottom-right overlay: the "Custom [Range]" readout the
--     owner is looking at, plus "[Call]" and "N Mhz [Radio]". All three sit
--     inside one `v-if="voice.uiEnabled"` (its voice-ui/src/App.vue), fed by a
--     single message sent from client/init/init.lua at pma-voice's start. It
--     defaults to ON, and the gamemode draws its own indicator.
local CONVARS = {
    { name    = 'voice_disableAutomaticListenerOnCamera',
      want    = 1,
      default = 0,   -- pma-voice's own default, so an unset convar reads as it
      why     = 'the bus/lobby/downed cameras put this client into pma-voice '
             .. 'spectator listening -- unlimited range, and it leaks across '
             .. 'the drop' },
    { name    = 'voice_enableUi',
      want    = 0,
      default = 1,
      why     = 'pma-voice draws its own bottom-right overlay on top of ours' },
    -- THE RADIO'S COSTUME, NOT THE RADIO. +radiotalk plays
    -- 'random@arrests'/'generic_radio_enter' on the talker's ped for as long as
    -- the key is held: it re-poses somebody who is aiming a rifle, and it tells
    -- every enemy who can see them that they are on comms. The KEY itself and
    -- voice_enableRadios are deliberately left alone -- that key is the only
    -- thing that ever puts a squadmate in the voice target, so turning it off
    -- is turning squad voice off. See the mode block at the top of this file.
    { name    = 'voice_enableRadioAnim',
      want    = 0,
      default = 1,
      why     = 'pma-voice re-poses your ped into a hold-a-radio animation '
             .. 'while you talk to your squad, through aiming and in plain '
             .. 'sight of anyone watching' },
}

--- WHICH OF THEM ARE WRONG ON THIS CLIENT, RIGHT NOW.
---
--- One function, two callers, for the same reason BR.Voice.gagged() is: the
--- start-up warning and /brvoice must not be able to disagree about it.
--- @return table array of { name, have, want, why }
function BR.Voice.convarProblems()
    local out = {}
    if not GetConvarInt then return out end   -- a harness, not a game
    for _, c in ipairs(CONVARS) do
        local have = GetConvarInt(c.name, c.default)
        if have ~= c.want then
            out[#out + 1] = { name = c.name, have = have,
                              want = c.want, why = c.why }
        end
    end
    return out
end

-- ------------------------------------------------ WHY YOU CANNOT HEAR ANYONE ---
--
-- THE FEATURE THIS FILE WAS MISSING, AND IT IS NOT A ROUTING FEATURE.
--
-- The playtest that produced #157 round seven reported "squads don't work".
-- The squad radio was assigned, the number was right, every member of one
-- squad had the same one and the server's guard let them all on. What nobody
-- had ever been told is that pma-voice's radio has its OWN push-to-talk --
-- +radiotalk, 'Talk over Radio', default LMENU -- and that in squad mode the
-- ordinary voice key carries nothing at all, because squad mode turns
-- proximity off. Two people pressed the key the game had taught them, heard
-- silence, and correctly concluded the feature was broken.
--
-- SO SILENCE NOW EXPLAINS ITSELF. This section is one pure function and one
-- reader for it, and every surface that can tell the player -- the HUD line,
-- the settings screen, the toast on the edge, and /brvoice -- is derived from
-- the same call. That is the same rule BR.Voice.gagged() is built on: a
-- readout that derives its own answer is a readout that can disagree with the
-- behaviour, and this issue is four rounds of exactly that.

--- The KEY a player has to hold to be heard on the squad radio.
---
--- READ OFF pma-voice's OWN CONVAR, which is the value it passed to
--- RegisterKeyMapping. That makes this the DEFAULT binding and not necessarily
--- the live one -- FiveM stores a rebind in the player's own profile and
--- exposes no way to read it back -- so every string built from this says
--- "default" and points at the settings screen where the truth is. Naming a
--- key the player has rebound would be worse than naming none.
local KEY_NAMES = {
    LMENU = 'Left Alt', RMENU = 'Right Alt',
    LCONTROL = 'Left Ctrl', RCONTROL = 'Right Ctrl',
    LSHIFT = 'Left Shift', RSHIFT = 'Right Shift',
    CAPITAL = 'Caps Lock', GRAVE = '`', SPACE = 'Space',
    RETURN = 'Enter', TAB = 'Tab', BACK = 'Backspace',
}

--- @return string  a human-readable key name, never empty
function BR.Voice.radioKeyLabel()
    local raw = GetConvar and GetConvar('voice_defaultRadio', 'LMENU') or 'LMENU'
    if raw == nil or raw == '' then raw = 'LMENU' end
    return KEY_NAMES[raw] or raw
end

--- WHAT THIS MODE IS ACTUALLY DOING, IN WORDS A PLAYER CAN ACT ON.
---
--- PURE, AND IT TAKES ITS INPUTS, for the same reason BR.Voice.audibleFor does:
--- the suite drives it through every combination without a game, and a version
--- that read the globals would agree with the code by construction.
---
--- `silent` is the load-bearing field and it means something narrow: NOTHING
--- CAN REACH THIS PLAYER AND NOTHING THEY SAY CAN LEAVE. It is true for 'off'
--- (which they asked for) and for squad-with-no-squad (which they did not, and
--- which is the state that got reported as a bug). It is NOT true for a squad
--- of two who have simply not found the radio key -- that one is a `hint`,
--- because audio can flow the moment they hold it.
--- @param mode string|nil
--- @param radio integer|nil  the channel the server granted, or nil
--- @param mates integer|nil  how many squadmates the server named
--- @return table  { code, silent, chosen, headline, detail }
function BR.Voice.statusFor(mode, radio, mates)
    local r = BR.VoiceRoutingFor(mode)
    mates = mates or 0

    if r.proximity then
        return { code = 'nearby', silent = false, chosen = false }
    end

    if not r.radio then
        -- The player asked for this one. Said, but never as an alarm.
        return {
            code = 'silenced', silent = true, chosen = true,
            headline = 'Voice is off',
            detail = 'You are not transmitting and not listening. Change it '
                  .. 'under Settings, Voice.',
        }
    end

    if not radio then
        -- THE STATE THIS WHOLE CHANGE EXISTS FOR. Squad mode, no squad: the
        -- server had no channel to grant, so there is no conversation to be in.
        return {
            code = 'nosquad', silent = true, chosen = false,
            headline = 'Squad voice: you have no squad',
            detail = 'Squad voice carries your squad and nobody else, so with '
                  .. 'no squad it carries nobody -- you cannot hear anyone and '
                  .. 'nobody can hear you. Solo matches have no squads. Switch '
                  .. 'to Nearby under Settings, Voice to hear the players '
                  .. 'around you.',
        }
    end

    local key = BR.Voice.radioKeyLabel()

    if mates <= 0 then
        return {
            code = 'alone', silent = false, chosen = false,
            headline = 'Squad voice: nobody else on your squad radio yet',
            detail = ('You are on squad radio %d and you are the only one on '
                  .. 'it. Hold %s (Talk over Radio) to speak once a squadmate '
                  .. 'joins -- the ordinary voice key carries nothing in this '
                  .. 'mode.'):format(radio, key),
        }
    end

    return {
        code = 'radio', silent = false, chosen = false,
        headline = ('Squad voice: hold %s to talk'):format(key),
        detail = ('Squad voice is a RADIO with its own push-to-talk. Hold %s '
              .. '-- "Talk over Radio", rebindable in the pause menu under '
              .. 'Settings, Key Bindings, FiveM. The ordinary voice key does '
              .. 'nothing in this mode, because squad mode turns proximity '
              .. 'off.'):format(key),
    }
end

--- The same verdict, taken off the live state. One caller per surface.
--- @return table  see statusFor
function BR.Voice.status()
    local s = BR.Voice.state
    return BR.Voice.statusFor(BR.Voice.pref.mode, s.radio, #s.mates)
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
        for _, p in ipairs(BR.Voice.convarProblems()) do
            print(('[br_core] VOICE: %s is %d on this client, must be %d -- %s')
                :format(p.name, p.have, p.want, p.why))
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
    -- DERIVED FROM THE ROUTING TABLE, not from a mode name. This line used to
    -- read `BR.Voice.pref.mode == 'squad'`, which is the second place a mode
    -- meant something -- and the first place, the proximity check, disagreed
    -- with it about whether 'squad' also meant proximity.
    local want = (BR.Voice.routing().radio and s.radio) and s.radio or 0
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

-- ------------------------------------------------------- refusing to listen ---

--- HOLD THE MUTES THIS MODE ASKS FOR, AND DROP THE ONES IT DOES NOT.
---
--- 'off' has always had to mean both halves -- the owner, on the version that
--- only did the first: "'you are not transmitting' should also mean 'you are
--- not listening', but alas both are false." Not transmitting is the proximity
--- check above. Not listening can only be per-player, because under pma-voice
--- the audio is already on its way before this client has any say.
---
--- 'squad' NOW REACHES THIS TOO, AND THAT IS THE CHANGE. "Only talk/listen
--- within a given squad" is two halves in exactly the way 'off' was: proximity
--- is off, so we send to nobody but the radio -- and every non-squadmate is
--- muted, so the nearby stranger's audio, which THEY decided to send us and we
--- have no say over, does not arrive either. Declining to transmit was never
--- enough to make a mode exclusive; this is the half that makes it true.
---
--- THIS IS THE ONE THING IN THIS FILE THAT CAN MAKE A PLAYER DEAF, so it is
--- built so it cannot do so by accident -- and the rule matters MORE now that
--- a second mode reaches it:
---
---   THE MUTE BRANCH IS THE ONLY BRANCH THAT NEEDS A REASON. The audible set is
---   recomputed from the CURRENT mode, roster and squad list on every tick by
---   BR.Voice.audibleFor(); there is no cached "should be muted" anywhere.
---   THE UNMUTE BRANCH NEEDS NONE. Anybody we hold a mute on who is audible on
---   this tick is released on this tick, whatever else is true and whatever
---   transition was or was not observed. That is the property #157 round two
---   lacked: its recovery depended on a native behaviour nobody had watched.
---   IT IS STILL FREE WHEN THERE IS NOTHING TO DO. 'nearby' refuses nobody, so
---   the first loop finds no work, nothing is held, and no export is called.
---
--- IT IS HANDED THE SET RATHER THAN DERIVING ITS OWN. The tick above already
--- computed `audible` for the talking indicator, and the two must agree: an
--- indicator naming somebody this function is refusing audio from is exactly
--- the lie that diagnosed #157, and two independent derivations is how you get
--- one.
---
--- pma-voice owns the mute itself (client/init/main.lua, mutedPlayers), which
--- is deliberate: it also gates that resource's own radio and call volume
--- restores, so a mute we applied behind its back would be undone by the next
--- person who spoke on the radio.
--- @param audible table  [src] = true, from BR.Voice.audibleFor
local function muteSweep(audible)
    local s = BR.Voice.state
    local roster = BR.State.roster or {}
    local me = BR.State.me and BR.State.me.src

    -- The common case, and it must stay cheap: this mode refuses nobody on the
    -- current roster, and we are holding nothing.
    local refuses = false
    for src in pairs(roster) do
        if src ~= me and not audible[src] then refuses = true break end
    end
    if not refuses and next(s.muted) == nil then return end
    if not present() then s.muted = {} return end

    -- pma-voice's own table is the truth. Read once per tick rather than asked
    -- per player, and diffed against it -- so there is no bookkeeping of ours
    -- to drift out of step with the engine, which is the failure this whole
    -- issue keeps having.
    local held = call('getMutedPlayers') or {}

    -- MUTE everybody on the roster this mode will not listen to.
    for src in pairs(roster) do
        if src ~= me and not audible[src] then
            if not held[src] then call('toggleMutePlayer', src) end
            s.muted[src] = true
        end
    end

    -- RELEASE everything we hold that this mode WOULD listen to now, and
    -- anybody who has left: a departed player is not somebody to keep a mute
    -- open on, and a table keyed on gone server ids would grow for the life of
    -- the session. Deleting the current key mid-pairs() is defined behaviour.
    for src in pairs(s.muted) do
        if audible[src] or roster[src] == nil then
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
    -- solo, a squad that has not formed, or a player in the lobby.
    --
    -- IT IS LOAD-BEARING NOW RATHER THAN DIAGNOSTIC. It used to be presentation
    -- only -- the radio's membership is pma-voice's, from the channel the
    -- server put everybody on -- but 'squad' also has to REFUSE everybody who
    -- is not on it, and this list is what that refusal is built from
    -- (BR.Voice.audibleFor -> muteSweep). Both halves therefore come from the
    -- same server answer, which is what stops "on my radio" and "not muted by
    -- me" from disagreeing; they can differ only while a push is in flight.
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
    -- COERCED IN br_lib, NOT HERE. These four lines used to spell out the valid
    -- set and the fallback by hand, and the fallback was 'squad' -- so an old
    -- KVP blob, a hand-fired event or a typo'd payload put this client on a
    -- mode the settings screen would never have stored and never displayed.
    -- One definition, in BR.ToVoiceMode.
    local mode = BR.ToVoiceMode(s.voiceMode)
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
--- ONE ENVELOPE CARRIES BOTH HALVES OF THE VOICE HUD.
---
--- `talking`/`names` are the bottom-centre indicator and have been on this
--- channel since it existed. The rest is the STATUS -- what this mode is doing
--- and, when the answer is "nothing", why. It rides the same envelope rather
--- than a new one because the page needs them together: a "Currently Talking"
--- line that never lists anybody and a screen that never says why are the two
--- halves of the report this round came from.
---
--- THE TOAST IS EDGE-TRIGGERED AND LIVES HERE, next to the thing it is about,
--- so there is one place that decides what the player is told. It fires when
--- the VERDICT changes -- squad formed, mode picked, squad dissolved -- and
--- never on a tick, because this function is called from the 10 Hz band.
--- @param talking table
--- @param names table
--- @param st table  from BR.Voice.status
local lastToast = nil
local function pushVoice(talking, names, st)
    TriggerEvent('br:ui:sendLocal', BR.Nui.VOICE, {
        talking  = talking or {},
        names    = names or {},
        -- The mode is sent so the settings screen can describe the mode the
        -- player is ACTUALLY on rather than the one it last drew a button for.
        mode     = BR.Voice.pref.mode,
        radio    = BR.Voice.state.radio,
        joined   = BR.Voice.state.joined,
        mates    = #BR.Voice.state.mates,
        status   = st.code,
        silent   = st.silent and true or false,
        chosen   = st.chosen and true or false,
        headline = st.headline,
        detail   = st.detail,
    })

    if st.code ~= lastToast then
        lastToast = st.code
        -- 'off' is the player's own choice and they made it two seconds ago;
        -- toasting it back at them is noise. Everything else is news.
        if st.headline and not st.chosen then
            TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
                text = st.headline,
                tone = st.silent and 'danger' or 'info',
            })
        end
    end
end

--- Sent on CHANGE, never on the tick.
local lastKey = ''
BR.Loop.register(BR.Loop.TICK, 'voice.hear', function()
    local s = BR.Voice.state

    -- WHO WE DO NOT REFUSE, from the one function that decides it. On 'nearby'
    -- that is everybody -- proximity is the SPEAKER's decision and we do not
    -- second-guess it, which is the rule that keeps a receive-side distance
    -- gate out of this file. On 'squad' it is the squadmates the server named,
    -- and on 'off' it is nobody.
    local audible = BR.Voice.audibleFor(BR.Voice.pref.mode, BR.State.roster,
                                        BR.Voice.state.mates,
                                        BR.State.me and BR.State.me.src)
    s.audible = audible

    -- ONE SET, BOTH CONSUMERS, IN THAT ORDER. The mutes are applied from the
    -- same table the indicator is about to be built from, so "named as talking"
    -- and "not muted" cannot disagree.
    muteSweep(audible)

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

    -- TWO FACTS ON ONE CHANNEL, AND BOTH OF THEM CHANGE ON THEIR OWN CLOCK.
    --
    -- Who is talking changes several times a second; whether this mode can
    -- carry audio at all changes when the player picks a mode or their squad
    -- forms, which may be once a match. The dedup key therefore covers BOTH --
    -- keying it on the talking list alone is how the status line would have
    -- sat stale on the HUD for as long as nobody spoke, which is precisely the
    -- moment it is worth reading.
    local st  = BR.Voice.status()
    local key = table.concat(talking, ',') .. '|' .. tostring(st.headline)
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

    pushVoice(talking, BR.Voice.names, st)
end)

AddEventHandler('br:ui:ready', function()
    pushVoice(BR.Voice.talking, BR.Voice.names, BR.Voice.status())
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
    print(('  %-14s%s'):format('voice engine',
        up and (VOICE_RES .. ' -- running')
            or (VOICE_RES .. ' IS NOT RUNNING. There is no voice at all. '
                .. 'Nothing below this line does anything.')))

    -- THE SECOND LINE IS THE VERDICT: is this player in a conversation at all,
    -- and if not, why not. It is second because it is the question the player
    -- actually has, and because every previous version of this readout made
    -- them derive it from six lines further down.
    do
        local st = BR.Voice.status()
        print(('  %-14s%s'):format('verdict',
            st.silent and ('SILENT -- ' .. tostring(st.headline))
                or (st.headline or 'carrying')))
        if st.detail then print('                ' .. st.detail) end
    end

    -- THE CONVARS, THIRD. A running pma-voice with these two unset is a running
    -- pma-voice that draws its own overlay and turns every bus rider into a
    -- spectator of the whole plane -- and neither of those shows up anywhere
    -- else on this readout. Silence here means both are correct.
    local probs = BR.Voice.convarProblems()
    if #probs > 0 then
        print(('  %-14s%d WRONG on this client:'):format('convars', #probs))
        for _, p in ipairs(probs) do
            print(('    %s is %d, must be %d'):format(p.name, p.have, p.want))
            print(('      %s'):format(p.why))
        end
        print('    br_core/server/voice.lua sets these when the operator has')
        print('    not. Seeing them here means the server was overridden, or')
        print('    this client joined before that ran -- rejoin and re-check.')
    end

    -- THE MODE, AND THEN WHAT IT ROUTES -- as TWO independent lines, because
    -- "which mode am I on" and "which of the two channels is carrying" is
    -- exactly the pair this issue keeps merging. The two flags are read out of
    -- the routing table, so this cannot describe a mode the code does not
    -- implement the way the old "squad = proximity plus radio" comment did.
    local r = BR.Voice.routing()
    print(('  %-14s%s'):format('mode', BR.Voice.pref.mode))
    print(('  %-14sproximity %s, squad radio %s -- NEVER BOTH'):format('routes',
        r.proximity and 'ON' or 'off', r.radio and 'ON' or 'off'))

    -- TRANSMIT. One line, and it is the truth as the proximity check will
    -- answer it on its next call -- same function, not a description of it.
    local gag, why = BR.Voice.gagged()
    print(('  %-14s%s'):format('prox mic',
        gag and ('NO -- ' .. tostring(why)) or 'yes, to players within range'))
    print(('  %-14s%.0f m (falloff -- pma-voice, speaker-side)%s'):format(
        'nearby range', s.nearby,
        r.proximity and '' or ' -- NOT IN USE on this mode'))

    -- THE BUS RULE, SHOWN AS ITS TWO INPUTS rather than as its answer, because
    -- the two failures it has had were both "the rule was right and the state
    -- was stale". If `in bus seat` says yes after the player has jumped, that
    -- is the bug, and it is visible here without reading any other file.
    print(('  %-14s%s'):format('in bus seat', tostring(onBus())))

    -- RADIO, AS THREE SEPARATE CLAIMS, EACH ANSWERED YES OR NO.
    --
    -- "the server gave me a channel", "I asked pma-voice for it" and "those are
    -- the same number" are three different facts, and #150 was a week of a
    -- readout that merged them. They are printed as an explicit verdict rather
    -- than as two numbers the reader has to compare, because the reader is a
    -- playtester mid-match and the comparison is the whole point of the line.
    print(('  %-14s%s'):format('radio granted',
        s.radio and ('YES -- channel ' .. tostring(s.radio))
            or 'NO -- the server assigned no squad radio (solo match, no '
               .. 'squad, or in the lobby)'))
    print(('  %-14s%s'):format('radio joined',
        s.joined == nil and 'NOT YET -- nothing has been asked of pma-voice'
            or (s.joined == 0
                and 'NO -- channel 0, which is correct for nearby and off'
                or ('YES -- channel ' .. tostring(s.joined)))))
    if r.radio then
        local want = s.radio or 0
        print(('  %-14s%s'):format('  agree',
            s.joined == want
                and 'YES -- granted and joined are the same channel'
                or ('NO -- this client is on ' .. tostring(s.joined)
                    .. ' and was granted ' .. tostring(s.radio)
                    .. '. A join in flight looks like this for one tick; '
                    .. 'anything longer is the bug.')))
    end
    print(('  %-14s%s'):format('squadmates',
        #s.mates > 0 and table.concat(s.mates, ', ')
            or 'none -- the server named nobody else on this squad'))

    -- AND THE KEY, WHICH IS THE ONE FACT NOBODY HAD EVER BEEN TOLD. The squad
    -- radio is pma-voice's, and pma-voice's radio has its own push-to-talk;
    -- the ordinary voice key carries proximity, which squad mode turns off.
    -- Printed whenever the radio is the mode, granted or not, because "hold
    -- this key" is useless information one match too late.
    if r.radio then
        print(('  %-14sHOLD "%s" (Talk over Radio, pma-voice). The ordinary')
            :format('talk key', BR.Voice.radioKeyLabel()))
        print('                voice key carries NOTHING in this mode. Rebind it')
        print('                in the pause menu: Settings, Key Bindings, FiveM.')
    end

    -- LISTEN.
    local hear = {}
    for src in pairs(s.audible) do hear[#hear + 1] = src end
    table.sort(hear)
    print(('  %-14s%s'):format('not refusing',
        #hear > 0 and table.concat(hear, ', ')
            or 'nobody -- correct for off, for squad with no squad, and for '
               .. 'standing alone'))
    local nmuted = 0
    for _ in pairs(s.muted) do nmuted = nmuted + 1 end
    print(('  %-14s%d player(s)%s'):format('muted', nmuted,
        r.proximity and ' -- MUST BE 0 on nearby'
            or (r.radio and ' -- squad, so everybody who is not a squadmate'
                or ' -- off, so all of them')))
    print(('  %-14s%s'):format('talking',
        #BR.Voice.talking > 0 and table.concat(BR.Voice.talking, ', ')
            or 'nobody'))

    -- AND THE THING A PLAYTESTER MUST KNOW BEFORE DIAGNOSING ANYTHING, because
    -- it inverts where you look. Every previous version of this file gated on
    -- the receive side, so "I cannot hear Bob" was a question about my machine.
    -- It is now a question about BOB'S.
    print('')
    print('  THE TWO MODES ARE EXCLUSIVE, not layered. Nearby is proximity and')
    print('  nothing else -- a squadmate across the map is as inaudible as any')
    print('  stranger. Squad is the squad radio and nothing else -- the enemy')
    print('  standing next to you is muted, at every distance.')
    print('')
    print('  Proximity is enforced by the SPEAKER: you hear somebody because')
    print('  THEY decided you were in range. So if you cannot hear Bob, run')
    print('  /brvoice on BOB\'s machine and read his "prox mic" line -- on')
    print('  nearby there is nothing on yours that can be refusing him. On')
    print('  SQUAD there is: this readout\'s "muted" line, and it is the mode')
    print('  doing what it was asked.')
end, false)

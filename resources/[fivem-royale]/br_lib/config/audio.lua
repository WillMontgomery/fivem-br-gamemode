-- COMBAT audio. Not interface audio -- that lives in the browser.
--
-- WHAT IS AND IS NOT HERE.
--
-- Everything the player hears from the INTERFACE is synthesised in
-- ui-src/src/audio/cues.ts: menus, verdicts, the storm, loot tiers. GTA's
-- frontend sounds are instantly recognisable as GTA Online's menus, which is
-- the one association a standalone game mode should not be making, and they
-- cannot be varied or put behind a volume slider.
--
-- What remains here is the handful of cues that fire DURING SHOOTING, where
-- PlaySoundFrontend earns its keep for one reason that cannot be reproduced
-- from a browser: THE ENGINE MIXES IT. A hitmarker fired from CEF sits on top
-- of a firefight at full volume forever.
--
-- EVERY NAME HERE MUST BE AUDITIONED. A wrong sound-set name does not error --
-- PlaySoundFrontend simply plays nothing, exactly like a misspelled native
-- returning nil. /brsfx exists for that, and it has already caught two: WIN
-- and LOSER live in HUD_AWARDS, not GTAO_FM_EVENTS_SOUNDSET, which is why
-- those two were silent.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Audio = {
    -- Master switch, for a player who wants silence without touching the game
    -- mixer. Client-side only; nothing here reaches another player.
    enabled = true,

    -- Per-cue rate limits, in ms. THE HITMARKER IS THE REASON THIS EXISTS: it
    -- fires once per bullet, and an unthrottled full-auto burst is thirty
    -- overlapping sounds. That has no visual symptom and will not be found by
    -- playing -- it just sounds broken and nobody can say why.
    minInterval = {
        ['hit']       = 60,
        ['hit.crit']  = 60,
        ['ui.hover']  = 40,
    },

    cues = {
        -- NATIVE IS COMBAT ONLY.
        --
        -- Everything the player hears from the INTERFACE -- menus, verdicts,
        -- pickups, the storm -- is synthesised in the browser
        -- (ui-src/src/audio/cues.ts). GTA's frontend sounds are instantly
        -- recognisable as GTA Online's menus, which is the one association a
        -- standalone mode should not be making, and they cannot be varied or
        -- volume-controlled.
        --
        -- What stays here is the handful of cues that fire DURING SHOOTING,
        -- where PlaySoundFrontend earns its place: the engine mixes it, so it
        -- ducks against gunfire. A hitmarker fired from CEF sits on top of a
        -- firefight at full volume forever.
        ['hit']      = { set = 'HUD_MINI_GAME_SOUNDSET', name = 'CHECKPOINT_NORMAL' },
        ['hit.crit'] = { set = 'HUD_MINI_GAME_SOUNDSET', name = 'CHECKPOINT_PERFECT' },

        -- ═══ THE PUMP, AND WHY THESE TWO ARE NATIVE WHEN THE RULE ABOVE SAYS
        --     INTERFACE AUDIO IS NOT ═══
        --
        --   "When pressing [key] to fuel, a sound should be played. This should
        --    be a native GTA V sound. Pick something most appropriate for
        --    'interact'"
        --   "When fuel reaches 100%, a 'complete' sound should be played.
        --    Again, GTA V sounds only please."
        --   "All occupants of a vehicle should hear these sounds."
        --                                          -- owner, 2026-08-22
        --
        -- THE LAST SENTENCE IS THE ONE THAT DECIDES THE MEDIUM, and it decides
        -- it on a fact rather than a preference. ui-src/src/audio/cues.ts plays
        -- into ONE browser on ONE client: a CEF-synthesised cue physically
        -- cannot reach the passenger sitting beside the driver, because that
        -- passenger is a different machine with a different browser. So "all
        -- occupants hear it" rules the browser out, and the owner asked for
        -- native anyway. These are also WORLD events, not menu events -- the
        -- same category the pickup cue was moved back into at the owner's call
        -- (see loot.lua's `pickupSound`: "a pickup is a world event, it fires
        -- while shooting, and the engine cue ducks correctly").
        --
        -- ═══ WHERE THESE TWO NAMES CAME FROM, BECAUSE A WRONG ONE IS SILENT
        --     RATHER THAN LOUD ═══
        --
        -- Both were checked against the game's own extracted audio table (2,203
        -- AudioName/AudioRef pairs, 500 distinct refs) rather than off a wiki --
        -- the header above says every name here must be auditioned, and this is
        -- the strongest check available without a running client.
        --
        -- HUD_FRONTEND_DEFAULT_SOUNDSET is additionally PROVEN LIVE IN THIS
        -- TREE: loot.lua already ships `PICK_UP` and `NAV_UP_DOWN` out of that
        -- exact set and both are audible in game. HUD_AWARDS is the set this
        -- file's own header records as where WIN and LOSER actually live, found
        -- the expensive way when they were silent in GTAO_FM_EVENTS_SOUNDSET.
        -- So neither ref is a guess: each has been heard from this codebase.
        --
        -- ═══ WHY THESE TWO SOUNDS AND NOT OTHERS ═══
        --
        -- THERE IS NO PETROL-PUMP SOUND IN GTA. The complete list of fuel-ish
        -- entries in the audio table is Gas_Explosion, ARM_2_Repo_Ignite_Petrol,
        -- FINALE_PETROL_SPILL, Gas_Tanker_Explosion, Gas_Station_Explosion and
        -- WEAPON_SELECT_FUEL_CAN -- five explosions and a weapon-shop click.
        -- This is the same shape as the blip sprite in config/fuel.lua, where
        -- GTA turned out to have no petrol-station icon either and a jerry can
        -- was the whole available choice. So both cues below are the GENERIC
        -- ones, chosen for what they communicate rather than for theme.
        --
        --   fuel.start  SELECT is the game's own "you interacted with a thing"
        --               confirm -- the most literal answer to "most appropriate
        --               for interact" the engine contains.
        --   fuel.done   CHALLENGE_UNLOCKED is its "a thing you were working on
        --               has finished" chime. Short, unmistakably terminal, and
        --               not the match-win fanfare -- a full tank is a completed
        --               task, not a victory.
        --
        -- NEITHER COLLIDES WITH A CUE ALREADY IN USE. PICK_UP is loot,
        -- NAV_UP_DOWN is the slot switch, CHECKPOINT_NORMAL and
        -- CHECKPOINT_PERFECT are the hitmarker and the crate. Two actions that
        -- sound identical are worse than one that sounds wrong.
        --
        -- PLAYED FROM THE VEHICLE, NOT FROM THE FRONTEND. See
        -- BR.Sfx.playFrom -- it is the same table and the same throttle, but
        -- PlaySoundFromEntity, so the cue is positioned on the car and mixed by
        -- the engine for every occupant.
        ['fuel.start'] = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'SELECT' },
        ['fuel.done']  = { set = 'HUD_AWARDS', name = 'CHALLENGE_UNLOCKED' },
    },
}

-- NOTE: the loot cue moved to the browser with the rest of the interface
-- audio, and the pickup sound itself went back to GTA's own PICK_UP at the
-- user's call -- it is a world event, it fires while shooting, and the engine
-- one was right. See client/inventory.lua.

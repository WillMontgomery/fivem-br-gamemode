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
        --               for interact" the engine contains. THE OWNER HAS HEARD
        --               THIS ONE AND KEPT IT; it is not to be changed.
        --   fuel.done   PROPERTY_PURCHASE is the game's "the transaction you
        --               were making has gone through" chime -- see the block
        --               below for why it replaced CHALLENGE_UNLOCKED.
        --
        -- ═══ WHY fuel.done IS NO LONGER CHALLENGE_UNLOCKED ═══
        --
        --   "the noise we're playing when fueling finishes is more like a
        --    warning sound than a complete/confirmation sound. That should be
        --    changed."                                 -- owner, 2026-08-22
        --
        -- THE SET DID NOT MOVE, AND THAT IS THE POINT. Only the name changed,
        -- and it changed WITHIN HUD_AWARDS. That matters more than any argument
        -- about which chime is nicer, because the one way a cue fails here is
        -- SILENTLY: a sound set that is not loaded plays nothing and reports
        -- nothing, exactly like a misspelled name. The owner's complaint is
        -- itself the proof that this set loads and is audible on the shipping
        -- build -- they heard CHALLENGE_UNLOCKED and disliked it. Staying inside
        -- the set they heard is the lowest-risk change available; hopping to a
        -- DLC bank would have put the audibility question back open.
        --
        -- (Pit_Stop_Complete was the on-theme candidate and was rejected for
        -- exactly that reason: it lives in DLC_H3_Circuit_Racing_Sounds, which
        -- is a script audio bank this gamemode never requests.)
        --
        -- CHECKED THE SAME THREE WAYS THE TWO ORIGINAL NAMES WERE:
        --   1. The game's own extracted audio table (2,204 AudioName/AudioRef
        --      pairs). HUD_AWARDS holds exactly 22 names and PROPERTY_PURCHASE
        --      is one of them, alongside CHALLENGE_UNLOCKED, WIN and LOSER --
        --      which is the same table agreeing with what this file's header
        --      already learned the expensive way.
        --   2. A second, independently maintained extraction of the same table
        --      lists the identical 22 names for HUD_AWARDS. Two sources, one
        --      answer.
        --   3. This file's own note above: HUD_AWARDS is where WIN and LOSER
        --      actually live, found when they were silent in
        --      GTAO_FM_EVENTS_SOUNDSET. The ref has been heard from this
        --      codebase.
        --
        -- WHY THIS NAME AND NOT ANOTHER OF THE 22. Most of HUD_AWARDS is
        -- CELEBRATION -- MEDAL_GOLD, RANK_UP, WIN, the golf and tennis stings --
        -- and a full tank is not a victory, which is the same reason
        -- CHALLENGE_UNLOCKED was picked over the win fanfare in the first place.
        -- PROPERTY_PURCHASE is the one entry that is a plain TRANSACTION
        -- CONFIRM: the sound GTA plays when a thing you were paying for is now
        -- done. That is what filling a tank is. COLLECTED was the other
        -- candidate and was dropped because it is a pickup cue and PICK_UP is
        -- already the loot sound -- see the collision rule immediately below.
        --
        -- STILL AUDITIONABLE THE SAME WAY, and nothing had to be added for it:
        -- /brsfx takes any key in this table, so the new cue is `/brsfx
        -- fuel.done` exactly as the old one was. `/brsfx HUD_AWARDS
        -- PROPERTY_PURCHASE` plays the raw pair without going through the table.
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
        ['fuel.done']  = { set = 'HUD_AWARDS', name = 'PROPERTY_PURCHASE' },
    },
}

-- NOTE: the loot cue moved to the browser with the rest of the interface
-- audio, and the pickup sound itself went back to GTA's own PICK_UP at the
-- user's call -- it is a world event, it fires while shooting, and the engine
-- one was right. See client/inventory.lua.

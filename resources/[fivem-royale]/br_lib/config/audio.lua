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

        -- ═══ THE WALL STARTS MOVING ═══
        --
        --   "We also need a sound for when the storm starts moving"
        --                                          -- owner, 2026-08-22
        --
        -- WHICH MOMENT THAT IS, DERIVED RATHER THAN ASSUMED. A storm phase has
        -- two halves and only one of them moves: BR.StormAt returns HOLDING
        -- while the circle sits still with the next one already drawn, and
        -- SHRINKING once the wall is travelling. "Starts moving" is the edge
        -- between them, and it is the edge server/storm.lua watches -- not
        -- phase entry, which is when the wall STOPS to hold.
        --
        -- ONE CUE FOR ALL EIGHT PHASES rather than eight cues. The event is
        -- the same event each time and a player learns it by ear once; what
        -- differs between phase 1 and phase 8 is the circle on their map, not
        -- what the moment means.
        --
        -- ═══ WHY THIS SOUND, AND WHY IT IS THE EASIEST THING HERE TO CHANGE
        --     ═══
        --
        -- GO_NON_RACE is GTA's "the thing has started -- move" stinger: the
        -- one it plays to start a non-race event. That is the sentence this
        -- cue has to say. It is a ONE-SHOT rather than a countdown loop, which
        -- rules out the other close candidates in the same set (10_SEC_WARNING
        -- and 5_SEC_WARNING are the tail of a timer, and the wall starting to
        -- move is the beginning of one).
        --
        -- THE SET IS THE SAFE HALF OF THE CHOICE AND IT WAS CHOSEN FIRST.
        -- HUD_MINI_GAME_SOUNDSET is where the hitmarker and the crate already
        -- live -- CHECKPOINT_NORMAL and CHECKPOINT_PERFECT, audible in every
        -- match this project has ever played. A cue fails SILENTLY when its
        -- set is not loaded (see this file's header), so picking the name out
        -- of a set this codebase demonstrably hears is what stops "I do not
        -- like it" and "it never played" looking identical.
        --
        -- AND IT IS A DEFAULT, NOT A VERDICT. Two fuel sounds have now been
        -- chosen from a desk and rejected by ear, so this one is wired to be
        -- replaced without a code edit:
        --
        --   /brsfx storm.move                  hear what is configured
        --   /brsfx audition HUD_MINI_GAME_SOUNDSET   hear the whole set
        --   /brsfx bind storm.move <SET> <NAME>      try one, live
        --
        -- and the line below is the one line to edit once the ear has decided.
        ['storm.move']  = { set = 'HUD_MINI_GAME_SOUNDSET', name = 'GO_NON_RACE' },
    },

    -- Per-cue rate limits are above; this one deliberately has none. The
    -- storm cue is addressed by the SERVER, once per HOLDING->SHRINKING edge,
    -- so a throttle here could only ever hide a server-side bug that sent it
    -- twice -- and hiding that is worse than hearing it.
}

-- NOTE: the loot cue moved to the browser with the rest of the interface
-- audio, and the pickup sound itself went back to GTA's own PICK_UP at the
-- user's call -- it is a world event, it fires while shooting, and the engine
-- one was right. See client/inventory.lua.

-- ===========================================================================
-- THE CATALOGUE: WHAT THERE IS TO CHOOSE FROM
-- ===========================================================================
--
--   "Can you make me something which plays GTA sounds with a console command
--    so I can pick which one sounds good?"      -- owner, 2026-08-22
--
-- THIS EXISTS BECAUSE TWO SOUNDS HAVE NOW BEEN PICKED FROM A DESK AND
-- REJECTED BY EAR. CHALLENGE_UNLOCKED was "more like a warning"; the
-- PROPERTY_PURCHASE that replaced it was not it either. The fault was never
-- which name got picked -- it was that a name was being picked by somebody
-- reading a table instead of somebody listening. So the table is here, /brsfx
-- browses it, and the choosing goes back to the ear it belongs to.
--
-- ═══ WHERE THESE 325 PAIRS CAME FROM, AND WHY NOT THE OBVIOUS PLACE ═══
--
-- THE OBVIOUS PLACE WAS DurtyFree/gta-v-data-dumps, which is what previous
-- rounds used to check names, and IT CANNOT BE VENDORED. That repository
-- carries NO LICENCE AT ALL -- the GitHub API answers `"license": null` and
-- the /license endpoint 404s -- which means all rights reserved by default.
-- tools/verify.sh's `vendored third-party` gate requires a LICENSE file to
-- travel with any vendored directory, and there is no notice in existence to
-- copy. Vendoring it would fail our own gate, correctly.
--
-- WHAT IS HERE INSTEAD IS A STRONGER SOURCE FOR THIS PARTICULAR JOB, not a
-- weaker one. These are the PLAY_SOUND_FRONTEND calls that GTA's OWN SCRIPTS
-- make, taken from the decompiled-script occurrence list that citizenfx's
-- native reference itself links from PLAY_SOUND_FRONTEND (Sainan's b2189
-- gist). A name dump proves a string exists somewhere in the audio metadata.
-- This proves Rockstar's own code plays it -- which is much closer to the
-- only question that matters here:
--
--   A NAME EXISTING DOES NOT MEAN ITS BANK IS LOADED ON THIS BUILD. That is
--   the whole reason Pit_Stop_Complete was rejected for fuel.done: it is a
--   real name in a real set, and its set is a DLC script audio bank this
--   gamemode never requests, so it would have been silent. Silent and
--   "wrong sound" are indistinguishable, which is what cost two rounds.
--
-- SO THE DLC SETS ARE FILTERED OUT. Every DLC_*/dlc_* set in that list is
-- gone; what remains is 325 pairs across 84 base-game sets. That is not a
-- promise that all 325 play -- see the `[silent?]` marker /brsfx prints, and
-- see below -- but it is the best filter available without a running client.
--
-- ═══ THREE SETS ARE MARKED, AND THE MARK MEANS SOMETHING DIFFERENT ═══
--
-- HUD_FRONTEND_DEFAULT_SOUNDSET, HUD_AWARDS and HUD_MINI_GAME_SOUNDSET carry
-- `heard from this codebase`. That is not "extracted from a dump" -- it is
-- "this project has played a sound out of this set and a human confirmed
-- hearing it": PICK_UP and SELECT, WIN and LOSER (found the expensive way
-- when they were silent in GTAO_FM_EVENTS_SOUNDSET), CHECKPOINT_NORMAL and
-- CHECKPOINT_PERFECT. They sort first because they are the sets where a
-- silence means the NAME is wrong rather than the whole bank being absent.
--
-- ═══ THIS LIST IS A STARTING POINT AND NOT A FENCE ═══
--
-- `/brsfx play <SET> <NAME>` plays ANY pair, catalogue or not. Nothing here
-- restricts what can be auditioned; the catalogue only decides what can be
-- BROWSED. Paste a name from anywhere and the same silence probe reports on
-- it.
--
-- ═══ AN ARRAY, NOT A KEYED TABLE, AND THAT IS DELIBERATE ═══
--
-- `pairs()` order is unspecified in Lua and varies run to run. A browsing
-- tool whose list reshuffles between two invocations is one the owner cannot
-- work down, so the order is fixed here in the source: the three heard sets
-- first, then the rest alphabetically, names sorted within each set.
BR.Config.Audio.catalogue = {
        { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET',   -- heard from this codebase
          names = { 'ATM_WINDOW', 'BACK', 'Back', 'CANCEL', 'CONTINUE',
                    'DPAD_WEAPON_SCROLL', 'ERROR', 'EXIT',
                    'HORDE_COOL_DOWN_TIMER', 'INFO', 'LEADER_BOARD',
                    'MP_5_SECOND_TIMER', 'MP_AWARD', 'MP_IDLE_KICK',
                    'MP_IDLE_TIMER', 'MP_RANK_UP', 'MP_WAVE_COMPLETE',
                    'NAV_LEFT_RIGHT', 'NAV_UP_DOWN', 'NO', 'OK', 'PICK_UP',
                    'SELECT', 'TOGGLE_ON', 'WAYPOINT_SET', 'YES',
                    'continue', } },
        { set = 'HUD_AWARDS',   -- heard from this codebase
          names = { 'BASE_JUMP_PASSED', 'CHALLENGE_UNLOCKED', 'COLLECTED',
                    'GOLF_NEW_RECORD', 'LOSER', 'OTHER_TEXT',
                    'PEYOTE_COMPLETED', 'PROPERTY_PURCHASE', 'RACE_PLACED',
                    'RANK_UP', 'SIGN_DESTROYED', 'TENNIS_POINT_WON',
                    'UNDER_THE_BRIDGE', 'WIN', } },
        { set = 'HUD_MINI_GAME_SOUNDSET',   -- heard from this codebase
          names = { '10_SEC_WARNING', '3_2_1', '3_2_1_NON_RACE',
                    '5_SEC_WARNING', 'CAM_PAN_DARTS', 'CHECKPOINT_AHEAD',
                    'CHECKPOINT_BEHIND', 'CHECKPOINT_MISSED',
                    'CHECKPOINT_NORMAL', 'CHECKPOINT_PERFECT',
                    'CHECKPOINT_UNDER_THE_BRIDGE', 'FIRST_PLACE', 'GO',
                    'GO_NON_RACE', 'LOOSE_MATCH', 'MEDAL_UP', 'TIMER_STOP', } },
        { set = 'Arena_Vehicle_Mod_Shop_Sounds',
          names = { 'supermod_consumer', 'supermod_scifi',
                    'supermod_wasteland', } },
        { set = 'ASSASSINATION_MULTI',
          names = { 'ASSASSINATIONS_HOTEL_TIMER_COUNTDOWN', } },
        { set = 'ATM_SOUNDS',
          names = { 'PIN_BUTTON', } },
        { set = 'BARRY_02_SOUNDSET',
          names = { 'HOORAY', } },
        { set = 'BIG_SCORE_3A_SOUNDS',
          names = { 'TRAFFIC_CONTROL_BG_NOISE',
                    'TRAFFIC_CONTROL_CHANGE_CAM',
                    'TRAFFIC_CONTROL_MOVE_CROSSHAIR',
                    'TRAFFIC_CONTROL_TOGGLE_LIGHT', 'Traffic_Control_Fail',
                    'Traffic_Control_Fail_Blank',
                    'Traffic_Control_Light_Switch_Back', } },
        { set = 'BIG_SCORE_SETUP_SOUNDS',
          names = { 'Camera_Hum', 'Camera_Zoom', } },
        { set = 'biker_formation_sounds',
          names = { 'player_riding', } },
        { set = 'CAR_STEAL_2_SOUNDSET',
          names = { 'DISTANT_DOG_BARK', 'Thermal_Off', 'Thermal_On', } },
        { set = 'CB_RADIO_SFX',
          names = { 'Background_Loop', 'End_Squelch', 'Start_Squelch', } },
        { set = 'CELEBRATION_SOUNDSET',
          names = { 'LOSER', 'ROUND_ENDING_STINGER_CUSTOM', 'SCREEN_FLASH',
                    'WINNER', } },
        { set = 'DOCKS_HEIST_FINALE_2B_SOUNDS',
          names = { 'Door_Open', } },
        { set = 'DOOR_GARAGE',
          names = { 'OPENED', 'OPENING', } },
        { set = 'EXILE_1',
          names = { 'Altitude_Warning', 'Falling_Crates', } },
        { set = 'FAMILY1_BOAT',
          names = { 'FAMILY_1_CAR_BREAKDOWN',
                    'FAMILY_1_CAR_BREAKDOWN_ADDITIONAL', } },
        { set = 'FAMILY_5_SOUNDS',
          names = { 'FLYING_STREAM_END_INSTANT', 'MICHAEL_LONG_SCREAM', } },
        { set = 'FBI_HEIST_FINALE_CHOPPER',
          names = { 'Heli_Crash', } },
        { set = 'Feed_Message_Sounds',
          names = { 'FestiveGift', } },
        { set = 'FM_Events_Sasquatch_Sounds',
          names = { 'Checkpoint_Beast_Hit', 'Frontend_Beast_Fade_Screen',
                    'Frontend_Beast_Freeze_Screen',
                    'Frontend_Beast_Text_Hit',
                    'Frontend_Beast_Transform_Back', 'Radar_Beast_Blip', } },
        { set = 'formation_flying_blips_soundset',
          names = { 'formation_active', 'formation_inactive', } },
        { set = 'GTAO_APT_DOOR_DOWNSTAIRS_GENERIC_SOUNDS',
          names = { 'LIMIT', 'PUSH', 'Push', 'SWING_SHUT', } },
        { set = 'GTAO_APT_DOOR_DOWNSTAIRS_GLASS_SOUNDS',
          names = { 'LIMIT', 'PUSH', 'SWING_SHUT', } },
        { set = 'GTAO_APT_DOOR_DOWNSTAIRS_WOOD_SOUNDS',
          names = { 'LIMIT', 'PUSH', 'SWING_SHUT', } },
        { set = 'GTAO_APT_DOOR_ROOF_METAL_SOUNDS',
          names = { 'LIMIT', 'PUSH', 'SWING_SHUT', } },
        { set = 'GTAO_Biker_FM_Shard_Sounds',
          names = { 'Shard_Disappear', } },
        { set = 'GTAO_Biker_FM_Soundset',
          names = { 'Boss_Message_Orange', } },
        { set = 'GTAO_Biker_Modes_Soundset',
          names = { 'Blip_Pickup', 'Crates_Blipped', 'Deliver_Item',
                    'Enemy_Pickup_Briefcase', 'Enter_1st',
                    'Generic_Negative_Event', 'Generic_Positive_Event',
                    'Lose_1st', 'Pickup_Briefcase', 'Pickup_Standard', } },
        { set = 'GTAO_Boss_Goons_FM_Shard_Sounds',
          names = { 'Shard_Disappear', } },
        { set = 'GTAO_Boss_Goons_FM_Soundset',
          names = { 'Boss_Message_Orange', 'Goon_Paid_Large',
                    'Goon_Paid_Small', } },
        { set = 'GTAO_Dancing_Sounds',
          names = { 'Beat_Pulse_Default', } },
        { set = 'GTAO_Exec_SecuroServ_Computer_Sounds',
          names = { 'Logout', 'Navigate', 'Popup_Cancel',
                    'Popup_Confirm_Fail', 'Popup_Confirm_Success', 'Sell', } },
        { set = 'GTAO_Exec_SecuroServ_Warehouse_PC_Sounds',
          names = { 'Cancel', 'Confirm', 'Error', 'Login', 'Mouse_Click',
                    'Sell', } },
        { set = 'GTAO_FM_Cross_The_Line_Soundset',
          names = { 'Player_Enter_Line', 'Player_Exit_Line',
                    'Remote_Enemy_Enter_Line', 'Remote_Friendly_Enter_Line', } },
        { set = 'GTAO_FM_Events_Soundset',
          names = { '5s_To_Event_Start_Countdown', 'Checkpoint_Cash_Hit',
                    'Checkpoint_Hit', 'Criminal_Damage_High_Value',
                    'Criminal_Damage_Kill_Player',
                    'Criminal_Damage_Low_Value', 'Enter_1st',
                    'Event_Message_Purple', 'Event_Start_Text',
                    'Kill_List_Counter', 'Lose_1st', 'Near_Miss_Counter',
                    'Near_Miss_Counter_Reset', 'OOB_Cancel', 'OOB_Start',
                    'OOB_Timer_Dynamic', 'Object_Collect_Player',
                    'Object_Collect_Remote', 'Object_Dropped_Remote',
                    'Parcel_Vehicle_Lost', 'Return_To_Vehicle_Timer',
                    'Shard_Disappear', 'Timer_10s', } },
        { set = 'GTAO_Heists_HUD_Sounds',
          names = { 'Scope_Spot_POI', } },
        { set = 'GTAO_ImpExp_Enter_Exit_Garage_Sounds',
          names = { 'Enter_On_Foot', 'Exit_In_Vehicle', } },
        { set = 'GTAO_Magnate_Boss_Modes_Soundset',
          names = { 'Crates_Blipped', 'Enter_1st', 'Lose_1st',
                    'Pickup_Briefcase', } },
        { set = 'GTAO_Rappel_Sounds',
          names = { 'Rappel_Land', 'Rappel_Loop', 'Rappel_Stop', } },
        { set = 'GTAO_Script_Doors_Faded_Screen_Sounds',
          names = { 'Bunker_Hatch', 'Garage_Door_Close', 'Garage_Door_Open', } },
        { set = 'GTAO_Script_Doors_Sounds',
          names = { 'Garage_Door_Close_Loop', 'Garage_Door_Open_Loop',
                    'Generic_Door_Closed', } },
        { set = 'GTAO_Shepherd_Sounds',
          names = { 'Checkpoint_Teammate', } },
        { set = 'GTAO_SMG_Hangar_Computer_Sounds',
          names = { 'Click_Back', 'Click_Fail', 'Click_Link',
                    'Click_Special', 'Exit', 'Show_Overview_Menu',
                    'Show_Sell_Menu', 'Show_Source_Menu', } },
        { set = 'GTAO_Speed_Convoy_Soundset',
          names = { 'Arming_Countdown', 'Bomb_Disarmed', } },
        { set = 'GTAO_Vision_Modes_SoundSet',
          names = { 'Nightvision_Loop', 'Off', 'On', 'Switch',
                    'Thermal_Loop', } },
        { set = 'HintCamSounds',
          names = { 'FocusIn', 'FocusOut', } },
        { set = 'HUD_AMMO_SHOP_SOUNDSET',
          names = { 'BACK', 'ERROR', 'NAV', 'WEAPON_PURCHASE',
                    'WEAPON_SELECT_ARMOR', } },
        { set = 'HUD_DEATHMATCH_SOUNDSET',
          names = { 'DELETE', 'EDIT', } },
        { set = 'HUD_FREEMODE_SOUNDSET',
          names = { 'BACK', 'CANCEL', 'ERROR', 'NAV_LEFT_RIGHT',
                    'NAV_UP_DOWN', 'SELECT', } },
        { set = 'HUD_FRONTEND_CLOTHESSHOP_SOUNDSET',
          names = { 'CANCEL', 'ERROR', 'NAV_UP_DOWN', 'SELECT', } },
        { set = 'HUD_FRONTEND_CUSTOM_SOUNDSET',
          names = { 'ROBBERY_MONEY_TOTAL', } },
        { set = 'HUD_FRONTEND_MP_COLLECTABLE_SOUNDS',
          names = { 'Deliver_Pick_Up', 'Dropped', 'Enemy_Deliver',
                    'Enemy_Pick_Up', 'Friend_Deliver', 'Friend_Pick_Up', } },
        { set = 'HUD_FRONTEND_MP_SOUNDSET',
          names = { 'BACK', 'SELECT', } },
        { set = 'HUD_FRONTEND_WEAPONS_PICKUPS_SOUNDSET',
          names = { 'PICKUP_WEAPON_BALL', } },
        { set = 'HUD_LIQUOR_STORE_SOUNDSET',
          names = { 'CANCEL', 'ERROR', 'NAV_UP_DOWN', 'PURCHASE', 'SELECT', } },
        { set = 'In_And_Out_Attacker_Sounds',
          names = { 'Deliver', 'Dropped', 'Friend_Pick_Up',
                    'Player_Pick_Up', } },
        { set = 'In_And_Out_Defender_Sounds',
          names = { 'Dropped', 'Enemy_Deliver', 'Enemy_Pick_Up', } },
        { set = 'JA16_Super_Mod_Garage_Sounds',
          names = { 'Banshee2_Upgrade', 'SultanRS_Upgrade', } },
        { set = 'LONG_PLAYER_SWITCH_SOUNDS',
          names = { 'Hit_1', } },
        { set = 'Low2_Super_Mod_Garage_Sounds',
          names = { 'Faction3_Upgrade', } },
        { set = 'Lowrider_Super_Mod_Garage_Sounds',
          names = { 'Lowrider_Upgrade', } },
        { set = 'MissionFailedSounds',
          names = { 'ScreenFlash', } },
        { set = 'MP_CCTV_SOUNDSET',
          names = { 'Background', 'Change_Cam', 'Pan', 'Zoom', } },
        { set = 'MP_LOBBY_SOUNDS',
          names = { 'BOATS_PLANES_HELIS_BOOM', 'CAR_BIKE_WHOOSH',
                    'Whoosh_1s_L_to_R', 'Whoosh_1s_R_to_L', } },
        { set = 'MP_MISSION_COUNTDOWN_SOUNDSET',
          names = { '10S', '10s', '5S', '5s', 'Get_Back_In_Vehicle',
                    'Oneshot_Final', 'Out_of_Bounds',
                    'Out_of_Bounds_Explode', } },
        { set = 'MP_PLAYER_APARTMENT',
          names = { 'DOOR_BUZZ', } },
        { set = 'MP_PROPERTIES_ELEVATOR_DOORS',
          names = { 'BUTTON', 'CLOSED', 'CLOSING', 'FAKE_ARRIVE', 'OPENED',
                    'OPENING', } },
        { set = 'MP_RADIO_SFX',
          names = { 'Off_High', 'Off_Low', 'Retune_High', 'Retune_Low', } },
        { set = 'MP_SNACKS_SOUNDSET',
          names = { 'Knuckle_Crack_Hard_Cel', 'Knuckle_Crack_Slap_Cel',
                    'Slow_Clap_Cel', } },
        { set = 'Phone_SoundSet_Default',
          names = { 'Menu_Accept', } },
        { set = 'Phone_Soundset_Franklin',
          names = { 'Camera_Shoot', } },
        { set = 'Phone_SoundSet_Michael',
          names = { 'Hang_Up', 'Put_Away', } },
        { set = 'PLAYER_SWITCH_CUSTOM_SOUNDSET',
          names = { '1st_Person_Transition', 'Camera_Move_Loop', 'HIT_OUT',
                    'Hit_In', 'Hit_Out', 'Hit_out', 'Short_Transition_In',
                    'Short_Transition_Out', } },
        { set = 'POLICE_CHOPPER_CAM_SOUNDS',
          names = { 'Found_Target', 'Lost_Target', 'Microphone', } },
        { set = 'POWER_PLAY_General_Soundset',
          names = { 'Round_Start_Blade', 'Wasted', } },
        { set = 'Radio_Soundset',
          names = { 'Change_Station_Loud', } },
        { set = 'RESPAWN_ONLINE_SOUNDSET',
          names = { 'Accept_Ghosting_Mode', 'Faster_Bar_Full',
                    'Faster_Click', 'Hit', } },
        { set = 'RESPAWN_SOUNDSET',
          names = { 'Hit', } },
        { set = 'SAFE_CRACK_SOUNDSET',
          names = { 'SAFE_DOOR_CLOSE', 'SAFE_DOOR_OPEN', 'TUMBLER_PIN_FALL',
                    'TUMBLER_PIN_FALL_FINAL', 'TUMBLER_RESET',
                    'TUMBLER_TURN', } },
        { set = 'Safe_Minigame_Sounds',
          names = { 'Idcnput_Code_Enter_Correct_Final', 'Input_Code_Down',
                    'Input_Code_Enter_Correct', 'Input_Code_Enter_Wrong',
                    'Input_Code_Up', } },
        { set = 'SHORT_PLAYER_SWITCH_SOUND_SET',
          names = { 'All', 'out', } },
        { set = 'WastedSounds',
          names = { 'Bed', 'MP_Flash', 'MP_Impact', 'ScreenFlash',
                    'TextHit', } },
        { set = 'WEB_NAVIGATION_SOUNDS_PHONE',
          names = { 'CLICK_BACK', 'Click_Fail', 'Click_Special', } },
}

--- Lowercased plain-text containment. `find` with the fourth argument true, so
--- a query full of `_` and `-` is compared as TEXT rather than compiled as a
--- Lua pattern -- every sound name in the catalogue contains an underscore,
--- and `%` or `(` typed into a search box must not be able to throw.
--- @param haystack string
--- @param needle string|nil   nil or '' matches everything
--- @return boolean
local function contains(haystack, needle)
    -- ═══ THE `== ''` HALF IS AN EARLY RETURN, NOT A BEHAVIOUR, AND MUTATION
    --     TESTING SAYS SO OUT LOUD ═══
    --
    -- A mutant that deletes it SURVIVES the suite, correctly. `string.find(s,
    -- '', 1, true)` answers 1 -- the empty string is found at position one of
    -- everything -- so an empty query already falls through to `true` without
    -- any help from this line. It stays because `sets('')` and `sets(nil)`
    -- meaning the same thing is a promise the command surface makes out loud,
    -- and a reader should not have to know that fact about string.find to be
    -- sure of it.
    if needle == nil or needle == '' then return true end
    return string.find(string.lower(haystack), string.lower(needle), 1, true) ~= nil
end

--- The sound sets, optionally narrowed by a substring of the set name.
---
--- PURE, AND THAT IS WHY IT IS HERE RATHER THAN IN THE COMMAND. The command
--- that prints this runs on a client and cannot be unit-tested; the rule about
--- what matches what is arithmetic and can be. Same split as
--- BR.Config.Storm.TotalSeconds().
---
--- @param q string|nil   substring of the set name, case-insensitive
--- @return table         { { set = string, n = integer }, ... } in catalogue order
function BR.Config.Audio.sets(q)
    local out = {}
    for _, entry in ipairs(BR.Config.Audio.catalogue) do
        if contains(entry.set, q) then
            out[#out + 1] = { set = entry.set, n = #entry.names }
        end
    end
    return out
end

--- Every catalogue pair whose NAME matches `q` and whose SET matches `setQ`.
---
--- BOTH FILTERS ARE OPTIONAL AND THEY ARE ANDed. "narrow it by set, by
--- substring, or both" was the ask, and both-at-once is the case that matters:
--- `find complete HUD` is how you look for a confirmation chime in the sets
--- this codebase has actually heard, which is the search that would have
--- settled fuel.done two rounds ago.
---
--- @param q string|nil      substring of the sound name
--- @param setQ string|nil   substring of the set name
--- @return table            { { set = string, name = string }, ... }
function BR.Config.Audio.find(q, setQ)
    local out = {}
    for _, entry in ipairs(BR.Config.Audio.catalogue) do
        if contains(entry.set, setQ) then
            for _, name in ipairs(entry.names) do
                if contains(name, q) then
                    out[#out + 1] = { set = entry.set, name = name }
                end
            end
        end
    end
    return out
end

--- The names in ONE set, by exact set name. Nil if there is no such set.
---
--- EXACT rather than substring, because this is what the sequential audition
--- walks: a substring that matched two sets would play through both and the
--- owner would have no idea which set the sound they liked came from, which is
--- the one fact they need to write it down.
--- @param set string
--- @return table|nil
function BR.Config.Audio.namesIn(set)
    for _, entry in ipairs(BR.Config.Audio.catalogue) do
        if entry.set == set then return entry.names end
    end
    return nil
end

--- Work out which ONE set a person meant by what they typed.
---
--- ═══ WHY THIS IS NOT JUST namesIn() BEING MADE CASE-INSENSITIVE ═══
---
--- namesIn() resolves an IDENTIFIER and stays exact on purpose: it is what the
--- sequential audition walks, and a loose match that covered two sets would
--- play through both, leaving the owner with a sound they liked and no idea
--- which set to write down. This resolves a TYPED QUERY, which is a different
--- job and is allowed to be forgiving -- because it hands back the catalogue's
--- OWN spelling and every caller prints it, so a near miss is announced rather
--- than acted on quietly.
---
--- THREE ATTEMPTS, IN DECREASING CONFIDENCE:
---
---   1. exact                  HUD_AWARDS
---   2. exact but for case     hud_awards -- GTA's set names SHOUT, and
---                             HUD_FRONTEND_WEAPONS_PICKUPS_SOUNDSET is 37
---                             characters nobody types in caps twice
---   3. ONE substring match    awards -- an answer only when it is the only
---                             one. `HUD` matches thirteen sets, and picking
---                             the first of those would be this tool guessing
---                             about the exact thing it exists to stop people
---                             guessing about.
---
--- SO THE SECOND RETURN IS THE POINT WHEN THE FIRST IS NIL. "no such set" and
--- "you might have meant any of these thirteen" are different answers, and only
--- one of them lets somebody get on with it.
---
--- @param q string|nil
--- @return string|nil   the catalogue's spelling, when exactly one set is meant
--- @return table        the sets it could have meant, in catalogue order
function BR.Config.Audio.resolveSet(q)
    -- A NON-STRING IS A CALLER BUG AND IS ANSWERED RATHER THAN THROWN, because
    -- this is reached from a console command whose arguments may be missing.
    -- The empty string is excluded separately: contains() treats '' as "match
    -- everything", so without this line sets('') would return all 84 and a
    -- bare `brsfx sounds` would resolve to whichever one sorted first.
    if type(q) ~= 'string' or q == '' then return nil, {} end

    local lowered = string.lower(q)
    local byCase
    for _, entry in ipairs(BR.Config.Audio.catalogue) do
        -- ═══ THE EXACT ARM IS SUBSUMED BY THE CASE-BLIND ONE TODAY, AND
        --     MUTATION TESTING SAYS SO OUT LOUD ═══
        --
        -- A mutant that deletes this line SURVIVES the suite, correctly:
        -- anything equal to `q` is also equal to `q` ignoring case, so the
        -- `byCase` arm below catches every query this one does. The two differ
        -- in exactly one situation -- two catalogue sets whose names differ
        -- ONLY in case, where `byCase` would answer with whichever appears
        -- first and this answers with the one that was actually typed. No such
        -- pair exists in the catalogue (checked, not assumed), so today this is
        -- a no-op that also happens to return sooner.
        --
        -- IT STAYS BECAUSE THE COST OF IT BEING WRONG IS SILENCE. The catalogue
        -- is a list somebody adds to, and the day a `Foo`/`FOO` pair lands, the
        -- failure without this line is `brsfx sounds FOO` listing the OTHER
        -- set's names -- names that are then played out of the set the reader
        -- believes they came from, and heard as nothing.
        if entry.set == q then return entry.set, { entry.set } end
        -- REMEMBERED, NOT RETURNED, so that an exact match later in the list
        -- still wins over a case-blind one found earlier.
        if byCase == nil and string.lower(entry.set) == lowered then
            byCase = entry.set
        end
    end
    if byCase then return byCase, { byCase } end

    local near = {}
    for _, s in ipairs(BR.Config.Audio.sets(q)) do near[#near + 1] = s.set end
    if #near == 1 then return near[1], near end
    return nil, near
end

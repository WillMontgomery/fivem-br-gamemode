-- br_audio: native GTA audio banks, and nothing else (#382).
--
-- The airdrop Cargobob's rotor recording, built from assets/audio/cargobob.ogg
-- by tools/build_audio.mjs. br_core/client/airdrop.lua requests the bank
-- `br_sfx/br_cargobob` and plays soundset `br_airdrop_soundset` from the
-- aircraft. tools/test_audio.lua reads both files back.
--
-- ═══ ITS OWN RESOURCE, SO A DEPLOY NEVER RESTARTS IT ═══
--
-- FiveM mounts these data files when the resource starts and unmounts them when
-- it stops, for every connected client, and unloading game data mid-session has
-- crashed clients before. Every deploy ends with `restart br_core`; this
-- resource is not in that list and must not be added to it. A change to these
-- files ships with a SERVER restart, and testers reconnect.
--
-- `ensure br_audio` sits above `ensure br_core` in server.cfg, so the bank is
-- mounted before anything asks for it.
--
-- ═══ NAMES ═══
--
-- The wave pack folder is `br_sfx`: the game indexes wave packs by their first
-- 8 characters, so the folder name must be unique in those. The sound data file
-- is named without its `54.rel` suffix below; the game adds it.

fx_version 'cerulean'
game 'gta5'

name 'br_audio'
description 'FiveM Royale -- native audio banks (the airdrop Cargobob rotor)'

files {
    'br_sfx/br_cargobob.awc',
    'data/br_airdrop_sounds.dat54.rel',
}

data_file 'AUDIO_WAVEPACK' 'br_sfx'
data_file 'AUDIO_SOUNDDATA' 'data/br_airdrop_sounds.dat'

-- World content control: IPLs and the Cayo Perico lobby island.
--
-- MAINLAND: FiveM streams the complete vanilla Los Santos map by default.
-- The famous "holes" appear when content is gated behind a toggle the game
-- normally flips itself -- and almost all of those are things this gamemode
-- deliberately does NOT want:
--
--   North Yankton ('prologue*')       -- a snow film set floating in the sky
--                                        north of the map; loading it puts
--                                        geometry inside the Battle Bus sky.
--   UFO / spaceship props             -- easter eggs, not battlegrounds.
--   Heist/DLC interiors               -- interiors are pointless until loot
--                                        exists inside them (M5 decides).
--
-- So the mainland list below is intentionally EMPTY until a milestone needs
-- something specific. Anything added later gets a comment saying which POI or
-- system needs it -- an IPL nobody can name a reason for is load time and
-- memory spent on nothing.
--
-- CAYO PERICO: the lobby and warmup island. It ships in the game files
-- (build 2189+; this server enforces 3095) but only exists when a script
-- turns it on -- the island content itself is toggled by the ISLAND_HOPPER
-- switch, exactly as the Cayo heist does it, with the IPL set below giving it
-- terrain, the airstrip, docks and the mansion. The lobby lives there; the
-- Battle Bus departs from its airstrip (M3); and once a match is PLAYING over
-- Los Santos the island is switched off to give its streaming budget back.

local ISLAND_HOPPER   = 0x9A9D1BA639675CF1  -- _SET_ISLAND_HOPPER_ENABLED
local ISLAND_PATHS    = 0xF74B1FFA4A15FBEA  -- island path nodes on/off

-- The island sits ~7km south-east of Los Santos. Everything position-gated
-- below keys off this point.
local ISLAND_CENTRE   = vector3(4840.6, -5174.4, 2.0)
local NEAR_ISLAND     = 2200.0   -- island is ~1.5km across; margin for the bus climb-out

-- Mainland IPLs. Empty on purpose -- see the header before adding anything.
local MAINLAND_IPLS = {}

-- The full Cayo Perico set: terrain + LODs, airstrip, beach, docks, tower,
-- mansion, and the quadrant placement groups. Sourced from the known-good
-- community island loaders; requested once and left requested -- the
-- ISLAND_HOPPER switch is what actually creates/destroys the island content,
-- so toggling that is the cheap, R*-sanctioned on/off.
local ISLAND_IPLS = {
    'h4_mph4_terrain_01_grass_0', 'h4_mph4_terrain_01_grass_1',
    'h4_mph4_terrain_02_grass_0', 'h4_mph4_terrain_02_grass_1',
    'h4_mph4_terrain_02_grass_2', 'h4_mph4_terrain_02_grass_3',
    'h4_mph4_terrain_04_grass_0', 'h4_mph4_terrain_04_grass_1',
    'h4_mph4_terrain_05_grass_0', 'h4_mph4_terrain_06_grass_0',
    'h4_islandx_terrain_01', 'h4_islandx_terrain_01_lod', 'h4_islandx_terrain_01_slod',
    'h4_islandx_terrain_02', 'h4_islandx_terrain_02_lod', 'h4_islandx_terrain_02_slod',
    'h4_islandx_terrain_03', 'h4_islandx_terrain_03_lod',
    'h4_islandx_terrain_04', 'h4_islandx_terrain_04_lod', 'h4_islandx_terrain_04_slod',
    'h4_islandx_terrain_05', 'h4_islandx_terrain_05_lod', 'h4_islandx_terrain_05_slod',
    'h4_islandx_terrain_06', 'h4_islandx_terrain_06_lod', 'h4_islandx_terrain_06_slod',
    'h4_islandx_terrain_props_05_a', 'h4_islandx_terrain_props_05_a_lod',
    'h4_islandx_terrain_props_05_b', 'h4_islandx_terrain_props_05_b_lod',
    'h4_islandx_terrain_props_05_c', 'h4_islandx_terrain_props_05_c_lod',
    'h4_islandx_terrain_props_05_d', 'h4_islandx_terrain_props_05_d_lod',
    'h4_islandx_terrain_props_05_d_slod',
    'h4_islandx_terrain_props_05_e', 'h4_islandx_terrain_props_05_e_lod',
    'h4_islandx_terrain_props_05_e_slod',
    'h4_islandx_terrain_props_05_f', 'h4_islandx_terrain_props_05_f_lod',
    'h4_islandx_terrain_props_05_f_slod',
    'h4_islandx_terrain_props_06_a', 'h4_islandx_terrain_props_06_a_lod',
    'h4_islandx_terrain_props_06_a_slod',
    'h4_islandx_terrain_props_06_b', 'h4_islandx_terrain_props_06_b_lod',
    'h4_islandx_terrain_props_06_b_slod',
    'h4_islandx_terrain_props_06_c', 'h4_islandx_terrain_props_06_c_lod',
    'h4_islandx_terrain_props_06_c_slod',
    'h4_mph4_terrain_01', 'h4_mph4_terrain_01_long_0',
    'h4_mph4_terrain_02', 'h4_mph4_terrain_03', 'h4_mph4_terrain_04',
    'h4_mph4_terrain_05', 'h4_mph4_terrain_06', 'h4_mph4_terrain_06_strm_0',
    'h4_mph4_terrain_lod',
    'h4_mph4_terrain_occ_00', 'h4_mph4_terrain_occ_01', 'h4_mph4_terrain_occ_02',
    'h4_mph4_terrain_occ_03', 'h4_mph4_terrain_occ_04', 'h4_mph4_terrain_occ_05',
    'h4_mph4_terrain_occ_06', 'h4_mph4_terrain_occ_07', 'h4_mph4_terrain_occ_08',
    'h4_mph4_terrain_occ_09',
    'h4_boatblockers', 'h4_islandx',
    'h4_islandx_disc_strandedshark', 'h4_islandx_disc_strandedshark_lod',
    'h4_islandx_disc_strandedwhale', 'h4_islandx_disc_strandedwhale_lod',
    'h4_islandx_props', 'h4_islandx_props_lod', 'h4_islandx_sea_mines',
    'h4_mph4_island', 'h4_mph4_island_long_0', 'h4_mph4_island_strm_0',
    'h4_aa_guns', 'h4_aa_guns_lod',
    'h4_beach', 'h4_beach_bar_props', 'h4_beach_lod',
    'h4_beach_party', 'h4_beach_party_lod',
    'h4_beach_props', 'h4_beach_props_lod', 'h4_beach_props_party',
    'h4_beach_props_slod', 'h4_beach_slod',
    'h4_islandairstrip', 'h4_islandairstrip_doorsclosed',
    'h4_islandairstrip_doorsclosed_lod',
    'h4_islandairstrip_hangar_props', 'h4_islandairstrip_hangar_props_lod',
    'h4_islandairstrip_hangar_props_slod',
    'h4_islandairstrip_lod', 'h4_islandairstrip_props',
    'h4_islandairstrip_propsb', 'h4_islandairstrip_propsb_lod',
    'h4_islandairstrip_propsb_slod',
    'h4_islandairstrip_props_lod', 'h4_islandairstrip_props_slod',
    'h4_islandairstrip_slod',
    'h4_islandxcanal_props', 'h4_islandxcanal_props_lod', 'h4_islandxcanal_props_slod',
    'h4_islandxdock', 'h4_islandxdock_lod',
    'h4_islandxdock_props', 'h4_islandxdock_props_2', 'h4_islandxdock_props_2_lod',
    'h4_islandxdock_props_2_slod', 'h4_islandxdock_props_lod',
    'h4_islandxdock_props_slod', 'h4_islandxdock_slod', 'h4_islandxdock_water_hatch',
    'h4_islandxtower', 'h4_islandxtower_lod', 'h4_islandxtower_slod',
    'h4_islandxtower_veg', 'h4_islandxtower_veg_lod', 'h4_islandxtower_veg_slod',
    'h4_islandx_barrack_hatch', 'h4_islandx_barrack_props',
    'h4_islandx_barrack_props_lod', 'h4_islandx_barrack_props_slod',
    'h4_islandx_checkpoint', 'h4_islandx_checkpoint_lod',
    'h4_islandx_checkpoint_props', 'h4_islandx_checkpoint_props_lod',
    'h4_islandx_checkpoint_props_slod',
    'h4_islandx_maindock', 'h4_islandx_maindock_lod',
    'h4_islandx_maindock_props', 'h4_islandx_maindock_props_2',
    'h4_islandx_maindock_props_2_lod', 'h4_islandx_maindock_props_2_slod',
    'h4_islandx_maindock_props_lod', 'h4_islandx_maindock_props_slod',
    'h4_islandx_maindock_slod',
    'h4_islandx_mansion', 'h4_islandx_mansion_b', 'h4_islandx_mansion_b_lod',
    'h4_islandx_mansion_b_side_fence', 'h4_islandx_mansion_b_slod',
    'h4_islandx_mansion_entrance_fence', 'h4_islandx_mansion_guardfence',
    'h4_islandx_mansion_lights',
    'h4_islandx_mansion_lockup_01', 'h4_islandx_mansion_lockup_01_lod',
    'h4_islandx_mansion_lockup_02', 'h4_islandx_mansion_lockup_02_lod',
    'h4_islandx_mansion_lockup_03', 'h4_islandx_mansion_lockup_03_lod',
    'h4_islandx_mansion_lod', 'h4_islandx_mansion_office',
    'h4_islandx_mansion_office_lod',
    'h4_islandx_mansion_props', 'h4_islandx_mansion_props_lod',
    'h4_islandx_mansion_props_slod', 'h4_islandx_mansion_slod',
    'h4_islandx_mansion_vault', 'h4_islandx_mansion_vault_lod',
    'h4_island_padlock_props', 'h4_mansion_gate_closed', 'h4_mansion_remains_cage',
    'h4_mph4_airstrip', 'h4_mph4_airstrip_interior_0_airstrip_hanger',
    'h4_mph4_beach', 'h4_mph4_dock', 'h4_mph4_island_lod',
    'h4_mph4_island_ne_placement', 'h4_mph4_island_nw_placement',
    'h4_mph4_island_se_placement', 'h4_mph4_island_sw_placement',
    'h4_mph4_mansion', 'h4_mph4_mansion_b', 'h4_mph4_mansion_b_strm_0',
    'h4_mph4_mansion_strm_0', 'h4_mph4_wtowers',
    'h4_ne_ipl_00', 'h4_ne_ipl_00_lod', 'h4_ne_ipl_00_slod',
    'h4_ne_ipl_01', 'h4_ne_ipl_01_lod', 'h4_ne_ipl_01_slod',
    'h4_ne_ipl_02', 'h4_ne_ipl_02_lod', 'h4_ne_ipl_02_slod',
    'h4_ne_ipl_03', 'h4_ne_ipl_03_lod', 'h4_ne_ipl_03_slod',
    'h4_ne_ipl_04', 'h4_ne_ipl_04_lod', 'h4_ne_ipl_04_slod',
    'h4_ne_ipl_05', 'h4_ne_ipl_05_lod', 'h4_ne_ipl_05_slod',
    'h4_ne_ipl_06', 'h4_ne_ipl_06_lod', 'h4_ne_ipl_06_slod',
    'h4_ne_ipl_07', 'h4_ne_ipl_07_lod', 'h4_ne_ipl_07_slod',
    'h4_ne_ipl_08', 'h4_ne_ipl_08_lod', 'h4_ne_ipl_08_slod',
    'h4_ne_ipl_09', 'h4_ne_ipl_09_lod', 'h4_ne_ipl_09_slod',
    'h4_nw_ipl_00', 'h4_nw_ipl_00_lod', 'h4_nw_ipl_00_slod',
    'h4_nw_ipl_01', 'h4_nw_ipl_01_lod', 'h4_nw_ipl_01_slod',
    'h4_nw_ipl_02', 'h4_nw_ipl_02_lod', 'h4_nw_ipl_02_slod',
    'h4_nw_ipl_03', 'h4_nw_ipl_03_lod', 'h4_nw_ipl_03_slod',
    'h4_nw_ipl_04', 'h4_nw_ipl_04_lod', 'h4_nw_ipl_04_slod',
    'h4_nw_ipl_05', 'h4_nw_ipl_05_lod', 'h4_nw_ipl_05_slod',
    'h4_nw_ipl_06', 'h4_nw_ipl_06_lod', 'h4_nw_ipl_06_slod',
    'h4_nw_ipl_07', 'h4_nw_ipl_07_lod', 'h4_nw_ipl_07_slod',
    'h4_nw_ipl_08', 'h4_nw_ipl_08_lod', 'h4_nw_ipl_08_slod',
    'h4_nw_ipl_09', 'h4_nw_ipl_09_lod', 'h4_nw_ipl_09_slod',
    'h4_se_ipl_00', 'h4_se_ipl_00_lod', 'h4_se_ipl_00_slod',
    'h4_se_ipl_01', 'h4_se_ipl_01_lod', 'h4_se_ipl_01_slod',
    'h4_se_ipl_02', 'h4_se_ipl_02_lod', 'h4_se_ipl_02_slod',
    'h4_se_ipl_03', 'h4_se_ipl_03_lod', 'h4_se_ipl_03_slod',
    'h4_se_ipl_04', 'h4_se_ipl_04_lod', 'h4_se_ipl_04_slod',
    'h4_se_ipl_05', 'h4_se_ipl_05_lod', 'h4_se_ipl_05_slod',
    'h4_se_ipl_06', 'h4_se_ipl_06_lod', 'h4_se_ipl_06_slod',
    'h4_se_ipl_07', 'h4_se_ipl_07_lod', 'h4_se_ipl_07_slod',
    'h4_se_ipl_08', 'h4_se_ipl_08_lod', 'h4_se_ipl_08_slod',
    'h4_se_ipl_09', 'h4_se_ipl_09_lod', 'h4_se_ipl_09_slod',
    'h4_sw_ipl_00', 'h4_sw_ipl_00_lod', 'h4_sw_ipl_00_slod',
    'h4_sw_ipl_01', 'h4_sw_ipl_01_lod', 'h4_sw_ipl_01_slod',
    'h4_sw_ipl_02', 'h4_sw_ipl_02_lod', 'h4_sw_ipl_02_slod',
    'h4_sw_ipl_03', 'h4_sw_ipl_03_lod', 'h4_sw_ipl_03_slod',
    'h4_sw_ipl_04', 'h4_sw_ipl_04_lod', 'h4_sw_ipl_04_slod',
    'h4_sw_ipl_05', 'h4_sw_ipl_05_lod', 'h4_sw_ipl_05_slod',
    'h4_sw_ipl_06', 'h4_sw_ipl_06_lod', 'h4_sw_ipl_06_slod',
    'h4_sw_ipl_07', 'h4_sw_ipl_07_lod', 'h4_sw_ipl_07_slod',
    'h4_sw_ipl_08', 'h4_sw_ipl_08_lod', 'h4_sw_ipl_08_slod',
    'h4_sw_ipl_09', 'h4_sw_ipl_09_lod', 'h4_sw_ipl_09_slod',
    'h4_underwater_gate_closed',
    'h4_islandx_placement_01', 'h4_islandx_placement_02', 'h4_islandx_placement_03',
    'h4_islandx_placement_04', 'h4_islandx_placement_05', 'h4_islandx_placement_06',
    'h4_islandx_placement_07', 'h4_islandx_placement_08', 'h4_islandx_placement_09',
    'h4_islandx_placement_10', 'h4_mph4_island_placement',
}

-- ---------------------------------------------------------------- state ---

local islandActive = false   -- what we have applied
local islandWanted = true    -- what the match state says we should have

local function nearIsland()
    return #(GetEntityCoords(PlayerPedId()) - ISLAND_CENTRE) < NEAR_ISLAND
end

--- Flip the island's existence. This is the same switch the Cayo heist flips;
--- everything else (scenarios, path nodes, ambient audio zones) rides along so
--- the island is a place rather than a diorama.
--- @param on boolean
local function applyIsland(on)
    islandActive = on
    Citizen.InvokeNative(ISLAND_HOPPER, 'HeistIsland', on)
    Citizen.InvokeNative(ISLAND_PATHS, on)
    SetScenarioGroupEnabled('Heist_Island_Peds', on)
    SetAmbientZoneListStatePersistent('AZL_DLC_Hei4_Island_Zones', on, true)
    SetAmbientZoneListStatePersistent('AZL_DLC_Hei4_Island_Disabled_Zones', not on, true)

    -- Flatten the deep-ocean swell while the island exists; the lobby sits at
    -- sea level and default swell periodically swallows the beach visually.
    SetDeepOceanScaler(on and 0.0 or 1.0)

    print(('[br_environment] Cayo Perico %s'):format(on and 'enabled' or 'disabled'))
end

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    -- The island exists everywhere EXCEPT a live match: once everyone is
    -- dropping over Los Santos its streaming budget belongs to the mainland.
    -- BUS keeps it -- that is the climb-out over the airstrip.
    islandWanted = d.state ~= BR.MatchState.PLAYING
end)

RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    if payload and payload.match and payload.match.state then
        islandWanted = payload.match.state ~= BR.MatchState.PLAYING
    end
end)

CreateThread(function()
    for _, ipl in ipairs(MAINLAND_IPLS) do RequestIpl(ipl) end
    for _, ipl in ipairs(ISLAND_IPLS) do RequestIpl(ipl) end

    applyIsland(true)   -- the default world is the lobby world

    while true do
        Wait(1000)
        if islandWanted ~= islandActive then
            -- NEVER pull the island out from under the player. Without this,
            -- forcing PLAYING while still standing on the airstrip (brforce,
            -- or M3's stragglers) deletes the ground mid-stand and drops them
            -- into open ocean. The switch waits until they are genuinely away.
            if islandWanted or not nearIsland() then
                applyIsland(islandWanted)
            end
        end
    end
end)

-- The island is ~7km offshore, past the ocean the minimap renders as void.
-- The heist swaps the radar to a fake interior centred on the island; without
-- this the minimap is empty blue and the pause map shows the player standing
-- in open sea. Per-frame by necessity (the natives are ThisFrame), but gated
-- so the cost exists only while actually standing on the lobby island.
CreateThread(function()
    while true do
        if islandActive and nearIsland() then
            SetRadarAsExteriorThisFrame()
            -- GetHashKey, not a backtick literal: backtick hashes are a FiveM
            -- Lua extension that plain luac (the verify gate) cannot parse.
            SetRadarAsInteriorThisFrame(GetHashKey('h4_fake_islandx'),
                4700.0, -5145.0, 0, 0)
            Wait(0)
        else
            Wait(1000)
        end
    end
end)

-- The character roster.
--
-- VANILLA MODELS ONLY, which is the project's standing rule and also the
-- reason this is a curated list rather than a dump of every ped in the game.
-- GTA ships hundreds; most of them are pedestrians who look like nothing in
-- particular, a good number are children or animals, and a few are story
-- characters whose models behave oddly outside their missions. A player
-- scrolling four hundred names is not choosing, they are giving up.
--
-- WHAT MAKES THE CUT: a distinct silhouette at six feet, no story baggage, and
-- a name a person would recognise as a description of the character rather
-- than as an internal asset id.
--
-- NO FREEMODE MODELS. mp_m_freemode_01 and its sibling are the customisable
-- ones, and they spawn BALD AND NAKED -- they are a character CREATOR, not a
-- character, and every component (head, hair, torso, legs, feet) has to be set
-- or the player is looking at a mannequin. That is a whole feature with its
-- own screen, and shipping it half-done would be worse than not having it.
--
-- `id` is what travels on the wire and what is stored in kvp; `model` is the
-- ped model name, hashed at use. The two are kept separate on purpose: a model
-- can be swapped out later without invalidating every player's saved choice.

BR = BR or {}

BR.Config.Peds = {
    -- The default is first, and it is deliberately the most ordinary-looking
    -- one: a player who never opens the locker should look like somebody who
    -- belongs in the world, not like a choice nobody made.
    { id = 'streetguy',  name = 'Street',      model = 'a_m_y_stwhi_01' },
    { id = 'streetgirl', name = 'Downtown',    model = 'a_f_y_hipster_01' },
    { id = 'hiker',      name = 'Hiker',       model = 'a_m_y_hiker_01' },
    { id = 'runner',     name = 'Runner',      model = 'a_f_y_runner_01' },
    { id = 'biker',      name = 'Biker',       model = 'g_m_y_lost_01' },
    { id = 'mechanic',   name = 'Mechanic',    model = 's_m_y_xmech_02' },
    { id = 'pilot',      name = 'Pilot',       model = 's_m_m_pilot_01' },
    { id = 'diver',      name = 'Diver',       model = 's_m_y_uscg_01' },
    { id = 'trooper',    name = 'Trooper',     model = 's_m_y_swat_01' },
    { id = 'agent',      name = 'Agent',       model = 's_m_m_fiboffice_01' },
    { id = 'chef',       name = 'Chef',        model = 's_m_y_chef_01' },
    { id = 'clown',      name = 'Clown',       model = 's_m_y_clown_01' },
    { id = 'juggalo',    name = 'Juggalo',     model = 'g_m_y_pologoon_01' },
    { id = 'surfer',     name = 'Surfer',      model = 'a_m_y_beach_02' },
    { id = 'exec',       name = 'Executive',   model = 'a_m_y_business_01' },
    { id = 'yeti',       name = 'Yeti',        model = 'u_m_y_baygor' },

    -- ------------------------------------------------------- second pass ---
    --
    -- MORE, AND MORE OF THEM WOMEN (owner, 2026-08-09). The first sixteen were
    -- twelve men and four women, and half of them were a costume -- so a
    -- player who wanted to look like an ordinary person had four choices and a
    -- player who wanted to look like an ordinary WOMAN had two.
    --
    -- Still nothing exotic: the strange ones are the market's job. These are
    -- people you would walk past in Los Santos.
    --
    -- THE BALANCE CONSTRAINT, stated once for the whole list: hitboxes are
    -- per-bone and validated server-side, so no model here is a smaller
    -- target. What WOULD be an advantage is a model that is harder to SEE --
    -- unusually dark clothing, a silhouette that breaks up in foliage -- and
    -- nothing below is picked for that.
    --
    -- EVERY NAME IS HAND-TYPED, so some of them will be wrong. Two already
    -- were (s_f_y_waitress_01 and a_m_y_tourist_01 "never streamed" -- user,
    -- 2026-08-09) and they are gone. The locker now VERIFIES the whole list at
    -- startup and drops anything the game does not have, so a typo costs a
    -- line in the console rather than a character that cannot be picked.

    -- Women, ordinary
    { id = 'fitness',    name = 'Athlete',     model = 'a_f_y_fitness_01' },
    { id = 'fitness2',   name = 'Trainer',     model = 'a_f_y_fitness_02' },
    { id = 'yoga',       name = 'Yoga',        model = 'a_f_y_yoga_01' },
    { id = 'tennis',     name = 'Tennis',      model = 'a_f_y_tennis_01' },
    { id = 'skatergirl', name = 'Skater',      model = 'a_f_y_skater_01' },
    { id = 'hipster2',   name = 'Eastside',    model = 'a_f_y_hipster_02' },
    { id = 'hipster3',   name = 'Westside',    model = 'a_f_y_hipster_03' },
    { id = 'vinewoodf',  name = 'Vinewood',    model = 'a_f_y_vinewood_01' },
    { id = 'vinewoodf2', name = 'Boulevard',   model = 'a_f_y_vinewood_02' },
    { id = 'bevhillsf',  name = 'Uptown',      model = 'a_f_y_bevhills_01' },
    { id = 'bevhillsf2', name = 'Rodeo',       model = 'a_f_y_bevhills_02' },
    { id = 'businessf',  name = 'Analyst',     model = 'a_f_y_business_01' },
    { id = 'businessf2', name = 'Broker',      model = 'a_f_y_business_02' },
    { id = 'beachf',     name = 'Beachgoer',   model = 'a_f_y_beach_01' },
    { id = 'genhot',     name = 'Local',       model = 'a_f_y_genhot_01' },
    { id = 'soucentf',   name = 'Southside',   model = 'a_f_y_soucent_01' },
    { id = 'eastsaf',    name = 'Sandy',       model = 'a_f_y_eastsa_01' },
    { id = 'eastsaf2',   name = 'Grapeseed',   model = 'a_f_y_eastsa_02' },
    { id = 'indianf',    name = 'Commuter',    model = 'a_f_y_indian_01' },
    { id = 'ranger_f',   name = 'Ranger',      model = 's_f_y_ranger_01' },
    { id = 'scrubs',     name = 'Medic',       model = 's_f_y_scrubs_01' },
    { id = 'shopf',      name = 'Retail',      model = 's_f_y_shop_low' },
    { id = 'shopf2',     name = 'Boutique',    model = 's_f_y_shop_mid' },
    { id = 'airhostess', name = 'Cabin crew',  model = 's_f_y_airhostess_01' },
    { id = 'baywatchf',  name = 'Lifeguard',   model = 's_f_y_baywatch_01' },
    { id = 'factoryf',   name = 'Factory',     model = 's_f_y_factory_01' },
    { id = 'busif',      name = 'Office',      model = 'a_f_m_business_02' },
    { id = 'bevhillsmf', name = 'Hills',       model = 'a_f_m_bevhills_01' },
    { id = 'soucentmf',  name = 'Chamberlain', model = 'a_f_m_soucent_01' },

    -- Men, ordinary
    { id = 'jogger',     name = 'Jogger',      model = 'a_m_y_runner_01' },
    { id = 'skater',     name = 'Skater',      model = 'a_m_y_skater_01' },
    { id = 'skater2',    name = 'Boarder',     model = 'a_m_y_skater_02' },
    { id = 'hipsterm',   name = 'Hipster',     model = 'a_m_y_hipster_01' },
    { id = 'hipsterm2',  name = 'Vinyl',       model = 'a_m_y_hipster_02' },
    { id = 'golfer',     name = 'Golfer',      model = 'a_m_y_golfer_01' },
    { id = 'cyclist',    name = 'Cyclist',     model = 'a_m_y_roadcyc_01' },
    { id = 'downtown',   name = 'Downtown',    model = 'a_m_y_downtown_01' },
    { id = 'bevhillsm',  name = 'Uptown',      model = 'a_m_y_bevhills_01' },
    { id = 'vinewoodm',  name = 'Vinewood',    model = 'a_m_y_vinewood_01' },
    { id = 'stwhi2',     name = 'Eastside',    model = 'a_m_y_stwhi_02' },
    { id = 'stbla',      name = 'Strawberry',  model = 'a_m_y_stbla_01' },
    { id = 'soucentm',   name = 'Southside',   model = 'a_m_y_soucent_01' },
    { id = 'soucentm3',  name = 'Grove',       model = 'a_m_y_soucent_03' },
    { id = 'latino',     name = 'Rancho',      model = 'a_m_y_latino_01' },
    { id = 'polynesian', name = 'Islander',    model = 'a_m_y_polynesian_01' },
    { id = 'salton',     name = 'Angler',      model = 'a_m_m_salton_01' },
    { id = 'farmer',     name = 'Farmhand',    model = 'a_m_m_farmer_01' },
    { id = 'muscl',      name = 'Muscle',      model = 'a_m_y_musclbeac_01' },
    { id = 'sunbathe',   name = 'Sunbather',   model = 'a_m_y_sunbathe_01' },
    { id = 'construct',  name = 'Construction',model = 's_m_y_construct_01' },
    { id = 'dockwork',   name = 'Dockworker',  model = 's_m_y_dockwork_01' },
    { id = 'ranger_m',   name = 'Warden',      model = 's_m_y_ranger_01' },
    { id = 'medicm',     name = 'Paramedic',   model = 's_m_m_paramedic_01' },
    { id = 'fireman',    name = 'Firefighter', model = 's_m_y_fireman_01' },
    { id = 'marine',     name = 'Soldier',     model = 's_m_y_marine_01' },
    { id = 'valet',      name = 'Valet',       model = 's_m_y_valet_01' },
    { id = 'barman',     name = 'Bartender',   model = 's_m_y_barman_01' },
    { id = 'trucker',    name = 'Driver',      model = 's_m_m_trucker_01' },
    { id = 'garbage',    name = 'Sanitation',  model = 's_m_y_garbage_01' },
    { id = 'busboy',     name = 'Busser',      model = 's_m_y_busboy_01' },
    { id = 'autoshop',   name = 'Grease',      model = 's_m_y_autopsy_01' },
}

--- @param id string|nil
--- @return table  never nil -- an unknown id falls back to the first entry
function BR.PedById(id)
    for _, p in ipairs(BR.Config.Peds) do
        if p.id == id then return p end
    end
    return BR.Config.Peds[1]
end

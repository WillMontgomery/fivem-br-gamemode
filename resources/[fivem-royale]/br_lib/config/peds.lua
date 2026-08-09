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

    -- SECOND PASS (owner, 2026-08-09: "how many more can we add? Let's not
    -- get exotic -- those will be in the market"). Everything below is an
    -- ordinary person in ordinary clothes: the roster was sixteen and skewed
    -- male, and half of it was a costume. These are the everyday end, chosen
    -- to widen who a player can see themselves as rather than to be
    -- memorable. The strange ones are the market's job.
    --
    -- Balance kept in mind and stated plainly: silhouette is what matters in
    -- a firefight, so nothing here is unusually small, unusually dark, or
    -- easier to lose in foliage than what is already above. Hitboxes are
    -- per-bone and server-validated, so a model cannot be a smaller target --
    -- but a model that is HARDER TO SEE would be an advantage, and that is
    -- the line these are picked against.
    { id = 'jogger',     name = 'Jogger',      model = 'a_m_y_runner_01' },
    { id = 'skater',     name = 'Skater',      model = 'a_m_y_skater_01' },
    { id = 'skatergirl', name = 'Skater II',   model = 'a_f_y_skater_01' },
    { id = 'hipster',    name = 'Hipster',     model = 'a_m_y_hipster_01' },
    { id = 'yoga',       name = 'Yoga',        model = 'a_f_y_yoga_01' },
    { id = 'tourist',    name = 'Tourist',     model = 'a_m_y_tourist_01' },
    { id = 'golfer',     name = 'Golfer',      model = 'a_m_y_golfer_01' },
    { id = 'genstreet',  name = 'Local',       model = 'a_f_y_genhot_01' },
    { id = 'vinewood',   name = 'Vinewood',    model = 'a_f_y_vinewood_01' },
    { id = 'bevhills',   name = 'Uptown',      model = 'a_m_y_bevhills_01' },
    { id = 'construct',  name = 'Construction',model = 's_m_y_construct_01' },
    { id = 'dockwork',   name = 'Dockworker',  model = 's_m_y_dockwork_01' },
    { id = 'ranger',     name = 'Ranger',      model = 's_m_y_ranger_01' },
    { id = 'medic',      name = 'Paramedic',   model = 's_m_m_paramedic_01' },
    { id = 'fire',       name = 'Firefighter', model = 's_m_y_fireman_01' },
    { id = 'armyfat',    name = 'Soldier',     model = 's_m_y_marine_01' },
    { id = 'valet',      name = 'Valet',       model = 's_m_y_valet_01' },
    { id = 'barman',     name = 'Bartender',   model = 's_m_y_barman_01' },
    { id = 'waitress',   name = 'Server',      model = 's_f_y_waitress_01' },
    { id = 'shopgirl',   name = 'Retail',      model = 's_f_y_shop_low' },
    { id = 'busdriver',  name = 'Driver',      model = 's_m_m_trucker_01' },
    { id = 'farmer',     name = 'Farmhand',    model = 'a_m_m_farmer_01' },
    { id = 'fisher',     name = 'Angler',      model = 'a_m_m_salton_01' },
    { id = 'sunbather',  name = 'Beachgoer',   model = 'a_f_y_beach_01' },
}

--- @param id string|nil
--- @return table  never nil -- an unknown id falls back to the first entry
function BR.PedById(id)
    for _, p in ipairs(BR.Config.Peds) do
        if p.id == id then return p end
    end
    return BR.Config.Peds[1]
end

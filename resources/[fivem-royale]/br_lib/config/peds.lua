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
}

--- @param id string|nil
--- @return table  never nil -- an unknown id falls back to the first entry
function BR.PedById(id)
    for _, p in ipairs(BR.Config.Peds) do
        if p.id == id then return p end
    end
    return BR.Config.Peds[1]
end

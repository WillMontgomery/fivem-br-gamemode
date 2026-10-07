-- Season 2 terminals (#396), round 5: GEAR UP, the server half.
--
-- THE OWNER, 2026-10-06 (he named it): "add a new one which allows the user to
-- give something to themselves - anything of their choice - any inventory
-- item or weapon which is not a heavy sniper or machine gun. This should be a
-- selection from a dropdown list within the tool, and the item they choose
-- can also be given to a teammate, or for a charge of 200 volts the whole
-- team can get them. If they choose a consumable, they are given the maxCarry
-- quantity of that item."
--
--   THE ITEM   option `item`: one of the list br_lib/config/terminals.lua
--              builds from the weapons and loot configs as it loads (`gearUp`
--              says what is left out and why). The door takes only a listed
--              one (BR.Terminal.options).
--   WHO        option `who`: 'self' (free), 'mate' (free; option `mate`, a
--              standing teammate the state listed, BR.Terminal.mates) or
--              'squad' (the row's `costBy`: 200 Volts) -- the last two in a
--              squad match alone, `bad_option` outside one.
--   HOW MUCH   a weapon: one, as a crate's is -- a full magazine (its `clip`)
--              and, through BR.Inv.give's found-gun rule, one spare. A
--              consumable or a throwable: a full stack (its `carryMax`, the
--              config's name for "maxCarry", or for one with no carry ceiling
--              -- the two shields -- its `maxStack`), clamped to what the
--              player may still carry and has room for (BR.Inv.roomFor).
--   THE DOOR   EVERYTHING THROUGH THE INVENTORY'S OWN API: BR.Inv.roomFor
--              asks, BR.Inv.give puts it in a slot and sends the INV_SET.
--              So a granted gun is the server's own slot from the moment it
--              exists -- the shot validator's held check and the weapon
--              strip's `ourWeapon` both read that slot -- and nothing here
--              hands a ped a weapon. Nothing is ever displaced: a player with
--              no room is refused, spending nothing, rather than having what
--              they carry thrown on the floor.
--
-- ═══ WHO GETS IT, AND WHEN IT IS REFUSED ═══
--
-- ONLY A PLAYER WHO IS STANDING (ALIVE): a downed one cannot reach their
-- inventory (server/inventory.lua's LIVE), and one in the air or out has
-- nowhere useful for it. Every refusal spends nothing, the Volts included,
-- and is asked again as the load ends (the door's rule), so a teammate who
-- went down or filled their bag in the seconds between gives everything back.
--
--   self    the runner: gear_standing, gear_full, gear_no_room
--   mate    that teammate: gear_no_mate (not a standing teammate now),
--           gear_full_mate, gear_no_room_mate
--   squad   everyone in the squad standing, the runner included. One already
--           carrying as many as they may is skipped -- they have it; ANY with
--           no room refuses the run (gear_no_room_squad), so 200 Volts never
--           buy a squad grant that leaves somebody out; everyone skipped is
--           gear_full_squad, and nobody standing gear_standing.
--
-- NOTHING TIMED, NOTHING ON ANYBODY'S HUD: it is instant, so there is no
-- persistent notice. The lobby hears notice_action (`gear_up_description`
-- names no item); each teammate who got it from somebody else's run is told
-- who and what (`gear_up_received`), after it. No client half.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function copy() return BR.Config.Terminals.copy end

--- Throwables are weapons by id (BR.Config.WeaponById), so this tells them
--- apart, once.
local THROWN = {}
for _, t in ipairs(BR.Config.Throwables or {}) do THROWN[t.id] = true end

--- The stack Gear Up hands over for an item, at its full count, or nil for an
--- id that is no item. A copy each time: nothing here is ever a config table.
--- @param id string
--- @return table|nil
function T.gearStack(id)
    if type(id) ~= 'string' then return nil end
    local w = BR.Config.WeaponById and BR.Config.WeaponById[id] or nil
    if w and THROWN[id] then
        return { item = id, kind = BR.ItemKind.THROWABLE, rarity = w.rarity,
                 count = math.max(1, math.floor(tonumber(w.maxStack) or 1)) }
    end
    if w then
        -- A FIREARM COMES LOADED, as a crate's does (its `clip`); melee has no
        -- magazine and carries none (BR.Inv.give keeps the two apart).
        return { item = id, kind = BR.ItemKind.WEAPON, rarity = w.rarity, count = 1,
                 clip = (not w.melee) and w.clip or nil }
    end
    local c = BR.Config.ConsumableById and BR.Config.ConsumableById[id] or nil
    if c then
        local n = tonumber(c.carryMax) or tonumber(c.maxStack) or 1
        return { item = id, kind = BR.ItemKind.CONSUMABLE, rarity = c.rarity,
                 count = math.max(1, math.floor(n)) }
    end
    return nil
end

--- What a toast calls the stack someone got: its name, or "3 Med Kits".
local function described(stack)
    local def = (BR.Config.WeaponById and BR.Config.WeaponById[stack.item])
        or (BR.Config.ConsumableById and BR.Config.ConsumableById[stack.item]) or {}
    local label = def.label or stack.item
    if (stack.count or 1) > 1 then
        return ('%d %s'):format(stack.count, def.plural or (label .. 's'))
    end
    return label
end

local function standing(src)
    local e = BR.Roster.get(src)
    return e ~= nil and e.state == BR.PlayerState.ALIVE, e
end

--- Who this run hands the item to and how many each takes, or nil and why.
--- @return table[]|nil plan  { { src, stack } }
--- @return string|nil why
local function plan(src, opts)
    local m, _, key = T.whereIs(src)
    if not m then return nil, 'unavailable' end
    local full = T.gearStack(opts and opts.item)
    if not full then return nil, 'bad_option' end
    local who = opts.who or 'self'
    if (who == 'mate' or who == 'squad') and not T.squadMatch(src) then return nil, 'bad_option' end

    local function sized(to)
        local n, why = BR.Inv.roomFor(to, full)
        if n <= 0 then return nil, why end
        local st = {}
        for k, v in pairs(full) do st[k] = v end
        st.count = n
        return st, nil
    end

    if who == 'self' then
        if not standing(src) then return nil, 'gear_standing' end
        local st, why = sized(src)
        if not st then return nil, why == 'carrymax' and 'gear_full' or 'gear_no_room' end
        return { { src = src, stack = st } }, nil
    end

    if who == 'mate' then
        local to = tonumber(opts.mate)
        local mate = false
        for _, row in ipairs(T.mates(src)) do
            if tonumber(row.id) == to then mate = true end
        end
        if not mate then return nil, 'gear_no_mate' end
        local st, why = sized(to)
        if not st then return nil, why == 'carrymax' and 'gear_full_mate' or 'gear_no_room_mate' end
        return { { src = to, stack = st } }, nil
    end

    if who ~= 'squad' then return nil, 'bad_option' end
    local out, anyone = {}, false
    for _, s in ipairs(T.squadOf(m, key)) do
        if standing(s) then
            anyone = true
            local st, why = sized(s)
            if st then
                out[#out + 1] = { src = s, stack = st }
            elseif why ~= 'carrymax' then
                return nil, 'gear_no_room_squad'
            end
        end
    end
    if not anyone then return nil, 'gear_standing' end
    if #out == 0 then return nil, 'gear_full_squad' end
    return out, nil
end

T.FUNCTIONS.gear_up = {
    -- LISTED, IT IS AVAILABLE IN A MATCH: whether this item fits this player
    -- is a question about choices the card has not made yet, and the run
    -- answers it before anything is spent. A dev session (typed facts, for
    -- walking the app) is never refused.
    refuse = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if opts == nil then return nil end
        local _, why = plan(src, opts)
        return why
    end,
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Gear Up ran on the dev terminal '
                    .. 'with nobody to give it to'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        -- ASKED AGAIN HERE, not taken from `refuse`: the dev command runs this
        -- without the door.
        local list, why = plan(src, opts or {})
        if not list then return { ok = false, code = why } end
        local given = {}
        for _, p in ipairs(list) do
            local ok = BR.Inv.give(p.src, p.stack)
            if ok then given[#given + 1] = p end
        end
        if #given == 0 then return { ok = false, code = 'gear_no_room' } end
        local runner = BR.Roster.get(src)
        print(('[br_core] terminals: Gear Up by %s (%d): %s to %d player(s)')
            :format(runner and runner.name or '?', src, tostring(opts and opts.item), #given))
        -- EACH TEAMMATE WHO GOT IT FROM THIS RUN IS TOLD WHO AND WHAT, after
        -- "has redeemed their special power: Gear Up..." -- never the runner,
        -- who chose it.
        return { ok = true, code = 'done', after = function()
            for _, p in ipairs(given) do
                if p.src ~= src then
                    BR.Server.notify(p.src, TS.line(TS.pick(copy(), 'gear_up_received', T.squadMatch(p.src) == true),
                        runner and runner.name or GetPlayerName(src), described(p.stack)), 'success', { ms = 8000 })
                end
            end
        end }
    end,
}

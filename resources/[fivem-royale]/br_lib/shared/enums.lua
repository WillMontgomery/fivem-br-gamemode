-- Shared enumerations. Loaded first; every other br_lib file assumes BR exists.

BR = BR or {}

--- Match lifecycle. The server owns transitions; clients only ever mirror them.
BR.MatchState = {
    WAITING = 'waiting', -- not enough players, lobby open
    WARMUP  = 'warmup',  -- countdown running, players on the warmup pad
    BUS     = 'bus',     -- battle bus in flight, players may jump
    PLAYING = 'playing', -- storm active, combat live
    ENDED   = 'ended',   -- winner decided, summary showing
    CLEANUP = 'cleanup', -- tearing down for the next match
}

--- Per-player state inside a match.
BR.PlayerState = {
    LOBBY      = 'lobby',
    WARMUP     = 'warmup',
    BUS        = 'bus',        -- aboard, not yet jumped
    FREEFALL   = 'freefall',   -- jumped, chute not open
    GLIDE      = 'glide',      -- chute open
    ALIVE      = 'alive',      -- landed and fighting
    DBNO       = 'dbno',       -- downed but not out (squads only)
    DEAD       = 'dead',
    SPECTATING = 'spectating',
    LEFT       = 'left',       -- disconnected mid-match
}

--- Loot rarity. Order matters: index is used for weighted rolls and comparisons.
BR.Rarity = {
    COMMON    = 1,
    UNCOMMON  = 2,
    RARE      = 3,
    EPIC      = 4,
    LEGENDARY = 5,
}

--- Single source of truth for rarity presentation. The Lua side uses `rgb` for
--- loot glow markers; the NUI uses `hex` for inventory borders. Keeping both here
--- is what stops the two from drifting apart.
BR.RarityInfo = {
    [BR.Rarity.COMMON]    = { key = 'common',    label = 'Common',    hex = '#B0B0B0', rgb = { 176, 176, 176 }, damageMult = 1.00 },
    [BR.Rarity.UNCOMMON]  = { key = 'uncommon',  label = 'Uncommon',  hex = '#4CD964', rgb = {  76, 217, 100 }, damageMult = 1.06 },
    [BR.Rarity.RARE]      = { key = 'rare',      label = 'Rare',      hex = '#3B9BFF', rgb = {  59, 155, 255 }, damageMult = 1.12 },
    [BR.Rarity.EPIC]      = { key = 'epic',      label = 'Epic',      hex = '#B15BFF', rgb = { 177,  91, 255 }, damageMult = 1.20 },
    [BR.Rarity.LEGENDARY] = { key = 'legendary', label = 'Legendary', hex = '#FFB020', rgb = { 255, 176,  32 }, damageMult = 1.28 },
}

--- What a loot entry / inventory slot actually holds.
BR.ItemKind = {
    WEAPON     = 'weapon',
    AMMO       = 'ammo',
    CONSUMABLE = 'consumable',
    THROWABLE  = 'throwable',
}

--- Ammo pools. Mapped onto GTA's native ammo groups so the engine tracks counts
--- for us rather than us shadowing them.
BR.AmmoType = {
    LIGHT  = 'light',  -- pistols
    SMG    = 'smg',
    MEDIUM = 'medium', -- rifles
    SHELLS = 'shells', -- shotguns
    HEAVY  = 'heavy',  -- snipers / LMG
}

--- Match modes. `squadSize` drives DBNO: solo has no downed state, because there
--- is nobody left who could revive you.
BR.Mode = {
    SOLO  = { key = 'solo',  label = 'Solo',  squadSize = 1, dbno = false },
    SQUAD = { key = 'squad', label = 'Squad', squadSize = 4, dbno = true  },
}

--- Modes are referenced by their string key across the wire and in config
--- (queue requests, Config.Match.defaultMode), so a key -> mode lookup is needed.
--- Without this every call site invents its own if/else chain.
BR.ModeByKey = {}
for _, m in pairs(BR.Mode) do
    BR.ModeByKey[m.key] = m
end

--- Resolve a mode from an untrusted string. Never returns nil: an unknown key
--- from a client falls back to solo rather than crashing the queue handler.
--- @param key string|nil
--- @return table
function BR.ResolveMode(key)
    return BR.ModeByKey[key] or BR.Mode.SOLO
end

--- Storm phase sub-state, returned by BR.StormAt().
BR.StormPhase = {
    PRE       = 'pre',       -- initial hold, before phase 1
    HOLDING   = 'holding',   -- circle static, next circle already revealed
    SHRINKING = 'shrinking', -- interpolating toward the next circle
    FINISHED  = 'finished',  -- final circle collapsed
}

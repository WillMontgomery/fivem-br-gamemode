-- Emotes: the dances a player buys in the Market, puts on the wheel and plays.
--
-- Owner, 2026-10-02 (#215, "Scope v2"): one PR with the complete SOLO system;
-- group emotes are out of scope. Anywhere except the lobby, on foot only. 250
-- Volts each and no free ones -- "an empty wheel is fine". Up to eight on the
-- wheel, managed from the Market. One license-free .ogg per dance, supplied by
-- the owner later.
--
-- ═══ THE GATE IS THE SEASON ═══
--
-- Emotes were dev-mode only behind one line here until #388 (owner,
-- 2026-10-04): they are the first Season 2 feature, and their gate is now the
-- `emotes` row in br_lib/config/seasons.lua. Every server handler, client key,
-- page control and console command asks BR.Season.has('emotes') and nothing
-- else (bremotegrant included: it is exempt from the console-command dev gate
-- for exactly this reason), and tools/check_emote_gate.lua fails the build when
-- one does not, or when anything asks dev mode a second way. verify.sh runs
-- every emote suite at the season before the row's `from` (off) and at `from`
-- (on).
--
-- ═══ ONE ROW SHAPE, WHEREVER THE CLIP COMES FROM ═══
--
-- A base-game dance and a custom one are the same eight fields. A custom pack
-- is a .ycd streamed from a stream-only resource, and its dictionary is the
-- file's name without `.ycd`, so `dict` is the only thing that differs.
--
--   id          'emote_<a-z0-9_>' -- the Market id and the DynamoDB `owned` entry
--   name        what the Market card and the wheel say
--   dict, clip  the animation; /brnativecheck probes that both exist
--   flag        TaskPlayAnim flags. 1 (AF_LOOPING) on every row here: full body,
--               so the legs do not walk. 16 and 32 free the legs and 1024
--               desyncs the ped for everybody else (fivem#3733), so a row
--               carrying any of them is refused below
--   durationMs  how long a dance lasts. The stop is COMPUTED at tStart +
--               durationMs and never messaged. Once a track exists this is the
--               track's length
--   track       'emotes/<id>.ogg', the file's path under br_ui/ui (copied there
--               from ui-src/public/emotes by the UI build). EVERY STARTER FILE IS
--               ABSENT TODAY: the page marks a missing file once and the dance
--               plays in silence and still stops at durationMs. Supplying a
--               track is: drop the file in, rebuild, set durationMs
--   price       Volts. 250 (owner, 2026-10-02)
--
-- THE STARTER SET HAS NO TRACK FILES AND NO MEASURED CLIP LENGTHS. Every dict
-- and clip below is in the DurtyFree animDictsCompact dump (read 2026-10-02),
-- none has been watched looping in game yet, and 12 s is a loop length rather
-- than a clip length.

BR = BR or {}
BR.Config = BR.Config or {}
BR.Emotes = BR.Emotes or {}

-- AFTER config/market.lua, AND THAT IS A LOAD ORDER RATHER THAN A READER'S ONE.
-- The rows below are registered into BR.Config.MarketIndex as this file loads,
-- so buyable(), the server's equip and the storefront find them by id like any
-- other item. Loading it first is a manifest mistake, and it says so.
assert(type(BR.Config.MarketIndex) == 'table' and type(BR.Config.Market) == 'table'
       and type(BR.Config.ItemKind) == 'table' and type(BR.Config.Rarity) == 'table',
       'br_lib/config/emotes.lua must load after br_lib/config/market.lua')

--- One more Market kind. Declared here rather than in config/market.lua so the
--- feature is one file; nothing iterates ItemKind.
BR.Config.ItemKind.EMOTE = 'emote'

BR.Config.Emotes = {
    -- "Up to 8 equipped" (owner). Wheel segment N is slot N is equip_emoteN.
    slots       = 8,
    -- Music falls linearly to silence at this distance from the dancer.
    hearRadiusM = 20.0,
    -- The server sends a dance's record only to players this close to it (and
    -- in the same routing bucket), so a dancer's position never reaches a
    -- client that could not already see them. Three hearing radii of margin.
    sendRadiusM = 60.0,
    -- A roster position older than this is not trusted for a record (the
    -- roster samples at 4 Hz and keeps the last point when the ped reads 0).
    posFreshMs  = 1000,
    -- A wheel released sooner than this after it opened is a tap, not a pick.
    tapMs       = 200,
    -- The Market season the rows are sold under; an inactive season stops sales.
    -- A catalogue set in config/market.lua, not the season the server runs:
    -- that one is BR.Season (config/seasons.lua), and it is what gates emotes.
    season      = 'founders',
    -- Where a dance may start and keep playing: the warmup pad and the match,
    -- alive. Not the lobby ("anywhere except the lobby"), and not DBNO or dead,
    -- which both cancel.
    states      = {
        [BR.PlayerState.WARMUP] = true,
        [BR.PlayerState.ALIVE]  = true,
    },
    -- PLAYs one player may send per window before the server drops them.
    playRate    = { windowMs = 10000, max = 6 },
    -- How often the server re-checks a live dance (state, seat, item, gate) and
    -- hands its record to anybody who has come into range.
    sweepMs     = 250,

    list = {
        { id = 'emote_club_podium',   name = 'Podium',
          dict = 'anim@amb@nightclub@dancers@podium_dancers@',
          clip = 'hi_dance_facedj_17_v2_male^5',
          flag = 1, durationMs = 12000, track = 'emotes/emote_club_podium.ogg', price = 250 },
        { id = 'emote_club_groove',   name = 'Groove',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@male@var_a@',
          clip = 'high_center',
          flag = 1, durationMs = 12000, track = 'emotes/emote_club_groove.ogg', price = 250 },
        { id = 'emote_club_drop',     name = 'Drop',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@male@var_b@',
          clip = 'high_center_down',
          flag = 1, durationMs = 12000, track = 'emotes/emote_club_drop.ogg', price = 250 },
        { id = 'emote_shuffle',       name = 'Shuffle',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@shuffle@',
          clip = 'high_center',
          flag = 1, durationMs = 12000, track = 'emotes/emote_shuffle.ogg', price = 250 },
        { id = 'emote_techno_karate', name = 'Techno Karate',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@techno_karate@',
          clip = 'high_left_up',
          flag = 1, durationMs = 12000, track = 'emotes/emote_techno_karate.ogg', price = 250 },
        { id = 'emote_techno_monkey', name = 'Monkey',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@techno_monkey@',
          clip = 'high_center',
          flag = 1, durationMs = 12000, track = 'emotes/emote_techno_monkey.ogg', price = 250 },
        { id = 'emote_beach_boxing',  name = 'Shadowbox',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@beach_boxing@',
          clip = 'med_right_down',
          flag = 1, durationMs = 12000, track = 'emotes/emote_beach_boxing.ogg', price = 250 },
        { id = 'emote_jumper',        name = 'Jumper',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@jumper@',
          clip = 'high_center',
          flag = 1, durationMs = 12000, track = 'emotes/emote_jumper.ogg', price = 250 },
        { id = 'emote_sand_trip',     name = 'Sand Trip',
          dict = 'anim@amb@nightclub@mini@dance@dance_solo@sand_trip@',
          clip = 'high_center',
          flag = 1, durationMs = 12000, track = 'emotes/emote_sand_trip.ogg', price = 250 },
        { id = 'emote_casino_sway',   name = 'Casino Sway',
          dict = 'anim@amb@casino@mini@dance@dance_solo@female@var_a@',
          clip = 'med_center',
          flag = 1, durationMs = 12000, track = 'emotes/emote_casino_sway.ogg', price = 250 },
        { id = 'emote_casino_bounce', name = 'Casino Bounce',
          dict = 'anim@amb@casino@mini@dance@dance_solo@female@var_b@',
          clip = 'high_center',
          flag = 1, durationMs = 12000, track = 'emotes/emote_casino_bounce.ogg', price = 250 },
        { id = 'emote_beach_party',   name = 'Beach Party',
          dict = 'anim@amb@nightclub_island@dancers@beachdance@',
          clip = 'hi_idle_a_m03',
          flag = 1, durationMs = 12000, track = 'emotes/emote_beach_party.ogg', price = 250 },
        { id = 'emote_beach_party_2', name = 'Beach Party II',
          dict = 'anim@amb@nightclub_island@dancers@beachdance@',
          clip = 'hi_idle_b_f01',
          flag = 1, durationMs = 12000, track = 'emotes/emote_beach_party_2.ogg', price = 250 },
        { id = 'emote_island_club',   name = 'Island Club',
          dict = 'anim@amb@nightclub_island@dancers@club@',
          clip = 'hi_idle_b_m03',
          flag = 1, durationMs = 12000, track = 'emotes/emote_island_club.ogg', price = 250 },
        { id = 'emote_uncle_disco',   name = 'Uncle Disco',
          dict = 'anim@mp_player_intcelebrationmale@uncle_disco',
          clip = 'uncle_disco',
          flag = 1, durationMs = 12000, track = 'emotes/emote_uncle_disco.ogg', price = 250 },
        { id = 'emote_the_woogie',    name = 'The Woogie',
          dict = 'anim@mp_player_intcelebrationmale@the_woogie',
          clip = 'the_woogie',
          flag = 1, durationMs = 12000, track = 'emotes/emote_the_woogie.ogg', price = 250 },
    },
}

--- Why a TaskPlayAnim flag may not be used for a dance, or nil when it may.
--- 16/32 free the legs (the dancer walks off); 1024 desyncs the ped for every
--- other player (fivem#3733). Shared by the row check and `bremote`.
--- @param flag any
--- @return string|nil
function BR.Emotes.flagProblem(flag)
    if math.type(flag) ~= 'integer' or flag < 0 then return 'flag must be a whole number' end
    if (flag & (16 | 32 | 1024)) ~= 0 then return 'flag may not carry 16, 32 or 1024' end
    return nil
end

--- Why a catalogue row cannot be sold, or nil when it can.
--- @param row any
--- @return string|nil
function BR.Emotes.rowProblem(row)
    if type(row) ~= 'table' then return 'not a table' end
    local id = row.id
    if type(id) ~= 'string' or #id > 54 or not id:match('^emote_[a-z0-9_]+$') then
        return 'id must be emote_ then a-z, 0-9 or _, at most 54 characters'
    end
    if type(row.name) ~= 'string' or row.name == '' then return 'no name' end
    if type(row.dict) ~= 'string' or row.dict == '' then return 'no dict' end
    if type(row.clip) ~= 'string' or row.clip == '' then return 'no clip' end
    local fp = BR.Emotes.flagProblem(row.flag)
    if fp then return fp end
    if math.type(row.durationMs) ~= 'integer'
       or row.durationMs < 1000 or row.durationMs > 600000 then
        return 'durationMs must be a whole number from 1000 to 600000'
    end
    if row.track ~= nil and (type(row.track) ~= 'string'
       or not row.track:match('^emotes/[%w_%-]+%.ogg$')) then
        return "track must be nil or 'emotes/<file>.ogg'"
    end
    if math.type(row.price) ~= 'integer' or row.price <= 0 then
        return 'price must be a positive whole number'
    end
    if BR.Config.MarketIndex[id] ~= nil then return 'id is already in the catalogue' end
    return nil
end

--- Valid rows by id, and their ids in list order. Every consumer iterates
--- `order`, never `list`: a row that failed rowProblem is in `list` and nowhere
--- else.
BR.Config.Emotes.byId  = {}
BR.Config.Emotes.order = {}

local season = nil
for _, s in ipairs(BR.Config.Market.seasons or {}) do
    if s.id == BR.Config.Emotes.season then season = s end
end
assert(season ~= nil, ('br_lib/config/emotes.lua: no Market season "%s"')
    :format(tostring(BR.Config.Emotes.season)))

-- A BAD ROW IS SKIPPED WITH ONE LINE, NOT A FAILED BOOT. The showroom's rule
-- for a refused model, and the same reason: one typo in a dance must not take
-- the gamemode down with it.
for _, row in ipairs(BR.Config.Emotes.list) do
    local why = BR.Emotes.rowProblem(row)
    if why then
        print(('[br_lib] emotes: row %s skipped -- %s')
            :format(tostring(type(row) == 'table' and row.id or '?'), why))
    else
        BR.Config.Emotes.byId[row.id] = row
        BR.Config.Emotes.order[#BR.Config.Emotes.order + 1] = row.id
        -- IN MarketIndex AND NOT IN season.items. The index is how every id is
        -- resolved; the season list is what br_ui's storefront and anything
        -- else iterating seasons walks, and none of those may see an emote
        -- while the gate is closed.
        BR.Config.MarketIndex[row.id] = {
            id = row.id, name = row.name, sub = 'Dance',
            kind = BR.Config.ItemKind.EMOTE,
            price = row.price, rarity = BR.Config.Rarity.COMMON,
            apply = row,
            season = season.id, seasonName = season.name,
            purchasable = season.active == true,
        }
    end
end

--- The valid row for an id, or nil.
--- @param id any
--- @return table|nil
function BR.Emotes.row(id)
    return BR.Config.Emotes.byId[tostring(id or '')]
end

-- The game-side half of the `configreport` dispatch verb.
--
--   lua tools/config_report.lua [path/to/br_lib]
--
-- Prints ONE LINE of JSON: the tuning values a person would want to read off a
-- running server, each carrying the config file it came from.
--
-- WHY THIS IS A SEPARATE SCRIPT AND NOT SHELL. The values live in Lua tables,
-- and several of the interesting ones are COMPUTED rather than written down --
-- the storm's total duration is the sum of every phase's wait and shrink, and
-- the map-wide loot budget is a sum over the POI table. An awk pass over the
-- files would get the literals and quietly invent the rest. Loading the files
-- and asking them is the only version that cannot drift from what the server
-- actually runs.
--
-- IT LOADS THEM IN A BARE LUA STATE, exactly as tools/check_pois.lua does.
-- `br_lib/config/*.lua` is pure data: no natives, no requires, nothing that
-- needs FXServer. That is a property worth keeping -- it is what lets both this
-- and the POI gate exist -- so if a config file ever grows a `GetConvar` call,
-- this script is what will notice.
--
-- WHAT IT DOES NOT DO: read the live process. See the long comment on
-- do_configreport in tools/dispatch.sh; the short version is that these are the
-- files on disk, and dispatch.sh separately reports whether they have changed
-- since FXServer started.

-- ---------------------------------------------------------------------------
-- THE ALLOWLIST -- and it is CLOSED, not open, for the same reason
-- PUBLIC_FIELDS and RINGMASTER_FIELDS in br_core/server/roster.lua are.
--
-- This output is rendered in a web browser and written to an audit log. A
-- walker over `BR.Config` would publish whatever anybody adds to it next,
-- including the day somebody parks a webhook URL or a key in a config table
-- "just for now". Enumerating the values by hand means a new secret in
-- BR.Config is invisible here until a human writes a line for it.
--
-- Nothing here is a credential today and nothing here may become one: this is
-- the tuning surface -- pacing, weights, prices -- which is exactly the set the
-- Live config page exists to show.
-- ---------------------------------------------------------------------------

local ROOT = arg[1]
if not ROOT or ROOT == '' then ROOT = 'resources/[fivem-royale]/br_lib' end
ROOT = ROOT:gsub('/+$', '') .. '/'

-- Loaded in dependency order. map.lua before loot.lua because the loot budget
-- is summed over the POI table; enums.lua first because everything reads it.
local FILES = {
    'shared/enums.lua',
    'config/map.lua',
    'config/match.lua',
    'config/storm.lua',
    'config/loot.lua',
    'config/market.lua',
}

local loadErrors = {}
for _, f in ipairs(FILES) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        loadErrors[#loadErrors + 1] = f .. ': ' .. tostring(err)
    else
        local ok, e = pcall(chunk)
        if not ok then
            loadErrors[#loadErrors + 1] = f .. ': ' .. tostring(e)
        end
    end
end

-- THE DEGRADED CASE HAS TO SURVIVE, and the first draft of this did not.
--
-- When every loadfile fails -- a wrong path, an undeployed box -- `BR` is not
-- an empty table, it is nil, and the direct `BR.Config.Storm.phases` reads
-- further down threw before a single line was printed. The caller then saw a
-- Lua stack trace on stdout, discarded it as unparseable, and reported "the
-- config reader produced nothing usable" -- swallowing the load errors, which
-- were the one thing that said WHY.
--
-- So the tables are conjured here whether or not anything loaded. Every getter
-- below then reads a missing key rather than indexing nil, `loadErrors` makes
-- it to the console, and the report degrades to "here is what broke".
BR = BR or {}
BR.Config = BR.Config or {}
BR.Config.Match = BR.Config.Match or {}
BR.Config.Storm = BR.Config.Storm or {}
BR.Config.Loot = BR.Config.Loot or {}
BR.Config.Market = BR.Config.Market or {}

-- --------------------------------------------------------------- formatting --

--- Numbers without Lua's trailing `.0` on whole floats.
---
--- `radius0` is 3500.0 in the file and reads as "3500" to a human. Printing the
--- float spelling is not wrong, but this output is read by somebody comparing
--- it against a number they typed, and two spellings of the same value is one
--- more thing for them to wonder about.
---
--- IT RAISES ON A NON-NUMBER RATHER THAN STRINGIFYING ONE, and that is the
--- whole reason `try` below works. The first version of this ended
--- `return tostring(v)`, so a renamed key arrived as nil, came back as the
--- four characters "nil", concatenated happily with its unit, and was reported
--- as a SUCCESSFUL row reading "nilms held to open a crate". try() never fired,
--- the verify.sh gate that exists to catch exactly that passed green, and the
--- failure would have surfaced as a nonsense value on the page. A getter that
--- cannot fail cannot be checked.
local function num(v)
    if type(v) ~= 'number' then
        error('expected a number, got ' .. type(v), 2)
    end
    if math.type(v) == 'integer' or v == math.floor(v) then
        return string.format('%d', math.floor(v))
    end
    return (string.format('%.2f', v):gsub('0+$', ''):gsub('%.$', ''))
end

--- Booleans, same contract as `num`: a missing key raises rather than becoming
--- the string "nil".
local function bool(v)
    if type(v) ~= 'boolean' then
        error('expected a boolean, got ' .. type(v), 2)
    end
    return tostring(v)
end

--- Non-empty strings, same contract again.
local function str(v)
    if type(v) ~= 'string' or v == '' then
        error('expected a non-empty string, got ' .. type(v), 2)
    end
    return v
end

--- One JSON string body. Same rules as dispatch.sh's json_str, and the same
--- reason: this line is parsed by the console, and one unescaped quote turns a
--- working report into "dispatch returned non-JSON".
local function jstr(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
    -- Control characters DROPPED rather than \u-escaped, matching dispatch.sh.
    -- Nothing legitimate puts one in a config label.
    s = s:gsub('%c', '')
    return s
end

local out = {}

--- Add one row. `value` is already a display string: the console renders this
--- as text beside a label, so formatting it here keeps the decision next to the
--- value it is about rather than in a component that cannot see the units.
local function row(group, file, key, value)
    out[#out + 1] = ('{"group":"%s","file":"%s","key":"%s","value":"%s"}')
        :format(jstr(group), jstr(file), jstr(key), jstr(value))
end

--- Add a row whose value has to be computed, without letting a moved key take
--- the whole report down with it.
---
--- A missing key is REPORTED, never skipped. A report that silently drops the
--- one value somebody came to look at is worse than one that says "this moved"
--- -- and tools/verify.sh fails the build on any row that lands here, so this
--- path is a build error on a dev machine long before it is a line on a page.
local function try(group, file, key, fn)
    local ok, v = pcall(fn)
    if not ok or v == nil then
        row(group, file, key, '(unreadable -- this key has moved or been removed)')
        return false
    end
    row(group, file, key, v)
    return true
end

-- ------------------------------------------------------------------- match --

local MATCH = 'br_lib/config/match.lua'

try('Match', MATCH, 'maxPlayers', function() return num(BR.Config.Match.maxPlayers) end)
try('Match', MATCH, 'minToStart (dev)', function() return num(BR.Config.Match.minToStart) end)
try('Match', MATCH, 'minToStart (prod)', function() return num(BR.Config.Match.minToStartProd) end)
try('Match', MATCH, 'warmupSeconds', function()
    return ('%ss, cut to %ss once the lobby is full')
        :format(num(BR.Config.Match.warmupSeconds), num(BR.Config.Match.warmupShortened))
end)
try('Match', MATCH, 'endedSeconds', function()
    return num(BR.Config.Match.endedSeconds) .. 's summary before the lobby'
end)
try('Match', MATCH, 'health', function()
    local M = BR.Config.Match
    return ('engine %s..%s, display 0..100, armour cap %s')
        :format(num(M.healthFloor), num(M.maxHealth), num(M.maxArmour))
end)
try('Match', MATCH, 'dbno', function()
    local M = BR.Config.Match
    return ('bleed %ss, revive %ss within %sm, revive to %s hp')
        :format(num(M.dbnoBleedBase), num(M.dbnoReviveTime),
                num(M.dbnoReviveDist), num(M.dbnoReviveHp))
end)

-- Voice, the GAMEMODE's half. The engine convars with the same word in them are
-- reported separately by dispatch.sh, and the pairing is the point: #150 was a
-- day spent on `voice_useNativeAudio` when the channel scheme -- which is these
-- values and nothing else -- was what mattered. Seeing both on one page is the
-- cheapest possible way to stop that happening twice.
try('Voice (gamemode)', MATCH, 'enabled', function()
    return bool(BR.Config.Match.voice.enabled)
end)
-- THE TWO RANGES, SEPARATELY, because #157 was "the channel is global" and the
-- answer is a pair of numbers that used to be one. `nearby` gates ordinary
-- speech through Mumble's distance; `squad` is where the client stops opening
-- the per-player volume override that carries squadmates past it. A single
-- "voice range" row would be the shape of the bug rather than of the fix.
try('Voice (gamemode)', MATCH, 'range.nearby', function()
    return num(BR.Config.Match.voice.range.nearby) .. 'm -- ordinary speech'
end)
try('Voice (gamemode)', MATCH, 'range.squad', function()
    return num(BR.Config.Match.voice.range.squad)
        .. 'm -- squadmates; past the map diagonal (~14000m) means never cuts out'
end)
try('Voice (gamemode)', MATCH, 'squadIsGlobal', function()
    local v = BR.Config.Match.voice.squadIsGlobal
    return bool(v) .. (v and ' -- squads hear each other past range.nearby'
                          or ' -- squads are proximity-only')
end)
try('Voice (gamemode)', MATCH, 'channels', function()
    local v = BR.Config.Match.voice
    return ('lobby %s, warmup %s, match %s+id')
        :format(num(v.lobbyChannel), num(v.warmupChannel), num(v.matchBase))
end)

-- ------------------------------------------------------------------- storm --

local STORM = 'br_lib/config/storm.lua'

try('Storm', STORM, 'radius0', function()
    return num(BR.Config.Storm.radius0) .. ' (floor on the computed opening radius)'
end)
try('Storm', STORM, 'edgeBiasMax', function() return num(BR.Config.Storm.edgeBiasMax) end)
try('Storm', STORM, 'edgeHug', function()
    local S = BR.Config.Storm
    return ('within %sm of the rim for the last %s phases')
        :format(num(S.edgeHugM), num(S.edgeHugPhases))
end)
try('Storm', STORM, 'total duration', function()
    local secs = BR.Config.Storm.TotalSeconds()
    return ('%s phases, %s min %ss total')
        :format(num(#BR.Config.Storm.phases), num(math.floor(secs / 60)), num(secs % 60))
end)

-- THE PACING TABLE ITSELF, one row per phase. This is the thing being tuned in
-- playtests and the thing there is currently no way to read off a running box,
-- so a summary line would miss the point -- "how long is phase 3's shrink" is
-- the actual question.
if BR.Config and BR.Config.Storm and type(BR.Config.Storm.phases) == 'table' then
    for i, p in ipairs(BR.Config.Storm.phases) do
        row('Storm phases', STORM, 'phase ' .. i,
            ('radius %sm, wait %ss, shrink %ss, %s dps, warn %ss')
                :format(num(p.radius), num(p.wait), num(p.shrink),
                        num(p.dps), num(p.warn)))
    end
else
    row('Storm phases', STORM, 'phases', '(unreadable -- the phase table has moved)')
end

-- -------------------------------------------------------------------- loot --

local LOOT = 'br_lib/config/loot.lua'

try('Loot', LOOT, 'map-wide budget', function()
    return num(BR.Config.TotalLootBudget()) .. ' POI items, summed over the POI table'
end)
try('Loot', LOOT, 'budgetPerTier', function()
    local b = BR.Config.Loot.budgetPerTier
    return ('tier 1 %s, tier 2 %s, tier 3 %s'):format(num(b[1]), num(b[2]), num(b[3]))
end)
try('Loot', LOOT, 'chestsPerTier', function()
    local c = BR.Config.Loot.chestsPerTier
    return ('tier 1 %s, tier 2 %s, tier 3 %s'):format(num(c[1]), num(c[2]), num(c[3]))
end)
try('Loot', LOOT, 'filler', function()
    local f = BR.Config.Loot.filler
    return ('%s roadside items on the tier %s table, %sm off the tarmac')
        :format(num(f.count), num(f.tier), num(f.minOffset))
end)
try('Loot', LOOT, 'chestHoldMs', function()
    return num(BR.Config.Loot.chestHoldMs) .. 'ms held to open a crate'
end)
try('Loot', LOOT, 'cellSize', function() return num(BR.Config.Loot.cellSize) .. 'm streaming cell' end)
try('Loot', LOOT, 'propDistance', function() return num(BR.Config.Loot.propDistance) .. 'm' end)
try('Loot', LOOT, 'pickupDistance', function() return num(BR.Config.Loot.pickupDistance) .. 'm' end)
try('Loot', LOOT, 'slots', function()
    return ('%s, plus slot %s for fists'):format(num(BR.Config.Loot.slots), num(BR.Config.Loot.meleeSlot))
end)
try('Loot', LOOT, 'weaponReserveClips', function()
    return num(BR.Config.Loot.weaponReserveClips)
end)

-- THE WEIGHTS, as weights AND as percentages. A raw weight of 74 next to one of
-- 16 is a ratio somebody has to work out on paper while looking at the page,
-- and "74" has been read as "74%" more than once. Both spellings, side by side.
if type(BR.Config.FloorKindWeights) == 'table' then
    local total = 0
    for _, w in ipairs(BR.Config.FloorKindWeights) do total = total + (w.weight or 0) end
    for _, w in ipairs(BR.Config.FloorKindWeights) do
        local pct = total > 0 and (100.0 * (w.weight or 0) / total) or 0
        row('Floor loot weights', LOOT, tostring(w.kind),
            ('weight %s of %s (%s%%)'):format(num(w.weight), num(total), num(pct)))
    end
else
    row('Floor loot weights', LOOT, 'FloorKindWeights', '(unreadable -- the table has moved)')
end

if BR.Config.Loot and type(BR.Config.Loot.chestItems) == 'table'
   and type(BR.Config.Loot.chestItems.weights) == 'table' then
    local ci = BR.Config.Loot.chestItems
    local total = 0
    for _, w in ipairs(ci.weights) do total = total + (w.weight or 0) end
    for _, w in ipairs(ci.weights) do
        local pct = total > 0 and (100.0 * (w.weight or 0) / total) or 0
        row('Crate contents', LOOT, num(w.n) .. ' items',
            ('weight %s of %s (%s%%)'):format(num(w.weight), num(total), num(pct)))
    end
else
    row('Crate contents', LOOT, 'chestItems', '(unreadable -- the table has moved)')
end

-- ------------------------------------------------------------------ payout --

local MARKET = 'br_lib/config/market.lua'

try('Payout', MARKET, 'currency', function() return str(BR.Config.Market.currency) end)
try('Payout', MARKET, 'completion', function()
    return num(BR.Config.Market.payout.completion) .. ' for finishing'
end)
try('Payout', MARKET, 'win', function() return num(BR.Config.Market.payout.win) end)
try('Payout', MARKET, 'placementTop', function()
    return num(BR.Config.Market.payout.placementTop) .. ', scaled linearly by placement'
end)
try('Payout', MARKET, 'perKill', function() return num(BR.Config.Market.payout.perKill) end)
try('Payout', MARKET, 'perRevive', function() return num(BR.Config.Market.payout.perRevive) end)

-- ------------------------------------------------------------------ output --

local errs = {}
for _, e in ipairs(loadErrors) do
    errs[#errs + 1] = '"' .. jstr(e) .. '"'
end

io.write('{"ok":', (#loadErrors == 0) and 'true' or 'false',
         ',"loadErrors":[', table.concat(errs, ','),
         '],"values":[', table.concat(out, ','), ']}\n')

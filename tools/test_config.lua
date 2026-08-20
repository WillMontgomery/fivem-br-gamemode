-- Unit tests for the server-tunable override layer.
--
--   lua tools/test_config.lua      (or via tools/verify.sh)
--
-- WHAT THIS SUITE IS GUARDING, because it is not obvious from the size of the
-- feature. br_lib/config/overrides.lua lets a .cfg on one box change values
-- that are otherwise committed constants. That creates, for six settings, a
-- SECOND PLACE the value can be written down -- and this project's most
-- expensive recurring bug is exactly that: two homes for one setting with
-- nothing comparing them (the voice default lived in four places and three of
-- them were wrong). So the tests below are weighted towards the seams:
--
--   * the override actually reaches BR.Config, and the default is genuinely
--     unchanged when nothing is set -- checked against a SECOND, PRISTINE load
--     of config/match.lua rather than against numbers typed in this file, so
--     the assertion cannot quietly re-encode the code's own opinion;
--   * a value that does not parse changes NOTHING and says so by name;
--   * a renamed config key is a hard failure, not a silently orphaned convar;
--   * the range published to operators is the range the parser enforces;
--   * no overridable key is read on the CLIENT, where the override never runs;
--   * every manifest that loads config/match.lua loads overrides.lua after it;
--   * the shipped .cfg examples parse under the real parser, and server.cfg's
--     exec line is above the ensure block it has to precede.

local ROOT  = 'resources/[fivem-royale]/br_lib/'

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        io.write('\27[31mFAIL\27[0m ', group, ' > ', name)
        if detail then io.write('\n       ', tostring(detail)) end
        io.write('\n')
    end
end

local function slurp(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

--- Load the config chain into a FRESH sandbox.
---
--- Each case gets its own `BR`, so a mutation in one cannot reach the next --
--- which matters more than usual here, since the whole feature is "mutate the
--- config table". `natives` seeds globals the file may look for; leaving it nil
--- is the bare-Lua state that tools/config_report.lua and every other suite
--- run in.
--- @param natives table|nil
--- @return table env
--- @return string|nil loadError
local function load(natives)
    local env = setmetatable({}, { __index = _G })
    for k, v in pairs(natives or {}) do env[k] = v end

    for _, f in ipairs({ 'config/match.lua', 'config/overrides.lua' }) do
        local chunk, err = loadfile(ROOT .. f, 't', env)
        if not chunk then return env, f .. ': ' .. tostring(err) end
        local good, e = pcall(chunk)
        if not good then return env, tostring(e) end
    end
    return env, nil
end

--- A reader over a plain table, in the shape apply() expects.
local function readerFor(t)
    return function(name) return t[name] end
end

-- The pristine copy. Nothing below ever overrides through this one, so it is
-- what "the committed default" means for the rest of the file -- an
-- independent load of the same file rather than a number retyped here.
local PRISTINE = load(nil)

-- --------------------------------------------------------------- the spec ---

describe('spec')
do
    local env = load(nil)
    local Ov  = env.BR.Config.Overrides

    ok(type(Ov) == 'table', 'config/overrides.lua defines BR.Config.Overrides')
    ok(type(Ov.SPEC) == 'table' and #Ov.SPEC > 0, 'the spec is not empty')

    local seenConvar, seenKey, shaped, prefixed, exists = {}, {}, true, true, true
    local dupes = nil
    for _, s in ipairs(Ov.SPEC) do
        if type(s.convar) ~= 'string' or type(s.group) ~= 'string'
           or type(s.key) ~= 'string' or (s.kind ~= 'int' and s.kind ~= 'bool') then
            shaped = false
        end
        if type(s.convar) == 'string' and not s.convar:match('^br_') then
            prefixed = false
        end
        if seenConvar[s.convar] or seenKey[s.key] then dupes = s.convar end
        seenConvar[s.convar], seenKey[s.key] = true, true

        local cfg = env.BR.Config[s.group]
        if type(cfg) ~= 'table' or cfg[s.key] == nil then exists = false end
    end

    ok(shaped, 'every entry has a convar, group, key and a known kind')
    ok(prefixed, 'every convar is namespaced br_*, so it cannot collide with an engine one')
    ok(dupes == nil, 'no convar or config key is claimed twice', dupes)
    ok(exists, 'every spec key already exists in BR.Config -- the spec never invents one')
end

-- ------------------------------------------------------------ absent case ---

describe('nothing set')
do
    -- The public server's case, and the one that must never surprise anybody:
    -- exec an empty file, or no file at all, and the game is byte-for-byte the
    -- committed configuration.
    for _, reader in ipairs({
        { name = 'unset (nil)',            fn = function() return nil end },
        { name = 'set to empty string',    fn = function() return '' end },
    }) do
        local env = load(nil)
        local Ov  = env.BR.Config.Overrides
        local applied, errors = Ov.apply(reader.fn)

        ok(#applied == 0, ('%s applies nothing'):format(reader.name))
        ok(#errors == 0, ('%s is not an error'):format(reader.name),
            errors[1] and errors[1].why)

        local drift = nil
        for _, s in ipairs(Ov.SPEC) do
            local live = env.BR.Config[s.group][s.key]
            local base = PRISTINE.BR.Config[s.group][s.key]
            if live ~= base then
                drift = ('%s is %s, pristine says %s')
                    :format(s.key, tostring(live), tostring(base))
            end
            -- The two failure modes the brief names by name. Neither can be
            -- produced by an absent convar, and both would be invisible in a
            -- test that only compared against itself.
            if live == nil then drift = s.key .. ' became nil' end
            if live == 0 and base ~= 0 then drift = s.key .. ' became 0' end
        end
        ok(drift == nil,
            ('%s leaves every value exactly as the file has it'):format(reader.name), drift)
    end
end

-- ------------------------------------------------------------- valid case ---

describe('a valid override')
do
    local env = load(nil)
    local Ov  = env.BR.Config.Overrides
    local applied, errors = Ov.apply(readerFor({ br_maxSquadSize = '2' }))

    ok(#errors == 0, 'br_maxSquadSize 2 is accepted', errors[1] and errors[1].why)
    ok(env.BR.Config.Match.maxSquadSize == 2, 'the live value is 2',
        tostring(env.BR.Config.Match.maxSquadSize))
    ok(PRISTINE.BR.Config.Match.maxSquadSize == 4,
        'and the committed default is still 4 -- the override edits the loaded '
        .. 'table, not the file',
        tostring(PRISTINE.BR.Config.Match.maxSquadSize))
    ok(#applied == 1 and applied[1].convar == 'br_maxSquadSize'
       and applied[1].from == 4 and applied[1].to == 2,
        'apply() reports the convar, the value it replaced and the value it set')

    -- Nothing else moved. An override that reaches a second setting is the
    -- kind of thing a single-value assertion never sees.
    local spill = nil
    for _, s in ipairs(Ov.SPEC) do
        if s.key ~= 'maxSquadSize'
           and env.BR.Config[s.group][s.key] ~= PRISTINE.BR.Config[s.group][s.key] then
            spill = s.key
        end
    end
    ok(spill == nil, 'no other setting moved', spill)
end

describe('the values Lua is worst at')
do
    -- ZERO. `if v then` is TRUE for 0 in Lua, so the classic bug here is the
    -- opposite of the usual one: not "0 was treated as absent", but code that
    -- tests truthiness and cannot tell 0 from 45. partyGraceSeconds 0 is a real
    -- setting -- never wait for a straggler -- and it must survive as 0.
    local env = load(nil)
    local _, errors = env.BR.Config.Overrides.apply(readerFor({ br_partyGraceSeconds = '0' }))
    ok(#errors == 0, 'partyGraceSeconds 0 is accepted', errors[1] and errors[1].why)
    ok(env.BR.Config.Match.partyGraceSeconds == 0, 'and lands as the number 0',
        tostring(env.BR.Config.Match.partyGraceSeconds))

    -- FALSE. Same shape, one type over: a boolean override that lands as nil
    -- instead of false reads as "not set" to every consumer.
    local benv = load(nil)
    local _, berrs = benv.BR.Config.Overrides.apply(readerFor({ br_autofill = 'false' }))
    ok(#berrs == 0, 'autofill false is accepted', berrs[1] and berrs[1].why)
    ok(benv.BR.Config.Match.autofill == false, 'and lands as boolean false, not nil',
        tostring(benv.BR.Config.Match.autofill))

    for raw, want in pairs({ ['true'] = true, ['TRUE'] = true, ['1'] = true,
                             ['false'] = false, ['False'] = false, ['0'] = false }) do
        local e = load(nil)
        e.BR.Config.Overrides.apply(readerFor({ br_autofill = raw }))
        ok(e.BR.Config.Match.autofill == want,
            ('autofill accepts %q as %s'):format(raw, tostring(want)),
            tostring(e.BR.Config.Match.autofill))
    end
end

-- ----------------------------------------------------------- invalid case ---

describe('an invalid value is refused, not absorbed')
do
    local cases = {
        { convar = 'br_maxSquadSize',     raw = 'two',   why = 'a word' },
        { convar = 'br_maxSquadSize',     raw = '2.5',   why = 'a fraction' },
        { convar = 'br_maxSquadSize',     raw = '0x2',   why = 'hex, which tonumber would have taken' },
        { convar = 'br_maxSquadSize',     raw = '2e1',   why = 'exponent notation, likewise' },
        { convar = 'br_maxSquadSize',     raw = '0',     why = 'below the minimum of 1' },
        { convar = 'br_maxSquadSize',     raw = '-1',    why = 'negative' },
        { convar = 'br_maxSquadSize',     raw = '17',    why = 'above the maximum' },
        { convar = 'br_maxSquadSize',     raw = '4 ok',  why = 'trailing junk' },
        { convar = 'br_warmupSeconds',    raw = '0',     why = 'below the minimum' },
        { convar = 'br_warmupSeconds',    raw = '99999', why = 'above the maximum' },
        { convar = 'br_partyGraceSeconds', raw = '-1',   why = 'below a minimum that IS zero' },
        { convar = 'br_autofill',         raw = 'yes',   why = 'not a boolean this parser takes' },
        { convar = 'br_autofill',         raw = '2',     why = 'a number that is not 0 or 1' },
    }

    for _, c in ipairs(cases) do
        local env = load(nil)
        local Ov  = env.BR.Config.Overrides

        local spec
        for _, s in ipairs(Ov.SPEC) do if s.convar == c.convar then spec = s end end

        local before = env.BR.Config[spec.group][spec.key]
        local applied, errors = Ov.apply(readerFor({ [c.convar] = c.raw }))

        ok(#errors == 1 and errors[1].convar == c.convar,
            ('%s = %q is refused (%s)'):format(c.convar, c.raw, c.why),
            errors[1] and errors[1].why or 'no error was reported')
        ok(#applied == 0, ('%s = %q applies nothing'):format(c.convar, c.raw))

        local after = env.BR.Config[spec.group][spec.key]
        ok(after == before and after ~= nil,
            ('%s = %q leaves the default in place -- not nil, not 0')
                :format(c.convar, c.raw),
            ('was %s, now %s'):format(tostring(before), tostring(after)))

        -- The message is the deliverable: it is read at boot by somebody who
        -- has never opened overrides.lua, so it has to name the setting AND
        -- show them what they typed.
        local msg = errors[1] and (errors[1].convar .. ' ' .. errors[1].why) or ''
        ok(msg:find(c.convar, 1, true) ~= nil,
            ('the refusal names %s'):format(c.convar), msg)
        ok(errors[1] and tostring(errors[1].raw) == c.raw,
            ('the refusal quotes back what was typed for %s'):format(c.convar), msg)
    end
end

describe('a bad value does not take the good ones with it')
do
    -- apply() keeps going, so the boot banner can list EVERY mistake at once
    -- rather than one per restart. The server still refuses to start (see the
    -- load-time hook below); this is about what the operator is told.
    local env = load(nil)
    local applied, errors = env.BR.Config.Overrides.apply(readerFor({
        br_maxSquadSize  = 'two',
        br_warmupSeconds = '0',
        br_endedSeconds  = 'later',
    }))
    ok(#errors == 3, 'all three mistakes are reported together', ('%d reported'):format(#errors))
    ok(#applied == 0, 'and none of them applied')
end

describe('a floor derived from another setting')
do
    -- These two bounds are computed from OTHER config values rather than typed
    -- into the spec, because both exist to stop a silent interaction:
    -- combat.lua floors a bleed at dbnoBleedMin, and the server's ENDED sweep
    -- deadline is coverSweepMs. A value under either is not "aggressive", it is
    -- ignored -- so it is refused, by name.
    local env = load(nil)
    local Ov  = env.BR.Config.Overrides
    local M   = env.BR.Config.Match

    local _, errors = Ov.apply(readerFor({ br_dbnoBleedBase = tostring(M.dbnoBleedMin - 1) }))
    ok(#errors == 1 and errors[1].why:find('dbnoBleedMin', 1, true) ~= nil,
        'a bleed under dbnoBleedMin is refused, and the message names dbnoBleedMin',
        errors[1] and errors[1].why)

    local env2 = load(nil)
    local M2   = env2.BR.Config.Match
    local floorS = math.ceil(M2.coverSweepMs / 1000)
    local _, errors2 = env2.BR.Config.Overrides.apply(
        readerFor({ br_endedSeconds = tostring(floorS - 1) }))
    ok(#errors2 == 1 and errors2[1].why:find('coverSweepMs', 1, true) ~= nil,
        'a summary screen shorter than the cover sweep is refused, naming coverSweepMs',
        errors2[1] and errors2[1].why)

    -- And the boundary itself is allowed, so the floor is inclusive rather than
    -- one off in the direction nobody checks.
    local env3 = load(nil)
    local M3   = env3.BR.Config.Match
    local _, errors3 = env3.BR.Config.Overrides.apply(
        readerFor({ br_dbnoBleedBase = tostring(M3.dbnoBleedMin) }))
    ok(#errors3 == 0, 'exactly dbnoBleedMin is allowed', errors3[1] and errors3[1].why)
end

describe('the published range is the enforced range')
do
    -- The bound appears in three places -- the rejection message, `brconfig`,
    -- and the admin console's config page -- and all three read Ov.bounds().
    -- This is what stops the page telling an operator 1..16 while the parser
    -- believes something else.
    local env = load(nil)
    local Ov  = env.BR.Config.Overrides

    for _, s in ipairs(Ov.SPEC) do
        if s.kind == 'int' then
            local lo, hi = Ov.bounds(s)
            local text   = Ov.rangeText(s)

            ok(text:find(tostring(lo), 1, true) ~= nil
               and text:find(tostring(hi), 1, true) ~= nil,
                ('%s publishes its real bounds'):format(s.convar), text)

            local atLo = Ov.parse(s, tostring(lo))
            local atHi = Ov.parse(s, tostring(hi))
            ok(atLo == lo and atHi == hi,
                ('%s accepts both ends of the range it publishes'):format(s.convar))

            local under = Ov.parse(s, tostring(lo - 1))
            local over  = Ov.parse(s, tostring(hi + 1))
            ok(under == nil and over == nil,
                ('%s rejects one step outside it'):format(s.convar))
        end
    end
end

-- --------------------------------------------------------------- drift -----

describe('a renamed config key is a hard failure')
do
    -- THE ORPHAN THIS PROJECT KEEPS PRODUCING, in its newest possible form. If
    -- config/match.lua renames maxSquadSize and the spec is not updated, a bare
    -- assignment would create a NEW key that nothing reads: the operator sets
    -- 2, the boot banner says 2, and the game plays four. Refusing to write a
    -- key that does not already exist is what makes that impossible.
    local env = load(nil)
    env.BR.Config.Match.maxSquadSize = nil

    local applied, errors = env.BR.Config.Overrides.apply(readerFor({ br_maxSquadSize = '2' }))

    ok(#applied == 0, 'nothing is applied to a key that has moved')
    ok(#errors == 1 and errors[1].why:find('does not exist', 1, true) ~= nil,
        'and the failure says the key does not exist', errors[1] and errors[1].why)
    ok(env.BR.Config.Match.maxSquadSize == nil,
        'no replacement key is invented')
end

-- ------------------------------------------------------------ reporting ----

describe('the report says which value is live')
do
    local env = load(nil)
    local Ov  = env.BR.Config.Overrides
    Ov.apply(readerFor({ br_maxSquadSize = '2' }))

    local lines, overridden = Ov.report()
    ok(#lines == #Ov.SPEC, 'every setting gets a line, set or not',
        ('%d lines for %d settings'):format(#lines, #Ov.SPEC))
    ok(overridden == 1, 'the overridden count is what apply() actually did',
        tostring(overridden))

    local joined = table.concat(lines, '\n')

    local squad, warm
    for _, l in ipairs(lines) do
        if l:find('maxSquadSize', 1, true) then squad = l end
        if l:find('warmupSeconds', 1, true) then warm = l end
    end

    ok(squad ~= nil and squad:find('br_maxSquadSize', 1, true) ~= nil
       and squad:find('2', 1, true) ~= nil,
        'the overridden line names the convar and the value it produced', squad)
    ok(squad ~= nil and squad:find('default 4', 1, true) ~= nil,
        'and says what it displaced, so the two representations are on one line', squad)
    ok(warm ~= nil and warm:find('default', 1, true) ~= nil
       and warm:find('br_warmupSeconds', 1, true) ~= nil,
        'an untouched setting says it is on the default and names the convar '
        .. 'that would change it', warm)

    -- The report is derived from the config table, so it cannot claim an
    -- override that did not land. Break the value behind its back and the
    -- report must follow.
    env.BR.Config.Match.maxSquadSize = 9
    local after = table.concat(Ov.report(), '\n')
    ok(after:find('9', 1, true) ~= nil and joined:find('9', 1, true) == nil,
        'the report reads the live table rather than remembering what it set')
end

-- ------------------------------------------------------- the load-time hook --

describe('the load-time hook')
do
    -- The path that actually runs on a server, exercised end to end: the file
    -- is loaded exactly as br_core's manifest loads it, with stubbed natives.

    local function serverEnv(convars, sink)
        return {
            IsDuplicityVersion = function() return true end,
            GetConvar = function(name, default)
                local v = convars[name]
                if v == nil then return default end
                return v
            end,
            print = function(s) if sink then sink[#sink + 1] = tostring(s) end end,
        }
    end

    local env, err = load(serverEnv({ br_maxSquadSize = '2' }))
    ok(err == nil, 'a server state with a valid convar loads', err)
    ok(env.BR.Config.Match.maxSquadSize == 2,
        'and the override is in place by the time the file has finished loading',
        tostring(env.BR.Config.Match.maxSquadSize))

    -- THE CLIENT. config/*.lua is loaded into the client's Lua state too, and
    -- the override must not run there: nothing below in this suite would catch
    -- a client and server disagreeing, because there is no client to ask.
    -- Keeping the client on the committed default is what makes "server-read
    -- only" enforceable at all.
    --
    -- THE CONVAR IS DELIBERATELY READABLE IN THIS STUB. An earlier version of
    -- this case handed the client a GetConvar that returned nothing, so it
    -- passed just as happily with the server-only guard deleted -- a test that
    -- asserted the stub rather than the code. The client must be offered a real
    -- value and still refuse it.
    local cenv = load({
        IsDuplicityVersion = function() return false end,
        GetConvar = function(name, d)
            if name == 'br_maxSquadSize' then return '2' end
            return d
        end,
    })
    ok(cenv.BR.Config.Match.maxSquadSize == 4,
        'a client state ignores convars it can plainly read, and keeps the '
        .. 'committed default',
        tostring(cenv.BR.Config.Match.maxSquadSize))

    -- The bare state: tools/config_report.lua, tools/check_pois.lua and every
    -- other suite. verify.sh depends on config/*.lua loading with no FXServer
    -- natives present at all.
    local benv, berr = load(nil)
    ok(berr == nil, 'a bare Lua state with no natives loads', berr)
    ok(benv.BR.Config.Match.maxSquadSize == 4, 'and gets the committed default')

    -- The failure. A bad value must stop the resource rather than start a
    -- server nobody asked for, and it must say so in words first.
    local sink = {}
    local fenv, ferr = load(serverEnv({ br_maxSquadSize = '0' }, sink))
    ok(ferr ~= nil, 'an invalid convar makes the file REFUSE TO LOAD, failing the resource',
        'it loaded cleanly')
    local banner = table.concat(sink, '\n')
    ok(banner:find('br_maxSquadSize', 1, true) ~= nil,
        'and the banner printed first names the setting', banner)
    ok(banner:find('REFUSED TO START', 1, true) ~= nil,
        'and says plainly that nothing started')
    ok(fenv.BR.Config.Match.maxSquadSize == 4,
        'the refused value was never written', tostring(fenv.BR.Config.Match.maxSquadSize))
end

-- ------------------------------------------------- the server-only property --
--
-- TWO STRUCTURAL PROPERTIES ARE ASSERTED IN tools/verify.sh, NOT HERE, and the
-- reason is portability rather than taste: both need to walk directories, and
-- Lua cannot list one without io.popen -- which spawns cmd.exe on the Windows
-- checkout this repo is developed on, where `ls` does not exist. A gate that
-- silently scans zero files is worse than no gate, so they live with the other
-- text gates, in bash, next to `find`:
--
--   * no br_*/client/*.lua reads an overridable key (the override only ever
--     runs in the server's Lua state, so a client read is two numbers for one
--     setting with nothing comparing them);
--   * every fxmanifest that pulls in config/match.lua pulls in
--     config/overrides.lua after it.
--
-- Everything above and below this line needs no directory walk and stays here.

-- ------------------------------------------------------ the shipped cfgs ----

--- Extract the ACTIVE convar assignments from a FiveM .cfg.
--- Commented lines are ignored, exactly as FXServer ignores them.
local function cfgConvars(text)
    local out, order = {}, {}
    for lineText in ((text or '') .. '\n'):gmatch('([^\n]*)\n') do
        local trimmed = lineText:gsub('^%s+', '')
        if trimmed ~= '' and not trimmed:match('^#') then
            local name, value = trimmed:match('^sets?r?a?%s+([%w_]+)%s+(.+)$')
            if name then
                value = value:gsub('%s+$', '')
                local quoted = value:match('^"(.-)"')
                if quoted then value = quoted end
                if out[name] == nil then order[#order + 1] = name end
                out[name] = value
            end
        end
    end
    return out, order
end

describe('the shipped dev cfg')
do
    -- THE EXAMPLE IS THE THING THE OWNER COPIES ONTO THE BOX, so a typo in it
    -- is a server that will not boot -- discovered on the box, at the start of
    -- a playtest. Running it through the real parser here moves that discovery
    -- to a red build.
    local text = slurp('tunables.dev.cfg.example')
    ok(text ~= nil, 'tunables.dev.cfg.example exists')

    local env  = load(nil)
    local Ov   = env.BR.Config.Overrides
    local set, order = cfgConvars(text)

    local byConvar = {}
    for _, s in ipairs(Ov.SPEC) do byConvar[s.convar] = s end

    -- Convars the file may legitimately set that this layer does not own.
    -- br_devMode predates it and is read by br_core/server/main.lua; it belongs
    -- in the dev cfg for the same reason everything else there does.
    local KNOWN_EXTRA = { br_devMode = true }

    local unknown, invalid = {}, {}
    for _, name in ipairs(order) do
        local spec = byConvar[name]
        if spec then
            local v, why = Ov.parse(spec, set[name])
            if v == nil then invalid[#invalid + 1] = ('%s %s'):format(name, tostring(why)) end
        elseif not KNOWN_EXTRA[name] then
            unknown[#unknown + 1] = name
        end
    end

    ok(#unknown == 0, 'every convar it sets is one something actually reads',
        #unknown > 0 and table.concat(unknown, ', ') or nil)
    ok(#invalid == 0, 'and every value it sets passes the real parser',
        #invalid > 0 and table.concat(invalid, '\n       ') or nil)

    -- THE RANGES THE FILE PROMISES ARE THE RANGES THE PARSER ENFORCES.
    --
    -- This file tells the operator what they may type, in prose, beside each
    -- setting -- and prose is exactly where a bound goes stale after somebody
    -- widens it in the spec. Requiring the literal `lo..hi` to appear makes
    -- changing a bound without updating its documentation a red build.
    local stale = {}
    for _, s in ipairs(Ov.SPEC) do
        if s.kind == 'int' then
            local lo, hi = Ov.bounds(s)
            local want = ('%d..%d'):format(lo, hi)
            if not text:find(want, 1, true) then
                stale[#stale + 1] = ('%s enforces %s, which the file never says')
                    :format(s.convar, want)
            end
        end
    end
    ok(#stale == 0, 'and every range it documents is the range that is enforced',
        #stale > 0 and table.concat(stale, '\n       ') or nil)

    -- THE OWNER'S ACTUAL REQUEST, pinned. Three clients and a maximum of four
    -- is one squad and no enemy; 2 is what puts a second squad on the map.
    ok(set.br_maxSquadSize == '2',
        'it sets br_maxSquadSize to 2 -- the reason this feature was asked for',
        tostring(set.br_maxSquadSize))

    -- And the committed default is NOT 2. If somebody "helpfully" hardcodes it
    -- later, the dev cfg becomes a no-op and the public server ships duos.
    ok(PRISTINE.BR.Config.Match.maxSquadSize == 4,
        'while the committed default stays 4, so the split still means something',
        tostring(PRISTINE.BR.Config.Match.maxSquadSize))
end

describe('the shipped public cfg')
do
    local text = slurp('tunables.public.cfg.example')
    ok(text ~= nil, 'tunables.public.cfg.example exists')

    local _, order = cfgConvars(text)
    ok(#order == 0,
        'it sets nothing at all -- copying it over tunables.cfg restores every '
        .. 'committed default',
        #order > 0 and table.concat(order, ', ') or nil)
end

describe('server.cfg.example execs before it ensures')
do
    -- The ordering requirement, asserted on the document the owner copies from.
    -- An exec below the ensure block sets every convar correctly and changes
    -- nothing about the game, which is the failure this whole file exists to
    -- make impossible to reach by accident.
    local text = slurp('server.cfg.example') or ''

    local execAt = text:find('exec%s+"?tunables%.cfg')
    ok(execAt ~= nil, 'it execs tunables.cfg')

    local ensureAt = text:find('\nensure br_')
    ok(ensureAt ~= nil, 'it has an `ensure br_` block')

    ok(execAt ~= nil and ensureAt ~= nil and execAt < ensureAt,
        'and the exec comes BEFORE the first `ensure br_`',
        ('exec at %s, first ensure at %s'):format(tostring(execAt), tostring(ensureAt)))

    ok(text:find('ABOVE', 1, true) ~= nil and text:find('tunables', 1, true) ~= nil,
        'and says out loud that the order matters, where somebody editing '
        .. 'server.cfg will read it')
end

-- ----------------------------------------------------------------- result ---

io.write(('\n%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')

-- Server-tunable overrides: the handful of config values a DEV SERVER wants
-- different from the public one, moved onto convars so the difference is one
-- `.cfg` file rather than one edited-and-never-committed Lua file.
--
-- THE SHAPE OF THE THING
--
--   server.cfg           exec "tunables.cfg"      <- BEFORE every `ensure br_*`
--   tunables.cfg         set br_maxSquadSize 2
--   this file            reads it, validates it, writes BR.Config.Match.maxSquadSize
--
-- Swapping which file server.cfg execs is what turns the public server into the
-- dev server. Copy tunables.dev.cfg.example over it for a dev box,
-- tunables.public.cfg.example for a public one. Both are tracked in the repo;
-- the live `tunables.cfg` is not, exactly as server.cfg is not.
--
-- ---------------------------------------------------------------------------
-- WHY THE ORDERING IS THE WHOLE FEATURE, AND WHAT BREAKS WITHOUT IT
--
-- These values are not all read lazily. br_core/server/match.lua builds its
-- DURATION table AT FILE LOAD from M.warmupSeconds and M.endedSeconds, so by
-- the time br_core is running, those two numbers have already been copied
-- somewhere this file can no longer reach. The override therefore has to land
-- BEFORE br_core loads, which means:
--
--   1. the convar must be set before `ensure br_core` -- so the exec line goes
--      above the gamemode block in server.cfg; and
--   2. this file must be a shared_script listed AFTER every config it edits and
--      before any file that reads them -- fxmanifest.lua in br_core does that,
--      and tools/test_config.lua fails the build if a manifest loads
--      config/match.lua without loading this one after it.
--
-- IF (1) IS VIOLATED the failure is silent in the worst way: the convars are
-- set, `configreport` shows them set, and the game runs on the hardcoded
-- defaults anyway. That is why boot prints a line per setting saying which
-- source won, and why br_core re-reads the convars ten seconds after start and
-- shouts if they have appeared since. "It says 2 in my cfg and squads are still
-- four" must not be a mystery for more than one console line.
--
-- ---------------------------------------------------------------------------
-- WHAT IS DELIBERATELY NOT HERE
--
-- A config surface that exposes everything is one nobody can reason about, so
-- the bar for a setting appearing below is: a dev server genuinely wants it
-- different, it is a single scalar, and IT IS READ ONLY ON THE SERVER.
--
-- That last clause is a hard rule, not a preference. config/*.lua is pulled
-- into the CLIENT's Lua state too, and this file only ever applies overrides on
-- the server (see the guard at the bottom). Overriding a value the client also
-- reads would give the two sides different numbers for the same setting with
-- nothing comparing them -- which is this project's signature bug, freshly
-- installed. tools/test_config.lua scans br_*/client/ for every key named below
-- and fails the build if one turns up there.
--
-- So, excluded on purpose:
--
--   engineTeams      client-read (br_core/client/natives.lua decides the team).
--   dbnoRevive*      client-read (br_core/client/squadmates.lua).
--   storm phases     client-read; br_core/client/storm.lua renders from the
--                    same table, and docs/match-math.md's arithmetic is built
--                    on it. A shorter storm is a different game, not a
--                    different server.
--   loot density     there is no density scalar to expose. The shape is
--                    per-tier tables (budgetPerTier, chestsPerTier); a convar
--                    that has to encode a table is exactly the surface nobody
--                    can reason about.
--   maxPlayers       the OneSync ceiling. Wrong here is a server that drops off
--                    the public list, and sv_maxclients has to agree with it.
--   minToStart       already has a dev switch: br_devMode, read by
--                    br_core/server/main.lua, which picks minToStart over
--                    minToStartProd. A second way to say the same thing is a
--                    second thing to disagree with.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Overrides = BR.Config.Overrides or {}

local Ov = BR.Config.Overrides

-- ---------------------------------------------------------------------------
-- THE SPEC. One row per overridable setting, and this table is the only place
-- the convar names are written down -- the cfg examples, the boot banner, the
-- `brconfig` dump and tools/config_report.lua all read it rather than repeating
-- it. A convar this file does not name is a convar nothing reads.
--
--   convar  the name an operator types in a .cfg
--   group   BR.Config.<group> -- 'Match' today, and nothing forces it to stay
--           that way
--   key     the field inside it. It MUST already exist: a rename that leaves
--           this behind is a hard boot failure, not a new orphan key.
--   kind    'int', 'bool' or 'url'. All three are parsed strictly; see parse().
--   min/max inclusive bounds for 'int'. OUT OF RANGE IS REFUSED, NEVER CLAMPED
--           -- a clamp answers a question the operator did not ask and looks
--           exactly like the setting not working.
--   floor   optional. A bound derived from another config value, so the two
--           cannot drift apart. Applied on top of min (the larger wins).
-- ---------------------------------------------------------------------------

Ov.SPEC = {
    {
        convar = 'br_maxSquadSize',
        group  = 'Match',
        key    = 'maxSquadSize',
        kind   = 'int',
        min    = 1,
        max    = 16,
        -- THE REASON THIS FEATURE EXISTS. Three dev clients and a maximum of
        -- four put all three in one squad, so cross-squad friendly fire and
        -- nearby-versus-squad voice cannot be produced in game at all. At 2,
        -- three clients are two squads (2 + 1) and both are on screen.
        --
        -- The public default stays 4 in config/match.lua. It is the dev cfg
        -- that says 2, which is the entire point of the split.
        note   = 'players per squad',
    },
    {
        convar = 'br_warmupSeconds',
        group  = 'Match',
        key    = 'warmupSeconds',
        kind   = 'int',
        min    = 5,
        max    = 600,
        -- 45s of standing on the airstrip, every single iteration. This is the
        -- largest fixed cost in a playtest loop and the cheapest to remove.
        --
        -- Safe to take below warmupShortened (15): the "lobby is full" cut only
        -- ever moves endsAt EARLIER (shortenWarmupIfFull returns when the cap is
        -- already later), so a short warmup cannot be lengthened by it.
        note   = 'lobby warmup',
    },
    {
        convar = 'br_endedSeconds',
        group  = 'Match',
        key    = 'endedSeconds',
        kind   = 'int',
        min    = 5,
        max    = 300,
        -- The summary screen. 20s per match on a loop you are running twenty
        -- times an afternoon.
        --
        -- FLOORED BY coverSweepMs, not by a number typed here. ENDED is also
        -- the window the server has to sweep a player home without ever
        -- hearing from their page; cut it below that deadline and CLEANUP
        -- inherits a rescue it was never meant to perform. Deriving the floor
        -- means the day coverSweepMs moves, this moves with it.
        floor  = function(cfg)
            local ms = cfg.coverSweepMs
            if type(ms) ~= 'number' then return nil end
            return math.ceil(ms / 1000)
        end,
        floorNote = 'coverSweepMs, the server-side sweep deadline',
        note   = 'summary screen',
    },
    {
        convar = 'br_partyGraceSeconds',
        group  = 'Match',
        key    = 'partyGraceSeconds',
        kind   = 'int',
        -- ZERO IS A REAL SETTING HERE, not a broken one: "start the moment the
        -- ready-ups clear the gate, never wait for a straggler". It is also the
        -- value Lua is least helpful about -- `if v then` is true for 0 -- which
        -- is why nothing below tests a parsed number for truthiness.
        min    = 0,
        max    = 300,
        note   = 'wait for a partymate',
    },
    {
        convar = 'br_autofill',
        group  = 'Match',
        key    = 'autofill',
        kind   = 'bool',
        -- config/match.lua's own note says to turn this off to test as two
        -- one-player squads. That instruction currently means "edit a tracked
        -- file and remember to put it back"; here it means "one line in the dev
        -- cfg".
        note   = 'top up squads with solos',
    },
    {
        convar = 'br_dbnoBleedBase',
        group  = 'Match',
        key    = 'dbnoBleedBase',
        kind   = 'int',
        min    = 5,
        max    = 600,
        -- Two minutes of bleeding out is right for a real match and is a long
        -- time to sit through when what you are testing is the revive prompt.
        --
        -- FLOORED BY dbnoBleedMin FOR A SPECIFIC REASON. server/combat.lua
        -- computes `base + step * (n - 1)` and then floors the result at
        -- dbnoBleedMin -- so a base BELOW that floor is silently ignored, and
        -- the operator sees 40s after asking for 20 with nothing saying why.
        -- Refusing it names the conflict instead.
        floor  = function(cfg)
            local m = cfg.dbnoBleedMin
            if type(m) ~= 'number' then return nil end
            return m
        end,
        floorNote = 'dbnoBleedMin, below which combat.lua silently floors it',
        note   = 'first-knock bleed-out',
    },
    {
        convar = 'br_adminConsoleUrl',
        group  = 'Admin',
        key    = 'consoleUrl',
        kind   = 'url',
        -- THE ADMIN TAB IN THE PAUSE MENU (#23). Unset is the default and the
        -- default is OFF: no tab, no HTTP call, no mention anywhere except one
        -- line in the boot banner. That is the whole licence for the feature --
        -- the game must never depend on Ringmaster, so a server with no console
        -- configured has to be a server that plays exactly as it did before.
        --
        -- IT IS THE ONE ENTRY HERE WITH NO REVIEWED DEFAULT TO OVERRIDE, and
        -- that is worth noticing rather than smoothing over. Every other row is
        -- a number br_lib/config/ committed and a dev box wants different; this
        -- is an address that exists only per deployment. It lives here because
        -- this is the only mechanism in the project that gives a convar a strict
        -- parse, a hard boot failure, a boot banner line and a `brconfig` line,
        -- and #23 asked for all four.
        note   = 'admin console origin',
    },
}

-- ---------------------------------------------------------------------------
-- Parsing. A convar is a STRING, always, and every interesting failure here is
-- a string that looks almost right.
-- ---------------------------------------------------------------------------

--- Trim surrounding whitespace.
--- @param s string
--- @return string
local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Strict integer parse.
---
--- `tonumber` is far too generous for this job: it takes '2.5', '0x10' and
--- '2e3' happily, and it takes '' to nil rather than to a complaint. A convar
--- holding '2.5' for a squad size is a typo, and a typo must be refused rather
--- than rounded into something playable-looking. So the digits are matched
--- first and tonumber is only asked to convert what has already been proven to
--- be an integer literal.
---
--- Surrounding whitespace IS forgiven, and only that: a stray space either side
--- of a number in a .cfg is not a mistake anybody needs telling about, while
--- '4 ok' still fails, because the thing after the number might have been meant
--- to matter.
--- @param raw string
--- @return integer|nil value
--- @return string|nil why
local function parseInt(raw)
    local s = trim(raw)
    if s == '' then return nil, 'is empty' end
    if not s:match('^%-?%d+$') then
        return nil, ("is not a whole number (got '%s')"):format(s)
    end
    local v = tonumber(s)
    if v == nil then return nil, ("is not a whole number (got '%s')"):format(s) end
    return math.tointeger(v) or v, nil
end

--- Strict boolean parse.
---
--- FiveM's own convention is the words true/false; 1/0 is accepted because
--- half the engine convars in server.cfg are written that way and an operator
--- copying the style of the line above should not be punished for it. NOTHING
--- ELSE is accepted -- 'yes', 'on' and 'True ' would each otherwise have to
--- fall somewhere, and every choice of where is a surprise to somebody.
--- @param raw string
--- @return boolean|nil value
--- @return string|nil why
local function parseBool(raw)
    local s = trim(raw):lower()
    if s == 'true' or s == '1' then return true, nil end
    if s == 'false' or s == '0' then return false, nil end
    return nil, ("is not true or false (got '%s')"):format(trim(raw))
end

--- Strict ORIGIN parse: scheme, host, optional port, and nothing else.
---
--- THIS IS STRICTER THAN "IS IT A URL" ON PURPOSE, AND EVERY REFUSAL BELOW IS A
--- REAL FAILURE THIS PROJECT WOULD OTHERWISE SHIP SILENTLY.
---
--- A TRAILING SLASH IS THE ONE THAT MATTERS MOST. The value is not only fetched,
--- it is COMPARED: the page refuses a postMessage whose `event.origin` is not
--- exactly this string, and that handler's entire job is to trigger the minting
--- of an admin session. `event.origin` is always bare -- browsers never put a
--- path or a trailing slash in it -- so `https://ringmaster.example/` can never
--- equal any origin any browser will ever produce. It would not error. The
--- comparison would simply always be false, the mint would never be asked for,
--- and the admin would look at a login page forever with nothing in any log.
--- One character, and the only symptom is a feature that does not work.
---
--- HTTPS IS REQUIRED, AND THAT IS A FACT ABOUT THE CONSOLE RATHER THAN A
--- PREFERENCE. A console framed by the NUI page is a third-party context, so its
--- session cookie has to be `SameSite=None`, and `SameSite=None` is only honoured
--- with `Secure`. The console derives both from its own AUTH_URL
--- (`sessionSameSite(secureCookies(AUTH_URL))` in fivem-ringmaster's
--- lib/handoff.ts): an http deployment gets `Lax` cookies, which are not sent
--- inside a frame at all. So an http origin here does not degrade -- the handoff
--- cannot work even once. Refusing it at boot beats debugging it at 2am.
---
--- @param raw string
--- @return string|nil value
--- @return string|nil why
local function parseUrl(raw)
    local s = trim(raw)
    if s == '' then return nil, 'is empty' end

    local scheme, rest = s:match('^(%a[%w+.-]*)://(.*)$')
    if scheme == nil then
        return nil, ("is not an origin -- it must look like "
                     .. "https://console.example (got '%s')"):format(s)
    end

    if scheme:lower() ~= 'https' then
        return nil, ("uses '%s://', but the console's session cookie is only "
                     .. "sent inside a frame over https (got '%s')")
                    :format(scheme:lower(), s)
    end

    -- Everything after the authority. A path, a query or a fragment all mean
    -- the operator wrote a URL where an origin was asked for.
    local stray = rest:match('[/?#]')
    if stray ~= nil then
        return nil, ("must be a bare origin with no path -- remove everything "
                     .. "from the '%s' onwards (got '%s')"):format(stray, s)
    end

    -- user:password@host. Nothing legitimate puts credentials here, and a
    -- browser's `event.origin` would not carry them anyway.
    if rest:find('@', 1, true) ~= nil then
        return nil, ("must not carry credentials (got '%s')"):format(s)
    end

    local host, port = rest:match('^(.-):(%d*)$')
    if host == nil then host = rest end

    if host == '' then
        return nil, ("names no host (got '%s')"):format(s)
    end
    -- Letters, digits, hyphens and dots, starting and ending on a letter or
    -- digit. Deliberately not a full IDN or IPv6 grammar: what goes here is the
    -- name a TLS certificate was issued for, and those are all in this subset.
    if host:match('^[A-Za-z0-9][A-Za-z0-9%-%.]*$') == nil
       or host:match('[A-Za-z0-9]$') == nil
       or host:find('..', 1, true) ~= nil then
        return nil, ("is not a hostname: '%s'"):format(host)
    end

    if port ~= nil then
        -- `port == ''` is a bare trailing colon, which is the shape of a typo
        -- rather than of a default port.
        local p = tonumber(port)
        if p == nil or p < 1 or p > 65535 then
            return nil, ("has a port of '%s', which is not 1..65535"):format(port)
        end
    end

    -- Returned normalised on the scheme only. The HOST IS LEFT EXACTLY AS
    -- TYPED: a browser lowercases the host when it builds `event.origin`, so
    -- lowercasing here would agree -- but it would also mean the string in the
    -- banner is not the string in the .cfg, and a value that quietly changes
    -- shape between what an operator wrote and what a comparison uses is the
    -- class of bug this parser exists to prevent. A capitalised host is refused
    -- by the pattern above instead, where it can be read about.
    if host:match('%u') ~= nil then
        return nil, ("has a capital letter in the host: '%s'. A browser reports "
                     .. "the origin lowercased, so the two would never match")
                    :format(host)
    end

    return ('https://%s'):format(rest), nil
end

--- Resolve one spec entry's effective bounds, honouring `floor`.
---
--- PUBLIC BECAUSE THE RANGE IS PUBLISHED IN THREE PLACES -- the rejection
--- message here, the `brconfig` dump, and the admin console's config page --
--- and a range the operator is shown that differs from the range the parser
--- enforces is worse than showing no range at all. One function, three callers.
--- @param spec table
--- @return integer|nil lo
--- @return integer|nil hi
--- @return string|nil floorWhy what raised the floor above spec.min, if anything
function Ov.bounds(spec)
    local cfg = BR.Config[spec.group]
    local lo, why = spec.min, nil
    if spec.floor and type(cfg) == 'table' then
        local f = spec.floor(cfg)
        if type(f) == 'number' and (lo == nil or f > lo) then
            lo, why = f, spec.floorNote
        end
    end
    return lo, spec.max, why
end

--- Parse and range-check one raw convar value against its spec.
---
--- Returns nil PLUS A REASON on every rejection. The reason is the product
--- here: it is what the operator reads at 2am, so it names the value they
--- typed and the range they may type instead.
--- @param spec table
--- @param raw string
--- @return boolean|integer|nil value
--- @return string|nil why
function Ov.parse(spec, raw)
    if type(raw) ~= 'string' then
        return nil, 'is not a string'
    end

    if spec.kind == 'bool' then
        return parseBool(raw)
    end

    if spec.kind == 'url' then
        return parseUrl(raw)
    end

    if spec.kind ~= 'int' then
        return nil, ("has an unknown kind '%s' in the spec"):format(tostring(spec.kind))
    end

    local v, why = parseInt(raw)
    -- `v == nil`, never `not v`. 0 is TRUTHY in Lua, so the two happen to agree
    -- today -- but partyGraceSeconds already has 0 as a real setting, nil is
    -- the only failure sentinel this file uses, and a `not v` written here is
    -- how the next legitimate zero gets read as a parse failure.
    if v == nil then return nil, why end

    local lo, hi, floorWhy = Ov.bounds(spec)

    if lo ~= nil and v < lo then
        if floorWhy then
            return nil, ('is %d, below the minimum of %d (%s)'):format(v, lo, floorWhy)
        end
        return nil, ('is %d, below the minimum of %d'):format(v, lo)
    end
    if hi ~= nil and v > hi then
        return nil, ('is %d, above the maximum of %d'):format(v, hi)
    end

    return v, nil
end

-- ---------------------------------------------------------------------------
-- Application.
-- ---------------------------------------------------------------------------

--- What the last apply() did. Read by the boot banner, `brconfig` and the
--- ten-second recheck; empty until apply() runs, which on a bare Lua state
--- (tools/config_report.lua, the unit tests) it never does.
Ov.applied = {}
Ov.errors  = {}

--- Apply every override the reader can supply.
---
--- `read(name)` returns the raw convar string, or nil / '' for "not set". BOTH
--- SPELLINGS MEAN ABSENT, deliberately: GetConvar returns its default only when
--- the convar is UNSET, so `set br_maxSquadSize ""` is set-to-empty and would
--- otherwise sail past the default straight into the parser. br_ringmaster's
--- config.lua collapses the two for the same reason.
---
--- NOTHING IS MUTATED FOR A VALUE THAT DOES NOT PARSE. A rejected setting keeps
--- the hardcoded default and lands in `errors`; the caller decides how loud
--- that is. This function never prints and never raises, so it is testable
--- without a server.
--- @param read function
--- @return table applied
--- @return table errors
function Ov.apply(read)
    local applied, errors = {}, {}

    for _, spec in ipairs(Ov.SPEC) do
        local raw = read(spec.convar)

        if raw ~= nil and raw ~= '' then
            local cfg = BR.Config[spec.group]

            -- THE ANTI-DRIFT CHECK, and it is the reason this is a hard error
            -- rather than a shrug. If config/match.lua renames maxSquadSize,
            -- assigning through this spec would create a BRAND NEW key that
            -- nothing reads -- the operator sets 2, the boot banner cheerfully
            -- reports 2, and the game plays four. A missing key is a build
            -- error in tools/test_config.lua and a boot failure here.
            if type(cfg) ~= 'table' or cfg[spec.key] == nil then
                errors[#errors + 1] = {
                    convar = spec.convar,
                    raw    = raw,
                    why    = ('names BR.Config.%s.%s, which does not exist -- '
                              .. 'the setting was renamed or removed')
                             :format(spec.group, tostring(spec.key)),
                }
            else
                local value, why = Ov.parse(spec, raw)
                if value == nil then
                    errors[#errors + 1] = { convar = spec.convar, raw = raw, why = why }
                else
                    local before = cfg[spec.key]
                    cfg[spec.key] = value
                    applied[#applied + 1] = {
                        convar = spec.convar,
                        group  = spec.group,
                        key    = spec.key,
                        from   = before,
                        to     = value,
                    }
                end
            end
        end
    end

    Ov.applied, Ov.errors = applied, errors
    return applied, errors
end

--- Look up what apply() did to one setting, by key.
--- @param key string
--- @return table|nil
function Ov.appliedFor(key)
    for _, a in ipairs(Ov.applied) do
        if a.key == key then return a end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Observability.
--
-- Every one of these settings now has TWO places it could be written down --
-- the Lua default and the cfg -- and an operator staring at a server that will
-- not do what they typed needs to be told which one won. So the report covers
-- EVERY spec entry, not only the overridden ones: "br_warmupSeconds is not set"
-- is the answer to half the questions this feature will generate.
-- ---------------------------------------------------------------------------

--- Format one value the way an operator wrote it.
local function show(v)
    if type(v) == 'boolean' then return tostring(v) end
    -- AN EMPTY STRING IS A SETTING, AND IT IS THE COMMONEST ONE. `consoleUrl`
    -- defaults to '', so a report that printed it verbatim would leave a blank
    -- column in the boot banner and in `brconfig` -- which reads as the report
    -- being broken rather than as the feature being off. The words are the
    -- product here, the same way they are in the rejection messages.
    if type(v) == 'string' then
        if trim(v) == '' then return '(unset)' end
        return v
    end
    if type(v) == 'number' then
        if math.type(v) == 'integer' or v == math.floor(v) then
            return ('%d'):format(math.floor(v))
        end
        return ('%s'):format(v)
    end
    return tostring(v)
end

--- What an operator is allowed to type, in words, straight from the bounds the
--- parser will actually enforce. Used by tools/config_report.lua, which renders
--- it on the admin console's config page -- the one surface where somebody is
--- reading the range without the rejection message in front of them.
--- @param spec table
--- @return string
function Ov.rangeText(spec)
    if spec.kind == 'bool' then return 'true or false' end
    -- No bounds to state, so it states the SHAPE instead -- which is what the
    -- operator gets wrong. Both halves of this sentence are refusals the parser
    -- actually makes, not advice.
    if spec.kind == 'url' then
        return 'an https:// origin with no path or trailing slash'
    end

    local lo, hi, why = Ov.bounds(spec)
    local text
    if lo ~= nil and hi ~= nil then
        text = ('%s..%s'):format(show(lo), show(hi))
    elseif lo ~= nil then
        text = ('%s or more'):format(show(lo))
    elseif hi ~= nil then
        text = ('%s or less'):format(show(hi))
    else
        text = 'any whole number'
    end
    if why then text = ('%s (lower bound from %s)'):format(text, why) end
    return text
end

--- Boot / `brconfig` lines: one per setting, live value first, then where it
--- came from. Returns lines rather than printing them, the same way
--- br_ringmaster's config report does, so the caller owns the banner and this
--- stays testable outside a server.
--- @return table lines
--- @return integer overridden how many came from a convar
function Ov.report()
    local lines, n = {}, 0

    for _, spec in ipairs(Ov.SPEC) do
        local cfg   = BR.Config[spec.group]
        local live  = cfg and cfg[spec.key]
        local hit   = Ov.appliedFor(spec.key)

        if hit then
            n = n + 1
            lines[#lines + 1] = ('  %-22s %-26s %-8s <- %s (default %s)')
                :format(spec.key, spec.note or '', show(live), spec.convar, show(hit.from))
        else
            lines[#lines + 1] = ('  %-22s %-26s %-8s    default (%s is not set)')
                :format(spec.key, spec.note or '', show(live), spec.convar)
        end
    end

    return lines, n
end

--- The failure banner. Separate from report() because it has to survive being
--- read by somebody who has never seen this file: it says what was refused,
--- what they typed, what is allowed, and that nothing was applied.
--- @param errors table
--- @return table lines
function Ov.errorLines(errors)
    local lines = {}
    lines[#lines + 1] = 'REFUSED TO START: a tunable convar is not a value this server can use.'
    lines[#lines + 1] = ''
    for _, e in ipairs(errors) do
        lines[#lines + 1] = ('  %s %s'):format(e.convar, e.why)
        lines[#lines + 1] = ("      you set: '%s'"):format(tostring(e.raw))
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  Fix the line in the .cfg your server.cfg execs (tunables.cfg),'
    lines[#lines + 1] = '  or delete it to fall back to the value in br_lib/config/.'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  The gamemode is NOT STARTING, and that is deliberate. Booting on a'
    lines[#lines + 1] = '  value you did not ask for is how a bad number spends an afternoon'
    lines[#lines + 1] = '  looking like a gameplay bug.'
    return lines
end

-- ---------------------------------------------------------------------------
-- THE LOAD-TIME HOOK -- server only, and absent everywhere else.
--
-- config/*.lua is loaded into the CLIENT's Lua state as well, and by
-- tools/config_report.lua and the unit suites in a BARE Lua state with no
-- FXServer natives at all. All three must load this file and get exactly the
-- hardcoded defaults, which is what the two type() guards below buy: no
-- IsDuplicityVersion means "not a game", no GetConvar means the same. That is
-- also the property tools/verify.sh's config-report gate exists to protect.
-- ---------------------------------------------------------------------------

--- Is this the server's Lua state?
--- @return boolean
local function isServerState()
    if type(IsDuplicityVersion) ~= 'function' then return false end
    local ok, dup = pcall(IsDuplicityVersion)
    return ok and dup == true
end

if isServerState() and type(GetConvar) == 'function' then
    local _, errors = Ov.apply(function(name)
        return GetConvar(name, '')
    end)

    if #errors > 0 then
        print('[br_lib] ')
        print('[br_lib] ############################################################')
        for _, l in ipairs(Ov.errorLines(errors)) do
            print('[br_lib]   ' .. l)
        end
        print('[br_lib] ############################################################')
        print('[br_lib] ')
        -- Raising here fails the RESOURCE, which is the loudest thing available
        -- at config-load time and the only one that cannot be scrolled past. A
        -- server that boots with the wrong squad size looks fine.
        error('br_lib: refusing to start on an invalid tunable convar -- see the banner above', 0)
    end
end

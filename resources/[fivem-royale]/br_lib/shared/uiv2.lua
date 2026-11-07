-- UI v2 (#436): every redone screen, behind one server switch and one per
-- screen, and the one door every piece of it asks. The list of pieces is
-- br_lib/config/uiv2.lua.
--
-- Owner, 2026-11-07: "All this UI rework - can we make a server-side toggle
-- for it? One toggle for everything (market, locker v2, HUD, inventory, player
-- list, etc), and also a separate toggle for each component? Let's call
-- everything as a whole UI v2." And the same day: UI v2 is SEPARATE FROM THE
-- SEASON (the season decides what content exists, UI v2 how it looks, in any
-- season), and it switches LIVE FROM THE SERVER CONSOLE, ON PROD TOO, as a
-- kill switch: players get a change in the lobby or at their next match,
-- never mid-match.
--
-- ═══ TWO SWITCHES, READ ON ONE SIDE ═══
--
--   br_uiv2            UI v2 as a whole: on or off, off when unset
--   br_uiv2_<piece>    one piece: on or off wins either way; unset, the
--                      piece follows br_uiv2
--
-- Any other text is OFF, and the banner or the console says so: a typo in a
-- kill switch still kills. They are read in this file and nowhere else
-- (verify.sh's `ui v2 gates`, U4), by br_core's server only: BR.UIv2.boot()
-- as br_core starts, and BR.UIv2.recheck() every 5 s after, so a `set` typed
-- into the console is applied within 5 s. `bruiv2` (br_core/server/uiv2.lua)
-- writes the switch itself (BR.UIv2.flip) and applies it at once.
--
-- A FLIP OUTLIVES `restart br_core`, NOT AN FXSERVER RESTART: a convar outlives
-- the resource that wrote it, so a hotfix restart cannot bring back what was
-- killed, and server.cfg stays the one lasting truth. Every flip prints the
-- server.cfg line that keeps it. Boot never writes a switch; only a flip does.
--
-- ═══ THE ANSWER CROSSES UNDER ITS OWN NAME, br_uiv2Served ═══
--
-- The season module's two reasons for a separate served name hold here too
-- (br_lib/shared/season.lua): an unset box is never written into, and a typed
-- `setr` of a switch never reaches a client. br_core's server resolves the
-- switches into ONE value, every piece sorted, `locker=on,market=off`, and
-- replicates that. One value, so a client never applies half a flip (several
-- convars land one `setr` at a time); every piece in it, so "all off" is not
-- "not landed yet" (empty is unknown). Nobody types it: the 5 s re-read
-- writes it back, with one console line, when someone has.
--
-- ═══ EVERY CLIENT HOLDS ITS OWN ANSWER ═══
--
-- The server's answer moves the moment a switch moves; a player's must not
-- move mid-match. So br_core's client is the one place on a machine that
-- HOLDS an answer (BR.UIv2.hold, from br_core/client/uiv2.lua): it takes the
-- first one at once, and any while the loading screen is still up; after that
-- a new one only standing in the lobby with the entrance over, or on the
-- first pass out of the lobby as the next match starts, behind its curtain.
-- It keeps the one it has through every match state.
--
-- Every other client Lua state -- br_ui's -- is a MIRROR: it asks the holder
-- as it loads (`br:uiv2:ask`) and takes what it is told (`br:uiv2:held`, the
-- answer's text). A local event is synchronous on the one machine, and the
-- held answer exists only in br_core's Lua state, so the payload IS the
-- answer here, unlike a server message. Until told, every has() is false.
--
-- ═══ THE DOOR ═══
--
-- BR.UIv2.has('<piece>') answers the held answer on a client and the live
-- answer on br_core's server. An id with no row is off, printed once, and
-- RAISES under BR.UIv2.strict (the suites). Table reads only, everywhere.
-- Nothing may call has() while a file loads and keep the answer (the season
-- module's rule): a file that keeps a derived answer follows BR.UIv2.onChange,
-- or asks again in a loop pass, as Locker v2's gate does.
--
-- ═══ NOT THE SEASON, NOT DEV MODE ═══
--
-- Nothing here reads the season or dev mode, and neither of those reads this.
-- The season still decides what content exists: the Market piece on Season 1
-- has no Emotes tab, because the season has no dances.

BR = BR or {}
BR.UIv2 = BR.UIv2 or {}

--- UI v2 as a whole: what the operator sets in server.cfg. br_core's server
--- reads it, and nothing else does.
BR.UIv2.CONVAR = 'br_uiv2'
--- One piece's switch is this and its id: br_uiv2_market, br_uiv2_locker.
BR.UIv2.PREFIX = 'br_uiv2_'
--- What br_core's server replicates: every piece, resolved.
BR.UIv2.SERVED = 'br_uiv2Served'

--- THE TESTS' SWITCH. With it on, has() of an id with no row RAISES instead of
--- answering, and a follower that raises fails the move. Off in game.
if BR.UIv2.strict == nil then BR.UIv2.strict = false end

--- 'server' once boot() ran, 'holder' once hold() ran, nil: a mirror.
local role = nil
--- The answer in force here: [id] = boolean, nil while unknown.
local answer = nil
--- The same answer, spelled the one way (encode), so a move is a change of text.
local answerText = nil
--- br_core's server: the switches as last read, { whole = text, pieces =
--- { [id] = text } }, and why each piece answers what it does.
local read = nil
local whyOf = {}
--- The holder: its predicate, br_uiv2Served as last read, and how it reads it.
local standing = nil
local servedText = ''
local listening = false
local polledAt = nil
--- A served text that did not decode, so a pass does not decode it again.
local badText = nil
--- onChange()'s functions, called in order with (nowText, beforeText).
local watchers = {}
--- has() ids already reported as unknown, so a door asked every pass prints once.
local unknownSeen = {}

--- A runtime with no convar listener (none since FiveM 2024-10) re-reads the
--- served value at most this often.
local POLL_MS = 1000

-- ---------------------------------------------------------------------------
-- The list and the one spelling
-- ---------------------------------------------------------------------------

--- An id is lowercase letters and digits, from a letter: a convar name ignores
--- case, and br_uiv2_<id> must name exactly one switch.
local function isId(id)
    return type(id) == 'string' and id:match('^[a-z][a-z0-9]*$') ~= nil
end

--- The rows of br_lib/config/uiv2.lua, or an empty table.
local function rows()
    local cfg = BR.Config and BR.Config.UIv2
    local pieces = type(cfg) == 'table' and cfg.pieces or nil
    return type(pieces) == 'table' and pieces or {}
end

--- Every piece's id, sorted.
--- @return string[]
local function ids()
    local out = {}
    for id, row in pairs(rows()) do
        if isId(id) and type(row) == 'table' then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

--- An answer as br_uiv2Served holds it: `<id>=on` or `<id>=off`, sorted by id,
--- joined by commas. THE ONE SPELLING, so a move is a change of text.
--- @param t table  [id] = boolean
--- @return string
local function encode(t)
    local keys = {}
    for id, v in pairs(t) do
        if isId(id) and type(v) == 'boolean' then keys[#keys + 1] = id end
    end
    table.sort(keys)
    for i, id in ipairs(keys) do keys[i] = id .. (t[id] and '=on' or '=off') end
    return table.concat(keys, ',')
end

--- br_uiv2Served's text, read: [id] = boolean, or nil when it says nothing --
--- empty (not landed yet) or not in the one spelling. NO REGISTRY NEEDED: a
--- mirror may be told before config/uiv2.lua loads, and an id with no row is
--- simply never asked.
--- @param text any
--- @return table|nil
local function decode(text)
    if type(text) ~= 'string' or text == '' then return nil end
    local t = {}
    for part in (text .. ','):gmatch('([^,]*),') do
        local id, v = part:match('^([a-z][a-z0-9]*)=(%a+)$')
        if id == nil or (v ~= 'on' and v ~= 'off') then return nil end
        t[id] = v == 'on'
    end
    return t
end

--- An answer in words: `locker on, market off`.
--- @param t table|nil
--- @return string
local function words(t)
    if t == nil then return 'not known yet' end
    local keys = {}
    for id in pairs(t) do keys[#keys + 1] = id end
    table.sort(keys)
    for i, id in ipairs(keys) do keys[i] = id .. (t[id] and ' on' or ' off') end
    if #keys == 0 then return 'no pieces' end
    return table.concat(keys, ', ')
end

--- Move this state's answer and tell every follower, in the order they asked.
--- One that raises does not keep the rest from hearing it.
--- @param t table @param text string
local function move(t, text)
    local before = answerText
    answer, answerText = t, text
    local failed = nil
    for i = 1, #watchers do
        local okW, err = pcall(watchers[i], text, before)
        if not okW then
            print(('[br_lib] BR.UIv2.onChange: a follower raised -- %s'):format(tostring(err)))
            failed = failed or err
        end
    end
    -- The suites hear it as a failure rather than a console line.
    if failed ~= nil and BR.UIv2.strict then error(failed, 0) end
end

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

--- A switch's text: true (on), false (off), or nil (unset).
---
--- Trimmed and lowercased, so `set br_uiv2 ON ` is on. Any other text is OFF,
--- with 'bad' as the second return: a typo in a kill switch still kills.
--- @param raw any
--- @return boolean|nil on
--- @return string|nil why  'bad' when the text is not on, off or empty
function BR.UIv2.parse(raw)
    if type(raw) ~= 'string' then return nil end
    local s = raw:match('^%s*(.-)%s*$'):lower()
    if s == '' then return nil end
    if s == 'on' then return true end
    if s == 'off' then return false end
    return false, 'bad'
end

--- One piece's answer from the two switches' texts.
---
---   piece on or off          that, whatever UI v2 says   why 'piece'
---   piece garbled            off                         why 'bad'
---   piece unset, UI v2 set   UI v2's                     why 'whole'
---   piece unset, garbled     off                         why 'bad'
---   both unset               off                         why 'default'
--- @param wholeRaw any  br_uiv2's text
--- @param pieceRaw any  br_uiv2_<piece>'s text
--- @return boolean on
--- @return string why
function BR.UIv2.resolve(wholeRaw, pieceRaw)
    local p, pBad = BR.UIv2.parse(pieceRaw)
    if pBad then return false, 'bad' end
    if p ~= nil then return p, 'piece' end
    local w, wBad = BR.UIv2.parse(wholeRaw)
    if wBad then return false, 'bad' end
    if w ~= nil then return w, 'whole' end
    return false, 'default'
end

-- ---------------------------------------------------------------------------
-- br_core's server: the switches, read, resolved and replicated
-- ---------------------------------------------------------------------------

--- A convar's text, made safe and short enough to quote in one console line.
--- @param raw string @return string
local function quoted(raw)
    local s = raw:gsub('%c', '?')
    if #s > 32 then s = s:sub(1, 32) .. '...' end
    return '"' .. s .. '"'
end

local function textOf(v) return type(v) == 'string' and v or '' end

--- Every switch, read now.
--- @param get function
--- @return table  { whole = text, pieces = { [id] = text } }
local function readAll(get)
    local r = { whole = textOf(get(BR.UIv2.CONVAR, '')), pieces = {} }
    for _, id in ipairs(ids()) do r.pieces[id] = textOf(get(BR.UIv2.PREFIX .. id, '')) end
    return r
end

--- Every piece's answer and why, from switches as read.
--- @param r table
--- @return table answer, table why
local function resolveAll(r)
    local t, why = {}, {}
    for _, id in ipairs(ids()) do
        t[id], why[id] = BR.UIv2.resolve(r.whole, r.pieces[id])
    end
    return t, why
end

--- UI v2 as a whole, in words: `on (br_uiv2 on)`, `off (br_uiv2 is not set)`.
--- @param raw string
--- @return string
local function wholeWords(raw)
    local v, bad = BR.UIv2.parse(raw)
    if bad then return ('off (%s %s is not on or off)'):format(BR.UIv2.CONVAR, quoted(raw)) end
    if v == nil then return ('off (%s is not set)'):format(BR.UIv2.CONVAR) end
    return ('%s (%s %s)'):format(v and 'on' or 'off', BR.UIv2.CONVAR, v and 'on' or 'off')
end

--- Why one piece answers what it does, as the status says it.
--- @param id string @param r table  the switches as read
--- @return string
local function pieceWhy(id, r)
    local raw = r.pieces[id] or ''
    local v, bad = BR.UIv2.parse(raw)
    if bad then return ('%s%s %s is not on or off'):format(BR.UIv2.PREFIX, id, quoted(raw)) end
    if v ~= nil then return ('%s%s %s'):format(BR.UIv2.PREFIX, id, v and 'on' or 'off') end
    return 'follows UI v2'
end

--- Each piece with its answer, and the switch that decided it when that is
--- its own: `locker on, market off (br_uiv2_market off)`.
--- @param t table @param r table
--- @return string
local function piecesWords(t, r)
    local parts = {}
    for _, id in ipairs(ids()) do
        local s = id .. (t[id] and ' on' or ' off')
        local v, bad = BR.UIv2.parse(r.pieces[id] or '')
        if bad then
            s = s .. (' (%s%s is not on or off)'):format(BR.UIv2.PREFIX, id)
        elseif v ~= nil then
            s = s .. (' (%s%s %s)'):format(BR.UIv2.PREFIX, id, v and 'on' or 'off')
        end
        parts[#parts + 1] = s
    end
    if #parts == 0 then return 'no pieces (br_lib/config/uiv2.lua)' end
    return table.concat(parts, ', ')
end

--- The boot banner's lines: the answer, and one more line per switch whose
--- text is not on or off, so a typo'd kill switch is seen as one.
--- @return string[]
local function banner()
    local L = {}
    L[#L + 1] = ('[br_core]   uiv2         %s: %s'):format(wholeWords(read.whole), piecesWords(answer, read))
    local _, wBad = BR.UIv2.parse(read.whole)
    if wBad then
        L[#L + 1] = ('[br_core]   uiv2         %s %s is not on or off: UI v2 off')
            :format(BR.UIv2.CONVAR, quoted(read.whole))
    end
    for _, id in ipairs(ids()) do
        local _, pBad = BR.UIv2.parse(read.pieces[id] or '')
        if pBad then
            L[#L + 1] = ('[br_core]   uiv2         %s%s %s is not on or off: %s off')
                :format(BR.UIv2.PREFIX, id, quoted(read.pieces[id]), id)
        end
    end
    return L
end

--- br_core's server, once, as it starts: read every switch, resolve them,
--- hold the answer, replicate it as br_uiv2Served -- always, even unchanged --
--- and hand back the boot banner's lines. It never writes a switch.
---
--- RETURNS THE LINES RATHER THAN PRINTING THEM so server/main.lua prints them
--- in its banner, beside the season's.
--- @param get function|nil  (name, default) -> string; GetConvar by default
--- @param set function|nil  (name, value); SetConvarReplicated by default
--- @return string[] lines
function BR.UIv2.boot(get, set)
    get = get or GetConvar
    set = set or SetConvarReplicated
    role = 'server'
    read = get and readAll(get) or { whole = '', pieces = {} }
    local t, why = resolveAll(read)
    whyOf = why
    move(t, encode(t))
    -- Guarded for the unit suites, which run without the Cfx runtime.
    if set then set(BR.UIv2.SERVED, answerText) end
    return banner()
end

--- Has a switch moved since the last read, or br_uiv2Served been set by hand?
---
--- A switch that moved is APPLIED: the answer is resolved again and
--- br_uiv2Served written if it moved, with one console line per moved switch.
--- A br_uiv2Served that is not the answer is written back, with one line.
--- nil when nothing moved, and on every state that never booted. Costs
--- 2 + pieces convar reads.
--- @param get function|nil  GetConvar by default
--- @param set function|nil  SetConvarReplicated by default
--- @return string[]|nil lines
function BR.UIv2.recheck(get, set)
    if role ~= 'server' or read == nil then return nil end
    get = get or GetConvar
    set = set or SetConvarReplicated
    if not get then return nil end
    local now = readAll(get)
    local served = textOf(get(BR.UIv2.SERVED, ''))
    local lines = {}

    local moved = now.whole ~= read.whole
    for id, raw in pairs(now.pieces) do
        if raw ~= read.pieces[id] then moved = true end
    end
    if moved then
        local was, wasRead = answer or {}, read
        read = now
        local t, why = resolveAll(now)
        whyOf = why
        if now.whole ~= wasRead.whole then
            lines[#lines + 1] = ('[br_core] %s is now %s: %s'):format(BR.UIv2.CONVAR,
                now.whole == '' and 'unset' or quoted(now.whole), piecesWords(t, now))
        end
        for _, id in ipairs(ids()) do
            if now.pieces[id] ~= wasRead.pieces[id] then
                local name = BR.UIv2.PREFIX .. id
                local state = id .. (t[id] and ' on' or ' off')
                if why[id] ~= 'piece' and why[id] ~= 'bad' then state = state .. ', following UI v2' end
                lines[#lines + 1] = ('[br_core] %s is now %s: %s (was %s)'):format(name,
                    now.pieces[id] == '' and 'unset' or quoted(now.pieces[id]), state, was[id] and 'on' or 'off')
            end
        end
        local text = encode(t)
        if text ~= answerText then
            move(t, text)
            if set then set(BR.UIv2.SERVED, text) end
            served = text
        else
            answer = t
        end
    end

    if served ~= answerText then
        if set then set(BR.UIv2.SERVED, answerText) end
        lines[#lines + 1] = ('[br_core] %s was set by hand -- written back: %s'):format(BR.UIv2.SERVED, words(answer))
    end
    if #lines == 0 then return nil end
    return lines
end

--- Every piece's id, sorted: the command's usage line and its refusals.
--- @return string[]
function BR.UIv2.pieces()
    return ids()
end

local CMD = '[br_core] bruiv2: '

--- What a piece answered and why, before a flip: `on, following UI v2`.
--- @param id string @param on boolean @param r table
--- @return string
local function wasWords(id, on, r)
    local why = pieceWhy(id, r)
    if why == 'follows UI v2' then why = 'following UI v2' end
    return (on and 'on' or 'off') .. ', ' .. why
end

--- The lines for a bare `bruiv2`: UI v2 as a whole, each piece, its answer and
--- why, and when a player takes a change.
--- @return string[]
function BR.UIv2.status()
    if role ~= 'server' or read == nil then return { CMD .. 'UI v2 has not booted on this server' } end
    local L = {}
    L[#L + 1] = CMD .. 'UI v2 ' .. wholeWords(read.whole)
    local width = 0
    for _, id in ipairs(ids()) do width = math.max(width, #id) end
    for _, id in ipairs(ids()) do
        L[#L + 1] = CMD .. ('  %-' .. width .. 's %-3s -- %s'):format(id, answer[id] and 'on' or 'off', pieceWhy(id, read))
    end
    L[#L + 1] = CMD .. 'players take a change standing in the lobby or as their next match starts; the Locker only in the lobby'
    return L
end

--- br_core's server, for `bruiv2` only (br_core/server/uiv2.lua): write a
--- switch and apply it at once, as the 5 s re-read would.
---
---   id nil       UI v2 as a whole: `on` or `off` (never `auto`: unset is off,
---                so an `auto` on a box whose server.cfg says on would kill
---                UI v2 for every lobby player)
---   id a piece   `on`, `off`, or `auto` (unset: follow UI v2 again)
---
--- A switch typed by hand since the last re-read is applied first, so the flip
--- is judged against the switches as they are. The lines say what moved, name
--- every piece a whole flip leaves where its own switch holds it, and give the
--- server.cfg line that keeps the flip past an FXServer restart.
--- @param id string|nil
--- @param to string
--- @param setc function|nil  (name, value); SetConvar by default
--- @param get function|nil   GetConvar by default
--- @param set function|nil   SetConvarReplicated by default
--- @return string[]|nil lines
--- @return string|nil why  'not booted', 'no such piece' or 'usage'
function BR.UIv2.flip(id, to, setc, get, set)
    if role ~= 'server' or read == nil then return nil, 'not booted' end
    setc = setc or SetConvar
    local name
    if id == nil then
        if to ~= 'on' and to ~= 'off' then return nil, 'usage' end
        name = BR.UIv2.CONVAR
    else
        if not isId(id) or type(rows()[id]) ~= 'table' then return nil, 'no such piece' end
        if to ~= 'on' and to ~= 'off' and to ~= 'auto' then return nil, 'usage' end
        name = BR.UIv2.PREFIX .. id
    end

    -- ANYTHING TYPED SINCE THE LAST RE-READ FIRST, with its own lines.
    local L = BR.UIv2.recheck(get, set) or {}

    local before = id == nil and read.whole or read.pieces[id]
    local v, bad = BR.UIv2.parse(before)
    local already = not bad and ((to == 'auto' and v == nil) or (to ~= 'auto' and v == (to == 'on')))
    if already then
        if id == nil then
            L[#L + 1] = CMD .. ('UI v2 is already %s'):format(to)
        elseif to == 'auto' then
            L[#L + 1] = CMD .. ('%s already follows UI v2'):format(id)
        else
            L[#L + 1] = CMD .. ('%s is already %s'):format(id, to)
        end
        return L
    end

    local wasAnswer, wasRead = answer or {}, read
    if setc then setc(name, to == 'auto' and '' or to) end
    -- Applied at once. Its own lines would only repeat the flip's.
    BR.UIv2.recheck(get, set)

    if id == nil then
        local wasV, wasBad = BR.UIv2.parse(wasRead.whole)
        local wasText = wasV and 'on' or 'off'
        if wasBad then
            wasText = ('off, %s %s is not on or off'):format(BR.UIv2.CONVAR, quoted(wasRead.whole))
        elseif wasV == nil then
            wasText = ('off, %s not set'):format(BR.UIv2.CONVAR)
        end
        L[#L + 1] = CMD .. ('UI v2 %s (was %s)'):format(to, wasText)
        -- A PARTIAL KILL NEVER READS AS A FULL ONE: every piece its own switch
        -- holds is named.
        for _, pid in ipairs(ids()) do
            if whyOf[pid] == 'piece' or whyOf[pid] == 'bad' then
                L[#L + 1] = CMD .. ('  %s stays %s: %s'):format(pid, answer[pid] and 'on' or 'off', pieceWhy(pid, read))
            end
        end
    elseif to == 'auto' then
        L[#L + 1] = CMD .. ('%s follows UI v2 again: %s (was %s)'):format(id, answer[id] and 'on' or 'off',
            wasWords(id, wasAnswer[id] == true, wasRead))
    else
        L[#L + 1] = CMD .. ('%s %s (was %s)'):format(id, to, wasWords(id, wasAnswer[id] == true, wasRead))
    end
    if to == 'auto' then
        L[#L + 1] = CMD .. ('until FXServer restarts; to keep it, take any %s line out of server.cfg'):format(name)
    else
        L[#L + 1] = CMD .. ('until FXServer restarts; to keep it, in server.cfg: set %s %s'):format(name, to)
    end
    return L
end

-- ---------------------------------------------------------------------------
-- br_core's client: the one answer this machine holds
-- ---------------------------------------------------------------------------

--- br_uiv2Served, read now.
local function readServed()
    servedText = textOf(GetConvar and GetConvar(BR.UIv2.SERVED, '') or '')
end

--- br_core's client, once, from br_core/client/uiv2.lua: this state HOLDS the
--- machine's answer from now on. `pred` says whether a new answer may be taken
--- now (standing in the lobby with the entrance over, or the loading screen
--- still up). Reads br_uiv2Served now, follows it with the runtime's listener
--- (pcall-guarded, so a listener that will not register leaves the re-read
--- behind it), and takes the first answer if it is there.
--- @param pred function
function BR.UIv2.hold(pred)
    role = 'holder'
    standing = type(pred) == 'function' and pred or nil
    readServed()
    if type(AddConvarChangeListener) == 'function' then
        listening = pcall(AddConvarChangeListener, BR.UIv2.SERVED, function() readServed() end) == true
    end
    BR.UIv2.adopt(false)
end

--- The holder's one pass (br_core/client/uiv2.lua's TICK pass 'uiv2.adopt').
---
--- THE PER-PASS COST IS ONE STRING COMPARE: the served text as the listener
--- last read it against the text held. Only a difference goes further. An
--- empty or garbled served value keeps what is held. A new answer is taken
--- when nothing is held yet (the first one, in any state), on the first pass
--- out of the lobby (`left`: the next match starting, behind its curtain), or
--- while `standing()` says so; otherwise it waits, held through the match and
--- through the walk-in. Taking one tells every follower here, prints one F8
--- line, and raises `br:uiv2:held` with the text for every mirror.
--- @param left boolean
function BR.UIv2.adopt(left)
    if role ~= 'holder' then return end
    if not listening then
        local now = type(GetGameTimer) == 'function' and GetGameTimer() or 0
        if polledAt == nil or now - polledAt >= POLL_MS then
            polledAt = now
            readServed()
        end
    end
    if servedText == answerText or servedText == badText then return end
    local t = decode(servedText)
    if t == nil then
        badText = servedText
        return
    end
    -- THE PREDICATE CANNOT TAKE THE PASS DOWN: BR.Loop suspends a callback
    -- after five errors in a row, and this pass is the kill switch's way onto
    -- this machine. A predicate that raises reads as "not now".
    local now = answer == nil or left
    if not now and standing ~= nil then
        local okS, st = pcall(standing)
        now = okS and st == true
    end
    if not now then return end
    move(t, servedText)
    print(('[br_core] UI v2 here: %s'):format(words(t)))
    if type(TriggerEvent) == 'function' then TriggerEvent('br:uiv2:held', answerText) end
end

-- ---------------------------------------------------------------------------
-- Every state
-- ---------------------------------------------------------------------------

--- Is this piece of UI v2 on, here?
---
--- On br_core's server, the live answer, which moves the moment a switch does;
--- false before boot (br_core boots in onResourceStart, before any handler or
--- job asks). On a client, the answer this machine holds: false for every
--- piece until one is held. AN ID WITH NO ROW IS OFF and the console is told
--- once; under BR.UIv2.strict it raises. TABLE READS, NEVER A NATIVE.
--- @param id string  a key of BR.Config.UIv2.pieces, written as a literal
--- @return boolean
function BR.UIv2.has(id)
    local row = id ~= nil and rows()[id] or nil
    if type(row) ~= 'table' then
        if BR.UIv2.strict then
            error(('BR.UIv2.has: no piece %q in br_lib/config/uiv2.lua'):format(tostring(id)), 2)
        end
        local key = tostring(id)
        if not unknownSeen[key] then
            unknownSeen[key] = true
            print(('[br_lib] BR.UIv2.has(%q): no such piece in br_lib/config/uiv2.lua -- treated as off'):format(key))
        end
        return false
    end
    return answer ~= nil and answer[id] == true
end

--- Is any answer in force here yet? Locker v2 takes its own first answer once
--- this is true (br_core/client/locker2.lua).
--- @return boolean
function BR.UIv2.known()
    return answer ~= nil
end

--- Be told when this state's answer moves: fn(nowText, beforeText), the first
--- answer included (beforeText nil). For a file that keeps a derived answer --
--- br_ui's Market grid re-pushes on it.
--- @param fn function
function BR.UIv2.onChange(fn)
    if type(fn) == 'function' then watchers[#watchers + 1] = fn end
end

-- ═══ THE MIRROR'S WIRING, FROM THE MOMENT THIS FILE LOADS, ON A CLIENT ═══
--
-- br_core's client becomes the holder a moment later (hold()), and from then
-- on ignores `br:uiv2:held`; every other state on the machine takes it.
local onServer = type(IsDuplicityVersion) == 'function' and IsDuplicityVersion() == true
if not onServer and type(AddEventHandler) == 'function' then
    AddEventHandler('br:uiv2:held', function(text)
        if role ~= nil or type(text) ~= 'string' or text == answerText then return end
        local t = decode(text)
        if t then move(t, text) end
    end)
    AddEventHandler('br:uiv2:ask', function()
        if role == 'holder' and answerText ~= nil and type(TriggerEvent) == 'function' then
            TriggerEvent('br:uiv2:held', answerText)
        end
    end)
    if type(TriggerEvent) == 'function' then TriggerEvent('br:uiv2:ask') end
end

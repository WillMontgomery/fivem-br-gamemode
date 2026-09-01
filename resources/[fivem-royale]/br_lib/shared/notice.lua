-- A notice with a PLAYER'S NAME in it, carried so the name can be drawn bold
-- and can never be anything but text.
--
-- ═══ THE OWNER'S RULE, 2026-08-31 ═══
--
--   "Any time we mention a player by name in a toast their name should be
--    bold."
--
-- EVERY toast, not only the new ones. That is a change to how a toast crosses
-- from Lua to the screen, because until now a toast was a STRING and a string
-- has no bold in it.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHY NOT MARKUP, AND WHY NOT A TOKEN
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The two obvious answers both put the formatting IN BAND -- in the same string
-- the player's own name is substituted into -- and both are forgeable, because
-- the name is the one part of that string a player writes:
--
--   MARKDOWN. `**%s** is down!` renders a name of `**` or `x** is down! **y`
--   as formatting. A player picks their own name; this is an injection with a
--   sign-up form in front of it.
--
--   A `{b:...}` TOKEN, the shape KeyText already uses for `{key:brptt}`. That
--   one is safe precisely BECAUSE its payload is an identifier we wrote --
--   `[A-Za-z0-9_]+`, a command name, never player data. A token whose payload
--   is a NAME has no such alphabet: names contain braces, colons and anything
--   else BR.ValidateName lets through, so `Bob}` closes the token early and
--   the rest of the sentence inherits the formatting.
--
-- ESCAPING IS THE THIRD WRONG ANSWER. It works right up until one of the two
-- ends forgets, and the failure is silent and cosmetic-looking.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- SO THE SENTENCE TRAVELS PRE-SPLIT, AND THE NAME IS NEVER PARSED
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A notice may now carry `parts`: an ordered list of pieces, each of which is
-- either
--
--     { t = 'literal prose we wrote' }      -- may still hold a {key:} token
--     { b = "the player's own name" }       -- drawn bold, drawn as TEXT
--
-- The split happens HERE, on the FORMAT STRING, which is always a literal in
-- our own source. The values substituted into it are never scanned, never
-- tokenised and never escaped -- they are copied whole into a part of their
-- own, and the page renders a `b` part as a React text child inside a bold
-- span. There is no grammar for a name to break out of because the name is not
-- inside a grammar.
--
-- `text` TRAVELS ALONGSIDE, and it is the same sentence flattened. It is what
-- the notice store dedups on, what the pause menu's history matches keys
-- against, and what any consumer that only wants a string gets. A sender that
-- names nobody sends `text` alone and nothing about it changes -- which is
-- almost every notice in the game.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- HOW A CALL SITE USES IT
-- ═══════════════════════════════════════════════════════════════════════════
--
--     BR.Server.notify(mate,
--         BR.Notice.line('%s is down!', BR.Notice.who(entry.name)),
--         'warn', { key = 'dbno.' .. src, ms = 6000 })
--
-- The format string keeps the shape the call site already had, so the sentence
-- is still readable in one line at the place it is sent from. `who()` is what
-- marks a hole as a PERSON -- and it has to be explicit, because not every
-- `%s` is a name:
--
--     BR.Notice.line('%s\'s invite expired -- %s.', BR.Notice.who(name), reason)
--
-- The first hole is a player and goes bold; the second is our own word for why
-- and does not. A rule of "every %s is a name" would have got that one wrong
-- and nothing would have looked broken.

BR = BR or {}
BR.Notice = {}

--- Mark a value as A PLAYER'S NAME, for BR.Notice.line.
---
--- The marker is a TABLE, which is what makes it unforgeable from the outside:
--- a player may call themselves anything at all and they still cannot hand this
--- module a table, because the only things that reach `line` are the arguments
--- our own call sites pass it.
--- @param name any
--- @return table
function BR.Notice.who(name)
    return { b = tostring(name or '') }
end

--- Is this one of our name markers?
--- @param v any
--- @return boolean
local function isWho(v)
    return type(v) == 'table' and type(v.b) == 'string' and v.t == nil
end

--- Compose a notice from a TRUSTED format string and untrusted values.
---
--- Only `%s` is understood, and `%%` is an escaped percent. Anything else is
--- literal -- this is not string.format and deliberately is not: a `%d` here
--- would be a second parser over the one string this module exists to keep
--- unparsed. Format numbers at the call site and pass the result as a plain
--- value.
---
--- RETURNS A PLAIN STRING WHEN NOBODY IS NAMED, so a call site that wraps a
--- sentence with no `who()` in it produces exactly what it produced before and
--- costs the wire nothing.
--- @param fmt string
--- @param ... any   values for the `%s` holes, in order; wrap names in who()
--- @return string|table   the flat string, or { text = ..., parts = { ... } }
function BR.Notice.line(fmt, ...)
    fmt = tostring(fmt or '')
    local args, n = { ... }, select('#', ...)

    local parts, text = {}, {}
    -- The literal run being accumulated. Flushed as one `t` part whenever a
    -- name interrupts it, so `'%s picked %s up.'` is three parts and not five
    -- with two empty ones in the middle.
    local run = {}
    local used = 0

    local function flush()
        if #run == 0 then return end
        parts[#parts + 1] = { t = table.concat(run) }
        run = {}
    end

    local i, len = 1, #fmt
    while i <= len do
        local c = fmt:sub(i, i)
        if c == '%' and i < len then
            local d = fmt:sub(i + 1, i + 1)
            if d == 's' then
                used = used + 1
                local v = used <= n and args[used] or nil
                if isWho(v) then
                    flush()
                    parts[#parts + 1] = { b = v.b }
                    text[#text + 1] = v.b
                else
                    -- NOT A NAME, SO IT IS PROSE. A `nil` argument writes
                    -- nothing rather than the word "nil": a hole with no value
                    -- is a bug at the call site, and an empty gap is the least
                    -- wrong thing to show a player while it is being found.
                    local s = v == nil and '' or tostring(v)
                    run[#run + 1] = s
                    text[#text + 1] = s
                end
                i = i + 2
            elseif d == '%' then
                run[#run + 1] = '%'
                text[#text + 1] = '%'
                i = i + 2
            else
                run[#run + 1] = c
                text[#text + 1] = c
                i = i + 1
            end
        else
            run[#run + 1] = c
            text[#text + 1] = c
            i = i + 1
        end
    end
    flush()

    local flat = table.concat(text)

    -- NOBODY WAS NAMED, SO THIS IS JUST A SENTENCE. Returning the string means
    -- `parts` never travels for the forty-odd notices in this game that name no
    -- player, and their path is byte for byte the one they had.
    for _, p in ipairs(parts) do
        if p.b ~= nil then return { text = flat, parts = parts } end
    end
    return flat
end

--- Unpack whatever a caller handed a notify function into what goes on the wire.
---
--- EVERY SENDER GOES THROUGH THIS, so "a notice is a string OR a built table"
--- is answered in one place rather than at each of the four send sites.
--- @param v any   a string, or a table from BR.Notice.line
--- @return string text, table|nil parts
function BR.Notice.wire(v)
    if type(v) == 'table' then
        local text = type(v.text) == 'string' and v.text or ''
        local parts = BR.Notice.clean(v.parts)
        return text, parts
    end
    return tostring(v or ''), nil
end

--- Rebuild a parts list out of only the fields this project defines.
---
--- FOR THE RECEIVING END. br_core/client/state.lua forwards a NOTIFY payload
--- field by field rather than passing it through whole -- "the UI should not be
--- the thing that discovers a sender invented a field" -- and `parts` is the
--- first field on that payload that is not a scalar. This is the same rule one
--- level down: a part that is not `{t=string}` or `{b=string}` is dropped, so
--- the page's renderer only ever sees the two shapes it has a branch for.
---
--- NIL FOR AN EMPTY LIST, never `{}`. An empty Lua table encodes as a JSON
--- OBJECT rather than an array on the way to the page, and the renderer's
--- `parts.length` would be undefined -- so the absent case travels as absent.
--- @param v any
--- @return table|nil
function BR.Notice.clean(v)
    if type(v) ~= 'table' then return nil end
    local out = {}
    for _, p in ipairs(v) do
        if type(p) == 'table' then
            if type(p.b) == 'string' then
                out[#out + 1] = { b = p.b }
            elseif type(p.t) == 'string' then
                out[#out + 1] = { t = p.t }
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

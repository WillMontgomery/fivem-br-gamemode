-- The source-reading half of the BOOL-native gate, as pure functions.
--
-- WHY THIS IS NOT JUST INSIDE tools/check_bool_natives.lua. That gate reads the
-- real tree against a recorded baseline, so on a clean checkout it proves the
-- tree has not got worse -- and it CANNOT prove it would notice if it had. A
-- detector that has quietly stopped detecting reports "ok" in exactly the same
-- green as a real pass, which is worse than no gate at all. icon_rules.lua
-- learned this first; this file inherits the lesson.
--
-- So the rules live here, take a source string, and return the faults in it.
-- The gate feeds them the real files; tools/test_bool_natives.lua feeds them
-- sources that are deliberately broken -- including every spelling of the fix,
-- which must NOT be reported -- and asserts each answer.
--
-- ── THE FAULT ─────────────────────────────────────────────────────────────
--
-- In Lua the number 0 is TRUTHY, and a FiveM native declared BOOL may hand back
-- 1/0 rather than true/false. Both obvious spellings are therefore wrong, in
-- OPPOSITE directions:
--
--     if HasCollisionLoadedAroundEntity(ped) then      -- TRUE for a 0: "no"
--                                                      -- reads as "yes".
--     while not HasCollisionLoadedAroundEntity(ped) do -- FALSE for a 0: the
--                                                      -- loop exits at once.
--
-- One proceeds without waiting, the other stops waiting. Every instance this
-- project has shipped lived in a wait, which is why the class costs so much:
-- the wait still looks like it is there.
--
-- Loaded with dofile from the repo root by both callers.

local M = {}

--- Strip comments and strings so their contents cannot look like code.
---
--- SAME-LENGTH BLANKS, so every column stays where it was -- the caller reports
--- line and column against the ORIGINAL text. Crude on purpose: this file is
--- full of prose about the very natives it is looking for, and a rule that read
--- its own explanation would report the essay as the bug.
--- @param line string
--- @return string
function M.blank(line)
    line = line:gsub('%-%-.*$', '')
    line = line:gsub('"[^"]*"', function(s) return string.rep(' ', #s) end)
    line = line:gsub("'[^']*'", function(s) return string.rep(' ', #s) end)
    return line
end

--- Does this identifier read as a native that answers 0 for "no"?
---
--- Is/Has/Does/Can AS A CAPITALISED WORD, ANYWHERE IN THE NAME -- not anchored
--- to the front. NetworkIsSessionStarted and GetIsLoadingScreenActive are both
--- BOOL, both were read raw in the seventh instance, and a front-anchored test
--- walks straight past both.
---
--- It also catches GetVehiclePedIsIn, which is not a BOOL at all -- it returns
--- an entity handle, and 0 for "none". That is the same bug wearing a different
--- return type, and server/vehicles.lua carries a write-up of it, so being
--- caught by the name rule is the right answer rather than a false alarm.
--- @param name string
--- @return boolean
function M.boolShaped(name)
    return name:find('%f[%u]Is%u') ~= nil
        or name:find('%f[%u]Has%u') ~= nil
        or name:find('%f[%u]Does%u') ~= nil
        or name:find('%f[%u]Can%u') ~= nil
end

--- The index of the `)` closing the `(` at index i, or nil if it does not close
--- on this line.
local function closeParen(s, i)
    local depth = 0
    for j = i, #s do
        local ch = s:sub(j, j)
        if ch == '(' then depth = depth + 1
        elseif ch == ')' then
            depth = depth - 1
            if depth == 0 then return j end
        end
    end
end

--- The keywords that put whatever follows them into TRUTH POSITION.
---
--- This list IS the rule. A native reached through anything else -- an
--- argument, an assignment, a comparison -- is not being believed, it is being
--- handled, and handling it is the fix.
local TRUTH = {
    ['if'] = true, ['elseif'] = true, ['while'] = true, ['until'] = true,
    ['and'] = true, ['or'] = true, ['not'] = true,
}

--- Every function name a source declares.
---
--- Used to EXCLUDE the project's own helpers. BR.Native.IsDeadHp, isAllowedVehicle
--- and friends read like natives and return real Lua booleans; reporting them
--- would train people to rename their functions to get past the gate, which is
--- the worst thing a gate can teach.
--- @param src string
--- @param into table|nil  accumulate into an existing set
--- @return table  set of names
function M.declared(src, into)
    local names = into or {}
    for raw in (src .. '\n'):gmatch('(.-)\n') do
        local code = M.blank(raw)
        for n in code:gmatch('function%s+([%w_%.:]+)%s*%(') do
            names[n:match('([%w_]+)$')] = true
        end
        for n in code:gmatch('([%w_]+)%s*=%s*function%s*%(') do
            names[n] = true
        end
        for n in code:gmatch('%[%s*[\'"]([%w_]+)[\'"]%s*%]%s*=%s*function') do
            names[n] = true
        end
    end
    return names
end

--- Every bare truth test on a BOOL-shaped native in this source.
---
--- NOT REPORTED, and each omission is deliberate:
---
---   isTrue(IsScreenFadedIn())   the value is an ARGUMENT to something else, so
---   tostring(IsPedOnFoot(ped))  it is not the truth value. This is how the
---                               helpers are recognised and why the rule needs
---                               no list of helper names: ANY wrapper takes the
---                               native out of truth position, and that is
---                               exactly what the fix does.
---   if DoesEntityExist(e) == 1  compared rather than believed.
---   local ok = IsPedOnFoot(p)   stored first. The same bug if `ok` is later
---                               tested -- and also how the fix is written, so
---                               flagging it would flag every correct file.
---   -- bool-ok: <why>           a line that genuinely wants the raw engine
---                               answer, marked per line like the scope gate's
---                               `scope-ok`.
--- @param src string
--- @param declared table|nil  names to skip (see M.declared)
--- @return table  list of { line = n, native = name, text = trimmed source }
function M.scan(src, declared)
    declared = declared or {}
    local found = {}
    local n = 0

    for raw in (src .. '\n'):gmatch('(.-)\n') do
        n = n + 1
        if not raw:find('bool%-ok:') then
            local code = M.blank(raw)
            local pos = 1
            while true do
                local s, e, name = code:find('([%w_]+)%s*%(', pos)
                if not s then break end
                pos = e

                -- `t.IsX(` and `t:IsX(` are somebody's method, and an identifier
                -- character in front means this is the tail of a longer word.
                local prefix = code:sub(math.max(1, s - 1), s - 1)
                if M.boolShaped(name) and not declared[name]
                   and prefix ~= '.' and prefix ~= ':'
                   and not prefix:match('[%w_]') then
                    local token = code:sub(1, s - 1):match('([%w_]+)%s*$')
                    if token and TRUTH[token] then
                        -- A call whose parenthesis does not close on this line
                        -- cannot be compared on this line either, so it counts.
                        local open = code:find('%(', s)
                        local close = closeParen(code, open)
                        local after = close
                            and code:sub(close + 1):match('^%s*(..?)') or ''
                        if not (after:find('^==') or after:find('^~=')
                                or after:find('^<') or after:find('^>')
                                or after:find('^%.%.')) then
                            found[#found + 1] = {
                                line = n, native = name,
                                text = raw:gsub('^%s+', ''),
                            }
                        end
                    end
                end
            end
        end
    end

    return found
end

return M

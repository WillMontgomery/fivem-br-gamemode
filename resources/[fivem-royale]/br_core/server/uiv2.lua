-- `bruiv2`: UI v2's switches from the server console (#436), on any box.
--
-- Owner, 2026-11-07: "One toggle for everything ... and also a separate
-- toggle for each component", switched live from the server console, on prod
-- too, as a kill switch. br_lib/shared/uiv2.lua holds the switches, the
-- answer and every console line, because it is the only file that may name
-- the convars (verify.sh's `ui v2 gates`, U4); this file reads BR.UIv2 at
-- call time only and sends nothing to any client.
--
--   bruiv2                         every switch, each piece's answer, and why
--   bruiv2 on|off                  UI v2 as a whole
--   bruiv2 <piece> on|off|auto     one piece on or off whatever UI v2 says, or
--                                  following it again
--
-- `auto` is for a piece only. UI v2 as a whole follows nothing: an `auto`
-- there would mean "unset, so off", and on a box whose server.cfg says
-- `set br_uiv2 on` an operator undoing a flip would kill UI v2 for every
-- lobby player.
--
-- A flip is written into the switch itself, so it survives `restart br_core`
-- and not an FXServer restart, and each one prints the server.cfg line that
-- keeps it. Players take it standing in the lobby or as their next match
-- starts (br_core/client/uiv2.lua); the server's own doors answer it at once.
--
-- ═══ DEVGATE-EXEMPT (br_lib/shared/devgate.lua), SO THIS BODY IS THE GATE ═══
--
-- A kill switch that only a dev box can throw is no kill switch, so this is
-- the fifth verb the dev gate lets through. It is SERVER-CONSOLE ONLY: the
-- first thing the handler does is refuse any source but the console (0 is
-- truthy in Lua, so the test is an equality), and it is registered restricted
-- as well. Restricted alone would admit an in-game group.admin. The refusal
-- prints to this console and nowhere else: no F8 line, no broadcast, so no
-- player ever reads who flipped it. tools/check_uiv2.lua (U7) pins all of it.

BR = BR or {}

--- The usage line, with the pieces the list has today.
--- @return string
local function usage()
    return ('[br_core] bruiv2: usage: bruiv2 | bruiv2 on|off | bruiv2 <%s> on|off|auto')
        :format(table.concat(BR.UIv2.pieces(), '|'))
end

RegisterCommand('bruiv2', function(src, args)
    if tonumber(src) ~= 0 then print('  bruiv2 is server-console only') return end
    args = type(args) == 'table' and args or {}
    local a1 = args[1] ~= nil and tostring(args[1]):lower() or nil
    local a2 = args[2] ~= nil and tostring(args[2]):lower() or nil

    local lines, why
    if a1 == nil then
        lines = BR.UIv2.status()
        lines[#lines + 1] = usage()
    elseif args[3] ~= nil then
        why = 'usage'
    elseif a2 == nil then
        -- UI v2 as a whole: on or off, and nothing else (`auto` alone included).
        if a1 == 'on' or a1 == 'off' then lines, why = BR.UIv2.flip(nil, a1) else why = 'usage' end
    else
        lines, why = BR.UIv2.flip(a1, a2)
    end

    if lines then
        for _, l in ipairs(lines) do print(l) end
    elseif why == 'no such piece' then
        print(('[br_core] bruiv2: %q is not a piece of UI v2 -- %s'):format(a1:sub(1, 16),
            table.concat(BR.UIv2.pieces(), ', ')))
    elseif why == 'not booted' then
        print('[br_core] bruiv2: UI v2 has not booted on this server')
    else
        print(usage())
    end
end, true)

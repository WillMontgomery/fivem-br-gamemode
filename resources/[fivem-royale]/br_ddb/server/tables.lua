--[[
    br_ddb tables -- which family of tables this resource named when it
    started: the dev box's `dev-` copies, or production's.

    ═══ WHY A LUA FILE ANSWERS FOR THE JS HALF ═══

    dist/server.js resolves its table prefixes ONCE, when this resource starts
    (js-src/br_ddb/src/index.js, `PREFIXES = resolvePrefixes(GetConvar)`), and
    never again. Dev mode switched on afterwards -- `set br_devMode true` typed
    live -- opens every dev gate in br_core while this resource goes on writing
    the production tables. br_core's dev doors that write a stored profile (the
    dev menu's Give volts and Give Yubikeys, #422, and `brvolts` and
    `brterminalsv key` with them) ask THIS before they write, and refuse unless
    the answer is the dev tables.

    THE SAME RULE, READ AT THE SAME MOMENT. src/prefix.js forces `dev-` when
    either of DEV_CONVARS reads exactly 'true' (`devConvarsOn`); this file reads
    the same two names the same way, once, as this resource starts -- the start
    the bundle reads them on. tools/test_devmenu.lua holds the
    two lists together.

    Exported rather than published to GlobalState: the answer is for this
    server's own Lua, and no client has any business knowing it.
]]

--- prefix.js's DEV_CONVARS, in its order.
local DEV_CONVARS = { 'sv_devMode', 'br_devMode' }

--- Did the bundle name the dev- tables when it started? Read once, here.
local devTables = false
for _, name in ipairs(DEV_CONVARS) do
    if GetConvar(name, 'false') == 'true' then devTables = true end
end

--- @return boolean  true when every table this resource names starts `dev-`
exports('devTables', function()
    return devTables
end)

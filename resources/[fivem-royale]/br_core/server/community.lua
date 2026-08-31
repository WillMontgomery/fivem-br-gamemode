-- Where our Discord is, told to every player's page (owner, 2026-08-30).
--
-- ONE CONVAR, TWO READERS NOW. br_ringmaster/server/appeal.lua has read
-- BR.Config.Community.discordUrl since 2026-08-20 to put an appeal line under a
-- kick; this file reads the same value to put a card in the pause menu. The
-- config file's own header used to say "no client reads this", and it was
-- amended in the commit that added this file rather than left to rot.
--
-- ═══ WHY br_core AND NOT br_ringmaster ═══
--
-- Because THE GAME MUST NEVER DEPEND ON RINGMASTER. That rule is why
-- server/grants.lua reads DynamoDB through br_ddb instead of asking the console,
-- and it applies with more force here: a server with br_ringmaster stopped is a
-- server that still has a Discord, and a card that vanished with the admin
-- console would be a bug nobody could explain. br_core already loads
-- @br_lib/config/community.lua (fxmanifest.lua:122), so the value is here.
--
-- ═══ WHY NOT br_ui, WHICH OWNS THE PAGE ═══
--
-- Because br_ui has no server_scripts at all. It is a client resource plus a
-- bundle, so it has no Lua state where config/overrides.lua ever applied the
-- convar -- it would be holding the committed default ('') while the server held
-- the operator's value, which is the exact disagreement tools/verify.sh's
-- tunable-overrides gate exists to make impossible. The value is read in the one
-- state that has it and shipped over the wire; br_ui/client/pause.lua forwards
-- the table without opening it.
--
-- ═══ NOTHING HERE IS A SECRET ═══
--
-- An invite is a public address, already printed in full to anyone we kick, so
-- this is broadcast to every player who asks rather than gated the way
-- server/admin.lua gates the console's origin. There is no eligibility question
-- to re-run and no reason to withhold it from anybody.

BR = BR or {}
BR.Community = BR.Community or {}

--- The invite this deployment publishes, or nil when it publishes none.
---
--- A RESTATEMENT OF br_ringmaster/server/appeal.lua's READER, NOT A CALL INTO
--- IT. That file is in a resource this one is forbidden to depend on, so the
--- twelve lines are copied on purpose and the two must agree. They collapse the
--- same three spellings of absent for the same reason: `type ~= 'string'` is a
--- config table that never loaded, a run of whitespace is a `set br_discordUrl
--- " "` that an operator will swear is empty, and '' is the COMMON case rather
--- than an error -- config/community.lua defaults the key to an empty string,
--- and GetConvar returns its default only when a convar is UNSET, so
--- `set br_discordUrl ""` also arrives here as ''.
---
--- READ AT CALL TIME rather than cached at load, matching appeal.lua. It costs
--- one table lookup per connect, and caching would mean holding a value from
--- before config/overrides.lua had applied the convar, depending on load order.
--- @return string|nil
local function invite()
    local community = BR.Config and BR.Config.Community
    local url = community and community.discordUrl
    if type(url) ~= 'string' then return nil end
    url = url:gsub('^%s+', ''):gsub('%s+$', '')
    if url == '' then return nil end
    return url
end

--- What this deployment would tell a page right now.
---
--- Exported for `brconfig`-style inspection and for the test suite, which asserts
--- the payload rather than the private reader -- the payload is the whole
--- observable surface of this file.
--- @return table  { invite = '<url>' } or {}
function BR.Community.payload()
    local payload = {}
    local url = invite()
    if url ~= nil then payload.invite = url end
    return payload
end

-- THE CLIENT SAYS WHEN IT IS READY, and that is the moment to answer.
--
-- A SECOND LISTENER BESIDE br_core's OWN AND BESIDE server/admin.lua's, rather
-- than a call from inside either: FiveM runs every registered handler, so none
-- of them has to know about the others. server/grants.lua and server/players.lua
-- already make this argument for br:incident:filed, and server/admin.lua makes
-- it for this very event.
--
-- AND THERE IS NO CACHE ON THE CLIENT SIDE OF THIS, deliberately.
-- br_core/client/state.lua's br:ui:ready handler ALWAYS re-requests -- it fires
-- on a fresh connect, on a reconnect and on every `restart br_ui` -- so hooking
-- br:ready is already the whole set of moments a page needs telling. A cache in
-- br_ui would also park the invite in a br_ui client-Lua local, which is the one
-- thing pause.lua's relay is written to avoid.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    -- `{}` WHEN THERE IS NO INVITE, NEVER SILENCE. An empty table is a definite
    -- "this server publishes no Discord", and it is what lets a page that is
    -- already up take the card down after an operator clears the convar and
    -- restarts. Staying quiet would leave the last answer standing forever.
    TriggerClientEvent(BR.Net.COMMUNITY, source, BR.Community.payload())
end)

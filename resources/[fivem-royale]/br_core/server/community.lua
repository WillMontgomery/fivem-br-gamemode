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
--
-- (THE OTHER HALF OF THIS FEATURE DOES HAVE A SECRET, and it is not in this
-- file. server/guild.lua holds the Discord bot token on a convar that is never
-- reported. This file asks it a question and puts one boolean on the wire.)
--
-- ═══ WHO IS TOLD, AS OF 2026-08-31 ═══
--
-- Everybody, EXCEPT the people we positively know are already in the Discord.
-- The owner: "let's make it always show in the help page (unless we know they're
-- in the guild)". Two rules in one sentence, and both of them replaced something:
--
--   ALWAYS SHOWS. The card used to be gone for the rest of the session once a
--   player had copied it -- his own earlier instruction, now withdrawn. Nothing
--   in this file ever knew about that; it lived in the page and it is gone from
--   there. It is named here because the two rules are about the same card and
--   the next person to read one will want the other.
--
--   UNLESS WE KNOW. `member` is on the wire ONLY for a confirmed yes.
--   server/guild.lua answers true, false or nil, and nil is every kind of not
--   knowing -- no token, no discord: identifier, a timeout, a 429. All of those
--   leave the field off the payload and the card up, because a card that hid
--   itself whenever we failed to ask would stop inviting exactly the people it
--   is for, in the states nobody is watching.

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
---
--- `src` IS OPTIONAL AND MEANS "ABOUT NOBODY IN PARTICULAR". Without it this
--- answers what the deployment publishes, which is what an inspection command
--- wants; with it, it also answers what we know about that one player.
---
--- `member` IS ONLY EVER `true`. It is absent for "not a member" and absent for
--- every shade of "we did not find out", and collapsing those two into one
--- absence is the point rather than a shortcut: the client's question is "may I
--- stop inviting this person", and only a confirmed yes may answer it. A `false`
--- on the wire would be a second thing for a page to test and a second way for it
--- to get the polarity wrong.
--- @param src number|string|nil
--- @return table  { invite = '<url>', member = true } -- either key may be absent
function BR.Community.payload(src)
    local payload = {}
    local url = invite()
    if url ~= nil then payload.invite = url end
    -- `== true`, NEVER TRUTHINESS. BR.Guild.member answers three values and the
    -- one that must not reach here is nil -- which is falsy, so `if member then`
    -- would happen to be right today and would be one refactor away from writing
    -- `member = nil` into a table, where it is indistinguishable from absent
    -- until somebody writes `member = false` instead.
    if src ~= nil and BR.Guild and BR.Guild.member(src) == true then
        payload.member = true
    end
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
--- Tell one player what we currently know.
---
--- ONE FUNCTION AND ONE EVENT, because the membership answer travels on the
--- payload that already exists rather than on a channel of its own. A second
--- channel would mean a page assembling the card from two envelopes that can
--- arrive in either order, which is a race with a visible symptom -- the card
--- appearing for a moment and then going away.
local function answer(src)
    -- `{}` WHEN THERE IS NO INVITE, NEVER SILENCE. An empty table is a definite
    -- "this server publishes no Discord", and it is what lets a page that is
    -- already up take the card down after an operator clears the convar and
    -- restarts. Staying quiet would leave the last answer standing forever.
    TriggerClientEvent(BR.Net.COMMUNITY, src, BR.Community.payload(src))
end

RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = source
    answer(src)

    -- AND THEN, AT MOST ONCE PER CONNECTION, ASK DISCORD.
    --
    -- NOT BEFORE THE SEND. The page is told what we know now and corrected if we
    -- learn better, rather than held back behind a network round trip to a third
    -- party -- a Discord outage must cost this feature its answer and never the
    -- rest of the payload.
    --
    -- ONLY A `true` RE-SENDS. false and nil both leave the card exactly where the
    -- first send left it, so there is nothing to say; sending anyway would put a
    -- redundant envelope on the wire for every player on the server.
    --
    -- WHICH IS ALSO WHY A LATE ANSWER IS HARMLESS. The realistic case is that the
    -- lookup primed at playerJoining below settled while the player was still
    -- loading, so the very first payload already carries `member` and no second
    -- envelope is sent at all.
    if BR.Guild then
        BR.Guild.ask(src, function(member)
            if member == true then answer(src) end
        end)
    end
end)

-- THE HEAD START. A connection has a resource download and a spawn between it and
-- its first br:ready -- tens of seconds -- and asking here spends that instead of
-- the seconds after the player is already in the world. Without it the card can
-- be on screen when the answer lands and disappear under somebody reading it.
--
-- THE GUARD IS THE INVITE, AND IT BELONGS HERE RATHER THAN IN server/guild.lua.
-- A server that publishes no Discord draws no card, so there is nothing to hide
-- and no reason to spend a Discord call per connection finding out who to hide it
-- from. guild.lua answers a question; this file decides when the question is
-- worth asking, which is the only reason it knows about both.
AddEventHandler('playerJoining', function()
    if invite() == nil then return end
    if BR.Guild then BR.Guild.ask(source, nil) end
end)

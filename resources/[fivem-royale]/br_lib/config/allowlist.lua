-- Who may join a DEV-MODE server, and nothing else.
--
-- ONE KEY: the Discord role a player must hold in our guild to connect while dev
-- mode is on (BR.Dev.on(), which is sv_devMode OR br_devMode). With dev mode off
-- nothing reads it and nothing about joining changes. br_ringmaster/server/
-- gate.lua enforces it, AFTER the ban check; br_core/server/guild.lua asks
-- Discord about it, with the same token and the same queue the Discord card uses,
-- and refuses every dev-mode join itself while that gate is not armed.
--
-- NOT A SECRET. A role id is visible to anybody in the guild with Discord's
-- developer mode on. The credential that lets us ASK about it is the bot token,
-- and that stays on its convar for the reasons config/community.lua gives.
--
-- NOT AN OVERRIDE. A different role per box has not been asked for, so this is a
-- committed value rather than a convar in config/overrides.lua.
--
-- READ ON THE SERVER ONLY, AND NOT WITHHELD FROM CLIENTS. br_core loads it into
-- its server Lua state alone, beside server/guild.lua, and no client script reads
-- it. The file itself is still in br_lib's `files` glob like every other config
-- file, so any client can download it -- which costs nothing, because it is not a
-- secret (above).

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Allowlist = {
    -- A Discord snowflake, AS A STRING, because it is compared against the
    -- strings Discord's member object carries in `roles`.
    roleId = '1548704100621750272',
}

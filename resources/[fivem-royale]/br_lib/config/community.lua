-- Where to send a player who wants to talk to us, and nothing else.
--
-- ONE KEY, AND IT HAS NO USEFUL COMMITTED DEFAULT -- the same shape as
-- config/admin.lua and here for the same reason. Every other value in
-- br_lib/config/ is a reviewed number a dev box may want different; this is an
-- address that exists per deployment, whose default is "there isn't one, so the
-- line is not printed". It lives on the override mechanism because that is the
-- only thing in this project that gives a convar a strict parse, a hard boot
-- failure on a bad value, a line in the boot banner and a line in `brconfig`.
--
-- IT IS NOT THE ADMIN CONSOLE'S FILE, and that is why this is a second file
-- rather than a second key in config/admin.lua. That file says "where the admin
-- console lives, and nothing else" in its first line, and it means it: its value
-- is compared against a browser's `event.origin` and is refused if it carries so
-- much as a trailing slash. This one is the opposite -- a link a player is meant
-- to open, path and all -- and folding two values with opposite rules into one
-- file whose header describes one of them is how the wrong parser gets applied.
--
-- NOTHING HERE IS A SECRET. A Discord invite is a public address; it is printed
-- to anyone we kick. The rule config/admin.lua states applies unchanged: the
-- address is not a secret, the secret is, and secrets live on convars that are
-- never reported (see br_ringmaster/server/config.lua).
--
-- SERVER-READ ONLY, like every other overridable key, and tools/verify.sh's
-- tunable-overrides gate enforces it by grepping br_*/client/*.lua for the key
-- name. No client reads this: the only surface it reaches is the message shown
-- to a player being kicked or refused at the door, and both of those are built
-- on the server.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Community = {
    -- The Discord invite, as a full link: scheme, host and path.
    --
    -- EMPTY MEANS NO LINE AT ALL. A kicked player is told why they were kicked
    -- and nothing more, exactly as before this existed. An appeal sentence with
    -- a blank where the address should be would be worse than no sentence --
    -- it invites somebody to go looking for a link that is not there.
    --
    -- A LINK, NOT AN ORIGIN, which is the difference between this and
    -- BR.Config.Admin.consoleUrl. An invite is `https://discord.gg/<code>`: the
    -- code is the whole point of it, and the parser in config/overrides.lua
    -- keeps the path for that reason while still refusing the shapes that would
    -- break the message it is printed in.
    discordUrl = '',
}

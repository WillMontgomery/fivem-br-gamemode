-- Where the admin console lives, and nothing else.
--
-- ONE KEY, AND IT HAS NO USEFUL COMMITTED DEFAULT. Every other value in
-- br_lib/config/ is a reviewed number that a dev box may override; this is the
-- opposite shape -- an address that differs per deployment, whose default is
-- "there isn't one, so the feature is off". It lives here anyway because
-- config/overrides.lua is the only mechanism in the project that gives a convar
-- a strict parse, a hard boot failure on a bad value, a line in the boot banner
-- and a line in `brconfig`, and all four of those are the point (#23).
--
-- THE SECRET IS NOT HERE AND MUST NEVER BE. br_ringmaster/server/config.lua
-- holds `br_ringmaster_ingest_secret`, out of the repo, on a convar, printed
-- only as a character count. The rule that file states is the rule here: the
-- URL is not a secret; the secret is. What this file holds is a public address
-- that a browser is going to display in full anyway.
--
-- SERVER-READ ONLY, like every other overridable key, and tools/verify.sh's
-- tunable-overrides gate enforces it by grepping br_*/client/*.lua for the key
-- name. The client DOES need this value -- it is the iframe's `src` -- and it
-- is sent over the wire in the `admin` envelope rather than read from here, so
-- there is exactly one reader of the convar and no way for the two sides to
-- hold different addresses for the same setting.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Admin = {
    -- The console's ORIGIN: scheme, host, optional port, and nothing else.
    --
    -- EMPTY MEANS OFF, and off is a perfectly ordinary server. No convar, no
    -- Admin tab, no HTTP call, nothing in any log beyond the boot banner
    -- saying it is not set. A game that cannot reach Ringmaster is a game
    -- that plays exactly as it did before Ringmaster existed.
    --
    -- IT IS AN ORIGIN RATHER THAN A URL because it is compared, not just
    -- fetched. The page checks `event.origin === this` before it will let a
    -- postMessage trigger the minting of an admin session, and `event.origin`
    -- is always bare -- no path, no trailing slash. A value carrying either
    -- would never match, the comparison would silently always fail, and the
    -- symptom would be a console that shows a login page forever. So the
    -- parser in config/overrides.lua refuses anything that is not bare.
    consoleUrl = '',
}

-- Seasons: the one list of features gated by the season a server runs (#388).
--
-- Owner, 2026-10-04: launch, then updates called Seasons. "Rather than cherry
-- pick for commits or PRs, we should gate our functions (or versions of them)
-- by a server convar (set at startup) for which season the server should be
-- running ... By default, any function introduced before the current server
-- version should be enabled, and future versions, if present, should be
-- disabled. This is how we can run season 3 on dev and season 2 on prod with
-- the same codebase."
--
-- ═══ ONE ROW PER GATED FEATURE, AND ONLY HERE ═══
--
--   <id> = { from = <n> }                     on from Season n
--   <id> = { from = <n>, untilSeason = <m> }  on from Season n, OFF again from
--                                             Season m ("It's possible a season
--                                             would remove a feature, yes.")
--
-- A door asks BR.Season.has('<id>') (br_lib/shared/season.lua), and that is the
-- only way anything asks. A feature with no row is not gated at all. For a
-- VERSION of a function or a value rather than a feature that is on or off,
-- BR.Season.pick({ [1] = old, [3] = new }) needs no row.
--
-- tools/check_seasons.lua (verify.sh's `season gates`) fails the build for an
-- id passed to has() with no row here, a row nothing asks about, a `from` past
-- `latest`, and an untilSeason at or before its `from`.
--
-- ═══ latest ═══
--
-- The newest season this code knows. A server whose config does not set
-- br_season runs this one, and says so in a banner at boot (owner, 2026-10-04:
-- "If a server's config doesn't set a season, assume the latest and warning in
-- the console"). A row's `from` may not be past it, so the first feature of a
-- new season is the commit that raises it.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Seasons = {
    latest = 2,

    features = {
        -- #215. Owner, 2026-10-04: the first Season 2 feature, moved from
        -- dev-only to Season 2 and later.
        emotes = { from = 2 },
        -- #395. Owner, 2026-10-04: the shipping-box crates -- a prop per tier,
        -- the opening clip, the festive set and the gift boxes -- are Season 2
        -- content. Off, every crate is today's wooden one and opens at once.
        crates2 = { from = 2 },
        -- #396. Owner, 2026-10-04: computer terminals that manipulate the
        -- match, unlocked by a Yubikey, "for Season 2".
        terminals = { from = 2 },
        -- #399. Owner, 2026-10-05: "yes snow is meant to reach the players" --
        -- December and January, on the festive crates' switch (`brfestive`),
        -- everywhere. The festive sky: the clear sky is XMAS with snow on the
        -- ground, and in a match it cycles SNOW, SNOWLIGHT, XMAS and BLIZZARD
        -- (2026-10-06). Off, every sky is the one it has always been.
        snow = { from = 2 },
    },
}

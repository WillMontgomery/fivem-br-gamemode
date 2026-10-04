-- br_core's per-frame budget: native calls per frame, per phase, that
-- `lua tools/perf_client.lua --check` allows (tools/verify.sh runs it).
--
-- WRITTEN, NOT EDITED: `lua tools/perf_client.lua --rebaseline` measures the
-- tree and writes this file with each phase's number plus 5% (at least 2
-- calls). Rebaseline only for a change that is MEANT to cost more, and say so
-- in its commit. See docs/testing.md.
return {
    frames = 600,
    phases = {
        { id = "lobby", measured = 74.7, budget = 79 },
        { id = "warmup", measured = 125.7, budget = 132 },
        { id = "plane boarding", measured = 105.6, budget = 111 },
        { id = "plane cruise", measured = 134.5, budget = 142 },
        { id = "freefall", measured = 124.6, budget = 131 },
        { id = "chute", measured = 134.0, budget = 141 },
        { id = "match", measured = 368.7, budget = 388 },
        { id = "match aim", measured = 281.1, budget = 296 },
        { id = "match pings", measured = 375.5, budget = 395 },
        { id = "match drive", measured = 372.7, budget = 392 },
        { id = "match revive", measured = 388.0, budget = 408 },
        { id = "match ptt", measured = 364.0, budget = 383 },
        { id = "match loot", measured = 360.3, budget = 379 },
        { id = "match sweep", measured = 331.2, budget = 348 },
        { id = "match late", measured = 180.5, budget = 190 },
        { id = "match outside", measured = 158.7, budget = 167 },
        { id = "match emote", measured = 258.9, budget = 272 },
        { id = "match downed", measured = 197.2, budget = 208 },
        { id = "match spectate", measured = 183.1, budget = 193 },
    },
}

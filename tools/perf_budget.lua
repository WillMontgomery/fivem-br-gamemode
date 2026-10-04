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
        { id = "match", measured = 362.4, budget = 381 },
        { id = "match sweep", measured = 339.5, budget = 357 },
        { id = "match late", measured = 183.2, budget = 193 },
    },
}

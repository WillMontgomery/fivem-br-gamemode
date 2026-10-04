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
        { id = "warmup", measured = 105.2, budget = 111 },
        { id = "plane boarding", measured = 85.5, budget = 90 },
        { id = "plane cruise", measured = 142.1, budget = 150 },
        { id = "freefall", measured = 146.7, budget = 154 },
        { id = "chute", measured = 123.5, budget = 130 },
        { id = "match", measured = 348.1, budget = 366 },
        { id = "match sweep", measured = 331.1, budget = 348 },
        { id = "match late", measured = 183.6, budget = 193 },
    },
}

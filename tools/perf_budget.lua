-- br_core's per-frame budget: what each phase measured, per frame, as native
-- calls, draw calls (natives named Draw*) and kilobytes allocated.
-- `lua tools/perf_client.lua --check` (tools/verify.sh runs it) fails a phase
-- that goes over any of them by more than 2.5 natives, 0.9 draws or 0.9 KB.
--
-- WRITTEN, NOT EDITED: `lua tools/perf_client.lua --rebaseline` measures the
-- tree and writes this file. The slack is in tools/perf_client.lua, not here.
-- Rebaseline only for a change that is MEANT to cost more (or that costs
-- less, to keep the guard tight), and say so in its commit. See docs/testing.md.
return {
    frames = 600,
    phases = {
        { id = "lobby", natives = 74.722, draws = 0.000, kb = 0.389 },
        { id = "warmup", natives = 125.913, draws = 4.000, kb = 0.270 },
        { id = "plane boarding", natives = 106.335, draws = 0.000, kb = 0.267 },
        { id = "plane cruise", natives = 159.272, draws = 49.053, kb = 0.606 },
        { id = "freefall", natives = 150.213, draws = 49.000, kb = 0.389 },
        { id = "chute", natives = 153.600, draws = 48.000, kb = 0.390 },
        { id = "match", natives = 503.872, draws = 334.000, kb = 0.936 },
        { id = "match aim", natives = 502.260, draws = 334.000, kb = 1.026 },
        { id = "match pings", natives = 510.633, draws = 338.000, kb = 1.173 },
        { id = "match drive", natives = 507.758, draws = 334.000, kb = 1.200 },
        { id = "match revive", natives = 529.110, draws = 335.000, kb = 1.176 },
        { id = "match ptt", natives = 499.093, draws = 334.000, kb = 0.952 },
        { id = "match loot", natives = 495.408, draws = 334.000, kb = 0.933 },
        { id = "match sweep", natives = 436.347, draws = 274.007, kb = 4.097 },
        { id = "match late", natives = 197.627, draws = 52.000, kb = 0.639 },
        { id = "match outside", natives = 187.770, draws = 52.000, kb = 0.640 },
        { id = "match emote", natives = 276.037, draws = 53.000, kb = 0.713 },
        { id = "match downed", natives = 214.265, draws = 52.000, kb = 0.644 },
        { id = "match spectate", natives = 200.240, draws = 52.000, kb = 0.935 },
    },
}

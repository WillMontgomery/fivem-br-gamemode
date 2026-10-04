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
        { id = "warmup", natives = 125.690, draws = 4.000, kb = 0.270 },
        { id = "plane boarding", natives = 105.655, draws = 0.000, kb = 0.267 },
        { id = "plane cruise", natives = 157.638, draws = 49.053, kb = 0.606 },
        { id = "freefall", natives = 148.580, draws = 49.000, kb = 0.389 },
        { id = "chute", natives = 151.967, draws = 48.000, kb = 0.390 },
        { id = "match", natives = 502.705, draws = 334.000, kb = 0.936 },
        { id = "match aim", natives = 501.107, draws = 334.000, kb = 1.026 },
        { id = "match pings", natives = 509.522, draws = 338.000, kb = 1.173 },
        { id = "match drive", natives = 506.658, draws = 334.000, kb = 1.200 },
        { id = "match revive", natives = 528.010, draws = 335.000, kb = 1.176 },
        { id = "match ptt", natives = 497.993, draws = 334.000, kb = 0.952 },
        { id = "match loot", natives = 494.308, draws = 334.000, kb = 0.933 },
        { id = "match sweep", natives = 435.247, draws = 274.007, kb = 26.305 },
        { id = "match late", natives = 196.527, draws = 52.000, kb = 0.639 },
        { id = "match outside", natives = 186.670, draws = 52.000, kb = 0.640 },
        { id = "match emote", natives = 274.937, draws = 53.000, kb = 0.713 },
        { id = "match downed", natives = 213.165, draws = 52.000, kb = 0.644 },
        { id = "match spectate", natives = 199.140, draws = 52.000, kb = 0.935 },
    },
}

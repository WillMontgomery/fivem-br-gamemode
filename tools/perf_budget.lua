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
        { id = "plane boarding", natives = 105.648, draws = 0.000, kb = 0.267 },
        { id = "plane cruise", natives = 134.422, draws = 21.837, kb = 0.606 },
        { id = "freefall", natives = 124.580, draws = 21.000, kb = 0.389 },
        { id = "chute", natives = 133.967, draws = 26.000, kb = 0.390 },
        { id = "match", natives = 368.705, draws = 196.000, kb = 0.936 },
        { id = "match aim", natives = 281.107, draws = 110.000, kb = 1.026 },
        { id = "match pings", natives = 375.520, draws = 200.000, kb = 1.173 },
        { id = "match drive", natives = 372.658, draws = 196.000, kb = 1.200 },
        { id = "match revive", natives = 388.010, draws = 191.000, kb = 1.176 },
        { id = "match ptt", natives = 363.993, draws = 196.000, kb = 0.952 },
        { id = "match loot", natives = 360.308, draws = 196.000, kb = 0.933 },
        { id = "match sweep", natives = 331.247, draws = 166.007, kb = 26.305 },
        { id = "match late", natives = 180.527, draws = 32.000, kb = 0.639 },
        { id = "match outside", natives = 158.670, draws = 20.000, kb = 0.640 },
        { id = "match emote", natives = 258.937, draws = 33.000, kb = 0.713 },
        { id = "match downed", natives = 197.165, draws = 32.000, kb = 0.644 },
        { id = "match spectate", natives = 183.140, draws = 32.000, kb = 0.935 },
    },
}

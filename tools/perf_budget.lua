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
        { id = "lobby", natives = 74.455, draws = 0.000, kb = 0.397 },
        { id = "warmup", natives = 127.480, draws = 4.000, kb = 0.279 },
        { id = "plane boarding", natives = 108.492, draws = 0.000, kb = 0.266 },
        { id = "plane cruise", natives = 158.955, draws = 49.053, kb = 0.674 },
        { id = "freefall", natives = 149.897, draws = 49.000, kb = 0.398 },
        { id = "chute", natives = 153.283, draws = 48.000, kb = 0.398 },
        { id = "match", natives = 503.557, draws = 334.000, kb = 0.851 },
        { id = "match aim", natives = 501.943, draws = 334.000, kb = 0.941 },
        { id = "match pings", natives = 510.318, draws = 338.000, kb = 1.087 },
        { id = "match drive", natives = 507.442, draws = 334.000, kb = 1.115 },
        { id = "match revive", natives = 528.793, draws = 335.000, kb = 1.091 },
        { id = "match ptt", natives = 498.775, draws = 334.000, kb = 0.866 },
        { id = "match loot", natives = 495.092, draws = 334.000, kb = 0.848 },
        { id = "match sweep", natives = 434.985, draws = 274.007, kb = 2.892 },
        { id = "match late", natives = 197.310, draws = 52.000, kb = 0.553 },
        { id = "match outside", natives = 187.620, draws = 52.000, kb = 0.554 },
        { id = "match emote", natives = 274.153, draws = 53.000, kb = 0.834 },
        { id = "match downed", natives = 213.948, draws = 52.000, kb = 0.558 },
        { id = "match spectate", natives = 199.923, draws = 52.000, kb = 0.850 },
    },
}

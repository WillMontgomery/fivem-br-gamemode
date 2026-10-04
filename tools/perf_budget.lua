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
        { id = "lobby", natives = 74.772, draws = 0.000, kb = 0.397 },
        { id = "warmup", natives = 125.963, draws = 4.000, kb = 0.278 },
        { id = "plane boarding", natives = 106.328, draws = 0.000, kb = 0.275 },
        { id = "plane cruise", natives = 159.400, draws = 49.053, kb = 0.614 },
        { id = "freefall", natives = 150.263, draws = 49.000, kb = 0.398 },
        { id = "chute", natives = 153.650, draws = 48.000, kb = 0.398 },
        { id = "match", natives = 503.922, draws = 334.000, kb = 0.851 },
        { id = "match aim", natives = 502.310, draws = 334.000, kb = 0.941 },
        { id = "match pings", natives = 510.683, draws = 338.000, kb = 1.087 },
        { id = "match drive", natives = 507.808, draws = 334.000, kb = 1.115 },
        { id = "match revive", natives = 529.160, draws = 335.000, kb = 1.091 },
        { id = "match ptt", natives = 499.143, draws = 334.000, kb = 0.866 },
        { id = "match loot", natives = 495.458, draws = 334.000, kb = 0.848 },
        { id = "match sweep", natives = 435.352, draws = 274.007, kb = 2.892 },
        { id = "match late", natives = 197.677, draws = 52.000, kb = 0.553 },
        { id = "match outside", natives = 187.820, draws = 52.000, kb = 0.554 },
        { id = "match emote", natives = 276.087, draws = 53.000, kb = 0.627 },
        { id = "match downed", natives = 214.315, draws = 52.000, kb = 0.558 },
        { id = "match spectate", natives = 200.290, draws = 52.000, kb = 0.850 },
    },
}

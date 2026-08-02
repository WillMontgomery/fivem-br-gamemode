-- Clock synchronisation (server half).
--
-- Small, but load-bearing. Every countdown in the game -- storm phases, the bus
-- route, warmup, bleed-out -- is derived locally on each client from a single
-- server timestamp rather than being ticked over the network. That is what makes
-- a shrinking storm cost zero per-frame traffic.
--
-- It only works if clients agree with the server about what time it is, which is
-- what this provides. See br_lib/shared/clock.lua for the estimator.

RegisterNetEvent(BR.Net.CLOCK_PING)
AddEventHandler(BR.Net.CLOCK_PING, function(sentAt)
    -- Echo the client's own send time back untouched so it can compute the round
    -- trip without keeping state, and stamp our own clock alongside it.
    TriggerClientEvent(BR.Net.CLOCK_PONG, source, sentAt, GetGameTimer())
end)

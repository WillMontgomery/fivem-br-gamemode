-- brring -- the health dump.
--
-- Modelled on br_stats' `brdb`, and for the same reason: when an operations
-- tool is quiet, "working perfectly" and "not configured" and "endpoint has
-- been refusing us for an hour" all look identical from the console. One
-- command that says which.
--
-- THIS IS THE ONLY RegisterCommand IN THIS RESOURCE, and verify.sh's Slice-1
-- boundary gate enforces that. It reads and prints; it changes nothing.

local RESTRICTED = true

local function line()
    return ('-'):rep(52)
end

RegisterCommand('brring', function()
    local c  = BR.Ring.Config
    local ok = c.configured()

    print(line())
    print('br_ringmaster')
    print(line())
    print(('boot epoch    %s'):format(BR.Ring.bootEpoch))
    print(('configured    %s'):format(tostring(ok)))

    if ok then
        print(('ingest        %s'):format(c.ingestUrl))
        -- Length only. Printing the secret into the console would also print it
        -- into whatever is capturing the console, which is the log file M9's
        -- own 9e section is about to start keeping for two weeks.
        print(('secret        set (%d chars)'):format(#c.ingestSecret))
        print(('push every    %dms'):format(c.pushMs))
    end

    print(('licenses seen %d this process'):format(BR.Ring.seenCount()))

    -- The push and event channels land in Slice 1's next commits; until then
    -- say so rather than printing zeros that look like a healthy idle.
    if BR.Ring.pushStats then
        local s = BR.Ring.pushStats()
        print(('snapshot      %s'):format(s.summary or 'idle'))
    else
        print('snapshot      not wired yet')
    end

    if BR.Ring.outbox then
        local s = BR.Ring.outbox:stats()
        print(('events        depth %d, inflight %d'):format(s.depth, s.inflight))
        print(('              emitted %d, sent %d'):format(s.emitted, s.sent))
        -- Dropped counters are the whole reason the outbox keeps them. A queue
        -- that silently discarded an anticheat firing is exactly the failure
        -- this tool exists to make visible.
        print(('              dropped full %d, retry %d, off %d')
            :format(s.droppedFull, s.droppedRetry, s.droppedOff))
    else
        print('events        not wired yet')
    end

    print(line())
end, RESTRICTED)

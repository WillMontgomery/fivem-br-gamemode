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

-- bridents [serverId] -- print a connected player's identifiers, or everyone's.
--
-- Exists because the absence of exactly this turned "read my own license off
-- my own server" into a multi-step ordeal by way of profile caches and match
-- lifecycles. The identifiers are RIGHT THERE on the connection; a console
-- command should simply print them.
--
-- Allowlisted via BR.Identity, not raw: the ip: entry is never collected, and
-- that policy holds doubly here because the console is mirrored to
-- console.log -- printing an IP would be writing network-location data to a
-- file this project has promised not to keep. The dropped count says how many
-- entries the allowlist refused, so nothing vanishes silently.
RegisterCommand('bridents', function(_, args)
    local function show(src)
        local name = GetPlayerName(src)
        if not name then
            print(('  no player with id %s'):format(tostring(src)))
            return
        end

        local _, ordered, dropped = BR.Identity.ofPlayer(src)
        print(('=== %s (%s) ==='):format(name, tostring(src)))
        for _, id in ipairs(ordered) do
            print(('  %-10s %s'):format(id.kind, BR.Identity.qualified(id.kind, id.value)))
        end
        if dropped > 0 then
            print(('  (%d identifier(s) not on the allowlist, not shown)'):format(dropped))
        end
    end

    local target = tonumber(args and args[1])
    if target then
        show(target)
        return
    end

    local players = GetPlayers()
    if #players == 0 then
        print('  nobody connected')
        return
    end
    for _, src in ipairs(players) do
        show(src)
    end
end, RESTRICTED)

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

    -- INCIDENTS ARE REPORTED SEPARATELY FROM THE OUTBOX because they do not go
    -- through it. The row is written straight to DynamoDB and only a doorbell
    -- rides the queue -- so an outbox showing zero drops says nothing at all
    -- about whether a case was filed.
    --
    -- `lost` is the number that matters and the reason this block exists: there
    -- is no queue behind a failed incident write, so a non-zero count is evidence
    -- that a moderation record no longer exists anywhere.
    if BR.Ring.incidentStats then
        local i = BR.Ring.incidentStats()
        print(('incidents     filed %d, in flight %d'):format(i.filed, i.inflight))
        -- NOT A SECOND KIND OF FILING. One persistent cheater is one case plus a
        -- handful of these, so counting them together would make the number
        -- describe the opposite of what happened. A high ratio here is the healthy
        -- shape: it means repeat offenders are landing on one case each.
        if (i.corroborated or 0) > 0 then
            print(('              %d corroborations appended to existing cases')
                :format(i.corroborated))
        end
        if i.duplicate > 0 then
            -- Not a fault. A retry after a lost ANSWER finds its own row already
            -- there, which is the idempotency token working as intended.
            print(('              %d were already present (retry after a lost reply)')
                :format(i.duplicate))
        end
        if i.failed > 0 then
            print(('^1              %d LOST -- no queue, no retry left, no record^7')
                :format(i.failed))
        end

        -- ═══ THE MATCH-END CLOSE, WHICH HAD NO VOICE ANYWHERE UNTIL NOW ═══
        --
        -- `closeFailed` has been counted since #30 and printed by nothing. The
        -- failure it counts is the quietest one this pipeline has: the case is
        -- filed, the row is durable, the console lists it, and the match-end
        -- write that would say how the match finished never lands. Every symptom
        -- appears on the CONSOLE -- cases reading "end never reported" -- and
        -- nothing on the game box says a word, so the obvious diagnosis is a
        -- console bug and the actual cause is an IAM policy that does not name
        -- an attribute this write touches. That has now come up three times.
        --
        -- ALWAYS PRINTED, INCLUDING THE ZERO, unlike the conditional lines above.
        -- Those are exceptions worth pointing at; this pair is the health of a
        -- write path, and "closes 0, failed 0" on a server that has been running
        -- matches is itself an answer -- it says no case has reached a match end
        -- yet, which is different from every close succeeding.
        print(('              closes %d, failed %d')
            :format(i.closed or 0, i.closeFailed or 0))
        if (i.closeFailed or 0) > 0 then
            -- THE DIAGNOSIS, NOT JUST THE COUNT. The attribute allowlist is the
            -- one cause a reader cannot guess from the console's symptom, and it
            -- is the cause every time this has happened.
            print(('^1              %d will read "end never reported" -- check dynamodb:Attributes^7')
                :format(i.closeFailed))
        end
    else
        print('incidents     not wired yet')
    end

    print(line())
end, RESTRICTED)

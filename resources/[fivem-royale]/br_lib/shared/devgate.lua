-- The dev gate: one switch in front of every console command in the project.
--
-- Owner, 2026-08-31: "Yes I want all client and server commands gated behind
-- devmode." Said after being shown that three of them are Ringmaster's hands on
-- the live server, which is why there is an exemption list at all.
--
-- ═══ WHY THIS WRAPS RegisterCommand INSTEAD OF BEING CALLED 142 TIMES ═══
--
-- The obvious shape is a helper every command calls first -- `if not devOnly()
-- then return end` -- and that is what brcar, brshots, brtestfire, brtime and
-- brweather each grew for themselves. Five copies of a rule is survivable.
-- A hundred and thirty is not, and the failure mode is not the copies: it is
-- the HUNDRED AND THIRTY-FIRST. A command written next month with no helper
-- call is ungated, it looks exactly like every gated one, and nothing says a
-- word. The gate would have to be enforced by policing every new call site
-- forever, which is the same job as remembering to write it.
--
-- So the rule is installed ONCE, at the only door all of them go through. Every
-- file that loads after this one gets a RegisterCommand that carries the gate,
-- and a new command is gated BY CONSTRUCTION rather than by anyone remembering.
-- tools/verify.sh checks the two things that construction rests on: that this
-- file is the first script in every resource that registers a command, and that
-- the raw door below is used by exactly the four sites named there.
--
-- ═══ AND WHY IT FAILS OPEN RATHER THAN CLOSED ═══
--
-- If this file ever falls out of a manifest, RegisterCommand is the untouched
-- native and every command in that resource registers ungated. That is the
-- WRONG direction for a security gate and the RIGHT one here, because the three
-- exempt verbs are the console's only reach into a running match --
-- br_ringmaster/server/kick.lua already guards its appeal lookup for exactly
-- this reason ("A KICK MUST HAPPEN WHATEVER ELSE IS WRONG"). A gate that can
-- take brkick off the public box by failing to load is worse than a gate that
-- can leave brshop on it. The dev box is where a missing gate gets noticed; the
-- public box is where a missing kick does not.

BR = BR or {}
BR.Dev = BR.Dev or {}

-- ─────────────────────────────────────────────────────────── the exemptions ---

-- THE THREE VERBS THAT KEEP WORKING ON THE PUBLIC BOX.
--
--   brkick, brspectate  tools/dispatch.sh types these into this console over
--                       tmux (send-keys, do_kick and do_spectate). They ARE the
--                       admin console's Kick and Spectate buttons. Gating them
--                       would not produce an error anywhere the console can
--                       see -- the button would post, the SSH verb would
--                       succeed, the keystrokes would land, and the player
--                       would stay exactly where they were.
--   brring              the health dump, and the only thing on the game box
--                       that can tell "the Ringmaster link is fine" from "it
--                       has been refusing us for an hour". DEPLOY.md sends the
--                       operator here after an IAM policy change, on the live
--                       server, by hand. Nothing types it for them.
local EXEMPT = { brkick = true, brspectate = true, brring = true }

-- ───────────────────────────────────────────────────────────────── the read ---

--- Is this box a dev box?
---
--- RESOLVED HERE RATHER THAN READ OFF BR.Server, because BR.Server exists in
--- exactly one Lua state -- br_core's server side -- and this file runs in
--- five resources across both states. br_ddb and br_stats have no BR.Server at
--- all, and a nil-indexed read there would raise inside every command they own.
--- The two convar names and the OR between them are br_core/server/main.lua's,
--- copied so the two answers cannot drift.
---
--- ON THE CLIENT ONLY br_devMode ARRIVES, and it arrives carrying the OR:
--- server/main.lua resolves both names and replicates the single answer under
--- that one. sv_devMode is never replicated, so the client's read of it is
--- always the default -- which is why this must OR rather than pick one.
---
--- READ AT CALL TIME, NOT AT REGISTRATION TIME. A replicated convar has not
--- necessarily reached the client when its scripts load, so a value latched at
--- registration would be `false` on a dev box for as long as the process lived,
--- and every client dev command would be dead with no way to tell why.
--- @return boolean
function BR.Dev.on()
    if not GetConvar then return false end
    return GetConvar('sv_devMode', 'false') == 'true'
        or GetConvar('br_devMode', 'false') == 'true'
end

-- ───────────────────────────────────────────────────────────────── the door ---

--- The unwrapped native, captured before the wrap below replaces it.
---
--- FOR PLAYER INPUT ONLY, and there are four uses in the project. GTA has no
--- concept of a keybind: FiveM builds one out of a command plus
--- RegisterKeyMapping, so `+brinteract`, `brslot3` and `brmap` are console
--- commands in the same sense `brshop` is -- and they are also E, 3 and M.
--- Running them through the gate would take the player's entire keyboard away
--- on the public box, which is not a diagnostic anyone loses, it is the game.
--- `brleave` is the fourth: a bindable, documented, player-facing verb.
---
--- tools/verify.sh pins this to those four sites. Anything else wanting the raw
--- door is a console command trying to walk around the gate.
---
--- CAPTURED INSIDE THE GUARD BELOW, and that is not tidiness. A second load of
--- this file -- the same module listed twice in one manifest -- would otherwise
--- re-capture RegisterCommand AFTER the wrap had replaced it, and every keybind
--- row in br_core/client/keybinds.lua would register through the gate while
--- still reading like it went around it. The public box would have no keyboard,
--- and the line that took it away would be the line that exists to protect it.

-- ───────────────────────────────────────────────────────────────── the wrap ---

--- Guarded so a file listed twice in one manifest cannot wrap the wrap: the
--- second pass would leave two gates in front of every command and print the
--- refusal twice.
if not BR.Dev.installed then
    BR.Dev.installed = true

    BR.Dev.rawCommand = RegisterCommand

    local raw = BR.Dev.rawCommand
    local res = GetCurrentResourceName and GetCurrentResourceName() or 'br'

    --- @param name string @param fn function @param restricted boolean|nil
    RegisterCommand = function(name, fn, restricted)
        -- The exempt three go to the native untouched, and so does a call whose
        -- name is not a string -- that one is malformed, and handing it to the
        -- native lets IT say so rather than having this wrapper swallow it or
        -- die inside :format. A name that is not a string is not a command
        -- anybody can type, so it is not a way around the gate.
        if type(name) ~= 'string' or EXEMPT[name] then
            return raw(name, fn, restricted)
        end

        return raw(name, function(source, args, rawText)
            -- IT PRINTS RATHER THAN RETURNING QUIETLY, which is the whole
            -- point of gating a hundred and thirty verbs at once: a refusal
            -- that says nothing is indistinguishable from a command that ran
            -- and did nothing, and after this change that will be the ordinary
            -- experience of the public box. The person typing it needs to read
            -- WHICH gate closed and what to do about it.
            --
            -- CONSOLE ONLY, on both sides. On the server this is the server
            -- console; on the client it is the F8 console, where the client
            -- dev commands are typed. Nothing here is ever shown to a player
            -- in game -- no chat line, no toast.
            if not BR.Dev.on() then
                print(('[%s] %s is dev-mode only. Start the server with '
                    .. 'br_devMode true (or sv_devMode true) to use it.')
                    :format(res, name))
                return
            end
            return fn(source, args, rawText)
        end, restricted)
    end
end

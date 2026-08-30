-- What the chat screen will not carry: the LISTS, not the rules.
--
-- ═══ WHY THIS IS A CONFIG FILE AND NOT PART OF THE MODULE ═══
--
-- br_lib/shared/chat_screen.lua holds the matching -- the boundary rules, the
-- UTF-8 decoder, the codepoint allowlist -- and none of that changes when a new
-- URL shortener appears. These two tables do, constantly, and the owner should
-- be able to add a domain without a developer (coordinator, 2026-08-30). So the
-- rules are code and the lists are config, which is the same split every other
-- maintained table in this project already has.
--
-- ═══ SERVER-ONLY, AND DECLARED IN server_scripts RATHER THAN shared_scripts ═══
--
-- EVERY OTHER config/*.lua IS SHARED. This one is not, and the exception is the
-- point: shipping it to clients would hand every player the exact shape of the
-- filter, including which shorteners are missing from it. A cheater reading the
-- list learns precisely which domain still gets through. See br_core's
-- fxmanifest, where this loads beside evidence_buf and incident_build -- the two
-- other files kept off clients because they describe what the anticheat knows.
--
-- ═══ THE COST OF A WRONG ENTRY IS SILENT, SO READ THIS BEFORE ADDING ONE ═══
--
-- A message this catches is SHADOWED: the sender sees it post normally and
-- nobody else ever receives it, and they are never told. So an entry that is too
-- broad does not produce a complaint -- it produces a player who quietly cannot
-- talk. Add the HOST somebody would actually type, never a bare word: `twitch`
-- would silently eat "meet me on twitch", and `twitch.tv` does not.
--
-- Both tables are matched case-insensitively; write them lowercase.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.ChatScreen = {
    --- Top-level domains that make a bare `something.tld` a link.
    ---
    --- A CURATED LIST RATHER THAN "TWO OR MORE LETTERS AFTER A DOT", AND THE
    --- LIST IS THE WHOLE DESIGN. The obvious rule -- a word, a dot, a word --
    --- flags `config.lua`, `main.ts`, `README.md`, `player.name` and half of
    --- what people type about the game itself.
    ---
    --- WHAT IS DELIBERATELY MISSING, AND WHY. Each of these was considered and
    --- dropped because a real English phrase reaches it through an ordinary
    --- full stop with no space after it -- "let me know.it works", "i.win",
    --- "call.me", "log.in", "a.pro":
    ---
    ---     it is at me in us uk so no be to do on or as by my we he ai pro win
    ---
    --- and three that collide with file extensions this repository is made of:
    --- `md`, `sh` and `ts` are all real country-code domains and all far more
    --- likely to arrive as a filename in a message about the server.
    ---
    --- `top` IS OUT AND STAYS OUT, and that one was earned rather than
    --- reasoned: tools/test_shared.lua failed on "get on.top of the hill" while
    --- it was on this list. A cheap gTLD that turns up in adverts is worth less
    --- than a sentence somebody genuinely types.
    ---
    --- `ly` WAS OUT AND IS NOW IN -- OWNER, 2026-08-30, OVERRULING THE ORIGINAL
    --- CALL. It was excluded on the same grounds as `top`: "definite.ly" and
    --- "actual.ly" are things people type on purpose. The owner's reasoning for
    --- reversing it, recorded here so the next reader sees a decision rather
    --- than drift:
    ---
    ---   * "on.top of the hill" is an ordinary sentence; "definite.ly" needs a
    ---     full stop with no space before a word beginning "ly", which is close
    ---     to theoretical.
    ---   * NEW SHORTENERS APPEARING IS A CERTAINTY. The host list below only
    ---     ever catches the ones somebody has named; a TLD catches the ones
    ---     nobody has heard of yet, and Libya's ccTLD is used almost entirely
    ---     by shorteners and vanity domains.
    ---
    --- The accepted cost is that a player typing "definite.ly" is shadowed.
    --- That is a known, deliberate false positive -- tools/test_shared.lua
    --- asserts it happens rather than pretending it does not.
    tlds = {
        -- The generic domains an advert actually arrives on.
        'com', 'net', 'org', 'info', 'biz',
        -- The cheap ones, which is why they are the ones abused.
        'xyz', 'club', 'shop', 'store', 'site', 'online', 'click', 'link',
        'live', 'space', 'website', 'app', 'dev',
        -- Two-letter domains, and only these. `gg` is Discord's; the rest are
        -- either shortener homes or the country domains this server's
        -- advertisers use. None of them is an English word that follows a full
        -- stop -- which `ly` above is the argued exception to.
        'co', 'io', 'gg', 'cc', 'ru', 'cn', 'tv', 'ly',
    },

    --- URI schemes that are an invitation on their own, with no hostname in them.
    ---
    --- ═══ NO HOST LIST CAN CATCH THESE, WHICH IS WHY THEY ARE A THIRD TABLE ═══
    ---
    --- `fivem://connect/<code>` is the protocol handler the FiveM client
    --- registers on the player's machine. Clicking one joins a server directly.
    --- It carries no domain and no dot -- `fivem://connect/abcdef` would satisfy
    --- neither the TLD rule nor the host rule -- so without this it is the one
    --- form of "come play over here" that walks straight through a filter built
    --- entirely out of hostnames. `redm://` is the same handler for RedM.
    ---
    --- MATCHED AS A PLAIN PREFIX, WITH NO BOUNDARY CHECK, because a scheme is
    --- unambiguous in a way a hostname is not: there is no English word that
    --- contains "fivem://".
    schemes = {
        { reason = 'invite', prefixes = { 'fivem://', 'redm://' } },
    },

    --- Named hosts, matched WHOLE, grouped by what they say about the sender.
    ---
    --- ═══ A SECOND SIGNAL, NOT A WIDER TLD LIST ═══
    ---
    --- The shorteners below live on ordinary country domains -- `.gd`, `.gl`,
    --- `.gy`, `.be`, `.me`, `.it` -- that carry ordinary traffic and must not be
    --- blanket-blocked. `.me` in particular is the exclusion that keeps
    --- "call.me" safe. Naming the host catches `is.gd` without touching
    --- `something.gd`, and `t.co` without touching `taco.co`.
    ---
    --- ORDER IS PRECEDENCE. A line matching two groups takes the reason of the
    --- FIRST that matches, so the groups are ordered most-specific first:
    --- an invite to a rival community is a stronger finding than a shortener,
    --- which is stronger than a social link. `youtu.be` is both a shortener by
    --- shape and YouTube's own domain, and it reads as `social` because that is
    --- the truer description.
    ---
    --- A HOST WITH A SUBDOMAIN NEEDS NO ENTRY. Matching allows a dot on the
    --- left, so `whatsapp.com` covers `chat.whatsapp.com` and `tiktok.com`
    --- covers `vm.tiktok.com`. Add the registrable domain and stop.
    ---
    --- A HOST WHOSE TLD IS ALREADY ABOVE IS STILL WORTH LISTING. `twitch.tv`
    --- would be refused by `tv` regardless; naming it changes the reason
    --- recorded on the incident from "a link" to "a link to a social or
    --- streaming site", which is what a moderator is reading.
    hosts = {
        {
            reason = 'invite',
            domains = {
                -- ═══ THE ONE THAT MATTERS MOST ON A FiveM SERVER ═══
                --
                -- `cfx.re/join/<id>` IS how a rival GTA RP server is
                -- advertised -- it is the link the FiveM client itself opens to
                -- connect. `.re` is on no TLD list here and never will be, so
                -- without this entry the single most on-topic advert in this
                -- gamemode's chat would go straight through.
                'cfx.re',

                -- Discord's own invite forms. `discord.gg` is already refused
                -- by the `gg` TLD; it is named so the reason says "invite".
                -- `discord.com/invite/...` and the legacy
                -- `discordapp.com/invite/...` are matched on the HOST rather
                -- than the path -- a player linking Discord at all, mid-match,
                -- is doing the thing this exists to stop, and path matching
                -- would be a whole parser for no extra truth.
                'discord.gg', 'discord.com', 'discordapp.com', 'discord.new',
                -- Discord's own URL shortener, which is not the invite host but
                -- is Discord-operated and redirects into it.
                'dis.gd',
                -- Third-party vanity-invite and server-list hosts.
                --
                -- `invites.gg` IS THE LIVE SERVICE; `invite.gg` (no s) answers
                -- HTTP 521 with its origin down. Both are listed because the
                -- singular is the one people misremember and it costs nothing.
                'dsc.gg', 'invites.gg', 'invite.gg', 'disboard.org', 'top.gg',
                'discadia.com', 'discord.st', 'discords.com', 'discord.me',
                -- Guilded is Discord's nearest equivalent and is used the same
                -- way. Already caught by `gg`; named for the reason.
                'guilded.gg',
            },
        },
        {
            reason = 'shortener',
            domains = {
                -- `.ly` shorteners. All of these are now ALSO caught by the
                -- `ly` TLD above, and they stay named here so the incident says
                -- "a shortened link" rather than "a link" -- somebody hiding a
                -- destination is a stronger signal than somebody pasting one.
                'bit.ly', 'ow.ly', 'buff.ly', 'cutt.ly', 'rebrand.ly',
                -- The ones no TLD rule reaches, which is why this list exists.
                'is.gd', 'v.gd', 'rb.gy', 'shorturl.at', 't.ly', 's.id',
                'surl.li', 'shrtco.de', 'cutt.us',
                -- Twitter's own shortener. Named here rather than under social
                -- because what it does is hide the destination; `taco.co` is
                -- untouched because this matches the whole host.
                't.co',
                -- Already caught by their TLDs; named for the reason.
                'tinyurl.com', 'tiny.cc', 'clck.ru', 'vk.cc',
                'adf.ly', 'short.io', 'rebrandly.com', 'gg.gg',
                -- `adf.ly` WAS EXPECTED TO BE DEAD AND IS NOT. It was acquired
                -- by Linkvertise and folded in: an `adf.ly/<code>` path still
                -- redirects live into linkvertise.com today, which is why both
                -- are here. The widely-used public shortener blocklists have it
                -- filed as inactive, so trusting one of those would have left a
                -- working redirector open.
                'linkvertise.com',
                -- Link aggregators rather than shorteners strictly, and they
                -- belong here: one allowed link that opens a page of other
                -- links is the standard way around a host filter.
                'linktr.ee',
                -- ═══ goo.gl IS NOT DEAD, WHICH IS THE OPPOSITE OF WHAT THE
                -- SHUTDOWN HEADLINES SAY ═══
                --
                -- Google announced in July 2024 that every goo.gl link would
                -- stop working on 2025-08-25, and then REVERSED IT on
                -- 2025-08-01: only links with no activity in late 2024 were
                -- deactivated, and "all other goo.gl links will be preserved
                -- and will continue to function as normal". The host still
                -- serves today, and `maps.app.goo.gl` is still actively issued
                -- by Google Maps -- which the subdomain rule covers from this
                -- one entry.
                'goo.gl',
                -- DEAD, AND KEPT ANYWAY. `shorte.st` answers HTTP 410 Gone and
                -- `shrtco.de` is now a parked domain for sale. A player pasting
                -- either is still advertising, the entries cost one string
                -- each, and a blocklist loses nothing by naming a host that has
                -- stopped resolving. They are labelled so nobody wastes an
                -- afternoon working out why they cannot test them.
                'shorte.st',
            },
        },
        {
            reason = 'social',
            domains = {
                'twitter.com', 'x.com', 'instagram.com', 'instagr.am', 'ig.me',
                'tiktok.com', 'youtube.com', 'youtu.be',
                'facebook.com', 'fb.me', 'fb.watch', 'm.me',
                'twitch.tv', 'kick.com', 'medal.tv',
                -- Steam's own shortener, beside the community host below.
                's.team',
                -- `redd.it` needs this list: `it` is excluded from the TLDs
                -- above so that "let me know.it works" stays safe.
                'reddit.com', 'redd.it',
                -- Telegram and WhatsApp live on `.me`, which is excluded for
                -- "call.me". Note "meet.me" and "shirt.me" do NOT match `t.me`:
                -- the character to its left is a letter, so the boundary fails.
                't.me', 'telegram.me', 'wa.me', 'whatsapp.com',
                'steamcommunity.com', 'vk.com', 'snapchat.com',
                -- BOTH THREADS DOMAINS. Meta moved Threads to `threads.com` in
                -- April 2025 and `threads.net` is now only a redirect to it --
                -- so a list carrying the old one alone would miss every link
                -- anybody has shared since.
                'threads.net', 'threads.com',
            },
        },
    },
}

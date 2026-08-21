--[[
    The last sentence a removed player reads.

    Owner, verbatim (2026-08-20):

        Please join our Discord to discuss or appeal: https://discord.gg/PggjJ7hDSg

    THE WORDS ARE FIXED AND THE ADDRESS IS NOT. Everything up to the colon is
    written here and nowhere else; the URL comes from `br_discordUrl`, parsed and
    range-checked at boot by br_lib/config/overrides.lua, which is the only
    mechanism in this project that refuses a bad value loudly instead of shipping
    it into a player's face.

    ═══ WHY IT IS ITS OWN FILE ═══

    Because there are two ways off this server and they are built in different
    places: kick.lua composes the reason an admin typed, and gate.lua composes a
    ban notice with an expiry sentence in it. One shared function is what stops
    the two from drifting into two slightly different sentences -- which is the
    failure mode for anything a person writes twice.

    It also keeps the wording somewhere a search finds. The owner gave this
    sentence word for word, and a phrase given verbatim should live at a single
    grep-able address rather than inside a format string in the middle of a
    connect handler.

    ═══ APPENDED ONCE, BY THE COMPOSER, NEVER BY DropPlayer ═══

    `BR.Ring.dropByLicense` takes the exact text to show and does not touch it.
    That matters because the ban gate calls it too: a late "banned" answer for
    somebody already admitted removes them with the message the gate built, which
    has been through here already. Appending inside the drop would have given
    that one path the sentence twice, and only that path -- the kind of bug
    nobody sees until they read a screenshot from a player.

    ═══ UNSET IS A REAL STATE, AND IT IS THE DEFAULT ═══

    With no `br_discordUrl` set there is NO LINE AT ALL. Not an empty URL, not a
    dangling colon, not the word "unset": the player sees the reason they were
    removed and nothing after it, exactly as they did before this file existed.
    An appeal sentence pointing nowhere is worse than no sentence -- it sends
    somebody looking for a door that is not there, and it makes the server look
    broken at the one moment it is trying to be fair.

    The kick and the ban happen either way. Nothing here can refuse, delay or
    fail a removal; the worst it can do is return the text it was given.
]]

BR = BR or {}
BR.Ring = BR.Ring or {}

--- The invite this deployment publishes, or nil when it publishes none.
---
--- READ AT CALL TIME rather than cached at load. It costs one table lookup on a
--- path that runs a handful of times a day, and it means a `set br_discordUrl`
--- typed into a live console is picked up by the next kick rather than by the
--- next restart. Caching would also mean holding a value from before
--- config/overrides.lua had applied the convar, depending on load order -- which
--- is exactly the class of bug that file's own header is about.
---
--- THE '' CASE IS THE COMMON ONE, NOT AN ERROR. config/community.lua defaults
--- the key to an empty string, and GetConvar returns its default only when a
--- convar is UNSET -- so `set br_discordUrl ""` is set-to-empty and arrives
--- here as ''. Both spellings mean absent, the same collapse
--- br_ringmaster/server/config.lua makes for its own convars.
--- @return string|nil
local function discordUrl()
    local community = BR.Config and BR.Config.Community
    local url = community and community.discordUrl
    if type(url) ~= 'string' then return nil end
    url = url:gsub('^%s+', ''):gsub('%s+$', '')
    if url == '' then return nil end
    return url
end

--- The sentence, or nil when there is no address to put in it.
--- @return string|nil
function BR.Ring.appealLine()
    local url = discordUrl()
    if url == nil then return nil end
    return ('Please join our Discord to discuss or appeal: %s'):format(url)
end

--- `text` with the appeal line on the end of it, when there is one.
---
--- A BLANK LINE BETWEEN, because both messages this is used on already separate
--- their parts that way and both are rendered in a dialog that does not wrap
--- kindly. The reason a player was removed and the invitation to argue about it
--- are two different sentences to them; running them together reads as one long
--- explanation and buries the link.
--- @param text string|nil
--- @return string
function BR.Ring.withAppeal(text)
    text = type(text) == 'string' and text or ''

    local line = BR.Ring.appealLine()
    if line == nil then return text end
    if text == '' then return line end

    return ('%s\n\n%s'):format(text, line)
end

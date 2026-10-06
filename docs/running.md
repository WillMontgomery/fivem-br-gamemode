# Running and developing

Server setup, the UI build, the verification gate and the in-game diagnostics.

[← Back to the main README](../README.md)

---

See **[DEPLOY.md](../DEPLOY.md)** for the full walkthrough. In short:

```bash
git clone https://github.com/WillMontgomery/fivem-br-gamemode.git
cp server.cfg.example server.cfg
printf 'sv_hostname "My Server"\nsv_licenseKey "..."\n' > server-identity.cfg
```

`sv_hostname` and `sv_licenseKey` are **not** in `server.cfg` any more. They live
in `server-identity.cfg`, which `server.cfg` execs and which is gitignored. On
the Blitz Royale boxes that file is written at boot from SSM Parameter Store; see
the block above the exec in `server.cfg.example` for why.

Copy `resources/[fivem-royale]/` into your server's resources directory, or use
[`tools/deploy.sh`](../tools/deploy.sh) to pull and sync automatically.

**OneSync is required** (`set onesync on`). Without it the server cannot see
player entities at all — no positions, no storm damage, no validation — and the
failure is completely silent. The server warns loudly at boot if it is off.

**And it must be `on`, not `legacy`.** Those are two different engines, and the
boot warning above cannot tell you so: it fires on `off` and on an empty value
and passes `legacy` without a word. `on` is what FXServer's `IsBigMode()`
answers to, and `playerEnteredScope` — the event that tells this server a
downed body has just been cloned onto somebody's machine, so its position can
be corrected — is raised inside that guard. On `legacy` the event never fires,
`br_core/server/combat.lua`'s whole resync section is dead code, and a body
somebody streams in stands wherever it was when they last saw it. Nothing
errors. The `entered` counter in `/brdbno` is what reads zero when a box has
been moved to legacy, and it is the only place the difference shows.

A database is **optional**. Without one, `br_stats` disables itself and matches
run normally; you just get no persistent stats.

### Two convars a deployment has to answer for itself

Everything else in `br_lib/config/overrides.lua` overrides a reviewed default.
These two have no default to override — they are addresses that exist only per
deployment — and both are **unset by default, where unset means the feature is
simply absent**:

| convar | kind | unset means |
|---|---|---|
| `br_adminConsoleUrl` | `url` | No Admin tab in the pause menu, no HTTP call, and one line in the boot banner. The game never depends on Ringmaster, so a server with no console configured plays exactly as it did before the feature existed. |
| `br_discordUrl` | `link` | A kicked or banned player is told why and nothing more — **no line at all**, not an empty URL and not a bare "contact an admin" — and there is **no Discord card in the pause menu**. Set, it does both: the appeal line on the way out, and a card on the Help page every player can press to copy the invite. |

**They are parsed differently on purpose, and that is why there are two kinds.**
`br_adminConsoleUrl` is *compared* against a browser's `event.origin`, so it must
be bare and a trailing slash is fatal. `br_discordUrl` is *opened* by a person,
and a Discord invite is nothing without its path — `https://discord.gg/<code>` is
entirely code. Kind `url` would have refused the only value anybody will ever put
in it.

**`br_discordUrl` now reaches clients, and that is not a hole in the
server-only rule.** The rule `verify.sh`'s *tunable overrides* gate enforces is
that an overridable **key** is read on the server and nowhere else — it greps
every `br_*/client/*.lua` for the bare name `discordUrl` and fails on a match in
code or in a comment. That is untouched. What changed on 2026-08-30 is that
`br_core/server/community.lua` reads the resolved value on `br:ready`, on the
server, and sends it to that player's page under the wire name **`invite`** for
the pause-menu Discord card. Renaming it on the way out is the sanctioned exit
and the same one `consoleUrl` → `origin` already takes: the client half never
says the key, so there is still exactly one reader per Lua state and the two
sides cannot drift. `{}` is a real answer — an operator who clears the convar
and restarts `br_core` sends the empty table, and a page still up takes the card
down on the strength of it.

> **The card used to disappear once a player had copied it, and that was
> reversed on 2026-08-31** (`2cf704e`). The owner's earlier instruction was that
> a copy should hide it for the rest of the session, reasoning "they may join
> the discord at that moment and it's not worth us writing something to listen
> for that". That is what got answered: the card now shows to **every** player
> and is withheld only from one Discord itself confirms is already in the guild.
> The copy-hides-the-card flag is gone rather than joined. Every other line of
> the copy behaviour, "Copied" included, is untouched.

Both get what the overrides mechanism gives everything else: a strict parse, a
hard boot failure on a malformed value, a boot banner line and a `brconfig` line.
A **third** address arriving in that file is the signal to ask whether it is still
the tunables or has quietly become the deployment addresses as well.

### Two more convars, and they are deliberately not in that file

Hiding the Discord card from players who have already joined costs a question
only Discord can answer, and asking it costs a credential. Since 2026-08-31
`br_core/server/guild.lua` reads two convars **straight off `GetConvar`**,
outside the overrides mechanism entirely:

| convar | what it is | unset means |
|---|---|---|
| `br_discord_bot_token` | A Discord bot token — **a secret**. Never write the value into a document, a commit or a `.cfg` that is tracked; it lives on the host in `server.cfg` and nowhere else. | The lookup is never made. |
| `br_discord_guild_id` | The guild's snowflake id — digits only, 32 characters at most, because it is interpolated straight into the request path. Not a secret. | The lookup is never made. |

**Both, or neither.** A token with no guild id has nothing to ask about and a
guild id with no token cannot ask, so `BR.Guild.configured()` requires the pair
and there is no half-configured state. **With neither set the feature is
completely inert** — no HTTP call, no dependency, and the Discord card simply
shows to everybody, which is the shipped default and the state the card was
designed for.

**The token is not a config key precisely because config keys get printed.**
Everything in `br_lib/config/` is echoed by `main.lua`'s tunables block at boot,
read back by `brconfig`, and rendered into the admin UI by the console's
`configreport` verb. A credential in that directory would be a credential in
three logs. So the boot line prints the guild id and only the **length** of the
token — enough to diagnose a truncated paste without the value reaching anyone's
scrollback — and `verify.sh`'s *secrets* and *config report* gates both hold that
line.

**They are read once, at load.** A convar set after boot applies on the next
`restart br_core`, and the boot line will say so when it does. A guild id that is
set but is not digits is its own state and says so loudly — the operator believes
the feature is on — rather than being quietly treated as absent.

**Only a confirmed yes hides anything.** No token, no `discord:` identifier for
that player, a timeout, a 429, a guild the bot cannot see — every one of them
shows the card, because a card that hid itself whenever the lookup failed would
stop inviting exactly the people it is for, in the states nobody is watching.

### The season a box runs: `br_season`

Features are gated by the season a server runs (#388; owner, 2026-10-04: "This
is how we can run season 3 on dev and season 2 on prod with the same codebase").
`br_season` is a whole number from 1, set in `server.cfg` above `ensure br_core`:

```
set br_season 1
```

**Prod must set it.** A box that does not runs the **latest** season this code
knows (`latest` in `br_lib/config/seasons.lua`, Season 2 today) and prints a
warning banner at boot. That suits a dev box that should always run the newest
season, and it is exactly what a public box must not rely on: the first deploy
after a new season's first feature lands would switch that feature on there. A
value that is not a season (`two`, `0`, `1.5`) also runs the latest, with a
banner quoting what was set.

**It is read once, as `br_core` starts.** Every deploy restarts the server, so a
changed `server.cfg` applies on the next one; by hand it is `set br_season <n>`
then `restart br_core`. A value typed into a live console otherwise changes
nothing, and the console says so once. The boot banner's `season` line says
which season is running and why, and in dev mode the lobby shows it beside the
version under Settings, as `S2 · 1a2b3c4`.

Clients never read `br_season`. The server replicates the season it is running
as `br_seasonServed`, which nothing should set by hand. Until it reaches a
client, that client knows no season and every season gate there is shut; it
does not assume the latest, which is only the server's answer to an unset
`br_season`.

**Gating the next feature:**

1. Add a row to `br_lib/config/seasons.lua`: `myfeature = { from = 3 }` (and
   raise `latest` if Season 3 is new). `untilSeason = 4` would switch it off
   again from Season 4.
2. Put `if not BR.Season.has('myfeature') then return end` at every door,
   on the server for anything a player could cheat; the client asks the same
   question for what it shows.
3. For a version of a value or a function rather than on/off, use
   `BR.Season.pick({ [1] = old, [3] = new })` where it is used, never at file
   load.

`verify.sh`'s *season gates* fails an id with no row, a row nothing asks about, a
`from` past `latest`, and any file but `br_lib/shared/season.lua` that reads
`br_season`.

**On a dev box, `brseason` switches without a restart** (owner, 2026-10-04:
"That was my only real intended use case for faster-than-restart switching").
It is a dev command, so a box without dev mode refuses it and prod stays
restart-only; `br_season` itself is never touched, so the next `br_core` start
reads it as always.

- `brseason` — the season in force, where it came from, and any staged switch
- `brseason <n>` — switch to Season n (1 to `latest`)
- `brseason reset` — back to the season `br_core` started on

With no match running it applies at once. While any match is running —
warmup to cleanup — it is staged and applied when the last one is torn down to
the lobby, never mid-match; a second `brseason` replaces a staged one. Applying
moves the season the server's doors answer, replicates it, pushes every
player's market state again, restyles every crate still standing (the warmup
pad's, its four, every husk) for the new season and re-announces each once,
re-reads the festive sky (a Season 2 feature, #399) and sends it if it moved,
and prints who switched in the console and in every client's F8. Each client
holds its season and re-reads the replicated value the moment it lands, so the
lobby label, the Market's Emotes tab, the Settings key and Music slider, and
the crates on screen (a Season 2 box rebuilt as today's wooden crate, or back)
follow. One thing cannot: GTA has no way to withdraw a key mapping, so after a
switch away from Season 2 the emote wheel's row stays in GTA's own key-binding
list, and pressing it does nothing. Nor can licensed assets (below): a switch
whose season runs a different set warns and names the resources.

### Licensed assets: the private bucket and `assets.lock` (#391)

Bought packs (the NTeam Legion map pack, the #215 emote packs) may not be
redistributed, and this repo is public, so they are never committed. Each
version lives in the private bucket as
`s3://blitz-royale-assets/assets/<resource>/<sha256>.tar.gz`, and `assets.lock`
at the repo root pins which version each box runs. A commit bumps an asset,
`git revert` rolls it back; dev deploys run dev's lock, prod runs main's.

**Owner, on each box, once, in this order:**

1. If the ops clone predates the deploy handover, pull it once: `git -C /opt/misc/fivem-br-gamemode pull` (after that each deploy runs the deployed branch's own `deploy.sh`; see [DEPLOY.md](../DEPLOY.md#deploying))
2. Add one line to `server.cfg`: `exec resources/[licensed]/licensed.cfg` (where: below)
3. Deploy as usual; the packs land, and load at that deploy's restart

An ops clone too old to hand over prints a red box naming that pull; do it,
then deploy again.

**Owner, on the PC: the `Blitz Assets` folder on the Desktop.** Its
`README.txt` says all of this; in short:

- Add a pack: drag its folder (the one holding `fxmanifest.lua`) into the season it starts in, usually `Season 1`
- Change it for every season: replace the files in the folder it is in
- Change it from a later season on: put the new version in that season's folder, same name
- Remove it from a later season on: make an EMPTY folder with its name in that season (`Season 3\legion`)
- Remove it everywhere: delete its folder from every season folder
- Double-click `Publish.cmd`: it shows the plan, uploads what is new, and asks `Commit and push to dev? [y/N]`
- `y` commits only `assets.lock`, on top of dev, and pushes it; `n` leaves nothing behind but the uploads
- To make the folder again: `py tools/assets.py init-drop "%USERPROFILE%\Desktop\Blitz Assets"`

Publish never touches a checkout anyone works in. It keeps its own clone of
the repo in `%LOCALAPPDATA%\BlitzAssets\repo`: the first Publish on a PC clones
dev there (git and `py` are all it needs), and every Publish fetches dev, checks
it out and runs that `tools/assets.py`, so it is always dev's latest. It plans
against GitHub's dev, builds the one-file commit on top of it, checks the lock
once more and pushes it onto exactly the dev it planned on (a lease, so a dev
rewound meanwhile by a purge stays rewound); if dev moved or was rewound it
plans again, pushes without asking when the plan is the same, and asks again
when it is not. It says "pushed" only once GitHub's dev holds the commit.

It also guards against a copy still running. Publish refuses anything in a
season folder created or written in the last minute ("is it still copying?").
After the `y`, it reads every pack again and refuses if anything differs from
the plan it showed. Neither can see a copy that has stopped partway, for
example Explorer waiting at a "file in use" dialog, so let a copy finish first.

The folders are the lock: a pack in two season folders is one version per
season, a pack dragged back after being removed goes up with no upload, and an
empty folder with no earlier version is skipped as "nothing to remove". A folder
with files but no `fxmanifest.lua` (at any depth, `[category]` folders too), or
anything in a Season folder Publish cannot read, stops Publish before it uploads
or asks: "is it still copying? nothing was published". Skipped, it would drop
the pack it replaces out of the lock. Every pack's files are read and hashed on
every Publish; `.publish-index.json` only spares packing them again. A drop
folder inside a git work tree is refused. The pre-push hook
(`./tools/install-hooks.sh`) refuses any push carrying a game-asset file or a
credential.

**From a terminal** (profile `blitz-assets`), for the same thing by hand:

- Push packs: `py tools/assets.py push "D:/packs/legion" "D:/packs/[emotes]"` (a folder of packs, or a `[category]`, pushes each)
- For a later season: add `--season 2`
- Remove one from a season on: `py tools/assets.py retire legion --season 3`; from every season: `retire legion`
- Lock vs bucket: `py tools/assets.py status --profile blitz-assets`
- Then commit `assets.lock` to dev

**Where the server.cfg line goes:**

```
exec resources/[licensed]/licensed.cfg
```

after `ensure ScaleformUI_Lua` and above the `ensure br_lib` block, where
`server.cfg.example` carries it commented. Nothing found needs it before or
after `br_core`. Until a pull has run the file is absent and the server prints
`No such config file` once and carries on.

**At the next deploy** `deploy.sh` stages the pull from the fetched branch
before the code sync: it downloads what `.assets-cache/` lacks (kept, so a
revert reinstalls with no download), checks every sha256, and unpacks into the
cache, changing nothing installed. A failure there stops the deploy with code
and assets as they were. Once the code and vendored syncs have succeeded it
swaps the staged set into `resources/[licensed]/`, removes what the lock no
longer puts in force there, and writes `licensed.cfg`, just before the
served-commit stamp. The swap is journaled: a failure is undone and stops the
deploy before any restart, and a killed one is undone by the next pull. If an
undo fails too, nothing is deleted and the error names where each old resource
is. A ref from before #391 leaves `resources/[licensed]/` alone. A pull refuses
a pack whose name a resource elsewhere under `resources/` already has. The cache
drops an archive only when the lock no longer names it and it has been out of
use for 14 days. `--dry-run` and `--status` print the plan and change nothing.
An empty lock leaves the deploy exactly as it was.

**On a box, to look:**

- The plan: `python3 /opt/fivem-server-classic/.gamemode-src/tools/assets.py pull --dry-run`
- Lock vs bucket vs installed: `python3 /opt/fivem-server-classic/.gamemode-src/tools/assets.py status`

**Seasons.** A box installs, for its season, the pin at the newest season at or
below it, like `BR.Season.pick`. A pin is a version, or `null`: removed from that
season on, until a later pin brings a version back. Before its earliest pin a
pack is not installed. The season is the `br_season` br_core sees when it
starts, and FXServer reads the cfg twice to get there: an early pass runs every
line (past `ensure br_core`) and carries what `set`, `setr` or `seta` gave
`br_season` into the real pass, which then runs in order up to the line that
starts br_core: `ensure br_core`, or `ensure`/`start` of a `[category]` folder
it sits in on the box. So a `set br_season` below `ensure br_core` still counts,
and once the convar exists a bare `br_season 2` line assigns too; `sets`
anywhere keeps the early value from being carried. A line splits at `;` before
comments are known, so a `#` or `//` ends its command, not the line:
`# note; set br_season 2` runs the set. Unset means the latest. `brseason` on
dev cannot swap streamed assets: it warns, naming what differs, and the assets
follow when `br_season` in server.cfg changes and the box is redeployed and
restarted.

**Escrowed packs** (`.fxap`) are stored byte for byte like anything else. Running
them needs each box's license key from the Cfx.re account that bought them.

The lock holds names, checksums, sizes, file lists and season pins, and nothing
else (`assets.py check` refuses any other key, and any pin that changes nothing).
The file lists let a test check that an anim dict or model our code names is in
a pack without the pack. Here `legion` runs `9c1e…` in Seasons 1-2, nothing in
3-4, and `4b7d…` from Season 5:

```json
{
  "format": 2,
  "resources": [
    {
      "name": "legion",
      "seasons": {
        "1": "9c1e…",
        "3": null,
        "5": "4b7d…"
      },
      "versions": {
        "9c1e…": {
          "size": 48213377,
          "files": {
            "fxmanifest.lua": 412,
            "stream/legion.ymap": 90112
          }
        },
        "4b7d…": {
          "size": 50110021,
          "files": {
            "fxmanifest.lua": 412,
            "stream/legion.ymap": 93184
          }
        }
      }
    }
  ]
}
```

### Voice is pma-voice, and it is vendored and pinned

Voice runs on **[pma-voice](https://github.com/AvarianKnight/pma-voice)** (MIT,
© Dillon Skaggs), which owns proximity and the squad radio. `br_core` sets the
convars and the channels; it does not implement voice.

**There is nothing to install.** pma-voice is vendored into this repository at
`resources/[voice]/pma-voice` and `tools/deploy.sh` syncs it to
`resources/[voice]/pma-voice` on the box — the same path a hand-installed clone
used, so a deploy *replaces* that clone rather than adding a second resource
beside it.

> **Upgrading a box that predates the vendoring:** `rm -rf` the old
> `resources/[voice]/pma-voice` **once**, before the first deploy that carries
> the vendored copy. `rsync --delete` does not delete excluded paths, so the old
> clone's `.git` would otherwise survive and misreport the version.

- **The pin is `v7.0.2-rc3`, not `v7.0.0`,** and this is the one place in the
  setup where "the latest tag that is not a release candidate" is the wrong
  instinct. `v7.0.0` carries the proximity bug this server reports; `v7.0.1-rc2`
  onwards fixes it upstream, three ways. `server.cfg.example` argues the whole
  case at the `ensure` line and prints the upgrade command at runtime when it
  detects the old build.
- **The exact upstream commit is recorded** in
  `resources/[voice]/pma-voice/VENDOR.json`, along with a log of every local
  change. There are four such lines, each marked `BR-PATCH`: they remove an
  unconditional debug `print`, silence the mic-click chirp at source, and delete
  the two `RegisterKeyMapping` calls that put "Cycle Proximity" (F11) and "Talk
  over Radio" (Left Alt) in FiveM's key list outside our own key layer. The
  `+radiotalk` **command** is untouched — it is the squad transmit path.
- **`tools/verify.sh` enforces the vendoring**: LICENSE present, version
  recorded, patch log and source in agreement both ways, and `deploy.sh`
  actually syncing the resource.
- **A missing pma-voice announces itself** in the server console at start and on
  the first attempt to use voice, rather than failing silently.
- The convars are set from `server.cfg.example`, which is **documentation and is
  not deployed** — `br_core` re-states what it needs at runtime, so a server
  brought up without them still works.

`brvoice` in the client console reads back mode, channel and who this client can
hear; `brvoice` in the server console says whether pma-voice is even present.

---

## Development

```bash
./tools/verify.sh                    # Lua syntax, suites, and repository gates
cd ui-src && npm run dev             # UI in a browser, no game required
cd ui-src && npm run build           # typecheck, build, CSS/UI/envelope checks
cd ui-src && npm run build:terminal  # just the Season 2 terminal app (#396)
cd ui-src && npm run build:check     # rebuild, compare committed output, restore it
cd js-src/br_ddb && npm run check    # rebuild in memory and compare its bundle
```

`ui-src` builds two pages from one lockfile: br_ui's HUD into
`resources/[fivem-royale]/br_ui/ui`, and the Season 2 terminal app
(`ui-src/terminal`, React + Cloudscape, `vite.terminal.config.ts`) into the
vendored `resources/[computer]/cuchi_computer/nui/apps/terminal`. `npm run build`
writes both and `build:check` byte-compares both, each against its own committed
build stamp. The app has its own gate, `scripts/check-terminal.mjs`: the
Cloudscape-on-CEF-103 findings of #385, no words written in its JSX, every
line read through one speaker (the squad words), Run's risk colors on tokens
Cloudscape defines, and a browser chrome that takes no mode -- its pure
parts' tests, `scripts/test-terminal-model.mjs`, and the computer's desktop
(`cuchi_computer/nui/br.js`) driven in a node:vm page model,
`scripts/test-terminal-desktop.mjs`: a run's last word is shown in the app or
handed back for a toast, on every path.

CI runs both package installs and bundle checks under Node 22 before
`tools/verify.sh`. Pull requests and pushes to `main` receive the same checks;
the local pre-commit gate remains the first line of defence on `dev`.

`verify.sh` runs **37 gates**, in increasing order of strictness, exiting
non-zero on any failure:

| | |
|---|---|
| `syntax` | Lua 5.4 on every file |
| `tests` | over 10,000 assertions across 35 suites; the ordered inventory must name every `tools/test_*.lua` file |
| `scope gate` | OneSync scope-limited natives banned from client gameplay code |
| `weapon table` | every weapon hash re-derived from its name, and every slot weapon's icon present in both the source and the built bundle |
| `vehicle table` | every refused-vehicle hash re-derived from its name, signed and unsigned |
| `POI siting` | spacing, water, no-loot zones, distance to roads — and the 23 ambulance spawns held to the same rules |
| `map boundary` | the surveyed ring is simple and closed, and every POI and ambulance spawn is inside it |
| `spectator microphone` | a spectator is muted at both session-start sites and unmuted once on stop |
| `spectator HUD` | a spectator's HUD reads the watched player, sent to one watcher and deduped |
| `squad voice marks` | the squad panel marks voice from what the client is told; one bit crosses, the mode crosses nothing |
| `squad levels` | a teammate's level travels only to their own squad, and draws nothing until the server knows it |
| `squad revive keys` | a squadmate's key travels only to their own squad, and folds into the panel as a tri-state that keeps its false |
| `notice names` | a toast that names a player carries the name as its own piece and never formats it into a sentence |
| `key glyphs` | keys draw as keys, resolved by command name off the keybinds list, and a dash when unbound |
| `vitals bars` | health and shield name themselves inside the pill, and a zero shield draws no numeral |
| `death verdict` | the death word and the verdict screen are two surfaces on one word table, driven by one deadline |
| `forward locals` | a `local function` called above its own declaration |
| `player states` | every `PlayerState` reference names one of the nine that exist |
| `bool natives` | a `BOOL` native read as a bare Lua truth value — the known set, and nothing new |
| `config report` | the convar allowlist stays free of credentials, and still finds everything it names |
| `voice defaults` | voice modes are exclusive and the default agrees in Lua, TS and the bundle |
| `tunable overrides` | overridable keys are server-only; every manifest loads them in order |
| `manifest coverage` | every `.lua` is declared in an fxmanifest |
| `shared coverage` | everything dropped in `br_lib` is actually loaded |
| `deploy payload` | the deploy's own payload check still works |
| `vendored third-party` | license kept, version recorded, patch log matches the source, `deploy.sh` syncs it |
| `console capability boundary` | `dispatch.sh`'s SSH verb set, exactly — plus `brcar`, `brshots`, `brtestfire` and `brtime`/`brweather` staying console-only |
| `dev gate on console commands` | every console command goes through the one wrap, exempting only the three; the ungated door is player input only |
| `branch-switch invariant` | no path to a hard reset that skips the dispatch blob check |
| `incident surface` | only `BR.ShotSuspicious` can reach the Ringmaster |
| `incident notice surface` | one announcer of the report notice, one `br:incident:filed`, one incident writer; corroboration is none of them |
| `timeline entry kinds` | every match-timeline kind Lua writes is one `close.js` stores |
| `secrets` | scans the whole repo, not just `resources/` |
| `br_ddb bundle` | the committed bundle is the one recorded against the current `js-src/br_ddb` |
| `br_ddb bundle over the wire` | `status` reports the bundle actually deployed on a box, and every absence as null |
| `duplicate console commands` | one name, one registration |
| `American spelling` | the lines a branch adds since it left `origin/dev` spell color, license, armor and tire the American way; names the code keeps are skipped |

> **This table said 21 gates and "~3,900 assertions across 10 suites" on
> 2026-08-27, and 17 gates and "~3,100 across 8" before that.** None of the six
> numbers survived. Fifteen gates in the table above were not in the last one —
> nine covering the HUD, the squad panel and spectating, plus `vehicle table`,
> `map boundary`, `player states`, `bool natives`,
> `dev gate on console commands` and `br_ddb bundle over the wire` — and the
> suite count went from 10 to 28 as each new subsystem brought its own. A gate list
> that quietly runs short is the failure mode this table exists to prevent, so
> the count is stated as well as the rows: if they disagree, the table is the
> stale one. The authority is `verify.sh`'s own output, which names every gate as
> it runs.

The unit tests cover the pure logic and the server model: geometry, storm solver
and anchor picker, seeded RNG, loot layout generation, loop registry, roster,
match flow, bus routes, storm engine, loot streaming and claims, the inventory
model, parties, the XP curve, the Ringmaster surface, and the client interaction
layer. See **[testing.md](testing.md)** for what each suite is for.

Every regression test must be **proven load-bearing**: revert the fix, confirm
the test fails, restore it. A test that passes either way is rewritten. Anything
that has to reach clients is asserted **on the wire** (the captured
`TriggerClientEvent` stream), not on the server's own tables — a bug that
passed every server-side assertion and still shipped is what set that rule.

Install the pre-commit and pre-push hooks with `./tools/install-hooks.sh`.

### In-game diagnostics

**Everything in this table needs dev mode** (`br_devMode true` or `sv_devMode
true`), client commands included, since 2026-08-31 — owner: "Yes I want all
client and server commands gated behind devmode". The two exceptions in the
table itself are `brring`, exempt for the reason below, and `/brleave`, which is
a player verb rather than a diagnostic and is registered through the ungated
door. The gate is one wrap around `RegisterCommand` in
`br_lib/shared/devgate.lua` rather than a check inside each verb, so a command
added later is gated without anybody remembering to do it. Typing one on the
public box prints which gate closed rather than doing nothing.

**The client had no dev mode at all before this**, which is half the commands:
`sv_devMode` and `br_devMode` are read on the server and neither is replicated,
so a client's `GetConvar` saw neither. `server/main.lua` now replicates the
**resolved** answer under `br_devMode`, so a box started with only `sv_devMode`
still has working client dev tools and both sides of the wire read one truth.
The gate reads it at call time rather than at registration, because a replicated
convar has not necessarily arrived when a client's scripts load.

**And it fails open**, which is the wrong direction for a security gate and the
right one here. If `devgate.lua` falls out of a manifest, `RegisterCommand` is
the untouched native and that resource's commands register ungated. A gate that
can take `brkick` off the public box by failing to load is worse than one that
can leave `brshop` on it.

**Four commands are exempt from this gate**: `brkick`
and `brspectate`, which the admin console types into this console over tmux and
which are therefore its Kick and Spectate buttons, and `brring`, which is how an
operator finds out on the live box that the Ringmaster link is dead (see the
IAM-policy note in [security.md](security.md)), and `bremotegrant`, whose gate is
the season instead (#388): it works on any box running a season that has
emotes — Season 2 and later — and is shut on a Season 1 box. `bridents` is *not* exempt —
nothing invokes it and it prints licenses and Discord ids for every connected
player. The keybind commands are not in this table and are not gated: FiveM
builds keybinds out of commands, so `+brinteract` and `brslot3` are also E and
3. `/brleave` is a player verb and is not gated either.

| Command | Where | What |
|---|---|---|
| `brnativecheck` | client | Verify every native assumption against the running build. Its timecycle probe reads the slot first and puts it back after (a vMenu TM or the storm's red survives it), and prints `GetTimecycleModifierIndex  REDMIST=<n>, after clear=-1`, the assumption the storm's grade rests on (#399) |
| `brtc`, `brtc <name> [strength]`, `brtc clear` | client, dev mode | The timecycle slot (#399). Bare, it prints what is on screen: the primary slot's index, name and strength, the extra slot's index, and whether the storm's red grade owns the primary slot (and what it will put back when it leaves). With a name it sets that modifier at `strength` (default 1.0); `clear` empties the slot. The storm's grade shares this slot with vMenu's TM menu and touches only what it set: a modifier already there when the red arrives is put back when it leaves, one set over the red is the dev's and is left alone, and a clear while the red is up brings the red straight back. `brfx stop` stops post effects only |
| `brprobe` | client | What the natives actually *do*, not what they are named. Sub-modes for ammo, vehicles, armour, crates; `brprobe raw` suspends our own writes so the engine can be watched alone |
| `brdriveby [seconds]` | client | Why a passenger cannot fire. Samples across frames from the seat: which seat, what the *engine* has in your hands versus what we granted, whether anything disabled a trigger control, and whether we ever asserted the drive-by permission. Also prints our own claim about which weapons a seat accepts next to what the engine actually did with yours, which is the only check there is on that table ([vehicle-data.md](vehicle-data.md)). Exists because those causes are indistinguishable from inside the car and each wants a different fix |
| `brboostwhy [seconds]` | client | Why the boost does nothing (#203). Walks the whole chain in one window and names the rung that fails: the three virtual-key codes shift can arrive as, counted side by side against the one the binding is actually watching; GTA's own controls on the same key, so "the game sees it and we do not" is visible; the seat and class gates; whether the loop decided to spend; whether `APPLY_FORCE_TO_ENTITY` was accepted or refused, with its error; and the speed the car actually gained against the +30 mph the spec asks for. A full meter is the symptom of all four faults at once, which is why counting is the only way to tell them apart. Also sweeps all 360 control ids on the frames the key is held and names anything answering to it that the (2020-vintage) hardcoded four do not cover, and reports the car's peak **lateral** speed while boosting — which is what a drift is, and the one measurement that can convict or clear the impulse itself |
| `brboostinfo` | client | The boost meter, the running boost and the ramp, in one snapshot. Says how many force calls the engine has accepted this session and what it said when it refused |
| `brdrivers` | client | Why the ambient drivers are calm. The mad-driver pass (`client/gamerules.lua`) re-tasks ambient drivers within `erraticRange`, and "they feel calm" has four causes that look identical through a windscreen: the feature switched off, the pass gated out by player state, the pass running and finding nothing in range, or finding drivers and having the re-task refused. Prints which, plus **what the pass anchored on** — a spectator's ped is a corpse where they fell while the shot is somewhere else entirely, which is exactly how every driver on screen went calm (owner, 2026-08-22). Also prints `IsPedAPlayer`'s raw return and type, because in Lua `0` is truthy and that test is a bare `not` |
| `brclock` | client | The time of day (#394). The lobby and the warmup pad hold still at 12:00; from bus start the clock runs from the match's anchor at `BR.Config.World.msPerGameMinute`. Prints the mode (hold, run or wait) and why, how the clock is kept (`writer`), the anchor, the expected time against what the engine reports, the drift, the engine's own ms-per-minute, and how many times the clock was written and had to be corrected. Healthy: writer ONCE, one write per state change and 0 corrections. Writer EVERY FRAME means the engine did not keep the rate (it read back wrong, or the drift guard fired 3 times inside a minute), so for the rest of the session the time is written every frame with the clock paused; the line says which and since when. Reads only; it never moves the clock |
| `brblack` | client | Every state that can cause a black screen, at once |
| `brfocus` | client | The NUI focus stack — why you do or don't have a cursor |
| `brbus`, `brdropdbg` | client | Bus ride and skydive state, live |
| `brloot` | client | What this client can see: entries, live props, nearest item |
| `brarc` | client | Whether loot actually arcs out of a container. Drops one item with a known origin and reports, link by link, how far it got — origin received, prop built, arc armed, frames flown — plus the same tally for real crates opened in play |
| `brbox ship <1-5> [festive\|plain]`, `brbox gift <white\|blue\|green\|red>` | client, dev mode | A Season 2 test crate (#395) two meters ahead: a shipping box of any tier, festive or plain, or a gift box. Server-owned like real loot, with real contents at that tier, so each prop, its clip and the burst can be tried the moment the props land. Needs `crates2` (Season 2; `brseason 2` first on a Season 1 box) and the server's dev trust, as `brcrate`. Prints which models this client will draw for it and whether its build has them; the server's report goes to the server console, not a toast |
| `brboxprompt`, `brboxprompt ship\|gift x=<m> y=<m> z=<m> rx=<deg> ry=<deg> rz=<deg> size=<m>` | client, dev mode | Move the hold prompt on a Season 2 box live (#395): one row for every shipping box (festive included), one for the gift box, in meters and degrees in the box's own frame (x right, y forward, z up). It moves on the next frame; the command prints the line to paste into the `prompt` table in `br_lib/config/crates.lua`. Not persisted. Bare, it prints both rows |
| `brboxcheck` | client, dev mode | Every configured Season 2 box against this build (#395), one line per row: the sealed and open models (in the CD image and valid), the clipset (exists and streams), and `GetAnimDuration` beside the configured `clipMs` — the number the **server** times the burst with — with the value to set on a mismatch. Also the props' resource (the server opens every crate at once until it runs) and the `crates2` gate |
| `brvoice` | both | Proximity voice state — mode, channel, who this client hears. The server's first line says whether pma-voice is even installed |
| `brdbno` | both | The downed/revive interaction, counted as it happens: asks, stops, refusals with their reason, progress ticks, and frames where a live hold found no body. Exists because "I hold the button, the ring fills, nothing happens" describes three different faults that look identical on screen. On the client, `brdbno settle august|new|old` (default august), `brdbno args old|new` (default old) and `brdbno keeper on|off` (default off) flip the #390 A/B arms (each from the next knock), and the readout prints which arms are set |
| `brcrawl` | client | The crawl: which clip the build actually resolved, and whether this client is emitting anything network-visible while lying still |
| `brpromptcheck` | client | Which prompt glyph actually renders for a custom keybind |
| `/brleave` | client | Leave the current match (counts as an elimination) |
| `bremote`, `bremote <dict> <clip> [flag]`, `bremote stop`, `bremote check` | client, dev only | The emote audition tool (#215). Bare, it prints the wheel's 8 slots and the catalogue; with a dict and clip it plays that animation locally (no record, no music, same cancels), refusing flags 16, 32 and 1024; `check` probes every dance's clip and track. Dev-only even in a season that has emotes, because it plays any animation on a ped other players see |
| `brprop spawn <model> [pickup\|static]`, `brprop list`, `brprop delete <id\|all>`, `brprop display <id> <pickup\|static>`, `brprop where <id>`, `brprop edit [id]`, `brprop save`, `brprop load` | client, dev mode | Dev props (#384): spawn a model by name in front of you, shown as a pickup (hovers, bobs and spins when you are near, like loot) or static, and move or turn it by hand — W/S, A/D, Q/Z move; J/L, I/K, U/O turn; Ctrl for coarse steps (10 cm / 15 deg, fine is 1 cm / 1 deg); F to the ground, C clears the rotation, Enter confirms, X cancels. `where` prints a paste-ready Lua line; `save` and `load` use `br_core/devprops.json`, which deploys keep and git ignores. Dev mode and nothing else — no grant. Every request runs on the server as `brpropsv`, which `brprop` types for you; `list` and `where` read this client's copies and show any model it failed to draw |
| `brpropsv <verb> ...` | server, dev mode | The server half of `brprop`, which runs it for you with `ExecuteCommand`; registered unrestricted, so dev mode is its only gate. Typed on the server console, `brpropsv delete`, `display`, `save` and `load` work as written; `edit` needs a player |
| `brterminal [nokey] [used] [offline]`, `brterminal close` | client, dev mode | Opens the Season 2 terminal computer (#396) anywhere, on a dev terminal whose facts are those words — a Yubikey and nothing against it by default; `nokey`, `used` (the squad has used its one) and `offline` (outside the storm) each make Storm reveal unavailable with that reason. Run it from the app to walk the whole round trip; Escape or the taskbar power button closes it. Season 2 only. Runs on the server as `brterminalsv`. See [the terminals' contract](terminals.md) |
| `brterminalsv open [words]`, `brterminalsv close` | server, dev mode | The server half of `brterminal`, which runs it for you; registered unrestricted, so dev mode is its only gate. From the server console it takes a player id first: `brterminalsv open 3 nokey` |
| `brperf [reset\|stop]` | both | Per-subsystem calls, errors and suspension. Client `reset` clears the window and arms per-callback stall capture; `stop` removes its timer overhead while the always-on frame histogram continues. Use `brbench`/`brab` for ordinary sub-frame cost |
| `brstormhitch [reset [ms]\|stop\|rows]` | client | `reset`, play a hold and a sweep, then `/brstormhitch`: a plain summary — what the storm map sent while the storm moved (the old zone's fade writes, and any clips added or removed for a picture drawn mid-sweep), the worst frame and how many frames went over 16.7 ms, and a one-line verdict. `rows` adds the detail: which storm/map/network/UI paths ran before each long frame. Opt-in and dormant outside a capture |
| `brstormbisect <normal\|mapoff\|mapfreeze\|walloff> [ms]` | client | Runtime A/B for #350 and #344. Each mode starts a fresh hitch capture while changing only local rendering: remove the custom map fill, keep it resident but send it nothing (no fade, no redraw), or suppress the shaped 3D wall. `normal` restores shipping behavior |
| `brconfig` | server | The config values that most often explain odd behaviour |
| `brseason`, `brseason <n>`, `brseason reset` | server, dev mode | Switch the season this box runs without restarting `br_core` (#388); see *The season a box runs*. At once with no match running, otherwise staged until the last match is torn down to the lobby. Bare, it prints the season in force, where it came from (`br_season`, the latest by default, or a `brseason` override) and any staged switch. Dev mode plus restricted |
| `brfestive [on\|off\|auto]` | server, dev mode | Force the festive months on or off for testing, or hand them back to the server's date — December and January — for the Season 2 festive crates (#395) **and the festive sky** (#399), which ask one calendar. Bare, it prints the answer, where it came from and what the date says. **The sky moves at once, for everyone**: on Season 2 and later the clear sky is XMAS with snow on the ground everywhere -- the lobby island, warmup and the match, after a storm exit too -- the bus keeps its overcast cover for the island swap (no snow on the ground under it, as under the storm's thunder: the ground is white exactly while the sky is a snow weather), and every client blends to it over `BR.Config.World.festiveBlendSec` (10 s). On Season 1 the sky never turns festive, and it says so. The crates apply to crates laid out from then on: the next match's layout (at its warmup), warmup-pad crates as they are stocked, and `brbox` crates; a match already laid out keeps the answer it started with. Dev mode plus restricted |
| `bremotegrant`, `bremotegrant <player name\|#id> <emoteId\|all>` | server console only | Hand a player one dance, or every dance they do not own, without charging Volts (#215). Bare, it lists the catalogue. Takes an **exact** name (case-insensitive, spaces allowed) or `#serverId`; a partial name only lists candidates, because there is no revoke. `all` grants one at a time and stops if the id changes hands. Exempt from the dev gate and gated by the season instead (emotes are Season 2+, #388): it prints the season and does nothing while emotes are off |
| `brring` | server | Ringmaster link: whether it is configured, and what it would send |
| `brallowlist [on\|off]` | server | The dev-mode join allowlist: `off` stops enforcing it (bans still apply, so with br_ringmaster down every dev-mode join is still refused) until `on` or the next start of br_core, bare prints which and whether the Discord lookup is configured. Restricted |
| `brddb` | server | Probe DynamoDB — reachability, credentials, table access |
| `brwhy <id>` | server | Why a given player is in the state they're in |
| `brshots [n\|reason]` | server console only | The last N shot adjudications with the arithmetic that decided each one: the measured distance beside the weapon's reach, this shot's interval beside its cadence floor, the magazine the **server** believed, and whether it watched a throw. The starred pair is the comparison that refused the row. Console-only rather than restricted, and that is #93 rather than caution: nobody is exempt from incidents, so an admin can be the *subject* of these rows, and a `br.admin` readout would hand that person the exact bound to stay under |
| `brtestfire <mode>` | server console only, dev mode | Bend one anticheat bound so a refusal can be fired deliberately from a real shot — `far` (range becomes 2% of the weapon's), `fast` (cadence floor becomes 60×), `thrown` (throw credit expires at once), `noammo <id>` (empty that player's magazine and pool in the server's model only), `off`, `status`. It never edits `BR.Config.Combat`; it swaps in a copy, so `off` restores exactly. Refusals it causes file **no** incident and are stamped `FORCED`. Announced by a banner, then a heartbeat every 15s while armed, and cleared at match teardown and on resource stop |
| `brtime <hour> [min]`, `brtime <hh:mm>`, `brtime reset` | server console only, dev mode | Move the clock for the whole session, and hold it still there until `reset` (#394). The world clock otherwise holds at 12:00 in the lobby and on the warmup pad and runs from each match's bus-start anchor, so this overrides both for every client — and the override is re-sent to a single client on `br:ready`, so a late joiner arrives into the same world rather than into noon. `reset` hands the clock back to the state's own clock (12:00, or the match's running time), and the empty override is sent rather than silence, so a client reconnecting after one is told the override is gone. **It is a gameplay change, not a screenshot change**, which is why it is dev-mode rather than merely console-only: GTA's ambient population is time-gated, several hospital ambulance spawns only fire in the evening and at night, and moving the clock changes what `BR.Rescue`'s discovery ledger can find and therefore where a squad can spend a revive key |
| `brweather <name>`, `brweather`, `brweather reset` | server console only, dev mode | The same for the sky, over the same 15 names (`BR.World.WEATHERS`, `EXTRASUNNY` through `HALLOWEEN`). Bare, it prints the list. While a sky is set it **outranks** the storm's thunder and the island's overcast rather than fighting them; `reset` hands the sky back to both. The four snow names (XMAS, SNOWLIGHT, SNOW, BLIZZARD) also turn on the ground snow pass, with tire and footprint tracks (#399); any other name turns it off. Neither verb is server state — the clock is overridden per client and the weather is written per client — so what the server owns is the one small override record, sent whole |
| `brscatter` | server | Spread everyone 3 km apart to test OneSync scoping |
| `brforce <state>`, `brskip`, `brkill <id>` | server | Drive the match by hand |
| `brloot [matchId]` | server | World loot: counts by kind and rarity, cells, who is subscribed. The id is the seven hex characters the console prints, and is read as hex (a shorter tag printed before 2026-09-12 still resolves) |
| `brinv <id>`, `brgive <id> <item> [n]` | server | Read or fill a player's inventory |
| `brphase <n>` | server | Jump the storm to phase n, seamlessly from the live circle |
| `brstormscale <0.05–1>` | server | Compress storm pacing for testing (0.1 ≈ a 2-minute cycle) |
| `brdown <id>`, `brdown <id> shot <shooterId>`, `brrevive <id> [by]`, `brbleed <id> [damage]` | server | Knock, pick up, or take damage off a downed player's clock as an enemy shot would. `brdown` refuses and says why when the rules say it should — solo, or no standing squadmate. `brdown <id> shot <shooterId>` knocks through `BR.Damage.applyHit`, the function every validated hit goes through, so the victim gets the same HIT_DAMAGE, DBNO_SET and HEALTH_SYNC a bullet sends and the shooter gets the same DAMAGE_FEED; only the engine's own damage on the shooter's machine is missing (#390). `brrevive` also puts an **eliminated** player back in: their placement, death stamp, storm stamp, killer record, revive key and spectate camera are all undone, they come back on full health where the body was, and the console names the three things that cannot be undone — the kill feed already broadcast, the killer's kill, and the kit the death box scattered. It refuses a match that is over, one the deciding death has already sealed, and one with nobody left standing |
| `brartifacts` | server | Incident screenshots: whether `screenshot-basic` is even running, cases open, frames claimed / asked for / stored / lost, and the refusals told apart from the losses — at the cap of nine, inside the first ten seconds, or for a case this process did not file. The only window onto this feature from the box, because nothing about a capture is visible in the game. Restricted |
| `brstrips` | server | The unissued-weapon detector: reports received and counted, throttled, and refused because the weapon turned out to be in the player's own server-side inventory. That last counter is what the command exists for — it is the one false positive this feature can produce, and on a healthy server it is zero. Restricted |
| `bradmin` | server | Why a given player has no Admin tab. The tab is binary and its preconditions are not, so this names which of six reasons applies to each connected player — convar unset, no license, grant row without the scope, no answer from DynamoDB yet, no `discord:` identifier, or an answer this process already settled. Restricted, because it names who holds admin scope |
| `brwarmupfreeze [off]` | server | Hold the warmup pad open indefinitely; the next match inherits the hold. Dev mode plus restricted, modelled on `brstormfreeze` down to `off` as the way back. Implemented as a deadline a day out rather than a flag, because clients count down by subtracting it and an infinity poisons every one of those subtractions. It does **not** lift itself at match end, unlike the storm freeze — a held warmup never reaches the end of a match to hang a release on, and a dissolve fires exactly when a tester stepped into the lobby for a moment. It **does** lift once the server is empty (#202): the hold survives matches, not the session, so a lobby rebuilt from nobody does not inherit a debug switch from the last one. `brstate` prints a line while it is on, and the transition log says `HELD` rather than the departure time it is not going to keep |
| `brstormfreeze [off]` | server | The same for the storm wall. Dev mode plus restricted; drops at the end of the match it was holding, because a next round with no storm never ends |
| `brcar <id> [model] [type]` | server | Put a vehicle in front of a player, since `sv_entityLockdown relaxed` refuses trainers — the platform validates a client's clone-create before `entityCreating` is raised, so vMenu's car is deleted without our detector ever seeing it. Uses server-side `CreateVehicleServerSetter`, which builds the entity on the server: it needs nobody in scope, it returns a handle that can actually be routed into the target's bucket, and the lockdown mode does not reach it. (It replaced server-side `CreateVehicle` in #212 — that one is an RPC returning a handle the server cannot resolve yet, so `SetEntityRoutingBucket` on it threw and the verb died one line after making the car. That is what "brcar does nothing" was.) `type` is the sync tree — automobile (default), bike, boat, heli, plane, submarine, trailer, train — and the platform does **not** check it against the model, so name the one the model actually is. **Server console only** — the `br.admin` ACE is deliberately not enough — plus dev mode. It spawns **only models `config/vehicles.lua` tolerates**, and that pre-check is now the whole boundary: the server setter raises `serverEntityCreated` and **not** `entityCreating`, so the refused-vehicle detector never sees what this verb makes. Nothing deletes it at match end; the platform collects it once nobody has it in scope, and the fuel ledger admits it the moment somebody in a match sits in it |
| `brawards` | server | The report-reward pipeline: claimed, swept, paid, already paid, settled, expired — then forces a sweep. Restricted, because it names licenses |
| `brxpsim <id> [xp]` | server | Drive a real XP award and level-up at a lobby player without playing a match. Server console only; Volts report as 0 on purpose, because claiming a payout nothing paid is the bug this exists to avoid |
| `brlootsim [crates] [tier] [seed]` | server | Roll the loot tables offline and print the distribution. Reads nothing about any player, changes nothing, spawns nothing |
| `brstate`, `brroster`, `brstorm`, `brqueue`, `brparty` | server | State dumps |

Separately, the console's SSH channel carries a read-only `configreport` verb
that renders a config surface into the admin UI. It reads an explicit allowlist
of convar names rather than the whole of `server.cfg`, because `server.cfg` is
where `sv_licenseKey` lives. That verb set — `status`, `telemetry`,
`configreport`, `kick`, `deploy`, `branches`, `switchref`, and nothing else — is
pinned by the *console capability boundary* gate in `verify.sh`; a new verb is a
new capability from the console to the host, and adding one means updating that
gate on purpose.

---

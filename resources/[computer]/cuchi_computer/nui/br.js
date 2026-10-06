// BR (fivem-royale, #396): THE BRIDGE BETWEEN client/shell.lua AND UPSTREAM'S
// DESKTOP. Not upstream code -- an added file, listed under `added` in
// ../VENDOR.json. Loaded after scripts/script.js, whose window manager (Load,
// OpenApp, CloseApp, MinimizeApp and the `apps` / `openedApps` lists) it calls
// exactly as upstream's own message handler did.
//
// The whole contract, with br_core's half, is docs/terminals.md. This file's
// share of it:
//
//   Lua -> page (SendNUIMessage from client/shell.lua)
//     { type: "br:open", state, copy, catalog, desktop }
//                                        boot the desktop (or, already up,
//                                        refresh it); the player opens the app
//                                        from its icon. desktop = { bootMinMs,
//                                        bootMaxMs, clock = { h, m } }
//     { type: "br:update", state }       the server's new view of this terminal
//                                        (once a second while open: the match
//                                        panel is in it)
//     { type: "br:result", result }      the server's answer to a run
//     { type: "br:clock", h, m }         the game's time, on each new minute
//     { type: "br:close" }               br_core closed it (no answer is sent)
//     { type: "br:close", storm: true }  THE STORM took the terminal in use
//                                        (round 4): a blue screen, a CRT
//                                        power-off, then closed -- and `off`
//                                        is said when the screen is dark
//
//   page -> Lua (NUI callbacks registered by client/shell.lua)
//     run    { functionId, options? }    the app asked; the server decides
//     close  { why }                     Escape, or the taskbar's power button
//     missed { toast }                   a run's last word the app never showed
//                                        (below): its toast, for br_core to
//                                        toast instead
//     off    {}                          the storm's close has played and the
//                                        screen is dark: the shell gives the
//                                        keyboard back
//
//   page <-> app (postMessage with the iframe; every message carries
//   brTerminal: 1, and each side only listens to the other's window)
//     app -> page  { type: "ready" }               send me everything
//                  { type: "run", functionId, options? }
//                                                  the player pressed Run
//                  { type: "escape" }              Escape, or Sign out, in the app
//                  { type: "loading", on, ms? }    a page load started (for ms)
//                                                  or ended: the tab's icon
//     page -> app  { type: "state", state, copy, catalog }
//                                                  render this (copy and catalog
//                                                  only on ready; an update is
//                                                  the state alone)
//                  { type: "result", result }      the answer to a run
//
// ═══ ROUND 2 (owner, 2026-10-05) ═══
//
//   * "the starting up animation should take longer - random between 7 and 10
//     seconds": every boot is a new uniform pick in br_core's range.
//   * "When accessing the computer, please don't make the app open
//     automatically": the boot ends on the desktop, and the player opens the
//     app from its icon -- which is when the app is loaded at all.
//   * "dark/light mode should not influence the browser's appearance, only the
//     website": the app no longer tells the desktop its mode, and the window's
//     frame (br.css) has one look.
//   * "the ability to resize (when grabbing the edges) and maximize the
//     window": eight handles and a maximize button, below.
//   * "make the computer clock match the game clock": the taskbar shows the
//     game's hour and minute, and no date.
//
// ═══ ROUND 3 (owner, 2026-10-06) ═══
//
//   * "the tab icon should change to a loading symbol to indicate it's
//     loading": while the app's browser loads a page (1-3 s, the app's own
//     timing), its window's tab -- this page's, outside the app's frame --
//     wears br.css's loading symbol in place of the app's icon. THE SYMBOL
//     ANIMATES ONLY WHILE A LOAD IS UNDER WAY (#385: a running animation
//     repaints the NUI every frame): its class goes, and with it the
//     animation, when the app says the page showed, when the app or the
//     computer goes away, when a fresh app says it is ready, and at the
//     latest TAB_LOAD_SLACK_MS after the load was due to end -- so nothing
//     here can spin forever, whatever the app does.
//
// ═══ ROUND 4 (owner, 2026-10-06) ═══
//
//   * "If they're using it while the storm moves and they're now outside the
//     storm, the computer should show a BSOD quickly followed by a CRT-style
//     visual power off." br_core's close for the storm (and only that close)
//     arrives with `storm: true`: the computer shuts at once -- the app
//     unloaded, nothing more run, updated or shown -- but its SCREEN stays:
//     a Windows-style blue screen in the copy block's words (bsod_*) for
//     BSOD_MS, then the picture collapses to a bright line, a dot, and black
//     over CRT_MS (br.css's .br-crt, the animation's only run), then the
//     screen is gone and the shell is told (`off`), which gives the keyboard
//     back. THE SCREEN AND ITS ANIMATION ARE REMOVED from the page when it
//     ends (#385), and an opening that arrives first drops them at once.
//
// NOTHING HERE DECIDES ANYTHING. A run is forwarded only while the desktop is
// open and only with a well-formed id, and that is shape-checking, not
// permission: the server checks the terminal, the key and the squad.
(() => {
    "use strict";

    // ONE LOCALE. locales/main.js reads the locale out of localStorage, and on
    // a FiveM client that storage belongs to the resource NAME on the player's
    // machine, not to this server: a player who chose French in cuchi_computer
    // anywhere else would arrive with a locale this copy no longer ships, and
    // the clock's GetLocale would throw. Pinned before the DOMContentLoaded
    // handler in script.js runs.
    Locale = "EN";

    const RES = typeof GetParentResourceName === "function"
        ? GetParentResourceName()
        : "cuchi_computer";
    const APP = "terminal";
    const APP_URL = "apps/terminal/index.html";
    // A boot whose range did not arrive (or was not one) takes upstream's
    // quarter second, as every boot did before round 2.
    const BOOT_FALLBACK_MS = 250;
    // The shape of a function id in br_lib/config/terminals.lua, and of an
    // option's id and its choice.
    const FUNCTION_ID = /^[a-z][a-z0-9_]{0,31}$/;
    const CHOICE = /^[a-z0-9_]{1,32}$/;
    const OPTIONS_MAX = 8;
    // THE SMALLEST THE WINDOW GOES. The app's side navigation (240 px) beside
    // a column of cards, the top bar's search with the balance, the light/dark
    // switch and the gamertag in one row, and a card's page with its Run
    // button still on screen.
    const MIN_W = 900;
    const MIN_H = 560;
    // THE TAB'S LOADING SYMBOL: a load's own length plus this, at the most,
    // and never longer than TAB_LOAD_MAX_MS whatever length the app sent.
    const TAB_LOAD_SLACK_MS = 1000;
    const TAB_LOAD_MAX_MS = 15000;
    const TAB_LOADING = "br-loading";
    // THE STORM'S CLOSE (round 4): the blue screen's time, then the CRT
    // power-off's -- br.css's br-crt-off runs for exactly CRT_MS. The shell
    // gives the keyboard back when it hears `off`, and by itself at 4 s.
    const BSOD_MS = 1500;
    const CRT_MS = 600;
    const CRT_CLASS = "br-crt";

    let isOpen = false;
    // Bumped by every open and close, so a boot timer that outlives the close
    // it raced does not put the desktop back up -- and never fires into a
    // later session.
    let session = 0;
    let state = null;
    let copy = {};
    let catalog = {};
    // A RUN'S LAST WORD NEVER GOES NOWHERE (review of round 2). One that
    // arrives while the app cannot take it -- its window closed, or opened
    // from the icon and still loading -- is HELD, and handed over after the
    // state when the app says it is ready. One the app took while its window
    // was minimized is UNSEEN until the window is shown again. If the computer
    // closes first (Escape, the power button, or br_core closing it), either
    // is handed back to client/shell.lua (`missed`), and br_core toasts the
    // server's own text for it -- the toast every last word carries. One that
    // reaches a desktop already closed goes the same way. A `running` answer
    // is not a last word: the state carries the run.
    let held = null;
    let unseen = null;
    // Has the app in the frame said it is ready (its message listener is up)?
    // Not "is its page set": an app still loading after its icon was clicked
    // has no listener, and a message posted to it is lost.
    let appReady = false;
    // The window's size and place before it was maximized, or null.
    let restoreRect = null;
    // The timer that takes the tab's loading symbol down if the app never
    // does, or null.
    let tabTimer = null;
    // The storm's close on screen: { el, timer }, or null.
    let blue = null;

    const post = (name, body) => fetch(`https://${RES}/${name}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(body || {}),
    }).catch(() => {});

    const frame = () => document.getElementById("terminal-frame");
    const win = () => document.getElementById("app-" + APP);
    const desk = () => document.getElementById("desktop");

    // A line of br_core's copy, or nothing. Never a key name and never a
    // default of our own: every word on this desktop is the owner's.
    const line = (key) => (typeof copy[key] === "string" ? copy[key] : "");

    // Is the app loaded in its window right now?
    const appLoaded = () => {
        const f = frame();
        return !!f && f.getAttribute("src") === APP_URL;
    };

    // Only to an app that has said it is ready; what it missed before then,
    // its 'ready' is answered with (the state, and a held last word).
    const toApp = (msg) => {
        const f = frame();
        if (f && f.contentWindow && appReady && appLoaded()) {
            f.contentWindow.postMessage(Object.assign({ brTerminal: 1 }, msg), "*");
        }
    };

    // A last word the app will not show, handed back for br_core to toast.
    const miss = (r) => {
        if (r && typeof r.toast === "string" && r.toast !== "") post("missed", { toast: r.toast });
    };

    // Held for the app; a second last word while one is held (the app is
    // away, so it cannot have asked for another -- but never dropped) hands
    // the first back rather than lose it.
    const hold = (r) => {
        if (held) miss(held);
        held = r;
    };

    // Is the app's window on screen: open, and not minimized?
    const winShown = () => {
        const w = win();
        return !!w && w.style.display !== "none" && w.style.visibility !== "hidden";
    };

    // A run's answer to the app, which is ready. A last word to a minimized
    // window is the app's, but not yet the player's.
    const give = (r) => {
        toApp({ type: "result", result: r });
        if (r.code === "running") return;
        if (winShown()) {
            unseen = null;
        } else {
            if (unseen) miss(unseen);
            unseen = r;
        }
    };

    // Upstream labels a desktop icon with its app id, capitalized. Here the
    // label is copy: the text after the icon's image is replaced.
    const applyCopy = () => {
        const icon = document.getElementById(APP);
        if (icon) {
            const img = icon.querySelector("img");
            icon.textContent = "";
            if (img) {
                img.alt = "";
                icon.appendChild(img);
            }
            icon.appendChild(document.createTextNode(line("desktop_icon")));
        }
        const title = document.getElementById("terminal-window-title");
        if (title) title.textContent = line("window_title");
    };

    // ── the tab's loading symbol ──────────────────────────────────────────

    // A page load of `ms` under way in the app (a new one replaces the last,
    // and its own length restarts the backstop), or -- null -- none: the
    // class and its animation removed, not paused.
    const tabLoading = (ms) => {
        const tab = document.getElementById("terminal-window-title");
        if (tabTimer !== null) {
            clearTimeout(tabTimer);
            tabTimer = null;
        }
        if (ms === null) {
            if (tab) tab.classList.remove(TAB_LOADING);
            return;
        }
        if (tab) tab.classList.add(TAB_LOADING);
        const n = Number(ms);
        const wait = Number.isFinite(n) && n >= 0
            ? Math.min(n + TAB_LOAD_SLACK_MS, TAB_LOAD_MAX_MS)
            : TAB_LOAD_MAX_MS;
        tabTimer = setTimeout(() => {
            tabTimer = null;
            tabLoading(null);
        }, wait);
    };

    // ── the clock ─────────────────────────────────────────────────────────

    // THE GAME'S TIME ON THE TASKBAR: the hour and the minute, written the
    // way upstream wrote the real one (the locale's date_format, en-US), and
    // no date. Nothing here runs a clock: it shows what br_core last sent.
    const showClock = (h, m) => {
        if (!Number.isInteger(h) || !Number.isInteger(m) || h < 0 || h > 23 || m < 0 || m > 59) return;
        const hours = document.getElementById("hours");
        const date = document.getElementById("date");
        const fmt = typeof GetLocale === "function" ? GetLocale("date_format") : "en-US";
        if (hours) hours.innerText = new Date(2000, 0, 1, h, m).toLocaleTimeString(fmt, { hour: "numeric", minute: "2-digit" });
        if (date) date.innerText = "";
    };

    // ── the window: its place, its size, maximized ──────────────────────

    // The desktop's area, in pixels: the screen above the taskbar.
    const area = () => {
        const d = desk();
        return { w: d ? d.clientWidth : window.innerWidth, h: d ? d.clientHeight : window.innerHeight };
    };

    // The middle of the desktop, in pixels, unless a drag has already placed
    // it this opening (br.css says why pixels).
    const center = (el) => {
        if (!el || el.style.top || el.style.left) return;
        const a = area();
        el.style.left = Math.max(0, Math.round((a.w - el.offsetWidth) / 2)) + "px";
        el.style.top = Math.max(0, Math.round((a.h - el.offsetHeight) / 2)) + "px";
    };

    const isMax = () => {
        const w = win();
        return !!w && w.classList.contains("br-max");
    };

    // MAXIMIZE TO THE DESKTOP, AND BACK TO WHERE IT WAS. The size and place
    // before are kept, and restoring puts both back exactly.
    const maximize = () => {
        const w = win();
        if (!w) return;
        if (isMax()) {
            w.classList.remove("br-max");
            if (restoreRect) {
                w.style.left = restoreRect.left;
                w.style.top = restoreRect.top;
                w.style.width = restoreRect.width;
                w.style.height = restoreRect.height;
            }
            restoreRect = null;
        } else {
            restoreRect = { left: w.style.left, top: w.style.top, width: w.style.width, height: w.style.height };
            const a = area();
            w.classList.add("br-max");
            w.style.left = "0px";
            w.style.top = "0px";
            w.style.width = a.w + "px";
            w.style.height = a.h + "px";
        }
    };

    // The window back to its own size, unmaximized and unplaced: the next
    // opening of the computer starts as the first did.
    const forgetWindow = () => {
        const w = win();
        if (!w) return;
        w.classList.remove("br-max", "br-sized");
        restoreRect = null;
        w.style.top = "";
        w.style.left = "";
        const def = typeof Applications === "object" && Applications[APP];
        if (def) {
            w.style.width = def.width + "px";
            w.style.height = def.height + "px";
        }
    };

    // RESIZING FROM ANY EDGE OR CORNER. The window keeps its MIN_W x MIN_H and
    // stays inside the desktop; the edge that is not being dragged stays
    // where it is. The app's frame ignores the pointer while it happens (an
    // iframe swallows mouse events over itself).
    let resizing = null;
    const startResize = (e, edge) => {
        const w = win();
        if (!w || isMax()) return;
        e.preventDefault();
        e.stopPropagation();
        const r = { left: w.offsetLeft, top: w.offsetTop, width: w.offsetWidth, height: w.offsetHeight };
        resizing = { edge, x: e.clientX, y: e.clientY, r };
        // From here the size is the player's: the opening size's caps go.
        w.style.width = r.width + "px";
        w.style.height = r.height + "px";
        w.classList.add("br-sized");
        const f = frame();
        if (f) f.style.pointerEvents = "none";
        document.body.classList.add("br-resizing-" + edge);
    };
    const moveResize = (e) => {
        if (!resizing) return;
        const w = win();
        if (!w) return;
        const { edge, x, y, r } = resizing;
        const a = area();
        const dx = e.clientX - x;
        const dy = e.clientY - y;
        let left = r.left;
        let top = r.top;
        let right = r.left + r.width;
        let bottom = r.top + r.height;
        if (edge.includes("w")) left = Math.min(Math.max(0, r.left + dx), right - MIN_W);
        if (edge.includes("e")) right = Math.max(Math.min(a.w, right + dx), left + MIN_W);
        if (edge.includes("n")) top = Math.min(Math.max(0, r.top + dy), bottom - MIN_H);
        if (edge.includes("s")) bottom = Math.max(Math.min(a.h, bottom + dy), top + MIN_H);
        w.style.left = left + "px";
        w.style.top = top + "px";
        w.style.width = (right - left) + "px";
        w.style.height = (bottom - top) + "px";
    };
    const endResize = () => {
        if (!resizing) return;
        document.body.classList.remove("br-resizing-" + resizing.edge);
        resizing = null;
        const f = frame();
        if (f) f.style.pointerEvents = "";
    };

    // ── the app ─────────────────────────────────────────────────────────

    // THE APP OPENS WHEN THE PLAYER OPENS IT, from its desktop icon -- and
    // only then is it loaded. This page loads at join on every client;
    // Cloudscape is ~1.7 MB and has no business running for a player who
    // never opens it. Its window's close button unloads it again, so every
    // opening of the app is a fresh one.
    const launch = () => {
        if (!isOpen) return;
        const f = frame();
        if (f && !appLoaded()) {
            appReady = false;
            f.setAttribute("src", APP_URL);
        }
        OpenApp(APP);
        center(win());
        if (f) f.focus();
    };

    // An answer the unloaded app had but the player never saw is held again.
    // A page it was loading never shows: the tab stops.
    const unload = () => {
        appReady = false;
        tabLoading(null);
        if (unseen) {
            hold(unseen);
            unseen = null;
        }
        const f = frame();
        if (f) f.setAttribute("src", "about:blank");
    };

    // The choices for a run, shape-checked, or false when malformed;
    // undefined stays undefined. The server checks them against the registry.
    const choices = (o) => {
        if (o === undefined || o === null) return undefined;
        if (typeof o !== "object" || Array.isArray(o)) return false;
        const keys = Object.keys(o);
        if (keys.length > OPTIONS_MAX) return false;
        const out = {};
        for (const k of keys) {
            if (!FUNCTION_ID.test(k) || typeof o[k] !== "string" || !CHOICE.test(o[k])) return false;
            out[k] = o[k];
        }
        return out;
    };

    // A boot's length: a uniform pick in br_core's range, every boot anew.
    const bootMs = (d) => {
        const lo = d && Number(d.bootMinMs);
        const hi = d && Number(d.bootMaxMs);
        if (!Number.isFinite(lo) || !Number.isFinite(hi) || lo < 0 || hi < lo) return BOOT_FALLBACK_MS;
        return Math.round(lo + Math.random() * (hi - lo));
    };

    const open = (msg) => {
        // A storm's close still on screen is over: the shell let go of it
        // before this opening, so it goes without a word.
        dropBlue(false);
        state = msg.state && typeof msg.state === "object" ? msg.state : null;
        copy = msg.copy && typeof msg.copy === "object" ? msg.copy : {};
        catalog = msg.catalog && typeof msg.catalog === "object" ? msg.catalog : {};
        const d = msg.desktop && typeof msg.desktop === "object" ? msg.desktop : {};
        applyCopy();
        if (d.clock) showClock(d.clock.h, d.clock.m);

        // Already up: a second open is a refresh, not a reboot.
        if (isOpen) {
            toApp({ type: "state", state, copy, catalog });
            return;
        }

        isOpen = true;
        held = null;
        unseen = null;
        const mine = ++session;
        document.body.style.display = "block";
        Load(true, line("shell_boot"), bootMs(d), () => {
            if (!isOpen || mine !== session) return;
            // THE BOOT ENDS ON THE DESKTOP. The app's icon is how it opens.
            document.getElementById("container").style.display = "block";
            Load(false);
        });
    };

    // `keep`: the page stays up, for the storm's close to play on it.
    const close = (why, fromLua, keep) => {
        if (!isOpen) return;
        isOpen = false;
        session++;

        if (!keep) document.body.style.display = "none";
        Load(false);
        endResize();

        // What upstream's ShutdownComputer did, without its 1.5 s screen: every
        // window shut, and every window's place forgotten, so the next opening
        // starts as the first did.
        openedApps.forEach((name) => CloseApp(name));
        openedApps = [];
        apps.forEach((name) => {
            const el = document.getElementById("app-" + name);
            if (el) {
                el.style.top = "";
                el.style.left = "";
            }
        });
        forgetWindow();

        // Unloading holds again what a minimized app had and the player never
        // saw; the last word the player never saw goes back for a toast,
        // before the close is said -- and whichever side closed it.
        unload();
        state = null;
        miss(held);
        held = null;

        if (!fromLua) post("close", { why });
    };

    // ── the storm's close (round 4) ─────────────────────────────────────

    // The blue screen taken down: the element and its animation REMOVED from
    // the page (#385: nothing is left that could animate), the page hidden as
    // every close hides it, and -- `tell` -- the shell told the screen is
    // dark, which gives the keyboard back. An opening that arrives first
    // drops it without a word: the shell has already let go.
    const dropBlue = (tell) => {
        if (!blue) return;
        clearTimeout(blue.timer);
        if (blue.el.parentNode) blue.el.parentNode.removeChild(blue.el);
        blue = null;
        if (!isOpen) document.body.style.display = "none";
        if (tell) post("off");
    };

    // THE STORM TOOK THE TERMINAL IN USE. The computer shuts as every one of
    // br_core's closes shuts it -- the app unloaded, its windows forgotten,
    // a held last word handed back -- but the page stays up for its screen:
    // the blue screen (#br-off, over everything, the copy block's bsod_*
    // lines) for BSOD_MS, then .br-crt collapses the picture to a line, a
    // dot and black over CRT_MS, then it is gone. A storm's close reaching a
    // page that is not open has nothing to show, and says so at once.
    const stormClose = () => {
        if (!isOpen) {
            post("off");
            return;
        }
        close("closed", true, true);
        const el = document.createElement("div");
        el.id = "br-off";
        const pic = document.createElement("div");
        pic.id = "br-bsod";
        [["br-bsod-face", "bsod_face"], ["br-bsod-text", "bsod_text"], ["br-bsod-code", "bsod_code"]]
            .forEach(([cls, key]) => {
                const p = document.createElement("p");
                p.className = cls;
                p.textContent = line(key);
                pic.appendChild(p);
            });
        el.appendChild(pic);
        document.body.appendChild(el);
        blue = { el, timer: null };
        blue.timer = setTimeout(() => {
            if (!blue || blue.el !== el) return;
            el.classList.add(CRT_CLASS);
            blue.timer = setTimeout(() => dropBlue(true), CRT_MS);
        }, BSOD_MS);
    };

    const fromApp = (d) => {
        if (d.brTerminal !== 1) return;
        if (d.type === "ready") {
            if (isOpen && appLoaded()) {
                appReady = true;
                // A fresh app is loading nothing.
                tabLoading(null);
                toApp({ type: "state", state, copy, catalog });
                if (held) {
                    const r = held;
                    held = null;
                    give(r);
                }
            }
        } else if (d.type === "run") {
            const options = choices(d.options);
            if (isOpen && typeof d.functionId === "string" && FUNCTION_ID.test(d.functionId)
                    && options !== false) {
                post("run", options === undefined
                    ? { functionId: d.functionId }
                    : { functionId: d.functionId, options });
            }
        } else if (d.type === "escape") {
            close("escape");
        } else if (d.type === "loading") {
            // Only for the app that is up, and only while the computer is.
            if (isOpen && appLoaded()) tabLoading(d.on === true ? d.ms : null);
        }
    };

    window.addEventListener("message", (event) => {
        const d = event.data;
        if (!d || typeof d !== "object") return;

        // The app, and only from its own window.
        const f = frame();
        if (f && event.source === f.contentWindow) {
            fromApp(d);
            return;
        }

        switch (d.type) {
            case "br:open":
                open(d);
                break;
            case "br:update":
                // THE STATE ALONE, once a second: the app keeps the copy and
                // the catalog it was opened with.
                if (isOpen) {
                    state = d.state && typeof d.state === "object" ? d.state : state;
                    toApp({ type: "state", state });
                }
                break;
            case "br:result": {
                const r = d.result && typeof d.result === "object" ? d.result : null;
                if (!r) break;
                if (isOpen && appReady) {
                    give(r);
                } else if (r.code !== "running") {
                    // Not the app's to take now: held while the desktop is
                    // up, and handed straight back once it has closed.
                    if (isOpen) hold(r);
                    else miss(r);
                }
                break;
            }
            case "br:clock":
                if (isOpen) showClock(d.h, d.m);
                break;
            case "br:close":
                if (d.storm === true) stormClose();
                else close("closed", true);
                break;
        }
    });

    // ESCAPE SHUTS THE COMPUTER, the boot included. Here for a key pressed on
    // the desktop; the app forwards its own (a keydown inside the iframe never
    // reaches this document). client/shell.lua releases NUI focus when the
    // close lands, so the keyboard and the mouse are the game's at once.
    document.addEventListener("keydown", (e) => {
        if (isOpen && e.key === "Escape") {
            e.preventDefault();
            close("escape");
        }
    });

    // A DRAG THAT CROSSES THE APP. Upstream's MakeElementDraggable follows the
    // mouse with document.onmousemove, and an iframe swallows mouse events
    // over itself, so a window dragged quickly by its title stuck wherever the
    // pointer first crossed the app. The frame ignores the pointer from the
    // title's mousedown to the mouseup. A MAXIMIZED window does not move: the
    // title's mousedown stops here, before upstream's drag sees it.
    document.addEventListener("mousedown", (e) => {
        const t = e.target;
        const handle = t && t.closest && t.closest(".br-resize");
        if (handle && handle.dataset.edge) {
            startResize(e, handle.dataset.edge);
            return;
        }
        if (t && t.closest && t.closest("#app-terminal-title") && !t.closest("button")) {
            if (isMax()) {
                e.stopPropagation();
                return;
            }
            const f = frame();
            if (f) f.style.pointerEvents = "none";
        }
    }, true);
    document.addEventListener("mousemove", moveResize, true);
    document.addEventListener("mouseup", () => {
        endResize();
        const f = frame();
        if (f) f.style.pointerEvents = "";
    }, true);

    // THE WINDOW'S BUTTONS AND THE APP'S ICON, wired after script.js's own
    // DOMContentLoaded (this listener is added later, so it runs later): the
    // icon launches the app; close unloads it as well as hiding it; maximize,
    // and a double-click on the title bar, toggle the desktop-sized window.
    document.addEventListener("DOMContentLoaded", () => {
        const icon = document.getElementById(APP);
        if (icon) icon.onclick = launch;
        const quit = document.getElementById(APP + "-quit");
        if (quit) {
            quit.onclick = () => {
                CloseApp(APP);
                unload();
            };
        }
        const max = document.getElementById(APP + "-maximize");
        if (max) max.onclick = maximize;
        const title = document.getElementById("app-" + APP + "-title");
        if (title) {
            title.addEventListener("dblclick", (e) => {
                if (e.target && e.target.closest && e.target.closest("button")) return;
                maximize();
            });
        }
        // The window shown again (the taskbar, or the icon): the player can
        // see what the app took while it was minimized.
        const w = win();
        if (w && typeof MutationObserver === "function") {
            new MutationObserver(() => {
                if (unseen && winShown()) unseen = null;
            }).observe(w, { attributes: true, attributeFilter: ["style"] });
        }
        // A maximized window follows the desktop when the screen changes size.
        window.addEventListener("resize", () => {
            const w = win();
            if (!w || !isMax()) return;
            const a = area();
            w.style.width = a.w + "px";
            w.style.height = a.h + "px";
        });
    });

    window.BRShell = { close: (why) => close(why || "exit") };
})();

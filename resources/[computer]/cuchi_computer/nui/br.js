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
//     { type: "br:open", state, copy }   boot the desktop, open the terminal app
//     { type: "br:update", state }       the server's new view of this terminal
//     { type: "br:result", result }      the server's answer to a run
//     { type: "br:close" }               br_core closed it (no answer is sent)
//
//   page -> Lua (NUI callbacks registered by client/shell.lua)
//     run   { functionId }               the app asked; the server decides
//     close { why }                      Escape, or the taskbar's power button
//
//   page <-> app (postMessage with the iframe; every message carries
//   brTerminal: 1, and each side only listens to the other's window)
//     app -> page  { type: "ready" }               send me the state
//                  { type: "run", functionId }     the player pressed Run
//                  { type: "escape" }              Escape inside the app
//     page -> app  { type: "state", state, copy }  render this
//                  { type: "result", result }      the answer to the last run
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
    // the clock's GetLocale would throw every second. Pinned before the
    // DOMContentLoaded handler in script.js starts that clock.
    Locale = "EN";

    const RES = typeof GetParentResourceName === "function"
        ? GetParentResourceName()
        : "cuchi_computer";
    const APP = "terminal";
    const APP_URL = "apps/terminal/index.html";
    // Upstream booted with two loader screens, 100 ms and 150 ms. One, the same
    // quarter second, under br_core's boot line.
    const BOOT_MS = 250;
    // The shape of a function id in br_lib/config/terminals.lua.
    const FUNCTION_ID = /^[a-z][a-z0-9_]{0,31}$/;

    let isOpen = false;
    // Bumped by every open and close, so a boot timer that outlives the close
    // it raced does not put the desktop back up.
    let session = 0;
    let state = null;
    let copy = {};

    const post = (name, body) => fetch(`https://${RES}/${name}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(body || {}),
    }).catch(() => {});

    const frame = () => document.getElementById("terminal-frame");

    // A line of br_core's copy, or nothing. Never a key name and never a
    // default of our own: every word on this desktop is the owner's.
    const line = (key) => (typeof copy[key] === "string" ? copy[key] : "");

    const toApp = (msg) => {
        const f = frame();
        if (f && f.contentWindow) {
            f.contentWindow.postMessage(Object.assign({ brTerminal: 1 }, msg), "*");
        }
    };

    // Upstream labels a desktop icon with its app id, capitalized. Here the
    // label is copy: the text after the icon's image is replaced.
    const applyCopy = () => {
        const icon = document.getElementById(APP);
        if (icon) {
            const img = icon.querySelector("img");
            icon.textContent = "";
            if (img) icon.appendChild(img);
            icon.appendChild(document.createTextNode(line("desktop_icon")));
        }
        const title = document.getElementById("terminal-window-title");
        if (title) title.textContent = line("window_title");
    };

    // The middle of the desktop, in pixels, unless a drag has already placed
    // it this opening (br.css says why pixels).
    const center = (el) => {
        if (!el || el.style.top || el.style.left) return;
        const desk = document.getElementById("desktop");
        const w = desk ? desk.clientWidth : window.innerWidth;
        const h = desk ? desk.clientHeight : window.innerHeight;
        el.style.left = Math.max(0, Math.round((w - el.offsetWidth) / 2)) + "px";
        el.style.top = Math.max(0, Math.round((h - el.offsetHeight) / 2)) + "px";
    };

    const open = (msg) => {
        state = msg.state && typeof msg.state === "object" ? msg.state : null;
        copy = msg.copy && typeof msg.copy === "object" ? msg.copy : {};
        applyCopy();

        // Already up: a second open is a refresh, not a reboot.
        if (isOpen) {
            toApp({ type: "state", state, copy });
            return;
        }

        isOpen = true;
        const mine = ++session;
        document.body.style.display = "block";
        Load(true, line("shell_boot"), BOOT_MS, () => {
            if (!isOpen || mine !== session) return;
            document.getElementById("container").style.display = "block";
            Load(false);

            // THE APP IS LOADED ON OPEN AND UNLOADED ON CLOSE. This page loads
            // at join on every client; Cloudscape is ~1.7 MB and has no
            // business running for the whole session of every player who never
            // touches a terminal. A fresh document per opening is also a fresh
            // app state -- nothing from the last terminal survives into this one.
            const f = frame();
            if (f && f.getAttribute("src") !== APP_URL) f.setAttribute("src", APP_URL);

            OpenApp(APP);
            center(document.getElementById("app-" + APP));
            if (f) f.focus();
        });
    };

    const close = (why, fromLua) => {
        if (!isOpen) return;
        isOpen = false;
        session++;

        document.body.style.display = "none";
        Load(false);

        // What upstream's ShutdownComputer did, without its 1.5 s screen: every
        // window shut, and every window's place forgotten, so the next opening
        // centers it again.
        openedApps.forEach((name) => CloseApp(name));
        openedApps = [];
        apps.forEach((name) => {
            const el = document.getElementById("app-" + name);
            if (el) {
                el.style.top = "";
                el.style.left = "";
            }
        });

        const f = frame();
        if (f) f.setAttribute("src", "about:blank");
        state = null;

        if (!fromLua) post("close", { why });
    };

    const fromApp = (d) => {
        if (d.brTerminal !== 1) return;
        if (d.type === "ready") {
            if (isOpen) toApp({ type: "state", state, copy });
        } else if (d.type === "run") {
            if (isOpen && typeof d.functionId === "string" && FUNCTION_ID.test(d.functionId)) {
                post("run", { functionId: d.functionId });
            }
        } else if (d.type === "escape") {
            close("escape");
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
                if (isOpen) {
                    state = d.state && typeof d.state === "object" ? d.state : state;
                    toApp({ type: "state", state, copy });
                }
                break;
            case "br:result":
                if (isOpen) toApp({ type: "result", result: d.result || null });
                break;
            case "br:close":
                close("closed", true);
                break;
        }
    });

    // ESCAPE SHUTS THE COMPUTER. Here for a key pressed on the desktop; the app
    // forwards its own (a keydown inside the iframe never reaches this
    // document). client/shell.lua releases NUI focus when the close lands.
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
    // title's mousedown to the mouseup.
    document.addEventListener("mousedown", (e) => {
        const t = e.target;
        if (t && t.closest && t.closest("#app-terminal-title")) {
            const f = frame();
            if (f) f.style.pointerEvents = "none";
        }
    }, true);
    document.addEventListener("mouseup", () => {
        const f = frame();
        if (f) f.style.pointerEvents = "";
    }, true);

    window.BRShell = { close: (why) => close(why || "exit") };
})();

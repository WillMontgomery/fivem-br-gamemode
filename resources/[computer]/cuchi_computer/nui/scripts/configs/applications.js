/*
 * ⚠️ WARNING ⚠️
 * Modifying this code without 
 * proper knowledge can result 
 * in its failure. 
 * 
 * Handle with care to avoid breaking it.
*/

// BR-PATCH 5 (fivem-royale, #396): ONE APP. Upstream's code, console,
// addresses, informations, market, themes and mail apps are gone; the desktop
// holds the terminal and nothing else. Its body is an iframe because the app
// is a React + Cloudscape page built separately (ui-src/terminal, output in
// nui/apps/terminal/): Cloudscape's global styles would restyle this desktop
// if they shared its document. br.js points the frame at the app when the
// player opens it from its desktop icon (round 2: the computer boots to the
// desktop and stops there) and back at nothing when its window or the
// computer closes, and the title is written there too, from br_core's copy --
// nothing below is player-facing text.
// 1440x880 is a browser window (owner, 2026-10-05: "I want the window/app to
// look like a web browser"), up from the 960x630 upstream gave its own iframe
// app one commit after v1.1.1 -- the Cloudscape app's side navigation and its
// cards need the room. ../br.css caps it at 98vw x 92vh, so on 1280x720 it is
// 1254x662.
//
// Round 2 (owner, 2026-10-05): "We should also have the ability to resize
// (when grabbing the edges) and maximize the window." So the title bar has a
// maximize button between minimize and close, and the window eight resize
// handles, one per edge and corner; ../br.js drives both and ../br.css draws
// them. And the app's icon is our own drawing, `icon` below, which the window
// manager reads where it used to build `<appName>.png` (BR-PATCH 12).
const Applications = {
    "terminal": {
        usable: true,
        width: 1440,
        height: 880,
        icon: "assets/images/terminal.svg",
        appCode: `
<div id="app-terminal" class="application">
    <h1 id="app-terminal-title"><button id="terminal-quit" class="app-exit"></button><button id="terminal-minimize" class="app-minimize"></button><button id="terminal-maximize" class="app-maximize"></button><span id="terminal-window-title"></span></h1>
    <div id="terminal-wrapper">
        <iframe id="terminal-frame" src="about:blank" tabindex="0"></iframe>
    </div>
    <div class="br-resize br-n" data-edge="n"></div><div class="br-resize br-s" data-edge="s"></div><div class="br-resize br-e" data-edge="e"></div><div class="br-resize br-w" data-edge="w"></div><div class="br-resize br-ne" data-edge="ne"></div><div class="br-resize br-nw" data-edge="nw"></div><div class="br-resize br-se" data-edge="se"></div><div class="br-resize br-sw" data-edge="sw"></div>
</div>`
    }
};
// BR-PATCH 5 end

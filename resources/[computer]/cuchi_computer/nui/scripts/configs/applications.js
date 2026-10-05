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
// computer opens and back at nothing when it closes, and the title is written
// there too, from br_core's copy -- nothing below is player-facing text.
// 1440x880 is a browser window (owner, 2026-10-05: "I want the window/app to
// look like a web browser"), up from the 960x630 upstream gave its own iframe
// app one commit after v1.1.1 -- the Cloudscape app's side navigation and its
// cards need the room. ../br.css caps it at 98vw x 92vh, so on 1280x720 it is
// 1254x662.
const Applications = {
    "terminal": {
        usable: true,
        width: 1440,
        height: 880,
        appCode: `
<div id="app-terminal" class="application">
    <h1 id="app-terminal-title"><button id="terminal-quit" class="app-exit"></button><button id="terminal-minimize" class="app-minimize"></button><span id="terminal-window-title"></span></h1>
    <div id="terminal-wrapper">
        <iframe id="terminal-frame" src="about:blank" tabindex="0"></iframe>
    </div>
</div>`
    }
};
// BR-PATCH 5 end

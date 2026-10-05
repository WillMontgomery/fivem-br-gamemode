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
// 960x630 is the size upstream gave its own iframe app (the browser, one
// commit after v1.1.1).
const Applications = {
    "terminal": {
        usable: true,
        width: 960,
        height: 630,
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

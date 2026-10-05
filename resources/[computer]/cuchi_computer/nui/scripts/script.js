let apps = [];
let openedApps = [];
// BR-PATCH 6 (fivem-royale, #396): the console's command history is gone
// with the console. BR-PATCH 6 end
let msgId = 0;
// BR-PATCH 6 (fivem-royale, #396): upstream's roleplay state is gone -- the
// fake IP, the framework identifier, and the mail app's account, list and
// reply target. BR-PATCH 6 end
let AppsZIndex = {};
// BR-PATCH 6 (fivem-royale, #396): the addresses app's state is gone with
// it. BR-PATCH 6 end
let openedApp = "";

// BR-PATCH 6 (fivem-royale, #396): UPSTREAM'S MESSAGE HANDLER IS GONE.
// It booted the desktop on "show" (writing the fake IP and the mail and
// market settings a framework callback had fetched), and handled "version",
// "identifier" and "force-close". br.js, loaded after this file, owns every
// message from client/shell.lua now -- open, update, result, close -- and
// calls the window manager below exactly as that handler did. BR-PATCH 6 end

document.addEventListener("DOMContentLoaded", () => {
    // BR-PATCH 7 (fivem-royale, #396): no language picker, so no SetLocale
    // and no picker wiring -- the element is gone from index.html, and
    // reaching for it threw before anything below could run. BR-PATCH 7 end

    // BR-PATCH 7 (fivem-royale, #396): NO SAVED THEME. Upstream restored a
    // theme from localStorage here, and NUI storage is per resource name on
    // the player's machine, not per server: a player who picked a theme in
    // cuchi_computer on any other server would get that theme here. The
    // themes app is gone, so the stylesheet's own :root colors are the one
    // theme. editTheme below is left as upstream wrote it. BR-PATCH 7 end

    setInterval(() => {
        let date = new Date();

        const dateFormat = GetLocale("date_format");
        document.getElementById("hours").innerText = date.toLocaleTimeString(dateFormat);
        document.getElementById("date").innerText = date.toLocaleDateString(dateFormat);
    }, 1000);

    // BR-PATCH 8 (fivem-royale, #396): THE POWER BUTTON SHUTS DOWN AT ONCE.
    // Upstream asked first, in a message box, and then played a 1.5 s
    // "shutting down" screen before giving the keyboard back. Here the
    // player is standing in a live match: br.js closes the desktop and
    // client/shell.lua releases NUI focus on the same click, the way Escape
    // does.
    document.getElementById("exit").onclick = () => BRShell.close("exit");
    // BR-PATCH 8 end

    let desktop = document.getElementById("desktop");
    let unusableApps = [];
    Object.entries(Applications).forEach(entry => {
        const [appName, appData] = entry;
        if (!Applications[appName].hide)
        {
            let appNameCapitalized = appName.charAt(0).toUpperCase() + appName.slice(1);
            desktop.innerHTML += `<button id="${appName}" class="desktop-icon"><img src="assets/images/${appName}.png">${appNameCapitalized}</button>`;
        }

        if (appData.usable) {
            apps.push(appName); // made an array since adding onclick event while be only applied for the last element with the object foreach (weird)
            desktop.innerHTML += appData.appCode;
        }
        else {
            unusableApps.push(appName);
        }
    });

    apps.forEach(app => {
        if (!Applications[app].hide)
            document.getElementById(app).onclick = () => OpenApp(app);

        document.getElementById(app+"-quit").onclick = () => CloseApp(app);
        document.getElementById(app+"-minimize").onclick = () => MinimizeApp(app);

        let appElement = document.getElementById("app-"+app);
        appElement.setAttribute("style", `display:none;width:${Applications[app].width}px;height:${Applications[app].height}px;`);
        MakeElementDraggable(appElement);
    });

    unusableApps.forEach(app => {
        document.getElementById(app).onclick = () => MessageBox("error", GetLocale("os_error"), GetLocale("os_fake_error").replace("{1}", app));
    });

    fetch(`https://${GetParentResourceName()}/NUIOk`,
    {
        method: "POST",
        body: null
    });

    // BR-PATCH 9 (fivem-royale, #396): the mail and market apps' wiring is
    // gone with the apps (both were oxmysql-backed roleplay features).
    // BR-PATCH 9 end
})

/**
 * Displays a loading page
 * @param {boolean} load create or destroy loading
 * @param {string} text text to display under the loading icon
 * @param {number} timeout time wait before calling the callback function
 * @param {function} callback callback function that is triggered after the loading
 */
const Load = (load, text, timeout, callback) => {
    if (load) {
        document.getElementById("loader-text").innerText = text;
        document.getElementById("loader-container").style.display = "flex";
        document.getElementById("container").style.display = "none";
        setTimeout(callback, timeout);
    }
    else {
        document.getElementById("loader-container").style.display = "none";
    }
};

/**
 * Plays mp3 audio file
 * @param {string} soundName file name of the audio (must be .mp3)
 */
const PlayAudio = (soundName) => {
    new Audio("assets/sounds/"+soundName+".mp3").play();
};

/**
 * Opens Application
 * @param {string} appName the application name
 * @param {boolean} [msgBox] is it a message box 
 * @returns {0 | 1 | 2} 0 -> app doesn't exist, 1 -> app opened, 2 -> app was already opened
 */
const OpenApp = (appName, msgBox) => {
    openedApps.push(appName);

    let elem = document.getElementById("app-"+appName);
    if (!elem) {
        if (Applications[appName] && !Applications[appName].usable) {
            MessageBox("error", GetLocale("os_error"), GetLocale("os_fake_error").replace("{1}", appName));
            return 1;
        }

        return 0;
    }
    elem.style.display = "flex";
    elem.style.visibility = "visible";

    let wasOpen = true;
    let taskbarIcon = document.getElementById("taskbar-"+appName);

    if (!taskbarIcon) {
        wasOpen = false;
        let taskbar = document.getElementById("left");
        taskbarIcon = document.createElement("button");
        taskbarIcon.id = "taskbar-"+appName;
        taskbarIcon.classList.add("taskbar-icon");
        taskbarIcon.innerHTML = `<img src="assets/images/${msgBox ? appName.split("_")[1] : appName}.png">`;
        taskbarIcon.onclick = () => {
            if (elem.style.visibility === "hidden" || elem.style.zIndex < 9999999) {
                FocusApp(false, appName);
                elem.style.visibility = "visible";
    
                if (appName == "console") {
                    let consoleInput = document.getElementById("console-input");
                    if (consoleInput) consoleInput.focus();
                }
            }
            else {
                MinimizeApp(appName);
            }
        }
        taskbar.appendChild(taskbarIcon);
    }

    elem.onmousedown = (e) => FocusApp(e, appName);
    document.body.onmousedown = () => UnfocusAllApp();
    FocusApp(false, appName);

    if (!wasOpen) {
        if (appName === "console") 
            ClearConsole();
        else if (appName === "mail") {
            mailCreation = false;
            document.getElementById("mail-create").innerText = GetLocale("mail_create");
            document.getElementById("mail-signout").style.display = "initial";
            document.getElementById("mail-refresh").style.display = "initial";
            document.getElementById("mail-creator").style.display = "none";
            document.getElementById("mail-reader").style.display = "none";
            document.getElementById("mail-container").style.display = "flex";
        }
    }

    return wasOpen ? 2 : 1;
};

/**
 * Closes Application
 * @param {string} appName the application name
 * @param {function} [callback] function callback
 * @returns {boolean} true or false if the app was or wasn't running
 */
const CloseApp = (appName, callback) => {
    const app = document.getElementById("app-"+appName);
    if (app)
        app.style.display = "none";

    let wasRunning = true;
    const taskbarIcon = document.getElementById("taskbar-"+appName);
    if (taskbarIcon)
        document.getElementById("left").removeChild(taskbarIcon);
    else
        wasRunning = false;

    if (callback) callback();

    let isMsgBox = appName.split("_")[0] == "msgbox";
    if (isMsgBox) {
        if (app)
            app.remove(); // delete message box so it is no longer in the html

        let inAppsIndex = apps.indexOf(appName);
        if (inAppsIndex >= 0)
            apps.splice(inAppsIndex, 1);
    }
    else if (appName === "addresses-content") {
        const event = new Event("addressesApplicationClose:" + openedApp);
        document.dispatchEvent(event);
        openedApp = "";
    }

    return wasRunning;
};

/**
 * Unfocuses all applications
 */
const UnfocusAllApp = () => {
    const focused = document.getElementsByClassName("app-active");
    while (focused.length > 0)
        focused[0].classList.remove("app-active");
};

/**
 * Focuses application
 * @param {MouseEvent | false} e 
 * @param {string} appName the application to focus
 */
const FocusApp = (e, appName) => {
    if (e)
        e.stopPropagation(); // stop the event from also being handled by the body

    UnfocusAllApp();

    let taskbarIcon = document.getElementById("taskbar-"+appName);
    taskbarIcon.classList.add("app-active");

    apps.forEach(app => {
        if (app == appName) {
            document.getElementById("app-"+appName).style.zIndex = 9999999;
            AppsZIndex[app] = 9999999;
        }
        else {
            if (AppsZIndex[app]) {
                AppsZIndex[app] -= 1;
            }
            document.getElementById("app-"+app).style.zIndex = AppsZIndex[app];
        }
    });

    if (appName == "console") {
        let consoleInput = document.getElementById("console-input");
        if (consoleInput) consoleInput.focus();
    }
};

/**
 * Minimizes application
 * @param {string} appName the application to minimize
 * @param {function} [callback] function callback
 */
const MinimizeApp = (appName, callback) => {
    document.getElementById("taskbar-"+appName).classList.remove("app-active");
    document.getElementById("app-"+appName).style.visibility = "hidden";

    if (callback) callback();
};

/**
 * Makes an element draggable
 * @param {HTMLDivElement} element the element to make draggable
 */
const MakeElementDraggable = (element) => {
    let pos1 = 0, pos2 = 0, pos3 = 0, pos4 = 0;
    let movable = document.getElementById(element.id + "-title");
    movable.style.cursor = "move";
    movable.onmousedown = (e) => {
        pos3 = e.clientX;
        pos4 = e.clientY;
        document.onmouseup = () => {
            document.onmouseup = null;
            document.onmousemove = null;
        };

        document.onmousemove = (e) => {
            pos1 = pos3 - e.clientX;
            pos2 = pos4 - e.clientY;
            pos3 = e.clientX;
            pos4 = e.clientY;

            let newTop = element.offsetTop - pos2;
            let newLeft = element.offsetLeft - pos1;
            
            // prevent window to be behind the taskbar 
            // screen height - 10% of itself because taskbar is 5% height + 5% of safety to let the title bar visible
            if (newTop >= 0 && newTop <= (window.innerHeight - 0.10 * window.innerHeight)) 
                element.style.top = newTop + "px";

            element.style.left = newLeft + "px";
        };
    };
};

// BR-PATCH 10 (fivem-royale, #396): OnConsoleCommand, AddConsoleLine,
// ClearConsole and AddInformation are gone with the console and the
// informations app. OpenApp and FocusApp above still have branches for the
// console and the mail app; they test for app ids that no longer exist, so
// they never run, and are left as upstream wrote them. BR-PATCH 10 end

/**
 * @typedef {Array} MessageBoxButtonsList
 * @property {MessageBoxButton} button - button properties
 */

/**
 * @typedef {Object} MessageBoxButton
 * @property {string} text - Text
 * @property {function} [callback] - specific callback for this button
 */

/**
 * Display a message
 * @param {"error" | "info"} type - The type of the message box
 * @param {string} title - Title of the message box
 * @param {string} message - Content of the message box
 * @param {MessageBoxButtonsList} [buttons]
 * @param {function} [onClose] function to execute when the close button is clicked
 * @param {function} [onMinimize] function to execute when the minimize button is clicked
 */
const MessageBox = (type, title, message, buttons, onClose, onMinimize) => {
    msgId += 1;
    let element = document.createElement("div");
    element.style.display = "flex";
    let appName = "msgbox_" + type + "_" + msgId;
    element.id = "app-" + appName;
    
    element.style.top = "50%";
    element.style.left = "50%";
    element.style.transform = "translate(-50%, -50%)";

    element.classList.add("application");

    let h1 = document.createElement("h1");
    h1.id = element.id+"-title";
    h1.innerHTML = `<button id="${appName}-quit" class="app-exit"></button><button id="${appName}-minimize" class="app-minimize"></button>${title}`
    element.appendChild(h1);

    let p = document.createElement("p");
    p.innerText = message;
    p.classList.add("msg-box-text");
    element.appendChild(p);

    if (!buttons) {
        let button = document.createElement("button");
        button.classList.add("msg-box-btn");
        button.innerText = GetLocale("os_close");
        button.onclick = () => CloseApp(appName);
    
        element.appendChild(button);
    }
    else {
        let buttonsContainer;
        if (buttons.length > 1) {
            buttonsContainer = document.createElement("div");
            buttonsContainer.classList.add("msg-box-btn-container");
            element.appendChild(buttonsContainer);
        }
        
        buttons.forEach(buttonData => {
            let buttonElem = document.createElement("button");
            buttonElem.classList.add("msg-box-btn");
            buttonElem.innerText = buttonData.text;
            buttonElem.onclick = () => {
                CloseApp(appName);
                if (buttonData.callback) 
                    buttonData.callback();
            };
        
            (buttonsContainer || element).appendChild(buttonElem);
        });
    }

    apps.push(appName);
    document.getElementById("desktop").appendChild(element);
    OpenApp(appName, true);
    document.getElementById(appName+"-quit").onclick = () => CloseApp(appName, onClose);
    document.getElementById(appName+"-minimize").onclick = () => MinimizeApp(appName, onMinimize);
    MakeElementDraggable(element);

    PlayAudio("message");
};

/**
 * Closes the interface
 * @param {HTMLElement} [exitBtn] if triggered from the exit button
 * @param {boolean} [forced] forced shutdown
 */
const ShutdownComputer = (exitBtn, forced) => {
    Load(true, forced ? GetLocale("os_shutdown_forced") : GetLocale("os_shuttingdown"), 1500, () => {
        document.body.style.display = "none";
        Load(false);
        fetch(`https://${GetParentResourceName()}/exit`,
        {
            method: "POST",
            body: null
        });
    });
    openedApps.forEach(appName => CloseApp(appName));
    openedApps = [];

    if (exitBtn)
        exitBtn.removeAttribute("validation");

    apps.forEach(app => {
        let appElement = document.getElementById("app-"+app);
        appElement.style.top = "25%";
        appElement.style.left = "25%";

        let appTextElement = document.getElementById(app+"-text");
        if (appTextElement) {
            appTextElement.innerHTML = "";
        }
    });
}

/**
 * Edit theme
 * @param {object} themeData object containing theme data
 */
const editTheme = (themeData) => {
    let oldTheme = document.getElementById("theme-"+localStorage.getItem("--main-color"));
    if (oldTheme) {
        oldTheme.innerHTML = "";
        document.getElementById("theme-"+themeData["--main-color"].toLowerCase()).innerHTML = "•";
    }

    for (let [key, value] of Object.entries(themeData)) {
        value = value.toLowerCase();
        localStorage.setItem(key, value);
        document.querySelector(":root").style.setProperty(key, value);
    }
}

// BR-PATCH 10 (fivem-royale, #396): setupMail and refreshMails are gone with
// the mail app. BR-PATCH 10 end

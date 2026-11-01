// The installed app's launch splash (shown only in standalone mode on a phone; app.css).
// The phone's own launch screen cannot be turned off, so this starts laid out like it (a small
// icon on white), grows the icon to the centre, holds SPLASH_MS and fades.
// Runs before the rest of the page is parsed, so its first frame is the phone's layout.
"use strict";
(function () {
  const SPLASH_MS = 400, IOS_START = 0.20;  // hold; iOS start size as a share of the short screen edge
  const ua = navigator.userAgent, isIOS = /iP(hone|ad|od)/.test(ua), isAndroid = /Android/i.test(ua);
  if (!isIOS && !isAndroid) return;
  const root = document.documentElement, sp = document.getElementById("splash");
  root.classList.add(isIOS ? "ios" : "android");
  // Samsung Internet shows the whole maskable tile on its launch screen: start at that size
  if (/SamsungBrowser/.test(ua)) root.classList.add("samsung");
  requestAnimationFrame(() => requestAnimationFrame(() => sp.classList.add("grow")));
  // iOS: start at the screen centre; the standalone page begins under the status bar, so the
  // page centre sits half a status bar lower. Measured once (re-applying made it jump).
  if (isIOS) {
    const d = screen.height - window.innerHeight, bar = d > 0 && d < 120 ? d : 47;
    sp.style.setProperty("--ios-top", `calc(50% - ${bar / 2}px)`);
    sp.style.setProperty("--ios-start", `${Math.min(screen.width, screen.height) * IOS_START}px`);
  }
  setTimeout(() => { sp.style.opacity = "0"; setTimeout(() => sp.remove(), 300); }, SPLASH_MS + 350);
})();

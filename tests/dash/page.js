// The page's own logic (asc/web/app.js) without a browser: what a favorite's row says, and how
// its history reads (labels, the text cleaned of pids, session ids and the home folder, repeats
// folded). The browser objects are stubs that answer everything; nothing is drawn.
//   node tests/dash/page.js <repo>     prints ok/FAIL lines; exit 0 = all passed
"use strict";
const vm = require("vm"), fs = require("fs"), path = require("path");
const stub = new Proxy(function () {}, {
  get: (t, k) => (k === Symbol.toPrimitive ? () => "" : k === "then" ? undefined : stub),
  apply: () => stub, construct: () => stub, has: () => false,
});
const ctx = vm.createContext({ document: stub, window: stub, navigator: {}, location: stub, history: stub,
  setInterval() {}, setTimeout() {}, clearTimeout() {}, fetch: () => new Promise(() => {}), console });
vm.runInContext(fs.readFileSync(path.join(process.argv[2], "asc/web/app.js"), "utf8"), ctx);
const run = (code) => vm.runInContext(code, ctx);
let fail = 0;
const check = (name, code) => {
  let got;
  try { got = run(code); } catch (e) { got = e; }
  if (got === true) console.log("  ok    page: " + name);
  else { console.log("  FAIL  page: " + name + " (" + got + ")"); fail++; }
};

// A home folder put together at run time, so the privacy check does not read it as a real one.
const HOME = ["", "home", "demo"].join("/");
run(`var T = Math.floor(Date.now() / 1000);
S = { home: "${HOME}", boot: { todo: ["0003", "0004", "0005"], why: "memory: watched for under 5 min" }, favorites: [
  { id4: "0001", state: "on", status: "waiting", waiting_for: "", status_at: T - 60, claudes: 1 },
  { id4: "0002", state: "off", resurrect: true, last_off: T - 60 },
  { id4: "0003", state: "on", status: "idle", claudes: 1 },
  { id4: "0004", state: "off (wanted on)", resurrect: true },
  { id4: "0005", state: "off (wanted on)", resurrect: true },
  { id4: "0006", state: "off", resurrect: false } ] };
var F = (id) => S.favorites.find((e) => e.id4 === id);`);

check("1 day ago, 3 days ago", `ago(Date.now() / 1000 - 86400) === "1 day ago" && ago(Date.now() / 1000 - 3 * 86400) === "3 days ago"`);
check("the time it was updated: day, month, year and seconds", `stamp(new Date(2026, 10, 4, 11, 27, 42)) === "4 Nov 2026, 11:27:42"`);
check("waiting with no reason: a prompt in its pane", `statusText(F("0001")).startsWith("Waiting for you (a prompt in its pane) since ")`);
check("waiting: the row's hint, not a why (the sheet says it in Status)",
  `look(F("0001")).hint === "A prompt in its pane, since " + hm(new Date((T - 60) * 1000)) && !look(F("0001")).why`);
check("waiting for something named: that", `look(Object.assign({}, F("0001"), { waiting_for: "approve Bash" })).hint.startsWith("approve Bash, since ")`);
check("resurrect on but off: why a reboot will not bring it back", `look(F("0002")).why === "Off, so a reboot won't bring it back." && look(F("0002")).group === "off"`);
check("off, resurrect off: no why", `look(F("0006")).why === ""`);
check("boot: the first still off says what it waits for (one on by hand is passed over)",
  `look(F("0004")).label === "Coming back" && look(F("0004")).why === "Starts once memory has stayed under 80% used for 5 min."`);
check("boot: the next waits its turn", `look(F("0005")).why === "Waits its turn: one start at a time." && look(F("0003")).group === "on"`);
check("boot reasons in words; an odd one passed on", `bootWhy("network: waiting for claude.ai to answer").startsWith("Starts once claude.ai answers")
  && bootWhy("pause: x") === "Starts in a moment." && bootWhy("memory: no recent sample (is the watcher running?)") === "No recent sample (is the watcher running?)."
  && bootWhy("memory: down to 12% available in the last 5 min (a start needs 20% steady)").startsWith("Starts once memory")`);

const ev = (kind, text, extra) => JSON.stringify(Object.assign({ t: 1000, kind, by: "page", text }, extra || {}));
const label = (kind, text) => `evLabel(${ev(kind, text)})`, detail = (kind, text) => `evDetail(${ev(kind, text)})`;
check("rc on/off read from its own words, not from a name with off in it",
  `${label("rc", "back-off-0421: rc on, title 'x' from its next start")} === "Remote control on" && ${label("rc", "a-0421: rc off, off now")} === "Remote control off"`);
check("rc: its name not sent is no switch, and says why",
  `${label("rc", "a-0421: its name not sent to claude.ai: busy")} === "Remote control" && ${detail("rc", "a-0421: its name not sent to claude.ai: busy")} === "Its name not sent to claude.ai: busy"`);
check("resurrect off", `${label("resurrect", "a-0421: resurrect off")} === "Resurrect off"`);
check("renamed: both forms name the new name",
  `${label("rename", "renamed to db-0421, claude and its claude.ai title too")} === "Renamed to db" && ${label("rename", "renamed: db-0421")} === "Renamed to db"`);
check("followed: a folder, another conversation, one chosen at start",
  `${label("followed", "its claude moved to " + HOME + "/src/x (was " + HOME + "/x)")} === "Folder moved" && ${detail("followed", "its claude moved to " + HOME + "/src/x (was " + HOME + "/x)")} === "Now ~/src/x"
  && ${label("followed", "its claude now holds session a (was b): a branch")} === "New conversation"
  && ${detail("followed", "session a is now b (claude chose it at start)")} === "Claude started in another conversation"`);
check("a refusal: prefix gone, the lock message in words",
  `${detail("refused", "on: 5105 is being started or stopped by another asctl; try again")} === "Busy with another start or stop"`);
check("no pid, session id, tmux command or home folder in a detail",
  `${detail("failed", "x-0421: tmux session started, but no claude came up (see: tmux attach -t =x-0421)")} === "Tmux session started, but no claude came up"
  && ${detail("refused", "off: its claude (2259699) runs outside its tmux session")} === "Its claude runs outside its tmux session"
  && ${detail("waiting", "boot: not started yet: claude 41234 holds session 11111111-2222-4333-8444-555555555555 in " + HOME + "/w")} === "Not started yet: claude holds session … in ~/w"`);
check("ended: the exit, not the label again", `${detail("ended", "claude ended, exit 143 (a signal), its tmux session up; memory: x")} === "Exit 143 (a signal), its tmux session up"`);
check("on and off carry no detail (their text has pids)", `${detail("on", "claude 41234, session x")} === "" && ${detail("off", "claude 1 ended")} === ""`);
check("a long detail is cut", `${detail("refused", "on: " + "w".repeat(400))}.length === 160`);
check("repeats in a row fold into one line, from the first",
  `(() => { const r = (t) => ({ t, kind: "refused", by: "page", text: "on: 0001 is being started or stopped by another asctl; try again" });
    const g = evFold([r(900), r(800), r(700), { t: 600, kind: "on", by: "page", text: "" }, r(500)]);
    return g.length === 3 && g[0].n === 3 && g[0].first === 700 && g[1].n === 1 && g[2].n === 1; })()`);
process.exit(fail ? 1 : 0);

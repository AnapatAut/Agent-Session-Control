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
const ctx = vm.createContext({ document: stub, window: stub, navigator: {}, location: stub, history: stub, URL,
  setInterval() {}, setTimeout() {}, clearTimeout() {}, fetch: () => new Promise(() => {}), console });
// Loaded as a page opened directly (the stubs: no referrer, no history); an error is kept for the
// first check below, so the checks after it still run.
let loadErr = null;
try { vm.runInContext(fs.readFileSync(path.join(process.argv[2], "asc/web/app.js"), "utf8"), ctx); } catch (e) { loadErr = e; }
const run = (code) => vm.runInContext(code, ctx);
let fail = 0;
const later = [];  // checks whose code gives a promise (act): judged once it settles, at the end
const check = (name, code) => {
  let got;
  try { got = run(code); } catch (e) { got = e; }
  const judge = (got) => {
    if (got === true) console.log("  ok    page: " + name);
    else { console.log("  FAIL  page: " + name + "\n" + String(got).replace(/^/gm, "        got: ")); fail++; }
  };
  if (got && typeof got.then === "function") later.push(got.then(judge, judge)); else judge(got);
};

// A home folder put together at run time, so the privacy check does not read it as a real one.
const HOME = ["", "home", "demo"].join("/");
run(`var T = Math.floor(Date.now() / 1000);
S = { home: "${HOME}", boot: { todo: ["0003", "0004", "0005"], why: "memory: watched for under 30 s" }, favorites: [
  { id4: "0001", state: "on", status: "waiting", waiting_for: "", status_at: T - 60, claudes: 1 },
  { id4: "0002", state: "off", resurrect: true, last_off: T - 60 },
  { id4: "0003", state: "on", status: "idle", claudes: 1 },
  { id4: "0004", state: "off (wanted on)", resurrect: true },
  { id4: "0005", state: "off (wanted on)", resurrect: true },
  { id4: "0006", state: "off", resurrect: false } ] };
var F = (id) => S.favorites.find((e) => e.id4 === id);`);

check("the page's script runs to its end, opened directly (no referrer)", loadErr === null ? "true" : `${JSON.stringify(String(loadErr))}`);
check("Settings: the version line, asctl and what the server runs; none without one", `(() => {
  const plain = el; let seen = null;
  el = (t, x, c) => { if (c === "ver") seen = x; return plain(t, x, c); };
  try {
    S.version = "1.2.3 (release 0123456789ab)";
    const withIt = settingsSheet().length === 3 && seen === "asctl 1.2.3 (release 0123456789ab)";
    delete S.version; seen = null;
    return withIt && settingsSheet().length === 2 && seen === null;
  } finally { el = plain; delete S.version; }
})()`);
check("1 day ago, 3 days ago", `ago(Date.now() / 1000 - 86400) === "1 day ago" && ago(Date.now() / 1000 - 3 * 86400) === "3 days ago"`);
check("the time it was updated: day, month, year and seconds", `stamp(new Date(2026, 10, 4, 11, 27, 42)) === "4 Nov 2026, 11:27:42"`);
check("outside its tmux session: where it runs", `look({ state: "on (outside its tmux session)", tmux: "x-0001",
  outside: { how: "terminal", text: "a terminal outside tmux (orca-ide, pts/27)", busy: "" } }).why
  === "Its claude runs in a terminal outside tmux (orca-ide, pts/27), not in tmux session x-0001."`);
check("waiting with no reason: a prompt in its pane", `statusText(F("0001")).startsWith("Waiting for you (a prompt in its pane) since ")`);
check("waiting: the row's hint, not a why (the sheet says it in Status)",
  `look(F("0001")).hint === "A prompt in its pane, since " + hm(new Date((T - 60) * 1000)) && !look(F("0001")).why`);
check("waiting for something named: that", `look(Object.assign({}, F("0001"), { waiting_for: "approve Bash" })).hint.startsWith("approve Bash, since ")`);
check("resurrect on but off: why a reboot will not bring it back", `look(F("0002")).why === "Off, so a reboot won't bring it back." && look(F("0002")).group === "off"`);
check("off, resurrect off: no why", `look(F("0006")).why === ""`);
check("boot: the first still off says what it waits for (one on by hand is passed over)",
  `look(F("0004")).label === "Coming back" && look(F("0004")).why === "Starts once memory has stayed under 80% used for 30 s."`);
check("boot: the next waits its turn", `look(F("0005")).why === "Waits its turn: one start at a time." && look(F("0003")).group === "on"`);
check("boot reasons in words; an odd one passed on", `bootWhy("network: waiting for claude.ai to answer").startsWith("Starts once claude.ai answers")
  && bootWhy("pause: x") === "Starts in a moment." && bootWhy("memory: no recent sample (is the watcher running?)") === "No recent sample (is the watcher running?)."
  && bootWhy("memory: down to 12% available in the last 30 s (a start needs 20% steady)").startsWith("Starts once memory")`);

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
// A favorite whose claude waits at Claude Code's trust prompt, and the page's Trust folder.
check("waiting for trust: needs attention, names the folder", `(() => { const l = look({ state: "waiting for trust", cwd: "${HOME}/fresh" });
  return l.group === "attention" && l.label === "Waiting for trust"
    && l.why === "Claude Code asks whether to trust ~/fresh. Trust folder lets claude start there; Off closes it."; })()`);
check("waiting at a prompt: needs attention, says what Claude Code asks and where to answer", `(() => {
  const l = look({ state: "waiting at a prompt", tmux: "fresh-0007", prompt: "2 new MCP servers found in this project" });
  const n = look({ state: "waiting at a prompt", tmux: "fresh-0007", prompt: "" });
  return l.group === "attention" && l.label === "Waiting at a prompt" && !isOn({ state: "waiting at a prompt" })
    && l.why === "Claude Code asks: “2 new MCP servers found in this project”. Answer it in its pane (tmux attach -t =fresh-0007); Off closes it."
    && n.why === "Its claude has not come up: Claude Code may ask something in its pane (tmux attach -t =fresh-0007); Off closes it."; })()`);
check("unknown (tmux did not answer): needs attention, says nothing is changed", `(() => { const l = look({ state: "unknown" });
  return l.group === "attention" && l.label === "Unknown" && !isOn({ state: "unknown" })
    && l.why === "tmux did not answer, so whether it runs is not known. Nothing is changed until tmux answers."; })()`);
check("new, trusted, untrusted: in words",
  `evLabel({ kind: "new" }) === "Created" && evLabel({ kind: "trusted" }) === "Folder trusted" && evLabel({ kind: "untrusted" }) === "Waiting for trust"`);
check("MCP server(s) not used, another prompt: in words, the servers named",
  `evLabel({ kind: "mcp", text: "Claude Code asked whether to use MCP server supa of ${HOME}/x/.mcp.json: not used (Esc)" }) === "MCP server supa not used"
    && evLabel({ kind: "mcp", text: "Claude Code asked whether to use MCP servers supa, beta of ${HOME}/x/.mcp.json: none used" }) === "MCP servers supa, beta not used"
    && evLabel({ kind: "mcp", text: "" }) === "MCP server not used" && evLabel({ kind: "prompt" }) === "Waiting at a prompt"`);

// act and Trust folder themselves, with a fetch that records what is sent and the confirm
// answered no, then yes; one after the other (chain): each sets the page's fetch and ask
run("var chain = Promise.resolve();");
const rec = `const sent = [], asked = [];
  fetch = async (u, o) => { if (o && o.body) sent.push(JSON.parse(o.body)); return { status: 200, json: async () => reply(sent[sent.length - 1]) }; };`;
check("trust folder: sent only after a yes to a warning that names the folder, with only which favorite", `(chain = chain.then(async () => {
  ${rec}
  const reply = () => ({ ok: true, out: "on" });
  ask = async (o) => { asked.push(o.text); return false; };
  const e = { id4: "0007", tmux: "fresh-0007", cwd: "${HOME}/fresh", state: "waiting for trust" };
  await trustFolder(e);
  const no = sent.length === 0 && asked.length === 1 && asked[0].includes(" files in ~/fresh, ");
  ask = async () => true;
  await trustFolder(e);
  return no && sent.length === 1 && JSON.stringify(sent[0]) === '{"action":"trust","id":"0007","tmux":"fresh-0007"}';
}))`);
check("new: memory short asks to force it, sent forced only after a yes", `(chain = chain.then(async () => {
  ${rec}
  const reply = (b) => b.force_memory ? { ok: true, out: "made" } : { ok: false, error: "memory: 5.0% available, a start needs 20%" };
  ask = async () => false;
  await act({ action: "new", name: "x", path: "~/x", rc: false });
  const no = sent.length === 1 && !("force_memory" in sent[0]);
  sent.length = 0;
  ask = async () => true;
  await act({ action: "new", name: "x", path: "~/x", rc: false });
  return no && sent.length === 2 && !("force_memory" in sent[0]) && sent[1].force_memory === true && sent[1].path === "~/x";
}))`);
// The memory card's swap pill and line (a 10 GB swap; memory known unless said).
const sw = (free, total = 10485760, mem = 33554432) => `JSON.stringify(swapView({ total_kb: ${mem}, swap_total_kb: ${total}, swap_free_kb: ${free} }))`;
check("swap: nearly full: amber, its sizes and share", `${sw(104858)} === JSON.stringify({ pill: "SWAP 9.9\u202f/\u202f10.0 GB (99%)", hi: true })`);
check("swap: a third used: grey", `${sw(6815744)} === JSON.stringify({ pill: "SWAP 3.5\u202f/\u202f10.0 GB (35%)", hi: false })`);
check("swap: used in MB, total in GB: both units", `JSON.parse(${sw(9961472)}).pill === "SWAP 512 MB\u202f/\u202f10.0 GB (5%)"`);
check("swap: amber from 90% (as shown, rounded): 90% and 89.5% amber, 89.4% grey", `JSON.parse(${sw(1048576)}).hi === true
  && JSON.parse(${sw(1101004)}).pill.endsWith(" (90%)") && JSON.parse(${sw(1101004)}).hi === true
  && JSON.parse(${sw(1111491)}).pill.endsWith(" (89%)") && JSON.parse(${sw(1111491)}).hi === false`);
check("swap: all free: 0 MB, 0%, grey", `${sw(10485760)} === JSON.stringify({ pill: "SWAP 0 MB\u202f/\u202f10.0 GB (0%)", hi: false })`);
check("swap: more free than its total (a bad reading): 0%, never below", `JSON.parse(${sw(20000000)}).pill === "SWAP 0 MB\u202f/\u202f10.0 GB (0%)"`);
check("swap: a total near the float limit: 100%, never Infinity", `JSON.parse(${sw(0, 1e308)}).pill.endsWith(" (100%)")`);
check("swap: free below 0 (a bad reading): all used, never over 100%", `JSON.parse(${sw(-1048576)}).pill === "SWAP 10.0\u202f/\u202f10.0 GB (100%)"`);
check("swap: a total below 0 or not a number (a bad reading): NO SWAP", `JSON.parse(${sw(0, -10485760)}).pill === "NO SWAP"
  && JSON.parse(${sw(0, '"10485760"')}).pill === "NO SWAP" && JSON.parse(${sw(0, "null")}).pill === "NO SWAP"`);
check("swap: none on the machine: NO SWAP, grey", `${sw(0, 0)} === JSON.stringify({ pill: "NO SWAP", hi: false })`);
check("swap: memory itself unknown: no pill", `swapView({ total_kb: 0, swap_total_kb: 0, swap_free_kb: 0 }) === null`);
// The memory card drawn (drawMem) on stand-in elements, one state after another: what the swap
// pill and the used/total by the label show after the last. Memory 26.0 of 32.0 GB used, a 10 GB swap.
const card = (...frees) => `(() => {
  const els = {}, saved = document;
  const mk = () => { const e = { hidden: false, textContent: "", style: {}, cls: new Set(), kids: [] };
    e.classList = { toggle: (c, on) => (on ? e.cls.add(c) : e.cls.delete(c)) };
    e.replaceChildren = (...k) => { e.kids = k; }; return e; };
  document = { getElementById: (id) => els[id] || (els[id] = mk()), createTextNode: (t) => ({ text: t }),
    createElement: (tag) => ({ tag }) };
  try {
    for (const f of ${JSON.stringify(frees)})
      drawMem({ favorites: [], on: 0, memory: f === "unknown" ? { total_kb: 0, avail_kb: 0, avail_pct: 0, warn: true }
        : { total_kb: 33554432, avail_kb: 6291456, avail_pct: 18.8, warn: false, swap_total_kb: f === "none" ? 0 : 10485760, swap_free_kb: f === "none" ? 0 : f } });
  } finally { document = saved; }
  const w = els.swap;
  return JSON.stringify({ hidden: w.hidden, pill: w.textContent, hi: w.cls.has("hi"), det: els["mem-det"].kids.map((k) => k.text ?? k.tag).join("|") });
})()`;
check("swap card: nearly full: the pill shown and amber; the details memory's only", `${card(104858)} === JSON.stringify({ hidden: false, pill: "SWAP 9.9\u202f/\u202f10.0 GB (99%)", hi: true,
  det: "26.0\u202f/\u202f32.0 GB" })`);
check("swap card: amber, then a third used: grey again", `JSON.parse(${card(104858, 6815744)}).hi === false && JSON.parse(${card(104858, 6815744)}).pill === "SWAP 3.5\u202f/\u202f10.0 GB (35%)"`);
check("swap card: no swap: NO SWAP", `${card("none")} === JSON.stringify({ hidden: false, pill: "NO SWAP", hi: false, det: "26.0\u202f/\u202f32.0 GB" })`);
check("swap card: shown, then memory unknown: the pill hidden", `JSON.parse(${card(104858, "unknown")}).hidden === true`);
check("memory card: high memory: the card's own class high, never warn (the notes' amber style); off again below", `(() => {
  const els = {}, saved = document;
  const mk = () => { const e = { hidden: false, textContent: "", style: {}, cls: new Set() };
    e.classList = { toggle: (c, on) => (on ? e.cls.add(c) : e.cls.delete(c)) }; e.replaceChildren = () => {}; return e; };
  document = { getElementById: (id) => els[id] || (els[id] = mk()), createTextNode: (t) => ({ text: t }) };
  const st = (warn) => ({ favorites: [], on: 0, memory: { total_kb: 33554432, avail_kb: 3355443, avail_pct: warn ? 10 : 20, warn,
    swap_total_kb: 0, swap_free_kb: 0 } });
  try {
    drawMem(st(true)); const high = [...els.mem.cls].join();
    drawMem(st(false)); return high === "high" && els.mem.cls.size === 0;
  } finally { document = saved; }
})()`);
// Memory in use by whom (useView), and the card's bar and key drawn from it (drawMem): you 5.0 GB,
// other users 12.1 GB (an estimate), the system 10.3 GB, of 32 GB.
const TOP = "{ mine_kb: 5242880, users_kb: 12687769, system_kb: 10800333 }";
check("memory by whom: you, other users (an estimate), the system: kB and the figure shown", `JSON.stringify(useView({ memory: { total_kb: 33554432, avail_kb: 4823450 }, top: ${TOP} }))
  === JSON.stringify([{ k: "you", name: "You", end: "", kb: 5242880, shown: "5.0 GB" },
    { k: "users", name: "Others", end: "", kb: 12687769, shown: "12.1 GB" },
    { k: "sys", name: "Sys", end: "tem", kb: 10800333, shown: "10.3 GB" }])`);
// shares: parts of what is in use, shown so they add up to it as shown (GB: x tenths of a GB in kB).
const GB = (x) => Math.round(x * 104857.6);
check("shares: rounded each on its own 5.1 + 12.4 + 10.1 = 27.6, not the 27.5 shown: the tenth over goes from the smallest fraction",
  `JSON.stringify(shares([${GB(50.8)}, ${GB(123.7)}, ${GB(100.5)}], ${GB(50.8) + GB(123.7) + GB(100.5)})) === JSON.stringify(["5.1 GB", "12.4 GB", "10.0 GB"])`);
check("shares: rounded each on its own 1.4 + 1.4 + 1.4 = 4.2, not the 4.1 shown: the tenth over goes from the smallest fraction",
  `JSON.stringify(shares([${GB(13.6)}, ${GB(13.7)}, ${GB(13.8)}], ${GB(13.6) + GB(13.7) + GB(13.8)})) === JSON.stringify(["1.3 GB", "1.4 GB", "1.4 GB"])`);
check("shares: under 1.0 GB in MB, 1.0 GB as GB, also 0.96 GB rounded up to 1.0 (not 983 MB)", `JSON.stringify(shares([524288, 1048576, 0], 1572864)) === JSON.stringify(["512 MB", "1.0 GB", "0 MB"])
  && JSON.stringify(shares([1006633], 1006633)) === JSON.stringify(["1.0 GB"])`);
check("shares: parts above what is in use, or far below it (a bad reading): each rounded on its own",
  `JSON.stringify(shares([${GB(30.6)}, ${GB(10.6)}], 1048576)) === JSON.stringify(["3.1 GB", "1.1 GB"])
  && JSON.stringify(shares([1048576, 1048576, 1048576], 4194304)) === JSON.stringify(["1.0 GB", "1.0 GB", "1.0 GB"])`);
check("memory by whom: unknown memory, an older server (others_kb), no top, or a figure below 0 or not a number: none", `useView({ memory: { total_kb: 0 }, top: ${TOP} }) === null
  && useView({ memory: { total_kb: 1 }, top: { mine_kb: 1, others_kb: 2 } }) === null && useView({ memory: { total_kb: 1 } }) === null
  && useView({ memory: { total_kb: 1 }, top: { mine_kb: 1, users_kb: -1, system_kb: 0 } }) === null
  && useView({ memory: { total_kb: 1 }, top: { mine_kb: 1, users_kb: "2", system_kb: 0 } }) === null`);
const byWhom = (...states) => `(() => {
  const els = {}, saved = document;
  const mk = () => { const e = { hidden: false, textContent: "", style: { setProperty() {} }, cls: new Set(), kids: [],
    get firstElementChild() { return this.kids[0]; } };
    e.classList = { toggle: (c, on) => (on ? e.cls.add(c) : e.cls.delete(c)) };
    e.replaceChildren = (...k) => { e.kids = k; }; return e; };
  document = { getElementById: (id) => els[id] || (els[id] = mk()), createTextNode: (t) => ({ text: t }),
    createElement: (tag) => { const e = { tag, kids: [] }; e.append = (c) => e.kids.push(c); return e; } };
  try {
    for (const top of [${states.join(", ")}])
      drawMem({ favorites: [], on: 0, top, memory: top === "unknown" ? { total_kb: 0, avail_kb: 0, avail_pct: 0, warn: false }
        : { total_kb: 33554432, avail_kb: 4823831, avail_pct: 14.4, warn: true, swap_total_kb: 0, swap_free_kb: 0 } });
  } finally { document = saved; }
  return JSON.stringify({ grow: ["you", "users", "sys"].map((k) => els["mem-" + k].style.flexGrow).join(),
    key: els["mem-key"].hidden ? null : els["mem-key"].kids.map((k) => k.className + ":" + k.kids.map((c) => c.text ?? "[" + c.textContent + "]").join("")).join("|"),
    pop: els["mem-top"].hidden });
})()`;
check("memory card: the bar's three shades as wide as each share; the key names each with its figure", `${byWhom(TOP)} === JSON.stringify({
  grow: "5242880,12687769,10800333", key: "k-you:You 5.0 GB|k-users:Others 12.1 GB|k-sys:Sys[tem] 10.3 GB|chev:", pop: true })`);
check("memory card: a share of 0 shows 0 MB; then memory unknown: no key, the used part one shade", `JSON.parse(${byWhom("{ mine_kb: 1048576, users_kb: 0, system_kb: 0 }")}).key
  === "k-you:You 1.0 GB|k-users:Others 0 MB|k-sys:Sys[tem] 0 MB|chev:"
  && ${byWhom(TOP, '"unknown"')} === JSON.stringify({ grow: "1,0,0", key: null, pop: true })`);
// fitKey on a stand-in key whose items sit at the given heights in full (System), all level when
// short (Sys): its last lower than its first (wrapped): short; level: not; and measured in full,
// whatever it was before (short already, still too long: short).
const fit = (tops, before) => `(() => {
  const saved = document, cls = new Set(${JSON.stringify(before)});
  const key = { hidden: false, children: ${JSON.stringify(tops)}.map((t) => ({ get offsetTop() { return cls.has("short") ? 0 : t; } })),
    classList: { remove: (c) => cls.delete(c), toggle: (c, on) => (on ? cls.add(c) : cls.delete(c)) } };
  document = { getElementById: () => key };
  try { fitKey(); } finally { document = saved; }
  return [...cls].join();
})()`;
check("memory key: wrapped: Sys; on one line: System; wrapped before, one line now: System again", `${fit([0, 0, 18], [])} === "short"
  && ${fit([0, 0, 0], [])} === "" && ${fit([0, 0, 0], ["short"])} === "" && ${fit([0, 0, 18], ["short"])} === "short"`);
// The memory card's pop-overs (setMemPop, toggleMemPop, placePops, memPopClick, memPopKey) on stand-ins:
// the card (its width), the key (a button: its place in the card, its first part You's place in it),
// the i (its place), the two pop-overs (their widths). Each run starts with none open; `steps` runs inside; returns `look` (JSON).
const popRig = (steps, look, geo = {}) => `(() => {
  const saved = document, g = Object.assign({ card: 358, keyLeft: 8, youLeft: 8, keyTop: 120, keyH: 20, popW: 240, parts: 4, keyHidden: false,
    iLeft: 168, noteW: 260 }, ${JSON.stringify(geo)});
  const attrs = (e) => { e.attr = {}; e.setAttribute = (k, v) => { e.attr[k] = v; }; e.getAttribute = (k) => (k in e.attr ? e.attr[k] : null);
    e.focused = 0; e.focus = () => { e.focused++; }; e.setAttribute("aria-expanded", "false"); return e; };
  const you = { offsetLeft: g.youLeft };
  const key = attrs({ hidden: g.keyHidden, offsetLeft: g.keyLeft, offsetTop: g.keyTop, offsetHeight: g.keyH, get firstElementChild() { return g.parts ? you : null; } });
  const about = attrs({ hidden: false, offsetLeft: g.iLeft, offsetWidth: 18, offsetTop: 0, offsetHeight: 18 });
  const pane = (w) => ({ hidden: true, offsetWidth: w, style: { vars: {}, setProperty(k, v) { this.vars[k] = v; } } });
  const pop = pane(g.popW), note = pane(g.noteW);
  const els = { mem: { clientWidth: g.card }, "mem-key": key, "mem-top": pop, "mem-about": about, "mem-note": note };
  document = { getElementById: (id) => els[id] };
  const inside = { closest: (s) => (s === "#mem-top, #mem-key, #mem-note, #mem-about" ? pop : null) }, elsewhere = { closest: () => null };
  try { memPop = null; ${steps}; return JSON.stringify(${look}); } finally { memPop = null; document = saved; }
})()`;
const popState = `{ open: memPop, top: !pop.hidden, note: !note.hidden, key: key.getAttribute("aria-expanded"), i: about.getAttribute("aria-expanded") }`;
const shut = { open: null, top: false, note: false, key: "false", i: "false" };
const topOpen = { open: "top", top: true, note: false, key: "true", i: "false" };
const noteOpen = { open: "note", top: false, note: true, key: "false", i: "true" };
const geoOf = (w) => `{ left: ${w}.style.left, top: ${w}.style.top, arrow: ${w}.style.vars["--arrow"] }`;
check("pop-over: the key opens your biggest processes under it (10px below: the arrow's tip clear of it), its arrow at You; a phone: kept 8px in from the card's left",
  `${popRig('toggleMemPop("top")', `[${popState}, ${geoOf("pop")}]`)} === JSON.stringify([${JSON.stringify(topOpen)}, { left: "8px", top: "150px", arrow: "12px" }])`);
check("pop-over: a computer (the key on the right): from 10px left of You, its arrow at You (You's place in the key added to the key's)",
  `${popRig('toggleMemPop("top")', geoOf("pop"), { card: 1053, keyLeft: 732 })} === JSON.stringify({ left: "730px", top: "150px", arrow: "14px" })`);
check("pop-over: never past the card's right edge (8px in), the arrow still at You",
  `${popRig('toggleMemPop("top")', geoOf("pop"), { card: 1053, keyLeft: 992 })} === JSON.stringify({ left: "805px", top: "150px", arrow: "199px" })`);
check("pop-over: the i opens the note under it, its arrow at the i's middle; a phone: moved left to stay in the card",
  `${popRig('toggleMemPop("note")', `[${popState}, ${geoOf("note")}]`)} === JSON.stringify([${JSON.stringify(noteOpen)}, { left: "90px", top: "28px", arrow: "81px" }])
  && ${popRig('toggleMemPop("note")', geoOf("note"), { card: 1053 })} === JSON.stringify({ left: "157px", top: "28px", arrow: "14px" })`);
check("pop-over: one at a time: the key while the note is open swaps them, and back; its own button again closes it",
  `${popRig('toggleMemPop("note"); toggleMemPop("top")', popState)} === JSON.stringify(${JSON.stringify(topOpen)})
  && ${popRig('toggleMemPop("top"); toggleMemPop("note")', popState)} === JSON.stringify(${JSON.stringify(noteOpen)})
  && ${popRig('toggleMemPop("top"); toggleMemPop("top")', popState)} === JSON.stringify(${JSON.stringify(shut)})
  && ${popRig('toggleMemPop("note"); toggleMemPop("note")', popState)} === JSON.stringify(${JSON.stringify(shut)})`);
check("pop-over: open, but no key (memory unknown) or a key with no parts: not shown",
  `JSON.parse(${popRig('toggleMemPop("top")', popState, { keyHidden: true })}).top === false && JSON.parse(${popRig('toggleMemPop("top")', popState, { parts: 0 })}).top === false`);
check("pop-over: a click inside one or on a button leaves it open; anywhere else closes it",
  `${popRig('toggleMemPop("top"); memPopClick({ target: inside })', popState)} === JSON.stringify(${JSON.stringify(topOpen)})
  && ${popRig('toggleMemPop("note"); memPopClick({ target: inside })', popState)} === JSON.stringify(${JSON.stringify(noteOpen)})
  && ${popRig('toggleMemPop("top"); memPopClick({ target: elsewhere })', popState)} === JSON.stringify(${JSON.stringify(shut)})
  && ${popRig('toggleMemPop("note"); memPopClick({ target: elsewhere })', popState)} === JSON.stringify(${JSON.stringify(shut)})`);
check("pop-over: a click with no target, or one without closest(): closes it, no error",
  `${popRig('toggleMemPop("top"); memPopClick({ target: null })', popState)} === JSON.stringify(${JSON.stringify(shut)})
  && ${popRig('toggleMemPop("top"); memPopClick({ target: {} })', popState)} === JSON.stringify(${JSON.stringify(shut)})`);
check("pop-over: a click while none is open changes nothing", `${popRig("memPopClick({ target: elsewhere })", popState)} === JSON.stringify(${JSON.stringify(shut)})`);
check("pop-over: Esc closes the open one, the keyboard back on its own button; another key, nothing; Esc with none open: the focus left alone",
  `${popRig('toggleMemPop("top"); memPopKey({ key: "Escape" })', `[${popState}, key.focused, about.focused]`)} === JSON.stringify([${JSON.stringify(shut)}, 1, 0])
  && ${popRig('toggleMemPop("note"); memPopKey({ key: "Escape" })', `[${popState}, key.focused, about.focused]`)} === JSON.stringify([${JSON.stringify(shut)}, 0, 1])
  && ${popRig('toggleMemPop("top"); memPopKey({ key: "Enter" })', popState)} === JSON.stringify(${JSON.stringify(topOpen)})
  && ${popRig('memPopKey({ key: "Escape" })', "[key.focused, about.focused]")} === "[0,0]"`);
check("pop-over: open stays open through a redraw; memory unknown hides it; known again shows it",
  `JSON.parse(${byWhom(TOP)}).pop === true && (() => { memPop = "top"; try { return JSON.parse(${byWhom(TOP)}).pop === false
    && JSON.parse(${byWhom(TOP, '"unknown"')}).pop === true && JSON.parse(${byWhom('"unknown"', TOP)}).pop === false; } finally { memPop = null; } })()`);
// The On header: the memory its favorites use (1.0 + 2.4 GB on; 5 GB off; 4 GB needing attention).
const ON = `[{ state: "on", status: "idle", claudes: 1, mem_kb: 1048576 }, { state: "on", status: "busy", claudes: 1, mem_kb: 2516582 },
  { state: "off", mem_kb: 5242880 }, { state: "duplicate", mem_kb: 4194304 }, { state: "on", status: "idle", claudes: 1 }]`;
check("on header: the memory of the favorites listed under On only (not Off, not Needs attention)", `onUse(${ON}) === "3.4 GB"`);
check("on header: none known, or none listed: no figure", `onUse([{ state: "on", status: "idle", claudes: 1 }]) === "" && onUse([]) === ""`);
check("on header: the Off chip: On lists nothing, so no figure", `(() => { filter = "off"; try { return onUse(${ON}) === ""; } finally { filter = "all"; } })()`);
check("on header: the figure after the count; no note, no third part", `(() => {
  const saved = document;
  document = { createElement: (tag) => { const e = { tag, kids: [] }; e.append = (c) => e.kids.push(c); return e; } };
  try {
    const h = section("On", "", [{}], "3.4 GB")[0], bare = section("On", "", [{}], "")[0];
    return h.textContent === "On" && h.kids.map((k) => k.className + ":" + k.textContent).join() === "pill :1,use:3.4 GB"
      && bare.kids.length === 1;
  } finally { document = saved; }
})()`);
// Settings: the start limit from the state (asc/memory.py's LIMITS, % used; anything else: 80).
check("start limit: each of 60 to 85 by 5 as saved; anything else (62, 90, 55, a string, 70.5, true, null, none, no state): 80", `(() => {
  const was = S, at = (v) => { S = { settings: { start_limit: v } }; return startLimit(); };
  try {
    return [60, 65, 70, 75, 80, 85].every((v) => at(v) === v) && [62, 90, 55, 0, -80, "70", 70.5, true, null, undefined].every((v) => at(v) === 80)
      && (S = { settings: null }, startLimit() === 80) && (S = {}, startLimit() === 80) && (S = null, startLimit() === 80);
  } finally { S = was; }
})()`);
check("start limit: boot's words name it", `(() => { const was = S; S = { settings: { start_limit: 65 } };
  try { return bootWhy("memory: watched for under 30 s") === "Starts once memory has stayed under 65% used for 30 s."; } finally { S = was; } })()`);
check("new session: Remote control on unless turned off", `newForm.rc === true`);
// Back (backFrom): the page at HERE, opened by another app; yes(ref) when it shows, giving that origin.
run(`var HERE = new URL("https://node.example.test:8585/"), APP = () => true;
var back = (ref, app = APP, depth = 2) => backFrom(ref, HERE, app, depth);`);
check("back: from another port of this host: its origin, its host:port (any path, query or login dropped)", `[
  ["https://node.example.test/", "https://node.example.test", "node.example.test"],
  ["https://node.example.test:8484/x/y?z=1#w", "https://node.example.test:8484", "node.example.test:8484"],
  ["https://" + ["u", "p"].join(":") + "@NODE.example.test:3002/", "https://node.example.test:3002", "node.example.test:3002"],  // a login in it: put together, as HOME
].every(([r, o, h]) => { const f = back(r); return !!f && f.origin === o && f.host === h && f.origin + "/" === o + "/"; })`);
check("back: none from this page itself (a reload), another host, a host that only starts or ends like it, another scheme", `[
  "https://node.example.test:8585/", "https://node.example.test:8585/x?y",
  "https://other.example.test:8484/", "https://node.example.test.evil.test:8484/", "https://evil-node.example.test/",
  "https://example.test:8484/", "http://node.example.test:8484/", "http://node.example.test:8585/",
].every((r) => back(r) === null)`);
check("back: none with no referrer or one that is no URL", `["", "not a url", "/x", "about:blank", null, undefined].every((r) => back(r) === null)`);
check("back: only in an installed app's window, with somewhere to go back to (2 entries: yes, 1: no)", `(() => { const R = "https://node.example.test:8484/";
  return back(R, () => false) === null && back(R, APP, 1) === null && back(R, APP, 0) === null && back(R, APP, 2) !== null && back(R, APP, 7) !== null; })()`);
check("back: the window is asked only once the referrer passes", `(() => { let n = 0; const c = () => (n++, true);
  return back("https://other.example.test/", c) === null && back("", c) === null && back("https://node.example.test:8585/", c) === null && n === 0
    && back("https://node.example.test/", c) !== null && n === 1; })()`);
// backLink on stand-ins: the document (its referrer and #back), location, history and the window's mode.
const backAt = (ref, o = {}) => `(() => {
  const saved = { document, location, history, window, navigator }, b = { hidden: true, href: "#", title: "", on: {} };
  b.addEventListener = (k, f) => { b.on[k] = f; };
  let backs = 0, asked = "";
  document = { referrer: ${JSON.stringify(ref)}, getElementById: (id) => (id === "back" ? b : null) };
  location = new URL("https://node.example.test:8585/");
  history = { length: ${o.depth ?? 2}, back: () => { backs++; } };
  window = { matchMedia: (q) => { asked = q; return { matches: ${JSON.stringify(o.matches ?? true)} }; } };
  navigator = { standalone: ${JSON.stringify(o.ios ?? false)} };
  try {
    backLink();
    let prevented = 0; if (b.on.click) b.on.click({ preventDefault: () => { prevented++; } });
    return { hidden: b.hidden, href: b.href, title: b.title, click: !!b.on.click, backs, prevented, asked };
  } finally { ({ document, location, history, window, navigator } = saved); }
})()`;
const R84 = "https://node.example.test:8484/apps?x=1";
check("back link: shown in the installed app: href that app's root, titled, a tap goes back once (the link itself not followed)",
  `(() => { const r = ${backAt(R84)}; return r.hidden === false && r.href === "https://node.example.test:8484/" && r.title === "Back to node.example.test:8484"
  && r.click && r.backs === 1 && r.prevented === 1 && r.asked === "(display-mode: standalone)"; })()`);
check("back link: an iPhone's home-screen app (navigator.standalone) too", `(() => { const r = ${backAt(R84, { matches: false, ios: true })}; return r.hidden === false && r.backs === 1; })()`);
check("back link: hidden, nothing wired, in a browser tab, a first page, from this page, from another host, or a mode that is only truthy",
  `[${backAt(R84, { matches: false })}, ${backAt(R84, { depth: 1 })}, ${backAt("https://node.example.test:8585/")},
    ${backAt("https://other.example.test:8484/")}, ${backAt("")}, ${backAt(R84, { matches: "yes", ios: 1 })}]
  .every((r) => r.hidden === true && r.href === "#" && r.title === "" && !r.click && r.backs === 0)`);
// The orange mark: drawn at the start limit (drawMem on stand-ins, as the memory card checks above).
const markAt = (v) => `(() => {
  const els = {}, saved = document, was = S;
  const mk = () => { const e = { hidden: false, textContent: "", style: { setProperty() {} }, kids: [], get firstElementChild() { return this.kids[0]; } };
    e.classList = { toggle() {} }; e.replaceChildren = (...k) => { e.kids = k; }; return e; };
  document = { getElementById: (id) => els[id] || (els[id] = mk()), createTextNode: (t) => ({ text: t }),
    createElement: (tag) => { const e = { tag, kids: [] }; e.append = (c) => e.kids.push(c); return e; } };
  S = { settings: { start_limit: ${JSON.stringify(v)} } };
  try { drawMem({ favorites: [], on: 0, top: ${TOP}, memory: { total_kb: 33554432, avail_kb: 4823831, avail_pct: 14.4, warn: true, swap_total_kb: 0, swap_free_kb: 0 } }); }
  finally { document = saved; S = was; }
  return els["mem-gate"].style.left;
})()`;
check("the orange mark at the start limit: 60, 85; a bad one at 80", `${markAt(60)} === "60%" && ${markAt(85)} === "85%" && ${markAt(90)} === "80%" && ${markAt("70")} === "80%"`);
// The Settings sheet on a small stand-in DOM: elements with classes, children, attributes,
// listeners and focus; closest() and querySelector(All) for the few selectors the sheet uses.
// settingsRig(body): the sheet opened (S.settings: start_limit 70, auto-restart off), then body
// runs (async) with lim (the slider), out (its figure), go(type) (an event on it), sent (what
// act sent) and reply (what the server answers); returns body's result. One at a time (chain).
run(`var settingsRig = (body) => (chain = chain.then(async () => {
  const saved = document, all = [], wasS = S, wasFetch = fetch;
  const has = (e, c) => (" " + e.className + " ").includes(" " + c + " ");
  const under = (e, ok) => { const out = []; const walk = (x) => { for (const k of x.kids) { if (ok(k)) out.push(k); walk(k); } }; walk(e); return out; };
  const match = (sel) => sel === "[role=switch]" ? (e) => e.attrs.role === "switch"
    : sel.includes(" ") ? ((c, tag) => (e) => e.tag === tag.toUpperCase() && (() => { for (let p = e.parent; p; p = p.parent) if (has(p, c)) return true; return false; })())(...sel.slice(1).split(" "))
    : (e) => has(e, sel.slice(1));
  const mk = (tag) => {
    const e = { tag: tag.toUpperCase(), kids: [], parent: null, attrs: {}, on: {}, style: {}, dataset: {}, textContent: "", className: "", disabled: false, isConnected: true };
    e.append = (...cs) => { for (const c of cs) { e.kids.push(c); c.parent = e; } };
    e.replaceChildren = (...cs) => { e.kids = []; e.append(...cs); };
    e.setAttribute = (k, v) => { e.attrs[k] = String(v); }; e.getAttribute = (k) => e.attrs[k] ?? null;
    e.addEventListener = (k, f) => { e.on[k] = f; };
    e.classList = { toggle: (c, on) => { const s = new Set(e.className.split(" ").filter(Boolean)); on ? s.add(c) : s.delete(c); e.className = [...s].join(" "); },
      contains: (c) => has(e, c) };
    e.closest = (sel) => { for (let x = e; x; x = x.parent) if (match(sel)(x)) return x; return null; };
    e.querySelector = (sel) => under(e, match(sel))[0] || null; e.querySelectorAll = (sel) => under(e, match(sel));
    e.focus = () => { doc.activeElement = e; };
    all.push(e); return e;
  };
  const body0 = mk("body"), sheet = mk("div"); sheet.id = "sheet";
  const doc = { activeElement: body0, body: body0, createElement: mk, createTextNode: (t) => ({ text: t }),
    getElementById: (id) => all.find((e) => e.id === id && (e === sheet || under(sheet, (k) => k === e).length)) || saved.getElementById(id) };
  document = doc;
  const sent = [], answer = { reply: { ok: true, out: "done" } };
  fetch = async (u, o) => { if (o && o.body) sent.push(JSON.parse(o.body)); return { status: 200, json: async () => answer.reply }; };
  S = { settings: { start_limit: 70, auto_restart: false } };
  sheetOf = { kind: "settings", key: "settings" }; sheetSig = ""; limDrag = false;
  try {
    renderSheet();
    const lim = $("lim"), out = lim.closest(".lim").querySelector(".v");
    const go = async (type, v) => { if (v !== undefined) lim.value = String(v); await lim.on[type](); };
    return await body({ lim, out, go, sent, answer, sheet, doc });
  } finally { document = saved; S = wasS; fetch = wasFetch; sheetOf = null; sheetSig = ""; limDrag = false; pending.delete("start_limit"); pending.delete("auto_restart"); }
}))`);
const rig = (code) => `settingsRig(async ({ lim, out, go, sent, answer, sheet, doc }) => { ${code} })`;
const labels = `lim.closest(".lim").querySelectorAll(".lbls span")`;
check("settings sheet: the slider at the saved value (70), its figure, 60 to 85 by 5, the label at 70 bold, default under 80 alone, said as 70%",
  rig(`const ls = ${labels};
  return lim.value === "70" && lim.min === "60" && lim.max === "85" && lim.step === "5" && lim.type === "range" && out.textContent === "70%"
    && ls.map((s) => [s.textContent, ...s.kids.map((k) => k.textContent)].join("/")).join() === "60,65,70,75,80/default,85"
    && ls.filter((s) => s.classList.contains("on")).map((s) => s.dataset.v).join() === "70"
    && ls.map((s) => s.style.left).join() === "0%,20%,40%,60%,80%,100%"
    && lim.getAttribute("aria-valuetext") === "70%" && lim.getAttribute("aria-label") === "Start limit, % of memory used";`));
check("settings sheet: moved: the figure, the bold label and what is said follow; nothing sent until let go; at 80 said as default",
  rig(`await go("input", 65); const a = out.textContent === "65%" && ${labels}.filter((s) => s.classList.contains("on")).map((s) => s.dataset.v).join() === "65"
    && lim.getAttribute("aria-valuetext") === "65%" && sent.length === 0;
  await go("input", 80); return a && lim.getAttribute("aria-valuetext") === "80% (default)" && out.textContent === "80%" && sent.length === 0;`));
check("settings sheet: let go on a new value: sent once, the value as a number; then it shows the saved one",
  rig(`await go("input", 85); const p = go("change"); const busy = lim.disabled === true; S = { settings: { start_limit: 85 } }; await p;
  return busy && JSON.stringify(sent) === '[{"action":"start_limit","id":"start_limit","pct":85}]' && lim.value === "85" && lim.disabled === false && out.textContent === "85%";`));
check("settings sheet: let go on the saved value (moved and back): nothing sent", rig(`await go("input", 75); await go("input", 70); await go("change"); return sent.length === 0 && lim.value === "70";`));
check("settings sheet: refused: back to the saved value",
  rig(`answer.reply = { ok: false, error: "start limit: no" }; await go("input", 60); await go("change"); return sent.length === 1 && lim.value === "70" && out.textContent === "70%";`));
check("settings sheet: a redraw while it is being moved leaves it; after let go it follows the state",
  rig(`await go("input", 85); S = { settings: { start_limit: 60 } }; syncSettings(); const kept = lim.value === "85" && out.textContent === "85%";
  limDrag = false; syncSettings(); return kept && lim.value === "60" && out.textContent === "60%";`));
check("settings sheet: while a save runs: disabled, and a redraw does not move it",
  rig(`pending.add("start_limit"); S = { settings: { start_limit: 60 } }; syncSettings(); const a = lim.disabled === true && lim.value === "70";
  pending.delete("start_limit"); syncSettings(); return a && lim.disabled === false && lim.value === "60";`));
check("settings sheet: a keyboard's save gives the focus back to the slider (disabled meanwhile, which drops it)",
  rig(`lim.focus(); doc.activeElement = doc.body; await go("input", 75); await go("change"); return doc.activeElement === lim;`));
check("settings sheet: the auto-restart switch follows the state, off while its save runs",
  rig(`const b = sheet.querySelector("[role=switch]"); const a = b.getAttribute("aria-checked") === "false";
  S = { settings: { auto_restart: true } }; syncSettings(); const c = b.getAttribute("aria-checked") === "true" && b.disabled === false;
  pending.add("auto_restart"); syncSettings(); return a && c && b.disabled === true;`));
check("settings sheet: drawn once; a redraw keeps the same slider", rig(`renderSheet(); return $("lim") === lim;`));
Promise.all(later).then(() => process.exit(fail ? 1 : 0));

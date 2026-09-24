# Idlewild 1.2.1

A process that had stopped running away stayed listed as running away.

An incident left the menu only when somebody clicked it, and since 1.1.1 its
duration counts live. So a process that finished its work at 23:32 was still in
the menu the next morning as "97% for 11.1 hours", long after it had exited. An
incident now leaves the menu as soon as its process exits or stays under the
threshold for a minute, and its notification goes with it, including one a Focus
mode was holding back overnight. Alerts left over from before an update are
cleared at launch.

## Always Force Quit

A runaway's menu has a new item, Always Force Quit. It asks how long the program
may run away first, from "as soon as it is caught" up to two hours, and, for an
app, whether to open it again afterwards. From then on Idlewild stops it without
asking and leaves a quiet notification saying so. Rules are tied to the
program's exact path, and are listed, and removed, in Settings → Exceptions.

## CPU History

A new window, CPU History, shows where the machine's CPU time went over the last
24 hours, 7 days or 30 days. Time runs round a clock face and each slice of it
bursts outwards, stacked by app. Hover a slice for its breakdown, or an app in
the list to pick it out of the chart. CPU time macOS will not let an app
attribute, such as root's processes and the kernel, is shown as System & kernel.
The record stays on this Mac, costs one dictionary update per busy process per
scan, and can be cleared from the window.

## Also

- A dip under the threshold for a scan or two no longer restarts the clock. One
  busy hour of Spotlight's knowledge daemon was reported four times in twenty
  minutes.
- A busy process with idle threads is no longer described as "threads look
  idle". Every thread is sampled whether it runs or not, so parked threads top
  the summary; Idlewild now looks past them to the code that is working and
  names it.
- A tool whose executable is named after its version, like Claude Code's
  `claude/versions/2.1.281`, now appears as claude.

# Idlewild 1.2.0

Idlewild updates itself.

It used to read a small JSON feed, say that a version existed and open the
download page — which left you dragging the app out of a disk image by hand, and
left the copy in Applications behind the one being worked on. Updates now arrive
in the app, through Sparkle, the framework the rest of the Mac apps distributed
outside the App Store use: it says a version is available, shows what changed,
downloads it, verifies it and relaunches.

The verification is the point. A disk image installs only if it carries an
Ed25519 signature made with a private key that exists only in the release job and
in the maintainer's keychain, *and* only if the app inside it is signed by the
same team as the one already running. Somebody who takes over the web server can
change the feed; they cannot make the app install anything.

A menu bar app is not allowed to steal focus, so a scheduled alert would appear
behind whatever you are doing. While an update is being handled, Idlewild rejoins
the Dock, badges its icon and posts a notification, then steps back into the
background.

## Also

- `CFBundleVersion` is now a real build number, `major*10000 + minor*100 +
  patch`. Sparkle compares that rather than the version string, so 1.1.1's build
  number of "1" could not have been followed by another release.
- The "Check for updates" switch in Settings now drives Sparkle's own setting
  instead of a second copy in our defaults. The app still contacts
  salamacchine.it once a day, and nothing installs without asking.
- The menu's "Download Idlewild …" item is gone; the update alert replaces it,
  and "Check for Updates…" asks on demand.

# Idlewild 1.1.1

A reported duration that had stopped counting.

An incident kept the duration it had when the alert fired, so a process still
running away twenty minutes later was still described as "5 min" in the menu —
the one number the whole feature exists to report. The duration is now read from
the moment the process crossed the threshold, so it keeps counting for as long as
the process keeps burning, and the menu is refreshed as each minute rolls over.

Memory incidents are unchanged. Theirs is the span of the history a leak was
fitted to: a measurement, not a clock.

Nothing else changed. Notifications are still one per incident, sent the moment
it is detected, and never re-posted.

# Idlewild 1.1.0

Idlewild now watches memory as well as CPU.

## Memory

Two things raise a memory alarm:

- **A leak.** Idlewild keeps a short history of each large process's physical
  footprint and fits a straight line through it. A leak is a line: positive
  slope, r² of at least 0.85, still climbing. Honest work is a staircase
  (loaded something, stopped) or a sawtooth (allocate, collect), and both fit a
  line badly. The alarm fires only when the process also holds more than a
  share of physical RAM (default 50%), has been climbing for the whole window
  (default 10 minutes), has grown by a meaningful amount relative to its own
  size, and at that rate would fill the rest of memory within a horizon
  (default 12 hours). The sentence you get carries the evidence: "memory
  climbing in a straight line for 25 min, usually a leak; at this rate it fills
  memory in 3.1 hours".
- **Memory pressure.** When the kernel reports that the machine is swapping,
  Idlewild names the single largest process that is not on the allowlist,
  whether or not it is growing. One process per pressure episode. This is
  push-based: the kernel wakes Idlewild, Idlewild does not poll for it.

Memory incidents offer Force Quit but not Pause It: a stopped process keeps
every byte, so pausing would leave you exactly where you were.

The data was already there. Every scan has always read each process's physical
footprint through `proc_pid_rusage`; 1.1.0 keeps a few points of history for
processes above a quarter of the share threshold and adds one `sysctl` per scan
for the pressure level. The self-test puts the per-scan cost up by about 10%.

Virtual size is deliberately ignored. On macOS every process maps the shared
cache and reserves address space, so even TextEdit reports hundreds of
gigabytes; the number carries no information.

## Settings

Settings is now four panes: **General** (cadence, notifications, login item,
updates, icon colour), **CPU** and **Memory** (a switch for each, both on by
default, and their thresholds), and **Exceptions**. About moved out of
Settings into the menu, where the action belongs.

## Also

- **Colour the flame** (General): an orange flame in place of the monochrome one
  when something is running away. Off by default, since most people keep the
  menu bar monochrome.
- The pid in an incident's submenu was formatted with the locale's grouping
  separator ("26.121"). It is now plain.
- The CLI takes `--memory-share PCT`, `--memory-sustain MIN`,
  `--memory-fill HOURS`, `--no-memory` and `--no-cpu`, and reports a
  `MEMORY HOG` block alongside `RUNAWAY PROCESS`.
- The end-to-end test now spawns a deliberate memory leak alongside the CPU
  burner and asserts that each is reported for the right reason, neither for
  the wrong one, and that the leak comes with a fill-time projection.

# Idlewild 1.0.0

A macOS menu bar app that notices when a process has been running away with a
CPU core, works out *why*, and offers to stop it.

Activity Monitor tells you what is busy once you go and look. Idlewild watches
for you and speaks up on its own.

## What it does

Watches for processes that hold above a threshold (default 80% of one core) for
a sustained period (default 5 minutes). When one does, it takes a stack sample,
classifies what the process is actually doing, and tells you in a sentence:

> a web page stuck throwing JavaScript errors in a loop
> garbage-collection thrash, usually a memory leak
> regular-expression backtracking
> a tight loop in the program's own code
> threads look idle — the CPU time may be elsewhere

That last one matters as much as the rest: it stops the app accusing a process
whose threads are merely parked.

Then it offers three things:

- **Force Quit** — `SIGKILL`.
- **Pause It** — `SIGSTOP`. Stops the burn without losing the process's state, so
  a stuck browser tab can be resumed.
- **Ignore** / **Always Allow** — dismiss once, or add it to the allowlist.

## Cost

A monitor must never become the thing it hunts.

| | CPU per hour | % of one core |
|---|---|---|
| **Idlewild** (120 s cadence, steady state) | **161 ms** | 0.0045% |
| A typical menu bar CPU meter, for scale | ~130,000 ms | 3.6% |

Measured on an M1 MacBook Air over a five-minute window with app startup
excluded. The About panel shows Idlewild's own consumption, so it stays
accountable to the standard it enforces.

## Apple Silicon only

That is deliberate, and it buys real signal. `rusage_info_v4` carries a per-QoS
breakdown of where a process spent its CPU time, which on Apple Silicon maps onto
physical cores: `user_interactive` work runs on P-cores at high clock, while
background work parks on E-cores and barely warms the die. Two processes at 100%
CPU can differ enormously in how much heat they produce, and Idlewild flags the
expensive kind with "this is what heats the machine".

## Requirements

- macOS 14 or later, Apple Silicon.
- Notifications are optional — the menu bar icon turns into a flame either way.

## Installing

Open the DMG and drag Idlewild to Applications. The app is signed with a
Developer ID certificate, notarized by Apple, and stapled, so it opens normally
with no right-click-to-open workaround.

Turn on **Launch at login** in Settings so it survives a reboot.

## Not on the Mac App Store

It cannot be. Under the App Sandbox, `proc_listpids`, `proc_pid_rusage` and
`kill()` all return EPERM — the app can neither find, measure, nor stop a runaway
process, and no App Store entitlement lifts that. This was tested; `Scripts/sandbox-probe.sh` reproduces it on any Mac.

## Known issues

- If notifications never prompt and the app does not appear in
  System Settings → Notifications, stale LaunchServices registrations are the
  likely cause. See `docs/DEVELOPMENT.md` for the fix.
- Browser tabs are reported as "Safari web page" without the page title.
  Getting the tab title requires private API; Activity Monitor uses it, we do
  not. Force-quitting the process makes Safari name the tab in its reload notice.

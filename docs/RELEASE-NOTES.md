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
Settings into the menu, since it is not a setting.

## Also

- **Colour the flame** (General): an orange flame instead of the monochrome one
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

Activity Monitor is a microscope, not a smoke alarm — you have to already suspect
something before you go look. Idlewild is the smoke alarm.

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
  a stuck browser tab can be resumed rather than lost.
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
process, and no App Store entitlement lifts that. This was tested rather than
assumed; `Scripts/sandbox-probe.sh` reproduces it on any Mac.

## Known issues

- If notifications never prompt and the app does not appear in
  System Settings → Notifications, stale LaunchServices registrations are the
  likely cause. See `docs/DEVELOPMENT.md` for the fix.
- Browser tabs are reported as "Safari web page" rather than by page title.
  Getting the tab title requires private API; Activity Monitor uses it, we do
  not. Force-quitting the process makes Safari name the tab in its reload notice.

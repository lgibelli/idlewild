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

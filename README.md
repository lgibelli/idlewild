# Idlewild

A macOS menu bar app that notices when a process has been running away with a
CPU core, works out *why*, and offers to stop it.

Activity Monitor is a microscope, not a smoke alarm — you have to already
suspect something before you go look. Idlewild is the smoke alarm.

```
──  Menu bar  ────────────────
 🔥  Runaway process detected

 Safari web page
 104% CPU for 9.8 hours,
 memory +11 MB/min
 a web page stuck throwing
 JavaScript errors in a loop

 [Force Quit] [Pause It] [Ignore]
──────────────────────────────
```

It was written after a Safari tab spent nine and a half hours pegging a core on
a fanless MacBook Air, entirely unnoticed.

## What makes it different

Most CPU monitors tell you *that* something is busy. Idlewild tells you **why**,
in a sentence. When a process crosses the threshold and holds, it takes a stack
sample and classifies it:

> a web page stuck throwing JavaScript errors in a loop
> garbage-collection thrash, usually a memory leak
> regular-expression backtracking
> threads look idle — the CPU time may be elsewhere

That last one matters as much as the others: it stops the app from accusing a
process whose threads are merely parked.

## The design constraint

**A monitor must never become the thing it hunts.**

Budget: under 1 second of CPU time per hour, measured rather than assumed, and
shown to you in the app's own About panel.

| | CPU per hour | % of one core |
|---|---|---|
| **Idlewild** (120 s cadence, steady state) | **161 ms** | 0.0045% |
| Same engine, headless CLI | 26 ms | 0.0007% |
| A typical menu bar CPU meter, for scale | ~130,000 ms | 3.6% |

Measured on an M1 MacBook Air over a 5-minute window with app startup excluded —
lifetime averages are dominated by AppKit initialisation and flatter the result.

Getting there took one real fix. `topProcesses` and `ownCPUms` were `@Published`
and changed on every scan, so SwiftUI invalidated the menu bar label each time
*even with the menu closed* — the exact always-redrawing menu bar item this app
was written to catch. Publishing only what the icon depends on took it from
680 ms/hour to 161 ms/hour.

Five decisions keep it there:

1. **The hot loop makes one syscall per process and nothing else.**
   `proc_pid_rusage()` only — no forking `ps`, no string formatting, no
   allocation (the pid buffer is reused). Executable paths cost a 4 KB string
   copy each, so they are resolved only for suspects, then cached.
2. **Timers carry 25% leeway,** letting the kernel coalesce our wakeup with
   others instead of pulling the SoC out of deep idle on our account. On fanless
   Apple Silicon, wakeups drive heat as much as cycles do.
3. **Adaptive cadence.** 120 s between scans when calm; 10 s only while a
   suspect is building. We hunt anomalies lasting minutes — polling at 1 Hz
   would buy nothing and cost 100×.
4. **The expensive path runs once per incident, never on a timer.** `sample(1)`
   suspends the target and walks its stacks.
5. **The menu bar icon changes only when state changes.** It never repaints on a
   schedule. A menu bar item that redraws every second is precisely the failure
   this app exists to catch.

## Apple Silicon only

That is a deliberate choice, and it buys real signal.

`rusage_info_v4` carries a per-QoS breakdown of where a process spent its CPU
time. On Apple Silicon that maps onto physical cores: `user_interactive` work
runs on P-cores at high clock, `background` work parks on E-cores and barely
warms the die. **Two processes at 100% CPU can differ enormously in how much
heat they produce,** and Idlewild can tell them apart — it flags the P-core kind
with "this is what heats the machine".

It also reads `ri_instructions` and `ri_cycles`. High IPC alongside pinned CPU
means a tight in-cache loop — a spin. Low IPC means memory stalls, which is more
often genuine work.

### The trap that comes with it

`proc_pid_rusage()` reports CPU time in **mach absolute time units, not
nanoseconds**. On Intel the timebase is 1/1 so the two coincide and the bug is
invisible. On Apple Silicon it is 125/3, making raw values read **41.67× too
low** — uncorrected, this watchdog would silently never fire, because nothing
would ever appear to cross an 80% threshold.

Always convert through `mach_timebase_info()`. Never hardcode the ratio; it is a
property of the machine, not of the architecture.

It was caught by cross-checking against `ps -r` and finding a suspiciously round
41.7× discrepancy. The same bug was simultaneously under-reporting Idlewild's
*own* cost by the same factor, so the first "well under budget" result was wrong
in both directions at once. Validate against an independent source.

## False positives are the whole product

A watchdog that interrupts a video export gets uninstalled the same day. What
keeps it quiet:

- **Allowlist** by executable path — compilers, ffmpeg, Docker, Final Cut,
  Logic, Blender, Resolve. Editable in Settings.
- **Sustain window** — 100% for 30 s is a build; for 9 hours it is a bug. This
  is the single most important setting.
- **Idle-thread guard** — a stack dominated by `__psynch_cvwait` means threads
  are parked, so Idlewild says so instead of accusing.
- **Memory growth** — RSS climbing steadily while CPU is pinned is strong
  evidence of a runaway loop rather than honest work.
- **Pause It** as an alternative to Force Quit — `SIGSTOP` stops the burn without
  losing the process's state, so a stuck tab can be resumed rather than lost.

Allowlist entries match whole path components, never raw substrings. This is not
fussiness: the first version matched substrings and shipped `"ld"` for the
linker, which silently allowlisted everything under `/var/folders/` — because
"folders" contains "ld". The end-to-end test caught it.

## Not on the Mac App Store

It cannot be. Under the App Sandbox, `proc_listpids`, `proc_pid_rusage` and
`kill()` all return EPERM — the app can neither find, measure, nor stop a
runaway process, and no App Store entitlement lifts that.

This was tested, not assumed: see [docs/APP-STORE.md](docs/APP-STORE.md), and
reproduce it yourself with `./Scripts/sandbox-probe.sh`.

Idlewild ships the way every comparable tool does — App Tamer, iStat Menus,
TG Pro — as a Developer ID signed, notarized, stapled app under the Hardened
Runtime.

## Building

```sh
./Scripts/build.sh                 # builds and adhoc-signs build/Idlewild.app
open build/Idlewild.app
./Scripts/e2e-test.sh              # spawns a real CPU burner and asserts on it
```

Release:

```sh
CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
NOTARY_PROFILE=idlewild-notary \
  ./Scripts/notarize.sh && ./Scripts/make-dmg.sh
```

There is no Xcode project — `swiftc` assembles the bundle directly, so the whole
build is reproducible from a shell.

## Layout

```
App/Engine/ProcessSampler.swift   kernel primitives, QoS and IPC
App/Engine/Detector.swift         detection state machine
App/Engine/Diagnoser.swift        stack sampling and classification
App/Engine/Monitor.swift          timer, cadence, coordination
App/UI/                           menu bar and settings
App/Support/                      preferences, signals, notifications
cli/main.swift                    headless CLI (scan / watch / selftest / cost)
Scripts/sandbox-probe.sh          reproduces the App Store findings
Scripts/e2e-test.sh               end-to-end test against a controlled burner
Scripts/make-icon.swift           generates the app icon
```

# Idlewild

A macOS menu bar app that notices when a process has been running away with a
CPU core or with the machine's memory, works out *why*, and offers to stop it.

Activity Monitor tells you what is busy once you go and look. Idlewild watches
for you and says something when a process has been holding a core, or growing,
for long enough to be a bug.

The menu bar icon is an ECG trace while everything is quiet, and a flame once
something is detected. Each detected process gets a submenu with the cause and
the actions worth taking. When it is the machine as a whole that is busy, with
no one process to blame, the menu says that instead of saying nothing.

It was written after a Safari tab spent nine and a half hours pegging a core on
a fanless MacBook Air, entirely unnoticed.

It keeps itself up to date, through Sparkle: an update installs only if its disk
image carries an Ed25519 signature made with a key that never leaves the release
job, and only if the app inside is signed by the same team as the one running.

## What makes it different

Most CPU monitors tell you *that* something is busy. Idlewild tells you **why**,
in a sentence. When a process crosses the threshold and holds, it takes a stack
sample and classifies it:

> a web page stuck throwing JavaScript errors in a loop
> garbage-collection thrash, usually a memory leak
> regular-expression backtracking
> a tight loop in the program's own code
> threads look idle — the CPU time may be elsewhere

That last one matters as much as the others: it stops the app from accusing a
process whose threads are merely parked.

Memory gets the same treatment. A leak is reported as a sentence with the
evidence in it:

> memory climbing in a straight line for 25 min, usually a leak; at this rate
> it fills memory in 3.1 hours

and when the Mac keeps running out of memory, it says so, and says where the
memory is:

> Swapping 4.1 MB/s for 10 min
> node — 7.7 GB in 21 processes
> java — 6.9 GB in 2 processes
> Safari & WebKit — 6.8 GB in 20 processes
> Google Chrome — 3.2 GB in 29 processes

That is a 16 GB Mac, and not one of those processes holds half of it. An app's
figure counts what of it has been compressed or swapped out, which is why
together they come to more than the Mac has.

## The design constraint

**A monitor must never become the thing it hunts.**

Budget: under 1 second of CPU time per hour. The figure below is measured, and
the app shows its own consumption in the About panel so you can check it.

| | CPU per hour | % of one core |
|---|---|---|
| **Idlewild** (120 s cadence, steady state) | **217 ms** | 0.006% |
| Same engine, headless CLI | 30 ms | 0.0008% |
| A typical menu bar CPU meter, for scale | ~130,000 ms | 3.6% |

Measured on an M1 MacBook Air over a ten-minute window with app startup
excluded — lifetime averages are dominated by AppKit initialisation and flatter
the result badly. The app figure predates memory watching; the CLI self-test
puts its per-scan cost about 10% higher, which is the one extra `sysctl` per
scan for the pressure level and the arithmetic on data it already had.

## False positives are the whole product

A watchdog that interrupts a video export gets uninstalled the same day. What
keeps it quiet:

- **Allowlist** by executable path — compilers, ffmpeg, Docker, Final Cut,
  Logic, Blender, Resolve. Editable in Settings.
- **Sustain window** — 100% for 30 s is a build; for 9 hours it is a bug. This
  is the single most important setting.
- **Idle-thread guard** — every thread is sampled whether it runs or not, so
  parked threads top a stack summary even in a busy process. Idlewild looks past
  the wait frames to the code that is working and names it; only when nothing
  is working does it say the CPU time may be elsewhere.
- **Dips are not calm** — a process has to stay under the threshold for a minute
  before its clock restarts, so one busy hour is one alert. An incident leaves
  the menu, and its notification is withdrawn, as soon as the process exits or
  calms down.
- **Memory growth** — RSS climbing steadily while CPU is pinned is strong
  strong evidence of a runaway loop.
- **Pause It** as an alternative to Force Quit — `SIGSTOP` stops the burn without
  losing the process's state, so a stuck tab can be resumed.

For memory the false-positive problem is worse, because Xcode, Docker's VM,
Lightroom, a virtual machine, or a browser with eighty tabs are all
legitimately huge. A plain "more than N GB" threshold would fire on every one of
them, so Idlewild does not use one. See the next section.

## Memory

The data has always been there: every scan reads each process's physical
footprint through the same `proc_pid_rusage` call that reads its CPU time.
Version 1.1 keeps a short, time-decimated history of it per process — only once
the process is large enough to matter, so the hundreds of small processes on a
Mac cost nothing — and fits a straight line through it.

A footprint is called a leak only when *all* of these hold:

| clause | what it removes |
|---|---|
| holds more than a share of physical RAM (default 10%) | small processes, which cost a history each to watch |
| the fit spans the sustain window (default 10 min) with at least six points | a burst, or a process that just started |
| positive slope, r² ≥ 0.85 | staircases (loaded a file, stopped) and sawtooths (allocate, collect) |
| grown by ≥ 32 MB *and* ≥ 5% of its own size | noise, which is proportional to size |
| latest sample within 2% of its peak | anything that has plateaued |
| at the fitted rate, fills the rest of memory within the horizon (default 12 h) | a 16 GB process gaining 5 MB/min on a 64 GB machine, which fills it in a week |

The share is relative to the machine because 6 GB is fine on a 64 GB Studio and
fatal on an 8 GB Air. It used to default to half, and a leak had done most of
its damage by the time it got there; what keeps honest growth from being called
a leak is the fit and the fill horizon, not the size. A drop of more than 10%
from the peak clears the history: a process that frees memory is not leaking it.

### Swapping

A Mac rarely runs out of memory because one process holds half of it. It runs
out because a browser, an editor, a build and a dozen other things each hold a
gigabyte or two. Earlier versions named a culprit under memory pressure only if
a single process held more than the share threshold, so on a 16 GB Mac swapping
twenty megabytes a second, with no one process above 8 GB, they said nothing.

What the machine feels when memory runs out is swap traffic: every page read
back from swap is a stall in whatever needed it, and every page written out is
the working set not fitting. So that is what Idlewild measures, from the
system's own running totals, one Mach call a scan. How much swap is in use says
little on its own; pages nobody touches can sit there for a week at no cost.

When the traffic has averaged 4 MB/s or more over ten minutes, which is 2.4 GB
moved, Idlewild posts a warning, lights the icon, and lists the apps holding the
most memory: every process of an app added up under the name CPU History uses,
whatever its size. A Mac with room to spare moves almost nothing; the one this
was measured on, out of room, moved 21 MB/s for half an hour. Waking an app that
was swapped out overnight reads a gigabyte or two back once, and ten minutes of
averaging leaves that out. The warning lasts until the average falls under
2 MB/s, so a machine sitting on the line is one warning, not twenty, and Ignore
Until It Stops puts the icon out without pretending the swapping has stopped.

The memory pressure dispatch source still lets the kernel wake Idlewild when
pressure rises, so the figures are fresh when it matters; there is no polling.

Memory incidents offer Force Quit but not Pause It: a stopped process keeps
every byte, so pausing would leave you exactly where you were.

Virtual size is deliberately ignored. On macOS every process maps the shared
cache and reserves address space, so even TextEdit reports hundreds of
gigabytes; the number carries no information. File descriptors are not
monitored either: a process that leaks them breaks itself and nothing else,
which is a job for a debugger.

Allowlist entries match whole path components, never raw substrings. This is not
fussiness: the first version matched substrings and shipped `"ld"` for the
linker, which silently allowlisted everything under `/var/folders/` — because
"folders" contains "ld". The end-to-end test caught it.

## Always Force Quit

Some programs have only one right answer. A runaway's menu offers Always Force
Quit, which asks how long the program may run away first and, for an app,
whether to open it again afterwards. After that Idlewild stops it without asking
and posts a silent notification saying it did. Only an app can honestly be
reopened; anything else was started by something with its own arguments and
environment, and the prompt says so instead of guessing. Rules match the exact
executable path and are listed in Settings → Exceptions.

## A busy machine with nothing running away

Every core can be in use with no process running away. A dozen programs each
well under the threshold add up; so do a build and a test run made of hundreds
of processes that live a few seconds each. None of them is an incident, and
Idlewild raises none. But a menu that says "Nothing running away" and stops
there, on a machine like that, reads as "all is well".

So once the machine has averaged half its cores in use over the sustain window,
the menu says so, and where the CPU is going:

> Nothing running away, but the CPU is busy
>
> 6.2 of 8 cores in use for 12 min
> node — 2.3 cores
> System & short-lived processes — 2.1 cores
> Google Chrome — 0.6 cores

That is all it does. There is no notification and no flame, because there is no
process to stop and a build is supposed to do this; which is also why the bar
can sit at half rather than at full. Load that comes in bursts pins every core
for half a minute at a time and averages two thirds. The lines go once the
average falls under four tenths of the cores, and with CPU watching switched
off they never appear.

It costs no measurement. The machine's busy time and each app's share of it are
what CPU History is already handed on every scan; this keeps the last sustain
window of them. "System & short-lived processes" is what the history draws as
System & kernel, named here for what most of it is on a machine that is
building: programs that started and finished between two scans.

## Where the CPU went

CPU History draws the last 24 hours, 7 days or 30 days as a radial bar chart:
time runs clockwise round a ring, and each slice is a spoke stacked by app. The
radius is area-true: each segment's area is proportional to the
CPU time it stands for.

The data costs nothing extra to collect. Each scan already computes every
process's CPU delta for detection; filing it under the app it belongs to is a
dictionary update. Whole-machine time comes from the host tick counters, and the
difference between the two is shown as System & kernel: a third of the processes
on a Mac belong to root or system users, and `proc_pid_rusage` will not measure
them for an unprivileged app. Five-minute slices are kept for a day and hourly
ones for a month, in a binary property list under Application Support.

## Not on the Mac App Store

It cannot be. Under the App Sandbox, `proc_listpids`, `proc_pid_rusage` and
`kill()` all return EPERM — the app can neither find, measure, nor stop a
runaway process, and no App Store entitlement lifts that.

This was tested: see [docs/APP-STORE.md](docs/APP-STORE.md), and
reproduce it yourself with `./Scripts/sandbox-probe.sh`.

Idlewild ships the way every comparable tool does — App Tamer, iStat Menus,
TG Pro — as a Developer ID signed, notarized, stapled app under the Hardened
Runtime.

## Building

```sh
./Scripts/build.sh                 # builds and signs build/Idlewild.app
open build/Idlewild.app
./Scripts/e2e-test.sh              # spawns a real CPU burner and a real leak, asserts on both
```

The first build downloads Sparkle — pinned by version and SHA-256 — into
`build/vendor/`, and links it into the bundle. There is no package manager
involved: the framework comes from Sparkle's own release tarball, which is what
its documentation points a build without Xcode at.

Release — copy `release.env.example` to `release.env`, fill in your Team ID and
notarytool profile, then:

```sh
./Scripts/notarize.sh     # build, sign, submit, staple, verify with spctl
./Scripts/make-dmg.sh     # package, sign and notarize the DMG itself
./Scripts/make-appcast.sh # sign the DMG into the appcast Sparkle reads
```

`build.sh` signs with the Developer ID Application identity for your `TEAM_ID`
when one is in the keychain, and falls back to adhoc otherwise — printing the
designated requirement either way, since that is what macOS uses as the app's
identity for permissions. Adhoc builds also disable library validation, or the
Sparkle framework could not be loaded at all.

There is no Xcode project — `swiftc` assembles the bundle directly, so the whole
build is reproducible from a shell.

## Layout

```
App/Engine/ProcessSampler.swift   kernel primitives, QoS and IPC
App/Engine/Detector.swift         detection state machine
App/Engine/Diagnoser.swift        stack sampling and classification
App/Engine/Monitor.swift          timer, cadence, coordination
App/Engine/History.swift          CPU history: slices, tiers, storage
App/UI/                           menu bar and settings
App/Support/                      preferences, signals, notifications, updates
cli/main.swift                    headless CLI (scan / watch / selftest / cost)
Scripts/sandbox-probe.sh          reproduces the App Store findings
Scripts/e2e-test.sh               end-to-end test against a controlled burner
Scripts/make-appcast.sh           signs a disk image into the update feed
Scripts/make-icon.swift           generates the app icon
```

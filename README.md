# Idlewild

A macOS menu bar app that notices when a process has been running away with a
CPU core or with the machine's memory, works out *why*, and offers to stop it.

Activity Monitor is a microscope, not a smoke alarm — you have to already
suspect something before you go look. Idlewild is the smoke alarm.

```
 🔥  ← the menu bar icon, once something is wrong

 ┌─────────────────────────────────────────────┐
 │ 1 process running away                      │
 ├─────────────────────────────────────────────┤
 │ Safari web page — 104% for 9.8 hours     ▸  │──┐
 ├─────────────────────────────────────────────┤  │
 │ Pause Monitoring                            │  │
 │ Settings…                                ⌘, │  │
 ├─────────────────────────────────────────────┤  │
 │ Quit Idlewild                            ⌘Q │  │
 └─────────────────────────────────────────────┘  │
                                                  ▼
                    ┌──────────────────────────────────────────┐
                    │ Force Quit                               │
                    │ Pause It                                 │
                    ├──────────────────────────────────────────┤
                    │ Ignore This Time                         │
                    │ Always Allow com.apple.WebKit.WebContent │
                    ├──────────────────────────────────────────┤
                    │ A web page stuck throwing JavaScript     │
                    │ errors in a loop                         │
                    │ On performance cores — this is what      │
                    │ heats the machine                        │
                    │ Memory growing 11 MB/min                 │
                    │ pid 84183                                │
                    └──────────────────────────────────────────┘
```

The icon is an ECG trace when all is well and a flame when it is not. It is a
real `NSMenu`, not a custom panel, and it shows no live statistics — see the
note on cost below.

It was written after a Safari tab spent nine and a half hours pegging a core on
a fanless MacBook Air, entirely unnoticed.

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

and when the kernel reports memory pressure, Idlewild names the single largest
process that is not on the allowlist, whether or not it is growing.

## The design constraint

**A monitor must never become the thing it hunts.**

Budget: under 1 second of CPU time per hour, measured rather than assumed, and
shown to you in the app's own About panel.

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

### Measure on a quiet machine

Measurements taken while building, installing or relaunching apps are worthless.
Every install broadcasts LaunchServices and workspace notifications that each
running app's run loop must service, so the thing being measured absorbs the
cost of the measuring. Two consecutive runs here reported 1449 and 3343 ms/hour
— and the *second*, with an optimisation reverted, was worse than the first.

That contradiction is the signal. When reverting a change appears to make things
worse, the experiment is broken before the code is. On a quiet machine the same
build measures 217 ms/hour.

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
| holds more than a share of physical RAM (default 50%) | everything that is not hurting anyone yet |
| the fit spans the sustain window (default 10 min) with at least six points | a burst, or a process that just started |
| positive slope, r² ≥ 0.85 | staircases (loaded a file, stopped) and sawtooths (allocate, collect) |
| grown by ≥ 32 MB *and* ≥ 5% of its own size | noise, which is proportional to size |
| latest sample within 2% of its peak | anything that has plateaued |
| at the fitted rate, fills the rest of memory within the horizon (default 12 h) | a 16 GB process gaining 5 MB/min on a 64 GB machine, which fills it in a week |

The share is relative to the machine because 6 GB is fine on a 64 GB Studio and
fatal on an 8 GB Air. A drop of more than 10% from the peak clears the history:
a process that frees memory is not leaking it.

Separately, a memory pressure dispatch source lets the kernel wake Idlewild
when the machine starts swapping — there is no polling — and it names the
largest process above the share threshold that is not allowlisted. One process
per pressure episode; the next may be named only once pressure has cleared or
that one has gone.

Memory incidents offer Force Quit but not Pause It: a stopped process keeps
every byte, so pausing would leave you exactly where you were.

Virtual size is deliberately ignored. On macOS every process maps the shared
cache and reserves address space, so even TextEdit reports hundreds of
gigabytes; the number carries no information. File descriptors are not
monitored either: a process that leaks them breaks itself and nothing else,
which is a job for a debugger rather than a smoke alarm.

Allowlist entries match whole path components, never raw substrings. This is not
fussiness: the first version matched substrings and shipped `"ld"` for the
linker, which silently allowlisted everything under `/var/folders/` — because
"folders" contains "ld". The end-to-end test caught it.

## Updates

Idlewild checks `https://www.salamacchine.it/apps/idlewild/latest.json` once a
day and, when a newer version exists, adds a download item to the menu. It never
downloads or installs anything by itself.

That restraint is the point. An updater that fetches and executes code turns its
feed into a way to run arbitrary software on every user's machine, which is why
Sparkle requires the feed to be signed with an EdDSA key and the public half
embedded in the app. Getting that wrong (an empty `SUPublicEDKey`, say) silently
disables the check while everything still appears to work. Idlewild reports the
version and opens the download page, so macOS applies Gatekeeper to whatever the
user chooses to run, exactly as it would for a fresh download.

The check sends an HTTP request to salamacchine.it, which necessarily reveals the
user's IP address and the app version in the User-Agent. Settings has a toggle to
turn it off, and the wording there says what it contacts.

Feed format:

```json
{
  "version": "1.0.1",
  "url": "https://www.salamacchine.it/apps/idlewild/",
  "notes": "What changed.",
  "minimumSystemVersion": "14.0"
}
```

The proposed URL is checked before anything is opened: it must be `https` on
salamacchine.it or github.com, so a mistyped or tampered feed cannot send anyone
somewhere unexpected. Version comparison is numeric per component, so 1.10.0
correctly sorts above 1.9.0.

## Verifying a download

Every release is built, signed and notarized by GitHub Actions, and carries a
SLSA build-provenance attestation recorded in Sigstore's public transparency
log. That binds the exact bytes you downloaded to the commit and workflow that
produced them:

```sh
gh attestation verify Idlewild-1.0.0.dmg --repo lgibelli/idlewild
```

The workflow itself is in `.github/workflows/release-signed.yml`, so you can read
what it did rather than take anyone's word for it.

macOS checks the rest for you before the app ever opens, but you can check by
hand too:

```sh
spctl -a -vvv -t execute /Applications/Idlewild.app   # notarized and accepted
xcrun stapler validate /Applications/Idlewild.app     # ticket stapled: works offline
codesign -dv --verbose=4 /Applications/Idlewild.app   # the signing identity
```

What the attestation proves is provenance, not reproducibility: it shows the
binary came from this source, not that rebuilding this source yields identical
bytes. Signing embeds timestamps, so a byte-identical rebuild is not achievable
on macOS without considerable effort.

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
./Scripts/e2e-test.sh              # spawns a real CPU burner and a real leak, asserts on both
```

Release — copy `release.env.example` to `release.env`, fill in your Team ID and
notarytool profile, then:

```sh
./Scripts/notarize.sh     # build, sign, submit, staple, verify with spctl
./Scripts/make-dmg.sh     # package, sign and notarize the DMG itself
```

`build.sh` signs with the Developer ID Application identity for your `TEAM_ID`
when one is in the keychain, and falls back to adhoc otherwise — printing the
designated requirement either way, since that is what macOS uses as the app's
identity for permissions.

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

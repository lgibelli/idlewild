# Idlewild

A macOS menu bar app that notices when a process has been running away with a
CPU core, works out *why*, and offers to stop it.

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

## The design constraint

**A monitor must never become the thing it hunts.**

Budget: under 1 second of CPU time per hour, measured rather than assumed, and
shown to you in the app's own About panel.

| | CPU per hour | % of one core |
|---|---|---|
| **Idlewild** (120 s cadence, steady state) | **217 ms** | 0.006% |
| Same engine, headless CLI | 26 ms | 0.0007% |
| A typical menu bar CPU meter, for scale | ~130,000 ms | 3.6% |

Measured on an M1 MacBook Air over a ten-minute window with app startup
excluded — lifetime averages are dominated by AppKit initialisation and flatter
the result badly.

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

Allowlist entries match whole path components, never raw substrings. This is not
fussiness: the first version matched substrings and shipped `"ld"` for the
linker, which silently allowlisted everything under `/var/folders/` — because
"folders" contains "ld". The end-to-end test caught it.

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
./Scripts/e2e-test.sh              # spawns a real CPU burner and asserts on it
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

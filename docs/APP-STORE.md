# Why Idlewild is not on the Mac App Store

Short version: the App Sandbox is mandatory for App Store distribution, and it
blocks every operation this app is built on. There is no way to engineer around it — there is no entitlement Apple grants App Store apps that lifts
it.

## The test

A minimal binary calling the four APIs Idlewild depends on, compiled twice:
once unsandboxed, once inside a real signed `.app` bundle carrying
`com.apple.security.app-sandbox`. Both run as the same user against the same
target process.

> A bare CLI binary with the sandbox entitlement simply traps at launch — it has
> no bundle from which to initialise a container. The sandboxed case must be a
> genuine `.app` bundle or the result is meaningless.

## The result

| call | unsandboxed | sandboxed (App Store conditions) |
|---|---|---|
| `proc_listpids` | OK — 601 pids | **BLOCKED** (EPERM) |
| `proc_pid_rusage` | OK | **BLOCKED** (EPERM) |
| `proc_pidpath` | OK | OK |
| `kill(pid, 0)` | OK | **BLOCKED** (EPERM) |
| spawn `sample(1)` | OK | ran, exit 255 |

Sandboxed, Idlewild cannot enumerate processes, cannot measure their CPU time,
cannot inspect why one is spinning, and cannot stop it. `proc_pidpath` survives,
which means a sandboxed build could name a process it already knew about — and
nothing else.

## What this means in practice

Every comparable tool ships outside the App Store for exactly this reason:
App Tamer, iStat Menus, TG Pro, Sensei, CleanMyMac. The distribution path for
this category is Developer ID + notarization, which is what `Scripts/notarize.sh`
implements.

Users still get the security guarantees that matter: the app is signed with a
verifiable Apple-issued identity, notarized (Apple has scanned it for malware),
stapled so verification works offline, and running under the Hardened Runtime.
The only thing missing is App Store *listing* — not trust.

## Reproducing

The probe is preserved at `Scripts/sandbox-probe.sh`. Run it on any Mac to
confirm the behaviour still holds on a newer macOS.

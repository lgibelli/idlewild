# Development notes

## "Notifications are not allowed for this application"

**Cause: stale LaunchServices registrations left by repeated rebuilds.** The
authorization prompt is never shown, and the app never appears in
System Settings → Notifications, so there is no way to enable it by hand either.

During development this bundle got rebuilt and reinstalled a dozen times, and
LaunchServices accumulated three registrations for one bundle identifier — one
of them pointing at `build/dmg/Idlewild.app`, a staging path `make-dmg.sh`
deletes after building the disk image. `usernoted` then cannot resolve the
bundle:

```
usernoted: _LSBundleCopyOrCheckNode: cached node not found,
           _LSBundleCreateNode for bundleID 3168 returned -43     # fnfErr
```

It still accepts the connection and `setNotificationCategories` succeeds, which
makes this misleading — only authorization fails.

### The fix

```sh
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# What does LaunchServices think exists?
$LSR -dump | grep -i idlewild | grep -iE '^path' | sort -u

# Drop stale and development copies, keep the installed one
$LSR -u /path/to/any/deleted/Idlewild.app
$LSR -f /Applications/Idlewild.app

killall usernoted        # respawns immediately
```

Then relaunch. The app now appears in System Settings → Notifications and can be
enabled there; `requestAuthorization` returns `granted=true` afterwards.

`make-dmg.sh` now unregisters its staging copy before deleting it, so the
condition should not recur.

### What it was not

Diagnosed by elimination, and three plausible-sounding hypotheses were wrong
before the right one. A twenty-line app that does nothing but call
`requestAuthorization` failed identically, which cleared any Idlewild bug. Then:

| hypothesis | test | result |
|---|---|---|
| adhoc signing (unstable cdhash) | signed with Developer ID | still failed |
| not notarized | notarized + stapled, Gatekeeper accepted | still failed |
| MDM restriction | `profiles status -type enrollment` | not enrolled |
| `LSUIElement` agent app | built a regular Dock app | still failed |
| cached denial | inspected `com.apple.ncprefs` | no record existed |
| a Focus mode | parsed `DoNotDisturb/DB/Assertions.json` | zero active assertions |
| display mirroring / sleep DND | `system_profiler SPDisplaysDataType` | `Mirror: Off` |

The lesson: ask the daemon. `log stream
--predicate 'process == "usernoted"'` produced the `-43` in one shot, after an
hour of hypotheses produced nothing.

Note that Focus modes are still worth checking — an active Focus genuinely
suppresses delivery — but it does not cause this error. To check:

```sh
plutil -p ~/Library/DoNotDisturb/DB/Assertions.json
```

An assertion is active only if no invalidation record shares its
`assertionUUID`; simply counting records will mislead you.

## Notifications do not persist across adhoc-signed builds

This is a separate, genuine caveat — it is *not* the cause of the error above,
though it is easy to conflate the two.

`./Scripts/build.sh` signs with the adhoc identity (`-`) by default, which makes
the app's designated requirement a hash of the binary itself:

```
$ codesign -d -r- build/Idlewild.app
# designated => cdhash H"562d38db64d671dcc7a3adfeaae0f8923e8538f3"
```

Every rebuild changes that hash, so macOS treats each build as a **different
application**. Notification authorization — and TCC permissions generally — are
keyed to that identity, so they cannot persist: the app may never appear in
Notification Center settings, and `UNUserNotificationCenter` may report
authorization as not granted no matter how many times you accept the prompt.

Signing with a Developer ID certificate produces
a stable requirement based on identifier and team ID:

```
designated => identifier "it.salamacchine.idlewild" and anchor apple generic and ...
```

which survives rebuilds and lets authorization stick.

To test notifications properly:

```sh
CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)" ./Scripts/build.sh
cp -R build/Idlewild.app /Applications/
open /Applications/Idlewild.app
```

Verify what actually happened:

```sh
log stream --predicate 'subsystem == "it.salamacchine.idlewild"'
```

That reports every detection, the result of `requestAuthorization`, and whether
each notification was posted or rejected.

## Verifying behaviour from outside the process

Do not infer app behaviour from broad `log show` predicates — Notification
Center chatter mentioning an app is not evidence that the app posted anything.
Two checks that are actually definitive:

```sh
# What Idlewild itself reports
log show --last 10m --predicate 'subsystem == "it.salamacchine.idlewild"' --style compact

# What macOS actually delivered
sqlite3 "file:$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db?immutable=1" \
  "select a.identifier, datetime(r.delivered_date+978307200,'unixepoch','localtime')
   from record r join app a on r.app_id=a.app_id
   where a.identifier like '%idlewild%' order by r.delivered_date desc limit 5;"
```

## Measuring cost correctly

Use a delta over a window with startup excluded. Lifetime averages are dominated
by AppKit initialisation (roughly 250 ms) and flatter the result badly on a
short run; a 90-second sample reported 16 s/hour where the true steady state was
161 ms/hour.

`./Scripts/e2e-test.sh` spawns a controlled CPU burner and asserts that Idlewild
finds that specific process — never just "some runaway", since the machine may
have genuine ones of its own.

## Shell traps in the release scripts

Two bugs of the same family bit this pipeline, both turning a *successful*
operation into a silent failure. Worth knowing before editing the scripts.

**`pipefail` + `grep -q`.** `grep -q` exits the moment it matches, the upstream
command takes SIGPIPE and returns non-zero, and `set -o pipefail` propagates
that. The hardened-runtime check therefore failed *precisely when it passed*.
Capture output first, then test it:

```sh
CS_FLAGS=$(codesign -d --verbose=2 "$APP" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)' || true)
case "$CS_FLAGS" in *runtime*) ;; *) die "..." ;; esac
```

**`set -e` and the tail of an `&&` chain.** A failing command at the *end* of an
`&&` chain is not exempt from `set -e`. `lsregister -u` exits non-zero when
there is nothing to unregister, so this aborted the whole script:

```sh
[ -n "$phys" ] && [ "$phys" != "$p" ] && "$LSREGISTER" -u "$phys"   # WRONG
```

`make-dmg.sh` stopped straight after creating the disk image — never signing,
notarizing or verifying it — and still exited 0, leaving an unsigned DMG that
looked finished. Guard every such call:

```sh
if [ -n "$phys" ] && [ "$phys" != "$p" ]; then
  "$LSREGISTER" -u "$phys" 2>/dev/null || true
fi
```

The general lesson: an exit status of 0 is not evidence that the work happened.
`make-dmg.sh` now verifies its own output by mounting the finished image and
assessing the app inside it, which is the check that would have caught this.

## Unregister before the path disappears

`lsregister -u` cannot reliably drop a record for a path that is already gone,
and LaunchServices stores the *physical* path — `/tmp` and `/var` are symlinks
to `/private/tmp` and `/private/var`, so the logical form does not match. Both
mistakes were made here at once, and the "fix" changed nothing until each was
corrected. Unregister while the path still exists, and try the resolved form too.

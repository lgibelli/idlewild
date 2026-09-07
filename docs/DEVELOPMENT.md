# Development notes

## "Notifications are not allowed for this application"

If `requestAuthorization` fails with this error, check whether a **Focus mode is
active** before looking anywhere else. It is the first thing to rule out, and it
is easy to misattribute to signing.

This was diagnosed by elimination. A twenty-line app that does nothing but call
`requestAuthorization` failed identically, which ruled out any Idlewild bug.
Then, one at a time:

| hypothesis | test | result |
|---|---|---|
| adhoc signing | signed with Developer ID | still failed |
| not notarized | notarized + stapled, Gatekeeper accepted | still failed |
| MDM restriction | `profiles status -type enrollment` | not enrolled |
| `LSUIElement` agent app | built a regular Dock app | still failed |
| cached denial | inspected `com.apple.ncprefs` | no record existed |

What remained was a scheduled **Sleep Focus** asserted in
`~/Library/DoNotDisturb/DB/Assertions.json`. Other apps had delivered
notifications normally earlier the same day, before it began.

To check the current state:

```sh
plutil -p ~/Library/DoNotDisturb/DB/Assertions.json | grep -A3 assertionDetails
```

`assertionDetailsUserVisibleEndDate` is a Mac absolute time — add 978307200 for
a Unix timestamp.

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

This is not a bug in Idlewild. Signing with a Developer ID certificate produces
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

Verify what actually happened rather than guessing from the outside:

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

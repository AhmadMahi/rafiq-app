# The Mac app's suites

```sh
mac/tests/run.sh            # the headless checks, which is what CI runs
mac/tests/run.sh --panels   # those, and then measure every settings page
```

Needs `swiftc` and `python3`. No hardware, no Bluetooth, no watch.

## The one rule

**Nothing here retypes app logic.** `extract.py` pulls `find`, `note`,
`rescan`, `stopScanning`, `resweep` and `attach` out of
`Sources/RobotLink.swift` verbatim, by brace balance from the signature,
and `run.sh` splices them into `linktest/harness.swift` at its
`#include_real_bodies` marker. A passing test is a pass against the code
that ships.

So the suite cannot quietly drift: rename one of those functions and
extraction fails loudly, instead of the tests carrying on green against a
stale copy of it.

When the suite needs something the app does not expose, the shim goes in
the harness, never in `Sources/`:

- `resweep()` is `private` where it ships. The harness reaches it through
  `tick()` rather than widening the real declaration to suit a test.
- `knownIds` is a computed property over `UserDefaults`, and the
  extractor takes functions only, so the harness restates it over a fake
  defaults store. The suite must never write to this Mac's real defaults.
- `startSweep()` schedules a `Timer` that needs a run loop the suite is
  not giving it, so `extract.py` points it at `startSweepStub()` and the
  harness drives `resweep()` directly instead.
- The real `didConnect` arrives on CoreBluetooth's queue and hops to the
  main actor. The fake is already on the main actor, so it uses
  `MainActor.assumeIsolated`: a `Task` would not run until the
  synchronous test had already returned, which once had four checks
  reading the state from before the connect completed.

## What is here

| | |
|---|---|
| `extract.py` | pulls the six shipped bodies into `linktest/real.swift.inc` |
| `linktest/harness.swift` | a fake CoreBluetooth around them, and the nine-part suite |
| `../rowcheck.py` | adds up what each settings row's content asks for and complains when nothing is left for the label |
| `../panelcheck.sh` | measures every page for real, against a settings domain of its own |

`real.swift.inc` and `linktest/run/` are generated and not committed.

## Why `--panels` is not the default

`panelcheck.sh` builds the app and lays every page out off screen. That
needs a window server, so it does not run on a CI runner and it does not
run from a shell with no GUI session - it aborts before the first page.
It is the better check when it can run, which is why it is wired into the
same runner rather than left somewhere else to be forgotten.

`rowcheck.py` is the cheap stand-in that works headless, and it is the
one CI runs.

# Contributing

## Building

Command Line Tools are enough. Xcode is not required.

```bash
git clone https://github.com/Kernel-Hunter/boost.git
cd boost
./Scripts/build.sh          # builds and installs /Applications/Boost.app
./Scripts/build.sh --no-install
```

## Tests

```bash
./Scripts/test.sh
```

Use the script rather than `swift test`. Two flags are needed that plain
`swift test` doesn't pass, and both fail with errors that blame the wrong
thing:

- `--disable-sandbox` — SPM sandboxes macro plugins; swift-testing is
  macro-based and the sandbox denies what it needs.
- `-plugin-path` — `libTestingMacros.dylib` lives in a `testing/`
  subdirectory of the toolchain's plugin folder, which isn't on the default
  search path.

Without them, every `@Test` fails to expand with *"plugin for module
'TestingMacros' not found"*, which reads like a missing dependency and isn't
one. The script works this out for you.

## What to test

Not everything here is testable — half the app is talking to the kernel and to
AppKit. What is testable, and where bugs actually hide:

- **The guard list.** Adding an entry means adding a test. A mistake here
  takes a user's desktop down.
- **Pure functions** — process-tree walking, widget name tidying, byte
  formatting, memory thresholds.
- **Anything that has broken before.** Every fix gets the test that would
  have caught it, named after the symptom. `descendants()` hanging on a cyclic
  parent chain is the model: the test was written first, hung, and found the
  bug.

Don't write tests that assert what the current code happens to do. Assert what
it must do, and say why in the test name.

## House style

The code is commented for someone reading it in a year with no memory of the
decisions. That means:

- **Comments say why, not what.** `// Parent first, so it cannot spawn a child
  that escapes the freeze` earns its place. `// loop over pids` does not.
- **Non-obvious choices get a sentence.** Why the Accessibility API and not
  `CGWindowList`. Why `sysctl` and not `ps`. Why the path cache is keyed on
  start time. Someone will otherwise "simplify" these back into the bug they
  were fixing.
- **Name the failure a guard prevents,** so nobody removes it as dead weight.

Swift 6 language mode, strict concurrency on. It has already caught two real
data races here — don't silence it with `nonisolated(unsafe)`; work out which
actor the state belongs to.

## Commits

Explain the problem, not the diff. A reader can see what changed; what they
cannot see is what was wrong, why the obvious fix was wrong, and what
convinced you it works now.

## Before opening a PR

```bash
./Scripts/test.sh && ./Scripts/build.sh --no-install
```

Then actually run it. Close something, pause something, resume it. A green
suite does not tell you whether the app still works — most of this codebase is
not covered by it.

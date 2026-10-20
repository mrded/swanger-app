---
worth: later
where: Tests/SwangerCoreTests/Model/ValidatorAgreementTests.swift:15
added: 2026-10-20
---
# ValidatorAgreementTests takes about 25 seconds

It checks ~6,000 schemas against 25 samples each, which is most of `swift test`'s run time (the other
~120 tests take under a second). Options: build it in release in CI, cut the cases that never disagree,
or run it as a separate target or behind an environment variable.

Unknown: whether the time actually hurts — local runs and CI minutes. If nobody notices, drop it.

# Contributing

Thank you for considering a contribution.

## Before you start

For anything beyond a small fix, open an issue first and describe what you intend to change. That avoids work that cannot be merged.

## Setting up

`doc/development.md` describes the development environment, the directory layout and the design decisions. Follow section 2 to get a running instance.

## Running the tests

```bash
scripts/run_tests.sh                  # backend and frontend
scripts/run_tests.sh --e2e            # plus the browser tests
```

All tests have to pass before a change is proposed.

Three test cases compare the source against internal project documents that are not part of this repository. **In a clone they skip and state why.** A skipped run is expected and is not a failure. Everything else has to be green.

## Expectations for a change

**Every change comes with a test.** A fix comes with a case that fails without it. A new behaviour comes with a case that describes it.

**Verify a new test by mutation.** Damage the code the test covers and check that the test fails. A test that stays green over damaged code does not test what it claims to.

**Test the effect, not the setting.** Comparing a configured value says nothing about whether that value has any effect.

**The source is written in English.** Identifiers, comments, test names, routes and stored domain values. Two automated checks enforce this.

**Console output is English.** Interface text belongs in the language files under `frontend/src/locales/`, never in a component.

**The rendering pipeline exists twice**, in Ruby and in JavaScript, and both have to produce identical output. They are checked against the shared vectors in `tests/vectors/rendering.json`. A divergence between them blocks a change.

## Licence of contributions

Contributions are accepted under the MIT licence of this project. By opening a pull request you agree that your contribution may be published under those terms.

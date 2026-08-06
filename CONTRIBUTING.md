# Contributing to Karst

Thank you for helping build Karst. Contributions should preserve its central principle: observation comes before recommendation.

## Getting started

1. Fork and clone the repository.
2. Run `bin/setup` to install dependencies.
3. Run `bin/test` to execute all checks.

## Coding style

- Follow the project RuboCop configuration and idiomatic Ruby conventions.
- Keep units small, composable, and explicit.
- Do not make claims about application behavior without captured evidence.
- Keep Rails integration boundaries narrow and avoid unnecessary coupling.
- Add documentation for public APIs and decisions that are not self-evident.

## Commits

Write focused commits with imperative, descriptive subjects. A commit should contain one coherent change and should leave the test suite passing. Explain important motivation in the commit body rather than restating the diff.

## Pull requests

Open a focused pull request and complete the template. Describe the runtime behavior affected, the evidence supporting the change, and any compatibility implications. Keep unrelated refactoring separate and update documentation and the changelog when appropriate.

Draft pull requests are welcome for early design feedback. Please discuss broad architectural changes in an issue before investing in an implementation.

## Tests

Every behavior change requires tests at the narrowest useful level. Bug fixes should include a regression test. Tests must be deterministic and must not depend on network services. Run `bin/test` before submitting a pull request; CI runs RSpec and RuboCop.

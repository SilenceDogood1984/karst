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

### Rails compatibility

Karst's compatibility harness currently covers Rails 6.1 on Ruby 2.7, Rails 7.0 and 7.1 on Ruby 3.2, and Rails 7.2 and 8.0 on Ruby 3.3. The Rails 6.1 / Ruby 2.7 job is blocking, the same as every other row: Karst claims that floor because CI proves it, not the other way around. See [ARCHITECTURE.md](ARCHITECTURE.md#compatibility-policy) for how optional features (currently: the page-local badge) degrade on that floor instead of raising.

The repository uses version-specific Gemfiles under `gemfiles/`. This keeps each dependency set explicit and lets Bundler and CI use their standard `BUNDLE_GEMFILE` behavior without an additional dependency-management tool. Matrix lockfiles are intentionally not committed: compatibility CI resolves the current dependency set allowed by each Rails line, so it detects dependency-resolution regressions instead of only testing a previously locked snapshot. To run one target locally:

```sh
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile EXPECTED_RAILS_VERSION=7.2 \
  bundle exec rspec spec/integration
```

Run every compatibility target with `bin/test-rails`. To add a Rails version, add a version-specific Gemfile, add it to `bin/test-rails`, and add the matching Rails/Ruby entry to the `rails-integration` matrix in `.github/workflows/ci.yml`. Choose a Ruby version on which that Rails release installs and runs, and keep linting out of the compatibility matrix.

# Releasing Karst

The exact sequence for publishing a version of the `karst` gem. Every step
starts from `origin/main` and ends with a fresh install from RubyGems. The
examples use 0.4.0; substitute the version in `lib/karst/version.rb`.

Notes that decide the order:

- Karst is the first gem to reach `v0.4.0`: no `v*` tag exists for any earlier
  release (0.1.0 and 0.2.0 were pushed without tags), and 0.3.0 was never
  published. The changelog's `[0.4.0]` link targets the `v0.4.0` tag, so the
  tag must exist on GitHub before the gem is pushed.
- The gemspec's own metadata links point at `main`, not a tag.
- Tags are never moved. If something fails after `git push origin v0.4.0`,
  fix it with a new patch version.

## 0. One-time prerequisites

- RubyGems account that owns `karst`, with MFA enabled (`rubygems_mfa_required`
  is set, so `gem push` asks for an OTP).
- Push access to `SilenceDogood1984/karst`.
- Ruby >= 3.3 locally.

## 1. Update from main

```sh
git fetch origin --tags
git switch main
git pull --ff-only origin main
```

## 2. Verify a clean tree and the release identity

```sh
git status --porcelain            # must print nothing
git rev-parse HEAD origin/main    # the two SHAs must match
ruby -r./lib/karst/version -e 'puts Karst::VERSION'   # 0.4.0
grep -n '^## \[0.4.0\]' CHANGELOG.md
git ls-remote --tags origin v0.4.0                    # must print nothing
```

CI on that exact commit must be green (GitHub, Actions tab, `main`).

## 3. Run the final test suite

```sh
bundle install
bundle exec rubocop
bundle exec rspec --exclude-pattern "spec/integration/**/*_spec.rb"
bin/test-rails                      # Rails 6.1 - 8.1 integration matrix (needs Rubies that install each)
# MCP range ends, as CI's mcp-compatibility job runs them:
EXC="spec/integration/{devise_golden_path_integration_spec.rb,multi_devise_golden_path_integration_spec.rb,custom_auth_golden_path_integration_spec.rb,rails8_auth_golden_path_integration_spec.rb}"
BUNDLE_GEMFILE=$PWD/gemfiles/mcp_1_5_0.gemfile EXPECTED_MCP_REQUIREMENT="= 1.5.0"  EXPECTED_RAILS_VERSION=8.0 bundle exec rspec spec/mcp spec/integration --exclude-pattern "$EXC"
BUNDLE_GEMFILE=$PWD/gemfiles/mcp_1_6.gemfile   EXPECTED_MCP_REQUIREMENT="~> 1.6.0" EXPECTED_RAILS_VERSION=8.0 bundle exec rspec spec/mcp spec/integration --exclude-pattern "$EXC"
bin/package-acceptance-test         # builds the gem, installs it, drives a fresh Rails app
```

`bin/test-rails` needs `bundle install` per Gemfile and the Ruby versions in
the CI matrix; if only one Ruby is available locally, the GitHub Actions
matrix for this commit is the authority for the others.

## 4. Build the gem

```sh
gem build karst.gemspec           # writes karst-0.4.0.gem in the repo root
```

## 5. Inspect the gem

```sh
tar -xOf karst-0.4.0.gem data.tar.gz | tar tz | grep -vE '^lib/'
# expect: ARCHITECTURE.md CHANGELOG.md CODE_OF_CONDUCT.md CONTRIBUTING.md LICENSE
#         README.md SECURITY.md and docs/{advanced-configuration,rails8-authentication,request-reproduction}.md
gem spec karst-0.4.0.gem dependencies   # runtime: activesupport (>= 6.1, < 9) only; mcp is development-only
gem spec karst-0.4.0.gem required_ruby_version metadata licenses
```

`spec/`, `benchmark/`, `gemfiles/`, `bin/`, `RELEASING.md` and
`LAUNCH_QUALIFICATION_REPORT.md` do not belong in the package.

## 6. Create the release tag

```sh
git tag -a v0.4.0 -m "Karst 0.4.0" "$(git rev-parse HEAD)"
git show --stat v0.4.0 | head
```

## 7. Push the tag

```sh
git push origin v0.4.0
curl -sI https://github.com/SilenceDogood1984/karst/releases/tag/v0.4.0 | head -1   # 200
```

## 8. Push the gem to RubyGems

Irreversible: a pushed version can be yanked but its number can never be
reused.

```sh
gem push karst-0.4.0.gem          # prompts for the MFA OTP
```

## 9. Verify the RubyGems version

```sh
gem list -r '^karst$' --all | head -2
curl -s https://rubygems.org/api/v1/versions/karst.json | ruby -rjson -e 'puts JSON.parse(STDIN.read).first.values_at("number","licenses")'
```

## 10. Install into a fresh temporary bundle

```sh
T="$(mktemp -d)" && cd "$T"
export GEM_HOME="$T/gems" GEM_PATH="$T/gems" PATH="$T/gems/bin:$PATH"
unset BUNDLE_GEMFILE RAILS_VERSION
gem install rails -v '~> 8.0' --no-document
rails new app --skip-git --skip-test --skip-system-test --skip-action-mailbox \
  --skip-action-mailer --skip-active-storage --skip-jbuilder --skip-kamal \
  --skip-thruster --skip-ci --skip-solid --skip-bundle --quiet
cd app
printf '\ngem "json", "< 3"\ngem "karst", "0.4.0", group: :development\ngem "mcp", ">= 1.5.0", "< 1.7"\n' >> Gemfile
bundle install        # must resolve karst 0.4.0 from rubygems.org
```

(`json < 3` is a pin for a Rails 8.0 session-cookie incompatibility,
unrelated to this gem.) Retry `bundle install` if RubyGems has not indexed the
version yet.

## 11. Post-publication smoke test

Still in `$T/app`:

```sh
bundle exec ruby -e 'require "karst"; puts Karst::VERSION'            # 0.4.0
bin/rails karst:verify GET / --anonymous                              # "verified usable", exit 0
bin/rails karst:reproduce GET / --json | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("schema_version")'
bin/rails generate karst:install                                      # then delete the generated files
{ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 2; } | timeout 15 bin/rails karst:mcp | grep -o '"name":"[a-z_]*"' | sort -u
# expect: reproduce_request, verify_access (plus the server name)
```

## If something fails

- Before step 8: only the tag is public. Delete it
  (`git push origin :refs/tags/v0.4.0`, `git tag -d v0.4.0`), fix on a branch,
  merge, and restart from step 1.
- After step 8: `gem yank karst -v 0.4.0` withdraws the version; ship the fix
  as 0.4.1.

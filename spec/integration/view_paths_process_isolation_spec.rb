# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../support/test_application"
require_relative "target_scoped_evidence_spec"

# Regression for a real incident: assigning a controller's view_paths to an
# ActionView::FixtureResolver (as target_scoped_evidence_spec.rb originally
# did) registers that resolver's #path -- which FixtureResolver hardcodes to
# "" -- into a process-wide Rails registry that ActionView::CacheExpiry reads
# on every full-middleware-stack request dispatched in *any* spec, for the
# rest of the process. ActiveSupport::FileUpdateChecker then joins "" into a
# glob with File.join("", "**", "*"), which is "/**/*": an unbounded
# recursive scan of the entire filesystem root, repeated on every subsequent
# full-stack request. On Rails <= 7.0 (where that registry is the flat
# ActionView::ViewPaths.all_view_paths) this made
# spec/integration/access_sweep_spec.rb:368 -- an ordinary test that dispatches
# through KarstTestApplication's full stack -- take minutes instead of
# milliseconds, and occasionally raise Errno::ENOENT out of File.mtime when a
# system file the scan reached (e.g. a systemd unit symlink) was removed by
# the OS mid-scan. Rails >= 7.1's ActionView::PathRegistry only auto-registers
# String/Pathname view paths into its watched-resolver set, so a resolver
# *object* passed directly never reaches it there -- masking this exact
# mistake on newer Rails while still making it on 6.1/7.0.
#
# require_relative "target_scoped_evidence_spec" above is deliberate, not
# incidental: it guarantees KarstEvidenceFixtureController's view_paths
# assignment has already run by the time these examples exercise
# ActionView::CacheExpiry, regardless of load/example order or RSpec's
# --seed -- this regression does not depend on running the rest of the
# integration suite, or on any particular seed, to reproduce the failure.
RSpec.describe "a controller's view_paths never poisons the process-wide view-path registry" do
  # The exact mechanism, exercised through the one stable public API it hangs
  # off across every supported Rails version: ActionView::CacheExpiry (its
  # class name and method names differ release to release -- 6.1's
  # CacheExpiry#clear_cache_if_necessary, 7.0's
  # CacheExpiry::ViewModificationWatcher#execute_if_updated, 7.1+'s
  # CacheExpiry::ViewReloader rebuilding eagerly in #initialize) is registered
  # via app.executor.to_run (see ActionView::Railtie's after_initialize), so
  # executor.wrap -- the same wrapper every full-stack request runs inside --
  # runs it regardless of which internal shape the current Rails version
  # uses. Timeout.timeout bounds the worst case at 5s instead of letting a
  # real regression hang this suite for minutes the way it hung
  # spec/integration/access_sweep_spec.rb in CI.
  it "keeps a full request-executor wrap fast, never scanning from the filesystem root" do
    expect { Timeout.timeout(5) { KarstTestApplication.executor.wrap { 1 } } }.not_to raise_error
  end

  # Belt and suspenders for the exact mechanism, on the Rails series where it
  # actually applies (<= 7.0's flat ActionView::ViewPaths.all_view_paths;
  # Rails >= 7.1 replaced it with ActionView::PathRegistry, which this
  # mistake never reaches at all -- see the file comment above).
  it "never lets a blank resolver path reach ActionView::ViewPaths.all_view_paths, where present" do
    unless ActionView::ViewPaths.respond_to?(:all_view_paths)
      skip "ActionView::ViewPaths.all_view_paths is Rails <= 7.0 only"
    end

    paths = ActionView::ViewPaths.all_view_paths.flat_map(&:paths).grep(ActionView::FileSystemResolver).map(&:path)

    expect(paths).not_to include("", nil)
  end
end

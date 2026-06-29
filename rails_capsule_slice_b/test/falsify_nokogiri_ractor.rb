# frozen_string_literal: true

# Falsification #11: the REAL nokogiri C-extension (libxml2-backed) is Ractor-UNSAFE when invoked
# off the main Ractor, and works on the owner (main Ractor) as the fallback path.
#
# This is the empirical justification for AdversarialService#native_capability_result's owner-only
# routing: a native capability cannot be isolated into a non-main Ractor, so the capsule must run it
# on the owner. We do NOT use the stand-in `native_parse`; we drive the actual gem.
#
# We do NOT modify any shared file. This test needs no DB, but DATABASE_URL may be set by the runner.
Warning[:experimental] = false

require "nokogiri"
require "minitest/autorun"

class FalsifyNokogiriRactor < Minitest::Test
  XML = "<r><a/></r>"

  # The C-extension off the main Ractor must NOT silently succeed. We attempt a real parse inside a
  # non-main Ractor and force the result back to the parent with Ractor#value, so any exception raised
  # inside the worker is re-raised here (Ractor propagates the worker's exception via #value).
  def test_nokogiri_raises_in_non_main_ractor
    raised_class = nil   # the actual exception the worker raised (unwrapped from the transport)
    wrapper_class = nil  # the class Ractor#value re-raised in the parent
    returned     = nil

    # The worker's internal thread reports its (expected) exception on stderr via report_on_exception.
    # Silence only that noise; the exception itself still propagates through Ractor#value below.
    prev_report = Thread.report_on_exception
    Thread.report_on_exception = false
    begin
      r = Ractor.new do
        require "nokogiri"                       # ensure the C-ext is loaded inside the worker too
        Nokogiri::XML("<r><a/></r>").root.name   # exercises libxml2 off the main Ractor
      end
      returned = r.value                          # re-raises the worker's exception in this Ractor
    rescue => e
      wrapper_class = e.class
      # Ractor#value transports a worker exception as Ractor::RemoteError whose #cause is the real
      # one raised inside the worker. Unwrap to observe the genuine underlying class.
      raised_class = (e.is_a?(Ractor::RemoteError) && e.cause) ? e.cause.class : e.class
    ensure
      Thread.report_on_exception = prev_report
    end

    # It must NOT have returned the parsed value: a clean "r" would falsify the unsafety claim.
    refute_equal "r", returned,
                 "Nokogiri C-ext unexpectedly SUCCEEDED off the main Ractor (returned #{returned.inspect}); " \
                 "the owner-only routing would be unjustified."
    refute_nil raised_class, "expected the non-main-Ractor parse to RAISE, but nothing was raised"

    # Record/observe the EXACT class. Ruby 4.0.5 exposes Ractor::UnsafeError for C-ext that flag
    # themselves Ractor-unsafe; if that constant exists we assert against it, otherwise we assert
    # against whatever isolation/unsafe error the runtime actually produced.
    if defined?(Ractor::UnsafeError)
      assert_equal Ractor::UnsafeError, raised_class,
                   "observed #{raised_class} rather than Ractor::UnsafeError"
    else
      # No UnsafeError in this runtime: assert it is a real Ractor isolation/unsafe failure.
      assert_includes %w[Ractor::IsolationError Ractor::Error], raised_class.name,
                      "observed #{raised_class}, not a recognized Ractor isolation/unsafe failure"
    end

    # Echo the observed classes to stdout so the raw run records them verbatim for the reviewer.
    puts "OBSERVED_WRAPPER_EXCEPTION=#{wrapper_class}"
    puts "OBSERVED_NON_MAIN_RACTOR_EXCEPTION=#{raised_class}"
  end

  # The owner fallback: on the main Ractor (the owner), the very same C-ext call succeeds.
  def test_nokogiri_runs_on_the_owner_main_ractor
    assert_equal Ractor.main, Ractor.current, "this test must execute on the owner (main Ractor)"
    assert_equal "r", Nokogiri::XML(XML).root.name,
                 "Nokogiri must parse correctly on the owner (main Ractor)"
  end
end

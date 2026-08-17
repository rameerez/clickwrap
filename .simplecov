# frozen_string_literal: true

# SimpleCov configuration file (auto-loaded before test suite)
# This keeps test_helper.rb clean and follows best practices.
# Coherent with the rest of the gem ecosystem (sessions, chats, moderate, …).

SimpleCov.start do
  # Use SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Don't count the test suite itself toward coverage
  add_filter "/test/"

  # Generators run as a separate process against a real host app; their
  # coverage comes from Rails::Generators::TestCase runs, which this in-process
  # instrumentation does not observe.
  add_filter "/lib/generators/"
  add_filter "/lib/clickwrap/version.rb"

  # Track Ruby files in both the library and the engine's app directory, since
  # the models carry real behavior (projections, digests, disposition) rather
  # than being thin ActiveRecord shells.
  track_files "{lib,app}/**/*.rb"

  # Enable branch coverage for more detailed metrics
  enable_coverage :branch

  # Minimum coverage thresholds to prevent coverage REGRESSION. These are a
  # floor, not a target: raise them as coverage grows. A gem whose whole value
  # is evidence that stays verifiable for years cannot afford untested
  # canonicalization, lifecycle, or disposition paths.
  #
  # Set just under the actuals, which is the only setting that makes a floor do
  # anything: at 80/60 against 91/72 actual, a change could delete a third of
  # the branch coverage in this gem and still pass.
  #
  # The gap that remains is deliberate, and it is not slack for new untested
  # code — it is the CI matrix. The database legs (sqlite / postgres / mysql)
  # do not all reach the same lines: the update and delete protections are
  # written for PostgreSQL, and the advisory-lock and concurrency paths only
  # execute on some adapters. The floor has to hold on the LEANEST leg, so it
  # sits below the richest one. Raise both numbers whenever every leg has
  # cleared them for a while.
  #
  # Currently 92.10 line / 72.62 branch on the leanest leg (sqlite), so this is
  # about a point of room in each. If a legitimate change spends it, add the
  # tests rather than lowering these back.
  #
  # Measure it on a CLEAN coverage directory. SimpleCov merges resultsets within
  # its merge timeout, so a full run following a `TEST=one_file.rb` run reports
  # a number neither of them produced.
  minimum_coverage line: 91, branch: 71

  # Disambiguate parallel test runs
  command_name "Job #{ENV["TEST_ENV_NUMBER"]}" if ENV["TEST_ENV_NUMBER"]
end

# Print coverage summary to terminal after tests complete
SimpleCov.at_exit do
  SimpleCov.result.format!
  puts "\n#{"=" * 60}"
  puts "COVERAGE SUMMARY"
  puts "=" * 60
  puts "Line Coverage:   #{SimpleCov.result.covered_percent.round(2)}%"
  branch_coverage = SimpleCov.result.coverage_statistics[:branch]&.percent&.round(2) || "N/A"
  puts "Branch Coverage: #{branch_coverage}%"
  puts "=" * 60
end

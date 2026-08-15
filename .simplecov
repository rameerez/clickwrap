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
  minimum_coverage line: 80, branch: 60

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

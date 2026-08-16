# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies are specified in clickwrap.gemspec
gemspec

# Build & release tools
gem "rake", "~> 13.0"

group :development do
  gem "appraisal"

  # Code quality
  gem "rubocop", "~> 1.0", require: false
  gem "rubocop-minitest", "~> 0.35", require: false
  gem "rubocop-performance", "~> 1.0", require: false
end

group :test do
  gem "minitest", "~> 6.0"
  # Minitest 6 extracted minitest/mock into its own gem.
  gem "minitest-mock"
  gem "mocha", "~> 2.0"
  # Optional integration contract only. Devise is deliberately not a runtime
  # dependency; this lane proves that choosing the adapter does not make it an
  # untested README promise.
  gem "devise", ">= 5.0.4", "< 6", require: false
  # Pinned to the 0.x line: SimpleCov 1.0 deprecates `SimpleCov.start` from a
  # `.simplecov` file, which is the layout the whole gem ecosystem uses.
  gem "simplecov", "~> 0.22", require: false

  # Optional integration contract only, like Devise above. The :markdown
  # document renderer uses whichever Markdown library the HOST bundles
  # (commonmarker, redcarpet, or kramdown) and adds no runtime dependency;
  # kramdown is the pure-Ruby one, so it is the one the test lane exercises.
  gem "kramdown", require: false

  # Rails frameworks the dummy app boots that are NOT runtime dependencies of
  # the gem itself. Clickwrap never requires a job backend or a mailer, but the
  # dummy app exercises the after-commit hook and the retention tasks against
  # real Rails APIs, and Active Job's :test adapter is how we prove that an
  # analytics or notification failure can never undo a committed action.
  gem "actionmailer"
  gem "activejob"

  # Database adapters. SQLite is the default lane; PostgreSQL runs the
  # concurrency, locking, and hardening lanes because that is where the
  # advisory locks and update/delete protections actually differ.
  gem "mysql2"
  gem "pg"
  gem "sqlite3", ">= 2.9.6"

  # Dummy Rails app
  gem "bootsnap", require: false
  gem "propshaft"
  gem "puma"

  # Fix RDoc version conflict (Ruby 3.4+ ships with 7.0.3)
  gem "rdoc", ">= 7.0"
end

# frozen_string_literal: true

require_relative "boot"

# Pull in ONLY the Rails frameworks the gem's test suite actually exercises,
# rather than `require "rails/all"`. A leaner boot is faster and makes the
# dependency surface explicit:
#   - active_record     : the clickwrap tables + the dummy host models
#   - active_job        : the after-commit hook path (proving an analytics or
#                         notification failure can never undo a committed action)
#   - action_controller : the engine's capture/receipt/withdrawal controllers
#   - action_view       : the form-builder helper and the reference views
#   - action_mailer     : hosts commonly mail from the post-commit hook; booting
#                         it keeps that integration path honest
# We deliberately SKIP action_cable / action_mailbox / action_text / active_storage:
# nothing in the gem's default path touches them, and Clickwrap must keep working
# in an application that has none of them installed.
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

# Load the gem under test. `Bundler.require` would also work, but requiring the
# entry point explicitly keeps the dummy honest about what it depends on and
# means the engine is loaded the same way a real host loads it.
require "clickwrap"

module Dummy
  # The minimal host application the engine mounts into. Everything here is the
  # smallest config that lets the suite boot across the Rails 7.1 / 7.2 / 8.0 /
  # 8.1 matrix and across the sqlite/postgres/mysql database matrix.
  class Application < Rails::Application
    # PIN THE APP ROOT EXPLICITLY to this dummy directory (test/dummy), not
    # whatever Rails guesses. Rails infers an application's root by walking up
    # for markers like a Gemfile/Rakefile/config.ru; from `rake test` (run at the
    # GEM root) it would otherwise guess the gem root, so `config/database.yml`
    # would resolve to `<gem>/config/database.yml` (the ENGINE's config dir,
    # which holds routes and locales but no database config) instead of
    # `test/dummy/config/database.yml`.
    config.root = File.expand_path("..", __dir__)

    # Pin the framework defaults to the gemspec floor (Rails 7.1). The dummy
    # must boot identically on every Rails in the matrix, so we anchor to the
    # LOWEST supported version's defaults — newer Rails happily loads older
    # defaults, and this avoids a higher default silently enabling behavior 7.1
    # hosts won't have.
    config.load_defaults 7.1

    # Eager load in test so the whole gem (every model, service, controller,
    # helper) is loaded up front: it surfaces autoload/NameError problems as a
    # boot failure instead of a mysterious mid-test error. For an evidence gem
    # this matters more than usual — a constant that only resolves on the happy
    # path is a constant that fails during a retention run at 3am.
    config.eager_load = true

    # Quiet, deterministic test output.
    config.consider_all_requests_local = Rails.env.test?
    config.action_controller.perform_caching = false
    config.active_support.deprecation = :stderr

    # Don't dump schema.rb after migrating. CI drives the test DB with
    # `db:migrate:reset` (migrations, not schema.rb) precisely because a dumped
    # schema.rb carries SQLite-specific JSON/default quirks that fail to load on
    # PostgreSQL/MySQL. Disabling the dump keeps the migrations the single source
    # of truth for the schema across the DB matrix.
    config.active_record.dump_schema_after_migration = false

    # test/test_helper.rb runs the real migrations before loading
    # rails/test_help. Disable Rails' second schema-maintenance pass so a stale,
    # gitignored local schema.rb cannot silently replace that freshly migrated
    # cross-adapter schema. CI and local development exercise the same
    # migration-only path.
    config.active_record.maintain_test_schema = false

    # :test adapters so the suite can assert on enqueued jobs and deliveries
    # without external services.
    config.active_job.queue_adapter = :test
    config.action_mailer.delivery_method = :test

    config.cache_store = :memory_store

    # What config/environments/test.rb sets in a generated app (the dummy has no
    # environment files): without it, every integration-test POST trips CSRF
    # protection and 422s.
    config.action_controller.allow_forgery_protection = false

    config.action_mailer.default_url_options = { host: "example.com" }

    # A fixed secret so signed presentation tokens are stable within a run. The
    # gem derives its own signing and request-evidence binding keys from this
    # through Rails' key generator, exactly as it does in a real application.
    config.secret_key_base = "clickwrap_dummy_secret_key_base_for_tests_only"

    # Active Record encryption keys. A real host generates these with
    # `bin/rails db:encryption:init` and keeps them in credentials; these are
    # fixed test values and are worthless outside this suite.
    #
    # They are here because Clickwrap encrypts the raw IP address and browser
    # user-agent columns by default, and the suite has to exercise that for
    # real rather than around it. A host with no keys gets a plain-English
    # boot error from Clickwrap::RequestEvidence instead of a stack trace.
    config.active_record.encryption.primary_key = "clickwrap_dummy_primary_key_for_tests_only"
    config.active_record.encryption.deterministic_key = "clickwrap_dummy_deterministic_key_test"
    config.active_record.encryption.key_derivation_salt = "clickwrap_dummy_key_derivation_salt"

    # The dummy's own document/policy/retention declarations live in
    # config/clickwrap.rb, which the engine's to_prepare loads. This is the same
    # path a real host uses.
  end
end

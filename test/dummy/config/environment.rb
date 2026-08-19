# frozen_string_literal: true

# Load the Rails application.
require_relative "application"

# Initialize the Rails application. This runs every initializer, including the
# engine's (Clickwrap::Engine) and the dummy's own config/initializers/clickwrap.rb,
# so by the time test_helper.rb requires this file the gem is fully wired and
# the host's documents, policies, and retention classes are compiled.
Rails.application.initialize!

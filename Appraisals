# frozen_string_literal: true

# Test the minimum supported Rails version (matches the gemspec floor). The
# adaptive install migration, the composite unique indexes the idempotency and
# current-grant guarantees depend on, and `ActiveRecord::Encryption` for the
# request-evidence annex must all work here.
appraise "rails-7.1" do
  gem "rails", "~> 7.1.0"
  # The :markdown renderer autodetects a host Markdown library; kramdown is
  # the pure-Ruby one the test lane exercises (same as the main Gemfile).
  gem "kramdown", require: false
  gem "markdown-rails", require: false
end

appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
  # The :markdown renderer autodetects a host Markdown library; kramdown is
  # the pure-Ruby one the test lane exercises (same as the main Gemfile).
  gem "kramdown", require: false
  gem "markdown-rails", require: false
end

appraise "rails-8.0" do
  gem "rails", "~> 8.0.0"
  # The :markdown renderer autodetects a host Markdown library; kramdown is
  # the pure-Ruby one the test lane exercises (same as the main Gemfile).
  gem "kramdown", require: false
  gem "markdown-rails", require: false
end

# Test the latest Rails version — this is the default/main Gemfile anyway.
appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
  # The :markdown renderer autodetects a host Markdown library; kramdown is
  # the pure-Ruby one the test lane exercises (same as the main Gemfile).
  gem "kramdown", require: false
  gem "markdown-rails", require: false
end

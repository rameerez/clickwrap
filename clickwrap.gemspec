# frozen_string_literal: true

require_relative "lib/clickwrap/version"

Gem::Specification.new do |spec|
  spec.name = "clickwrap"
  spec.version = Clickwrap::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Name reservation: clickwrap is not implemented or published yet"
  spec.description = "This release holds the clickwrap gem name while the product is being defined; it is deliberately empty. It ships no engine, no models, no migrations, no generators, and no public API, and declares no runtime dependencies. Do not depend on it. The intended gem is an evidence-and-assent layer for Rails covering agreements, consent, declarations, and authorizations, and its README describes that intended design as a contract to build against, not as code that exists today. A functional release will be published as 0.1.0 or later."
  spec.homepage = "https://github.com/rameerez/clickwrap"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |file|
      (file == gemspec) ||
        file.start_with?(*%w[
          .github/
          bin/
          gemfiles/
          spec/
          test/
        ]) ||
        %w[
          .gitignore
          AGENTS.md
        ].include?(file)
    end
  end

  spec.require_paths = ["lib"]

  # No runtime dependencies: there is nothing here to depend on anything yet.
end

# frozen_string_literal: true

require_relative "lib/clickwrap/version"

Gem::Specification.new do |spec|
  spec.name = "clickwrap"
  spec.version = Clickwrap::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Make your Rails users accept your Terms and legal documents — with standalone-verifiable receipts"
  spec.description = "clickwrap turns Terms acceptance, privacy notice acknowledgments, consent, declarations, attestations, and one-time authorizations into one Rails primitive: frozen document versions, server-owned policies, atomic evidence capture (the evidence and the protected action commit in the same transaction), and canonical receipts with a standalone verifier. Consent can actually be withdrawn, declarations expire without rewriting history, authorizations are consumed once, and optional IP address, browser user-agent, and IP geolocation evidence stays off by default. No JavaScript package, no Redis, no background jobs, no external services — just Rails and your database. clickwrap provides evidence mechanics only: your application and its counsel own the legal text, lawful basis, and retention periods."
  spec.homepage = "https://github.com/rameerez/clickwrap"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  development_files = %w[.simplecov AGENTS.md Appraisals CLAUDE.md Rakefile context7.json]
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) || development_files.include?(f) ||
        f.start_with?(*%w[bin/ gemfiles/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies are the Rails components the approved surface actually
  # uses, never the `rails` meta-gem. Clickwrap's whole value is long-lived
  # evidence in your own database, so installing it must not drag in
  # infrastructure you then have to keep alive for the evidence to stay
  # readable. Deliberately NOT dependencies, and never required at runtime:
  # Devise, `trackdown`, Active Storage, Active Job, a job backend, Redis, a
  # PDF library, a JavaScript runtime, a CSS framework, an HTTP client, or any
  # external service. Every one of those is an optional adapter with a working
  # no-op default.
  spec.add_dependency "actionpack", ">= 7.1.0", "< 9.0"
  spec.add_dependency "actionview", ">= 7.1.0", "< 9.0"
  spec.add_dependency "activerecord", ">= 7.1.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1.0", "< 9.0"
  spec.add_dependency "railties", ">= 7.1.0", "< 9.0"
end

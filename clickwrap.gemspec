# frozen_string_literal: true

require_relative "lib/clickwrap/version"

Gem::Specification.new do |spec|
  spec.name = "clickwrap"
  spec.version = Clickwrap::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Trustworthy agreements, consent, declarations, and authorizations for Rails"
  spec.description = "clickwrap is the missing evidence-and-assent layer for Rails. It turns terms acceptance, privacy notice acknowledgment, GDPR consent, factual declarations, operator attestations, and one-time authorizations into one coherent Rails primitive: immutable versioned documents, server-owned policies, signed presentation manifests that stop render-to-submit substitution, append-only evidence events, and canonical receipts anyone can verify independently. Required evidence and the protected database action commit in the same transaction, so an account, payout, or provider handoff can never succeed without the evidence that authorized it. Consent can actually be withdrawn, declarations expire and get corrected without rewriting history, authorizations are consumed once, and optional IP address, browser user-agent, and IP geolocation evidence is off by default, encrypted, separately disposable, and named field by field in plain English. No JavaScript package, no Redis, no background job, no external account, no legal-document vendor. clickwrap provides evidence mechanics only: your application and its counsel still own the legal text, lawful basis, substantive validity, capacity, authority, and retention periods, and the gem never claims compliance, enforceability, identity, or trusted time."
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

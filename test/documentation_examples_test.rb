# frozen_string_literal: true

require "test_helper"

# Public Ruby examples are part of the API: readers copy them before they read
# implementation code. Every Ruby fence must parse, and every complete
# top-level Clickwrap declaration is evaluated against the real compiler. A
# contextual fragment may opt out of evaluation with the explicit first-line
# marker `# clickwrap-doc-test: syntax-only`; it is still syntax checked.
class DocumentationExamplesTest < ActiveSupport::TestCase
  # The north-star contract lives in the git-ignored docs/ corpus: present on
  # the author's machine, absent on CI and fresh clones. Its examples are
  # checked whenever the file is here, but its absence must not stop the suite.
  DOCUMENTATION_PATHS = [
    Rails.root.join("..", "..", "README.md").expand_path.to_s,
    Rails.root.join("..", "..", "docs", "north-star-readme.md").expand_path.to_s,
    *Dir[Rails.root.join("..", "..", "guides", "**", "*.md")]
  ].select { |path| File.exist?(path) }.freeze

  Example = Data.define(:path, :line, :source) do
    def label
      root = File.expand_path("..", __dir__)
      "#{path.delete_prefix("#{root}/")}:#{line}"
    end

    def syntax_only? = source.lines.first&.include?("clickwrap-doc-test: syntax-only")

    def complete_declaration?
      first_executable_line&.match?(/\AClickwrap\.(?:configure|document|policy|retention)\b/)
    end

    private

    def first_executable_line
      source.lines.map(&:strip).find { |candidate| candidate.present? && !candidate.start_with?("#") }
    end
  end

  EXAMPLES = DOCUMENTATION_PATHS.flat_map do |path|
    examples = []
    source = File.readlines(path)
    opening_line = nil
    body = []

    source.each_with_index do |line, index|
      if opening_line.nil? && line.match?(/^```ruby\s*$/)
        opening_line = index + 2
        body = []
      elsif opening_line && line.match?(/^```\s*$/)
        examples << Example.new(path:, line: opening_line, source: body.join)
        opening_line = nil
      elsif opening_line
        body << line
      end
    end

    raise "Unclosed Ruby fence at #{path}:#{opening_line}" if opening_line

    examples
  end.freeze

  class DocumentationAuthorityAdapter
    def verify(**)
      Clickwrap::AuthorityDecision.new(authorized: false, source: "documentation_test")
    end
  end

  test "every public Ruby fence compiles" do
    failures = EXAMPLES.filter_map do |example|
      RubyVM::InstructionSequence.compile(example.source, example.label)
      nil
    rescue SyntaxError => error
      "#{example.label}: #{error.message.lines.first.strip}"
    end

    assert_empty failures, "Documentation contains invalid Ruby:\n#{failures.join("\n")}"
  end

  test "every complete top-level Clickwrap declaration reaches the real compiler" do
    examples = EXAMPLES.select(&:complete_declaration?).reject(&:syntax_only?)
    failures = examples.filter_map do |example|
      compile_documentation_example(example)
      nil
    rescue StandardError, ScriptError => error
      "#{example.label}: #{error.class}: #{error.message.lines.first}"
    ensure
      Clickwrap.reset!
    end

    assert_operator examples.length, :>=, 20,
                    "The semantic documentation test stopped discovering complete examples."
    assert_empty failures, "Documentation examples do not match the shipped API:\n#{failures.join("\n")}"
  end

  private

  def compile_documentation_example(example)
    configure_documentation_host(example.source)
    # These are trusted, repository-owned Ruby examples. Executing them is the
    # test's purpose: syntax-only compilation cannot catch calls to a stale API.
    # rubocop:disable Security/Eval
    Object.new.instance_eval { eval(example.source, binding, example.label, 1) }
    # rubocop:enable Security/Eval
    supply_referenced_declarations
    Clickwrap::Services::ValidatePolicyReferences.call
  end

  def configure_documentation_host(source)
    Clickwrap.reset!
    Clickwrap.configure do |config|
      config.trusted_proxy_configuration_digest =
        Clickwrap::Digest.digest("reviewed-documentation-test-proxy-configuration")
      config.ip_geolocation_resolver = Clickwrap::IpGeolocation::StaticResolver.new
    end

    source.scan(/\busing:\s*:(\w+)/).flatten.each do |name|
      unless Clickwrap.config.ip_geolocation_resolver_for(name)
        Clickwrap.config.register_ip_geolocation_resolver(
          name,
          Clickwrap::IpGeolocation::StaticResolver.new
        )
      end
      unless Clickwrap.config.represented_party_authority_adapter(name)
        Clickwrap.config.register_represented_party_authority(name, DocumentationAuthorityAdapter.new)
      end
    end
  end

  def supply_referenced_declarations
    supply_documents
    supply_retention_classes
    supply_retention_calculations
    supply_authority_adapters
    supply_ip_geolocation_resolvers
  end

  def supply_documents
    Clickwrap.policies.each do |policy|
      locales = policy.locales.presence || ["en"]
      policy.document_keys.each do |key|
        locales.each do |locale|
          next if Clickwrap.documents.values.any? do |definition|
            definition.key == key && definition.locale == locale.to_s
          end

          Clickwrap.document(
            key,
            version: "documentation-test-v1",
            locale: locale,
            content: "Frozen documentation test content for #{key}."
          )
        end
      end
    end
  end

  def supply_retention_classes
    Clickwrap.policies.each do |policy|
      next if Clickwrap.retention_classes[policy.retention_class_key]

      Clickwrap.retention policy.retention_class_key do
        retain_core_event_for 1.year
        delete_recorded_ip_address_after 30.days
        delete_recorded_browser_user_agent_after 30.days
        delete_recorded_ip_geolocation_after 30.days
      end
    end
  end

  def supply_retention_calculations
    names = Clickwrap.retention_classes.values.flat_map do |retention_class|
      retention_class.rules.values.filter_map(&:host_event_name)
    end
    names.concat(
      Clickwrap.policies.values.flat_map do |policy|
        Clickwrap::RequestEvidencePolicy::FIELD_CATEGORIES.filter_map do |category|
          policy.request_evidence.setting_for(category).retain_until
        end
      end
    )

    (names.map(&:to_sym).uniq - Clickwrap.config.retention_time_calculator_names).each do |name|
      Clickwrap.config.calculate_retention_time_for(name) { |_event| Clickwrap.now + 1.year }
    end
  end

  def supply_authority_adapters
    Clickwrap.policies.values.filter_map(&:authority_rule).each do |rule|
      next if rule.adapter_name == "host"
      next if Clickwrap.config.represented_party_authority_adapter(rule.adapter_name)

      Clickwrap.config.register_represented_party_authority(
        rule.adapter_name,
        DocumentationAuthorityAdapter.new
      )
    end
  end

  def supply_ip_geolocation_resolvers
    Clickwrap.policies.each do |policy|
      request_evidence = policy.request_evidence
      next unless request_evidence.records_ip_geolocation?

      name = request_evidence.ip_geolocation_resolver_name
      next if Clickwrap.config.ip_geolocation_resolver_for(name)

      Clickwrap.config.register_ip_geolocation_resolver(
        name,
        Clickwrap::IpGeolocation::StaticResolver.new
      )
    end
  end
end

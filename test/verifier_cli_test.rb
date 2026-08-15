# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# `clickwrap verify receipt.json` — the promise that an exported receipt can be
# checked by somebody who does not have this application.
#
# Every test here shells out to the real executable with bundler's setup
# stripped from the environment and only the gem's own `lib` reachable. That is
# not ceremony: a verifier that needed the application which produced the
# evidence could only ever report that the application agrees with itself, and
# the first accidental `require "rails"` in that dependency closure would break
# the promise the receipt itself makes in its `verifier_instructions`.
class VerifierCliTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.expand_path("exe/clickwrap", GEM_ROOT)
  LIBRARY = File.expand_path("lib", GEM_ROOT)

  # Bundler exports its setup through the environment, so a subprocess started
  # from a `bundle exec` test inherits the whole host bundle unless these are
  # cleared. Passing nil removes the variable rather than blanking it.
  WITHOUT_BUNDLER = {
    "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
    "BUNDLE_APP_CONFIG" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil
  }.freeze

  setup do
    @user = create_user
    @receipt = capture_clickwrap(:signup, actor: @user)
  end

  test "verifying a receipt without its cited artifacts is visibly incomplete and exits two" do
    in_a_bundle do |directory|
      path = write_receipt(directory, @receipt.to_canonical_json)

      output, error, status = run_clickwrap("verify", path)

      assert_equal 2, status.exitstatus, error
      assert_match(/Receipt #{@receipt.event_id}/, output)
      assert_match(/✓ json_parses/, output)
      assert_match(/✓ known_schema/, output)
      assert_match(/✓ receipt_digest/, output)

      # A document nobody supplied is neither reported as a digest mismatch nor
      # allowed to produce a fully verified exit status.
      assert_match(/– document:terms@2026-08-15@en:source/, output)
      assert_match(/– document:terms@2026-08-15@en:rendered/, output)
      assert_match(/no document files were supplied/, output)
      assert_match(/INCOMPLETE/, output)

      # And the bounded claim travels with the green result, every time.
      assert_match(/does not establish who/, output)
      assert_match(/could not have written both the record and the digest/, output)
    end
  end

  test "verifying a receipt against the document bytes it cites checks them too" do
    in_a_bundle do |directory|
      path = write_receipt(directory, @receipt.to_canonical_json)
      documents = File.join(directory, "documents")
      Dir.mkdir(documents)

      @receipt.documents.each do |binding|
        version = Clickwrap::DocumentVersion.find(binding.document_version_id)
        basename = "#{binding.document_key}-#{binding.version_label}-#{binding.locale}"
        File.binwrite(File.join(documents, "#{basename}.source.md"), version.content_bytes)
        File.binwrite(File.join(documents, "#{basename}.rendered.html"), version.rendered_bytes)
      end

      output, error, status = run_clickwrap("verify", path, "--documents", documents)

      assert_equal 0, status.exitstatus, error
      assert_match(/✓ document:terms@2026-08-15@en:source/, output)
      assert_match(/✓ document:terms@2026-08-15@en:rendered/, output)
      assert_match(/document terms@2026-08-15@en:source read from terms-2026-08-15-en\.source\.md/, output)
    end
  end

  test "an edited receipt exits one and names the check that failed" do
    in_a_bundle do |directory|
      edited = JSON.parse(@receipt.to_canonical_json)
      edited["acts"].first["assertion"] = "Something nobody ever agreed to"
      path = write_receipt(directory, JSON.generate(edited))

      output, _error, status = run_clickwrap("verify", path)

      # The bytes changed after the digest was taken, which is exactly what a
      # digest is for. A non-zero exit is what makes this usable from a script.
      assert_equal 1, status.exitstatus
      assert_match(/✗ receipt_digest/, output)
      assert_match(/Something about these bytes changed after the digest was taken/, output)
      assert_match(/see the failing checks above/, output)
    end
  end

  test "a receipt in a schema this verifier does not know stops rather than guessing" do
    in_a_bundle do |directory|
      unknown = JSON.parse(@receipt.to_canonical_json).merge("schema" => "clickwrap.receipt.v99")
      path = write_receipt(directory, JSON.generate(unknown))

      output, _error, status = run_clickwrap("verify", path)

      assert_equal 1, status.exitstatus
      assert_match(/✗ known_schema/, output)
      assert_match(/Verification stopped rather than guessing/, output)
    end
  end

  test "a missing file and an unreadable one are reported without a stack trace" do
    output, error, status = run_clickwrap("verify", "/nonexistent/receipt.json")

    assert_equal 1, status.exitstatus
    assert_empty output
    assert_match(%r{There is no file at /nonexistent/receipt\.json}, error)

    in_a_bundle do |directory|
      path = write_receipt(directory, "{ not json at all")
      _, malformed, status_for_malformed = run_clickwrap("verify", path)

      assert_equal 1, status_for_malformed.exitstatus
      assert_match(/is not valid JSON/, malformed)
    end
  end

  test "--help and --version exit zero and describe the bounded claim" do
    help, _error, help_status = run_clickwrap("--help")

    assert_equal 0, help_status.exitstatus
    assert_match(/clickwrap verify RECEIPT\.json/, help)
    assert_match(/What a pass means/, help)
    assert_match(/It does not\s+establish who produced the receipt/, help)

    version, _error, version_status = run_clickwrap("--version")

    assert_equal 0, version_status.exitstatus
    assert_match(/clickwrap #{Regexp.escape(Clickwrap::VERSION)}/, version)
    assert_match(/receipt schema #{Regexp.escape(Clickwrap::CANONICAL_SCHEMA_VERSION)}/, version)
  end

  test "the verifier's whole dependency closure contains no Rails, ActiveRecord, or ActiveSupport" do
    script = <<~RUBY
      $LOAD_PATH.unshift(#{LIBRARY.inspect})
      require "clickwrap/version"
      require "clickwrap/errors"
      require "clickwrap/canonical_json"
      require "clickwrap/digest"
      require "clickwrap/receipt_verifier"
      puts [defined?(Rails), defined?(ActiveRecord), defined?(ActiveSupport)].inspect
    RUBY

    output, error, status = run_ruby("-e", script)

    # This is the assertion the promise rests on. One `require "active_support"`
    # anywhere under the verifier and a receipt can only be checked by machines
    # that happen to have Rails installed — five years from now, that is nobody.
    assert_equal 0, status.exitstatus, error
    assert_equal "[nil, nil, nil]", output.strip
  end

  test "canonical JSON can be required directly in a bare Ruby process" do
    script = <<~RUBY
      $LOAD_PATH.unshift(#{LIBRARY.inspect})
      require "clickwrap/canonical_json"
      puts Clickwrap::CanonicalJson.generate({"answer" => 42})
    RUBY

    output, error, status = run_ruby("-e", script)

    assert_equal 0, status.exitstatus, error
    assert_equal '{"answer":42}', output.strip
  end

  test "hostile canonical numbers become failed findings instead of exceptions" do
    oversized = @receipt.to_canonical_json.sub(/\}\z/, ',"x_host_number":9007199254740992}')
    infinite = @receipt.to_canonical_json.sub(/\}\z/, ',"x_host_number":1e999}')

    [oversized, infinite].each do |json|
      result = Clickwrap::ReceiptVerifier.verify(json)

      assert result.failed?
      assert_equal "failed", result.status
      finding = result.failures.find { |check| check.name == "verifier_input" }
      assert finding, result.to_s
      assert_match(/could not be verified safely/, finding.detail)
    end
  end

  private

  def in_a_bundle(&) = Dir.mktmpdir("clickwrap-receipt", &)

  def write_receipt(directory, json)
    path = File.join(directory, "receipt.json")
    File.write(path, json)
    path
  end

  def run_clickwrap(*) = run_ruby(EXECUTABLE, *)

  def run_ruby(*)
    Open3.capture3(WITHOUT_BUNDLER, RbConfig.ruby, *, chdir: GEM_ROOT)
  end
end

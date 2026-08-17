# frozen_string_literal: true

require "test_helper"

# A presentation signs the document link into the manifest, digests it, and
# keeps it as the exact document the person was offered. On an application that
# never mounted the engine that link is built from the engine's own routes and
# resolves to nothing — so the evidence would cite a 404, permanently, and look
# perfectly valid while doing it.
#
# Nothing downstream can catch that: the digest is over the wrong link. The only
# moment it can be caught is while the presentation is being built.
class EngineMountTest < ActiveSupport::TestCase
  setup { @user = create_user }

  # The dummy mounts at "/legal", NOT at the root, so this also proves the
  # fallback carries the host's real mount prefix rather than a bare path that
  # only happens to work when the engine is mounted at "/".
  #
  # :manual_bank_transfer, because its document declares no `link:` and
  # therefore still resolves through the engine's own per-version route.
  test "a mounted engine signs the document link the host actually routes" do
    paths = document_paths_in(Clickwrap.present(:manual_bank_transfer, actor: @user,
                                                                       capture_channel: :operator))

    assert_predicate paths, :any?
    paths.each { |path| assert_match(%r{\A/legal/}, path, "the signed link must carry the mount prefix") }
  end

  # The refusal is about the ENGINE's route. A document that names the host page
  # a person actually reads it on never reaches it — and a policy whose every
  # document does that presents on an application with no mount at all.
  test "a declared link is signed as declared, and needs no mount to be resolvable" do
    Clickwrap::ControllerHelpers.stubs(:engine_is_mounted?).returns(false)

    assert_equal ["/terms-of-service", "/privacy-policy"],
                 document_paths_in(Clickwrap.present(:signup, actor: @user))
  end

  test "presenting refuses to sign a document link an unmounted engine cannot resolve" do
    Clickwrap::ControllerHelpers.stubs(:engine_is_mounted?).returns(false)

    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.present(:manual_bank_transfer, actor: @user, capture_channel: :operator)
    end

    # The sentence has to name the line that fixes it. An error that says
    # "could not build the URL" sends someone reading their own code.
    assert_match(/will not sign a document link that resolves to nothing/, error.message)
    assert_match(%r{mount Clickwrap::Engine => "/agreements"}, error.message)
    assert_match(/document_version_path_with/, error.message)
  end

  test "a host that binds its own document route may present without mounting the engine" do
    Clickwrap::ControllerHelpers.stubs(:engine_is_mounted?).returns(false)

    # And it wins over the declared `link:` too: a resolver passed at the call
    # site is the host saying where this document lives on THIS screen, which is
    # more specific than what the declaration says in general.
    paths = document_paths_in(
      Clickwrap.present(
        :signup,
        actor: @user,
        document_version_path_with: ->(version) { "/our/legal/#{version.id}" }
      )
    )

    assert_predicate paths, :any?
    paths.each { |path| assert_match(%r{\A/our/legal/}, path) }
  end

  test "the doctor reports an unmounted engine as a problem whenever a policy is compiled" do
    Clickwrap::ControllerHelpers.stubs(:engine_is_mounted?).returns(false)

    findings = Clickwrap::Doctor.new.report
    finding = findings.find { |candidate| candidate.message.include?("sign a document link") }

    assert finding, "the doctor must say the mount is missing: #{findings.map(&:message)}"
    assert_predicate finding, :problem?
    assert_match(%r{mount Clickwrap::Engine => "/agreements"}, finding.message)
  end

  test "the doctor confirms the mount when the engine is mounted" do
    findings = Clickwrap::Doctor.new.report

    assert(findings.any? { |finding| finding.ok? && finding.message.include?("Clickwrap::Engine is mounted") })
  end

  test "the doctor stays quiet about the mount when nothing is compiled" do
    # Nothing presents anything, so the mount is not yet a fact about this
    # application. The "no policies are compiled" warning is the finding that
    # matters there, and a second line about routing would only bury it.
    Clickwrap.reset!
    Clickwrap::ControllerHelpers.stubs(:engine_is_mounted?).returns(false)

    findings = Clickwrap::Doctor.new.report

    assert_empty(findings.select { |finding| finding.message.include?("sign a document link") })
  end

  private

  def document_paths_in(presentation)
    presentation.to_h["statements"].flat_map { |statement| statement["documents"] }
                                   .map { |document| document["path"] }
  end
end

# frozen_string_literal: true

require "test_helper"

# The optional integrity tiers, and the exact claim each one is allowed to make.
#
# A chain makes a rewrite of history detectable for as long as the chain head
# remains trustworthy. It does not stop a privileged actor who rewrites the
# events and their digests together, and nothing here — the walk, the adapters,
# or the receipt — is permitted to say otherwise.
class IntegrityTest < ActiveSupport::TestCase
  class VerifiedTimestampAdapter
    def timestamp(digest)
      {
        issued: true,
        token: "test-token-for-#{digest}",
        digest: digest,
        provider_name: "test_timestamp_authority",
        protocol: "test-only",
        provider_reported_time: Time.current
      }
    end

    def verify(token, digest)
      {
        checked: true,
        verified: token == "test-token-for-#{digest}",
        provider_name: "test_timestamp_authority",
        provider_reported_status: "valid"
      }
    end

    def capabilities
      { name: "test_timestamp_authority", independently_verifiable: true }
    end
  end

  class MismatchedTimestampAdapter < VerifiedTimestampAdapter
    def timestamp(_digest)
      {
        issued: true,
        token: "wrong",
        digest: "sha256:#{"0" * 64}",
        provider_name: "mismatch"
      }
    end
  end

  class RaisingTimestampAdapter < VerifiedTimestampAdapter
    def timestamp(_digest) = raise("timestamp provider unavailable")
  end

  class VerifiedAnchorAdapter
    attr_reader :verified_publication

    def anchor(chain_head)
      {
        anchored: true,
        reference: "immutable://test/#{chain_head.last_event_id}",
        published_at: Time.current,
        provider_name: "test_anchor"
      }
    end

    def verify(publication, chain_head)
      @verified_publication = publication
      {
        checked: true,
        verified: publication["reference"] == "immutable://test/#{chain_head.last_event_id}",
        provider_name: "test_anchor"
      }
    end

    def capabilities
      { name: "test_anchor", publishes_outside_primary_database: true }
    end
  end

  setup do
    @user = create_user
  end

  # --- Chaining ---------------------------------------------------------------

  test "consecutive captures in one scope link to their predecessor and increment the sequence" do
    chain_event_history!

    first = submit_clickwrap(:signup, actor: @user)
    second = submit_clickwrap(:signup, actor: create_user)

    first_event = first.event.reload
    second_event = second.event.reload

    assert_equal "global/signup", first_event.chain_scope
    assert_equal 1, first_event.chain_sequence
    assert_nil first_event.previous_event_digest, "the head of a chain has no predecessor"

    assert_equal 2, second_event.chain_sequence

    # This is the whole mechanism: an event carries the digest of the one before
    # it, so rewriting or removing that predecessor stops the two linking up. If
    # the link were left blank the walk below would have nothing to compare and
    # would report every chain as intact.
    assert_equal first_event.event_digest, second_event.previous_event_digest

    # The head carries the digest the latest event was actually written with.
    # Recording it before the event is saved is how a chain ends up full of
    # nils, and a chain of nils reports every scope as intact.
    head = Clickwrap::ChainHead.find_by(chain_scope: "global/signup")
    assert_equal second_event.event_digest, head.last_event_digest
    assert_equal 2, head.chain_sequence
  end

  test "chaining is off unless it is configured" do
    receipt = submit_clickwrap(:signup, actor: @user)

    assert_nil receipt.event.reload.chain_scope
    assert_nil receipt.event.chain_sequence
    assert_equal 0, Clickwrap::ChainHead.count
    assert_not Clickwrap::Integrity::Chain.verify.chaining_enabled
  end

  test "a chain is scoped per tenant and per policy rather than globally" do
    chain_event_history!
    first_tenant = create_organization
    second_tenant = create_organization

    one = submit_clickwrap(:signup, actor: @user, tenant: first_tenant)
    two = submit_clickwrap(:signup, actor: create_user, tenant: second_tenant)
    three = submit_clickwrap(:signup, actor: create_user, tenant: first_tenant)

    assert_not_equal one.event.reload.chain_scope, two.event.reload.chain_scope

    # Independent sequences, on purpose. One global chain would put every
    # capture in a queue behind every other tenant's captures and buy assurance
    # nobody asked for at a cost everybody pays.
    assert_equal 1, one.event.chain_sequence
    assert_equal 1, two.event.chain_sequence
    assert_equal 2, three.event.reload.chain_sequence
    assert_equal one.event.event_digest, three.event.previous_event_digest

    result = Clickwrap::Integrity::Chain.verify
    assert result.success?
    assert_equal 2, result.scopes.length
  end

  test "the walk passes on an intact chain and reports the first break when one is rewritten" do
    chain_event_history!

    submit_clickwrap(:signup, actor: @user)
    rewritten = submit_clickwrap(:signup, actor: create_user)
    submit_clickwrap(:signup, actor: create_user)

    intact = Clickwrap::Integrity::Chain.verify
    assert intact.success?
    assert_equal 3, intact.counts["checked"]
    assert_equal 3, intact.counts["verified"]
    assert_nil intact.first_break

    # `update_all` is how this happens in real life: a well-meant migration, a
    # console fix, a partial restore. None of them go through the append-only
    # guard, and all of them are what a chain exists to make visible.
    Clickwrap::Event.where(id: rewritten.event_id).update_all(reason: "rewritten by hand")

    broken = Clickwrap::Integrity::Chain.verify

    assert_not broken.success?
    assert_equal rewritten.event_id, broken.first_break.event_id
    assert_equal :digest_does_not_match, broken.first_break.reason
    assert_equal 2, broken.first_break.chain_sequence
    assert_match(/meaningful bytes changed after it was written/, broken.first_break.detail)
    assert_equal 1, broken.counts["scopes"]
    assert_equal 3, broken.counts["checked"]
  end

  test "the chain counts documented core dispositions without calling their deleted digests verified" do
    chain_event_history!
    receipt = submit_clickwrap(:signup, actor: @user)

    Clickwrap::Retention::Disposition.dispose_core_event!(
      receipt.event,
      because: "The reviewed retention period ended"
    )

    result = Clickwrap::Integrity::Chain.verify

    assert result.success?
    assert_equal 2, result.counts["checked"]
    assert_equal 1, result.counts["verified"]
    assert_equal 1, result.counts["documented_dispositions"]
    assert_equal :documented_core_disposition, receipt.event.reload.digest_integrity_status
  end

  test "an event whose stored digest is replaced stops linking to its successor" do
    chain_event_history!

    first = submit_clickwrap(:signup, actor: @user)
    second = submit_clickwrap(:signup, actor: create_user)

    # A restored partial backup, or a row someone patched to make a digest
    # check pass, changes the stored digest itself. The successor recorded the
    # old one, so the two stop forming a chain — which is the property the
    # previous digest exists to give, and it is checked separately from whether
    # each event still hashes to its own body.
    Clickwrap::Event.where(id: first.event_id).update_all(event_digest: "sha256:#{"0" * 64}")

    result = Clickwrap::Integrity::Chain.verify
    reasons = result.breaks.map(&:reason)

    assert_not result.success?
    assert_equal first.event_id, result.first_break.event_id
    assert_includes reasons, :digest_does_not_match
    assert_includes reasons, :previous_digest_does_not_link

    link_break = result.breaks.find { |candidate| candidate.reason == :previous_digest_does_not_link }
    assert_equal second.event_id, link_break.event_id
    assert_match(/no longer form a chain/, link_break.detail)
  end

  test "deleting the newest event is detected against the durable chain head" do
    chain_event_history!

    first = submit_clickwrap(:signup, actor: @user)
    removed = submit_clickwrap(:signup, actor: create_user)
    connection = ActiveRecord::Base.connection
    connection.disable_referential_integrity do
      Clickwrap::Event.where(id: removed.event_id).delete_all
    end

    result = Clickwrap::Integrity::Chain.verify(scope: "global/signup")

    assert_not result.success?
    assert_equal 1, result.counts["checked"]
    assert_equal first.event_id, result.first_break.event_id
    assert_includes result.breaks.map(&:reason), :chain_tail_missing
    assert_includes result.breaks.map(&:reason), :chain_head_event_mismatch
    assert_includes result.breaks.map(&:reason), :chain_head_digest_mismatch
  end

  test "deleting every event still leaves a detectable chain-head discrepancy" do
    chain_event_history!
    removed = submit_clickwrap(:signup, actor: @user)

    ActiveRecord::Base.connection.disable_referential_integrity do
      Clickwrap::Event.where(id: removed.event_id).delete_all
    end

    result = Clickwrap::Integrity::Chain.verify(scope: "global/signup")

    assert_not result.success?
    assert_equal 0, result.counts["checked"]
    assert_equal :chain_tail_missing, result.first_break.reason
    assert_match(/has no event rows/, result.first_break.detail)
  end

  test "a bounded walk reports that it started mid-chain instead of calling it a break" do
    chain_event_history!

    submit_clickwrap(:signup, actor: @user)
    submit_clickwrap(:signup, actor: create_user)

    result = Clickwrap::Integrity::Chain.verify(scope: "global/signup", from: 2)

    # "Everything since last night" is a legitimate way to run this from cron.
    # Starting at sequence two is then a fact about the run, not a finding about
    # the data — and an unbounded walk that started there would be a finding.
    assert result.success?
    assert_equal 1, result.counts["checked"]
    assert_equal [{ "chain_scope" => "global/signup", "chain_sequence" => 2 }], result.started_mid_chain
  end

  test "what a chain verification reports never claims more than it detects" do
    chain_event_history!
    submit_clickwrap(:signup, actor: @user)

    body = Clickwrap::Integrity::Chain.verify.to_h

    assert body["chaining_enabled"]
    assert_match(/for as long as the chain head remains trustworthy/, body["detects"])
    assert_match(/Not a rewrite of the events and their digests together/, body["detects"])
    assert_no_match(/tamper.?proof/i, body["detects"])
  end

  # --- The optional adapters --------------------------------------------------

  test "the no-op anchor reports the absence of an anchor rather than failing" do
    anchor = Clickwrap::Integrity::Anchor.new
    head = Clickwrap::ChainHead.create!(chain_scope: "global/signup", chain_sequence: 0)

    publication = anchor.anchor(head)
    verification = anchor.verify(publication, head)

    # "Not anchored" is an ordinary outcome, not an error: a no-op adapter, an
    # outage, and a queue that has not drained all mean the same thing, and the
    # record says so instead of leaving a caller to infer it.
    assert_not publication.anchored
    assert_equal "no_anchor", publication.provider_name
    assert_match(/publishes nowhere/, publication.to_h["detail"])

    # "We could not check" and "we checked and it does not match" are different
    # answers, which is why `checked` exists alongside `verified`.
    assert_not verification.checked
    assert_not verification.verified
    assert_not anchor.available?
    assert_not anchor.capabilities["publishes_outside_primary_database"]
    assert_not anchor.capabilities["independently_verifiable"]
    assert_match(/reports the absence of an anchor/, anchor.capabilities["supplies"])
    assert_match(/no_anchor/, anchor.to_s)
  end

  test "the no-op timestamp provider issues no token and says the only time is the server's own" do
    provider = Clickwrap::Integrity::Timestamp.new
    token = provider.timestamp("sha256:abc")
    verification = provider.verify("token", "sha256:abc")

    assert_not token.issued
    assert_equal "sha256:abc", token.to_h["digest"]
    assert_equal "no_timestamp_provider", token.provider_name
    assert_match(/the only\s+recorded time remains the application server's own/, token.to_h["detail"])

    assert_not verification.checked
    assert_not verification.verified
    assert_not provider.available?
    assert_nil provider.capabilities["protocol"]

    # A configured provider supplies exactly what that provider supplies, and
    # this gem never restates it more strongly — including here, where there is
    # no provider at all.
    assert_match(/never restates it more\s+strongly/, provider.capabilities["note"])
    assert_no_match(/trusted time/i, provider.capabilities.to_s)
  end

  test "a verified timestamp is immutable, digest-bound, and independently checkable as a receipt record" do
    adapter = VerifiedTimestampAdapter.new
    Clickwrap.config.timestamp_receipts_with = adapter
    receipt = submit_clickwrap(:signup, actor: @user)

    attestation = Clickwrap::Integrity::Attestor.new(receipt.event).timestamp_event

    assert attestation.verified_for?(receipt.event)
    assert attestation.digest_verified?
    assert_equal receipt.event.event_digest, attestation.subject_digest
    assert_equal "third_party_timestamp", receipt.to_h.dig("integrity", "tier")
    assert_raises(Clickwrap::ImmutableEvidenceError) { attestation.update!(state: "failed") }
    assert_raises(Clickwrap::ImmutableEvidenceError) { attestation.destroy! }

    result = Clickwrap::ReceiptVerifier.verify(
      receipt.to_canonical_json,
      documents: document_artifacts_for(receipt)
    )
    assert result.success?, result.to_s
    assert(
      result.checks.any? do |check|
        check.name.start_with?("integrity_attestation") && check.passed?
      end
    )
  end

  test "a timestamp result for a different digest is recorded as failed and never upgrades the tier" do
    Clickwrap.config.timestamp_receipts_with = MismatchedTimestampAdapter.new
    receipt = submit_clickwrap(:signup, actor: @user)

    attestation = Clickwrap::Integrity::Attestor.new(receipt.event).timestamp_event

    assert_equal "failed", attestation.state
    refute attestation.verified?
    assert_equal "baseline", receipt.to_h.dig("integrity", "tier")
    assert_match(/different digest/, attestation.verification.fetch("detail"))
  end

  test "an integrity-provider exception leaves a failed immutable attempt and reports the outage" do
    reported = []
    Clickwrap.config.timestamp_receipts_with = RaisingTimestampAdapter.new
    Clickwrap.config.report_after_commit_failure_with =
      ->(error, event) { reported << [error, event.id] }
    receipt = submit_clickwrap(:signup, actor: @user)

    Clickwrap::Integrity::Attestor.new(receipt.event).timestamp_event

    attestation = receipt.event.integrity_attestations.last
    assert_equal "failed", attestation.state
    assert_equal "RuntimeError", attestation.provider_result.fetch("error_class")
    assert_equal([["timestamp provider unavailable", receipt.event_id]],
                 reported.map { |error, event_id| [error.message, event_id] })
  end

  test "an anchor verifier receives the exact publication it is asked to substantiate" do
    adapter = VerifiedAnchorAdapter.new
    chain_event_history!
    Clickwrap.config.anchor_event_history_with = adapter
    receipt = submit_clickwrap(:signup, actor: @user)

    attestation = Clickwrap::Integrity::Attestor.new(receipt.event).anchor_event

    assert attestation.verified_for?(receipt.event)
    assert_equal attestation.provider_result, adapter.verified_publication
    assert_equal "external_event_anchoring", receipt.to_h.dig("integrity", "tier")
  end

  test "missing timestamp attestations can be reconciled without duplicating recorded attempts" do
    receipt = submit_clickwrap(:signup, actor: @user)
    Clickwrap.config.timestamp_receipts_with = VerifiedTimestampAdapter.new

    first = Clickwrap.reconcile_missing_integrity_attestations!
    second = Clickwrap.reconcile_missing_integrity_attestations!

    assert_equal({ "attempted" => 1, "recorded" => 1, "not_recorded" => 0 }, first.counts)
    assert first.clean?
    assert_equal 0, second.attempted

    attestation = receipt.event.integrity_attestations.find_by!(kind: "third_party_timestamp")
    assert attestation.verified_for?(receipt.event)
  end

  test "failed attestations are retried only when the caller says so" do
    receipt = submit_clickwrap(:signup, actor: @user)
    Clickwrap.config.timestamp_receipts_with = RaisingTimestampAdapter.new

    first = Clickwrap.reconcile_missing_integrity_attestations!
    ordinary_rerun = Clickwrap.reconcile_missing_integrity_attestations!
    explicit_retry = Clickwrap.reconcile_missing_integrity_attestations!(retry_failed_attestations: true)

    assert_equal 1, first.attempted
    assert_equal 0, ordinary_rerun.attempted
    assert_equal 1, explicit_retry.attempted
    assert_equal %w[failed failed], receipt.event.integrity_attestations.order(:attempted_at, :id).pluck(:state)
  end

  test "anchor reconciliation touches only events that were actually chained" do
    unchained = submit_clickwrap(:signup, actor: @user)
    chain_event_history!
    chained = submit_clickwrap(:signup, actor: create_user)
    Clickwrap.config.anchor_event_history_with = VerifiedAnchorAdapter.new

    result = Clickwrap.reconcile_missing_integrity_attestations!

    assert_equal 1, result.attempted
    assert_empty unchained.event.integrity_attestations
    assert chained.event.integrity_attestations.find_by!(kind: "event_anchor").verified_for?(chained.event)
  end

  # --- What the receipt is allowed to say -------------------------------------

  test "a receipt states the chained tier only when its event is actually chained" do
    baseline = submit_clickwrap(:signup, actor: @user).to_h["integrity"]

    assert_equal "baseline", baseline["tier"]
    assert_match(/detects accidental or ordinary modification/, baseline["detects"])
    assert_match(/does not establish who produced them/, baseline["detects"])
    assert_nil baseline["chain_scope"]

    chain_event_history!
    chained = submit_clickwrap(:signup, actor: create_user).to_h["integrity"]

    # The tier is read off what was actually recorded, never off the fact that
    # somebody turned a setting on, and the sentence changes with it.
    assert_equal "chained_history", chained["tier"]
    assert_equal "global/signup", chained["chain_scope"]
    assert_equal 1, chained["chain_sequence"]
    assert_match(/makes a rewrite of history detectable/, chained["detects"])
    assert_not_equal baseline["detects"], chained["detects"]
    assert_includes Clickwrap::Vocabulary::INTEGRITY_TIERS, chained["tier"]
  end

  private

  def chain_event_history!
    Clickwrap.configure { |config| config.chain_event_history_with = :sha256 }
  end

  def document_artifacts_for(receipt)
    receipt.documents.to_h do |binding|
      version = Clickwrap::DocumentVersion.find(binding.document_version_id)
      [
        "#{binding.document_key}@#{binding.version_label}",
        { source: version.content_bytes, rendered: version.rendered_bytes }
      ]
    end
  end
end

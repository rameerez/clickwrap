# frozen_string_literal: true

require "json"

module Clickwrap
  # The answer to "show me exactly what the application recorded."
  #
  # One canonical JSON body per event, plus a human-readable projection of the
  # same facts. The canonical form is what gets digested and independently
  # verified, so it is built from the stored evidence alone: no Ruby object
  # serialization, no current policy source, no database column order, no
  # locale-dependent number formatting. A verifier written years from now in
  # another language must be able to reproduce these bytes from the data.
  #
  # Raw IP address, browser user-agent, and IP-geolocation values are NOT in the
  # canonical body. They live in a separately encrypted annex with its own
  # authorization, retention, hold, and disposition state, and the body carries
  # only a keyed digest binding the two. That boundary is what lets the core
  # event stay immutable and verifiable when a permitted retention process later
  # removes the annex — deletion changes what a receipt can show, not what it
  # says happened.
  class Receipt
    SCHEMA = "clickwrap.receipt.v1"

    # The Clickwrap profile for timestamps: UTC, exactly six fractional digits,
    # `Z` suffix. Fixed width so two verifiers never disagree about whether a
    # trailing zero was significant.
    TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"

    attr_reader :event

    def initialize(event)
      @event = event
    end

    class << self
      def find(event_id)
        # The annex is eager-loaded only where it can exist. An installation
        # that records no request evidence never created that table, and
        # `includes` would read its schema before deciding there is nothing in
        # it. The receipt still reports every category by state — the states
        # just all come out `not_configured`, which is the true answer.
        associations = %i[statements documents policy_revision]
        associations << :request_evidence if SchemaRequirements.available?(:request_evidence)

        event = Event.includes(*associations).find_by(id: event_id)

        raise ReceiptInvalid, "No Clickwrap event with id #{event_id.inspect}" unless event

        new(event)
      end

      def format_time(time)
        return nil if time.nil?

        time.utc.strftime(TIME_FORMAT)
      end

      # An export names each sensitive field it includes. There is deliberately
      # no `include_sensitive_context: true`: one flag that turns on three
      # different categories of personal data is exactly the kind of option that
      # makes an operator's intent unreviewable.
      def export(receipt, requested_by: nil, because: nil,
                 include_ip_address: false, include_browser_user_agent: false,
                 include_ip_geolocation: false, access_channel: "export")
        receipt = find(receipt) if receipt.is_a?(String)
        requested = { ip_address: include_ip_address,
                      browser_user_agent: include_browser_user_agent,
                      ip_geolocation: include_ip_geolocation }

        authorize_export!(receipt, requested, requested_by, because)
        # A redacted receipt contains no annex value and therefore performs no
        # privileged read. It needs neither an access row nor a transaction of
        # its own; making ordinary exports depend on commit context would make
        # harmless rendering fail inside otherwise unrelated host work.
        return receipt.to_h unless requested.value?(true)

        refuse_export_inside_an_outer_transaction!

        exported = nil
        Event.transaction(requires_new: true) do
          event = Event.lock.find(receipt.event.id)
          current_receipt = new(event)
          included = requested.transform_keys(&:to_s)
          requested_by_reference = Reference.actor(requested_by)

          ReceiptAccess.record!(
            event: event,
            requested_by: requested_by,
            because: because,
            included_fields: included,
            access_channel: access_channel
          )

          Lifecycle.append_lifecycle_event!(
            event: event,
            event_type: "receipt_access",
            reason: because.presence || "Exported a redacted receipt",
            actor: requested_by,
            extra: {
              protected_outcome: {
                "receipt_access" => {
                  "requested_by_reference" => requested_by_reference,
                  "included_fields" => included,
                  "access_channel" => access_channel.to_s
                }.compact
              }
            }
          )

          exported = current_receipt.send(
            :to_h_with_revealed_request_evidence,
            requested.select { |_, wanted| wanted }.keys
          )
        end

        exported
      end

      # Verifies a receipt with no host application, no database, and no policy
      # source — the standalone path the CLI uses.
      def verify(canonical_json, documents: {})
        ReceiptVerifier.verify(canonical_json, documents: documents)
      end

      private

      def authorize_export!(receipt, requested, requested_by, because)
        return unless requested.any? { |_, wanted| wanted }

        if because.to_s.strip.empty?
          raise AccessNotAuthorized,
                "Reading unredacted request evidence needs a `because:` naming the specific " \
                "reason — an investigation, a dispute, a request. It is recorded with the access."
        end

        permitted = Clickwrap.config.authorize_unredacted_request_evidence_access_with
                             .call(requested_by, receipt, because)

        return if permitted

        raise AccessNotAuthorized,
              "The host's authorize_unredacted_request_evidence_access_with callback declined " \
              "this request for #{requested.select { |_, w| w }.keys.join(", ")}."
      end

      def refuse_export_inside_an_outer_transaction!
        return unless ::ActiveRecord::Base.connection.transaction_open?

        raise AccessNotAuthorized,
              "Receipt export cannot run inside an outer database transaction. Clickwrap records " \
              "the access event before returning any export; call it after the surrounding " \
              "transaction commits so the audit record cannot later roll back."
      end
    end

    # --- Identity -------------------------------------------------------------

    def event_id = event.id
    def policy_key = event.policy_key
    def recorded_at_by_server = event.recorded_at_by_server
    def actor_reference = event.actor_reference
    def actor = event.actor
    def subject = event.subject
    def committed? = true

    def statements = event.statements
    def documents = event.documents
    def request_evidence = event.request_evidence

    def held? = event.on_legal_hold?

    # --- Serialization --------------------------------------------------------

    # The canonical, digestible body.
    #
    # `integrity.receipt_digest` covers this exact body with only the
    # self-referential `integrity.receipt_digest` field removed — the digest
    # cannot cover itself, and the exclusion has to be one a verifier in another
    # language can reproduce without guessing. It is a
    # different value from `integrity.event_digest`, which the application
    # computed over the event's own canonical body when the event was written.
    # Both are reported, because they answer different questions: one says this
    # file has not been edited, the other says the row it describes has not been.
    #
    # An export that reveals request evidence is a different document from a
    # redacted one, so it carries a different receipt digest. That is correct:
    # each file verifies as the file it actually is.
    def to_h
      build_receipt_body(revealed_request_evidence: [])
    end

    def to_h_with_revealed_request_evidence(categories)
      build_receipt_body(revealed_request_evidence: Array(categories).map(&:to_sym))
    end
    private :to_h_with_revealed_request_evidence

    def build_receipt_body(revealed_request_evidence:)
      body = build_body(reveal: revealed_request_evidence)
      algorithm = event.digest_algorithm.presence || "sha256"
      covered = body.deep_dup

      body["integrity"]["receipt_digest"] = Digest.digest_canonical(covered, algorithm: algorithm)
      body
    end
    private :build_receipt_body

    def to_canonical_json = CanonicalJson.generate(to_h)

    def to_json(*) = to_canonical_json

    def as_json(*) = to_h

    # The human-readable projection. Same facts, rendered — never a different
    # set of facts, and never a stronger claim than the canonical body makes.
    def to_html(view_context: nil) = ReceiptHtml.new(self, view_context: view_context).render

    def build_body(reveal:)
      {
        "schema" => SCHEMA,
        "event_id" => event.id,
        "event_type" => event.event_type,
        "event" => event.canonical_body,
        "policy" => policy_fragment,
        "actor" => actor_fragment,
        "acts" => statements.map(&:canonical_fragment),
        "documents" => documents.map(&:canonical_fragment),
        "presentation" => presentation_fragment,
        "outcome" => event.protected_outcome.presence,
        "lifecycle" => lifecycle_fragment,
        "provider" => provider_fragment,
        "request_evidence" => request_evidence_fragment(reveal),
        "retention" => retention_fragment,
        "integrity" => integrity_fragment,
        "recorded_at_by_server" => self.class.format_time(event.recorded_at_by_server),
        "occurred_at" => self.class.format_time(event.occurred_at),
        "system" => system_fragment,
        "verifier_instructions" => verifier_instructions
      }.compact
    end
    private :build_body

    # PDF is optional rendering of the receipt, never the source of truth. The
    # gem ships no PDF dependency; a host configures a renderer if it wants one.
    def to_pdf(*)
      raise ConfigurationError,
            "Clickwrap does not render PDFs itself — a PDF library is not a dependency of an " \
            "evidence gem, and a PDF is a rendering of the receipt rather than the record. " \
            "Render `to_html` with your own PDF pipeline if you need one."
    end

    # --- Verification ---------------------------------------------------------

    def verify
      Verification.verify(event.id)
    end

    def digest_verified? = event.digest_verified?

    # --- Legal holds ----------------------------------------------------------

    def place_on_legal_hold!(because:, placed_by:, review_at:)
      SchemaRequirements.require!(:retention_ops)

      hold = nil

      ::ActiveRecord::Base.transaction do
        locked_event = Event.lock.find(event.id)
        hold = LegalHold.create!(
          hold_scope: "event",
          event_id: event.id,
          reason: because,
          placed_by_reference: reference_for(placed_by),
          placed_at: Clickwrap.now,
          review_at: review_at,
          created_at: Clickwrap.now
        )

        locked_event.set_legal_hold!(true)
        Lifecycle.append_lifecycle_event!(event: locked_event, event_type: "legal_hold_placed",
                                          reason: because, actor: placed_by)
      end

      hold
    end

    def release_legal_hold!(because:, released_by:)
      ::ActiveRecord::Base.transaction do
        locked_event = Event.lock.find(event.id)
        holds = LegalHold.lock.for_event(event.id).in_effect.to_a
        return nil if holds.empty?

        holds.each do |hold|
          hold.release!(because: because, released_by: released_by)
        end

        locked_event.set_legal_hold!(LegalHold.for_event(event.id).in_effect.exists?)
        Lifecycle.append_lifecycle_event!(event: locked_event, event_type: "legal_hold_released",
                                          reason: because, actor: released_by)
      end
    end

    def legal_holds = LegalHold.for_event(event.id)

    def inspect = "#<Clickwrap::Receipt #{event_id} #{policy_key}>"

    def to_s = event_id

    private

    def policy_fragment
      {
        "key" => event.policy_key,
        "revision" => event.policy_revision&.revision_digest,
        "retention_class" => event.retention_class_key
      }.compact
    end

    def actor_fragment
      {
        "reference" => event.actor_reference,
        "attribution" => {
          "method" => event.attribution_method,
          "authenticated" => event.attribution_method == "authenticated_session"
        },
        "authentication_method" => event.authentication_method,
        "snapshot" => event.actor_snapshot.presence,
        "acting_for" => acting_for_fragment,
        "tenant" => event.tenant_key,
        "subject" => subject_fragment
      }.compact
    end

    def acting_for_fragment
      return nil if event.represented_party_reference.blank?

      {
        "type" => event.represented_party_type,
        "reference" => event.represented_party_reference,
        "authority_source" => event.authority_source,
        "authority_role" => event.authority_role,
        "authority_verified_at" => self.class.format_time(event.authority_verified_at),
        "authority_details" => event.authority_details.presence
      }.compact
    end

    def subject_fragment
      return nil if event.subject_key.blank?

      { "reference" => event.subject_key, "fingerprint" => event.subject_fingerprint }.compact
    end

    def presentation_fragment
      return nil if event.presentation_manifest_digest.blank?

      manifest = event.presentation_manifest || {}

      {
        "manifest_digest" => event.presentation_manifest_digest,
        "submit_button_text" => manifest["submit_button_text"],
        "locale" => manifest["locale"],
        "capture_channel" => event.capture_channel,
        "offered_at" => manifest["issued_at"],
        # Said plainly, in the receipt itself, so nobody has to infer it: this
        # is what the server generated and accepted, not what a person read.
        "proves" => "The server generated this presentation manifest and accepted a submission " \
                    "bound to it. It does not establish that the person read or understood the " \
                    "documents, saw particular pixels, or received a legally sufficient interface."
      }.compact
    end

    def lifecycle_fragment
      successors = Event.where(root_event_id: event.id).or(Event.where(predecessor_event_id: event.id))
                        .chronological

      fragment = {
        "root_event_id" => event.root_event_id,
        "predecessor_event_id" => event.predecessor_event_id,
        "successors" => successors.map do |successor|
          {
            "event_id" => successor.id,
            "event_type" => successor.event_type,
            "recorded_at_by_server" => self.class.format_time(successor.recorded_at_by_server),
            "reason" => successor.reason,
            # A lifecycle summary without the successor's independently
            # digestible body could be rewritten and covered only by the
            # self-contained receipt digest. Embedding both lets the standalone
            # verifier re-derive every event that changed this receipt's state.
            "event" => successor.canonical_body,
            "event_digest" => successor.event_digest
          }.compact
        end
      }.compact

      fragment["successors"].empty? && fragment.length == 1 ? nil : fragment
    end

    def provider_fragment
      return nil if event.provider_name.blank?

      {
        "name" => event.provider_name,
        "event_id" => event.provider_event_id,
        "verification" => event.provider_verification.presence,
        # An imported provider event is not a click this application captured,
        # and the receipt says so rather than letting the two look alike.
        "note" => "Recorded from an external provider's receipt. Clickwrap did not present this " \
                  "content or observe this action."
      }.compact
    end

    # Five distinct states, kept distinct. "Blank" is never allowed to blur "we
    # chose not to collect this" into "collection failed" into "we deleted it
    # under a retention rule" — those tell a reader completely different things.
    def request_evidence_fragment(reveal)
      annex = request_evidence

      RequestEvidence::CATEGORIES.to_h do |category|
        [category.to_s, category_fragment(annex, category, reveal)]
      end
    end

    def category_fragment(annex, category, reveal)
      return { "state" => "not_configured" } if annex.nil?

      authorized = reveal.include?(category)
      state = annex.state_for(category, authorized_to_read: authorized, held: held?)

      fragment = { "state" => state }
      fragment["unavailable_reason"] = annex.unavailable_reason_for(category) if state == "unavailable"
      fragment["deleted_at"] = self.class.format_time(annex.public_send(:"#{category}_deleted_at")) if
        state == "deleted_after_retention"

      fragment.merge!(revealed_values(annex, category)) if authorized && state == "recorded"
      fragment
    end

    def revealed_values(annex, category)
      case category
      when :ip_address
        {
          "value" => annex.ip_address,
          "reader" => annex.ip_address_reader_name,
          "trusted_proxy_configuration_digest" => annex.trusted_proxy_configuration_digest,
          "recorded_at" => self.class.format_time(annex.ip_address_recorded_at),
          # Stated in the receipt because the alternative is a reader assuming
          # otherwise: an address is a network observation about a request.
          "means" => "IP address observed by the configured reader for this request. Not identity."
        }.compact
      when :browser_user_agent
        {
          "value" => annex.browser_user_agent,
          "was_client_supplied" => annex.browser_user_agent_was_client_supplied?,
          "recorded_at" => self.class.format_time(annex.browser_user_agent_recorded_at),
          "means" => "The User-Agent header the client sent. Client-supplied, and not a device " \
                     "identity or proof of what was rendered."
        }.compact
      when :ip_geolocation
        geolocation_values(annex)
      end
    end

    def geolocation_values(annex)
      values = annex.authorized_ip_geolocation_fields.to_h do |field|
        [field, geolocation_field_value(annex, field)]
      end.compact

      values.merge(
        "provider_name" => annex.ip_geolocation_provider_name,
        "provider_source" => annex.ip_geolocation_provider_source,
        "database_version" => annex.ip_geolocation_database_version,
        "database_sha256" => annex.ip_geolocation_database_sha256,
        "accuracy_radius_confidence_percentage" => annex.ip_geolocation_accuracy_radius_confidence_percentage,
        "was_estimated" => annex.ip_geolocation_was_estimated?,
        "source_was_verified_by_host" => annex.ip_geolocation_source_was_verified_by_host?,
        "resolved_at" => self.class.format_time(annex.ip_geolocation_resolved_at),
        "means" => "One provider's estimate for the observed IP address at the time shown. " \
                   "Not GPS, not a street address, and not proof that the person was there."
      ).compact
    end

    def geolocation_field_value(annex, field)
      case field
      when "country" then annex.ip_geolocation_country_code
      when "region" then annex.ip_geolocation_region_code || annex.ip_geolocation_region_name
      when "city" then annex.ip_geolocation_city_name
      when "postal_code" then annex.ip_geolocation_postal_code
      when "latitude_and_longitude"
        latitude = annex.ip_geolocation_latitude
        longitude = annex.ip_geolocation_longitude
        # Both or neither: half a coordinate is not a result, and a lone
        # latitude in an export invites someone to pair it with a guess.
        latitude && longitude ? { "latitude" => latitude.to_s, "longitude" => longitude.to_s } : nil
      when "timezone" then annex.ip_geolocation_timezone
      when "continent" then annex.ip_geolocation_continent_code
      when "metro_code" then annex.ip_geolocation_metro_code
      when "accuracy_radius_in_kilometers" then annex.ip_geolocation_accuracy_radius_in_kilometers
      end
    end

    def retention_fragment
      {
        "class" => event.retention_class_key,
        "core_event_retained_until" => self.class.format_time(event.retain_core_event_until),
        "retention_rule" => event.retention_rule_name,
        "core_event_disposed_at" => self.class.format_time(event.core_event_disposed_at),
        "on_legal_hold" => event.on_legal_hold?
      }.compact
    end

    # Each tier states exactly what it detects. The baseline claim is
    # deliberately modest, because a hash computed and stored by the same system
    # that stored the record cannot say more than this.
    def integrity_fragment
      {
        "digest_algorithm" => event.digest_algorithm,
        "event_digest" => event.event_digest,
        "previous_event_digest" => event.previous_event_digest,
        "chain_scope" => event.chain_scope,
        "chain_sequence" => event.chain_sequence,
        "request_evidence_category_binding_digests" =>
          event.request_evidence_category_binding_digests.presence,
        "request_evidence_digest_algorithm" => event.request_evidence_digest_algorithm,
        "request_evidence_key_id" => event.request_evidence_key_id,
        "request_evidence_binding_status" => event.request_evidence_binding_status.to_s,
        "attestations" => event.integrity_attestations.map(&:canonical_fragment).presence,
        "tier" => integrity_tier,
        "detects" => integrity_claim
      }.compact
    end

    def integrity_tier
      verified = event.integrity_attestations.select { |attestation| attestation.verified_for?(event) }
      return "third_party_timestamp" if verified.any? do |attestation|
        attestation.kind == "third_party_timestamp" &&
        attestation.adapter_capabilities.to_h["independently_verifiable"] == true
      end
      return "external_event_anchoring" if verified.any? do |attestation|
        attestation.kind == "event_anchor" &&
        attestation.adapter_capabilities.to_h["publishes_outside_primary_database"] == true
      end
      return "chained_history" if event.chain_scope.present?

      "baseline"
    end

    def integrity_claim
      case integrity_tier
      when "third_party_timestamp"
        "A configured timestamp provider returned a token over this exact event digest, and the " \
        "configured adapter recorded a successful verification. The provider result, status, " \
        "and capabilities are preserved so a reader can evaluate that provider's own claim."
      when "external_event_anchoring"
        "A configured adapter reported publishing this exact event chain position outside the " \
        "primary database, and its verifier accepted the stored publication result. This " \
        "improves detection only while that external publication remains available and trustworthy."
      when "chained_history"
        "Event digests are chained, which makes a rewrite of history detectable for as long as " \
        "the chain head remains trustworthy."
      else
        "The recorded digest detects accidental or ordinary modification of the bytes it covers. " \
        "It does not establish who produced them, when, or that a party controlling both the " \
        "application and the database could not have written both the record and the digest."
      end
    end

    def system_fragment
      {
        "gem_version" => event.gem_version,
        "application_version" => event.application_version,
        "template_version" => event.template_version,
        "canonical_schema_version" => event.canonical_schema_version,
        "verifier_version" => Clickwrap::VERIFIER_VERSION
      }.compact
    end

    def verifier_instructions
      receipt_check =
        "Remove only integrity.receipt_digest, canonicalize the remaining object with RFC 8785 " \
        "(JSON Canonicalization Scheme), and compare it with integrity.receipt_digest."

      event_check = if event.disposed?
                      "The original event payload was disposed of, so its event digest cannot be " \
                        "re-derived; verify the retained tombstone and the digest-bound disposition " \
                        "successor instead."
                    else
                      "Canonicalize event and compare it with integrity.event_digest."
                    end

      "#{receipt_check} #{event_check} Verify each documents[].source_digest and " \
        "documents[].rendered_digest against the corresponding source and rendered files in the " \
        "bundle. Run `clickwrap verify receipt.json --documents ./dir` to perform these checks " \
        "without the host application."
    end

    def reference_for(actor)
      Reference.actor(actor)
    end
  end
end

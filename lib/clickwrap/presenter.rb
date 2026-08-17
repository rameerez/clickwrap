# frozen_string_literal: true

module Clickwrap
  # Builds a presentation: resolves the policy's documents and copy for one
  # locale, records the exact call to action, and signs the result into a
  # short-lived token.
  #
  # This is the one place that turns a policy into something a person can see,
  # and everything that renders — the form-builder helper, the reference views,
  # the engine's standalone screen, a JSON API response, a fully custom design
  # system — goes through it. There is deliberately no second path: a shortcut
  # that skipped the manifest would produce evidence that looks identical and
  # proves considerably less.
  class Presenter
    # The only two kinds a composed sentence may absorb. A consent must stay
    # unbundled to be separately withdrawable and separately provable, and a
    # declaration, attestation, or authorization is a specific assertion someone
    # should have to read on its own line rather than find folded into a
    # sentence about something else.
    COMPOSABLE_KINDS = %w[agreement acknowledgment].freeze

    # Where a sentence fragment puts the documents it is about.
    DOCUMENTS_PLACEHOLDER = "%{documents}"

    Statement = Data.define(:key, :kind, :assertion, :label, :required, :optional, :choices,
                            :requires_an_explicit_choice, :documents, :control_name,
                            :control_id, :error_id, :purpose_key, :withdrawal_path) do
      def required? = required
      def optional? = optional
      def requires_an_explicit_choice? = requires_an_explicit_choice
      def checkbox? = choices.nil?
    end

    Document = Data.define(:key, :label, :version_label, :locale, :source_media_type,
                           :source_content_digest, :rendered_media_type,
                           :rendered_content_digest, :renderer_name, :renderer_version,
                           :sanitizer_name, :sanitizer_version, :version_id, :path)

    # One statement's share of a composed sentence, already split around the
    # place its documents go. Kept as parts rather than a template with a
    # placeholder so a view can drop real links into the middle of a sentence
    # without ever concatenating HTML into translated text.
    Fragment = Data.define(:statement_key, :kind, :prefix, :suffix, :documents, :documents_joiner) do
      def to_text = "#{prefix}#{documents.map(&:label).join(documents_joiner)}#{suffix}"
    end

    # The one control and the one sentence a composable policy renders. It is
    # not a statement and never becomes one: the statements it covers keep their
    # own kinds, documents, answers, and lifecycles in the evidence. What this
    # object describes is the offer a person saw.
    Combined = Data.define(:sentence, :fragments, :joiner, :terminator, :statement_keys,
                           :control_name, :control_id, :error_id) do
      def covers?(statement_key) = statement_keys.include?(statement_key.to_s)

      # Always. Only required statements compose, so the single control is
      # required too — which also lets a custom surface pass this object to
      # `clickwrap_statement_check_box` and get the same markup contract a
      # statement gets.
      def required? = true

      # The statement whose name the single control carries. Every covered
      # statement is answered by it; this is the one whose key it is submitted
      # under, so a browser sends one value and the server fans it out.
      def answered_as = statement_keys.first
    end

    Result = Data.define(:policy, :manifest, :token, :statements, :combined, :submit_button_text,
                         :locale, :actor, :subject, :represented_party, :tenant_key) do
      def statement(key) = statements.find { |candidate| candidate.key == key.to_s }
      def combined? = !combined.nil?
      def policy_key = policy.key
      def revision = manifest.revision_digest
      def to_h = manifest.to_h
      def as_json(*) = manifest.to_h

      # The statements this presentation renders as controls of their own:
      # everything the composed line could not honestly absorb.
      def itemized_statements
        return statements if combined.nil?

        statements.reject { |statement| combined.covers?(statement.key) }
      end
    end

    def initialize(policy:, actor: nil, subject: nil, tenant: nil, locale: nil,
                   submit_button_text: nil, capture_channel: :web_browser,
                   registration_flow_id: nil, prospective_actor: nil, acting_for: nil,
                   represented_party_creation_flow_id: nil,
                   authentication_context: nil,
                   document_version_path_with: nil,
                   default_document_version_path_with: nil,
                   combined: true)
      @policy = policy
      @actor = actor
      @prospective_actor = prospective_actor
      @subject = subject
      @tenant = tenant
      @locale = (locale || default_locale).to_s
      @submit_button_text = submit_button_text
      @capture_channel = capture_channel.to_s
      @registration_flow_id = registration_flow_id
      @acting_for = acting_for
      @represented_party_creation_flow_id = represented_party_creation_flow_id
      @authentication_context = (authentication_context || {}).to_h.symbolize_keys
      @document_version_path_with = document_version_path_with
      # Wired by `form.clickwrap` and `present_clickwrap` from the render
      # context, never by a host: it is the engine fallback with the render's
      # own Hotwire Native treatment attached, and it is asked LAST, after a
      # document's declared `link:` has had its say.
      @default_document_version_path_with = default_document_version_path_with
      @combined = combined != false

      return unless @document_version_path_with && !@document_version_path_with.respond_to?(:call)

      raise ArgumentError,
            "document_version_path_with must respond to call(version), so Clickwrap can bind " \
            "the exact immutable link target into the presentation."
    end

    attr_reader :policy, :actor, :subject, :tenant, :locale, :capture_channel

    def present
      policy.validate_tenant!(tenant)
      validate_actor_binding!
      validate_subject_binding!
      validate_represented_party_binding!
      validate_channel!
      validate_locale!
      authority_at_presentation = authority_at_presentation_snapshot

      revision = PolicyRevision.freeze_for(policy)
      resolved = policy.statements.map { |statement| resolve_statement(statement) }
      combined = compose(resolved)

      manifest = PresentationManifest.build(
        policy: policy,
        revision_digest: revision.revision_digest,
        statements: resolved.map { |statement| manifest_fragment(statement) },
        submit_button_text: @submit_button_text,
        locale: locale,
        actor_reference: actor_reference,
        actor_type: actor&.class&.name,
        tenant_key: tenant_key,
        subject_key: subject_key,
        subject_fingerprint: subject_fingerprint,
        registration_flow_id: @registration_flow_id,
        prospective_actor_type: @prospective_actor&.class&.name,
        represented_party_reference: represented_party_reference,
        represented_party_type: @acting_for&.class&.name,
        authority_rule: policy.authority_rule&.to_snapshot,
        represented_party_creation_flow_id: @represented_party_creation_flow_id,
        represented_party_will_be_created_by_protected_action:
          prospective_represented_party?,
        authority_at_presentation: authority_at_presentation,
        combined_control: combined_control_fragment(combined),
        capture_channel: capture_channel
      )

      persist_presentation(manifest, revision) if policy.persist_presentations?

      Result.new(
        policy: policy,
        manifest: manifest,
        token: manifest.to_token,
        statements: resolved,
        combined: combined,
        submit_button_text: @submit_button_text,
        locale: locale,
        actor: actor,
        subject: subject,
        represented_party: @acting_for,
        tenant_key: tenant_key
      )
    end

    # The fingerprint of whatever the policy says identifies this subject. It is
    # how an authorization for one withdrawal stops being usable for a different
    # one, and how a declaration about one set of orders stops covering a
    # changed set.
    def subject_fingerprint
      SubjectFingerprint.for(policy, subject)
    end

    def subject_key = StatementState.subject_key_for(subject)

    def tenant_key = Reference.tenant(tenant)

    def actor_reference
      return nil if actor.nil?

      Reference.actor(actor)
    end

    def represented_party_reference
      return nil if @acting_for.nil?
      return "represented_party_creation/#{@represented_party_creation_flow_id}" if prospective_represented_party?

      Reference.represented_party(@acting_for)
    end

    private

    def validate_subject_binding!
      return unless policy.subject_bound? && subject.nil?

      raise DefinitionError,
            "Policy #{policy.key} binds evidence to a subject fingerprint, so presenting it " \
            "requires `subject:`. A subject-bound policy cannot be completed from a generic " \
            "URL with no server-owned resource context."
    end

    def validate_actor_binding!
      return if actor

      unless @prospective_actor
        raise DefinitionError,
              "Presenting policy #{policy.key} without an actor requires `prospective_actor:`. " \
              "Use it only for a new account registration flow; anonymous users need an " \
              "explicit `Clickwrap.anonymous_actor(...)` reference."
      end

      return if @registration_flow_id.present?

      raise DefinitionError,
            "A prospective-actor presentation needs `registration_flow_id:` from server-owned " \
            "session state, so a token from another signup flow cannot create evidence for this account."
    end

    def validate_represented_party_binding!
      if @acting_for.nil?
        if @represented_party_creation_flow_id.present?
          raise DefinitionError,
                "A represented-party creation flow needs `acting_for:` to name the exact new record."
        end

        # A policy may support represented-party actions and ordinary personal
        # actions. No represented party on this particular presentation is a
        # valid, explicitly bound state.
        return
      end

      unless policy.permits_acting_for_party?(@acting_for)
        allowed = policy.authority_rule&.represented_party_types
        raise DefinitionError,
              "Policy #{policy.key} does not permit acting for #{@acting_for.class.name}. " \
              "Allowed represented-party types: #{allowed&.join(", ").presence || "(none)"}."
      end

      if prospective_represented_party?
        unless policy.authority_rule.allows_represented_party_creation?
          raise DefinitionError,
                "Policy #{policy.key} does not permit creating the represented party inside " \
                "the protected action. Opt in explicitly in the represented-party authority rule."
        end
        if @represented_party_creation_flow_id.blank?
          raise DefinitionError,
                "Presenting a new represented party needs " \
                "`represented_party_creation_flow_id:` from server-owned session state."
        end
      elsif @represented_party_creation_flow_id.present?
        raise DefinitionError,
              "`represented_party_creation_flow_id:` is only valid while `acting_for:` is a new record."
      end
    end

    def prospective_represented_party?
      @acting_for.respond_to?(:new_record?) && @acting_for.new_record?
    end

    def authority_at_presentation_snapshot
      return nil if @acting_for.nil?

      if prospective_represented_party?
        return {
          "state" => "not_yet_verifiable",
          "reason" => "represented_party_will_be_created_by_protected_action"
        }
      end

      AuthorityVerifier.verify!(
        policy: policy,
        actor: actor,
        represented_party: @acting_for,
        tenant: tenant,
        authentication_context: @authentication_context
      ).to_snapshot
    end

    def default_locale
      defined?(::I18n) ? ::I18n.locale : :en
    end

    def validate_channel!
      return if policy.permits_capture_channel?(capture_channel)

      raise DefinitionError,
            "Policy #{policy.key} does not accept captures from #{capture_channel}. It allows: " \
            "#{policy.capture_channels.join(", ")}."
    end

    def validate_locale!
      return if policy.permits_locale?(locale)

      raise MissingTranslation.new(key: policy.key, locale: locale)
    end

    def resolve_statement(statement)
      copy = statement.resolve_copy(locale: locale)
      documents = resolve_documents(statement)

      Statement.new(
        key: statement.key,
        kind: statement.kind,
        assertion: copy["assertion"],
        label: copy["label"],
        required: statement.required?,
        optional: statement.optional?,
        choices: statement.choices,
        requires_an_explicit_choice: statement.requires_an_explicit_choice?,
        documents: documents,
        control_name: control_name(statement),
        control_id: "clickwrap_#{policy.key}_#{statement.key}",
        error_id: "clickwrap_#{policy.key}_#{statement.key}_error",
        purpose_key: statement.purpose_key,
        withdrawal_path: statement.withdrawal_path
      )
    end

    # --- Composing the one-line offer ----------------------------------------
    #
    # A signup screen asks for two ordinary things — agree to the Terms,
    # acknowledge the Privacy Notice — and rendering them as two stacked
    # checkboxes with a "Required" flag, a version label, and an "(opens in a
    # new tab)" hint apiece is four times the interface the moment deserves.
    # When every statement is one of those ordinary things, they compose into
    # ONE control carrying ONE sentence with the documents linked inside it.
    #
    # Composing is a decision about PRESENTATION only. The evidence keeps every
    # statement separate — its own kind, its own documents, its own answer, its
    # own lifecycle — because "agreed to the Terms" and "acknowledged the
    # Privacy Notice" remain different facts no matter how few boxes it took to
    # say both.

    def compose(resolved)
      return nil unless @combined

      composable = resolved.select { |statement| composable?(statement) }
      return nil if composable.empty?

      connectives = sentence_connectives
      return nil if connectives.nil?

      fragments = composable.map { |statement| sentence_fragment(statement, connectives) }
      return nil if fragments.any?(&:nil?)

      build_combined(composable, fragments, connectives)
    end

    def build_combined(composable, fragments, connectives)
      control = composable.first

      Combined.new(
        sentence: fragments.map(&:to_text).join(connectives[:joiner]) + connectives[:terminator],
        fragments: fragments.freeze,
        joiner: connectives[:joiner],
        terminator: connectives[:terminator],
        statement_keys: composable.map(&:key).freeze,
        control_name: control.control_name,
        control_id: control.control_id,
        error_id: control.error_id
      )
    end

    # Every clause here is a way a statement can be more than the sentence can
    # honestly say. An optional consent bundled into a required line would make
    # it required; a choice folded into a checkbox would turn a recorded "no"
    # into an unrecorded silence; a statement with a withdrawal route needs that
    # route beside the control it belongs to; and copy the application wrote
    # itself is copy it wrote for a reason.
    def composable?(statement)
      return false unless COMPOSABLE_KINDS.include?(statement.kind)
      return false unless statement.required? && statement.checkbox?
      return false if statement.withdrawal_path.present?
      return false if statement.documents.empty?

      default_worded?(policy.statement!(statement.key))
    end

    # The assertion is still the conventional key the DSL fills in, so nobody
    # has chosen these words for this policy. A policy that did — a literal, a
    # locale map, its own I18n key — gets its own control and its own sentence,
    # unedited.
    def default_worded?(declared)
      declared.assertion.declaration == :"clickwrap.statements.#{declared.kind}.#{declared.key}"
    end

    # The words that hold a composed sentence together, in the locale being
    # presented. A locale that has not translated them composes nothing and
    # renders itemized instead — half a sentence in the wrong language is worse
    # than two tidy lines in the right one.
    def sentence_connectives
      joiner = sentence_text("joiner")
      documents_joiner = sentence_text("documents_joiner")
      terminator = sentence_text("terminator")
      return nil if joiner.nil? || documents_joiner.nil? || terminator.nil?

      { joiner: joiner, documents_joiner: documents_joiner, terminator: terminator }
    end

    def sentence_fragment(statement, connectives)
      template = sentence_text(statement.kind)
      return nil if template.nil?

      prefix, suffix = template.split(DOCUMENTS_PLACEHOLDER, 2)
      # A translation with nowhere to put the documents would render a sentence
      # about documents nobody can open. Itemize instead.
      return nil if suffix.nil?

      Fragment.new(
        statement_key: statement.key,
        kind: statement.kind,
        prefix: prefix,
        suffix: suffix,
        documents: statement.documents,
        documents_joiner: connectives[:documents_joiner]
      )
    end

    # What the manifest signs about a composed offer. The per-statement
    # fragments already carry the acts, the documents, and their digests; this
    # carries the thing only the composed shape has — the exact sentence a
    # person read, and which statement keys the one answer they gave covers.
    def combined_control_fragment(combined)
      return nil if combined.nil?

      {
        "sentence" => combined.sentence,
        "covers" => combined.statement_keys,
        "answered_as" => combined.answered_as,
        "control_name" => combined.control_name
      }
    end

    def sentence_text(key)
      return nil unless defined?(::I18n)

      text = ::I18n.t("clickwrap.sentence.#{key}", locale: locale, default: nil)
      text&.to_s
    end

    # The form field name. Answers arrive nested under one key so a host's
    # strong parameters can permit the whole envelope in one line, and so an
    # answer can never be mistaken for one of the host's own attributes.
    def control_name(statement)
      "clickwrap_submission[answers][#{statement.key}]"
    end

    def resolve_documents(statement)
      statement.document_keys.filter_map do |document_key|
        version = current_document_version(document_key)

        unless version
          raise DocumentNotPublishedError,
                "Policy #{policy.key} presents #{document_key} but no published version of it " \
                "is effective for locale #{locale}. Declare it with `Clickwrap.document " \
                "#{document_key.to_sym.inspect}, version: \"...\", from: ...` and run " \
                "`bin/rails clickwrap:publish`."
        end

        label, = statement.link_labels[document_key]&.resolve(locale: locale)

        Document.new(
          key: document_key,
          label: label || document_key.humanize,
          version_label: version.version_label,
          locale: version.locale,
          source_media_type: version.media_type,
          source_content_digest: version.content_digest,
          rendered_media_type: version.rendered_media_type.presence || version.media_type,
          rendered_content_digest: version.rendered_content_digest.presence || version.content_digest,
          renderer_name: version.renderer_name,
          renderer_version: version.renderer_version,
          sanitizer_name: version.sanitizer_name,
          sanitizer_version: version.sanitizer_version,
          version_id: version.id,
          path: document_path(version, declared_link_for(document_key, version))
        )
      end
    end

    # The `link:` the application declared for exactly these bytes: same tenant,
    # same key, same version label, same locale. Read from the registry rather
    # than the database because it is a presentation decision, not evidence —
    # the evidence is the digest of the bytes, which the row already holds.
    def declared_link_for(document_key, version)
      document = documents_for_this_policy[document_key.to_s]
      return nil unless document

      Clickwrap.documents[[document.tenant_key, document.document_key,
                           version.version_label, version.locale]]&.link
    end

    # Documents are immutable and published: within one presentation build, the
    # answer for a key cannot change, and two statements naming the same
    # document must get the same answer anyway. So every key this policy
    # references is resolved once, in two queries, rather than one lookup (or
    # two) plus a version query per statement-document pair.
    def current_document_version(document_key)
      current_document_versions[document_key.to_s]
    end

    def current_document_versions
      @current_document_versions ||= begin
        documents = documents_for_this_policy
        versions = newest_effective_versions_by_document_id(documents.values.map(&:id))

        documents.transform_values { |document| versions[document.id] }
      end
    end

    # The order here is the whole contract of a document link.
    #
    #   1. A resolver the CALLER passed wins outright: it is the host saying, at
    #      this call site, exactly where this document lives.
    #   2. The document's declared `link:` — the host's own reader-facing page.
    #   3. The render context's default resolver: the mounted engine route, with
    #      whatever Hotwire Native treatment this request calls for. It is given
    #      the declared link too, so a native render absolutizes a host page the
    #      same way it absolutizes an engine path.
    #   4. Nothing but the engine's own routes, which refuse rather than sign a
    #      path that resolves to nothing.
    def document_path(version, link)
      path =
        if @document_version_path_with
          @document_version_path_with.call(version)
        elsif @default_document_version_path_with
          @default_document_version_path_with.call(version, link)
        elsif link.present?
          link
        elsif defined?(Clickwrap::Engine)
          engine_document_version_path(version)
        end

      return path.to_s if path.present?

      raise ConfigurationError,
            "Clickwrap could not build the immutable URL for document version #{version.id}. " \
            "Present through form.clickwrap or present_clickwrap so the mounted route is known, " \
            "or pass document_version_path_with: ->(version) { ... }."
    rescue Clickwrap::Error
      raise
    rescue StandardError => error
      raise ConfigurationError,
            "Clickwrap could not build the immutable URL for document version #{version.id}: " \
            "#{error.class}: #{error.message}"
    end

    # The tenant's own document wins over the shared one, exactly as the
    # per-key lookup did. When there is no tenant the two scopes are the same
    # query, so only one is issued.
    def documents_for_this_policy
      @documents_for_this_policy ||= begin
        keys = policy.statements.flat_map(&:document_keys).uniq

        if keys.empty?
          {}
        else
          shared = ::Clickwrap::Document.where(document_key: keys, tenant_key: nil).index_by(&:document_key)

          if tenant_key.blank?
            shared
          else
            shared.merge(::Clickwrap::Document.for_tenant(tenant_key)
                                              .where(document_key: keys).index_by(&:document_key))
          end
        end
      end
    end

    # One query for every version this presentation could offer, ordered the
    # same way Document#current_version orders one document's versions, so the
    # first row per document is the one that method would have returned.
    def newest_effective_versions_by_document_id(document_ids)
      return {} if document_ids.empty?

      at = Clickwrap.now

      ::Clickwrap::DocumentVersion
        .published
        .effective_at_or_before(at)
        .not_retired_at(at)
        .for_locale(locale)
        .where(document_id: document_ids)
        .order(effective_at: :desc, published_at: :desc, created_at: :desc)
        .group_by(&:document_id)
        .transform_values(&:first)
    end

    # The engine's own URL helpers carry no mount prefix, so on an application
    # that never mounted the engine they answer with a path that resolves to
    # nothing. That answer would be *signed*: it goes into the manifest, into
    # the digest, and into the evidence as the exact document the person was
    # offered. A signed dead link is the worst failure this gem has — it looks
    # like evidence and cites a 404 — so it is refused at build time instead.
    def engine_document_version_path(version)
      ControllerHelpers.assert_engine_can_resolve_document_links!(version)

      Clickwrap::Engine.routes.url_helpers.document_version_path(version.id)
    end

    def manifest_fragment(statement)
      declared = policy.statement!(statement.key)

      {
        "key" => statement.key,
        "kind" => statement.kind,
        "assertion" => statement.assertion,
        "label" => statement.label,
        "required" => statement.required?,
        "optional" => statement.optional?,
        "choices" => statement.choices,
        "requires_an_explicit_choice" => statement.requires_an_explicit_choice?,
        "purpose" => statement.purpose_key,
        "withdrawal_path" => statement.withdrawal_path,
        "valid_for_seconds" => declared.valid_for&.to_i,
        "one_time" => declared.one_time?,
        "requires" => declared.requires,
        "requires_current_version" => declared.requires_current_version?,
        "subject_fingerprint" => subject_fingerprint_for(declared),
        "subject_fingerprint_version" => declared.subject_fingerprint_version,
        "protected_outcome_version" => declared.protected_outcome_version,
        "control_name" => statement.control_name,
        "documents" => statement.documents.map do |document|
          {
            "key" => document.key,
            "label" => document.label,
            "version" => document.version_label,
            "locale" => document.locale,
            "source_media_type" => document.source_media_type,
            "source_digest" => document.source_content_digest,
            "rendered_media_type" => document.rendered_media_type,
            "rendered_digest" => document.rendered_content_digest,
            "renderer" => {
              "name" => document.renderer_name,
              "version" => document.renderer_version,
              "sanitizer_name" => document.sanitizer_name,
              "sanitizer_version" => document.sanitizer_version
            }.compact.presence,
            "version_id" => document.version_id.to_s,
            "path" => document.path
          }
        end
      }.compact
    end

    def subject_fingerprint_for(statement)
      return nil unless statement.subject_bound?

      SubjectFingerprint.for_statement(statement, subject)
    end

    # Only written when a policy asked for it. The state is `presented_by_server`
    # and nothing stronger: the server generated and offered this. Whether a
    # human ever saw it is not something a web server can know.
    def persist_presentation(manifest, revision)
      Presentation.create!(
        policy_key: policy.key,
        policy_revision: revision,
        nonce: manifest.nonce,
        manifest: manifest.to_h,
        manifest_digest: manifest.digest,
        actor: actor.is_a?(::ActiveRecord::Base) ? actor : nil,
        actor_reference: actor_reference,
        registration_flow_id: @registration_flow_id,
        represented_party_type: @acting_for.is_a?(::ActiveRecord::Base) ? @acting_for.class.name : nil,
        represented_party_id: @acting_for.is_a?(::ActiveRecord::Base) ? @acting_for.id : nil,
        represented_party_reference: represented_party_reference.presence,
        tenant_key: tenant_key,
        subject: subject.is_a?(::ActiveRecord::Base) ? subject : nil,
        subject_fingerprint: subject_fingerprint,
        locale: locale,
        capture_channel: capture_channel,
        state: "presented_by_server",
        issued_at: manifest.issued_at,
        expires_at: manifest.expires_at,
        retain_until: Clickwrap.now + policy.persist_presentations_for,
        created_at: Clickwrap.now
      )
    end
  end
end

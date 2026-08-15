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
    Statement = Data.define(:key, :kind, :assertion, :label, :required, :optional, :choices,
                            :requires_an_explicit_choice, :documents, :control_name,
                            :control_id, :error_id, :purpose_key, :withdrawal_path) do
      def required? = required
      def optional? = optional
      def requires_an_explicit_choice? = requires_an_explicit_choice
      def checkbox? = choices.nil?
    end

    Document = Data.define(:key, :label, :version_label, :locale, :media_type,
                           :content_digest, :version_id, :path)

    Result = Data.define(:policy, :manifest, :token, :statements, :submit_button_text,
                         :locale, :actor, :subject, :tenant_key) do
      def statement(key) = statements.find { |candidate| candidate.key == key.to_s }
      def policy_key = policy.key
      def revision = manifest.revision_digest
      def to_h = manifest.to_h
      def as_json(*) = manifest.to_h
    end

    def initialize(policy:, actor: nil, subject: nil, tenant: nil, locale: nil,
                   submit_button_text: nil, capture_channel: :web_browser,
                   registration_flow_id: nil, prospective_actor: nil)
      @policy = policy
      @actor = actor
      @prospective_actor = prospective_actor
      @subject = subject
      @tenant = tenant
      @locale = (locale || default_locale).to_s
      @submit_button_text = submit_button_text
      @capture_channel = capture_channel.to_s
      @registration_flow_id = registration_flow_id
    end

    attr_reader :policy, :actor, :subject, :tenant, :locale, :capture_channel

    def present
      validate_channel!
      validate_locale!

      revision = PolicyRevision.freeze_for(policy)
      resolved = policy.statements.map { |statement| resolve_statement(statement) }

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
        capture_channel: capture_channel
      )

      persist_presentation(manifest, revision) if policy.persist_presentations?

      Result.new(
        policy: policy,
        manifest: manifest,
        token: manifest.to_token,
        statements: resolved,
        submit_button_text: @submit_button_text,
        locale: locale,
        actor: actor,
        subject: subject,
        tenant_key: tenant_key
      )
    end

    # The fingerprint of whatever the policy says identifies this subject. It is
    # how an authorization for one withdrawal stops being usable for a different
    # one, and how a declaration about one set of rides stops covering a changed
    # set.
    def subject_fingerprint
      return nil if subject.nil?

      fingerprinting = policy.statements.find(&:subject_bound?)
      return nil unless fingerprinting

      value = fingerprinting.subject_fingerprint_with.call(subject)
      value.nil? ? nil : Digest.digest(value.to_s)
    end

    def subject_key = StatementState.subject_key_for(subject)

    def tenant_key
      return nil if tenant.nil?
      return tenant.to_s if tenant.is_a?(String) || tenant.is_a?(Symbol)
      return tenant.to_gid.to_s if tenant.respond_to?(:to_gid)

      "#{tenant.class.name}/#{tenant.id}"
    end

    def actor_reference
      return nil if actor.nil?

      Clickwrap.config.identify_actor_with.call(actor)
    end

    private

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
          media_type: version.media_type,
          content_digest: version.content_digest,
          version_id: version.id,
          path: document_path(version)
        )
      end
    end

    def current_document_version(document_key)
      document = ::Clickwrap::Document.for_tenant(tenant_key).find_by(key: document_key)
      document ||= ::Clickwrap::Document.find_by(key: document_key, tenant_key: nil)

      document&.current_version(locale: locale)
    end

    def document_path(version)
      return nil unless defined?(Clickwrap::Engine)

      Clickwrap::Engine.routes.url_helpers.document_version_path(version.id)
    rescue StandardError
      nil
    end

    def manifest_fragment(statement)
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
        "control_name" => statement.control_name,
        "documents" => statement.documents.map do |document|
          {
            "key" => document.key,
            "label" => document.label,
            "version" => document.version_label,
            "locale" => document.locale,
            "media_type" => document.media_type,
            "digest" => document.content_digest,
            "version_id" => document.version_id.to_s
          }
        end
      }.compact
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

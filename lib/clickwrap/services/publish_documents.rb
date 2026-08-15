# frozen_string_literal: true

module Clickwrap
  module Services
    # `bin/rails clickwrap:publish` — reads the declared document bytes once,
    # digests them, and freezes a database snapshot.
    #
    # After this runs, the snapshot is the evidence and the file on disk is only
    # where it came from. Editing the file changes nothing about what was
    # already published, which is exactly the property a receipt from three
    # years ago depends on.
    #
    # The task is idempotent: re-publishing identical bytes under the same label
    # is a no-op. Re-publishing *different* bytes under the same label is
    # refused, because a version label that can mean two different documents is
    # not a version label.
    class PublishDocuments
      Outcome = Data.define(:definition, :status, :version, :message) do
        def published? = status == :published
        def unchanged? = status == :unchanged
        def planned? = status == :planned
      end

      def initialize(dry_run: false, definitions: nil)
        @dry_run = dry_run
        @definitions = definitions || Clickwrap.documents.values
      end

      attr_reader :dry_run, :definitions

      def call
        definitions.map { |definition| publish(definition) }
      end

      alias plan call

      private

      def publish(definition)
        bytes = definition.read_bytes
        digest = Digest.digest(bytes, algorithm: digest_algorithm)
        existing = find_existing(definition)

        if existing
          return conflict(definition, existing, digest) unless matches?(existing, digest)

          return Outcome.new(definition: definition, status: :unchanged, version: existing,
                             message: "Already published with identical bytes.")
        end

        if dry_run
          return Outcome.new(definition: definition, status: :planned, version: nil,
                             message: "Would publish #{bytes.bytesize} bytes (#{digest}).")
        end

        Outcome.new(definition: definition, status: :published,
                    version: create_version(definition, bytes, digest),
                    message: "Published #{bytes.bytesize} bytes (#{digest}).")
      end

      def find_existing(definition)
        document = ::Clickwrap::Document.find_by(
          key: definition.key, tenant_key: definition.tenant_key
        )
        return nil unless document

        document.versions.find_by(version_label: definition.version_label, locale: definition.locale)
      end

      def matches?(existing, digest)
        Digest.secure_compare?(existing.content_digest, digest)
      end

      # The refusal a version label exists to make possible.
      def conflict(definition, existing, digest)
        raise DocumentVersionConflictError,
              "Document #{definition} was already published with different bytes.\n" \
              "  published: #{existing.content_digest}\n" \
              "  on disk:   #{digest}\n\n" \
              "Reusing a version label for different content would silently change what every " \
              "receipt that cites this version says the person was shown. Publish the new text " \
              "under a new version label instead."
      end

      def create_version(definition, bytes, digest)
        ::ActiveRecord::Base.transaction do
          document = ::Clickwrap::Document.find_or_create_by!(
            key: definition.key, tenant_key: definition.tenant_key
          ) { |record| record.created_at = Clickwrap.now }

          rendered = render(definition, bytes)
          backend = storage_backend_for(definition)

          document.versions.create!(
            version_label: definition.version_label,
            locale: definition.locale,
            media_type: definition.media_type,
            content: backend == "database" ? bytes : nil,
            storage_locator: backend == "active_storage" ? store_in_active_storage(definition, bytes) : nil,
            content_byte_size: bytes.bytesize,
            content_digest_algorithm: digest_algorithm,
            content_digest: digest,
            rendered_content: rendered&.fetch(:bytes, nil),
            rendered_media_type: rendered&.fetch(:media_type, nil),
            rendered_content_digest: rendered && Digest.digest(rendered[:bytes], algorithm: digest_algorithm),
            renderer_name: rendered&.fetch(:renderer_name, nil),
            renderer_version: rendered&.fetch(:renderer_version, nil),
            sanitizer_name: rendered&.fetch(:sanitizer_name, nil),
            sanitizer_version: rendered&.fetch(:sanitizer_version, nil),
            storage_backend: backend,
            source_reference: definition.source_reference,
            # A version with no declared schedule is effective as soon as it is
            # published. Storing that explicitly rather than leaving NULL keeps
            # "which version is current" a deterministic question: PostgreSQL
            # sorts NULLs first in a descending order and SQLite sorts them
            # last, so a nullable column here would mean two databases
            # disagreeing about which document a person was shown.
            effective_at: definition.effective_at || Clickwrap.now,
            published_at: Clickwrap.now,
            created_at: Clickwrap.now
          )
        end
      end

      # When a source format is transformed for display, the rendered bytes are
      # stored and digested alongside the source. That keeps "this Markdown file
      # existed" and "this rendered representation was offered" as two separate
      # claims instead of letting one borrow the other's credibility.
      #
      # A custom renderer must return the exact bytes it offered. It is given
      # no opportunity to render one thing and report another.
      def render(definition, bytes)
        renderer = definition.renderer || Clickwrap.config.document_renderer
        return nil unless renderer

        result = renderer.call(bytes, definition)
        return nil if result.nil?

        result = { bytes: result } if result.is_a?(String)
        result = result.symbolize_keys

        unless result[:bytes].is_a?(String)
          raise ConfigurationError,
                "A document renderer must return the exact rendered bytes as a String (or a Hash " \
                "with a :bytes key). It returned #{result[:bytes].class}."
        end

        result
      end

      # Where the bytes come FROM and where they are KEPT are different
      # questions, and a per-document `resolver:` answers the first one only —
      # exactly like `from:` and `content:`. Publishing calls it once, and from
      # then on the frozen snapshot is the evidence.
      #
      # `config.store_document_contents_in = :resolver` is the other question:
      # it says the application will hand back the bytes on every read rather
      # than have Clickwrap keep them. That adapter still has to return
      # immutable bytes that hash to the recorded digest, which is verified on
      # every read.
      def storage_backend_for(_definition)
        Clickwrap.config.store_document_contents_in.to_s
      end

      # Larger applications can keep document bodies in content-addressed object
      # storage instead of the database. The contract does not change: whatever
      # the adapter returns must be the exact immutable bytes, and the digest
      # recorded here is verified against them on every read. A locator alone is
      # never a document version.
      def store_in_active_storage(definition, bytes)
        unless defined?(::ActiveStorage)
          raise ConfigurationError,
                "store_document_contents_in is :active_storage, but Active Storage is not loaded " \
                "in this application. Clickwrap does not depend on it; require it, or use " \
                ":database."
        end

        blob = ::ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes),
          filename: "#{definition.key}-#{definition.version_label}-#{definition.locale}",
          content_type: definition.media_type,
          identify: false
        )

        blob.signed_id
      end

      def digest_algorithm = Clickwrap.config.digest_canonical_receipts_with.to_s
    end
  end
end

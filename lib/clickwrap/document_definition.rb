# frozen_string_literal: true

module Clickwrap
  # A declared document version, before it is published.
  #
  #   Clickwrap.document :terms,
  #     version: "2026-08-15",
  #     locale: :en,
  #     effective_at: Time.utc(2026, 8, 15),
  #     from: Rails.root.join("app/content/legal/terms.en.md")
  #
  # The declaration says which bytes to publish. `bin/rails clickwrap:publish`
  # reads them once, digests them, and freezes a database snapshot. From then
  # on the snapshot is the evidence; the file on disk is only where it came
  # from. Changing the file does not change published evidence, and reusing a
  # version label for different bytes is refused rather than silently accepted.
  class DocumentDefinition
    SOURCE_KINDS = %i[file inline resolver].freeze

    MEDIA_TYPES_BY_EXTENSION = {
      ".md" => "text/markdown",
      ".markdown" => "text/markdown",
      ".html" => "text/html",
      ".htm" => "text/html",
      ".txt" => "text/plain",
      ".json" => "application/json",
      ".pdf" => "application/pdf"
    }.freeze

    REFUSED_VERSION_LABELS = %w[unversioned current latest head none default].freeze

    attr_reader :key, :version_label, :locale, :media_type, :effective_at,
                :tenant_key, :source_kind, :source_reference, :inline_content,
                :resolver, :renderer

    def initialize(key:, version:, locale: :en, media_type: nil, effective_at: nil,
                   tenant: nil, from: nil, content: nil, resolver: nil, renderer: nil)
      @key = normalize_key(key)
      @version_label = normalize_version(version)
      @locale = locale.to_s
      @effective_at = effective_at
      @tenant_key = tenant&.to_s
      @renderer = renderer

      assign_source(from:, content:, resolver:)
      @media_type = (media_type || infer_media_type).to_s

      validate!
      freeze
    end

    # Reads the exact bytes this definition points at. Called at publish time,
    # never at export time: an export that re-read a mutable source and called
    # the result historical evidence would be a lie.
    def read_bytes
      case source_kind
      when :inline then inline_content.to_s.dup
      when :file then read_file_bytes
      when :resolver then read_resolver_bytes
      end
    end

    def identity = [tenant_key, key, version_label, locale]

    def to_s
      "#{key} #{version_label} (#{locale})"
    end

    private

    def assign_source(from:, content:, resolver:)
      provided = { from:, content:, resolver: }.compact

      if provided.length > 1
        raise DefinitionError,
              "Document #{key} #{version_label} declares #{provided.keys.join(" and ")}. " \
              "Give it exactly one source."
      end

      if from
        @source_kind = :file
        @source_reference = from.to_s
      elsif content
        @source_kind = :inline
        @inline_content = content.to_s
        @source_reference = "inline"
      elsif resolver
        @source_kind = :resolver
        @resolver = resolver
        @source_reference = "resolver"
      else
        raise DefinitionError,
              "Document #{key} #{version_label} has no source. Use `from:` with a path, " \
              "`content:` with a string, or `resolver:` with something that returns bytes."
      end
    end

    def read_file_bytes
      unless File.exist?(source_reference)
        raise DocumentNotPublishedError,
              "Document #{self} points at #{source_reference}, which does not exist."
      end

      File.binread(source_reference)
    end

    def read_resolver_bytes
      bytes = resolver.respond_to?(:call) ? resolver.call(self) : resolver.read(self)

      if bytes.nil? || bytes.to_s.empty?
        raise DocumentNotPublishedError,
              "The resolver for document #{self} returned no bytes."
      end

      bytes.to_s
    end

    def infer_media_type
      return "text/plain" unless source_kind == :file

      MEDIA_TYPES_BY_EXTENSION.fetch(File.extname(source_reference).downcase, "text/plain")
    end

    def normalize_key(value)
      normalized = value.to_s
      raise DefinitionError, "A document needs a key, for example :terms" if normalized.empty?

      normalized
    end

    # A version label is the application's own name for a frozen set of bytes.
    # Clickwrap does not interpret it — a date, a semantic version, and a git
    # SHA are all fine — but it refuses the placeholder labels applications
    # reach for when they have not really versioned anything, because a policy
    # that requires a current version cannot be satisfied by "unversioned".
    def normalize_version(value)
      normalized = value.to_s.strip

      if normalized.empty?
        raise DefinitionError,
              "Document #{key} needs a `version:` label, for example \"2026-08-15\"."
      end

      if REFUSED_VERSION_LABELS.include?(normalized.downcase)
        raise DefinitionError,
              "Document #{key} cannot use the version label #{normalized.inspect}: it names a " \
              "moving target rather than a frozen set of bytes. Use a date, a release tag, or " \
              "any label you will never reuse for different content."
      end

      normalized
    end

    def validate!
      return unless effective_at && !effective_at.respond_to?(:to_time)

      raise DefinitionError,
            "Document #{self} has an `effective_at:` that is not a time."
    end
  end
end

# frozen_string_literal: true

module Clickwrap
  # A declared document version, before it is published.
  #
  #   Clickwrap.document :terms,
  #     from: Rails.root.join("app/content/legal/terms.md")
  #
  #   Clickwrap.document :terms,
  #     version: "2026-08-15",
  #     locale: :en,
  #     effective_at: Time.utc(2026, 8, 15),
  #     from: Rails.root.join("app/content/legal/terms.en.md")
  #
  #   Clickwrap.document :terms,
  #     from: Rails.root.join("app/content/legal/terms.md"),
  #     link: "/legal/terms"
  #
  # `link:` is where a PERSON reads this document — the host's own formatted
  # page, with its typography, its navigation, and its language switcher —
  # rather than the engine's plain rendering of the published bytes. It is the
  # path Clickwrap presents beside the control AND the path it signs into the
  # presentation manifest, so the evidence never cites a different target from
  # the link somebody could actually press.
  #
  # The trade is explicit and belongs to the host: a host page shows whatever
  # is current, so the signed path is a stable address rather than an immutable
  # snapshot. The bytes are still frozen, digested, and recorded — what changes
  # is which URL the receipt says was offered. A host that wants the immutable
  # rendering in the evidence simply leaves `link:` off and gets the engine's
  # per-version route, as before.
  #
  # The declaration says which bytes to publish. `bin/rails clickwrap:publish`
  # reads them once, digests them, and freezes a database snapshot. From then
  # on the snapshot is the evidence; the file on disk is only where it came
  # from. Changing the file does not change published evidence, and reusing a
  # version label for different bytes is refused rather than silently accepted.
  #
  # `version:` is optional exactly when the source can name its own: a file or
  # inline content whose leading YAML front matter carries `clickwrap_version:`
  # (or `last_updated:`) IS the single source of truth for its label, so
  # bumping a legal text is one edit in one file. A source with no front-matter
  # version and no explicit `version:` is refused at boot with a sentence —
  # Clickwrap never invents a label, because a policy that requires a current
  # version cannot be satisfied by a guess.
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

    # A `link:` is rendered as an href and signed into evidence, so it has to be
    # somewhere a browser can navigate. Anything else — `javascript:`, `data:`,
    # a bare word — would be a scheme the gem itself painted into a page.
    LINK_SCHEMES = %r{\A(?:/[^/]|/\z|https://|http://)}

    attr_reader :key, :version_label, :locale, :media_type, :effective_at,
                :tenant_key, :source_kind, :source_reference, :inline_content,
                :resolver, :renderer, :link

    def initialize(key:, version: nil, locale: :en, media_type: nil, effective_at: nil,
                   tenant: nil, from: nil, content: nil, resolver: nil, renderer: nil,
                   link: nil)
      @key = normalize_key(key)
      @locale = locale.to_s
      @effective_at = effective_at
      @tenant_key = tenant&.to_s
      @renderer = renderer
      @link = normalize_link(link)

      assign_source(from:, content:, resolver:)
      @version_label = normalize_version(version || version_label_from_front_matter)
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

    # No explicit `version:` was given, so the source itself must name one
    # through its leading YAML front matter. Every refusal here is a boot
    # failure with the fix in the sentence, because a silently invented label
    # would let "unversioned" evidence masquerade as versioned.
    def version_label_from_front_matter
      case source_kind
      when :file then file_front_matter_version_label
      when :inline then inline_front_matter_version_label
      else
        raise DefinitionError,
              "Document #{key} has no `version:`, and a `resolver:` source cannot name its own " \
              "version at boot because its bytes are only read at publish time. Pass `version:` " \
              "explicitly, for example version: \"2026-08-15\"."
      end
    end

    def file_front_matter_version_label
      unless File.exist?(source_reference)
        raise DefinitionError,
              "Document #{key} has no `version:` and its file #{source_reference} does not " \
              "exist yet, so there is no front matter to read one from. Create the file with a " \
              "`clickwrap_version:` or `last_updated:` front-matter key, or pass `version:` " \
              "explicitly."
      end

      FrontMatter.version_label_in(File.read(source_reference)) ||
        raise(DefinitionError,
              "Document #{key} has no `version:` and #{source_reference} has no " \
              "`clickwrap_version:` or `last_updated:` front-matter key. The version label has " \
              "no other source of truth — add one of those keys to the file's front matter " \
              "(`clickwrap_version:` wins when both are present), or pass `version:` explicitly.")
    end

    def inline_front_matter_version_label
      FrontMatter.version_label_in(inline_content) ||
        raise(DefinitionError,
              "Document #{key} has no `version:` and its inline `content:` has no " \
              "`clickwrap_version:` or `last_updated:` front-matter key. Add one to the " \
              "content's leading front matter, or pass `version:` explicitly.")
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

    def normalize_link(value)
      return nil if value.nil?

      normalized = value.to_s.strip
      return nil if normalized.empty?

      unless normalized.match?(LINK_SCHEMES)
        raise DefinitionError,
              "Document #{key} has a `link:` of #{value.inspect}. A link is the page a person " \
              "reads this document on, so it must be a root-relative path (\"/legal/terms\") or " \
              "an absolute http(s) URL. Clickwrap renders it as an href and signs it into the " \
              "presentation manifest, and it will not sign a scheme it cannot navigate to."
      end

      normalized.freeze
    end

    def validate!
      return unless effective_at && !effective_at.respond_to?(:to_time)

      raise DefinitionError,
            "Document #{self} has an `effective_at:` that is not a time."
    end
  end
end

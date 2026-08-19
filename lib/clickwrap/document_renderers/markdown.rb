# frozen_string_literal: true

module Clickwrap
  module DocumentRenderers
    # Optional Markdown rendering for the representation people are offered.
    #
    # The reference renderer deliberately escapes Markdown into a <pre> block:
    # faithful, dependency-free, and ugly for a forty-page Terms document. This
    # renderer produces real HTML instead, using whichever Markdown library the
    # application already bundles — it is opt-in and it adds no dependency:
    #
    #   Clickwrap.configure do |config|
    #     config.document_renderer = :markdown
    #   end
    #
    # Three engines are recognized, in order: Commonmarker (1.x and the older
    # CommonMarker 0.x), Redcarpet, and Kramdown. An application whose Markdown
    # dialect needs specific options can inject its own rendering instead and
    # must name it, because the receipt records which renderer produced the
    # offered bytes:
    #
    #   config.document_renderer = Clickwrap::DocumentRenderers::Markdown.new(
    #     render_markdown_with: ->(markdown_text) { MyMarkdown.render(markdown_text) },
    #     engine_name: "my_markdown",
    #     engine_version: MyMarkdown::VERSION
    #   )
    #
    # A leading YAML front-matter block (the Jekyll/Sitepress convention) is
    # stripped from the RENDERED representation only — the source digest still
    # covers the exact file bytes, front matter included. Bundled engines'
    # output always passes through the same safe-list sanitizer as the
    # reference renderer, so a Markdown library's raw-HTML passthrough cannot
    # smuggle markup into an offer. A host-supplied `render_markdown_with:`
    # may additionally pass `sanitize_rendered_html: false` when its own pages
    # serve the renderer's output verbatim: re-sanitizing reparses the HTML
    # and changes its bytes, and a stored digest must describe exactly what
    # readers were shown. The provenance records which choice was made.
    # Non-Markdown documents delegate to the reference renderer unchanged.
    class Markdown
      NAME = "clickwrap_markdown_document_renderer"
      VERSION = "1"

      def initialize(render_markdown_with: nil, engine_name: nil, engine_version: nil,
                     sanitize_rendered_html: true)
        @sanitize_rendered_html = sanitize_rendered_html != false

        if !@sanitize_rendered_html && render_markdown_with.nil?
          raise ConfigurationError,
                "sanitize_rendered_html: false is only available with your own " \
                "render_markdown_with. Clickwrap's bundled engines always sanitize; skipping " \
                "sanitization is a promise about a rendering pipeline YOU own — that its " \
                "output is exactly what your own pages already serve to readers."
        end

        if render_markdown_with
          unless render_markdown_with.respond_to?(:call)
            raise ConfigurationError,
                  "render_markdown_with must respond to call(markdown_text) and return HTML."
          end
          if engine_name.to_s.strip.empty?
            raise ConfigurationError,
                  "A custom render_markdown_with needs an engine_name (and ideally an " \
                  "engine_version), because receipts record which renderer produced the " \
                  "bytes a person was offered."
          end

          @render_markdown = render_markdown_with
          @engine_name = engine_name.to_s
          @engine_version = engine_version.to_s.strip.empty? ? "unstated" : engine_version.to_s
        else
          @render_markdown, @engine_name, @engine_version = resolve_bundled_engine
        end

        @fallback = DocumentRenderer.new
      end

      attr_reader :engine_name, :engine_version

      def call(bytes, definition)
        return @fallback.call(bytes, definition) unless definition.media_type == "text/markdown"

        text = utf8_text!(bytes, definition)
        html = @render_markdown.call(FrontMatter.strip(text))

        if @sanitize_rendered_html
          {
            bytes: DocumentRenderer.sanitize_html(html),
            media_type: "text/html; charset=utf-8",
            renderer_name: NAME,
            renderer_version: "#{VERSION} (#{@engine_name} #{@engine_version})",
            sanitizer_name: DocumentRenderer::SANITIZER_NAME,
            sanitizer_version: DocumentRenderer::SANITIZER_VERSION
          }
        else
          # Byte parity with the host's own pages is the point: re-sanitizing
          # reparses and re-serializes the HTML, so the stored digest would
          # describe bytes nobody was ever shown. The provenance says plainly
          # that no sanitizer ran — the host's rendering pipeline owns safety.
          {
            bytes: html.to_s.dup.force_encoding(Encoding::UTF_8),
            media_type: "text/html; charset=utf-8",
            renderer_name: NAME,
            renderer_version: "#{VERSION} (#{@engine_name} #{@engine_version})",
            sanitizer_name: "none",
            sanitizer_version: "host_renderer_output_stored_verbatim"
          }
        end
      end

      private

      def resolve_bundled_engine
        commonmarker_engine || redcarpet_engine || kramdown_engine ||
          raise(ConfigurationError,
                "config.document_renderer = :markdown needs a Markdown library, and none of " \
                "the ones Clickwrap recognizes (commonmarker, redcarpet, kramdown) is " \
                "available in this application. Add one of them to your Gemfile, or supply " \
                "your own rendering with " \
                "Clickwrap::DocumentRenderers::Markdown.new(render_markdown_with:, engine_name:).")
      end

      def commonmarker_engine
        attempt_require("commonmarker")

        if defined?(::Commonmarker)
          [->(text) { ::Commonmarker.to_html(text) }, "commonmarker", loaded_gem_version("commonmarker")]
        elsif defined?(::CommonMarker)
          [->(text) { ::CommonMarker.render_html(text) }, "commonmarker", loaded_gem_version("commonmarker")]
        end
      end

      def redcarpet_engine
        attempt_require("redcarpet")
        return unless defined?(::Redcarpet::Markdown)

        # A fresh renderer per call: Redcarpet's renderer objects carry state
        # between renders and are not safe to share across threads.
        render = lambda do |text|
          ::Redcarpet::Markdown.new(
            ::Redcarpet::Render::HTML.new(with_toc_data: true),
            tables: true, autolink: true, fenced_code_blocks: true, strikethrough: true,
            footnotes: true, no_intra_emphasis: true
          ).render(text)
        end
        [render, "redcarpet", loaded_gem_version("redcarpet")]
      end

      def kramdown_engine
        attempt_require("kramdown")
        return unless defined?(::Kramdown::Document)

        [->(text) { ::Kramdown::Document.new(text).to_html }, "kramdown", loaded_gem_version("kramdown")]
      end

      def attempt_require(name)
        require name
      rescue LoadError
        nil
      end

      def loaded_gem_version(name)
        Gem.loaded_specs[name]&.version&.to_s || "unstated"
      end

      def utf8_text!(bytes, definition)
        text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        return text if text.valid_encoding?

        raise DefinitionError,
              "Document #{definition} cannot be rendered as Markdown because its bytes are " \
              "not valid UTF-8."
      end
    end
  end
end

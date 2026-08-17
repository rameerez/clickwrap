# frozen_string_literal: true

module Clickwrap
  module DocumentRenderers
    # Byte parity with the application's own pages, by construction.
    #
    # Content-file Rails apps (Sitepress and friends) render their public
    # legal pages through the `markdown-rails` gem, whose initializer
    # registers a renderer for `.md` templates:
    #
    #   MarkdownRails.handle :md do
    #     ApplicationMarkdown.new
    #   end
    #
    # When the same files are also Clickwrap documents, what people accept and
    # what the public page serves must be the SAME BYTES — same renderer, same
    # options, no re-sanitization pass changing entities behind the digest.
    # Wiring that by hand means a lambda, an engine name, gem versions, and a
    # parity test, all copied between applications. This renderer says it once:
    #
    #   Clickwrap.configure do |config|
    #     config.document_renderer = :markdown_rails
    #   end
    #
    # At render time it asks markdown-rails for the exact renderer object the
    # application's own `.md` pages go through, renders through it, stores the
    # output verbatim (`sanitizer_name: "none"` in the provenance — safety
    # stays where it already lives, in the pipeline every public page trusts),
    # and records honest provenance: the renderer class the application
    # registered, plus the markdown-rails and Markdown-engine gem versions.
    #
    # The handler is resolved LAZILY, at first render, never at configuration
    # time: Rails initializers run alphabetically, so `clickwrap.rb` usually
    # runs before `markdown.rb`, and an eager lookup would capture the stock
    # default renderer instead of the application's own.
    #
    # Honest bound: the renderer is called directly, without a view context —
    # exactly how a frozen document must render, because a snapshot cannot
    # depend on the request it happened to be published during. Markdown that
    # calls Rails view helpers (image_tag and friends) fails loudly at publish;
    # documents like that need the explicit lambda form of
    # Clickwrap::DocumentRenderers::Markdown instead.
    class MarkdownRails
      HANDLER_EXTENSION = :md

      def initialize
        # The gem must be bundled for this choice to ever work, and a missing
        # bundle is a configuration mistake worth failing the boot for. The
        # HANDLER may legitimately not be registered yet — see the class
        # comment — so that half of the check waits until render time.
        #
        # The handler file loads first on purpose: markdown-rails' engine runs
        # an on_load(:action_view) hook that references its own Handler
        # constant, and when Action View is already loaded (it is, here) that
        # hook fires mid-require, before the entry file has declared the
        # autoload the hook depends on.
        begin
          require "markdown-rails/handler"
          require "markdown-rails"
        rescue LoadError
          raise ConfigurationError,
                "config.document_renderer = :markdown_rails needs the markdown-rails gem, and " \
                "it is not in this application's bundle. Add `gem \"markdown-rails\"` (the " \
                "Sitepress content stack), or render through your own pipeline with " \
                "Clickwrap::DocumentRenderers::Markdown.new(render_markdown_with:, engine_name:)."
        end

        @fallback = DocumentRenderer.new
      end

      def call(bytes, definition)
        return @fallback.call(bytes, definition) unless definition.media_type == "text/markdown"

        application_markdown_renderer_for(definition).call(bytes, definition)
      end

      # The provenance the application's registered renderer would produce
      # right now — exposed so hosts and tests can ask "which renderer will my
      # documents publish through?" in one call.
      def engine_name
        "markdown_rails/#{registered_renderer_class_name}"
      end

      def engine_version
        %w[markdown-rails redcarpet commonmarker kramdown].filter_map do |gem_name|
          spec = Gem.loaded_specs[gem_name]
          "#{gem_name} #{spec.version}" if spec
        end.join(" / ").presence || "unstated"
      end

      private

      # A fresh delegate per call, resolved from the registry markdown-rails
      # keeps: publish-time work, and late binding keeps development reloads of
      # the application's renderer class honest.
      def application_markdown_renderer_for(definition)
        renderer = registered_renderer(definition)

        Markdown.new(
          render_markdown_with: ->(markdown_text) { renderer.renderer.render(markdown_text) },
          engine_name: "markdown_rails/#{renderer.class.name}",
          engine_version: engine_version,
          sanitize_rendered_html: false
        )
      end

      def registered_renderer(definition = nil)
        handler = ::MarkdownRails::Handler.handler_for(HANDLER_EXTENSION)
        if handler.nil?
          raise ConfigurationError,
                "config.document_renderer = :markdown_rails found no markdown-rails handler " \
                "registered for .#{HANDLER_EXTENSION}#{" while rendering document #{definition}" if definition}. " \
                "Register one in config/initializers/markdown.rb — " \
                "`MarkdownRails.handle :md { ApplicationMarkdown.new }` — so Clickwrap can " \
                "render documents through the exact pipeline your own pages use."
        end

        handler.create_renderer
      end

      def registered_renderer_class_name
        registered_renderer.class.name
      end
    end
  end
end

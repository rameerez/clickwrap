# frozen_string_literal: true

require "test_helper"

# `config.document_renderer = :markdown_rails` renders documents through the
# application's OWN registered markdown-rails renderer — the exact pipeline its
# public `.md` pages already go through — so the stored snapshot is
# byte-identical to the page readers see, by construction rather than by a
# parity test every host has to port.
class DocumentRenderersMarkdownRailsTest < ActiveSupport::TestCase
  Definition = Struct.new(:media_type) do
    def to_s = "test document"
  end

  MARKDOWN = Definition.new("text/markdown")
  PLAIN = Definition.new("text/plain")

  # A stand-in for a host's ApplicationMarkdown: the markdown-rails renderer
  # convention (an object whose `renderer` renders markdown), with an option
  # the gem's own bundled Redcarpet defaults do NOT use, so byte equality below
  # proves the APPLICATION's pipeline ran and not a lookalike.
  class ParityMarkdown
    def renderer
      require "redcarpet"
      @renderer ||= ::Redcarpet::Markdown.new(
        ::Redcarpet::Render::HTML.new(hard_wrap: true),
        tables: true
      )
    end
  end

  setup do
    # Handler first: markdown-rails' engine hook references it mid-require
    # when Action View is already loaded. The renderer under test does the
    # same dance for the same reason.
    require "markdown-rails/handler"
    require "markdown-rails"
    @previous_handlers = ::MarkdownRails::Handler.class_variable_get(:@@handlers).dup
    ::MarkdownRails.handle(:md) { ParityMarkdown.new }
  end

  teardown do
    restore_markdown_rails_handlers(@previous_handlers)
  end

  test "renders byte-identically through the application's registered renderer" do
    source = "---\ntitle: Terms\nlast_updated: 2026-01-01\n---\n\n# Terms\nline one\nline two\n"
    result = Clickwrap::DocumentRenderers::MarkdownRails.new.call(source, MARKDOWN)

    expected = ParityMarkdown.new.renderer.render(Clickwrap::FrontMatter.strip(source))

    assert_equal expected, result[:bytes],
                 "the snapshot must be the exact bytes the application's own pipeline produces"
    assert_equal "none", result[:sanitizer_name],
                 "provenance must say plainly that no sanitizer ran on host-renderer output"
    assert_includes result[:renderer_version], "ParityMarkdown",
                    "provenance must name the renderer class the application registered"
  end

  test "resolves the handler lazily, so initializer order cannot capture the wrong renderer" do
    # config/initializers/clickwrap.rb runs before config/initializers/markdown.rb
    # (alphabetical order), so the renderer configured there must not look the
    # handler up until render time. Prove it: construct first, register after.
    restore_markdown_rails_handlers({})
    renderer = Clickwrap::DocumentRenderers::MarkdownRails.new
    ::MarkdownRails.handle(:md) { ParityMarkdown.new }

    result = renderer.call("**late**\n", MARKDOWN)

    assert_includes result[:bytes], "<strong>late</strong>"
  end

  test "no registered handler refuses with the wiring instructions" do
    restore_markdown_rails_handlers({})

    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap::DocumentRenderers::MarkdownRails.new.call("# hi\n", MARKDOWN)
    end

    assert_match(/no markdown-rails handler registered/, error.message)
    assert_match(%r{config/initializers/markdown\.rb}, error.message)
  end

  test "non-Markdown documents fall through to the reference renderer" do
    result = Clickwrap::DocumentRenderers::MarkdownRails.new.call("plain words", PLAIN)

    assert_includes result[:bytes], "plain words"
    refute_equal "none", result[:sanitizer_name],
                 "the reference renderer's provenance is its own, untouched by this class"
  end

  test "the provenance helpers answer without rendering anything" do
    renderer = Clickwrap::DocumentRenderers::MarkdownRails.new

    assert_equal "markdown_rails/DocumentRenderersMarkdownRailsTest::ParityMarkdown",
                 renderer.engine_name
    assert_match(/markdown-rails \d/, renderer.engine_version)
    assert_match(/redcarpet \d/, renderer.engine_version)
  end

  test "config.document_renderer accepts :markdown_rails and names it in the refusal list" do
    config = Clickwrap::Configuration.new

    config.document_renderer = :markdown_rails
    assert_instance_of Clickwrap::DocumentRenderers::MarkdownRails, config.document_renderer

    error = assert_raises(Clickwrap::ConfigurationError) { config.document_renderer = :html }
    assert_match(/:markdown_rails/, error.message)
  end

  private

  # markdown-rails keeps its registry in a class variable of its own; putting
  # a saved copy back is the only way to leave the global exactly as found.
  def restore_markdown_rails_handlers(handlers)
    ::MarkdownRails::Handler.class_variable_set(:@@handlers, handlers) # rubocop:disable Style/ClassVars
  end
end

# frozen_string_literal: true

require "test_helper"

# The :markdown renderer is opt-in sugar over the same evidence contract as the
# reference renderer: exact rendered bytes, recorded provenance, safe-list
# sanitization. These tests run against kramdown (the pure-Ruby engine the test
# lane bundles); the engine-resolution order itself is exercised through the
# injected-engine seam so no native Markdown gem is required.
class DocumentRenderersMarkdownTest < ActiveSupport::TestCase
  Definition = Struct.new(:media_type) do
    def to_s = "test document"
  end

  MARKDOWN = Definition.new("text/markdown")

  test "renders real HTML through a bundled engine and records which one" do
    renderer = Clickwrap::DocumentRenderers::Markdown.new
    result = renderer.call("# Título\n\nHola **mundo**.\n", MARKDOWN)

    assert_includes result[:bytes], "<h1"
    assert_includes result[:bytes], "<strong>mundo</strong>"
    assert_equal "text/html; charset=utf-8", result[:media_type]
    assert_equal "clickwrap_markdown_document_renderer", result[:renderer_name]
    assert_match(/\A1 \(kramdown \d/, result[:renderer_version],
                 "the receipt must record which Markdown engine produced the offered bytes")
  end

  test "strips a leading YAML front-matter block from the rendered representation only" do
    source = "---\ntitle: Términos\nlast_updated: 2026-07-23\n---\n\n# Términos\n\nTexto.\n"
    result = Clickwrap::DocumentRenderers::Markdown.new.call(source, MARKDOWN)

    refute_includes result[:bytes], "last_updated",
                    "front matter is page metadata, not part of the offered document"
    assert_includes result[:bytes], "<h1"
  end

  test "front matter in the middle of a document is content, not metadata" do
    source = "Intro.\n\n---\nnot: frontmatter\n---\n"
    result = Clickwrap::DocumentRenderers::Markdown.new.call(source, MARKDOWN)

    assert_includes result[:bytes], "not: frontmatter"
  end

  test "sanitizes engine output through the same safe list as the reference renderer" do
    renderer = Clickwrap::DocumentRenderers::Markdown.new(
      render_markdown_with: ->(_text) { %(<p>ok</p><script>alert("boo")</script>) },
      engine_name: "hostile_test_engine"
    )
    result = renderer.call("anything", MARKDOWN)

    assert_includes result[:bytes], "<p>ok</p>"
    refute_includes result[:bytes], "<script"
  end

  test "delegates every non-Markdown media type to the reference renderer" do
    result = Clickwrap::DocumentRenderers::Markdown.new.call(
      "plain words", Definition.new("text/plain")
    )

    assert_equal Clickwrap::DocumentRenderer::NAME, result[:renderer_name]
    assert_includes result[:bytes], "plain words"
  end

  test "an injected engine must be named, because receipts record provenance" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap::DocumentRenderers::Markdown.new(render_markdown_with: ->(text) { text })
    end

    assert_match(/engine_name/, error.message)
  end

  test "config.document_renderer accepts :markdown and :safe_text and refuses other symbols" do
    Clickwrap.configure { |config| config.document_renderer = :markdown }
    assert_instance_of Clickwrap::DocumentRenderers::Markdown, Clickwrap.config.document_renderer

    Clickwrap.configure { |config| config.document_renderer = :safe_text }
    assert_instance_of Clickwrap::DocumentRenderer, Clickwrap.config.document_renderer

    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure { |config| config.document_renderer = :fancy }
    end
    assert_match(/:safe_text, :markdown/, error.message)
  ensure
    Clickwrap.configure { |config| config.document_renderer = Clickwrap::DocumentRenderer.new }
  end

  test "publishing a Markdown document through the :markdown renderer stores real HTML" do
    Clickwrap.configure { |config| config.document_renderer = :markdown }

    Clickwrap.document :markdown_rendered_terms,
                       version: "2026-08-15",
                       content: "---\ntitle: Page metadata\n---\n\n# Rendered Terms\n\nBody.\n",
                       media_type: "text/markdown"

    outcome = Clickwrap.publish!.find do |published|
      published.definition.key == "markdown_rendered_terms"
    end
    version = outcome.version

    assert_includes version.rendered_content, "<h1"
    refute_includes version.rendered_content, "Page metadata"
    assert_equal "clickwrap_markdown_document_renderer", version.renderer_name
  ensure
    Clickwrap.configure { |config| config.document_renderer = Clickwrap::DocumentRenderer.new }
  end
end

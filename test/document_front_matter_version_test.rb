# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A document declared without `version:` resolves its label from the source's
# OWN leading YAML front matter — the file that IS the legal text names its own
# version, so there is no second copy of the label anywhere to drift. What
# these tests pin hardest is the refusals: Clickwrap never invents a label,
# because a policy that requires a current version cannot be satisfied by a
# guess.
class DocumentFrontMatterVersionTest < ActiveSupport::TestCase
  test "a file names its own version through its last_updated front matter" do
    with_legal_file("---\ntitle: Terms\nlast_updated: 2026-01-01\n---\n\n# Terms\n") do |path|
      definition = Clickwrap::DocumentDefinition.new(key: :front_matter_terms, from: path)

      assert_equal "2026-01-01", definition.version_label
    end
  end

  test "clickwrap_version outranks last_updated, for same-day point releases" do
    source = "---\nlast_updated: 2026-01-01\nclickwrap_version: 2026-01-01.2\n---\n\nBody.\n"
    with_legal_file(source) do |path|
      definition = Clickwrap::DocumentDefinition.new(key: :point_release, from: path)

      assert_equal "2026-01-01.2", definition.version_label
    end
  end

  test "quoted front-matter values lose their quotes" do
    with_legal_file("---\nlast_updated: \"2026-01-01\"\n---\n\nBody.\n") do |path|
      definition = Clickwrap::DocumentDefinition.new(key: :quoted, from: path)

      assert_equal "2026-01-01", definition.version_label
    end
  end

  test "a trailing YAML comment is not part of the label" do
    # `last_updated: 2026-11-01  # was 2026-08-15` is exactly what a careful
    # editor writes when bumping a version — the note must not become part of
    # the label. Inside quotes, a hash is just a character.
    with_legal_file("---\nlast_updated: 2026-11-01  # was 2026-08-15\n---\n\nBody.\n") do |path|
      assert_equal "2026-11-01",
                   Clickwrap::DocumentDefinition.new(key: :commented, from: path).version_label
    end

    with_legal_file("---\nlast_updated: \"v1 #internal\"\n---\n\nBody.\n") do |path|
      assert_equal "v1 #internal",
                   Clickwrap::DocumentDefinition.new(key: :hash_in_quotes, from: path).version_label
    end
  end

  test "an explicit version: always wins over the front matter" do
    with_legal_file("---\nlast_updated: 2026-01-01\n---\n\nBody.\n") do |path|
      definition = Clickwrap::DocumentDefinition.new(key: :explicit, version: "v9", from: path)

      assert_equal "v9", definition.version_label
    end
  end

  test "inline content resolves its version the same way as a file" do
    definition = Clickwrap::DocumentDefinition.new(
      key: :inline_versioned,
      content: "---\nclickwrap_version: 2026-02-02\n---\n\nInline body.\n"
    )

    assert_equal "2026-02-02", definition.version_label
  end

  test "a missing file refuses at declaration, with the fix in the sentence" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap::DocumentDefinition.new(key: :ghost, from: "/nowhere/terms.md")
    end

    assert_match(/does not exist yet/, error.message)
    assert_match(/clickwrap_version/, error.message)
    assert_match(/pass `version:` explicitly/, error.message)
  end

  test "a file with no version key refuses rather than inventing a label" do
    with_legal_file("---\ntitle: Terms\n---\n\nNo version anywhere.\n") do |path|
      error = assert_raises(Clickwrap::DefinitionError) do
        Clickwrap::DocumentDefinition.new(key: :unlabeled, from: path)
      end

      assert_match(/no `clickwrap_version:` or `last_updated:` front-matter key/, error.message)
      assert_match(/no other source of truth/, error.message)
    end
  end

  test "a file with no front matter at all gets the same refusal" do
    with_legal_file("# Terms\n\nJust markdown.\n") do |path|
      assert_raises(Clickwrap::DefinitionError) do
        Clickwrap::DocumentDefinition.new(key: :bare, from: path)
      end
    end
  end

  test "a resolver source cannot name its own version, and says why" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap::DocumentDefinition.new(key: :resolved, resolver: ->(_definition) { "bytes" })
    end

    assert_match(/only read at publish time/, error.message)
    assert_match(/Pass `version:` explicitly/, error.message)
  end

  test "a front-matter label meets the same placeholder refusal as an explicit one" do
    # "unversioned" in the file is exactly as dishonest as "unversioned" in
    # the declaration — the source of the label never launders the label.
    with_legal_file("---\nlast_updated: unversioned\n---\n\nBody.\n") do |path|
      error = assert_raises(Clickwrap::DefinitionError) do
        Clickwrap::DocumentDefinition.new(key: :laundered, from: path)
      end

      assert_match(/moving target/, error.message)
    end
  end

  private

  def with_legal_file(source)
    Dir.mktmpdir("clickwrap-front-matter") do |directory|
      path = File.join(directory, "terms.md")
      File.write(path, source)
      yield path
    end
  end
end

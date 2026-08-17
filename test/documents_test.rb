# frozen_string_literal: true

require "test_helper"

# Documents are the one thing a receipt cannot reconstruct from anything else.
# If the bytes are wrong, everything built on top of them is wrong too, so
# publishing, freezing, and digest verification get their own tests.
class DocumentsTest < ActiveSupport::TestCase
  test "publishing freezes the exact bytes with a versioned digest" do
    version = Clickwrap::Document.find_by(document_key: "terms").current_version
    source = File.binread(Rails.root.join("app/content/legal/terms.md"))

    assert_equal source, version.content_bytes
    assert_equal Clickwrap::Digest.digest(source), version.content_digest
    assert_equal source.bytesize, version.content_byte_size
    assert version.published?
    assert_equal "text/markdown", version.media_type
  end

  test "publishing is idempotent" do
    assert_no_difference -> { Clickwrap::DocumentVersion.count } do
      outcomes = Clickwrap.publish!
      assert outcomes.all?(&:unchanged?), outcomes.map(&:message).join("; ")
    end
  end

  test "a plan reports what would be published without writing" do
    Clickwrap.document(:terms, version: "2027-01-01", locale: :en, content: "Revised terms.")

    assert_no_difference -> { Clickwrap::DocumentVersion.count } do
      planned = Clickwrap::Services::PublishDocuments.new(dry_run: true).call
      assert planned.any?(&:planned?)
    end
  end

  test "reusing a version label for different bytes is refused with both digests" do
    # A deploy/reload clears the in-memory declarations, while the immutable
    # published version remains in the database. The publication check must
    # therefore still catch a reused label even though duplicate declarations
    # inside one boot are rejected earlier by the registry.
    Clickwrap.documents.clear
    Clickwrap.document(:terms, version: "2026-08-15", locale: :en, content: "completely different")

    error = assert_raises(Clickwrap::DocumentVersionConflictError) { Clickwrap.publish! }

    assert_match(/already published with different bytes/, error.message)
    assert_match(/published:/, error.message)
    assert_match(/on disk:/, error.message)
    assert_match(/new version label/, error.message)
  end

  test "reading bytes verifies them against the recorded digest" do
    version = Clickwrap::Document.find_by(document_key: "terms").current_version

    assert version.verify_content_digest

    # Simulate a privileged actor editing the row around the model guard.
    version.update_columns(content: "quietly rewritten")

    version.reload
    assert_not version.verify_content_digest
    error = assert_raises(Clickwrap::DocumentDigestMismatchError) { version.content_bytes }
    assert_match(/no longer match the digest/, error.message)
  end

  test "a version scheduled for the future is not presentable yet" do
    Clickwrap.document(:terms, version: "2030-01-01", locale: :en,
                               effective_at: Time.utc(2030, 1, 1), content: "Future terms.")
    Clickwrap.publish!

    current = Clickwrap::Document.find_by(document_key: "terms").current_version

    # `effective_at` is what makes scheduling possible at all. A version that
    # became presentable the moment it was published could not be prepared in
    # advance.
    assert_equal "2026-08-15", current.version_label

    travel_to Time.utc(2030, 6, 1) do
      assert_equal "2030-01-01", Clickwrap::Document.find_by(document_key: "terms").current_version.version_label
    end
  end

  test "a retired version stops being presentable without disappearing" do
    document = Clickwrap::Document.find_by(document_key: "terms")
    version = document.current_version

    version.update_columns(retired_at: 1.minute.ago, retired_reason: "Published in error")

    assert_nil document.reload.current_version
    assert Clickwrap::DocumentVersion.exists?(version.id),
           "retiring stops future offers; it does not delete versions bound into earlier events"
  end

  test "a document version is looked up per locale" do
    Clickwrap.document(:terms, version: "2026-08-15", locale: :es, content: "Términos en español.")
    Clickwrap.publish!

    document = Clickwrap::Document.find_by(document_key: "terms")

    assert_equal "en", document.current_version(locale: :en).locale
    assert_equal "es", document.current_version(locale: :es).locale
    assert_not_equal document.current_version(locale: :en).content_digest,
                     document.current_version(locale: :es).content_digest
  end

  test "a document declaration needs exactly one source" do
    assert_raises(Clickwrap::DefinitionError) { Clickwrap.document(:x, version: "1") }
    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.document(:x, version: "1", content: "a", from: "/tmp/b")
    end
  end

  test "a document declaration refuses a version label that names a moving target" do
    %w[latest current head unversioned none default].each do |label|
      error = assert_raises(Clickwrap::DefinitionError) do
        Clickwrap.document(:x, version: label, content: "a")
      end

      assert_match(/moving target/, error.message)
    end
  end

  test "a link is the page a person reads the document on, and it must be navigable" do
    declaration = Clickwrap.document(:linked, version: "1", content: "a", link: "  /legal/terms  ")
    assert_equal "/legal/terms", declaration.link

    assert_nil Clickwrap.document(:unlinked, version: "1", content: "a").link
    assert_nil Clickwrap.document(:blank_link, version: "1", content: "a", link: "   ").link
    assert_equal "https://www.example.com/terms",
                 Clickwrap.document(:absolute, version: "1", content: "a",
                                               link: "https://www.example.com/terms").link

    # A link is rendered as an href AND signed into the manifest, so a scheme
    # the gem would be painting into a page is refused at boot rather than at
    # the moment somebody presses it. `//host` is refused for the same reason:
    # protocol-relative is a different origin wearing a path's clothes.
    ["javascript:alert(1)", "data:text/html,<script>", "legal/terms", "//evil.example.com"].each do |hostile|
      error = assert_raises(Clickwrap::DefinitionError) do
        Clickwrap.document(:hostile, version: "1", content: "a", link: hostile)
      end

      assert_match(/root-relative path/, error.message)
    end
  end

  test "an unknown document option is refused by name, `link:` included in the list" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.document(:x, version: "1", content: "a", lnik: "/legal/terms")
    end

    assert_match(/`lnik:`/, error.message)
    assert_match(/`link:`/, error.message)
  end

  test "a missing source file is reported with its path" do
    Clickwrap.document(:nowhere, version: "1", from: Rails.root.join("app/content/legal/absent.md"))

    error = assert_raises(Clickwrap::DocumentNotPublishedError) { Clickwrap.publish! }
    assert_match(/absent\.md/, error.message)
  end

  test "a resolver is a source, not a storage backend: its bytes are frozen at publish" do
    calls = 0
    Clickwrap.document(:resolved, version: "1", resolver: lambda { |_definition|
      calls += 1
      "bytes from a resolver"
    })
    Clickwrap.publish!

    version = Clickwrap::Document.find_by(document_key: "resolved").current_version

    # Called once, at publish. Reading the document afterwards must not call it
    # again — a source that could answer differently on a later read is exactly
    # what the frozen snapshot exists to rule out.
    assert_equal "database", version.storage_backend
    assert_equal "bytes from a resolver", version.content_bytes
    assert_equal "bytes from a resolver", version.content_bytes
    assert_equal 1, calls
  end

  test "a resolver that returns nothing is refused rather than publishing an empty document" do
    Clickwrap.document(:empty_source, version: "1", resolver: ->(_definition) {})

    assert_raises(Clickwrap::DocumentNotPublishedError) { Clickwrap.publish! }
  end

  test "a document containing non-ASCII characters publishes and still verifies" do
    # Documents are read as binary so the digest covers the exact bytes on disk,
    # and a text column holds text — so the two have to be reconciled somewhere.
    # An em dash is enough to hit it, and real legal text is full of them.
    text = "Terms — with an em dash, a café, and a ﬁ ligature."
    Clickwrap.document(:unicode_terms, version: "1", content: text)
    Clickwrap.publish!

    version = Clickwrap::Document.find_by(document_key: "unicode_terms").current_version

    assert_equal text, version.content_bytes
    assert version.verify_content_digest
    assert_equal Clickwrap::Digest.digest(text), version.content_digest
  end

  test "a document that is not valid UTF-8 is refused rather than corrupted" do
    # A corrupted document is one whose digest will never verify again, which is
    # a worse outcome than a clear refusal pointing at the right storage backend.
    Clickwrap.document(:binary_doc, version: "1", content: (+"\xFF\xFE\x00binary").force_encoding("BINARY"))

    error = assert_raises(Clickwrap::DefinitionError) { Clickwrap.publish! }

    assert_match(/not valid UTF-8/, error.message)
    assert_match(/active_storage/, error.message)
  end

  test "a renderer's exact output is digested alongside the source" do
    Clickwrap.config.document_renderer = lambda do |bytes, _definition|
      { bytes: "<p>#{bytes.strip}</p>", media_type: "text/html",
        renderer_name: "test_renderer", renderer_version: "1" }
    end

    Clickwrap.document(:rendered, version: "1", content: "hello")
    Clickwrap.publish!

    version = Clickwrap::Document.find_by(document_key: "rendered").current_version

    # "This Markdown file existed" and "this rendered representation was
    # offered" are different claims, and each gets its own digest so neither
    # borrows the other's credibility.
    assert_equal "hello", version.content
    assert_equal "<p>hello</p>", version.rendered_content
    assert_equal "test_renderer", version.renderer_name
    assert_not_equal version.content_digest, version.rendered_content_digest
    assert Clickwrap::Digest.matches?("<p>hello</p>", version.rendered_content_digest)
  end

  test "a renderer that does not return bytes is refused" do
    Clickwrap.config.document_renderer = ->(_bytes, _definition) { { bytes: 42 } }
    Clickwrap.document(:bad_render, version: "1", content: "hello")

    error = assert_raises(Clickwrap::ConfigurationError) { Clickwrap.publish! }
    assert_match(/exact rendered bytes/, error.message)
  end

  test "the built-in renderer falls back to the HTML4 safe-list sanitizer" do
    html5_sanitizer = Rails::HTML5.send(:remove_const, :SafeListSanitizer)

    rendered = Clickwrap::DocumentRenderer.sanitize_html("<p>Safe</p><script>unsafe()</script>")

    assert_includes rendered, "<p>Safe</p>"
    assert_not_includes rendered, "<script>"
  ensure
    Rails::HTML5.const_set(:SafeListSanitizer, html5_sanitizer) if html5_sanitizer
  end

  test "an Active Storage upload finishes before the database transaction opens" do
    Clickwrap.config.store_document_contents_in = :active_storage
    Clickwrap.document(:stored_file, version: "1", content: "stored bytes")
    blob = fake_active_storage_blob("stored-file-signed-id")
    starting_transaction_depth = ActiveRecord::Base.connection.open_transactions

    with_fake_active_storage(blob) do
      Clickwrap.publish!
    end

    version = Clickwrap::Document.find_by(document_key: "stored_file").current_version
    assert_equal "active_storage", version.storage_backend
    assert_equal "stored-file-signed-id", version.storage_locator
    assert_equal starting_transaction_depth, blob.transaction_depth_when_uploaded
    refute blob.purged
  end

  test "a failed publication purges the Active Storage blob uploaded for it" do
    Clickwrap.config.store_document_contents_in = :active_storage
    definition = Clickwrap.documents.values.find { |candidate| candidate.key == "terms" }
    blob = fake_active_storage_blob("failed-upload-signed-id")
    publisher = Clickwrap::Services::PublishDocuments.new(definitions: [definition])
    publisher.stubs(:find_existing).returns(nil)
    starting_transaction_depth = ActiveRecord::Base.connection.open_transactions

    with_fake_active_storage(blob) do
      assert_raises(ActiveRecord::RecordInvalid) { publisher.call }
    end

    assert blob.purged
    assert_equal starting_transaction_depth, blob.transaction_depth_when_uploaded
  end

  FakeBlob = Struct.new(:signed_id, :transaction_depth_when_uploaded, :purged, keyword_init: true) do
    def purge
      self.purged = true
    end
  end

  private

  def fake_active_storage_blob(signed_id)
    FakeBlob.new(signed_id:, transaction_depth_when_uploaded: nil, purged: false)
  end

  def with_fake_active_storage(blob)
    already_loaded = Object.const_defined?(:ActiveStorage, false)
    original = Object.const_get(:ActiveStorage) if already_loaded
    Object.send(:remove_const, :ActiveStorage) if already_loaded

    active_storage = Module.new
    blob_class = Class.new
    blob_class.define_singleton_method(:create_and_upload!) do |**_options|
      blob.transaction_depth_when_uploaded = ActiveRecord::Base.connection.open_transactions
      blob
    end
    active_storage.const_set(:Blob, blob_class)
    Object.const_set(:ActiveStorage, active_storage)

    yield
  ensure
    Object.send(:remove_const, :ActiveStorage) if Object.const_defined?(:ActiveStorage, false)
    Object.const_set(:ActiveStorage, original) if already_loaded
  end
end

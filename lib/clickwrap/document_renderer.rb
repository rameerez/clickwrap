# frozen_string_literal: true

require "erb"
# Require the sanitizer implementation without loading the Action View helper
# facade. Requiring `rails-html-sanitizer` while Action View is booting can
# create a circular require; these are the library's implementation entrypoints
# and do not install unrelated helper methods.
require "loofah"
require "rails/html/scrubbers"
require "rails/html/sanitizer"

module Clickwrap
  # Safe, dependency-free rendering for the text formats most legal documents
  # use. It intentionally favors faithful, readable text over clever Markdown
  # interpretation: source characters are escaped, then placed in a <pre>
  # element. Applications that want richer Markdown may supply a renderer, but
  # its HTML still passes through #sanitize_html before Clickwrap stores it.
  class DocumentRenderer
    NAME = "clickwrap_safe_document_renderer"
    VERSION = "1"
    SANITIZER_NAME = "rails_safe_list_sanitizer"
    SANITIZER_VERSION = "1"

    SAFE_TAGS = %w[
      a abbr b blockquote br cite code dd del details div dl dt em h1 h2 h3 h4 h5 h6
      hr i ins kbd li mark ol p pre q s samp small span strong sub summary sup table
      tbody td tfoot th thead tr u ul var
    ].freeze
    SAFE_ATTRIBUTES = %w[href title lang dir class id colspan rowspan scope].freeze

    def call(bytes, definition)
      text = utf8_text!(bytes, definition)

      html = case definition.media_type
             when "text/html" then text
             when "text/markdown", "text/plain", "application/json"
               %(<pre class="clickwrap-document-source">#{ERB::Util.html_escape(text)}</pre>)
             else
               return nil
             end

      {
        bytes: self.class.sanitize_html(html),
        media_type: "text/html; charset=utf-8",
        renderer_name: NAME,
        renderer_version: VERSION,
        sanitizer_name: SANITIZER_NAME,
        sanitizer_version: SANITIZER_VERSION
      }
    end

    def self.sanitize_html(html)
      safe_list_sanitizer_class.new.sanitize(
        html.to_s,
        tags: SAFE_TAGS,
        attributes: SAFE_ATTRIBUTES
      ).to_s
    end

    def self.safe_list_sanitizer_class
      return Rails::HTML5::SafeListSanitizer if defined?(Rails::HTML5::SafeListSanitizer)
      return Rails::HTML4::SafeListSanitizer if defined?(Rails::HTML4::SafeListSanitizer)

      raise ConfigurationError,
            "Clickwrap could not find Rails::HTML5::SafeListSanitizer or " \
            "Rails::HTML4::SafeListSanitizer. Install a rails-html-sanitizer version that " \
            "provides one of those supported safe-list sanitizers."
    end
    private_class_method :safe_list_sanitizer_class

    private

    def utf8_text!(bytes, definition)
      text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?

      raise DefinitionError,
            "Document #{definition} cannot be rendered as text because its bytes are not valid UTF-8. " \
            "Store binary source with :active_storage (or a byte-preserving resolver) and provide " \
            "a reviewed renderer for the representation people should be offered."
    end
  end
end

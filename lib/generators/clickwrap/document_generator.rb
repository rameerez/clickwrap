# frozen_string_literal: true

require "rails/generators/base"

module Clickwrap
  module Generators
    # `rails generate clickwrap:document terms` — declares one document and
    # creates the file its bytes will come from, with the file's own front
    # matter naming its version.
    #
    # Declaring is not publishing. This generator adds a declaration and a
    # placeholder file; `bin/rails clickwrap:publish` is what reads the bytes,
    # digests them, and freezes the snapshot that receipts point at from then
    # on (deploys do this automatically after `db:prepare`).
    #
    # Changing a document later is NOT another run of this generator: the file
    # that holds the words also names its version, so a new version is one
    # edit in one file — change the text, bump `last_updated:` (or add
    # `clickwrap_version:` for a same-day correction), publish. The
    # declaration never changes, published bytes are never edited in place,
    # and every receipt goes on pointing at the exact version its accepted
    # server offer bound.
    class DocumentGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Declare a clickwrap document and create its content file"

      argument :name, type: :string, banner: "DOCUMENT_NAME"

      class_option :document_version, type: :string,
                                      desc: "An explicit version label, written into the file's " \
                                            "front matter (defaults to today's date as last_updated)"
      class_option :locale, type: :string,
                            desc: "Declare this version for one locale (en, es…)"

      def create_content_file
        if host_file?(content_path)
          say_status :skip, "#{content_path} (you already have a file there)", :yellow
          return
        end

        create_file content_path, placeholder_content
      end

      def declare_document
        create_policy_file_if_missing

        if declaration_present?
          say_status :skip, "#{policy_file} (:#{document_key} is already declared — a new " \
                            "version is a front-matter bump in #{content_path}, not a new " \
                            "declaration)", :yellow
          return
        end

        append_to_file policy_file, declaration
      end

      def display_next_steps
        say "\n☑️  Document :#{document_key} declared.", :green
        say "\nTo finish:"
        say "  1. Put the real text in #{content_path}, keeping the front matter at the top."
        say "     Clickwrap never writes legal text — the words are yours."
        say "  2. Run 'bin/rails clickwrap:publish' to freeze an immutable snapshot."
        say "     Deploys do this for you — publishing rides `db:prepare`."
        say "  3. Reference it from a policy in #{policy_file}."
        say "\nThe file names its own version: its `last_updated:` front matter is the label,"
        say "so changing the text later is one edit in one file — new words, bumped label,"
        say "publish. Reusing a label for different bytes is refused rather than accepted,"
        say "and old receipts go on pointing at the bytes their accepted server offers bound.\n"
      end

      private

      def document_key
        name.to_s.underscore.tr("-", "_").tr("/", "_")
      end

      def explicit_version_label
        options[:document_version].presence
      end

      def locale
        options[:locale].presence
      end

      def policy_file
        "config/clickwrap.rb"
      end

      def content_path
        return "app/content/legal/#{document_key}.#{locale}.md" if locale

        "app/content/legal/#{document_key}.md"
      end

      def declaration
        lines = ["\nClickwrap.document :#{document_key},"]
        lines << "  locale: :#{locale}," if locale
        lines << "  from: Rails.root.join(#{content_path.inspect})\n"
        lines.join("\n")
      end

      # One declaration per document key (and per locale): the version lives in
      # the file, so a "new version" never adds a declaration — and a second
      # version-less declaration of the same key would be refused at boot as a
      # duplicate anyway.
      def declaration_present?
        File.read(File.expand_path(policy_file, destination_root))
            .include?("Clickwrap.document :#{document_key},#{"\n  locale: :#{locale}," if locale}")
      rescue StandardError
        false
      end

      def create_policy_file_if_missing
        return if host_file?(policy_file)

        create_file policy_file, <<~RUBY
          # frozen_string_literal: true

          # Clickwrap documents, policies, and retention classes. Ordinary Ruby, so it is
          # reviewable in a pull request and deploys with the code that depends on it.
        RUBY
      end

      def host_file?(path)
        File.exist?(File.expand_path(path, destination_root))
      end

      # The front matter is the version label. `last_updated:` is the usual
      # key; an explicit --document-version lands as `clickwrap_version:`,
      # which outranks it, so a hand-chosen label and a human-facing date can
      # coexist without fighting.
      def placeholder_front_matter
        lines = ["---", "title: #{document_key.humanize}"]
        lines << "clickwrap_version: #{explicit_version_label}" if explicit_version_label
        lines << "last_updated: #{Date.today.iso8601}"
        lines << "---"
        "#{lines.join("\n")}\n\n"
      end

      def placeholder_content
        <<~MARKDOWN
          #{placeholder_front_matter.rstrip}

          # PLACEHOLDER — replace this with your own reviewed text

          **This is not a #{document_key.humanize.downcase}.** The `clickwrap` gem created this
          file so the declaration in `config/clickwrap.rb` has bytes to point at, and it
          deliberately contains no legal text of any kind: the gem does not know who you
          are, where you operate, or which rules apply, and text that merely looked
          plausible would be worse than this, because someone would ship it.

          Replace this file, then run `bin/rails clickwrap:publish` to freeze an immutable
          snapshot. Publishing records the exact bytes, media type, locale, and digest, so
          a receipt written today can reproduce the document version its accepted server
          offer bound years from now.

          The front matter above is the version label: when the text changes, bump
          `last_updated:` (or add `clickwrap_version:` for a same-day correction) and
          publish again, rather than editing a published version in place.
        MARKDOWN
      end
    end
  end
end

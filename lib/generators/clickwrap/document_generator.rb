# frozen_string_literal: true

require "rails/generators/base"

module Clickwrap
  module Generators
    # `rails generate clickwrap:document terms` — declares one immutable document
    # version and creates the file its bytes will come from.
    #
    # Declaring is not publishing. This generator adds a declaration and a
    # placeholder file; `bin/rails clickwrap:publish` is what reads the bytes,
    # digests them, and freezes the snapshot that receipts point at from then on.
    #
    # A new version of an existing document is the normal case, and it is why
    # this generator APPENDS rather than edits: the previous declaration keeps
    # describing the bytes bound into earlier accepted server offers, and
    # nothing about that evidence changes because you wrote a new version.
    class DocumentGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Declare a clickwrap document version and create its content file"

      argument :name, type: :string, banner: "DOCUMENT_NAME"

      class_option :document_version, type: :string,
                                      desc: "The version label (defaults to today's date)"
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
          say_status :skip, "#{policy_file} (:#{document_key} #{version_label} is already declared)", :yellow
          return
        end

        append_to_file policy_file, declaration
      end

      def display_next_steps
        say "\n☑️  Document :#{document_key} #{version_label} declared.", :green
        say "\nTo finish:"
        say "  1. Put the real text in #{content_path}."
        say "     Clickwrap never writes legal text — the words are yours."
        say "  2. Run 'bin/rails clickwrap:publish' to freeze an immutable snapshot."
        say "  3. Reference it from a policy in #{policy_file}."
        say "\nPublishing is idempotent, and reusing a version label for different bytes is"
        say "refused rather than accepted. When the text changes, declare a NEW version:"
        say "old receipts go on pointing at the bytes their accepted server offers bound.\n"
      end

      private

      def document_key
        name.to_s.underscore.tr("-", "_").tr("/", "_")
      end

      def version_label
        options[:document_version].presence || Date.today.iso8601
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
        lines = ["\nClickwrap.document :#{document_key},", "  version: #{version_label.inspect},"]
        lines << "  locale: :#{locale}," if locale
        lines << "  from: Rails.root.join(#{content_path.inspect})\n"
        lines.join("\n")
      end

      def declaration_present?
        File.read(File.expand_path(policy_file, destination_root)).include?(declaration.strip)
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

      def placeholder_content
        <<~MARKDOWN
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

          When the text changes, declare a new version rather than editing a published one.
        MARKDOWN
      end
    end
  end
end

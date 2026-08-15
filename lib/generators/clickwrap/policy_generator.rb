# frozen_string_literal: true

require "rails/generators/base"

module Clickwrap
  module Generators
    # `rails generate clickwrap:policy driver_declaration` — a documented policy
    # skeleton and a matching test.
    #
    # The skeleton is commented rather than filled in, because the interesting
    # decision is which of the six verbs an act actually is, and that is a
    # decision about meaning that nobody but the author can make. A generator
    # that picked `agree_to` for everything would be teaching the exact mistake
    # this gem exists to fix.
    #
    # The test comes with it for the same reason tests come with a model: a
    # policy is executable meaning, and "does this still say what we think it
    # says" is a question worth asking on every commit.
    class PolicyGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Create a documented clickwrap policy skeleton and its test"

      argument :name, type: :string, banner: "POLICY_NAME"

      def create_policy_file
        template "policy.rb.erb", "config/clickwrap/#{policy_key}.rb"
      end

      def create_policy_test
        template "policy_test.rb.erb", "test/clickwrap/#{policy_key}_policy_test.rb"
      end

      def display_next_steps
        say "\n☑️  Policy skeleton created.", :green
        say "\nTo finish it:"
        say "  1. Choose the verb for each act in config/clickwrap/#{policy_key}.rb."
        say "     agree_to (terms) · acknowledge (a notice) · consent_to (a purpose you"
        say "     have decided consent is the right basis for) · declare (a fact stated"
        say "     by the actor) · attest (an operational fact) · authorize (one protected"
        say "     action). The verb decides the lifecycle, so it is worth a minute."
        say "  2. Declare every document it references, and run 'bin/rails clickwrap:publish'."
        say "  3. Write the statement text in config/locales, or pass `statement:` inline."
        say "  4. Fill in test/clickwrap/#{policy_key}_policy_test.rb."
        say "\nThe policy compiles at boot: a missing document, a duplicate statement key, a"
        say "consent without a withdrawal path, or an indefinite one-time authorization is a"
        say "startup failure with a sentence explaining it.\n"
      end

      private

      def policy_key
        name.to_s.underscore.tr("-", "_").tr("/", "_")
      end

      def test_class_name
        "#{policy_key.camelize}PolicyTest"
      end
    end
  end
end

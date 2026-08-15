# frozen_string_literal: true

require "rails/generators/base"

module Clickwrap
  module Generators
    # `rails generate clickwrap:policy driver_declaration declare
    # --statement-text="I declare ..."` — one compiling policy and its test.
    #
    # The verb and exact first-person statement are required because choosing or
    # inventing either would silently make product/legal meaning on the host's
    # behalf. Once they are supplied, the generated file compiles immediately;
    # it never writes an empty policy or an executable TODO placeholder.
    #
    # The test comes with it for the same reason tests come with a model: a
    # policy is executable meaning, and "does this still say what we think it
    # says" is a question worth asking on every commit.
    class PolicyGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Create one compiling clickwrap policy and its test"

      VERBS = %w[agree_to acknowledge consent_to declare attest authorize].freeze

      argument :name, type: :string, banner: "POLICY_NAME"
      argument :verb, type: :string, banner: VERBS.join("|")

      class_option :statement_text, type: :string, required: true,
                                    desc: "Exact first-person assertion for the generated control"
      class_option :statement_key, type: :string,
                                   desc: "Stable statement key (defaults to the policy name)"
      class_option :document, type: :string,
                              desc: "Declared Clickwrap document key to link (optional)"
      class_option :retention_class, type: :string, default: "ordinary_agreement_evidence",
                                     desc: "Existing Clickwrap retention class"
      class_option :withdrawal_path, type: :string,
                                     desc: "Required remediation path for consent_to"

      def validate_arguments!
        return if VERBS.include?(policy_verb) && (!consent? || withdrawal_path.present?)

        unless VERBS.include?(policy_verb)
          raise Thor::Error,
                "#{verb.inspect} is not a Clickwrap policy verb. Choose one of: #{VERBS.join(", ")}."
        end

        raise Thor::Error,
              "A consent_to policy needs --withdrawal-path=/your/settings/page so the " \
              "person has a concrete way to withdraw it."
      end

      def create_policy_file
        template "policy.rb.erb", "config/clickwrap/#{policy_key}.rb"
      end

      def create_policy_test
        template "policy_test.rb.erb", "test/clickwrap/#{policy_key}_policy_test.rb"
      end

      def display_next_steps
        say "\n☑️  Compiling policy created.", :green
        say "\nTo finish it:"
        say "  1. Review the verb and exact statement in config/clickwrap/#{policy_key}.rb."
        say "  2. If it references a document, declare and publish that document."
        say "  3. Replace the generated test skips with your real actor and submission flow."
        say "\nThe policy compiles at boot: a missing document, a duplicate statement key, a"
        say "consent without a withdrawal path, or an indefinite one-time authorization is a"
        say "startup failure with a sentence explaining it.\n"
      end

      private

      def policy_key
        name.to_s.underscore.tr("-", "_").tr("/", "_")
      end

      def policy_verb = verb.to_s

      def statement_key
        (options[:statement_key].presence || policy_key).underscore.tr("-", "_").tr("/", "_")
      end

      def statement_text = options.fetch(:statement_text).to_s

      def document_key
        key = options[:document].presence&.underscore
        key&.tr("-", "_")&.tr("/", "_")
      end

      def retention_class_key = options.fetch(:retention_class).to_s.underscore.tr("-", "_").tr("/", "_")
      def withdrawal_path = options[:withdrawal_path].to_s.strip
      def consent? = policy_verb == "consent_to"

      def evidence_kind
        {
          "agree_to" => "agreement",
          "acknowledge" => "acknowledgment",
          "consent_to" => "consent",
          "declare" => "declaration",
          "attest" => "attestation",
          "authorize" => "authorization"
        }.fetch(policy_verb)
      end

      def statement_options
        options = ["statement: #{statement_text.inspect}"]
        options.unshift("document: :#{document_key}") if document_key
        options.unshift("document: nil") unless document_key
        options << "optional: true" if consent?
        options << "withdrawal_path: #{withdrawal_path.inspect}" if consent?
        options
      end

      def test_class_name
        "#{policy_key.camelize}PolicyTest"
      end
    end
  end
end

# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Clickwrap
  module Generators
    # `rails generate clickwrap:install` — the adaptive migration, one annotated
    # initializer, a conventional policy file, placeholder legal content, and an
    # optional engine mount.
    #
    # Two things make this installer different from an ordinary one.
    #
    # First, it asks. Recording an IP address or a provider-estimated city is a
    # decision with consequences for the people using the host application, so
    # every request-evidence field is a separate question in plain English with
    # the consequence stated before the choice — never a category enabled as a
    # side effect of something else.
    #
    # Second, it refuses to guess. The actor class is inferred only when it is
    # unambiguous, legal text is never invented, and no purpose or legal basis is
    # written on the host's behalf: those come out as TODO placeholders that a
    # human has to replace.
    #
    # The `--request-evidence-recipe` flag is SCAFFOLDING ONLY. It expands into
    # the individual settings written into the initializer and then disappears;
    # it is deliberately not a runtime concept. There is no
    # `record_network_context`, `record_everything`, `full_evidence`, or
    # regulation-named mode switch anywhere in this gem, because a flag that
    # enables a whole category of personal data is the thing this gem exists not
    # to do, and no flag can make a legal determination on a host's behalf.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Install clickwrap: adaptive migration, annotated initializer, policy file, and placeholders"

      # The adapters the gem's portable core behavior is tested against.
      SUPPORTED_ADAPTERS = %w[sqlite sqlite3 postgresql postgis mysql mysql2 trilogy].freeze

      # Used only when a request-evidence field is enabled and nobody named a
      # period. It is a placeholder to be reviewed, not a recommended period:
      # Clickwrap does not know your jurisdiction, your disputes, or your
      # obligations, and it will not pretend to.
      DEFAULT_RETENTION_DAYS = 90

      RECIPES = %w[privacy-minimized evidence-rich].freeze

      # The command-line flags name IP-geolocation fields in the plural, the way
      # a person says them out loud ("record cities"); the configuration names
      # one field ("city"). This maps one to the other so both stay readable.
      IP_GEOLOCATION_FIELD_FOR_OPTION = {
        "country" => "country",
        "regions" => "region",
        "cities" => "city",
        "postal_codes" => "postal_code",
        "latitude_and_longitude" => "latitude_and_longitude",
        "timezones" => "timezone",
        "continents" => "continent",
        "metro_codes" => "metro_code",
        "accuracy_radius_in_kilometers" => "accuracy_radius_in_kilometers"
      }.freeze

      # --- Request evidence: one explicit flag per field ------------------------
      #
      # No defaults are declared for these booleans on purpose: an absent key
      # means "the operator did not choose", which is what lets an explicit
      # `--no-record-...` override a recipe, and what stops the installer from
      # asking a question that was already answered on the command line.

      class_option :record_ip_addresses_by_default,
                   type: :boolean, desc: "Record the request IP address for every policy"
      class_option :record_browser_user_agents_by_default,
                   type: :boolean, desc: "Record the browser User-Agent for every policy"
      class_option :record_ip_geolocation_country_by_default,
                   type: :boolean, desc: "Record the estimated country for every policy"
      class_option :record_ip_geolocation_regions_by_default,
                   type: :boolean, desc: "Record the estimated region for every policy"
      class_option :record_ip_geolocation_cities_by_default,
                   type: :boolean, desc: "Record the estimated city for every policy"
      class_option :record_ip_geolocation_postal_codes_by_default,
                   type: :boolean, desc: "Record the estimated postal code for every policy"
      class_option :record_ip_geolocation_latitude_and_longitude_by_default,
                   type: :boolean, desc: "Record estimated coordinates for every policy"
      class_option :record_ip_geolocation_timezones_by_default,
                   type: :boolean, desc: "Record the estimated timezone for every policy"
      class_option :record_ip_geolocation_continents_by_default,
                   type: :boolean, desc: "Record the estimated continent for every policy"
      class_option :record_ip_geolocation_metro_codes_by_default,
                   type: :boolean, desc: "Record the estimated metro code for every policy"
      class_option :record_ip_geolocation_accuracy_radius_in_kilometers_by_default,
                   type: :boolean, desc: "Record the estimated accuracy radius for every policy"

      class_option :delete_recorded_ip_addresses_after_days,
                   type: :numeric, desc: "Delete recorded IP addresses after N days"
      class_option :delete_recorded_browser_user_agents_after_days,
                   type: :numeric, desc: "Delete recorded browser User-Agent strings after N days"
      class_option :delete_recorded_ip_geolocation_after_days,
                   type: :numeric, desc: "Delete recorded IP geolocation after N days"

      class_option :request_evidence_recipe,
                   type: :string, enum: RECIPES,
                   desc: "Scaffold the individual settings above (privacy-minimized or " \
                         "evidence-rich). Generator-only: a recipe expands into settings and " \
                         "does not survive as a runtime concept."

      class_option :actor_class,
                   type: :string,
                   desc: "The model that can act (User, Account, Member…) when it can't be inferred"
      class_option :skip_routes,
                   type: :boolean, default: false,
                   desc: "Don't offer to mount Clickwrap::Engine in config/routes.rb"
      class_option :skip_questions,
                   type: :boolean, default: false,
                   desc: "Non-interactive: ask nothing and write the safe defaults"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      # Everything this run decides about the host is resolved HERE, before a
      # single file is written, and memoized. The steps below create
      # config/initializers/clickwrap.rb, config/clickwrap.rb, and content files;
      # re-reading the environment halfway through would answer a different
      # question than the one this step asked, and the post-install message would
      # describe an application that did not exist when the decisions were made.
      def detect_environment!
        database_adapter
        primary_key_type
        devise_detected?
        rails_authentication_detected?
        actor_class_name

        say "\n☑️  Installing clickwrap.", :green
        say "   Database adapter:  #{database_adapter || "not detected"}"
        say "   Primary key type:  #{primary_key_type_description}"
        say "   Authentication:    #{detected_authentication || "none detected (both integrations are optional)"}"
        say "   Actor class:       #{actor_class_name || "not inferred — see the initializer"}"

        return if actor_class_name

        say "\n⚠️  Clickwrap could not infer your actor class unambiguously.", :yellow
        say "   #{actor_class_reason}", :yellow
        say "   `config.actor_class_name` is therefore left COMMENTED OUT in the", :yellow
        say "   generated initializer, with an explanation beside it. Which record", :yellow
        say "   can act is a security-relevant identity mapping, and a wrong guess", :yellow
        say "   attributes evidence to the wrong kind of record for years. Set it", :yellow
        say "   yourself, or re-run with --actor-class=YourModel.", :yellow
      end

      # The questions come verbatim from the request-evidence design: each one
      # states the consequence before asking for the choice, because a developer
      # who has not thought about IP addresses this week deserves the context in
      # the question rather than in a document they will read later.
      def ask_about_request_evidence
        ask_request_evidence_questions unless skip_request_evidence_questions?

        # The summary prints in every mode, before any file is written, so the
        # operator sees every enabled field, purpose, encryption choice,
        # source posture, access behavior, and retention rule together.
        summarize_request_evidence_choices
      end

      def create_migration_file
        migration_template "create_clickwrap_tables.rb.erb",
                           File.join(db_migrate_path, "create_clickwrap_tables.rb")
      end

      def create_initializer
        template "initializer.rb.erb", "config/initializers/clickwrap.rb"
      end

      def create_policy_file
        template "clickwrap_policies.rb.erb", "config/clickwrap.rb"
      end

      # Placeholders only, and only when nothing is there. Clickwrap never
      # invents legal text: the words are the host's, reviewed by the host's
      # counsel, and a gem that shipped plausible-looking Terms would be
      # inviting an application to publish text nobody read.
      def create_legal_content_placeholders
        copy_legal_placeholder "terms.md", "app/content/legal/terms.md"
        copy_legal_placeholder "privacy.md", "app/content/legal/privacy.md"
      end

      def mount_engine
        return if options[:skip_routes]
        return say_missing_routes_file unless routes_file?
        return say_already_mounted if engine_already_mounted?
        return say_mount_instructions unless interactive?

        return unless ask_question(<<~QUESTION)
          Mount the Clickwrap engine at "/agreements" in config/routes.rb?
          It adds actor-owned capture, receipt, consent-withdrawal, and
          document-history screens using your parent controller, layout, locale,
          and authorization callbacks — so a required agreement can be completed
          in place instead of becoming a dead end. Nothing is exposed publicly:
          access still goes through your own authorization callbacks. [y/N]
        QUESTION

        route "mount Clickwrap::Engine => \"/agreements\""
        @mounted_engine = true
      end

      def print_unsupported_adapter_notes
        return if supported_adapter?

        say "\n⚠️  #{database_adapter || "Your database adapter"} is outside the set clickwrap tests.", :yellow
        say "   Tested: SQLite, PostgreSQL, and MySQL. On anything else these are", :yellow
        say "   unverified rather than known-broken, and worth checking yourself:", :yellow
        say "     • the JSON/JSONB column types and their defaults in the migration;", :yellow
        say "     • long document bodies (a silently truncated agreement is the", :yellow
        say "       worst failure this gem has);", :yellow
        say "     • whether the unique index on (policy_key, idempotency_key) really", :yellow
        say "       rejects a duplicate submit under concurrency; and", :yellow
        say "     • `rails generate clickwrap:hardening --database`, whose update and", :yellow
        say "       delete protections are written for PostgreSQL only.", :yellow
      end

      def display_post_install_message
        say "\n☑️  The `clickwrap` gem has been installed.", :green
        say "\nTo complete the setup:"

        step = 0
        say "  #{step += 1}. Run 'rails db:migrate' to create the clickwrap tables."
        say "     ⚠️  You must run migrations before starting your app!", :yellow

        say "  #{step += 1}. Declare which records can act:"
        say "       class #{actor_class_name || "User"} < ApplicationRecord"
        say "         has_clickwraps"
        say "       end"
        say "       (and set `config.actor_class_name` in the initializer)" unless actor_class_name

        say "  #{step += 1}. Replace the placeholder legal text with your own reviewed documents:"
        say "       app/content/legal/terms.md"
        say "       app/content/legal/privacy.md"
        say "       then set each `version:` in config/clickwrap.rb."

        say "  #{step += 1}. Publish immutable snapshots:"
        say "       bin/rails clickwrap:publish"

        say "  #{step += 1}. Render the policy and its bound submit action:"
        say "       <%= form.clickwrap :signup, submit: \"Create account\" %>"

        unless @mounted_engine
          say "  #{step += 1}. Mount the standalone capture/receipt/withdrawal screens when you want them:"
          say "       # config/routes.rb"
          say "       mount Clickwrap::Engine => \"/agreements\""
        end

        if any_ip_geolocation_field?
          say "  #{step + 1}. Install an IP-geolocation resolver — the initializer configures one", :yellow
          say "     because you enabled IP-geolocation fields, and Clickwrap refuses to boot", :yellow
          say "     with fields it cannot resolve:", :yellow
          say "       bundle add trackdown", :yellow
          say "     (or set `config.ip_geolocation_resolver` to your own adapter, or turn the", :yellow
          say "     fields back off)", :yellow
        end

        print_review_checklist
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end

      # --- The review checklist -------------------------------------------------

      # Deliberately a list of things a human still has to do. The installer
      # copied files; it did not review anything, and it is not in a position to
      # tell anyone their agreements are in order.
      def print_review_checklist
        say "\nBefore this carries any weight, review — with counsel where that applies:"
        say "  ☐ Legal text — the Terms and Privacy Notice are yours; the gem wrote placeholders."
        say "  ☐ Policy semantics — is each act the right verb? agree_to for terms, acknowledge"
        say "    for a notice, consent_to only where consent is genuinely your chosen basis,"
        say "    declare/attest for statements of fact, authorize for one protected action."
        say "  ☐ Lawful basis and, where applicable, a data-protection impact assessment for"
        say "    every request-evidence field you enabled."
        say "  ☐ Retention periods — the generated ones are placeholders, not recommendations."
        say "  ☐ Your privacy notice — does it describe what you now record, and for how long?"
        say "  ☐ Trusted proxies — Clickwrap reads request.remote_ip; if you record IP addresses,"
        say "    verify and TEST your ActionDispatch::RemoteIp configuration behind your"
        say "    load balancer or CDN, or you are recording a header someone else controls."
        say "  ☐ The whole page — placement, wording, contrast, the call to action, and"
        say "    accessibility of the screen your controls appear on. Clickwrap renders the"
        say "    controls; the page around them is yours."
        say "  ☐ Tests — a real signup, a refused submit, and a forced evidence-write failure"
        say "    that proves the account is not created without its evidence."
        say "\nClickwrap records evidence mechanics and keeps them verifiable. The words, the"
        say "lawful basis, the periods, and the legal judgment stay yours.\n", :green
      end

      # --- Detection ------------------------------------------------------------

      def database_adapter
        return @database_adapter if defined?(@database_adapter)

        @database_adapter = ActiveRecord::Base.connection_db_config.adapter.to_s
      rescue StandardError
        @database_adapter = nil
      end

      def supported_adapter?
        SUPPORTED_ADAPTERS.include?(database_adapter.to_s.downcase)
      end

      # The same setting `rails g model` reads, so an application generated with
      # `g.orm :active_record, primary_key_type: :uuid` gets uuid clickwrap
      # tables and uuid foreign keys without being asked.
      def primary_key_type
        return @primary_key_type if defined?(@primary_key_type)

        generators = Rails.configuration.generators
        @primary_key_type = generators.options[generators.orm][:primary_key_type]
      rescue StandardError
        @primary_key_type = nil
      end

      def primary_key_type_description
        primary_key_type ? primary_key_type.to_s : "integer (the Rails default)"
      end

      def devise_detected?
        return @devise_detected if defined?(@devise_detected)

        @devise_detected = defined?(::Devise) ? true : false
      end

      # The class names behind the host's `devise_for` scopes, as strings. Never
      # constantized: a generator has no business coupling itself to the host's
      # model boot order.
      def devise_actor_class_names
        return @devise_actor_class_names if defined?(@devise_actor_class_names)
        return @devise_actor_class_names = [] unless devise_detected?

        @devise_actor_class_names = ::Devise.mappings.values.map { |mapping| mapping.class_name.to_s }.uniq.sort
      rescue StandardError
        @devise_actor_class_names = []
      end

      # Rails 8's `bin/rails generate authentication` writes both an
      # `app/models/session.rb` and an `Authentication` concern. Requiring both
      # keeps an unrelated Session model in an older application from being read
      # as omakase authentication.
      def rails_authentication_detected?
        return @rails_authentication_detected if defined?(@rails_authentication_detected)

        @rails_authentication_detected =
          host_file?("app/models/session.rb") && host_file?("app/controllers/concerns/authentication.rb")
      end

      def detected_authentication
        return @detected_authentication if defined?(@detected_authentication)

        detected = []
        detected << "Rails authentication" if rails_authentication_detected?
        detected << "Devise" if devise_detected?
        @detected_authentication = detected.any? ? detected.join(" + ") : nil
      end

      def actor_class_name
        return @actor_class_name if defined?(@actor_class_name)

        @actor_class_name, @actor_class_reason = infer_actor_class
        @actor_class_name
      end

      def actor_class_reason
        actor_class_name
        @actor_class_reason
      end

      # The reason travels into the generated initializer as a comment, so it is
      # wrapped rather than left as one long line in someone else's file.
      def actor_class_reason_comment
        lines = actor_class_reason.to_s.split.each_with_object([""]) do |word, wrapped|
          if wrapped.last.empty?
            wrapped[-1] = word
          elsif wrapped.last.length + word.length + 1 <= 72
            wrapped[-1] = "#{wrapped.last} #{word}"
          else
            wrapped << word
          end
        end

        lines.map { |line| "  # #{line}" }.join("\n")
      end

      # Inference stops at the first ambiguity. "Probably User" is not a good
      # enough answer for the question "whose agreement is this".
      def infer_actor_class
        explicit = options[:actor_class].to_s.strip
        return [explicit, nil] unless explicit.empty?

        names = devise_actor_class_names

        if names.length > 1
          return [nil, "Devise maps several models (#{names.join(", ")}), so there is no single " \
                       "conventional actor to choose."]
        end

        return [names.first, nil] if names.length == 1
        return ["User", nil] if user_model?

        [nil, "No `User` model was found, and nothing else identified itself as the conventional actor."]
      end

      def user_model?
        host_file?("app/models/user.rb") || (defined?(::User) ? true : false)
      end

      def current_actor_method_name
        return "current_user" unless actor_class_name

        "current_#{actor_class_name.underscore.tr("/", "_")}"
      end

      def host_file?(path)
        File.exist?(File.expand_path(path, destination_root))
      end

      def routes_file?
        host_file?("config/routes.rb")
      end

      def engine_already_mounted?
        File.read(File.expand_path("config/routes.rb", destination_root)).include?("Clickwrap::Engine")
      rescue StandardError
        false
      end

      def say_missing_routes_file
        say "\n   No config/routes.rb found, so nothing was mounted."
      end

      def say_already_mounted
        say "\n   config/routes.rb already mounts Clickwrap::Engine — left untouched."
        @mounted_engine = true
      end

      def say_mount_instructions
        say "\n   Routes were left untouched (nothing was asked). Add this line when you want"
        say "   the standalone capture, receipt, withdrawal, and document-history screens:"
        say "       mount Clickwrap::Engine => \"/agreements\""
      end

      def interactive?
        !options[:skip_questions]
      end

      # --- The questions --------------------------------------------------------

      def answers
        @answers ||= {}
      end

      def recipe
        options[:request_evidence_recipe]
      end

      def evidence_rich_recipe?
        recipe == "evidence-rich"
      end

      def privacy_minimized_recipe?
        recipe == "privacy-minimized"
      end

      def request_evidence_option_keys
        @request_evidence_option_keys ||= [
          :record_ip_addresses_by_default,
          :record_browser_user_agents_by_default,
          *IP_GEOLOCATION_FIELD_FOR_OPTION.keys.map { |name| :"record_ip_geolocation_#{name}_by_default" }
        ]
      end

      # A recipe or an explicit flag is already an answer. Asking again would be
      # asking someone to repeat themselves.
      def skip_request_evidence_questions?
        return true if options[:skip_questions]
        return true if recipe

        request_evidence_option_keys.any? { |key| !options[key].nil? }
      end

      def ask_request_evidence_questions
        say "\nClickwrap records none of the following unless you say so here. Each one is a"
        say "separate question because each one is a separate decision.\n"

        ask_about_ip_addresses
        ask_about_browser_user_agents
        ask_about_ip_geolocation
      end

      # Thor's prompt escapes newlines, so a multi-line question handed straight
      # to `yes?` prints as one long line of literal \n. The question is said in
      # full first, and only its last line — the one carrying [y/N] — becomes the
      # prompt, which keeps the wording exactly as written.
      def ask_question(text)
        lines = text.strip.lines.map(&:chomp)

        say ""
        lines[0..-2].each { |line| say line }
        yes?(lines.last)
      end

      def ask_about_ip_addresses
        answers[:ip_address] = ask_question(<<~QUESTION)
          Should Clickwrap record IP addresses by default?
          IP addresses can help investigate disputes, but they are personal data and
          need a documented purpose, access policy, and deletion schedule. [y/N]
        QUESTION

        return unless answers[:ip_address]

        answers[:ip_address_purpose] = ask_purpose("recording IP addresses")
        answers[:ip_address_days] = ask_retention_days("recorded IP addresses")
      end

      def ask_about_browser_user_agents
        answers[:browser_user_agent] = ask_question(<<~QUESTION)
          Should Clickwrap record browser User-Agent headers by default?
          The value is supplied by the browser, may be spoofed, and is not a unique
          device identity. [y/N]
        QUESTION

        return unless answers[:browser_user_agent]

        answers[:browser_user_agent_purpose] = ask_purpose("recording browser User-Agent strings")
        answers[:browser_user_agent_days] = ask_retention_days("recorded browser User-Agent strings")
      end

      def ask_about_ip_geolocation
        answers["country"] = ask_question(<<~QUESTION)
          Should Clickwrap estimate and record a country from each IP address?
          This is an estimate for the IP address, not the person's physical location.
          It requires an IP geolocation resolver such as trackdown. [y/N]
        QUESTION

        say <<~FRAMING

          Should Clickwrap estimate and record region, city, or postal-code fields?
          Each field is provider-estimated from the IP address, may be inaccurate, and
          must have a documented purpose and retention rule. Select fields individually.
        FRAMING

        answers["region"] = yes?("  Record the estimated region? [y/N]")
        answers["city"] = yes?("  Record the estimated city? [y/N]")
        answers["postal_code"] = yes?("  Record the estimated postal code? [y/N]")

        answers["latitude_and_longitude"] = ask_question(<<~QUESTION)
          Should Clickwrap record provider-estimated latitude and longitude?
          These coordinates describe an approximate IP-network location, not GPS or the
          person's physical position. Accuracy radius is stored when available. [y/N]
        QUESTION

        ask_about_remaining_ip_geolocation_fields
        ask_about_ip_geolocation_purpose
      end

      # The remaining fields get the same treatment as the ones above: named
      # individually, estimated, and off unless asked for.
      def ask_about_remaining_ip_geolocation_fields
        say <<~FRAMING

          Clickwrap can also record four smaller provider-estimated fields. Each is an
          estimate about the IP address and needs the same purpose and retention rule
          as the ones above.
        FRAMING

        answers["timezone"] = yes?("  Record the estimated timezone? [y/N]")
        answers["continent"] = yes?("  Record the estimated continent? [y/N]")
        answers["metro_code"] = yes?("  Record the estimated metro code? [y/N]")
        answers["accuracy_radius_in_kilometers"] = ask_question(<<~QUESTION)
          Record the accuracy radius in kilometers? Keeping it is how a later reader
          can tell how uncertain the estimate above actually was. [y/N]
        QUESTION
      end

      # One purpose and one retention rule cover the IP-geolocation category:
      # the fields are separate decisions about what to keep, but they are all
      # resolved from the same address by the same provider at the same moment.
      def ask_about_ip_geolocation_purpose
        return unless ip_geolocation_fields.any? { |field| answers[field] == true }

        answers[:ip_geolocation_purpose] = ask_purpose("recording IP geolocation")
        answers[:ip_geolocation_days] = ask_retention_days("recorded IP geolocation")
      end

      # A purpose typed by the operator is the operator's sentence. A blank
      # answer becomes a TODO, never a sentence this generator made up.
      def ask_purpose(label)
        say "\n  Why does the application need #{label}? One plain sentence, in your own"
        say "  words — it goes into the initializer and the privacy inventory, and an"
        say "  empty answer is left as a TODO rather than filled in for you."
        ask("  Purpose:").to_s.strip
      end

      def ask_retention_days(label)
        say "\n  After how many days should Clickwrap delete #{label}?"
        say "  Nothing is kept forever here, so this cannot be blank. #{DEFAULT_RETENTION_DAYS} is only a"
        say "  placeholder to replace with your reviewed period."
        days = ask("  Days [#{DEFAULT_RETENTION_DAYS}]:").to_s.strip.to_i
        days.positive? ? days : DEFAULT_RETENTION_DAYS
      end

      # --- Resolved answers (flag > recipe > question > off) --------------------

      def record_ip_addresses?
        resolve_record_choice(:record_ip_addresses_by_default, :ip_address)
      end

      def record_browser_user_agents?
        resolve_record_choice(:record_browser_user_agents_by_default, :browser_user_agent)
      end

      def record_ip_geolocation_field?(field)
        option_name = IP_GEOLOCATION_FIELD_FOR_OPTION.key(field)
        resolve_record_choice(:"record_ip_geolocation_#{option_name}_by_default", field)
      end

      def resolve_record_choice(option_key, answer_key)
        return options[option_key] unless options[option_key].nil?
        return true if evidence_rich_recipe?
        return false if privacy_minimized_recipe?

        answers.fetch(answer_key, false) == true
      end

      def ip_geolocation_fields
        Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS
      end

      def enabled_ip_geolocation_fields
        ip_geolocation_fields.select { |field| record_ip_geolocation_field?(field) }
      end

      def any_ip_geolocation_field?
        enabled_ip_geolocation_fields.any?
      end

      def records_any_request_evidence?
        record_ip_addresses? || record_browser_user_agents? || any_ip_geolocation_field?
      end

      def delete_recorded_ip_addresses_after_days
        retention_days(:delete_recorded_ip_addresses_after_days, :ip_address_days)
      end

      def delete_recorded_browser_user_agents_after_days
        retention_days(:delete_recorded_browser_user_agents_after_days, :browser_user_agent_days)
      end

      def delete_recorded_ip_geolocation_after_days
        retention_days(:delete_recorded_ip_geolocation_after_days, :ip_geolocation_days)
      end

      def retention_days(option_key, answer_key)
        days = options[option_key] || answers[answer_key] || DEFAULT_RETENTION_DAYS
        days.to_i
      end

      # The generator never writes a purpose it made up. Either the operator
      # typed one, or the line says out loud that a human still has to.
      def purpose_for(answer_key, subject)
        typed = answers[answer_key].to_s.strip
        return typed unless typed.empty?

        "TODO: replace with your reviewed purpose for #{subject}"
      end

      def reason_for_recording_ip_addresses
        purpose_for(:ip_address_purpose, "recording IP addresses")
      end

      def reason_for_recording_browser_user_agents
        purpose_for(:browser_user_agent_purpose, "recording browser User-Agent strings")
      end

      def reason_for_recording_ip_geolocation
        purpose_for(:ip_geolocation_purpose, "recording IP geolocation")
      end

      # A date one year out, so an enabled field gets looked at again by someone
      # rather than quietly outliving the reason it was turned on.
      def review_request_evidence_configuration_on
        Date.today.next_year
      end

      def review_date_literal
        date = review_request_evidence_configuration_on
        "Date.new(#{date.year}, #{date.month}, #{date.day})"
      end

      # --- The pre-write summary ------------------------------------------------

      def summarize_request_evidence_choices
        say "\nRequest evidence Clickwrap will record BY DEFAULT for every policy:"

        unless records_any_request_evidence?
          say "  • nothing."
          say "    That is the safe default and it stays true until you change it. An"
          say "    individual policy can still enable a field it genuinely needs."
          return
        end

        summarize_category("IP address", record_ip_addresses?, reason_for_recording_ip_addresses,
                           delete_recorded_ip_addresses_after_days)
        summarize_category("browser User-Agent", record_browser_user_agents?,
                           reason_for_recording_browser_user_agents,
                           delete_recorded_browser_user_agents_after_days)

        if any_ip_geolocation_field?
          summarize_category("IP geolocation (#{enabled_ip_geolocation_fields.join(", ")})", true,
                             reason_for_recording_ip_geolocation, delete_recorded_ip_geolocation_after_days)
          say "    source:     provider-estimated from the IP address — not GPS, not a street"
          say "                address, and not proof of where anyone was. Provider name,"
          say "                source, estimated state, and accuracy provenance are stored"
          say "                alongside every value."
        end

        say "\n  encryption: on (config.encrypt_recorded_* = true)."
        say "  access:     unredacted values are DENIED until you write"
        say "              `authorize_unredacted_request_evidence_access_with`; every export"
        say "              needs a human-readable reason and appends an access event."
        say "  review on:  #{review_request_evidence_configuration_on.iso8601}"
        say "\n  These are settings, not a verdict. Read every purpose and period above and"
        say "  replace anything that is still a TODO before you rely on it.", :yellow
        say "  The recipe flag, if you used one, stops here: it expanded into the individual", :yellow
        say "  settings written into the initializer and does not exist at runtime.", :yellow
      end

      def summarize_category(label, enabled, purpose, days)
        return unless enabled

        say "  • #{label}"
        say "    purpose:    #{purpose}"
        say "    delete:     after #{days} days"
      end

      # --- Files ----------------------------------------------------------------

      def copy_legal_placeholder(source, destination)
        if host_file?(destination)
          say_status :skip, "#{destination} (you already have a file there)", :yellow
          return
        end

        copy_file source, destination
      end
    end
  end
end

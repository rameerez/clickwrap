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
    # unambiguous, legal text is never invented, and no purpose, retention
    # period or resolver is written on the host's behalf. Proxy provenance is
    # derived from the effective Rails rules themselves rather than invented.
    # An incomplete personal-data choice stops the generator before it writes a
    # file.
    #
    # The only `--request-evidence-recipe` is `privacy-minimized`, a convenient
    # spelling of the off-by-default posture. It disappears after generation;
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

      RECIPES = %w[privacy-minimized].freeze

      # Places applications already keep the legal text their public routes
      # serve. Both documents must exist for a convention to count; order
      # matters, so a Sitepress-style content directory wins over files a
      # previous install of this generator wrote.
      #
      # `rendered_by_the_application` separates the two cases: the Sitepress
      # directory holds pages the application itself renders and serves, which
      # is what makes rendering Clickwrap's snapshot through the application's
      # own Markdown pipeline the right default. The second convention is a
      # previous install's placeholder files, which nothing else renders.
      EXISTING_LEGAL_CONVENTIONS = [
        { dir: "app/content/pages/legal", terms: "terms.html.md", privacy: "privacy.html.md",
          rendered_by_the_application: true },
        { dir: "app/content/legal", terms: "terms.md", privacy: "privacy.md",
          rendered_by_the_application: false }
      ].freeze

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

      class_option :reason_for_recording_ip_addresses_by_default,
                   type: :string,
                   desc: "Plain-English reason for recording IP addresses by default"
      class_option :reason_for_recording_browser_user_agents_by_default,
                   type: :string,
                   desc: "Plain-English reason for recording browser User-Agent strings by default"
      class_option :reason_for_recording_ip_geolocation_by_default,
                   type: :string,
                   desc: "Plain-English reason for recording IP geolocation by default"
      class_option :trusted_proxy_configuration_digest,
                   type: :string,
                   desc: "Prefixed SHA-2 digest of the reviewed trusted-proxy configuration"
      class_option :ip_geolocation_resolver_class_name,
                   type: :string,
                   desc: "Resolver class to instantiate when IP geolocation is enabled"

      class_option :request_evidence_recipe,
                   type: :string, enum: RECIPES,
                   desc: "Use the privacy-minimized, all-fields-off scaffold. " \
                         "Generator-only: it does not survive as a runtime concept."

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
        validate_request_evidence_choices!

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

      # Placeholders only, and only when the application has no legal text
      # anywhere Clickwrap recognizes. Clickwrap never invents legal text: the
      # words are the host's, reviewed by the host's counsel, and a gem that
      # shipped plausible-looking Terms would be inviting an application to
      # publish text nobody read.
      #
      # When the app ALREADY serves legal pages (a Sitepress content directory,
      # or a previous install's files), the generated config points at those
      # exact files instead of writing a second set: what people accept must be
      # the same bytes the public legal routes render, and two copies of the
      # Terms is how they silently stop being the same document.
      def create_legal_content_placeholders
        if detected_legal_documents
          say_status :found, "existing legal pages in #{detected_legal_documents[:dir]} — " \
                             "config/clickwrap.rb points at them; no placeholders written", :green
          return
        end

        write_legal_placeholder "terms.md.erb", "app/content/legal/terms.md"
        write_legal_placeholder "privacy.md.erb", "app/content/legal/privacy.md"
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

        if detected_legal_documents
          say "  #{step += 1}. Your existing legal pages are the documents (same bytes people"
          say "     read and accept):"
          say "       #{terms_document_path}"
          say "       #{privacy_document_path}"
          if documents_needing_an_explicit_version.empty?
            say "       Each page names its own version in its front matter, so config/clickwrap.rb"
            say "       declares both without a `version:` line."
          else
            say "       A page that names its own version in its front matter is declared in"
            say "       config/clickwrap.rb without a `version:` line."
            say_documents_needing_an_explicit_version
          end
        else
          say "  #{step += 1}. Replace the placeholder legal text with your own reviewed documents:"
          say "       #{terms_document_path}"
          say "       #{privacy_document_path}"
          say "       Keep the `last_updated:` front matter at the top of each file accurate:"
          say "       that line is the version label, so a text change is one edit in one file."
        end

        say "  #{step += 1}. Publish immutable snapshots:"
        say "       bin/rails clickwrap:publish"
        say "       Deploys do this for you — publishing rides `db:prepare`, so a snapshot"
        say "       exists before the server takes traffic."

        say "  #{step += 1}. Render the policy and its bound submit action:"
        say "       <%= form.clickwrap :signup, submit: \"Create account\" %>"

        say "  #{step += 1}. Set up your test suite (presentations refuse unpublished documents"
        say "     in tests exactly as in production):"
        say "       # test/test_helper.rb"
        say "       class ActiveSupport::TestCase"
        say "         include Clickwrap::TestHelpers"
        say "         parallelize_setup { Clickwrap.publish! }   # per parallel worker..."
        say "       end"
        say "       Clickwrap.publish!                           # ...and once per process"

        unless @mounted_engine
          say "  #{step += 1}. Mount the standalone capture/receipt/withdrawal screens when you want them:"
          say "       # config/routes.rb"
          say "       mount Clickwrap::Engine => \"/agreements\""
        end

        if any_ip_geolocation_field?
          say "  #{step + 1}. Ensure #{ip_geolocation_resolver_class_name} and its data source", :yellow
          say "     are available in every environment. The initializer uses the resolver you", :yellow
          say "     explicitly selected; Clickwrap refuses to boot with fields it cannot resolve.", :yellow
        end

        print_review_checklist
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end

      # Said only when a detected page could not name its own version. What was
      # generated boots — it carries an explicit label — but the label now lives
      # somewhere other than the text it describes, and that is exactly the pair
      # that drifts apart the next time someone edits the page in a hurry.
      def say_documents_needing_an_explicit_version
        paths = documents_needing_an_explicit_version
        return if paths.empty?

        say "       ⚠️  #{paths.join(" and ")}", :yellow
        say "       #{paths.one? ? "has" : "have"} no `clickwrap_version:` or `last_updated:` " \
            "front-matter key, so", :yellow
        say "       config/clickwrap.rb carries an explicit `version: \"#{Date.today.iso8601}\"` " \
            "for #{paths.one? ? "it" : "them"}.", :yellow
        say "       Move that label into the page's own front matter and delete the line, so", :yellow
        say "       the text names its version and there is only one copy of the label.", :yellow
      end

      # --- The review checklist -------------------------------------------------

      # Deliberately a list of things a human still has to do. The installer
      # copied files; it did not review anything, and it is not in a position to
      # tell anyone their agreements are in order.
      def print_review_checklist
        say "\nBefore this carries any weight, review — with counsel where that applies:"
        if detected_legal_documents
          say "  ☐ Legal text — the Terms and Privacy Notice are yours; the gem points at your existing pages."
        else
          say "  ☐ Legal text — the Terms and Privacy Notice are yours; the gem wrote placeholders."
        end
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
        say "  ☐ Styles — add <%= stylesheet_link_tag \"clickwrap\" %> to the layouts that render"
        say "    clickwrap blocks (the engine's own screens emit their styles themselves)."
        say "    Every rule is scoped under .clickwrap, so it cannot repaint the rest of your"
        say "    page. Rather own the CSS? `rails generate clickwrap:views` ejects the templates."
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

      def detected_legal_documents
        return @detected_legal_documents if defined?(@detected_legal_documents)

        @detected_legal_documents = EXISTING_LEGAL_CONVENTIONS.find do |convention|
          host_file?(File.join(convention[:dir], convention[:terms])) &&
            host_file?(File.join(convention[:dir], convention[:privacy]))
        end
      end

      # The paths the generated config's `from:` lines point at — the app's own
      # legal files when they exist, the freshly written placeholders otherwise.
      def terms_document_path
        convention = detected_legal_documents
        convention ? File.join(convention[:dir], convention[:terms]) : "app/content/legal/terms.md"
      end

      def privacy_document_path
        convention = detected_legal_documents
        convention ? File.join(convention[:dir], convention[:privacy]) : "app/content/legal/privacy.md"
      end

      # A document declared without `version:` reads its label from the file's
      # own leading front matter, which is where a version label belongs: in the
      # file that IS the legal text, with nothing to drift against. The
      # placeholders this installer writes carry one.
      #
      # An application's existing legal pages may not, and a versionless
      # declaration over a page with no version key fails the next boot. So the
      # generated declaration for THAT document carries an explicit label, plus
      # the one line telling a developer where it really belongs.
      def terms_document_names_its_own_version?
        document_names_its_own_version?(terms_document_path)
      end

      def privacy_document_names_its_own_version?
        document_names_its_own_version?(privacy_document_path)
      end

      def documents_needing_an_explicit_version
        {
          terms_document_path => terms_document_names_its_own_version?,
          privacy_document_path => privacy_document_names_its_own_version?
        }.reject { |_path, names_its_own| names_its_own }.keys
      end

      def document_names_its_own_version?(path)
        # The placeholders this installer writes open with front matter, so a
        # fresh install always has its version labels in the files themselves.
        return true unless detected_legal_documents

        @document_names_its_own_version ||= {}
        return @document_names_its_own_version[path] if @document_names_its_own_version.key?(path)

        @document_names_its_own_version[path] = front_matter_version_label_in(path).present?
      end

      # An unreadable file answers the same way a file with no version key
      # does. Writing the explicit label is the recoverable mistake; leaving a
      # declaration that cannot resolve a version is a boot failure.
      def front_matter_version_label_in(path)
        Clickwrap::FrontMatter.version_label_in(
          File.read(File.expand_path(path, destination_root))
        )
      rescue StandardError
        nil
      end

      # The lockfile rather than the Gemfile, because the lockfile is the bundle
      # this application actually resolved. It is evidence that the gem is
      # there, not proof that the legal pages render through it — which is why
      # the generated setting also requires the application to be serving those
      # exact pages, and why the worst case is a boot error naming the missing
      # gem rather than a document published through the wrong pipeline.
      def host_bundles_markdown_rails?
        return @host_bundles_markdown_rails if defined?(@host_bundles_markdown_rails)

        @host_bundles_markdown_rails =
          begin
            lockfile = File.expand_path("Gemfile.lock", destination_root)
            File.exist?(lockfile) && File.read(lockfile).match?(/^\s+markdown-rails[\s(]/)
          rescue StandardError
            false
          end
      end

      # Both halves have to be true for this to be the right default: the
      # application renders its own legal pages through markdown-rails, and
      # those same pages are the documents Clickwrap will publish. Then the
      # snapshot people accept and the page they read come out of one renderer
      # instead of two that have to be kept in agreement by hand.
      def renders_documents_through_markdown_rails?
        return false unless detected_legal_documents&.fetch(:rendered_by_the_application, false)

        host_bundles_markdown_rails?
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
        return false if options[:skip_questions]

        # No terminal, no questions: a piped or scripted run (CI, a provisioning
        # script, an AI agent) would otherwise stream every prompt into a jumble
        # and take the [y/N] defaults anyway. Skipping deliberately keeps the
        # same collect-nothing outcome and says so once, instead of pretending
        # a conversation happened.
        unless $stdin.tty?
          @announced_non_interactive ||= begin
            say "Non-interactive run detected: skipping questions and writing the safe, " \
                "collect-nothing defaults (same as --skip-questions).", :yellow
            true
          end
          return false
        end

        true
      end

      # --- The questions --------------------------------------------------------

      def answers
        @answers ||= {}
      end

      def recipe
        options[:request_evidence_recipe]
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

      # Privacy-minimized and --skip-questions are complete postures. Individual
      # flags are not: in an interactive run, Clickwrap still asks about every
      # category the operator did not explicitly decide.
      def skip_request_evidence_questions?
        !interactive? || privacy_minimized_recipe?
      end

      def ask_request_evidence_questions
        say "\nClickwrap records none of the following unless you say so here. Each one is a"
        say "separate question because each one is a separate decision.\n"

        ask_about_ip_addresses
        ask_about_browser_user_agents
        ask_about_ip_geolocation
        ask_about_ip_geolocation_resolver
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
        if options[:record_ip_addresses_by_default].nil?
          answers[:ip_address] = ask_question(<<~QUESTION)
            Should Clickwrap record IP addresses by default?
            IP addresses can help investigate disputes, but they are personal data and
            need a documented purpose, access policy, and deletion schedule. [y/N]
          QUESTION
        end

        return unless record_ip_addresses?

        if options[:reason_for_recording_ip_addresses_by_default].nil?
          answers[:ip_address_purpose] = ask_purpose("recording IP addresses")
        end
        return unless options[:delete_recorded_ip_addresses_after_days].nil?

        answers[:ip_address_days] = ask_retention_days("recorded IP addresses")
      end

      def ask_about_browser_user_agents
        if options[:record_browser_user_agents_by_default].nil?
          answers[:browser_user_agent] = ask_question(<<~QUESTION)
            Should Clickwrap record browser User-Agent headers by default?
            The value is supplied by the browser, may be spoofed, and is not a unique
            device identity. [y/N]
          QUESTION
        end

        return unless record_browser_user_agents?

        if options[:reason_for_recording_browser_user_agents_by_default].nil?
          answers[:browser_user_agent_purpose] = ask_purpose("recording browser User-Agent strings")
        end
        return unless options[:delete_recorded_browser_user_agents_after_days].nil?

        answers[:browser_user_agent_days] = ask_retention_days("recorded browser User-Agent strings")
      end

      def ask_about_ip_geolocation
        # Supplying any geolocation field on the command line makes that list an
        # explicit allowlist. Asking about the remaining fields would make a
        # non-interactive-looking command unexpectedly collect more data.
        return if ip_geolocation_options_supplied?

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
        return unless any_ip_geolocation_field?

        if options[:reason_for_recording_ip_geolocation_by_default].nil?
          answers[:ip_geolocation_purpose] = ask_purpose("recording IP geolocation")
        end
        return unless options[:delete_recorded_ip_geolocation_after_days].nil?

        answers[:ip_geolocation_days] = ask_retention_days("recorded IP geolocation")
      end

      def ask_purpose(label)
        say "\n  Why does the application need #{label}? One plain sentence, in your own"
        say "  words — it goes into the initializer and the privacy inventory. A blank"
        say "  or scaffolding answer stops generation before Clickwrap writes any files."
        ask("  Purpose:").to_s.strip
      end

      def ask_retention_days(label)
        say "\n  After how many days should Clickwrap delete #{label}?"
        say "  Clickwrap does not invent a period. Enter the positive number your application"
        say "  has reviewed; a blank or zero answer stops generation before files are written."
        ask("  Days:").to_s.strip.to_i
      end

      def ask_about_ip_geolocation_resolver
        return unless any_ip_geolocation_field?
        return unless options[:ip_geolocation_resolver_class_name].nil?

        say "\n  Which resolver class should Clickwrap instantiate for IP geolocation?"
        say "  Example: Clickwrap::IpGeolocation::TrackdownResolver (requires `trackdown`)."
        answers[:ip_geolocation_resolver_class_name] = ask("  Resolver class:").to_s.strip
      end

      # --- Resolved answers (flag > question > privacy-minimized/off) -----------

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

      def records_ip_derived_request_evidence?
        record_ip_addresses? || any_ip_geolocation_field?
      end

      def ip_geolocation_options_supplied?
        request_evidence_option_keys
          .grep(/record_ip_geolocation/)
          .any? { |key| !options[key].nil? }
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
        (options[option_key] || answers[answer_key]).to_i
      end

      def purpose_for(option_key, answer_key)
        (options[option_key] || answers[answer_key]).to_s.strip
      end

      def reason_for_recording_ip_addresses
        purpose_for(:reason_for_recording_ip_addresses_by_default, :ip_address_purpose)
      end

      def reason_for_recording_browser_user_agents
        purpose_for(:reason_for_recording_browser_user_agents_by_default, :browser_user_agent_purpose)
      end

      def reason_for_recording_ip_geolocation
        purpose_for(:reason_for_recording_ip_geolocation_by_default, :ip_geolocation_purpose)
      end

      def trusted_proxy_configuration_digest
        (options[:trusted_proxy_configuration_digest] ||
          answers[:trusted_proxy_configuration_digest]).to_s.strip.presence
      end

      def ip_geolocation_resolver_class_name
        (options[:ip_geolocation_resolver_class_name] ||
          answers[:ip_geolocation_resolver_class_name]).to_s.strip.presence
      end

      # Every enabled personal-data category must be complete before Thor moves
      # on to its first file-writing task. This makes the command atomic from the
      # host developer's point of view: either it writes a bootable initializer
      # containing their decisions, or it writes nothing.
      def validate_request_evidence_choices!
        validate_enabled_category!(
          "IP addresses",
          enabled: record_ip_addresses?,
          because: reason_for_recording_ip_addresses,
          delete_after_days: delete_recorded_ip_addresses_after_days,
          reason_option: "--reason-for-recording-ip-addresses-by-default",
          retention_option: "--delete-recorded-ip-addresses-after-days"
        )
        validate_enabled_category!(
          "browser User-Agent strings",
          enabled: record_browser_user_agents?,
          because: reason_for_recording_browser_user_agents,
          delete_after_days: delete_recorded_browser_user_agents_after_days,
          reason_option: "--reason-for-recording-browser-user-agents-by-default",
          retention_option: "--delete-recorded-browser-user-agents-after-days"
        )
        validate_enabled_category!(
          "IP geolocation",
          enabled: any_ip_geolocation_field?,
          because: reason_for_recording_ip_geolocation,
          delete_after_days: delete_recorded_ip_geolocation_after_days,
          reason_option: "--reason-for-recording-ip-geolocation-by-default",
          retention_option: "--delete-recorded-ip-geolocation-after-days"
        )
        validate_ip_geolocation_coordinates!
        validate_trusted_proxy_configuration!
        validate_ip_geolocation_resolver_class_name!
      end

      def validate_enabled_category!(label, enabled:, because:, delete_after_days:,
                                     reason_option:, retention_option:)
        return unless enabled

        unless Clickwrap::ReviewedText.present_and_reviewed?(because)
          raise Thor::Error,
                "Clickwrap cannot enable #{label} with a blank or scaffolding reason. " \
                "Give the application's reviewed, present-tense reason with " \
                "#{reason_option}=\"...\", or turn that category off. No files were written."
        end

        return if delete_after_days.positive?

        raise Thor::Error,
              "Clickwrap cannot enable #{label} without a positive deletion period. " \
              "Set #{retention_option}=DAYS to the period your application reviewed, or " \
              "turn that category off. No files were written."
      end

      def validate_ip_geolocation_coordinates!
        return unless record_ip_geolocation_field?("latitude_and_longitude")
        return if record_ip_geolocation_field?("accuracy_radius_in_kilometers")

        raise Thor::Error,
              "Clickwrap cannot record provider-estimated latitude and longitude without " \
              "their accuracy radius. Add " \
              "--record-ip-geolocation-accuracy-radius-in-kilometers-by-default, or turn " \
              "coordinates off. No files were written."
      end

      def validate_trusted_proxy_configuration!
        digest = trusted_proxy_configuration_digest
        return if digest.nil?
        return if Clickwrap::Digest.well_formed?(digest)

        raise Thor::Error,
              "--trusted-proxy-configuration-digest must be a complete prefixed SHA-2 digest " \
              "(for example sha256: followed by 64 lowercase hexadecimal characters). " \
              "Omit it to derive provenance from Rails' effective trusted-proxy rules, or " \
              "supply the reviewed digest and try again. No files were written."
      end

      def validate_ip_geolocation_resolver_class_name!
        class_name = ip_geolocation_resolver_class_name
        return if class_name.nil? && !any_ip_geolocation_field?
        return if class_name&.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)

        raise Thor::Error,
              "Recording IP geolocation requires --ip-geolocation-resolver-class-name with " \
              "a Ruby class name such as Clickwrap::IpGeolocation::TrackdownResolver. " \
              "Clickwrap will not choose a provider or dependency for the application. " \
              "No files were written."
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
        say "\n  These are the explicit settings you supplied, not a legal verdict. Review"
        say "  them in the generated initializer before relying on them.", :yellow
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

      # A template rather than a copy, because the placeholder opens with front
      # matter whose `last_updated:` is the document's version label, and the
      # only honest value for it is the day the file was written. That is also
      # why the generated declaration in config/clickwrap.rb needs no `version:`
      # at all: the file carrying the words names its own version.
      def write_legal_placeholder(source, destination)
        if host_file?(destination)
          say_status :skip, "#{destination} (you already have a file there)", :yellow
          return
        end

        template source, destination
      end
    end
  end
end

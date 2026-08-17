# frozen_string_literal: true

module Clickwrap
  # Which optional tables this installation needs, and whether it has them.
  #
  # Seven of the seventeen tables this gem knows about cannot receive a row
  # until a matching configuration is turned on, and every one of those is off
  # by default. `clickwrap:install` therefore emits only the reachable ones, and
  # each capability comes with its own generator flag.
  #
  # That trade has exactly one failure mode: a host turns the capability on and
  # forgets the migration. It must not be discovered by a NoMethodError inside a
  # capture at 3am, so it is discovered at boot, reported by the doctor, and
  # refused at the entry points nothing else covers — always with the exact
  # command that fixes it.
  module SchemaRequirements
    Feature = Data.define(:key, :tables, :flag, :because) do
      def generator_command = "bin/rails generate clickwrap:install #{flag}"

      def explanation
        "#{because} That needs #{"the" if tables.length == 1}" \
          "#{tables.length == 1 ? " #{tables.first} table" : " tables #{tables.join(" and ")}"}, " \
          "which this database does not have. Add #{tables.length == 1 ? "it" : "them"}:\n\n  " \
          "#{generator_command}\n  bin/rails db:migrate"
      end
    end

    FEATURES = [
      Feature.new(
        key: :persisted_presentations,
        tables: %w[clickwrap_presentations].freeze,
        flag: "--with-persisted-presentations",
        because: "A policy declares `persist_presentations_before_submission_for`, so Clickwrap " \
                 "is expected to keep the presentation it offered before the person submitted."
      ),
      Feature.new(
        key: :request_evidence,
        tables: %w[clickwrap_request_evidence].freeze,
        flag: "--with-request-evidence",
        because: "This installation records request evidence — an IP address, a browser " \
                 "user-agent, or provider-estimated IP geolocation."
      ),
      Feature.new(
        key: :integrity,
        tables: %w[clickwrap_chain_heads clickwrap_integrity_attestations].freeze,
        flag: "--with-integrity",
        because: "This installation configures event chaining, external anchoring, or " \
                 "third-party timestamping."
      ),
      Feature.new(
        key: :retention_ops,
        tables: %w[clickwrap_legal_holds clickwrap_disposition_plans].freeze,
        flag: "--with-retention-ops",
        because: "Legal holds and reviewed disposition are the operator tooling for deleting " \
                 "evidence on schedule and pausing that schedule."
      ),
      Feature.new(
        key: :external_actions,
        tables: %w[clickwrap_external_actions].freeze,
        flag: "--with-external-actions",
        because: "`Clickwrap.authorize_external_action!` commits a pending outbox row in the " \
                 "same transaction as the evidence that authorizes it."
      )
    ].freeze

    FEATURES_BY_KEY = FEATURES.index_by(&:key).freeze

    class << self
      def feature!(key) = FEATURES_BY_KEY.fetch(key)

      # Features whose tables are absent, among the ones the CONFIGURATION says
      # this installation uses. Retention operations and external actions are
      # not configured — they are called — so they are checked at their entry
      # points instead, through `require!`.
      #
      # Empty while migrations are pending, and that is the whole point: `rails
      # db:migrate` boots the application before it runs the migration that
      # would satisfy this check, so a boot-time raise here would make the fix
      # unrunnable. An installation mid-migration is not a misconfigured one.
      def missing_for_configuration
        return [] unless schema_is_settled?

        %i[persisted_presentations request_evidence integrity]
          .map { |key| feature!(key) }
          .select { |feature| configured?(feature.key) && installed?(feature) == false }
      end

      # False when migrations are pending, when Clickwrap's own core tables are
      # not there yet, and when the question cannot be answered at all. Each of
      # those is an installation part-way through being set up, and the fix for
      # a missing table is a migration — so refusing to boot before it can run
      # would make the fix unreachable.
      def schema_is_settled?
        return false if table_presence("clickwrap_events") != true

        !pending_migrations?
      rescue StandardError
        false
      end

      # `migration_context.migrations_paths` is relative to the application
      # root, and nothing guarantees the process is running from there — a rake
      # task, a test suite, and a console all disagree. Resolving against
      # `Rails.root` is what makes the answer the same from all three.
      def pending_migrations?
        context = ::ActiveRecord::Base.connection_pool.migration_context
        root = (::Rails.root if defined?(::Rails) && ::Rails.respond_to?(:root))

        paths = Array(context.migrations_paths).map do |path|
          root && !Pathname.new(path).absolute? ? root.join(path).to_s : path
        end

        ::ActiveRecord::MigrationContext.new(paths).needs_migration?
      end

      # Raised at the entry point of a capability nothing in the configuration
      # announces. `installed?` returning nil means the question could not be
      # asked (no database yet), and an unanswerable question is not a refusal.
      def require!(key)
        feature = feature!(key)
        return if installed?(feature) != false

        raise ConfigurationError, feature.explanation
      end

      # true, false, or nil when there is no database to ask. Memoized per
      # feature and cleared with the rest of the global state, because asking
      # the connection on every capture would be a query per event.
      def installed?(feature)
        cache = (@installed ||= {})
        return cache[feature.key] if cache.key?(feature.key)

        answers = feature.tables.map { |table| table_presence(table) }
        # One unanswerable table makes the whole answer unknown. Folding nil
        # into false here would report "not installed" for every application
        # whose connection was not up yet, which is most of them at boot.
        cache[feature.key] = answers.any?(&:nil?) ? nil : answers.all?
      rescue StandardError
        cache[feature.key] = nil
      end

      def reset!
        @installed = nil
      end

      private

      # Three answers, not two: true, false, and nil for "there is no live
      # connection to ask". Deliberately not a predicate, because a predicate
      # that can answer nil is a predicate somebody will read as false.
      def table_presence(table)
        connection = ::ActiveRecord::Base.connection
        return nil unless connection.active?

        connection.data_source_exists?(table)
      end

      def configured?(key)
        case key
        when :persisted_presentations then any_policy_persists_presentations?
        when :request_evidence then records_request_evidence?
        when :integrity then configures_integrity?
        else false
        end
      end

      def any_policy_persists_presentations?
        Clickwrap.policies.any? { |policy| policy.persist_presentations_for.present? }
      end

      def records_request_evidence?
        config = Clickwrap.config
        return true if config.record_ip_address_by_default || config.record_browser_user_agent_by_default
        return true if Vocabulary::IP_GEOLOCATION_DATA_FIELDS.any? do |field|
          config.public_send(:"record_ip_geolocation_#{field}_by_default")
        end

        Clickwrap.policies.any? { |policy| policy.request_evidence.records_anything? }
      end

      def configures_integrity?
        config = Clickwrap.config

        [config.chain_event_history_with, config.anchor_event_history_with,
         config.timestamp_receipts_with].any?(&:present?)
      end
    end
  end
end

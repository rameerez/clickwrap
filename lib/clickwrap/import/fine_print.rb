# frozen_string_literal: true

module Clickwrap
  module Import
    # `bin/rails clickwrap:import:fine_print[:plan]` — read FinePrint's tables
    # and turn its signatures into explicit `imported_legacy` events.
    #
    # ===========================================================================
    # FinePrint is established Rails prior art for versioned contracts and
    # signature gates, and this importer exists because applications outgrow a
    # question, not because they chose badly. FinePrint answers "did user U sign
    # version N of contract X?", and it answers it well. What it does not record
    # — because it was never trying to — is the presentation, the exact wording
    # beside the control, the call to action, the request context, or the domain
    # action the signature authorized.
    #
    # Those fields therefore come across as `unknown` / `not_collected`. This
    # importer synthesizes none of them. A migration that filled in today's
    # Terms digest for a 2019 signature would turn a modest, honest record into
    # a confident false one, and the person reading the receipt in a dispute
    # would have no way to tell.
    #
    # Read against FinePrint's signature model at the audited commit:
    # https://github.com/openstax/fine_print/blob/3b75fbcbcfb048ecd2f4ee7c4f0b9bd3d10f7603/app/models/fine_print/signature.rb#L1-L33
    #
    # NOTE ON COUPLING: this class deliberately does NOT depend on the
    # `fine_print` gem, require any of its files, or reference any of its
    # constants. It reads two tables through the host's own connection, if they
    # are there, and columns are discovered rather than assumed. A migration
    # tool that forces you to keep the gem you are migrating away from installed
    # is a migration tool with a hostage.
    # ===========================================================================
    class FinePrint
      CONTRACTS_TABLE = "fine_print_contracts"
      SIGNATURES_TABLE = "fine_print_signatures"

      # What FinePrint's schema does not contain, recorded on every imported
      # event so the gap is stated rather than inferred from silence.
      UNKNOWN_FIELDS = %w[
        exact_document_bytes
        presentation_manifest
        assertion
        submit_button_text
        protected_action
        request_evidence
        ip_address
        browser_user_agent
      ].freeze

      # A plan or an import, described the same way either way.
      Report = Data.define(:status, :policy_key, :tables_present, :contracts, :signatures,
                           :results, :message) do
        def possible? = status != :tables_absent
        def imported = results.select(&:imported?)
        def already_imported = results.select(&:already_imported?)
        def planned = results.select(&:planned?)
        def to_s = message
      end

      # One FinePrint contract version, and whether this application has a
      # published Clickwrap document version that corresponds to it.
      ContractMapping = Data.define(:name, :version, :title, :document_key, :version_label,
                                    :published_version_id, :signature_count) do
        def published? = !published_version_id.nil?
      end

      class << self
        # Reads everything, writes nothing.
        def plan(**options) = new(dry_run: true, **options).call

        def import!(**options) = new(**options).call
      end

      # `map_contract_with` receives a contract row (a plain Hash of column name
      # to value) and returns the Clickwrap document key that contract
      # corresponds to. `find_actor_with` receives (user_type, user_id) and
      # returns the actor record, or a stable actor reference string, or nil to
      # skip that signature.
      def initialize(policy_key:, find_actor_with:, map_contract_with: nil, contract_names: nil,
                     because: nil, limit: nil, dry_run: false)
        @policy_key = policy_key.to_s
        @find_actor_with = find_actor_with
        @map_contract_with = map_contract_with
        @contract_names = contract_names&.map(&:to_s)
        @because = because
        @limit = limit
        @dry_run = dry_run
      end

      attr_reader :policy_key, :find_actor_with, :map_contract_with, :contract_names,
                  :because, :limit, :dry_run

      def call
        return tables_absent unless tables_present?

        contracts = load_contracts
        mappings = map_contracts(contracts)
        results = import_signatures(contracts)

        Report.new(
          status: dry_run ? :planned : :imported,
          policy_key: policy_key,
          tables_present: true,
          contracts: mappings,
          signatures: results.length,
          results: results,
          message: summary(mappings, results)
        )
      end

      private

      def connection = ::ActiveRecord::Base.connection

      def tables_present?
        connection.data_source_exists?(CONTRACTS_TABLE) &&
          connection.data_source_exists?(SIGNATURES_TABLE)
      end

      # Nothing to do, said plainly. An importer that raised here would make
      # `clickwrap:doctor` and a migration checklist harder to run on an
      # application that simply never used FinePrint.
      def tables_absent
        missing = [CONTRACTS_TABLE, SIGNATURES_TABLE].reject { |table| connection.data_source_exists?(table) }

        Report.new(
          status: :tables_absent, policy_key: policy_key, tables_present: false,
          contracts: [], signatures: 0, results: [],
          message: "FinePrint's tables are not in this database (missing: #{missing.join(", ")}), " \
                   "so there is nothing to import and nothing was written. If you are migrating " \
                   "from FinePrint, run this against the database that still has its tables."
        )
      end

      # Columns are read, not assumed. FinePrint's schema is stable at the
      # audited commit, but a host may have added to it, and an importer that
      # hard-codes a SELECT list breaks on a database it could have read fine.
      def contract_columns = @contract_columns ||= connection.columns(CONTRACTS_TABLE).map(&:name)
      def signature_columns = @signature_columns ||= connection.columns(SIGNATURES_TABLE).map(&:name)

      def load_contracts
        rows = connection.select_all("SELECT * FROM #{quoted(CONTRACTS_TABLE)}").to_a
        return rows if contract_names.nil?

        rows.select { |row| contract_names.include?(row["name"].to_s) }
      end

      def load_signatures
        sql = +"SELECT * FROM #{quoted(SIGNATURES_TABLE)}"
        sql << " ORDER BY #{quoted_column("id")}" if signature_columns.include?("id")
        sql << " LIMIT #{limit.to_i}" if limit

        connection.select_all(sql).to_a
      end

      # FinePrint contract versions become Clickwrap documents. The mapping is
      # host-owned: only the application knows that its FinePrint contract named
      # "terms_of_use" is the document this gem calls `:terms`. What this
      # reports is whether the corresponding version is actually published here,
      # because that is what decides whether an imported event can carry real
      # document bytes or must record the label alone.
      def map_contracts(contracts)
        counts = signature_counts_by_contract_id

        contracts.map do |row|
          document_key = document_key_for(row)
          label = row["version"].to_s
          version = document_key && published_version(document_key, label)

          ContractMapping.new(
            name: row["name"].to_s,
            version: label,
            title: row["title"].to_s.presence,
            document_key: document_key,
            version_label: label,
            published_version_id: version&.id,
            signature_count: counts[row["id"]].to_i
          )
        end
      end

      def signature_counts_by_contract_id
        return {} unless signature_columns.include?("contract_id")

        connection
          .select_all("SELECT contract_id, COUNT(*) AS signature_count FROM " \
                      "#{quoted(SIGNATURES_TABLE)} GROUP BY contract_id")
          .to_a
          .to_h { |row| [row["contract_id"], row["signature_count"]] }
      end

      def import_signatures(contracts)
        by_id = contracts.index_by { |row| row["id"] }

        load_signatures.filter_map do |signature|
          contract = by_id[signature["contract_id"]]
          next if contract.nil?

          actor = resolve_actor(signature)
          next if actor.nil?

          import_one(signature, contract, actor)
        end
      end

      def import_one(signature, contract, actor)
        Legacy.new(
          policy: Clickwrap.policy!(policy_key),
          actor: actor,
          occurred_at: occurred_at_for(signature),
          known: known_for(signature, contract),
          unknown: UNKNOWN_FIELDS,
          because: because || default_reason(signature, contract),
          source: "fine_print",
          capture_channel: "imported_provider",
          dry_run: dry_run
        ).import!
      end

      # FinePrint records when the signature row was created. That is the best
      # time available and it is recorded as `occurred_at` — separate, as
      # always, from when this import wrote the Clickwrap event down.
      def occurred_at_for(signature)
        signature["created_at"] || signature["updated_at"]
      end

      def known_for(signature, contract)
        {
          "source_system" => "fine_print",
          "fine_print_signature_id" => signature["id"],
          "fine_print_contract_id" => contract["id"],
          "contract_name" => contract["name"],
          "contract_title" => contract["title"],
          # Deliberately NOT written as `document_version`: that key makes the
          # legacy importer link published bytes, and a FinePrint version number
          # is a label in another system's numbering, not a claim about ours.
          "fine_print_contract_version" => contract["version"],
          "signed_by_type" => signature["user_type"] || signature["signer_type"],
          "signed_by_id" => signature["user_id"] || signature["signer_id"]
        }.compact
      end

      def default_reason(signature, contract)
        "Imported from FinePrint signature #{signature["id"]} for contract " \
          "#{contract["name"]} version #{contract["version"]}"
      end

      def resolve_actor(signature)
        find_actor_with.call(
          signature["user_type"] || signature["signer_type"],
          signature["user_id"] || signature["signer_id"]
        )
      end

      def document_key_for(contract)
        return map_contract_with.call(contract)&.to_s if map_contract_with

        contract["name"].to_s.presence
      end

      def published_version(document_key, label)
        document = ::Clickwrap::Document.find_by(key: document_key, tenant_key: nil)
        return nil unless document

        document.versions.find_by(version_label: label)
      end

      def summary(mappings, results)
        unpublished = mappings.reject(&:published?).map { |mapping| "#{mapping.name}@#{mapping.version}" }

        [
          dry_run ? "Would import" : "Imported",
          "#{results.length} FinePrint signature(s) into #{policy_key} as imported_legacy events.",
          "Presentation manifest, IP address, call-to-action text, and protected action were not " \
          "recorded by FinePrint and are marked unknown rather than filled in.",
          if unpublished.empty?
            nil
          else
            "No published Clickwrap document version matches: " \
                                               "#{unpublished.join(", ")}. Those imports record the label " \
                                               "only, not document bytes."
          end
        ].compact.join(" ")
      end

      def quoted(table) = connection.quote_table_name(table)
      def quoted_column(column) = connection.quote_column_name(column)
    end
  end
end

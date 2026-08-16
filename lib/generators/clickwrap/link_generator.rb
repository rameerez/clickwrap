# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Clickwrap
  module Generators
    # Links a domain table to the clickwrap evidence that authorized its rows:
    #
    #   bin/rails generate clickwrap:link payouts_withdrawals
    #
    # writes the migration for a `clickwrap_event_id` column (ULID string,
    # indexed, nullable, no foreign key — see the migration's own comment for
    # why each of those is deliberate). Pair it with `has_clickwrap_evidence`
    # on the model and assign `pending_receipt.event_id` inside
    # `capture_clickwrap_and!`.
    class LinkGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :table_name, type: :string,
                            desc: "The domain table whose rows are authorized by a clickwrap capture"

      def create_link_migration
        migration_template "link_clickwrap_event_migration.rb.erb",
                           "db/migrate/add_clickwrap_event_to_#{table_name}.rb"
      end

      def explain
        say ""
        say "Next, on the model:"
        say ""
        say "  has_clickwrap_evidence"
        say ""
        say "and assign the event inside the capture that authorizes the row:"
        say ""
        say "  capture_clickwrap_and!(:your_policy) do |pending_receipt|"
        say "    record.clickwrap_event_id = pending_receipt.event_id"
        say "    record.save!"
        say "  end"
        say ""
      end

      private

      def migration_class_name
        "AddClickwrapEventTo#{table_name.camelize}"
      end
    end
  end
end

# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Clickwrap
  module Generators
    # `rails generate clickwrap:upgrade` — the schema changes a newer release
    # needs, as NEW migrations.
    #
    # This generator exists because of a promise: a released migration is never
    # edited underneath an installed application. Editing one would change the
    # schema that existing evidence was written under while leaving that evidence
    # in place, and a receipt whose table no longer means what it meant is worth
    # less than no receipt at all. So upgrades add migrations, and the files you
    # already ran stay exactly as they were.
    #
    # At 0.1.0 there is nothing to upgrade from. This generator says so and
    # creates nothing, rather than writing an empty migration to look busy.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Create the migrations needed to move an installed app to this release"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_upgrade_migrations
        say "\n☑️  clickwrap #{Clickwrap::VERSION} has no upgrade migrations.", :green
        say "\n0.1.0 is the first release, so there is no earlier schema to move from and"
        say "nothing was created."
        say "\nIf you are installing clickwrap for the first time, you want:"
        say "    bin/rails generate clickwrap:install"
        say "\nWhen a later release needs a schema change, this generator will add NEW"
        say "migrations for it and report exactly what they do. Your existing migration"
        say "files stay untouched, and evidence written under them goes on verifying —"
        say "every released receipt format keeps a golden fixture, and a new format means"
        say "a new explicit schema and verifier rather than a quiet reinterpretation.\n"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end

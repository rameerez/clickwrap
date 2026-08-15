# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Clickwrap
  module Generators
    # `rails generate clickwrap:hardening --database` — the opt-in database tier.
    #
    # Clickwrap's models already refuse `update` and `destroy` on an event. This
    # generator adds the same refusal one layer down, where a stray console
    # session, a bulk `update_all`, or a well-meaning data-fix script cannot talk
    # its way past a callback.
    #
    # What that is worth is bounded, and the bound is the point: it rejects
    # unsupported mutation paths within the documented database threat model. It
    # does not make rows impossible to change, and it does nothing at all against
    # anyone holding database superuser rights, direct file access, or the
    # ability to drop the triggers — which, in most Rails applications, is the
    # same credential that runs migrations. Real assurance against that comes
    # from the tiers above it: chained history, independent anchoring, and
    # provider timestamps.
    #
    # It is opt-in because it is a production decision with real consequences for
    # anyone who clears tables with DELETE.
    class HardeningGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add opt-in database update/delete protection for clickwrap evidence tables"

      class_option :database, type: :boolean, default: false,
                              desc: "Required. Generate the adapter-specific database protection migration."

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def require_explicit_opt_in!
        return if options[:database]

        raise Thor::Error, <<~MSG
          ❌ Nothing was generated, on purpose.

          Database hardening changes what your database will accept, in every
          environment the migration runs in, so it is never applied as a side
          effect of installing the gem. Ask for it explicitly:

            rails generate clickwrap:hardening --database

          Read what it does and does not do first — the generated migration says
          so at the top, and the honest summary is: it rejects unsupported
          mutation paths, and it stops nobody with superuser rights.
        MSG
      end

      def create_migration_file
        migration_template "clickwrap_hardening.rb.erb",
                           File.join(db_migrate_path, "clickwrap_database_hardening.rb")
      end

      def explain_adapter_support
        case adapter_family
        when :postgresql then explain_postgresql
        when :sqlite then explain_sqlite
        when :mysql then explain_mysql
        else explain_unknown_adapter
        end
      end

      def display_post_install_message
        say "\n☑️  The database hardening migration has been created.", :green
        say "\nBefore you run it:"
        say "  1. Read it. It is short, and the comments say exactly what it rejects."
        say "  2. Check how your test suite clears tables. Transactional tests are fine —"
        say "     a rollback is not a DELETE. But fixtures, and any cleaner using the"
        say "     deletion strategy, run `DELETE FROM …`, and these protections will"
        say "     reject that on the three evidence tables."
        say "  3. Run 'rails db:migrate'."
        say "\nThe migration is reversible: `rails db:rollback` removes the triggers and"
        say "functions it created and leaves your data alone."
        say "\nWhat this tier claims, in full: it rejects unsupported mutation paths within"
        say "the documented database threat model. Nothing more. A local digest is still a"
        say "local digest, and your server's clock is still your server's clock.\n"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end

      def database_adapter
        return @database_adapter if defined?(@database_adapter)

        @database_adapter = ActiveRecord::Base.connection_db_config.adapter.to_s.downcase
      rescue StandardError
        @database_adapter = nil
      end

      def adapter_family
        case database_adapter
        when /postgres|postgis/ then :postgresql
        when /sqlite/ then :sqlite
        when /mysql|trilogy/ then :mysql
        end
      end

      def explain_postgresql
        say "\n   PostgreSQL detected. The migration installs row-level triggers that:", :green
        say "     • reject any UPDATE to clickwrap_events except the three columns"
        say "       Clickwrap itself writes (core_event_disposed_at, on_legal_hold,"
        say "       request_evidence_id — disposition and legal holds);"
        say "     • reject every DELETE from clickwrap_events; and"
        say "     • reject every UPDATE and DELETE on clickwrap_event_statements and"
        say "       clickwrap_event_documents, which have no legitimate mutation at all."
        say "\n   Optional personal request evidence is deliberately NOT protected: it has"
        say "   to stay deletable on its retention schedule, and disposition appends its"
        say "   own event recording that it happened."
      end

      def explain_sqlite
        say "\n⚠️  SQLite detected. The migration will run and do nothing.", :yellow
        say "\n   This is not an oversight, and writing SQLite triggers here would be"
        say "   theatre. SQLite has no users, no roles, and no privileges: the database is"
        say "   a file, and any process that can open it for writing can drop a trigger as"
        say "   easily as it can update a row. A protection that the thing it protects"
        say "   against can remove in one statement is worth stating honestly rather than"
        say "   installing."
        say "\n   What still holds on SQLite: the models refuse update and destroy, the"
        say "   schema has no `updated_at` on events to tempt anyone, every receipt is"
        say "   digest-verified, and `bin/rails clickwrap:verify` detects bytes that no"
        say "   longer match. What does not hold: anything about a writer with file access."
        say "\n   If this data matters that much, the tier that helps is independent"
        say "   anchoring — chain heads stored somewhere the database cannot rewrite."
      end

      def explain_mysql
        say "\n⚠️  MySQL detected. The migration will run and do nothing.", :yellow
        say "\n   MySQL triggers could raise on UPDATE and DELETE, so the honest reason is"
        say "   narrower than SQLite's: what MySQL cannot do is protect the triggers"
        say "   themselves from the account that installs them. Your application user runs"
        say "   migrations, so it holds TRIGGER (and usually DROP), and a protection that"
        say "   the protected account can remove is a comment, not a control."
        say "\n   The control that does work on MySQL is privilege separation, and it lives"
        say "   outside this gem: a migration role that owns the schema, and a runtime role"
        say "   with SELECT and INSERT on clickwrap_events, clickwrap_event_statements, and"
        say "   clickwrap_event_documents, plus UPDATE on nothing but the disposition and"
        say "   legal-hold columns. That is a database-administration decision with real"
        say "   operational consequences, so this generator explains it instead of guessing"
        say "   at your deployment."
      end

      def explain_unknown_adapter
        say "\n⚠️  Adapter #{database_adapter || "unknown"} is outside the tested set.", :yellow
        say "   The migration only applies protections on PostgreSQL; on anything else it"
        say "   runs and does nothing rather than executing DDL nobody has tested."
      end
    end
  end
end

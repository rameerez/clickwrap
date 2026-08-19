# frozen_string_literal: true

module Clickwrap
  # A small coordination row for one exact statement identity or actor-wide
  # state scope. Evidence stays in Event; this table exists because a row
  # lock cannot be taken before the first projection/event creates its row.
  #
  # Persisting one lock per identity avoids adapter-specific advisory locks.
  # On PostgreSQL and MySQL each acquisition is a real row lock; SQLite emits
  # no locking clause (Arel's SQLite visitor is a no-op for FOR UPDATE), so
  # what serializes writers there is the database-wide write lock — a
  # different mechanism whose contention surfaces as SQLITE_BUSY rather than
  # a blocked row. The concurrency test lane runs on PostgreSQL and MySQL for
  # exactly this reason. Callers acquire several identities in digest order so
  # policies with more than one one-time statement cannot deadlock by
  # choosing a different order.
  class StatementIdentityLock < ApplicationRecord
    self.table_name = "clickwrap_statement_identity_locks"

    validates :identity_digest, presence: true

    def self.acquire!(identity_digest)
      lock_row = create_or_find_by!(identity_digest:) do |row|
        row.created_at = Clickwrap.now
      end
      lock_row.lock!
      lock_row
    end

    def self.actor_state_scope_for(actor_reference)
      Digest.digest_canonical({ "actor_state_reference" => actor_reference.to_s })
    end

    def self.acquire_for_actor!(actor_reference)
      acquire!(actor_state_scope_for(actor_reference))
    end
  end
end

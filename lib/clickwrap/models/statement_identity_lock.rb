# frozen_string_literal: true

module Clickwrap
  # A small coordination row for one exact statement identity. Evidence stays
  # in Event; this table exists only because a row lock cannot be taken on a
  # StatementState row before the first authorization creates that row.
  #
  # Persisting one lock per identity avoids adapter-specific advisory locks and
  # gives PostgreSQL, MySQL, and SQLite the same correctness contract. Callers
  # acquire several identities in digest order so policies with more than one
  # one-time statement cannot deadlock by choosing a different order.
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
  end
end

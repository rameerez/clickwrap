# frozen_string_literal: true

module Clickwrap
  # The head of one tamper-evident event chain.
  #
  # Chaining is off unless configured, and when it is on the scope is per tenant
  # or per aggregate, never one global chain. A single chain across unrelated
  # tenants turns every capture into a queue behind every other capture, and
  # buys assurance nobody asked for at a cost everybody pays.
  #
  # What a chain detects: an event rewritten or removed after the fact, as long
  # as the head remains trustworthy. What it does not do: stop a party with full
  # control of the application and database from rewriting both the events and
  # the head. That is what the optional independent anchor adapter is for, and
  # even then the claim is only as strong as the anchor.
  class ChainHead < ApplicationRecord
    self.table_name = "clickwrap_chain_heads"

    validates :chain_scope, presence: true, uniqueness: true

    # Appends an event to its chain and returns [previous_digest, sequence].
    # Takes a row lock so two concurrent captures in the same scope cannot both
    # read the same predecessor and produce a fork.
    def self.append!(chain_scope:, event_id:, event_digest:)
      head = lock.find_by(chain_scope: chain_scope) ||
             create!(chain_scope: chain_scope, sequence: 0)

      previous_digest = head.last_event_digest
      next_sequence = head.sequence + 1

      head.update!(
        last_event_id: event_id,
        last_event_digest: event_digest,
        sequence: next_sequence
      )

      [previous_digest, next_sequence]
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def to_s = "chain #{chain_scope} at #{sequence}"
  end
end

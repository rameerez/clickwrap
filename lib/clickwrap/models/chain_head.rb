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

    # Appending is two phases, and it has to be.
    #
    # An event's digest is computed from its own body, which the event does not
    # have until it is built — but its `previous_event_digest` has to be set
    # before it is saved. So `reserve!` hands out the predecessor's digest and
    # the next sequence number, the event is written with those, and `record!`
    # then stores the digest the event actually ended up with.
    #
    # Doing it in one call is how a chain quietly ends up with a head full of
    # nils: every link would point at a digest that had not been computed yet.

    # Takes the next position in the chain. The row lock is what stops two
    # concurrent captures in the same scope from reading the same predecessor
    # and forking the chain.
    def self.reserve!(chain_scope:)
      head = lock.find_by(chain_scope: chain_scope) ||
             create!(chain_scope: chain_scope, sequence: 0)

      next_sequence = head.sequence + 1
      previous_digest = head.last_event_digest

      head.update!(sequence: next_sequence)

      [previous_digest, next_sequence]
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    # Records the digest the event was actually written with, so the next event
    # in this scope links to something real.
    def self.record!(chain_scope:, event_id:, event_digest:)
      head = lock.find_by(chain_scope: chain_scope)
      return nil unless head

      head.update!(last_event_id: event_id, last_event_digest: event_digest)
      head
    end

    def to_s = "chain #{chain_scope} at #{sequence}"
  end
end

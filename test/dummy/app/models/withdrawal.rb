# frozen_string_literal: true

# A consequential domain record: the thing a one-time authorization authorizes.
# This is the "protected action" in `capture_and!` — the whole point being that
# a withdrawal must never reach `submitted` without the evidence that authorized
# it committing in the same transaction.
class Withdrawal < ApplicationRecord
  has_clickwrap_evidence policy: :withdrawal_authorization,
                         statement: :withdrawal,
                         actor: :user,
                         subject: :self,
                         required_for_new_records: false
  belongs_to :user

  def submit!(authorized_by_clickwrap_event:)
    update!(state: "submitted", authorized_by_clickwrap_event: authorized_by_clickwrap_event)
    self
  end

  # What the policy fingerprints. Changing the covered order set changes this, so
  # an authorization for one set cannot be replayed against another.
  def covered_orders_fingerprint = "orders:#{covered_order_ids}"

  def evidence_fingerprint = "withdrawal:#{id}:#{amount_cents}:#{covered_order_ids}"
end

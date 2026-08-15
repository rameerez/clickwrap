# frozen_string_literal: true

module Clickwrap
  # A frozen snapshot of one compiled policy.
  #
  # Policies are written in Ruby because that is what a reviewer can read in a
  # pull request. But an export has to stay intelligible after the source has
  # moved on, so the first time a revision is presented or captured its compiled
  # form is written here and never changed. An event points at the revision it
  # was captured under, so a receipt explains itself without a checkout of the
  # application at the right commit.
  #
  # The revision digest covers declared structure and copy. Host callables —
  # subject fingerprints, protected-outcome recorders — are recorded as present
  # rather than serialized, because a lambda's body cannot be canonicalized.
  # That boundary is stated in the receipt rather than papered over.
  class PolicyRevision < ApplicationRecord
    self.table_name = "clickwrap_policy_revisions"

    has_many :events,
             class_name: "Clickwrap::Event",
             foreign_key: :policy_revision_id,
             inverse_of: :policy_revision,
             dependent: :restrict_with_error

    has_many :presentations,
             class_name: "Clickwrap::Presentation",
             foreign_key: :policy_revision_id,
             inverse_of: :policy_revision,
             dependent: :restrict_with_error

    validates :policy_key, :revision_digest, :canonical_schema_version, :gem_version, presence: true
    validates :revision_digest, uniqueness: { scope: :policy_key }

    before_update :refuse_change

    scope :for_policy, ->(key) { where(policy_key: key.to_s) }

    # Finds or freezes the revision for a compiled policy. Called on the first
    # presentation and again at capture; both are races that the unique index
    # settles, so a lost race just reads the row the winner wrote.
    def self.freeze_for(policy)
      existing = find_by(policy_key: policy.key, revision_digest: policy.revision)
      return existing if existing

      create!(
        policy_key: policy.key,
        revision_digest: policy.revision,
        compiled_snapshot: policy.snapshot,
        retention_class_key: policy.retention_class_key,
        canonical_schema_version: Clickwrap::CANONICAL_SCHEMA_VERSION,
        gem_version: Clickwrap::VERSION,
        compiled_at: Clickwrap.now,
        created_at: Clickwrap.now
      )
    rescue ActiveRecord::RecordNotUnique
      find_by!(policy_key: policy.key, revision_digest: policy.revision)
    end

    # True when the currently loaded policy compiles to this same revision. A
    # false is not an error — it means the policy has been edited since, which
    # is exactly why the snapshot is here.
    def matches_loaded_policy?
      Clickwrap.policies[policy_key]&.revision == revision_digest
    end

    def statement_snapshot(statement_key)
      Array(compiled_snapshot["statements"]).find { |s| s["key"] == statement_key.to_s }
    end

    def to_s = "#{policy_key}@#{revision_digest}"

    private

    def refuse_change
      raise EventWriteFailed,
            "Policy revision #{self} is frozen. Editing the policy in Ruby produces a new " \
            "revision; it does not change what earlier events were captured under."
    end
  end
end

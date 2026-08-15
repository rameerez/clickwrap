# frozen_string_literal: true

# The dummy HOST's own tables — the User (actor), Organization (tenant), and
# Withdrawal (subject / protected action) models the gem is applied to. These are
# NOT part of the gem; they stand in for whatever a real host app already has.
# Kept deliberately tiny: just the columns the suite reads.
class CreateDummyHostTables < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :email
      t.string :name
      t.string :role
      t.datetime :accepted_terms_at
      t.string :terms_version
      t.timestamps
    end

    create_table :organizations do |t|
      t.string :name
      t.timestamps
    end

    create_table :withdrawals do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :amount_cents, null: false, default: 0
      t.string :covered_ride_ids, null: false, default: ""
      t.string :state, null: false, default: "draft"
      t.string :authorized_by_clickwrap_event
      t.timestamps
    end
  end
end

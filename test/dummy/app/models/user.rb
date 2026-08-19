# frozen_string_literal: true

# The dummy host's actor model — the README's one-liner.
class User < ApplicationRecord
  has_clickwraps

  has_many :withdrawals, dependent: :destroy

  def security_operator? = role == "security_operator"
end

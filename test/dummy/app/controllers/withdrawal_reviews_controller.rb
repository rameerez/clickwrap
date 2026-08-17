# frozen_string_literal: true

# A subject-bound host action used to prove that the remediation route carries
# the exact server-owned Withdrawal through the standalone Clickwrap screen.
class WithdrawalReviewsController < ApplicationController
  before_action :find_withdrawal
  requires_clickwrap :contractor_declaration, subject_with: :withdrawal

  def show
    render plain: "withdrawal review #{@withdrawal.id}"
  end

  private

  attr_reader :withdrawal

  def find_withdrawal
    @withdrawal = current_user.withdrawals.find(params[:id])
  end
end

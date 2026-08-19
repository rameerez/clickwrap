# frozen_string_literal: true

# A host controller behind the `requires_clickwrap` gate.
#
# The gate is only observable through a real request: it has to resolve the
# current actor, verify the policy, notice that the visitor is an HTML browser or
# a JSON client, and either redirect them somewhere they can fix it or hand back
# something they can branch on. So the dummy carries a gated controller and
# test/integration/capture_flow_test.rb drives it.
#
# `requires_clickwrap` is declared with no `remediation_path:`, which is the
# ordinary case: the dummy mounts Clickwrap::Engine, so the gate resolves the
# mounted capture screen itself.
class BillingController < ApplicationController
  requires_clickwrap :current_terms

  def show
    respond_to do |format|
      format.html { render plain: "billing statement" }
      format.json { render json: { billing: "statement" } }
    end
  end
end

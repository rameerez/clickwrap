# frozen_string_literal: true

require "test_helper"

# Row locks must be exercised through separate real database connections. SQLite
# has one writer and cannot prove this guarantee; the PostgreSQL and MySQL matrix
# runs the race against the same databases production applications use.
class RetentionConcurrencyTest < ActiveSupport::TestCase
  use_real_database_commits!

  test "two appliers cannot both apply one reviewed plan" do
    adapter = ActiveRecord::Base.connection.adapter_name.downcase
    skip "concurrent writers need PostgreSQL or MySQL (this lane is #{adapter})" if adapter.include?("sqlite")

    user = create_user
    operator = create_security_operator
    receipt = submit_clickwrap(:signup, actor: user)

    travel_to 7.years.from_now do
      plan = Clickwrap::Retention::Planner.new(
        created_by: operator,
        because: "Scheduled retention run"
      ).call
      start_line = Queue.new
      outcomes = Queue.new

      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start_line.pop
            result = Clickwrap::Retention::Applier.new(
              Clickwrap::DispositionPlan.find(plan.id),
              applied_by: operator.clickwrap_actor_reference
            ).call
            outcomes << result
          rescue StandardError => error
            outcomes << error
          end
        end
      end

      2.times { start_line << true }
      threads.each(&:join)
      results = 2.times.map { outcomes.pop }
      successes = results.grep(Clickwrap::Retention::Applier::Result)
      refusals = results.grep(Clickwrap::DispositionPlanInvalid)
      unexpected = results.grep(StandardError) - refusals

      assert_empty unexpected, unexpected.map(&:full_message).join("\n")
      assert_equal 1, successes.length
      assert_equal 1, refusals.length
      assert_match(/already being applied|already applied/, refusals.first.message)
      assert receipt.event.reload.disposed?
      assert_equal 1,
                   Clickwrap::Event.where(event_type: "disposition",
                                          predecessor_event_id: receipt.event_id).count
      assert_equal "applied", plan.reload.state
      assert_equal 1, plan.application_attempt_count
    end
  end
end

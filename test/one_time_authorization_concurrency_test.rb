# frozen_string_literal: true

require "test_helper"

# Real commits and separate connections are required to exercise the absent-row
# race. SQLite intentionally skips this: it has one writer, while PostgreSQL and
# MySQL CI run the contention the production guarantee depends on.
class OneTimeAuthorizationConcurrencyTest < ActiveSupport::TestCase
  use_real_database_commits!

  test "different concurrent presentations cannot both perform one protected action" do
    adapter = ActiveRecord::Base.connection.adapter_name.downcase
    skip "concurrent writers need PostgreSQL or MySQL (this lane is #{adapter})" if adapter.include?("sqlite")

    user = create_user
    withdrawal = create_withdrawal(user: user)
    presentations = 2.times.map do
      present_clickwrap(:withdrawal_authorization, actor: user, subject: withdrawal)
    end
    answers = { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }
    starts = Queue.new
    results = Queue.new
    counter = 0
    counter_lock = Mutex.new

    deadlock_retries = 0

    threads = presentations.map do |presentation|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          attempts = 0
          begin
            Clickwrap.capture_and!(
              :withdrawal_authorization,
              actor: User.find(user.id),
              subject: Withdrawal.find(withdrawal.id),
              submission: submission_for(presentation, answers)
            ) do
              counter_lock.synchronize { counter += 1 }
              # The block's return value is what record_protected_outcome_with
              # receives — the policy's hook describes a withdrawal, so return
              # one, exactly as a real protected action would.
              Withdrawal.find(withdrawal.id)
            end
            results << :committed
          rescue Clickwrap::OneTimeAuthorizationConflict
            results << :conflict
          rescue Clickwrap::RetryableTransactionError
            # MySQL sometimes resolves this exact race by killing one
            # transaction as a deadlock victim instead of letting it lose
            # cleanly at the unique index. The gem deliberately refuses to
            # auto-retry — it cannot prove a protected action is safe to run
            # twice — and tells the HOST to retry the whole operation. This
            # test is the host, and the retried loser must then find the
            # authorization consumed and get the ordinary conflict answer.
            attempts += 1
            counter_lock.synchronize { deadlock_retries += 1 }
            retry if attempts < 3
            raise
          rescue StandardError => error
            results << error
          end
        end
      end
    end

    2.times { starts << true }
    threads.each(&:join)
    outcomes = 2.times.map { results.pop }

    unexpected = outcomes.grep(StandardError)
    assert_empty unexpected, unexpected.map(&:full_message).join("\n")
    assert_equal %i[committed conflict], outcomes.sort

    # THE guarantee: exactly one authorization committed, exactly one evidence
    # event exists. The Ruby counter can legitimately read 2 when a deadlock
    # victim had already run its block before the database rolled it back —
    # that rollback is the capture_and! contract working, not a double commit,
    # and it is why hosts must keep protected-action blocks transactional.
    if deadlock_retries.zero?
      assert_equal 1, counter
    else
      assert_includes [1, 2], counter
    end
    assert_equal 1, Clickwrap::Event.captures.for_policy("withdrawal_authorization").count
  end

  test "concurrent captures reserve distinct linked chain positions" do
    adapter = ActiveRecord::Base.connection.adapter_name.downcase
    skip "concurrent writers need PostgreSQL or MySQL (this lane is #{adapter})" if adapter.include?("sqlite")

    Clickwrap.config.chain_event_history_with = :sha256
    users = 2.times.map { create_user }
    presentations = users.map { |user| present_clickwrap(:signup, actor: user) }
    starts = Queue.new
    errors = Queue.new

    threads = users.zip(presentations).map do |user, presentation|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          starts.pop
          Clickwrap.capture!(
            :signup,
            actor: User.find(user.id),
            submission: submission_for(presentation, terms: "1", privacy_notice: "1")
          )
        rescue StandardError => error
          errors << error
        end
      end
    end

    2.times { starts << true }
    threads.each(&:join)
    unexpected = []
    unexpected << errors.pop until errors.empty?
    assert_empty unexpected, unexpected.map(&:full_message).join("\n")

    events = Clickwrap::Event.for_policy("signup").order(:chain_sequence).to_a
    assert_equal [1, 2], events.map(&:chain_sequence)
    assert_nil events.first.previous_event_digest
    assert_equal events.first.event_digest, events.second.previous_event_digest

    head = Clickwrap::ChainHead.find_by!(chain_scope: "global/signup")
    assert_equal events.second.id, head.last_event_id
    assert_equal events.second.event_digest, head.last_event_digest
    assert Clickwrap::Integrity::Chain.verify(scope: "global/signup").success?
  end
end

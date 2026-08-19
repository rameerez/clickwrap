# frozen_string_literal: true

require "time"

module Clickwrap
  # Fault injection, for this gem's suite and for yours.
  #
  # ===========================================================================
  # The central promise of this gem is that required evidence and the protected
  # database action commit together or not at all. A promise like that is worth
  # exactly as much as your ability to prove it in a test, and you cannot prove
  # it by reading the code — you prove it by making the evidence write fail on
  # purpose and watching the account, the payout, or the withdrawal fail with
  # it.
  #
  #   Clickwrap::Testing.fail_next_event_write do
  #     assert_raises(Clickwrap::EventWriteFailed) { perform_signup }
  #   end
  #
  #   assert_not User.exists?(email: "person@example.com")
  #   assert_no_clickwrap_event :signup
  #
  # The failure is injected INSIDE the `Clickwrap::Event` create, which means
  # inside the capture's transaction, which means the host's protected action
  # rolls back with it. Raising before the transaction opened would prove
  # nothing at all: of course the domain action does not happen if the capture
  # never started.
  #
  # Everything here installs on entry and removes on exit, in an `ensure`, so a
  # failing assertion inside the block cannot leave a sabotage hook attached to
  # `Clickwrap::Event` for the rest of the suite. Nothing here is left resident
  # in a production process: the callbacks exist only while a block is running,
  # and this file is only loaded if something references `Clickwrap::Testing`.
  # ===========================================================================
  module Testing
    # Raised by `fail_next_domain_write`. Deliberately not one of the gem's
    # real errors: it stands in for the host's own domain failure, and a test
    # that rescued a Clickwrap error here would be testing the wrong thing.
    class DomainWriteFailed < StandardError; end

    EVENT_WRITE_KEY = :clickwrap_testing_fail_next_event_write
    DOMAIN_WRITE_KEY = :clickwrap_testing_fail_next_domain_write
    FROZEN_TIME_KEY = :clickwrap_testing_frozen_time

    # The injected callbacks, held as constants so `skip_callback` can find the
    # same object it was given. An anonymous lambda created per call would
    # install fine and never come off.
    FAIL_EVENT_WRITE = lambda do |_event|
      next unless Testing.consume_flag!(EVENT_WRITE_KEY)

      raise EventWriteFailed,
            "Clickwrap::Testing.fail_next_event_write made this evidence write fail on purpose. " \
            "Whatever your protected action did in this transaction must roll back with it — " \
            "that is the property this helper exists to let you assert."
    end

    FAIL_DOMAIN_WRITE = lambda do |record|
      next if record.is_a?(Clickwrap::ApplicationRecord)
      next unless Testing.consume_flag!(DOMAIN_WRITE_KEY)

      raise DomainWriteFailed,
            "Clickwrap::Testing.fail_next_domain_write made this domain write fail on purpose. " \
            "The Clickwrap evidence in the same transaction must roll back with it, so that a " \
            "failed action never leaves behind a receipt saying it succeeded."
    end

    # Reads the frozen server clock, if a `freeze_time_at` block is running.
    # Prepended onto `Clickwrap`'s singleton rather than redefining `now`, so
    # the original method stays reachable through `super` and restoring it is
    # not a matter of remembering to.
    module FrozenClock
      def now
        Testing.frozen_time || super
      end
    end

    class << self
      # Makes the NEXT `Clickwrap::Event` insert raise
      # `Clickwrap::EventWriteFailed`, from inside the create, and therefore
      # from inside whatever transaction the capture is running in.
      #
      # Only the next one: a capture that legitimately retries, or a test that
      # goes on to record a control event afterwards, is not sabotaged twice.
      def fail_next_event_write
        install_event_callback!
        Thread.current[EVENT_WRITE_KEY] = true

        yield
      ensure
        Thread.current[EVENT_WRITE_KEY] = nil
        remove_event_callback!
      end

      # The mirror image: makes the next non-Clickwrap `ActiveRecord` save
      # raise, so you can prove the other direction — that a domain action
      # blowing up takes its evidence down with it, and never leaves a receipt
      # describing something that did not happen.
      def fail_next_domain_write
        install_domain_callback!
        Thread.current[DOMAIN_WRITE_KEY] = true

        yield
      ensure
        Thread.current[DOMAIN_WRITE_KEY] = nil
        remove_domain_callback!
      end

      # Freezes the server clock Clickwrap records and evaluates expiry
      # against, so a test about a declaration that expired last Tuesday does
      # not have to sleep until next Tuesday.
      #
      # It moves `Clickwrap.now` only. `Time.now` is left alone on purpose:
      # this gem's evidentiary time is the value it writes into
      # `recorded_at_by_server`, and a helper that quietly moved the whole
      # process clock would make it much harder to tell which of the two a test
      # actually depends on.
      def freeze_time_at(moment)
        moment = Time.parse(moment.to_s) if moment.is_a?(String)
        previous = Thread.current[FROZEN_TIME_KEY]

        install_clock!
        Thread.current[FROZEN_TIME_KEY] = moment.utc

        block_given? ? yield(moment.utc) : moment.utc
      ensure
        Thread.current[FROZEN_TIME_KEY] = previous
      end

      def frozen_time = Thread.current[FROZEN_TIME_KEY]

      # Clears every flag and detaches every injected callback. Safe to call
      # when nothing was ever installed, which is the point: a suite calls it
      # in `setup` and in `teardown` without having to know whether the test
      # that just ran used any of this.
      def reset!
        Thread.current[EVENT_WRITE_KEY] = nil
        Thread.current[DOMAIN_WRITE_KEY] = nil
        Thread.current[FROZEN_TIME_KEY] = nil

        # Unconditional, and `raise: false` throughout: `reset!` is called from
        # `setup` and `teardown` in suites that mostly never touch fault
        # injection, and it must be a quiet no-op there rather than an
        # ArgumentError about a callback nobody installed.
        @event_depth = 0
        @domain_depth = 0
        Event.skip_callback(:create, :before, FAIL_EVENT_WRITE, raise: false)
        ::ActiveRecord::Base.skip_callback(:save, :before, FAIL_DOMAIN_WRITE, raise: false)

        self
      end

      # Reads a one-shot flag and clears it in the same breath, so the sabotage
      # applies to exactly one write.
      def consume_flag!(key)
        return false unless Thread.current[key]

        Thread.current[key] = nil
        true
      end

      private

      # Installed only while a block is active. There is no permanent
      # production hook on `Clickwrap::Event`: a gem whose whole subject is
      # trustworthy writes has no business leaving a callback in the write path
      # whose only job is to break it.
      #
      # The depth counters are not ceremony. Nested blocks are ordinary in a
      # suite that tests one fault inside another, and an inner `ensure` that
      # detached the callback would silently disarm the outer one.
      def install_event_callback!
        @event_depth = @event_depth.to_i + 1
        return if @event_depth > 1

        Event.set_callback(:create, :before, FAIL_EVENT_WRITE)
      end

      def remove_event_callback!
        return if @event_depth.to_i.zero?

        @event_depth -= 1
        return if @event_depth.positive?

        Event.skip_callback(:create, :before, FAIL_EVENT_WRITE, raise: false)
      end

      def install_domain_callback!
        @domain_depth = @domain_depth.to_i + 1
        return if @domain_depth > 1

        ::ActiveRecord::Base.set_callback(:save, :before, FAIL_DOMAIN_WRITE)
      end

      def remove_domain_callback!
        return if @domain_depth.to_i.zero?

        @domain_depth -= 1
        return if @domain_depth.positive?

        ::ActiveRecord::Base.skip_callback(:save, :before, FAIL_DOMAIN_WRITE, raise: false)
      end

      # `prepend` with an already-prepended module is a no-op, so this is safe
      # to call from every `freeze_time_at`. The module falls straight through
      # to `super` whenever no time is frozen, which is always outside a block.
      def install_clock!
        Clickwrap.singleton_class.prepend(FrozenClock)
      end
    end
  end
end

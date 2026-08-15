# frozen_string_literal: true

module Clickwrap
  # One normalization path for every stable reference Clickwrap writes or
  # queries. Keeping this in one place is security-relevant: a capture written
  # under a GlobalID must not become unreachable because a lifecycle or actor
  # proxy later queried the same tenant with `to_s`.
  module Reference
    class << self
      def actor(actor)
        return nil if actor.nil?
        return actor.to_s if actor.is_a?(String) || actor.is_a?(Symbol)

        Clickwrap.config.identify_actor_with.call(actor).to_s
      end

      def tenant(tenant)
        stable(tenant)
      end

      def subject(subject)
        stable(subject)
      end

      def represented_party(represented_party)
        stable(represented_party)
      end

      def record(record)
        stable(record)
      end

      private

      def stable(record)
        return "" if record.nil?
        return record.to_s if record.is_a?(String) || record.is_a?(Symbol)
        return record.to_gid.to_s if record.respond_to?(:to_gid)

        "#{record.class.name}/#{record.id}"
      end
    end
  end
end

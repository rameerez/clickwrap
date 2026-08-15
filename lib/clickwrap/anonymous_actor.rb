# frozen_string_literal: true

module Clickwrap
  # An actor who is not a persisted record: someone completing a checkout, an
  # applicant, a visitor acting before any account exists.
  #
  # The identifier is host-owned and opaque, and the host owns any later account
  # linking and every identity or capacity question that goes with it.
  #
  # An IP address is explicitly not acceptable here. It is not stable, it is not
  # unique to a person, it is shared by households and offices and whole
  # networks, and using one as an actor identifier would put a claim in the
  # evidence that the evidence cannot support. The constructor refuses one
  # rather than letting it become a hard-to-notice mistake.
  class AnonymousActor
    IP_ADDRESS_PATTERN = /\A(\d{1,3}\.){3}\d{1,3}\z|\A[0-9a-f:]+:[0-9a-f:]*\z/i

    attr_reader :identifier

    def initialize(identifier)
      @identifier = identifier.to_s

      if @identifier.strip.empty?
        raise ArgumentError,
              "An anonymous actor needs a stable identifier your application owns, for example " \
              "\"checkout_#{signed_checkout_id}\"."
      end

      if IP_ADDRESS_PATTERN.match?(@identifier)
        raise ArgumentError,
              "#{@identifier.inspect} looks like an IP address. An IP address is not an actor: " \
              "it is shared, reassigned, and proxied, so evidence attributed to one would claim " \
              "more than it can support. Use a stable identifier your application controls."
      end

      freeze
    end

    def clickwrap_actor_reference = "anonymous/#{identifier}"
    def id = identifier
    def to_s = clickwrap_actor_reference
    def persisted? = false
    def ==(other) = other.is_a?(self.class) && other.identifier == identifier
    alias eql? ==
    def hash = [self.class, identifier].hash
  end

  # A named non-human actor, for seeds, imports, migrations, and background
  # processes. Recording one is how a system-created record says out loud that
  # no person did this, instead of leaving a gap that later reads like a human
  # action nobody can find.
  class SystemActor
    attr_reader :name

    def initialize(name)
      @name = name.to_s

      if @name.strip.empty?
        raise ArgumentError,
              "A system actor needs a name describing what created the record, for example " \
              "\"database_seed\" or \"crm_import_2026_08\"."
      end

      freeze
    end

    def clickwrap_actor_reference = "system/#{name}"
    def id = name
    def to_s = clickwrap_actor_reference
    def persisted? = false
    def ==(other) = other.is_a?(self.class) && other.name == name
    alias eql? ==
    def hash = [self.class, name].hash
  end
end

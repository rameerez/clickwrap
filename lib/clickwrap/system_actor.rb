# frozen_string_literal: true

module Clickwrap
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

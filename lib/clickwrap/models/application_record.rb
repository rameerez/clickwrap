# frozen_string_literal: true

module Clickwrap
  # The abstract base class every model the gem ships inherits from. It plays
  # the exact role an engine's `app/models/<engine>/application_record.rb`
  # normally plays.
  #
  # It inherits from the HOST's `::ActiveRecord::Base`, NOT from the host's
  # `::ApplicationRecord`. That matters here more than in most engines: evidence
  # tables must behave identically in every host, and a default scope, a
  # multitenancy filter, or a `before_save` bolted onto the app's base class
  # could quietly change what gets recorded — or hide rows from an export that
  # is supposed to be complete.
  #
  # The reference to `::ActiveRecord::Base` is fully qualified so Ruby's
  # constant lookup can never re-bind it to a `Clickwrap::ActiveRecord`.
  class ApplicationRecord < ::ActiveRecord::Base
    self.abstract_class = true
  end
end

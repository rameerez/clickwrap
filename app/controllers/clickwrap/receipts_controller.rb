# frozen_string_literal: true

module Clickwrap
  # "Show me exactly what the application recorded."
  #
  # Every screen here answers that question about one recorded event, and every
  # screen here goes through the host's authorization callback to do it. There
  # is no built-in "actors can always read their own" shortcut: the host decides
  # who may read what, and the conventional initializer says so out loud.
  #
  #   config.authorize_receipt_access_with = lambda do |controller, receipt|
  #     controller.current_user == receipt.actor || controller.current_user.admin?
  #   end
  #
  # Until that is configured the default answers false, so an unconfigured host
  # shows an empty list rather than leaking a receipt it never decided to share.
  # A receipt the viewer may not see is NOT FOUND, never forbidden: a 403 tells
  # an outsider that the id they guessed exists, and existence is itself
  # information about someone.
  class ReceiptsController < ApplicationController
    # An honest page size rather than an unbounded query. A production actor can
    # accumulate years of retained history even when optional annex data is
    # disposed on a separate schedule.
    PER_PAGE = 50

    def index
      @events = own_events.limit(PER_PAGE).select { |event| authorized_to_read?(event) }
    end

    def show
      @event = find_readable_event
      return head :not_found if @event.nil?

      @receipt = @event.receipt

      respond_to do |format|
        format.html
        format.json { render json: @receipt.to_canonical_json }
      end
    end

    private

    # The viewer's own events, newest first. Scoping by the actor reference the
    # evidence itself carries — rather than by a foreign key that a deleted
    # account would take with it — is what keeps this list working after a row
    # has gone.
    def own_events
      Event.for_actor(actor_reference)
           .order(recorded_at_by_server: :desc, id: :desc)
    end

    def actor_reference
      Reference.actor(clickwrap_current_actor)
    end

    def find_readable_event
      event = Event.find_by(id: params[:id])
      return nil if event.nil?
      return nil unless authorized_to_read?(event)

      event
    end

    # The host's answer, treated as a plain yes/no. The default is no, so a host
    # that has not made this decision yet cannot accidentally publish anything.
    def authorized_to_read?(event)
      !!Clickwrap.config.authorize_receipt_access_with.call(self, event.receipt)
    end
  end
end

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
  #     controller.current_user.present? &&
  #       (controller.current_user == receipt.actor || controller.current_user.admin?)
  #   end
  #
  # Until that is configured the default answers false, so an unconfigured host
  # shows an empty list rather than leaking a receipt it never decided to share.
  # A receipt the viewer may not see is NOT FOUND, never forbidden: a 403 tells
  # an outsider that the id they guessed exists, and existence is itself
  # information about someone.
  class ReceiptsController < ApplicationController
    before_action :require_clickwrap_actor

    # An honest page size rather than an unbounded query. A production actor can
    # accumulate years of retained history even when optional annex data is
    # disposed on a separate schedule.
    PER_PAGE = 50

    # How many of the viewer's own rows this screen will read looking for
    # PER_PAGE it may show. The host's callback is Ruby, not SQL, so the
    # database cannot apply it and something has to bound the search. A viewer
    # whose first thousand events are all unreadable to them is a host
    # authorization question, not a paging question.
    AUTHORIZATION_SCAN_LIMIT = 1_000

    BATCH_SIZE = 100

    def index
      @events = authorized_page
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

    # Authorize, THEN paginate. Taking PER_PAGE rows and filtering afterwards
    # renders an empty page whenever the viewer's newest fifty events happen to
    # be ones the host will not show them — while readable receipts sit at row
    # fifty-one. "Your receipts are gone" is a bad thing for this screen to say
    # by accident.
    #
    # The actor is eager-loaded because the conventional callback compares
    # `controller.current_user == receipt.actor`, which is one query per row
    # otherwise. Reading in batches keeps that at a handful of queries for the
    # whole page instead of one per receipt.
    def authorized_page
      authorized = []
      scanned = 0

      while authorized.length < page_size && scanned < authorization_scan_limit
        batch = own_events.includes(:actor).offset(scanned).limit(batch_size).to_a
        break if batch.empty?

        authorized.concat(batch.select { |event| authorized_to_read?(event) })
        scanned += batch.length
        break if batch.length < batch_size
      end

      authorized.first(page_size)
    end

    # Readers rather than bare constants so a host that ejects this controller
    # can page it differently by overriding one method.
    def page_size = PER_PAGE
    def batch_size = BATCH_SIZE
    def authorization_scan_limit = AUTHORIZATION_SCAN_LIMIT

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

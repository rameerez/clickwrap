# frozen_string_literal: true

# Built-in resolver value objects and adapters are part of Clickwrap's public
# initializer API, so they must be available before Rails finishes setting up
# Zeitwerk. In particular, a host should be able to write the documented line
#
#   config.ip_geolocation_resolver = Clickwrap::IpGeolocation::TrackdownResolver.new
#
# without knowing a private file path or adding a load-order `require`. The
# Trackdown adapter itself still loads the optional `trackdown` gem lazily in
# its constructor; requiring Clickwrap never makes Trackdown a dependency.
require_relative "ip_geolocation/location"
require_relative "ip_geolocation/resolver"
require_relative "ip_geolocation/null_resolver"
require_relative "ip_geolocation/static_resolver"
require_relative "ip_geolocation/trackdown_resolver"

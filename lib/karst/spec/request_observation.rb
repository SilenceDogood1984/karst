# frozen_string_literal: true

require_relative "../value"

module Karst
  module Spec
    # One HTTP request observed during a single RSpec example.
    #
    # `principal_before`/`principal_after` are the active Warden principal
    # immediately before and immediately after this request was processed;
    # `principal_changed` is true when they differ -- a login, a logout, or a
    # switch from one principal to another. This is raw observed evidence,
    # not an interpretation of what the request was FOR. Karst does not
    # classify a request as "setup" or "the subject under test": a signup
    # route, an invitation-acceptance route, or a checkout-completion route
    # that happens to establish a session is a legitimate subject request,
    # not authentication plumbing, and a single request carries no reliable
    # signal for telling those apart. That classification, if Karst ever
    # offers one, belongs to catalog-building logic downstream of this
    # observer, informed by more context than one request can supply.
    #
    # Named `http_method`, not `method`, so it never shadows Object#method.
    RequestObservation = Value.define(
      :sequence,
      :http_method,
      :path,
      :route_pattern,
      :controller,
      :action,
      :format,
      :status,
      :redirect_location,
      :principal_before,
      :principal_after,
      :principal_changed
    )
  end
end

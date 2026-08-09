# frozen_string_literal: true

module Karst
  module Spec
    # One HTTP request observed during a single RSpec example.
    #
    # `role` is :authentication when the active Warden principal changed
    # (established or cleared) while this exact request was processed, and
    # :subject otherwise. This is an observed runtime fact -- the principal
    # actually changed -- not a guess based on the request's path, so a
    # sign-in issued through any route, helper, or literal path is identified
    # the same way, and a request that happens to authenticate as a side
    # effect of the behavior under test is labeled :authentication like any
    # other principal change would be.
    #
    # Named `http_method`, not `method`, so it never shadows Object#method.
    RequestObservation = Data.define(
      :sequence,
      :http_method,
      :path,
      :route_pattern,
      :controller,
      :action,
      :format,
      :status,
      :redirect_location,
      :role,
      :principal
    )
  end
end

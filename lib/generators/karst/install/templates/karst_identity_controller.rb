# frozen_string_literal: true

# Development-only endpoints used by the custom probe hooks in karst.rb.
class KarstIdentityController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def create
    principal = Karst::Identity.resolve(model_name: params[:principal_type], id: params[:principal_id])
    return head(:forbidden) unless principal

    # TODO: establish this app's authentication for principal, then return a response.
    raise NotImplementedError, "Implement this application's custom Karst sign-in"
  end

  def destroy
    # TODO: clear the authentication established by create, then return a response.
    raise NotImplementedError, "Implement this application's custom Karst sign-out"
  end
end

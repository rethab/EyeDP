# frozen_string_literal: true

Doorkeeper.configure do # rubocop:disable Metrics/BlockLength
  # Change the ORM that doorkeeper will use (needs plugins)
  orm :active_record

  base_controller 'ApplicationController'

  # This block will be called to check whether the resource owner is authenticated or not.
  resource_owner_authenticator do
    app = Application.find_by(uid: request.query_parameters['client_id'])

    if user_signed_in?
      if app&.groups&.any?
        if (current_user.groups & app.groups).empty?
          redirect_to main_app.root_url, notice: 'You are not authorized to access this application.'
        else
          current_user
        end
      else
        current_user
      end
    else
      store_user_location! if storable_location?
      redirect_to(new_user_session_url)
      nil
    end
  end

  skip_authorization do |_resource_owner, client|
    client.application.internal?
  end

  # Define access token scopes for your provider
  # For more information go to
  # https://github.com/doorkeeper-gem/doorkeeper/wiki/Using-Scopes
  #
  default_scopes :openid
  optional_scopes :profile, :email, :address, :phone

  grant_flows %w[authorization_code implicit_oidc]
end

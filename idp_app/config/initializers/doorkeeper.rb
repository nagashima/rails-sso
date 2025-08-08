# frozen_string_literal: true

Doorkeeper.configure do
  # Change the ORM that doorkeeper will use (requires ORM extensions installed)
  # Check the list of supported ORMs here: https://github.com/doorkeeper-gem/doorkeeper#orms
  orm :active_record

  # This block will be called to check whether the resource owner is authenticated or not.
  resource_owner_authenticator do
    # 既存のJWT認証システムを使用
    token = cookies.signed[:auth_token]
    
    if token
      begin
        payload = JWT.decode(token, Rails.application.secret_key_base).first
        User.find(payload['user_id'])
      rescue JWT::DecodeError, ActiveRecord::RecordNotFound
        # OAuth2フローの情報を保存してログインページにリダイレクト
        session[:oauth2_return_to] = request.fullpath
        redirect_to(login_path)
      end
    else
      # OAuth2フローの情報を保存してログインページにリダイレクト
      session[:oauth2_return_to] = request.fullpath
      redirect_to(login_path)
    end
  end

  # Define access token scopes for your provider
  # For more information go to
  # https://doorkeeper.gitbook.io/guides/ruby-on-rails/scopes
  #
  # SSO用スコープの設定（OpenID Connect準拠）
  default_scopes  :openid
  optional_scopes :profile, :email

  # Issue access tokens with refresh token (disabled by default), you may also
  # pass a block which accepts `context` to customize when to give a refresh
  # token or not. Similar to +custom_access_token_expires_in+, `context` has
  # the following properties:
  #
  # `client` - the OAuth client application (see Doorkeeper::OAuth::Client)
  # `grant_type` - the grant type of the request (see Doorkeeper::OAuth)
  # `scopes` - the requested scopes (see Doorkeeper::OAuth::Scopes)
  #
  # SSO用にリフレッシュトークンを有効化
  use_refresh_token
end
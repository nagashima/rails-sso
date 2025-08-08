Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, {
    name: :sso,
    scope: [:openid, :profile, :email],
    response_type: :code,
    issuer: ENV['HYDRA_PUBLIC_URL'],
    discovery: false,
    send_nonce: false,
    client_options: {
      identifier: ENV['OAUTH_CLIENT_ID'],
      secret: ENV['OAUTH_CLIENT_SECRET'],
      redirect_uri: ENV['OAUTH_REDIRECT_URI'],
      authorization_endpoint: "#{ENV['HYDRA_PUBLIC_URL']}/oauth2/auth",
      token_endpoint: "#{ENV['HYDRA_PUBLIC_URL_INTERNAL']}/oauth2/token",
      userinfo_endpoint: "#{ENV['HYDRA_PUBLIC_URL_INTERNAL']}/userinfo",
      jwks_uri: "#{ENV['HYDRA_PUBLIC_URL_INTERNAL']}/.well-known/jwks.json",
      end_session_endpoint: "#{ENV['HYDRA_PUBLIC_URL']}/oauth2/sessions/logout"
    }
  }
end

# OmniAuth 2.0のCSRF保護設定
OmniAuth.config.allowed_request_methods = [:post, :get]

# CSRF/State検証設定
OmniAuth.config.test_mode = false if Rails.env.development?

# SSL検証を無効化（開発環境用）
require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE
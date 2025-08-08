Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, {
    name: :sso,
    scope: [:openid, :profile, :email],
    response_type: :code,
    issuer: 'http://localhost:3000',  # ブラウザ向けURL（外部向け）
    discovery: false,
    send_nonce: false,
    # RSA公開鍵でJWT検証（JWKS使用）
    verify_id_token: true,
    client_options: {
      identifier: 'rp-client',  # setup-doorkeeper-client.shで設定したClient ID
      secret: 'rp-client-secret',  # setup-doorkeeper-client.shで設定したClient Secret
      redirect_uri: 'http://localhost:3001/auth/sso/callback',
      authorization_endpoint: "http://localhost:3000/oauth/authorize",  # ブラウザ向け
      token_endpoint: "http://idp:3000/oauth/token",  # コンテナ間通信
      userinfo_endpoint: "http://idp:3000/api/v1/user_info",  # コンテナ間通信
      jwks_uri: "http://idp:3000/.well-known/jwks.json",  # JWKS取得用
      end_session_endpoint: "http://idp:3000/oauth/revoke"  # コンテナ間通信
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
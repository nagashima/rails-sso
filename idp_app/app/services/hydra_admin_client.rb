class HydraAdminClient
  include HTTParty
  
  base_uri ENV.fetch('HYDRA_ADMIN_URL', 'http://localhost:4445')
  
  # ログインチャレンジの詳細を取得
  def self.get_login_request(login_challenge)
    response = get("/admin/oauth2/auth/requests/login", 
                   query: { login_challenge: login_challenge })
    handle_response(response)
  end
  
  # ログインチャレンジを受け入れ
  def self.accept_login_request(login_challenge, subject)
    response = put("/admin/oauth2/auth/requests/login/accept",
                   query: { login_challenge: login_challenge },
                   body: {
                     subject: subject,
                     remember: false,
                     remember_for: 0
                   }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    handle_response(response)
  end
  
  # ログインチャレンジを拒否
  def self.reject_login_request(login_challenge, error_description)
    response = put("/admin/oauth2/auth/requests/login/reject",
                   query: { login_challenge: login_challenge },
                   body: {
                     error: 'access_denied',
                     error_description: error_description
                   }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    handle_response(response)
  end
  
  # 同意チャレンジの詳細を取得
  def self.get_consent_request(consent_challenge)
    response = get("/admin/oauth2/auth/requests/consent",
                   query: { consent_challenge: consent_challenge })
    handle_response(response)
  end
  
  # 同意チャレンジを受け入れ
  def self.accept_consent_request(consent_challenge, grant_scope, identity_token_claims = {})
    response = put("/admin/oauth2/auth/requests/consent/accept",
                   query: { consent_challenge: consent_challenge },
                   body: {
                     grant_scope: grant_scope,
                     grant_access_token_audience: [],
                     session: {
                       id_token: identity_token_claims
                     }
                   }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    handle_response(response)
  end
  
  # 同意チャレンジを拒否
  def self.reject_consent_request(consent_challenge, error_description)
    response = put("/admin/oauth2/auth/requests/consent/reject",
                   query: { consent_challenge: consent_challenge },
                   body: {
                     error: 'access_denied',
                     error_description: error_description
                   }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    handle_response(response)
  end
  
  # ログアウトチャレンジの詳細を取得
  def self.get_logout_request(logout_challenge)
    response = get("/admin/oauth2/auth/requests/logout",
                   query: { logout_challenge: logout_challenge })
    handle_response(response)
  end
  
  # ログアウトチャレンジを受け入れ
  def self.accept_logout_request(logout_challenge)
    response = put("/admin/oauth2/auth/requests/logout/accept",
                   query: { logout_challenge: logout_challenge })
    handle_response(response)
  end
  
  private
  
  # レスポンス処理
  def self.handle_response(response)
    case response.code
    when 200..299
      response.parsed_response
    when 404
      raise HydraError, "Challenge not found: #{response.body}"
    when 400..499
      raise HydraError, "Client error: #{response.body}"
    when 500..599
      raise HydraError, "Server error: #{response.body}"
    else
      raise HydraError, "Unexpected error: #{response.code} - #{response.body}"
    end
  end
end

class HydraError < StandardError; end
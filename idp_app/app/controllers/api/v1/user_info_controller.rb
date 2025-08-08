class Api::V1::UserInfoController < ApplicationController
  # API用エンドポイントはCSRF除外（Bearer Token認証のため）
  skip_forgery_protection
  
  before_action :authenticate_with_access_token
  
  def show
    user_claims = build_user_claims(@current_user, @token_scopes)
    render json: user_claims
  end
  
  private
  
  def authenticate_with_access_token
    authorization_header = request.headers['Authorization']
    
    unless authorization_header&.start_with?('Bearer ')
      render json: { error: 'Missing or invalid authorization header' }, status: :unauthorized
      return
    end
    
    access_token = authorization_header.sub('Bearer ', '')
    
    begin
      # Hydraでアクセストークンを検証
      token_info = verify_access_token(access_token)
      
      # ユーザーIDを取得
      user_id = token_info['sub']
      @current_user = User.find(user_id)
      @token_scopes = token_info['scope']&.split(' ') || []
      
    rescue => e
      Rails.logger.error "Token verification failed: #{e.message}"
      render json: { error: 'Invalid access token' }, status: :unauthorized
    end
  end
  
  def verify_access_token(access_token)
    # Hydra Public APIのintrospectエンドポイントでトークンを検証
    response = HTTParty.post(
      "#{ENV.fetch('HYDRA_PUBLIC_URL', 'http://localhost:4444')}/oauth2/introspect",
      body: { token: access_token },
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
    )
    
    unless response.success?
      raise "Token introspection failed: #{response.code} - #{response.body}"
    end
    
    token_info = response.parsed_response
    
    unless token_info['active']
      raise "Token is not active"
    end
    
    token_info
  end
  
  def build_user_claims(user, scopes)
    claims = {}
    
    # 基本クレーム（sub は必須）
    claims[:sub] = user.id.to_s
    
    # profileスコープが含まれている場合
    if scopes.include?('profile')
      claims[:name] = user.name
      claims[:birthdate] = user.date_of_birth&.strftime('%Y-%m-%d') if user.date_of_birth
    end
    
    # emailスコープが含まれている場合
    if scopes.include?('email')
      claims[:email] = user.email
      claims[:email_verified] = true
    end
    
    # addressスコープが含まれている場合（カスタムスコープ）
    if scopes.include?('address') && user.address.present?
      claims[:address] = {
        formatted: user.address
      }
    end
    
    # phoneスコープが含まれている場合（カスタムスコープ）
    if scopes.include?('phone') && user.phone_number.present?
      claims[:phone_number] = user.phone_number
      claims[:phone_number_verified] = false  # 電話番号認証は未実装
    end
    
    claims
  end
end
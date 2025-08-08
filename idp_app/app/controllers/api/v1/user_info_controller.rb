# frozen_string_literal: true

class Api::V1::UserInfoController < ApplicationController
  # API用エンドポイントはCSRF除外（OAuth2 Bearer Token認証のため）
  skip_forgery_protection
  
  before_action :doorkeeper_authorize!

  # OpenID Connect UserInfo エンドポイント
  # https://openid.net/specs/openid-connect-core-1_0.html#UserInfo
  def show
    user = User.find(doorkeeper_token.resource_owner_id)
    
    # リクエストされたスコープに基づいてレスポンスを構築
    user_info = build_user_info(user, doorkeeper_token.scopes)
    
    render json: user_info
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'User not found' }, status: :not_found
  end

  private

  def build_user_info(user, scopes)
    info = { sub: user.id.to_s }
    
    # OpenID Connectの標準クレーム
    # https://openid.net/specs/openid-connect-core-1_0.html#StandardClaims
    
    if scopes.include?('email')
      info[:email] = user.email
      info[:email_verified] = true  # メール認証済みのため
    end
    
    if scopes.include?('profile')
      info[:name] = user.name
      info[:given_name] = user.name.split(' ').first if user.name
      info[:family_name] = user.name.split(' ').last if user.name
      info[:birthdate] = user.date_of_birth.strftime('%Y-%m-%d') if user.date_of_birth
      info[:address] = {
        formatted: user.address
      } if user.address.present?
      info[:phone_number] = user.phone_number if user.phone_number.present?
    end
    
    # 認証時刻も含める（OpenID Connectで推奨）
    info[:auth_time] = Time.current.to_i
    
    info
  end
end
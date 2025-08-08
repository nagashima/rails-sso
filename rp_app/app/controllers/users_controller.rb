class UsersController < ApplicationController
  before_action :authenticate_user!
  
  def show
    # IdPのAPIから詳細なユーザー情報を取得
    @user_info = fetch_user_info_from_idp
  end

  private

  def fetch_user_info_from_idp
    return current_user unless current_user['access_token']

    begin
      uri = URI("#{ENV['IDP_API_URL']}/user_info")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'

      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{current_user['access_token']}"
      request['Content-Type'] = 'application/json'

      response = http.request(request)
      
      case response.code
      when '200'
        JSON.parse(response.body)
      when '401'
        handle_access_token_expired
      else
        Rails.logger.error "Failed to fetch user info: #{response.code} #{response.body}"
        current_user
      end
    rescue => e
      Rails.logger.error "Error fetching user info: #{e.message}"
      current_user
    end
  end

  def handle_access_token_expired
    user_id = current_user&.dig('uid') || 'unknown'
    handle_token_expired(user_id)
    nil
  end
end
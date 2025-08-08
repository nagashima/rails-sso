class Oauth2::LogoutController < ApplicationController
  # GET /oauth2/logout?logout_challenge=... - Hydraからのログアウト要求
  def logout
    logout_challenge = params[:logout_challenge]
    
    if logout_challenge.blank?
      Rails.logger.error "OAuth2 logout called without logout_challenge"
      redirect_to root_path, alert: '不正なアクセスです'
      return
    end
    
    begin
      # Hydraからのログアウト要求詳細を取得
      logout_request = HydraAdminClient.get_logout_request(logout_challenge)
      Rails.logger.info "Processing logout request for subject: #{logout_request['subject']}"
      
      # IdPローカルセッションをクリア
      perform_local_logout
      
      # Hydraのログアウト要求を受け入れ
      response = HydraAdminClient.accept_logout_request(logout_challenge)
      
      # Hydraが指定したリダイレクト先に転送（通常はRPのトップページ）
      redirect_to response['redirect_to'], allow_other_host: true
      
    rescue HydraError => e
      Rails.logger.error "Failed to handle logout request: #{e.message}"
      # エラー時もローカルログアウトは実行
      perform_local_logout
      redirect_to root_path, notice: 'ログアウトしました'
    end
  end
  
  private
  
  def perform_local_logout
    # 認証ログ: OAuth2ログアウト
    AuthenticationLoggerService.log_logout(
      current_user, 
      request, 
      logout_type: 'oauth2_global'
    )
    
    cookies.signed[:auth_token] = nil
    session.clear
    Rails.logger.info "IdP local logout completed at #{Time.current}"
  end
end
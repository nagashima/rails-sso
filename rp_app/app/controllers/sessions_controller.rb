class SessionsController < ApplicationController
  skip_before_action :authenticate_user!

  def omniauth
    # OmniAuthがリダイレクトを処理
  end

  def omniauth_callback
    auth = request.env['omniauth.auth']
    
    Rails.logger.info "OAuth callback received"
    Rails.logger.info "Auth present: #{auth.present?}"
    Rails.logger.info "Auth data: #{auth.inspect}" if auth.present?
    
    if auth.present?
      # ユーザー情報をセッションに保存
      user_info = {
        uid: auth.uid,
        email: auth.info.email,
        name: auth.info.name,
        access_token: auth.credentials.token,
        id_token: auth.credentials.id_token
      }
      
      session[:user_info] = user_info
      session[:logged_in_at] = Time.current.to_s  # ログイン時刻を記録
      Rails.logger.info "User info saved to session: #{user_info.inspect}"
      Rails.logger.info "Session after save: #{session[:user_info].inspect}"
      
      redirect_to profile_path, notice: 'ログインしました'
    else
      Rails.logger.error "OAuth authentication failed - no auth data"
      redirect_to root_path, alert: 'ログインに失敗しました'
    end
  end

  def auth_failure
    error_type = params[:message] || 'unknown_error'
    error_details = request.env['omniauth.error'] || 'No details available'
    
    Rails.logger.error "OmniAuth authentication failed: #{error_type}"
    Rails.logger.error "Error details: #{error_details.inspect}"
    Rails.logger.error "Request params: #{params.inspect}"
    Rails.logger.error "Request env omniauth: #{request.env.select { |k, v| k.to_s.include?('omniauth') }}"
    
    redirect_to root_path, alert: "ログインに失敗しました: #{error_type}"
  end

  def destroy
    # RPのローカルログアウト（セッションのみクリア）
    session[:user_info] = nil
    redirect_to root_path, notice: 'ログアウトしました'
  end
end
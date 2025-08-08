class ApplicationController < ActionController::Base
  before_action :authenticate_user!

  private

  def authenticate_user!
    Rails.logger.info "authenticate_user! called"
    Rails.logger.info "current_user: #{current_user.inspect}"
    Rails.logger.info "session[:user_info]: #{session[:user_info].inspect}"
    
    unless current_user
      handle_session_expired('ログインが必要です。')
      return
    end
    
    # セッション期限の確認（オプション：より厳密な管理が必要な場合）
    check_session_validity if session[:user_info]
  end

  def current_user
    @current_user ||= session[:user_info] if session[:user_info]
  end

  def user_signed_in?
    current_user.present?
  end

  # セッション期限切れ時の共通処理
  def handle_session_expired(message = '認証が期限切れです。再度ログインしてください。')
    Rails.logger.info "Session expired at #{Time.current}"
    session[:user_info] = nil
    redirect_to root_path, alert: message
  end

  # Access Token期限切れ時の共通処理
  def handle_token_expired(user_id = nil)
    Rails.logger.warn "Access token expired for user #{user_id} at #{Time.current}"
    handle_session_expired('認証トークンが期限切れです。再度ログインしてください。')
  end

  # セッション有効性チェック（オプション）
  def check_session_validity
    # セッションに登録時刻が記録されている場合の期限チェック
    if session[:logged_in_at]
      login_time = Time.parse(session[:logged_in_at])
      if Time.current > login_time + 30.minutes
        Rails.logger.info "Session timeout detected for session created at #{login_time}"
        handle_session_expired('セッションがタイムアウトしました。再度ログインしてください。')
      end
    end
  end

  helper_method :current_user, :user_signed_in?
end

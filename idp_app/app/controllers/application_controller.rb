class ApplicationController < ActionController::Base
  # CSRF保護強化
  protect_from_forgery with: :exception, prepend: true
  
  # セキュリティヘッダー設定
  before_action :set_security_headers
  
  # ビューでも使えるようにヘルパーメソッドとして登録
  helper_method :current_user, :logged_in?
  
  # JWT認証ヘルパー
  def current_user
    return @current_user if defined?(@current_user)
    
    token = cookies.signed[:auth_token]
    return @current_user = nil unless token
    
    begin
      payload = JWT.decode(token, Rails.application.secret_key_base).first
      @current_user = User.find(payload['user_id'])
    rescue JWT::DecodeError, ActiveRecord::RecordNotFound
      @current_user = nil
    end
  end
  
  def logged_in?
    current_user.present?
  end
  
  def require_login
    redirect_to root_path, alert: 'ログインが必要です。' unless logged_in?
  end
  
  def verify_user_ownership
    unless current_user == @user
      redirect_to root_path, alert: '他のユーザーの情報にはアクセスできません。'
    end
  end
  
  # JWT Cookie設定
  def set_jwt_cookie(user)
    jwt_token = JWT.encode(
      { user_id: user.id, exp: 30.minutes.from_now.to_i }, 
      Rails.application.secret_key_base
    )
    
    cookies.signed[:auth_token] = {
      value: jwt_token,
      httponly: true,
      secure: Rails.env.production?
    }
  end
  
  private
  
  def set_security_headers
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
    response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
  end
end

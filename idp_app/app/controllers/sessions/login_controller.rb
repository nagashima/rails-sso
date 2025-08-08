class Sessions::LoginController < ApplicationController
  before_action :redirect_if_logged_in, except: [:destroy]
  before_action :require_login_session, only: [:verification_form, :verify]

  # GET /login - ログインフォーム表示
  def login
  end

  # POST /login - 第1段階認証（メール・パスワード）
  def authenticate
    user = User.find_by(email: params[:email])
    
    if user&.authenticate(params[:password]) && user.activated?
      # 認証ログ: パスワード認証成功
      AuthenticationLoggerService.log_password_authentication(user, request, success: true)
      
      # 認証コード生成・送信
      user.generate_auth_code!
      UserMailer.auth_code_email(user).deliver_now
      
      # セッションに一時保存
      session[:login_user_id] = user.id
      
      redirect_to authentication_success_redirect_path, notice: '認証コードをメールで送信しました。'
    else
      handle_authentication_error
    end
  end

  # GET /login/verify - 認証コード入力画面
  def verification_form 
    @user = User.find(session[:login_user_id])
    
    # 認証コード期限切れチェック
    if @user.auth_code_expires_at && Time.current > @user.auth_code_expires_at
      session.delete(:login_user_id)
      redirect_to login_path, alert: '認証コードの有効期限が切れました。最初からログインし直してください。'
      return
    end
  end

  # POST /login/verify - 第2段階認証（認証コード検証）
  def verify
    user = User.find(session[:login_user_id])
    
    if user.auth_code_valid?(params[:auth_code])
      # 認証ログ: 2段階認証成功
      AuthenticationLoggerService.log_two_factor_authentication(user, request, success: true)
      
      # 1. 共通セッション処理
      prepare_common_session(user)
      
      # 2. フロー固有セッション処理（サブクラスでオーバーライド可能）
      handle_flow_specific_session
      
      # 3. ログイン成功処理（サブクラスでオーバーライド可能）
      handle_login_success(user)
    else
      handle_login_error
    end
  end

  # DELETE /logout - 設定に応じたログアウト
  def destroy
    if current_user
      # IdPローカルセッションをクリア
      perform_local_logout
      
      # 設定に応じてグローバルログアウトを実行
      if global_logout_enabled?
        # Hydraのグローバルログアウトを実行
        hydra_logout_url = "#{ENV['HYDRA_PUBLIC_URL']}/oauth2/sessions/logout"
        Rails.logger.info "Initiating global logout via Hydra: #{hydra_logout_url}"
        redirect_to hydra_logout_url, allow_other_host: true
      else
        # ローカルログアウトのみ
        Rails.logger.info "Local logout only (LOGOUT_STRATEGY=#{logout_strategy})"
        redirect_to root_path, notice: 'ログアウトしました'
      end
    else
      redirect_to root_path, notice: '既にログアウトしています'
    end
  end
  
  private
  
  # ローカルログアウト処理
  def perform_local_logout
    # 認証ログ: ログアウト
    AuthenticationLoggerService.log_logout(current_user, request, logout_type: logout_strategy)
    
    cookies.signed[:auth_token] = nil
    session.clear
    Rails.logger.info "IdP local logout completed at #{Time.current}"
  end
  
  # グローバルログアウトが有効かチェック
  def global_logout_enabled?
    logout_strategy == 'global'
  end
  
  # ログアウト戦略を取得（デフォルト: local）
  def logout_strategy
    ENV.fetch('LOGOUT_STRATEGY', 'local')
  end

  private

  def redirect_if_logged_in
    if current_user
      redirect_to root_path, alert: '既にログインしています。'
    end
  end

  def require_login_session
    unless session[:login_user_id]
      redirect_to login_path, alert: '最初からログインし直してください。'
    end
  end
  
  # 共通セッション処理
  def prepare_common_session(user)
    user.clear_auth_code!
    set_jwt_cookie(user)
    session.delete(:login_user_id)
  end
  
  # フロー固有セッション処理（サブクラスでオーバーライド可能）
  # 呼び出し元: #verify (POST /login/verify, POST /oauth2/login/verify)
  def handle_flow_specific_session
    # 通常フローでは何もしない
  end
  
  # ログイン成功処理（サブクラスでオーバーライド可能）
  # 呼び出し元: #verify (POST /login/verify, POST /oauth2/login/verify)
  def handle_login_success(user)
    # 認証ログ: ログイン成功
    AuthenticationLoggerService.log_login_success(user, request, login_method: 'standard', redirect_to: root_path)
    
    redirect_to root_path, notice: 'ログインしました。'
  end
  
  # 認証成功時のリダイレクト先（サブクラスでオーバーライド可能）
  # 呼び出し元: #authenticate (POST /login, POST /oauth2/login)
  def authentication_success_redirect_path
    login_verify_path
  end
  
  # フォームURL設定（サブクラスでオーバーライド可能）
  # 呼び出し元: #handle_authentication_error (POST /login, POST /oauth2/login エラー時)
  def set_form_urls
    # 通常ログインでは特別な設定不要
  end
  
  # 第1段階認証エラー処理（サブクラスでオーバーライド可能）
  # 呼び出し元: #authenticate (POST /login, POST /oauth2/login エラー時)
  def handle_authentication_error
    # 認証ログ: パスワード認証失敗
    AuthenticationLoggerService.log_password_authentication(
      params[:email], 
      request, 
      success: false, 
      failure_reason: 'invalid_credentials'
    )
    
    set_form_urls
    flash.now[:alert] = 'メールアドレスまたはパスワードが正しくありません。'
    render :login, status: :unprocessable_entity
  end
  
  # 第2段階認証エラー処理
  def handle_login_error
    @user = User.find(session[:login_user_id])
    
    # 認証ログ: 2段階認証失敗
    AuthenticationLoggerService.log_two_factor_authentication(
      @user, 
      request, 
      success: false, 
      failure_reason: 'invalid_code'
    )
    
    flash.now[:alert] = '認証コードが正しくありません。'
    render :verification_form, status: :unprocessable_entity
  end
end
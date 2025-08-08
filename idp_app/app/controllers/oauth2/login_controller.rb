class Oauth2::LoginController < Sessions::LoginController
  # OAuth2フローでは既ログイン時のリダイレクトをスキップ
  skip_before_action :redirect_if_logged_in, only: [:login, :authenticate, :verification_form, :verify]
  
  # OAuth2フローのエントリーポイント
  def login
    return redirect_with_error('不正なアクセスです') if login_challenge.blank?
    
    begin
      login_request = HydraAdminClient.get_login_request(login_challenge)
      store_login_challenge
      
      # 認証ログ: OAuth2ログイン開始
      AuthenticationLoggerService.log_oauth2_login_start(
        request,
        client_id: login_request.dig('client', 'client_id'),
        login_challenge: login_challenge
      )
      
      if should_auto_accept_login?
        auto_accept_login
      else
        show_login_form
      end
      
    rescue HydraError => e
      handle_hydra_error(e, 'ログイン処理中にエラーが発生しました')
    end
  end
  
  # POST /oauth2/login - 第1段階認証（メール・パスワード）
  # 親クラス: Sessions::LoginController#authenticate をオーバーライド
  # OAuth2固有のテンプレートメソッドを活用して処理を委譲
  def authenticate
    super  # 親クラスのテンプレートメソッドを活用
  end
  
  # GET /oauth2/login/verify - 認証コード入力フォーム表示
  # 親クラス: Sessions::LoginController#verification_form をオーバーライド
  # OAuth2専用のフォームURL設定を追加
  def verification_form
    super
    set_oauth2_verify_form_url
  end
  
  protected
  
  # OAuth2固有のセッション処理をオーバーライド
  # 親クラス: Sessions::LoginController#handle_flow_specific_session
  # 呼び出し元: Sessions::LoginController#verify (POST /oauth2/login/verify)
  def handle_flow_specific_session
    @login_challenge = session.delete(:login_challenge)
  end
  
  # OAuth2のログイン成功処理をオーバーライド
  # 親クラス: Sessions::LoginController#handle_login_success
  # 呼び出し元: Sessions::LoginController#verify (POST /oauth2/login/verify)
  def handle_login_success(user)
    # 認証ログ: OAuth2ログイン成功
    AuthenticationLoggerService.log_login_success(
      user, 
      request, 
      login_method: 'oauth2', 
      redirect_to: 'hydra_redirect'
    )
    
    accept_hydra_login_request(user)
  end
  
  # OAuth2の認証成功時のリダイレクト先をオーバーライド
  # 親クラス: Sessions::LoginController#authentication_success_redirect_path
  # 呼び出し元: Sessions::LoginController#authenticate (POST /oauth2/login)
  def authentication_success_redirect_path
    oauth2_login_verify_path
  end
  
  # OAuth2のフォームURL設定をオーバーライド
  # 親クラス: Sessions::LoginController#set_form_urls
  # 呼び出し元: Sessions::LoginController#handle_authentication_error (POST /oauth2/login エラー時)
  def set_form_urls
    @login_form_url = oauth2_login_path
  end
  
  private
  
  def login_challenge
    @login_challenge ||= params[:login_challenge]
  end
  
  def store_login_challenge
    session[:login_challenge] = login_challenge
  end
  
  def should_auto_accept_login?
    current_user.present?
  end
  
  def auto_accept_login
    response = HydraAdminClient.accept_login_request(login_challenge, current_user.id.to_s)
    redirect_to response['redirect_to']
  end
  
  def show_login_form
    set_form_urls
    render 'sessions/login/login'
  end
  
  def accept_hydra_login_request(user)
    response = HydraAdminClient.accept_login_request(@login_challenge, user.id.to_s)
    redirect_to response['redirect_to']
  rescue HydraError => e
    handle_hydra_error(e, 'ログイン処理中にエラーが発生しました')
  end
  
  def set_oauth2_verify_form_url
    @verify_form_url = oauth2_login_verify_path
  end
  
  def redirect_with_error(message)
    Rails.logger.error "OAuth2 error: #{message}"
    redirect_to root_path, alert: message
  end
  
  def handle_hydra_error(error, user_message)
    Rails.logger.error "Hydra error: #{error.message}"
    redirect_to root_path, alert: user_message
  end
end
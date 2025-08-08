class AuthenticationLoggerService
  class << self
    # パスワード認証ログ
    def log_password_authentication(user_or_email, request, success: true, failure_reason: nil)
      user = user_or_email.is_a?(User) ? user_or_email : nil
      email = user_or_email.is_a?(String) ? user_or_email : user&.email

      details = { email: email }
      details[:failure_reason] = failure_reason if failure_reason

      create_log(
        user: user,
        event_type: AuthenticationLog::EVENT_TYPES[:password_authentication],
        request: request,
        success: success,
        details: details
      )
    end

    # 2段階認証ログ
    def log_two_factor_authentication(user, request, success: true, failure_reason: nil, code_attempts: 1)
      details = { 
        email: user.email,
        code_attempts: code_attempts
      }
      details[:failure_reason] = failure_reason if failure_reason

      create_log(
        user: user,
        event_type: AuthenticationLog::EVENT_TYPES[:two_factor_authentication],
        request: request,
        success: success,
        details: details
      )
    end

    # ログイン成功ログ
    def log_login_success(user, request, login_method: 'standard', redirect_to: nil)
      details = {
        email: user.email,
        login_method: login_method
      }
      details[:redirect_to] = redirect_to if redirect_to

      create_log(
        user: user,
        event_type: AuthenticationLog::EVENT_TYPES[:login_success],
        request: request,
        success: true,
        details: details
      )
    end

    # OAuth2ログイン開始ログ
    def log_oauth2_login_start(request, client_id: nil, login_challenge: nil)
      details = {}
      details[:client_id] = client_id if client_id
      details[:login_challenge] = login_challenge if login_challenge

      create_log(
        user: nil, # OAuth2開始時点ではユーザー未確定
        event_type: AuthenticationLog::EVENT_TYPES[:oauth2_login_start],
        request: request,
        success: true,
        details: details
      )
    end

    # OAuth2同意ログ
    def log_oauth2_consent(user, request, client_id: nil, scopes: [], consent_challenge: nil)
      details = {
        email: user.email,
        scopes: scopes
      }
      details[:client_id] = client_id if client_id
      details[:consent_challenge] = consent_challenge if consent_challenge

      create_log(
        user: user,
        event_type: AuthenticationLog::EVENT_TYPES[:oauth2_consent],
        request: request,
        success: true,
        details: details
      )
    end

    # ログアウトログ
    def log_logout(user, request, logout_type: 'local', session_duration: nil)
      details = {
        logout_type: logout_type
      }
      
      if user
        details[:email] = user.email
        details[:session_duration] = session_duration if session_duration
      else
        details[:note] = 'Already logged out'
      end

      create_log(
        user: user,
        event_type: AuthenticationLog::EVENT_TYPES[:logout],
        request: request,
        success: true,
        details: details
      )
    end

    private

    # 認証ログエントリの作成
    def create_log(user:, event_type:, request:, success:, details: {})
      AuthenticationLog.create!(
        user: user,
        event_type: event_type,
        ip_address: extract_ip_address(request),
        user_agent: request.user_agent,
        success: success,
        details: details,
        occurred_at: Time.current
      )
    rescue => e
      Rails.logger.error "Failed to create authentication log: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end

    # IPアドレスの取得（プロキシ対応）
    def extract_ip_address(request)
      # X-Forwarded-For ヘッダーから実際のクライアントIPを取得
      forwarded_for = request.headers['X-Forwarded-For']
      if forwarded_for.present?
        # カンマ区切りの場合は最初のIPを使用
        forwarded_for.split(',').first.strip
      else
        request.remote_ip
      end
    end
  end
end
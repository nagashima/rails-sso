module ApplicationHelper
  # OAuth2フローかどうかでログインフォームのaction先を動的に変更
  def current_login_path
    if session[:login_challenge].present?
      oauth2_login_path  # OAuth2用のPOST先
    else
      login_path         # 通常のWEBログイン用のPOST先
    end
  end
  
  def current_login_verify_path
    if session[:login_challenge].present?
      oauth2_login_verification_path  # OAuth2用の認証コード検証先
    else
      login_verification_path         # 通常のWEBログイン用の認証コード検証先
    end
  end
end
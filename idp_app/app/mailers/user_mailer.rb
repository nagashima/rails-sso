class UserMailer < ApplicationMailer
  default from: 'noreply@sso-idp.local'

  def activation_email(user)
    @user = user
    @activation_url = users_activate_url(token: user.activation_token)
    
    mail(
      to: @user.email,
      subject: '【SSO IdP】メール認証のお願い'
    )
  end

  def auth_code_email(user)
    @user = user
    @auth_code = user.auth_code
    
    mail(
      to: @user.email,
      subject: '【SSO IdP】ログイン認証コード'
    )
  end
end

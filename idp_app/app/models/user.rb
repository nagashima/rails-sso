class User < ApplicationRecord
  has_secure_password

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :password, length: { minimum: 8 }, if: -> { new_record? || !password.nil? }

  def generate_auth_code!
    self.auth_code = SecureRandom.random_number(100000..999999).to_s
    self.auth_code_expires_at = 10.minutes.from_now
    save!
  end

  def auth_code_valid?(code)
    return false if auth_code.blank? || auth_code_expires_at.blank?
    return false if Time.current > auth_code_expires_at
    
    auth_code == code
  end

  def clear_auth_code!
    self.auth_code = nil
    self.auth_code_expires_at = nil
    save!
  end

  # メール認証関連
  def activated?
    email_verified_at.present?
  end

  def generate_activation_token!
    self.activation_token = SecureRandom.urlsafe_base64(32)
    self.activation_expires_at = 24.hours.from_now
    save!
  end

  def activation_token_valid?(token)
    return false if activation_token.blank? || activation_expires_at.blank?
    return false if Time.current > activation_expires_at
    
    activation_token == token
  end

  def activate!
    self.email_verified_at = Time.current
    self.activation_token = nil
    self.activation_expires_at = nil
    save!
  end
end

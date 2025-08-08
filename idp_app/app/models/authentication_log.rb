class AuthenticationLog < ApplicationRecord
  belongs_to :user, optional: true

  # イベントタイプの定数定義
  EVENT_TYPES = {
    password_authentication: 'password_authentication',
    two_factor_authentication: 'two_factor_authentication', 
    login_success: 'login_success',
    oauth2_login_start: 'oauth2_login_start',
    oauth2_consent: 'oauth2_consent',
    logout: 'logout'
  }.freeze

  # バリデーション
  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES.values }
  validates :ip_address, presence: true
  validates :occurred_at, presence: true
  validates :success, inclusion: { in: [true, false] }

  # スコープ
  scope :successful, -> { where(success: true) }
  scope :failed, -> { where(success: false) }
  scope :by_event_type, ->(type) { where(event_type: type) }
  scope :recent, -> { order(occurred_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }

  # detailsカラムの自動JSON変換
  serialize :details, JSON

  # ユーザー情報の取得（ゲストユーザー対応）
  def user_identifier
    user&.email || "guest:#{ip_address}"
  end

  # イベントタイプの日本語名
  def event_type_name
    case event_type
    when 'password_authentication'
      'パスワード認証'
    when 'two_factor_authentication'
      '2段階認証'
    when 'login_success'
      'ログイン成功'  
    when 'oauth2_login_start'
      'OAuth2ログイン開始'
    when 'oauth2_consent'
      'OAuth2同意'
    when 'logout'
      'ログアウト'
    else
      event_type
    end
  end

  # 成功/失敗の日本語表示
  def success_status
    success? ? '成功' : '失敗'
  end
end
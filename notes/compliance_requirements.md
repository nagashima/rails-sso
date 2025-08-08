# SSOシステムにおけるコンプライアンス要件

SSO（Single Sign-On）システムを企業・金融・国際サービスで運用する際に必要となる主要なコンプライアンス要件について解説する。

---

## GDPR（EU一般データ保護規則）

### 概要

**正式名称**: General Data Protection Regulation  
**施行日**: 2018年5月25日  
**対象**: EU市民の個人データを処理するすべての組織  
**目的**: EU市民の個人データ保護を強化

### SSOシステムでの適用範囲

```
個人データの例:
├── 識別子: メールアドレス、ユーザーID
├── 基本情報: 氏名、生年月日、住所
├── 連絡先: 電話番号
└── 行動データ: ログイン履歴、アクセスパターン
```

IdPがこれらのデータを管理・RPに共有することで、GDPR適用対象となる。

### 具体的な実装要件

#### 1. **明示的同意（Explicit Consent）**

```ruby
# app/controllers/oauth2/consent_controller.rb
def consent
  @consent_request = HydraAdminClient.get_consent_request(consent_challenge)
  
  # GDPR準拠の情報表示
  @requested_scopes = consent_request['requested_scope']
  @client_name = consent_request['client']['client_name']
  @privacy_policy_url = consent_request['client']['policy_uri']
  @data_usage_purpose = get_data_usage_purpose(@requested_scopes)
  
  # 同意画面で以下を表示:
  # - どのデータが共有されるか
  # - 何の目的で使用されるか  
  # - 同意を撤回する方法
  # - データ保存期間
end

def accept
  # 同意記録の保存（証跡として必要）
  ConsentRecord.create!(
    user_id: current_user.id,
    client_id: consent_request['client']['client_id'],
    granted_scopes: params[:granted_scopes],
    consent_given_at: Time.current,
    ip_address: request.remote_ip,
    user_agent: request.user_agent
  )
  
  HydraAdminClient.accept_consent_request(consent_challenge, {
    grant_scope: params[:granted_scopes],
    session: build_user_claims(current_user, params[:granted_scopes])
  })
end
```

#### 2. **データ保護原則の実装**

```ruby
# データ最小化の例
def build_user_claims(user, granted_scopes)
  claims = { sub: user.id.to_s }
  
  # スコープに基づく最小限のデータのみ提供
  if granted_scopes.include?('email')
    claims[:email] = user.email
    claims[:email_verified] = user.email_verified?
  end
  
  if granted_scopes.include?('profile')
    claims[:name] = user.name
    # 生年月日は必要な場合のみ
    claims[:birthdate] = user.date_of_birth if user.date_of_birth.present?
  end
  
  claims
end

# データ保存期間制限
class AccessToken
  # アクセストークン短期間（GDPR推奨）
  EXPIRY_TIME = 1.hour
  
  scope :expired, -> { where('expires_at < ?', Time.current) }
  
  # 期限切れトークンの自動削除
  def self.cleanup_expired
    expired.delete_all
  end
end
```

#### 3. **データ主体の権利実装**

```ruby
# app/controllers/users/gdpr_controller.rb
class Users::GdprController < ApplicationController
  before_action :authenticate_user!
  
  # データポータビリティ権（Article 20）
  def export_data
    user_data = {
      personal_info: current_user.slice(:name, :email, :date_of_birth),
      login_history: current_user.login_logs.last(100),
      consent_records: current_user.consent_records,
      created_at: current_user.created_at,
      updated_at: current_user.updated_at
    }
    
    send_data user_data.to_json, 
              filename: "user_data_#{Date.current}.json",
              type: 'application/json'
  end
  
  # 忘れられる権利（Article 17）
  def delete_account
    # すべての関連データを削除
    current_user.transaction do
      # IdP内のデータ削除
      current_user.consent_records.destroy_all
      current_user.login_logs.destroy_all
      
      # Hydraセッション削除
      HydraAdminClient.revoke_all_user_sessions(current_user.id)
      
      # ユーザーアカウント削除
      current_user.destroy!
      
      # 監査ログに記録
      GdprAuditLog.create!(
        event: 'DATA_DELETION_REQUEST',
        user_id: current_user.id,
        executed_at: Time.current,
        ip_address: request.remote_ip
      )
    end
    
    redirect_to root_path, notice: 'アカウントとすべてのデータを削除しました。'
  end
end
```

---

## SOC2（Service Organization Control 2）

### 概要

**正式名称**: Service Organization Control 2  
**発行機関**: AICPA（米国公認会計士協会）  
**目的**: サービス組織のセキュリティ統制を第三者が監査  
**対象**: 顧客データを処理するサービスプロバイダー

### 5つの信頼原則

| 原則 | 内容 | SSOでの適用例 |
|------|------|--------------|
| **セキュリティ** | アクセス制御、認証 | 多要素認証、権限管理 |
| **可用性** | システムの稼働率 | 冗長化、監視 |
| **処理の完全性** | データの正確性 | 入力検証、整合性チェック |
| **機密性** | データの秘匿 | 暗号化、アクセス制御 |
| **プライバシー** | 個人情報保護 | データ分類、保護策 |

### 実装要件

#### 1. **包括的な監査ログ**

```ruby
# app/models/sso_audit_log.rb
class SSOAuditLog < ApplicationRecord
  # SOC2 Type IIで要求される監査証跡
  
  SECURITY_EVENTS = %w[
    LOGIN_ATTEMPT LOGIN_SUCCESS LOGIN_FAILURE
    PASSWORD_CHANGE MFA_ENABLED MFA_DISABLED
    ADMIN_ACCESS PRIVILEGE_ESCALATION
    DATA_ACCESS DATA_EXPORT
    CONSENT_GRANTED CONSENT_REVOKED
    SESSION_CREATED SESSION_DESTROYED
  ].freeze
  
  validates :event_type, inclusion: { in: SECURITY_EVENTS }
  validates :user_id, :timestamp, :ip_address, presence: true
  
  scope :security_events, -> { where(event_type: SECURITY_EVENTS) }
  scope :failed_attempts, -> { where(outcome: 'FAILURE') }
  scope :by_date_range, ->(start_date, end_date) { 
    where(timestamp: start_date..end_date) 
  }
end

# app/services/sso_audit_logger.rb
class SSOAuditLogger
  def self.log_authentication(event_type, details = {})
    SSOAuditLog.create!(
      event_type: event_type,
      user_id: details[:user_id],
      client_id: details[:client_id],
      ip_address: details[:ip_address],
      user_agent: details[:user_agent],
      timestamp: Time.current,
      outcome: details[:success] ? 'SUCCESS' : 'FAILURE',
      failure_reason: details[:failure_reason],
      session_id: details[:session_id],
      additional_data: details[:additional_data]&.to_json
    )
  end
  
  def self.log_admin_action(admin_user, action, target_resource = nil)
    log_authentication('ADMIN_ACCESS', {
      user_id: admin_user.id,
      ip_address: admin_user.current_sign_in_ip,
      success: true,
      additional_data: {
        action: action,
        target_resource: target_resource,
        timestamp: Time.current
      }
    })
  end
end
```

#### 2. **アクセス制御の実装**

```ruby
# app/controllers/admin/base_controller.rb
class Admin::BaseController < ApplicationController
  before_action :require_admin_access
  before_action :log_admin_access
  after_action :log_admin_action_completion
  
  private
  
  def require_admin_access
    unless current_user&.admin?
      SSOAuditLogger.log_authentication('UNAUTHORIZED_ADMIN_ACCESS', {
        user_id: current_user&.id,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        success: false,
        failure_reason: 'Insufficient privileges'
      })
      
      raise UnauthorizedError, "管理者権限が必要です"
    end
  end
  
  def log_admin_access
    SSOAuditLogger.log_admin_action(
      current_user,
      "#{controller_name}##{action_name}",
      params[:id] # 対象リソースのID
    )
  end
  
  def log_admin_action_completion
    # アクションの完了ログ
    Rails.logger.info({
      event: 'ADMIN_ACTION_COMPLETED',
      admin_id: current_user.id,
      action: "#{controller_name}##{action_name}",
      duration: request_duration,
      response_status: response.status
    }.to_json)
  end
end

# app/models/user.rb
class User < ApplicationRecord
  # 役割ベースアクセス制御（RBAC）
  enum role: {
    user: 0,
    admin: 1,
    super_admin: 2,
    auditor: 3  # 読み取り専用アクセス
  }
  
  # 最小権限の原則
  def can_access_admin_panel?
    admin? || super_admin?
  end
  
  def can_modify_users?
    super_admin?
  end
  
  def can_view_audit_logs?
    admin? || super_admin? || auditor?
  end
end
```

#### 3. **システム監視とアラート**

```ruby
# app/services/security_monitor.rb
class SecurityMonitor
  # 異常検知とアラート
  def self.check_suspicious_activity
    # 短時間での大量ログイン失敗
    suspicious_ips = SSOAuditLog.failed_attempts
                               .where(timestamp: 15.minutes.ago..Time.current)
                               .group(:ip_address)
                               .having('COUNT(*) > ?', 10)
                               .count
    
    suspicious_ips.each do |ip, count|
      alert_security_team("大量ログイン失敗検知: IP #{ip}, #{count}回")
      # IPブロックリストに追加
      BlockedIp.create!(ip_address: ip, reason: 'Brute force attempt')
    end
    
    # 管理者権限での異常なアクセス
    unusual_admin_access = SSOAuditLog.where(
      event_type: 'ADMIN_ACCESS',
      timestamp: 1.hour.ago..Time.current
    ).where('DATE(timestamp) != DATE(last_admin_login)')
    
    unusual_admin_access.each do |log|
      alert_security_team("通常時間外の管理者アクセス: User #{log.user_id}")
    end
  end
  
  private
  
  def self.alert_security_team(message)
    SecurityAlertMailer.urgent_alert(message).deliver_now
    # Slack/Teams等への通知
    SlackNotifier.notify("#security-alerts", message)
  end
end
```

---

## PCI DSS（Payment Card Industry Data Security Standard）

### 概要

**正式名称**: Payment Card Industry Data Security Standard  
**策定**: PCI Security Standards Council  
**対象**: クレジットカード情報を保存・処理・送信する組織  
**目的**: カード会員データの保護

### SSOシステムでの関連性

```
決済システム ← SSO認証 ← IdP
      ↓
  PCI DSS対象
      ↓
認証システムも影響を受ける
```

### 12の主要要件とSSO実装

#### 1. **ファイアウォールとネットワーク分離**

```yaml
# docker-compose.prod.yml（本番環境例）
version: '3.8'

services:
  # DMZ（非PCI環境）
  idp:
    networks:
      - dmz_network
    # カード情報にアクセスしない
    
  rp:
    networks:
      - dmz_network
    # 認証後にPCI環境にアクセス
    
  # PCI環境（カード情報処理）
  payment_system:
    networks:
      - pci_network
    # IdPからのSSO認証を受け入れ
    
networks:
  dmz_network:
    driver: bridge
  pci_network:
    driver: bridge
    internal: true  # 外部アクセス禁止
```

#### 2. **暗号化の実装**

```ruby
# config/application.rb
class Application < Rails::Application
  # TLS 1.2以上を強制（PCI DSS要件）
  config.force_ssl = true
  config.ssl_options = {
    hsts: {
      expires: 1.year,
      subdomains: true,
      preload: true
    }
  }
end

# app/models/user.rb
class User < ApplicationRecord
  # 保存時暗号化（PCI DSS Level 1要件）
  encrypts :phone_number, :address
  
  # パスワードハッシュ化（bcrypt）
  has_secure_password
  
  # 機密データのマスキング
  def masked_phone_number
    return nil unless phone_number
    phone_number.gsub(/.(?=.{4})/, '*')
  end
end

# config/database.yml
production:
  # データベース接続の暗号化
  adapter: mysql2
  encoding: utf8mb4
  host: <%= ENV['DB_HOST'] %>
  database: <%= ENV['DB_NAME'] %>
  username: <%= ENV['DB_USER'] %>
  password: <%= ENV['DB_PASSWORD'] %>
  sslmode: require
  sslcert: /path/to/client-cert.pem
  sslkey: /path/to/client-key.pem
  sslrootcert: /path/to/ca-cert.pem
```

#### 3. **アクセス制御と監査**

```ruby
# app/services/pci_audit_logger.rb
class PCIAuditLogger
  # PCI DSS 10.2 監査要件に準拠したログ
  def self.log_cardholder_data_access(user, action, card_token = nil)
    PCIAuditLog.create!(
      user_id: user.id,
      action: action,
      card_token: card_token,
      timestamp: Time.current,
      ip_address: user.current_sign_in_ip,
      session_id: user.current_session_id,
      system_component: 'SSO_IdP',
      
      # PCI DSS 10.3 必須要素
      user_identification: user.email,
      event_type: map_action_to_event_type(action),
      date_and_time: Time.current,
      success_failure: 'SUCCESS',
      origination: determine_access_origin(user),
      affected_resource: card_token ? "Card ending in #{card_token[-4..]}" : 'User profile'
    )
  end
  
  private
  
  def self.map_action_to_event_type(action)
    case action
    when 'payment_access' then 'CARDHOLDER_DATA_ACCESS'
    when 'profile_update' then 'ACCOUNT_MODIFICATION'
    when 'login' then 'AUTHENTICATION'
    else 'OTHER'
    end
  end
end

# app/controllers/payments_controller.rb
class PaymentsController < ApplicationController
  before_action :require_pci_compliant_authentication
  before_action :log_cardholder_data_access
  
  private
  
  def require_pci_compliant_authentication
    # 決済システムアクセス前の追加認証
    unless session[:pci_authenticated]
      redirect_to pci_authentication_path
    end
  end
  
  def log_cardholder_data_access
    PCIAuditLogger.log_cardholder_data_access(
      current_user,
      'payment_access',
      params[:card_token]
    )
  end
end
```

#### 4. **脆弱性管理**

```ruby
# Gemfile
# セキュリティパッチの定期適用
gem 'bundler-audit'  # 脆弱性チェック
gem 'brakeman'       # 静的解析

# config/schedule.rb（whenever gem）
every 1.day, at: '2:00 am' do
  runner "SecurityScanner.run_daily_scan"
end

# app/services/security_scanner.rb
class SecurityScanner
  def self.run_daily_scan
    # 1. 依存関係の脆弱性チェック
    bundler_audit_result = `bundle audit check --update`
    
    # 2. アプリケーションの静的解析
    brakeman_result = `brakeman -o /tmp/brakeman_report.json --format json`
    
    # 3. ログ解析による異常検知
    suspicious_activities = detect_suspicious_patterns
    
    # 4. レポート生成
    generate_security_report(bundler_audit_result, brakeman_result, suspicious_activities)
    
    # 5. 重大な問題があればアラート
    alert_if_critical_issues_found
  end
  
  private
  
  def self.detect_suspicious_patterns
    # SQLインジェクション試行の検知
    sql_injection_attempts = Rails.application.routes.recognize_path
    
    # XSS試行の検知
    xss_attempts = SSOAuditLog.where(
      'additional_data LIKE ? OR additional_data LIKE ?',
      '%<script%', '%javascript:%'
    ).where(timestamp: 24.hours.ago..Time.current)
    
    {
      sql_injection: sql_injection_attempts.count,
      xss_attempts: xss_attempts.count
    }
  end
end
```

---

## OIDC Certification（OpenID Connect認証）

### 概要

**正式名称**: OpenID Connect Certification  
**認証機関**: OpenID Foundation  
**目的**: OpenID Connectプロトコルの標準準拠を第三者が認証  
**意義**: 相互運用性の保証、セキュリティの向上

### 認証レベル

| レベル | 名称 | 要件 | 適用ケース |
|--------|------|------|----------|
| **Basic OP** | 基本プロバイダー | Authorization Code Flow | 一般的なSSO |
| **Implicit OP** | Implicit対応 | Implicit Flow | SPA対応 |
| **Hybrid OP** | Hybrid対応 | Hybrid Flow | 高度なセキュリティ |
| **Config OP** | 設定対応 | Dynamic Registration | マルチテナント |
| **Dynamic OP** | 完全動的 | 完全なDynamic対応 | エンタープライズ |

### 実装要件

#### 1. **Discovery Document**

```ruby
# app/controllers/oidc/discovery_controller.rb
class Oidc::DiscoveryController < ApplicationController
  def openid_configuration
    config = {
      # 必須フィールド
      issuer: ENV['HYDRA_PUBLIC_URL'],
      authorization_endpoint: "#{ENV['HYDRA_PUBLIC_URL']}/oauth2/auth",
      token_endpoint: "#{ENV['HYDRA_PUBLIC_URL']}/oauth2/token",
      userinfo_endpoint: "#{request.base_url}/api/v1/user_info",
      jwks_uri: "#{ENV['HYDRA_PUBLIC_URL']}/.well-known/jwks.json",
      
      # サポートする認証方式
      response_types_supported: [
        "code",
        "id_token",
        "code id_token",
        "code token",
        "id_token token",
        "code id_token token"
      ],
      
      subject_types_supported: ["public", "pairwise"],
      
      # IDトークン署名アルゴリズム
      id_token_signing_alg_values_supported: ["RS256", "ES256"],
      
      # サポートするスコープ
      scopes_supported: [
        "openid",
        "profile", 
        "email",
        "address",
        "phone"
      ],
      
      # サポートするクレーム
      claims_supported: [
        "sub",
        "name", 
        "given_name",
        "family_name",
        "email",
        "email_verified",
        "phone_number",
        "phone_number_verified",
        "address",
        "birthdate",
        "updated_at"
      ],
      
      # 認証方式
      token_endpoint_auth_methods_supported: [
        "client_secret_basic",
        "client_secret_post",
        "private_key_jwt"
      ],
      
      # PKCE対応
      code_challenge_methods_supported: ["S256"],
      
      # クレーム配信方式
      claim_types_supported: ["normal"],
      claims_parameter_supported: true,
      request_parameter_supported: true,
      request_uri_parameter_supported: false
    }
    
    render json: config
  end
end
```

#### 2. **UserInfo Endpoint**

```ruby
# app/controllers/api/v1/user_info_controller.rb
class Api::V1::UserInfoController < ApplicationController
  before_action :authenticate_with_access_token
  
  def show
    # アクセストークンからスコープを取得
    token_info = introspect_access_token(access_token)
    granted_scopes = token_info['scope']&.split(' ') || []
    
    # スコープに基づいてクレームを構築
    user_info = build_user_claims(current_user, granted_scopes)
    
    render json: user_info
  end
  
  private
  
  def build_user_claims(user, scopes)
    claims = {
      sub: user.id.to_s  # 必須クレーム
    }
    
    # profile スコープ
    if scopes.include?('profile')
      claims.merge!(
        name: user.name,
        given_name: user.given_name,
        family_name: user.family_name,
        birthdate: user.date_of_birth&.strftime('%Y-%m-%d'),
        updated_at: user.updated_at.to_i
      )
    end
    
    # email スコープ
    if scopes.include?('email')
      claims.merge!(
        email: user.email,
        email_verified: user.email_verified?
      )
    end
    
    # phone スコープ
    if scopes.include?('phone')
      claims.merge!(
        phone_number: user.phone_number,
        phone_number_verified: user.phone_number_verified?
      )
    end
    
    # address スコープ
    if scopes.include?('address')
      claims[:address] = {
        formatted: user.formatted_address,
        street_address: user.street_address,
        locality: user.city,
        region: user.state,
        postal_code: user.postal_code,
        country: user.country
      }
    end
    
    claims.compact
  end
  
  def authenticate_with_access_token
    auth_header = request.headers['Authorization']
    unless auth_header&.start_with?('Bearer ')
      render json: { error: 'invalid_request' }, status: 401
      return
    end
    
    @access_token = auth_header.sub('Bearer ', '')
    token_info = introspect_access_token(@access_token)
    
    unless token_info['active']
      render json: { error: 'invalid_token' }, status: 401
      return
    end
    
    @current_user = User.find(token_info['sub'])
  end
  
  def introspect_access_token(token)
    # Hydraのtoken introspectionエンドポイントを呼び出し
    HydraAdminClient.introspect_token(token)
  end
end
```

#### 3. **OIDC Compliance Tests**

```ruby
# spec/requests/oidc_compliance_spec.rb
RSpec.describe 'OIDC Compliance', type: :request do
  describe 'Discovery Document' do
    it 'returns valid OpenID Connect discovery document' do
      get '/.well-known/openid_configuration'
      
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq('application/json; charset=utf-8')
      
      config = JSON.parse(response.body)
      
      # 必須フィールドの検証
      expect(config['issuer']).to be_present
      expect(config['authorization_endpoint']).to be_present
      expect(config['token_endpoint']).to be_present
      expect(config['userinfo_endpoint']).to be_present
      expect(config['jwks_uri']).to be_present
      expect(config['response_types_supported']).to include('code')
      expect(config['subject_types_supported']).to include('public')
      expect(config['id_token_signing_alg_values_supported']).to include('RS256')
    end
  end
  
  describe 'UserInfo Endpoint' do
    let(:user) { create(:user) }
    let(:access_token) { create_valid_access_token(user, ['openid', 'profile', 'email']) }
    
    it 'returns user information for valid access token' do
      get '/api/v1/user_info', headers: {
        'Authorization' => "Bearer #{access_token}"
      }
      
      expect(response).to have_http_status(:ok)
      user_info = JSON.parse(response.body)
      
      # 必須クレーム
      expect(user_info['sub']).to eq(user.id.to_s)
      
      # profileスコープのクレーム
      expect(user_info['name']).to eq(user.name)
      expect(user_info['email']).to eq(user.email)
    end
    
    it 'respects scope limitations' do
      limited_token = create_valid_access_token(user, ['openid', 'email'])
      
      get '/api/v1/user_info', headers: {
        'Authorization' => "Bearer #{limited_token}"
      }
      
      user_info = JSON.parse(response.body)
      
      # emailスコープのクレームは含まれる
      expect(user_info['email']).to be_present
      
      # profileスコープのクレームは含まれない
      expect(user_info['name']).to be_nil
    end
    
    it 'rejects invalid access tokens' do
      get '/api/v1/user_info', headers: {
        'Authorization' => 'Bearer invalid_token'
      }
      
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)['error']).to eq('invalid_token')
    end
  end
  
  describe 'ID Token Validation' do
    it 'issues valid ID tokens' do
      # OAuth2フローを実行してIDトークンを取得
      id_token = perform_oauth2_flow_and_get_id_token
      
      # IDトークンの検証
      public_key = fetch_jwks_public_key
      decoded = JWT.decode(id_token, public_key, true, 
                          algorithm: 'RS256',
                          iss: ENV['HYDRA_PUBLIC_URL'],
                          verify_iss: true,
                          aud: oauth2_client_id,
                          verify_aud: true)
      
      payload = decoded[0]
      
      # 必須クレームの検証
      expect(payload['iss']).to eq(ENV['HYDRA_PUBLIC_URL'])
      expect(payload['sub']).to be_present
      expect(payload['aud']).to eq(oauth2_client_id)
      expect(payload['exp']).to be > Time.current.to_i
      expect(payload['iat']).to be <= Time.current.to_i
    end
  end
end
```

---

## まとめ

これらのコンプライアンス要件は、SSOシステムを異なる環境で運用する際の重要な指針となる：

### **適用シナリオ**

- **GDPR**: EU向けサービス → 明示的同意フロー、データ保護機能
- **SOC2**: 企業向けSaaS → 包括的監査ログ、アクセス制御
- **PCI DSS**: 決済関連システム → 暗号化、ネットワーク分離
- **OIDC認証**: 相互運用性重視 → 標準準拠実装、互換性テスト

### **実装戦略**

1. **段階的実装**: 基本機能 → コンプライアンス対応の順
2. **自動化**: テスト・監査・レポート生成の自動化
3. **文書化**: 実装内容と証跡の詳細記録
4. **継続改善**: 定期的な見直しとアップデート

適切な設計により、これらの要件を満たしながら使いやすいSSOシステムを構築できる。
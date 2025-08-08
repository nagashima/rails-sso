# Doorkeeper vs ORY Hydra 詳細比較ガイド

## 📋 基本比較（概要）

| 比較項目 | Doorkeeper | ORY Hydra |
| :--- | :--- | :--- |
| **役割** | Railsアプリケーションに組み込まれる**OAuth 2.0認可サーバーGem**。認証と認可の両方をアプリケーション内で処理 | 認証ロジックを持たない**純粋なOAuth 2.0認可サーバー**。認証は外部サービス（Railsアプリ等）に委ねる |
| **アーキテクチャ** | **密結合**。既存のRailsアプリケーションと一体化 | **疎結合**。独立したサービスとしてデプロイ・運用 |
| **実装の容易さ** | **容易**。Rails慣習に従い、既存`User`モデル活用可能 | **複雑**。HydraデプロイとRails⟷Hydra API連携実装が必要 |
| **学習コスト** | **低**。OAuth 2.0概念+Railsノウハウで対応 | **高**。OAuth2/OIDC深い知識+HydraアーキテクチャAPI理解必須 |

---

## 🏗️ 実装面の詳細比較

### コード複雑度

#### Doorkeeper実装例
```ruby
# Gemfile
gem 'doorkeeper'
gem 'doorkeeper-openid_connect'

# 設定生成（1コマンド）
rails generate doorkeeper:install
rails generate doorkeeper:openid_connect:install

# OAuth2クライアント登録（Rails Console）
Doorkeeper::Application.create!(
  name: "RP Application",
  uid: "rp-client", 
  secret: "rp-client-secret",
  redirect_uri: "http://localhost:3001/auth/sso/callback"
)

# 同意画面カスタマイズ（標準Rails View）
# app/views/doorkeeper/authorizations/new.html.erb
<%= form_with url: oauth_authorization_path do |f| %>
  <h2>アプリケーションが以下の権限を要求しています</h2>
  <%= f.submit "許可する", class: "btn btn-primary" %>
<% end %>
```

#### ORY Hydra実装例
```ruby
# IdP側：複雑なHydra Admin API連携
def oauth_login
  challenge = params[:login_challenge]
  
  # 1. Hydra Admin APIでログインリクエスト取得
  login_request = hydra_admin_client.get_login_request(challenge)
  
  # 2. 認証済みユーザーかチェック
  if user_signed_in? && login_request.subject == current_user.id.to_s
    # 3. ログインリクエストを受け入れ
    accept_request = {
      subject: current_user.id.to_s,
      context: { user_id: current_user.id }
    }
    accept_response = hydra_admin_client.accept_login_request(challenge, accept_request)
    redirect_to accept_response.redirect_to
  else
    # 4. ログイン画面表示（challengeを保持）
    session[:login_challenge] = challenge
    redirect_to new_user_session_path
  end
rescue Hydra::ApiError => e
  Rails.logger.error "Hydra login error: #{e.message}"
  render :error
end

# 複雑な同意画面処理
def oauth_consent
  challenge = params[:consent_challenge]
  consent_request = hydra_admin_client.get_consent_request(challenge)
  
  # 自動同意判定ロジック
  if auto_consent?(consent_request.client.client_id)
    accept_consent_request(challenge, consent_request.requested_scope)
  else
    @consent_request = consent_request
    render :consent
  end
end
```

### 設定ファイル量

```yaml
# Doorkeeper：最小設定
# config/initializers/doorkeeper.rb （約50行）
Doorkeeper.configure do
  resource_owner_authenticator do
    current_user || warden.authenticate!(scope: :user)
  end
  grant_flows %w[authorization_code client_credentials]
end

# ORY Hydra：複雑設定
# docker/hydra/hydra.yml （約100-150行）
serve:
  public:
    port: 4444
  admin:
    port: 4445

urls:
  self:
    issuer: http://localhost:4444
  login: http://localhost:3000/oauth2/login
  consent: http://localhost:3000/oauth2/consent

oauth2:
  expose_internal_errors: true
  pkce:
    enforced: false
    
# さらに環境変数、Docker設定、クライアント登録スクリプト等
```

---

## ⚙️ 運用面の詳細比較

### デプロイメント構成

| 要素 | Doorkeeper | ORY Hydra |
|------|------------|-----------|
| **コンテナ数** | 2個（IdP+RP） | 4個（Hydra+IdP+RP+MySQL） |
| **設定ファイル** | 1個（doorkeeper.rb） | 3個（hydra.yml+docker-compose.yml+env） |
| **起動順序** | 依存なし（標準Rails起動） | 複雑（Hydra→IdP依存関係） |
| **ヘルスチェック** | Rails標準 | Hydra+IdP両方の監視必要 |

### エラーハンドリング

#### Doorkeeper
```ruby
# 統合エラーハンドリング
rescue_from Doorkeeper::Errors::DoorkeeperError do |exception|
  Rails.logger.error "OAuth2 Error: #{exception.message}"
  render json: { error: exception.name, description: exception.description }
end
```

#### ORY Hydra
```ruby
# 分散エラーハンドリング
rescue_from Net::HTTPError do |e|
  if e.response.code == '409'
    # Hydra特有エラー：Login challenge already used
    Rails.logger.error "Hydra login challenge conflict"
    redirect_to new_user_session_path
  elsif e.response.code == '404'
    # Challenge not found
    Rails.logger.error "Invalid login challenge"
    render :not_found
  end
end

# Hydra API呼び出しエラー
rescue_from Hydra::ApiError do |e|
  Rails.logger.error "Hydra API error: #{e.response_body}"
  case e.response_headers['content-type']
  when /application\/json/
    error_data = JSON.parse(e.response_body)
    Rails.logger.error "Hydra error details: #{error_data}"
  end
end
```

---

## 💰 コスト詳細比較

### 開発コスト（人日）

| 開発フェーズ | Doorkeeper | ORY Hydra |
|-------------|------------|-----------|
| **環境構築** | 2人日 | 5人日 |
| **OAuth2実装** | 3人日 | 8人日 |
| **テスト実装** | 2人日 | 5人日 |
| **ドキュメント作成** | 1人日 | 3人日 |
| **合計** | **8人日** | **21人日** |

### 運用コスト（年額）

```yaml
# AWS ECS環境想定

Doorkeeper:
  ECS Fargate:
    IdP (0.5vCPU, 1GB): $432/年
    RP (0.25vCPU, 0.5GB): $216/年
  RDS MySQL:
    db.t3.small Multi-AZ: $564/年
  その他 (ALB, NAT等): $1,140/年
  合計: $2,352/年

ORY Hydra:
  ECS Fargate:
    Hydra Public (0.25vCPU, 0.5GB): $216/年
    Hydra Admin (0.25vCPU, 0.5GB): $108/年
    IdP (0.5vCPU, 1GB): $432/年
    RP (0.25vCPU, 0.5GB): $216/年
  RDS MySQL:
    IdP用 db.t3.small: $564/年
    Hydra用 db.t3.small: $564/年
  その他: $1,140/年
  合計: $3,240/年
  
差額: $888/年（約27%増）
```

---

## 🔧 Rails SSO実装の詳細比較

### 認証フロー実装

#### Doorkeeper実装フロー
```ruby
# 1. ユーザー → RP「SSOログイン」
# routes.rb
get '/auth/sso', to: 'sessions#omniauth'

# 2. OmniAuth → DoorkeeperのOAuth2エンドポイント
# config/initializers/omniauth.rb
provider :openid_connect, {
  name: :sso,
  scope: [:openid, :profile, :email],
  issuer: 'http://localhost:3000',
  client_options: {
    identifier: 'rp-client',
    secret: 'rp-client-secret',
    authorization_endpoint: "http://localhost:3000/oauth/authorize",
    token_endpoint: "http://idp:3000/oauth/token",
    userinfo_endpoint: "http://idp:3000/api/v1/user_info"
  }
}

# 3. Doorkeeper → IdPログイン画面
# app/controllers/application_controller.rb (IdP側)
before_action :authenticate_user!  # Devise標準認証

# 4. 認証成功 → 自動的にOAuth2フローへ
# Doorkeeperが内部処理、手動実装不要

# 5. 同意画面（自動同意の実装例）
# app/controllers/doorkeeper/authorizations_controller.rb
class Doorkeeper::AuthorizationsController < ApplicationController
  before_action :authenticate_resource_owner!
  before_action :auto_consent_for_trusted_clients

  private

  def auto_consent_for_trusted_clients
    if trusted_client?(params[:client_id])
      redirect_to oauth_authorization_path(params.merge(commit: "Authorize"))
    end
  end

  def trusted_client?(client_id)
    trusted_clients = ENV.fetch('TRUSTED_CLIENT_IDS', '').split(',')
    trusted_clients.include?(client_id)
  end
end

# 6. アクセストークン → ユーザー情報取得
# app/controllers/api/v1/user_info_controller.rb
class Api::V1::UserInfoController < ApplicationController
  before_action :doorkeeper_authorize!

  def show
    render json: {
      sub: current_resource_owner.id.to_s,
      email: current_resource_owner.email,
      name: current_resource_owner.name,
      # OpenID Connect標準クレーム
    }
  end

  private

  def current_resource_owner
    @current_resource_owner ||= User.find(doorkeeper_token.resource_owner_id)
  end
end
```

#### ORY Hydra実装フロー
```ruby
# 1. ユーザー → RP「SSOログイン」（同じ）

# 2. RP → Hydra Public API
redirect_to "http://localhost:4444/oauth2/auth?" +
  "response_type=code&" +
  "client_id=rp-client&" +
  "redirect_uri=#{callback_url}&" +
  "scope=openid profile email&" +
  "state=#{state}"

# 3. Hydra → IdPログインチャレンジ
# app/controllers/oauth2/login_controller.rb
class Oauth2::LoginController < ApplicationController
  def show
    challenge = params[:login_challenge]
    
    begin
      # HydraのAdmin APIでログインリクエスト取得
      login_request = hydra_admin_client.get_login_request(challenge)
      
      if user_signed_in?
        # 既にログイン済み → 直接承認
        accept_login(challenge, current_user.id.to_s)
      else
        # 未ログイン → ログイン画面
        session[:login_challenge] = challenge
        redirect_to new_user_session_path
      end
    rescue => e
      Rails.logger.error "Hydra login challenge error: #{e.message}"
      render :error
    end
  end

  def create
    challenge = session.delete(:login_challenge)
    
    if authenticate_user_credentials(params[:email], params[:password])
      # 2段階認証
      if two_factor_authenticate(current_user)
        accept_login(challenge, current_user.id.to_s)
      else
        redirect_to two_factor_path(challenge: challenge)
      end
    else
      session[:login_challenge] = challenge
      redirect_to new_user_session_path, alert: 'Invalid credentials'
    end
  end

  private

  def accept_login(challenge, subject)
    accept_request = {
      subject: subject,
      remember: true,
      remember_for: 3600,
      context: { user_id: subject }
    }
    
    response = hydra_admin_client.accept_login_request(challenge, accept_request)
    redirect_to response.redirect_to
  end
end

# 4. Hydra → IdP同意チャレンジ
# app/controllers/oauth2/consent_controller.rb
class Oauth2::ConsentController < ApplicationController
  def show
    challenge = params[:consent_challenge]
    
    begin
      consent_request = hydra_admin_client.get_consent_request(challenge)
      
      # 自動同意判定
      if auto_consent?(consent_request.client.client_id)
        accept_consent(challenge, consent_request.requested_scope)
      else
        @consent_request = consent_request
        render :show
      end
    rescue => e
      Rails.logger.error "Hydra consent challenge error: #{e.message}"
      render :error
    end
  end

  def create
    challenge = params[:consent_challenge]
    granted_scopes = params[:granted_scopes] || []
    
    accept_consent(challenge, granted_scopes)
  end

  private

  def auto_consent?(client_id)
    trusted_clients = ENV.fetch('TRUSTED_CLIENT_IDS', '').split(',')
    trusted_clients.include?(client_id)
  end

  def accept_consent(challenge, granted_scopes)
    accept_request = {
      grant_scope: granted_scopes,
      session: {
        id_token: {
          email: current_user.email,
          name: current_user.name
        }
      }
    }
    
    response = hydra_admin_client.accept_consent_request(challenge, accept_request)
    redirect_to response.redirect_to
  end
end

# 5. Hydra Admin APIクライアント実装
# app/services/hydra_admin_client.rb
class HydraAdminClient
  include HTTParty
  base_uri ENV.fetch('HYDRA_ADMIN_URL', 'http://hydra:4445')

  def get_login_request(challenge)
    response = self.class.get("/admin/oauth2/auth/requests/login?login_challenge=#{challenge}")
    handle_response(response)
  end

  def accept_login_request(challenge, accept_request)
    response = self.class.put(
      "/admin/oauth2/auth/requests/login/accept?login_challenge=#{challenge}",
      body: accept_request.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    handle_response(response)
  end

  def get_consent_request(challenge)
    response = self.class.get("/admin/oauth2/auth/requests/consent?consent_challenge=#{challenge}")
    handle_response(response)
  end

  def accept_consent_request(challenge, accept_request)
    response = self.class.put(
      "/admin/oauth2/auth/requests/consent/accept?consent_challenge=#{challenge}",
      body: accept_request.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    handle_response(response)
  end

  private

  def handle_response(response)
    if response.success?
      OpenStruct.new(JSON.parse(response.body))
    else
      raise "Hydra API Error: #{response.code} - #{response.body}"
    end
  end
end
```

### セッション管理とセキュリティ

#### Doorkeeper（統合セッション）
```ruby
# セッション管理：Rails標準
# config/initializers/session_store.rb
Rails.application.config.session_store :redis_store,
  servers: ["redis://localhost:6379/0/session"],
  expire_after: 90.minutes,
  secure: Rails.env.production?,
  same_site: :lax

# CSRF対策：Rails統合
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
end

# OAuth2トークン検証
before_action :doorkeeper_authorize!, except: [:public_endpoints]
```

#### ORY Hydra（分離セッション）
```ruby
# IdPセッション管理
class ApplicationController < ActionController::Base
  before_action :set_current_user
  
  private
  
  def set_current_user
    @current_user = User.find(session[:user_id]) if session[:user_id]
  end
end

# Hydraセッション管理（別途）
# Hydraが独自にセッション管理
# IdP側ではHydraのchallenge/responseのみ処理

# OAuth2トークン検証（RP側）
# JWT検証実装が必要
def verify_id_token(id_token)
  # 1. JWKSエンドポイントから公開鍵取得
  jwks_response = HTTParty.get("#{idp_url}/.well-known/jwks.json")
  
  # 2. JWT検証
  JWT.decode(id_token, jwks_response['keys'], true, algorithm: 'RS256')
rescue JWT::DecodeError => e
  Rails.logger.error "JWT verification failed: #{e.message}"
  nil
end
```

### エラーハンドリング・デバッグ

#### Doorkeeper（統合エラー処理）
```ruby
# 統一エラーハンドリング
class ApplicationController < ActionController::Base
  rescue_from Doorkeeper::Errors::DoorkeeperError do |exception|
    Rails.logger.error "OAuth2 Error: #{exception.class} - #{exception.message}"
    
    case exception
    when Doorkeeper::Errors::InvalidToken
      render json: { error: 'invalid_token' }, status: :unauthorized
    when Doorkeeper::Errors::TokenExpired
      render json: { error: 'token_expired' }, status: :unauthorized
    else
      render json: { error: 'oauth2_error' }, status: :bad_request
    end
  end
end

# ログ出力例
# I, [2024-01-15T10:30:45.123456 #1234]  INFO -- : 
# OAuth2 Token issued: client_id=rp-client, scopes=["openid", "profile"], user_id=123
```

#### ORY Hydra（分散エラー処理）
```ruby
# IdP側エラーハンドリング
class Oauth2::BaseController < ApplicationController
  rescue_from Net::HTTPError do |exception|
    Rails.logger.error "Hydra API Error: #{exception.message}"
    
    case exception.response.code
    when '409'
      # Challenge already used
      redirect_to new_user_session_path, alert: 'Session expired'
    when '404'
      # Invalid challenge
      render :not_found, status: :not_found
    when '400'
      # Bad request
      render :bad_request, status: :bad_request
    else
      render :error, status: :internal_server_error
    end
  end

  rescue_from JSON::ParserError do |exception|
    Rails.logger.error "Hydra response parsing error: #{exception.message}"
    render :error, status: :internal_server_error
  end
end

# RP側エラーハンドリング
class SessionsController < ApplicationController
  def auth_failure
    error_type = params[:message] || 'unknown_error'
    error_details = request.env['omniauth.error'] || 'No details'
    
    Rails.logger.error "SSO authentication failed: #{error_type}"
    Rails.logger.error "Error details: #{error_details}"
    
    case error_type
    when 'invalid_credentials'
      redirect_to root_path, alert: 'Invalid username or password'
    when 'access_denied'
      redirect_to root_path, alert: 'Access was denied'
    when 'invalid_request'
      redirect_to root_path, alert: 'Invalid authentication request'
    else
      redirect_to root_path, alert: 'Authentication failed'
    end
  end
end

# 分散ログ例
# IdP Log: [2024-01-15 10:30:45] Hydra login challenge received: abc123
# Hydra Log: [2024-01-15 10:30:46] Login request accepted for subject: user-456  
# RP Log: [2024-01-15 10:30:47] OAuth callback received with auth code: xyz789
```

---

## ☁️ AWS VPC環境での詳細運用比較

### ネットワークアーキテクチャ設計

#### ORY Hydra構成
```yaml
# 推奨VPC構成
VPC (10.0.0.0/16):
  Public Subnets (Multi-AZ):
    - Application Load Balancer (Internet-facing)
      - Target Groups: 
        - Hydra Public (4444) 
        - IdP App (3000)
        - RP App (3001)
    - NAT Gateway ×2 (AZ-a, AZ-c)
  
  Private Subnets (Multi-AZ):
    App Tier (10.0.1.0/24, 10.0.2.0/24):
      - ECS Fargate Cluster: sso-cluster
        - Service: idp-service (tasks: 2-8)
        - Service: rp-service (tasks: 2-4) 
        - Service: hydra-public-service (tasks: 2-10)
        - Service: hydra-admin-service (tasks: 1, fixed)
    
    Data Tier (10.0.11.0/24, 10.0.12.0/24):
      - RDS MySQL Multi-AZ:
        - Cluster: idp-cluster (writer + reader)
        - Cluster: hydra-cluster (writer + reader)
      - ElastiCache Redis:
        - Replication Group: session-cache (primary + replica)

# セキュリティグループ詳細設計
Security Groups:
  # インターネット向け
  ALB-SG:
    Inbound:
      - HTTP/80: 0.0.0.0/0
      - HTTPS/443: 0.0.0.0/0
    Outbound:
      - HTTP/3000: IdP-App-SG
      - HTTP/3001: RP-App-SG  
      - HTTP/4444: Hydra-Public-SG

  # IdPアプリケーション
  IdP-App-SG:
    Inbound:
      - HTTP/3000: ALB-SG
      - HTTP/3000: RP-App-SG  # API呼び出し用
    Outbound:
      - HTTP/4445: Hydra-Admin-SG  # Admin API
      - MySQL/3306: RDS-IdP-SG
      - Redis/6379: Cache-SG

  # Hydra Public（OAuth2エンドポイント）
  Hydra-Public-SG:
    Inbound:
      - HTTP/4444: ALB-SG
    Outbound:
      - MySQL/3306: RDS-Hydra-SG
      - HTTP/3000: IdP-App-SG  # リダイレクト確認用

  # Hydra Admin（内部API）
  Hydra-Admin-SG:
    Inbound:
      - HTTP/4445: IdP-App-SG  # IdPからのAdmin API呼び出し
    Outbound:
      - MySQL/3306: RDS-Hydra-SG

  # データベース層
  RDS-IdP-SG:
    Inbound:
      - MySQL/3306: IdP-App-SG
  
  RDS-Hydra-SG:
    Inbound:
      - MySQL/3306: Hydra-Public-SG
      - MySQL/3306: Hydra-Admin-SG
```

#### Doorkeeper構成（シンプル）
```yaml
# シンプルVPC構成
VPC (10.0.0.0/16):
  Public Subnets (Multi-AZ):
    - Application Load Balancer (Internet-facing)
      - Target Groups:
        - IdP App (3000) - OAuth2統合
        - RP App (3001)
    - NAT Gateway ×2

  Private Subnets (Multi-AZ):
    App Tier (10.0.1.0/24, 10.0.2.0/24):
      - ECS Fargate Cluster: sso-simple-cluster
        - Service: idp-service (tasks: 2-10, OAuth2統合)
        - Service: rp-service (tasks: 2-4)
    
    Data Tier (10.0.11.0/24, 10.0.12.0/24):
      - RDS MySQL Multi-AZ:
        - Cluster: sso-cluster (統合DB)
      - ElastiCache Redis:
        - Replication Group: session-cache

# シンプルセキュリティグループ設計
Security Groups:
  ALB-SG:
    Inbound:
      - HTTP/80, HTTPS/443: 0.0.0.0/0
    Outbound:
      - HTTP/3000: IdP-App-SG
      - HTTP/3001: RP-App-SG

  IdP-App-SG:  # OAuth2サーバー統合
    Inbound:
      - HTTP/3000: ALB-SG
      - HTTP/3000: RP-App-SG
    Outbound:
      - MySQL/3306: RDS-SG
      - Redis/6379: Cache-SG

  RDS-SG:  # 統合データベース
    Inbound:
      - MySQL/3306: IdP-App-SG
```

### ECS Fargate詳細設定

#### ORY Hydra Task Definitions
```json
{
  "family": "sso-hydra-stack",
  "taskRoleArn": "arn:aws:iam::123456789012:role/ECS-SSO-TaskRole",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ECS-SSO-ExecutionRole",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "containers": [
    {
      "name": "hydra-public",
      "image": "oryd/hydra:v2.2.0",
      "cpu": 256,
      "memory": 512,
      "essential": true,
      "environment": [
        {
          "name": "DSN",
          "value": "mysql://hydra_user:password@hydra-cluster.cluster-xyz.ap-northeast-1.rds.amazonaws.com:3306/hydra"
        },
        {
          "name": "URLS_SELF_ISSUER",
          "value": "https://sso.example.com"
        },
        {
          "name": "URLS_LOGIN",
          "value": "https://idp.example.com/oauth2/login"
        },
        {
          "name": "URLS_CONSENT", 
          "value": "https://idp.example.com/oauth2/consent"
        }
      ],
      "secrets": [
        {
          "name": "SECRETS_SYSTEM",
          "valueFrom": "arn:aws:ssm:ap-northeast-1:123456789012:parameter/sso/hydra/system-secret"
        }
      ],
      "portMappings": [
        {
          "containerPort": 4444,
          "protocol": "tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/sso-hydra-public",
          "awslogs-region": "ap-northeast-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:4444/health/ready || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    },
    {
      "name": "hydra-admin",
      "image": "oryd/hydra:v2.2.0", 
      "cpu": 256,
      "memory": 512,
      "essential": false,
      "environment": [
        {
          "name": "DSN", 
          "value": "mysql://hydra_user:password@hydra-cluster.cluster-xyz.ap-northeast-1.rds.amazonaws.com:3306/hydra"
        }
      ],
      "portMappings": [
        {
          "containerPort": 4445,
          "protocol": "tcp"
        }
      ],
      "command": ["serve", "-c", "/etc/config/hydra.yml", "admin"],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/sso-hydra-admin",
          "awslogs-region": "ap-northeast-1"
        }
      }
    },
    {
      "name": "idp-app",
      "image": "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/sso-idp:latest",
      "cpu": 512,
      "memory": 1024,
      "essential": true,
      "environment": [
        {
          "name": "RAILS_ENV",
          "value": "production"
        },
        {
          "name": "HYDRA_ADMIN_URL",
          "value": "http://localhost:4445"
        },
        {
          "name": "HYDRA_PUBLIC_URL",
          "value": "https://sso.example.com"
        }
      ],
      "secrets": [
        {
          "name": "DATABASE_URL",
          "valueFrom": "arn:aws:ssm:ap-northeast-1:123456789012:parameter/sso/idp/database-url"
        },
        {
          "name": "RAILS_MASTER_KEY",
          "valueFrom": "arn:aws:ssm:ap-northeast-1:123456789012:parameter/sso/idp/master-key"
        }
      ],
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "dependsOn": [
        {
          "containerName": "hydra-admin",
          "condition": "HEALTHY"
        }
      ]
    }
  ]
}
```

#### Doorkeeper Task Definition（シンプル）
```json
{
  "family": "sso-doorkeeper-stack",
  "taskRoleArn": "arn:aws:iam::123456789012:role/ECS-SSO-TaskRole",
  "cpu": "512",
  "memory": "1024", 
  "containers": [
    {
      "name": "idp-app",
      "image": "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/sso-idp-doorkeeper:latest",
      "cpu": 512,
      "memory": 1024,
      "environment": [
        {
          "name": "RAILS_ENV",
          "value": "production"
        }
      ],
      "secrets": [
        {
          "name": "DATABASE_URL",
          "valueFrom": "arn:aws:ssm:ap-northeast-1:123456789012:parameter/sso/database-url"
        }
      ],
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/sso-idp-doorkeeper"
        }
      }
    }
  ]
}
```

### Auto Scaling設定

#### ORY Hydra Auto Scaling
```yaml
# ECS Service Auto Scaling設定

# Hydra Public Service（高負荷対応）
HydraPublicService:
  MinCapacity: 2
  MaxCapacity: 10
  TargetTrackingScalingPolicies:
    - TargetValue: 70.0
      ScaleInCooldown: 300
      ScaleOutCooldown: 120
      MetricType: ECSServiceAverageCPUUtilization
    - TargetValue: 1000  # 1000 requests/minute per task
      MetricType: ALBRequestCountPerTarget

# Hydra Admin Service（固定、管理用）
HydraAdminService:
  MinCapacity: 1
  MaxCapacity: 1  # 競合回避のため固定
  # Auto Scaling無し

# IdP Service（認証処理用）  
IdPService:
  MinCapacity: 2
  MaxCapacity: 8
  TargetTrackingScalingPolicies:
    - TargetValue: 60.0  # CPU使用率
      MetricType: ECSServiceAverageCPUUtilization
    - TargetValue: 80.0  # メモリ使用率
      MetricType: ECSServiceAverageMemoryUtilization

# RP Service（軽負荷）
RPService:
  MinCapacity: 2
  MaxCapacity: 4
  TargetTrackingScalingPolicies:
    - TargetValue: 50.0
      MetricType: ECSServiceAverageCPUUtilization
```

#### Doorkeeper Auto Scaling（シンプル）
```yaml
# 統合IdP Service（OAuth2+認証統合）
IdPService:
  MinCapacity: 2
  MaxCapacity: 10
  TargetTrackingScalingPolicies:
    - TargetValue: 60.0  # CPU
      ScaleInCooldown: 480  # 8分（長めに設定）
      ScaleOutCooldown: 90   # 1.5分（早めにスケール）
      MetricType: ECSServiceAverageCPUUtilization
    - TargetValue: 1500    # より多くのリクエストを処理
      MetricType: ALBRequestCountPerTarget

# RP Service
RPService:
  MinCapacity: 2
  MaxCapacity: 6
  TargetTrackingScalingPolicies:
    - TargetValue: 50.0
      MetricType: ECSServiceAverageCPUUtilization
```

### コスト詳細分析（月額）

#### ORY Hydra本格構成
```yaml
# ECS Fargate Compute
Hydra Public (0.25vCPU×512MB×2): $18.00
Hydra Admin (0.25vCPU×512MB×1):  $9.00
IdP App (0.5vCPU×1GB×2):         $36.00
RP App (0.25vCPU×512MB×2):       $18.00
Fargate小計: $81.00

# RDS MySQL Multi-AZ
IdP Cluster (db.t3.small):       $47.00
Hydra Cluster (db.t3.small):     $47.00
RDS小計: $94.00

# ネットワーク・ロードバランサ
Application Load Balancer:       $23.00
NAT Gateway (×2 AZ):            $65.00
VPC Endpoints (ECR, S3):        $15.00

# キャッシュ・その他
ElastiCache Redis (t3.micro):   $12.00
CloudWatch Logs (5GB):          $5.00
AWS Systems Manager (Parameter Store): $3.00
Route 53 (Hosted Zone):         $1.00

# 合計
基本運用コスト: $299.00/月
高負荷時 (+50%スケール): $374.00/月
```

#### Doorkeeper簡易構成
```yaml
# ECS Fargate Compute
IdP App (0.5vCPU×1GB×2):        $36.00
RP App (0.25vCPU×512MB×2):      $18.00
Fargate小計: $54.00

# RDS MySQL Multi-AZ  
統合Cluster (db.t3.small):      $47.00

# ネットワーク・ロードバランサ
Application Load Balancer:      $23.00
NAT Gateway (×2 AZ):           $65.00
VPC Endpoints (ECR, S3):       $15.00

# キャッシュ・その他
ElastiCache Redis (t3.micro):  $12.00
CloudWatch Logs (3GB):         $3.00
Route 53 (Hosted Zone):        $1.00

# 合計
基本運用コスト: $220.00/月
高負荷時 (+50%スケール): $265.00/月

# コスト差
通常時: $79/月節約 (26.4%削減)
高負荷時: $109/月節約 (29.1%削減)
```

### セキュリティ・コンプライアンス統合

#### AWS WAF v2 統合

##### ORY Hydra用WAF設定
```json
{
  "Name": "SSO-Hydra-WebACL",
  "Scope": "REGIONAL",
  "DefaultAction": {"Allow": {}},
  "Rules": [
    {
      "Name": "HydraOAuth2RateLimit",
      "Priority": 1,
      "Statement": {
        "RateBasedStatement": {
          "Limit": 1000,
          "AggregateKeyType": "IP",
          "ScopeDownStatement": {
            "ByteMatchStatement": {
              "SearchString": "/oauth2/",
              "FieldToMatch": {"UriPath": {}},
              "TextTransformations": [{"Priority": 0, "Type": "LOWERCASE"}]
            }
          }
        }
      },
      "Action": {"Block": {}},
      "VisibilityConfig": {
        "SampledRequestsEnabled": true,
        "CloudWatchMetricsEnabled": true,
        "MetricName": "HydraOAuth2RateLimit"
      }
    },
    {
      "Name": "IdPLoginProtection", 
      "Priority": 2,
      "Statement": {
        "RateBasedStatement": {
          "Limit": 100,
          "AggregateKeyType": "IP",
          "ScopeDownStatement": {
            "ByteMatchStatement": {
              "SearchString": "/oauth2/login",
              "FieldToMatch": {"UriPath": {}}
            }
          }
        }
      },
      "Action": {"Block": {}},
      "VisibilityConfig": {
        "MetricName": "IdPLoginProtection"
      }
    },
    {
      "Name": "AWSManagedRulesCommonRuleSet",
      "Priority": 10,
      "OverrideAction": {"None": {}},
      "Statement": {
        "ManagedRuleGroupStatement": {
          "VendorName": "AWS",
          "Name": "AWSManagedRulesCommonRuleSet"
        }
      }
    }
  ]
}
```

##### Doorkeeper用WAF設定（シンプル）
```json
{
  "Name": "SSO-Doorkeeper-WebACL",
  "Rules": [
    {
      "Name": "OAuth2UnifiedRateLimit",
      "Priority": 1,
      "Statement": {
        "RateBasedStatement": {
          "Limit": 500,
          "AggregateKeyType": "IP",
          "ScopeDownStatement": {
            "OrStatement": {
              "Statements": [
                {
                  "ByteMatchStatement": {
                    "SearchString": "/oauth/",
                    "FieldToMatch": {"UriPath": {}}
                  }
                },
                {
                  "ByteMatchStatement": {
                    "SearchString": "/auth/sso",
                    "FieldToMatch": {"UriPath": {}}
                  }
                }
              ]
            }
          }
        }
      },
      "Action": {"Block": {}},
      "VisibilityConfig": {
        "MetricName": "OAuth2UnifiedRateLimit"
      }
    }
  ]
}
```

### 監視・ログ管理

#### CloudWatch統合監視

##### ORY Hydra監視設定
```yaml
# Custom Metrics（複数サービス）
CloudWatch Dashboard:
  - Widget: "Hydra Public Metrics"
    Metrics:
      - ECS/ContainerInsights: CPUUtilization, MemoryUtilization (hydra-public)
      - ApplicationELB: RequestCount, TargetResponseTime (/oauth2/*)
      - Custom: hydra_oauth2_requests_total, hydra_oauth2_errors_total
  
  - Widget: "IdP Integration Metrics"  
    Metrics:
      - Custom: idp_hydra_admin_api_calls, idp_hydra_api_errors
      - ECS: CPUUtilization, MemoryUtilization (idp-service)

# Log Insights Queries（分散ログ統合）
LogGroups:
  - /ecs/sso-hydra-public
  - /ecs/sso-hydra-admin
  - /ecs/sso-idp-app
  - /ecs/sso-rp-app
  
Queries:
  "OAuth2 Error Analysis":
    "fields @timestamp, @message | filter @message like /error/ | stats count() by bin(5m)"
  
  "Login Challenge Flow":
    "fields @timestamp, login_challenge, @message | filter @message like /challenge/ | sort @timestamp"

# X-Ray Distributed Tracing
Services:
  - sso-idp-app (Rails)
  - sso-hydra-public (Go)
  - sso-hydra-admin (Go)
  - RDS MySQL (IdP)
  - RDS MySQL (Hydra)

Trace Analysis:
  "Complete OAuth2 Flow":
    Browser → ALB → IdP → Hydra Admin → Hydra DB → Hydra Public → RP
    平均所要時間: 800ms-1.2s（ネットワーク遅延含む）
```

##### Doorkeeper監視設定（統合）
```yaml
# Simplified Metrics
CloudWatch Dashboard:
  - Widget: "Doorkeeper OAuth2 Metrics"
    Metrics:
      - Custom: doorkeeper_authorization_requests, doorkeeper_token_issued
      - ECS: CPUUtilization, MemoryUtilization (idp-service)
      - ApplicationELB: RequestCount, TargetResponseTime
      - RDS: DatabaseConnections, ReadLatency, WriteLatency

# Single Log Group
LogGroups:
  - /ecs/sso-idp-doorkeeper
  - /ecs/sso-rp-app

# Simplified X-Ray
Services:
  - sso-idp-doorkeeper (Rails統合OAuth2)
  - RDS MySQL (統合DB)

Trace Analysis:
  "Complete OAuth2 Flow":  
    Browser → ALB → IdP (OAuth2統合) → RDS → RP
    平均所要時間: 400ms-600ms（短縮されたパス）
```

---

## 📊 パフォーマンス比較

### トークン発行性能（req/sec）

| シナリオ | Doorkeeper | ORY Hydra |
|----------|------------|-----------|
| **Authorization Code取得** | 150 req/s | 300 req/s |
| **Access Token交換** | 200 req/s | 500 req/s |
| **Token検証** | 800 req/s | 1,200 req/s |
| **UserInfo取得** | 300 req/s | 200 req/s |

**理由**:
- Hydra: Go言語実装で高速なOAuth2処理
- Doorkeeper: Ruby実装だがUserInfo APIが直接統合されて効率的

### レスポンス時間

```yaml
# Authorization Code Flow（平均応答時間）

Doorkeeper:
  /oauth/authorize: 120ms
  /oauth/token: 80ms
  /api/v1/user_info: 50ms
  合計: 250ms

ORY Hydra:
  /oauth2/auth: 30ms
  /oauth2/token: 40ms
  /api/v1/user_info: 80ms + ネットワーク遅延
  合計: 200ms（ネットワーク条件良好時）
```

---

## 🔒 セキュリティ詳細比較

### OAuth2仕様準拠度

| 仕様項目 | Doorkeeper | ORY Hydra |
|----------|------------|-----------|
| **RFC 6749 (OAuth 2.0)** | ✅ 完全対応 | ✅ 完全対応 |
| **RFC 7636 (PKCE)** | ✅ 対応 | ✅ 対応 |
| **OpenID Connect 1.0** | ⚠️ gem追加必要 | ✅ ネイティブ対応 |
| **JWT Bearer Token** | ⚠️ カスタム実装必要 | ✅ 標準対応 |
| **Dynamic Client Registration** | ❌ 未対応 | ✅ 対応 |

### 脆弱性対応

```yaml
# セキュリティアップデート頻度（2023年実績）

Doorkeeper:
  - Ruby/Rails脆弱性: 影響あり
  - gem依存関係: bundler auditで管理
  - CVE対応: Rails LTSに依存
  
ORY Hydra:
  - Go言語脆弱性: 影響限定的
  - コンテナイメージ: 月次更新
  - CVE対応: 専門チームで迅速対応
```

---

## 🎯 選択指針（決定フローチャート）

```mermaid
graph TD
    A[SSOシステム検討開始] --> B{Rails中心の開発体制？}
    B -->|Yes| C{月間OAuth2リクエスト数}
    B -->|No| D[ORY Hydra推奨]
    
    C -->|<10,000| E{開発期間の制約}
    C -->|≥10,000| F[ORY Hydra推奨<br/>（高負荷対応）]
    
    E -->|<2週間| G[Doorkeeper推奨<br/>（迅速開発）]
    E -->|≥2週間| H{将来の拡張計画}
    
    H -->|多言語連携予定| I[ORY Hydra推奨<br/>（将来性重視）]
    H -->|Rails中心継続| J[Doorkeeper推奨<br/>（統合性重視）]
```

### 具体的な判断基準

#### Doorkeeperを選ぶべき条件
```yaml
技術的条件:
  ✅ Rails 5.0以上の既存アプリ
  ✅ 月間OAuth2リクエスト < 10,000件
  ✅ SSO対象サービス数 < 5個
  ✅ OAuth2カスタマイズ要件が軽微

組織的条件:
  ✅ Rails開発者中心のチーム
  ✅ インフラ運用リソースが限定的
  ✅ 開発期間 < 1ヶ月
  ✅ 予算制約あり
```

#### ORY Hydraを選ぶべき条件
```yaml
技術的条件:
  ✅ 月間OAuth2リクエスト > 10,000件
  ✅ 多言語・多フレームワーク連携
  ✅ 厳格なOAuth2仕様準拠が必要
  ✅ マイクロサービス指向

組織的条件:
  ✅ SRE・インフラエンジニア在籍
  ✅ コンテナオーケストレーション運用経験
  ✅ 開発期間 > 1ヶ月確保可能
  ✅ 運用コスト許容（年額+30-50万円）
```

---

## 📚 参考情報

### 学習リソース

#### Doorkeeper
- [公式ドキュメント](https://doorkeeper.gitbook.io/guides/)
- [Railsガイド](https://railsguides.jp/)
- 学習時間目安: **20-30時間**

#### ORY Hydra  
- [公式ドキュメント](https://www.ory.sh/docs/hydra/)
- [OAuth2/OIDC仕様書](https://openid.net/connect/)
- 学習時間目安: **60-80時間**

### コミュニティサポート

| 項目 | Doorkeeper | ORY Hydra |
|------|------------|-----------|
| **GitHub Star** | 5.2k | 15k |
| **日本語情報** | 豊富 | 限定的 |
| **Stack Overflow** | 1,500件 | 800件 |
| **企業サポート** | コミュニティ中心 | Ory Corp |

この詳細比較により、プロジェクトの要件と制約に基づいた適切な選択が可能です。
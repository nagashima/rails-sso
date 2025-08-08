# IdP側Doorkeeper実装ノート

**実装方式**: Doorkeeper gem + doorkeeper-openid_connect gem
**アーキテクチャ**: 統合型OAuth2プロバイダー
**JWT署名**: RSA256
**認証状態管理**: JWT Cookie + Doorkeeper OAuth2 Sessions
**Container対応**: Rails 7 Host Authorization

---

## 目次

1. [JWT Cookie認証の設計](#1-jwt-cookie認証の設計)
2. [Doorkeeper gem アーキテクチャ](#2-doorkeeper-gem-アーキテクチャ)
3. [SSO認証フロー詳細](#3-sso認証フロー詳細)
4. [RSA鍵管理とJWT署名](#4-rsa鍵管理とjwt署名)
5. [Rails 7 Host Authorization対応](#5-rails-7-host-authorization対応)
6. [本番環境セキュリティ設計](#6-本番環境セキュリティ設計)
7. [Doorkeeper設定詳細](#7-doorkeeper設定詳細)
8. [API設計](#8-api設計)
9. [トラブルシューティング](#9-トラブルシューティング)
10. [パフォーマンス最適化](#10-パフォーマンス最適化)

---

## 1. JWT Cookie認証の設計

### 認証方式の選択理由

本IdPアプリケーションでは、**JWT Cookie方式**を採用している。

#### 3つの認証方式比較

| 方式 | 保存場所 | 送信方法 | 特徴 |
|-----|---------|---------|------|
| **従来セッションCookie** | Cookie: session_id<br>サーバー: セッションデータ | 自動（Cookie） | シンプル、即座無効化可能、ステートフル |
| **JWT Bearer** | localStorage/変数 | 手動（Authorizationヘッダー） | ステートレス、SPA向け、XSS脆弱性 |
| **JWT Cookie** | Cookie: JWT本体 | 自動（Cookie） | ステートレス、自動送信、ハイブリッド |

### JWT Cookie方式の採用理由（Doorkeeper版）

#### 1. **統合OAuth2プロバイダーとの相性**
```
ユーザー → RP → IdP (統合OAuth2エンドポイント)
                 ↑
           Cookieが自動送信される
```
- **統合型アーキテクチャ**: IdPとOAuth2プロバイダーが同一アプリケーション内
- DoorkeeperのAuthorizationsControllerが直接認証状態をチェック
- JWT Cookieによる自動認証で同意フローがシームレス

#### 2. **React化への対応**
```javascript
// React内でのAPI呼び出し
fetch('/api/users/profile', {
  credentials: 'include'  // JWT Cookieが自動送信
})
```
- **段階的移行**が可能（一部画面ずつReact化）
- **同じJWT**をCookie/Bearerヘッダー両方で利用可能
- API認証とSSO認証を統一

#### 3. **セキュリティとログアウト制御**
```ruby
# ログアウト時
def logout
  cookies.delete(:auth_token)  # Cookie削除
  # → OAuth2・API両方で認証失敗になる
end
```
- **ステートレス**（サーバーが状態を持たない）
- **Cookie制御**でログアウト時の即座無効化
- **HttpOnly設定**でXSS対策

### Rails実装
```ruby
# JWT生成・Cookie設定（Sessions::LoginController）
jwt_token = JWT.encode(
  { user_id: user.id, exp: 30.minutes.from_now.to_i },
  Rails.application.secret_key_base
)

cookies.signed[:auth_token] = {
  value: jwt_token,
  httponly: true,
  secure: Rails.env.production?
}

# 認証チェック（ApplicationController）
def current_user
  token = cookies.signed[:auth_token]
  return nil unless token

  payload = JWT.decode(token, Rails.application.secret_key_base).first
  User.find(payload['user_id'])
rescue JWT::DecodeError, ActiveRecord::RecordNotFound
  nil
end
```

---

## 2. Doorkeeper gem アーキテクチャ

### 2.1. 技術的な実装
本プロジェクトは **Doorkeeper gem** + **doorkeeper-openid_connect gem** を使用してOAuth2/OpenID Connect Provider として動作する：

- **Doorkeeper**: OAuth2 Authorization Server の完全実装（RFC 6749準拠）
- **doorkeeper-openid_connect**: OpenID Connect拡張（OpenID Connect 1.0準拠）
- **統合型アーキテクチャ**: IdPアプリケーション内でOAuth2サーバー機能を提供
- **RSA署名**: JWT IDトークンのRS256署名対応
- **JWKS**: 手動実装による公開鍵配布

### 2.2. アーキテクチャ比較

#### **Doorkeeper版（統合型）**
```
┌─────────────────────────────────┐
│        IdP Application          │
│  ┌─────────────┐ ┌─────────────┐│
│  │   IdP Core  │ │ Doorkeeper  ││
│  │(認証・管理) │ │(OAuth2 API) ││
│  │   Sessions  │ │Authorizations││
│  │   Users     │ │   Tokens    ││
│  └─────────────┘ └─────────────┘│
└─────────────────────────────────┘
```

#### **ORY Hydra版（分離型）**
```
┌─────────────┐  HTTP API  ┌─────────────┐
│ IdP Core    │<---------->│ ORY Hydra   │
│(認証・管理) │            │(OAuth2 API) │
│  Sessions   │            │   Tokens    │
│  Users      │            │   Flows     │
└─────────────┘            └─────────────┘
```

### 2.3. Doorkeeper gem実装の特徴

#### **メリット**
- **統合性**: 1つのRailsアプリケーション内で完結
- **デバッグ容易**: 単一アプリケーションでのログ・デバッグ
- **設定ベース**: OAuth2動作を設定で制御
- **Rails親和性**: Railsの慣例に従った実装

#### **制約**
- **JWKS非標準**: 手動実装が必要
- **スケール限界**: Rails アプリケーションの制約に依存
- **設定複雑性**: 高度なOAuth2機能は設定が複雑

### 2.4. 命名規則とエンドポイント

技術的にはOAuth2 + OpenID Connectだが、以下の理由で**OAuth2**表記で統一：

1. **ルート名**: `/oauth/authorize` - Dorokeeperの慣例
2. **一般認識**: OAuth2の方が広く知られている
3. **実装レベル**: OAuth2 APIを拡張してOIDCを実現

**結論**: 実装は**OAuth2 + OpenID Connect**、命名・ルーティングは**OAuth2**で統一

---

## 3. SSO認証フロー（Doorkeeper Authorization Code Flow）

### Doorkeeperによる認証状態管理

#### **重要: DoorkeeperがOAuth2認証フローを統合管理**

Doorkeeperは **既存のIdP認証システム** と **OAuth2フロー** を`resource_owner_authenticator`設定により統合する。

```
Doorkeeper統合認証フロー:
┌─────────────────────────────────────┐
│ OAuth2 Authorization Request       │
│ ├─ resource_owner_authenticator    │
│ │  └─ current_user || redirect     │
│ ├─ 既存ログイン済み: 同意画面      │
│ ├─ 未ログイン: Sessions::Login      │
│ └─ 認証完了: Authorization Code     │
└─────────────────────────────────────┘
```

#### **SSOフローの分岐点**

**パターンA: IdP認証済み状態がある場合**
```
User → RP → IdP/Oauth (認証状態チェック) ✅ JWT Cookie有効
                ↓
          ログイン画面をスキップ
                ↓
          直接同意画面表示 → 認証コード発行
          (ユーザーはIdPログイン画面を見ない)
```

**パターンB: IdP認証済み状態がない場合**
```
User → RP → IdP/OAuth (認証状態チェック) ❌ JWT Cookie無効/なし
                ↓
          Sessions::LoginControllerにリダイレクト → 認証実行
                ↓
          認証成功 → 同意画面 → 認証コード発行
```

### シーケンス図（Doorkeeper版）
```
User → RP → IdP/Doorkeeper
 │      │       │
 │      │       ├─ resource_owner_authenticator
 │      │       ├─ 認証処理（必要に応じて）
 │      │       └─ 同意処理・認証コード発行
 │      │
 │      └─ トークン取得・ユーザー情報取得
 │
 └─ ログイン完了
```

### 詳細フロー

#### **フロー全体の分岐構造（Doorkeeper版）**

```
1. User → RP → IdP/OAuth: 認証リクエスト
          ↓
2. Doorkeeper: resource_owner_authenticator実行
   ├─ [JWT Cookie有効] → 即座に同意画面
   └─ [JWT Cookie無効] → Sessions::Loginにリダイレクト
                         ↓
3. Sessions::Login: 認証処理 → JWT Cookie設定 → Doorkeeperに戻る
                         ↓
4. Doorkeeper: 同意画面 → 認証コード発行
```

#### **ケース1: IdP認証済み（SSO発動）**
```
User: RPの「ログイン」ボタンクリック
  ↓
RP: IdPのOAuth2エンドポイントに認証リクエスト
  GET /oauth/authorize?response_type=code&client_id=xxx&scope=openid
  ↓
Doorkeeper: resource_owner_authenticator実行 → current_user ✅ JWT Cookie有効
  ↓
Doorkeeper: ログイン画面をスキップし、直接同意画面表示
  ↓
User: 同意ボタンクリック
  ↓
Doorkeeper: RPのコールバックに認証コード送信
  GET /auth/sso/callback?code={auth_code}&state={state}
  ↓
RP: アクセストークン取得・ユーザー情報取得
  ユーザー体感: 同意画面のみで瞬時にログイン完了
```

#### **ケース2: IdP未認証（フル認証実行）**

**2-1. 認証開始**
```
User: RPの「ログイン」ボタンクリック
  ↓
RP: IdPのOAuth2エンドポイントに認証リクエスト
  GET /oauth/authorize?response_type=code&client_id=xxx&scope=openid
  ↓
Doorkeeper: resource_owner_authenticator実行 → current_user ❌ JWT Cookie無効
  ↓
Doorkeeper: Sessions::Loginにリダイレクト
  redirect_to login_path
```

**2-2. IdPでの認証処理**
```
Sessions::Login: ログイン画面表示
  ↓
User: メール・パスワード入力 + 2段階認証
  ↓
Sessions::Login: JWT Cookie設定 + リダイレクト
  - set_jwt_cookie(user)
  - redirect_to session[:return_to] || root_path
```

**2-3. OAuth2フロー復帰**
```
Doorkeeper: OAuth2フロー継続
  - resource_owner_authenticator再実行 → current_user ✅
  ↓
Doorkeeper: 同意画面表示
  ↓
User: スコープ確認・同意ボタンクリック
  ↓
Doorkeeper: RPのコールバックに認証コード送信
  GET /auth/sso/callback?code={auth_code}&state={state}
  ↓
RP: アクセストークン取得・ユーザー情報取得
  POST /oauth/token (client認証付き)
  GET /api/v1/user_info (Bearer Token)
```

### **役割分担の明確化（Doorkeeper版）**

| コンポーネント | 役割 | 管理する状態 |
|---------------|------|-------------|
| **Doorkeeper** | **OAuth2サーバー統合管理** | OAuth2トークン・認証コード・クライアント登録 |
| **Sessions::Login** | **ユーザー認証処理** | JWT Cookie・個別ユーザー認証 |
| **RP** | **OAuth2クライアント** | RPアプリ固有のセッション管理 |

### **Doorkeeper設定の重要ポイント**

```ruby
# config/initializers/doorkeeper.rb
Doorkeeper.configure do
  # 統合認証の核心設定
  resource_owner_authenticator do
    current_user || redirect_to(login_path)
  end

  # 自動同意設定（開発環境）
  skip_authorization do |resource_owner, client|
    Rails.env.development?
  end

  # アクセストークン有効期限
  access_token_expires_in 2.hours

  # PKCE設定（セキュリティ強化）
  force_ssl_in_redirect_uri false  # 開発環境のみ
end
```

---

## 4. RSA鍵管理とJWT署名

### 4.1. RSA鍵ペア生成と管理

#### **Docker環境での鍵ペア管理**

```bash
# ホスト側での鍵生成（初回のみ）
mkdir -p keys
openssl genrsa -out keys/private_key.pem 2048
openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem

# 権限設定
chmod 600 keys/private_key.pem
chmod 644 keys/public_key.pem
```

#### **Docker Compose設定**
```yaml
# docker-compose.yml
services:
  idp:
    volumes:
      - ./keys:/app/config/keys:ro  # 読み取り専用マウント
```

#### **セキュリティ考慮**
- **Git除外**: `.gitignore`で`keys/`を除外
- **権限制限**: 秘密鍵は600, 公開鍵は644
- **環境分離**: 本番環境では外部キー管理システム使用

### 4.2. JWT署名実装（doorkeeper-openid_connect）

#### **OpenID Connect設定**
```ruby
# config/initializers/doorkeeper_openid_connect.rb
Doorkeeper::OpenidConnect.configure do
  issuer "http://localhost:3000"

  signing_key_from_file Rails.root.join('config/keys/private_key.pem')

  subject_types_supported ['public']

  id_token_signing_alg_values_supported ['RS256']

  claims do
    claim :email, scope: :email do |user|
      user.email
    end

    claim :name, scope: :profile do |user|
      user.name
    end

    claim :birthdate, scope: :profile do |user|
      user.date_of_birth&.iso8601
    end
  end
end
```

### 4.3. JWKS実装（手動実装）

#### **公開鍵配布エンドポイント**
```ruby
# app/controllers/well_known_controller.rb
class WellKnownController < ApplicationController
  def jwks
    public_key_file = Rails.root.join('config/keys/public_key.pem')
    public_key = OpenSSL::PKey::RSA.new(File.read(public_key_file))

    jwk = JWT::JWK.new(public_key)
    jwks = { keys: [jwk.export.merge(alg: 'RS256', use: 'sig')] }

    render json: jwks
  rescue StandardError => e
    Rails.logger.error "JWKS generation failed: #{e.message}"
    render json: { error: 'JWKS unavailable' }, status: 500
  end
end
```

#### **ルーティング設定**
```ruby
# config/routes.rb
get '/.well-known/jwks.json', to: 'well_known#jwks'
```

### 4.4. 鍵ローテーション戦略

#### **本番環境での鍵管理**
```ruby
# 複数鍵対応（将来拡張用）
def load_signing_keys
  key_files = Dir[Rails.root.join('config/keys/private_key_*.pem')]
  key_files.map { |file| OpenSSL::PKey::RSA.new(File.read(file)) }
end

def current_signing_key
  # 最新の秘密鍵を使用
  load_signing_keys.last
end
```

---

## 5. Rails 7 Host Authorization対応

### 5.1. Container間通信の課題

Rails 7では`config.hosts`によるHost Authorization機能が導入され、Docker環境でのコンテナ間通信に影響を与える。

#### **問題の発生**
```
RP Container → IdP Container (http://idp:3000)
              ↓
Rails 7: "Blocked host: idp" エラー
```

#### **原因**
- Rails 7のセキュリティ機能によりコンテナ名でのアクセスが拒否
- 開発環境では`localhost`のみが許可されている

### 5.2. 解決策の実装

#### **IdP側設定**
```ruby
# idp_app/config/environments/development.rb
Rails.application.configure do
  # Docker コンテナ間通信許可
  config.hosts << "idp"           # コンテナ名でのアクセス
  config.hosts << "idp:3000"      # ポート付きコンテナ名
  config.hosts << "localhost"     # 従来のローカルアクセス
  config.hosts << "localhost:3000"

  # 開発環境では全ホスト許可（セキュリティ注意）
  # config.hosts.clear
end
```

#### **RP側設定は不要**
```ruby
# RP側: Host Authorization設定不要
# 理由: RPはIdPにリクエストを送信する「クライアント側」のため、
#       Rails 7 Host Authorization制限の対象外
```

### 5.3. OmniAuth設定での使い分け

#### **外部向けURL vs 内部通信URL**
```ruby
# rp_app/config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, {
    name: :sso,
    scope: [:openid, :profile, :email],
    issuer: 'http://localhost:3000',  # ブラウザ向けURL
    client_options: {
      # ブラウザリダイレクト用（外部向け）
      authorization_endpoint: "http://localhost:3000/oauth/authorize",

      # コンテナ間通信用（内部向け）
      token_endpoint: "http://idp:3000/oauth/token",
      userinfo_endpoint: "http://idp:3000/api/v1/user_info",
      jwks_uri: "http://idp:3000/.well-known/jwks.json"
    }
  }
end
```

### 5.4. セキュリティ考慮事項

#### **開発環境での設定**
- **必要最小限**: 具体的なホスト名のみ許可
- **避けるべき**: `config.hosts.clear`（全ホスト許可）

#### **本番環境での設定**
```ruby
# 本番環境例
config.hosts << "auth.company.com"
config.hosts << "internal-idp.company.local"
```

---

## 6. 本番環境セキュリティ設計

### 6.1. 統合型アーキテクチャのセキュリティ境界

#### **Doorkeeper版の特徴**
```
┌─────────────────────────────────┐ 信頼境界: アプリケーション
│        IdP + OAuth2 Server      │
│  ┌─────────────┐ ┌─────────────┐│
│  │   IdP Core  │ │ Doorkeeper  ││ ← 単一アプリケーション内
│  │  /login     │ │ /oauth/*    ││
│  │  /users     │ │ /api/v1     ││
│  └─────────────┘ └─────────────┘│
└─────────────────────────────────┘
```

#### **Hydra版との比較**
- **Doorkeeper**: 単一障害点、統合セキュリティ設定
- **Hydra**: 分離された信頼境界、個別セキュリティ設定

### 6.2. アプリケーションレベルセキュリティ

#### **必須セキュリティ設定**

```ruby
# config/application.rb
config.force_ssl = true  # 本番環境ではHTTPS強制

# config/initializers/doorkeeper.rb
Doorkeeper.configure do
  # PKCE強制（OAuth2セキュリティ強化）
  pkce_required true

  # SSL/TLS設定
  force_ssl_in_redirect_uri !Rails.env.development?

  # トークン有効期限
  access_token_expires_in 1.hour
  refresh_token_expires_in 1.week

  # セキュアなランダム生成
  access_token_generator "Doorkeeper::JWT"
end
```

#### **セキュリティヘッダー設定**
```ruby
# config/application.rb
config.force_ssl = true

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :set_security_headers

  private

  def set_security_headers
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
  end
end
```

### 6.3. 鍵管理セキュリティ

#### **本番環境での鍵管理**
```ruby
# 環境変数ベースの鍵管理
private_key = ENV['RSA_PRIVATE_KEY'] ||
              File.read(Rails.root.join('config/keys/private_key.pem'))

Doorkeeper::OpenidConnect.configure do
  signing_key private_key
end
```

#### **鍵ローテーション**
```bash
# 鍵ローテーション手順
1. 新しい鍵ペア生成
2. JWKS に新しい公開鍵追加
3. IdPの署名鍵を新しい秘密鍵に切り替え
4. 24時間後に古い鍵をJWKSから削除
```

### 6.4. データベースセキュリティ

#### **OAuth2データの暗号化**
```ruby
# OAuth2トークンの暗号化
class Doorkeeper::AccessToken
  encrypts :token
  encrypts :refresh_token
end
```

#### **ログ出力制御**
```ruby
# config/initializers/filter_parameter_logging.rb
Rails.application.config.filter_parameters += [
  :password, :token, :client_secret, :authorization_code
]
```

### 6.5. Rate Limiting

#### **Nginx設定例**
```nginx
# OAuth2エンドポイント保護
location /oauth/ {
    limit_req zone=oauth burst=10 nodelay;
    proxy_pass http://app_backend;
}

# API エンドポイント保護
location /api/ {
    limit_req zone=api burst=20 nodelay;
    proxy_pass http://app_backend;
}
```

#### **アプリケーションレベル**
```ruby
# Gemfile
gem 'rack-attack'

# config/initializers/rack_attack.rb
class Rack::Attack
  throttle('oauth/ip', limit: 10, period: 60.seconds) do |req|
    req.ip if req.path.start_with?('/oauth/')
  end
end
```

---

## 7. Doorkeeper設定詳細

### 7.1. コア設定

#### **基本認証フロー**
```ruby
# config/initializers/doorkeeper.rb
Doorkeeper.configure do
  # OAuth2 grant flows
  grant_flows %w[authorization_code]

  # 統合認証システム
  resource_owner_authenticator do
    current_user || redirect_to(login_path)
  end

  # リソースオーナー取得
  resource_owner_from_credentials do |routes|
    user = User.find_by(email: params[:username])
    user if user&.authenticate(params[:password])
  end
end
```

### 7.2. クライアント管理

#### **OAuth2クライアント登録**
```ruby
# db/seeds.rb または setup script
Doorkeeper::Application.create!(
  name: "RP Client",
  uid: "rp-client",
  secret: "rp-client-secret",
  redirect_uri: "http://localhost:3001/auth/sso/callback",
  scopes: "openid profile email",
  confidential: true
)
```

#### **スコープ設定**
```ruby
Doorkeeper.configure do
  default_scopes :openid
  optional_scopes :profile, :email, :address, :phone

  scope_for :userinfo do
    %w[openid profile email]
  end
end
```

### 7.3. カスタムコントローラー

#### **認証画面カスタマイズ**
```ruby
# app/controllers/custom_authorizations_controller.rb
class CustomAuthorizationsController < Doorkeeper::AuthorizationsController
  before_action :authenticate_resource_owner!

  def new
    # カスタム同意画面ロジック
    if auto_approve?
      redirect_to oauth_authorization_path(authorize_response_params)
    else
      render :new
    end
  end

  private

  def auto_approve?
    # 信頼できるクライアントは自動承認
    @pre_auth.client.trusted?
  end
end
```

#### **ルーティング上書き**
```ruby
# config/routes.rb
use_doorkeeper controllers: {
  authorizations: 'custom_authorizations',
  tokens: 'custom_tokens'
}
```

---

## 8. API設計

### 8.1. ユーザー情報取得API

#### **エンドポイント実装**
```ruby
# app/controllers/api/v1/user_info_controller.rb
class Api::V1::UserInfoController < ApplicationController
  before_action :doorkeeper_authorize!

  def show
    user = User.find(doorkeeper_token.resource_owner_id)
    scopes = doorkeeper_token.scopes.to_a

    render json: build_user_claims(user, scopes)
  end

  private

  def build_user_claims(user, scopes)
    claims = { sub: user.id.to_s }

    if scopes.include?('email')
      claims[:email] = user.email
      claims[:email_verified] = user.activated?
    end

    if scopes.include?('profile')
      claims[:name] = user.name
      claims[:birthdate] = user.date_of_birth&.iso8601
    end

    claims
  end
end
```

#### **Bearer Token認証**
```ruby
# Bearer Token による API認証
def show
  # doorkeeper_authorize! が自動でBearerトークンを検証
  # Authorization: Bearer {access_token}

  token = doorkeeper_token
  user_id = token.resource_owner_id
  scopes = token.scopes

  # スコープベースのデータフィルタリング
  user_data = filter_by_scopes(User.find(user_id), scopes)
  render json: user_data
end
```

### 8.2. エラーハンドリング

#### **OAuth2エラーレスポンス**
```ruby
# app/controllers/api/v1/base_controller.rb
class Api::V1::BaseController < ActionController::API
  include Doorkeeper::Helpers::Controller

  rescue_from Doorkeeper::Errors::DoorkeeperError do |exception|
    render json: {
      error: exception.name,
      error_description: exception.description
    }, status: exception.status
  end

  private

  def doorkeeper_unauthorized_render_options(error:)
    {
      json: {
        error: 'invalid_token',
        error_description: 'The access token is invalid'
      }
    }
  end
end
```

---

## 9. トラブルシューティング

### 9.1. よくある問題と解決策

#### **🔴 "Blocked host" エラー**
```
ActionController::BadRequest (Blocked host: idp):
```

**原因**: Rails 7の Host Authorization によりコンテナ名でのアクセスが拒否

**解決策**:
```ruby
# config/environments/development.rb
config.hosts << "idp"
config.hosts << "idp:3000"
```

#### **🔴 JWT署名検証エラー**
```
JWT::VerificationError: signature verification failed
```

**原因**: RSA鍵ペアの不整合またはJWKS設定ミス

**解決策**:
```bash
# 鍵ペア再生成
rm -rf keys/
mkdir keys
openssl genrsa -out keys/private_key.pem 2048
openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem

# コンテナ再起動
docker-compose restart idp rp
```

#### **🔴 OAuth2クライアント未登録**
```
Doorkeeper::Errors::InvalidClient: Client authentication failed
```

**解決策**:
```bash
./scripts/setup-doorkeeper-client.sh
```

#### **🔴 JWKS エンドポイントエラー**
```
OpenSSL::PKey::RSAError: Neither PUB key nor PRIV key
```

**原因**: 公開鍵ファイルの読み込み失敗

**解決策**:
```ruby
# app/controllers/well_known_controller.rb で鍵ファイル存在確認
def jwks
  public_key_file = Rails.root.join('config/keys/public_key.pem')

  unless File.exist?(public_key_file)
    return render json: { error: 'Public key not found' }, status: 500
  end

  # ...
end
```

#### **🔴 OAuth2フロー途中でIdPトップページに留まる**
```
問題: IdP未ログイン状態でSSOログイン → ログイン完了後にIdPトップページに留まり、OAuth2フローが中断される
```

**原因**: `resource_owner_authenticator`でログインページにリダイレクト時、OAuth2フロー情報が失われる

**解決策**:
```ruby
# config/initializers/doorkeeper.rb
resource_owner_authenticator do
  token = cookies.signed[:auth_token]

  if token
    begin
      payload = JWT.decode(token, Rails.application.secret_key_base).first
      User.find(payload['user_id'])
    rescue JWT::DecodeError, ActiveRecord::RecordNotFound
      # OAuth2フロー情報を保存してリダイレクト
      session[:oauth2_return_to] = request.fullpath
      redirect_to(login_path)
    end
  else
    # OAuth2フロー情報を保存してリダイレクト
    session[:oauth2_return_to] = request.fullpath
    redirect_to(login_path)
  end
end
```

```ruby
# app/controllers/sessions/login_controller.rb
def handle_login_success(user)
  # OAuth2フローからの復帰をチェック
  return_to = session.delete(:oauth2_return_to)

  if return_to
    # OAuth2フローに復帰
    redirect_to return_to, notice: 'ログインが完了しました。認証フローを継続します。'
  else
    # 通常のログインフロー
    redirect_to root_path, notice: 'ログインしました。'
  end
end
```

**動作確認**:
1. IdP未ログイン状態でRPからSSOログイン開始
2. IdPログイン→2段階認証完了
3. 自動的にOAuth2フロー復帰→同意画面→RPログイン完了

### 9.2. デバッグ手法

#### **OAuth2フロー追跡**
```ruby
# config/initializers/doorkeeper.rb
Doorkeeper.configure do
  # デバッグ用ログ
  enable_application_owner confirmation: false

  # 詳細ログ出力
  Rails.logger.level = :debug if Rails.env.development?
end
```

#### **トークン検証**
```bash
# アクセストークンの内容確認
curl -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:3000/api/v1/user_info | jq

# JWKSエンドポイント確認
curl http://localhost:3000/.well-known/jwks.json | jq
```

#### **データベース状態確認**
```ruby
# Rails console
Doorkeeper::Application.all
Doorkeeper::AccessToken.active
User.count
```

---

## 10. パフォーマンス最適化

### 10.1. データベース最適化

#### **インデックス設定**
```ruby
# OAuth2関連テーブルのインデックス
class AddIndexesToOauth2Tables < ActiveRecord::Migration[7.0]
  def change
    add_index :oauth_access_tokens, :resource_owner_id
    add_index :oauth_access_tokens, :application_id
    add_index :oauth_access_tokens, [:token], unique: true

    add_index :oauth_applications, [:uid], unique: true
  end
end
```

#### **N+1問題対策**
```ruby
# ユーザー情報API最適化
def show
  user = User.includes(:profile)
            .find(doorkeeper_token.resource_owner_id)

  render json: build_user_claims(user, doorkeeper_token.scopes)
end
```

### 10.2. キャッシュ戦略

#### **JWKS キャッシュ**
```ruby
# app/controllers/well_known_controller.rb
def jwks
  Rails.cache.fetch('jwks_public_keys', expires_in: 1.hour) do
    generate_jwks
  end
end

private

def generate_jwks
  public_key = OpenSSL::PKey::RSA.new(File.read(public_key_path))
  jwk = JWT::JWK.new(public_key)
  { keys: [jwk.export.merge(alg: 'RS256', use: 'sig')] }
end
```

#### **ユーザー情報キャッシュ**
```ruby
def build_user_claims(user, scopes)
  cache_key = "user_claims_#{user.id}_#{scopes.to_a.sort.join('_')}"

  Rails.cache.fetch(cache_key, expires_in: 10.minutes) do
    generate_user_claims(user, scopes)
  end
end
```

### 10.3. 本番環境設定

#### **Puma設定最適化**
```ruby
# config/puma.rb
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count

workers ENV.fetch("WEB_CONCURRENCY") { 2 }

preload_app!

on_worker_boot do
  ActiveRecord::Base.establish_connection
end
```

#### **データベースプール設定**
```ruby
# config/database.yml
production:
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  checkout_timeout: 5
```

### 10.4. 監視とメトリクス

#### **重要なメトリクス**
- OAuth2認証リクエスト/秒
- トークン発行レスポンス時間
- JWT署名・検証時間
- API レスポンス時間
- エラー率

#### **アラート設定**
```ruby
# OAuth2エラー監視
class OAuth2ErrorTracker
  def self.track_error(error_type, details)
    Rails.logger.error "[OAuth2] #{error_type}: #{details}"

    # 外部監視サービスに送信
    if Rails.env.production?
      MetricsService.increment("oauth2.error.#{error_type}")
    end
  end
end
```

---

## まとめ

Doorkeeper版実装は、統合型アーキテクチャによりシンプルな構成を実現している。Hydra版との主な違いは：

### **Doorkeeper版の利点**
- **統合性**: 単一Railsアプリケーション内で完結
- **開発効率**: Railsの慣例に沿った開発
- **デバッグ容易**: 統合ログとエラー追跡
- **設定簡素**: Rubyコードベースの設定

### **考慮事項**
- **スケーラビリティ**: Rails アプリケーションの制約
- **JWKS手動実装**: 標準ライブラリ不足のため自前実装
- **Host Authorization**: Rails 7でのコンテナ対応必須

### **推奨用途**
- **中小規模システム**: 統合管理による運用効率重視
- **Rails主体環境**: 既存Rails資産活用
- **プロトタイプ**: 迅速な機能検証

この実装ノートにより、Doorkeeper版SSO認証システムの技術詳細とベストプラクティスを網羅的に理解できる。
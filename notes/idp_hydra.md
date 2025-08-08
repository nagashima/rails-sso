# IdP側ORY Hydra連携実装ノート

**実装方式**: ORY Hydra + IdP分離アーキテクチャ
**アーキテクチャ**: 分離型OAuth2プロバイダー
**JWT署名**: Hydra管理
**認証状態管理**: JWT Cookie + Hydra OAuth2 Sessions
**通信方式**: Hydra Admin API連携

---

## 目次

1. [JWT Cookie認証の設計](#1-jwt-cookie認証の設計)
2. [OAuth2 vs OpenID Connect (OIDC)について](#2-oauth2-vs-openid-connect-oidc-について)
3. [SSO認証フロー（OpenID Connect Authorization Code Flow）](#3-sso認証フローopenid-connect-authorization-code-flow)
4. [本番環境ネットワーク構成とセキュリティ設計](#4-本番環境ネットワーク構成とセキュリティ設計)
5. [HydraAdminClientサービスクラス](#5-hydraadminclientサービスクラス)
6. [OAuth2コントローラー設計（最適化後）](#6-oauth2コントローラー設計最適化後)
7. [Template Method による基底クラス設計](#7-template-method-による基底クラス設計)
8. [API設計](#8-api設計)
9. [実際のリダイレクトフロー詳細](#9-実際のリダイレクトフロー詳細)
10. [認証フローの実装詳細](#10-認証フローの実装詳細)
11. [Hydraグローバルログアウト システム解説](#11-hydraグローバルログアウト-システム解説)

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

### JWT Cookie方式の採用理由

#### 1. **SSO（Hydra連携）との相性**
```
ユーザー → RP → Hydra → IdP (リダイレクト)
                        ↑
                  Cookieが自動送信される
```
- **リダイレクトベース**のOAuth/OIDC フローでは、ブラウザが自動でCookieを送信
- JWT Bearerヘッダーはリダイレクト時に送信されない
- 従来セッションでも動作するが、React化時に問題

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
  # → SSO・API両方で認証失敗になる
end
```
- **ステートレス**（サーバーが状態を持たない）
- **Cookie制御**でログアウト時の即座無効化
- **HttpOnly設定**でXSS対策

### Rails実装
```ruby
# JWT生成・Cookie設定
jwt_token = JWT.encode(
  { user_id: user.id, exp: 30.minutes.from_now.to_i },
  Rails.application.secret_key_base
)

cookies.signed[:auth_token] = {
  value: jwt_token,
  httponly: true,
  secure: Rails.env.production?
}

# 認証チェック
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

## 2. OAuth2 vs OpenID Connect (OIDC) について

### 2.1. 技術的な実装
本プロジェクトは厳密には **OpenID Connect (OIDC)** を実装している：

- **OAuth2**: 認可フレームワーク（リソースアクセス権限管理）
- **OIDC**: OAuth2の拡張による認証プロトコル（ユーザー身元確認 + プロフィール情報）

### 2.2. ORY Hydraでの実装詳細
- ORY Hydraは **OpenID Connect Provider** として動作
- `scope=openid` - OIDC必須スコープを使用
- `response_type=code` - Authorization Code Flowを採用
- **IDトークン（JWT）** + **アクセストークン**を発行
- IdPから**ユーザー情報（claims）**を取得

### 2.3. 命名規則の統一
技術的にはOIDCですが、以下の理由で**OAuth2**表記で統一：

1. **ルート名**: `/oauth2/login` - Hydraの慣例に合わせる
2. **一般認識**: OAuth2の方が広く知られている
3. **実装レベル**: OAuth2 APIを拡張してOIDCを実現

**結論**: 実装は**OpenID Connect**、命名・ルーティングは**OAuth2**で統一

---

## 3. SSO認証フロー（OpenID Connect Authorization Code Flow）

### 3.1. Hydraによる認証状態管理

#### **重要: Hydraがメインの認証状態管理者**

Hydraは **ユーザー（ブラウザセッション）** と **RPクライアント** の組み合わせで認証状態を管理する。

```
Hydra内部の認証済み状態管理:
┌─────────────────────────────────────┐
│ User + Browser Session              │
│ ├─ RP1 Client: 認証済み            │
│ ├─ RP2 Client: 認証済み            │
│ └─ RP3 Client: 未認証              │
└─────────────────────────────────────┘
```

#### **SSOフローの分岐点**

**パターンA: Hydraに認証済み状態がある場合**
```
User → RP → Hydra (認証状態チェック) ✅ 認証済み発見
                ↓
          IdPへのリダイレクト無し
                ↓
          直接アクセストークン発行 → RP
          (ユーザーはIdP画面を見ない)
```

**パターンB: Hydraに認証済み状態がない場合**
```
User → RP → Hydra (認証状態チェック) ❌ 認証済み状態なし
                ↓
          IdPにリダイレクト → 認証実行
                ↓
          認証成功 → Hydraに状態保存 → RP
```

### 3.2. シーケンス図
```
User → RP → Hydra → IdP
 │      │     │      │
 │      │     │      ├─ ログイン状態チェック
 │      │     │      ├─ 認証処理（必要に応じて）
 │      │     │      └─ 同意処理
 │      │     │
 │      │     └─ 認証コード発行
 │      │
 │      └─ トークン取得・ユーザー情報取得
 │
 └─ ログイン完了
```

### 3.3. 詳細フロー

#### **フロー全体の分岐構造**

```
1. User → RP → Hydra: 認証リクエスト
          ↓
2. Hydra: 認証状態チェック
   ├─ [認証済み] → 即座にトークン発行 (IdP経由なし)
   └─ [未認証] → IdPにリダイレクト
                 ↓
3. IdP: ログイン処理 → Hydra状態更新 → トークン発行
```

#### **ケース1: Hydra認証済み（SSO発動）**
```
User: RPの「ログイン」ボタンクリック
  ↓
RP: Hydraに認証リクエスト
  GET /oauth2/auth?response_type=code&client_id=xxx&scope=openid
  ↓
Hydra: ユーザー+RPの認証状態確認 ✅ 認証済み発見
  ↓
Hydra: IdPを経由せず、直接RPのコールバックに認証コード送信
  GET /oauth2/callback?code={auth_code}&state={state}
  ↓
RP: アクセストークン取得・ユーザー情報取得
  ユーザー体感: 瞬時にログイン完了（IdP画面なし）
```

#### **ケース2: Hydra未認証（IdP認証実行）**

**2-1. 認証開始**
```
User: RPの「ログイン」ボタンクリック
  ↓
RP: Hydraに認証リクエスト
  GET /oauth2/auth?response_type=code&client_id=xxx&scope=openid
  ↓
Hydra: ユーザー+RPの認証状態確認 ❌ 認証済み状態なし
  ↓
Hydra: IdPのログイン画面にリダイレクト
  GET /oauth2/login?login_challenge={challenge}
```

**2-2. IdPでの処理（IdP内でもさらに分岐）**

##### **パターンA: IdPで未ログイン状態**
```
IdP: JWT Cookie認証チェック → 未ログイン
  ↓
IdP: ログイン画面表示
  ↓
User: メール・パスワード入力 + 2段階認証
  ↓
IdP: JWT Cookie設定 + Hydraにログイン成功通知
  PUT /admin/oauth2/auth/requests/login/accept?login_challenge={challenge}
```

##### **パターンB: IdPでログイン済み状態**
```
IdP: JWT Cookie認証チェック → JWT有効・ログイン済み
  ↓
IdP: ログイン画面をスキップ、即座にHydraに成功通知
  PUT /admin/oauth2/auth/requests/login/accept?login_challenge={challenge}
  ユーザー体感: IdPページは表示されるが、すぐに次に進む
```

**2-3. 同意・トークン発行**

同意フローは実装方針により**省略可能**である：

##### **パターンA: 自動同意（同意画面省略）**
```
IdP: Hydraにログイン成功通知完了
  ↓
Hydra: 同意をスキップし、直接RPのコールバックに認証コード送信
  GET /oauth2/callback?code={auth_code}&state={state}
  ↓
RP: アクセストークン取得・ユーザー情報取得
  ユーザー体感: 同意画面なし、シームレス
```

##### **パターンB: 明示的同意（同意画面表示）**
```
Hydra: IdPの同意画面にリダイレクト
  GET /oauth2/consent?consent_challenge={challenge}
  ↓
IdP: 同意画面表示
  ↓
User: スコープ内容確認・同意ボタンクリック
  ↓
IdP: Hydraに同意完了通知
  PUT /admin/oauth2/auth/requests/consent/accept?consent_challenge={challenge}
  ↓
Hydra: RPのコールバックに認証コード送信
  GET /oauth2/callback?code={auth_code}&state={state}
  ↓
RP: アクセストークン取得・ユーザー情報取得
  GET /api/v1/user_info (Bearer Token)
```

いずれの場合も最終的に：
```
Hydra: **ユーザー+RP認証状態を内部保存** ← 重要！
```

### 3.4. **役割分担の明確化**

| コンポーネント | 役割 | 管理する状態 |
|---------------|------|-------------|
| **Hydra** | **SSO状態管理者** | ユーザー+RPクライアントの認証状態 |
| **IdP** | **認証処理実行者** | 個別ユーザーの認証処理 |
| **RP** | **リソース要求者** | アプリ固有のセッション管理 |

### 3.5. **実際の動作確認方法**

#### **Hydraセッション有効確認**
```bash
# 1回目: 通常のSSO認証フロー
# 2回目: 同じブラウザで別RPまたは同RPに再ログイン
# 期待動作: IdP画面なし、瞬時ログイン
```

#### **Hydraセッション無効確認**
```bash
# グローバルログアウト実行後
# 期待動作: IdP認証画面表示
```

### 3.6. IdP実装エンドポイント

| エンドポイント | 役割 | 処理内容 | 実装必須度 |
|---------------|------|----------|----------|
| `GET /oauth2/login` | ログイン要求受付 | JWT Cookie確認、ログイン状態判定 | **必須** |
| `POST /oauth2/login` | 認証処理 | メール・パスワード・2FA認証 | **必須** |
| `GET /oauth2/consent` | 同意要求受付 | ユーザー情報共有の同意画面 | **省略可能** |
| `POST /oauth2/consent` | 同意処理 | 同意完了、Hydraに通知 | **省略可能** |
| `GET /api/v1/user_info` | ユーザー情報API | アクセストークン検証、ユーザー情報返却 | **必須** |

### 3.7. **同意フロー実装の判断基準**

#### **自動同意を選ぶ場合（同意画面省略）**
- **企業内システム**: 信頼できる内部アプリケーション同士
- **シームレスUX重視**: ユーザーフリクションを最小化
- **基本スコープのみ**: `openid`, `profile`, `email` 程度
- **実装**: `Oauth2::ConsentController`で自動的に`accept_consent_request`を呼び出し

#### **明示的同意を選ぶ場合（同意画面表示）**
- **外部連携**: サードパーティアプリケーションとの連携
- **プライバシー重視**: GDPR等のコンプライアンス要件
- **機密スコープ**: 個人情報や特権的なデータアクセス
- **実装**: ユーザーに同意画面を表示し、明示的な承認を取得

### 3.8. Cookie認証の利点

**シームレスなSSO体験:**
- **初回ログイン**: 通常の認証フロー
- **2回目以降**: JWT Cookieにより**自動でスキップ**
- **ログアウト後**: Cookie削除により再認証要求

```ruby
# IdPでの認証状態判定
def oauth2_login
  jwt_token = cookies.signed[:auth_token]

  if jwt_token && (user = verify_jwt(jwt_token))
    # ✅ ログイン済み → 即座にHydraに成功通知
    hydra_accept_login(params[:login_challenge], user)
  else
    # ❌ 未ログイン → ログイン画面表示
    session[:login_challenge] = params[:login_challenge]
    redirect_to login_path
  end
end
```

---

## 4. 本番環境ネットワーク構成とセキュリティ設計

### 4.1. SSO環境の標準ネットワーク構成

#### **一般的な3層構成**

```
[Internet] → [DMZ] → [Private Network]
     ↓        ↓           ↓
   ユーザー   LB/WAF    アプリケーション
```

#### **本番SSO推奨アーキテクチャ**

```
Internet (HTTPS)
    ↓
[Load Balancer / WAF]
    ↓ HTTPS/HTTP
[Reverse Proxy Layer]
    ↓ HTTP (内部)
┌─────────────────────────────────┐
│ Private Application Network     │
│                                 │
│ ┌─────┐  ┌─────────┐  ┌─────┐   │
│ │ IdP │  │ Hydra   │  │ RP  │   │
│ │:3000│  │Pub:4444 │  │:3001│   │
│ └─────┘  │Adm:4445 │  └─────┘   │
│     ↑    └─────────┘      ↑     │
│     └──── 内部HTTP通信 ───┘     │
└─────────────────────────────────┘
```

### 4.2. ORY Hydraの2つのAPIインターフェース

#### **Public API (OAuth2/OIDC標準)**
- **ポート**: 4444 (慣例)
- **役割**: OAuth2/OIDC プロトコル処理
- **公開**: **Internet公開必須**
- **アクセス元**: ブラウザ、RP、外部クライアント
- **プロトコル**: HTTPS必須

```bash
# 標準エンドポイント
GET  /oauth2/auth                           # 認証開始
POST /oauth2/token                          # トークン取得
GET  /oauth2/introspect                     # トークン検証
GET  /oauth2/sessions/logout                # ログアウト
GET  /.well-known/openid_configuration      # OIDC Discovery
```

#### **Admin API (管理・制御)**
- **ポート**: 4445 (慣例)
- **役割**: Hydra内部制御・管理
- **公開**: **絶対に外部公開禁止**
- **アクセス元**: IdPのみ
- **プロトコル**: 内部HTTP可

```bash
# 管理エンドポイント
GET  /admin/oauth2/auth/requests/login/{challenge}      # ログイン要求
PUT  /admin/oauth2/auth/requests/login/accept           # ログイン受入
GET  /admin/oauth2/auth/requests/consent/{challenge}    # 同意要求
PUT  /admin/oauth2/auth/requests/consent/accept         # 同意受入
GET  /admin/oauth2/auth/requests/logout/{challenge}     # ログアウト要求
PUT  /admin/oauth2/auth/requests/logout/accept          # ログアウト受入
```

### 4.3. 通信パターンとセキュリティレベル

#### **外部公開通信（HTTPS必須）**

| 通信 | 経路 | プロトコル | セキュリティ要件 |
|------|------|----------|---------------|
| ブラウザ → IdP | Internet | **HTTPS** | 認証情報保護、CSRF対策 |
| ブラウザ → RP | Internet | **HTTPS** | セッション保護 |
| ブラウザ → Hydra Public | Internet | **HTTPS** | OAuth2フロー保護 |
| RP → Hydra Public | Internet/VPN | **HTTPS** | トークン交換保護 |

#### **内部通信（HTTP可能）**

| 通信 | 経路 | プロトコル | セキュリティ考慮 |
|------|------|----------|---------------|
| RP → IdP API | 内部ネットワーク | HTTP可 | Bearer Token認証 |
| IdP → Hydra Admin | 内部ネットワーク | HTTP可 | ネットワーク分離必須 |

### 4.4. セキュリティ境界と脅威モデル

#### **信頼境界**

```
┌─────────────────┐ 信頼境界1: Internet
│   Internet      │ ↓ 脅威: MITM、盗聴、改ざん
└─────────────────┘ ↓ 対策: HTTPS、証明書検証
┌─────────────────┐
│   DMZ/LB        │ 信頼境界2: Load Balancer
└─────────────────┘ ↓ 脅威: DDoS、WAF bypass
┌─────────────────┐ ↓ 対策: Rate limiting、WAF
│ Private Network │ 信頼境界3: 内部ネットワーク
│ ┌─────────────┐ │ ↓ 脅威: 内部侵害、横移動
│ │ Hydra Admin │ │ ↓ 対策: ネットワーク分離
│ └─────────────┘ │
└─────────────────┘
```

#### **重要なセキュリティ原則**

1. **Hydra Admin API外部公開禁止**
   - 管理APIは内部ネットワークのみ
   - ファイアウォール・セキュリティグループで制限

2. **プロトコル分離**
   - 外部: HTTPS必須
   - 内部: HTTP可（暗号化オーバーヘッド削減）

3. **認証の多層防御**
   - ネットワーク分離
   - アプリケーション認証（Bearer Token）
   - 監査ログ

### 4.5. 本番環境での実装パターン

#### **Kubernetes環境**

```yaml
# nginx-ingress または istio
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  rules:
  - host: auth.company.com
    http:
      paths:
      - path: /
        backend:
          service:
            name: idp-service
            port: 3000
  - host: oauth.company.com
    http:
      paths:
      - path: /
        backend:
          service:
            name: hydra-public-service
            port: 4444
# hydra-admin-service は Ingress に含めない（内部のみ）
```

#### **AWS/GCP環境**

```
ALB/Cloud Load Balancer
├─ auth.company.com → ECS/GKE IdP
├─ app.company.com  → ECS/GKE RP
└─ oauth.company.com → ECS/GKE Hydra Public

内部サービス:
└─ hydra-admin.internal → Hydra Admin (外部アクセス不可)
```

#### **オンプレミス環境**

```nginx
# nginx.conf
upstream idp_backend {
    server idp1:3000;
    server idp2:3000;
}

upstream hydra_public {
    server hydra1:4444;
    server hydra2:4444;
}

# 外部公開
server {
    listen 443 ssl;
    server_name auth.company.com;
    location / { proxy_pass http://idp_backend; }
}

server {
    listen 443 ssl;
    server_name oauth.company.com;
    location / { proxy_pass http://hydra_public; }
}

# hydra admin は nginx で公開しない
```

### 4.6. セキュリティベストプラクティス

#### **必須セキュリティ設定**

1. **HTTPS強制**
   ```nginx
   # すべてのHTTPをHTTPSにリダイレクト
   server {
       listen 80;
       return 301 https://$server_name$request_uri;
   }
   ```

2. **セキュリティヘッダー**
   ```nginx
   add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
   add_header X-Frame-Options DENY;
   add_header X-Content-Type-Options nosniff;
   add_header Referrer-Policy strict-origin-when-cross-origin;
   ```

3. **Rate Limiting**
   ```nginx
   # OAuth2認証エンドポイント保護
   limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/m;
   location /oauth2/auth {
       limit_req zone=auth burst=5 nodelay;
   }
   ```

#### **監視・ログ設定**

```bash
# 重要なイベント監視
- OAuth2認証失敗
- 異常なトークン要求
- Admin API不正アクセス試行
- 認証スキップ異常

# ログ項目
- クライアントIP
- User-Agent
- OAuth2 state/code パラメータ
- レスポンス時間
- エラー詳細
```

### 4.7. 脅威と対策

#### **主要脅威**

| 脅威 | 対象 | 対策 |
|------|------|------|
| **Admin API外部露出** | Hydra Admin | ネットワーク分離、FW制限 |
| **トークン傍受** | OAuth2フロー | HTTPS強制、PKCE |
| **CSRF攻撃** | 認証フロー | State parameter、SameSite Cookie |
| **セッション固定** | 認証後 | セッション再生成 |
| **中間者攻撃** | 通信経路 | 証明書検証、HSTS |

#### **コンプライアンス考慮**

- **GDPR**: 同意フロー、データ保護
- **SOC2**: 監査ログ、アクセス制御
- **PCI DSS**: 暗号化、ネットワーク分離
- **OIDC Certification**: 標準準拠実装

この設計により、セキュアで運用しやすいSSO環境を構築できる。

---

## 5. HydraAdminClientサービスクラス

### 5.1 概要
`HydraAdminClient`は**IdPアプリケーション**と**ORY Hydra**の間の橋渡しを行う重要なサービスクラス。
HTTPartyを使用してHydra Admin APIとの通信を担当し、純粋にAPIクライアントとして機能する。

### 5.2. 主な機能

#### 1. **ログインフロー管理**
- `get_login_request(login_challenge)` - Hydraからのログイン要求詳細を取得
- `accept_login_request(login_challenge, subject)` - ユーザー認証成功時にHydraに通知
- `reject_login_request(login_challenge, error_description)` - ユーザー認証失敗時にHydraに通知

#### 2. **同意フロー管理**
- `get_consent_request(consent_challenge)` - Hydraからの同意要求詳細を取得
- `accept_consent_request(consent_challenge, grant_scope, identity_token_claims)` - ユーザー同意時にスコープとクレームを送信
- `reject_consent_request(consent_challenge, error_description)` - ユーザー拒否時にHydraに通知

#### 3. **ログアウトフロー管理**
- `get_logout_request(logout_challenge)` - Hydraからのログアウト要求を取得
- `accept_logout_request(logout_challenge)` - ログアウト処理完了をHydraに通知

## 6. OAuth2コントローラー設計（最適化後）

#### 継承による機能共有
- `authenticate` (POST /oauth2/login) - 第1段階認証
- `verification_form` (GET /oauth2/login/verify) - 認証コード入力画面
- `verify` (POST /oauth2/login/verify) - 第2段階認証
- 上記は全て**Sessions::LoginController**から継承

### 6.1. OAuth2::LoginController（Sessions継承型）
**役割**: Hydraからのログイン要求を受け取り、継承による認証処理を実行

```ruby
# app/controllers/oauth2/login_controller.rb
class Oauth2::LoginController < Sessions::LoginController
  # OAuth2フローのエントリーポイント
  def login
    login_challenge = params[:login_challenge]

    # チャレンジ検証
    login_request = HydraAdminClient.get_login_request(login_challenge)

    # セッションに保存し、直接ログインフォーム表示（リダイレクトなし）
    session[:login_challenge] = login_challenge
    render 'sessions/login/login'
  end

  protected

  # OAuth2固有のセッション処理をオーバーライド
  def handle_flow_specific_session
    @login_challenge = session.delete(:login_challenge)
  end

  # OAuth2のログイン成功処理をオーバーライド
  def handle_login_success(user)
    response = HydraAdminClient.accept_login_request(@login_challenge, user.id.to_s)
    redirect_to response['redirect_to']
  end
end
```

### 6.2. OAuth2::ConsentController
**役割**: ユーザー同意画面の表示と同意処理

```ruby
# app/controllers/oauth2/consent_controller.rb
class Oauth2::ConsentController < ApplicationController
  def consent
    # 1. consent_challengeパラメータを取得
    consent_challenge = params[:consent_challenge]

    # 2. HydraAdminClientで同意要求詳細を取得
    consent_request = HydraAdminClient.get_consent_request(consent_challenge)

    # 3. 同意画面を表示
    @consent_request = consent_request
    @requested_scopes = consent_request['requested_scope']
  end

  def accept
    # ユーザー同意後の処理
    # HydraAdminClient.accept_consent_request(...) を呼び出し
  end
end
```

### 6.3. OAuth2::LogoutController
**役割**: SSOログアウト処理

```ruby
# app/controllers/oauth2/logout_controller.rb
class Oauth2::LogoutController < ApplicationController
  def logout
    # SSOログアウト処理
    # HydraAdminClient.accept_logout_request(...) を呼び出し
  end
end
```

## 7. Template Method による基底クラス設計

IdPの認証システムでは、通常ログインとOAuth2ログインの共通部分を効率的に管理するため、**テンプレートメソッドパターン**を採用している。

- **親クラス**: `Sessions::LoginController` - 基本的な認証フローのテンプレートを提供
- **子クラス**: `Oauth2::LoginController` - OAuth2固有の処理をオーバーライド

| メソッド名 | 目的 | 親クラスデフォルト | 子クラスオーバーライド |
|------------|------|-------------------|----------------------|
| `authentication_success_redirect_path` | 1段階認証成功時のリダイレクト先 | `login_verify_path` | `oauth2_login_verify_path` |
| `handle_flow_specific_session` | フロー固有のセッション処理 | 何もしない | `login_challenge`の取得 |
| `handle_login_success` | ログイン成功時の処理 | root_pathリダイレクト | Hydra login request受け入れ |
| `set_form_urls` | フォームURL設定 | 何もしない | OAuth2専用URLセット |

このテンプレートメソッドパターンにより、複雑なOAuth2フローと通常ログインフローを効率的に管理し、保守しやすいコードベースを実現している。


### 7.1. Sessions::LoginController（基底クラス）

```ruby
# app/controllers/sessions/login_controller.rb
class Sessions::LoginController < ApplicationController
  # GET /login - ログインフォーム表示
  def login
  end

  # POST /login - 第1段階認証（メール・パスワード）
  def authenticate
    user = User.find_by(email: params[:email])

    if user&.authenticate(params[:password]) && user.activated?
      user.generate_auth_code!
      UserMailer.auth_code_email(user).deliver_now
      session[:login_user_id] = user.id
      redirect_to login_verification_path, notice: '認証コードをメールで送信しました。'
    else
      flash.now[:alert] = 'メールアドレスまたはパスワードが正しくありません。'
      render :login, status: :unprocessable_entity
    end
  end

  # POST /login/verify - 第2段階認証（認証コード検証）
  def verify
    user = User.find(session[:login_user_id])

    if user.auth_code_valid?(params[:auth_code])
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

  protected

  # 共通セッション処理
  def prepare_common_session(user)
    user.clear_auth_code!
    set_jwt_cookie(user)
    session.delete(:login_user_id)
  end

  # フロー固有セッション処理（サブクラスでオーバーライド可能）
  def handle_flow_specific_session
    # 通常フローでは何もしない
  end

  # ログイン成功処理（サブクラスでオーバーライド可能）
  def handle_login_success(user)
    redirect_to root_path, notice: 'ログインしました。'
  end
end
```

### 7.2. Template Method + 継承のメリット

1. **完全な画面共有**: `render 'sessions/login/login'`で既存ビューを再利用
2. **コード重複ゼロ**: 認証ロジックは基底クラスに1箇所のみ
3. **多態性**: 同じメソッド名で異なる後処理（WEB/OAuth2）
4. **保守性**: 共通部分の修正が全フローに自動反映
5. **拡張性**: 新しい認証フロー（SAML等）の追加が容易
6. **パフォーマンス**: 余分なHTTPリダイレクトを削除

### 7.3. 設計パターンの効果

- **Template Method**: 共通アルゴリズムと固有処理の分離
- **継承**: コードの再利用と多態性の実現
- **Strategy Pattern**: ログイン成功後の処理を動的に切り替え

OpenID Connectフローでも通常のWEBログインでも、ユーザーは全く同じ画面・操作でログインでき、開発者は保守性の高いコードを維持できる。

## 8. API設計

### 8.1 ユーザー情報取得API

```ruby
# app/controllers/api/v1/user_info_controller.rb
class Api::V1::UserInfoController < ApplicationController
  def show
    # OAuth2アクセストークン検証
    # ユーザー情報をJSON形式で返却（OIDCクレーム形式）
  end
end
```

**エンドポイント**: `GET /api/v1/user_info`
**認証**: OAuth 2.0 Bearer Token認証（RFC 6750準拠）
**レスポンス**: OIDCスタンダードクレーム（sub, email, name, birthdate等）

#### 8.2 Bearer Token認証の詳細

##### リクエスト仕様
```http
GET /api/v1/user_info HTTP/1.1
Host: localhost:3000
Authorization: Bearer {access_token}
Content-Type: application/json
```

##### 認証フロー
1. **RP**: Hydraからアクセストークンを取得
2. **RP**: `Authorization: Bearer {token}`ヘッダーでIdP APIに要求
3. **IdP**: Hydraの`/oauth2/introspect`でトークン検証
4. **IdP**: トークンのスコープに応じたユーザー情報を返却

##### なぜBearer Token認証なのか
- **OAuth2標準仕様（RFC 6750）**: OAuth2におけるAPI認証の国際標準
- **ステートレス**: サーバー間通信に適している（セッション不要）
- **API専用**: RESTful APIでの認証に特化した方式
- **セキュリティ**: アクセストークンは一時的で、スコープ制限あり

##### JWT CookieとBearer Tokenの使い分け
```ruby
# IdP内のWEBページ = JWT Cookie/Session認証
class UsersController < ApplicationController
  before_action :require_login  # session[:user_id]を確認
  # ブラウザ-サーバー間のセッション管理
end

# IdP内のAPI = Bearer Token認証
class Api::V1::UserInfoController < ApplicationController
  before_action :authenticate_with_access_token  # Authorization ヘッダーを確認
  # サーバー-サーバー間のAPI通信
end
```

##### スコープ別レスポンス例
```json
// scope="openid profile email" の場合
{
  "sub": "123",
  "name": "山田太郎",
  "email": "yamada@example.com",
  "email_verified": true,
  "birthdate": "1990-01-01"
}

// scope="openid email" の場合（profileスコープなし）
{
  "sub": "123",
  "email": "yamada@example.com",
  "email_verified": true
}
```

---

## 9. 実際のリダイレクトフロー詳細

### 9.1. ユーザー体験から見たフロー（最適化後）

```
1. RP → Hydra (ユーザーのブラウザリダイレクト)
   GET /oauth2/auth?response_type=code&client_id=...
   ユーザー体感: 「ログインボタンをクリック」

2. Hydra → IdP (ユーザーのブラウザリダイレクト)
   GET /oauth2/login?login_challenge=xyz123
   ユーザー体感: 「IdPのログイン画面が表示される」

   IdP内部処理: OAuth2::LoginController#login → 直接ログインフォーム表示
   render 'sessions/login/login' (リダイレクトなし)

3. ユーザーがログイン画面でフォーム送信
   POST /oauth2/login → OAuth2::LoginController#authenticate (継承)
   ユーザー体感: 「認証情報を入力して送信」

4. IdP → Hydra (API呼び出し - リダイレクトではない)
   HydraAdminClient.accept_login_request()
   ユーザー体感: 「処理中...」

5. IdP → ユーザーブラウザ (リダイレクト)
   redirect_to response['redirect_to'] # Hydraが指定したURL
   ユーザー体感: 「同意画面またはRPに戻る」

6. ユーザーブラウザ → Hydra → RP (自動リダイレクト)
   最終的にRPのコールバックURLへ
   ユーザー体感: 「RPサイトにログイン完了」
```

### 9.2. リダイレクトの種類（最適化後）

- **1,2,5,6**: **ユーザーのブラウザが実際に移動**（URL変更あり）
- **4**: **サーバー間のAPI通信**（リダイレクトではない、バックグラウンド処理）

### 9.3. 最適化による改善点

1. **削除されたリダイレクト**: IdP内部の余分なリダイレクトを削除
2. **Template Method継承**: 共通認証ロジックを継承で再利用
3. **直接レンダリング**: `render 'sessions/login/login'`でビュー共有
4. **パフォーマンス向上**: HTTPリダイレクト回数を削減

### 9.4. 重要なポイント

1. **ユーザーが体感するリダイレクト**: `RP → IdP → 同意画面 → RP` の実質3回
2. **最短経路**: 無駄なHTTPリダイレクトを排除
3. **コード保守性**: Template Methodパターンで共通化
4. **ビュー共有**: 既存テンプレートを完全再利用

### 9.5. コントローラーの役割分担（最適化後）

- **Sessions::LoginController**: 認証処理の「基底クラス」（Template Methodパターン）
  - 共通認証ロジック（メール・パスワード・2段階認証）
  - 抽象メソッド定義（handle_login_success等）

- **OAuth2::LoginController**: Hydra専用「特化クラス」（Sessions継承）
  - `login_challenge`の受け取りと検証
  - OAuth2固有のセッション処理
  - Hydra連携処理（accept_login_request）

- **OAuth2::ConsentController**: 同意処理の専用コントローラー

---

## 10. 認証フローの実装詳細

IdPの認証システムでは、通常ログインとOAuth2ログインの共通部分を効率的に管理するため、**テンプレートメソッドパターン**を採用している。

- **親クラス**: `Sessions::LoginController` - 基本的な認証フローのテンプレートを提供
- **子クラス**: `Oauth2::LoginController` - OAuth2固有の処理をオーバーライド

### 10.1. Sessions側認証フロー（通常ログイン）

#### 1 GET /login - ログインフォーム表示
```
Sessions::LoginController#login
└── フォーム表示のみ
```

#### 2. POST /login - 第1段階認証（メール・パスワード）
```
Sessions::LoginController#authenticate
├── ユーザー検索・パスワード認証
├── 認証コード生成・メール送信
├── セッション一時保存 (session[:login_user_id])
└── リダイレクト先決定
    └── authentication_success_redirect_path [テンプレートメソッド]
        └── login_verify_path (デフォルト)
```

#### 3. GET /login/verify - 認証コード入力画面
```
Sessions::LoginController#verification_form
├── セッションから一時ユーザー取得
├── 認証コード期限切れチェック
└── フォーム表示
```

#### 4. POST /login/verify - 第2段階認証（認証コード検証）
```
Sessions::LoginController#verify
├── 認証コード検証
├── 成功時処理
│   ├── prepare_common_session(user) [共通処理]
│   │   ├── 認証コードクリア
│   │   ├── JWT Cookie設定
│   │   └── 一時セッション削除
│   ├── handle_flow_specific_session [テンプレートメソッド]
│   │   └── （通常フローでは何もしない）
│   └── handle_login_success(user) [テンプレートメソッド]
│       └── root_path へリダイレクト (デフォルト)
└── 失敗時処理
    └── handle_login_error
```

### 10.2. OAuth2側認証フロー（SSOログイン）

#### 1. GET /oauth2/login?login_challenge=... - OAuth2エントリーポイント
```
Oauth2::LoginController#login [親クラス継承]
├── login_challenge バリデーション
├── HydraAdminClient.get_login_request(login_challenge)
├── セッション保存 (session[:login_challenge])
├── 自動ログイン判定
│   ├── should_auto_accept_login? → current_user.present?
│   ├── [Yes] auto_accept_login
│   │   ├── HydraAdminClient.accept_login_request
│   │   └── Hydra redirect_to URL へリダイレクト
│   └── [No] show_login_form
│       ├── set_form_urls [テンプレートメソッド オーバーライド]
│       │   └── @login_form_url = oauth2_login_path
│       └── render 'sessions/login/login'
└── エラーハンドリング
```

#### 2. POST /oauth2/login - 第1段階認証（メール・パスワード）
```
Oauth2::LoginController#authenticate [親クラス オーバーライド]
└── super [親クラスのテンプレートメソッドを活用]
    ├── ユーザー検索・パスワード認証
    ├── 認証コード生成・メール送信
    ├── セッション一時保存 (session[:login_user_id])
    └── リダイレクト先決定
        └── authentication_success_redirect_path [オーバーライド]
            └── oauth2_login_verify_path
```

#### 3. GET /oauth2/login/verify - 認証コード入力画面
```
Oauth2::LoginController#verification_form [親クラス オーバーライド]
├── super [親クラス処理実行]
│   ├── セッションから一時ユーザー取得
│   ├── 認証コード期限切れチェック
│   └── フォーム表示準備
└── set_oauth2_verify_form_url
    └── @verify_form_url = oauth2_login_verify_path
```

#### 4. POST /oauth2/login/verify - 第2段階認証（認証コード検証）
```
Oauth2::LoginController [親クラス Sessions::LoginController#verify を継承]
├── 認証コード検証
├── 成功時処理
│   ├── prepare_common_session(user) [共通処理]
│   │   ├── 認証コードクリア
│   │   ├── JWT Cookie設定
│   │   └── 一時セッション削除
│   ├── handle_flow_specific_session [オーバーライド]
│   │   └── @login_challenge = session.delete(:login_challenge)
│   └── handle_login_success(user) [オーバーライド]
│       └── accept_hydra_login_request(user)
│           ├── HydraAdminClient.accept_login_request(@login_challenge, user.id)
│           └── Hydra redirect_to URL へリダイレクト
└── 失敗時処理
    └── handle_login_error [親クラス処理]
```

### 10.3. 同意フロー（OAuth2のみ）

#### 1. GET /oauth2/consent?consent_challenge=...
```
Oauth2::ConsentController#consent
├── consent_challenge バリデーション
├── HydraAdminClient.get_consent_request(consent_challenge)
├── 自動同意判定
│   ├── should_auto_consent?
│   │   ├── Hydra skip フラグチェック
│   │   ├── 信頼クライアントチェック
│   │   └── 基本スコープのみチェック
│   ├── [Yes] accept_consent_automatically
│   │   ├── build_user_claims(current_user, granted_scopes)
│   │   ├── HydraAdminClient.accept_consent_request
│   │   └── Hydra redirect_to URL へリダイレクト
│   └── [No] 同意画面表示
└── エラーハンドリング
```

#### 2. POST /oauth2/consent/accept
```
Oauth2::ConsentController#accept
├── consent_challenge バリデーション
├── HydraAdminClient.get_consent_request(consent_challenge)
├── granted_scopes 決定
├── build_user_claims(current_user, granted_scopes)
├── HydraAdminClient.accept_consent_request
└── Hydra redirect_to URL へリダイレクト
```

---

## 11. Hydraグローバルログアウト システム解説

## 概要

このシステムでは、**設定可能なログアウト戦略**により、IdPからのログアウト時に以下の2つの動作を選択できる：

- **ローカルログアウト** (`LOGOUT_STRATEGY=local`): IdPセッションのみ破棄
- **グローバルログアウト** (`LOGOUT_STRATEGY=global`): IdP + Hydra + 全RP セッション破棄

## グローバルログアウトの仕組み

### 11.1. アーキテクチャ概要

```
[IdP]     [Hydra]     [RP1] [RP2] [RP3]
  |         |           |     |     |
  |-- SSO Session Manager ---|     |     |
  |         |           |     |     |
  +-- Global Logout -->-+     |     |
            |                 |     |
            +-- Session Clear-+     |
                      |             |
                      +-- Session Clear
```

### 11.2. コンポーネント間の役割

#### **IdP (Identity Provider)**
- **役割**: グローバルログアウトの起点
- **責任**: ローカルセッション破棄 + Hydraログアウト要求送信
- **実装**: `Sessions::LoginController#destroy` + 環境変数制御

#### **Hydra (OpenID Connect Provider)**
- **役割**: SSOセッション管理とグローバルログアウト調整
- **責任**: セッション状態管理、IdPコールバック処理、最終リダイレクト
- **設定**: `post_logout_redirect` による最終着地点指定

#### **RP (Relying Party)**
- **役割**: アクセストークン期限切れによる自然なログアウト
- **動作**: 次回API呼び出し時にトークンエラーで自動ログアウト検出

## フロー詳細

### 11.3.1. グローバルログアウトフロー

```
1. ユーザーがIdPでログアウトボタンをクリック
   ↓
2. IdP: Sessions::LoginController#destroy
   - perform_local_logout() でIdPセッションクリア
   - LOGOUT_STRATEGY=global を確認
   ↓
3. IdP → Hydra: グローバルログアウト要求
   GET http://localhost:4444/oauth2/sessions/logout
   ↓
4. Hydra: SSOセッション破棄処理開始
   - 内部セッションデータをクリア
   - logout_challenge生成
   ↓
5. Hydra → IdP: ログアウトコールバック
   GET http://localhost:3000/oauth2/logout?logout_challenge=...
   ↓
6. IdP: Oauth2::LogoutController#logout
   - get_logout_request()でチャレンジ詳細取得
   - perform_local_logout()で追加クリーンアップ
   - accept_logout_request()でHydraに完了通知
   ↓
7. Hydra → IdP: 最終リダイレクト
   redirect_to response['redirect_to']
   ↓
8. IdP: トップページ表示（ログアウト完了）
```

### 11.3.2. ローカルログアウトフロー（比較用）

```
1. ユーザーがIdPでログアウトボタンをクリック
   ↓
2. IdP: Sessions::LoginController#destroy
   - perform_local_logout() でIdPセッションクリア
   - LOGOUT_STRATEGY=local を確認
   ↓
3. IdP: 直接トップページにリダイレクト
   （Hydraセッションは保持される）
```

## 実装詳細

### 11.4.1. 環境変数設定

```bash
# .env.local
LOGOUT_STRATEGY=global  # または local
```

### 11.4.2. IdP側実装

```ruby
# app/controllers/sessions/login_controller.rb
def destroy
  if current_user
    perform_local_logout

    if global_logout_enabled?
      hydra_logout_url = "#{ENV['HYDRA_PUBLIC_URL']}/oauth2/sessions/logout"
      redirect_to hydra_logout_url, allow_other_host: true
    else
      redirect_to root_path, notice: 'ログアウトしました'
    end
  end
end

def global_logout_enabled?
  ENV.fetch('LOGOUT_STRATEGY', 'local') == 'global'
end
```

### 11.4.3. OAuth2ログアウトコントローラー

```ruby
# app/controllers/oauth2/logout_controller.rb
def logout
  logout_challenge = params[:logout_challenge]

  logout_request = HydraAdminClient.get_logout_request(logout_challenge)
  perform_local_logout
  response = HydraAdminClient.accept_logout_request(logout_challenge)

  redirect_to response['redirect_to'], allow_other_host: true
end
```

### 11.4.4. Hydra設定

```yaml
# docker/hydra/hydra.yml
urls:
  logout: http://localhost:3000/oauth2/logout
  post_logout_redirect: http://localhost:3000/
```

## 検証方法

### 11.5.1. グローバルログアウト動作確認

#### **事前準備**
```bash
# .env.localでグローバルログアウト有効化
LOGOUT_STRATEGY=global
```

#### **検証手順**

**Step 1: SSOログイン完了**
1. RP (`http://localhost:3001`) → SSOログイン
2. IdP認証完了 → RPにログイン状態で戻る

**Step 2: Hydraセッション有効性確認**
1. 新しいタブで RP → SSOログイン再試行
2. **期待動作**: IdP認証画面なし（自動ログイン）
3. → **Hydraセッション有効**の証明

**Step 3: グローバルログアウト実行**
1. IdP (`http://localhost:3000`) でログアウトボタンクリック
2. **期待動作**: IdPトップページにリダイレクト

**Step 4: Hydraセッション破棄確認**
1. RP でローカルログアウト実行（RPセッションクリア）
2. RP → SSOログイン再試行
3. **期待動作**: IdP認証画面表示（メール・パスワード入力要求）
4. → **Hydraセッション破棄**の証明

### 11.5.2. 重要な確認ポイント

#### **Hydraセッション状態の判定基準**

| 状態 | SSO再実行時の動作 | 意味 |
|------|------------------|------|
| セッション有効 | IdP認証画面スキップ | Hydraがユーザーを既認証と判定 |
| セッション無効 | IdP認証画面表示 | Hydraがユーザー認証を要求 |

#### **RP側のセッション状態について**

**重要**: RPは独自セッションを持つため、Hydraセッション破棄後も一時的にログイン状態を保持する。これは正常な動作である。

- **RP継続ログイン**: JWTクッキーが有効なため
- **自然なログアウト**: 次回IdP API呼び出し時にアクセストークンエラーで検出
- **検証方法**: RPローカルログアウト → SSO再実行で確認

### 11.5.3. ログアウト戦略比較

#### **ローカルログアウト** (`LOGOUT_STRATEGY=local`)
```
IdPログアウト → IdPセッションのみクリア
結果: RPでSSO再実行時、自動ログイン（Hydraセッション保持）
```

#### **グローバルログアウト** (`LOGOUT_STRATEGY=global`)
```
IdPログアウト → IdP + Hydraセッションクリア
結果: RPでSSO再実行時、IdP再認証要求（Hydraセッション破棄）
```

## セキュリティ考慮事項

### 11.6.1. セッション管理の分離

- **IdPセッション**: IdP内でのログイン状態（JWTクッキー）
- **Hydraセッション**: SSO全体でのログイン状態（OAuth2セッション）
- **RPセッション**: RP内でのログイン状態（独立管理）

### 11.6.2. トークン有効期限

- **アクセストークン**: 短期間（通常1時間以内）
- **IDトークン**: 認証情報の証明書（検証用）
- **セッション**: アプリケーション固有の管理

### 11.6.3. 推奨設定

**企業内システム**: `LOGOUT_STRATEGY=global`
- セキュリティ重視
- 共有端末での確実なログアウト

**一般消費者向け**: `LOGOUT_STRATEGY=local`
- UX重視
- ユーザーが複数サービスを使い分け

このシステムにより、セキュリティ要件に応じた柔軟なログアウト戦略を実現している。

---

## まとめ

ORY Hydra版実装は、分離型アーキテクチャにより高度なセキュリティとスケーラビリティを実現している。Doorkeeper版との主な違いは：

### **Hydra版の利点**
- **分離アーキテクチャ**: IdPとOAuth2サーバーの独立運用
- **エンタープライズ対応**: 高度なセキュリティ・スケーラビリティ
- **標準準拠**: OAuth2/OIDC完全準拠の専用サーバー
- **JWKS標準実装**: 鍵管理の標準仕様準拠

### **技術的特徴**
- **Template Methodパターン**: OAuth2専用コントローラーによる柔軟な拡張
- **Admin API連携**: HydraAdminClientによるサーバー間通信
- **グローバルログアウト**: 企業レベルのセキュリティ要件対応
- **Container Network**: 内部/外部URL分離によるセキュアな通信

### **考慮事項**
- **複雑性**: 複数サービス間の連携管理が必要
- **学習コスト**: OAuth2/OpenID Connect専門知識が必須
- **運用負荷**: Hydraサーバー独立運用のオペレーション
- **デバッグ**: 複数サービス跨ぎでの障害解析

### **推奨用途**
- **大規模エンタープライズ**: 厳格なセキュリティ・コンプライアンス要件
- **マイクロサービス**: 認証基盤の独立スケーリング
- **多様なクライアント**: モバイル・SPA・サーバーサイド混在環境
- **長期運用システム**: 将来の拡張性・保守性重視

### **Doorkeeper版との使い分け**

| 要件 | Hydra版 | Doorkeeper版 |
|------|---------|---------------|
| **システム規模** | 大規模・エンタープライズ | 中小規模・プロトタイプ |
| **チーム構成** | OAuth2専門チーム | Rails開発チーム |
| **セキュリティ要件** | 最高レベル | 標準レベル |
| **運用体制** | 専任インフラチーム | アプリ開発チーム兼任 |
| **開発スピード** | 慎重な設計・実装 | 迅速な機能追加 |

この実装ノートにより、ORY Hydra版SSO認証システムの技術アーキテクチャと運用ベストプラクティスを包括的に理解できる。
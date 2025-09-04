# Rails 8.0 SSO IdP HTTPS環境構築完全ガイド

**作成日**: 2025-09-02
**対象**: Phase 4a-2 HTTPS環境構築 + OAuth2 SSOセッションスキップ機能
**結果**: ✅ 完全達成

## 🎯 プロジェクト概要

ORY Hydra v2.3.0を使用したRails 8.0 SSO Identity Provider（IdP）のHTTPS環境構築。nginx直接SSL終端によるリバースプロキシ構成で、外部RPからのOAuth2 SSOでのセッションスキップ機能を完全実現。

### 🏗️ 最終アーキテクチャ
```
[RP: localhost:3001] --HTTP--> [nginx: idp.localhost:443] --HTTPS--> [Rails: web:3000]
                                         |                            [Hydra: hydra:4444]
                                         |                            [MySQL: db:3306]
                                         +---> SSL終端               [Valkey: valkey:6379]
```

## 📋 実装フェーズ完全記録

### Phase 1: SSL証明書生成とnginx SSL設定

#### 1.1 SSL証明書生成
```bash
# 自己署名証明書の生成
mkdir -p docker/nginx/ssl
cd docker/nginx/ssl

# 秘密鍵生成
openssl genrsa -out localhost.key 2048

# 証明書署名要求生成
openssl req -new -key localhost.key -out localhost.csr \
  -subj "/C=JP/ST=Tokyo/L=Tokyo/O=Dev/OU=Dev/CN=idp.localhost"

# 自己署名証明書生成
openssl x509 -req -days 365 -in localhost.csr -signkey localhost.key -out localhost.crt
```

#### 1.2 nginx SSL設定
**ファイル**: `docker/nginx/nginx.conf`

```nginx
# HTTPからHTTPSへのリダイレクト
server {
    listen 80;
    server_name idp.localhost;
    return 301 https://$server_name$request_uri;
}

# HTTPS設定
server {
    listen 443 ssl http2;
    server_name idp.localhost;

    ssl_certificate /etc/nginx/ssl/localhost.crt;
    ssl_certificate_key /etc/nginx/ssl/localhost.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # セキュリティヘッダー
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # 共通proxy設定
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port 443;
    proxy_redirect off;
    proxy_cookie_flags ~ secure;


    # IdP Rails アプリケーションの認証関連パス (port 3000)
    location /auth/ {
        proxy_pass http://web:3000;
    }

    # Hydra Public API - OAuth2エンドポイント (port 4444)
    location /oauth2/ {
        proxy_pass http://hydra:4444;
    }

    # Hydra の .well-known エンドポイント
    location /.well-known/ {
        proxy_pass http://hydra:4444;
    }

    # Hydra UserInfo エンドポイント
    location /userinfo {
        proxy_pass http://hydra:4444/userinfo;
    }

    # IdP Rails アプリケーションのその他のパス (port 3000)
    location / {
        proxy_pass http://web:3000;
    }
}
```

**重要ポイント**:
- `proxy_cookie_flags ~ secure;` - すべてのクッキーにSecureフラグ自動付与
- `location /.well-known/` - Hydra Discovery エンドポイント正常動作
- `proxy_set_header Host $host` - 動的ホストヘッダー設定

### Phase 2: IdP側HTTPS設定とRails設定更新

#### 2.1 Rails HTTPS設定
**ファイル**: `config/environments/development.rb`

```ruby
# HTTPS環境の条件分岐設定
if ENV['HOST_PORT'] == '443'
  # HTTPS環境設定
  config.force_ssl = true
  config.ssl_options = { redirect: false }  # nginxでリダイレクト処理
  config.hosts = ['idp.localhost']

  # URL生成設定（HTTPS）
  Rails.application.routes.default_url_options = {
    host: ENV.fetch('HOST_NAME', 'idp.localhost'),
    protocol: 'https'
  }
else
  # HTTP環境設定（既存）
  Rails.application.routes.default_url_options = {
    host: ENV.fetch('HOST_NAME', 'localhost'),
    port: ENV.fetch('HOST_PORT', '8080').to_i
  }
end
```

#### 2.2 Session Store設定
**ファイル**: `config/initializers/session_store.rb`

```ruby
# HTTPS環境でのセッションCookieセキュア設定
if ENV['HOST_PORT'] == '443'
  Rails.application.config.session_store :cache_store,
    expire_after: 90.minutes,
    key: "_idp_session",
    secure: true,    # HTTPS必須
    httponly: true   # XSS防御
else
  # HTTP環境設定（既存）
  Rails.application.config.session_store :cache_store,
    expire_after: 90.minutes,
    key: "_idp_session"
end
```

#### 2.3 環境変数設定
**ファイル**: `.env.local`

```bash
# URL Generation Settings (HTTPS環境)
HOST_NAME=idp.localhost
HOST_PORT=443

# ORY Hydra Configuration (HTTPS環境)
HYDRA_PUBLIC_URL=https://idp.localhost
HYDRA_ADMIN_URL=http://hydra:4445
```

### Phase 3: Hydra HTTPS設定とOAuth2エンドポイント確認

#### 3.1 Hydra設定更新
**ファイル**: `docker/hydra/hydra.yml`

```yaml
urls:
  self:
    issuer: https://idp.localhost
  login: https://idp.localhost/auth/login
  consent: https://idp.localhost/auth/consent
  logout: https://idp.localhost/auth/logout
  post_logout_redirect: https://idp.localhost/

serve:
  cookies:
    domain: idp.localhost
    secure: true
    same_site_mode: Lax
```

#### 3.2 Discovery エンドポイント確認
```bash
curl -k https://idp.localhost/.well-known/openid-configuration
```

**期待レスポンス**:
```json
{
  "issuer": "https://idp.localhost",
  "authorization_endpoint": "https://idp.localhost/oauth2/auth",
  "token_endpoint": "https://idp.localhost/oauth2/token",
  "userinfo_endpoint": "https://idp.localhost/userinfo",
  ...
}
```

## 🐛 発生した問題と解決策

### 問題1: Session Cookie Secureフラグ不足

**症状**: HTTPSアクセス時にRails sessionが無効

**原因**: `config/initializers/session_store.rb`でsecure設定なし

**解決策**: HTTPS環境でのsecure設定追加
```ruby
if ENV['HOST_PORT'] == '443'
  Rails.application.config.session_store :cache_store,
    secure: true,
    httponly: true
end
```

### 問題2: OAuth2 Token取得時の301リダイレクトエラー

**症状**: RP側からトークンエンドポイントアクセス時に301エラー

**原因**: RP側の内部通信設定がHTTP
```bash
# RP .env.local
HYDRA_PUBLIC_URL_INTERNAL=http://idp-nginx-1:80  # ← HTTP
```

**解決策**: HTTPS内部通信設定
```bash
# RP .env.local
HYDRA_PUBLIC_URL_INTERNAL=https://idp-nginx-1:443  # ← HTTPS
SSL_VERIFY=false  # 自己署名証明書対応
```

### 問題3: JWT Cookie Secureフラグ問題（最重要）

**症状**: OAuth2フロー時に`current_user`が常に`nil`

**デバッグログ**:
```
=== OAuth2 Auto-Accept Check ===
current_user: nil
cookies[:auth_token]: nil        ← JWTクッキーが送信されない
cookies: {"_idp_session" => "...", ...}  ← Rails sessionは正常
should_auto_accept_login? result: false
```

#### 3.1 環境変数不一致問題

**根本原因**: 環境変数読み込み優先順位
```bash
# Docker Composeの読み込み順序
.env (HOST_PORT=8443) → .env.local (HOST_PORT=443)
# .envが優先 → Caddyの古い設定が残存
```

**影響**:
```ruby
# application_controller.rb
secure_flag = Rails.env.production? || ENV['HOST_PORT'] == '443'
# ENV['HOST_PORT'] = '8443' → '443'と不一致 → secure_flag = false
```

**解決策**: `.env`ファイル修正
```bash
# .env
# 修正前
HOST_PORT=8443  # Caddy時代の残存設定

# 修正後
HOST_PORT=443   # nginx direct SSL port
```

#### 3.2 SameSite制限によるCross-Origin問題

**症状**: Cross-Origin遷移時にJWTクッキーが送信されない

**原因**: SameSite=Strict設定
```ruby
# application_controller.rb
cookies[:auth_token] = {
  secure: true,
  same_site: :strict  # ← Cross-Originで送信拒否
}
```

**Cross-Originフロー**:
```
RP (http://localhost:3001) → IdP (https://idp.localhost)
異なるプロトコル + 異なるホスト = Cross-Origin
SameSite=Strict → Cookieブロック
```

**解決策**: SameSite=Lax設定
```ruby
cookies[:auth_token] = {
  secure: true,
  same_site: :lax  # ← Cross-Originでも送信可能
}
```

**設定比較**:
| Setting | Same-Origin | Cross-Origin | OAuth2 SSO |
|---------|-------------|--------------|-------------|
| `:strict` | ✅ 送信 | ❌ ブロック | ❌ 失敗 |
| `:lax` | ✅ 送信 | ✅ 送信 | ✅ 成功 |

**重要な発見**:
- **IdP内タブ移動**: Same-Origin → `auth_token`正常送信 → ログイン状態維持
- **RP→IdP遷移**: Cross-Origin → SameSite=Strict時に`auth_token`ブロック → セッションスキップ失敗
- **Rails Session**: デフォルトでSameSite=Lax → Cross-Originでも送信される

## 🔧 最終的なファイル設定

### JWT Cookie設定（最終版）
**ファイル**: `app/controllers/application_controller.rb`

```ruby
def set_jwt_cookie(user)
  jwt_token = JWT.encode(
    { user_id: user.id, exp: JwtConfig::TOKEN_EXPIRATION_MINUTES.minutes.from_now.to_i },
    Rails.application.secret_key_base
  )

  secure_flag = Rails.env.production? || ENV['HOST_PORT'] == '443'

  cookies[:auth_token] = {
    value: jwt_token,
    httponly: true,
    secure: secure_flag,     # HTTPS環境でtrue
    same_site: :lax          # Cross-Origin対応
  }
end
```

### 環境変数設定（最終版）
**ファイル**: `.env`
```bash
HOST_PORT=443  # nginx direct SSL port
```

**ファイル**: `.env.local`
```bash
HOST_NAME=idp.localhost
HOST_PORT=443
HYDRA_PUBLIC_URL=https://idp.localhost
```

**ファイル**: `rp/.env.local`
```bash
HYDRA_PUBLIC_URL=https://idp.localhost
HYDRA_PUBLIC_URL_INTERNAL=https://idp-nginx-1:443
SSL_VERIFY=false
```

## 🎯 動作確認手順

### 1. 基本HTTPS動作確認
```bash
# SSL証明書確認
curl -k -I https://idp.localhost

# Discovery エンドポイント
curl -k https://idp.localhost/.well-known/openid-configuration

# IdP認証画面
curl -k https://idp.localhost/auth/login
```

### 2. SSO動作確認
1. **IdP側**: `https://idp.localhost` でログイン
2. **RP側**: `http://localhost:3001` → "Login with SSO"
3. **期待動作**: ID+パスワード入力なしで直接同意画面またはコールバック

### 3. デバッグ確認
```bash
# IdP側ログ確認
docker-compose logs web --tail=50 | grep "OAuth2 Auto-Accept"

# 成功時のログ
# === OAuth2 Auto-Accept Check ===
# current_user: #<User id: XX, ...>
# cookies[:auth_token]: present
# should_auto_accept_login? result: true
```

## 📊 成果・学習事項

### 技術的成果
1. **nginx直接SSL終端構成の確立**
2. **Rails HTTPS環境の完全対応**
3. **ORY Hydra v2.3.0のHTTPS統合**
4. **Cross-Origin OAuth2 SSOの実現**
5. **セッションスキップ機能の完全動作**

### 学習した技術課題
1. **環境変数の層構造管理**（Docker Compose → .env → .env.local）
2. **Cookie SameSite制限の詳細理解**（Strict vs Lax）
3. **nginx proxy設定の最適化**（Header, Cookie Flags）
4. **HTTPS環境でのProxy設定**（Header, Cookie Flags）
5. **JWT認証 vs Session認証の使い分け**

### セキュリティ考慮事項
- ✅ **SSL/TLS設定**: TLS 1.2/1.3対応
- ✅ **Cookie Security**: Secure + HttpOnly + SameSite=Lax
- ✅ **CSRF保護**: Rails標準機能 + セキュリティヘッダー
- ✅ **Proxy Security**: 適切なHeader転送
- ✅ **JWT Security**: 適切な有効期限設定

### Cookie設定の最終判断
```ruby
# Rails Session Cookie (自動設定)
{
  secure: true,      # HTTPS環境で自動設定
  httponly: true,    # XSS防御
  same_site: :lax    # デフォルト（Cross-Origin対応）
}

# JWT Auth Cookie (手動設定)
{
  secure: true,      # HTTPS環境で明示設定
  httponly: true,    # XSS防御
  same_site: :lax    # Cross-Origin OAuth2対応（:strictから変更）
}
```

## 🚀 今後の拡張ポイント

1. **nginx Host header最適化** - 固定値から動的値への完全移行
2. **本番SSL証明書対応** - Let's Encrypt等の正式証明書
3. **パフォーマンス最適化** - キャッシュ戦略、圧縮設定
4. **監視・ログ強化** - アクセスログ、エラー追跡
5. **セキュリティ強化** - レート制限、WAF導入検討

---

**🎉 Phase 4a-2: HTTPS環境構築 + OAuth2 SSOセッションスキップ機能 完全達成！**

**作成者**: Claude Code Assistant
**完了日**: 2025-09-02
**プロジェクト**: Rails 8.0 SSO Identity Provider with ORY Hydra v2.3.0
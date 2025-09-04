# ORY Hydra v2.3.0 完全セットアップガイド

**最終更新**: 2025-09-03  
**対象環境**: Rails 8.0 + ORY Hydra v2.3.0 + Docker Compose  
**セッション成果**: Cross-Domain SSO + HTTPS環境 + セッションキャッシュ完全理解

---

## 🎯 概要

このガイドでは、ORY Hydra v2.3.0を使用したSSO（Single Sign-On）システムの完全なセットアップ手順を解説します。開発環境から本番環境まで、セキュアで実用的なOAuth2 IdP（Identity Provider）の構築方法を詳述します。

### 🏗️ アーキテクチャ

```
┌─────────────────┐    OAuth2     ┌─────────────────┐
│   RP Application│◄─────────────►│  IdP Application│
│ (localhost:3443)│   HTTPS       │ (idp.localhost) │
└─────────────────┘               └─────────────────┘
                                           │
                                    ┌─────────────────┐
                                    │  ORY Hydra      │
                                    │  OAuth2 Engine  │
                                    └─────────────────┘
```

---

## 🔧 Hydra基本セットアップ

### 1. Docker Compose設定

```yaml
# docker-compose.yml
hydra:
  image: oryd/hydra:v2.3.0
  environment:
    - DSN=${HYDRA_DSN}
  ports:
    - "4444:4444" # Public API
    # Admin API (4445) は内部通信のみ
  volumes:
    - ./docker/hydra:/etc/config
  entrypoint: >
    sh -c "
      echo 'Hydra v2.3.0: Running migrations...' &&
      hydra migrate sql -c /etc/config/hydra.yml -e --yes &&
      echo 'Hydra v2.3.0: Starting server...' &&
      hydra serve -c /etc/config/hydra.yml all
    "
```

### 2. 基本設定ファイル

```yaml
# docker/hydra/hydra.yml
serve:
  public:
    port: 4444
    host: 0.0.0.0
  admin:
    port: 4445
    host: 0.0.0.0
  cookies:
    same_site_mode: None  # Cross-Domain対応の必須設定
    same_site_legacy_workaround: true
    secure: true  # HTTPS環境では必須

# 開発環境では必ずコメントアウトまたは削除
# dev: true  # ← これがあるとセッションキャッシュが無効化される

dsn: mysql://rails:rails_password@db:3306/hydra_development?parseTime=true

urls:
  self:
    issuer: https://idp.localhost
  login: https://idp.localhost/auth/login
  consent: https://idp.localhost/auth/consent
  logout: https://idp.localhost/auth/logout
  post_logout_redirect: https://idp.localhost/

# 本番環境では必ず変更
secrets:
  system:
    - hydra-fixed-development-secret-for-session-persistence-do-not-use-in-production

oidc:
  subject_identifiers:
    supported_types:
      - public
    pairwise:
      salt: hydra-salt-change-this-in-production

oauth2:
  expose_internal_errors: true  # 開発環境のみ
```

---

## 🚨 重要な設定ポイント

### 1. dev: true の影響

```yaml
# ❌ 問題のある設定
dev: true  # セッションキャッシュを無効化、毎回署名鍵が変わる

# ✅ 正しい設定
# dev: true を削除またはコメントアウト
```

**dev: true の問題:**
- 毎回Cookie署名鍵が変更される
- セッションが無効化される
- remember設定が効かない

### 2. Cross-Domain Cookie設定

```yaml
cookies:
  same_site_mode: None      # Cross-Origin対応の必須設定
  same_site_legacy_workaround: true  # 古いブラウザ対応
  secure: true              # HTTPS必須、SameSite=None時は必須
```

### 3. secrets.system の重要性

```yaml
secrets:
  system:
    - "固定値-絶対に変更しない-本番では強力な値"
```

**重要:**
- DB初期化後は**絶対に変更しない**
- 変更すると暗号化されたJWKsが復号できなくなる
- 本番環境では非常に強力なランダム値を使用

---

## 🛠️ セットアップ手順

### Step 1: データベース準備

```bash
# 新規セットアップまたはsecrets変更後
docker-compose exec db mysql -u root -proot_password -e "DROP DATABASE IF EXISTS hydra_development; CREATE DATABASE hydra_development;"
```

### Step 2: マイグレーション実行

```bash
# Hydra起動時に自動実行されるが、手動実行も可能
docker-compose exec hydra hydra migrate sql --config /etc/config/hydra.yml -e --yes
```

### Step 3: JWKs生成（通常は自動、緊急時のみ手動）

```bash
# 通常は Hydra 起動時に自動生成される
# 手動生成が必要なケース:
# - dev: true → dev: false 変更後
# - DB完全リセット後
# - secrets.system 変更後

# OpenID Token署名用JWKs手動生成
docker-compose exec hydra hydra create jwks hydra.openid.id-token --alg RS256 --use sig --endpoint http://localhost:4445
```

### Step 4: Hydra起動・確認

```bash
docker-compose up -d hydra
docker-compose logs hydra  # 起動ログ確認
```

---

## 👥 OAuth2クライアント管理

### 1. 基本的なクライアント登録

```bash
# 拡張版登録スクリプト（CORS対応）
./scripts/simple-register-client.sh "https://localhost:3443/auth/sso/callback" --first-party --cors-origin "https://idp.localhost,https://localhost:3443"
```

### 2. スクリプトの機能

```bash
# 使用方法
./simple-register-client.sh REDIRECT_URI [--first-party] [--cors-origin "domain1,domain2"]

# 例
./simple-register-client.sh "https://example.com/callback" --first-party --cors-origin "https://idp.localhost,https://example.com"
```

**スクリプトの機能:**
- OAuth2クライアント登録
- First-party設定（同意画面スキップ）
- CORS Origins設定（Cross-Domain対応）
- 動的なクライアント管理

### 3. 手動クライアント設定

```bash
# 基本登録
docker-compose exec hydra hydra create oauth2-client \
  --endpoint http://localhost:4445 \
  --format json \
  --name "My Application" \
  --scope openid --scope profile --scope email \
  --grant-type authorization_code --grant-type refresh_token \
  --response-type code \
  --redirect-uri "https://myapp.com/auth/callback" \
  --allowed-cors-origin "https://idp.localhost" \
  --allowed-cors-origin "https://myapp.com" \
  --metadata '{"first_party": true}'
```

---

## 🔄 Remember（セッションキャッシュ）設定

### 1. Rails側実装

```ruby
# app/services/hydra_admin_client.rb

# Login Accept API
def self.accept_login_request(login_challenge, subject)
  response = put("/admin/oauth2/auth/requests/login/accept",
                 query: { login_challenge: login_challenge },
                 body: {
                   subject: subject,
                   remember: true,      # セッションキャッシュ有効
                   remember_for: 300    # 5分間キャッシュ
                 }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  handle_response(response)
end

# Consent Accept API
def self.accept_consent_request(consent_challenge, grant_scope, identity_token_claims = {})
  response = put("/admin/oauth2/auth/requests/consent/accept",
                 query: { consent_challenge: consent_challenge },
                 body: {
                   grant_scope: grant_scope,
                   grant_access_token_audience: [],
                   remember: true,      # 同意キャッシュ有効
                   remember_for: 300,   # 5分間キャッシュ
                   session: {
                     id_token: identity_token_claims
                   }
                 }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  handle_response(response)
end
```

### 2. Remember設定の意味

**Login Remember:**
- ユーザー認証状態のキャッシュ
- 同じユーザーの再認証をスキップ

**Consent Remember:**
- 同意確認状態のキャッシュ
- 同じスコープの再同意をスキップ

### 3. Cross-Domain環境での動作

**現実的な動作パターン:**
```
Cross-Domain環境 (localhost:3443 ↔ idp.localhost):
├── Login Challenge: 毎回IdP確認（セキュリティ重視）
├── Consent Challenge: 毎回同意確認（セキュリティ重視）
├── 認証セッション: 既存セッション再利用（効率性）
└── 結果: セキュアで高速なSSO認証
```

**同一ドメイン環境:**
- より積極的なキャッシュが期待される
- 本番環境での長期セッション管理

---

## 🌐 HTTPS・SSL設定

### 1. 開発環境用自己署名証明書

```bash
# SSL証明書生成
mkdir -p docker/nginx/ssl
cd docker/nginx/ssl

# 自己署名証明書作成
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout localhost.key -out localhost.crt \
  -subj "/CN=idp.localhost"
```

### 2. nginx SSL設定

```nginx
# docker/nginx/nginx.conf
server {
    listen 80;
    server_name idp.localhost;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name idp.localhost;

    ssl_certificate /etc/nginx/ssl/localhost.crt;
    ssl_certificate_key /etc/nginx/ssl/localhost.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # セキュリティヘッダー
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location /auth/ {
        proxy_pass http://web:3000;
        proxy_set_header Host idp.localhost;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_redirect off;
        proxy_cookie_flags ~ secure;
    }

    location /oauth2/ {
        proxy_pass http://hydra:4444;
        proxy_set_header Host idp.localhost;
        # ... 他のproxy設定
    }
}
```

---

## 🚀 本番環境構築のポイント

### 1. セキュリティ設定

```yaml
# 本番環境 hydra.yml
secrets:
  system:
    - "YOUR_EXTREMELY_STRONG_RANDOM_SECRET_NEVER_CHANGE_THIS"

oidc:
  subject_identifiers:
    pairwise:
      salt: "YOUR_UNIQUE_SALT_FOR_PAIRWISE_SUBJECTS"

oauth2:
  expose_internal_errors: false  # 本番では無効化
```

### 2. 環境変数管理

```bash
# .env (本番環境)
HYDRA_SYSTEM_SECRET=your-extremely-strong-secret
HYDRA_PAIRWISE_SALT=your-unique-salt
HYDRA_DSN=mysql://user:password@prod-db:3306/hydra_production
HOST_NAME=your-domain.com
```

### 3. SSL証明書

```bash
# 本番環境では正式なSSL証明書を使用
# Let's Encrypt、商用証明書など
```

### 4. JWKs管理（本番環境特有）

```yaml
# 本番環境でのJWKs設定例
jwks:
  default_algorithm: RS256    # 本番推奨: RS256 または ES256
  key_size: 4096             # より大きなキーサイズ（セキュリティ強化）
```

**本番環境でのJWKs運用:**

```bash
# 基本は自動生成（開発環境と同じ）
hydra serve -c /etc/config/hydra.yml all
# ↑ 初回起動時に自動でJWKs生成

# 定期的なキーローテーション（セキュリティ強化）
hydra create jwks hydra.openid.id-token --alg RS256 --use sig --endpoint http://localhost:4445

# JWKsバックアップ（災害復旧用）
mysqldump hydra_production hydra_jwk > jwks_backup_$(date +%Y%m%d).sql
```

**手動JWKs生成が必要なケース:**
- 災害復旧時（DB完全損失）
- カスタムセキュリティ要件対応
- マルチテナント環境での個別キー管理

### 5. パフォーマンス最適化

**Hydra設定 (`hydra.yml`):**
```yaml
# OAuth2トークンライフスパン調整
oauth2:
  authorization_code_lifespan: 1m     # Authorization Code の有効期限
  access_token_lifespan: 1h           # アクセストークンの有効期限
  refresh_token_lifespan: 720h        # リフレッシュトークンの有効期限（30日）
  id_token_lifespan: 1h               # OIDC ID トークンの有効期限

# サーバー設定（接続タイムアウト等）
serve:
  public:
    read_timeout: 5s
    write_timeout: 10s
    idle_timeout: 120s
```

**MySQL最適化 (`docker/mysql/my.cnf`):**
```ini
[mysqld]
max_connections = 200
innodb_buffer_pool_size = 1G
query_cache_size = 64M
innodb_log_file_size = 256M
```

**Redis/Valkey最適化 (`docker-compose.yml`):**
```yaml
valkey:
  command: >
    valkey-server
    --maxmemory 512mb
    --maxmemory-policy allkeys-lru
    --tcp-keepalive 60
    --timeout 300
```

---

## 🔍 トラブルシューティング

### 1. よくあるエラー

**`server_error | Could not ensure that signing keys for 'hydra.openid.id-token' exists`**

```bash
# 原因: JWKs（署名鍵）が見つからない
# よくある原因:
# - dev: true → dev: false 変更後
# - secrets.system 変更後
# - DB初期化後

# 解決方法
# 1. secrets.systemが変更されていないか確認
cat docker/hydra/hydra.yml | grep -A2 secrets

# 2. DBリセット＋再マイグレーション（開発環境）
docker-compose exec db mysql -u root -ppassword -e "DROP DATABASE hydra_development; CREATE DATABASE hydra_development;"
docker-compose restart hydra

# 3. 手動JWKs生成（必要に応じて）
docker-compose exec hydra hydra create jwks hydra.openid.id-token --alg RS256 --use sig --endpoint http://localhost:4445
```

**`invalid_client | The requested OAuth 2.0 Client does not exist`**

```bash
# 解決方法
# 1. クライアントIDが正しいか確認
docker-compose exec hydra hydra list oauth2-clients --endpoint http://localhost:4445
# 2. RP側設定ファイル確認
# 3. コンテナ再起動
```

### 2. デバッグ方法

```bash
# Hydraログ確認
docker-compose logs hydra

# DB状態確認
docker-compose exec db mysql -u root -ppassword hydra_development -e "
SELECT subject, client_id, login_remember, consent_remember, requested_at 
FROM hydra_oauth2_flow 
ORDER BY requested_at DESC LIMIT 5;"

# クライアント設定確認
docker-compose exec hydra hydra get oauth2-client CLIENT_ID --endpoint http://localhost:4445 --format json
```

---

## 📋 開発環境チェックリスト

### セットアップ前確認

- [ ] Docker Compose環境準備完了
- [ ] MySQL/Valkey コンテナ正常起動
- [ ] SSL証明書生成完了
- [ ] 環境変数設定完了

### Hydra設定確認

- [ ] `dev: true` がコメントアウト済み
- [ ] `secrets.system` 固定値設定済み
- [ ] `same_site_mode: None` 設定済み
- [ ] `secure: true` 設定済み
- [ ] HTTPS URL設定済み

### クライアント登録確認

- [ ] OAuth2クライアント登録済み
- [ ] CORS Origins設定済み
- [ ] First-party設定済み（必要に応じて）
- [ ] RP側設定ファイル更新済み

### 動作確認

- [ ] SSO認証フロー正常動作
- [ ] Cross-Domain Cookie送信確認
- [ ] Remember設定動作確認
- [ ] エラーログなし

---

## 🏭 本番環境チェックリスト

### セキュリティ

- [ ] 強力な`secrets.system`設定
- [ ] `expose_internal_errors: false`
- [ ] 正式SSL証明書導入
- [ ] ネットワークセキュリティ設定
- [ ] Admin API (4445) 外部非公開

### パフォーマンス

- [ ] DB接続プール最適化
- [ ] キャッシュシステム導入
- [ ] ログレベル最適化
- [ ] モニタリング設定

### 運用

- [ ] バックアップ戦略（DB + JWKs）
- [ ] JWKs定期ローテーション計画
- [ ] ログローテーション
- [ ] ヘルスチェック設定
- [ ] 障害対応手順書
- [ ] secrets.system バックアップ（安全な場所）

---

## 📚 参考リンク

- [ORY Hydra公式ドキュメント](https://www.ory.sh/hydra/docs/)
- [OAuth 2.0 RFC](https://tools.ietf.org/html/rfc6749)
- [OpenID Connect仕様](https://openid.net/connect/)

---

**最終更新**: 2025-09-03  
**作成者**: Claude Code Development Session  
**検証環境**: Rails 8.0 + ORY Hydra v2.3.0 + Docker Compose
# Doorkeeper版 SSO認証システム（doorkeeperブランチ）

Doorkeeper gemを利用したSingle Sign-On (SSO) 認証システムの実装です。

## ブランチ構成

- **main**: 基本的なIdP機能（2段階認証付きログイン・会員管理） → mainブランチのREADME.mdを参照
- **feature/hydra**: ORY Hydra を使用したSSO実装 → hydraブランチのREADME.mdを参照
- **feature/doorkeeper**: Doorkeeper Gem を使用したSSO実装 ← **このREADME**

## 技術スタック（doorkeeperブランチ）

- **IdP / RP**: Rails 7.1.x + Ruby 3.2.6
- **SSO**: Doorkeeper gem (OpenID Connect)
- **データベース**: MySQL 8.0
- **認証**: 2段階認証（メール） + OAuth 2.0/OpenID Connect
- **JWT署名**: RSA鍵ペア (RS256)
- **開発環境**: Docker Compose

## 重要：ブランチ別DB管理

**各ブランチは独立したデータベースを使用します**：

```
main ブランチ      → ./data/db-main (独立DB)
hydra ブランチ     → ./data/db-hydra (独立DB)
doorkeeper ブランチ → ./data/db-doorkeeper (独立DB) ← **現在のブランチ**
```

- ✅ ブランチ切り替えで自動的にDBが切り替わる
- ⚠️ **各ブランチで個別にセットアップが必要**
- ⚠️ **ブランチ間でデータは共有されない**

---

## 🚀 クイックスタート

### 1. リポジトリのクローンとブランチ切り替え

```bash
git clone <repository-url>
cd rails-sso
git checkout feature/doorkeeper
```

### 2. 初期設定ファイル作成（必須）

**⚠️ 重要**: Docker起動前に以下のファイルを作成する必要があります。

#### 2-1. .env.localファイル作成

```bash
# .env.localを作成（空でも可）
touch .env.local

# または必要な環境変数を設定
cat << 'EOF' > .env.local
# IdP API URL（RP → IdP通信用）
IDP_API_URL=http://idp:3000/api/v1

# ログアウト戦略設定（IdPアプリ用）
# local  - IdPローカルログアウトのみ（デフォルト）
# global - IdP + Doorkeeper + 全RP グローバルログアウト
LOGOUT_STRATEGY=global
EOF
```

#### 2-2. RSA鍵ペア生成（JWT署名用）

```bash
# JWT署名用のRSA鍵ペアを生成
mkdir -p keys
openssl genrsa -out keys/private_key.pem 2048
openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem

# 生成された鍵を確認
ls -la keys/
# private_key.pem (秘密鍵: IdPでJWT署名用)
# public_key.pem  (公開鍵: RPでJWT検証用)
```

**⚠️ セキュリティ注意**：
- `keys/`ディレクトリは`.gitignore`に含まれています
- 本番環境では適切なキー管理システム（AWS KMS等）を使用してください

### 3. Docker環境の起動

```bash
docker-compose up -d
```

このコマンドで以下が**自動実行**されます：
- MySQLコンテナ起動とDB作成
- IdP・RPのRails環境セットアップ（`rails db:prepare`含む）
- Doorkeeperのマイグレーション実行

**重要**: `rails db:migrate`等の追加コマンドは不要です。

### 4. OAuth2クライアント登録

```bash
./scripts/setup-doorkeeper-client.sh
```

実行後、以下のような出力が表示されます：
```
=== Doorkeeper OAuth2 クライアント登録完了 ===
Name: RP Application
Client ID: rp-client
Client Secret: rp-client-secret
Redirect URI: http://localhost:3001/auth/sso/callback
Scopes: openid profile email
```

### 5. 動作確認（初期セットアップ完了後）

**注意**: OAuth2クライアント設定（CLIENT_ID/SECRET）は固定値のため、追加の環境変数設定は不要です。

ブラウザでアクセス：
- **IdP（認証プロバイダー）**: http://localhost:3000
- **RP（SSOログインサイト）**: http://localhost:3001
- **メール確認画面**: http://localhost:3000/letter_opener

---

## 📋 SSOログインテスト手順

### Step1: 会員登録（IdPで）
1. **IdP**（http://localhost:3000）にアクセス
2. 「新規会員登録」で登録
   - メールアドレス、パスワード、氏名を入力
   - 確認画面で「登録する」

### Step2: SSOログイン（RPから）  
1. **RP**（http://localhost:3001）にアクセス
2. 「SSOログイン」ボタンをクリック
3. IdPのログイン画面にリダイレクト
4. メールアドレス・パスワードを入力
5. **メール確認**（http://localhost:3000/letter_opener）で認証コードを確認
6. 認証コードを入力
7. 同意画面で「許可する」をクリック
8. **RPに戻って会員情報が表示される** ✅

---

## 🔧 アーキテクチャ

### 認証フロー
```
1. ユーザー → RP「SSOログイン」クリック
2. RP → Doorkeeperの認証エンドポイントにリダイレクト
3. Doorkeeper → IdPログイン画面にリダイレクト  
4. IdP → ユーザー認証（メール+パスワード+2FA）
5. IdP → Doorkeeperに認証成功通知
6. Doorkeeper → IdP同意画面にリダイレクト
7. IdP → ユーザー同意確認
8. IdP → Doorkeeperに同意通知
9. Doorkeeper → RPにauthorization codeを送信
10. RP → DoorkeeperからAccess Token・ID Tokenを取得
11. RP → IdP APIでユーザー情報を取得・表示
```

### JWT署名・検証フロー
1. **IdP**: RSA秘密鍵でIDトークンに署名（RS256）
2. **JWKS**: `/.well-known/jwks.json`でRSA公開鍵を配布
3. **RP**: JWKSから公開鍵を取得してIDトークンを検証

### コンテナ構成
- **db**: MySQL 8.0（2つのDB: idp_development, rp_development）
- **idp**: IdP Rails アプリ（認証・同意画面・Doorkeeper OAuth2サーバー）
- **rp**: RP Rails アプリ（SSOログインのテストサイト）

### OpenID Connect実装
- **認証エンドポイント**: `/oauth/authorize`
- **トークンエンドポイント**: `/oauth/token`
- **ユーザー情報API**: `/api/v1/user_info`
- **JWKS**: `/.well-known/jwks.json`

---

## 🛠️ 開発用コマンド

### コンテナ操作

```bash
# 全コンテナ起動
docker-compose up -d

# 特定コンテナのログ確認
docker-compose logs -f idp    # IdPログ
docker-compose logs -f rp     # RPログ  

# 全コンテナ停止
docker-compose down
```

### データベース操作

```bash
# MySQL接続
docker-compose exec db mysql -u sso_user -p
# パスワード: sso_password

# Rails操作（IdP）
docker-compose exec idp bundle exec rails console
docker-compose exec idp bundle exec rails routes

# Rails操作（RP）
docker-compose exec rp bundle exec rails console
docker-compose exec rp bundle exec rails routes
```

### Doorkeeper操作

```bash
# OAuth2アプリケーション確認（Rails Console）
docker-compose exec idp bundle exec rails console
> Doorkeeper::Application.all

# OAuth2データリセット（テスト用）
./scripts/clear-oauth-data.sh

# クライアント再登録
./scripts/setup-doorkeeper-client.sh
```

---

## 🚨 トラブルシューティング

### よくある問題

#### 🔴 RPでログイン後にエラーが発生
**原因**: OAuth2クライアント登録が未完了、またはRSA鍵が未生成
```bash
# 解決方法
./scripts/setup-doorkeeper-client.sh
# RSA鍵ペアが存在するか確認
ls -la keys/
# 鍵が存在しない場合は再生成
openssl genrsa -out keys/private_key.pem 2048
openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem
docker-compose restart idp rp
```

#### 🔴 メール認証コードが表示されない
**URL**: http://localhost:3000/letter_opener でメール確認

#### 🔴 「JWT verification failed」エラー
**原因**: RSA鍵ペアの不整合またはJWKSエンドポイントの問題
```bash
# RSA鍵ペア再生成
rm keys/*
openssl genrsa -out keys/private_key.pem 2048
openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem
docker-compose restart idp rp
```

#### 🔴 データベース初期化（Doorkeeperブランチのみ）
```bash
docker-compose down
rm -rf data/db-doorkeeper/*  # ⚠️ Doorkeeperブランチのデータが削除されます
docker-compose up -d
./scripts/setup-doorkeeper-client.sh
```

### 完全リセット

```bash
# 全データとボリューム削除
docker-compose down -v
rm -rf data/db-doorkeeper/*
rm -rf keys/*
docker system prune -f

# 再構築
openssl genrsa -out keys/private_key.pem 2048
openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem
docker-compose up -d
./scripts/setup-doorkeeper-client.sh
```

---

## 🌐 ポート・URL一覧

| サービス | URL | 説明 |
|---------|-----|------|
| **🏠 IdP** | http://localhost:3000 | 認証プロバイダー（会員登録・ログイン・同意画面・OAuth2サーバー） |
| **🎯 RP** | http://localhost:3001 | リライングパーティ（SSOログインテストサイト） |
| **📧 メール確認** | http://localhost:3000/letter_opener | 2段階認証コード確認画面 |
| **🔐 OAuth2認証** | http://localhost:3000/oauth/authorize | Doorkeeper OAuth2エンドポイント |
| **🔑 JWKS** | http://localhost:3000/.well-known/jwks.json | RSA公開鍵配布エンドポイント |
| **🗄️ DB管理** | localhost:3306 | MySQL（sso_user/sso_password） |

---

## RSA鍵管理

### 鍵ペアの役割
- **秘密鍵**: `keys/private_key.pem` (IdP用, JWT署名)
- **公開鍵**: `keys/public_key.pem` (RP用, JWT検証)
- **マウント**: `./keys:/app/config/keys:ro` (読み取り専用)

### 鍵の再生成
```bash
# 既存の鍵を削除
rm keys/*

# 新しい鍵ペアを生成
openssl genrsa -out keys/private_key.pem 2048
openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem

# 権限設定
chmod 600 keys/private_key.pem
chmod 644 keys/public_key.pem

# コンテナ再起動
docker-compose restart idp rp
```

---

## 他ブランチへの切り替え方法

### mainブランチ（基本IdP機能のみ）
```bash
git checkout main
docker-compose down && docker-compose up -d
# → mainブランチのREADME.mdに従ってセットアップ
```

### hydraブランチ（ORY Hydra版SSO）  
```bash
git checkout feature/hydra
docker-compose down && docker-compose up -d
# → hydraブランチのREADME.mdに従ってセットアップ
```

**注意**: 各ブランチは独立したDBを使用するため、初回切り替え時は各ブランチのREADME.mdに従ってセットアップが必要です。

---

## 関連ドキュメント

### プロジェクト仕様
- **技術仕様詳細**: [CLAUDE.md](./CLAUDE.md)
- **セキュリティ実装**: `notes/security_implementation_plan.md`

### 外部ドキュメント
- **Doorkeeper gem**: https://github.com/doorkeeper-gem/doorkeeper
- **doorkeeper-openid_connect**: https://github.com/doorkeeper-gem/doorkeeper-openid_connect
- **OpenID Connect仕様**: https://openid.net/connect/

---

## ライセンス

学習・研究目的のプロジェクトです。
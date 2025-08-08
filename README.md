# ORY Hydra版 SSO認証システム（hydraブランチ）

ORY Hydraを利用したSingle Sign-On (SSO) 認証システムの実装です。

## ブランチ構成

- **main**: 基本的なIdP機能（2段階認証付きログイン・会員管理） → mainブランチのREADME.mdを参照
- **feature/hydra**: ORY Hydra を使用したSSO実装 ← **このREADME**
- **feature/doorkeeper**: Doorkeeper Gem を使用したSSO実装 → doorkeeperブランチのREADME.mdを参照

## 技術スタック（hydraブランチ）

- **IdP / RP**: Rails 7.1.x + Ruby 3.2.6
- **SSO**: ORY Hydra v2.2.0 (OpenID Connect)
- **データベース**: MySQL 8.0
- **認証**: 2段階認証（メール） + OAuth 2.0/OpenID Connect
- **開発環境**: Docker Compose

## 重要：ブランチ別DB管理

**各ブランチは独立したデータベースを使用します**：

```
main ブランチ      → ./data/db-main (独立DB)
hydra ブランチ     → ./data/db-hydra (独立DB) ← **現在のブランチ**
doorkeeper ブランチ → ./data/db-doorkeeper (独立DB)
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
git checkout feature/hydra
```

### 2. Docker環境の起動

```bash
docker-compose up -d
```

このコマンドで以下が**自動実行**されます：
- MySQLコンテナ起動とDB作成
- ORY Hydraのマイグレーションとサーバー起動
- IdP・RPのRails環境セットアップ（`rails db:prepare`含む）

**重要**: `rails db:migrate`等の追加コマンドは不要です。

### 3. Hydraクライアント登録

```bash
./scripts/setup-hydra-client.sh
```

実行後、以下のような出力が表示されます：
```
=== ORY Hydra クライアント登録 ===
クライアント作成完了:
{"client_id":"bcfd3e14-6545-41c8-914a-1cf91eeea9db",...}

=== 重要: 上記JSONから client_id と client_secret をRPアプリの設定に使用してください ===
```

### 4. 環境設定ファイル確認・更新

`.env.local`ファイルのclient_idを上記の値に更新：

```bash
# .env.local
OAUTH_CLIENT_ID=bcfd3e14-6545-41c8-914a-1cf91eeea9db  # ← 新しい値に更新
OAUTH_CLIENT_SECRET=rp-client-secret
HYDRA_PUBLIC_URL=http://localhost:4444
HYDRA_PUBLIC_URL_INTERNAL=http://hydra:4444
OAUTH_REDIRECT_URI=http://localhost:3001/auth/sso/callback

# IdP API URL（RP → IdP通信用）
IDP_API_URL=http://idp:3000/api/v1

# ログアウト戦略設定（IdPアプリ用）
# local  - IdPローカルログアウトのみ（デフォルト）
# global - IdP + Hydra + 全RP グローバルログアウト
LOGOUT_STRATEGY=global

# 信頼できるクライアントID（自動同意設定）
TRUSTED_CLIENT_IDS=bcfd3e14-6545-41c8-914a-1cf91eeea9db  # ← 上記と同じ値
```

### 5. 環境変数適用のため全コンテナ再起動

```bash
docker-compose down && docker-compose up -d
```

### 6. 動作確認

ブラウザでアクセス：
- **IdP（認証プロバイダー）**: http://localhost:3000
- **RP（SSOログインサイト）**: http://localhost:3001
- **メール確認画面**: http://localhost:3000/letter_opener
- **Hydra Public API**: http://localhost:4444

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
7. 同意画面で「許可する」をクリック（※基本スコープのみの場合は自動同意でスキップ）
8. **RPに戻って会員情報が表示される** ✅

---

## 🔧 アーキテクチャ

### 認証フロー
```
1. ユーザー → RP「SSOログイン」クリック
2. RP → Hydra認証エンドポイントにリダイレクト
3. Hydra → IdPログイン画面にリダイレクト  
4. IdP → ユーザー認証（メール+パスワード+2FA）
5. IdP → Hydraに認証成功通知
6. Hydra → IdP同意画面にリダイレクト
7. IdP → ユーザー同意確認
8. IdP → Hydraに同意通知
9. Hydra → RPにauthorization codeを送信
10. RP → HydraからAccess Token・ID Tokenを取得
11. RP → IdP APIでユーザー情報を取得・表示
```

### コンテナ構成
- **db**: MySQL 8.0（3つのDB: idp_development, rp_development, hydra_development）
- **hydra-migrate**: Hydraスキーマ初期化（一回のみ実行）
- **hydra**: ORY Hydra v2.2.0（OAuth2/OpenID Connect サーバー）
- **idp**: IdP Rails アプリ（認証・同意画面）
- **rp**: RP Rails アプリ（SSOログインのテストサイト）

### 自動同意の仕組み

同意画面は以下の条件で**自動的にスキップ**されます：

1. **Hydraのskipフラグ**がtrueの場合
2. **信頼できるクライアント**（`TRUSTED_CLIENT_IDS`環境変数で指定）の場合  
3. **基本スコープのみ**（openid, profile, email）の場合

現在の設定では条件3により、自動同意が有効になっています。

---

## 🛠️ 開発用コマンド

### コンテナ操作

```bash
# 全コンテナ起動
docker-compose up -d

# 特定コンテナのログ確認
docker-compose logs -f idp    # IdPログ
docker-compose logs -f rp     # RPログ  
docker-compose logs -f hydra  # Hydraログ

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

### Hydra操作

```bash
# クライアント一覧
docker exec sso_hydra hydra list oauth2-clients --endpoint http://localhost:4445

# クライアント削除
docker exec sso_hydra hydra delete oauth2-client --endpoint http://localhost:4445 <client_id>

# クライアント再登録
./scripts/setup-hydra-client.sh
```

---

## 🚨 トラブルシューティング

### よくある問題

#### 🔴 RPでログイン後に「401 Unauthorized」または「invalid_client」
**原因**: クライアント登録が未完了、または環境変数が未設定
```bash
# 解決方法
./scripts/setup-hydra-client.sh
# .env.localのOAUTH_CLIENT_IDを上記で生成された値に更新
docker-compose down && docker-compose up -d
```

#### 🔴 「Connection refused」「Name resolution failure」
**原因**: `HYDRA_PUBLIC_URL_INTERNAL`が未設定でコンテナ間通信に失敗
```bash
# .env.localに以下を確認・追加
HYDRA_PUBLIC_URL_INTERNAL=http://hydra:4444
docker-compose restart rp
```

#### 🔴 メール認証コードが表示されない
**URL**: http://localhost:3000/letter_opener でメール確認

#### 🔴 データベース初期化（Hydraブランチのみ）
```bash
docker-compose down
rm -rf data/db-hydra/*  # ⚠️ Hydraブランチのデータが削除されます
docker-compose up -d
./scripts/setup-hydra-client.sh
# .env.local更新 + 全コンテナ再起動
```

### 完全リセット

```bash
# 全データとボリューム削除
docker-compose down -v
rm -rf data/db-hydra/*
docker system prune -f

# 再構築
docker-compose up -d
./scripts/setup-hydra-client.sh
# .env.local更新後、docker-compose down && docker-compose up -d
```

---

## 🌐 ポート・URL一覧

| サービス | URL | 説明 |
|---------|-----|------|
| **🏠 IdP** | http://localhost:3000 | 認証プロバイダー（会員登録・ログイン・同意画面） |
| **🎯 RP** | http://localhost:3001 | リライングパーティ（SSOログインテストサイト） |
| **📧 メール確認** | http://localhost:3000/letter_opener | 2段階認証コード確認画面 |
| **🔐 Hydra Public** | http://localhost:4444 | OAuth2/OpenID Connect エンドポイント |
| **🗄️ DB管理** | localhost:3306 | MySQL（sso_user/sso_password） |

**注意**: Hydra Admin API (4445) は内部通信専用でホストからはアクセスできません。

---

## 他ブランチへの切り替え方法

### mainブランチ（基本IdP機能のみ）
```bash
git checkout main
docker-compose down && docker-compose up -d
# → mainブランチのREADME.mdに従ってセットアップ
```

### doorkeeperブランチ（Doorkeeper版SSO）  
```bash
git checkout feature/doorkeeper
docker-compose down && docker-compose up -d
# → doorkeeperブランチのREADME.mdに従ってセットアップ
```

**注意**: 各ブランチは独立したDBを使用するため、初回切り替え時は各ブランチのREADME.mdに従ってセットアップが必要です。

---

## 関連ドキュメント

### プロジェクト仕様
- **技術仕様詳細**: [CLAUDE.md](./CLAUDE.md)
- **セキュリティ実装**: `notes/security_implementation_plan.md`

### 外部ドキュメント
- **ORY Hydra公式**: https://www.ory.sh/docs/hydra
- **OpenID Connect仕様**: https://openid.net/connect/

---

## ライセンス

学習・研究目的のプロジェクトです。
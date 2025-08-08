# Rails SSO プロジェクト（mainブランチ）

Ruby on Rails による Single Sign-On (SSO) 認証システムの実装プロジェクトです。

## ブランチ構成

- **main**: 基本的なIdP機能（2段階認証付きログイン・会員管理）← **このREADME**
- **feature/hydra**: ORY Hydra を使用したSSO実装 → 各ブランチのREADME.mdを参照
- **feature/doorkeeper**: Doorkeeper Gem を使用したSSO実装 → 各ブランチのREADME.mdを参照

## 技術スタック（mainブランチ）

- **Rails**: 7.1.x
- **Ruby**: 3.2.6
- **データベース**: MySQL 8.0
- **開発環境**: Docker Compose

## 重要：ブランチ別DB管理

**各ブランチは独立したデータベースを使用します**：

```
main ブランチ      → ./data/db-main (独立DB)
hydra ブランチ     → ./data/db-hydra (独立DB)  
doorkeeper ブランチ → ./data/db-doorkeeper (独立DB)
```

- ✅ ブランチ切り替えで自動的にDBが切り替わる
- ⚠️ **各ブランチで個別にセットアップが必要**
- ⚠️ **ブランチ間でデータは共有されない**

---

## mainブランチ セットアップ手順

### 1. リポジトリのクローン

```bash
git clone <repository-url>
cd rails-sso
git checkout main
```

### 2. Docker環境の起動

```bash
docker-compose up -d
```

このコマンドで以下が**自動実行**されます：
- MySQLコンテナの起動とDB作成
- Rails環境のセットアップ（`rails db:prepare`含む）

**重要**: `rails db:migrate`等の追加コマンドは不要です。

### 3. 動作確認

ブラウザでアクセス：
- **IdPアプリケーション**: http://localhost:3000

---

## 主な機能（mainブランチ）

### IdP（Identity Provider）機能

- **新規会員登録**: メールアドレス・パスワード・氏名での登録
- **ログイン**: メールアドレス + パスワード + 2段階認証（メール認証コード）
- **会員情報管理**: プロフィール表示・編集
- **ログアウト**: セッション終了

### セキュリティ機能

- 2段階認証（メール送信による認証コード）
- セキュリティヘッダー設定
- CSRF保護
- JWT Cookie認証
- 認証ログ記録

---

## 開発用コマンド

### コンテナ操作

```bash
# 起動
docker-compose up -d

# ログ確認
docker-compose logs idp

# 停止
docker-compose down
```

### データベース操作

```bash
# MySQL接続
docker-compose exec db mysql -u sso_user -p
# パスワード: sso_password

# データベースリセット（必要な場合のみ）
docker-compose exec idp bundle exec rails db:reset
```

**重要**: マイグレーション実行は不要です。docker-compose起動時に自動で `rails db:prepare` が実行されます。

### Rails操作

```bash
# Railsコンソール
docker-compose exec idp bundle exec rails console

# ルーティング確認
docker-compose exec idp bundle exec rails routes
```

---

## 他ブランチの利用方法

### SSO機能を試したい場合

各ブランチには独立したセットアップ手順があります：

```bash
# Hydra版SSO
git checkout feature/hydra
# → feature/hydraブランチのREADME.mdを参照してセットアップ

# Doorkeeper版SSO  
git checkout feature/doorkeeper
# → feature/doorkeeperブランチのREADME.mdを参照してセットアップ
```

**注意**: 各ブランチは独立したDBを使用するため、初回切り替え時は各ブランチのREADME.mdに従ってセットアップが必要です。

---

## トラブルシューティング

### コンテナが起動しない

```bash
docker-compose down -v
docker system prune
docker-compose up -d
```

### データベースエラー

```bash
# MySQLコンテナ確認
docker-compose ps
docker-compose logs db

# DB再初期化
docker-compose exec idp bundle exec rails db:reset
```

---

## ディレクトリ構成

```
├── README.md                   # このファイル（mainブランチ用）
├── docker-compose.yml          # Docker構成
├── idp_app/                    # IdP Rails アプリケーション
├── data/
│   ├── db-main/               # mainブランチ用DBファイル
│   ├── db-hydra/              # hydraブランチ用DBファイル
│   └── db-doorkeeper/         # doorkeeperブランチ用DBファイル
├── docker/                     # Docker設定
├── notes/                      # 設計ドキュメント
└── tmp/                        # 一時ファイル
```

---

## 関連ドキュメント

### プロジェクト仕様
- **`notes/CLAUDE.md`**: 全体仕様
- **`notes/log_based_security_implementation.md`**: セキュリティ機能実装仕様

### 他ブランチ
- **feature/hydra**: ORY Hydra実装 → そのブランチのREADME.md参照
- **feature/doorkeeper**: Doorkeeper実装 → そのブランチのREADME.md参照

---

## ライセンス

学習・研究目的のプロジェクトです。
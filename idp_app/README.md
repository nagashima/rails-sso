# SSO IdP Application

Rails 7.1ベースのIdentity Provider (IdP) アプリケーション

## セットアップ

### Ruby version
3.2.6

### System dependencies
- Docker & Docker Compose
- MySQL 8.0

### Database creation
```bash
docker-compose up -d mysql
docker-compose exec idp bundle exec rails db:create
docker-compose exec idp bundle exec rails db:migrate
```

### How to run
```bash
docker-compose up -d
```

### Services
- IdP Application: http://localhost:3000
- MySQL: localhost:3306

## データベース接続

### MySQLに直接接続
```bash
# IdPデータベースに直接接続
docker-compose exec mysql mysql -u sso_user -psso_password sso_development

# 接続後のSQL操作例
SHOW TABLES;              # テーブル一覧
DESCRIBE users;           # usersテーブル構造
SELECT * FROM users;      # usersテーブルの全データ
SELECT * FROM users\G     # 縦表示（見やすい）
```

### Railsコンソールからデータ確認
```bash
# Railsコンソールを起動
docker-compose exec idp bundle exec rails console

# ActiveRecordでデータ操作
User.all
User.count
User.find(1)
User.where(activated: true)
```

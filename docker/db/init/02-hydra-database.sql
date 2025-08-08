-- ORY Hydra用データベース初期化スクリプト
CREATE DATABASE IF NOT EXISTS hydra_development;

-- Hydra用ユーザーにデータベースへのアクセス権限を付与
GRANT ALL PRIVILEGES ON hydra_development.* TO 'sso_user'@'%';
FLUSH PRIVILEGES;
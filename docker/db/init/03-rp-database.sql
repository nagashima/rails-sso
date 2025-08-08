-- RP (Relying Party)用データベース初期化スクリプト
CREATE DATABASE IF NOT EXISTS rp_development;

-- RP用ユーザーにデータベースへのアクセス権限を付与
GRANT ALL PRIVILEGES ON rp_development.* TO 'sso_user'@'%';
FLUSH PRIVILEGES;
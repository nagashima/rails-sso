-- IdP用データベース初期化スクリプト
CREATE DATABASE IF NOT EXISTS idp_development;

-- IdP用ユーザーにデータベースへのアクセス権限を付与
GRANT ALL PRIVILEGES ON idp_development.* TO 'sso_user'@'%';
FLUSH PRIVILEGES;
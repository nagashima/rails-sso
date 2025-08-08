#!/bin/bash

# OAuth2認証データクリアスクリプト
# Doorkeeperの認証済みトークンと認可グラント、OpenIDリクエストを全削除
# 同意状態をリセットして、フレッシュなSSOテストを可能にする

set -e

echo "🧹 OAuth2認証データをクリア中..."

docker exec sso_idp bundle exec rails runner "
puts '=== Doorkeeper OAuth2 Data Cleanup ==='

# 現在のデータ状況を表示
puts \"Access Tokens: #{Doorkeeper::AccessToken.count}\"
puts \"Access Grants: #{Doorkeeper::AccessGrant.count}\"
puts \"OpenID Requests: #{Doorkeeper::OpenidConnect::Request.count}\"

# 全データ削除
puts '\\n削除中...'
Doorkeeper::AccessToken.delete_all
Doorkeeper::AccessGrant.delete_all  
Doorkeeper::OpenidConnect::Request.delete_all

puts '\\n✅ OAuth2データクリア完了'
puts 'SSOフローをフレッシュな状態でテストできます'
"

echo "✅ OAuth2認証データのクリアが完了しました"
echo "💡 次回SSO開始時に同意画面が表示されます"
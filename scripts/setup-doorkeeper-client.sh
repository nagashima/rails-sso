#!/bin/bash
set -e

echo "=== Doorkeeper OAuth2 クライアント登録 ==="

# IdPが起動するまで待機
echo "IdPの起動を待っています..."
until curl -f -s http://localhost:3000/health 2>/dev/null || curl -f -s http://localhost:3000 2>/dev/null; do
  echo "IdPの起動を待機中..."
  sleep 2
done

echo "RPアプリケーション用OAuth2クライアントを作成中..."

# Rails consoleでOAuth2アプリケーション作成
docker exec sso_idp bundle exec rails runner "
app = Doorkeeper::Application.find_or_create_by(uid: 'rp-client') do |application|
  application.name = 'RP Application'
  application.secret = 'rp-client-secret'
  application.redirect_uri = 'http://localhost:3001/auth/sso/callback'
  application.scopes = 'openid profile email'
end

puts ''
puts '=== Doorkeeper OAuth2 クライアント登録完了 ==='
puts \"Name: #{app.name}\"
puts \"Client ID: #{app.uid}\"
puts \"Client Secret: #{app.secret}\"
puts \"Redirect URI: #{app.redirect_uri}\"
puts \"Scopes: #{app.scopes}\"
puts ''
puts '=== 重要: 上記情報をRPアプリの設定に使用してください ==='
"

echo "=== クライアント登録完了 ==="
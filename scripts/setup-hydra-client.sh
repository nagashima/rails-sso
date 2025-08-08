#!/bin/bash
set -e

echo "=== ORY Hydra クライアント登録 ==="

# Hydraが起動するまで待機
echo "Hydraの起動を待っています..."
until docker exec sso_hydra wget -q --spider http://localhost:4444/health/ready 2>/dev/null; do
  echo "Hydraの起動を待機中..."
  sleep 2
done

echo "RPアプリケーション用OAuth2クライアントを作成中..."

# クライアント作成（自動生成されたIDとSecretを取得）
client_json=$(docker exec sso_hydra hydra create oauth2-client \
  --endpoint http://localhost:4445 \
  --format json \
  --name "RP Application" \
  --secret rp-client-secret \
  --grant-type authorization_code \
  --grant-type refresh_token \
  --response-type code \
  --response-type id_token \
  --scope openid \
  --scope profile \
  --scope email \
  --redirect-uri http://localhost:3001/auth/sso/callback)

# 結果を表示（JSONレスポンス）
echo "クライアント作成完了:"
echo "$client_json"

echo ""
echo "=== 重要: 上記JSONから client_id と client_secret をRPアプリの設定に使用してください ==="

echo "=== クライアント登録完了 ==="
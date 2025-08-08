#!/bin/sh
set -e

echo "Waiting for Hydra to be ready..."
until wget -q --spider http://hydra:4444/health/ready 2>/dev/null; do
  echo "Waiting for Hydra..."
  sleep 2
done

echo "Creating OAuth2 client for RP..."
/usr/bin/hydra create oauth2-client \
  --endpoint http://hydra:4445 \
  --name "RP Client" \
  --secret "rp-client-secret" \
  --grant-type authorization_code,refresh_token \
  --response-type code,id_token \
  --scope openid,profile,email \
  --redirect-uri http://localhost:3001/auth/sso/callback

echo "Client setup complete!"
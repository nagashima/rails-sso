# IdP本番運用: ドメイン構成設計指針

**作成日**: 2025-08-31  
**目的**: Rails IdP + Hydraの本番運用におけるドメイン構成の選択指針  
**背景**: nginx導入完了後の本番想定アーキテクチャ検討  
**運用条件**: 同一VPC内運用、nginx 1台でのマルチドメイン対応

---

## 🏗️ 2つの主要なドメイン構成パターン

### パターン1: 別ドメイン構成（マルチドメインnginx）
```
[同一VPC内]
ALB (*.company.com) 
    ↓
nginx (マルチドメイン対応)
    ├── auth.company.com → Rails IdP
    └── oauth.company.com → Hydra
```

**nginx設定例:**
```nginx
server {
    server_name auth.company.com;
    location / { 
        proxy_pass http://rails-idp-cluster; 
    }
}
server {
    server_name oauth.company.com;
    location / { 
        proxy_pass http://hydra-cluster; 
    }
}
```

### パターン2: 同ドメイン・パス分離構成
```
[同一VPC内]
ALB (idp.company.com)
    ↓
nginx (パス分離)
    ├── /auth/* → Rails IdP  
    └── /oauth2/* → Hydra
```

**nginx設定例:**
```nginx
server {
    server_name idp.company.com;
    location /auth/ { 
        proxy_pass http://rails-idp-cluster; 
    }
    location /oauth2/ { 
        proxy_pass http://hydra-cluster; 
    }
}
```

---

## 📊 詳細比較表（同一VPC・nginx 1台条件）

| 観点 | 別ドメイン（マルチドメイン） | 同ドメイン（パス分離） |
|------|--------------------------|----------------------|
| **SSL証明書管理** | △ ワイルドカード証明書必要 | ◎ 単一ドメイン証明書 |
| **ACM管理** | △ *.company.com証明書 | ◎ idp.company.com証明書 |
| **Route53設定** | △ 複数Aレコード | ◎ 1つのAレコード |
| **nginx設定複雑度** | ◎ server単位でシンプル | △ location単位で複雑 |
| **CORS設定** | △ クロスドメイン対応必要 | ◎ 同一オリジン |
| **Cookie共有** | ❌ ドメイン跨ぎ制約 | ◎ 可能 |
| **RP側設定複雑度** | △ 複数エンドポイント管理 | ◎ 単一ドメイン |
| **Discovery利用** | △ 複雑化 | ◎ 素直に利用可能 |
| **SPOF** | 同じ（nginx 1台） | 同じ（nginx 1台） |
| **ログ追跡** | ◎ ドメイン単位で分離 | △ 混在、工夫が必要 |
| **責務分離明確度** | ◎ ドメイン単位で明確 | △ パス構造での理解必要 |
| **ALB健全性チェック** | ◎ サービス別チェック可能 | △ nginx経由での複合チェック |

---

## 🎯 各構成の詳細メリット・デメリット

### パターン1: 別ドメイン構成（マルチドメインnginx）

#### ✅ メリット
**nginx設定面:**
- **server単位でのシンプル設定**: ドメインベースの明確な分離
- **ログ分離**: access.logでserver_name別の自然な分離
- **健全性チェック**: ALBから各サービスへの独立した健全性確認

**システム設計面:**
- **責務の明確化**: URL体系でのサービス境界の明示
- **将来的な独立性**: 各ドメインを異なるインフラへ移行する柔軟性
- **チーム分離**: ドメイン単位での開発・運用責任分担

**運用・監視面:**
```nginx
# ドメイン別ログ分離が自然
access_log /var/log/nginx/auth.company.com.log;  # Rails IdP
access_log /var/log/nginx/oauth.company.com.log; # Hydra
```

#### ❌ デメリット
**RP側設定の複雑化:**
```ruby
# RP側での複数エンドポイント管理が必要
discovery_endpoint: "https://oauth.company.com"        # Hydra Discovery
authorization_endpoint: "https://oauth.company.com/oauth2/auth"
token_endpoint: "https://oauth.company.com/oauth2/token"
userinfo_endpoint: "https://oauth.company.com/userinfo"
# さらにIdP UIとの連携も必要
login_ui_endpoint: "https://auth.company.com/login"
```

**SSL・DNS管理:**
- **ワイルドカード証明書**: `*.company.com`証明書の取得・管理
- **複数DNSレコード**: auth.company.com, oauth.company.com の個別管理

**Discovery (.well-known) の複雑化:**
```json
// oauth.company.com/.well-known/openid-configuration
{
  "issuer": "https://oauth.company.com",
  "authorization_endpoint": "https://oauth.company.com/oauth2/auth",
  // しかし実際のUIはauth.company.comにある！
}
```

**CORS設定:**
```javascript
// フロントエンドからの異なるドメインへのアクセス
fetch('https://oauth.company.com/oauth2/token', {
  credentials: 'include',  // クロスドメインでのCookie送信制約
});
```

### パターン2: 同ドメイン・パス分離構成

#### ✅ メリット
**RP側設定の超シンプル化:**
```ruby
# RP側設定 - これだけ！
client_options: {
  identifier: ENV['OAUTH_CLIENT_ID'],
  secret: ENV['OAUTH_CLIENT_SECRET'],  
  redirect_uri: ENV['OAUTH_REDIRECT_URI'],
  issuer: 'https://idp.company.com'  # Discovery自動取得
}
```

**Discovery標準利用:**
```json
// https://idp.company.com/.well-known/openid-configuration
{
  "issuer": "https://idp.company.com",
  "authorization_endpoint": "https://idp.company.com/oauth2/auth",
  "token_endpoint": "https://idp.company.com/oauth2/token",
  "userinfo_endpoint": "https://idp.company.com/userinfo"
  // すべて同一ドメインで統一！
}
```

**運用・管理の簡素化:**
- **単一SSL証明書**: idp.company.com のみ
- **単一DNSレコード**: 1つのAレコードのみ
- **CORS設定不要**: 同一オリジンでの通信

**Cookie・セッション管理:**
```javascript
// 同一ドメインでのシームレスな認証状態管理
document.cookie = "session_id=xxx; domain=idp.company.com";
// Rails IdPとHydraで共通のドメイン設定
```

**開発・デバッグ体験:**
- **開発環境一貫性**: localhost環境での動作確認が直感的
- **ブランド統一**: ユーザーにとって統一されたドメイン体験

#### ❌ デメリット
**nginx設定の複雑化:**
```nginx
# 細かいパス制御が必要
location = /.well-known/openid-configuration {
    proxy_pass http://hydra-cluster/.well-known/openid-configuration;
}
location /.well-known/ {
    proxy_pass http://hydra-cluster;
}
location /userinfo {
    proxy_pass http://hydra-cluster/userinfo;
}
location /oauth2/ {
    proxy_pass http://hydra-cluster;
}
location /auth/ {
    proxy_pass http://rails-idp-cluster;
}
location / {
    proxy_pass http://rails-idp-cluster;
}
```

**ログ・監視の複雑化:**
```bash
# 同じaccess.logにRailsとHydraが混在
# リクエスト追跡にX-Request-IDなどの工夫が必要
tail -f /var/log/nginx/access.log | grep "/oauth2/"  # Hydra
tail -f /var/log/nginx/access.log | grep "/auth/"   # Rails
```

**責務の見通し:**
- **URL構造理解**: `/auth/` vs `/oauth2/` の役割分担の理解が必要
- **エラー追跡**: どちらのサービスでエラーが発生したか判別の工夫が必要

**健全性チェック:**
```yaml
# ALBでの健全性チェック設計
health_check:
  path: "/health"  # どちらのサービスの健全性を確認？
  # 両方のサービスが健全でないとALBがNGと判断する複雑さ
```

---

## 🌍 業界動向・実際の採用例

### ORY Hydra公式推奨（重要）

#### 絶対的なセキュリティルール
- **Admin API**: 外部公開厳禁、VPC内クローズド運用必須
- **Public API**: TLS必須、信頼できるFQDN必要

#### ドメイン構成の公式スタンス
**「どちらでも動く」前提** - 運用チーム・環境に応じた選択を推奨

**公式チュートリアル・docker-compose例:**
```yaml
# ORY公式サンプルの典型的なパターン
services:
  hydra:
    ports:
      - "4444:4444"  # Public API
      # Admin API（4445）は外部公開しない
  
  nginx:
    # 同一ドメイン + パス切り替えパターンを標準採用
    location /oauth2/ { proxy_pass hydra:4444; }
    location /.well-known/ { proxy_pass hydra:4444; }
```

**ORY公式ベストプラクティス:**
- **小規模/シンプル運用** → 同一ドメイン + パス切り替え推奨
- **セキュリティ分離/可用性重視** → サブドメイン分離推奨
- **運用の柔軟性**: 環境や運用チームの好みに合わせて選択OK

### 大手SaaS（同ドメイン・パス分離派）
- **Auth0**: `auth0.com/oauth/*`, `auth0.com/api/*`
- **Okta**: `dev-xxx.okta.com/oauth2/*`, `dev-xxx.okta.com/api/*`  
- **AWS Cognito**: `cognito-idp.region.amazonaws.com/region_xxx/*`

**採用理由分析:**
- 顧客（RP）の設定簡素化を最優先
- Discovery標準の活用でエコシステム構築の促進
- 開発者体験（DX）の向上
- **ORY公式推奨パターンとの一致**

### OSS・セルフホスト（別ドメイン派）
- **Keycloak**: `auth.example.com`, `api.example.com`
- **企業内IdP**: セキュリティ境界重視で別ドメイン

**採用理由分析:**
- システム境界の明確化を重視
- 運用チーム分離・責任分界点の明確化
- セキュリティ監査・コンプライアンス対応

---

## 🚀 選択指針・推奨パターン

### 組織規模・要件別推奨

#### スタートアップ・中小規模（～100万ユーザー）
**推奨**: パターン2（同ドメイン・パス分離）

**理由**:
- **RP設定の極限的簡素化**: エコシステム構築の加速
- **運用コスト・人的リソース重視**: SSL・DNS管理の最小化
- **開発・デバッグ効率**: 開発環境での直感的な動作確認

#### 企業・大規模サービス（100万ユーザー～）
**推奨**: パターン1（別ドメイン・マルチドメインnginx）

**理由**:
- **責任分界点の明確化**: 運用チーム分離・監査要件対応
- **高可用性設計**: サービス別での独立した監視・スケーリング
- **セキュリティ境界**: コンプライアンス・監査での明確な境界

### 段階的アプローチ（推奨戦略）
```
Phase 1: 同ドメイン・パス分離でサービス開始
         ↓ (ユーザー数・要件成長に応じて)
Phase 2: 必要に応じて別ドメイン構成へ移行
```

**移行タイミング指標**:
- [ ] 月間アクティブユーザー100万人突破
- [ ] IdP運用チーム・Hydra運用チームの組織分離
- [ ] セキュリティ監査・コンプライアンスでの境界分離要求
- [ ] 証明書・DNS管理コストが許容可能な規模
- [ ] 高可用性要件（99.9%以上）への対応

---

## 💡 同ドメイン構成での運用課題と解決策

### 1. ログ追跡の工夫
```nginx
# nginx access.logでのservice識別
log_format detailed '$remote_addr - $remote_user [$time_local] '
                   '"$request" $status $body_bytes_sent '
                   '"$http_referer" "$http_user_agent" '
                   'service=$service_name upstream=$upstream_addr';

server {
    server_name idp.company.com;
    set $service_name "rails-idp";
    
    location /oauth2/ {
        set $service_name "hydra";
        proxy_pass http://hydra-cluster;
        access_log /var/log/nginx/access.log detailed;
    }
    location /auth/ {
        proxy_pass http://rails-idp-cluster;
        access_log /var/log/nginx/access.log detailed;
    }
}
```

### 2. リクエスト追跡
```nginx
# 統一リクエストIDでの追跡
map $request_id $correlation_id {
    default $request_id;
}

proxy_set_header X-Request-ID $correlation_id;
proxy_set_header X-Correlation-ID $correlation_id;
```

### 3. 健全性チェック設計
```nginx
# サービス別健全性チェックエンドポイント
location /health/rails {
    proxy_pass http://rails-idp-cluster/health;
    access_log off;
}
location /health/hydra {
    proxy_pass http://hydra-cluster/health/ready;
    access_log off;
}
location /health {
    # 複合的な健全性チェック実装
    return 200 "OK\n";
    add_header Content-Type text/plain;
}
```

### 4. 監視・アラート分離
```yaml
# CloudWatch Logs Insights での分離
rails_logs: 'fields @timestamp, @message | filter service_name = "rails-idp"'
hydra_logs: 'fields @timestamp, @message | filter service_name = "hydra"'
```

---

## 🎯 現在のプロジェクトでの推奨方針

### 採用決定: パターン2（同ドメイン・パス分離）

**決定理由**:
1. **ORY公式推奨との完全一致**: Hydra公式チュートリアルと同じパターン採用
2. **RP設定の極限的簡素化**: 外部チームへの導入コスト最小化
3. **現実的な運用開始**: 証明書・DNS管理の簡素化でサービス開始を加速
4. **開発環境一貫性**: 現在のnginx構成との整合性
5. **nginx統合効果最大化**: 今回構築した疎結合アーキテクチャの活用
6. **段階的移行可能性**: 将来の別ドメイン移行余地の確保

### 本番移行時の推奨構成
```
https://idp.company.com/auth/*       → Rails IdP (認証・同意UI)
https://idp.company.com/oauth2/*     → Hydra (OAuth2 API)
https://idp.company.com/userinfo     → Hydra (UserInfo API)
https://idp.company.com/.well-known/ → Hydra (Discovery)
```

**RP側設定例（超シンプル）**:
```ruby
client_options: {
  identifier: ENV['OAUTH_CLIENT_ID'],
  secret: ENV['OAUTH_CLIENT_SECRET'],  
  redirect_uri: ENV['OAUTH_REDIRECT_URI'],
  issuer: 'https://idp.company.com'  # Discovery自動取得で完結
}
```

### 将来の移行判断基準
**別ドメイン移行を検討すべきタイミング**:
- [ ] 月間アクティブユーザー100万人突破
- [ ] IdP運用チーム・Hydra運用チームの組織分離要件
- [ ] セキュリティ監査・コンプライアンスでの境界分離要求
- [ ] ワイルドカード証明書管理コストが許容可能な規模への成長
- [ ] 高可用性要件（99.9%以上SLA）への対応

---

## 📚 実装・運用ドキュメント

### 現在の実装状況
- **nginx設定**: `nginx.conf` - パス分離リバースプロキシ実装済み
- **疎結合アーキテクチャ実証**: `network-architecture-issues.md`
- **nginx導入過程**: `nginx-integration-plan.md`

### 本番環境用nginx設定テンプレート
```nginx
# /etc/nginx/sites-available/idp.company.com
upstream rails-idp-cluster {
    server rails-idp-1:3000;
    server rails-idp-2:3000;
    server rails-idp-3:3000;
}

upstream hydra-cluster {
    server hydra-1:4444;
    server hydra-2:4444;
    server hydra-3:4444;
}

server {
    listen 443 ssl http2;
    server_name idp.company.com;
    
    # SSL設定
    ssl_certificate /etc/ssl/certs/idp.company.com.crt;
    ssl_certificate_key /etc/ssl/private/idp.company.com.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    # セキュリティヘッダー
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    
    # ログ設定
    access_log /var/log/nginx/idp.company.com.access.log detailed;
    error_log /var/log/nginx/idp.company.com.error.log;
    
    # OAuth2 API (Hydra)
    location /oauth2/ {
        proxy_pass http://hydra-cluster;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Request-ID $request_id;
        
        # Hydraタイムアウト設定
        proxy_read_timeout 10s;
        proxy_connect_timeout 5s;
    }
    
    # UserInfo API (Hydra)  
    location /userinfo {
        proxy_pass http://hydra-cluster/userinfo;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Request-ID $request_id;
    }
    
    # Discovery (Hydra)
    location /.well-known/ {
        proxy_pass http://hydra-cluster;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Request-ID $request_id;
        
        # キャッシュ設定
        proxy_cache_valid 200 1h;
    }
    
    # 健全性チェック
    location /health {
        return 200 "OK\n";
        add_header Content-Type text/plain;
        access_log off;
    }
    
    location /health/rails {
        proxy_pass http://rails-idp-cluster/health;
        access_log off;
    }
    
    location /health/hydra {
        proxy_pass http://hydra-cluster/health/ready;
        access_log off;
    }
    
    # Authentication UI (Rails IdP)
    location /auth/ {
        proxy_pass http://rails-idp-cluster;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Request-ID $request_id;
        
        # Rails長時間処理対応
        proxy_read_timeout 30s;
    }
    
    # Default to Rails IdP (管理画面・その他)
    location / {
        proxy_pass http://rails-idp-cluster;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Request-ID $request_id;
    }
}

# HTTPからHTTPSへのリダイレクト
server {
    listen 80;
    server_name idp.company.com;
    return 301 https://$server_name$request_uri;
}
```

### ALB設定例 (Terraform)
```hcl
resource "aws_lb" "idp" {
  name               = "idp-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.idp_alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true
}

resource "aws_lb_target_group" "nginx" {
  name     = "idp-nginx"
  port     = 443
  protocol = "HTTPS"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTPS"
    timeout             = 5
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.idp.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = aws_acm_certificate.idp.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx.arn
  }
}
```

---

**最終更新**: 2025-08-31  
**採用決定**: 同ドメイン・パス分離構成でサービス開始 → 段階的に別ドメイン移行検討  
**次のアクション**: 本番環境でのnginx + ALB + SSL設定の具体化
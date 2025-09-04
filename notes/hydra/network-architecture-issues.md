# IdP開発環境のネットワーク構成問題と本番想定とのギャップ

**作成日**: 2025-08-31
**問題発覚**: nginx導入後のRP側Token Exchange処理でのエラー
**根本問題**: 開発環境での便宜的sso-network構成と本番想定アーキテクチャの乖離

---

## 🚨 発生した問題

### エラー詳細
```
Failed to open TCP connection to localhost:8080 (Connection refused - connect(2) for "localhost" port 8080)
```

**発生箇所**: RP側 OmniAuth処理でのToken Exchange（Authorization Code → Access Token変換）

**エラー発生フロー**:
1. SSO認証フロー正常動作（ブラウザ経由）✅
2. コールバック受信: `http://localhost:3001/auth/sso/callback?code=xxx` ✅
3. **RP内部Token Exchange処理でエラー**❌

### 設定状況
```bash
# RP側 .env.local
HYDRA_PUBLIC_URL=http://localhost:8080           # ブラウザアクセス用（nginx経由）
HYDRA_PUBLIC_URL_INTERNAL=http://idp-hydra-1:4444  # サーバー間通信用（直接Hydra）
```

---

## 🏗️ ネットワーク構成の現状と問題点

### 現在の開発環境構成（問題のある状況）
```
[sso-network - Docker Compose共有ネットワーク]
┌────────────────────────────────────────────────────┐
│  ┌─────┐    ┌─────────────────────────────────┐    │
│  │ RP  │    │        IdP System               │    │
│  │     │ ◄──┤  ┌───────┐ ┌──────┐ ┌───────┐   │    │
│  └─────┘    │  │ nginx │ │ Rails│ │ Hydra │   │    │
│  (3001)     │  │ (8080)│ │(3000)│ │(4444) │   │    │
│             │  └───────┘ └──────┘ └───────┘   │    │
│             └─────────────────────────────────┘    │
└────────────────────────────────────────────────────┘
```

**問題点:**
- **異常な相乗り**: 本来別ネットワークにあるべきRPがIdP内部ネットワークに参加
- **内部構成の露出**: RPがHydraの内部構成（ポート4444等）を知っている
- **疎結合違反**: RPがIdPの実装詳細（Rails+Hydra分離構成）に依存

### 本番想定の正しい構成
```
[外部ネットワーク]            [IdP VPC/ネットワーク]
┌─────────────────┐        ┌─────────────────────────────┐
│   RP System     │        │     IdP System              │
│                 │        │  ┌───────────────────────┐  │
│  ┌─────────────┐│  HTTPS │  │ ┌───────┐ ┌──────┐    │  │
│  │   Rails     ││ ◄──────┤  │ │ nginx │ │ Rails│    │  │
│  │   Backend   ││        │  │ │  (ALB)│ │      │    │  │
│  └─────────────┘│        │  │ └───┬───┘ └───┬──┘    │  │
│                 │        │  │     │         │       │  │
└─────────────────┘        │  │     └─────────┼───────┤  │
                           │  │               │       │  │
                           │  │           ┌───▼───┐   │  │
                           │  │           │ Hydra │   │  │
                           │  │           │(内部)  │   │  │
                           │  │           └───────┘   │  │
                           │  └───────────────────────┘  │
                           └─────────────────────────────┘
```

---

## 🔄 SSO処理における2つの通信パターン

### パターン1: フロントエンド処理（ブラウザ経由）
```
RP Frontend → ブラウザ → IdP nginx → Rails/Hydra
```

**処理内容:**
- OAuth2 Authorization Request (`/oauth2/authorize`)
- 認証画面表示・ユーザー認証
- 同意画面表示・同意処理
- Authorization Code取得・コールバック

**通信の特性:**
- ブラウザが媒介
- 公開URL経由でのアクセス
- CORS・リダイレクト制御が必要

### パターン2: バックエンド処理（サーバー間通信）
```
RP Backend ----直接----> IdP Token Endpoint
```

**処理内容:**
- **Authorization Code → Access Token交換** ←今回のエラー箇所
- Access Token検証・更新
- UserInfo API呼び出し

**通信の特性:**
- サーバー間直接HTTP通信
- `client_secret`使用（フロントエンドでは不可能）
- 高速・セキュアな通信が必要

---

## 🎯 根本問題の分析

### 疎結合設計違反
**現在の問題:**
```bash
# RP側がIdPの内部構成を知っている
HYDRA_PUBLIC_URL_INTERNAL=http://idp-hydra-1:4444  # ❌ 内部実装詳細
```

**あるべき姿:**
```bash
# RP側は公開インターフェースのみ知る
HYDRA_TOKEN_URL=https://idp.company.com/oauth2/token  # ✅ 公開API
```

### アーキテクチャ上の混乱
1. **開発環境便宜性**: sso-network共有による動作確認の簡素化
2. **本番想定乖離**: 別ネットワーク構成での疎結合設計
3. **設定の二重管理**: フロントエンド用・バックエンド用URLの分岐管理

---

## 💡 解決方向性

### 短期解決（現在の開発環境）

#### オプション1: nginx経由統一（推奨）
```bash
# RP側設定統一
HYDRA_PUBLIC_URL=http://localhost:8080      # フロントエンド用
HYDRA_TOKEN_URL=http://localhost:8080       # バックエンド用（nginx経由）
```

**メリット:**
- 完全な疎結合実現
- 本番移行時の設定変更最小化
- IdP内部構成変更の影響なし

#### オプション2: RP内部からnginx接続
```bash
# RP側設定
HYDRA_PUBLIC_URL=http://localhost:8080      # フロントエンド用
HYDRA_TOKEN_URL=http://idp-nginx-1:80       # バックエンド用（Docker内部）
```

### 長期解決（本番想定）

#### サブドメイン分離構成
```bash
# 本番環境設定
HYDRA_PUBLIC_URL=https://oauth.company.com    # 統一エンドポイント
HYDRA_TOKEN_URL=https://oauth.company.com     # 統一エンドポイント
```

**インフラ構成:**
```
https://auth.company.com    → Rails IdP (ALB)
https://oauth.company.com   → Hydra (ALB)
```

---

## 🔧 即座の修正方針

### 1. nginx設定確認
Token Exchange用エンドポイント `/oauth2/token` がnginx経由で正しくHydraにルーティングされているか

### 2. RP側設定統一
```bash
# .env.local修正
HYDRA_PUBLIC_URL=http://localhost:8080
HYDRA_TOKEN_URL=http://localhost:8080        # nginx経由に統一
# HYDRA_PUBLIC_URL_INTERNAL削除            # 内部詳細の排除
```

### 3. 疎通確認
```bash
# RP環境からのToken Endpoint疎通テスト
curl -X POST http://localhost:8080/oauth2/token \
  -d "grant_type=authorization_code&code=test"
```

---

## 📚 学んだ重要な教訓

### アーキテクチャ設計
1. **疎結合の徹底**: クライアントは実装詳細を知るべきではない
2. **ネットワーク境界の明確化**: 開発環境でも本番想定を維持
3. **公開インターフェースの統一**: フロント・バック問わず同じエンドポイント

### 開発環境設計
1. **便宜性と設計原則のバランス**: 動作確認優先も長期的影響を考慮
2. **本番移行コストの早期考慮**: 開発段階での設定統一の重要性
3. **Docker Network設計**: サービス境界とネットワーク境界の一致

### OAuth2/OIDC設計
1. **通信パターンの分類**: フロントエンド vs バックエンド処理の明確化
2. **セキュリティ境界**: `client_secret`使用箇所の適切な分離
3. **エンドポイント統合**: 複数URL管理の複雑性回避

---

## 🚀 次のアクション

### 即座の対応
- [ ] RP側設定の統一（nginx経由）
- [ ] Token Exchange疎通確認
- [ ] 統合動作テスト実施

### 設計改善
- [ ] 本番想定ネットワーク構成の詳細化
- [ ] IdP公開API仕様の明文化
- [ ] 外部RP向けドキュメント整備

---

## 🎯 解決完了（2025-08-31）

### 最終的な修正内容

#### 問題の解決
```bash
# RP側設定
HYDRA_PUBLIC_URL=http://localhost:8080           # ブラウザアクセス用
HYDRA_PUBLIC_URL_INTERNAL=http://idp-nginx-1:80  # サーバー間通信用（nginx経由）
```

#### nginx設定追加
```nginx
# Hydra UserInfo エンドポイント追加
location /userinfo {
    proxy_pass http://hydra:4444/userinfo;
    proxy_set_header Host localhost:8080;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
}
```

### 重要な技術的発見: UserInfo エンドポイントの2種類

#### 1. OIDC標準のUserInfo（Hydra提供）
```
/userinfo → http://hydra:4444/userinfo
```
**特性:**
- OIDC標準仕様（RFC準拠）
- Hydra自動実装（設定不要）
- 汎用的なOIDCクライアントで利用可能
- **今回のRP動作で使用**

#### 2. IdP独自のUserInfo API（Rails実装・移植漏れ）
```
/api/v1/userinfo → http://web:3000/api/v1/userinfo（未実装）
```
**特性:**
- IdP特有の追加情報・ビジネスロジック対応
- Rails実装が必要（移植元: `tmp/rails7/idp_app/app/controllers/api/v1/user_info_controller.rb`）
- カスタマイズ可能な独自仕様

#### 以前動作していた理由
```bash
# 直接Hydra接続時代
HYDRA_PUBLIC_URL_INTERNAL=http://idp-hydra-1:4444
userinfo_endpoint: "http://idp-hydra-1:4444/userinfo"  # Hydra標準を直接利用
```

RPは標準的なOIDCクライアントのため、Hydra標準の`/userinfo`で十分動作していた。

### アーキテクチャ上の意味

#### 疎結合の完全実現
- **RP**: OIDC標準仕様のみ知る
- **nginx**: 内部実装詳細を隠蔽
- **Hydra**: OAuth2/OIDC Provider機能を担当
- **Rails IdP**: 認証・同意画面のUI担当に集中

#### 将来的な拡張性
```nginx
# nginx.conf での統合管理
location /userinfo {
    proxy_pass http://hydra:4444/userinfo;          # OIDC標準
}
location /api/v1/userinfo {
    proxy_pass http://web:3000/api/v1/userinfo;     # 独自仕様（将来実装）
}
```

**両方ともnginx経由でアクセス可能** = 完全な疎結合アーキテクチャの実現

---

**最終更新**: 2025-08-31  
**解決状況**: ✅ 完全解決 - nginx経由での疎結合アーキテクチャ実現  
**関連ドキュメント**:
- `nginx-integration-plan.md` - nginx導入計画・想定漏れ問題
- `production-environment-planning.md` - 本番環境構築計画
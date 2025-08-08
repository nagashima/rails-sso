# 認証方式比較：サーバーセッション vs JWT Cookie

**重要な設計判断**: ログイン情報の管理方法選択

---

## 1. 認証方式の基本概念

### 1.1 サーバーセッション認証
```ruby
# ログイン時
session[:user_id] = user.id
session[:user_name] = user.name
session[:user_email] = user.email

# 認証チェック時
def current_user
  return nil unless session[:user_id]
  @current_user ||= OpenStruct.new(
    id: session[:user_id],
    name: session[:user_name],    # ← セッションから取得（DB負荷なし）
    email: session[:user_email]
  )
end
```

### 1.2 JWT Cookie認証
```ruby
# ログイン時
jwt_token = JWT.encode(
  { user_id: user.id, exp: 30.minutes.from_now.to_i },
  Rails.application.secret_key_base
)
cookies.signed[:auth_token] = jwt_token

# 認証チェック時
def current_user
  payload = JWT.decode(token, secret).first
  @current_user = User.find(payload['user_id'])  # ← 毎回DB問い合わせ
end
```

---

## 2. 詳細比較分析

### 2.1 DB負荷・パフォーマンス

| 項目 | サーバーセッション | JWT Cookie |
|------|-------------------|------------|
| **認証時のDB負荷** | 初回ログイン時のみ | **リクエスト毎** |
| **ユーザー情報取得** | セッションから即座取得 | **毎回DB SELECT** |
| **レスポンス時間** | 高速（メモリアクセス） | 遅い（DB + ネットワーク） |

#### パフォーマンス試算
```
📊 1000人同時ログインユーザー、毎分10リクエストの場合

サーバーセッション:
└─ DB負荷: 1000回/ログイン時のみ
└─ メモリ使用: 100KB/ユーザー × 1000 = 100MB

JWT Cookie:
└─ DB負荷: 1000×10 = 10,000回/分 (継続的)
└─ DB接続プール圧迫リスク
└─ レスポンス遅延: +1-3ms/リクエスト
```

### 2.2 スケーラビリティ

| 項目 | サーバーセッション | JWT Cookie |
|------|-------------------|------------|
| **水平スケーリング** | セッション共有が必要 | **完全独立** |
| **ロードバランサー** | Sticky Sessions必要 | **自由分散可能** |
| **複数サーバー運用** | Redis/DB共有ストア必要 | **設定不要** |
| **マイクロサービス** | 認証サーバー依存 | **ステートレス連携** |

#### 構成例

**サーバーセッション構成:**
```
Load Balancer (Sticky Sessions)
├─ App Server 1 ← Redis Session Store → App Server 2
└─ App Server 3 ← Redis Session Store → App Server 4
                        ↑
                   単一障害点リスク
```

**JWT Cookie構成:**
```
Load Balancer (Round Robin)
├─ App Server 1 (独立動作)
├─ App Server 2 (独立動作)  
├─ App Server 3 (独立動作)
└─ App Server 4 (独立動作)
        ↑
    セッション共有不要
```

### 2.3 セキュリティ

| セキュリティ項目 | サーバーセッション | JWT Cookie |
|------------------|-------------------|------------|
| **即座ログアウト** | ✅ session.clear | ❌ JWT期限まで有効 |
| **権限変更反映** | ✅ 即座反映 | ❌ JWT期限まで反映されない |
| **セッション固定** | ✅ regenerate_id可能 | ⚠️ JWTローテーション複雑 |
| **情報漏洩リスク** | サーバー側のみ | クライアント側にデータ |

#### セキュリティ課題例
```ruby
# 権限変更の反映タイムラグ
user.update(role: 'admin')  # DB更新

# サーバーセッション: 次回リクエストで即座反映
session[:user_role] = 'admin'

# JWT Cookie: 最大30分間古い権限で動作
jwt_payload = { user_id: 42, role: 'user', exp: 30.min.from_now }
# ↑ JWTが期限切れるまで古い'user'権限が有効
```

### 2.4 実装複雑度・保守性

| 項目 | サーバーセッション | JWT Cookie |
|------|-------------------|------------|
| **初期実装** | Rails標準（簡単） | JWT gem + 設定必要 |
| **ログアウト処理** | `session.clear` | Cookie削除 + 無効化ロジック |
| **期限管理** | セッション期限のみ | JWT期限 + セッション期限 |
| **デバッグ** | セッション内容確認容易 | JWT decode必要 |

---

## 3. 使い分け判断基準

### 3.1 サーバーセッション推奨ケース

#### ✅ **適用場面**
- **モノリシックアーキテクチャ**
- **大量同時アクセス**（DB負荷を避けたい）
- **リアルタイム権限変更**が必要
- **セキュリティ優先**（即座無効化重要）
- **実装コスト削減**

#### 📝 **実装例**
```ruby
# 会員制ECサイト
class ApplicationController < ActionController::Base
  def current_user
    return nil unless session[:user_id]
    @current_user ||= User.find(session[:user_id])
  rescue ActiveRecord::RecordNotFound
    session.clear
    nil
  end
end

# メリット活用例
def admin_required
  redirect_to root_path unless current_user&.admin?
  # ↑ DB問い合わせなし、高速判定
end
```

### 3.2 JWT Cookie推奨ケース

#### ✅ **適用場面**
- **マイクロサービスアーキテクチャ**
- **API中心設計**（SPA、モバイルアプリ）
- **水平スケーリング**重視
- **複数サーバー・複数リージョン**展開
- **ステートレス**設計要件

#### 📝 **実装例**
```ruby
# API Gateway + マイクロサービス
class ApiController < ActionController::API
  def current_user
    payload = JWT.decode(auth_token, secret).first
    @current_user = UserService.find_user(payload['user_id'])
    # ↑ 各マイクロサービスが独立してユーザー情報取得
  end
end

# メリット活用例
# 認証サーバー、ユーザーサービス、注文サービスが独立運用可能
```

### 3.3 ハイブリッド方式

#### 🔄 **組み合わせパターン**
```ruby
# セッション + JWT の使い分け
class ApplicationController < ActionController::Base
  def current_user
    # Web画面: サーバーセッション
    if request.format.html?
      return session_based_user
    end
    
    # API: JWT Cookie
    if request.format.json?
      return jwt_based_user
    end
  end
end
```

---

## 4. パフォーマンス改善策

### 4.1 JWT Cookie最適化

#### **A. JWTペイロード拡張**
```ruby
def set_jwt_cookie(user)
  jwt_token = JWT.encode({
    user_id: user.id,
    name: user.name,           # よく使う情報を含める
    email: user.email,
    role: user.role,
    permissions: user.permissions,
    exp: 30.minutes.from_now.to_i
  }, secret)
end

# DB問い合わせ削減
def current_user
  payload = JWT.decode(token, secret).first
  @current_user = OpenStruct.new(payload.except('exp'))
  # ↑ DB問い合わせなし
end
```

**トレードオフ**: JWTサイズ増大 vs DB負荷削減

#### **B. Redis キャッシュ併用**
```ruby
def current_user
  payload = JWT.decode(token, secret).first
  user_id = payload['user_id']
  
  # 5分間キャッシュ
  @current_user = Rails.cache.fetch("user:#{user_id}", expires_in: 5.minutes) do
    User.find(user_id)
  end
end
```

**効果**: DB負荷 90% 削減（キャッシュヒット時）

### 4.2 サーバーセッション最適化

#### **Redis セッションストア**
```ruby
# config/initializers/session_store.rb
Rails.application.config.session_store :redis_store, {
  servers: ["redis://localhost:6379/0/session"],
  expire_after: 1.hour,
  key: '_idp_session'
}
```

---

## 5. 実際の選択例

### 5.1 大手サービスの選択

| サービス例 | 認証方式 | 選択理由 |
|------------|----------|----------|
| **GitHub** | サーバーセッション | Web中心、セキュリティ優先 |
| **Twitter API** | JWT (OAuth2) | API中心、スケール重視 |
| **Slack** | ハイブリッド | Web+API両対応 |
| **Netflix** | JWT | グローバル分散、マイクロサービス |

### 5.2 本プロジェクトでの選択

#### **現在の実装**: JWT Cookie
**選択理由**:
- SSO用途（複数アプリ間連携）
- ORY Hydra連携（ステートレス要件）
- React化準備（API認証統一）

#### **トレードオフ受容**:
- DB負荷増加 → **小規模～中規模で許容範囲**
- リアルタイム性不足 → **一般的な会員サイトで問題なし**

---

## 6. 実装時のベストプラクティス

### 6.1 JWT Cookie使用時の注意点

```ruby
# ✅ 推奨実装
class ApplicationController < ActionController::Base
  # リクエスト内キャッシュ
  def current_user
    return @current_user if defined?(@current_user)
    @current_user = authenticate_with_jwt
  end
  
  # 重要情報は都度DB確認
  def require_admin
    user = User.find(current_user.id)  # 最新の権限を確認
    redirect_to root_path unless user.admin?
  end
  
  # 適切なJWT期限設定
  JWT_EXPIRATION = 30.minutes  # 長すぎず短すぎず
end
```

### 6.2 サーバーセッション使用時の注意点

#### **Rails標準のセッション期限設定**
```ruby
# config/initializers/session_store.rb
Rails.application.config.session_store :cookie_store, 
  expire_after: 1.hour  # Rails標準の期限設定
```

#### **追加のセッション管理（必要に応じて独自実装）**
```ruby
# ✅ 推奨実装
class ApplicationController < ActionController::Base
  # カスタムセッション期限チェック（独自実装）
  before_action :check_custom_session_expiry
  
  # ユーザー情報の定期更新
  def current_user
    return @current_user if defined?(@current_user)
    
    if session[:user_id] && session[:last_updated] < 10.minutes.ago
      update_session_user_data  # 定期的にDB同期（独自実装）
    end
    
    @current_user = build_user_from_session  # 独自実装
  end
  
  private
  
  # カスタム期限チェック（開発者が実装）
  def check_custom_session_expiry
    if session[:last_activity] && 
       session[:last_activity] < 30.minutes.ago
      session.clear
      redirect_to login_path, alert: 'セッションが期限切れです'
    else
      session[:last_activity] = Time.current
    end
  end
  
  # セッションのユーザー情報更新（開発者が実装）
  def update_session_user_data
    user = User.find(session[:user_id])
    session[:user_name] = user.name
    session[:user_email] = user.email
    session[:last_updated] = Time.current
  rescue ActiveRecord::RecordNotFound
    session.clear
  end
  
  # セッションからユーザーオブジェクト構築（開発者が実装）
  def build_user_from_session
    return nil unless session[:user_id]
    
    OpenStruct.new(
      id: session[:user_id],
      name: session[:user_name],
      email: session[:user_email]
    )
  end
end
```

**注意**: 上記のカスタムメソッドは全て開発者による独自実装が必要です。Rails標準では基本的なセッション期限管理（`expire_after`）のみ提供されています。

---

## 7. 結論

### 判断フローチャート

```
認証方式選択
├─ スケール要件？
│  ├─ 大規模・分散 → JWT Cookie
│  └─ 小中規模・単体 → サーバーセッション
├─ アーキテクチャ？
│  ├─ マイクロサービス → JWT Cookie  
│  └─ モノリシック → サーバーセッション
├─ セキュリティ要件？
│  ├─ 即座無効化必須 → サーバーセッション
│  └─ 標準的 → どちらでも可
└─ 開発コスト？
   ├─ 削減優先 → サーバーセッション
   └─ 将来拡張性優先 → JWT Cookie
```

**重要**: どちらも有効な選択肢。**プロジェクトの特性と要件に応じた判断が重要**。

---

**更新履歴**:
- 2025-08-06: 初版作成（JWT Cookie vs サーバーセッション比較分析）
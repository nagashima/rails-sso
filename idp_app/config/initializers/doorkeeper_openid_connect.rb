# frozen_string_literal: true

Doorkeeper::OpenidConnect.configure do
  # iss（Issuer）の設定
  issuer { "http://localhost:3000" }

  # subject_types_supportedの設定
  subject_types_supported [:public]

  # JWT署名用のRSA秘密キー設定（文字列として渡す）
  signing_key File.read('/app/config/keys/private_key.pem')
  
  # JWT署名アルゴリズムの設定（RSA256）
  signing_algorithm :rs256
  
  # Key ID の設定（JWKSと一致させる）
  # signing_key_id "doorkeeper-rsa-key"  # メソッドが存在しない場合はコメントアウト

  # UserInfoエンドポイントで返すクレーム設定
  claims do
    claim :email, scope: :email do |user|
      user.email
    end

    claim :name, scope: :profile do |user|
      user.name
    end

    claim :date_of_birth, scope: :profile do |user|
      user.date_of_birth&.strftime('%Y-%m-%d')
    end

    claim :address, scope: :profile do |user|
      user.address if user.address.present?
    end

    claim :phone_number, scope: :profile do |user|
      user.phone_number if user.phone_number.present?
    end
  end

  # リソースオーナーがcurrent_userであることを定義
  resource_owner_from_access_token do |access_token|
    User.find(access_token.resource_owner_id) if access_token&.resource_owner_id
  end

  # subject（ユーザー識別子）の定義
  subject do |resource_owner, application|
    resource_owner.id.to_s
  end

  # 認証時刻の定義
  auth_time_from_resource_owner do |resource_owner|
    # 現在時刻を返す（実際の実装では最後の認証時刻を返すべき）
    Time.current.to_i
  end
end
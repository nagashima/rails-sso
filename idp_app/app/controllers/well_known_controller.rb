class WellKnownController < ApplicationController
  # JWKSエンドポイント - OpenID Connect標準
  # GET /.well-known/jwks.json
  def jwks
    render json: jwks_data
  end

  private

  def jwks_data
    {
      keys: [
        {
          kty: "RSA",
          use: "sig", 
          kid: generate_key_id,  # 動的にKey ID生成
          alg: "RS256",
          n: rsa_public_key_modulus,
          e: rsa_public_key_exponent
        }
      ]
    }
  end

  # RSA公開鍵のmodulus (n) をBase64URL形式で取得
  def rsa_public_key_modulus
    public_key = OpenSSL::PKey::RSA.new(File.read('/app/config/keys/public_key.pem'))
    Base64.urlsafe_encode64(public_key.n.to_s(2), padding: false)
  end

  # RSA公開鍵のexponent (e) をBase64URL形式で取得  
  def rsa_public_key_exponent
    public_key = OpenSSL::PKey::RSA.new(File.read('/app/config/keys/public_key.pem'))
    Base64.urlsafe_encode64(public_key.e.to_s(2), padding: false)
  end

  # Key ID生成（Doorkeeperのデフォルトに合わせる）
  def generate_key_id
    # Doorkeeperは通常kidを設定しないか、固定値を使用
    # まずは空文字列で試す（kidなしの場合もある）
    ""
  end
end
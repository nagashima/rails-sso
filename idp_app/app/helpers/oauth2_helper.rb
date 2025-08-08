module Oauth2Helper
  def scope_description(scope)
    descriptions = {
      'openid' => 'OpenID Connect による認証',
      'profile' => 'プロフィール情報（氏名、生年月日）',
      'email' => 'メールアドレス',
      'address' => '住所情報', 
      'phone' => '電話番号'
    }
    
    descriptions[scope] || scope
  end
end
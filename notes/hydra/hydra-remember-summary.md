# Hydra の Remember 機能まとめ

## 1. Hydra のリダイレクト挙動

- RP からの認証リクエストがあると、Hydra は **必ず** IdP の `login` エンドポイントにリダイレクトします。  
  例えセッションがあっても、このリダイレクト自体は省略されません。  
  Hydra が「skipできる」と判断した場合は、IdP 側で UI を出さずに即 `accept` を返すことでスムーズに進められます。  
  → 仕様的にもそうなっており、Hydraはあくまでブローカーとしてloginの確認を常に要求します（例：[Oryドキュメント – カスタムログイン・コンセント](https://www.ory.sh/docs/oauth2-oidc/custom-login-consent/flow)）。

- 同様に、Hydra は **必ず** IdP の `consent` エンドポイントにリダイレクトします。  
  過去に同意済みのクライアント＋スコープであれば、`consent_request["skip"] == true` となり UI をスキップできますが、**リダイレクト自体は発生します**。  
  → `skip_consent = true`（クライアント設定）も同様の扱いです（例：[Oryドキュメント – Skip Consent](https://www.ory.sh/docs/oauth2-oidc/skip-consent)）。

---

## 2. Remember の役割

### ログイン (Login Remember)
- IdP からの `acceptOAuth2LoginRequest` において渡せるパラメータ：  
  ```json
  { "remember": true, "remember_for": <秒数> }
  ```
- その結果、Hydra は「この subject はこのブラウザでログイン済み」と記録し、次回のlogin_requestで `skip: true` を返せるようになります。  
- ただし、**login へのリダイレクトを省略する訳ではありません**。UIをスキップできるだけです。  
  → この挙動も仕様に記載されています（例：[Oryドキュメント – カスタムログイン・コンセント](https://www.ory.sh/docs/oauth2-oidc/custom-login-consent/flow)）。

### コンセント (Consent Remember)
- 同様に、IdP からの `acceptOAuth2ConsentRequest` に渡せるパラメータ：  
  ```json
  { "remember": true, "remember_for": <秒数> }
  ```
- 結果として、同じ client_id + subject + scope で次回以降のリクエストがあった場合、`consent_request.skip == true` となり同意画面をスキップ可能。  
- ただし、**consent へのリダイレクト自体は必ず発生**します。  
  → 詳細は上記ドキュメントもしくは公式APIリファレンスに解説あり。

---

## 3. まとめ

| キャッシュ対象         | 作用の概要                            | リダイレクトは省略されるか？         |
|----------------------|----------------------------------|----------------------------|
| Login（認証状態）       | UIをスキップできる状態を記憶            | いいえ（login のたびにリダイレクトが発生） |
| Consent（同意状態）     | 同意画面のスキップ可能状態を記憶         | いいえ（consent のたびにリダイレクトが発生） |

- **`remember` は "画面スキップ状態を記憶する" 機構**であり、**リダイレクトを省く機能ではありません**。
- Hydra を stateless broker として設計し、UIの省略のみを remember に委ねるのがベストプラクティスです。

---

##  利用している主な情報源

- [Ory Hydra ドキュメント — Custom login & consent flow](https://www.ory.sh/docs/oauth2-oidc/custom-login-consent/flow)  
- [Ory Hydra ドキュメント — Skip Consent](https://www.ory.sh/docs/oauth2-oidc/skip-consent)  
- Ory Medium ブログや GitHub Issues などの実例・FAQ（仕様根拠として参照されることが多いです）

Rails.application.routes.draw do
  get 'home/index'
  
  # 開発環境でのメール確認用（Letter Opener Web）
  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end
  
  # 新規登録ワークフロー（具体的なパスを先に配置）
  get 'users/new', to: 'users/new#new'
  post 'users/new', to: 'users/new#create'
  get 'users/new/confirm', to: 'users/new#confirm'
  post 'users/new/register', to: 'users/new#register'
  get 'users/new/complete', to: 'users/new#complete'
  
  # 編集ワークフロー
  get 'users/edit', to: 'users/edit#edit'
  post 'users/edit', to: 'users/edit#create'
  get 'users/edit/confirm', to: 'users/edit#confirm'
  post 'users/edit/update', to: 'users/edit#update'
  get 'users/edit/complete', to: 'users/edit#complete'

  # メール認証ワークフロー
  get 'users/activate/:token', to: 'users/activation#activate', as: :users_activate
  get 'users/activated', to: 'users/activation#activated', as: :users_activated
  
  # ログインワークフロー
  get 'login', to: 'sessions/login#login'
  post 'login', to: 'sessions/login#authenticate'
  get 'login/verify', to: 'sessions/login#verification_form'
  post 'login/verify', to: 'sessions/login#verify'
  delete 'logout', to: 'sessions/login#destroy'
  
  # 会員情報表示（最後に配置）
  resources :users, only: [:show]

  # ルートページ
  root "home#index"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end

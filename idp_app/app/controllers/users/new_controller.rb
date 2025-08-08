class Users::NewController < Users::BaseController
  # 新規会員登録フォーム
  def new
    # 確認画面から戻った場合は入力値を復元
    if session[:user_data]
      @user = User.new(session[:user_data])
    else
      @user = User.new
    end
  end

  # 登録確認画面表示
  def create
    @user = User.new(user_params)
    if @user.valid?
      session[:user_data] = user_params.to_h
      render :confirm
    else
      render :new, status: :unprocessable_entity
    end
  end

  # 登録確認画面
  def confirm
    redirect_to users_new_path unless session[:user_data]
    @user = User.new(session[:user_data])
  end

  # 仮登録処理
  def register
    user_data = session[:user_data]
    unless user_data
      redirect_to users_new_path, alert: 'セッションが無効です。最初からやり直してください。'
      return
    end

    @user = User.new(user_data)
    if @user.save
      # 認証トークンを生成してメール送信
      @user.generate_activation_token!
      UserMailer.activation_email(@user).deliver_now
      
      session.delete(:user_data)
      session[:registered_user_id] = @user.id  # 完了画面で使用
      redirect_to users_new_complete_path
    else
      # 保存に失敗した場合は新規登録画面に戻る
      render :new, status: :unprocessable_entity
    end
  end

  # 登録完了画面
  def complete
    user_id = session[:registered_user_id]
    unless user_id
      redirect_to users_new_path, alert: '不正なアクセスです。'
      return
    end
    
    @user = User.find(user_id)
    session.delete(:registered_user_id)  # セッションをクリア
  end
end
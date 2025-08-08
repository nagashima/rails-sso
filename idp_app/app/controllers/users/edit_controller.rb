class Users::EditController < Users::BaseController
  before_action :require_login
  before_action :set_user
  before_action :verify_user_ownership

  # 会員情報編集フォーム
  def edit
    # 確認画面から戻った場合は入力値を復元
    if session[:edit_user_data]
      @user.assign_attributes(session[:edit_user_data])
    end
  end

  # 編集確認画面表示
  def create
    @user.assign_attributes(user_params)
    if @user.valid?
      session[:edit_user_data] = user_params.to_h
      render :confirm
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # 編集確認画面
  def confirm
    redirect_to users_edit_path unless session[:edit_user_data]
    @user.assign_attributes(session[:edit_user_data])
  end

  # 会員情報更新処理
  def update
    user_data = session[:edit_user_data]
    unless user_data
      redirect_to users_edit_path, alert: 'セッションが無効です。最初からやり直してください。'
      return
    end

    if @user.update(user_data)
      session.delete(:edit_user_data)
      session[:updated_user_id] = @user.id  # 完了画面で使用
      redirect_to users_edit_complete_path
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # 更新完了画面  
  def complete
    user_id = session[:updated_user_id]
    unless user_id
      redirect_to users_edit_path, alert: '不正なアクセスです。'
      return
    end
    
    @user = User.find(user_id)
    session.delete(:updated_user_id)  # セッションをクリア
  end

  private

  def set_user
    @user = current_user  # セッションベースなのでIDパラメータ不要
  end
end
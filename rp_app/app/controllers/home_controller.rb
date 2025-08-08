class HomeController < ApplicationController
  skip_before_action :authenticate_user!
  
  def index
    # ログイン済みの場合はプロフィールページにリダイレクト
    redirect_to profile_path if user_signed_in?
  end
end
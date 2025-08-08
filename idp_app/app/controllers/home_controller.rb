class HomeController < ApplicationController
  def index
    # ログイン状態に応じてトップページを表示
    # current_user と logged_in? はApplicationControllerで定義済み
  end
end

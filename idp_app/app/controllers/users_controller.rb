class UsersController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :verify_user_ownership

  # 会員情報詳細表示
  def show
  end

  private

  def set_user
    @user = User.find(params[:id])
  end
end
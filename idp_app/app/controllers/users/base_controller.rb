class Users::BaseController < ApplicationController
  private
  
  def user_params
    params.require(:user).permit(:email, :password, :password_confirmation, :name, :date_of_birth, :address, :phone_number)
  end
end
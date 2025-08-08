class AddEmailVerificationToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :email_verified_at, :datetime
    add_column :users, :activation_token, :string
    add_column :users, :activation_expires_at, :datetime
    
    add_index :users, :activation_token, unique: true
  end
end

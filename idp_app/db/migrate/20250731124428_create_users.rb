class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :email
      t.string :password_digest
      t.string :name
      t.date :date_of_birth
      t.text :address
      t.string :phone_number
      t.string :auth_code
      t.datetime :auth_code_expires_at

      t.timestamps
    end
    add_index :users, :email, unique: true
  end
end

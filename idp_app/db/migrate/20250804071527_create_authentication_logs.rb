class CreateAuthenticationLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :authentication_logs do |t|
      t.references :user, null: true, foreign_key: true
      t.string :event_type
      t.string :ip_address
      t.text :user_agent
      t.text :details
      t.boolean :success
      t.datetime :occurred_at

      t.timestamps
    end
    add_index :authentication_logs, :event_type
    add_index :authentication_logs, :success
    add_index :authentication_logs, :occurred_at
  end
end

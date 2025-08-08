# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2025_08_04_071527) do
  create_table "authentication_logs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "user_id"
    t.string "event_type"
    t.string "ip_address"
    t.text "user_agent"
    t.text "details"
    t.boolean "success"
    t.datetime "occurred_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_type"], name: "index_authentication_logs_on_event_type"
    t.index ["occurred_at"], name: "index_authentication_logs_on_occurred_at"
    t.index ["success"], name: "index_authentication_logs_on_success"
    t.index ["user_id"], name: "index_authentication_logs_on_user_id"
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "email"
    t.string "password_digest"
    t.string "name"
    t.date "date_of_birth"
    t.text "address"
    t.string "phone_number"
    t.string "auth_code"
    t.datetime "auth_code_expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "email_verified_at"
    t.string "activation_token"
    t.datetime "activation_expires_at"
    t.index ["activation_token"], name: "index_users_on_activation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "authentication_logs", "users"
end

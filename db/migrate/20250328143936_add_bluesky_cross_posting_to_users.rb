# frozen_string_literal: true

class AddBlueskyCrossPostingToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :bluesky_cross_posting_enabled, :boolean, default: false, null: false
    add_column :users, :bluesky_handle, :string
    add_column :users, :bluesky_did, :string
    add_column :users, :encrypted_bluesky_password, :string
  end
end

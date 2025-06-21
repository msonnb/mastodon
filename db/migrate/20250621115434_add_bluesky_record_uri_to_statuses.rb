# frozen_string_literal: true

class AddBlueskyRecordUriToStatuses < ActiveRecord::Migration[8.0]
  def change
    add_column :statuses, :bluesky_record_uri, :string
  end
end

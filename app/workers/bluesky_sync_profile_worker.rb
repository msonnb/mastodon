# frozen_string_literal: true

class BlueskySyncProfileWorker
  include Sidekiq::Worker

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.bluesky_cross_posting_enabled? && user.bluesky_did.present?

    Bluesky::SyncProfileService.new.call(user)
  rescue => e
    Rails.logger.error("Error syncing Bluesky profile for user #{user_id}: #{e.message}")
  end
end

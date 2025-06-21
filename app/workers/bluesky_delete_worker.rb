# frozen_string_literal: true

class BlueskyDeleteWorker
  include Sidekiq::Worker

  def perform(bluesky_record_uri, user_id)
    return if bluesky_record_uri.blank?

    user = User.find_by(id: user_id)
    return unless user&.bluesky_cross_posting_enabled? && user.bluesky_did.present?

    Bluesky::DeleteService.new.call(bluesky_record_uri, user)
  rescue => e
    Rails.logger.error("Error deleting Bluesky record #{bluesky_record_uri} for user #{user_id}: #{e.message}")
  end
end

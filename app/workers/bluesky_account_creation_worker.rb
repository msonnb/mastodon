# frozen_string_literal: true

class BlueskyAccountCreationWorker
  include Sidekiq::Worker

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.bluesky_cross_posting_enabled? && user.bluesky_did.blank?

    Bluesky::CreateAccountService.new.call(user)
  rescue => e
    Rails.logger.error("Error creating Bluesky account for user #{user_id}: #{e.message}")
    user&.update(bluesky_cross_posting_enabled: false)
  end
end

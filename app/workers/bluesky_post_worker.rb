# frozen_string_literal: true

class BlueskyPostWorker
  include Sidekiq::Worker

  def perform(status_id)
    status = Status.find_by(id: status_id)
    return unless status&.account&.user&.bluesky_cross_posting_enabled? && status.account.user.bluesky_did.present?

    Bluesky::PostService.new.call(status)
  rescue => e
    Rails.logger.error("Error posting to Bluesky for status #{status_id}: #{e.message}")
  end
end

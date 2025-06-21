# frozen_string_literal: true

class Bluesky::DeleteService < Bluesky::BaseService
  def call(bluesky_record_uri, user)
    @bluesky_record_uri = bluesky_record_uri
    @user = user

    return unless should_delete_from_bluesky?

    initialize_api_url

    begin
      @access_token = authenticate_user(@user)
      delete_record_response = delete_record(@access_token)

      Rails.logger.info("Bluesky record #{@bluesky_record_uri} deleted successfully for user #{@user.id}") if delete_record_response
    rescue Mastodon::UnexpectedResponseError => e
      Rails.logger.error("Failed to delete Bluesky record #{@bluesky_record_uri} for user #{@user.id}: #{e.message}")
    rescue => e
      Rails.logger.error("Unexpected error deleting Bluesky record #{@bluesky_record_uri} for user #{@user.id}: #{e.message}")
    end
  end

  private

  def should_delete_from_bluesky?
    return false if @bluesky_record_uri.blank?
    return false unless @user&.bluesky_cross_posting_enabled?
    return false if @user.bluesky_did.blank?
    return false if @user.encrypted_bluesky_password.blank?

    true
  end

  def delete_record(access_token)
    # Parse the AT URI to extract components
    # Format: at://did:plc:abcd1234/app.bsky.feed.post/rkey123
    uri_parts = parse_at_uri(@bluesky_record_uri)
    return nil unless uri_parts

    data = {
      repo: uri_parts[:repo],
      collection: uri_parts[:collection],
      rkey: uri_parts[:rkey],
    }

    request = Request.new(
      :post,
      "#{@api_url}/com.atproto.repo.deleteRecord",
      body: data.to_json
    )

    request.add_headers({
      'Content-Type' => 'application/json',
      'User-Agent' => 'Mastodon/4.0.0',
      'Authorization' => "Bearer #{access_token}",
    })

    request.perform do |response|
      if response.status == 200
        Rails.logger.info('Bluesky record deleted successfully')
        return true
      else
        Rails.logger.error("Failed to delete Bluesky record: #{response.status} #{response.body}")
        raise Mastodon::UnexpectedResponseError, response
      end
    end
  end

  def parse_at_uri(uri)
    return nil unless uri&.start_with?('at://')

    path = uri[5..]
    parts = path.split('/')

    return nil unless parts.length == 3

    {
      repo: parts[0],
      collection: parts[1],
      rkey: parts[2],
    }
  rescue => e
    Rails.logger.error("Failed to parse AT URI '#{uri}': #{e.message}")
    nil
  end
end

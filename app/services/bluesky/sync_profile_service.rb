# frozen_string_literal: true

class Bluesky::SyncProfileService < Bluesky::BaseService
  def call(user)
    @user = user
    return unless should_sync_profile?

    initialize_api_url

    begin
      @access_token = authenticate_user(@user)
      current_profile = fetch_current_profile(@access_token)

      if current_profile
        @images_uploaded = false
        updated_profile = build_updated_profile(current_profile)
        update_profile(@access_token, updated_profile) if profile_needs_update?(current_profile, updated_profile)
      else
        Rails.logger.warn("Could not fetch current Bluesky profile for user #{@user.id}")
      end

      Rails.logger.info("Bluesky profile sync completed for user #{@user.id}")
    rescue Mastodon::UnexpectedResponseError => e
      Rails.logger.error("Failed to sync Bluesky profile for user #{@user.id}: #{e.message}")
    rescue => e
      Rails.logger.error("Unexpected error syncing Bluesky profile for user #{@user.id}: #{e.message}")
    end
  end

  private

  def should_sync_profile?
    return false unless @user&.bluesky_cross_posting_enabled?
    return false if @user.bluesky_did.blank?
    return false if @user.encrypted_bluesky_password.blank?
    return false unless @user.account&.local?

    true
  end

  def fetch_current_profile(access_token)
    params = {
      repo: @user.bluesky_did,
      collection: 'app.bsky.actor.profile',
      rkey: 'self',
    }

    request = Request.new(
      :get,
      "#{@api_url}/com.atproto.repo.getRecord?#{params.to_query}"
    )

    request.add_headers({
      'User-Agent' => 'Mastodon/4.0.0',
      'Authorization' => "Bearer #{access_token}",
    })

    request.perform do |response|
      if response.status == 200
        body = JSON.parse(response.body)
        Rails.logger.info("Current Bluesky profile fetched successfully for user #{@user.id}")
        return body['value']
      else
        Rails.logger.error("Failed to fetch current Bluesky profile: #{response.status} #{response.body}")
        return nil
      end
    end
  rescue => e
    Rails.logger.error("Error fetching current Bluesky profile for user #{@user.id}: #{e.message}")
    nil
  end

  def build_updated_profile(current_profile)
    updated_profile = current_profile.dup
    updated_profile['displayName'] = @user.account.display_name
    updated_profile['description'] = @user.account.note

    if @user.account.avatar.present?
      if should_upload_avatar?(current_profile)
        begin
          avatar_blob = upload_image(@access_token, @user.account.avatar)
          if avatar_blob
            updated_profile['avatar'] = avatar_blob
            @images_uploaded = true
            Rails.logger.info("Avatar uploaded successfully for user #{@user.id}")
          end
        rescue => e
          Rails.logger.warn("Failed to upload avatar for user #{@user.id}: #{e.message}")
        end
      end
    elsif current_profile.key?('avatar')
      updated_profile.delete('avatar')
      @images_uploaded = true
    end

    if @user.account.header.present?
      if should_upload_header?(current_profile)
        begin
          banner_blob = upload_image(@access_token, @user.account.header)
          if banner_blob
            updated_profile['banner'] = banner_blob
            @images_uploaded = true
            Rails.logger.info("Header/banner uploaded successfully for user #{@user.id}")
          end
        rescue => e
          Rails.logger.warn("Failed to upload header/banner for user #{@user.id}: #{e.message}")
        end
      end
    elsif current_profile.key?('banner')
      updated_profile.delete('banner')
      @images_uploaded = true
    end

    updated_profile
  end

  def profile_needs_update?(current_profile, updated_profile)
    text_changed = current_profile['displayName'] != updated_profile['displayName'] ||
                   current_profile['description'] != updated_profile['description']

    text_changed || @images_uploaded
  end

  def update_profile(access_token, profile_data)
    data = {
      repo: @user.bluesky_did,
      collection: 'app.bsky.actor.profile',
      rkey: 'self',
      record: profile_data,
    }

    request = Request.new(
      :post,
      "#{@api_url}/com.atproto.repo.putRecord",
      body: data.to_json
    )

    request.add_headers({
      'Content-Type' => 'application/json',
      'User-Agent' => 'Mastodon/4.0.0',
      'Authorization' => "Bearer #{access_token}",
    })

    request.perform do |response|
      if response.status == 200
        Rails.logger.info("Bluesky profile updated successfully for user #{@user.id}")
        return true
      else
        Rails.logger.error("Failed to update Bluesky profile: #{response.status} #{response.body}")
        raise Mastodon::UnexpectedResponseError, response
      end
    end
  end

  def should_upload_avatar?(current_profile)
    return true unless current_profile.key?('avatar')

    @user.account.avatar_updated_at.present? &&
      @user.account.avatar_updated_at > 1.hour.ago
  end

  def should_upload_header?(current_profile)
    return true unless current_profile.key?('banner')

    @user.account.header_updated_at.present? &&
      @user.account.header_updated_at > 1.hour.ago
  end

  def upload_image(access_token, image_object)
    unless supported_image_type?(image_object.content_type)
      Rails.logger.warn("Unsupported image type #{image_object.content_type} for user #{@user.id}, skipping")
      return nil
    end

    file_data = get_file_data(
      image_object,
      local: @user.account.local?,
      id: @user.id
    )
    return nil unless file_data

    unless file_size_valid?(file_data)
      Rails.logger.warn("Image size #{file_data.size} bytes exceeds Bluesky limit of #{BLUESKY_MAX_IMAGE_SIZE} bytes for user #{@user.id}")
      return nil
    end

    upload_blob(access_token, file_data, image_object.content_type)
  end
end

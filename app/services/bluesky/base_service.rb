# frozen_string_literal: true

class Bluesky::BaseService < BaseService
  BLUESKY_MAX_IMAGE_SIZE = 1_000_000 # 1MB in bytes
  BLUESKY_SUPPORTED_IMAGE_TYPES = %w(
    image/jpeg
    image/png
  ).freeze

  protected

  def initialize_api_url
    @pds_domain = ENV.fetch('ATPROTO_PDS_DOMAIN')
    @api_url = "https://#{@pds_domain}/xrpc"
  end

  def authenticate_user(user)
    request = Request.new(
      :post,
      "#{@api_url}/com.atproto.server.createSession",
      body: {
        identifier: user.bluesky_handle,
        password: user.encrypted_bluesky_password,
      }.to_json
    )

    request.add_headers({
      'Content-Type' => 'application/json',
      'User-Agent' => 'Mastodon/4.0.0',
    })

    request.perform do |response|
      if response.status == 200
        body = JSON.parse(response.body)
        access_token = body['accessJwt']
        Rails.logger.info("Bluesky authentication successful for user #{user.id}")
        return access_token
      else
        Rails.logger.error("Bluesky authentication failed: #{response.status} #{response.body}")
        raise Mastodon::UnexpectedResponseError, response
      end
    end
  end

  def create_record(access_token, data)
    request = Request.new(
      :post,
      "#{@api_url}/com.atproto.repo.createRecord",
      body: data.to_json
    )

    request.add_headers({
      'Content-Type' => 'application/json',
      'User-Agent' => 'Mastodon/4.0.0',
      'Authorization' => "Bearer #{access_token}",
    })

    request.perform do |response|
      if response.status == 200
        body = JSON.parse(response.body)
        Rails.logger.info('Record created successfully')
        return body
      else
        Rails.logger.error("Failed to create record: #{response.status} #{response.body}")
        raise Mastodon::UnexpectedResponseError, response
      end
    end
  end

  def upload_blob(access_token, file_data, mime_type)
    request = Request.new(
      :post,
      "#{@api_url}/com.atproto.repo.uploadBlob",
      body: file_data
    )

    request.add_headers({
      'Content-Type' => mime_type,
      'User-Agent' => 'Mastodon/4.0.0',
      'Authorization' => "Bearer #{access_token}",
    })

    request.perform do |response|
      if response.status == 200
        body = JSON.parse(response.body)
        Rails.logger.info("Blob uploaded successfully, size: #{file_data.size} bytes")
        return body['blob']
      else
        Rails.logger.error("Failed to upload blob: #{response.status} #{response.body}")
        raise Mastodon::UnexpectedResponseError, response
      end
    end
  end

  def make_api_request(method, endpoint, body: nil, headers: {}, auth_type: nil, auth_value: nil)
    request = Request.new(
      method,
      "#{@api_url}/#{endpoint}",
      body: body&.to_json
    )

    default_headers = {
      'Content-Type' => 'application/json',
      'User-Agent' => 'Mastodon/4.0.0',
    }

    default_headers['Authorization'] = "#{auth_type} #{auth_value}" if auth_type && auth_value

    request.add_headers(default_headers.merge(headers))

    request.perform do |response|
      if response.status == 200
        body = JSON.parse(response.body)
        return body
      else
        Rails.logger.error("API request failed: #{method} #{endpoint} - #{response.status} #{response.body}")
        raise Mastodon::UnexpectedResponseError, response
      end
    end
  end

  def supported_image_type?(content_type)
    BLUESKY_SUPPORTED_IMAGE_TYPES.include?(content_type)
  end

  def file_size_valid?(file_data)
    file_data && file_data.size <= BLUESKY_MAX_IMAGE_SIZE
  end

  def get_file_data(file_object, context_info = {})
    return nil if file_object.blank?

    is_local = context_info[:local] || (file_object.respond_to?(:local?) && file_object.local?)
    object_id = context_info[:id] || (file_object.respond_to?(:id) ? file_object.id : 'unknown')

    if is_local
      get_local_file_data(file_object, object_id)
    else
      get_remote_file_data(file_object, object_id)
    end
  rescue => e
    Rails.logger.error("Failed to get file data for #{object_id}: #{e.message}")
    nil
  end

  private

  def get_local_file_data(file_object, object_id)
    file_path = file_object.respond_to?(:path) ? file_object.path : nil

    if file_path.present? && File.exist?(file_path)
      File.read(file_path)
    elsif file_object.respond_to?(:read)
      file_object.read
    else
      Rails.logger.error("Unable to read local file for #{object_id}")
      nil
    end
  rescue Paperclip::Errors::NotAttachedError
    Rails.logger.error("File not found locally for #{object_id}")
    nil
  end

  def get_remote_file_data(file_object, object_id)
    url = file_object.respond_to?(:url) ? file_object.url(:original) : file_object.to_s

    request = Request.new(:get, url)
    request.perform do |response|
      if response.status.success?
        response.body_with_limit(BLUESKY_MAX_IMAGE_SIZE * 2) # Allow buffer for size check
      else
        Rails.logger.error("Failed to download remote file for #{object_id}: HTTP #{response.status}")
        nil
      end
    end
  rescue Mastodon::LengthValidationError => e
    Rails.logger.error("Remote file for #{object_id} too large: #{e.message}")
    nil
  rescue => e
    Rails.logger.error("Failed to download remote file for #{object_id}: #{e.message}")
    nil
  end
end

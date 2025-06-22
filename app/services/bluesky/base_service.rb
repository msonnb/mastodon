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
    body = make_api_request(
      :post,
      'com.atproto.server.createSession',
      body: {
        identifier: user.bluesky_handle,
        password: user.encrypted_bluesky_password,
      }
    )

    access_token = body['accessJwt']
    Rails.logger.info("Bluesky authentication successful for user #{user.id}")
    access_token
  end

  def create_record(access_token, data)
    body = make_api_request(
      :post,
      'com.atproto.repo.createRecord',
      body: data,
      auth_type: 'Bearer',
      auth_value: access_token
    )

    Rails.logger.info('Record created successfully')
    body
  end

  def upload_blob(access_token, file_data, mime_type)
    body = make_api_request(
      :post,
      'com.atproto.repo.uploadBlob',
      body: file_data,
      headers: { 'Content-Type' => mime_type },
      auth_type: 'Bearer',
      auth_value: access_token,
      raw_body: true
    )

    Rails.logger.info("Blob uploaded successfully, size: #{file_data.size} bytes")
    body['blob']
  end

  def make_api_request(method, endpoint, body: nil, headers: {}, auth_type: nil, auth_value: nil, raw_body: false, query_params: nil)
    url = "#{@api_url}/#{endpoint}"
    url += "?#{query_params.to_query}" if query_params && method.to_s.downcase == 'get'

    request_body = if raw_body
                     body
                   else
                     body&.to_json
                   end

    request = Request.new(
      method,
      url,
      body: request_body
    )

    default_headers = {
      'User-Agent' => 'Mastodon/4.0.0',
    }

    # Only set Content-Type to JSON if not using raw_body and not overridden in headers
    default_headers['Content-Type'] = 'application/json' unless raw_body || headers.key?('Content-Type')

    default_headers['Authorization'] = "#{auth_type} #{auth_value}" if auth_type && auth_value

    request.add_headers(default_headers.merge(headers))

    request.perform do |response|
      if response.status == 200
        JSON.parse(response.body)
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

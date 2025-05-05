# frozen_string_literal: true

class Bluesky::BaseService < BaseService
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
end

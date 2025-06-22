# frozen_string_literal: true

class Bluesky::CreateAccountService < Bluesky::BaseService
  def call(user)
    @user = user
    initialize_api_url
    handle = "#{@user.account.username}.#{@pds_domain}"
    password = SecureRandom.hex(16)

    invite_code = create_invite_code
    did, actual_handle = create_account(@user.email, handle, password, invite_code)
    return unless did && actual_handle

    @user.update!(
      bluesky_did: did,
      bluesky_handle: actual_handle,
      encrypted_bluesky_password: password
    )

    access_token = authenticate_user(@user)

    profile_data = {
      createdAt: Time.current.iso8601,
      displayName: @user.account.display_name,
      description: @user.account.note,
    }

    if @user.account.avatar.present?
      begin
        avatar_blob = upload_image(access_token, @user.account.avatar)
        profile_data[:avatar] = avatar_blob if avatar_blob
        Rails.logger.info("Avatar uploaded successfully for user #{@user.id}")
      rescue => e
        Rails.logger.warn("Failed to upload avatar for user #{@user.id}: #{e.message}")
      end
    end

    if @user.account.header.present?
      begin
        banner_blob = upload_image(access_token, @user.account.header)
        profile_data[:banner] = banner_blob if banner_blob
        Rails.logger.info("Header/banner uploaded successfully for user #{@user.id}")
      rescue => e
        Rails.logger.warn("Failed to upload header/banner for user #{@user.id}: #{e.message}")
      end
    end

    data = {
      repo: did,
      collection: 'app.bsky.actor.profile',
      rkey: 'self',
      record: profile_data,
    }
    create_record(access_token, data)

    Rails.logger.info("Bluesky account created successfully for user #{@user.id} with handle #{actual_handle}")
  end

  private

  def create_invite_code
    admin_password = ENV.fetch('ATPROTO_PDS_ADMIN_PASS')
    basic_auth = Base64.strict_encode64("admin:#{admin_password}")

    response = make_api_request(
      :post,
      'com.atproto.server.createInviteCode',
      body: { useCount: 1 },
      auth_type: 'Basic',
      auth_value: basic_auth
    )

    invite_code = response['code']
    Rails.logger.info("Invite code created successfully: #{invite_code}")
    invite_code
  end

  def create_account(email, handle, password, invite_code)
    response = make_api_request(
      :post,
      'com.atproto.server.createAccount',
      body: {
        email: email,
        handle: handle,
        password: password,
        inviteCode: invite_code,
      }
    )

    did = response['did']
    actual_handle = response['handle']
    Rails.logger.info("Account created successfully: #{did} #{actual_handle}")
    [did, actual_handle]
  end
end

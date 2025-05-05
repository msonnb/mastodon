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
    data = {
      repo: did,
      collection: 'app.bsky.actor.profile',
      rkey: 'self',
      record: {
        createdAt: Time.current.iso8601,
        displayName: @user.account.display_name,
        description: @user.account.note,
      },
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

# frozen_string_literal: true

class Bluesky::PostService < Bluesky::BaseService
  def call(status)
    @status = status
    @user = @status.account.user
    initialize_api_url

    access_token = authenticate_user(@user)
    record = prepare_record

    data = {
      repo: @user.bluesky_did,
      collection: 'app.bsky.feed.post',
      record: record,
    }

    create_record(access_token, data)
    Rails.logger.info("Post created successfully on Bluesky for user #{@user.id}")
  end

  private

  def prepare_record
    text = prepare_text(@status.text)

    {
      text: text,
      createdAt: @status.created_at.iso8601,
    }
  end

  def prepare_text(mastodon_text)
    plain_text = ActionView::Base.full_sanitizer.sanitize(mastodon_text, tags: [])
    plain_text = CGI.unescapeHTML(plain_text)

    if plain_text.length > 300
      truncated_length = 300 - 4
      plain_text = "#{plain_text[0...truncated_length]}..."
    end

    plain_text
  end
end

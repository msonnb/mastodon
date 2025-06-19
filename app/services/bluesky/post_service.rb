# frozen_string_literal: true

class Bluesky::PostService < Bluesky::BaseService
  BLUESKY_IMAGE_LIMIT = 4
  BLUESKY_MEDIA_SUPPORTED_IMAGE_TYPES = (BLUESKY_SUPPORTED_IMAGE_TYPES + %w(
    image/webp
    image/gif
  )).freeze

  def call(status)
    @status = status
    @user = @status.account.user
    initialize_api_url

    @access_token = authenticate_user(@user)
    record = prepare_record

    data = {
      repo: @user.bluesky_did,
      collection: 'app.bsky.feed.post',
      record: record,
    }

    create_record(@access_token, data)
    Rails.logger.info("Post created successfully on Bluesky for user #{@user.id}")
  end

  private

  def prepare_record
    text = prepare_text(@status.text)
    record = {
      text: text,
      createdAt: @status.created_at.iso8601,
    }

    if @status.with_media?
      embed = process_media_attachments
      record[:embed] = embed if embed
    end

    record
  end

  def process_media_attachments
    media_attachments = @status.ordered_media_attachments

    image_attachments = media_attachments.select(&:image?).take(BLUESKY_IMAGE_LIMIT)
    other_media = media_attachments.reject(&:image?)

    if other_media.any?
      media_types = other_media.map(&:type).uniq
      Rails.logger.info("Skipping #{other_media.count} non-image media attachments (types: #{media_types.join(', ')}) for Bluesky post")
    end

    return nil if image_attachments.empty?

    uploaded_blobs = []

    image_attachments.each do |attachment|
      begin
        if attachment.not_processed?
          Rails.logger.warn("Media attachment #{attachment.id} still processing, skipping")
          next
        end

        blob_data = upload_media_attachment(attachment)
        uploaded_blobs << blob_data if blob_data
      rescue Mastodon::UnexpectedResponseError => e
        Rails.logger.error("Bluesky API error uploading attachment #{attachment.id}: #{e.message}")
      rescue => e
        Rails.logger.error("Failed to upload media attachment #{attachment.id}: #{e.message}")
      end
    end

    if uploaded_blobs.empty?
      Rails.logger.warn('No media attachments could be uploaded to Bluesky')
      return nil
    end

    create_image_embed(uploaded_blobs)
  end

  def upload_media_attachment(attachment)
    unless BLUESKY_MEDIA_SUPPORTED_IMAGE_TYPES.include?(attachment.file_content_type)
      Rails.logger.warn("Unsupported image type #{attachment.file_content_type} for attachment #{attachment.id}, skipping")
      return nil
    end

    file_data = get_file_data(
      attachment.file,
      local: attachment.local?,
      id: attachment.id
    )
    return nil unless file_data

    unless file_size_valid?(file_data)
      Rails.logger.warn("Media attachment #{attachment.id} size #{file_data.size} bytes exceeds Bluesky limit of #{BLUESKY_MAX_IMAGE_SIZE} bytes")
      return nil
    end

    blob = upload_blob(@access_token, file_data, attachment.file_content_type)

    embed_data = {
      alt: attachment.description.presence || '',
      image: blob,
    }

    aspect_ratio = extract_aspect_ratio(attachment)
    embed_data[:aspectRatio] = aspect_ratio if aspect_ratio

    embed_data
  end

  def extract_aspect_ratio(attachment)
    return nil if attachment.file_meta.blank?

    original_meta = attachment.file_meta['original']
    return nil unless original_meta

    width = original_meta['width']
    height = original_meta['height']

    { width: width, height: height } if width && height && width.positive? && height.positive?
  end

  def create_image_embed(uploaded_blobs)
    {
      '$type' => 'app.bsky.embed.images',
      'images' => uploaded_blobs,
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

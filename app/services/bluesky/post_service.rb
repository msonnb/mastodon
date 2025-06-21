# frozen_string_literal: true

class Bluesky::PostService < Bluesky::BaseService
  BLUESKY_IMAGE_LIMIT = 4
  BLUESKY_MEDIA_SUPPORTED_IMAGE_TYPES = (BLUESKY_SUPPORTED_IMAGE_TYPES + %w(
    image/webp
    image/gif
  )).freeze
  BLUESKY_SUPPORTED_VIDEO_TYPES = %w(
    video/mp4
  ).freeze
  BLUESKY_MAX_VIDEO_SIZE = 50_000_000

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

    facets = extract_facets(text)
    record[:facets] = facets if facets&.any?

    if @status.with_media?
      embed = process_media_attachments
      record[:embed] = embed if embed
    end

    record
  end

  def extract_facets(text)
    facets = []
    link_facets = detect_links(text)
    facets.concat(link_facets) if link_facets.any?

    mention_facets = detect_mentions(text)
    facets.concat(mention_facets) if mention_facets.any?

    facets
  end

  def detect_links(text)
    facets = []
    matches = []
    text.scan(URI::RFC2396_PARSER.make_regexp(['http', 'https'])) { matches << Regexp.last_match }

    matches.each do |match|
      start, stop = match.byteoffset(0)
      url = match[0]

      cleaned_url = clean_url(url)

      next if cleaned_url.empty?

      if cleaned_url != url
        prefix = text[0...match.begin(0)]
        start = prefix.encode('UTF-8').bytesize
        stop = start + cleaned_url.encode('UTF-8').bytesize
      end

      facets << {
        index: {
          byteStart: start,
          byteEnd: stop,
        },
        features: [
          {
            '$type' => 'app.bsky.richtext.facet#link',
            :uri => cleaned_url,
          },
        ],
      }
    end

    domain_matches = []
    domain_regex = %r{(?<!\w|://)([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?=\s|$|[^\w\-.])}i

    text.scan(domain_regex) { domain_matches << Regexp.last_match }

    domain_matches.each do |match|
      domain = match[0]

      next if matches.any? { |http_match| http_match[0].include?(domain) }

      next unless valid_domain?(domain)

      start, stop = match.byteoffset(0)

      facets << {
        index: {
          byteStart: start,
          byteEnd: stop,
        },
        features: [
          {
            '$type' => 'app.bsky.richtext.facet#link',
            :uri => "https://#{domain}",
          },
        ],
      }
    end

    facets
  end

  def detect_mentions(text)
    facets = []
    mentioned_accounts_by_acct = @status.mentioned_accounts.index_by(&:acct)

    text.scan(Account::MENTION_RE) do |match|
      full_match = Regexp.last_match
      username_with_domain = match[0]
      mentioned_account = mentioned_accounts_by_acct[username_with_domain]
      next unless mentioned_account

      start_pos, end_pos = full_match.byteoffset(0)
      profile_url = ActivityPub::TagManager.instance.url_for(mentioned_account)
      next unless profile_url

      facets << {
        index: {
          byteStart: start_pos,
          byteEnd: end_pos,
        },
        features: [
          {
            '$type' => 'app.bsky.richtext.facet#link',
            :uri => profile_url,
          },
        ],
      }
    end

    facets
  end

  def clean_url(url)
    cleaned = url.gsub(/[.,;!?]+$/, '')
    cleaned = cleaned[0...-1] if cleaned.end_with?(')') && !cleaned.include?('(')

    cleaned
  end

  def prepare_uri(url)
    if !url.match?(%r{^https?://}) && valid_domain?(url)
      "https://#{url}"
    else
      url
    end
  end

  def valid_domain?(domain_string)
    return false unless domain_string.include?('.')

    parts = domain_string.split('.')
    return false if parts.length < 2

    tld = parts.last.downcase
    tld.match?(/^[a-z]{2,6}$/)
  end

  def process_media_attachments
    media_attachments = @status.ordered_media_attachments

    video_attachment = media_attachments.find(&:video?)
    return process_video_attachment(video_attachment) if video_attachment

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

  def process_video_attachment(attachment)
    if attachment.not_processed?
      Rails.logger.warn("Video attachment #{attachment.id} still processing, skipping")
      return nil
    end

    unless BLUESKY_SUPPORTED_VIDEO_TYPES.include?(attachment.file_content_type)
      Rails.logger.warn("Unsupported video type #{attachment.file_content_type} for attachment #{attachment.id}, skipping")
      return nil
    end

    video_file_data = get_file_data(
      attachment.file,
      local: attachment.local?,
      id: attachment.id
    )
    unless video_file_data
      Rails.logger.warn("Could not read video file data for attachment #{attachment.id}")
      return nil
    end

    if video_file_data.size > BLUESKY_MAX_VIDEO_SIZE
      Rails.logger.warn("Video attachment #{attachment.id} size #{video_file_data.size} bytes exceeds Bluesky limit of #{BLUESKY_MAX_VIDEO_SIZE} bytes")
      return nil
    end

    video_blob = upload_blob(@access_token, video_file_data, attachment.file_content_type)
    alt_text = attachment.description.presence || ''
    aspect_ratio = extract_aspect_ratio(attachment)

    create_video_embed(video_blob, alt_text, aspect_ratio)
  end

  def create_video_embed(video_blob, alt_text, aspect_ratio)
    embed = {
      '$type' => 'app.bsky.embed.video',
      'video' => video_blob,
      'alt' => alt_text,
    }
    embed['aspectRatio'] = aspect_ratio if aspect_ratio
    embed
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

    if file_data.size > BLUESKY_MAX_IMAGE_SIZE
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

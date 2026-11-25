class Api::V1::CorporateFilesController < ActionController::Base # rubocop:disable Rails/ApplicationController -- Media uses its own scoped encrypted cookie.
  def show
    attachment = authorised_attachment
    return head :locked unless attachment.meta.to_h['scan_state'] == 'clean'

    private_headers
    return head :ok if request.head?

    serve_file(attachment.file)
  rescue ActiveRecord::RecordNotFound, ActiveStorage::FileNotFoundError
    head :not_found
  end

  private

  def authorised_attachment
    raise ActiveRecord::RecordNotFound unless Corporate.enabled?

    user = Corporate::FileSession.user(cookies, request)
    raise ActiveRecord::RecordNotFound unless user.is_a?(User)

    attachment = Attachment.find(params[:id])
    raise ActiveRecord::RecordNotFound unless Corporate.can_read?(attachment.account, user, attachment.message)

    attachment
  end

  def private_headers
    headers['Cache-Control'] = 'no-store, private'
    headers['Referrer-Policy'] = 'no-referrer'
    headers['X-Content-Type-Options'] = 'nosniff'
    headers['Accept-Ranges'] = 'bytes'
  end

  def serve_file(file)
    options = { filename: file.filename.to_s, type: file.content_type, disposition: disposition(file) }
    return serve_range(file, options) if request.headers['Range'].present?

    file.blob.open { |input| send_data input.read, **options }
  end

  def disposition(file)
    file.content_type.to_s.start_with?('image/', 'audio/', 'video/') ? 'inline' : 'attachment'
  end

  def serve_range(file, options)
    ranges = Rack::Utils.get_byte_ranges(request.headers['Range'], file.byte_size)
    return head :range_not_satisfiable unless ranges&.length == 1 && ranges.first

    range = ranges.first
    headers['Content-Range'] = "bytes #{range.begin}-#{range.end}/#{file.byte_size}"
    send_data file.download_chunk(range), **options, status: :partial_content
  end
end

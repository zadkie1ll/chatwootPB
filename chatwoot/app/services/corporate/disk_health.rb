class Corporate::DiskHealth
  def self.status
    output = IO.popen(['df', '-Pk', Rails.root.join('storage').to_s], &:read)
    columns = output.lines.last.to_s.split
    total = columns[1].to_i * 1024
    available = columns[3].to_i * 1024
    { healthy: total.positive? && available > 2.gigabytes && available.to_f / total > 0.05, available_bytes: available }
  rescue SystemCallError, IOError
    { healthy: false, available_bytes: nil }
  end
end

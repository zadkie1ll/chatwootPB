require 'socket'
require 'timeout'

class Corporate::Antivirus
  class Unavailable < StandardError; end

  def self.scan(data)
    return data.exclude?('EICAR-STANDARD-ANTIVIRUS-TEST-FILE') if ENV['TELEGRAM_MODE'] == 'mock'

    Timeout.timeout(25) do
      Socket.tcp(ENV.fetch('CLAMAV_HOST', 'clamav'), 3310, connect_timeout: 3) do |socket|
        socket.write("zINSTREAM\0")
        (0...data.bytesize).step(65_536) do |offset|
          chunk = data.byteslice(offset, 65_536)
          socket.write([chunk.bytesize].pack('N'))
          socket.write(chunk)
        end
        socket.write([0].pack('N'))
        result = socket.gets("\0")
        return true if result&.end_with?("OK\0")
        return false if result&.include?('FOUND')

        raise Unavailable
      end
    end
  rescue Timeout::Error, SocketError, SystemCallError, IOError
    raise Unavailable
  end
end

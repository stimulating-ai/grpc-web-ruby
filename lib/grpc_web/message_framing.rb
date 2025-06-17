# frozen_string_literal: true

require 'grpc_web/message_frame'

# Placeholder
module GRPCWeb::MessageFraming
  PAYLOAD_FRAME_TYPE = 0
  HEADER_FRAME_TYPE = 128

  class << self
    # Packs a single frame into a binary string with a 5-byte header.
    def pack_frame(frame)
      [frame.type, frame.body.length, frame.body].pack('CNa*')
    end

    # Packs an array of frames into a single binary string.
    # This is kept for the unary case.
    def pack_frames(frames)
      frames.map { |frame| pack_frame(frame) }.join
    end

    def unpack_frames(content)
      frames = []
      remaining_content = content

      until remaining_content.empty?
        msg_length = remaining_content[1..4].unpack1('N')
        frame_end = 5 + msg_length
        frames << ::GRPCWeb::MessageFrame.new(
          remaining_content[0].bytes[0],
          remaining_content[5...frame_end],
        )
        remaining_content = remaining_content[frame_end..-1]
      end
      frames
    end
  end
end

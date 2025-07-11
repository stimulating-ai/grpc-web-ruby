# frozen_string_literal: true

# Placeholder
class GRPCWeb::MessageFrame
  PAYLOAD_FRAME_TYPE = 0 # String: "\x00"
  HEADER_FRAME_TYPE = 128 # String: "\x80"

  def self.payload_frame(body)
    new(PAYLOAD_FRAME_TYPE, body)
  end

  def self.header_frame(body)
    new(HEADER_FRAME_TYPE, body)
  end

  attr_accessor :frame_type, :body

  def initialize(frame_type, body)
    self.frame_type = frame_type
    self.body = body.b # treat body as a byte string
  end

  def payload?
    frame_type == PAYLOAD_FRAME_TYPE
  end

  def header?
    frame_type == HEADER_FRAME_TYPE
  end

  # Alias for compatibility with MessageFraming.pack_frame
  def type
    frame_type
  end

  def ==(other)
    frame_type == other.frame_type && body == other.body
  end
end

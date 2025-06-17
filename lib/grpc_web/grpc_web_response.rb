# frozen_string_literal: true

module GRPCWeb
  class GRPCWebResponse
    attr_reader :content_type, :body, :frames

    def initialize(content_type, body = '', frames = [])
      @content_type = content_type
      @body = body
      @frames = frames
    end

    def streaming?
      false
    end
  end
end

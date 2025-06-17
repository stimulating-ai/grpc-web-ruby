# frozen_string_literal: true

require 'json'
require 'net/http'

require 'grpc/errors'
require 'grpc_web/content_types'
require 'grpc_web/message_framing'

# Client execution concerns for streaming responses
module GRPCWeb::StreamingClientExecutor
  class << self
    include ::GRPCWeb::ContentTypes

    GRPC_STATUS_HEADER = 'grpc-status'
    GRPC_MESSAGE_HEADER = 'grpc-message'
    GRPC_HEADERS = %W[x-grpc-web #{GRPC_STATUS_HEADER} #{GRPC_MESSAGE_HEADER}].freeze

    def request_stream(uri, rpc_desc, params = {}, metadata = {})
      req_proto = rpc_desc.input.new(params)
      marshalled_proto = rpc_desc.marshal_proc.call(req_proto)
      frame = ::GRPCWeb::MessageFrame.payload_frame(marshalled_proto)
      request_body = ::GRPCWeb::MessageFraming.pack_frames([frame])

      resp = post_request(uri, request_body, metadata)
      handle_streaming_response(resp, rpc_desc)
    end

    private

    def request_headers(metadata)
      {
        'Accept' => PROTO_CONTENT_TYPE,
        'Content-Type' => PROTO_CONTENT_TYPE,
      }.merge(metadata[:metadata] || {})
    end

    def post_request(uri, request_body, metadata)
      request = Net::HTTP::Post.new(uri, request_headers(metadata))
      request.body = request_body
      request.basic_auth uri.user, uri.password if uri.userinfo

      begin
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(request)
        end
      rescue StandardError => e
        raise ::GRPC::Unavailable, e.message
      end
    end

    def handle_streaming_response(resp, rpc_desc)
      check_response_status(resp)

      # Parse all frames from the response body
      frames = ::GRPCWeb::MessageFraming.unpack_frames(resp.body)
      
      # Separate payload frames from header frames
      payload_frames = frames.select(&:payload?)
      header_frames = frames.select(&:header?)
      
      # Check for errors in header frames
      check_header_frames_for_errors(header_frames)
      
      # Return an enumerator that yields each message
      StreamingResponseEnumerator.new(payload_frames, rpc_desc)
    end

    def check_response_status(resp)
      unless resp.is_a?(Net::HTTPSuccess)
        case resp
        when Net::HTTPBadRequest # 400
          raise ::GRPC::Internal, resp.message
        when Net::HTTPUnauthorized # 401
          raise ::GRPC::Unauthenticated, resp.message
        when Net::HTTPForbidden # 403
          raise ::GRPC::PermissionDenied, resp.message
        when Net::HTTPNotFound # 404
          raise ::GRPC::Unimplemented, resp.message
        when Net::HTTPTooManyRequests, # 429
             Net::HTTPBadGateway, # 502
             Net::HTTPServiceUnavailable, # 503
             Net::HTTPGatewayTimeOut # 504
          raise ::GRPC::Unavailable, resp.message
        else
          raise ::GRPC::Unknown, resp.message
        end
      end
    end

    def check_header_frames_for_errors(header_frames)
      return if header_frames.empty?

      header_frame = header_frames.last # Use the last header frame (trailer)
      headers = parse_headers(header_frame.body)
      
      metadata = headers.reject { |key, _| GRPC_HEADERS.include?(key) }
      status_str = headers[GRPC_STATUS_HEADER]
      status_code = status_str.to_i if status_str && status_str == status_str.to_i.to_s

      # Check for gRPC errors
      if status_code && status_code != 0
        raise ::GRPC::BadStatus.new_status_exception(
          status_code,
          headers[GRPC_MESSAGE_HEADER],
          metadata,
        )
      end
    end

    def parse_headers(header_str)
      headers = {}
      lines = header_str.split(/\r?\n/)
      lines.each do |line|
        key, value = line.split(':', 2)
        headers[key] = value if key && value
      end
      headers
    end
  end

  # Enumerator for streaming responses
  class StreamingResponseEnumerator
    include Enumerable

    def initialize(payload_frames, rpc_desc)
      @payload_frames = payload_frames
      @rpc_desc = rpc_desc
    end

    def each
      return to_enum(__method__) unless block_given?

      @payload_frames.each do |frame|
        message = @rpc_desc.unmarshal_proc(:output).call(frame.body)
        yield message
      end
    end

    def to_a
      each.to_a
    end
  end
end 
# frozen_string_literal: true

require 'google/protobuf'
require 'rack'
require 'rack/request'
require 'grpc_web/content_types'
require 'grpc_web/grpc_web_request'
require 'grpc_web/grpc_web_call'
require 'grpc_web/server/error_callback'
require 'grpc_web/server/grpc_request_processor'
require 'grpc_web/server/grpc_response_encoder'
require "base64"

# Placeholder
module GRPCWeb::RackHandler
  NOT_FOUND = 404
  UNSUPPORTED_MEDIA_TYPE = 415
  INTERNAL_SERVER_ERROR = 500
  ACCEPT_HEADER = 'HTTP_ACCEPT'

  class << self
    include ::GRPCWeb::ContentTypes

    def call(service, service_method, env)
      rack_request = Rack::Request.new(env)
      return not_found_response(rack_request.path) unless rack_request.post?
      return unsupported_media_type_response unless valid_content_types?(rack_request)

      content_type = rack_request.content_type
      accept = rack_request.get_header(ACCEPT_HEADER)
      body = rack_request.body.read
      metadata = extract_metadata(env)

      request = GRPCWeb::GRPCWebRequest.new(service, service_method, content_type, accept, body)
      grpc_call = GRPCWeb::GRPCWebCall.new(request, metadata, started: false)
      response = GRPCWeb::GRPCRequestProcessor.process(grpc_call)
      encoded_response = ::GRPCWeb::GRPCResponseEncoder.encode(response)

      if response.streaming?
        # Use Rack hijacking for true streaming
        if env['rack.hijack?']
          return hijacked_streaming_response(env, response, encoded_response)
        else
          # Fallback to chunked response for servers that don't support hijacking
          headers = {
            'Content-Type' => response.content_type,
            'Transfer-Encoding' => 'chunked',
            'Cache-Control' => 'no-cache, no-store, must-revalidate',
            'Connection' => 'keep-alive',
            'X-Accel-Buffering' => 'no'
          }
          return [200, headers, encoded_response]
        end
      else
        # Unary response
        [200, { 'Content-Type' => response.content_type }, [encoded_response]]
      end
    rescue Google::Protobuf::ParseError => e
      invalid_response(e.message)
    rescue StandardError => e
      ::GRPCWeb.on_error.call(e, service, service_method)
      error_response
    end

    private

    def hijacked_streaming_response(env, response, encoded_response)
      # Set up hijacking
      env['rack.hijack'].call
      io = env['rack.hijack_io']
      
      # Write HTTP response headers manually
      headers = [
        "HTTP/1.1 200 OK",
        "Content-Type: #{response.content_type}",
        "Transfer-Encoding: chunked",
        "Cache-Control: no-cache, no-store, must-revalidate",
        "Connection: keep-alive",
        "X-Accel-Buffering: no",
        "", # Empty line to end headers
        ""
      ]
      
      io.write(headers.join("\r\n"))
      io.flush
      
      # Stream the chunks directly to the socket
      begin
        encoded_response.each do |chunk|
          # Write chunk in HTTP chunked format
          chunk_size = chunk.bytesize.to_s(16)
          io.write("#{chunk_size}\r\n")
          io.write(chunk)
          io.write("\r\n")
          io.flush
        end
        
        # Write final chunk (0-length chunk indicates end)
        io.write("0\r\n")
        io.write("\r\n")  # Final CRLF to end the chunked response
        io.flush
      rescue => e
        # Log error but don't raise since we've already started sending response
        puts "Streaming error: #{e.message}"
      ensure
        io.close rescue nil
      end
      
      # Return special response to indicate hijacking was used
      [-1, {}, []]
    end

    def extract_metadata(env)
      Hash[
        *env.select { |k, _v| k.start_with? 'HTTP_' }
            .reject { |k, _v| k.eql? ACCEPT_HEADER }
            .map { |k, v| [k.sub(/^HTTP_/, ''), v] }
            .map { |k, v| [k, k.end_with?('_BIN') ? Base64.decode64(v) : v] }
            .map { |k, v| [k.split('_').collect(&:downcase).join('_'), v] }
            .sort
            .flatten
      ]
    end

    def valid_content_types?(rack_request)
      return false unless ALL_CONTENT_TYPES.include?(rack_request.content_type)

      accept = rack_request.get_header(ACCEPT_HEADER)
      return true if UNSPECIFIED_CONTENT_TYPES.include?(accept)

      ALL_CONTENT_TYPES.include?(accept)
    end

    def not_found_response(path)
      [
        NOT_FOUND,
        { 'Content-Type' => 'text/plain', 'X-Cascade' => 'pass' },
        ["Not Found: #{path}"],
      ]
    end

    def unsupported_media_type_response
      [
        UNSUPPORTED_MEDIA_TYPE,
        { 'Content-Type' => 'text/plain' },
        ['Unsupported Media Type: Invalid Content-Type or Accept header'],
      ]
    end

    def invalid_response(message)
      [422, { 'Content-Type' => 'text/plain' }, ["Invalid request format: #{message}"]]
    end

    def error_response
      [
        INTERNAL_SERVER_ERROR,
        { 'Content-Type' => 'text/plain' },
        ['Request failed with an unexpected error.'],
      ]
    end
  end
end

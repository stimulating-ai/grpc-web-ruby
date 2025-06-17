# frozen_string_literal: true

require 'grpc_web/content_types'
require 'grpc_web/grpc_web_response'
require 'grpc_web/server/request_framing'
require 'grpc_web/server/error_callback'
require 'grpc_web/server/message_serialization'
require 'grpc_web/server/text_coder'
require 'grpc_web/server/grpc_response_encoder'
require 'grpc_web/server/grpc_request_decoder'

# Streaming response processor for server-side streaming RPCs
module GRPCWeb::StreamingResponseProcessor
  class << self
    include ::GRPCWeb::ContentTypes

    def process(grpc_call)
      decoder = GRPCWeb::GRPCRequestDecoder
      
      # Use the original PascalCase method name for RPC descriptor lookup
      # but convert to snake_case for calling the actual Ruby method
      original_method_name = grpc_call.request.service_method.to_s
      service_method = ::GRPC::GenericService.underscore(original_method_name)
      
      begin
        # Decode the incoming request
        decoded_request = decoder.decode(grpc_call.request)
        
        # Check arity to maintain backwards compatibility
        service_instance = grpc_call.request.service.new
        if service_instance.method(service_method.to_sym).arity == 1
          stream_enumerator = service_instance.send(
            service_method,
            decoded_request.body,
          )
        else
          stream_enumerator = service_instance.send(
            service_method, 
            decoded_request.body, 
            grpc_call,
          )
        end
        
        # Create streaming response
        create_streaming_response(grpc_call.request, stream_enumerator)
      rescue StandardError => e
        ::GRPCWeb.on_error.call(e, grpc_call.request.service, grpc_call.request.service_method)
        create_error_response(grpc_call.request, e)
      end
    end

    private

    def create_streaming_response(request, stream_enumerator)
      response_content_type = determine_response_content_type(request)
      
      # Create a special streaming response that will be handled by the encoder
      StreamingResponse.new(response_content_type, stream_enumerator)
    end

    def create_error_response(request, error)
      response_content_type = determine_response_content_type(request)
      ::GRPCWeb::GRPCWebResponse.new(response_content_type, error)
    end

    def determine_response_content_type(request)
      if UNSPECIFIED_CONTENT_TYPES.include?(request.accept)
        request.content_type
      else
        request.accept
      end
    end
  end
  
  # Special response class for streaming responses
  class StreamingResponse < ::GRPCWeb::GRPCWebResponse
    attr_reader :stream_enumerator
    
    def initialize(content_type, stream_enumerator)
      @stream_enumerator = stream_enumerator
      super(content_type, nil)
    end
    
    def streaming?
      true
    end
  end
end 
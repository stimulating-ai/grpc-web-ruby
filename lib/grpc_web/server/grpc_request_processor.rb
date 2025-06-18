# frozen_string_literal: true

require 'grpc_web/content_types'
require 'grpc_web/grpc_web_response'
require 'grpc_web/server/error_callback'
require 'grpc_web/server/message_serialization'
require 'grpc_web/server/text_coder'
require 'grpc_web/server/grpc_request_decoder'
require 'grpc_web/server/rpc_type_detector'
require 'grpc_web/server/streaming_response_processor'

module GRPCWeb
  # Module for processing GRPC Web requests.
  #
  # Requests are first decoded, then deserialized, then the service is called,
  # and the response is serialized and encoded.
  # Errors that occur during this process are rescued and serialized into an
  # error response.
  module GRPCRequestProcessor
    class << self
      include GRPCWeb::ContentTypes

          def process(grpc_call)
      service_class = grpc_call.request.service.is_a?(Class) ? grpc_call.request.service : grpc_call.request.service.class
      rpc_type = RpcTypeDetector.new(service_class, grpc_call.request.service_method).detect
      if rpc_type == :server_streaming
        StreamingResponseProcessor.process(grpc_call)
      else
        process_unary(grpc_call)
      end
      rescue GRPC::BadStatus => e
        create_error_response(grpc_call.request, e)
      rescue StandardError => e
        GRPCWeb.on_error.call(e, grpc_call.request.service, grpc_call.request.service_method)
        create_error_response(grpc_call.request, e)
      end

      private

      def process_unary(grpc_call)
        decoder = GRPCRequestDecoder
        body = decoder.decode(grpc_call.request).body
        
        # Convert PascalCase method name to snake_case for calling the Ruby method
        original_method_name = grpc_call.request.service_method.to_s
        service_method = ::GRPC::GenericService.underscore(original_method_name)
        
        service_instance = grpc_call.request.service.is_a?(Class) ? grpc_call.request.service.new : grpc_call.request.service
        
        # Check arity to maintain backwards compatibility
        if service_instance.method(service_method.to_sym).arity == 1
          response = service_instance.send(service_method, body)
        else
          response = service_instance.send(service_method, body, grpc_call)
        end
        response_content_type = determine_response_content_type(grpc_call.request)
        grpc_web_response = GRPCWeb::GRPCWebResponse.new(response_content_type, response)
        MessageSerialization.serialize_response(grpc_web_response)
      end

      def determine_response_content_type(request)
        if UNSPECIFIED_CONTENT_TYPES.include?(request.accept)
          request.content_type
        else
          request.accept
        end
      end

      def create_error_response(request, error)
        response_content_type = determine_response_content_type(request)
        grpc_web_response = GRPCWeb::GRPCWebResponse.new(response_content_type, error)
        MessageSerialization.serialize_response(grpc_web_response)
      end
    end
  end
end

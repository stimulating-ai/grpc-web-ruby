# frozen_string_literal: true

# Utility to detect RPC type (unary vs streaming) based on service descriptors
class GRPCWeb::RpcTypeDetector
  def initialize(service_class, method_name)
    @service_class = service_class
    @method_name = method_name
  end

  def detect
    return :server_streaming if server_streaming?
    :unary
  end

  private

  # Determine if a given RPC method is server-side streaming
  def server_streaming?
    return false unless @service_class.respond_to?(:rpc_descs)
    
    # Try to find the RPC descriptor with the exact method name first
    rpc_desc = @service_class.rpc_descs[@method_name.to_sym]
    
    # If not found, try converting snake_case to PascalCase
    if rpc_desc.nil?
      pascal_case_method = @method_name.to_s.split('_').map(&:capitalize).join
      rpc_desc = @service_class.rpc_descs[pascal_case_method.to_sym]
    end
    
    # If still not found, try converting PascalCase to snake_case
    if rpc_desc.nil?
      snake_case_method = @method_name.to_s.gsub(/([A-Z])/, '_\1').downcase.gsub(/^_/, '')
      rpc_desc = @service_class.rpc_descs[snake_case_method.to_sym]
    end
    
    return false unless rpc_desc
    
    # Check if the output is a GRPC::RpcDesc::Stream object
    # This indicates server-side streaming
    rpc_desc.output.is_a?(GRPC::RpcDesc::Stream)
  rescue
    # If we can't determine the streaming type, assume it's unary for backward compatibility
    false
  end

  class << self
    # Class method for backward compatibility
    def server_streaming?(service_class, method_name)
      new(service_class, method_name).send(:server_streaming?)
    end

    # Heuristic method: check if the service method returns an enumerable
    def likely_streaming_response?(response)
      response.respond_to?(:each) && 
        !response.is_a?(String) && 
        !response.is_a?(Hash) && 
        !response.respond_to?(:to_proto) # Not a protobuf message
    end

    # Alternative detection method for when descriptors aren't available
    # This checks if the method name or response suggests streaming
    def detect_streaming_from_response(service, method_name, response)
      # Method name heuristics
      method_suggests_streaming = method_name.to_s.downcase.include?('stream')
      
      # Response type heuristics
      response_is_enumerable = likely_streaming_response?(response)
      
      method_suggests_streaming || response_is_enumerable
    end
  end
end 
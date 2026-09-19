# How to use declared messages with protocol-grpc

Use fast-protowire classes as the request and response types of a `protocol-grpc` (and so
`async-grpc`) RPC. You need the service's request and response messages declared with the
DSL.

`protocol-grpc` never loads `google-protobuf`; it writes a request by calling `to_proto`
on it, and reads a response by calling `decode` on the class named in the RPC declaration.
Declared classes provide both.

## Steps

1. Declare the request and response messages:

   ```ruby
   module Proto
     class ExportMetricsServiceRequest < Fast::Protowire::Message
       repeated :resource_metrics, ResourceMetrics, 1
     end

     class ExportMetricsPartialSuccess < Fast::Protowire::Message
       field :rejected_data_points, :int64, 1
       field :error_message, :string, 2
     end

     class ExportMetricsServiceResponse < Fast::Protowire::Message
       field :partial_success, ExportMetricsPartialSuccess, 1
     end
   end
   ```

2. Name them in the interface:

   ```ruby
   require "protocol/grpc/interface"

   class MetricsServiceInterface < Protocol::GRPC::Interface
     rpc :Export,
         request_class: Proto::ExportMetricsServiceRequest,
         response_class: Proto::ExportMetricsServiceResponse
   end
   ```

3. Call it through an `async-grpc` stub as usual. The response comes back decoded:

   ```ruby
   stub = Async::GRPC::Client.new(http_client).stub(MetricsServiceInterface, "opentelemetry.proto.collector.metrics.v1.MetricsService")
   response = stub.export(Proto::ExportMetricsServiceRequest.new(resource_metrics: [...]))
   response.partial_success&.rejected_data_points
   ```

4. On the server side, a handler for the same interface receives decoded requests and
   writes instances of the declared response class. `protocol-grpc` checks the written
   message `is_a?` the declared class, so write a declared instance, not a hash or a
   `google-protobuf` object.

## Notes

`protocol-grpc` currently declares `google-protobuf` as a runtime dependency without using
it, so the gem still installs alongside yours until that declaration is loosened upstream.
Nothing loads it.

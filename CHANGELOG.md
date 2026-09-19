# Changelog

## 0.1.0

- Initial release: `Wire`, `Reader`, `Enum` and the `Message` DSL covering
  every scalar type, proto2 and proto3 presence, packed and unpacked
  repeated fields, maps, oneofs, nested and recursive messages, unknown
  field preservation and merge-on-decode, verified byte-for-byte against
  `google-protobuf`. `encode` is compiled per message class.

# How to declare a schema from a .proto file

Translate a `.proto` file into fast-protowire declarations so that your classes encode the
same bytes `protoc`-generated code would. You need the `.proto` file and its `syntax` line.

## Steps

1. Set the syntax to match the file. Every class defaults to proto3; under proto2 declare
   it explicitly, because the two differ in presence and packing rules:

   ```ruby
   class LabelPair < Fast::Protowire::Message
     syntax :proto2
     optional :name, :string, 1
     optional :value, :string, 2
   end
   ```

2. Translate each field line with the table below. The field's name, type and number
   carry over unchanged; the keyword picks the rule.

   | `.proto` | Declaration |
   |---|---|
   | proto3 `string name = 1;` | `field :name, :string, 1` |
   | proto3 `optional string name = 1;` | `optional :name, :string, 1` |
   | proto2 `optional string name = 1;` | `optional :name, :string, 1` (or `field`, which means the same under `syntax :proto2`) |
   | proto2 `required int32 id = 1;` | `required :id, :int32, 1` |
   | proto2 `optional int32 n = 1 [default = 42];` | `optional :n, :int32, 1, default: 42` |
   | `repeated int32 ids = 1;` | `repeated :ids, :int32, 1` |
   | proto2 `repeated int32 ids = 1 [packed = true];` | `repeated :ids, :int32, 1, packed: true` |
   | proto3 `repeated int32 ids = 1 [packed = false];` | `repeated :ids, :int32, 1, packed: false` |
   | `map<string, int64> counts = 1;` | `map :counts, :string, :int64, 1` |
   | `Other other = 1;` | `field :other, Other, 1` |
   | `MyEnum kind = 1;` | `field :kind, MyEnum, 1` |

   Scalar types keep their `.proto` names as Symbols: `:double`, `:float`, `:int32`,
   `:int64`, `:uint32`, `:uint64`, `:sint32`, `:sint64`, `:fixed32`, `:fixed64`,
   `:sfixed32`, `:sfixed64`, `:bool`, `:string`, `:bytes`.

3. Declare enums before the fields that use them, with the values from the `.proto`:

   ```ruby
   MetricType = Fast::Protowire::Enum.define(COUNTER: 0, GAUGE: 1, SUMMARY: 2)
   ```

4. Translate a `oneof` block into an `oneof` block with the same members. Members are
   declared with `field` regardless of syntax; being in a oneof gives them presence:

   ```ruby
   class AnyValue < Fast::Protowire::Message
     oneof :value do
       field :string_value, :string, 1
       field :bool_value, :bool, 2
       field :int_value, :int64, 3
     end
   end
   ```

5. For a message that refers to itself, or to a message declared later in the file, give
   the type as a String naming the class. It's resolved on first use, relative to the
   namespace the declaring class lives in:

   ```ruby
   module Schema
     class Tree < Fast::Protowire::Message
       field :label, :string, 1
       repeated :children, "Tree", 2
       field :sibling, "Leaf", 3
     end

     class Leaf < Fast::Protowire::Message
       field :label, :string, 1
     end
   end
   ```

6. Nested messages (`message Outer { message Inner { ... } }`) become nested classes,
   which the DSL allows anywhere a class is allowed:

   ```ruby
   class ExponentialHistogramDataPoint < Fast::Protowire::Message
     class Buckets < Fast::Protowire::Message
       field :offset, :sint32, 1
       repeated :bucket_counts, :uint64, 2
     end

     field :positive, Buckets, 8
   end
   ```

7. Leave out fields you never set or read. A decoder keeps any field it doesn't know
   about as unknown bytes and writes them back on encode, so a partial declaration still
   round-trips foreign messages intact. Field numbers must still be unique within the
   class.

8. Check the result the way the library checks itself: compile the same `.proto` with
   `protoc --ruby_out`, build one message on each side from the same attributes, and
   compare `encode` with `to_proto`. See
   [How to verify parity against google-protobuf](verify-parity-against-google-protobuf.md).

## Things that do not translate

`extensions`, `group`, `import` of well-known types, custom options and `reserved` ranges
have no equivalent; the DSL is the wire format only. A `google.protobuf.Timestamp` field,
for example, is declared as its own two-field message (`seconds` int64 = 1, `nanos` int32
= 2) if you need it, or left out and carried as unknown bytes if you don't.

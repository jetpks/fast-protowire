# How to stream a large repeated field

Write a message with a very large repeated field, one element at a time, without ever
holding every element as an object. You need the field's number and the class of its
elements.

A repeated message field is a sequence of length-delimited entries that all carry the same
tag, and Protocol Buffers lets a repeated field's entries appear anywhere in the enclosing
message. So the enclosing message's bytes can be its other fields followed by each entry
appended as it's produced.

## Steps

1. Encode the enclosing message with everything except the large field. Here `metric` is
   field 4 of `MetricFamily`:

   ```ruby
   buffer = MetricFamily.new(name: "http_requests_total", type: :COUNTER).encode
   ```

2. Build the field's tag once. A message-typed field is length-delimited (wire type 2):

   ```ruby
   METRIC = Fast::Protowire::Wire.tag(4, Fast::Protowire::Wire::LENGTH_DELIMITED)
   ```

3. Append each element with `Wire.append_length_delimited`, encoding it and discarding it
   in the same step:

   ```ruby
   series.each do |labels, value|
     metric = Metric.new(label: labels, counter: { value: value })
     Fast::Protowire::Wire.append_length_delimited(buffer, METRIC, metric.encode)
   end
   ```

   `buffer` now holds bytes identical to `MetricFamily.new(name:, type:, metric: [...all
   of them...]).encode`, but at no point did more than one `Metric` exist.

4. If the result is itself a field of an outer message, prefix it the same way, or, for
   a delimited stream such as Prometheus exposition, prefix its length alone:

   ```ruby
   out = String.new
   Fast::Protowire::Wire.append_varint(out, buffer.bytesize)
   out << buffer
   ```

## Notes

Keep each element's encode in its own small buffer and copy it, as
`append_length_delimited` does. Writing the element into the big buffer and inserting the
length prefix afterwards is slower: `String#insert` costs time proportional to the whole
buffer, wherever the insert lands.

fast-prometheus renders its protobuf exposition exactly this way; see its
`Formats::Protobuf`.

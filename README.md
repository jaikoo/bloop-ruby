# bloop-sdk (Ruby)

Ruby SDK for [bloop](https://github.com/your-org/bloop) error observability. Zero external dependencies — uses only the Ruby standard library.

## Install

```ruby
gem "bloop-sdk"
```

## Usage

```ruby
require "bloop"

client = Bloop::Client.new(
  endpoint: "https://bloop.example.com",
  project_key: "your-api-key",
  environment: "production",
  release: "1.0.0",
)

# Capture an error
client.capture(error_type: "TypeError", message: "something broke")

# Capture a Ruby exception
begin
  do_something
rescue => e
  client.capture_exception(e)
end

# Graceful shutdown (also called via at_exit hook)
client.close
```

## API

### `Bloop::Client.new(endpoint:, project_key:, **opts)`

- `environment:` — Environment tag. Default: `"production"`
- `release:` — Release version. Default: `""`
- `flush_interval:` — Seconds between auto-flushes. Default: `5`
- `max_buffer_size:` — Flush when buffer reaches this size. Default: `100`

### `client.capture(error_type:, message:, **kwargs)`

Buffer an error event. Options: `source:`, `stack:`, `route_or_procedure:`, `screen:`, `metadata:`.

### `client.capture_exception(exception, **kwargs)`

Capture a Ruby exception (uses class name, message, and backtrace).

### `client.flush`

Send buffered events immediately.

### `client.close`

Flush and stop background thread.

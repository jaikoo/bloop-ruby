# frozen_string_literal: true

require "minitest/autorun"
require "webrick"
require "json"
require_relative "../lib/bloop"

class TestTracing < Minitest::Test
  def setup
    @received = []
    captured = @received

    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new("/dev/null"), AccessLog: [])
    @server.mount_proc("/v1/traces/batch") do |req, res|
      captured << { path: req.path, body: JSON.parse(req.body), headers: req.header }
      res.status = 200
      res.body = '{"status":"accepted"}'
    end

    @port = @server[:Port]
    @thread = Thread.new { @server.start }
    sleep 0.1

    @client = Bloop::Client.new(
      endpoint: "http://127.0.0.1:#{@port}",
      project_key: "test-key",
      flush_interval: 999,
      environment: "test",
    )
  end

  def teardown
    @client.close
    @server.shutdown
    @thread.join(2)
  end

  # -- Trace creation --

  def test_trace_creation
    trace = @client.start_trace(name: "chat-completion")
    assert_match(/\A[0-9a-f\-]{36}\z/, trace.id)
    assert_equal "chat-completion", trace.name
    assert_equal "running", trace.status
    assert_kind_of Integer, trace.started_at
    assert trace.started_at > 0
  end

  def test_trace_creation_with_optional_fields
    trace = @client.start_trace(
      name: "chat",
      session_id: "sess-1",
      user_id: "user-42",
      input: "hello",
      metadata: { env: "test" },
      prompt_name: "greeting",
      prompt_version: "v2",
    )
    assert_equal "sess-1", trace.session_id
    assert_equal "user-42", trace.user_id
    assert_equal "hello", trace.input
    assert_equal({ env: "test" }, trace.metadata)
    assert_equal "greeting", trace.prompt_name
    assert_equal "v2", trace.prompt_version
  end

  # -- Span creation --

  def test_span_creation
    trace = @client.start_trace(name: "test")
    span = trace.start_span(span_type: :generation, name: "llm-call", model: "gpt-4", provider: "openai")
    assert_match(/\A[0-9a-f\-]{36}\z/, span.id)
    assert_equal "generation", span.span_type
    assert_equal "llm-call", span.name
    assert_equal "gpt-4", span.model
    assert_equal "openai", span.provider
    assert_kind_of Integer, span.started_at
    assert span.started_at > 0
  end

  def test_span_added_to_trace
    trace = @client.start_trace(name: "test")
    span = trace.start_span(span_type: :custom, name: "step-1")
    assert_equal 1, trace.spans.size
    assert_same span, trace.spans.first
  end

  # -- Span finish --

  def test_span_finish
    trace = @client.start_trace(name: "test")
    span = trace.start_span(span_type: :generation, name: "call")
    sleep 0.01 # ensure measurable latency
    span.finish(status: :ok, input_tokens: 100, output_tokens: 50, cost: 0.003)

    assert_equal "ok", span.status
    assert_kind_of Integer, span.latency_ms
    assert span.latency_ms >= 0
    assert_equal 100, span.input_tokens
    assert_equal 50, span.output_tokens
    assert_equal 0.003, span.cost
  end

  def test_span_finish_with_error
    trace = @client.start_trace(name: "test")
    span = trace.start_span(span_type: :generation, name: "call")
    span.finish(status: :error, error_message: "timeout")

    assert_equal "error", span.status
    assert_equal "timeout", span.error_message
  end

  def test_span_finish_with_output_and_ttft
    trace = @client.start_trace(name: "test")
    span = trace.start_span(span_type: :generation, name: "call")
    span.finish(status: :ok, output: "Hello!", time_to_first_token_ms: 42)

    assert_equal "Hello!", span.output
    assert_equal 42, span.time_to_first_token_ms
  end

  def test_span_set_usage
    trace = @client.start_trace(name: "test")
    span = trace.start_span(span_type: :generation, name: "call")
    span.set_usage(input_tokens: 200, output_tokens: 80, cost: 0.005)

    assert_equal 200, span.input_tokens
    assert_equal 80, span.output_tokens
    assert_equal 0.005, span.cost
  end

  # -- Trace finish --

  def test_trace_finish
    trace = @client.start_trace(name: "test")
    trace.start_span(span_type: :custom, name: "step")
    trace.finish(status: :completed, output: "done")

    assert_equal "completed", trace.status
    assert_equal "done", trace.output
    assert_kind_of Integer, trace.ended_at
    assert trace.ended_at >= trace.started_at
  end

  # -- Serialization --

  def test_trace_serialization
    trace = @client.start_trace(
      name: "chat",
      session_id: "s1",
      user_id: "u1",
      input: "hi",
      metadata: { k: "v" },
      prompt_name: "greet",
      prompt_version: "v1",
    )
    span = trace.start_span(span_type: :generation, name: "gen", model: "gpt-4", provider: "openai")
    span.finish(status: :ok, input_tokens: 10, output_tokens: 5)
    trace.finish(status: :completed, output: "bye")

    h = trace.to_h
    assert_equal trace.id, h[:id]
    assert_equal "chat", h[:name]
    assert_equal "completed", h[:status]
    assert_equal "s1", h[:session_id]
    assert_equal "u1", h[:user_id]
    assert_equal "hi", h[:input]
    assert_equal "bye", h[:output]
    assert_equal({ k: "v" }, h[:metadata])
    assert_equal "greet", h[:prompt_name]
    assert_equal "v1", h[:prompt_version]
    assert_kind_of Integer, h[:started_at]
    assert_kind_of Integer, h[:ended_at]
    assert_kind_of Array, h[:spans]
    assert_equal 1, h[:spans].size
  end

  def test_span_serialization
    trace = @client.start_trace(name: "test")
    span = trace.start_span(
      span_type: :generation,
      name: "gen",
      model: "gpt-4",
      provider: "openai",
      input: "prompt text",
      metadata: { temp: 0.7 },
    )
    span.finish(status: :ok, input_tokens: 10, output_tokens: 5, cost: 0.001,
                output: "response", time_to_first_token_ms: 30)

    h = span.to_h
    assert_equal span.id, h[:id]
    assert_equal "generation", h[:span_type]
    assert_equal "gen", h[:name]
    assert_equal "gpt-4", h[:model]
    assert_equal "openai", h[:provider]
    assert_equal "prompt text", h[:input]
    assert_equal "response", h[:output]
    assert_equal({ temp: 0.7 }, h[:metadata])
    assert_equal 10, h[:input_tokens]
    assert_equal 5, h[:output_tokens]
    assert_equal 0.001, h[:cost]
    assert_equal "ok", h[:status]
    assert_kind_of Integer, h[:started_at]
    assert_kind_of Integer, h[:latency_ms]
    assert_equal 30, h[:time_to_first_token_ms]
  end

  def test_span_serialization_omits_empty_fields
    trace = @client.start_trace(name: "test")
    span = trace.start_span(span_type: :custom, name: "minimal")
    # Don't finish - check minimal hash
    h = span.to_h
    refute h.key?(:model)         # empty string omitted
    refute h.key?(:provider)      # empty string omitted
    refute h.key?(:input_tokens)  # nil omitted
    refute h.key?(:output_tokens) # nil omitted
    refute h.key?(:cost)          # nil omitted
    refute h.key?(:latency_ms)    # nil omitted
    refute h.key?(:error_message) # nil omitted
    refute h.key?(:input)         # nil omitted
    refute h.key?(:output)        # nil omitted
    refute h.key?(:metadata)      # nil omitted
    refute h.key?(:parent_span_id) # nil omitted
  end

  # -- with_trace block --

  def test_with_trace_block
    trace = @client.with_trace("my-trace", session_id: "s1") do |t|
      t.start_span(span_type: :generation, name: "step")
    end

    assert_equal "completed", trace.status
    assert_kind_of Integer, trace.ended_at
    assert_equal 1, trace.spans.size
  end

  def test_with_trace_error
    error = assert_raises(RuntimeError) do
      @client.with_trace("failing-trace") do |t|
        t.start_span(span_type: :generation, name: "step")
        raise RuntimeError, "something broke"
      end
    end

    assert_equal "something broke", error.message
    # The trace should have been finished with error status
    # We can verify by checking that a trace was enqueued (it will be flushed)
  end

  # -- with_generation block --

  def test_with_generation_block
    trace = @client.start_trace(name: "test")
    trace.with_generation(model: "gpt-4", provider: "openai", name: "gen") do |span|
      span.set_usage(input_tokens: 100, output_tokens: 50)
    end

    assert_equal 1, trace.spans.size
    span = trace.spans.first
    assert_equal "generation", span.span_type
    assert_equal "ok", span.status
    assert_kind_of Integer, span.latency_ms
    assert_equal 100, span.input_tokens
    assert_equal 50, span.output_tokens
  end

  def test_with_generation_error
    trace = @client.start_trace(name: "test")
    assert_raises(RuntimeError) do
      trace.with_generation(model: "gpt-4", name: "gen") do |_span|
        raise RuntimeError, "api error"
      end
    end

    span = trace.spans.first
    assert_equal "error", span.status
    assert_equal "api error", span.error_message
  end

  # -- Trace flush integration --

  def test_trace_sent_to_server
    trace = @client.start_trace(name: "integration-test")
    span = trace.start_span(span_type: :generation, name: "call", model: "gpt-4")
    span.finish(status: :ok, input_tokens: 10, output_tokens: 5)
    trace.finish(status: :completed)
    @client.flush
    sleep 0.5 # wait for async send

    assert_equal 1, @received.size
    body = @received[0][:body]
    assert body.key?("traces")
    assert_equal 1, body["traces"].size
    assert_equal "integration-test", body["traces"][0]["name"]
  end

  def test_trace_hmac_signature
    trace = @client.start_trace(name: "sig-test")
    trace.finish(status: :completed)
    @client.flush
    sleep 0.5

    req = @received[0]
    body = JSON.generate(req[:body])
    expected = OpenSSL::HMAC.hexdigest("SHA256", "test-key", body)
    assert_equal expected, req[:headers]["x-signature"]&.first
  end

  # -- Parent span --

  def test_nested_spans
    trace = @client.start_trace(name: "test")
    parent = trace.start_span(span_type: :custom, name: "parent")
    child = trace.start_span(span_type: :generation, name: "child", parent_span_id: parent.id)

    assert_equal parent.id, child.parent_span_id
    assert_equal 2, trace.spans.size

    h = child.to_h
    assert_equal parent.id, h[:parent_span_id]
  end
end

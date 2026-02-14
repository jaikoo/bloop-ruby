# frozen_string_literal: true

require "openssl"
require "net/http"
require "json"
require "uri"
require "securerandom"
require_relative "bloop/tracing"

module Bloop
  VERSION = "0.2.0"

  class Client
    attr_reader :endpoint, :project_key

    # @param endpoint [String] Bloop server URL
    # @param project_key [String] Project API key for HMAC signing
    # @param environment [String] Environment tag (default: "production")
    # @param release [String] Release version tag
    # @param flush_interval [Numeric] Seconds between auto-flushes (default: 5)
    # @param max_buffer_size [Integer] Flush when buffer reaches this size (default: 100)
    def initialize(endpoint:, project_key:, environment: "production", release: "", flush_interval: 5, max_buffer_size: 100)
      @endpoint = endpoint.chomp("/")
      @project_key = project_key
      @environment = environment
      @release = release
      @flush_interval = flush_interval
      @max_buffer_size = max_buffer_size

      @buffer = []
      @trace_buffer = []
      @mutex = Mutex.new
      @closed = false

      start_flush_thread
      install_at_exit
    end

    # Capture an error event.
    #
    # @param error_type [String] The error class name
    # @param message [String] Human-readable error message
    # @param source [String] Source platform (default: "ruby")
    # @param stack [String] Stack trace
    # @param route_or_procedure [String] Route or method
    # @param screen [String] Screen name (mobile)
    # @param metadata [Hash] Arbitrary metadata
    def capture(error_type:, message:, source: "ruby", stack: "", route_or_procedure: "", screen: "", metadata: nil, **kwargs)
      return if @closed

      event = {
        timestamp: (Time.now.to_f * 1000).to_i,
        source: source,
        environment: @environment,
        error_type: error_type,
        message: message,
      }
      event[:release] = @release unless @release.empty?
      event[:stack] = stack unless stack.empty?
      event[:route_or_procedure] = route_or_procedure unless route_or_procedure.empty?
      event[:screen] = screen unless screen.empty?
      event[:metadata] = metadata if metadata

      kwargs.each { |k, v| event[k] = v unless event.key?(k) }

      @mutex.synchronize do
        @buffer << event
        flush_locked if @buffer.size >= @max_buffer_size
      end
    end

    # Capture a Ruby exception.
    #
    # @param exception [Exception] The exception to capture
    def capture_exception(exception, **kwargs)
      capture(
        error_type: exception.class.name,
        message: exception.message,
        stack: (exception.backtrace || []).join("\n"),
        **kwargs
      )
    end

    # Wrap a block and capture any raised exception, then re-raise.
    #
    # @param kwargs [Hash] Extra context passed to capture_exception (e.g. route_or_procedure:, metadata:)
    # @yield The block to execute
    # @return The block's return value
    def with_error_capture(**kwargs, &block)
      block.call
    rescue Exception => e
      capture_exception(e, **kwargs)
      raise
    end

    # Flush buffered events immediately.
    def flush
      @mutex.synchronize { flush_locked }
    end

    # Flush and stop the background thread.
    def close
      @closed = true
      flush
      @flush_thread&.kill
    end

    # Start a new LLM trace for observability.
    #
    # @param name [String] Trace name (e.g. "chat-completion")
    # @param session_id [String] Optional session identifier
    # @param user_id [String] Optional user identifier
    # @param input [Object] Optional input data
    # @param metadata [Hash] Optional metadata
    # @param prompt_name [String] Optional prompt template name
    # @param prompt_version [String] Optional prompt version
    # @return [Bloop::Trace]
    def start_trace(name:, session_id: nil, user_id: nil, input: nil, metadata: nil,
                    prompt_name: nil, prompt_version: nil)
      Bloop::Trace.new(client: self, name: name, session_id: session_id,
                       user_id: user_id, input: input, metadata: metadata,
                       prompt_name: prompt_name, prompt_version: prompt_version)
    end

    # Wrap a block in a trace. Auto-finishes on success or error.
    #
    # @param name [String] Trace name
    # @param kwargs [Hash] Extra args passed to start_trace
    # @yield [Bloop::Trace] The trace object
    # @return [Bloop::Trace]
    def with_trace(name, **kwargs)
      trace = start_trace(name: name, **kwargs)
      yield trace
      trace.finish(status: :completed) if trace.status == "running"
      trace
    rescue Exception => e
      trace.finish(status: :error, output: e.message) if trace.status == "running"
      raise
    end

    private

    def flush_locked
      unless @buffer.empty?
        events = @buffer.dup
        @buffer.clear
        Thread.new { send_events(events) }
      end

      flush_traces_locked
    end

    def send_events(events)
      if events.size == 1
        path = "/v1/ingest"
        body = JSON.generate(events.first)
      else
        path = "/v1/ingest/batch"
        body = JSON.generate({ events: events })
      end

      signature = OpenSSL::HMAC.hexdigest("SHA256", @project_key, body)

      uri = URI("#{@endpoint}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 5
      http.read_timeout = 10

      req = Net::HTTP::Post.new(uri.path)
      req["Content-Type"] = "application/json"
      req["X-Signature"] = signature
      req["X-Project-Key"] = @project_key
      req.body = body

      http.request(req)
    rescue StandardError
      # Fire and forget — don't crash the host app
    end

    def enqueue_trace(trace)
      @mutex.synchronize do
        @trace_buffer << trace.to_h
        flush_traces_locked if @trace_buffer.size >= @max_buffer_size
      end
    end

    def flush_traces_locked
      return if @trace_buffer.empty?

      traces = @trace_buffer.dup
      @trace_buffer.clear
      Thread.new { send_traces(traces) }
    end

    def send_traces(traces)
      traces.each_slice(50) do |batch|
        body = JSON.generate({ traces: batch })
        signature = OpenSSL::HMAC.hexdigest("SHA256", @project_key, body)
        uri = URI("#{@endpoint}/v1/traces/batch")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 10
        req = Net::HTTP::Post.new(uri.path)
        req["Content-Type"] = "application/json"
        req["X-Signature"] = signature
        req["X-Project-Key"] = @project_key
        req.body = body
        http.request(req)
      end
    rescue StandardError
      # Fire and forget
    end

    def start_flush_thread
      @flush_thread = Thread.new do
        loop do
          sleep @flush_interval
          flush unless @closed
        rescue StandardError
          # Ignore flush errors
        end
      end
      @flush_thread.abort_on_exception = false
    end

    def install_at_exit
      client = self
      at_exit { client.close }
    end
  end

  # Rack middleware that captures unhandled exceptions and reports them to bloop.
  #
  # Works with Rails, Sinatra, Grape, and any Rack-compatible framework.
  #
  # @example Rails
  #   # config/application.rb
  #   config.middleware.use Bloop::RackMiddleware, client: Bloop::Client.new(...)
  #
  # @example Sinatra
  #   use Bloop::RackMiddleware, client: Bloop::Client.new(...)
  class RackMiddleware
    # @param app [#call] The Rack application
    # @param client [Bloop::Client] A configured bloop client instance
    def initialize(app, client:)
      @app = app
      @client = client
    end

    def call(env)
      @app.call(env)
    rescue Exception => e
      @client.capture_exception(e,
        route_or_procedure: env["PATH_INFO"],
        metadata: {
          method: env["REQUEST_METHOD"],
          query: env["QUERY_STRING"],
          remote_ip: env["REMOTE_ADDR"],
        }
      )
      raise
    end
  end
end

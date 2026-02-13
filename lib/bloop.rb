# frozen_string_literal: true

require "openssl"
require "net/http"
require "json"
require "uri"

module Bloop
  VERSION = "0.1.0"

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

    private

    def flush_locked
      return if @buffer.empty?

      events = @buffer.dup
      @buffer.clear

      Thread.new { send_events(events) }
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
end

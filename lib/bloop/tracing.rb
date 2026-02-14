# frozen_string_literal: true

module Bloop
  class Span
    attr_reader :id, :parent_span_id, :span_type, :name, :model, :provider,
                :started_at, :input, :metadata
    attr_accessor :input_tokens, :output_tokens, :cost, :latency_ms,
                  :time_to_first_token_ms, :status, :error_message, :output

    def initialize(span_type:, name: "", model: "", provider: "", input: nil,
                   metadata: nil, parent_span_id: nil)
      @id = SecureRandom.uuid
      @parent_span_id = parent_span_id
      @span_type = span_type.to_s
      @name = name
      @model = model
      @provider = provider
      @input = input
      @metadata = metadata
      @started_at = (Time.now.to_f * 1000).to_i
    end

    def finish(status: :ok, input_tokens: nil, output_tokens: nil, cost: nil,
               error_message: nil, output: nil, time_to_first_token_ms: nil)
      @latency_ms = (Time.now.to_f * 1000).to_i - @started_at
      @status = status.to_s
      @input_tokens = input_tokens if input_tokens
      @output_tokens = output_tokens if output_tokens
      @cost = cost if cost
      @error_message = error_message if error_message
      @output = output if output
      @time_to_first_token_ms = time_to_first_token_ms if time_to_first_token_ms
      self
    end

    def set_usage(input_tokens: nil, output_tokens: nil, cost: nil)
      @input_tokens = input_tokens if input_tokens
      @output_tokens = output_tokens if output_tokens
      @cost = cost if cost
    end

    def to_h
      h = {
        id: @id, span_type: @span_type, name: @name,
        started_at: @started_at, status: @status || "ok",
      }
      h[:parent_span_id] = @parent_span_id if @parent_span_id
      h[:model] = @model unless @model.empty?
      h[:provider] = @provider unless @provider.empty?
      h[:input_tokens] = @input_tokens if @input_tokens
      h[:output_tokens] = @output_tokens if @output_tokens
      h[:cost] = @cost if @cost
      h[:latency_ms] = @latency_ms if @latency_ms
      h[:time_to_first_token_ms] = @time_to_first_token_ms if @time_to_first_token_ms
      h[:error_message] = @error_message if @error_message
      h[:input] = @input if @input
      h[:output] = @output if @output
      h[:metadata] = @metadata if @metadata
      h
    end
  end

  class Trace
    attr_reader :id, :name, :session_id, :user_id, :started_at, :input, :metadata,
                :prompt_name, :prompt_version, :spans
    attr_accessor :status, :output, :ended_at

    def initialize(client:, name:, session_id: nil, user_id: nil, input: nil,
                   metadata: nil, prompt_name: nil, prompt_version: nil)
      @id = SecureRandom.uuid
      @client = client
      @name = name
      @session_id = session_id
      @user_id = user_id
      @status = "running"
      @input = input
      @metadata = metadata
      @prompt_name = prompt_name
      @prompt_version = prompt_version
      @started_at = (Time.now.to_f * 1000).to_i
      @spans = []
    end

    def start_span(span_type: :custom, name: "", model: "", provider: "",
                   input: nil, metadata: nil, parent_span_id: nil)
      span = Span.new(span_type: span_type, name: name, model: model,
                      provider: provider, input: input, metadata: metadata,
                      parent_span_id: parent_span_id)
      @spans << span
      span
    end

    def with_generation(model: "", provider: "", name: "", input: nil, metadata: nil)
      span = start_span(span_type: :generation, name: name, model: model,
                        provider: provider, input: input, metadata: metadata)
      yield span
      span.finish(status: :ok) unless span.status
      span
    rescue Exception => e
      span.finish(status: :error, error_message: e.message) unless span.status
      raise
    end

    def finish(status: :completed, output: nil)
      @ended_at = (Time.now.to_f * 1000).to_i
      @status = status.to_s
      @output = output if output
      @client.send(:enqueue_trace, self)
    end

    def to_h
      h = {
        id: @id, name: @name, status: @status, started_at: @started_at,
        spans: @spans.map(&:to_h),
      }
      h[:session_id] = @session_id if @session_id
      h[:user_id] = @user_id if @user_id
      h[:input] = @input if @input
      h[:output] = @output if @output
      h[:metadata] = @metadata if @metadata
      h[:prompt_name] = @prompt_name if @prompt_name
      h[:prompt_version] = @prompt_version if @prompt_version
      h[:ended_at] = @ended_at if @ended_at
      h
    end
  end
end

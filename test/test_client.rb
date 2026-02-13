# frozen_string_literal: true

require "minitest/autorun"
require "webrick"
require "json"
require_relative "../lib/bloop"

class TestBloopClient < Minitest::Test
  def setup
    @received = []
    captured = @received

    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new("/dev/null"), AccessLog: [])
    @server.mount_proc("/v1/ingest") do |req, res|
      captured << { path: req.path, body: JSON.parse(req.body), headers: req.header }
      res.status = 200
      res.body = '{"status":"accepted"}'
    end
    @server.mount_proc("/v1/ingest/batch") do |req, res|
      captured << { path: req.path, body: JSON.parse(req.body), headers: req.header }
      res.status = 200
      res.body = '{"status":"accepted"}'
    end

    @port = @server[:Port]
    @thread = Thread.new { @server.start }
    sleep 0.1
  end

  def teardown
    @server.shutdown
    @thread.join(2)
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  def test_capture_and_flush
    client = Bloop::Client.new(
      endpoint: base_url,
      project_key: "test-key",
      flush_interval: 999,
      environment: "test",
      release: "1.0.0",
    )
    client.capture(error_type: "TypeError", message: "test error")
    client.flush
    sleep 0.5
    client.close

    assert_equal 1, @received.size
    assert_equal "/v1/ingest", @received[0][:path]
    assert_equal "TypeError", @received[0][:body]["error_type"]
  end

  def test_batch_flush
    client = Bloop::Client.new(endpoint: base_url, project_key: "test-key", flush_interval: 999)
    client.capture(error_type: "Error1", message: "msg1")
    client.capture(error_type: "Error2", message: "msg2")
    client.flush
    sleep 0.5
    client.close

    assert_equal 1, @received.size
    assert_equal "/v1/ingest/batch", @received[0][:path]
    assert_equal 2, @received[0][:body]["events"].size
  end

  def test_hmac_signature
    client = Bloop::Client.new(endpoint: base_url, project_key: "my-secret", flush_interval: 999)
    client.capture(error_type: "SigTest", message: "verify")
    client.flush
    sleep 0.5
    client.close

    req = @received[0]
    body = JSON.generate(req[:body])
    expected = OpenSSL::HMAC.hexdigest("SHA256", "my-secret", body)
    assert_equal expected, req[:headers]["x-signature"]&.first
  end

  def test_capture_exception
    client = Bloop::Client.new(endpoint: base_url, project_key: "test-key", flush_interval: 999)
    begin
      raise RuntimeError, "boom"
    rescue => e
      client.capture_exception(e)
    end
    client.flush
    sleep 0.5
    client.close

    assert_equal 1, @received.size
    assert_equal "RuntimeError", @received[0][:body]["error_type"]
    assert_equal "boom", @received[0][:body]["message"]
  end
end

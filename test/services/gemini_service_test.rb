require 'test_helper'
require 'webmock/minitest'

class GeminiServiceTest < ActiveSupport::TestCase
  test "should return insight from Gemini API on successful request" do
    stub_request(:post, /generativelanguage\.googleapis\.com/).
      to_return(
        status: 200,
        body: {
          "candidates" => [{
            "content" => {
              "parts" => [{
                "text" => "This is a test insight."
              }]
            }
          }]
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    insight = GeminiService.generate_insight("test transaction")
    assert_equal "This is a test insight.", insight
  end

  test "should return nil when Gemini API returns an error" do
    stub_request(:post, /generativelanguage\.googleapis\.com/).
      to_return(status: 500, body: "{}")

    insight = GeminiService.generate_insight("test transaction")
    assert_nil insight
  end

  test "should return nil and log error when an exception is raised" do
    stub_request(:post, /generativelanguage\.googleapis\.com/).
      to_raise(StandardError.new("test error"))

    Rails.logger.expects(:error).with("Gemini API Error: test error")
    insight = GeminiService.generate_insight("test transaction")
    assert_nil insight
  end
end
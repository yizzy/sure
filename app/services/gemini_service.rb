require 'net/http'
require 'json'
require 'uri'

class GeminiService
  def self.generate_insight(transaction_description)
    prompt = "Summarize this transaction in plain English: #{transaction_description}"
    response = ask_gemini(prompt)
    response.dig("candidates", 0, "content", "parts", 0, "text")
  rescue => e
    Rails.logger.error "Gemini API Error: #{e.message}"
    nil
  end

  private

  def self.ask_gemini(prompt)
    uri = URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=#{ENV['GEMINI_API_KEY']}")
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = {
      contents: [{
        parts: [{ text: prompt }]
      }]
    }.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    JSON.parse(response.body)
  end
end
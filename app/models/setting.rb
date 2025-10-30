# Dynamic settings the user can change within the app (helpful for self-hosting)
class Setting < RailsSettings::Base
  class ValidationError < StandardError; end

  cache_prefix { "v1" }

  # Third-party API keys
  field :twelve_data_api_key, type: :string, default: ENV["TWELVE_DATA_API_KEY"]
  field :openai_access_token, type: :string, default: ENV["OPENAI_ACCESS_TOKEN"]
  field :openai_uri_base, type: :string, default: ENV["OPENAI_URI_BASE"]
  field :openai_model, type: :string, default: ENV["OPENAI_MODEL"]
  field :brand_fetch_client_id, type: :string, default: ENV["BRAND_FETCH_CLIENT_ID"]

  # Single hash field for all dynamic provider credentials and other dynamic settings
  # This allows unlimited dynamic fields without declaring them upfront
  field :dynamic_fields, type: :hash, default: {}

  # Onboarding and app settings
  ONBOARDING_STATES = %w[open closed invite_only].freeze
  DEFAULT_ONBOARDING_STATE = begin
    env_value = ENV["ONBOARDING_STATE"].to_s.presence || "open"
    ONBOARDING_STATES.include?(env_value) ? env_value : "open"
  end

  field :onboarding_state, type: :string, default: DEFAULT_ONBOARDING_STATE
  field :require_invite_for_signup, type: :boolean, default: false
  field :require_email_confirmation, type: :boolean, default: ENV.fetch("REQUIRE_EMAIL_CONFIRMATION", "true") == "true"

  def self.validate_onboarding_state!(state)
    return if ONBOARDING_STATES.include?(state)

    raise ValidationError, I18n.t("settings.hostings.update.invalid_onboarding_state")
  end

  class << self
    alias_method :raw_onboarding_state, :onboarding_state
    alias_method :raw_onboarding_state=, :onboarding_state=

    def onboarding_state
      value = raw_onboarding_state
      return "invite_only" if value.blank? && require_invite_for_signup

      value.presence || DEFAULT_ONBOARDING_STATE
    end

    def onboarding_state=(state)
      validate_onboarding_state!(state)
      self.require_invite_for_signup = state == "invite_only"
      self.raw_onboarding_state = state
    end

    # Support dynamic field access via bracket notation
    # First checks if it's a declared field, then falls back to dynamic_fields hash
    def [](key)
      key_str = key.to_s

      # Check if it's a declared field first
      if respond_to?(key_str)
        public_send(key_str)
      else
        # Fall back to dynamic_fields hash
        dynamic_fields[key_str]
      end
    end

    def []=(key, value)
      key_str = key.to_s

      # If it's a declared field, use the setter
      if respond_to?("#{key_str}=")
        public_send("#{key_str}=", value)
      else
        # Otherwise, store in dynamic_fields hash
        current_dynamic = dynamic_fields.dup
        current_dynamic[key_str] = value
        self.dynamic_fields = current_dynamic
      end
    end

    # Check if a dynamic field exists (useful to distinguish nil value vs missing key)
    def key?(key)
      key_str = key.to_s
      respond_to?(key_str) || dynamic_fields.key?(key_str)
    end

    # Delete a dynamic field
    def delete(key)
      key_str = key.to_s
      return nil if respond_to?(key_str) # Can't delete declared fields

      current_dynamic = dynamic_fields.dup
      value = current_dynamic.delete(key_str)
      self.dynamic_fields = current_dynamic
      value
    end

    # List all dynamic field keys (excludes declared fields)
    def dynamic_keys
      dynamic_fields.keys
    end
  end

  # Validates OpenAI configuration requires model when custom URI base is set
  def self.validate_openai_config!(uri_base: nil, model: nil)
    # Use provided values or current settings
    uri_base_value = uri_base.nil? ? openai_uri_base : uri_base
    model_value = model.nil? ? openai_model : model

    # If custom URI base is set, model must also be set
    if uri_base_value.present? && model_value.blank?
      raise ValidationError, "OpenAI model is required when custom URI base is configured"
    end
  end
end

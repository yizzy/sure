class LunchflowItem::Importer
  attr_reader :lunchflow_item, :lunchflow_provider

  def initialize(lunchflow_item, lunchflow_provider:)
    @lunchflow_item = lunchflow_item
    @lunchflow_provider = lunchflow_provider
  end

  def import
    Rails.logger.info "LunchflowItem::Importer - Starting import for item #{lunchflow_item.id}"

    # Step 1: Fetch all accounts from Lunchflow
    accounts_data = fetch_accounts_data
    unless accounts_data
      Rails.logger.error "LunchflowItem::Importer - Failed to fetch accounts data for item #{lunchflow_item.id}"
      return { success: false, error: "Failed to fetch accounts data", accounts_imported: 0, transactions_imported: 0 }
    end

    # Store raw payload
    begin
      lunchflow_item.upsert_lunchflow_snapshot!(accounts_data)
    rescue => e
      Rails.logger.error "LunchflowItem::Importer - Failed to store accounts snapshot: #{e.message}"
      # Continue with import even if snapshot storage fails
    end

    # Step 2: Import accounts
    accounts_imported = 0
    accounts_failed = 0

    if accounts_data[:accounts].present?
      accounts_data[:accounts].each do |account_data|
        begin
          import_account(account_data)
          accounts_imported += 1
        rescue => e
          accounts_failed += 1
          account_id = account_data[:id] || "unknown"
          Rails.logger.error "LunchflowItem::Importer - Failed to import account #{account_id}: #{e.message}"
          # Continue importing other accounts even if one fails
        end
      end
    end

    Rails.logger.info "LunchflowItem::Importer - Imported #{accounts_imported} accounts (#{accounts_failed} failed)"

    # Step 3: Fetch transactions for each account
    transactions_imported = 0
    transactions_failed = 0

    lunchflow_item.lunchflow_accounts.each do |lunchflow_account|
      begin
        result = fetch_and_store_transactions(lunchflow_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "LunchflowItem::Importer - Failed to fetch/store transactions for account #{lunchflow_account.account_id}: #{e.message}"
        # Continue with other accounts even if one fails
      end
    end

    Rails.logger.info "LunchflowItem::Importer - Completed import for item #{lunchflow_item.id}: #{accounts_imported} accounts, #{transactions_imported} transactions"

    {
      success: accounts_failed == 0 && transactions_failed == 0,
      accounts_imported: accounts_imported,
      accounts_failed: accounts_failed,
      transactions_imported: transactions_imported,
      transactions_failed: transactions_failed
    }
  end

  private

    def fetch_accounts_data
      begin
        accounts_data = lunchflow_provider.get_accounts
      rescue Provider::Lunchflow::LunchflowError => e
        # Handle authentication errors by marking item as requiring update
        if e.error_type == :unauthorized || e.error_type == :access_forbidden
          begin
            lunchflow_item.update!(status: :requires_update)
          rescue => update_error
            Rails.logger.error "LunchflowItem::Importer - Failed to update item status: #{update_error.message}"
          end
        end
        Rails.logger.error "LunchflowItem::Importer - Lunchflow API error: #{e.message}"
        return nil
      rescue JSON::ParserError => e
        Rails.logger.error "LunchflowItem::Importer - Failed to parse Lunchflow API response: #{e.message}"
        return nil
      rescue => e
        Rails.logger.error "LunchflowItem::Importer - Unexpected error fetching accounts: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        return nil
      end

      # Validate response structure
      unless accounts_data.is_a?(Hash)
        Rails.logger.error "LunchflowItem::Importer - Invalid accounts_data format: expected Hash, got #{accounts_data.class}"
        return nil
      end

      # Handle errors if present in response
      if accounts_data[:error].present?
        handle_error(accounts_data[:error])
        return nil
      end

      accounts_data
    end

    def import_account(account_data)
      # Validate account data structure
      unless account_data.is_a?(Hash)
        Rails.logger.error "LunchflowItem::Importer - Invalid account_data format: expected Hash, got #{account_data.class}"
        raise ArgumentError, "Invalid account data format"
      end

      account_id = account_data[:id]

      # Validate required account_id to prevent duplicate creation
      if account_id.blank?
        Rails.logger.warn "LunchflowItem::Importer - Skipping account with missing ID"
        raise ArgumentError, "Account ID is required"
      end

      lunchflow_account = lunchflow_item.lunchflow_accounts.find_or_initialize_by(
        account_id: account_id.to_s
      )

      begin
        lunchflow_account.upsert_lunchflow_snapshot!(account_data)
        lunchflow_account.save!
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowItem::Importer - Failed to save lunchflow_account: #{e.message}"
        raise StandardError.new("Failed to save account: #{e.message}")
      end
    end

    def fetch_and_store_transactions(lunchflow_account)
      start_date = determine_sync_start_date(lunchflow_account)
      Rails.logger.info "LunchflowItem::Importer - Fetching transactions for account #{lunchflow_account.account_id} from #{start_date}"

      begin
        # Fetch transactions
        transactions_data = lunchflow_provider.get_account_transactions(
          lunchflow_account.account_id,
          start_date: start_date
        )

        # Validate response structure
        unless transactions_data.is_a?(Hash)
          Rails.logger.error "LunchflowItem::Importer - Invalid transactions_data format for account #{lunchflow_account.account_id}"
          return { success: false, transactions_count: 0, error: "Invalid response format" }
        end

        transactions_count = transactions_data[:transactions]&.count || 0
        Rails.logger.info "LunchflowItem::Importer - Fetched #{transactions_count} transactions for account #{lunchflow_account.account_id}"

        # Store transactions in the account
        if transactions_data[:transactions].present?
          begin
            existing_transactions = lunchflow_account.raw_transactions_payload.to_a

            # Build set of existing transaction IDs for efficient lookup
            existing_ids = existing_transactions.map do |tx|
              tx.with_indifferent_access[:id]
            end.to_set

            # Filter to ONLY truly new transactions (skip duplicates)
            # Transactions are immutable on the bank side, so we don't need to update them
            new_transactions = transactions_data[:transactions].select do |tx|
              next false unless tx.is_a?(Hash)

              tx_id = tx.with_indifferent_access[:id]
              tx_id.present? && !existing_ids.include?(tx_id)
            end

            if new_transactions.any?
              Rails.logger.info "LunchflowItem::Importer - Storing #{new_transactions.count} new transactions (#{existing_transactions.count} existing, #{transactions_data[:transactions].count - new_transactions.count} duplicates skipped) for account #{lunchflow_account.account_id}"
              lunchflow_account.upsert_lunchflow_transactions_snapshot!(existing_transactions + new_transactions)
            else
              Rails.logger.info "LunchflowItem::Importer - No new transactions to store (all #{transactions_data[:transactions].count} were duplicates) for account #{lunchflow_account.account_id}"
            end
          rescue => e
            Rails.logger.error "LunchflowItem::Importer - Failed to store transactions for account #{lunchflow_account.account_id}: #{e.message}"
            return { success: false, transactions_count: 0, error: "Failed to store transactions: #{e.message}" }
          end
        else
          Rails.logger.info "LunchflowItem::Importer - No transactions to store for account #{lunchflow_account.account_id}"
        end

        # Fetch and update balance
        begin
          fetch_and_update_balance(lunchflow_account)
        rescue => e
          # Log but don't fail transaction import if balance fetch fails
          Rails.logger.warn "LunchflowItem::Importer - Failed to update balance for account #{lunchflow_account.account_id}: #{e.message}"
        end

        { success: true, transactions_count: transactions_count }
      rescue Provider::Lunchflow::LunchflowError => e
        Rails.logger.error "LunchflowItem::Importer - Lunchflow API error for account #{lunchflow_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: e.message }
      rescue JSON::ParserError => e
        Rails.logger.error "LunchflowItem::Importer - Failed to parse transaction response for account #{lunchflow_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: "Failed to parse response" }
      rescue => e
        Rails.logger.error "LunchflowItem::Importer - Unexpected error fetching transactions for account #{lunchflow_account.id}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        { success: false, transactions_count: 0, error: "Unexpected error: #{e.message}" }
      end
    end

    def fetch_and_update_balance(lunchflow_account)
      begin
        balance_data = lunchflow_provider.get_account_balance(lunchflow_account.account_id)

        # Validate response structure
        unless balance_data.is_a?(Hash)
          Rails.logger.error "LunchflowItem::Importer - Invalid balance_data format for account #{lunchflow_account.account_id}"
          return
        end

        if balance_data[:balance].present?
          balance_info = balance_data[:balance]

          # Validate balance info structure
          unless balance_info.is_a?(Hash)
            Rails.logger.error "LunchflowItem::Importer - Invalid balance info format for account #{lunchflow_account.account_id}"
            return
          end

          # Only update if we have a valid amount
          if balance_info[:amount].present?
            lunchflow_account.update!(
              current_balance: balance_info[:amount],
              currency: balance_info[:currency].presence || lunchflow_account.currency
            )
          else
            Rails.logger.warn "LunchflowItem::Importer - No amount in balance data for account #{lunchflow_account.account_id}"
          end
        else
          Rails.logger.warn "LunchflowItem::Importer - No balance data returned for account #{lunchflow_account.account_id}"
        end
      rescue Provider::Lunchflow::LunchflowError => e
        Rails.logger.error "LunchflowItem::Importer - Lunchflow API error fetching balance for account #{lunchflow_account.id}: #{e.message}"
        # Don't fail if balance fetch fails
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowItem::Importer - Failed to save balance for account #{lunchflow_account.id}: #{e.message}"
        # Don't fail if balance save fails
      rescue => e
        Rails.logger.error "LunchflowItem::Importer - Unexpected error updating balance for account #{lunchflow_account.id}: #{e.class} - #{e.message}"
        # Don't fail if balance update fails
      end
    end

    def determine_sync_start_date(lunchflow_account)
      # Check if this account has any stored transactions
      # If not, treat it as a first sync for this account even if the item has been synced before
      has_stored_transactions = lunchflow_account.raw_transactions_payload.to_a.any?

      if has_stored_transactions
        # Account has been synced before, use item-level logic with buffer
        # For subsequent syncs, fetch from last sync date with a buffer
        if lunchflow_item.last_synced_at
          lunchflow_item.last_synced_at - 7.days
        else
          # Fallback if item hasn't been synced but account has transactions
          90.days.ago
        end
      else
        # Account has no stored transactions - this is a first sync for this account
        # Use account creation date or a generous historical window
        account_baseline = lunchflow_account.created_at || Time.current
        first_sync_window = [ account_baseline - 7.days, 90.days.ago ].max

        # Use the more recent of: (account created - 7 days) or (90 days ago)
        # This caps old accounts at 90 days while respecting recent account creation dates
        first_sync_window
      end
    end

    def handle_error(error_message)
      # Mark item as requiring update for authentication-related errors
      error_msg_lower = error_message.to_s.downcase
      needs_update = error_msg_lower.include?("authentication") ||
                     error_msg_lower.include?("unauthorized") ||
                     error_msg_lower.include?("api key")

      if needs_update
        begin
          lunchflow_item.update!(status: :requires_update)
        rescue => e
          Rails.logger.error "LunchflowItem::Importer - Failed to update item status: #{e.message}"
        end
      end

      Rails.logger.error "LunchflowItem::Importer - API error: #{error_message}"
      raise Provider::Lunchflow::LunchflowError.new(
        "Lunchflow API error: #{error_message}",
        :api_error
      )
    end
end

class LunchflowAccount::Transactions::Processor
  attr_reader :lunchflow_account

  def initialize(lunchflow_account)
    @lunchflow_account = lunchflow_account
  end

  def process
    unless lunchflow_account.raw_transactions_payload.present?
      Rails.logger.info "LunchflowAccount::Transactions::Processor - No transactions in raw_transactions_payload for lunchflow_account #{lunchflow_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = lunchflow_account.raw_transactions_payload.count
    Rails.logger.info "LunchflowAccount::Transactions::Processor - Processing #{total_count} transactions for lunchflow_account #{lunchflow_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    lunchflow_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = LunchflowEntry::Processor.new(
          transaction_data,
          lunchflow_account: lunchflow_account
        ).process

        if result.nil?
          # Transaction was skipped (e.g., no linked account)
          failed_count += 1
          errors << { index: index, transaction_id: transaction_data[:id], error: "No linked account" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "LunchflowAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "LunchflowAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "LunchflowAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "LunchflowAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end
end

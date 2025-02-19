class Schema::Transaction < Lockstep::ApiRecord

# ApiRecord will crash unless `id_ref` is defined
def self.id_ref
  nil
end

  # Group account transaction is associated with.
  # @type: string
  # @format: uuid
  field :group_key

  # The base currency code of the group.
  # @type: string
  field :base_currency_code

  # An additional reference number that is sometimes used to identify a transaction.
  # The meaning of this field is specific to the ERP or accounting system used by the user.
  # @type: string
  field :reference_number

  # The unique ID of the transaction record.
  # @type: string
  # @format: uuid
  field :transaction_id

  # The status of the transaction record.
  #             
  # Recognized Invoice status codes are:
  # * `Open` - Represents an invoice that is considered open and needs more work to complete
  # * `Closed` - Represents an invoice that is considered closed and resolved
  #             
  # Recognized Payment status codes are:
  # * `Open` - Represents an payment that includes some unassigned amount that has not yet been applied to an invoice
  # * `Closed` - Represents an payment where `UnappliedAmount` will be zero
  # @type: string
  field :transaction_status

  # The type of the transaction record.
  #             
  # Recognized Invoice types are:
  # * `AR Invoice` - Represents an invoice sent by Company to the Customer
  # * `AP Invoice` - Represents an invoice sent by Vendor to the Company
  # * `AR Credit Memo` - Represents a credit memo generated by Company given to Customer
  # * `AP Credit Memo` - Represents a credit memo generated by Vendor given to Company
  #             
  # Recognized PaymentType values are:
  # * `AR Payment` - A payment made by a Customer to the Company
  # * `AP Payment` - A payment made by the Company to a Vendor
  # @type: string
  field :transaction_type

  # Additional type categorization of the transaction.
  # @type: string
  field :transaction_sub_type

  # The date when a transaction record was reported.
  # @type: string
  # @format: date-time
  field :transaction_date, Types::Params::DateTime

  # The date when a transaction record is due for payment or completion.
  # @type: string
  # @format: date-time
  field :due_date, Types::Params::DateTime

  # The amount of days past the due date the transaction is left un-closed.
  # @type: integer
  # @format: int32
  field :days_past_due

  # The currency code of the transaction.
  # @type: string
  field :currency_code

  # The total value of this transaction, inclusive or all taxes and line items.
  # @type: number
  # @format: double
  field :transaction_amount

  # The remaining balance of this transaction.
  # @type: number
  # @format: double
  field :outstanding_amount

  # The total value of this transaction, inclusive or all taxes and line items in the group's base currency.
  # @type: number
  # @format: double
  field :base_currency_transaction_amount

  # The remaining balance of this transaction in the group's base currency.
  # @type: number
  # @format: double
  field :base_currency_outstanding_amount

  # The count of items associated to the transaction.
  #             
  # Examples:
  # * Number of payments for an invoice.
  # * Number of invoices a payment or credit memo is applied to.
  # @type: integer
  # @format: int32
  field :transaction_detail_count

  # Specific transactions have support for pdf retrieval from their respective erp. When this flag is true, an additional
  # call to Invoices/{id}/pdf or Payments/{id}/pdf can be made to retrieve a pdf directly from the erp.
  # @type: boolean
  field :supports_erp_pdf_retrieval



end
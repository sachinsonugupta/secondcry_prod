class TransactionsController < ApplicationController

  skip_before_filter :verify_authenticity_token, :only => :payu_response

  before_filter only: [:show] do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_view_your_inbox")
  end
  before_filter do |controller|
    return_url = "#{request.protocol}#{request.host_with_port}/en/transactions/new?utf8=#{params[:utf8]}&listing_id=#{params[:listing_id]}"
    encoded_url = URI.encode(return_url)
    return_with_fb_login = URI.parse(encoded_url)
    session[:return_to_content] = "#{return_with_fb_login}"
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_do_a_transaction")
  end

  MessageForm = Form::Message

  TransactionForm = EntityUtils.define_builder(
    [:listing_id, :fixnum, :to_integer, :mandatory],
    [:message, :string],
    [:quantity, :fixnum, :to_integer, default: 1],
    [:start_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ],
    [:end_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ]
  )

  def new
    Result.all(
      ->() {
        fetch_data(params[:listing_id])
      },
      ->((listing_id, listing_model)) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community)
      }
    ).on_success { |((listing_id, listing_model, author_model, process, gateway))|
      booking = listing_model.unit_type == :day

      transaction_params = HashUtils.symbolize_keys({listing_id: listing_model.id}.merge(params.slice(:start_on, :end_on, :quantity, :delivery)))

      @shipping_address = ShippingAddress.where("person_id = '#{@current_user.id}' and address_type = 'buyer'").last
      if @shipping_address.blank?
        @shipping_address = ShippingAddress.where("person_id = '#{@current_user.id}' and address_type = 'seller'").last
      end  
      
      # Only selling and renting listings should get payment button
      listing = Listing.where("id = #{params[:listing_id]}").first
      listing_shape = ListingShape.find(listing.listing_shape_id)
      @payment_button = 0
      if (listing_shape.name == "selling" || listing_shape.name == "renting-out")
        @payment_button = 1
      end

      # fill the phone number from user profile (if present)
      person = Person.find_by_id(@current_user.id)
      if !person.blank?
        @phone_number = person.phone_number
      end

      case [process[:process], gateway, booking]
      when matches([:none])
        render_free(listing_model: listing_model, author_model: author_model, community: @current_community, params: transaction_params)
      when matches([:preauthorize, __, true])
        redirect_to book_path(transaction_params)
      when matches([:preauthorize, :paypal])
        redirect_to initiate_order_path(transaction_params)
      when matches([:preauthorize, :braintree])
        redirect_to preauthorize_payment_path(transaction_params)
      when matches([:postpay])
        redirect_to post_pay_listing_path(transaction_params)
      else
        opts = "listing_id: #{listing_id}, payment_gateway: #{gateway}, payment_process: #{process}, booking: #{booking}"
        raise ArgumentError.new("Cannot find new transaction path to #{opts}")
      end
    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      redirect_to(session[:return_to_content] || root)
    }
  end
  
  def fetch_city_state_from_pincode
    response_hash = Hash.new
    if !params[:pincode].blank?
      uri = URI("http://postalpincode.in/api/pincode/#{params[:pincode]}")
      response = Net::HTTP.get(uri)
      api_response = JSON.parse(response)
      if api_response["Status"] == 'Error'
        response_hash[:status] == "failure"
      else
        if api_response["PostOffice"][0]["Circle"] == "NA"
          response_hash[:district] = api_response["PostOffice"][0]["District"]
        else
          response_hash[:district] = api_response["PostOffice"][0]["Taluk"]
        end
        response_hash[:state] = api_response["PostOffice"][0]["State"]
        response_hash[:status] = "success"
      end
    end
    render :json => response_hash.to_json, :callback => params[:callback]
  end

  def create
    Result.all(
      ->() {
        TransactionForm.validate(params)
      },
      ->(form) {
        fetch_data(form[:listing_id])
      },
      ->(form, (_, _, _, process)) {
        validate_form(form, process)
      },
      ->(_, (listing_id, listing_model), _) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community)
      },
      ->(form, (listing_id, listing_model, author_model, process, gateway), _, _) {
        booking_fields = Maybe(form).slice(:start_on, :end_on).select { |booking| booking.values.all? }.or_else({})

        quantity = Maybe(booking_fields).map { |b| DateUtils.duration_days(b[:start_on], b[:end_on]) }.or_else(form[:quantity])

        TransactionService::Transaction.create(
          {
            transaction: {
              community_id: @current_community.id,
              listing_id: listing_id,
              listing_title: listing_model.title,
              starter_id: @current_user.id,
              listing_author_id: author_model.id,
              unit_type: listing_model.unit_type,
              unit_price: listing_model.price,
              shipping_price: listing_model.shipping_price,
              unit_tr_key: listing_model.unit_tr_key,
              listing_quantity: quantity,
              content: form[:message],
              booking_fields: booking_fields,
              payment_gateway: process[:process] == :none ? :none : gateway, # TODO This is a bit awkward
              payment_process: process[:process]}
          })
      }
    ).on_success { |(_, (_, _, _, process), _, _, tx)|
      after_create_actions!(process: process, transaction: tx[:transaction], community_id: @current_community.id)
      flash[:notice] = after_create_flash(process: process) # add more params here when needed

      # proceed to payment page only when listing is of type selling and renting
      listing = Listing.where("id = #{params[:listing_id]}").first
      listing_shape = ListingShape.find(listing.listing_shape_id)

      if (listing_shape.name != "selling" && listing_shape.name != "renting-out")
        redirect_to after_create_redirect(process: process, starter_id: @current_user.id, transaction: tx[:transaction]) # add more params here when needed
      else
        transaction = Transaction.find(tx[:transaction][:id])
        listing = Listing.where("id = '#{transaction.listing_id}'").first
        shipping_price = listing.shipping_price.blank? ? 0:listing.shipping_price

        email = Email.where("person_id = '#{@current_user.id}' and confirmed_at is not null").first
        transaction_amount = transaction.unit_price * transaction.listing_quantity + shipping_price
        date = "#{Date.today}".gsub('-','')

        render "transactions/payu", locals: {
          pay_url: "#{PAYU_URL}",
          key:     "#{PAYU_KEY}",
          orderId: "#{date}#{transaction.id}",
          amount:  "#{transaction_amount}",
          product_name: "#{transaction.listing_title}",
          firstName: "#{params[:name]}",
          email:     "#{email.address}",
          phoneNo:   "#{params[:phone_number]}",
          address1:  "#{params[:address1]}",
          address2:  "#{params[:address2]}",
          city:      "#{params[:city]}",
          state:     "#{params[:state]}",
          zipcode:   "#{params[:pincode]}",
          country:   "India",
          udf1: "#{transaction.conversation_id}",
          surl: "#{request.protocol}#{request.host_with_port}/payu_response",
          furl: "#{request.protocol}#{request.host_with_port}/payu_response",
          hash: Digest::SHA2.new(512).hexdigest("#{PAYU_KEY}|#{date}#{transaction.id}|#{transaction_amount}|#{transaction.listing_title}|#{params[:name]}|#{email.address}|#{transaction.conversation_id}||||||||||#{PAYU_SALT}")
        }
      end
    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      redirect_to(session[:return_to_content] || root)
    }
  end

  def payu_response
    hash_value = params[:hash]
    transaction_id = params[:txnid].slice(8..-1)
    transaction = Transaction.where("id = #{transaction_id}").first
    buyer = Person.find_by_id(@current_user.id)
    seller = Person.find_by_id(transaction.listing.author_id)
    if !buyer.blank? && buyer.phone_number.blank?
      buyer.phone_number = params[:phone]
      buyer.save
    end
    
    shipping_address = ShippingAddress.create(:transaction_id => transaction_id, :status => params[:status], :name => params[:firstname], :phone => params[:phone], :street1 => params[:address1], :street2 => params[:address2],
    :city => params[:city], :state_or_province => params[:state], :country => params[:country], :person_id => @current_user.id, :postal_code => params[:zipcode], :address_type => "buyer")
    
    value = "#{PAYU_SALT}|#{params[:status]}||||||||||#{params[:udf1]}|#{params[:email]}|#{params[:firstname]}|#{params[:productinfo]}|#{params[:amount]}|#{params[:txnid]}|#{PAYU_KEY}"
    reshashvalue = Digest::SHA2.new(512).hexdigest("#{value}")

    is_payment_success = !hash_value.blank? && params[:status] == "success" && (hash_value == reshashvalue)

    if is_payment_success
      payment_string = "Dear #{seller.given_name},
I have successfully made the payment of Rs.#{params[:amount]} to SecondCry towards your listing \"#{params[:productinfo]}\". Transaction reference number is #{params[:txnid]}.
Kindly acknowledge that the product is with you and ready to ship by replying \"I accept\" to this message. Along with this, please ensure your bank details are updated.
Once the product reaches me and is acceptable, I will also reply back \"I accept\" to your message and Secondcry will release the payment to your bank account.
Thanks."

      transaction.listing.open = 0
      transaction.listing.save
      transaction.order_status = 'payment successfull'
      transaction.save
    else
      payment_string = "Dear #{seller.given_name},
Attempt to make payment of Rs.#{params[:amount]} to SecondCry towards your listing \"#{params[:productinfo]}\" failed due to some reason.
If I am still interested, I will retry. This transaction stands closed.
Thanks."
      transaction.order_status = 'payment failure'
      transaction.save
    end

    # add payment status message to the transaction message log
    messageController = MessagesController.new
    messageController.request = request
    messageController.response = response
    post_params = {
      :post_payu_flow => true,
      :current_user_id => @current_user.id,
      :message => {
        :conversation_id => "#{params[:udf1]}",
        :content => "#{payment_string}"
      }
    }
    messageController.params = post_params
    messageController.create

    # email admins
    payment_status = params[:status]
    transaction_url = "#{request.protocol}#{request.host_with_port}/en/transactions/#{params[:udf1]}"
    listing_url = "#{request.protocol}#{request.host_with_port}/en/listings/#{transaction.listing.id}"
    MailCarrier.deliver_now(TransactionMailer.order_created(transaction_url, payment_status, listing_url, params))

    # redirect to transaction's history of conversations
    redirect_to "#{request.protocol}#{request.host_with_port}/en/transactions/#{transaction_id}"
  end
  
  def pickup
    if params[:txn_id].blank?
      flash[:error] = t("layouts.notifications.you_are_not_authorized_to_view_this_content")
      redirect_to root
    else
      @transactions = Transaction.where("listing_author_id = '#{@current_user.id}' and id = '#{params[:txn_id]}'").first
      if !@transactions.blank?
        @pickup_address = ShippingAddress.where("person_id = '#{@transactions.listing_author_id}' and address_type = 'seller'").last
        if @pickup_address.blank?
          @pickup_address = ShippingAddress.where("person_id = '#{@transactions.listing_author_id}' and address_type = 'buyer'").last
        end
        person = Person.find_by_id(@current_user.id)
          if !person.blank?
            @phone_number = person.phone_number
          end
      else
        flash[:error] = t("layouts.notifications.you_are_not_authorized_to_view_this_content")
        redirect_to root          
      end
    end
  end
  
  def save_seller_address
    transaction = Transaction.where("id = '#{params[:tx_id]}'").first
    pickup_address = ShippingAddress.where("transaction_id = '#{params[:tx_id]}' and person_id = '#{params[:author_id]}' and address_type = 'seller'").last
    if pickup_address.blank?
      pickup_address = ShippingAddress.create(:transaction_id => params[:tx_id], :status => "success", :name => params[:name], :phone => params[:phone_number], :street1 => params[:address1], :street2 => params[:address2],
      :city => params[:city], :state_or_province => params[:state], :country => "India", :person_id => params[:author_id], :postal_code => params[:pincode], :address_type => "seller")
      seller = Person.find_by_id(@current_user.id)
      if !seller.blank? && seller.phone_number.blank?
        seller.phone_number = params[:phone]
        seller.save
      end
      message = Message.new
      message.conversation_id = transaction.conversation_id
      message.sender_id = params[:author_id]
      message.content = "I have accepted the transaction and shared my pickup details with Secondcry. We will hear from Secondcry in next 24 hours about the next steps."
      message.save
      transaction.order_status = 'order accepted'
      transaction.save
    else
      pickup_address = pickup_address.update_attributes(:status => "success", :name => params[:name], :phone => params[:phone_number], :street1 => params[:address1], :street2 => params[:address2],
      :city => params[:city], :state_or_province => params[:state], :country => "India", :person_id => params[:author_id], :postal_code => params[:pincode], :address_type => "seller")
    end
    flash[:notice] = "Your address updated successfully"
    redirect_to "#{request.protocol}#{request.host_with_port}/en/transactions/#{params[:tx_id]}"    
  end
  
  def save_decline_message
    transaction = Transaction.where("id = '#{params[:txn_id]}'").first
    transaction.order_status = 'cancelled by seller'
    transaction.save
    message = Message.new
    message.conversation_id = transaction.conversation_id
    message.sender_id = @current_user.id
    message.content = "The product is not available for sale anymore. You will receive a refund from Secondcry within 7 working days. Apologies for the inconvenience caused. The listing is now closed."
    message.save
    flash[:notice] = "Buyer has been informed of your refusal. Your listing is now closed."
    redirect_to "#{request.protocol}#{request.host_with_port}/en/transactions/#{params[:txn_id]}"
  end

  def show
    m_participant =
      Maybe(
        MarketplaceService::Transaction::Query.transaction_with_conversation(
        transaction_id: params[:id],
        person_id: @current_user.id,
        community_id: @current_community.id))
      .map { |tx_with_conv| [tx_with_conv, :participant] }

    m_admin =
      Maybe(@current_user.has_admin_rights_in?(@current_community))
      .select { |can_show| can_show }
      .map {
        MarketplaceService::Transaction::Query.transaction_with_conversation(
          transaction_id: params[:id],
          community_id: @current_community.id)
      }
      .map { |tx_with_conv| [tx_with_conv, :admin] }

    transaction_conversation, role = m_participant.or_else { m_admin.or_else([]) }

    tx = TransactionService::Transaction.get(community_id: @current_community.id, transaction_id: params[:id])
         .maybe()
         .or_else(nil)

    unless tx.present? && transaction_conversation.present?
      flash[:error] = t("layouts.notifications.you_are_not_authorized_to_view_this_content")
      return redirect_to root
    end

    tx_model = Transaction.where(id: tx[:id]).first
    conversation = transaction_conversation[:conversation]
    listing = Listing.where(id: tx[:listing_id]).first

    @address_button = 0
    if (tx_model.listing_author_id == @current_user.id) && (tx_model.order_status == 'payment successfull') 
      @address_button = 1
    end

    messages_and_actions = TransactionViewUtils.merge_messages_and_transitions(
      TransactionViewUtils.conversation_messages(conversation[:messages], @current_community.name_display_type),
      TransactionViewUtils.transition_messages(transaction_conversation, conversation, @current_community.name_display_type))

    MarketplaceService::Transaction::Command.mark_as_seen_by_current(params[:id], @current_user.id)

    is_author =
      if role == :admin
        true
      else
        listing.author_id == @current_user.id
      end

    render "transactions/show", locals: {
      messages: messages_and_actions.reverse,
      transaction: tx,
      listing: listing,
      transaction_model: tx_model,
      conversation_other_party: person_entity_with_url(conversation[:other_person]),
      is_author: is_author,
      role: role,
      address_button: @address_button,
      message_form: MessageForm.new({sender_id: @current_user.id, conversation_id: conversation[:id]}),
      message_form_action: person_message_messages_path(@current_user, :message_id => conversation[:id]),
      price_break_down_locals: price_break_down_locals(tx)
    }
  end

  def op_status
    process_token = params[:process_token]

    resp = Maybe(process_token)
      .map { |ptok| paypal_process.get_status(ptok) }
      .select(&:success)
      .data
      .or_else(nil)

    if resp
      render :json => resp
    else
      redirect_to error_not_found_path
    end
  end

  def person_entity_with_url(person_entity)
    person_entity.merge({
      url: person_path(id: person_entity[:username]),
      display_name: PersonViewUtils.person_entity_display_name(person_entity, @current_community.name_display_type)})
  end

  def paypal_process
    PaypalService::API::Api.process
  end

  private

  def ensure_can_start_transactions(listing_model:, current_user:, current_community:)
    error =
      if listing_model.closed?
        "layouts.notifications.you_cannot_reply_to_a_closed_offer"
      elsif listing_model.author == current_user
       "layouts.notifications.you_cannot_send_message_to_yourself"
      elsif !listing_model.visible_to?(current_user, current_community)
        "layouts.notifications.you_are_not_authorized_to_view_this_content"
      end

    if error
      Result::Error.new(error, {error_tr_key: error})
    else
      Result::Success.new
    end
  end

  def after_create_flash(process:)
    case process[:process]
    when :none
      t("layouts.notifications.message_sent")
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def after_create_redirect(process:, starter_id:, transaction:)
    case process[:process]
    when :none
      person_transaction_path(person_id: starter_id, id: transaction[:id])
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def after_create_actions!(process:, transaction:, community_id:)
    case process[:process]
    when :none
      # TODO Do I really have to do the state transition here?
      # Shouldn't it be handled by the TransactionService
      MarketplaceService::Transaction::Command.transition_to(transaction[:id], "free")

      # TODO: remove references to transaction model
      transaction = Transaction.find(transaction[:id])

      Delayed::Job.enqueue(MessageSentJob.new(transaction.conversation.messages.last.id, community_id))
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  # Fetch all related data based on the listing_id
  #
  # Returns: Result::Success([listing_id, listing_model, author, process, gateway])
  #
  def fetch_data(listing_id)
    Result.all(
      ->() {
        if listing_id.nil?
          Result::Error.new("No listing ID provided")
        else
          Result::Success.new(listing_id)
        end
      },
      ->(l_id) {
        # TODO Do not use Models directly. The data should come from the APIs
        Maybe(@current_community.listings.where(id: l_id).first)
          .map     { |listing_model| Result::Success.new(listing_model) }
          .or_else { Result::Error.new("Cannot find listing with id #{l_id}") }
      },
      ->(_, listing_model) {
        # TODO Do not use Models directly. The data should come from the APIs
        Result::Success.new(listing_model.author)
      },
      ->(_, listing_model, *rest) {
        TransactionService::API::Api.processes.get(community_id: @current_community.id, process_id: listing_model.transaction_process_id)
      },
      ->(*) {
        Result::Success.new(MarketplaceService::Community::Query.payment_type(@current_community.id))
      }
    )
  end

  def validate_form(form_params, process)
    if process[:process] == :none && form_params[:message].blank?
      Result::Error.new("Message cannot be empty")
    else
      Result::Success.new
    end
  end

  def price_break_down_locals(tx)
    if tx[:payment_process] == :none && tx[:listing_price].cents == 0
      nil
    else
      unit_type = tx[:unit_type].present? ? ListingViewUtils.translate_unit(tx[:unit_type], tx[:unit_tr_key]) : nil
      localized_selector_label = tx[:unit_type].present? ? ListingViewUtils.translate_quantity(tx[:unit_type], tx[:unit_selector_tr_key]) : nil
      booking = !!tx[:booking]
      quantity = tx[:listing_quantity]
      show_subtotal = !!tx[:booking] || quantity.present? && quantity > 1 || tx[:shipping_price].present?
      total_label = (tx[:payment_process] != :preauthorize) ? t("transactions.price") : t("transactions.total")
      shipping_price = !tx[:shipping_price].blank? ? tx[:shipping_price] : 0
      
      TransactionViewUtils.price_break_down_locals({
        listing_price: tx[:listing_price],
        localized_unit_type: unit_type,
        localized_selector_label: localized_selector_label,
        booking: booking,
        start_on: booking ? tx[:booking][:start_on] : nil,
        end_on: booking ? tx[:booking][:end_on] : nil,
        duration: booking ? tx[:booking][:duration] : nil,
        quantity: quantity,
        subtotal: show_subtotal ? tx[:listing_price] * quantity : nil,
        total: Maybe(tx[:payment_total]).or_else(tx[:checkout_total]) + shipping_price,
        shipping_price: tx[:shipping_price],
        total_label: total_label
      })
    end
  end

  def render_free(listing_model:, author_model:, community:, params:)
    # TODO This data should come from API
    listing = {
      id: listing_model.id,
      title: listing_model.title,
      action_button_label: t(listing_model.action_button_tr_key),
      price: listing_model.price
    }
    author = {
      display_name: PersonViewUtils.person_display_name(author_model, community),
      username: author_model.username
    }

    unit_type = listing_model.unit_type.present? ? ListingViewUtils.translate_unit(listing_model.unit_type, listing_model.unit_tr_key) : nil
    localized_selector_label = listing_model.unit_type.present? ? ListingViewUtils.translate_quantity(listing_model.unit_type, listing_model.unit_selector_tr_key) : nil
    booking_start = Maybe(params)[:start_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking_end = Maybe(params)[:end_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking = !!(booking_start && booking_end)
    duration = booking ? DateUtils.duration_days(booking_start, booking_end) : nil
    quantity = Maybe(booking ? DateUtils.duration_days(booking_start, booking_end) : TransactionViewUtils.parse_quantity(params[:quantity])).or_else(1)
    total_label = t("transactions.price")
    shipping_price = listing_model.shipping_price.blank? ? 0:listing_model.shipping_price
    
    m_price_break_down = Maybe(listing_model).select { |l_model| l_model.price.present? }.map { |l_model|
      TransactionViewUtils.price_break_down_locals(
        {
          listing_price: l_model.price,
          localized_unit_type: unit_type,
          localized_selector_label: localized_selector_label,
          booking: booking,
          start_on: booking_start,
          end_on: booking_end,
          duration: duration,
          quantity: quantity,
          subtotal: quantity != 1 ? l_model.price * quantity : nil,
          total: l_model.price * quantity + shipping_price,
          shipping_price: l_model.shipping_price,
          total_label: total_label
        })
    }

    render "transactions/new", locals: {
             listing: listing,
             author: author,
             action_button_label: t(listing_model.action_button_tr_key),
             m_price_break_down: m_price_break_down,
             booking_start: booking_start,
             booking_end: booking_end,
             quantity: quantity,
             form_action: person_transactions_path(person_id: @current_user, listing_id: listing_model.id)
           }
  end
end

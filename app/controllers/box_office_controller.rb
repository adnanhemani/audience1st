class BoxOfficeController < ApplicationController

  before_filter(:is_boxoffice_filter,
                :redirect_to => { :controller => :customers, :action => :login})

  # sets  instance variable @showdate and others for every method.
  before_filter :get_showdate, :except => [:mark_checked_in, :modify_walkup_vouchers]
  verify(:method => :post,
         :only => %w(do_walkup_sale modify_walkup_vouchers),
         :redirect_to => { :action => :walkup, :id => @showdate },
    :add_to_flash => {:warning => "Warning: action only callable as POST, no transactions were recorded! "})
  verify :method => :post, :only => :mark_checked_in
  ssl_required(:walkup, :do_walkup_sale)
  ssl_allowed :change_showdate
  
  private

  # this filter must setup @showdates and @showdate to non-nil,
  # or else force a redirect to a different controller & action
  def get_showdate
    @showdates = Showdate.find(:all,
      :conditions => ['thedate >= ?', Time.now.at_beginning_of_season - 1.year],
      :order => "thedate ASC")
    return true if (!params[:id].blank?) &&
      (@showdate = Showdate.find_by_id(params[:id].to_i))
    if (@showdate = (Showdate.current_or_next(2.hours) ||
                    Showdate.find(:first, :order => "thedate DESC")))
      redirect_to :action => action_name, :id => @showdate
    else
      flash[:notice] = "There are no shows listed.  Please add some."
      redirect_to :controller => 'shows', :action => 'index'
    end
  end

  def vouchers_for_showdate(showdate)
    perf_vouchers = @showdate.advance_sales_vouchers
    total = perf_vouchers.size
    num_subscribers = perf_vouchers.select { |v| v.customer.subscriber? }.size
    vouchers = perf_vouchers.group_by do |v|
      "#{v.customer.last_name},#{v.customer.first_name},#{v.customer_id},#{v.vouchertype_id}"
    end
    return [total,num_subscribers,vouchers]
  end

  def at_least_1_ticket_or_donation
    if (@qty.values.map(&:to_i).sum.zero?  &&  @donation.zero?)
      logger.info(flash[:warning] = "No tickets or donation to process")
      nil
    else
      true
    end
  end

  # given a hash of valid-voucher ID's and quantities, compute the total
  # price represented if those vouchers were to be purchase

  def compute_price(qtys,donation='')
    total = 0.0
    qtys.each_pair do |vtype,q|
      total += q.to_i * ValidVoucher.find(vtype).price
    end
    total += donation.to_f
    total
  end



  # process a sale of walkup vouchers by linking them to the walkup customer
  # pass a hash of {ValidVoucher ID => quantity} pairs
  
  def process_walkup_vouchers(qtys,howpurchased = Purchasemethod.find_by_shortdesc('none'), comment = '')
    vouchers = []
    qtys.each_pair do |vtype,q|
      vv = ValidVoucher.find(vtype)
      vouchers += vv.instantiate(Customer.find(logged_in_id), howpurchased, q.to_i, comment)
    end
    Customer.walkup_customer.vouchers += vouchers
    (flash[:notice] ||= "") << "Successfully added #{vouchers.size} vouchers"
  end

  public

  def index
    redirect_to :action => :walkup, :id => params[:id]
  end

  def change_showdate
    unless ((sd = params[:id].to_i) &&
            (showdate = Showdate.find_by_id(sd)))
      flash[:notice] = "Invalid show date."
    end
    redirect_to :action => 'walkup', :id => sd
  end

  def checkin
    @total,@num_subscribers,@vouchers = vouchers_for_showdate(@showdate)
  end

  def mark_checked_in
    render :nothing => true and return unless params[:vouchers]
    vouchers = params[:vouchers].split(/,/).map { |v| Voucher.find_by_id(v) }.compact
    if params[:uncheck]
      vouchers.map { |v| v.un_check_in! }
    else
      vouchers.map { |v| v.check_in! }
    end
    render :update do |page|
      showdate = vouchers.first.showdate
      page.replace_html 'show_stats', :partial => 'show_stats', :locals => {:showdate => showdate}
      if params[:uncheck]
        vouchers.each { |v| page[v.id.to_s].removeClassName('checked_in') }
      else
        vouchers.each { |v| page[v.id.to_s].addClassName('checked_in') }
      end
    end
  end

  def door_list
    @total,@num_subscribers,@vouchers = vouchers_for_showdate(@showdate)
    if @vouchers.empty?
      flash[:notice] = "No reservations for '#{@showdate.printable_name}'"
      redirect_to :action => 'walkup', :id => @showdate
    else
      render :layout => 'door_list'
    end
  end

  def walkup
    @showdate = (Showdate.find_by_id(params[:id]) ||
      Showdate.current_or_next(2.hours))
    @valid_vouchers = @showdate.valid_vouchers_for_walkup
    @qty = params[:qty] || {}     # voucher quantities
  end

  def do_walkup_sale
    @qty = params[:qty]
    @donation = params[:donation].to_f
    redirect_to :action => 'walkup', :id => @showdate and return unless at_least_1_ticket_or_donation
    begin
      total = compute_price(@qty, @donation) 
    rescue Exception => e
      flash[:warning] =
        "There was a problem verifying the amount of the order:<br/>#{e.message}"
      redirect_to(:action => 'walkup', :id => @showdate) and return
    end
    if total == 0.0 # zero-cost purchase
      process_walkup_vouchers(@qty, p=Purchasemethod.find_by_shortdesc('none'), 'Zero revenue transaction')
      Txn.add_audit_record(:txn_type => 'tkt_purch',
                           :customer_id => Customer.walkup_customer.id,
                           :comments => 'walkup',
                           :purchasemethod_id => p,
                           :logged_in_id => logged_in_id)
      flash[:notice] << " as zero-revenue order"
      logger.info "Zero revenue order successful"
      redirect_to :action => 'walkup', :id => @showdate
      return
    end
    # if there was a swipe_data field, a credit card was swiped, so
    # assume it was a credit card purchase; otherwise depends on which
    # submit button was used.
    params[:commit] ||= 'credit' # Stripe form-resubmit from Javascript doesn't pass name of submit button
    case params[:commit]
    when /credit/i
      method,how = :credit_card, Purchasemethod.find_by_shortdesc('box_cc')
      comment = ''
      args = {
        :bill_to => Customer.new(:first_name => params[:credit_card][:first_name],
          :last_name => params[:credit_card][:last_name]),
        :comment => '(walkup)',
        :credit_card_token => params[:credit_card_token],
        :order_number => Cart.generate_order_id
      }
    when /cash|zero/i
      method,how = :cash, Purchasemethod.find_by_shortdesc('box_cash')
      comment = ''
      args = {}
    when /check/i
      method,how = :check, Purchasemethod.find_by_shortdesc('box_chk')
      comment = params[:check_number].blank? ? '' : "Check #: #{params[:check_number]}"
      args = {}
    else
      logger.info(flash[:notice] = "Unrecognized purchase type: #{params[:commit]}")
      redirect_to(:action => 'walkup', :id => @showdate, :qty => @qty, :donation => @donation) and return
    end
    resp = Store.purchase!(method,total,args) do
      process_walkup_vouchers(@qty, how, comment)
      Donation.walkup_donation(@donation,logged_in_id) if @donation > 0.0
      Txn.add_audit_record(:txn_type => 'tkt_purch',
        :customer_id => Customer.walkup_customer.id,
        :comments => 'walkup',
        :purchasemethod_id => how.id,
        :logged_in_id => logged_in_id)
    end
    if resp.success?
      flash[:notice] << " purchased via #{how.description}"
      logger.info "Successful #{how.description} walkup"
      redirect_to :action => 'walkup', :id => @showdate
    else
      flash[:warning] = "Transaction NOT processed: #{resp.message}"
      flash[:notice] = ''
      logger.info "Failed walkup sale: #{resp.message}"
      redirect_to :action => 'walkup', :id => @showdate, :qty => @qty, :donation => @donation
    end
  end

  def walkup_report
    @vouchers = @showdate.walkup_vouchers.group_by(&:purchasemethod)
    @subtotal = {}
    @total = 0
    @vouchers.each_pair do |purch,vouchers|
      @subtotal[purch] = vouchers.map(&:price).sum
      @total += @subtotal[purch]
    end
    @other_showdates = @showdate.show.showdates
  end

  # process a change of walkup vouchers by either destroying them or moving them
  # to another showdate, as directed
  def modify_walkup_vouchers
    if params[:vouchers].blank?
      flash[:warning] = "You didn't select any vouchers to remove or transfer."
      redirect_to(:action => :index) and return
    end
    voucher_ids = params[:vouchers]
    action = params[:commit].to_s
    showdate_id = 0
    begin
      vouchers = Voucher.find(voucher_ids)
      showdate_id = vouchers.first.showdate_id
      if action =~ /destroy/i
        Voucher.destroy_multiple(vouchers, logged_in_user)
        flash[:notice] = "#{vouchers.length} vouchers destroyed."
      elsif action =~ /transfer/i # transfer vouchers to another showdate
        showdate = Showdate.find(params[:to_showdate])
        Voucher.transfer_multiple(vouchers, showdate, logged_in_user)
        flash[:notice] = "#{vouchers.length} vouchers transferred to #{showdate.printable_name}."
      else
        flash[:warning] = "Unrecognized action: '#{action}'"
      end
    rescue Exception => e
      flash[:warning] = "Error (NO changes were made): #{e.message}"
      RAILS_DEFAULT_LOGGER.warn(e.backtrace)
    end
    redirect_to :action => :index, :id => showdate_id
  end

end

=begin rdoc
A ValidVoucher is a record indicating the conditions under which a particular
voucher type can be redeemed.  For non-subscriptions, the valid voucher refers
to a particular showdate ID.  For subscriptions, the showdate ID is zero.
#
is a record that states "for a particular showdate ID, this particular type of voucher
is accepted", and encodes additional information such as the capacity limit for this vouchertype for thsi
 performance, the start and end dates of redemption for this vouchertype, etc.
=end

class ValidVoucher < ActiveRecord::Base

  class InvalidRedemptionError < RuntimeError ;  end
  class InvalidProcessedByError < RuntimeError ; end

  belongs_to :showdate
  belongs_to :vouchertype
  validates_associated :showdate, :if => lambda { |v| !(v.vouchertype.bundle?) }
  validates_associated :vouchertype
  validates_numericality_of :max_sales_for_type, :allow_nil => true, :greater_than_or_equal_to => 0
  validates_presence_of :start_sales
  validates_presence_of :end_sales


  # Capacity is infinite if it is left blank
  INFINITE = 1 << 20
  def max_sales_for_type ; self[:max_sales_for_type] || INFINITE ; end
  def sales_unlimited?   ; max_sales_for_type >= INFINITE ; end

  validate :check_dates

  # for a given showdate ID, a particular vouchertype ID should be listed only once.
  validates_uniqueness_of :vouchertype_id, :scope => :showdate_id, :message => "already valid for this performance", :unless => lambda { |s| s.showdate_id.nil? }

  attr_accessor :customer, :supplied_promo_code # used only when checking visibility - not stored
  attr_accessor :explanation # tells customer/staff why the # of avail seats is what it is
  attr_accessor :visible     # should this offer be viewable by non-admins?
  alias_method :visible?, :visible # for convenience and more readable specs

  delegate :name, :price, :name_with_price, :display_order, :visible_to?, :season, :offer_public_as_string, :to => :vouchertype
  delegate :<=>, :printable_name, :thedate, :saleable_seats_left, :to => :showdate

  def event_type
    showdate.try(:show).try(:event_type)
  end

  def self.from_params(valid_vouchers_hash)
    result = {}
    (valid_vouchers_hash || {}).each_pair do |id,qty|
      if ((vv = self.find_by_id(id)) &&
          ((q = qty.to_i) > 0))
        result[vv] = q
      end
    end
    result
  end

  private

  # Vouchertype's valid date must not be later than valid_voucher start date
  # Vouchertype expiration date must not be earlier than valid_voucher end date
  def check_dates
    errors.add_to_base("Dates and times for start and end sales must be provided") and return if (start_sales.blank? || end_sales.blank?)
    errors.add_to_base("Start sales time cannot be later than end sales time") and return if start_sales > end_sales
    vt = self.vouchertype
    if self.end_sales > (end_of_season = Time.now.at_end_of_season(vt.season))
      errors.add_to_base "Voucher type '#{vt.name}' is valid for the
        season ending #{end_of_season.to_formatted_s(:showtime_including_year)},
        but you've indicated sales should continue later than that
        (until #{end_sales.to_formatted_s(:showtime_including_year)})."
    end
  end

  def match_promo_code(str)
    promo_code.blank? || str.to_s.contained_in_or_blank(promo_code)
  end

  protected
  
  def adjust_for_visibility
    if !match_promo_code(supplied_promo_code)
      self.explanation = 'Promo code required'
      self.visible = false
    elsif !visible_to?(customer)
      self.explanation = "Ticket sales of this type restricted to #{offer_public_as_string}"
      self.visible = false
    end
    self.max_sales_for_type = 0 if !self.explanation.blank?
    !self.explanation.blank?
  end

  def adjust_for_showdate
    if !showdate
      self.max_sales_for_type = 0
      return nil
    end
    if showdate.thedate < Time.now
      self.explanation = 'Event date is in the past'
      self.visible = false
    elsif showdate.really_sold_out?
      self.explanation = 'Event is sold out'
      self.visible = true
    end
    self.max_sales_for_type = 0 if !self.explanation.blank?
    !self.explanation.blank?
  end

  def adjust_for_sales_dates
    now = Time.now
    if showdate && (now > showdate.end_advance_sales)
      self.explanation = 'Advance sales for this performance are closed'
      self.visible = true
    elsif now < start_sales
      self.explanation = "Tickets of this type not on sale until #{start_sales.to_formatted_s(:showtime)}"
      self.visible = true
    elsif now > end_sales
      self.explanation = "Tickets of this type not sold after #{end_sales.to_formatted_s(:showtime)}"
      self.visible = true
    end
    self.max_sales_for_type = 0 if !self.explanation.blank?
    !self.explanation.blank?
  end

  def adjust_for_advance_reservations
    if Time.now > end_sales
      self.explanation = 'Advance reservations for this performance are closed'
      self.max_sales_for_type = 0
    end
    !self.explanation.blank?
  end

  def adjust_for_capacity
    self.max_sales_for_type = seats_of_type_remaining()
    self.explanation =
      case max_sales_for_type
      when 0 then "No seats remaining for tickets of this type"
      when INFINITE then "No performance-specific limit applies"
      else "#{max_sales_for_type} of these tickets remaining"
      end
    self.visible = true
  end

  def clone_with_id
    result = self.clone
    result.id = self.id # necessary since views expect valid-vouchers to have an id...
    result.visible = true
    result.customer = customer
    result.explanation = ''
    result
  end
  
  public

  def inspect ; self.to_s ; end
  def to_s
    sprintf "%s max %3d %s- %s %s", vouchertype, max_sales_for_type,
    start_sales.strftime('%c'), end_sales.strftime('%c'),
    promo_code
  end

  def seats_of_type_remaining
    return INFINITE unless showdate
    total_empty = showdate.saleable_seats_left
    remain = if sales_unlimited? # no limit on ticket type: only limit is show capacity
             then total_empty
             else  [[max_sales_for_type - showdate.sales_by_type(vouchertype_id), 0].max, total_empty].min
             end
    remain = [remain, 0].max    # make sure it's positive
  end

  def self.bundles_available_to(customer = Customer.generic_customer, admin = nil, promo_code=nil)
    # in Rails 3 this can be cleaned up by building up query with ARel
    bundles = ValidVoucher.find(:all, :include => :vouchertype, :conditions => 'vouchertypes.category = "bundle"',
      :order => "season DESC,display_order,price DESC")
    if !admin
      bundles.map! do |b|
        b.customer = customer
        b.adjust_for_customer(promo_code)
      end
    end
    bundles
  end

  # returns a copy of this ValidVoucher, but with max_sales_for_type adjusted to
  # the number of tickets of THIS vouchertype for THIS show available to
  # THIS customer. 
  def adjust_for_customer(customer_supplied_promo_code = '')
    result = self.clone_with_id
    result.supplied_promo_code = customer_supplied_promo_code.to_s
    result.adjust_for_visibility ||
      result.adjust_for_showdate ||
      result.adjust_for_sales_dates ||
      result.adjust_for_capacity # this one must be called last
    result.freeze
  end

  # returns a copy of this ValidVoucher for a voucher *that the customer already has*
  #  but adjusted to see if it can be redeemed
  def adjust_for_customer_reservation
    result = self.clone_with_id
    result.adjust_for_showdate ||
      result.adjust_for_advance_reservations ||
      result.adjust_for_capacity # this one must be called last
    result.freeze
  end

  named_scope :on_sale_now, :conditions => ['? BETWEEN start_sales AND end_sales', Time.now]


  def self.for_advance_sales(supplied_promo_code = '')
    general_conds = "? BETWEEN start_sales AND end_sales"
    general_opts = [Time.now]
    promo_code_conds = "promo_code IS NULL OR promo_code = ''"
    promo_code_opts = []
    unless promo_codes.empty?
      promo_code_conds += " OR promo_code LIKE ? " * promo_codes.length
    end
    ValidVoucher.find(:all,
      :conditions => ["#{general_conds} AND (#{promo_code_conds})", general_opts + promo_codes])
  end

  def date_with_explanation
    display_name = showdate.menu_selection_name
    max_sales_for_type > 0 ? display_name : "#{display_name} (#{explanation})"
  end

  def name_with_explanation
    display_name = showdate.printable_name
    max_sales_for_type > 0 ? display_name : "#{display_name} (#{explanation})"
  end

  def vouchertype_name_with_seats_of_type_remaining
    "#{name} (#{seats_of_type_remaining} left)"
  end

  def show_name_with_seats_of_type_remaining
    "#{showdate.printable_name} (#{seats_of_type_remaining} left)"
  end

  def instantiate(quantity)
    raise InvalidProcessedByError unless customer.kind_of?(Customer)
    vouchers = vouchertype.instantiate(quantity, :promo_code => self.promo_code)
    # if vouchertype was a bundle, check whether any of its components
    #   are monogamous, if so reserve them
    if vouchertype.bundle?
      try_reserve_for_unique(vouchers)
      # if the original vouchertype was NOT a bundle, we have a bunch of regular vouchers.
      #   if a showdate was given OR the vouchers are monogamous, reserve them.
    elsif (theshowdate = self.showdate || vouchertype.unique_showdate)
      try_reserve_for(vouchers, theshowdate)
    end
    vouchers
  end

  def try_reserve_for_unique(vouchers)
    vouchers.each do |v|
      if (showdate = v.unique_showdate)
        v.reserve_for(showdate, customer) ||
          raise(InvalidRedemptionError, v.errors.full_messages.join(', '))
      end
    end
  end

  def try_reserve_for(vouchers, showdate)
    vouchers.each do |v|
      v.reserve_for(showdate, customer) ||
        raise(InvalidRedemptionError, v.errors.full_messages.join(', '))
    end
  end

end

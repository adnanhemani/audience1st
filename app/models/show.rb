class Show < ActiveRecord::Base

  require 'ruport'
  acts_as_reportable

  REGULAR_SHOW = 'Regular Show'
  TYPES = [REGULAR_SHOW, 'Special Event', 'Class', 'Subscription']

  has_many :showdates, -> { order('thedate') }, :dependent => :destroy
  has_one :latest_showdate, -> { order('thedate DESC') }, :class_name => 'Showdate'
  # NOTE: We can't do the trick below because the database's timezone
  #  may not be the same as the appserver's timezone.
  #has_many :future_showdates, :class_name => 'Showdate', :conditions => 'end_advance_sales >= #{Time.db_now}'
  has_many :vouchers, :through => :showdates
  has_many :imports

  validates_presence_of :opening_date, :closing_date, :listing_date
  validates_inclusion_of :event_type, :in => Show::TYPES
  validates_length_of :name, :within => 3..40, :message =>
    "Show name must be between 3 and 40 characters"
  validates_numericality_of :house_capacity, :greater_than => 0

  attr_accessible :name, :opening_date, :closing_date, :house_capacity, :patron_notes, :landing_page_url
  attr_accessible :listing_date, :description, :event_type, :sold_out_dropdown_message, :sold_out_customer_info

  # current_or_next returns the Show object corresponding to either the
  # currently running show, or the one with the next soonest opening date.

  def self.current_or_next
    Showdate.current_or_next.try(:show)
  end

  scope :current_and_future, -> {
    joins(:showdates).
    where('showdates.thedate >= ?', 1.day.ago).
    select('DISTINCT shows.*').
    order('opening_date ASC')
  }

  def has_showdates? ; !showdates.empty? ; end
  
  def upcoming_showdates
    showdates.where('thedate > ?', Time.now).includes(:valid_vouchers)
  end

  def next_showdate
    showdates.where('thedate > ?', Time.now).includes(:valid_vouchers).first
  end

  def self.all_for_season(season=Time.this_season)
    startdate = Time.at_beginning_of_season(season)
    enddate = startdate + 1.year - 1.day
    Show.where('opening_date BETWEEN ? AND ?', startdate, enddate).
      order('opening_date').
      select('DISTINCT shows.*').
      includes(:showdates)
  end

  scope :all_for_seasons, ->(from,to) {
    where('opening_date BETWEEN ? AND ?',
        Time.at_beginning_of_season(from), Time.at_end_of_season(to))
  }

  def self.seasons_range
    [Show.order('opening_date').first.season,
      Show.order('opening_date DESC').first.season]
  end
  
  def special? ; event_type != 'Regular Show' ; end
  def special ; special? ; end

  def self.type(arg)
    TYPES.include?(arg) ? arg : REGULAR_SHOW
  end
  
  scope :of_type, ->(type) {
    where('event_type = ?', self.type(type))
  }
  
  def season
    # latest season that contains opening date
    self.opening_date.at_beginning_of_season.year
  end

  def future_showdates
    self.showdates.where('end_advance_sales >= ?', Time.now).order('thedate')
  end

    

  def special? ; event_type != 'Regular Show' ; end
  def special ; special? ; end

  def revenue ; self.vouchers.inject(0) {|sum,v| sum + v.amount} ; end

  def revenue_per_seat
    v = self.vouchers.count("category NOT IN ('comp','subscriber')")
    v.zero? ? 0.0 : revenue / v
  end

  def revenue_by_type(vouchertype_id)
    self.vouchers.find_by_id(vouchertype_id).inject(0) {|sum,v| sum + v.amount}
  end

  def capacity
    self.showdates.inject(0) { |cap,sd| cap + sd.capacity }
  end

  def percent_sold
    showdates.size.zero? ? 0.0 :
      showdates.inject(0) { |t,s| t+s.percent_sold } / showdates.size
  end

  def percent_of_house
    showdates.size.zero? ? 0.0 :
      showdates.inject(0) { |t,s| t+s.percent_of_house } / showdates.size
  end

  def compute_total_sales
    showdates.inject(0) { |t,s| t+s.compute_total_sales }
  end

  def max_allowed_sales
    showdates.inject(0) { |t,s| t+s.max_allowed_sales }
  end

  def total_offered_for_sale ; showdates.length * house_capacity ; end

  def menu_selection_name ; name ; end

  def name_with_description
    description.blank? ? name : "#{name} (#{description})"
  end

  def run_dates
    "#{opening_date.to_formatted_s(:month_day_only)} - #{closing_date.to_formatted_s(:month_day_only)}"
  end

  def name_with_run_dates ; "#{name} - #{run_dates}" ; end

  def name_with_run_dates_short
    s = self.opening_date
    e = self.closing_date
    if s.year == e.year
      dt = (s.month == e.month)? s.strftime('%b %Y') :
        "#{s.strftime('%b')} - #{e.strftime('%b %Y')}"
    else                        # different years
      dt = "#{s.strftime('%b %Y')} - #{e.strftime('%b %Y')}"
    end
    "#{self.name} (#{dt})"
  end

  def self.find_unique(name)
    Show.where('name LIKE ?', name.strip).first
  end

  # return placeholder entity that will pass basic validations if saved
  
  def self.create_placeholder!(name)
    name = name.to_s
    name << "___" if name.length < 3
    Show.create!(:name => name,
      :opening_date => Date.today,
      :closing_date => Date.today + 1.day,
      :house_capacity => 1
      )
  end
  
  def adjust_metadata_from_showdates
    return if showdates.empty?
    dates = showdates.map(&:thedate)
    first,last = dates.min.to_date, dates.max.to_date
    self.opening_date = first if opening_date > first
    self.closing_date = last if closing_date < last
    return self.changed?
  end
      
end

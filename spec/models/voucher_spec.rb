require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe Voucher do

  before :all do
    #  some Vouchertype objects for these tests
    @vt_regular = Vouchertype.create!(:fulfillment_needed => false,
                                      :name => 'regular voucher',
                                      :category => 'revenue',
                                      :account_code => '9999',
                                      :price => 10.00,
                                      :valid_date => Time.now - 1.month,
                                      :expiration_date => Time.now+1.month)
    @vt_bundle = Vouchertype.create!(:fulfillment_needed => false,
                                     :name => 'bundle voucher',
                                     :category => 'bundle',
                                     :price => 25.00,
                                     :account_code => '8888',
                                     :valid_date => Time.now - 1.month,
                                     :expiration_date => Time.now+1.month)
  end

  describe "regular voucher when first created", :shared => true do
    it "should not be reserved" do  @v.should_not be_reserved  end
    it "should not belong to anyone" do @v.customer.should be_nil end
    it "should not be valid" do @v.should_not be_valid end
    it "should not show up as processed by anyone" do
      @v.processed_by.should be_nil
    end
    it "should have no associated purchasemethod" do
      @v.purchasemethod.should be_nil
    end
  end

  describe "regular voucher when templated from vouchertype" do
    before(:all) do
      @v = Voucher.new_from_vouchertype(@vt_regular)
    end
    it_should_behave_like "regular voucher when first created"
    it "should have a vouchertype" do  @v.vouchertype.should == @vt_regular end
    it "price should match its vouchertype" do
      @v.price.should == 10.00
    end
    it "should not be valid" do @v.should_not be_valid end
  end

  describe "expired voucher" do
    before(:all) do
      @v = Voucher.new_from_vouchertype(@vt_regular, :purchasemethod => Purchasemethod.create!)
      @v.expiration_date = 1.month.ago
      @v.should be_valid
    end
    it "should not be valid today" do
      @v.should_not be_valid_today
    end
    it "should not be reservable" do
      @v.should_not be_reservable
    end
  end
  describe "reservation for a valid showdate" do
    it "should fail when voucher is not reservable" 
    context "when voucher is reservable by customer" do
      context "by customer"
      context "by box office only"
    end
  end
  describe "transferring a voucher" do
    before(:each) do
      @from = Customer.create!(:first_name => "John", :last_name => "Donor")
      @v = Voucher.new_from_vouchertype(@vt_regular, :purchasemethod => Purchasemethod.create!)
      @v.should be_valid
      @from.vouchers << @v
      @from.save!
    end
    context "when recipient exists" do
      before(:all) do
        @to = Customer.create!(:first_name => "Jane", :last_name => "Recipient")
      end
      it "should add the voucher to the recipient's account" do
        @v.transfer_to_customer(@to)
        @to.vouchers.should include(@v)
      end
      it "should remove the voucher from the transferor's account" do
        @v.transfer_to_customer(@to)
        @from.vouchers.should_not include(@v)
      end
    end
    context "when recipient doesn't exist" do
      before(:all) do
        @to = Customer.new(:first_name => "Jane", :last_name => "Nonexistent")
      end
      it "should not cause an error" do
        lambda { @v.transfer_to_customer(@to) }.should_not raise_error
      end
      it "should not remove the voucher from the transferor's account" do
        @v.transfer_to_customer(@to)
        @from.vouchers.should include(@v)
      end
    end
  end
end



class FacilityJournalsController < ApplicationController
  include DateHelper

  admin_tab     :all
  before_filter :authenticate_user!
  before_filter :check_acting_as
  before_filter :check_billing_access
  before_filter :init_journals, :except => :create_with_search

  include TransactionSearch
  
  layout 'two_column'
  
  def initialize
    @subnav     = 'billing_nav'
    @active_tab = 'admin_billing'
    super
  end
  
  # GET /facilities/journals
  def index
    @pending_journal = get_pending_journal

    @journals = @journals.
      order('journals.created_at DESC').
      paginate(:page => params[:page])
  end

  # GET /facilities/journals/new
  def new_with_search
    set_default_variables
    @layout = "two_column_head"
  end
   
  #PUT /facilities/journals/:id
  def update
    @pending_journal = @journal
    @pending_journal.updated_by = session_user.id

    Journal.transaction do
      begin
        # blank input
        @pending_journal.errors.add(:base, I18n.t('controllers.facility_journals.update.error.status')) if params[:journal_status].blank?

        # failed
        if params[:journal_status] == 'failed'
          @pending_journal.is_successful = false
          @pending_journal.update_attributes!(params[:journal])
          OrderDetail.update_all('journal_id = NULL', "journal_id = #{@pending_journal.id}") # null out journal_id for all order_details

        # succeeded, with errors
        elsif params[:journal_status] == 'succeeded_errors'
          @pending_journal.is_successful = true
          @pending_journal.update_attributes!(params[:journal])

        # if succeeded, no errors
        elsif params[:journal_status]
          @pending_journal.is_successful = true
          @pending_journal.update_attributes!(params[:journal])
          reconciled_status = OrderStatus.reconciled.first
          @pending_journal.order_details.each do |od|
            raise Exception unless od.change_status!(reconciled_status)
          end
        else
          raise Exception
        end

        flash[:notice] = I18n.t 'controllers.facility_journals.update.notice'
        redirect_to facility_journals_url(current_facility) and return
      rescue Exception => e
        @pending_journal.errors.add(:base, I18n.t('controllers.facility_journals.update.error.rescue'))
        raise ActiveRecord::Rollback
      end
    end
    @order_details = OrderDetail.for_facilities(manageable_facilities).need_journal
    set_soonest_journal_date
    @soonest_journal_date = params[:journal_date] || @soonest_journal_date 
    render :action => :index
  end

  # POST /facilities/journals
  def create_with_search
    @journal = Journal.new
    @journal.created_by = session_user.id
    @journal.journal_date = parse_usa_date(params[:journal_date])
    
    if params[:order_detail_ids].present?
      @update_order_details = @order_details.where(:id => params[:order_detail_ids])
    else
      @update_order_details = []
    end

    if @update_order_details.empty?
      @journal.errors.add(:base, I18n.t('controllers.facility_journals.create.errors.no_orders'))
    else
      if Journal.order_details_span_fiscal_years?(@update_order_details)
        @journal.errors.add(:base, I18n.t('controllers.facility_journals.create.errors.fiscal_span'))
      else
        # detect if this should be a multi-facility journal, set facility_id appropriately
        if @update_order_details.includes(:order).count('orders.facility_id', :distinct => true) > 1
          @journal.facility_id = nil
        else
          @journal.facility_id = @update_order_details.first.order.facility_id
        end
        Journal.transaction do
          begin
            @journal.save!
            @journal.create_journal_rows!(@update_order_details)
            

            OrderDetail.update_all(['journal_id = ?', @journal.id], ['id IN (?)', @update_order_details.collect{|od| od.id}])
            # create the spreadsheet
            @journal.create_spreadsheet
            flash[:notice] = I18n.t('controllers.facility_journals.create.notice')
            redirect_to facility_journals_url(current_facility) and return
          rescue Exception => e
            @journal.errors.add(:base, I18n.t('controllers.facility_journals.create.errors.rescue', :message => e.message))
            Rails.logger.error(e.backtrace.join("\n"))
            raise ActiveRecord::Rollback
          end
        end
      end
    end
    if @journal.errors.any?
      flash[:error] = @journal.errors.values.join("<br/>").html_safe
      remove_ugly_params
      redirect_to params.merge({:action => :new}) and return
    end
    @layout = "two_column_head"
  end

  # GET /facilities/journals/:id
  def show
    if request.format.xml?
      @journal_rows = @journal.journal_rows
      headers["Content-type"] = "text/xml"
      headers['Content-Disposition'] = "attachment; filename=\"journal_#{@journal.id}_#{@journal.created_at.strftime("%Y%m%d")}.xml\"" 

      render 'show.xml.haml', :layout => false and return
    end

    @order_details = @journal.order_details
  end

  def reconcile
    if params[:order_detail_ids].blank?
      flash[:error] = 'No orders were selected to reconcile'
      redirect_to facility_journal_url(current_facility, @journal) and return
    end
    rec_status = OrderStatus.reconciled.first
    order_details = OrderDetail.for_facilities(manageable_facilities).where(:id => params[:order_detail_ids]).readonly(false)
    order_details.each do |od|
      if od.journal_id != @journal.id
        flash[:error] = 'An error was encountered while reconcile orders'
        redirect_to facility_journal_url(current_facility, @journal) and return
      end
      od.change_status!(rec_status)
    end
    flash[:notice] = 'The select orders have been reconciled successfully'
    redirect_to facility_journal_url(current_facility, @journal) and return
  end


  private
  
  def get_pending_journal
    return @journals.find_by_is_successful(nil)
  end
  
  def set_soonest_journal_date
    @soonest_journal_date=@order_details.collect{ |od| od.fulfilled_at }.max
    @soonest_journal_date=Time.zone.now unless @soonest_journal_date
  end
  
  def set_default_variables
    @pending_journal = get_pending_journal
    @order_details   = @order_details.need_journal
    #@accounts = @accounts.where("type in (?)", ['NufsAccount'])
    #@journal         = current_facility.journals.new()
    set_soonest_journal_date
    if @pending_journal.nil?
      @order_detail_action = :create
      @action_date_field = {:journal_date => @soonest_journal_date}
    end
  end

  def init_journals
    @journals = Journal.for_facilities(manageable_facilities, manageable_facilities.size > 1)

    if params[:id]
      @journal = @journals.find(params[:id])
    end
  end
end

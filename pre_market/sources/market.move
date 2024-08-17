module pre_market::market {
    use whusdce::coin::COIN as USDC;

    use sui::coin::{Self, Coin};
    use sui::sui::{SUI};
    use sui::balance::{Balance};
    use sui::package::{Self, Publisher};
    use sui::object::{Self};
    use sui::balance::{Self};
    use sui::table::{Self, Table};
    use sui::url::{Self, Url};
    use sui::pay::{keep};
    use sui::event::{emit};
    use sui::clock::Clock;
    
    use std::string::{String};
    use std::ascii::{Self};
    use std::type_name::{Self};
    use std::vector::{Self};

    // ========================= CONSTANTS =========================
    // ========================= Statuses
    const ACTIVE: u8 = 0;
    const CANCELLED: u8 = 1;
    const SETTLEMENT: u8 = 2;
    const CLOSED: u8 = 3;
    
    const SETTLEMENT_TIME_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours
    const FEE_PERCENTAGE: u64 = 2;

    // ========================= ERRORS =========================

    const ENotAuthorized :u64 = 0;
    const EMarketInactive :u64 = 1;
    const EMarketNotClosed :u64 = 2;
    const EMarketNotSettlement :u64 = 3;
    const EInvalidCoinType :u64 = 4;

    // ========================= STRUCTS =========================

    public struct MARKET has drop {}
    
    public struct Market has key {
        /// Market ID
        id: UID,
        /// Name of the market
        name: String,
        /// URL of the market
        url: Url,
        /// Status of the market
        /// 0 - Active, 1 - Cancelled, 2 - Settlement, 3 - Closed
        status: u8,
        /// Offers in the market
        /// Key: address of the offer participant, Value: vector of offer IDs participated by the address (created or filled)
        offers: Table<address, vector<ID>>,
        /// Fee percentage of the market
        fee_percentage: u64,
        /// Balance of the market
        balance: Balance<USDC>,

        /// Market statistics
        
        /// Sell interest of the market
        sell_interest: u64,
        /// Buy interest of the market
        buy_interest: u64,
        /// Total interest of the market (sell_interest + buy_interest)
        total_interest: u64,
        /// Total volume of the market is the sum of all the volumes of the filled offers
        total_volume: u64,

        /// Settlement details

        /// Coin type of the token to be settled
        coin_type: Option<String>,
        /// Settlement end timestamp in milliseconds
        /// The market will be closed after the settlement timestamp
        /// And no more offers can be created or filled
        settlement_end_timestamp_ms: Option<u64>,
    }

    // ========================= EVENTS =========================
    
    public struct MarketCreated has copy, drop {
        market: ID,
    }

    public struct MarketCancelled has copy, drop {
        market: ID,
    }

    public struct MarketSettlement has copy, drop {
        market: ID,
    }

    public struct MarketClosed has copy, drop {
        market: ID,
    }

    // ========================= INIT =========================

    fun init(otw: MARKET, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        transfer::public_transfer(publisher, ctx.sender());
    }

    // ========================= PUBLIC FUNCTIONS =========================

    // ========================= Write admin functions

    public fun new(cap: &Publisher, name: vector<u8>, ctx: &mut TxContext){
        assert_admin(cap);

        let market = Market {
            id: object::new(ctx),
            name: name.to_string(),
            url: url::new_unsafe_from_bytes(name),
            status: ACTIVE,
            offers: table::new(ctx),
            fee_percentage: FEE_PERCENTAGE,
            balance: balance::zero(),

            sell_interest: 0,
            buy_interest: 0,
            total_interest: 0,
            total_volume: 0,
            coin_type: option::none(),
            settlement_end_timestamp_ms: option::none(),
        };

        emit(MarketCreated { market: object::id(&market) });

        transfer::share_object(market);
    }

    public fun cancel(market: &mut Market, cap: &Publisher, _ctx: &mut TxContext){
        assert_admin(cap);
        assert_market_active(market);

        emit(MarketCancelled { market: object::id(market) });

        market.status = CANCELLED;
    }

    public fun settlement(market: &mut Market, cap: &Publisher, coin_type: vector<u8>, clock: &Clock, _ctx: &mut TxContext){
        assert_admin(cap);
        assert_market_active(market);

        emit(MarketSettlement { market: object::id(market) });

        market.status = SETTLEMENT;
        market.settlement_end_timestamp_ms = option::some(clock.timestamp_ms() + SETTLEMENT_TIME_MS);
        market.coin_type = option::some(coin_type.to_string());
    }

    public fun close(market: &mut Market, cap: &Publisher, clock: &Clock, ctx: &mut TxContext){
        assert_admin(cap);
        assert_market_closable(market, clock);

        emit(MarketClosed { market: object::id(market) });

        market.status = CLOSED;
    }

    public fun withdraw(market: &mut Market, cap: &Publisher, ctx: &mut TxContext){
        assert_admin(cap);

        keep(coin::from_balance(market.balance.withdraw_all(), ctx), ctx);
    }

    // ========================= Read functions

    public fun get_address_offers(market: &Market, address: address): vector<ID> {
        market.offers[address]
    }
    
    // ========================= PUBLIC(PACKAGE) FUNCTIONS =========================

    // ========================= Write functions

    public(package) fun assert_market_active(market: &Market){
        assert!(market.status == ACTIVE, EMarketInactive);
    }

    public(package) fun assert_market_settlement(market: &Market, clock: &Clock){
        assert!(
            market.status == SETTLEMENT && 
            market.settlement_end_timestamp_ms.is_some() &&
            clock.timestamp_ms() <= *market.settlement_end_timestamp_ms.borrow(), 
        EMarketNotSettlement);
    }

    /// Check if the coin type is valid for closing the offer
    /// Call when market is in settlement status
    public(package) fun assert_coin_type<T>(market: &Market){
        let coin_type = type_name::get_with_original_ids<T>().into_string().into_bytes();
        let market_coin_type = (*market.coin_type.borrow()).into_bytes();

        assert!(coin_type == market_coin_type, EInvalidCoinType);
    }

    /// Update the market offer table
    /// Call when creating an offer or filling an offer
    public(package) fun add_offer(market: &mut Market, address: address, offer_id: ID){
        let offers = &mut market.offers;
        if (!offers.contains(address)) {
            offers.add(address, vector::empty());
        };

        offers[address].push_back(offer_id);
    }

    /// Add fee to the market
    /// Call when creating an offer or filling an offer
    public(package) fun top_up(market: &mut Market, coin: Coin<USDC>){
        market.balance.join(coin.into_balance());
    }

    /// Add sell interest to the market
    /// Call when creating an sell offer or filling a buy offer
    public(package) fun add_sell_interest(market: &mut Market, interest: u64){
        market.sell_interest = market.sell_interest + interest;
        market.total_interest = market.total_interest + interest;
    }

    /// Add buy interest to the market
    /// Call when creating an buy offer or filling a sell offer
    public(package) fun add_buy_interest(market: &mut Market, interest: u64){
        market.buy_interest = market.buy_interest + interest;
        market.total_interest = market.total_interest + interest;
    }

    /// Add volume to the market
    /// Call only when filling an offer
    public(package) fun add_volume(market: &mut Market, volume: u64){
        market.total_volume = market.total_volume + volume;
    }

    // ========================= Read functions

    public(package) fun get_percent_fee(market: &Market): u64 {
        market.fee_percentage
    }

    // ========================= PRIVATE FUNCTIONS =========================

    /// Check if the market settlement is ended 
    /// And the market is ready to be closed
    fun assert_market_closable(market: &Market, clock: &Clock){
        assert!(
            market.status == SETTLEMENT && 
            market.settlement_end_timestamp_ms.is_some() &&
            clock.timestamp_ms() >= *market.settlement_end_timestamp_ms.borrow(), 
        EMarketNotClosed);
    }
    
    fun assert_admin(cap: &Publisher){
        assert!(cap.from_module<MARKET>(), ENotAuthorized);
    }

    // ========================= TESTS =========================

    #[test]
    fun test_types_comparison() {
        let v1 = type_name::get_with_original_ids<Market>().into_string().into_bytes();
        
        let bytes = b"0000000000000000000000000000000000000000000000000000000000000000::market::Market";
        let v2 = bytes.to_string().into_bytes();

        assert!(v1 == v2);
    }
}


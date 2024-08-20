module pre_market::market {
    use whusdce::coin::COIN as USDC;
    use pre_market::utils::{withdraw_balance};

    use sui::coin::{Self, Coin};
    use sui::balance::{Balance};
    use sui::package::{Self, Publisher};
    use sui::balance::{Self};
    use sui::table::{Self, Table};
    use sui::url::{Self, Url};
    use sui::event::{emit};
    use sui::clock::Clock;
    
    use std::string::{String};
    use std::type_name::{Self};

    // ========================= CONSTANTS =========================
    // ========================= Statuses
    /// Active/Trading Phase
    const ACTIVE: u8 = 0;
    /// Settlement/Delivery Phase
    const SETTLEMENT: u8 = 1;
    const CLOSED: u8 = 2;
    
    // const SETTLEMENT_TIME_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours
    const SETTLEMENT_TIME_MS: u64 = 1000 * 60 * 5; // 5 minutes
    const FEE_PERCENTAGE: u64 = 2;

    const PRE_MARKET_SUFFIX: vector<u8> = b"Pre Market ";

    // ========================= ERRORS =========================

    const ENotAuthorized :u64 = 0;
    const EMarketInactive :u64 = 1;
    const EMarketNotSettlement :u64 = 2;
    const EMarketNotClosed :u64 = 3;
    const EInvalidCoinType :u64 = 4;


    // ========================= STRUCTS =========================

    public struct MARKET has drop {}
    
    public struct Market has key {
        /// Market ID
        id: UID,
        /// Name of the market
        name: String,
        /// Symbol of the token
        symbol: String,
        /// URL of info about the token
        url: Url,
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
        /// !!! Type without 0x prefix
        coin_type: Option<String>,
        coin_decimals: Option<u8>,
        /// Settlement end timestamp in milliseconds
        /// The market will be closed after the settlement timestamp
        /// And no more offers can be created or filled
        settlement_end_timestamp_ms: Option<u64>,
        
        //// Status of the market
        //// 0 - Active, 1 - Settlement, 2 - Closed
        // status: () -> u8
    }

    // ========================= EVENTS =========================
    
    public struct MarketCreated has copy, drop {
        market: ID,
    }

    public struct MarketSettlement has copy, drop {
        market: ID,
    }

    public struct MarketUnsettlement has copy, drop {
        market: ID,
    }

    // ========================= INIT =========================

    fun init(otw: MARKET, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        transfer::public_transfer(publisher, ctx.sender());
    }

    // ========================= PUBLIC FUNCTIONS =========================

    // ========================= Write admin functions

    entry public fun new(cap: &Publisher, name: vector<u8>, symbol: vector<u8>, url: vector<u8>, ctx: &mut TxContext) {
        assert_admin(cap);

        let market = Market {
            id: object::new(ctx),
            name: generate_market_name(name),
            symbol: symbol.to_string(),
            url: url::new_unsafe_from_bytes(url),
            offers: table::new(ctx),
            fee_percentage: FEE_PERCENTAGE,
            balance: balance::zero(),

            sell_interest: 0,
            buy_interest: 0,
            total_interest: 0,
            total_volume: 0,

            coin_type: option::none(),
            coin_decimals: option::none(),
            settlement_end_timestamp_ms: option::none(),
        };

        emit(MarketCreated { market: object::id(&market) });

        transfer::share_object(market);
    }

    entry public fun settlement(
        market: &mut Market, 
        cap: &Publisher, 
        // 76cb819b01abed502bee8a702b4c2d547532c12f25001c9dea795a5e631c26f1::fud::FUD
        coin_type: vector<u8>, 
        // 5
        coin_decimals: u8,
        clock: &Clock,
    ) {
        assert_admin(cap);

        market.settlement_end_timestamp_ms = option::some(clock.timestamp_ms() + SETTLEMENT_TIME_MS);
        market.coin_type = option::some(coin_type.to_string());
        market.coin_decimals = option::some(coin_decimals);

        emit(MarketSettlement { market: object::id(market) });
    }

    /// Optional function to unsettle the market
    /// Call this function if there are settlement issues
    entry public fun unsettlement(market: &mut Market, cap: &Publisher) {
        assert_admin(cap);

        market.settlement_end_timestamp_ms = option::none();
        market.coin_type = option::none();
        market.coin_decimals = option::none();

        emit(MarketUnsettlement { market: object::id(market) });
    }

    entry public fun withdraw(market: &mut Market, cap: &Publisher, ctx: &mut TxContext) {
        assert_admin(cap);

        withdraw_balance(&mut market.balance, ctx);
    }

    // ========================= Read functions

    public fun status(market: &Market, clock: &Clock): u8 {
        if (market.settlement_end_timestamp_ms.is_none()) {
            ACTIVE
        } else if (clock.timestamp_ms() <= *market.settlement_end_timestamp_ms.borrow()) {
            SETTLEMENT
        } else {
            CLOSED
        }
    }

    public fun get_address_offers(market: &Market, address: address): vector<ID> {
        market.offers[address]
    }
    
    // ========================= PUBLIC(PACKAGE) FUNCTIONS =========================

    // ========================= Write functions

    public(package) fun assert_active(market: &Market, clock: &Clock) {
        assert!(market.status(clock) == ACTIVE, EMarketInactive);
    }

    public(package) fun assert_settlement(market: &Market, clock: &Clock) {
        assert!(market.status(clock) == SETTLEMENT, EMarketNotSettlement);
    }

    /// Check if the market settlement is ended 
    /// And the market is ready to be closed
    public(package) fun assert_closed(market: &Market, clock: &Clock) {
        assert!(market.status(clock) == CLOSED, EMarketNotClosed);
    }

    /// Check if the coin type is valid for closing the offer
    /// Call when market is in settlement status
    public(package) fun assert_coin_type<T>(market: &Market) {
        let coin_type = type_name::get_with_original_ids<T>().into_string().into_bytes();
        let market_coin_type = (*market.coin_type.borrow()).into_bytes();

        assert!(coin_type == market_coin_type, EInvalidCoinType);
    }

    /// Update the market offer table
    /// Call when creating an offer or filling an offer
    public(package) fun add_offer(
        market: &mut Market, 
        offer_id: ID, 
        is_buy: bool, 
        is_fill: bool, 
        value: u64,
        fee: Coin<USDC>,
        ctx: &TxContext
    ) {
        market.update_offers(ctx.sender(), offer_id);

        coin::put(&mut market.balance, fee);

        market.update_stats(is_buy, is_fill, value);
    }

    // ========================= Read functions

    public(package) fun fee_percentage(market: &Market): u64 {
        market.fee_percentage
    }

    public(package) fun coin_decimals(market: &Market): u8 {
        *market.coin_decimals.borrow()
    }

    // ========================= PRIVATE FUNCTIONS =========================
    
    fun assert_admin(cap: &Publisher) {
        assert!(cap.from_module<MARKET>(), ENotAuthorized);
    }

    fun update_offers(market: &mut Market, address: address, offer_id: ID) {
        let offers = &mut market.offers;
        if (!offers.contains(address)) {
            offers.add(address, vector::empty());
        };
        offers[address].push_back(offer_id);
    }

    fun update_stats(market: &mut Market, is_buy: bool, is_fill: bool, value: u64) {
        if (is_fill) {
            market.total_volume = market.total_volume + value;
        };
        if (is_buy) {
            market.buy_interest = market.buy_interest + value;
        } else {
            market.sell_interest = market.sell_interest + value;
        };
        market.total_interest = market.total_interest + value;
    }

    fun generate_market_name(name: vector<u8>): String {
        let mut market_name = b"".to_string();
        market_name.append(PRE_MARKET_SUFFIX.to_string());
        market_name.append(name.to_string());
        market_name
    }

    // ========================= TEST ONLY FUNCTIONS =========================

    #[test_only]
    public fun create_test_market(ctx: &mut TxContext) {
        let market = Market {
            id: object::new(ctx),
            name: b"TestTokenMarket".to_string(),
            symbol: b"TTM".to_string(),
            url: url::new_unsafe_from_bytes(b"TestUrl"),
            offers: table::new(ctx),
            fee_percentage: FEE_PERCENTAGE,
            balance: balance::zero(),

            sell_interest: 0,
            buy_interest: 0,
            total_interest: 0,
            total_volume: 0,
            coin_type: option::none(),
            coin_decimals: option::none(),
            settlement_end_timestamp_ms: option::none(),
        };
        
        transfer::share_object(market);
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


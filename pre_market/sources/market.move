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
    // ========================= STATUSES
    const ACTIVE: u8 = 0;
    const CANCELLED: u8 = 1;
    const SETTLEMENT: u8 = 2;
    const CLOSED: u8 = 3;
    
    const SETTLEMENT_TIME_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours

    // ========================= ERRORS =========================

    const ENotAuthorized :u64 = 0;
    const EMarketInactive :u64 = 1;
    const EMarketNotSettled :u64 = 2;
    const EInvalidCoinType :u64 = 3;

    // ========================= STRUCTS =========================

    public struct MARKET has drop {}
    
    public struct Market has key {
        id: UID,
        name: String,
        url: Url,
        status: u8,
        offers: Table<address, vector<ID>>,

        sell_interest: u64,
        buy_interest: u64,
        total_interest: u64,
        total_volume: u64,

        coin_type: Option<String>,
        settlement_timestamp_ms: Option<u64>,
    }

    // ========================= EVENTS =========================
    
    public struct MarketCreated has copy, drop {
        market: ID,
    }

    public struct MarketCancelled has copy, drop {
        market: ID,
    }

    public struct MarketSettled has copy, drop {
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

    public fun new(cap: &Publisher, name: vector<u8>, ctx: &mut TxContext){
        assert_admin(cap);

        let market = Market {
            id: object::new(ctx),
            name: name.to_string(),
            url: url::new_unsafe_from_bytes(name),
            status: ACTIVE,
            offers: table::new(ctx),

            sell_interest: 0,
            buy_interest: 0,
            total_interest: 0,
            total_volume: 0,

            coin_type: option::none(),
            settlement_timestamp_ms: option::none(),
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

    public fun settle(market: &mut Market, cap: &Publisher, coin_type: vector<u8>, clock: &Clock, _ctx: &mut TxContext){
        assert_admin(cap);
        assert_market_active(market);

        emit(MarketSettled { market: object::id(market) });

        market.status = SETTLEMENT;
        market.settlement_timestamp_ms = option::some(clock.timestamp_ms() + SETTLEMENT_TIME_MS);
        market.coin_type = option::some(coin_type.to_string());
    }

    public fun close(market: &mut Market, cap: &Publisher, clock: &Clock, ctx: &mut TxContext){
        assert_admin(cap);
        assert_market_settled(market, clock);

        emit(MarketClosed { market: object::id(market) });

        market.status = CLOSED;
    }


    // ========================= PUBLIC(PACKAGE) FUNCTIONS =========================

    public(package) fun assert_market_active(market: &Market){
        assert!(market.status == ACTIVE, EMarketInactive);
    }

    public(package) fun assert_market_settled(market: &Market, clock: &Clock){
        assert!(
            market.status == SETTLEMENT && 
            clock.timestamp_ms() >= *market.settlement_timestamp_ms.borrow(), 
        EMarketNotSettled);
    }

    public(package) fun assert_coin_type<T>(market: &Market){
        let coin_type = type_name::get_with_original_ids<T>().into_string().into_bytes();
        let market_coin_type = (*market.coin_type.borrow()).into_bytes();

        assert!(coin_type == market_coin_type, EInvalidCoinType);
    }

    // ========================= PRIVATE FUNCTIONS =========================
    
    
    fun assert_admin(cap: &Publisher){
        assert!(cap.from_module<MARKET>(), ENotAuthorized);
    }


    #[test]
    fun test_bytes_comparison() {
        let v1 = type_name::get_with_original_ids<Market>().into_string().into_bytes();
        
        let bytes = b"0000000000000000000000000000000000000000000000000000000000000000::market::Market";
        let v2 = bytes.to_string().into_bytes();

        assert!(v1 == v2);
    }
}


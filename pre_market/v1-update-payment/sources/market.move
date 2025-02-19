module pre_market::market;

use pre_market::utils::withdraw_balance;
use std::string::{Self, String};
use std::type_name;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, CoinMetadata};
use sui::event::emit;
use sui::package::{Self, Publisher};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::url::{Self, Url};

// ========================= CONSTANTS =========================

const SETTLEMENT_TIME_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours
const FEE_PERCENTAGE: u64 = 2;

const PRE_MARKET_SUFFIX: vector<u8> = b"Pre Market ";

// ========================= Statuses
/// Active/Trading Phase
const ACTIVE: u8 = 0;
/// Settlement/Delivery Phase
const SETTLEMENT: u8 = 1;
const CLOSED: u8 = 2;

// ========================= ERRORS =========================

const ENotAuthorized: u64 = 0;
const EMarketInactive: u64 = 1;
const EMarketNotSettlement: u64 = 2;
const EMarketNotClosed: u64 = 3;
const EInvalidCoinType: u64 = 4;

// ========================= STRUCTS =========================

public struct MARKET has drop {}

public struct Market<phantom C> has key {
    /// Market ID
    id: UID,
    /// Name of the market
    name: String,
    /// URL of info about the token
    url: Url,
    /// Fee percentage of the market
    fee_percentage: u64,
    /// Balance of the market
    balance: Balance<C>,
    /// Created at timestamp in milliseconds
    created_at_timestamp_ms: u64,
    /// Symbol of the token
    /// Initiate with predicted symbol
    /// And then update with the actual token symbol in the settlement
    coin_symbol: Option<String>,
    /// Coin type of the token to be settled
    /// !!! Type without 0x prefix
    coin_type: Option<String>,
    coin_decimals: Option<u8>,
    /// Settlement end timestamp in milliseconds
    /// The market will be closed after the settlement timestamp
    /// And no more offers can be created or filled
    settlement_end_timestamp_ms: Option<u64>,
    /// Offers in the market
    /// Key: address of the offer participant, Value: vector of offer IDs participated by the address (created or filled)
    address_offers: Table<address, vector<ID>>,
    /// Buy offers
    buy_offers: Table<ID, ID>,
    /// Sell offers
    sell_offers: Table<ID, ID>,
    /// Filled offers
    filled_offers: Table<ID, ID>,
    /// Closed offers
    closed_offers: Table<ID, ID>,
    /// Average bids: buy_value / buy_amount
    /// Total value of all buy/fill-sell offers
    total_buy_value: u64,
    /// Total amount of all buy/fill-sell offers
    total_buy_amount: u64,
    /// Average asks: sell_value / sell_amount
    /// Total value of all sell/fill-buy offers
    total_sell_value: u64,
    /// Total amount of all sell/fill-buy offers
    total_sell_amount: u64,
    /// Total volume of the filled (traded) offers
    total_volume: u64,
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

public entry fun new<C>(
    cap: &Publisher,
    name: vector<u8>,
    url: vector<u8>,
    symbol: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_admin(cap);

    let market = Market<C> {
        id: object::new(ctx),
        name: generate_market_name(name),
        url: url::new_unsafe_from_bytes(url),
        fee_percentage: FEE_PERCENTAGE,
        balance: balance::zero(),
        created_at_timestamp_ms: clock.timestamp_ms(),
        coin_symbol: option::some(symbol.to_string()),
        coin_type: option::none(),
        coin_decimals: option::none(),
        settlement_end_timestamp_ms: option::none(),
        address_offers: table::new(ctx),
        buy_offers: table::new(ctx),
        sell_offers: table::new(ctx),
        filled_offers: table::new(ctx),
        closed_offers: table::new(ctx),
        total_buy_value: 0,
        total_buy_amount: 0,
        total_sell_value: 0,
        total_sell_amount: 0,
        total_volume: 0,
    };

    emit(MarketCreated { market: object::id(&market) });

    transfer::share_object(market);
}

public entry fun settlement<T, C>(
    market: &mut Market<C>,
    cap: &Publisher,
    coin_metadata: &CoinMetadata<T>,
    clock: &Clock,
) {
    assert_admin(cap);

    market.coin_symbol = option::some(string::from_ascii(coin_metadata.get_symbol()));
    market.coin_type =
        option::some(string::from_ascii(type_name::get_with_original_ids<T>().into_string()));
    market.coin_decimals = option::some(coin_metadata.get_decimals());
    market.settlement_end_timestamp_ms = option::some(clock.timestamp_ms() + SETTLEMENT_TIME_MS);

    emit(MarketSettlement { market: object::id(market) });
}

/// Optional function to unsettle the market
/// Call this function if there are settlement issues
public entry fun unsettlement<C>(market: &mut Market<C>, cap: &Publisher) {
    assert_admin(cap);

    market.coin_symbol = option::none();
    market.coin_type = option::none();
    market.coin_decimals = option::none();
    market.settlement_end_timestamp_ms = option::none();

    emit(MarketUnsettlement { market: object::id(market) });
}

/// Optional function to close the market
/// Call for tests or if the market is not needed anymore
/// In usual cases, the market will be closed after the `settlement_end_timestamp_ms` is reached
public entry fun close<C>(market: &mut Market<C>, cap: &Publisher, clock: &Clock) {
    assert_admin(cap);

    market.settlement_end_timestamp_ms = option::some(clock.timestamp_ms());

    emit(MarketClosed { market: object::id(market) });
}

public entry fun withdraw<C>(market: &mut Market<C>, cap: &Publisher, ctx: &mut TxContext) {
    assert_admin(cap);

    withdraw_balance(&mut market.balance, ctx);
}

// ========================= Read functions

public fun status<C>(market: &Market<C>, clock: &Clock): u8 {
    if (market.settlement_end_timestamp_ms.is_none()) {
        ACTIVE
    } else if (clock.timestamp_ms() <= *market.settlement_end_timestamp_ms.borrow()) {
        SETTLEMENT
    } else {
        CLOSED
    }
}

public fun get_address_offers<C>(market: &Market<C>, address: address): vector<ID> {
    market.address_offers[address]
}

// ========================= PUBLIC(PACKAGE) FUNCTIONS =========================

// ========================= Write functions

public(package) fun assert_active<C>(market: &Market<C>, clock: &Clock) {
    assert!(market.status(clock) == ACTIVE, EMarketInactive);
}

public(package) fun assert_settlement<C>(market: &Market<C>, clock: &Clock) {
    assert!(market.status(clock) == SETTLEMENT, EMarketNotSettlement);
}

/// Check if the market settlement is ended
/// And the market is ready to be closed
public(package) fun assert_closed<C>(market: &Market<C>, clock: &Clock) {
    assert!(market.status(clock) == CLOSED, EMarketNotClosed);
}

/// Check if the coin type is valid for closing the offer
/// Call when market is in settlement status
public(package) fun assert_coin_type<T, C>(market: &Market<C>) {
    let coin_type = type_name::get_with_original_ids<T>().into_string().into_bytes();
    let market_coin_type = (*market.coin_type.borrow()).into_bytes();

    assert!(coin_type == market_coin_type, EInvalidCoinType);
}

/// Update the market offer table
/// Call when creating an offer or filling an offer
public(package) fun add_offer<C>(
    market: &mut Market<C>,
    offer_id: ID,
    is_buy: bool,
    is_fill: bool,
    value: u64,
    amount: u64,
    fee: Coin<C>,
    ctx: &TxContext,
) {
    market.update_tables(offer_id, is_buy, is_fill, ctx.sender());

    market.update_stats(is_buy, is_fill, value, amount);

    coin::put(&mut market.balance, fee);
}

/// Cancel the offer
/// Only creator can cancel the offer so no need to check the fill status
/// No need to delete the offer from the buy/sell tables
public(package) fun cancel_offer<C>(
    market: &mut Market<C>,
    _offer_id: ID,
    is_buy: bool,
    value: u64,
    amount: u64,
) {
    market.reset_stats(is_buy, value, amount);
}

public(package) fun update_closed_offers<C>(market: &mut Market<C>, offer_id: ID) {
    market.closed_offers.add(offer_id, offer_id);
}

// ========================= Read functions

public(package) fun fee_percentage<C>(market: &Market<C>): u64 {
    market.fee_percentage
}

public(package) fun coin_decimals<C>(market: &Market<C>): u8 {
    *market.coin_decimals.borrow()
}

// ========================= PRIVATE FUNCTIONS =========================

fun assert_admin(cap: &Publisher) {
    assert!(cap.from_module<MARKET>(), ENotAuthorized);
}

fun update_tables<C>(
    market: &mut Market<C>,
    offer_id: ID,
    is_buy: bool,
    is_fill: bool,
    address: address,
) {
    // Add offer to the address_offers table
    // Call for both creator and filler
    let address_offers = &mut market.address_offers;
    if (!address_offers.contains(address)) {
        address_offers.add(address, vector::empty());
    };
    address_offers[address].push_back(offer_id);

    // Add offers only when creating an offer
    // Do not add when filling an offer due to mirroring
    if (!is_fill) {
        if (is_buy) {
            market.buy_offers.add(offer_id, offer_id);
        } else {
            market.sell_offers.add(offer_id, offer_id);
        }
    } else {
        market.filled_offers.add(offer_id, offer_id);
    }
}

fun update_stats<C>(market: &mut Market<C>, is_buy: bool, is_fill: bool, value: u64, amount: u64) {
    if (is_fill) {
        market.total_volume = market.total_volume + value;
    };
    if (is_buy) {
        market.total_buy_value = market.total_buy_value + value;
        market.total_buy_amount = market.total_buy_amount + amount;
    } else {
        market.total_sell_value = market.total_sell_value + value;
        market.total_sell_amount = market.total_sell_amount + amount;
    };
}

fun reset_stats<C>(market: &mut Market<C>, is_buy: bool, value: u64, amount: u64) {
    if (is_buy) {
        market.total_buy_value = market.total_buy_value - value;
        market.total_buy_amount = market.total_buy_amount - amount;
    } else {
        market.total_sell_value = market.total_sell_value - value;
        market.total_sell_amount = market.total_sell_amount - amount;
    };
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
    let market = Market<SUI> {
        id: object::new(ctx),
        name: b"TestTokenMarket".to_string(),
        coin_symbol: option::some(b"TTM".to_string()),
        url: url::new_unsafe_from_bytes(b"TestUrl"),
        fee_percentage: FEE_PERCENTAGE,
        balance: balance::zero(),
        created_at_timestamp_ms: 0,
        address_offers: table::new(ctx),
        buy_offers: table::new(ctx),
        sell_offers: table::new(ctx),
        filled_offers: table::new(ctx),
        closed_offers: table::new(ctx),
        total_buy_value: 0,
        total_buy_amount: 0,
        total_sell_value: 0,
        total_sell_amount: 0,
        total_volume: 0,
        coin_type: option::none(),
        coin_decimals: option::none(),
        settlement_end_timestamp_ms: option::none(),
    };

    transfer::share_object(market);
}

// ========================= TESTS =========================
#[test_only]
use sui::test_utils::assert_eq;

#[test]
fun test_types_comparison() {
    let generated_type = type_name::get_with_original_ids<Market<SUI>>().into_string();

    let mut hardcode_type = b"".to_string();
    hardcode_type.append(@pre_market.to_string());
    hardcode_type.append(b"::market::Market<0000000000000000000000000000000000000000000000000000000000000002::sui::SUI>".to_string());

    std::debug::print(&generated_type);
    std::debug::print(&hardcode_type);

    assert_eq(generated_type.into_bytes(), hardcode_type.into_bytes());
}

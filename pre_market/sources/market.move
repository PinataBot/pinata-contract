module pre_market::market;

use pre_market::utils::withdraw_balance;
use std::string::{Self, String};
use std::type_name;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, CoinMetadata};
use sui::event::emit;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};
use sui::url::{Self, Url};
use usdc::usdc::USDC;

// ========================= CONSTANTS =========================

const SETTLEMENT_TIME_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours
const FEE_PERCENTAGE: u64 = 2;

const PRE_MARKET_SUFFIX: vector<u8> = b"Pre Market ";

// ========================= ERRORS =========================

const ENotAuthorized: u64 = 0;
const EMarketInactive: u64 = 1;
const EMarketNotSettlement: u64 = 2;
const EMarketNotClosed: u64 = 3;
const EInvalidCoinType: u64 = 4;

// ========================= STRUCTS =========================

public struct MARKET has drop {}

public enum Status has copy, store, drop {
    Active,
    Settlement,
    Closed,
}

public struct Market has key {
    /// Market ID
    id: UID,
    /// Name of the market
    name: String,
    /// URL of info about the token
    url: Url,
    /// Fee percentage of the market
    fee_percentage: u64,
    /// Balance of the market
    balance: Balance<USDC>,
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

public entry fun new(
    cap: &Publisher,
    name: vector<u8>,
    url: vector<u8>,
    symbol: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_admin(cap);

    let market = Market {
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

public entry fun settlement<T>(
    market: &mut Market,
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
public entry fun unsettlement(market: &mut Market, cap: &Publisher) {
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
public entry fun close(market: &mut Market, cap: &Publisher, clock: &Clock) {
    assert_admin(cap);

    market.settlement_end_timestamp_ms = option::some(clock.timestamp_ms());

    emit(MarketClosed { market: object::id(market) });
}

public entry fun withdraw(market: &mut Market, cap: &Publisher, ctx: &mut TxContext) {
    assert_admin(cap);

    withdraw_balance(&mut market.balance, ctx);
}

// ========================= Read functions

public fun status(market: &Market, clock: &Clock): Status {
    if (market.settlement_end_timestamp_ms.is_none()) {
        Status::Active
    } else if (clock.timestamp_ms() <= *market.settlement_end_timestamp_ms.borrow()) {
        Status::Settlement
    } else {
        Status::Closed
    }
}

public fun get_address_offers(market: &Market, address: address): vector<ID> {
    market.address_offers[address]
}

// ========================= PUBLIC(PACKAGE) FUNCTIONS =========================

// ========================= Write functions

public(package) fun assert_active(market: &Market, clock: &Clock) {
    assert!(market.status(clock) == Status::Active, EMarketInactive);
}

public(package) fun assert_settlement(market: &Market, clock: &Clock) {
    assert!(market.status(clock) == Status::Settlement, EMarketNotSettlement);
}

/// Check if the market settlement is ended
/// And the market is ready to be closed
public(package) fun assert_closed(market: &Market, clock: &Clock) {
    assert!(market.status(clock) == Status::Closed, EMarketNotClosed);
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
    amount: u64,
    fee: Coin<USDC>,
    ctx: &TxContext,
) {
    market.update_tables(offer_id, is_buy, is_fill, ctx.sender());

    market.update_stats(is_buy, is_fill, value, amount);

    coin::put(&mut market.balance, fee);
}

/// Cancel the offer
/// Only creator can cancel the offer so no need to check the fill status
/// No need to delete the offer from the buy/sell tables
public(package) fun cancel_offer(
    market: &mut Market,
    _offer_id: ID,
    is_buy: bool,
    value: u64,
    amount: u64,
) {
    market.reset_stats(is_buy, value, amount);
}

public(package) fun update_closed_offers(market: &mut Market, offer_id: ID) {
    market.closed_offers.add(offer_id, offer_id);
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

fun update_tables(
    market: &mut Market,
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
    if (!address_offers[address].contains(&offer_id)) {
        address_offers[address].push_back(offer_id);
    };

    // Add offers only when creating an offer
    // Do not add when filling an offer due to mirroring
    if (!is_fill) {
        if (is_buy) {
            market.buy_offers.add(offer_id, offer_id);
        } else {
            market.sell_offers.add(offer_id, offer_id);
        }
    } else {
        if (!market.filled_offers.contains(offer_id)) {
            market.filled_offers.add(offer_id, offer_id);
        }
    }
}

fun update_stats(market: &mut Market, is_buy: bool, is_fill: bool, value: u64, amount: u64) {
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

fun reset_stats(market: &mut Market, is_buy: bool, value: u64, amount: u64) {
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

#[test_only]
public fun test_claim_publisher(ctx: &mut TxContext): Publisher {
    package::claim(MARKET {}, ctx)
}

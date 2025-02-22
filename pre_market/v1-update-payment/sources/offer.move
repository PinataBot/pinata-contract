module pre_market::offer;

use pre_market::market::Market;
use pre_market::utils::withdraw_balance;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event::emit;

// ========================= CONSTANTS =========================

const ONE_USDC: u64 = 1_000_000;

// ========================= Statuses
const ACTIVE: u8 = 0;
const CANCELLED: u8 = 1;
const FILLED: u8 = 2;
const CLOSED: u8 = 3;

// ========================= ERRORS =========================

const EInvalidAmount: u64 = 0;
const EInvalidCollateralValue: u64 = 1;
const EInvalidPayment: u64 = 2;
const EOfferInactive: u64 = 3;
const EOfferNotFilled: u64 = 4;
const ENotCreator: u64 = 5;
const ENotFiller: u64 = 6;
const EInvalidSettlement: u64 = 7;

// ========================= STRUCTS =========================

public struct Offer<phantom C> has key {
    /// Offer ID
    id: UID,
    /// Market ID
    market_id: ID,
    /// Status of the offer. 0 - Active, 1 - Cancelled, 2 - Filled, 3 - Closed
    status: u8,
    /// Is the offer buy or sell
    /// true - buy, false - sell
    is_buy: bool,
    /// Creator of the offer
    creator: address,
    /// Filled by
    filler: Option<address>,
    /// Amount of tokens T to buy/sell
    /// Whole amount of the token
    /// Later this amount multiplied by 10^decimals of the token
    amount: u64,
    /// Total value in USDC with 6 decimals
    /// Creator has to deposit this amount in USDC
    /// Filler has to deposit this amount in USDC
    collateral_value: u64,
    /// Balance of the offer
    /// After the offer is created, the balance is equal to collateral_value
    /// After the offer is filled, the balance is 2 * collateral_value
    /// After the offer is closed, the balance is 0
    balance: Balance<C>,
    /// Created at timestamp in milliseconds
    created_at_timestamp_ms: u64,
}

// ========================= EVENTS =========================

public struct OfferCreated has copy, drop {
    offer: ID,
}

public struct OfferCanceled has copy, drop {
    offer: ID,
}

public struct OfferFilled has copy, drop {
    offer: ID,
}

public struct OfferClosed has copy, drop {
    offer: ID,
}

// ========================= PUBLIC FUNCTIONS =========================

public entry fun create<C>(
    market: &mut Market<C>,
    is_buy: bool,
    amount: u64,
    collateral_value: u64,
    mut coin: Coin<C>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_active(clock);
    assert!(amount > 0, EInvalidAmount);
    assert!(collateral_value >= ONE_USDC, EInvalidCollateralValue);

    let mut offer = Offer {
        id: object::new(ctx),
        market_id: object::id(market),
        status: ACTIVE,
        is_buy,
        creator: ctx.sender(),
        filler: option::none(),
        amount,
        collateral_value,
        balance: balance::zero(),
        created_at_timestamp_ms: clock.timestamp_ms(),
    };

    let fee = offer.split_fee(market, &mut coin, ctx);
    market.add_offer(
        object::id(&offer),
        offer.is_buy,
        false,
        offer.collateral_value,
        offer.amount,
        fee,
        ctx,
    );

    coin::put(&mut offer.balance, coin);

    emit(OfferCreated { offer: object::id(&offer) });

    transfer::share_object(offer);
}

public entry fun cancel<C>(offer: &mut Offer<C>, market: &mut Market<C>, ctx: &mut TxContext) {
    offer.assert_active();
    offer.assert_creator(ctx);

    market.cancel_offer(object::id(offer), offer.is_buy, offer.collateral_value, offer.amount);

    withdraw_balance(&mut offer.balance, ctx);
    offer.status = CANCELLED;

    emit(OfferCanceled { offer: object::id(offer) });
}

/// Fill the offer with the USDC deposit
/// After filling the offer, the balance of the offer is 2 * collateral_value
/// And users have to wait settlement phase to settle the offer
public entry fun fill<C>(
    offer: &mut Offer<C>,
    market: &mut Market<C>,
    mut coin: Coin<C>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_active(clock);
    offer.assert_active();
    offer.assert_not_creator(ctx);

    let fee = offer.split_fee(market, &mut coin, ctx);
    market.add_offer(
        object::id(offer),
        !offer.is_buy,
        true,
        offer.collateral_value,
        offer.amount,
        fee,
        ctx,
    );

    coin::put(&mut offer.balance, coin);
    offer.filler = option::some(ctx.sender());
    offer.status = FILLED;

    emit(OfferFilled { offer: object::id(offer) });
}

/// Settle the offer
/// After the offer is settled, the balance of the offer is 0
/// Sender sends coins to the second party and withdraws the USDC deposit from 2 parties
/// If there are no settlement after settlement phase, the second party can withdraw the USDC deposit from 2 parties
public entry fun settle_and_close<T, C>(
    offer: &mut Offer<C>,
    market: &mut Market<C>,
    coin: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_settlement(clock);
    offer.assert_filled();

    let recipient: address;
    if (offer.is_buy) {
        // Maxim - Buy, Ernest - Sell
        // Ernest settles tokens
        // Maxim receives tokens
        // Ernest receives USDC deposit from 2 parties
        offer.assert_filler(ctx);
        recipient = offer.creator;
    } else {
        // Maxim - Sell, Ernest - Buy
        // Maxim settles tokens
        // Ernest receives tokens
        // Maxim receives USDC deposit from 2 parties
        offer.assert_creator(ctx);
        recipient = *offer.filler.borrow();
    };

    offer.assert_valid_settlement(market, &coin);

    transfer::public_transfer(coin, recipient);

    withdraw_balance(&mut offer.balance, ctx);

    offer.status = CLOSED;

    market.update_closed_offers(object::id(offer));

    emit(OfferClosed { offer: object::id(offer) });
}

/// Close the offer
/// After the settlement phase, if the offer is not settled, the second party can close the offer
/// And withdraw the USDC deposit from 2 parties
public entry fun close<C>(
    offer: &mut Offer<C>,
    market: &mut Market<C>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_closed(clock);
    offer.assert_filled();

    if (offer.is_buy) {
        // Maxim - Buy, Ernest - Sell
        // Ernest doesn't settle tokens
        // Maxim can close the offer and withdraw the USDC deposit from 2 parties
        offer.assert_creator(ctx);
    } else {
        // Maxim - Sell, Ernest - Buy
        // Maxim doesn't settle tokens
        // Ernest can close the offer and withdraw the USDC deposit from 2 parties
        offer.assert_filler(ctx);
    };

    withdraw_balance(&mut offer.balance, ctx);

    offer.status = CLOSED;

    market.update_closed_offers(object::id(offer));

    emit(OfferClosed { offer: object::id(offer) });
}

// ========================= PRIVATE FUNCTIONS =========================

// 1UDSC: 1_000_000
// 1_000_000 * 2 / 100 = 20_000
// 1_000_000 + 20_000 = 1_020_000
fun split_fee<C>(
    offer: &Offer<C>,
    market: &Market<C>,
    coin: &mut Coin<C>,
    ctx: &mut TxContext,
): Coin<C> {
    let fee_value = offer.collateral_value * market.fee_percentage() / 100;

    assert!(coin.value() == offer.collateral_value + fee_value, EInvalidPayment);

    let fee = coin.split(fee_value, ctx);

    fee
}

fun assert_active<C>(offer: &Offer<C>) {
    assert!(offer.status == ACTIVE, EOfferInactive);
}

fun assert_filled<C>(offer: &Offer<C>) {
    assert!(offer.status == FILLED, EOfferNotFilled);
}

fun assert_creator<C>(offer: &Offer<C>, ctx: &TxContext) {
    assert!(offer.creator == ctx.sender(), ENotCreator);
}

fun assert_not_creator<C>(offer: &Offer<C>, ctx: &TxContext) {
    assert!(offer.creator != ctx.sender(), ENotCreator);
}

fun assert_filler<C>(offer: &Offer<C>, ctx: &TxContext) {
    assert!(offer.filler.is_some() && offer.filler.borrow() == ctx.sender(), ENotFiller);
}

fun assert_valid_settlement<T, C>(offer: &Offer<C>, market: &Market<C>, coin: &Coin<T>) {
    market.assert_coin_type<T, C>();

    assert!(coin.value() == offer.amount * 10u64.pow(market.coin_decimals()), EInvalidSettlement);
}

// ========================= TESTS =========================
#[test_only]
use pre_market::market;
#[test_only]
use sui::test_scenario as ts;
#[test_only]
use sui::sui::SUI;

#[test]
fun test_payment() {
    let sender = @0xA;
    let mut ts = ts::begin(sender);

    market::create_test_market(ts::ctx(&mut ts));
    ts::next_tx(&mut ts, sender);

    let market = ts::take_shared<Market<SUI>>(&ts);

    // 1 USDC = 10^6
    let collateral_value = ONE_USDC;
    let amount = 1000;
    std::debug::print(&collateral_value);
    let fee_value = collateral_value * market.fee_percentage() / 100;
    std::debug::print(&fee_value);
    let coin_value = collateral_value + fee_value;
    std::debug::print(&coin_value);

    let mut coin = coin::mint_for_testing<SUI>(coin_value, ts::ctx(&mut ts));
    ts::next_tx(&mut ts, sender);
    // std::debug::print(&coin);

    let id = object::new(ts::ctx(&mut ts));
    let offer = Offer<SUI> {
        id,
        market_id: object::id(&market),
        status: ACTIVE,
        is_buy: true,
        creator: sender,
        filler: option::none(),
        // price,
        amount,
        collateral_value,
        balance: balance::zero(),
        created_at_timestamp_ms: 0,
    };
    transfer::share_object(offer);
    ts::next_tx(&mut ts, sender);

    let offer = ts::take_shared<Offer<SUI>>(&ts);
    let fee = offer.split_fee(&market, &mut coin, ts::ctx(&mut ts));
    ts::next_tx(&mut ts, sender);
    // std::debug::print(&fee);

    assert!(coin.value() == collateral_value);
    assert!(fee.value() == fee_value);

    ts::return_shared(market);
    ts::return_shared(offer);
    coin::burn_for_testing(coin);
    coin::burn_for_testing(fee);
    ts::end(ts);
}

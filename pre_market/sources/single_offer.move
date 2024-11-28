module pre_market::single_offer;

use pre_market::market::Market;
use pre_market::utils::withdraw_balance;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event::emit;
use usdc::usdc::USDC;

// ========================= CONSTANTS =========================

const ONE_USDC: u64 = 1_000_000;

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

public enum Status has copy, store, drop {
    Active,
    Cancelled,
    Filled,
    Closed,
}

public struct SingleOffer has key {
    /// Offer ID
    id: UID,
    /// Market ID
    market_id: ID,
    /// Status of the offer. 0 - Active, 1 - Cancelled, 2 - Filled, 3 - Closed
    status: Status,
    /// Is the offer buy or sell
    /// true - buy, false - sell
    buy_or_sell: bool,
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
    balance: Balance<USDC>,
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

public entry fun create(
    market: &mut Market,
    buy_or_sell: bool,
    amount: u64,
    collateral_value: u64,
    mut coin: Coin<USDC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_active(clock);
    assert!(amount > 0, EInvalidAmount);
    assert!(collateral_value >= ONE_USDC, EInvalidCollateralValue);

    let mut offer = SingleOffer {
        id: object::new(ctx),
        market_id: object::id(market),
        status: Status::Active,
        buy_or_sell,
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
        offer.buy_or_sell,
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

public entry fun cancel(offer: &mut SingleOffer, market: &mut Market, ctx: &mut TxContext) {
    offer.assert_active();
    offer.assert_creator(ctx);

    market.cancel_offer(object::id(offer), offer.buy_or_sell, offer.collateral_value, offer.amount);

    withdraw_balance(&mut offer.balance, ctx);
    offer.status = Status::Cancelled;

    emit(OfferCanceled { offer: object::id(offer) });
}

/// Fill the offer with the USDC deposit
/// After filling the offer, the balance of the offer is 2 * collateral_value
/// And users have to wait settlement phase to settle the offer
public entry fun fill(
    offer: &mut SingleOffer,
    market: &mut Market,
    mut coin: Coin<USDC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_active(clock);
    offer.assert_active();
    offer.assert_not_creator(ctx);

    let fee = offer.split_fee(market, &mut coin, ctx);
    market.add_offer(
        object::id(offer),
        !offer.buy_or_sell,
        true,
        offer.collateral_value,
        offer.amount,
        fee,
        ctx,
    );

    coin::put(&mut offer.balance, coin);
    offer.filler = option::some(ctx.sender());
    offer.status = Status::Filled;

    emit(OfferFilled { offer: object::id(offer) });
}

/// Settle the offer
/// After the offer is settled, the balance of the offer is 0
/// Sender sends coins to the second party and withdraws the USDC deposit from 2 parties
/// If there are no settlement after settlement phase, the second party can withdraw the USDC deposit from 2 parties
public entry fun settle_and_close<T>(
    offer: &mut SingleOffer,
    market: &mut Market,
    coin: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_settlement(clock);
    offer.assert_filled();

    let recipient: address;
    if (offer.buy_or_sell) {
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

    offer.status = Status::Closed;

    market.update_closed_offers(object::id(offer));

    emit(OfferClosed { offer: object::id(offer) });
}

/// Close the offer
/// After the settlement phase, if the offer is not settled, the second party can close the offer
/// And withdraw the USDC deposit from 2 parties
public entry fun close(
    offer: &mut SingleOffer,
    market: &mut Market,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_closed(clock);
    offer.assert_filled();

    if (offer.buy_or_sell) {
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

    offer.status = Status::Closed;

    market.update_closed_offers(object::id(offer));

    emit(OfferClosed { offer: object::id(offer) });
}

// ========================= PRIVATE FUNCTIONS =========================

// 1UDSC: 1_000_000
// 1_000_000 * 2 / 100 = 20_000
// 1_000_000 + 20_000 = 1_020_000
fun split_fee(
    offer: &SingleOffer,
    market: &Market,
    coin: &mut Coin<USDC>,
    ctx: &mut TxContext,
): Coin<USDC> {
    let fee_value = offer.collateral_value * market.fee_percentage() / 100;

    assert!(coin.value() == offer.collateral_value + fee_value, EInvalidPayment);

    let fee = coin.split(fee_value, ctx);

    fee
}

fun assert_active(offer: &SingleOffer) {
    assert!(offer.status == Status::Active, EOfferInactive);
}

fun assert_filled(offer: &SingleOffer) {
    assert!(offer.status == Status::Filled, EOfferNotFilled);
}

fun assert_creator(offer: &SingleOffer, ctx: &TxContext) {
    assert!(offer.creator == ctx.sender(), ENotCreator);
}

fun assert_not_creator(offer: &SingleOffer, ctx: &TxContext) {
    assert!(offer.creator != ctx.sender(), ENotCreator);
}

fun assert_filler(offer: &SingleOffer, ctx: &TxContext) {
    assert!(offer.filler.is_some() && offer.filler.borrow() == ctx.sender(), ENotFiller);
}

fun assert_valid_settlement<T>(offer: &SingleOffer, market: &Market, coin: &Coin<T>) {
    market.assert_coin_type<T>();

    assert!(coin.value() == offer.amount * 10u64.pow(market.coin_decimals()), EInvalidSettlement);
}


// ========================= TEST ONLY FUNCTIONS =========================

#[test_only]
public fun test_split_fee(
    offer: &SingleOffer,
    market: &Market,
    coin: &mut Coin<USDC>,
    ctx: &mut TxContext,
): Coin<USDC> {
    split_fee(offer, market, coin, ctx)
}

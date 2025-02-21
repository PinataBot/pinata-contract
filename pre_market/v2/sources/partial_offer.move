module pre_market::partial_offer;

use pre_market::market::Market;
use pre_market::utils::{withdraw_balance, withdraw_balance_value, withdraw_balance_to_coin};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event::emit;
use sui::vec_map::{Self, VecMap};
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
    PartialCancelled,
    Filled,
    PartialFilled,
    Closed,
    PartialClosed,
}

public struct PartialOffer has key {
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
    /// address -> amount
    fillers: VecMap<address, u64>,
    /// Amount of tokens T to buy/sell
    /// Whole amount of the token
    /// Later this amount multiplied by 10^decimals of the token
    amount: u64,
    /// Amount of filled tokens
    filled_amount: u64,
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
    assert_minimal_amount(amount);
    assert_minimal_collateral_value(collateral_value);

    let mut offer = PartialOffer {
        id: object::new(ctx),
        market_id: object::id(market),
        status: Status::Active,
        buy_or_sell,
        creator: ctx.sender(),
        fillers: vec_map::empty(),
        amount,
        filled_amount: 0,
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

// todo: check if partially filled
public entry fun cancel(offer: &mut PartialOffer, market: &mut Market, ctx: &mut TxContext) {
    offer.assert_fillable();
    offer.assert_creator(ctx);

    if (offer.status == Status::Active) {
        market.cancel_offer(
            object::id(offer),
            offer.buy_or_sell,
            offer.collateral_value,
            offer.amount,
        );

        withdraw_balance(&mut offer.balance, ctx);
        offer.status = Status::Cancelled;
    } else {
        let filled_amount = offer.filled_amount;
        let unfilled_amount = offer.amount - filled_amount;

        // collateral value  = 10 USDC, amount = 10, filled_amount = 5
        // unfilled_amount = 10 - 5 = 5
        // unfilled_collateral_value = 10 - 5 * 10 / 10 = 5
        let unfilled_collateral_value =
            offer.balance.value() - filled_amount * offer.collateral_value / offer.amount;

        market.cancel_offer(
            object::id(offer),
            offer.buy_or_sell,
            unfilled_collateral_value,
            unfilled_amount,
        );

        withdraw_balance_value(&mut offer.balance, unfilled_collateral_value, ctx);
        offer.status = Status::PartialCancelled;
    };

    emit(OfferCanceled { offer: object::id(offer) });
}

public entry fun fill(
    offer: &mut PartialOffer,
    market: &mut Market,
    amount: u64,
    mut coin: Coin<USDC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_active(clock);
    offer.assert_fillable();
    offer.assert_not_creator(ctx);

    assert_minimal_amount(amount);
    assert!(amount <= offer.amount - offer.filled_amount, EInvalidAmount);

    let fee = offer.split_fee_partial(market, &mut coin, amount, ctx);
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
    offer.add_filler(ctx.sender(), amount);
    offer.filled_amount = offer.filled_amount + amount;
    offer.status = if (offer.filled_amount >= offer.amount) {
            Status::Filled
        } else {
            Status::PartialFilled
        };

    emit(OfferFilled { offer: object::id(offer) });
}

// TODO: add tests
public entry fun settle_and_close<T>(
    offer: &mut PartialOffer,
    market: &mut Market,
    mut coin: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_settlement(clock);
    offer.assert_closable();

    if (offer.buy_or_sell) {
        // Maxim - Buy, Ernest and others - Sell
        // Ernest and others settles tokens
        // Maxim receives tokens
        // Ernest and others receives USDC deposit from their filled amount
        offer.assert_filler(ctx);

        transfer::public_transfer(coin, offer.creator);

        let filler_amount = offer.fillers.get_mut(&ctx.sender());
        let filler_value = offer.collateral_value / offer.amount * *filler_amount;

        withdraw_balance_value(&mut offer.balance, filler_value, ctx);

        offer.status = if (offer.balance.value() > 0) {
                Status::PartialClosed
            } else {
                Status::Closed
            };
    } else {
        // Maxim - Sell, Ernest - Buy
        // Maxim settles tokens
        // Ernest receives tokens
        // Maxim receives USDC deposit from all parties
        offer.assert_creator(ctx);

        offer.assert_valid_full_settlement(market, &coin);

        let (addresses, amounts) = offer.fillers.into_keys_values();

        addresses.length().do!(|i| {
            let address = addresses[i];
            let amount = amounts[i];

            let coin = coin.split(amount * 10u64.pow(market.coin_decimals()), ctx);
            transfer::public_transfer(coin, address);
        });
        coin.destroy_zero();

        withdraw_balance(&mut offer.balance, ctx);

        offer.status = Status::Closed;

        market.update_closed_offers(object::id(offer));

        emit(OfferClosed { offer: object::id(offer) });
    };
}

/// Close the offer
/// After the settlement phase, if the offer is not settled, the second party can close the offer
/// And withdraw the USDC deposit from 2 parties
public entry fun close(
    offer: &mut PartialOffer,
    market: &mut Market,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_closed(clock);
    offer.assert_closable();

    if (offer.buy_or_sell) {
        // Maxim - Buy, Ernest - Sell
        // Someoune of fillers doesn't settle tokens
        // Maxim can close the offer and withdraw unfilled USDC deposits from all unfilled parties
        offer.assert_creator(ctx);

        withdraw_balance(&mut offer.balance, ctx);
    } else {
        // Maxim - Sell, Ernest - Buy
        // Maxim doesn't settle tokens
        // Ernest can close the offer and withdraw the USDC deposit to all fillers
        offer.assert_filler(ctx);

        let (addresses, amounts) = offer.fillers.into_keys_values();

        let mut balance_coin = withdraw_balance_to_coin(&mut offer.balance, ctx);
        addresses.length().do!(|i| {
            let address = addresses[i];
            let amount = amounts[i];

            let collater_value = 2 * offer.collateral_value / offer.amount * amount;

            let coin = balance_coin.split(collater_value, ctx);
            transfer::public_transfer(coin, address);
        });
        balance_coin.destroy_zero();
    };

    offer.status = Status::Closed;

    market.update_closed_offers(object::id(offer));

    emit(OfferClosed { offer: object::id(offer) });
}

// ========================= PRIVATE FUNCTIONS =========================

// 1UDSC: 1_000_000
// 1_000_000 * 2 / 100 = 20_000
// 1_000_000 + 20_000 = 1_020_000
fun split_fee(
    offer: &PartialOffer,
    market: &Market,
    coin: &mut Coin<USDC>,
    ctx: &mut TxContext,
): Coin<USDC> {
    let fee_value = offer.collateral_value * market.fee_percentage() / 100;

    assert!(coin.value() == offer.collateral_value + fee_value, EInvalidPayment);

    let fee = coin.split(fee_value, ctx);

    fee
}

fun split_fee_partial(
    offer: &PartialOffer,
    market: &Market,
    coin: &mut Coin<USDC>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<USDC> {
    let partial_value = offer.collateral_value / offer.amount * amount;
    // ensure that the partial value is not less than the minimal collateral value (1 USDC)
    assert_minimal_collateral_value(partial_value);

    let fee_value = partial_value * market.fee_percentage() / 100;

    // if offer.collateral_value = 10 USDC, offer.amount = 10, amount = 5 => partial_value = 5 USDC, fee_value = 5 * 2 / 100 = 0.1 USDC
    assert!(coin.value() == partial_value + fee_value, EInvalidPayment);

    let fee = coin.split(fee_value, ctx);

    fee
}

fun add_filler(offer: &mut PartialOffer, address: address, amount: u64) {
    if (offer.fillers.contains(&address)) {
        let current_amount = offer.fillers.get_mut(&address);
        *current_amount = *current_amount + amount;
    } else {
        offer.fillers.insert(address, amount);
    }
}

// ========================= Asserts

fun assert_active(offer: &PartialOffer) {
    assert!(offer.status == Status::Active, EOfferInactive);
}

fun assert_fillable(offer: &PartialOffer) {
    assert!(offer.status == Status::Active || offer.status == Status::PartialFilled, EOfferInactive);
}

fun assert_partial_filled(offer: &PartialOffer) {
    assert!(offer.status == Status::PartialFilled, EOfferNotFilled);
}

fun assert_filled(offer: &PartialOffer) {
    assert!(offer.status == Status::Filled, EOfferNotFilled);
}

fun assert_closable(offer: &PartialOffer) {
    assert!(
        offer.status == Status::Filled || offer.status == Status::PartialFilled || offer.status == Status::PartialCancelled || offer.status == Status::PartialClosed,
        EOfferNotFilled,
    );
}

fun assert_creator(offer: &PartialOffer, ctx: &TxContext) {
    assert!(offer.creator == ctx.sender(), ENotCreator);
}

fun assert_not_creator(offer: &PartialOffer, ctx: &TxContext) {
    assert!(offer.creator != ctx.sender(), ENotCreator);
}

fun assert_filler(offer: &PartialOffer, ctx: &TxContext) {
    assert!(offer.fillers.contains(&ctx.sender()), ENotFiller);
}

fun assert_valid_full_settlement<T>(offer: &PartialOffer, market: &Market, coin: &Coin<T>) {
    market.assert_coin_type<T>();

    assert!(
        coin.value() == offer.filled_amount * 10u64.pow(market.coin_decimals()),
        EInvalidSettlement,
    );
}

fun assert_minimal_amount(amount: u64) {
    assert!(amount > 0, EInvalidAmount);
}

fun assert_minimal_collateral_value(collateral_value: u64) {
    assert!(collateral_value >= ONE_USDC, EInvalidCollateralValue);
}
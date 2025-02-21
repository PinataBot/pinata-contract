module pre_market::utils;

use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::pay::keep;

public(package) fun withdraw_balance<T>(balance: &mut Balance<T>, ctx: &mut TxContext) {
    keep(coin::from_balance(balance.withdraw_all(), ctx), ctx);
}

public(package) fun withdraw_balance_to_coin<T>(
    balance: &mut Balance<T>,
    ctx: &mut TxContext,
): Coin<T> {
    coin::from_balance(balance.withdraw_all(), ctx)
}

public(package) fun withdraw_balance_value<T>(
    balance: &mut Balance<T>,
    value: u64,
    ctx: &mut TxContext,
) {
    keep(coin::from_balance(balance.split(value), ctx), ctx);
}

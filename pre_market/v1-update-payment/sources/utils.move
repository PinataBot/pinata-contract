module pre_market::utils;

use std::string::{Self, String};
use std::type_name::get_with_original_ids;
use sui::balance::Balance;
use sui::coin;
use sui::pay::keep;

public(package) fun withdraw_balance<T>(balance: &mut Balance<T>, ctx: &mut TxContext) {
    keep(coin::from_balance(balance.withdraw_all(), ctx), ctx);
}

public(package) fun type_to_string<T>(): String {
    string::from_ascii(get_with_original_ids<T>().into_string())
}

module pre_market::utils {
    use pre_market::market::{Self, Market};
    use whusdce::coin::COIN as USDC;

    use sui::coin::{Self, Coin};
    use sui::sui::{SUI};
    use sui::balance::{Balance};
    use sui::package::{Self};
    use sui::object::{Self};
    use sui::balance::{Self};
    use sui::pay::{keep};
    use sui::event::{emit};

    use std::string::{String};
    use std::type_name::{Self};

    public(package) fun withdraw_balance<T>(balance: &mut Balance<T>, ctx: &mut TxContext){
        keep(coin::from_balance(balance.withdraw_all(), ctx), ctx);
    }
}
module double_or_nothing::pay_utils {
    use sui::coin::{Self, Coin};
    use sui::balance::{Balance};
    use sui::pay::{keep};

    const NULL_ADDRESS: address = @0x0;

    public(package) fun burn_coin<T>(coin: Coin<T>) {
        transfer::public_transfer(coin, NULL_ADDRESS);
    }

    public(package) fun balance_withdraw_all<T>(balance: &mut Balance<T>, ctx: &mut TxContext) {
        keep(coin::from_balance(balance.withdraw_all(), ctx), ctx);
    }

    public(package) fun balance_withdraw_all_to_coin<T>(balance: &mut Balance<T>, ctx: &mut TxContext): Coin<T> {
        coin::from_balance(balance.withdraw_all(), ctx)
    }

    public(package) fun balance_withdraw<T>(balance: &mut Balance<T>, value: u64, ctx: &mut TxContext) {
        keep(coin::take(balance, value, ctx), ctx);
    }

    public(package) fun balance_withdraw_to_coin<T>(balance: &mut Balance<T>, value: u64, ctx: &mut TxContext): Coin<T> {
        let coin;
        if (balance.value() < value) {
            coin = balance_withdraw_all_to_coin(balance, ctx)
        } else {
            coin = coin::take(balance, value, ctx);
        };

        coin
    }

    public(package) fun balance_split_percent_to_coin<T>(
        balance: &mut Balance<T>,
        percent: u64,
        ctx: &mut TxContext
    ): Coin<T> {
        let percent_value = balance.value() * percent / 100;

        coin::take(balance, percent_value, ctx)
    }

    public(package) fun coin_split_percent_to_coin<T>(coin: &mut Coin<T>, percent: u64, ctx: &mut TxContext): Coin<T> {
        let percent_value = coin.value() * percent / 100;

        coin.split(percent_value, ctx)
    }

    public(package) fun balance_top_up<T>(balance: &mut Balance<T>, coin: Coin<T>) {
        balance.join(coin.into_balance());
    }
}
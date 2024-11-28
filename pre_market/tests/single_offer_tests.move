#[test_only]
module pre_market::single_offer_tests;

use pre_market::market::{Self, Market};
use pre_market::market_tests::{Self};
use pre_market::single_offer::{Self, SingleOffer};
use std::debug::print;
use std::unit_test::assert_eq;
use sui::clock;
use sui::coin;
use sui::test_scenario as ts;
use usdc::usdc::USDC;

#[test]
fun test_fee() {
    let sender = @0xA;
    let mut ts = ts::begin(sender);

    market_tests::new(ts.ctx());
    ts.next_tx(sender);

    let mut market = ts.take_shared<Market>();

    // 1 USDC = 10^6
    let collateral_value = 1_000_000;
    let amount = 1000;
    print(&collateral_value);
    let fee_value = collateral_value * market.fee_percentage() / 100;
    print(&fee_value);
    let coin_value = collateral_value + fee_value;
    print(&coin_value);

    let coin = coin::mint_for_testing<USDC>(coin_value, ts.ctx());
    let clock = clock::create_for_testing(ts.ctx());
    single_offer::create(&mut market, true, amount, collateral_value, coin, &clock, ts.ctx());

    ts.next_tx(sender);
    //-

    let offer = ts.take_shared<SingleOffer>();

    let mut test_coin = coin::mint_for_testing<USDC>(coin_value, ts.ctx());

    let fee = offer.test_split_fee(&market, &mut test_coin, ts.ctx());

    assert_eq!(test_coin.value(), collateral_value);
    assert_eq!(fee.value(), fee_value);

    //-

    clock.destroy_for_testing();
    ts::return_shared(market);
    ts::return_shared(offer);
    test_coin.burn_for_testing();
    fee.burn_for_testing();
    ts.end();
}

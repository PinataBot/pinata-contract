#[test_only]
module pre_market::market_tests;

use pre_market::market::{Self, Market};
use std::type_name;
use sui::clock;
use sui::test_utils::destroy;

public fun new(ctx: &mut TxContext) {
    let cap = market::test_claim_publisher(ctx);
    let clock = clock::create_for_testing(ctx);

    market::new(&cap, b"TestTokenMarket", b"TestUrl", b"TTM", &clock, ctx);

    destroy(cap);
    clock.destroy_for_testing();
}

#[test]
fun test_types_comparison() {
    let generated_type = type_name::get_with_original_ids<Market>().into_string();

    let mut hardcode_type = b"".to_string();
    hardcode_type.append(@pre_market.to_string());
    hardcode_type.append(b"::market::Market".to_string());

    assert!(generated_type.into_bytes() == hardcode_type.into_bytes());
}

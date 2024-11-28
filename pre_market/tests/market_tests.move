#[test_only]
module pre_market::market_tests;

use pre_market::market::Market;
use std::type_name;

#[test]
fun test_types_comparison() {
    let generated_type = type_name::get_with_original_ids<Market>().into_string();

    let mut hardcode_type = b"".to_string();
    hardcode_type.append(@pre_market.to_string());
    hardcode_type.append(b"::market::Market".to_string());

    assert!(generated_type.into_bytes() == hardcode_type.into_bytes());
}

module double_or_nothing::random_utils {
    use sui::random::{RandomGenerator};

    const EInvalidVectorLength: u64 = 1;

    public(package) fun weighted_random_choice<T: copy + drop>(
        weights: vector<u64>,
        values: vector<T>,
        rg: &mut RandomGenerator
    ): T {
        assert!(weights.length() == values.length(), EInvalidVectorLength);

        let total_weight = weights.fold!(0, |acc, x| acc + x);
        let random_value = rg.generate_u64_in_range(0, total_weight - 1);

        let mut acc_weight = 0;
        let mut i = 0;
        let values_index = loop {
            acc_weight = acc_weight + weights[i];
            if (random_value < acc_weight) {
                break i
            };
            i = i + 1;
        };

        values[values_index]
    }


    // ========================= TESTS =========================

    #[test_only] use sui::test_scenario as ts;
    #[test_only] use sui::table::{Self};
    #[test_only] use sui::random::{Self, Random};

    #[test_only] use std::debug::print;

    #[test_only] const A: address = @0xA;


    #[test_only]
    fun test_init(ts: &mut ts::Scenario) {
        ts.next_tx(@0x0);
        random::create_for_testing(ts.ctx());
    }

    #[test]
    fun weighted_random_test() {
        let mut ts = ts::begin(A);

        test_init(&mut ts);

        ts.next_tx(A);
        let r = ts.take_shared<Random>();

        let mut rg = random::new_generator(&r, ts.ctx());

        let weights = vector[60, 25, 10, 5];
        let values = vector[0, 2, 5, 10];

        let mut results = table::new<u64, u64>(ts.ctx());
        values.do!(|value| results.add(value, 0));


        1000u64.do!(|_| {
            let random_value = weighted_random_choice(weights, values, &mut rg);

            let current_value = &mut results[random_value];
            *current_value = *current_value + 1;
        });

        values.do!(|value| {
            let value_count = results[value];

            let mut result_string = value.to_string();
            result_string.append(b": ".to_string());
            result_string.append(value_count.to_string());
            print(&result_string);
        });


        results.drop();
        ts::return_shared(r);
        ts.end();
    }
}
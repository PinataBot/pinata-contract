module split_bill::bill {
    use sui::coin::{Self, Coin};
    use sui::balance::{Balance};
    use sui::balance::{Self};
    use sui::event::{emit};
    use sui::pay::{keep};
    use sui::clock::Clock;
    use sui::vec_map::{Self, VecMap};
    
    use std::string::{String};

    // ========================= CONSTANTS =========================

    const MIN_MEMBERS: u64 = 2;
    
    // ========================= ERRORS =========================
    const EInvalidVectorLength: u64 = 0;
    const ENotMember: u64 = 1;
    const EBillAlreadyPaid: u64 = 2;
    const EMemberAlreadyPaid: u64 = 3;
    const EInvalidPayment: u64 = 4;
    
    // ========================= STRUCTS =========================

    public struct Bill<phantom Currency> has key {
        id: UID,
        name: String,
        description: String,

        amount: u64,
        paid_amount: u64,
        withdrawed_amount: u64,
        paid: bool,

        members: VecMap<address, Member>,

        balance: Balance<Currency>,

        created_at_timestamp_ms: u64,
        paid_at_timestamp_ms: Option<u64>,
    }

    public struct BillWithdrawCap has key, store {
        id: UID,
        bill_id: ID
    }

    public struct Member has store {
        address: address,
        name: String,
        amount: u64,
        paid: bool,

        note: Option<String>,
        paid_by: Option<address>,
        paid_at_timestamp_ms: Option<u64>,
    }

    // ========================= EVENTS =========================

    public struct BillCreated has copy, drop {
        bill_id: ID,
    }

    public struct BillPaid has copy, drop {
        bill_id: ID,
    }

    public struct BillMemberPaid has copy, drop {
        bill_id: ID,
        address: address,
        payer: address,
    }

    public struct BillWithdrawed has copy, drop {
        bill_id: ID,
    }

    // ========================= PUBLIC FUNCTIONS =========================

    entry public fun new<T>(
        name: vector<u8>,
        description: vector<u8>,
        amount: u64,
        addresses: vector<address>,
        amounts: vector<u64>,
        names: vector<vector<u8>>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let members_length = addresses.length();
        assert!(members_length >= MIN_MEMBERS);
        assert_vector_length(&amounts, members_length);
        assert_vector_length(&names, members_length);
        assert_sum_vector(&amounts, amount);

        let mut members = vec_map::empty<address, Member>();
        addresses.do!(|address| {
            let (_, index) = addresses.index_of(&address);
            
            members.insert(address, Member { 
                address, 
                amount: amounts[index], 
                name: names[index].to_string(), 
                paid: false, 
                note: option::none(),
                paid_by: option::none(),
                paid_at_timestamp_ms: option::none()
            })
        });

        let bill = Bill<T> {
            id: object::new(ctx),
            name: name.to_string(),
            description: description.to_string(),
            paid: false,
            amount: amount,
            paid_amount: 0,
            withdrawed_amount: 0,
            members: members,
            balance: balance::zero(),
            created_at_timestamp_ms: clock.timestamp_ms(),
            paid_at_timestamp_ms: option::none()
        };

        let bill_manager = BillWithdrawCap {
            id: object::new(ctx),
            bill_id: object::id(&bill)
        };

        emit(BillCreated { bill_id: object::id(&bill) });

        transfer::share_object(bill);
        transfer::public_transfer(bill_manager, ctx.sender());
    }

    entry public fun withdraw<T>(bill: &mut Bill<T>, cap: &BillWithdrawCap, ctx: &mut TxContext) {
        bill.assert_withdraw_permission(cap);

        let coin = coin::from_balance(bill.balance.withdraw_all(), ctx);

        bill.withdrawed_amount = bill.withdrawed_amount + coin.value();
        
        keep(coin, ctx);

        emit(BillWithdrawed { bill_id: object::id(bill) });
    }

    entry public fun pay<T>(
        bill: &mut Bill<T>,
        note: vector<u8>,
        coin: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        pay_impl(bill, ctx.sender(), note, coin, clock, ctx);
    }

    entry public fun pay_for<T>(
        bill: &mut Bill<T>,
        mut addresses: vector<address>,
        mut notes: vector<vector<u8>>,
        mut coins: vector<Coin<T>>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {        
        let pay_for_members_length = addresses.length();
        assert!(pay_for_members_length >= 1);
        assert_vector_length(&coins, pay_for_members_length);
        assert_vector_length(&notes, pay_for_members_length);

        addresses.reverse();
        addresses.do!(|address| {
            let coin = coins.pop_back();
            let note = notes.pop_back();
            pay_impl(bill, address, note, coin, clock, ctx);
        });

        coins.destroy_empty();
    }


    fun pay_impl<T>(
        bill: &mut Bill<T>,
        address: address,
        note: vector<u8>,
        coin: Coin<T>,
        clock: &Clock,
        ctx: &TxContext
    ) {
        let payer = ctx.sender();
        
        bill.assert_bill_not_paid();
        bill.assert_member(payer);
        bill.assert_member(address);

        let member = &mut bill.members[&address];
        member.assert_member_not_paid();
        member.assert_payment(&coin);

        member.paid = true;
        member.note = option::some(note.to_string());
        member.paid_by = option::some(payer);
        member.paid_at_timestamp_ms = option::some(clock.timestamp_ms());

        coin::put(&mut bill.balance, coin);
        bill.paid_amount = bill.paid_amount + member.amount;

        emit(BillMemberPaid { bill_id: object::id(bill), address: address, payer });

        if (bill.paid_amount >= bill.amount) {
            bill.paid = true;
            bill.paid_at_timestamp_ms = option::some(clock.timestamp_ms());
            emit(BillPaid { bill_id: object::id(bill) });
        };
    }
    
    // ========================= PUBLIC(PACKAGE) FUNCTIONS =========================

    // ========================= PRIVATE FUNCTIONS =========================

    fun assert_vector_length<T>(v: &vector<T>, length: u64) {
        assert!(v.length() == length, EInvalidVectorLength);
    }

    fun sum_vector(v: vector<u64>): u64 {
        v.fold!(0, |acc, x| acc + x)
    }

    fun assert_sum_vector(v: &vector<u64>, sum: u64) {
        assert!(sum_vector(*v) == sum);
    }

    fun assert_withdraw_permission<T>(bill: &Bill<T>, cap: &BillWithdrawCap,) {
        assert!(cap.bill_id == object::id(bill));
    }

    fun assert_member<T>(bill: &Bill<T>, address: address) {
        assert!(bill.members.contains(&address), ENotMember);
    }

    fun assert_bill_not_paid<T>(bill: &Bill<T>) {
        assert!(!bill.paid, EBillAlreadyPaid);
    }

    fun assert_member_not_paid(member: &Member) {
        assert!(!member.paid, EMemberAlreadyPaid);
    }

    fun assert_payment<T>(member: &Member, coin: &Coin<T>) {
        assert!(member.amount == coin.value(), EInvalidPayment);
    }


    // ========================= TEST FUNCTIONS =========================
    #[test_only] use sui::test_scenario as ts;
    #[test_only] use sui::sui::SUI;
    #[test_only] use sui::clock::{Self};

    
    #[test_only] const ONE_SUI: u64 = 1_000_000_000;

    #[test_only] const ALICE: address = @0xA;
    #[test_only] const ALICE_AMOUNT: u64 = ONE_SUI;

    #[test_only] const BOB: address = @0xB;
    #[test_only] const BOB_AMOUNT: u64 = ONE_SUI * 2;
    
    #[test_only] const CHARLIE: address = @0xC;
    #[test_only] const CHARLIE_AMOUNT: u64 = ONE_SUI * 3;

    
    #[test_only]
    fun create_bill(ts: &mut ts::Scenario, clock: &Clock) {
        new<SUI>(
            b"Bill",
            b"Bill description",
            ONE_SUI * 6,
            vector[ALICE, BOB, CHARLIE],
            vector[ALICE_AMOUNT, BOB_AMOUNT, CHARLIE_AMOUNT],
            vector[b"Alice", b"Bob", b"Charlie"],
            clock,
            ts.ctx()
        );
    }
    
    #[test]
    fun test_sum_vector() {
        let v = vector[1, 2, 3, 4, 5];

        let sum_vector = sum_vector(v);
        
        // std::debug::print(&sum_vector);
        
        assert!(sum_vector == 15);
    }

    #[test]
    fun test_pay() {
        let mut ts = ts::begin(ALICE);
        let clock = clock::create_for_testing(ts.ctx());

        create_bill(&mut ts, &clock);

        ts::next_tx(&mut ts, ALICE);
        let mut bill = ts::take_shared<Bill<SUI>>(&ts);
        // std::debug::print(&bill);

        ts::next_tx(&mut ts, BOB);
        let note = b"Bob paid";
        let coin = coin::mint_for_testing<SUI>(BOB_AMOUNT, ts.ctx());
        pay(&mut bill, note, coin, &clock, ts.ctx());
        // std::debug::print(&bill);

        // std::debug::print(&bill.members[&BOB]);
        let bob = BOB;
        assert!(bill.members[&bob].paid);
        
        ts::return_shared(bill);
        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    fun test_pay_for(){
        let mut ts = ts::begin(ALICE);
        let clock = clock::create_for_testing(ts.ctx());

        create_bill(&mut ts, &clock);

        ts::next_tx(&mut ts, ALICE);
        let mut bill = ts::take_shared<Bill<SUI>>(&ts);
        
        let alice_note = b"Alice paid";
        let bob_note = b"Bob paid";
        let charlie_note = b"Charlie paid";
        
        ts::next_tx(&mut ts, BOB);
        let coin_a = coin::mint_for_testing<SUI>(ALICE_AMOUNT, ts.ctx());
        let coin_b = coin::mint_for_testing<SUI>(BOB_AMOUNT, ts.ctx());
        let coin_c = coin::mint_for_testing<SUI>(CHARLIE_AMOUNT, ts.ctx());

        pay_for(&mut bill, vector[ALICE, BOB, CHARLIE], vector[alice_note, bob_note, charlie_note], vector[coin_a, coin_b, coin_c], &clock, ts.ctx());
        // std::debug::print(&bill);

        assert!(bill.paid);
        assert!(bill.balance.value() == bill.amount);
        
        ts::return_shared(bill);
        clock::destroy_for_testing(clock);
        ts::end(ts);
    }
}

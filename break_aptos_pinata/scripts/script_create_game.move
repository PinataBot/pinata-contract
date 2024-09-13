script {

    fun create_game(admin: &signer) {
        break_aptos_pinata::game::new(admin, 10, 10000000)
    }
}

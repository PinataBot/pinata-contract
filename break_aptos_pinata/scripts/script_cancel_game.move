script {

    fun cancel(admin: &signer) {
        let game_id = 1;
        break_aptos_pinata::game::cancel(admin, game_id)
    }
}

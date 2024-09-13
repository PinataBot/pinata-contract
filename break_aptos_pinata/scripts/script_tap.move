script {

    fun tap(tapper: &signer) {
        let game_id = 0;
        break_aptos_pinata::game::tap(tapper, game_id)
    }
}

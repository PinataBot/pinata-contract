#!/bin/sh

set -e

echo "##### Running move script to create gotchi #####"

# Profile is the account you used to execute transaction
# Run "aptos init" to create the profile, then get the profile name from .aptos/config.yaml
PROFILE=admin

ADDR=0x$(aptos config show-profiles --profile=$PROFILE | grep 'account' | sed -n 's/.*"account": \"\(.*\)\".*/\1/p')

# Need to compile the package first
aptos move compile \
  --named-addresses break_aptos_pinata=$ADDR

# Run the script
aptos move run-script \
  --profile $PROFILE \
  --compiled-script-path build/break_aptos_pinata/bytecode_scripts/cancel.mv

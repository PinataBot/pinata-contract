#!/bin/sh

set -e

echo "##### Running move script to create gotchi #####"

# Profile is the account you used to execute transaction
# Run "aptos init" to create the profile, then get the profile name from .aptos/config.yaml
ADMIN_PROFILE=admin
PROFILE=tapper

ADDR=0x$(aptos config show-profiles --profile=$ADMIN_PROFILE | grep 'account' | sed -n 's/.*"account": \"\(.*\)\".*/\1/p')

# Need to compile the package first
aptos move compile \
  --named-addresses break_aptos_pinata=$ADDR

for i in {1..10} ; do
    # Run the script
    aptos move run-script \
      --profile $PROFILE \
      --compiled-script-path build/break_aptos_pinata/bytecode_scripts/tap.mv \
    	--assume-yes
done
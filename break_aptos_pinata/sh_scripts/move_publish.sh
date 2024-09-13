#!/bin/sh

set -e

echo "##### Publish module under a new object #####"

# Profile is the account you used to execute transaction
# Run "aptos init" to create the profile, then get the profile name from .aptos/config.yaml
PUBLISHER_PROFILE=admin

PUBLISHER_ADDR=0x$(aptos config show-profiles --profile=$PUBLISHER_PROFILE | grep 'account' | sed -n 's/.*"account": \"\(.*\)\".*/\1/p')

aptos move publish \
  --named-addresses "break_aptos_pinata=$PUBLISHER_ADDR"\
  --profile $PUBLISHER_PROFILE \
	--assume-yes

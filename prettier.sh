# USAGE: ./prettier.sh <path-to-move-file>

PATH_TO_MOVE_FILE=$1

echo "##### Prettify Move file #####"

./node_modules/.bin/prettier --plugin=prettier-plugin-move --write $PATH_TO_MOVE_FILE
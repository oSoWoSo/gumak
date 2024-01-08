#!/usr/bin/bash
# Author: zenobit
# Description: Uses gum to provide a simple TUI
# License MIT
if [ -n "${1}" ]; then
	"${1}" --help > ${1} 2> /dev/null && echo "File named ${1} created" || echo "Not happened!"
	echo -e "With content:\n$(cat ${1} | gum format)"
else
	gum style \
	--padding '0 1' \
	--align center \
	--border rounded \
	--border-foreground "#295340" \
"No argument provided!
Require name of program
for exporting help message.
(To make it more glamorous)
Usage: mg <command>
Example: mg ls"
fi


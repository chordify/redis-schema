#!/usr/bin/env bash

OLDIFS="$IFS"
IFS=$'\n'
grep ^## README.md \
	| sed -r \
		-e 's/^#//' \
		-e 's/# /* /' \
		-e 's/#/  /g' \
	| while read -r heading; do
		slug="$(
			echo "$heading" \
				| tr -c 'A-Za-z0-9' '-' \
				| tr '[:upper:]' '[:lower:]' \
				| sed -r \
					-e 's/-+/-/g' \
					-e 's/^-//' \
					-e 's/-$//'
		)"

		echo "$heading" \
			| sed -r -e "s|\\* (.*)|* [\\1](#${slug})|"
	done
IFS="$OLDIFS"

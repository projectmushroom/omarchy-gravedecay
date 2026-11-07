#!/bin/bash
# Refusals that happen before any network access.
set -u
api="$(dirname "$0")/../bin/gravedecay-api"
fail=0
refuse() { # <stdin> <args...>
  local input=$1; shift
  if printf '%s' "$input" | bash "$api" "$@" >/dev/null 2>&1; then echo "not refused: $*"; fail=1; fi
}
refuse "" probe example.com
refuse "" probe 'grave.ts.net@evil.example'
refuse "" releases 'http://grave.ts.net'
refuse "" request GET grave.tail1.ts.net files
refuse "" request GET grave.tail1.ts.net 'keeper?id=../../etc&after=0'
refuse "" request GET grave.tail1.ts.net 'keeper?id=1794059485-57344bf2b45d4fcda75bbf9124c37dc6&after=0&x=1'
refuse "" request GET grave.tail1.ts.net 'diggers?name=wl&x=1'
refuse "" request GET grave.tail1.ts.net 'diggers/conversation?name=Bad&id=1794059485-57344bf2b45d4fcda75bbf9124c37dc6&after=0'
refuse "" request DELETE grave.tail1.ts.net keeper
refuse "" request POST grave.tail1.ts.net action
refuse "" request POST grave.tail1.ts.net admin/upgrade
refuse '[1]' request POST grave.tail1.ts.net keeper/cancel
refuse '{}' request POST evil.example.com keeper/cancel
refuse "" bogus
((fail)) && exit 1
echo "api refusal tests passed"

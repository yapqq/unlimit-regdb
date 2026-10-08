#!/usr/bin/env bash
# Patch db.txt (remove all limits) and rebuild regulatory.bin / .db / .db.p7s.
#
# Usage: drop a fresh upstream db.txt into this directory and run ./run.sh
#
# The patch:
#   - every rule keeps its "start - end @ bandwidth" and gets max EIRP 100 dBm
#   - every restricting flag is dropped (DFS, NO-IR, NO-OUTDOOR, NO-INDOOR,
#     NO-OFDM, wmmrule=...); AUTO-BW is kept, it only widens channels
#   - "country XX: DFS-ETSI" loses its DFS region, wmmrule blocks and all
#     comments are removed
#   - country 00 becomes the "super region" (all channels open)
#
# The untouched upstream file is kept as db.txt.orig.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

read -r -d '' PATCH <<'AWK' || true
function num(x) {
	gsub(/^[ \t]+|[ \t]+$/, "", x)
	if (x ~ /\./) { sub(/0+$/, "", x); sub(/\.$/, "", x) }
	return x
}
function rule(s, e, bw, rest,    r) {
	r = "\t(" num(s) " - " num(e) " @ " num(bw) "), (100)"
	if (rest ~ /AUTO-BW/) r = r ", AUTO-BW"
	return r
}
function die(msg) { print "patch error: " msg > "/dev/stderr"; failed = 1; exit 1 }
BEGIN { n = 0; skip = 0; cur = 0 }
{
	sub(/\r$/, ""); sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
	if ($0 == "") { skip = 0; next }
	if ($0 ~ /^wmmrule[ \t]+[^:]*:/) { skip = 1; next }
	if ($0 ~ /^country[ \t]+/) {
		skip = 0; code = $2; sub(/:.*/, "", code)
		cur = ++n; cc[cur] = code; body[cur] = ""
		next
	}
	if (skip) next
	if (cur && $0 ~ /^\(/) {
		close1 = index($0, ")"); inner = substr($0, 2, close1 - 2); rest = substr($0, close1 + 1)
		if (split(inner, a, /[-@]/) != 3 || rest !~ /^[ \t]*,[ \t]*\(/) die("bad rule in " cc[cur] ": " $0)
		body[cur] = body[cur] (body[cur] == "" ? "" : "\n") rule(a[1], a[2], a[3], rest)
		next
	}
	die("unrecognised line: " $0)
}
END {
	if (failed) exit 1
	if (!n) die("no countries found")
	print "country 00:"
	print "\t(755 - 928 @ 2), (100)"
	print "\t(2400 - 2500 @ 100), (100)"
	print "\t(5000 - 8000 @ 1000), (100)"
	print "\t(17000 - 66000 @ 49000), (100)"
	for (i = 1; i <= n; i++) {
		if (cc[i] == "00") continue
		print ""
		print "country " cc[i] ":"
		print body[i]
	}
}
AWK

[ -f db.txt ] || { echo "db.txt not found" >&2; exit 1; }

awk "$PATCH" db.txt > "$tmp/db.txt"

# sanity: nothing but "country XX:", blank lines and "\t(a - b @ w), (100)[, AUTO-BW]"
if grep -nvE '^(country [A-Z0-9]+:|)$|^	\([0-9.]+ - [0-9.]+ @ [0-9.]+\), \(100\)(, AUTO-BW)?$' "$tmp/db.txt"; then
	echo "patched db.txt has unexpected lines" >&2
	exit 1
fi

if cmp -s "$tmp/db.txt" db.txt; then
	echo "db.txt: already patched"
else
	cp -p db.txt db.txt.orig
	cp "$tmp/db.txt" db.txt
	echo "db.txt: patched, original saved as db.txt.orig"
fi
echo "db.txt: $(grep -c '^country ' db.txt) countries, $(grep -c '^	(' db.txt) rules"

# --- rebuild -------------------------------------------------------------
# The helper scripts use "#!/usr/bin/env python", Ubuntu only ships python3.
mkdir "$tmp/bin"
ln -s "$(command -v python3)" "$tmp/bin/python"
export PATH="$tmp/bin:$PATH"

author=${REGDB_AUTHOR:-$(whoami)}
export REGDB_AUTHOR=$author
priv="$HOME/.wireless-regdb-$author.key.priv.pem"
pub="$author.key.pub.pem"
cert="$author.x509.pem"

# the signing key is generated on first run; the public key/cert must match it
if [ ! -f "$priv" ] || [ ! -f "$cert" ] ||
	[ "$(openssl rsa -in "$priv" -pubout 2>/dev/null)" != "$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)" ]; then
	echo "signing key missing or not matching $cert, regenerating"
	rm -f "$pub" "$cert"
fi

rm -f regulatory.bin regulatory.db regulatory.db.p7s sha1sum.txt

# db2bin.py (regulatory.bin) needs M2Crypto; fetch the deb without root if missing
if ! python3 -c 'import M2Crypto' 2>/dev/null; then
	m2="$HOME/.cache/regdb-m2crypto"
	mkdir -p "$m2"
	if [ ! -d "$m2/ext" ]; then
		(cd "$m2" && apt-get download python3-m2crypto && dpkg -x python3-m2crypto_*.deb ext)
	fi
	export PYTHONPATH="$m2/ext/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
	python3 -c 'import M2Crypto'
fi

make regulatory.bin regulatory.db regulatory.db.p7s sha1sum.txt

echo
ls -l regulatory.bin regulatory.db regulatory.db.p7s
sha1sum db.txt regulatory.db

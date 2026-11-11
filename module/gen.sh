#!/system/bin/sh
# Standalone config generator for the module (no app required).
# Reads $DIR/subs.list (name|url per line) and $DIR/data/subN.yaml provider files.
DIR=/data/adb/mihomo_tproxy
DATA=$DIR/data
LIST=$DIR/subs.list
SECRETFILE=$DIR/secret
CFG=$DATA/config.yaml
TMP=$DATA/.config.tmp

mkdir -p $DATA

SECRET=$(cat $SECRETFILE 2>/dev/null)
if [ -z "$SECRET" ]; then
  SECRET=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 16)
  echo "$SECRET" > $SECRETFILE
  chmod 600 $SECRETFILE
fi

USED=""
USECSV=""
i=0
if [ -f "$LIST" ]; then
  while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    f="sub${i}.yaml"
    if [ -f "$DATA/p$i.yaml" ] && grep -q "name:" "$DATA/p$i.yaml"; then
      USED="$USED sub$i"
    elif [ -f "$DATA/$f" ] && grep -q "proxies:" "$DATA/$f"; then
      # a subscription is a full Clash config; a provider must contain only the proxies list
      awk 'BEGIN{p=0} /^proxies:/{p=1; print; next} p && /^[A-Za-z0-9_-]+:/{exit} p{print}' "$DATA/$f" > "$DATA/p$i.yaml"
      if [ "$(grep -cE '(^|[[:space:]])name[[:space:]]*:' "$DATA/p$i.yaml" 2>/dev/null)" -gt 0 ]; then
        USED="$USED sub$i"
      fi
    fi
    i=$((i+1))
  done < "$LIST"
fi


# ---- merge every provider into one list, de-duplicated by proxy name ----
MERGE="$DATA/all.yaml"
cat > "$DATA/dedupe.awk" <<'AWKEOF'
# Merges proxy items from one or more Clash configs into a single provider list.
# Handles both styles:
#   - { name: 'HK 01', type: ss, ... }      (flow)
#   - name: HK 01                            (block, multi-line)
#     type: ss
# ...
BEGIN { Q1 = sprintf("%c", 39); Q2 = sprintf("%c", 34) }

function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
function trim(s)  { return rtrim(ltrim(s)) }

function unq(s,   c, p) {
  s = trim(s)
  c = substr(s, 1, 1)
  if (c == Q1 || c == Q2) {
    p = index(substr(s, 2), c)
    if (p > 0) return substr(s, 2, p - 1)
    return substr(s, 2)
  }
  return s
}

function flow_name(s,   body, i, j, c, q, seg, n, parts, k) {
  i = index(s, "{")
  if (!i) return ""
  body = substr(s, i + 1)
  i = index(body, "}")
  if (i) body = substr(body, 1, i - 1)
  n = 0; seg = ""; q = ""
  for (i = 1; i <= length(body); i++) {
    c = substr(body, i, 1)
    if (q != "") {
      seg = seg c
      if (c == q) q = ""
    } else if (c == Q1 || c == Q2) {
      q = c; seg = seg c
    } else if (c == ",") {
      n++; parts[n] = seg; seg = ""
    } else {
      seg = seg c
    }
  }
  n++; parts[n] = seg
  for (i = 1; i <= n; i++) {
    k = index(parts[i], ":")
    if (k > 0 && trim(substr(parts[i], 1, k - 1)) == "name") return unq(substr(parts[i], k + 1))
  }
  return ""
}

function block_name(lines, cnt,   i) {
  for (i = 1; i <= cnt; i++) {
    if (match(lines[i], /^[ \t]*(-[ \t]+)?name[ \t]*:/)) return unq(substr(lines[i], RSTART + RLENGTH))
  }
  return ""
}

function junk(n) { return n ~ /剩余流量|套餐|到期|过期|已用流量|重置|官网|订阅|客服|试用/ }

function flush(   i, nm) {
  if (in_item && nbuf > 0) {
    if (buf[1] ~ /^[ \t]*-[ \t]+\{/) nm = flow_name(buf[1])
    else nm = block_name(buf, nbuf)
    # mihomo needs unique names inside one provider, so de-duplicate by name
    if (!junk(nm) && (nm == "" || !(nm in seen))) {
      if (nm != "") seen[nm] = 1
      for (i = 1; i <= nbuf; i++) print buf[i]
    }
  }
  nbuf = 0; in_item = 0
}

# normalise CRLF subscriptions (no-op on LF)
{ sub(/\r$/, "") }

# each pN.yaml starts with its own proxies: header; reset grouping there
/^proxies:[ \t]*$/ { flush(); item_indent = ""; next }

{
  if (match($0, /^[ \t]*-[ \t]+/)) {
    dash = index($0, "-")
    ws = substr($0, 1, dash - 1)
    if (!in_item) {
      in_item = 1; item_indent = ws
      nbuf = 1; buf[1] = $0
      next
    }
    if (ws == item_indent) {
      flush()
      in_item = 1; item_indent = ws
      nbuf = 1; buf[1] = $0
      next
    }
    # deeper dash lines are nested lists (e.g. alpn:), keep them in the item
    nbuf++; buf[nbuf] = $0
    next
  }
  if (in_item) { nbuf++; buf[nbuf] = $0 }
}

END { flush() }
AWKEOF

{
  echo "proxies:"
  for u in $USED; do
    idx=${u#sub}
    [ -f "$DATA/p$idx.yaml" ] && cat "$DATA/p$idx.yaml"
  done | awk -f "$DATA/dedupe.awk"
} > "$MERGE"
MERGED=$(grep -cE '(^|[[:space:]])name[[:space:]]*:' "$MERGE" 2>/dev/null)

# Never fail silently: if subscriptions were picked up but nothing merged, the
# proxy list format was not understood (previously block-style nodes vanished).
if [ -n "$USED" ] && [ "$MERGED" -eq 0 ]; then
  echo "warn: subscriptions found but no proxy merged, check the proxies format" >&2
fi

USECSV=$(echo $USED | tr ' ' ',')
{
  echo "mixed-port: 7890"
  echo "allow-lan: false"
  echo "bind-address: 127.0.0.1"
  echo "mode: rule"
  echo "log-level: info"
  echo "ipv6: false"
  echo "unified-delay: true"
  echo "tcp-concurrent: true"
  echo "find-process-mode: strict"
  echo "external-controller: 127.0.0.1:9090"
  echo "secret: \"$SECRET\""
  echo "geodata-mode: false"
  echo "geo-auto-update: false"
  echo "profile:"
  echo "  store-selected: true"
  echo "  store-fake-ip: true"
  echo "sniffer:"
  echo "  enable: true"
  echo "  force-dns-mapping: true"
  echo "  parse-pure-ip: true"
  echo "  override-destination: true"
  echo "  sniff:"
  echo "    TLS:"
  echo "      ports: [443, 8443]"
  echo "    HTTP:"
  echo "      ports: [80, 8080-8880]"
  echo "    QUIC:"
  echo "      ports: [443, 8443]"
  echo "tun:"
  echo "  enable: true"
  echo "  stack: mixed"
  echo "  device: mihomo0"
  echo "  auto-route: true"
  echo "  auto-detect-interface: true"
  echo "  dns-hijack:"
  echo "    - any:53"
  echo "  mtu: 9000"
  echo "dns:"
  echo "  enable: true"
  echo "  listen: 0.0.0.0:1053"
  echo "  ipv6: false"
  echo "  enhanced-mode: fake-ip"
  echo "  fake-ip-range: 198.18.0.1/16"
  echo "  respect-rules: true"
  echo "  fake-ip-filter:"
  echo "    - \"geosite:geolocation-!cn\""
  echo "    - \"*.lan\""
  echo "    - \"*.local\""
  echo "    - \"+.msftconnecttest.com\""
  echo "    - \"+.msftncsi.com\""
  echo "  default-nameserver:"
  echo "    - 223.5.5.5"
  echo "    - 119.29.29.29"
  echo "  proxy-server-nameserver:"
  echo "    - 223.5.5.5"
  echo "    - 119.29.29.29"
  echo "  nameserver:"
  echo "    - \"https://dns.alidns.com/dns-query\""
  echo "    - \"https://doh.pub/dns-query\""
  echo "    - 223.5.5.5"
  echo "  nameserver-policy:"
  echo "    \"geosite:cn,private\": [\"https://dns.alidns.com/dns-query\", \"223.5.5.5\"]"
  echo ""
  if [ -n "$USED" ]; then
    echo "proxy-providers:"
    echo "  all:"
    echo "    type: file"
    echo "    path: ./all.yaml"
    echo "    health-check:"
    echo "      enable: true"
    echo "      url: http://www.gstatic.com/generate_204"
    echo "      interval: 300"
    echo "proxy-groups:"
    echo "  - name: 🚀 节点选择"
    echo "    type: select"
    echo "    proxies: [♻️ 自动选择, 🔯 故障转移, DIRECT]"
    echo "    use: [all]"
    echo "  - name: ♻️ 自动选择"
    echo "    type: url-test"
    echo "    url: http://www.gstatic.com/generate_204"
    echo "    interval: 300"
    echo "    tolerance: 50"
    echo "    lazy: false"
    echo "    use: [all]"
    echo "  - name: 🔯 故障转移"
    echo "    type: fallback"
    echo "    url: http://www.gstatic.com/generate_204"
    echo "    interval: 300"
    echo "    use: [all]"
    for r in "🇭🇰 香港:香港|HK|Hong Kong" "🇯🇵 日本:日本|JP|Japan|东京|大阪" "🇸🇬 新加坡:新加坡|SG|Singapore|狮城" "🇺🇸 美国:美国|US|United States|洛杉矶|圣何塞" "🇹🇼 台湾:台湾|TW|Taiwan|台北" "🇰🇷 韩国:韩国|KR|Korea|首尔" "🇬🇧 英国:英国|UK|London|伦敦" "🇩🇪 德国:德国|DE|Germany|法兰克福" "🇫🇷 法国:法国|FR|France|巴黎" "🇳🇱 荷兰:荷兰|NL|Amsterdam|阿姆斯特丹"; do
      n=${r%%:*}
      f=${r#*:}
      echo "  - name: $n"
      echo "    type: url-test"
      echo "    url: http://www.gstatic.com/generate_204"
      echo "    interval: 300"
      echo "    tolerance: 50"
      echo "    use: [all]"
      echo "    filter: \"$f\""
    done
    echo "rules:"
    echo "  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,DIRECT"
    echo "  - DOMAIN-SUFFIX,clientservices.googleapis.com,🚀 节点选择"
    echo "  - DOMAIN-SUFFIX,services.googleapis.cn,🚀 节点选择"
    echo "  - DOMAIN-SUFFIX,gvt1.com,DIRECT"
    echo "  - DOMAIN-SUFFIX,gvt2.com,DIRECT"
    echo "  - DOMAIN-SUFFIX,googleusercontent.com,🚀 节点选择"
    echo "  - DOMAIN,dl.google.com,DIRECT"
    echo "  - GEOSITE,geolocation-!cn,🚀 节点选择"
    echo "  - GEOSITE,cn,DIRECT"
    echo "  - GEOIP,CN,DIRECT"
    echo "  - MATCH,🚀 节点选择"
  else
    echo "proxies: []"
    echo "proxy-groups: []"
    echo "rules:"
    echo "  - MATCH,DIRECT"
  fi
} > "$TMP"

mv -f "$TMP" "$CFG"
chmod 644 "$CFG"
echo "config written: $CFG (providers:$USED merged:$MERGED nodes)"

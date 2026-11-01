# A declarative plan. Named sets survive chain edits and unrelated service sync.
def fams: if . == "both" then ["ipv4","ipv6"] else [.] end;
def network($f): if $f == "ipv4" then "ip" else "ip6" end;
def nfproto($f): "meta nfproto " + $f + " ";
def ports($proto;$port):
  (if $proto == "any" then "" elif $proto == "both" then "meta l4proto { tcp, udp } " else "meta l4proto " + $proto + " " end) +
  (if $port == "any" then "" else "th dport { " + ($port|split(",")|join(", ")) + " } " end);
def hexnum: ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c<=57 then $c-48 else $c-87 end));
def hexstr: if .<16 then "0123456789abcdef"[.:.+1] else (./16|floor|hexstr)+(.%16|hexstr) end;
def words($f):
  if $f=="ipv4" then split(".")|map(tonumber)|[.[0]*256+.[1],.[2]*256+.[3]]
  else
    (if contains(".") then capture("^(?<head>.*:)(?<tail>[0-9.]+)$") |
       .head + (.tail|words("ipv4")|map(hexstr)|join(":")) else . end) |
    if contains("::") then split("::")|
      (.[0]|split(":")|map(select(.!=""))) as $a | (.[1]|split(":")|map(select(.!=""))) as $b |
      ($a+([range(0;8-($a|length)-($b|length))]|map("0"))+$b)|map(hexnum)
    else split(":")|map(hexnum) end
  end;
def address_range($f):
  split("/") | (.[0]|words($f)) as $w |
  (if length==2 then .[1]|tonumber elif $f=="ipv4" then 32 else 128 end) as $prefix |
  [range(0;($w|length)) as $i | ([$prefix-16*$i,0]|max|[.,16]|min) as $bits |
    pow(2;16-$bits) as $unit | (($w[$i]/$unit|floor)*$unit) as $lo | [$lo,$lo+$unit-1]] |
  {lo:map(.[0]),hi:map(.[1])};
def successor:
  . as $w | reduce range(length-1;-1;-1) as $i ({w:$w,carry:true};
    if .carry then if .w[$i]==65535 then .w[$i]=0 else .w[$i]+=1|.carry=false end else . end) |
  if .carry then null else .w end;
def address_text($f):
  if $f=="ipv4" then [ (.[0]/256|floor), (.[0]%256), (.[1]/256|floor), (.[1]%256) ] | map(tostring)|join(".")
  else map(hexstr)|join(":") end;
# Canonical disjoint intervals are essential for safe element deltas: nft
# auto-merge otherwise hides a retained host inside a deleted broad subnet.
def addresses($source;$f):
  (if $source == "any" then [if $f == "ipv4" then "0.0.0.0/0" else "::/0" end]
   else $source | split(",") | map(select((contains(":")) == ($f == "ipv6"))) end) |
  map(address_range($f)) | sort_by(.lo) |
  reduce .[] as $r ([]; if length>0 and ($r.lo<=.[-1].hi or $r.lo<=(.[-1].hi|successor))
    then .[-1].hi=([.[-1].hi,$r.hi]|max) else .+[$r] end) |
  map(if .lo==.hi then .lo|address_text($f)
      elif all(.lo[];.==0) and all(.hi[];.==65535) then if $f=="ipv4" then "0.0.0.0/0" else "::/0" end
      else (.lo|address_text($f))+"-"+(.hi|address_text($f)) end);
def name($prefix;$id;$f): $prefix + ($id|@base64|gsub("=";"")|gsub("/";"_S")|gsub("\\+";"_P")) + (if $f == "ipv4" then "_4" else "_6" end);
def meter_timeout($r):
  ($r.rate|split("/")) as $rate |
  ({second:1,minute:60,hour:3600,day:86400}[$rate[1]] * ($r.burst//5) / ($rate[0]|tonumber) | ceil) |
  [.,60]|max|tostring;
def source_set($id;$source;$f;$expiry):
  {key:name("s_";$id;$f),value:{definition:("type " + $f + "_addr; flags interval,timeout; auto-merge;"),dynamic:false,
    elements:(addresses($source;$f)|map({value:.,expires_at:$expiry})|map(select(.expires_at==0 or .expires_at > $now)))}};
def srcmatch($id;$f): network($f) + " saddr @" + name("s_";$id;$f) + " ";
def dstmatch($destination;$f): if $destination=="any" then "" else network($f)+" daddr { "+($destination|split(",")|join(", "))+" } " end;
def endpoint($r): nfproto($r.family) + ports($r.proto;$r.port) + dstmatch($r.destination;$r.family) +
  (if $r.source=="any" then "" else network($r.family)+" saddr { "+($r.source|split(",")|join(", "))+" } " end) +
  (if ($r.interfaces.in // "")=="" then "" else "iifname "+($r.interfaces.in|tojson)+" " end);
def intervals: if .=="any" then [[1,65535]] else split(",")|map(split("-")|map(tonumber)|[.[0],.[-1]]) end;
def intersection($a;$b):
  [$a|intervals[] as $x | $b|intervals[] as $y |
    ([ $x[0],$y[0] ]|max) as $lo | ([ $x[1],$y[1] ]|min) as $hi |
    select($lo<=$hi) | if $lo==$hi then $lo|tostring else "\($lo)-\($hi)" end] | unique | join(",");
# A stale service selector is dormant, never a wildcard. Scope follows the
# owner's original public endpoints and intersects explicit manual selectors.
def effective($s;$r;$input):
  if ($r.service//"")=="" then $r.family|fams[] as $f | $r+{family:$f,destination:"any"}
  else
    $s.requirements[] as $q |
    select($q.owner==$r.service and $s.links[$q.owner].detached!=true) |
    select($r.family=="both" or $r.family==$q.family) |
    select($r.proto=="both" or $r.proto=="any" or $r.proto==$q.proto) |
    intersection($r.port;($q.original_port//$q.port)) as $port | select($port!="") |
    if $input then select($q.kind=="input") | $r+{family:$q.family,proto:$q.proto,port:$q.port,destination:$q.destination}
    else $r+{family:$q.family,proto:$q.proto,port:$port,destination:($q.original_destination//$q.destination)} end
  end;
. as $s |
[$s.requirements[] | select($s.links[.owner].detached != true)] as $req |
[$s.rules[] | . as $r | .family|fams[] as $f | source_set($r.id;$r.source;$f;($r.expires_at//0))] as $sources |
[$s.limits[] | . as $r | .family|fams[] as $f |
  source_set($r.id;$r.source;$f;0),
  (if ($r.rate//"")!="" then {key:name("m_";$r.id;$f),value:{definition:("type "+$f+"_addr; flags dynamic,timeout; timeout "+meter_timeout($r)+"s; size 65535; comment \"rate:"+$r.rate+":burst:"+(($r.burst//5)|tostring)+"\";"),dynamic:true,elements:[]}} else empty end),
  (if ($r.connections//0)>0 then {key:name("c_";$r.id;$f),value:{definition:("type "+$f+"_addr; flags dynamic; size 65535; comment \"connections:"+($r.connections|tostring)+"\";"),dynamic:true,elements:[]}} else empty end)] as $meters |
[$s.rules[] | select(.action=="deny" or .action=="allow-only") | effective($s;.;false) | . as $r | .family as $f |
  (nfproto($f)+ports($r.proto;$r.port)+dstmatch($r.destination;$f)) as $match |
  if $r.action=="deny" then $match+srcmatch($r.id;$f)+"counter drop"
  else $match+network($f)+" saddr != @"+name("s_";$r.id;$f)+" counter drop" end] as $restrictions |
[$s.limits[] | effective($s;.;false) | . as $r | .family as $f |
  (nfproto($f)+ports($r.proto;$r.port)+dstmatch($r.destination;$f)+srcmatch($r.id;$f)+
    (if $r.proto=="tcp" then "ct state new tcp flags & (syn | ack) == syn " else "" end)) as $match |
  (if ($r.rate//"")!="" then $match+"update @"+name("m_";$r.id;$f)+" { "+network($f)+" saddr limit rate over "+$r.rate+" burst "+(($r.burst//5)|tostring)+" packets } counter drop" else empty end),
  (if ($r.connections//0)>0 then $match+"add @"+name("c_";$r.id;$f)+" { "+network($f)+" saddr ct count over "+($r.connections|tostring)+" } counter drop" else empty end)] as $limits |
[$s.rules[] | select(.action=="allow" or .action=="allow-only") | effective($s;.;true) | . as $r | .family as $f |
  nfproto($f)+ports($r.proto;$r.port)+dstmatch($r.destination;$f)+srcmatch($r.id;$f)+"counter accept"] as $manual |
{sets:($sources+$meters|from_entries),chains:{
  prerouting:{definition:"type filter hook prerouting priority -150; policy accept;",rules:
    (["iifname \"lo\" accept","ct direction reply accept","fib daddr type != local accept",
      "meta l4proto 58 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept",
      "meta l4proto tcp ct state established,related accept"]+($restrictions|unique)+($limits|unique))},
  input:{definition:"type filter hook input priority 0; policy drop;",rules:
    (["iifname \"lo\" accept","ct state invalid drop","ct state established,related accept",
      "meta l4proto 58 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept",
      "meta l4proto icmp icmp type { destination-unreachable, time-exceeded, parameter-problem, echo-request } accept"]+
     $manual+[$req[]|select(.kind=="input")|endpoint(.)+"counter accept"]+
     (if $s.logging then ["limit rate 5/second burst 10 packets log prefix \"vpsctl drop: \" counter drop"] else [] end))},
  forward:{definition:"type filter hook forward priority 0; policy accept;",rules:
    [$req[]|select(.kind=="route")|
      endpoint(.)+"ct status dnat ct original proto-dst { "+(.original_port|split(",")|join(", "))+" } "+
      (if .original_destination=="any" then "" else "ct original "+network(.family)+" daddr { "+(.original_destination|split(",")|join(", "))+" } " end)+"counter accept"]}
}}

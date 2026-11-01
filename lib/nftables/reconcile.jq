# Generate one atomic batch. Only this table is named by any command.
def prefix: "inet vpsctl_firewall ";
def referenced_changes($a;$b): any($a.sets|to_entries[];
  (.key|startswith("generation_")|not) and $b.sets[.key].definition != .value.definition);
def addset($k;$s): "add set "+prefix+$k+" { "+$s.definition+" }";
def elements($op;$key;$list):
  $list[] | select($op=="delete" or .expires_at==0 or .expires_at>$now) |
  $op+" element "+prefix+$key+" { "+.value+
  (if $op=="add" and .expires_at>0 then " timeout "+((.expires_at-$now)|tostring)+"s" else "" end)+" }";
$old[0] as $old | . as $new |
(if $exists then empty else "add table inet vpsctl_firewall" end),
# Remove references before replacing/deleting any set definitions.
($old.chains|to_entries[] | .key as $key |
  select($new.chains[$key] != .value or referenced_changes($old;$new)) |
  "flush chain "+prefix+$key),
($old.chains|keys[] as $key | select($new.chains[$key]==null) | "delete chain "+prefix+$key),
($old.sets|to_entries[] | .key as $key | select($new.sets[$key].definition != .value.definition) | "delete set "+prefix+$key),
($new.sets|to_entries[] | .key as $key | .value as $set |
  if $old.sets[$key].definition != $set.definition then addset($key;$set),elements("add";$key;$set.elements)
  elif $set.dynamic then empty
  elif $old.sets[$key].elements != $set.elements then
    # nft 1.0.2 caches deleted interval endpoints within a batch. Replacing
    # just this set's elements is atomic and preserves its handle, all other
    # sets/meters and the original absolute expiry of every retained member.
    "flush set "+prefix+$key,
    elements("add";$key;$set.elements)
  else empty
  end),
($new.chains|to_entries[] | .key as $key | .value as $chain |
  (if $old.chains[$key]==null then "add chain "+prefix+$key+" { "+$chain.definition+" }" else empty end),
  (if $old.chains[$key] != $chain or referenced_changes($old;$new)
   then $chain.rules[] | "add rule "+prefix+$key+" "+. else empty end))

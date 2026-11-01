def integer: type == "number" and floor == .;
def port:
  type == "string" and (. == "any" or
    (test("^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$") and
     all(split(",")[]; split("-") | map(tonumber) |
       all(.[]; . >= 1 and . <= 65535) and .[0] <= .[-1])));
def source: type == "string" and (. == "any" or test("^[a-fA-F0-9.:/]+(,[a-fA-F0-9.:/]+)*$"));
def family: . == "both" or . == "ipv4" or . == "ipv6";
def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$");
def text: type == "string" and (test("[\u0000-\u001f\u007f]") | not);
def rule:
  type == "object" and (.id | id) and
  (.action == "allow" or .action == "deny" or .action == "allow-only") and
  (.proto == "tcp" or .proto == "udp" or .proto == "both" or .proto == "any") and
  (.port | port) and (.source | source) and (.family | family) and
  ((.service // "") | text) and ((.comment // "") | text) and
  ((.expires_at // 0) | integer and . >= 0) and
  (.proto != "any" or .port == "any");
def limit:
  type == "object" and (.id | id) and (.proto == "tcp" or .proto == "udp") and
  (.port | port) and (.source | source) and (.family | family) and
  ((.service // "") | text) and
  ((.rate // "") | type == "string" and (. == "" or test("^[1-9][0-9]{0,8}/(second|minute|hour|day)$"))) and
  ((.burst // 5) | integer and . >= 1 and . <= 1000000000) and
  ((.connections // 0) | integer and . >= 0 and . <= 1000000000) and
  (.proto == "tcp" or (.connections // 0) == 0) and
  ((.rate // "") != "" or (.connections // 0) > 0);
def requirement:
  type == "object" and (.owner | id) and (.scope | id) and
  (.kind == "input" or .kind == "route") and
  (.family == "ipv4" or .family == "ipv6") and (.proto == "tcp" or .proto == "udp") and
  (.port | port) and .port != "any" and (.source | source) and (.destination | source) and
  ((.temporary // false) | type == "boolean") and
  ((.interfaces // {in:"",out:""}) | type == "object" and
    all(.in,.out; type == "string" and test("^[A-Za-z0-9_.:-]{0,15}$"))) and
  (.kind != "route" or (has("original_port") and has("original_destination"))) and
  ((has("original_port") | not) or ((.original_port | port) and .original_port != "any")) and
  ((has("original_destination") | not) or (.original_destination | source)) and
  ((.preserve_existing // false) | type == "boolean");
type == "object" and .schema_version == 1 and
(.revision | integer and . >= 0) and (.enabled | type == "boolean") and
(.logging | type == "boolean") and (.rules | type == "array" and all(.[]; rule)) and
(.limits | type == "array" and all(.[]; limit)) and
([.rules[].id,.limits[].id] | length == (unique | length)) and
(.requirements | type == "array" and all(.[]; requirement)) and
(.links | type == "object" and all(to_entries[]; (.key | id) and
  (.value | type == "object" and (.detached | type == "boolean") and ((.scope // "") | text)))) and
(.leases | type == "object" and all(to_entries[]; (.key | id) and
  (.value | type == "object" and (.pid | integer and . > 0) and
    (.boot_id | text) and (.start_time | type == "string" and test("^[0-9]+$")))))

# shellcheck shell=bash
# Loading this module only defines functions. The installed runner uses it without
# the manager or distribution library; its entire dependency tree is pinned.

_backup_schedule_marker() { printf '# Managed by vpsctl backup schedule v1\n'; }

_backup_schedule_managed() {
    local line
    [[ -f "$1" && ! -L "$1" ]] && IFS= read -r line <"$1" &&
        [[ "$line" == "$(_backup_schedule_marker)" ]]
}

_backup_schedule_id() { [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; }

_backup_schedule_name() { printf 'vpsctl-backup-%s-%s' "$1" "$2"; }

# Numeric five-field cron plus English month/week names. No shell evaluation.
# The systemd timer and cron both wake each minute; this single matcher preserves
# cron's day-of-month/day-of-week OR semantics and the host's DST transitions.
_backup_schedule_cron() {
    python3 - "$@" <<'PY'
import datetime, json, os, re, sys, time
os.environ.pop('TZ', None)
time.tzset()
mode, expression = sys.argv[1:3]
try:
    if len(expression) > 200 or re.search(r'[^A-Za-z0-9*,/ \t-]', expression):
        raise ValueError('cron contains unsupported characters')
    fields = expression.split()
    if len(fields) != 5:
        raise ValueError('cron requires exactly five fields')
    names = [{}, {}, {}, dict(zip(['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'], range(1,13))),
             dict(zip(['SUN','MON','TUE','WED','THU','FRI','SAT'], range(7)))]
    sets = []
    for field, (low, high), mapping in zip(fields, [(0,59),(0,23),(1,31),(1,12),(0,7)], names):
        field = re.sub('[A-Za-z]+', lambda m: str(mapping.get(m[0].upper(), m[0])), field)
        values = set()
        for part in field.split(','):
            m = re.fullmatch(r'(\*|[0-9]{1,2}(?:-[0-9]{1,2})?)(?:/([0-9]{1,3}))?', part)
            if not m:
                raise ValueError('unsupported cron field: ' + field)
            base, step = m[1], int(m[2] or 1)
            if step == 0:
                raise ValueError('cron step must be positive')
            if base == '*':
                start, end = low, high
            elif '-' in base:
                start, end = map(int, base.split('-'))
            else:
                start = int(base)
                end = high if m[2] else start
            if not low <= start <= end <= high:
                raise ValueError('cron value outside field range: ' + field)
            values.update(range(start, end + 1, step))
        sets.append(values)
    sets[4] = {v % 7 for v in sets[4]}
    def day_match(d):
        dom, dow = d.day in sets[2], (d.weekday() + 1) % 7 in sets[4]
        return (dom and dow) if fields[2].startswith('*') or fields[4].startswith('*') else (dom or dow)
    now = int(sys.argv[3]) if len(sys.argv) > 3 else int(time.time())
    if mode == 'match':
        d = datetime.datetime.fromtimestamp(now)
        sys.exit(0 if d.minute in sets[0] and d.hour in sets[1] and d.month in sets[3] and day_match(d) else 1)
    if mode == 'validate':
        sys.exit(0)
    if mode != 'inspect':
        raise ValueError('unknown cron operation')
    first = datetime.datetime.fromtimestamp(now).date()
    next_time = None
    # Search by matching dates, not by every minute of eight years. Include both
    # folds of a DST hour, and reject nonexistent local clock times after mktime.
    for offset in range(366 * 8):
        date = first + datetime.timedelta(days=offset)
        if date.month not in sets[3] or not day_match(date):
            continue
        candidates = []
        for hour in sorted(sets[1]):
            for minute in sorted(sets[0]):
                wanted = (date.year, date.month, date.day, hour, minute, 0)
                for dst in (-1, 0, 1):
                    stamp = int(time.mktime(wanted + (0, 0, dst)))
                    if stamp > now and time.localtime(stamp)[:6] == wanted:
                        candidates.append(stamp)
        if candidates:
            next_time = datetime.datetime.fromtimestamp(min(candidates)).astimezone().isoformat()
            break
    zone = os.path.realpath('/etc/localtime')
    if '/zoneinfo/' in zone:
        zone = zone.split('/zoneinfo/', 1)[1]
    else:
        zone = '/'.join(time.tzname)
    print(json.dumps({'cron': ' '.join(fields), 'timezone': zone, 'next_run': next_time}))
except (ValueError, OverflowError) as error:
    print('Invalid schedule: ' + str(error), file=sys.stderr)
    sys.exit(2)
PY
}

_backup_schedule_backend() {
    local init=''
    if [[ "${VPSCTL_TESTING:-0}" == 1 && -n "${BACKUP_TEST_SCHEDULER:-}" ]]; then
        case "$BACKUP_TEST_SCHEDULER" in systemd|cron) printf '%s\n' "$BACKUP_TEST_SCHEDULER"; return ;; esac
        return 3
    fi
    [[ ! -r /proc/1/comm ]] || IFS= read -r init </proc/1/comm
    if [[ "$init" == systemd ]] && command -v systemctl >/dev/null 2>&1; then
        printf 'systemd\n'
    elif command -v crontab >/dev/null 2>&1 && { command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; }; then
        printf 'cron\n'
    else
        return 3
    fi
}

_backup_schedule_cron_running() {
    local file name
    for file in /proc/[0-9]*/comm; do
        IFS= read -r name <"$file" 2>/dev/null || continue
        [[ "$name" != cron && "$name" != crond ]] || return 0
    done
    return 1
}

_backup_schedule_start_cron() {
    local name
    [[ "${VPSCTL_TESTING:-0}" != 1 ]] || return 0
    _backup_schedule_cron_running && return 0
    for name in cron crond cronie; do
        [[ -x "/etc/init.d/$name" ]] || continue
        if command -v rc-service >/dev/null 2>&1 && [[ -d /run/openrc ]]; then
            rc-service "$name" start || return 20
            rc-update add "$name" default || return 20
        else
            "/etc/init.d/$name" start || return 20
        fi
        _backup_schedule_cron_running && return 0
    done
    vps_cmd_error '已检测到 cron 工具，但没有运行的 cron daemon；无法启用调度'
    return 3
}

_backup_schedule_crontab_read() {
    local output status=0
    output="$(LC_ALL=C crontab -l 2>&1)" || status=$?
    if ((status == 0)); then printf '%s' "$output"; return 0; fi
    if [[ "$output" == *'no crontab for '* || "$output" == *'no crontab for user '* ]]; then return 0; fi
    vps_cmd_error "无法读取 crontab：$output"
    return 20
}

_backup_schedule_crontab_update() {
    local type="$1" plan="$2" action="$3" content line temporary quoted
    local marker="# vpsctl-backup-schedule:v1:$type:$plan"
    content="$(_backup_schedule_crontab_read)" || return $?
    temporary="$(mktemp "$BACKUP_STATE/schedules/.crontab.XXXXXXXX")" || return 20
    chmod 0600 "$temporary" || return 20
    while IFS= read -r line; do
        [[ "$line" != *" $marker" ]] || continue
        [[ -n "$line" ]] && printf '%s\n' "$line" >>"$temporary"
    done <<<"$content"
    if [[ "$action" == enable ]]; then
        quoted="$(python3 - "$BACKUP_LIBEXEC/$type/runner" "$plan" <<'PY'
import shlex, sys
print(' '.join(shlex.quote(value) for value in sys.argv[1:]).replace('%', r'\%'))
PY
        )" || { rm -f -- "$temporary"; return 20; }
        printf '* * * * * /bin/bash %s %s\n' "$quoted" "$marker" >>"$temporary"
    fi
    if ! crontab "$temporary"; then rm -f -- "$temporary"; return 20; fi
    rm -f -- "$temporary"
}

_backup_schedule_atomic() {
    local path="$1" mode="${2:-0600}" temporary
    vps_cmd_require_no_symlink_components "$path" || return $?
    temporary="$(mktemp "${path%/*}/.schedule.XXXXXXXX")" || return 20
    if ! cat >"$temporary" || ! chmod "$mode" "$temporary" || ! mv -f -- "$temporary" "$path"; then
        rm -f -- "$temporary"
        return 20
    fi
}

_backup_schedule_files() (
    local root="$1" type="$2" bundle
    [[ "$type" == system ]] && bundle=system-backup || bundle=system-backup-docker
    [[ -f "$root/lib/registry.sh" && ! -L "$root/lib/registry.sh" ]] || return 3
    # The same-version registry is the only source of private-module filenames.
    # shellcheck disable=SC1091
    source "$root/lib/registry.sh"
    printf '%s\n' VERSION lib/command.sh lib/environment.sh lib/ui.sh lib/registry.sh
    vps_registry_bundle_files shared-backup || return $?
    vps_registry_bundle_files "$bundle"
)

_backup_schedule_launcher() {
    local type="$1"
    printf '#!/usr/bin/env bash\n'
    _backup_schedule_marker
    printf 'set -Eeuo pipefail\numask 077\n'
    printf 'export BACKUP_ETC=%q BACKUP_STATE=%q BACKUP_LIBEXEC=%q\n' "$BACKUP_ETC" "$BACKUP_STATE" "$BACKUP_LIBEXEC"
    printf 'export VPSCTL_TESTING=%q VPSCTL_SYSTEM_ROOT=%q\n' "${VPSCTL_TESTING:-0}" "${VPSCTL_SYSTEM_ROOT:-}"
    printf 'type=%q\n' "$type"
    cat <<'SH'
export VPSCTL_NON_INTERACTIVE=1 VPSCTL_ASSUME_YES=1 VPSCTL_INSTALL_DEPS=0 VPSCTL_DRY_RUN=0
unset TZ VPSCTL_DISTRIBUTED
[[ $# == 1 && "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || exit 2
base="$BACKUP_LIBEXEC/$type"
# Hold the tree lock only while pinning the version, permitting upgrades during
# a long backup. The version lease remains open across every child process.
exec {tree_lock}<"$base/.runtime.lock"
flock -s "$tree_lock"
version="$(readlink -f -- "$base/current")"
[[ "$version" == "$base/versions/"* && -f "$version/.managed" && -f "$version/.lease" ]] || exit 10
exec {lease}<"$version/.lease"
flock -s "$lease"
flock -u "$tree_lock"
exec {tree_lock}<&-
# shellcheck disable=SC1091
source "$version/lib/backup/schedule.sh"
backup_schedule_runner "$version" "$type" "$1"
SH
}

_backup_schedule_runtime_install() (
    local type="$1" root="${BACKUP_PROJECT_ROOT:-$VPSCTL_PROJECT_ROOT}" file list entry hash stage='' base version lock
    local -a files=()
    base="$BACKUP_LIBEXEC/$type"
    [[ "$type" == system ]] && entry=commands/system/backup.sh || entry=commands/system/backup-docker.sh
    list="$(_backup_schedule_files "$root" "$type")" || { vps_cmd_error '运行文件清单不可用'; return 3; }
    mapfile -t files <<<"$list"
    [[ "$list" == *"$entry"* && "$list" == *lib/backup/schedule.sh* && "$list" == *lib/backup.sh* ]] || return 10
    for file in "${files[@]}"; do
        case "$file" in
            VERSION|lib/command.sh|lib/environment.sh|lib/ui.sh|lib/registry.sh|lib/backup.sh|lib/backup/*.sh|"$entry"|"${entry%.sh}/"*.sh|"${entry%.sh}/"*.py) ;;
            *) vps_cmd_error "备份包包含不允许的运行文件：$file"; return 10 ;;
        esac
        [[ "$file" != *..* && -f "$root/$file" ]] || return 10
        vps_cmd_require_no_symlink_components "$root/$file" || return $?
    done
    hash="$(cd -- "$root" && sha256sum -- "${files[@]}" | sha256sum)" || return 20
    hash="${hash%% *}"
    IFS= read -r version <"$root/VERSION" || [[ -n "$version" ]] || return 10
    [[ "$version" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || return 10
    version="$version-${hash:0:24}"
    backup_private_dir "$BACKUP_LIBEXEC" "$base" "$base/versions" || return $?
    vps_cmd_require_no_symlink_components "$base/.runtime.lock" || return $?
    umask 077
    exec {lock}>"$base/.runtime.lock"
    flock -x "$lock" || return 20
    if [[ ! -e "$base/versions/$version" ]]; then
        stage="$(mktemp -d "$base/versions/.stage.XXXXXXXX")" || return 20
        trap '[[ -z "$stage" ]] || rm -rf -- "$stage"' EXIT
        for file in "${files[@]}"; do
            if [[ "$file" == */* ]]; then install -d -m 0700 -- "$stage/${file%/*}" || return 20; fi
            cp -- "$root/$file" "$stage/$file" || return 20
            chmod 0600 "$stage/$file" || return 20
            cmp -s -- "$root/$file" "$stage/$file" || return 20
        done
        # Verify the whole snapshot too: a concurrently changed source must not
        # produce a version assembled from different release contents.
        [[ "$(cd -- "$stage" && sha256sum -- "${files[@]}" | sha256sum)" == "$hash  -" ]] || return 20
        _backup_schedule_marker >"$stage/.managed"
        : >"$stage/.lease"
        mv -- "$stage" "$base/versions/$version" || return 20
        stage=''
    else
        _backup_schedule_managed "$base/versions/$version/.managed" || return 10
        [[ "$(cd -- "$base/versions/$version" && sha256sum -- "${files[@]}" | sha256sum)" == "$hash  -" ]] || return 10
    fi
    if [[ -e "$base/runner" ]] && ! _backup_schedule_managed "$base/runner"; then
        # runner starts with a shebang; its marker is checked separately.
        [[ "$(sed -n '2p' "$base/runner")" == "$(_backup_schedule_marker)" && ! -L "$base/runner" ]] || return 10
    fi
    _backup_schedule_launcher "$type" | _backup_schedule_atomic "$base/runner" 0700 || return $?
    [[ ! -e "$base/current" || -L "$base/current" ]] || return 10
    ln -s "versions/$version" "$base/.current.$$" || return 20
    if ! mv -Tf -- "$base/.current.$$" "$base/current"; then rm -f -- "$base/.current.$$"; return 20; fi
    # Retention cleanup cannot invalidate an already committed new version.
    _backup_schedule_prune_locked "$base" "$version" || vps_cmd_warning '旧运行版本未完全清理；当前版本已完整安装'
)

# Caller holds the tree lock. A busy version is retained; no task loses a module
# even if it loads that module long after an upgrade or feature uninstall.
_backup_schedule_prune_locked() {
    local base="$1" keep="${2:-}" directory lease
    for directory in "$base"/versions/*; do
        [[ -d "$directory" && ! -L "$directory" && "${directory##*/}" != "$keep" ]] || continue
        _backup_schedule_managed "$directory/.managed" || continue
        [[ -f "$directory/.lease" && ! -L "$directory/.lease" ]] || continue
        (
            exec {lease}<"$directory/.lease"
            flock -xn "$lease" || exit 0
            rm -rf -- "$directory"
        ) || return 20
    done
}

_backup_schedule_unit_quote() {
    local value="$1"
    value="${value//\\/\\\\}" value="${value//\"/\\\"}" value="${value//%/%%}" value="${value//\$/\$\$}"
    printf '"%s"' "$value"
}

_backup_schedule_systemd_check() {
    local type="$1" plan="$2" directory name file
    name="$(_backup_schedule_name "$type" "$plan")"
    directory="$(vps_cmd_system_path /etc/systemd/system)" || return $?
    vps_cmd_require_no_symlink_components "$directory" || return $?
    for file in "$directory/$name.service" "$directory/$name.timer"; do
        [[ ! -e "$file" && ! -L "$file" ]] || _backup_schedule_managed "$file" || {
            vps_cmd_error "拒绝覆盖非受管 unit：$file"; return 10;
        }
    done
}

_backup_schedule_systemd_enable() {
    local type="$1" plan="$2" directory name
    name="$(_backup_schedule_name "$type" "$plan")"
    directory="$(vps_cmd_system_path /etc/systemd/system)" || return $?
    _backup_schedule_systemd_check "$type" "$plan" || return $?
    install -d -m 0755 -- "$directory" || return 20
    {
        _backup_schedule_marker
        printf '[Unit]\nDescription=vpsctl %s backup schedule %s\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nUMask=0077\n' "$type" "$plan"
        printf 'ExecStart=/bin/bash %s %s\n' "$(_backup_schedule_unit_quote "$BACKUP_LIBEXEC/$type/runner")" "$(_backup_schedule_unit_quote "$plan")"
        printf 'TimeoutStartSec=infinity\n'
    } | _backup_schedule_atomic "$directory/$name.service" 0644 || return $?
    {
        _backup_schedule_marker
        printf '[Unit]\nDescription=vpsctl backup minute matcher %s\n\n[Timer]\nOnCalendar=*-*-* *:*:00\nOnBootSec=30s\nAccuracySec=1s\nPersistent=true\nUnit=%s.service\n\n[Install]\nWantedBy=timers.target\n' "$plan" "$name"
    } | _backup_schedule_atomic "$directory/$name.timer" 0644 || return $?
    systemctl daemon-reload && systemctl enable --now "$name.timer" || return 20
}

_backup_schedule_disable() {
    local type="$1" plan="$2" directory name file changed=0 content marker
    name="$(_backup_schedule_name "$type" "$plan")"
    directory="$(vps_cmd_system_path /etc/systemd/system)" || return $?
    if _backup_schedule_managed "$directory/$name.timer"; then
        if [[ "$(_backup_schedule_backend 2>/dev/null || true)" == systemd ]]; then
            systemctl disable --now "$name.timer" || return 20
        fi
    fi
    for file in "$directory/$name.timer" "$directory/$name.service"; do
        _backup_schedule_managed "$file" || continue
        rm -f -- "$file" || return 20
        changed=1
    done
    if ((changed)) && [[ "$(_backup_schedule_backend 2>/dev/null || true)" == systemd ]]; then
        systemctl daemon-reload || return 20
    fi
    if command -v crontab >/dev/null 2>&1; then
        marker="# vpsctl-backup-schedule:v1:$type:$plan"
        content="$(_backup_schedule_crontab_read)" || return $?
        if [[ "$content" == *" $marker"* ]]; then
            backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/schedules" || return $?
            _backup_schedule_crontab_update "$type" "$plan" disable || return $?
        fi
    fi
    file="$BACKUP_ETC/schedules/$type-$plan.json"
    if [[ -f "$file" && ! -L "$file" ]] && jq -e '.managed_by == "vpsctl-backup-schedule-v1"' "$file" >/dev/null; then
        local json
        json="$(jq '.enabled = false' "$file")" || return 10
        backup_atomic_json "$file" "$json" || return $?
    fi
}

_backup_schedule_status() {
    local type="$1" plan="$2" file json cron_info='{}' enabled=false active=false content name directory
    file="$BACKUP_ETC/schedules/$type-$plan.json"
    command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
        vps_cmd_error '查看调度需要 jq 和 python3；status 不会安装依赖'; return 3;
    }
    json='{}'
    if [[ -e "$file" ]]; then
        backup_private_file "$file" || return $?
        json="$(cat -- "$file")" || return 20
        jq -e --arg type "$type" --arg plan "$plan" '.managed_by == "vpsctl-backup-schedule-v1" and .type == $type and .plan == $plan and .schema_version == 1' >/dev/null <<<"$json" || return 10
        cron_info="$(_backup_schedule_cron inspect "$(jq -r .cron <<<"$json")")" || return $?
    fi
    name="$(_backup_schedule_name "$type" "$plan")"
    directory="$(vps_cmd_system_path /etc/systemd/system)" || return $?
    case "$(jq -r '.backend // "none"' <<<"$json")" in
        systemd)
            if _backup_schedule_managed "$directory/$name.timer" && command -v systemctl >/dev/null 2>&1; then
                systemctl is-enabled --quiet "$name.timer" 2>/dev/null && enabled=true
                systemctl is-active --quiet "$name.timer" 2>/dev/null && active=true
            fi ;;
        cron)
            if command -v crontab >/dev/null 2>&1; then
                content="$(_backup_schedule_crontab_read)" || return $?
                [[ "$content" != *" # vpsctl-backup-schedule:v1:$type:$plan"* ]] || enabled=true
                if [[ "$enabled" == true ]] && _backup_schedule_cron_running; then active=true; fi
            fi ;;
    esac
    json="$(jq -n --arg type "$type" --arg plan "$plan" --argjson saved "$json" --argjson timing "$cron_info" \
        --argjson enabled "$enabled" --argjson active "$active" \
        '{schema_version:1,type:$type,plan:$plan,backend:($saved.backend // "none"),enabled:$enabled,active:$active,
          cron:($saved.cron // null),timezone:($saved.timezone // null),host_timezone:($timing.timezone // null),
          timezone_changed:($saved.timezone != null and $saved.timezone != $timing.timezone),
          next_run:(if $enabled then $timing.next_run else null end),resolution:"one-minute",catch_up:false}')" || return 20
    if [[ "${BACKUP_JSON:-0}" == 1 ]]; then printf '%s\n' "$json"; return; fi
    printf '%s\n' "$json" | jq -r '"计划: \(.type)/\(.plan)\n后端: \(.backend)\n启用: \(.enabled)\n运行: \(.active)\n时间表: \(.cron // "未配置")\n主机时区: \(.host_timezone // "未知")\n下次执行: \(.next_run // "无")\n每分钟匹配；错过的备份不会自动补跑。"'
    [[ "$(jq -r .timezone_changed <<<"$json")" != true ]] || vps_cmd_warning '主机时区已改变，计划现按新的主机时区执行'
}

backup_schedule() (
    local type="${1:-}" plan="${2:-}" action="${3:-}" expression="${4:-}" backend info json repo lock file
    (($# >= 3 && $# <= 4)) && [[ "$type" == system || "$type" == docker ]] && backup_valid_id "$plan" || return 2
    case "$action" in enable) ;; disable|status) [[ -z "$expression" ]] || return 2 ;; *) return 2 ;; esac
    [[ "$action" != status ]] || { _backup_schedule_status "$type" "$plan"; return $?; }
    if [[ "$action" == enable ]]; then
        [[ -n "$expression" ]] || { [[ "$type" == system ]] && expression='0 3 * * 0' || expression='0 3 * * *'; }
        backup_ensure_tools python3 jq || return $?
        if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
            vps_cmd_info '演练：依赖安装后将检查计划和 cron，再准备独立运行版本；当前不写入任何文件'
            return 0
        fi
        info="$(_backup_schedule_cron inspect "$expression")" || return $?
        backup_plan_load "$plan" "$type" || return $?
        [[ "$(jq -r .next_run <<<"$info")" != null ]] || { vps_cmd_error '未来八年没有匹配的执行日期'; return 2; }
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：$action $type/$plan 调度${expression:+（$expression，主机时区，每分钟匹配）}；不写入运行文件或调度配置"
        return 0
    fi
    vps_cmd_require_root || return $?
    backup_ensure_tools jq python3 flock sha256sum || return $?
    backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/schedules" || return $?
    umask 077
    vps_cmd_require_no_symlink_components "$BACKUP_STATE/schedules/.configuration.lock" || return $?
    exec {lock}>"$BACKUP_STATE/schedules/.configuration.lock"
    flock -x "$lock" || return 20
    [[ "$action" != disable ]] || { _backup_schedule_disable "$type" "$plan"; return $?; }
    backend="$(_backup_schedule_backend)" || {
        backup_ensure_tools crontab || return $?
        backend="$(_backup_schedule_backend)" || { vps_cmd_error '未检测到 systemd 或受支持的 cron daemon'; return 3; }
    }
    [[ "$backend" != cron ]] || _backup_schedule_start_cron || return $?
    [[ "$backend" != systemd ]] || _backup_schedule_systemd_check "$type" "$plan" || return $?
    repo="$(jq -r .repo <<<"$BACKUP_PLAN_JSON")" || return 10
    backup_repo_probe "$repo" || return $?
    backup_private_dir "$BACKUP_ETC" "$BACKUP_ETC/schedules" || return $?
    file="$BACKUP_ETC/schedules/$type-$plan.json"
    if [[ -e "$file" ]]; then
        backup_private_file "$file" || return $?
        jq -e '.managed_by == "vpsctl-backup-schedule-v1"' "$file" >/dev/null || return 10
    fi
    _backup_schedule_runtime_install "$type" || return $?
    json="$(jq -n --arg type "$type" --arg plan "$plan" --arg backend "$backend" --argjson info "$info" \
        '$info + {schema_version:1,managed_by:"vpsctl-backup-schedule-v1",type:$type,plan:$plan,backend:$backend,enabled:true}')" || return 20
    backup_atomic_json "$file" "$json" || return $?
    if [[ "$backend" == systemd ]]; then
        _backup_schedule_systemd_enable "$type" "$plan" || return $?
    else
        _backup_schedule_crontab_update "$type" "$plan" enable || return $?
    fi
    vps_cmd_success "已启用 $type/$plan：$(jq -r .cron <<<"$info")；主机时区 $(jq -r .timezone <<<"$info")；下次 $(jq -r .next_run <<<"$info")"
)

_backup_schedule_event() {
    local directory="$1" event="$2" detail="${3:-}" json
    json="$(jq -nc --arg time "$(date -u +%FT%TZ)" --arg event "$event" --arg detail "$detail" \
        '{schema_version:1,time:$time,event:$event,detail:$detail}')" || return 20
    printf '%s\n' "$json" >>"$directory/events.jsonl"
}

backup_schedule_runner() (
    local version="$1" type="$2" plan="$3" config directory lock expression tick last=0 previous=0 entry status=0 saved_zone current_zone
    [[ "$type" == system || "$type" == docker ]] && _backup_schedule_id "$plan" || return 2
    config="$BACKUP_ETC/schedules/$type-$plan.json"
    [[ -f "$config" && ! -L "$config" ]] || return 3
    jq -e --arg type "$type" --arg plan "$plan" '.schema_version == 1 and .managed_by == "vpsctl-backup-schedule-v1" and .type == $type and .plan == $plan and .enabled == true' "$config" >/dev/null || return 0
    directory="$BACKUP_STATE/schedules/$type-$plan"
    umask 077
    mkdir -p -- "$directory" || return 20
    [[ ! -L "$directory" && ! -L "$directory/run.lock" ]] || return 10
    exec {lock}>"$directory/run.lock"
    if ! flock -xn "$lock"; then _backup_schedule_event "$directory" overlap 'previous scheduled task still running'; return 0; fi
    expression="$(jq -r .cron "$config")" || return 10
    _backup_schedule_cron validate "$expression" || return $?
    tick="$(date +%s)"; tick=$((tick / 60))
    if [[ -r "$directory/last-tick" ]]; then IFS= read -r previous <"$directory/last-tick" || true; fi
    [[ "$previous" =~ ^[0-9]+$ ]] || return 10
    ((previous == 0 || tick - previous <= 2)) || _backup_schedule_event "$directory" missed-ticks "$previous..$tick; no automatic catch-up"
    printf '%s\n' "$tick" >"$directory/.last-tick.$$" && mv -f -- "$directory/.last-tick.$$" "$directory/last-tick" || return 20
    [[ "$type" == system ]] && entry=commands/system/backup.sh || entry=commands/system/backup-docker.sh
    # Recovery is plan-scoped and the entry owns the shared capture lock. Never
    # bypass it here: manual backups and the other backup type use the same lock.
    bash "$version/$entry" recover-interrupted "$plan" --non-interactive --yes || status=$?
    if ((status)); then _backup_schedule_event "$directory" recovery-failed "$status"; return "$status"; fi
    if ! _backup_schedule_cron match "$expression" "$((tick * 60))"; then return 0; fi
    if [[ -r "$directory/last-attempt-minute" ]]; then IFS= read -r last <"$directory/last-attempt-minute" || true; fi
    [[ "$last" =~ ^[0-9]+$ ]] || return 10
    ((last != tick)) || return 0
    printf '%s\n' "$tick" >"$directory/.last-attempt.$$" && mv -f -- "$directory/.last-attempt.$$" "$directory/last-attempt-minute" || return 20
    saved_zone="$(jq -r .timezone "$config")"
    current_zone="$(_backup_schedule_cron inspect "$expression" | jq -r .timezone)" || return 20
    [[ "$saved_zone" == "$current_zone" ]] || _backup_schedule_event "$directory" timezone-changed "$saved_zone -> $current_zone"
    _backup_schedule_event "$directory" started "${version##*/}" || return $?
    bash "$version/$entry" run "$plan" --non-interactive --yes || status=$?
    _backup_schedule_event "$directory" finished "$status" || return $?
    return "$status"
)

backup_schedule_uninstall() (
    local type="${1:-}" file plan base lock configuration_lock
    (($# == 1)) && [[ "$type" == system || "$type" == docker ]] || return 2
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then vps_cmd_info "演练：卸载 $type 受管调度与未使用的运行版本；保留配置、凭据和备份"; return 0; fi
    vps_cmd_require_root || return $?
    command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || return 3
    backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/schedules" || return $?
    vps_cmd_require_no_symlink_components "$BACKUP_STATE/schedules/.configuration.lock" || return $?
    umask 077
    exec {configuration_lock}>"$BACKUP_STATE/schedules/.configuration.lock"
    flock -x "$configuration_lock" || return 20
    for file in "$BACKUP_ETC/schedules/$type-"*.json; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        jq -e --arg type "$type" '.managed_by == "vpsctl-backup-schedule-v1" and .type == $type' "$file" >/dev/null || continue
        plan="$(jq -r .plan "$file")" || return 10
        _backup_schedule_id "$plan" || return 10
        _backup_schedule_disable "$type" "$plan" || return $?
    done
    base="$BACKUP_LIBEXEC/$type"
    [[ -d "$base" && ! -L "$base" ]] || return 0
    [[ -f "$base/.runtime.lock" && ! -L "$base/.runtime.lock" ]] || return 10
    exec {lock}>"$base/.runtime.lock"
    flock -x "$lock" || return 20
    [[ ! -L "$base/current" ]] || rm -f -- "$base/current" || return 20
    if [[ -f "$base/runner" && ! -L "$base/runner" && "$(sed -n '2p' "$base/runner")" == "$(_backup_schedule_marker)" ]]; then
        rm -f -- "$base/runner" || return 20
    fi
    _backup_schedule_prune_locked "$base"
)

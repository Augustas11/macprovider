set -euo pipefail
root="$1"; cur="$2"; prev_b64="$3"; unit="$4"; helper="$5"; expected="$6"; window="$7"
# The exact prior .previous-target bytes (base64); restore writes them
# unchanged, and an empty file makes it remove .previous-target.
prior_window="$(dirname "$window")/prior-window"
if [ "$prev_b64" = "__EMPTY__" ]; then : > "$prior_window"; else printf '%s' "$prev_b64" | base64 -d > "$prior_window"; fi
python3 "$helper" validate || { echo "rollback: lock validation failed; not mutating" >&2; exit 1; }
exec 8</run/lock/macprovider-pearl-updater.lock || { echo "rollback: cannot open updater lock; not mutating" >&2; exit 1; }
flock -n 8 || { echo "rollback: Pearl updater lock held; not mutating" >&2; exit 1; }
exec 9</opt/macprovider/.coordinator-deploy.lock || { echo "rollback: cannot open coordinator lock; not mutating" >&2; exit 1; }
flock -n 9 || { echo "rollback: coordinator deploy lock held; not mutating" >&2; exit 1; }
live="$(readlink "$root/current")" || { echo "rollback: cannot read current; not mutating" >&2; exit 1; }
live="${live#./}"
if [ "$live" = "$expected" ]; then
  ln -sfn "$cur" "$root/.current.rollback"
  mv -Tf "$root/.current.rollback" "$root/current"
  window_rc=0
  python3 -I "$window" restore --root "$root" --from-file "$prior_window" --expect-current "$cur" || window_rc=$?
  pid="$(systemctl show -p MainPID --value "$unit")"
  [ -n "$pid" ] && [ "$pid" != "0" ] && kill -HUP "$pid" || true
  [ "$window_rc" -eq 0 ] || { echo "rollback: rolled back current to $cur but .previous-target restore failed" >&2; exit 1; }
  echo "rolled back to $cur"
elif [ "$live" = "$cur" ]; then
  python3 -I "$window" restore --root "$root" --from-file "$prior_window" --expect-current "$cur"
  echo "rollback: restored .previous-target only (current still $cur)"
else
  echo "rollback: current is $live, not $expected; not mutating"
  exit 0
fi

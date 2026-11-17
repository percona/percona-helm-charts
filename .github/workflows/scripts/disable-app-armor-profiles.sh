#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu enables AppArmor and loads the mysqld profile when its MySQL package
# is installed, as on GitHub's Ubuntu runners. That profile uses Ubuntu paths,
# not the Percona images' /etc/my.cnf and /usr/share/percona-* layout.
# In our Azure reproduction it attached to /usr/sbin/mysqld inside Minikube
# even with container AppArmor Unconfined, denying config and errmsg.sys reads.
# my_print_defaults could read those files because it is a different executable.
# Unload only this host profile on disposable CI runners; keep other profiles
# and seccomp unchanged. This is not a production configuration.
main() {
  if [[ -n "${ACT:-}" ]]; then
    echo "Skipping host AppArmor changes under act"
    return
  fi

  local profile=/etc/apparmor.d/usr.sbin.mysqld profiles
  if [[ ! -f "$profile" ]]; then
    echo "No host MySQL AppArmor profile file"
    return
  fi
  profiles="$(sudo cat /sys/kernel/security/apparmor/profiles)"
  if grep -Eq '^(/usr/sbin/mysqld|mysqld) \(' <<< "$profiles"; then
    sudo apparmor_parser -R "$profile"
    echo "Unloaded host MySQL AppArmor profile for Percona tests"
  else
    echo "Host MySQL AppArmor profile is not loaded"
  fi
}

main "$@"

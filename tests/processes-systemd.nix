{ nixpkgs, tarball, buildFun }:

let
  dysnomia = buildFun {
    pkgs = import nixpkgs {};
    inherit tarball;
    jobTemplate = "systemd";
    enableLegacy = true;
  };
in
with import nixpkgs {};
with import "${nixpkgs}/nixos/lib/testing.nix" { system = builtins.currentSystem; };

let
  # Test services

  wrapper = import ./deployment/wrapper.nix {
    inherit stdenv;
  };

  wrapper_unprivileged = import ./deployment/wrapper-unprivileged.nix {
    inherit stdenv;
  };

  process = import ./deployment/process.nix {
    inherit stdenv;
  };

  process_unprivileged = import ./deployment/process-unprivileged.nix {
    inherit stdenv;
  };

  process_socketactivation = import ./deployment/process-socketactivation.nix {
    inherit stdenv;
  };
in
makeTest {
  nodes = {
    machine = {config, pkgs, ...}:

    {
      virtualisation.memorySize = 1024;
      virtualisation.diskSize = 4096;

      environment.systemPackages = [ dysnomia pkgs.netcat ];

      system.activationScripts.dysnomia = ''
        mkdir -p /etc/systemd-mutable/system
        if [ ! -f /etc/systemd-mutable/system/dysnomia.target ]
        then
            ( echo "[Unit]"
              echo "Description=Services that are activated and deactivated by Dysnomia"
              echo "After=final.target"
            ) > /etc/systemd-mutable/system/dysnomia.target
        fi
      '';
    };
  };

  testScript =
    ''
      startAll;

      # Check if Dysnomia systemd target exists. It should exist, or the
      # remaining tests will not work reliably.
      $machine->mustSucceed("[ -f /etc/systemd-mutable/system/dysnomia.target ]");

      # Test wrapper module. Here we invoke the wrapper
      # of a certain service. On activation it writes a state file in
      # the temp folder.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type wrapper --operation activate --component ${wrapper} --environment");
      $machine->mustSucceed("sleep 5; [ \"\$(cat /tmp/wrapper.state)\" = \"wrapper active\" ]");
      $machine->mustSucceed("[ \"\$(stat -c %U /tmp/wrapper.state)\" = \"root\" ]");

      # Activate again. This operation should succeed as it is idempotent.
      $machine->mustSucceed("dysnomia --type wrapper --operation activate --component ${wrapper} --environment");
      $machine->mustSucceed("sleep 5; [ \"\$(cat /tmp/wrapper.state)\" = \"wrapper active\" ]");
      $machine->mustSucceed("[ \"\$(stat -c %U /tmp/wrapper.state)\" = \"root\" ]");

      # Test wrapper module. Here we invoke the lock
      # operation of a certain service. It should write a lock file
      # into the temp dir and it should be owned by root.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type wrapper --operation lock --component ${wrapper} --environment");
      $machine->mustSucceed("[ \"\$(stat -c %U /tmp/wrapper.lock)\" = \"root\" ]");

      # Test wrapper module. Here we invoke the unlock
      # operation of a certain service. The lock file should be removed.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type wrapper --operation unlock --component ${wrapper} --environment");
      $machine->mustSucceed("[ ! -f /tmp/wrapper.lock ]");

      # Deactivate the wrapper script. We also check whether the file created
      # on activation is owned by root.
      # This test should succeed.
      $machine->mustSucceed("dysnomia --type wrapper --operation deactivate --component ${wrapper} --environment");
      $machine->mustSucceed("sleep 5; [ ! -f /tmp/wrapper.state ]");

      # Deactivate again. This operation should succeed as it is idempotent.
      $machine->mustSucceed("dysnomia --type wrapper --operation deactivate --component ${wrapper} --environment");
      $machine->mustSucceed("sleep 5; [ ! -f /tmp/wrapper.state ]");

      # Test wrapper module. Here we invoke the wrapper
      # of a certain service. On activation it writes a state file in
      # the temp folder.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type wrapper --operation activate --component ${wrapper_unprivileged} --environment");
      $machine->mustSucceed("sleep 5; [ \"\$(cat /tmp/wrapper.state)\" = \"wrapper active\" ]");
      $machine->mustSucceed("[ \"\$(stat -c %U /tmp/wrapper.state)\" = \"unprivileged\" ]");

      # Activate again. This test should succeed as it is idempotent.
      $machine->mustSucceed("dysnomia --type wrapper --operation activate --component ${wrapper_unprivileged} --environment");
      $machine->mustSucceed("sleep 5; [ \"\$(cat /tmp/wrapper.state)\" = \"wrapper active\" ]");
      $machine->mustSucceed("[ \"\$(stat -c %U /tmp/wrapper.state)\" = \"unprivileged\" ]");

      # Test wrapper module. Here we invoke the lock
      # operation of a certain service. It should write a lock file
      # into the temp dir and it should be owned by an unprivileged user.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type wrapper --operation lock --component ${wrapper_unprivileged} --environment");
      $machine->mustSucceed("[ \"\$(stat -c %U /tmp/wrapper.lock)\" = \"unprivileged\" ]");

      # Test wrapper module. Here we invoke the unlock
      # operation of a certain service. The lock file should be removed.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type wrapper --operation unlock --component ${wrapper_unprivileged} --environment");
      $machine->mustSucceed("[ ! -f /tmp/wrapper.lock ]");

      # Deactivate the wrapper script. We also check whether the file created
      # on activation is owned by the unprivileged user.
      # This test should succeed.
      $machine->mustSucceed("dysnomia --type wrapper --operation deactivate --component ${wrapper_unprivileged} --environment");
      $machine->mustSucceed("sleep 5; [ ! -f /tmp/wrapper.state ]");

      # Deactivate again. This test should succeed as it is idempotent.
      $machine->mustSucceed("dysnomia --type wrapper --operation deactivate --component ${wrapper_unprivileged} --environment");
      $machine->mustSucceed("sleep 5; [ ! -f /tmp/wrapper.state ]");

      # Test process module. Here we start a process which
      # loops forever. We check whether it has been started and
      # then we deactivate it again and verify whether it has been
      # stopped. We also check if the process runs as root.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type process --operation activate --component ${process} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustSucceed("[ \"\$(systemctl status disnix-\$(basename ${process}) | grep \"Active: active\")\" != \"\" ]");
      $machine->mustSucceed("[ \"\$(ps aux | grep ${process}/bin/loop | grep -v grep | grep root)\" != \"\" ]");

      # Activate again. This operation should succeed as it is idempotent.
      $machine->mustSucceed("dysnomia --type process --operation activate --component ${process} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustSucceed("[ \"\$(systemctl status disnix-\$(basename ${process}) | grep \"Active: active\")\" != \"\" ]");
      $machine->mustSucceed("[ \"\$(ps aux | grep ${process}/bin/loop | grep -v grep | grep root)\" != \"\" ]");

      # Deactivate the process
      $machine->mustSucceed("dysnomia --type process --operation deactivate --component ${process} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustFail("systemctl status disnix-\$(basename ${process})");

      # Deactivate again. This operation should succeed as it is idempotent.
      $machine->mustSucceed("dysnomia --type process --operation deactivate --component ${process} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustFail("systemctl status disnix-\$(basename ${process})");

      # Test process module. Here we start a process which
      # loops forever. We check whether it has been started and
      # then we deactivate it again and verify whether it has been
      # stopped. We also check if the process runs as an uprivileged user.
      # This test should succeed.

      $machine->mustSucceed("dysnomia --type process --operation activate --component ${process_unprivileged} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustSucceed("[ \"\$(systemctl status disnix-\$(basename ${process_unprivileged}) | grep \"Active: active\")\" != \"\" ]");
      $machine->mustSucceed("[ \"\$(ps aux | grep ${process_unprivileged}/bin/loop | grep -v grep | grep unprivileged)\" != \"\" ]");

      # Activate again. This test should succeed as the operation is idempotent.
      $machine->mustSucceed("dysnomia --type process --operation activate --component ${process_unprivileged} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustSucceed("[ \"\$(systemctl status disnix-\$(basename ${process_unprivileged}) | grep \"Active: active\")\" != \"\" ]");
      $machine->mustSucceed("[ \"\$(ps aux | grep ${process_unprivileged}/bin/loop | grep -v grep | grep unprivileged)\" != \"\" ]");

      # Wreck the service and activate again. This test should succeed as the operation is idempotent.
      my $serviceName = "disnix-\$(basename ${process_unprivileged}).service";

      $machine->mustSucceed("systemctl stop $serviceName"); # We deliberately stop the service manually
      $machine->mustSucceed("rm /etc/systemd-mutable/system/dysnomia.target.wants/$serviceName"); # We, by accident, remove the unit from the wants/ directory

      $machine->mustSucceed("dysnomia --type process --operation activate --component ${process_unprivileged} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustSucceed("[ \"\$(systemctl status disnix-\$(basename ${process_unprivileged}) | grep \"Active: active\")\" != \"\" ]");
      $machine->mustSucceed("[ \"\$(ps aux | grep ${process_unprivileged}/bin/loop | grep -v grep | grep unprivileged)\" != \"\" ]");

      # Deactivate the process
      $machine->mustSucceed("dysnomia --type process --operation deactivate --component ${process_unprivileged} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustFail("systemctl status disnix-\$(basename ${process_unprivileged})");

      # Deactivate again. This test should succeed as the operation is idempotent.
      $machine->mustSucceed("dysnomia --type process --operation deactivate --component ${process_unprivileged} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustFail("systemctl status disnix-\$(basename ${process_unprivileged})");

      # Socket activation test. We activate the process, but it should
      # only run if we attempt to connect to its corresponding socket. After we
      # have deactivated the service, it should both be terminated and the
      # socket should have disappeared.

      $machine->mustSucceed("dysnomia --type process --operation activate --component ${process_socketactivation} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustFail("ps aux | grep ${process_socketactivation} | grep -v grep");
      $machine->mustSucceed("nc -z -n -v 127.0.0.1 5123");
      $machine->mustSucceed("ps aux | grep ${process_socketactivation} | grep -v grep");
      $machine->mustSucceed("dysnomia --type process --operation deactivate --component ${process_socketactivation} --environment");
      $machine->mustSucceed("sleep 5");
      $machine->mustFail("ps aux | grep ${process_socketactivation} | grep -v grep");
      $machine->mustFail("nc -z -n -v 127.0.0.1 5123");
    '';
}

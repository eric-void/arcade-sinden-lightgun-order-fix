# arcade-sinden-lightgun-order-fix
This is a method to fix sinden lightgun initialization order at boot, for batocera systems (tested on V40, V41 & V42).

Batocera uses an approach in initializing the guns at boot that could cause them to start in random order.
Additionally, Linux itself can sometimes change device identifiers, leading to further mixing.

This method solves the problem.

*WARN: This is a work in progress, running in my own system. I never tried this in other systems!*

## Details

Batocera relies on scripts launched by udev system to initialize the gun.
That way as soon as a gun is connected its execution environment is immediately initialized. This is great for plug'n'play use, when guns are connected only when needed.
But at boot time this approach creates problems. The udev system launches all the scripts nearly at the same time, in different threads, and this creates concurrency problems. In fact the order of initialization of the environment becomes random.

To solve the problem, a code block is added to the script _/usr/bin/virtual-sindenlightgun-add_ (called by udev), so at boot time (verified by the existence of the file _/var/run/virtual-events.started_) it only adds an initialization script to be started at final init stage (by adding it in _/var/run/virtual-events.waiting_).
This initialization script will take care of starting the guns environment in the correct order.
The script _/usr/bin/virtual-sindenlightgun-remap_ is also overridden in case a refresh is needed (in the correct order).

## Installation on batocera

- copy _arcade-sinden-lightgun.sh_ and _arcade-sinden-lightgun.settings_ to _/userdata/bin_ (create the directory if not present) 
- execute:
```
chmod +x /userdata/bin/arcade-sinden-lightgun.sh
```
- edit _arcade-sinden-lightgun.settings_ for your needs (launch "/userdata/bin/arcade-sinden-lightgun.sh list" to list all lightguns detected and their _product_id_, and use this it in WANTED_ORDER setting)
- add this lines in _/usr/bin/virtual-sindenlightgun-add_, just after the first line #!/bin/bash
```
if [ ! -f "/var/run/virtual-events.started" ]; then
  exec 200>"/tmp/arcade-sinden-lightgun-init.lock"
  if flock -n 200 && ( [ ! -f "/var/run/virtual-events.waiting" ] || ! grep -q "arcade-sinden-lightgun" "/var/run/virtual-events.waiting" ); then
    echo "sindengun init - - /userdata/bin/arcade-sinden-lightgun.sh" >> /var/run/virtual-events.waiting
  fi
  exit 0
fi
```
- add this line in _/usr/bin/virtual-sindenlightgun-remap_, just after the first line #!/bin/bash
```
/userdata/bin/arcade-sinden-lightgun.sh refresh && exit $?
```
- execute _batocera_save_overlay_ system script to update batocera overlay layer and persist the changes on /usr/bin scripts.

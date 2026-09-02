# manage-swap

[![CI](https://github.com/aleksandrychev/cfengine-manage-swap/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/aleksandrychev/cfengine-manage-swap/actions/workflows/ci.yml)

CFEngine Build module which manages a swap file on Linux hosts.
It makes sure a swap file of the configured size exists, is active, survives reboots via `/etc/fstab`, and it reports the active swap files as inventory in Mission Portal.

## What it does

On every agent run, on Linux hosts:

1. Ensures the swap file exists and is only accessible by root (`0600 root:root`).
2. If the file is missing or does not have the desired size, writes it with `dd` from `/dev/zero`.
   If the file is currently active with a different size, it is deactivated with `swapoff` first.
3. Runs `mkswap` on the (inactive) file and activates it with `swapon`.
4. Once the swap file has been activated successfully, adds `<path> none swap sw 0 0` to `/etc/fstab`.
   An existing uncommented `/etc/fstab` entry for the same path is left untouched, so custom options such as `pri=10` are respected.
5. Reports inventory (see below), read from `/proc/swaps`.

Nothing is done if the input is invalid (a report line explains why) or on non-Linux hosts.

## Usage

Add the module to your CFEngine Build project and answer the input questions:

```sh
cfbs add manage-swap
cfbs input manage-swap
cfbs build
```

Pressing Enter at a question keeps the default.
If you do not enter any input, the module uses its defaults: a 2 GB swap file at `/swapfile`.

## Inputs

Both inputs live in the `manage_swap:main` bundle and can be set via `cfbs input` (interactive), Mission Portal's build page, augments (`def.json`), CMDB or host-specific data.

| Variable                          | Type   | Default     | Description                                                 |
|-----------------------------------|--------|-------------|-------------------------------------------------------------|
| `manage_swap:main.swap_size_gb`   | string | `2`         | Size of the swap file in GB. Decimals are accepted (`0.5`). |
| `manage_swap:main.swap_file_path` | string | `/swapfile` | Absolute path of the swap file.                             |

Augments example (`def.json`):

```json
{
  "variables": {
    "manage_swap:main.swap_size_gb": {
      "value": "4"
    },
    "manage_swap:main.swap_file_path": {
      "value": "/var/swapfile"
    }
  }
}
```

Changing the size of an existing swap file makes the module run `swapoff`, rewrite the file and activate it again.
`swapoff` needs enough free memory to hold the pages currently swapped out; if it fails, the module leaves the existing swap file active and retries on the next run.

## Inventory

The module reports two inventory attributes, visible in Mission Portal inventory reports and the Inventory API:

| Attribute         | Type   | Description                                                      |
|-------------------|--------|------------------------------------------------------------------|
| `Swap files`      | list   | Active swap files, i.e. entries of type `file` in `/proc/swaps`. |
| `Swap total (MB)` | number | Total size of all active swap, files and partitions, in MB.      |

## Requirements

- Linux with `util-linux` (`mkswap`, `swapon`, `swapoff`) and `dd`.
  The module does not install packages itself. If `util-linux` is missing on some hosts, the [conditional-installer](https://build.cfengine.com/modules/conditional-installer/) module can install it, for example with the package `util-linux` and the condition `linux`.
- CFEngine 3.18 or newer (the policy uses the `int()` function).
- The swap file must be on a filesystem which supports swap files.

## Testing

`tests/run-locally.sh` builds policy sets with `cfbs` and runs the functional test (`tests/functional.sh`) as root in a privileged Docker container, covering creation, idempotency, resizing, re-activation, respecting custom fstab entries, inventory, invalid input and defaults:

```sh
bash tests/run-locally.sh
```

It needs `cfbs` and Docker; CFEngine is installed inside the container with `cf-remote`.
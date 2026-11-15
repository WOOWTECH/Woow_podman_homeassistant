# Preserve existing HA integrations during upgrades

The upgrade path now chooses the existing-device seed policy after its cold backup. Equal, newer or unrecognized custom-component versions are kept as complete trees; an older known version receives the newer packaged files without deleting local additions. Existing YAML, themes, blueprints and frontend assets are retained. No user identity or device pairing is seeded. The policy is recorded so later plain installer reruns keep it. Fresh installations retain their managed-file policy.

An explicit adoption can use scripts/install.sh --preserve-existing-seed after a reviewed backup. This is not permission to bypass the image-change or legacy-container guards. Invalid/symlink paths are refused before writes.

The same merge policy preserved the original HA accounts, devices and integrations on the N100. [Validation](https://github.com/WOOWTECH/Woow_ubuntu_version_control/blob/195dcda9357100a7821407e1c8469a349acc9831/distribution/docs/existing-device-upgrades.md).

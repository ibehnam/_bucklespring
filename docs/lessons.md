# Bucklespring lessons

## Menu choices and launch validation need one profile list

A directory-backed profile can disappear after a menu renders. I use `buckle_profile_rows`
for shell rows, native-menu compilation, and `buckle_profile_valid`; a second copied list
would let the menu and action owner disagree. The built-in default stays first. Reject an
unknown or path-shaped profile before stopping the current process. Compile-time metadata
does not authorize a later launch.

Native quiet-hour callbacks leave reopening to their source-validating menu dispatcher.
The plugin still owns parsing, persistence, rejection feedback, and restarting a running
process. Two reopen owners can replace each other's frames or lose the selected row.

## `nohup` does not detach a daemon from its caller's process group

A background `nohup` child still inherited the menu or restore runner's process group. Runner
cleanup could therefore kill Bucklespring several seconds after the one-second launch check had
painted its icon green. Launch through the repository's shared detacher with a new session, closed
descriptors, an exact working directory, and an exact child process identifier. Reconciliation
must stop a live process when intent is disabled and replace it during forced code convergence.

A profile validator must consume the complete shared enumerator even after finding a match.
Returning early closes the process-substitution pipe and turns later producer writes into misleading
broken-pipe errors in the lifecycle log.

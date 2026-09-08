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

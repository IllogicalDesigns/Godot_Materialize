# Coding rules

1. **No hard-coded node paths in scripts.** A script must not resolve a widget
   with `get_node("Box/IOSrow/Paste")`, `$UI/MapsAnd3DFunctions/...`, a
   `const` path table, or any other literal node path. Every widget a script
   wires is declared as an `@export` reference and assigned in the Inspector in
   the `.tscn` file, so the scene owns the tree and the script owns the
   behaviour. When a widget moves, renaming it in the Inspector is the whole
   change; no script edit is needed.

   The same rule applies to the tests under `tests/`: they reach widgets through
   the panels' export references, not through paths.

   Each script that wires widgets ends with `_check_exports()`, called from
   `_ready()`. It reports any export that was never assigned in the Inspector,
   so a missing widget fails at load with a named error instead of a null crash
   mid-run.

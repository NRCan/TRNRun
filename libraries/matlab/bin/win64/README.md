# Staged Windows runtime

Release staging places the matched `trnrun.exe`, `trnrunq.exe`, and
`TrnRun.Interop.dll` files in this directory. They are build artifacts and are
not committed to source control. Run `just native-stage` before source-tree
integration testing or packaging.

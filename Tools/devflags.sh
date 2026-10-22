# The dev build's `swift build` flags, for Tools/build.sh and Tools/hotreload.sh (sourced: sets `flags` from `repo`).
# 80 batches of files, not one per core: the files' costs differ, and with one batch a core a few slow batches kept a
# clean build waiting on one or two cores (M1 Max: 88 s; 73 s with 80). An edit rebuilds the same either way.
flags=(--package-path "$repo" --scratch-path "$repo/.build-dev" -Xswiftc -O -Xswiftc -driver-batch-count -Xswiftc 80)

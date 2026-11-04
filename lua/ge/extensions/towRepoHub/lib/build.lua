-- Build switches. Release builds set debugTools to false; tools/package.sh refuses to package
-- while it is true (unless run with --debug). The release workflow checks that a tag v<version>
-- matches version.

return {
  -- Shown in the phone footer next to the RLS version.
  version = "1.0.0",
  -- Test tools in the phone app: test offers, short jobs, teleports, a new board, save now.
  debugTools = false,
}

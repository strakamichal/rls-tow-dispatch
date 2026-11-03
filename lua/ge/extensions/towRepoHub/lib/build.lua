-- Build switches. Release builds set debugTools to false; tools/package.sh refuses to package
-- while it is true (unless run with --debug).

return {
  -- Test tools in the phone app: test offers, short jobs, teleports, a new board, save now.
  debugTools = true,
}

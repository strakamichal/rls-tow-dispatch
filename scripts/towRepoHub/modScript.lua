-- core_modmanager temporarily wraps extensions.load while executing modScript.
-- Defer like RLS does so the extension loads through BeamNG's real loader.
core_jobsystem.create(function(job)
  job.sleep(0.25)
  setExtensionUnloadMode("towRepoHub_core", "manual")
  extensions.load("towRepoHub_core")
end)

local ADDON, ns = ...

local M = {}
ns.Migrate = M

-- Runs migrations[n](global) for every n > global.schemaVersion, ascending.
-- Returns the resulting schema version.
function M.Run(global, migrations)
  local version = global.schemaVersion or 0
  for n = version + 1, #migrations do
    migrations[n](global)
    version = n
    global.schemaVersion = n
  end
  global.schemaVersion = version
  return version
end

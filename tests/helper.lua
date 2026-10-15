-- Test helper: loads addon files (paths relative to Harvestbook/) as chunks,
-- passing ("Harvestbook", ns) just like WoW does.
local M = {}

function M.load(...)
  local ns = {}
  for _, rel in ipairs({ ... }) do
    local path = "Harvestbook/" .. rel
    local chunk, err = loadfile(path)
    if not chunk then error(err, 2) end
    chunk("Harvestbook", ns)
  end
  return ns
end

return M

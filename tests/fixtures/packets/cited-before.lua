-- the file a packet cites, as it was when the packet was saved
local M = {}

function M.depth(q)
  return #(q.tasks or {})
end

-- below the cited range
M.LIMIT = 8

return M

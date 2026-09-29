-- the file a packet cites, after a commit rewrote the cited function
local M = {}

function M.depth(q)
  if type(q) ~= "table" then return 0 end
  return #(q.tasks or {})
end

-- below the cited range
M.LIMIT = 8

return M

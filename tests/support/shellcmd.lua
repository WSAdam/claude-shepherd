-- shellcmd.lua : read back a command line core.redirectedCommand built (2026-11-04).
-- FX.taskToFiles runs `/bin/sh -c "'prog' 'arg' ... > 'out' 2> 'err'"`, every word POSIX
-- single-quoted (a quote inside one is '\''). Stubbed hs.task recorders use this to see the
-- program and its args, and to write a fake answer where the child would have.
local M = {}

-- cmd -> argv (program first), outFile, errFile; nil when it isn't one of those lines.
function M.parse(cmd)
  if type(cmd) ~= "string" then return nil end
  local words, i, n = {}, 1, #cmd
  while i <= n do
    local c = cmd:sub(i, i)
    if c == " " then
      i = i + 1
    elseif c == "'" then
      local buf = {}
      while true do
        local close = cmd:find("'", i + 1, true)
        if not close then return nil end
        buf[#buf + 1] = cmd:sub(i + 1, close - 1)
        if cmd:sub(close, close + 3) == "'\\''" then
          buf[#buf + 1] = "'"
          i = close + 3
        else
          i = close + 1
          break
        end
      end
      words[#words + 1] = { quoted = true, text = table.concat(buf) }
    else
      local stop = cmd:find(" ", i, true) or (n + 1)
      words[#words + 1] = { quoted = false, text = cmd:sub(i, stop - 1) }
      i = stop
    end
  end
  local argv, out, err = {}, nil, nil
  local k = 1
  while k <= #words do
    local w = words[k]
    if not w.quoted and w.text == ">" and words[k + 1] then out = words[k + 1].text; k = k + 2
    elseif not w.quoted and w.text == "2>" and words[k + 1] then err = words[k + 1].text; k = k + 2
    elseif w.quoted then argv[#argv + 1] = w.text; k = k + 1
    else return nil end
  end
  if #argv == 0 or not out or not err then return nil end
  return argv, out, err
end

function M.write(path, s)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(s or ""); f:close()
  return true
end

return M

-- loopvar.test.lua : no Lua file assigns to a for-loop variable (2026-09-17).
-- 2026-09-17 live: a coworker's install aborted in its test gate -- Homebrew's lua is 5.5, where a
-- for-loop variable is read-only, and cc-core.lua:5007 (queueSplitLines) did `line = line:gsub(...)`
-- inside `for line in ...`, a compile error that failed every suite loading cc-core.lua. Adam's
-- lua 5.4 accepts it, so this scanner (not the compiler) pins the rule on any Lua version.
-- Hammerspoon's embedded Lua is 5.4 today; a newer one would break the live panel the same way.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end

-- Tokens with line numbers; comments and strings (short and long) are skipped.
local function tokens(src)
  local out, i, n, line = {}, 1, #src, 1
  local function long_bracket(at)
    local eq = src:match("^%[(=*)%[", at)
    if not eq then return nil end
    local close = "]" .. eq .. "]"
    local s, e = src:find(close, at + #eq + 2, true)
    return e or n
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then line = line + 1; i = i + 1
    elseif c:match("%s") then i = i + 1
    elseif src:sub(i, i + 1) == "--" then
      local e = long_bracket(i + 2)
      if e then
        local _, nl = src:sub(i, e):gsub("\n", ""); line = line + nl; i = e + 1
      else
        local nl = src:find("\n", i, true) or n + 1; i = nl
      end
    elseif c == "[" and src:match("^%[=*%[", i) then
      local e = long_bracket(i)
      local _, nl = src:sub(i, e):gsub("\n", ""); line = line + nl; i = e + 1
      out[#out + 1] = { t = "str", line = line }
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c or d == "\n" then break
        else j = j + 1 end
      end
      out[#out + 1] = { t = "str", line = line }; i = j + 1
    elseif c:match("[%a_]") then
      local w = src:match("^[%w_]+", i); out[#out + 1] = { t = "name", v = w, line = line }; i = i + #w
    elseif c:match("%d") then
      local w = src:match("^[%w_.]+", i); out[#out + 1] = { t = "num", line = line }; i = i + #w
    else
      local two = src:sub(i, i + 1)
      local three = src:sub(i, i + 2)
      local op = (three == "...") and three
        or ((two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." or two == "::" or two == "//") and two)
        or c
      out[#out + 1] = { t = "op", v = op, line = line }; i = i + #op
    end
  end
  return out
end

local KEYWORDS = { ["and"]=1, ["break"]=1, ["do"]=1, ["else"]=1, ["elseif"]=1, ["end"]=1, ["false"]=1,
  ["for"]=1, ["function"]=1, ["goto"]=1, ["if"]=1, ["in"]=1, ["local"]=1, ["nil"]=1, ["not"]=1, ["or"]=1,
  ["repeat"]=1, ["return"]=1, ["then"]=1, ["true"]=1, ["until"]=1, ["while"]=1 }

-- Every `x = ...` (x a for-loop variable still in scope, not shadowed by a local or a function
-- parameter) -> "file:line: x".
local function offenders(path)
  local f = io.open(path, "r"); if not f then return { path .. ": unreadable" } end
  local src = f:read("*a"); f:close()
  local toks, found = tokens(src), {}
  -- blocks: each is { vars = {name=true} } opened by function/if/do/repeat/while-do/for-do
  local blocks, pendingFor, pendingFunc = { { vars = {} } }, nil, nil
  local function declare(name, isLoop)
    blocks[#blocks].vars[name] = isLoop and "loop" or "local"
  end
  local function lookup(name)
    for b = #blocks, 1, -1 do local k = blocks[b].vars[name]; if k then return k end end
    return nil
  end
  local i = 1
  while i <= #toks do
    local tk = toks[i]
    local v = tk.v
    if tk.t == "name" and v == "for" then
      local names, j = {}, i + 1
      while toks[j] and toks[j].t == "name" and not KEYWORDS[toks[j].v] do
        names[#names + 1] = toks[j].v; j = j + 1
        if toks[j] and toks[j].v == "," then j = j + 1 else break end
      end
      pendingFor = names; i = j
    elseif tk.t == "name" and (v == "function") then
      -- parameters shadow outer loop variables inside the function body
      local params, j = {}, i + 1
      while toks[j] and toks[j].v ~= "(" do j = j + 1 end
      j = j + 1
      while toks[j] and toks[j].v ~= ")" do
        if toks[j].t == "name" then params[#params + 1] = toks[j].v end
        j = j + 1
      end
      blocks[#blocks + 1] = { vars = {} }
      for _, p in ipairs(params) do declare(p, false) end
      i = j + 1
    elseif tk.t == "name" and (v == "do") then
      blocks[#blocks + 1] = { vars = {} }
      if pendingFor then for _, nme in ipairs(pendingFor) do declare(nme, true) end; pendingFor = nil end
      i = i + 1
    elseif tk.t == "name" and (v == "if" or v == "repeat") then
      blocks[#blocks + 1] = { vars = {} }; i = i + 1
    elseif tk.t == "name" and (v == "elseif" or v == "else") then
      blocks[#blocks].vars = {}; i = i + 1   -- a new branch: locals of the previous one are gone
    elseif tk.t == "name" and (v == "end" or v == "until") then
      if #blocks > 1 then table.remove(blocks) end; i = i + 1
    elseif tk.t == "name" and v == "local" then
      local j = i + 1
      if toks[j] and toks[j].v == "function" then
        if toks[j + 1] and toks[j + 1].t == "name" then declare(toks[j + 1].v, false) end
        i = j
      else
        -- declared once the statement ends; the right-hand side still sees the outer name,
        -- which is fine: reading a loop variable is allowed
        local names = {}
        while toks[j] and toks[j].t == "name" and not KEYWORDS[toks[j].v] do
          names[#names + 1] = toks[j].v; j = j + 1
          if toks[j] and toks[j].v == "<" then j = j + 3 end   -- <const>/<close>
          if toks[j] and toks[j].v == "," then j = j + 1 else break end
        end
        for _, nme in ipairs(names) do declare(nme, false) end
        i = j
      end
    elseif tk.t == "name" and not KEYWORDS[v] then
      -- an assignment target: NAME followed by `=` or `,` ... `=`, not after `.`/`:`/`local`
      local prev = toks[i - 1]
      local isField = prev and (prev.v == "." or prev.v == ":")
      if not isField then
        local j, targets = i, {}
        while toks[j] and toks[j].t == "name" and not KEYWORDS[toks[j].v] do
          targets[#targets + 1] = toks[j]
          if toks[j + 1] and toks[j + 1].v == "," and toks[j + 2] and toks[j + 2].t == "name" then j = j + 2
          else break end
        end
        local after = toks[j + 1]
        local stmtStart = (not prev) or prev.t ~= "op" or prev.v == ";" or prev.v == ")" or prev.v == "]" or prev.v == "}"
        if prev and prev.t == "name" and not KEYWORDS[prev.v] then stmtStart = true end
        if prev and prev.t == "name" and KEYWORDS[prev.v] then
          stmtStart = (prev.v == "do" or prev.v == "then" or prev.v == "else" or prev.v == "end" or prev.v == "repeat"
            or prev.v == "break" or prev.v == "return" and false)
        end
        if prev and (prev.t == "str" or prev.t == "num") then stmtStart = true end
        if stmtStart and after and after.v == "=" then
          for _, t in ipairs(targets) do
            if lookup(t.v) == "loop" then found[#found + 1] = path:gsub("^.*/%.%./", "") .. ":" .. t.line .. ": " .. t.v end
          end
          i = j + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    elseif tk.t == "name" and v == "while" then
      i = i + 1   -- its `do` opens the block
    else
      i = i + 1
    end
  end
  return found
end

-- the scanner itself: catches the 2026-09-17 shape, and leaves legal code alone
local tmp = os.tmpname()
local function scan(src) local f = io.open(tmp, "w"); f:write(src); f:close(); return offenders(tmp) end
check("scanner: `for line in ... do line = ...` is caught",
      #scan('local function f(t)\n  for line in t:gmatch("x") do\n    line = line:gsub("a", "b")\n  end\nend\n') == 1)
check("scanner: a numeric for's variable is caught too", #scan("for i = 1, 3 do\n  if i then i = 2 end\nend\n") == 1)
check("scanner: a local that shadows the loop variable may be assigned",
      #scan('for line in x do\n  local line = line:lower()\n  line = line .. "!"\nend\n') == 0)
check("scanner: reading the loop variable and assigning a field are fine",
      #scan("for k, v in pairs(t) do\n  t.v = v\n  out[k] = v == 1\nend\n") == 0)
check("scanner: after the loop the name is free again", #scan("for i = 1, 2 do end\ni = 5\n") == 0)
check("scanner: a function parameter with the same name may be assigned",
      #scan("for s in x do\n  local function g(s) s = 1 end\nend\n") == 0)
os.remove(tmp)

local files = {}
local p = io.popen('git -C "' .. ROOT .. '" ls-files "*.lua"')
if p then for l in p:lines() do files[#files + 1] = l end; p:close() end
check("found the repo's Lua files to scan (" .. #files .. ")", #files > 5)
for _, f in ipairs(files) do
  local bad = offenders(ROOT .. f)
  check(f .. " assigns to no for-loop variable" .. (#bad > 0 and ("  (" .. table.concat(bad, ", ") .. ")") or ""), #bad == 0)
end

print("-- loopvar.test.lua: " .. run .. " run, " .. failed .. " failed --")
os.exit(failed == 0 and 0 or 1)
